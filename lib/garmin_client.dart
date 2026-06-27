/// Authentication engine for Garmin Connect (Dart port of garminconnect).
///
/// Strategy chain (each strategy is tried in order; only auth errors stop it):
/// 1. Mobile iOS login (sso.garmin.com/mobile/api/login)
/// 2. SSO embed widget login (HTML form flow)
/// 3. Portal web login (sso.garmin.com/portal/api/login, anti-WAF delay)
///
/// TLS fingerprint impersonation (curl_cffi in the Python original) is not
/// available in Dart, so the cffi/requests variants collapse into one plain
/// HTTP attempt per strategy.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'http_session.dart';
import 'logging.dart';

class GarminAuthException implements Exception {
  final String message;
  GarminAuthException(this.message);
  @override
  String toString() => 'GarminAuthException: $message';
}

class GarminTooManyRequestsException implements Exception {
  final String message;
  GarminTooManyRequestsException(this.message);
  @override
  String toString() => 'GarminTooManyRequestsException: $message';
}

class GarminConnectionException implements Exception {
  final String message;
  final int? statusCode;
  GarminConnectionException(this.message, {this.statusCode});
  @override
  String toString() => 'GarminConnectionException: $message';
}

class _MfaRequired implements Exception {}

// -- iOS mobile app constants (Strategy 1) --
const _iosSsoClientId = 'GCM_IOS_DARK';
const _iosServiceUrl = 'https://mobile.integration.garmin.com/gcm/ios';
const _iosLoginUa =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148';

// -- Portal (fallback) constants --
const _portalSsoClientId = 'GarminConnect';
const _desktopUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/131.0.0.0 Safari/537.36';

// -- Anti-WAF delay bounds (seconds) --
const _loginDelayMinS = 10.0;
const _loginDelayMaxS = 20.0;
const _widgetDelayMinS = 3.0;
const _widgetDelayMaxS = 8.0;

// -- Native API headers --
const _nativeApiUserAgent = 'GCM-Android-5.23';
const _nativeXGarminUserAgent =
    'com.garmin.android.apps.connectmobile/5.23; ; Google/sdk_gphone64_arm64/google; '
    'Android/33; Dalvik/2.1.0';

const _diGrantType =
    'https://connectapi.garmin.com/di-oauth2-service/oauth/grant/service_ticket';
const _diClientIds = <String>[
  'GARMIN_CONNECT_MOBILE_ANDROID_DI_2025Q2',
  'GARMIN_CONNECT_MOBILE_ANDROID_DI_2024Q4',
  'GARMIN_CONNECT_MOBILE_ANDROID_DI',
  'GARMIN_CONNECT_MOBILE_IOS_DI',
];

final _csrfRe = RegExp(r'name="_csrf"\s+value="(.+?)"');
final _titleRe = RegExp(r'<title>(.+?)</title>');
final _ticketRe = RegExp(r'embed\?ticket=([^"]+)"');

Map<String, String> _nativeHeaders([Map<String, String>? extra]) => {
  'User-Agent': _nativeApiUserAgent,
  'X-Garmin-User-Agent': _nativeXGarminUserAgent,
  'X-Garmin-Paired-App-Version': '10861',
  'X-Garmin-Client-Platform': 'Android',
  'X-App-Ver': '10861',
  'X-Lang': 'en',
  'X-GCExperience': 'GC5',
  'Accept-Language': 'en-US,en;q=0.9',
  ...?extra,
};

String _buildBasicAuth(String clientId) =>
    'Basic ${base64.encode(utf8.encode('$clientId:'))}';

typedef MfaPrompt = FutureOr<String> Function();

/// A client to communicate with Garmin Connect.
class GarminClient {
  final String domain;
  final MfaPrompt? promptMfa;
  final int retryAttempts;
  final double retryMinWait;
  final double retryMaxWait;

  late final String _sso = 'https://sso.$domain';
  late final String _connect = 'https://connect.$domain';
  late final String _connectapi = 'https://connectapi.$domain';
  late final String _portalServiceUrl = 'https://connect.$domain/app';
  late final String _diTokenUrl =
      'https://diauth.$domain/di-oauth2-service/oauth/token';

  String? diToken;
  String? diRefreshToken;
  String? diClientId;
  String? jwtWeb;
  String? csrfToken;

  final HttpSession _apiSession = HttpSession();
  String? _tokenstorePath;

  final _random = Random();

  // MFA continuation state.
  HttpSession? _mfaSession;
  Map<String, String> _mfaLoginParams = const {};
  Map<String, String> _mfaPostHeaders = const {};
  String _mfaFlow = 'portal';
  String _mfaMethod = 'email';
  String? _mfaServiceUrl;
  SessionResponse? _widgetLastResp;

  GarminClient({
    required this.domain,
    this.promptMfa,
    this.retryAttempts = 3,
    this.retryMinWait = 1.0,
    this.retryMaxWait = 10.0,
  });

  bool get isAuthenticated => (diToken != null) || (jwtWeb != null);

  Map<String, String> getApiHeaders() {
    if (!isAuthenticated) {
      throw GarminAuthException('Not authenticated');
    }
    if (diToken != null) {
      return _nativeHeaders({
        'Authorization': 'Bearer $diToken',
        'Accept': 'application/json',
      });
    }
    final headers = <String, String>{
      'Accept': 'application/json',
      'NK': 'NT',
      'Origin': _connect,
      'Referer': '$_connect/modern/',
      'DI-Backend': 'connectapi.$domain',
      'Cookie': 'JWT_WEB=$jwtWeb',
    };
    if (csrfToken != null) headers['connect-csrf-token'] = csrfToken!;
    return headers;
  }

  // ---------------------------------------------------------------------- //
  //  LOGIN                                                                  //
  // ---------------------------------------------------------------------- //

  Future<void> login(
    String email,
    String password, {
    String? tokenstore,
  }) async {
    if (tokenstore != null) {
      _tokenstorePath = tokenstore;
      final loaded = await _tryLoadTokens(tokenstore);
      if (loaded) {
        if (diRefreshToken != null && _tokenExpiresSoon()) {
          logDebug('Token expiring soon, refreshing proactively');
          await _refreshSession();
        }
        await _validateSession();
        return;
      }
    }

    if (email.isEmpty || password.isEmpty) {
      throw GarminAuthException('Username and password are required');
    }

    await _runLoginChain(email, password);

    if (tokenstore != null) {
      try {
        await dump(tokenstore);
      } catch (_) {
        /* best effort */
      }
    }

    await _validateSession();
  }

  Future<void> _runLoginChain(String email, String password) async {
    final strategies = <(String, Future<void> Function())>[
      ('mobile', () => _mobileLogin(email, password)),
      ('widget', () => _widgetLogin(email, password)),
      ('portal', () => _portalLogin(email, password)),
    ];

    Object? lastErr;
    var rateLimited = 0;

    for (final (name, run) in strategies) {
      try {
        logDebug('Trying login strategy: $name');
        await run();
        return;
      } on GarminAuthException {
        rethrow;
      } on _MfaRequired {
        if (promptMfa == null) {
          throw GarminAuthException(
            'MFA Required but no prompt_mfa mechanism supplied',
          );
        }
        final code = await promptMfa!();
        await _completeMfa(code);
        return;
      } on GarminTooManyRequestsException catch (e) {
        logWarning('$name returned 429: ${e.message}');
        rateLimited++;
        lastErr = e;
      } catch (e) {
        logWarning('$name failed: $e');
        lastErr = e;
      }
    }

    if (rateLimited == strategies.length) {
      throw GarminTooManyRequestsException(
        'All login strategies rate limited (429). Try again later.',
      );
    }
    throw GarminConnectionException('All login strategies exhausted: $lastErr');
  }

  // -- Strategy 1: Mobile iOS login -------------------------------------- //

  Future<void> _mobileLogin(String email, String password) async {
    final sess = HttpSession();
    final loginParams = {
      'clientId': _iosSsoClientId,
      'locale': 'en-US',
      'service': _iosServiceUrl,
    };
    final loginHeaders = {
      'User-Agent': _iosLoginUa,
      'Accept': 'application/json, text/plain, */*',
      'Content-Type': 'application/json',
      'Origin': _sso,
    };

    final r = await sess.postJson(
      Uri.parse('$_sso/mobile/api/login'),
      params: loginParams,
      headers: loginHeaders,
      json: {
        'username': email,
        'password': password,
        'rememberMe': true,
        'captchaToken': '',
      },
    );

    if (r.statusCode == 429) {
      throw GarminTooManyRequestsException('Mobile login returned 429');
    }

    final dynamic res = _tryJson(r);
    if (res is! Map) {
      throw GarminConnectionException(
        'Mobile login failed (non-JSON): HTTP ${r.statusCode}',
      );
    }

    final respType = (res['responseStatus'] as Map?)?['type'];
    if (respType == 'MFA_REQUIRED') {
      _mfaMethod =
          ((res['customerMfaInfo'] as Map?)?['mfaLastMethodUsed'] ?? 'email')
              .toString();
      _mfaSession = sess;
      _mfaLoginParams = loginParams;
      _mfaPostHeaders = loginHeaders;
      _mfaServiceUrl = _iosServiceUrl;
      _mfaFlow = 'ios';
      throw _MfaRequired();
    }
    if (respType == 'SUCCESSFUL') {
      await _establishSession(
        res['serviceTicketId'] as String,
        session: sess,
        serviceUrl: _iosServiceUrl,
      );
      return;
    }
    if (respType == 'INVALID_USERNAME_PASSWORD') {
      throw GarminAuthException(
        '401 Unauthorized (Invalid Username or Password)',
      );
    }
    if ((res['error'] as Map?)?['status-code'] == '429') {
      throw GarminTooManyRequestsException('Mobile login: 429 in JSON body');
    }
    throw GarminConnectionException('Mobile login failed: $res');
  }

  // -- Strategy 2: SSO embed widget login -------------------------------- //

  Future<void> _widgetLogin(String email, String password) async {
    final sess = HttpSession(headers: {'User-Agent': _desktopUserAgent});
    final ssoBase = '$_sso/sso';
    final ssoEmbed = '$ssoBase/embed';
    final embedParams = {
      'id': 'gauth-widget',
      'embedWidget': 'true',
      'gauthHost': ssoBase,
    };
    final signinParams = {
      ...embedParams,
      'gauthHost': ssoEmbed,
      'service': ssoEmbed,
      'source': ssoEmbed,
      'redirectAfterAccountLoginUrl': ssoEmbed,
      'redirectAfterAccountCreationUrl': ssoEmbed,
    };

    var r = await sess.get(Uri.parse(ssoEmbed), params: embedParams);
    if (r.statusCode == 429) {
      throw GarminTooManyRequestsException('Widget embed GET returned 429');
    }
    if (!r.ok) {
      throw GarminConnectionException('Widget embed returned ${r.statusCode}');
    }

    r = await sess.get(
      Uri.parse('$ssoBase/signin'),
      params: signinParams,
      headers: {'Referer': ssoEmbed},
    );
    if (r.statusCode == 429) {
      throw GarminTooManyRequestsException('Widget signin GET returned 429');
    }

    final csrfMatch = _csrfRe.firstMatch(r.body);
    if (csrfMatch == null) {
      throw GarminConnectionException('Widget login: missing CSRF token');
    }

    await _antiWafDelay(_widgetDelayMinS, _widgetDelayMaxS);

    r = await sess.request(
      'POST',
      Uri.parse('$ssoBase/signin'),
      params: signinParams,
      headers: {'Referer': r.url.toString()},
      formFields: {
        'username': email,
        'password': password,
        'embed': 'true',
        '_csrf': csrfMatch.group(1)!,
      },
    );

    if (r.statusCode == 429) {
      throw GarminTooManyRequestsException('Widget signin POST returned 429');
    }

    final title = _titleRe.firstMatch(r.body)?.group(1) ?? '';
    final titleLower = title.toLowerCase();
    if ([
      'bad gateway',
      'service unavailable',
      'cloudflare',
      '502',
      '503',
    ].any(titleLower.contains)) {
      throw GarminConnectionException("Widget login: server error '$title'");
    }
    if ([
      'locked',
      'invalid',
      'incorrect',
      'account error',
    ].any(titleLower.contains)) {
      throw GarminAuthException("Widget authentication failed: '$title'");
    }
    if (title.contains('MFA')) {
      _mfaSession = sess;
      _mfaLoginParams = signinParams;
      _mfaPostHeaders = {'Referer': r.url.toString()};
      _mfaFlow = 'widget';
      _widgetLastResp = r;
      throw _MfaRequired();
    }
    if (title != 'Success') {
      throw GarminConnectionException(
        "Widget login: unexpected title '$title'",
      );
    }

    final ticketMatch = _ticketRe.firstMatch(r.body);
    if (ticketMatch == null) {
      throw GarminConnectionException('Widget login: missing service ticket');
    }
    await _establishSession(
      ticketMatch.group(1)!,
      session: sess,
      serviceUrl: ssoEmbed,
    );
  }

  // -- Strategy 3: Portal web login -------------------------------------- //

  Future<void> _portalLogin(String email, String password) async {
    final sess = HttpSession(headers: {'User-Agent': _desktopUserAgent});
    final signinUrl = '$_sso/portal/sso/en-US/sign-in';

    final getResp = await sess.get(
      Uri.parse(signinUrl),
      params: {'clientId': _portalSsoClientId, 'service': _portalServiceUrl},
      headers: {
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
      },
    );
    if (getResp.statusCode == 429) {
      throw GarminTooManyRequestsException('Portal login GET returned 429');
    }

    await _antiWafDelay(_loginDelayMinS, _loginDelayMaxS);

    final loginParams = {
      'clientId': _portalSsoClientId,
      'locale': 'en-US',
      'service': _portalServiceUrl,
    };
    final postHeaders = {
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'en-US,en;q=0.9',
      'Content-Type': 'application/json',
      'Origin': _sso,
      'Referer':
          '$signinUrl?clientId=$_portalSsoClientId&service=$_portalServiceUrl',
    };

    final r = await sess.postJson(
      Uri.parse('$_sso/portal/api/login'),
      params: loginParams,
      headers: postHeaders,
      json: {
        'username': email,
        'password': password,
        'rememberMe': true,
        'captchaToken': '',
      },
    );
    if (r.statusCode == 429) {
      throw GarminTooManyRequestsException('Portal login POST returned 429');
    }

    final dynamic res = _tryJson(r);
    if (res is! Map) {
      throw GarminConnectionException(
        'Portal login failed (non-JSON): HTTP ${r.statusCode}',
      );
    }

    final respType = (res['responseStatus'] as Map?)?['type'];
    if (respType == 'MFA_REQUIRED') {
      _mfaMethod =
          ((res['customerMfaInfo'] as Map?)?['mfaLastMethodUsed'] ?? 'email')
              .toString();
      _mfaSession = sess;
      _mfaLoginParams = loginParams;
      _mfaPostHeaders = postHeaders;
      _mfaServiceUrl = _portalServiceUrl;
      _mfaFlow = 'portal';
      throw _MfaRequired();
    }
    if (respType == 'SUCCESSFUL') {
      await _establishSession(
        res['serviceTicketId'] as String,
        session: sess,
        serviceUrl: _portalServiceUrl,
      );
      return;
    }
    if (respType == 'INVALID_USERNAME_PASSWORD') {
      throw GarminAuthException(
        '401 Unauthorized (Invalid Username or Password)',
      );
    }
    if ((res['error'] as Map?)?['status-code'] == '429') {
      throw GarminTooManyRequestsException('Portal login: 429 in JSON body');
    }
    throw GarminConnectionException('Portal web login failed: $res');
  }

  // -- MFA completion ---------------------------------------------------- //

  Future<void> _completeMfa(String mfaCode) async {
    if (_mfaFlow == 'widget') {
      await _completeMfaWidget(mfaCode);
      return;
    }
    final sess = _mfaSession!;
    final mfaJson = {
      'mfaMethod': _mfaMethod,
      'mfaVerificationCode': mfaCode,
      'rememberMyBrowser': true,
      'reconsentList': <dynamic>[],
      'mfaSetup': false,
    };
    final flowPath = _mfaFlow == 'ios' ? 'mobile' : _mfaFlow;

    final endpoints = <(String, Map<String, String>)>[
      ('$_sso/$flowPath/api/mfa/verifyCode', _mfaLoginParams),
    ];
    if (flowPath == 'mobile') {
      endpoints.add((
        '$_sso/portal/api/mfa/verifyCode',
        {
          'clientId': _portalSsoClientId,
          'locale': 'en-US',
          'service': _portalServiceUrl,
        },
      ));
    } else {
      endpoints.add((
        '$_sso/mobile/api/mfa/verifyCode',
        {
          'clientId': _iosSsoClientId,
          'locale': 'en-US',
          'service': _iosServiceUrl,
        },
      ));
    }

    final failures = <String>[];
    var rateLimited = 0;

    for (final (url, params) in endpoints) {
      SessionResponse r;
      try {
        r = await sess.postJson(
          Uri.parse(url),
          params: params,
          headers: _mfaPostHeaders,
          json: mfaJson,
        );
      } catch (e) {
        failures.add('$url: connection error $e');
        continue;
      }
      if (r.statusCode == 429) {
        failures.add('$url: HTTP 429');
        rateLimited++;
        continue;
      }
      final dynamic res = _tryJson(r);
      if (res is! Map) {
        failures.add('$url: HTTP ${r.statusCode} non-JSON');
        continue;
      }
      if ((res['error'] as Map?)?['status-code'] == '429') {
        failures.add('$url: 429 in JSON body');
        rateLimited++;
        continue;
      }
      if ((res['responseStatus'] as Map?)?['type'] == 'SUCCESSFUL') {
        final svc =
            _mfaFlow == 'ios'
                ? _iosServiceUrl
                : (_mfaServiceUrl ?? _portalServiceUrl);
        await _establishSession(
          res['serviceTicketId'] as String,
          session: sess,
          serviceUrl: svc,
        );
        return;
      }
      failures.add('$url: $res');
    }

    if (rateLimited == endpoints.length) {
      throw GarminTooManyRequestsException(
        'MFA verification rate limited on all endpoints: $failures',
      );
    }
    throw GarminAuthException('MFA verification failed: $failures');
  }

  Future<void> _completeMfaWidget(String mfaCode) async {
    final sess = _mfaSession;
    final r0 = _widgetLastResp;
    if (sess == null || r0 == null) {
      throw GarminAuthException('Missing widget MFA context');
    }
    final csrfMatch = _csrfRe.firstMatch(r0.body);
    if (csrfMatch == null) {
      throw GarminAuthException('Widget MFA: missing CSRF token');
    }
    final r = await sess.request(
      'POST',
      Uri.parse('$_sso/sso/verifyMFA/loginEnterMfaCode'),
      params: _mfaLoginParams,
      headers: _mfaPostHeaders,
      formFields: {
        'mfa-code': mfaCode,
        'embed': 'true',
        '_csrf': csrfMatch.group(1)!,
        'fromPage': 'setupEnterMfaCode',
      },
    );
    if (r.statusCode == 429) {
      throw GarminTooManyRequestsException('Widget MFA verify returned 429');
    }
    final title = _titleRe.firstMatch(r.body)?.group(1) ?? '';
    if (title != 'Success') {
      throw GarminAuthException('Widget MFA failed: $title');
    }
    final ticketMatch = _ticketRe.firstMatch(r.body);
    if (ticketMatch == null) {
      throw GarminAuthException('Widget MFA: missing service ticket');
    }
    await _establishSession(
      ticketMatch.group(1)!,
      session: sess,
      serviceUrl: '$_sso/sso/embed',
    );
  }

  // -- Session establishment --------------------------------------------- //

  Future<void> _establishSession(
    String ticket, {
    required HttpSession session,
    String? serviceUrl,
  }) async {
    try {
      await _exchangeServiceTicket(ticket, serviceUrl: serviceUrl);
      return;
    } catch (e) {
      logWarning('DI token exchange failed ($e), falling back to JWT_WEB');
    }

    final svc = serviceUrl ?? _iosServiceUrl;
    await session.get(
      Uri.parse(svc),
      params: {'ticket': ticket},
      followRedirects: true,
    );
    final jwt = session.cookies['JWT_WEB'];
    if (jwt == null) {
      throw GarminAuthException(
        'JWT_WEB cookie not set after ticket consumption',
      );
    }
    jwtWeb = jwt;
  }

  Future<void> _exchangeServiceTicket(
    String ticket, {
    String? serviceUrl,
  }) async {
    final svcUrl = serviceUrl ?? _iosServiceUrl;
    String? token;
    String? refresh;
    String? clientIdOut;

    for (final clientId in _diClientIds) {
      final r = await _apiSession.request(
        'POST',
        Uri.parse(_diTokenUrl),
        headers: _nativeHeaders({
          'Authorization': _buildBasicAuth(clientId),
          'Accept': 'application/json,text/html;q=0.9,*/*;q=0.8',
          'Content-Type': 'application/x-www-form-urlencoded',
          'Cache-Control': 'no-cache',
        }),
        formFields: {
          'client_id': clientId,
          'service_ticket': ticket,
          'grant_type': _diGrantType,
          'service_url': svcUrl,
        },
      );
      if (r.statusCode == 429) {
        throw GarminTooManyRequestsException('DI token exchange rate limited');
      }
      if (!r.ok) {
        logDebug('DI exchange failed for $clientId: ${r.statusCode}');
        continue;
      }
      try {
        final data = r.jsonBody() as Map;
        token = data['access_token'] as String;
        refresh = data['refresh_token'] as String?;
        clientIdOut = _extractClientIdFromJwt(token) ?? clientId;
        break;
      } catch (e) {
        logDebug('DI token parse failed for $clientId: $e');
      }
    }

    if (token == null) {
      throw GarminAuthException('DI token exchange failed for all client IDs');
    }
    diToken = token;
    diRefreshToken = refresh;
    diClientId = clientIdOut;
  }

  Future<void> _refreshDiToken() async {
    if (diRefreshToken == null || diClientId == null) {
      throw GarminAuthException('No DI refresh token available');
    }
    final r = await _apiSession.request(
      'POST',
      Uri.parse(_diTokenUrl),
      headers: _nativeHeaders({
        'Authorization': _buildBasicAuth(diClientId!),
        'Accept': 'application/json',
        'Content-Type': 'application/x-www-form-urlencoded',
        'Cache-Control': 'no-cache',
      }),
      formFields: {
        'grant_type': 'refresh_token',
        'client_id': diClientId!,
        'refresh_token': diRefreshToken!,
      },
    );
    if (!r.ok) {
      throw GarminAuthException('DI token refresh failed: ${r.statusCode}');
    }
    final data = r.jsonBody() as Map;
    diToken = data['access_token'] as String;
    diRefreshToken = (data['refresh_token'] as String?) ?? diRefreshToken;
    diClientId = _extractClientIdFromJwt(diToken!) ?? diClientId;
  }

  Future<void> _refreshSession() async {
    if (diToken != null) {
      try {
        await _refreshDiToken();
        if (_tokenstorePath != null) {
          try {
            await dump(_tokenstorePath!);
          } catch (_) {
            /* best effort */
          }
        }
      } catch (err) {
        logDebug('DI token refresh failed: $err');
      }
    }
  }

  String? _extractClientIdFromJwt(String token) {
    try {
      final parts = token.split('.');
      if (parts.length < 2) return null;
      final payload = json.decode(_b64UrlDecode(parts[1])) as Map;
      final value = payload['client_id'];
      return value?.toString();
    } catch (_) {
      return null;
    }
  }

  bool _tokenExpiresSoon() {
    final token = diToken ?? jwtWeb;
    if (token == null) return false;
    try {
      final parts = token.split('.');
      if (parts.length < 2) return false;
      final payload = json.decode(_b64UrlDecode(parts[1])) as Map;
      final exp = payload['exp'];
      if (exp is int) {
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        if (now > (exp - 900)) return true;
      }
    } catch (_) {
      logDebug('Failed to check token expiry');
    }
    return false;
  }

  // -- Token persistence ------------------------------------------------- //

  String dumps() => json.encode({
    'di_token': diToken,
    'di_refresh_token': diRefreshToken,
    'di_client_id': diClientId,
  });

  Future<void> dump(String path) async {
    final file = _resolveTokenFile(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(dumps());
  }

  Future<bool> _tryLoadTokens(String path) async {
    try {
      final file = _resolveTokenFile(path);
      if (!await file.exists()) return false;
      final data = json.decode(await file.readAsString()) as Map;
      diToken = data['di_token'] as String?;
      diRefreshToken = data['di_refresh_token'] as String?;
      diClientId = data['di_client_id'] as String?;
      if (!isAuthenticated) return false;
      return true;
    } catch (e) {
      logDebug('Failed to cleanly load tokens from $path: $e');
      return false;
    }
  }

  File _resolveTokenFile(String path) {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.directory || !path.endsWith('.json')) {
      return File('$path/garmin_tokens.json');
    }
    return File(path);
  }

  // -- Profile validation ------------------------------------------------ //

  Future<void> _validateSession() async {
    Map<dynamic, dynamic>? prof;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final p = await connectapi('/userprofile-service/socialProfile');
        if (p is Map) {
          prof = p;
          break;
        }
      } catch (e) {
        if (attempt == 2) {
          throw GarminAuthException('Failed to retrieve social profile');
        }
        logDebug('Retrying social profile fetch: $e');
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    if (prof == null) {
      throw GarminAuthException('Invalid profile data found');
    }
  }

  // -- Requests ---------------------------------------------------------- //

  Future<dynamic> connectapi(String path, {Map<String, String>? params}) async {
    final resp = await _withRetry(
      () => _runRequest('GET', path, params: params),
    );
    return resp.statusCode == 204 ? <String, dynamic>{} : resp.jsonBody();
  }

  Future<List<int>> download(String path, {Map<String, String>? params}) async {
    final resp = await _withRetry(
      () => _runRequest('GET', path, params: params, extra: {'Accept': '*/*'}),
    );
    return resp.bodyBytes;
  }

  Future<SessionResponse> _runRequest(
    String method,
    String path, {
    Map<String, String>? params,
    Map<String, String>? extra,
  }) async {
    if (isAuthenticated && _tokenExpiresSoon()) {
      await _refreshSession();
    }

    final url =
        path.startsWith('http')
            ? Uri.parse(path)
            : Uri.parse(
              '$_connectapi/${path.replaceFirst(RegExp(r'^/+'), '')}',
            );

    final headers = getApiHeaders();
    if (extra != null) headers.addAll(extra);

    var resp = await _apiSession.request(
      method,
      url,
      headers: headers,
      params: params,
      timeout: const Duration(seconds: 30),
    );

    if (resp.statusCode == 401) {
      await _refreshSession();
      resp = await _apiSession.request(
        method,
        url,
        headers: getApiHeaders(),
        params: params,
      );
    }

    if (resp.statusCode == 204) return resp;

    if (resp.statusCode >= 400) {
      var msg = 'API Error ${resp.statusCode}';
      final body = resp.body;
      if (body.length < 500) msg += ' - $body';
      throw GarminConnectionException(msg, statusCode: resp.statusCode);
    }
    return resp;
  }

  Future<SessionResponse> _withRetry(
    Future<SessionResponse> Function() fn,
  ) async {
    final attempts = retryAttempts < 0 ? 0 : retryAttempts;
    Object? lastErr;
    for (var attempt = 0; attempt <= attempts; attempt++) {
      try {
        return await fn();
      } on GarminAuthException {
        rethrow;
      } on GarminTooManyRequestsException {
        rethrow;
      } on GarminConnectionException catch (e) {
        lastErr = e;
        final status = e.statusCode;
        final retryable = status != null && status >= 500 && status < 600;
        if (!retryable || attempt == attempts) rethrow;
      } on SocketException catch (e) {
        lastErr = e;
        if (attempt == attempts) rethrow;
      } on TimeoutException catch (e) {
        lastErr = e;
        if (attempt == attempts) rethrow;
      }
      await Future<void>.delayed(_backoffDelay(attempt));
    }
    throw GarminConnectionException('Request failed: $lastErr');
  }

  Duration _backoffDelay(int attempt) {
    final base = min(retryMaxWait, retryMinWait * pow(2, attempt));
    final seconds = base * (0.5 + _random.nextDouble() * 0.5);
    return Duration(milliseconds: (seconds * 1000).round());
  }

  Future<void> _antiWafDelay(double minS, double maxS) async {
    final seconds = minS + _random.nextDouble() * (maxS - minS);
    logDebug('Waiting ${seconds.toStringAsFixed(0)}s anti-WAF delay...');
    await Future<void>.delayed(
      Duration(milliseconds: (seconds * 1000).round()),
    );
  }

  dynamic _tryJson(SessionResponse r) {
    try {
      return r.jsonBody();
    } catch (_) {
      return null;
    }
  }

  String _b64UrlDecode(String input) {
    var s = input.replaceAll('-', '+').replaceAll('_', '/');
    s = s.padRight(s.length + (4 - s.length % 4) % 4, '=');
    return utf8.decode(base64.decode(s));
  }
}

/// iGPSPORT route upload and roadbook client.
library;

import 'dart:convert';
import 'dart:io';

import 'package:mime/mime.dart';

import 'config.dart';
import 'http_session.dart';
import 'json_util.dart';
import 'logging.dart';
import 'models.dart';
import 'poi.dart';

const _roadlistHeaders = {
  'accept': '*/*',
  'accept-language': 'ja,en-US;q=0.9,en;q=0.8',
  'x-requested-with': 'XMLHttpRequest',
  'referer': defaultIgpsportWebRoadlistReferer,
  'sec-fetch-dest': 'empty',
  'sec-fetch-mode': 'cors',
  'sec-fetch-site': 'same-origin',
};

class IgpsportClient {
  final String username;
  final String password;
  final String domain;
  final File _webCookieFile;
  final int roadlistPageSize;
  final HttpSession _session;
  final HttpSession _webSession;

  IgpsportClient({
    required this.username,
    required this.password,
    required this.domain,
    required String referer,
    String webCookieFile = defaultIgpsportWebCookieFile,
    int roadlistPageSize = defaultIgpsportRoadlistPageSize,
  }) : _webCookieFile = File(webCookieFile),
       roadlistPageSize = roadlistPageSize < 1 ? 1 : roadlistPageSize,
       _session = HttpSession(
         headers: {
           'user-agent': browserUserAgent,
           'accept': 'application/json, text/plain, */*',
           'origin': referer,
           'referer': referer,
         },
       ),
       _webSession = HttpSession(
         headers: {
           'user-agent': browserUserAgent,
           'accept': '*/*',
           'x-requested-with': 'XMLHttpRequest',
           'origin': defaultIgpsportWebBaseUrl,
           'referer': defaultIgpsportWebReferer,
         },
       );

  String get _baseUrl => 'https://$domain/service';

  Future<void> login() async {
    final response = await _session.postJson(
      Uri.parse('$_baseUrl/auth/account/login'),
      json: {
        'username': username,
        'password': password,
        'appId': 'igpsport-web',
      },
      timeout: const Duration(seconds: 30),
    );
    if (!response.ok) {
      throw StateError('iGPSPORT login failed: HTTP ${response.statusCode}');
    }
    final data = response.jsonBody();
    if (jsonGetCi(data, 'code') != 0) {
      throw StateError('iGPSPORT login failed: $data');
    }
    final tokenData = jsonGetCi(data, 'data');
    final token = jsonGetCi(tokenData, 'accessToken');
    if (token == null || (token is String && token.isEmpty)) {
      throw StateError(
        'iGPSPORT login succeeded but no access token was found',
      );
    }
    _session.defaultHeaders['authorization'] = 'Bearer $token';
    logInfo('Authenticated to iGPSPORT');
  }

  Future<void> uploadRoute(
    String routeName,
    String filename,
    List<int> content,
  ) => _uploadRouteViaWeb(routeName, filename, content);

  Future<SessionResponse> _fetchRoadlistPage(int pageIndex) {
    return _webSession.get(
      Uri.parse(defaultIgpsportWebRoadlistUrl),
      params: {
        'type': 'mine',
        'pageSize': '$roadlistPageSize',
        'pageIndex': '$pageIndex',
      },
      headers: _roadlistHeaders,
      timeout: const Duration(seconds: 30),
    );
  }

  /// Return existing roadbooks from iGPSPORT web RoadList API.
  Future<List<RoadBookSummary>> getMyRoadbooks() async {
    await _restoreWebCookiesFromDisk();
    final pageSize = roadlistPageSize;
    var pageIndex = 1;
    final allItems = <dynamic>[];

    while (true) {
      var response = await _fetchRoadlistPage(pageIndex);
      if (_looksLikeLoginRequired(response)) {
        await _webLoginAndPersist();
        response = await _fetchRoadlistPage(pageIndex);
      }

      List<dynamic> items;
      int? total;
      try {
        if (!response.ok) {
          throw StateError('HTTP ${response.statusCode}');
        }
        final payload = response.jsonBody();
        items = _extractRoadlistItems(payload);
        total = _extractRoadlistTotal(payload);
      } catch (exc) {
        final debug = _formatResponseDebug(response);
        logError('Failed to load RoadList: $debug');
        throw StateError('Failed to load RoadList: $debug');
      }

      allItems.addAll(items);

      if (total == null) {
        if (items.length < pageSize) break;
        pageIndex++;
        continue;
      }
      if (allItems.length >= total) break;
      if (items.isEmpty) break;
      pageIndex++;
    }

    final roadbooks = <RoadBookSummary>[];
    for (final item in allItems) {
      if (item is! Map) continue;
      final roadbookId = jsonGetCi(item, 'roadbookid');
      final title = jsonGetCi(item, 'title');
      if (roadbookId == null || title is! String || title.trim().isEmpty) {
        continue;
      }
      final normalizedId =
          roadbookId is int ? roadbookId : int.tryParse(roadbookId.toString());
      if (normalizedId == null) continue;
      roadbooks.add(
        RoadBookSummary(roadbookId: normalizedId, title: title.trim()),
      );
    }
    return roadbooks;
  }

  String _formatResponseDebug(SessionResponse response) {
    final contentType = response.header('content-type') ?? '';
    var body = response.body.trim().replaceAll('\n', ' ');
    if (body.length > 600) body = '${body.substring(0, 600)}...';
    return "url='${response.url}' status=${response.statusCode} "
        "content_type='$contentType' body='$body'";
  }

  List<dynamic> _extractRoadlistItems(dynamic payloadIn) {
    var payload = payloadIn;
    if (payload is String) {
      try {
        payload = jsonDecode(payload);
      } catch (_) {
        throw StateError('RoadList payload is not valid JSON string');
      }
    }

    if (payload is List) return payload;
    if (payload is! Map) {
      throw StateError(
        'Unexpected RoadList payload type: ${payload.runtimeType}',
      );
    }

    final code = jsonGetCi(payload, 'code');
    if (code != null && code != 0 && code != '0') {
      throw StateError('RoadList API failed: $payload');
    }

    final data = jsonGetCi(payload, 'data');
    final containers = <dynamic>[payload, if (data != null) data];

    if (data == null || (data is Map && data.isEmpty)) return [];
    if (data is! Map && data is! List) {
      throw StateError('Unexpected RoadList Data type: ${data.runtimeType}');
    }

    for (final container in containers) {
      if (container is List) return container;
      if (container is! Map) continue;
      final hasItems = container.keys.any(
        (k) => k is String && normalizeKey(k) == 'items',
      );
      if (!hasItems) continue;
      final value = jsonGetCi(container, 'items');
      if (value == null) return [];
      if (value is List) return value;
      throw StateError('Unexpected RoadList items type: ${value.runtimeType}');
    }

    if (_extractTotalValue(payload) == 0) return [];
    if (_extractTotalValue(data) == 0) return [];
    if (payload.isEmpty && (code == null || code == 0 || code == '0')) {
      return [];
    }

    throw StateError('Unexpected RoadList response format');
  }

  int? _extractRoadlistTotal(dynamic payloadIn) {
    var payload = payloadIn;
    if (payload is String) {
      try {
        payload = jsonDecode(payload);
      } catch (_) {
        return null;
      }
    }
    if (payload is! Map) return null;
    final data = jsonGetCi(payload, 'data');
    return _extractTotalValue(payload) ?? _extractTotalValue(data);
  }

  static int? _extractTotalValue(dynamic container) {
    if (container is! Map) return null;
    final raw = jsonGetCi(container, 'total');
    if (raw == null) return null;
    if (raw is int) return raw;
    return int.tryParse(raw.toString());
  }

  Future<void> setAuxiliaryPoints(
    int roadbookId,
    List<PoiCandidate> points,
  ) async {
    if (points.isEmpty) return;

    final payload = {
      'roadBookId': roadbookId,
      'editRoutesAuxiliaryPointRequestDtos': [
        for (final point in points)
          {
            'auxiliaryPointType': point.poiType.value,
            'auxiliaryPointName': point.name,
            'latitude': point.latitude,
            'selected': false,
            'longitude': point.longitude,
            'auxiliaryPointNameOrigin': point.nameOrigin,
          },
      ],
    };

    final headers = {
      'content-type': 'application/json; charset=utf-8',
      'accept': '*/*',
      'qiwu-phone': 'iPhone_iPad Pro (12.9-inch) (3rd generation)',
      'qiwu-app-version': '8.06.35',
      'priority': 'u=3, i',
      'accept-language': 'en',
      'user-agent': 'iPadOS/26.4',
      'timezone': 'Asia/Tokyo',
    };

    final response = await _session.request(
      'PUT',
      Uri.parse(
        '$_baseUrl/sportg/roadbook4j/road-book/editRoutesAuxiliaryPoint',
      ),
      jsonBody: payload,
      headers: headers,
      timeout: const Duration(seconds: 30),
    );
    if (!response.ok) {
      throw StateError(
        'Failed to set POI on iGPSPORT: HTTP ${response.statusCode}',
      );
    }
    final result = response.jsonBody();
    if (result is! Map || jsonGetCi(result, 'code') != 0) {
      throw StateError('Failed to set POI on iGPSPORT roadbook: $result');
    }
  }

  Future<void> setRoutePrivate(int roadbookId, String title) async {
    final payload = {'title': title, 'status': 0, 'id': roadbookId};
    final headers = {
      'content-type': 'application/json',
      'accept': 'application/json, text/plain, */*',
      'accept-language': 'ja',
      'qiwu-app-version': '8.07.06',
      'timezone': 'Asia/Tokyo',
    };

    final response = await _session.request(
      'PUT',
      Uri.parse('$_baseUrl/web/api/Routes/EditRoutesSummary'),
      jsonBody: payload,
      headers: headers,
      timeout: const Duration(seconds: 30),
    );
    if (!response.ok) {
      throw StateError(
        'Failed to set iGPSPORT route private: HTTP ${response.statusCode}',
      );
    }
    final result = response.jsonBody();
    final code = result is Map ? jsonGetCi(result, 'code') : null;
    if (result is! Map || (code != 0 && code != '0')) {
      throw StateError('Failed to set iGPSPORT route private: $result');
    }
  }

  Future<void> _uploadRouteViaWeb(
    String routeName,
    String filename,
    List<int> content,
  ) async {
    await _restoreWebCookiesFromDisk();
    final contentType = lookupMimeType(filename) ?? 'application/octet-stream';
    final files = [
      MultipartFile(
        field: 'file',
        filename: filename,
        bytes: content,
        contentType: contentType,
      ),
    ];
    final data = {'title': routeName, 'descr': ''};

    final first = await _webSession.request(
      'POST',
      Uri.parse(defaultIgpsportWebUploadUrl),
      formFields: data,
      files: files,
      timeout: const Duration(seconds: 60),
    );

    final (success, reason) = _isWebUploadSuccess(first);
    if (success) {
      await _persistWebCookiesToDisk();
      return;
    }

    if (_looksLikeLoginRequired(first) || reason.isNotEmpty) {
      await _webLoginAndPersist();
      final second = await _webSession.request(
        'POST',
        Uri.parse(defaultIgpsportWebUploadUrl),
        formFields: data,
        files: files,
        timeout: const Duration(seconds: 60),
      );
      final (success2, reason2) = _isWebUploadSuccess(second);
      if (success2) {
        await _persistWebCookiesToDisk();
        return;
      }
      throw StateError('Web upload failed after re-login: $reason2');
    }
    throw StateError('Web upload failed: $reason');
  }

  (bool, String) _isWebUploadSuccess(SessionResponse response) {
    final bodyText =
        response.body.length > 500
            ? response.body.substring(0, 500)
            : response.body;
    if (!response.ok) {
      return (false, 'http_error=${response.statusCode} body=$bodyText');
    }

    dynamic payload;
    try {
      payload = response.jsonBody();
    } catch (_) {
      payload = null;
    }

    if (payload is Map) {
      final code = jsonGetCi(payload, 'code');
      final data = jsonGetCi(payload, 'data');

      if (code == 0 || code == '0') {
        if (data is String && data.toLowerCase().contains('not_found')) {
          return (false, 'json_failure=$payload');
        }
        if (data == true ||
            data == null ||
            data == '' ||
            data == 1 ||
            data == '1') {
          return (true, '');
        }
        if (data is String &&
            {'true', 'ok', 'success'}.contains(data.trim().toLowerCase())) {
          return (true, '');
        }
      }
      if ({'1', '200', '0'}.contains('${jsonGetCi(payload, 'status')}')) {
        return (true, '');
      }
      if ({
        'true',
        '1',
      }.contains('${jsonGetCi(payload, 'success', '')}'.toLowerCase())) {
        return (true, '');
      }
      return (false, 'json_failure=$payload');
    }

    final text = bodyText.trim();
    final lower = text.toLowerCase();
    if ({'ok', 'success', 'true', '1'}.contains(lower)) return (true, '');
    final asInt = int.tryParse(text);
    if (asInt != null && asInt >= 0) return (true, '');
    return (false, 'plain_failure=$bodyText');
  }

  bool _looksLikeLoginRequired(SessionResponse response) {
    if (response.statusCode == 401 || response.statusCode == 403) return true;
    final lower = response.body.toLowerCase();
    return lower.contains('auth/login') || lower.contains('please login');
  }

  Future<void> _webLoginAndPersist() async {
    final response = await _webSession.postJson(
      Uri.parse('$defaultIgpsportWebBaseUrl$defaultIgpsportWebLoginPath'),
      json: {'username': username, 'password': password},
      timeout: const Duration(seconds: 30),
    );
    if (!response.ok) {
      throw StateError(
        'iGPSPORT web login failed: HTTP ${response.statusCode}',
      );
    }
    final payload = response.jsonBody();
    final code = jsonGetCi(payload, 'code');
    if (code != 0 && code != '0') {
      throw StateError('iGPSPORT web login failed: $payload');
    }
    await _persistWebCookiesToDisk();
  }

  Future<void> _persistWebCookiesToDisk() async {
    final cookieMap = _webSession.cookies;
    if (cookieMap.isEmpty) return;
    await _webCookieFile.parent.create(recursive: true);
    await _webCookieFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(cookieMap),
    );
  }

  Future<void> _restoreWebCookiesFromDisk() async {
    if (!await _webCookieFile.exists()) return;
    try {
      final decoded = jsonDecode(await _webCookieFile.readAsString());
      if (decoded is! Map) return;
      final normalized = <String, String>{
        for (final entry in decoded.entries)
          entry.key.toString(): entry.value.toString(),
      };
      _webSession.replaceCookies(normalized);
    } catch (_) {
      return;
    }
  }
}

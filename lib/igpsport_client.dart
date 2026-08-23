/// iGPSPORT route upload and roadbook client.
library;

import 'dart:convert';

import 'config.dart';
import 'http_session.dart';
import 'json_util.dart';
import 'logging.dart';
import 'models.dart';
import 'poi.dart';

class IgpsportClient {
  final String username;
  final String password;
  final String domain;
  final int roadlistPageSize;
  final HttpSession _session;

  /// Plain session for OSS signed-URL uploads. The signed URL carries the
  /// signature in its query string; extra authorization/cookie headers or a
  /// content-type not covered by the signature would invalidate it.
  final HttpSession _ossSession = HttpSession();

  IgpsportClient({
    required this.username,
    required this.password,
    required this.domain,
    required String referer,
    int roadlistPageSize = defaultIgpsportRoadlistPageSize,
  }) : roadlistPageSize = roadlistPageSize < 1 ? 1 : roadlistPageSize,
       _session = HttpSession(
         headers: {
           'user-agent': browserUserAgent,
           'accept': 'application/json, text/plain, */*',
           'origin': referer,
           'referer': referer,
           'x-platform': 'web',
           'qiwu-app-version': igpsportWebAppVersion,
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

  /// Upload a route file through the OSS signed-URL flow used by
  /// app.igpsport.com: request a signed URL, PUT the raw bytes to OSS, then
  /// ask the API to generate a route from the uploaded file.
  ///
  /// Route generation is asynchronous on the server; the new roadbook may take
  /// a while to appear in [getMyRoadbooks] after this returns.
  Future<void> uploadRoute(
    String routeName,
    String filename,
    List<int> content,
  ) async {
    final dotIndex = filename.lastIndexOf('.');
    final fileExtension = dotIndex >= 0 ? filename.substring(dotIndex) : '.gpx';

    final signedResponse = await _session.get(
      Uri.parse('$_baseUrl/sportg/third-party-server/oss/getSignedUrl'),
      params: {'fileExtension': fileExtension},
      timeout: const Duration(seconds: 30),
    );
    final signedData = _requireApiData(signedResponse, what: 'OSS signed URL');
    final signedUrl = jsonGetCi(signedData, 'signedUrl');
    final ossId = jsonGetCi(signedData, 'ossId');
    if (signedUrl is! String || signedUrl.isEmpty || ossId == null) {
      throw StateError(
        'OSS signed URL response missing signedUrl/ossId: $signedData',
      );
    }

    final ossResponse = await _ossSession.request(
      'PUT',
      Uri.parse(signedUrl),
      bodyBytes: content,
      timeout: const Duration(seconds: 120),
    );
    if (!ossResponse.ok) {
      throw StateError(
        'OSS upload failed: ${_formatResponseDebug(ossResponse)}',
      );
    }

    final generateResponse = await _session.postJson(
      Uri.parse('$_baseUrl/web/api/Routes/UploadOssGenerateRoutes'),
      json: {
        'fileName': filename,
        'fileId': ossId,
        'title': routeName,
        'description': '',
      },
      timeout: const Duration(seconds: 60),
    );
    _requireApiData(generateResponse, what: 'UploadOssGenerateRoutes');
  }

  /// Check an API response for HTTP and `code` success, returning its `data`.
  dynamic _requireApiData(SessionResponse response, {required String what}) {
    if (!response.ok) {
      throw StateError('$what failed: ${_formatResponseDebug(response)}');
    }
    dynamic payload;
    try {
      payload = response.jsonBody();
    } catch (_) {
      throw StateError(
        '$what returned non-JSON: '
        '${_formatResponseDebug(response)}',
      );
    }
    final code = jsonGetCi(payload, 'code');
    if (code != 0 && code != '0') {
      throw StateError('$what failed: $payload');
    }
    return jsonGetCi(payload, 'data');
  }

  Future<SessionResponse> _fetchRoadlistPage(int pageIndex) {
    return _session.get(
      Uri.parse('$_baseUrl/web/api/Routes/RouteListForWeb'),
      params: {
        'type': 'mine',
        'pageSize': '$roadlistPageSize',
        'pageIndex': '$pageIndex',
      },
      timeout: const Duration(seconds: 30),
    );
  }

  /// Return existing roadbooks from the iGPSPORT RouteListForWeb API.
  Future<List<RoadBookSummary>> getMyRoadbooks() async {
    final pageSize = roadlistPageSize;
    var pageIndex = 1;
    final allItems = <dynamic>[];

    while (true) {
      final response = await _fetchRoadlistPage(pageIndex);

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
        logError('Failed to load RouteListForWeb: $debug');
        throw StateError('Failed to load RouteListForWeb: $debug');
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
      final roadbookId =
          jsonGetCi(item, 'roadBookId') ??
          jsonGetCi(item, 'ruteId') ??
          jsonGetCi(item, 'routeId') ??
          jsonGetCi(item, 'id');
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
}

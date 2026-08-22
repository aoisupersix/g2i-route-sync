/// A cookie-aware HTTP session, the Dart equivalent of ``requests.Session``.
///
/// Built on ``dart:io`` ``HttpClient`` so ``Set-Cookie`` headers are parsed
/// correctly and redirects can be followed manually while accumulating cookies.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class SessionResponse {
  final int statusCode;
  final Map<String, String> headers;
  final List<int> bodyBytes;
  final Uri url;

  SessionResponse({
    required this.statusCode,
    required this.headers,
    required this.bodyBytes,
    required this.url,
  });

  String get body => utf8.decode(bodyBytes, allowMalformed: true);

  dynamic jsonBody() => jsonDecode(body);

  bool get ok => statusCode >= 200 && statusCode < 300;

  String? header(String name) => headers[name.toLowerCase()];
}

class MultipartFile {
  final String field;
  final String filename;
  final List<int> bytes;
  final String contentType;

  MultipartFile({
    required this.field,
    required this.filename,
    required this.bytes,
    required this.contentType,
  });
}

class HttpSession {
  final HttpClient _client = HttpClient();
  final Map<String, String> _cookies = {};
  final Map<String, String> defaultHeaders;
  final Duration defaultTimeout;
  int _boundaryCounter = 0;

  HttpSession({
    Map<String, String>? headers,
    this.defaultTimeout = const Duration(seconds: 30),
  }) : defaultHeaders = {...?headers};

  Map<String, String> get cookies => Map.unmodifiable(_cookies);

  void replaceCookies(Map<String, String> values) {
    _cookies
      ..clear()
      ..addAll(values);
  }

  void close() => _client.close(force: true);

  Future<SessionResponse> get(
    Uri url, {
    Map<String, String>? headers,
    Map<String, String>? params,
    bool followRedirects = true,
    Duration? timeout,
  }) => request(
    'GET',
    url,
    headers: headers,
    params: params,
    followRedirects: followRedirects,
    timeout: timeout,
  );

  Future<SessionResponse> postJson(
    Uri url, {
    Map<String, String>? headers,
    Map<String, String>? params,
    Object? json,
    bool followRedirects = true,
    Duration? timeout,
  }) => request(
    'POST',
    url,
    headers: headers,
    params: params,
    jsonBody: json,
    followRedirects: followRedirects,
    timeout: timeout,
  );

  Future<SessionResponse> request(
    String method,
    Uri url, {
    Map<String, String>? headers,
    Map<String, String>? params,
    Object? jsonBody,
    Map<String, String>? formFields,
    List<MultipartFile>? files,
    List<int>? bodyBytes,
    bool followRedirects = true,
    Duration? timeout,
  }) async {
    if (params != null && params.isNotEmpty) {
      url = url.replace(
        queryParameters: {...url.queryParametersAll, ...params},
      );
    }

    List<int>? payload;
    String? contentType;
    if (jsonBody != null) {
      payload = utf8.encode(jsonEncode(jsonBody));
      contentType = 'application/json';
    } else if (files != null) {
      final boundary = _nextBoundary();
      payload = _buildMultipart(boundary, formFields ?? {}, files);
      contentType = 'multipart/form-data; boundary=$boundary';
    } else if (formFields != null) {
      payload = utf8.encode(
        formFields.entries
            .map(
              (e) =>
                  '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
            )
            .join('&'),
      );
      contentType = 'application/x-www-form-urlencoded';
    } else if (bodyBytes != null) {
      payload = bodyBytes;
    }

    var currentMethod = method;
    var currentUrl = url;
    var currentPayload = payload;
    var currentContentType = contentType;
    var redirects = 0;
    final effectiveTimeout = timeout ?? defaultTimeout;

    while (true) {
      final req = await _client.openUrl(currentMethod, currentUrl);
      req.followRedirects = false;

      final merged = {...defaultHeaders, ...?headers};
      var sentContentType = false;
      merged.forEach((k, v) {
        req.headers.set(k, v);
        if (k.toLowerCase() == 'content-type') sentContentType = true;
      });
      if (currentContentType != null && !sentContentType) {
        req.headers.set('content-type', currentContentType);
      }
      final cookieHeader = _cookieHeader();
      if (cookieHeader.isNotEmpty) req.headers.set('cookie', cookieHeader);

      if (currentPayload != null) {
        // Explicit length avoids chunked transfer encoding, which some
        // endpoints (e.g. OSS signed-URL PUT) reject with 411.
        req.contentLength = currentPayload.length;
        req.add(currentPayload);
      }

      final resp = await req.close().timeout(effectiveTimeout);
      _storeCookies(resp.cookies);

      final isRedirect =
          resp.statusCode >= 300 &&
          resp.statusCode < 400 &&
          resp.headers.value('location') != null;
      if (followRedirects && isRedirect && redirects < 10) {
        final location = resp.headers.value('location')!;
        await resp.drain<void>();
        currentUrl = currentUrl.resolve(location);
        redirects++;
        if (resp.statusCode != 307 && resp.statusCode != 308) {
          currentMethod = 'GET';
          currentPayload = null;
          currentContentType = null;
        }
        continue;
      }

      final bytes = await _collectBytes(resp);
      return SessionResponse(
        statusCode: resp.statusCode,
        headers: _flattenHeaders(resp.headers),
        bodyBytes: bytes,
        url: currentUrl,
      );
    }
  }

  String _cookieHeader() =>
      _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  void _storeCookies(List<Cookie> cookies) {
    for (final c in cookies) {
      _cookies[c.name] = c.value;
    }
  }

  String _nextBoundary() =>
      '----dartHttpSessionBoundary${DateTime.now().microsecondsSinceEpoch}${_boundaryCounter++}';

  List<int> _buildMultipart(
    String boundary,
    Map<String, String> fields,
    List<MultipartFile> files,
  ) {
    final out = <int>[];
    void writeStr(String s) => out.addAll(utf8.encode(s));

    fields.forEach((name, value) {
      writeStr('--$boundary\r\n');
      writeStr('Content-Disposition: form-data; name="$name"\r\n\r\n');
      writeStr('$value\r\n');
    });
    for (final f in files) {
      writeStr('--$boundary\r\n');
      writeStr(
        'Content-Disposition: form-data; name="${f.field}"; '
        'filename="${f.filename}"\r\n',
      );
      writeStr('Content-Type: ${f.contentType}\r\n\r\n');
      out.addAll(f.bytes);
      writeStr('\r\n');
    }
    writeStr('--$boundary--\r\n');
    return out;
  }

  Map<String, String> _flattenHeaders(HttpHeaders headers) {
    final map = <String, String>{};
    headers.forEach((name, values) {
      map[name.toLowerCase()] = values.join(', ');
    });
    return map;
  }

  Future<List<int>> _collectBytes(HttpClientResponse resp) async {
    final chunks = <List<int>>[];
    await for (final chunk in resp) {
      chunks.add(chunk);
    }
    return chunks.expand((c) => c).toList();
  }
}

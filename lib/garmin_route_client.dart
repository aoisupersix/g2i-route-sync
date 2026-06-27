/// Garmin Connect route listing and download client.
library;

import 'config.dart';
import 'garmin_client.dart';
import 'gpx.dart';
import 'json_util.dart';
import 'logging.dart';
import 'models.dart';

class GarminRouteClient {
  final String email;
  final String password;
  final bool isCn;
  final String sessionDir;
  final String listEndpoint;
  final String downloadEndpoint;
  final GarminClient _garmin;

  GarminRouteClient({
    required this.email,
    required this.password,
    required this.isCn,
    required this.sessionDir,
    String? listEndpoint,
    String? downloadEndpoint,
  }) : listEndpoint = listEndpoint ?? defaultGarminRouteListEndpoint,
       downloadEndpoint =
           downloadEndpoint ?? defaultGarminRouteDownloadEndpoint,
       _garmin = GarminClient(domain: isCn ? 'garmin.cn' : 'garmin.com');

  Future<void> login() async {
    await _garmin.login(email, password, tokenstore: sessionDir);
    logInfo('Authenticated to Garmin Connect');
  }

  Future<List<RouteSummary>> listRoutes(int limit) async {
    final paramsCandidates = <Map<String, String>>[
      {'start': '0', 'limit': '$limit'},
      {'page': '1', 'pageSize': '$limit'},
      {'offset': '0', 'limit': '$limit'},
    ];
    Object? lastError;

    for (final params in paramsCandidates) {
      try {
        final payload = await _garmin.connectapi(listEndpoint, params: params);
        final routes = _extractRouteList(payload);
        if (routes.isNotEmpty) {
          logInfo(
            'Found ${routes.length} routes from Garmin endpoint=$listEndpoint',
          );
          return routes.length > limit ? routes.sublist(0, limit) : routes;
        }
      } catch (exc) {
        lastError = exc;
        logDebug(
          'Garmin route list call failed endpoint=$listEndpoint '
          'params=$params err=$exc',
        );
      }
    }

    if (lastError != null) {
      throw StateError(
        'Failed to fetch Garmin routes from configured endpoint: $lastError',
      );
    }
    throw StateError('No Garmin routes found');
  }

  Future<(List<int>, String)> downloadRoute(RouteSummary route) async {
    final directUrl = jsonGetCi(route.raw, 'downloadUrl');
    if (directUrl is String && directUrl.isNotEmpty) {
      try {
        final content = await _garmin.download(directUrl);
        return (content, inferExtension(content, directUrl));
      } catch (exc) {
        logDebug(
          'Direct Garmin route download failed route_id=${route.routeId} '
          'url=$directUrl err=$exc',
        );
      }
    }

    final endpoint = downloadEndpoint.replaceAll('{route_id}', route.routeId);
    try {
      final content = await _garmin.download(endpoint);
      return (content, inferExtension(content, endpoint));
    } catch (exc) {
      logDebug(
        'Garmin route download failed route_id=${route.routeId} '
        'endpoint=$endpoint err=$exc',
      );
      logDebug(
        'Falling back to GPX generation from course detail '
        'route_id=${route.routeId}',
      );
    }

    final courseDetail = await _getCourseDetail(route.routeId);
    final gpxBytes = buildGpxFromCourseDetail(courseDetail, route.name);
    return (gpxBytes, '.gpx');
  }

  static List<RouteSummary> _extractRouteList(dynamic payload) {
    List<dynamic> items;
    if (payload is List) {
      items = payload;
    } else if (payload is Map) {
      final value = jsonGetCi(payload, 'courseItems');
      items = value is List ? value : <dynamic>[];
    } else {
      items = <dynamic>[];
    }

    final routes = <RouteSummary>[];
    for (final item in items) {
      if (item is! Map) continue;
      final routeId = jsonGetCi(item, 'courseId');
      if (routeId == null) continue;
      final routeName =
          jsonGetCi(item, 'courseName') ?? 'garmin-route-$routeId';
      routes.add(
        RouteSummary(
          routeId: routeId.toString(),
          name: routeName.toString(),
          raw: Map<String, dynamic>.from(item),
        ),
      );
    }
    return routes;
  }

  Future<Map<String, dynamic>> _getCourseDetail(String routeId) async {
    final payload = await _garmin.connectapi('/course-service/course/$routeId');
    if (payload is! Map) {
      throw StateError(
        'Unexpected Garmin course detail payload type: ${payload.runtimeType}',
      );
    }
    return Map<String, dynamic>.from(payload);
  }
}

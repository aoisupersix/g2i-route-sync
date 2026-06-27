/// Route ordering helpers and the Garmin -> iGPSPORT sync orchestration.
library;

import 'config.dart';
import 'garmin_route_client.dart';
import 'igpsport_client.dart';
import 'json_util.dart';
import 'logging.dart';
import 'models.dart';
import 'poi.dart';

double? normalizeToUnixSeconds(dynamic value) {
  if (value == null || value is bool) return null;

  if (value is num) {
    final numeric = value.toDouble();
    if (numeric <= 0) return null;
    if (numeric > 1000000000000) return numeric / 1000.0;
    return numeric;
  }

  if (value is String) {
    final text = value.trim();
    if (text.isEmpty) return null;

    if (RegExp(r'^\d+$').hasMatch(text)) {
      return normalizeToUnixSeconds(double.parse(text));
    }

    final normalized = text.replaceAll('Z', '+00:00');
    final dtValue = DateTime.tryParse(normalized);
    if (dtValue == null) return null;
    return dtValue.toUtc().millisecondsSinceEpoch / 1000.0;
  }

  return null;
}

double? _parseRouteCreatedTimestamp(RouteSummary route) =>
    normalizeToUnixSeconds(jsonGetCi(route.raw, 'createTime'));

List<RouteSummary> sortRoutesOldestFirst(List<RouteSummary> routes) {
  final indexed = [for (var i = 0; i < routes.length; i++) (i, routes[i])];

  indexed.sort((a, b) {
    final tsA = _parseRouteCreatedTimestamp(a.$2);
    final tsB = _parseRouteCreatedTimestamp(b.$2);
    final groupA = tsA == null ? 1 : 0;
    final groupB = tsB == null ? 1 : 0;
    if (groupA != groupB) return groupA - groupB;
    final keyA = tsA ?? double.infinity;
    final keyB = tsB ?? double.infinity;
    final cmp = keyA.compareTo(keyB);
    if (cmp != 0) return cmp;
    return a.$1 - b.$1;
  });

  return [for (final entry in indexed) entry.$2];
}

Future<int> runSync(
  AppConfig config, {
  required int limit,
  required bool dryRun,
  required String sessionDir,
}) async {
  final garmin = GarminRouteClient(
    email: config.garminEmail,
    password: config.garminPassword,
    isCn: config.garminCn,
    sessionDir: sessionDir,
    listEndpoint: config.routeListEndpoint,
    downloadEndpoint: config.routeDownloadEndpoint,
  );
  final igpsport = IgpsportClient(
    username: config.igpsportUsername,
    password: config.igpsportPassword,
    domain: config.igpsportDomain,
    referer: config.igpsportReferer,
    webCookieFile: config.webCookieFile,
    roadlistPageSize: config.roadlistPageSize,
  );

  await garmin.login();
  final routes = await garmin.listRoutes(limit);
  if (routes.isEmpty) {
    logInfo('No Garmin routes found');
    return 0;
  }

  // State-file based dedupe is disabled. We always evaluate all Garmin routes
  // against current iGPSPORT titles so deleted routes can be re-uploaded.
  final pendingRoutes = sortRoutesOldestFirst(routes);
  logInfo('Routes to evaluate: ${pendingRoutes.length}');

  var titleToRoadbookId = <String, int>{};
  if (!dryRun) {
    await igpsport.login();
    final roadbooks = await igpsport.getMyRoadbooks();
    titleToRoadbookId = {for (final rb in roadbooks) rb.title: rb.roadbookId};
    logInfo('Loaded iGPSPORT roadbooks: ${roadbooks.length}');
  }

  var synced = 0;
  var failed = 0;
  var skipped = 0;
  for (final route in pendingRoutes) {
    logInfo('Processing route id=${route.routeId} name=${route.name}');
    try {
      final normalizedTitle = route.name.trim();
      final (routeBytes, extension) = await garmin.downloadRoute(route);
      final filename = '${route.routeId}$extension';
      var uploadedNow = false;

      final poiCandidates = extractPoisFromGpxBytes(routeBytes);
      if (poiCandidates.isNotEmpty) {
        logInfo(
          'Extracted POI candidates from GPX: route_id=${route.routeId} '
          'count=${poiCandidates.length}',
        );
      }

      if (dryRun) {
        logInfo(
          'dry-run: skip upload route id=${route.routeId} file=$filename '
          'size=${routeBytes.length}',
        );
        skipped++;
        continue;
      }

      int? targetRoadbookId = titleToRoadbookId[normalizedTitle];

      if (targetRoadbookId != null) {
        logInfo(
          'Skip upload (already exists on iGPSPORT by title): '
          'route_id=${route.routeId} title=${route.name} '
          'roadbook_id=$targetRoadbookId',
        );
        skipped++;
      } else {
        await igpsport.uploadRoute(route.name, filename, routeBytes);
        final refreshed = await igpsport.getMyRoadbooks();
        titleToRoadbookId = {
          for (final rb in refreshed) rb.title: rb.roadbookId,
        };
        targetRoadbookId = titleToRoadbookId[normalizedTitle];
        if (targetRoadbookId == null) {
          throw StateError(
            'Route uploaded but could not resolve iGPSPORT roadbook ID by title',
          );
        }
        uploadedNow = true;
        synced++;
        logInfo(
          'Synced route id=${route.routeId} -> roadbook_id=$targetRoadbookId',
        );
      }

      if (uploadedNow) {
        await igpsport.setRoutePrivate(targetRoadbookId, normalizedTitle);
        logInfo('Set iGPSPORT route private: roadbook_id=$targetRoadbookId');
      }

      if (poiCandidates.isNotEmpty) {
        await igpsport.setAuxiliaryPoints(targetRoadbookId, poiCandidates);
        logInfo(
          'Applied POI to iGPSPORT route: roadbook_id=$targetRoadbookId '
          'count=${poiCandidates.length}',
        );
      }
    } catch (exc) {
      // Broad on purpose: this is the per-route boundary — one bad route must
      // not abort the whole run.
      logError('Failed route id=${route.routeId} error=$exc');
      failed++;
    }
  }

  logInfo('Sync done. uploaded=$synced skipped=$skipped failed=$failed');
  return 0;
}

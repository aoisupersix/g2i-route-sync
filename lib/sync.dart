/// Route ordering helpers and the Garmin -> iGPSPORT sync orchestration.
library;

import 'dart:math';

import 'config.dart';
import 'fingerprint.dart';
import 'garmin_route_client.dart';
import 'igpsport_client.dart';
import 'json_util.dart';
import 'logging.dart';
import 'models.dart';
import 'poi.dart';
import 'sync_state.dart';

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

/// What to do with a Garmin route, given its previous sync and the current
/// iGPSPORT roadbooks.
sealed class SyncAction {
  const SyncAction();
}

/// Synced before and unchanged since.
class SkipUnchanged extends SyncAction {
  final int roadbookId;
  const SkipUnchanged(this.roadbookId);
}

/// Not tracked yet, but a roadbook with the same title exists.
class AdoptExisting extends SyncAction {
  final int roadbookId;
  const AdoptExisting(this.roadbookId);
}

class UploadNew extends SyncAction {
  const UploadNew();
}

/// Renamed or modified since the last sync: upload again, then delete the
/// previous roadbook.
class ReplaceRoadbook extends SyncAction {
  final int oldRoadbookId;
  final bool renamed;
  const ReplaceRoadbook(this.oldRoadbookId, {required this.renamed});
}

SyncAction decideSyncAction({
  required SyncedRoute? previous,
  required String title,
  required String fingerprint,
  required List<RoadBookSummary> roadbooks,
}) {
  if (previous != null &&
      roadbooks.any((rb) => rb.roadbookId == previous.roadbookId)) {
    final renamed = previous.title != title;
    if (!renamed && previous.fingerprint == fingerprint) {
      return SkipUnchanged(previous.roadbookId);
    }
    return ReplaceRoadbook(previous.roadbookId, renamed: renamed);
  }

  // Untracked (first run, lost state) or the previous roadbook was deleted on
  // iGPSPORT: fall back to title matching so existing routes are not
  // uploaded twice.
  for (final rb in roadbooks) {
    if (rb.title == title) return AdoptExisting(rb.roadbookId);
  }
  return const UploadNew();
}

/// Upload a route and return the ID of the roadbook generated from it.
Future<int> _uploadRoadbook(
  IgpsportClient igpsport, {
  required String title,
  required String filename,
  required List<int> content,
  required Set<int> knownRoadbookIds,
}) async {
  await igpsport.uploadRoute(title, filename, content);
  // Route generation from the uploaded file is asynchronous on the iGPSPORT
  // side, so poll until a roadbook with an unknown ID shows up by title.
  // Excluding known IDs tells it apart from the roadbook being replaced.
  final normalizedTitle = title.trim();
  const pollAttempts = 12;
  const pollDelay = Duration(seconds: 5);
  for (var attempt = 0; attempt < pollAttempts; attempt++) {
    await Future<void>.delayed(pollDelay);
    final refreshed = await igpsport.getMyRoadbooks();
    final created = [
      for (final rb in refreshed)
        if (rb.title == normalizedTitle &&
            !knownRoadbookIds.contains(rb.roadbookId))
          rb.roadbookId,
    ];
    if (created.isNotEmpty) return created.reduce(max);
  }
  throw StateError(
    'Route uploaded but could not resolve iGPSPORT roadbook ID by title',
  );
}

Future<int> runSync(
  AppConfig config, {
  required int limit,
  required bool dryRun,
  required String sessionDir,
  required String stateFile,
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
    roadlistPageSize: config.roadlistPageSize,
  );

  await garmin.login();
  final routes = await garmin.listRoutes(limit);
  if (routes.isEmpty) {
    logInfo('No Garmin routes found');
    return 0;
  }

  final pendingRoutes = sortRoutesOldestFirst(routes);
  logInfo('Routes to evaluate: ${pendingRoutes.length}');

  final roadbooks = <RoadBookSummary>[];
  if (!dryRun) {
    await igpsport.login();
    roadbooks.addAll(await igpsport.getMyRoadbooks());
    logInfo('Loaded iGPSPORT roadbooks: ${roadbooks.length}');
  }
  final syncState = loadSyncState(stateFile);
  logInfo('Loaded sync state: ${syncState.length} routes');

  var synced = 0;
  var replaced = 0;
  var failed = 0;
  var skipped = 0;
  try {
    for (final route in pendingRoutes) {
      logInfo('Processing route id=${route.routeId} name=${route.name}');
      try {
        final normalizedTitle = route.name.trim();
        final (routeBytes, extension) = await garmin.downloadRoute(route);
        final filename = '${route.routeId}$extension';

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

        final fingerprint = routeFingerprint(routeBytes);
        final action = decideSyncAction(
          previous: syncState[route.routeId],
          title: normalizedTitle,
          fingerprint: fingerprint,
          roadbooks: roadbooks,
        );

        final int targetRoadbookId;
        switch (action) {
          case SkipUnchanged(:final roadbookId):
            logInfo(
              'Skip upload (unchanged since last sync): '
              'route_id=${route.routeId} title=${route.name} '
              'roadbook_id=$roadbookId',
            );
            skipped++;
            targetRoadbookId = roadbookId;
          case AdoptExisting(:final roadbookId):
            logInfo(
              'Skip upload (already exists on iGPSPORT by title): '
              'route_id=${route.routeId} title=${route.name} '
              'roadbook_id=$roadbookId',
            );
            skipped++;
            targetRoadbookId = roadbookId;
          case UploadNew() || ReplaceRoadbook():
            if (action case ReplaceRoadbook(
              :final oldRoadbookId,
              :final renamed,
            )) {
              final reason = renamed ? 'renamed' : 'content changed';
              logInfo(
                'Re-uploading route ($reason since last sync): '
                'route_id=${route.routeId} title=${route.name} '
                'old_roadbook_id=$oldRoadbookId',
              );
            }
            targetRoadbookId = await _uploadRoadbook(
              igpsport,
              title: route.name,
              filename: filename,
              content: routeBytes,
              knownRoadbookIds: {for (final rb in roadbooks) rb.roadbookId},
            );
            roadbooks.add(
              RoadBookSummary(
                roadbookId: targetRoadbookId,
                title: normalizedTitle,
              ),
            );
            logInfo(
              'Synced route id=${route.routeId} -> '
              'roadbook_id=$targetRoadbookId',
            );
            await igpsport.setRoutePrivate(targetRoadbookId, normalizedTitle);
            logInfo(
              'Set iGPSPORT route private: roadbook_id=$targetRoadbookId',
            );
        }

        // Record the new roadbook before deleting the old one, so a failed
        // delete does not make the next run upload the route yet again.
        syncState[route.routeId] = SyncedRoute(
          roadbookId: targetRoadbookId,
          title: normalizedTitle,
          fingerprint: fingerprint,
        );

        if (poiCandidates.isNotEmpty) {
          await igpsport.setAuxiliaryPoints(targetRoadbookId, poiCandidates);
          logInfo(
            'Applied POI to iGPSPORT route: roadbook_id=$targetRoadbookId '
            'count=${poiCandidates.length}',
          );
        }

        switch (action) {
          case UploadNew():
            synced++;
          case ReplaceRoadbook(:final oldRoadbookId):
            await igpsport.deleteRoute(oldRoadbookId);
            roadbooks.removeWhere((rb) => rb.roadbookId == oldRoadbookId);
            logInfo(
              'Deleted previous iGPSPORT route: roadbook_id=$oldRoadbookId',
            );
            replaced++;
          case SkipUnchanged() || AdoptExisting():
            break;
        }
      } catch (exc) {
        // Broad on purpose: this is the per-route boundary — one bad route must
        // not abort the whole run.
        logError('Failed route id=${route.routeId} error=$exc');
        failed++;
      }
    }
  } finally {
    if (!dryRun) {
      saveSyncState(stateFile, syncState);
      logInfo('Saved sync state: ${syncState.length} routes -> $stateFile');
    }
  }

  logInfo(
    'Sync done. uploaded=$synced replaced=$replaced skipped=$skipped '
    'failed=$failed',
  );
  return 0;
}

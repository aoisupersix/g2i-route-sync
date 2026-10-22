/// Persisted mapping from Garmin routes to the iGPSPORT roadbooks synced from
/// them, used to detect content changes and renames.
library;

import 'dart:convert';
import 'dart:io';

import 'logging.dart';

const _stateVersion = 1;

class SyncedRoute {
  final int roadbookId;
  final String title;
  final String fingerprint;

  const SyncedRoute({
    required this.roadbookId,
    required this.title,
    required this.fingerprint,
  });

  Map<String, dynamic> toJson() => {
    'roadbookId': roadbookId,
    'title': title,
    'fingerprint': fingerprint,
  };

  static SyncedRoute? fromJson(dynamic json) {
    if (json is! Map) return null;
    final roadbookId = json['roadbookId'];
    final title = json['title'];
    final fingerprint = json['fingerprint'];
    if (roadbookId is! int || title is! String || fingerprint is! String) {
      return null;
    }
    return SyncedRoute(
      roadbookId: roadbookId,
      title: title,
      fingerprint: fingerprint,
    );
  }
}

/// Load synced routes keyed by Garmin route ID.
///
/// A missing or unreadable file yields an empty state; the sync then falls
/// back to title matching, so a corrupt cache never blocks the run.
Map<String, SyncedRoute> loadSyncState(String path) {
  final file = File(path);
  if (!file.existsSync()) return {};

  final dynamic json;
  try {
    json = jsonDecode(file.readAsStringSync());
  } on FormatException catch (exc) {
    logWarning('Ignoring unreadable sync state file=$path error=$exc');
    return {};
  }
  final routes = json is Map ? json['routes'] : null;
  if (routes is! Map) {
    logWarning('Ignoring sync state with unexpected format file=$path');
    return {};
  }

  return {
    for (final entry in routes.entries)
      if (SyncedRoute.fromJson(entry.value) case final route?)
        entry.key.toString(): route,
  };
}

void saveSyncState(String path, Map<String, SyncedRoute> routes) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  final json = {
    'version': _stateVersion,
    'routes': {
      for (final entry in routes.entries) entry.key: entry.value.toJson(),
    },
  };
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
}

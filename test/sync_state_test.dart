import 'dart:io';

import 'package:g2i_route_sync/sync_state.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('sync_state'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  test('round-trips through a file in a new directory', () {
    final path = '${tempDir.path}/nested/sync_state.json';
    saveSyncState(path, {
      '123': const SyncedRoute(roadbookId: 1, title: 'A', fingerprint: 'f'),
    });

    final loaded = loadSyncState(path);
    expect(loaded.keys, ['123']);
    expect(loaded['123']!.roadbookId, 1);
    expect(loaded['123']!.title, 'A');
    expect(loaded['123']!.fingerprint, 'f');
  });

  test('missing file yields empty state', () {
    expect(loadSyncState('${tempDir.path}/none.json'), isEmpty);
  });

  test('corrupt file yields empty state', () {
    final path = '${tempDir.path}/broken.json';
    File(path).writeAsStringSync('{not json');
    expect(loadSyncState(path), isEmpty);
  });

  test('skips malformed entries', () {
    final path = '${tempDir.path}/partial.json';
    File(path).writeAsStringSync(
      '{"version":1,"routes":{'
      '"1":{"roadbookId":10,"title":"A","fingerprint":"f"},'
      '"2":{"roadbookId":"x"}}}',
    );
    expect(loadSyncState(path).keys, ['1']);
  });
}

import 'package:g2i_route_sync/models.dart';
import 'package:g2i_route_sync/sync.dart';
import 'package:g2i_route_sync/sync_state.dart';
import 'package:test/test.dart';

RouteSummary _route(String routeId, dynamic createTime) => RouteSummary(
  routeId: routeId,
  name: routeId,
  raw: {'createTime': createTime},
);

void main() {
  test('normalizeToUnixSeconds handles variants', () {
    expect(normalizeToUnixSeconds(1700000000), 1700000000.0);
    // Milliseconds are scaled down to seconds.
    expect(normalizeToUnixSeconds(1700000000000), 1700000000.0);
    expect(normalizeToUnixSeconds('1700000000'), 1700000000.0);
    expect(normalizeToUnixSeconds('2023-11-14T22:13:20Z'), isNotNull);
  });

  test('normalizeToUnixSeconds rejects invalid', () {
    expect(normalizeToUnixSeconds(null), isNull);
    expect(normalizeToUnixSeconds(true), isNull);
    expect(normalizeToUnixSeconds(0), isNull);
    expect(normalizeToUnixSeconds('not a date'), isNull);
  });

  test('sortRoutesOldestFirst', () {
    final routes = [
      _route('new', 2000),
      _route('old', 1000),
      _route('no_ts', null),
    ];
    final ordered = [for (final r in sortRoutesOldestFirst(routes)) r.routeId];
    // Oldest first; routes without timestamp sink to the end.
    expect(ordered, ['old', 'new', 'no_ts']);
  });

  test('sort is stable for missing timestamps', () {
    final routes = [_route('a', null), _route('b', null)];
    final ordered = [for (final r in sortRoutesOldestFirst(routes)) r.routeId];
    expect(ordered, ['a', 'b']);
  });

  group('decideSyncAction', () {
    final roadbooks = [
      RoadBookSummary(roadbookId: 10, title: 'Morning Ride'),
      RoadBookSummary(roadbookId: 20, title: 'Hill Climb'),
    ];
    const previous = SyncedRoute(
      roadbookId: 10,
      title: 'Morning Ride',
      fingerprint: 'f1',
    );

    SyncAction decide({
      SyncedRoute? previous,
      String title = 'Morning Ride',
      String fingerprint = 'f1',
      List<RoadBookSummary>? current,
    }) => decideSyncAction(
      previous: previous,
      title: title,
      fingerprint: fingerprint,
      roadbooks: current ?? roadbooks,
    );

    test('skips unchanged route', () {
      final action = decide(previous: previous);
      expect(action, isA<SkipUnchanged>());
      expect((action as SkipUnchanged).roadbookId, 10);
    });

    test('replaces route whose content changed', () {
      final action = decide(previous: previous, fingerprint: 'f2');
      expect(action, isA<ReplaceRoadbook>());
      expect((action as ReplaceRoadbook).oldRoadbookId, 10);
      expect(action.renamed, isFalse);
    });

    test('replaces renamed route', () {
      final action = decide(previous: previous, title: 'Evening Ride');
      expect(action, isA<ReplaceRoadbook>());
      expect((action as ReplaceRoadbook).oldRoadbookId, 10);
      expect(action.renamed, isTrue);
    });

    test('adopts roadbook with same title when untracked', () {
      final action = decide(title: 'Hill Climb');
      expect(action, isA<AdoptExisting>());
      expect((action as AdoptExisting).roadbookId, 20);
    });

    test('uploads untracked route without matching title', () {
      expect(decide(title: 'New Route'), isA<UploadNew>());
    });

    test('falls back to title matching when tracked roadbook was deleted', () {
      final current = [RoadBookSummary(roadbookId: 20, title: 'Hill Climb')];
      expect(
        decide(previous: previous, fingerprint: 'f2', current: current),
        isA<UploadNew>(),
      );
    });
  });
}

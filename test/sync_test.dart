import 'package:g2i_route_sync/models.dart';
import 'package:g2i_route_sync/sync.dart';
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
}

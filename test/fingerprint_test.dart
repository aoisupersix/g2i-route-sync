import 'dart:convert';

import 'package:g2i_route_sync/fingerprint.dart';
import 'package:test/test.dart';

List<int> _gpx({
  String time = '2026-01-01T00:00:00Z',
  String lat = '35.2',
  String wptName = 'Water Stop',
}) => utf8.encode('''<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
  <metadata><time>$time</time></metadata>
  <wpt lat="35.0" lon="139.0"><name>$wptName</name><type>Water</type></wpt>
  <trk><name>route</name><trkseg>
    <trkpt lat="$lat" lon="139.2"><ele>10.0</ele><time>$time</time></trkpt>
    <trkpt lat="35.3" lon="139.3"><ele>12.0</ele></trkpt>
  </trkseg></trk>
</gpx>
''');

void main() {
  test('ignores timestamps', () {
    expect(
      routeFingerprint(_gpx(time: '2026-01-01T00:00:00Z')),
      routeFingerprint(_gpx(time: '2026-06-01T12:34:56Z')),
    );
  });

  test('detects track point changes', () {
    expect(
      routeFingerprint(_gpx(lat: '35.2')),
      isNot(routeFingerprint(_gpx(lat: '35.25'))),
    );
  });

  test('detects waypoint changes', () {
    expect(
      routeFingerprint(_gpx(wptName: 'Water Stop')),
      isNot(routeFingerprint(_gpx(wptName: 'Cafe'))),
    );
  });

  test('falls back to raw bytes for non-GPX content', () {
    final fit = [0x0e, 0x10, 0x00, 0x00, 0x2e, 0x46, 0x49, 0x54];
    expect(routeFingerprint(fit), routeFingerprint(List.of(fit)));
    expect(routeFingerprint(fit), isNot(routeFingerprint([...fit, 0x00])));
  });
}

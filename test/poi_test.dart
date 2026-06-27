import 'dart:convert';

import 'package:g2i_route_sync/poi.dart';
import 'package:test/test.dart';

final sampleGpx = utf8.encode('''<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
  <wpt lat="35.0" lon="139.0"><name>Water Stop</name><type>Water</type></wpt>
  <wpt lat="35.1" lon="139.1"><name>Top</name><type>Summit</type></wpt>
  <wpt lat="35.0" lon="139.0"><name>Water Stop</name><type>Water</type></wpt>
  <trk><name>route</name><trkseg>
    <trkpt lat="35.2" lon="139.2"><name>Named Track Point</name></trkpt>
    <trkpt lat="35.3" lon="139.3"></trkpt>
  </trkseg></trk>
</gpx>
''');

void main() {
  test('map known type', () {
    expect(mapIgpsportPoiType('Water'), IgpsportPoiType.supplyPoint);
    expect(mapIgpsportPoiType('Sharp Curve'), IgpsportPoiType.sharpBend);
  });

  test('map summit fallback', () {
    expect(mapIgpsportPoiType('Summit'), IgpsportPoiType.hcLevelClimbing);
  });

  test('map unknown defaults to via point', () {
    expect(mapIgpsportPoiType('totally-unknown'), IgpsportPoiType.viaPoint);
    expect(mapIgpsportPoiType(null), IgpsportPoiType.viaPoint);
  });

  test('extract pois dedupes and maps', () {
    final pois = extractPoisFromGpxBytes(sampleGpx);
    final names = [for (final p in pois) p.name];
    // Duplicate "Water Stop" collapsed; unnamed trkpt excluded.
    expect(names, ['Water Stop', 'Top', 'Named Track Point']);
    expect(pois[0].poiType, IgpsportPoiType.supplyPoint);
    expect(pois[1].poiType, IgpsportPoiType.hcLevelClimbing);
  });

  test('extract pois respects maxPoints', () {
    expect(
      extractPoisFromGpxBytes(sampleGpx, maxPoints: 1)[0].name,
      'Water Stop',
    );
    expect(extractPoisFromGpxBytes(sampleGpx, maxPoints: 0), isEmpty);
  });

  test('extract pois invalid gpx returns empty', () {
    expect(extractPoisFromGpxBytes(utf8.encode('not gpx at all')), isEmpty);
  });
}

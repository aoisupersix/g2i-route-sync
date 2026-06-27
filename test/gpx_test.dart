import 'dart:convert';

import 'package:g2i_route_sync/gpx.dart';
import 'package:test/test.dart';

void main() {
  test('inferExtension by suffix', () {
    expect(inferExtension(<int>[], 'course.gpx'), '.gpx');
    expect(inferExtension(<int>[], 'course.tcx'), '.tcx');
    expect(inferExtension(<int>[], 'course.fit'), '.fit');
  });

  test('inferExtension by content', () {
    expect(
      inferExtension(utf8.encode('<?xml version="1.0"?><gpx></gpx>'), 'x'),
      '.gpx',
    );
    expect(
      inferExtension(
        utf8.encode('<?xml version="1.0"?><TrainingCenterDatabase>'),
        'x',
      ),
      '.tcx',
    );
    expect(inferExtension([0x00, 0x01, ...utf8.encode('binary')], 'x'), '.fit');
  });

  test('buildGpxFromCourseDetail includes track and waypoints', () {
    final detail = {
      'courseName': 'Test Course',
      'geoPoints': [
        {'latitude': 35.0, 'longitude': 139.0, 'elevation': 10},
        {'latitude': 35.1, 'longitude': 139.1, 'timestamp': 1700000000000},
      ],
      'coursePoints': [
        {
          'lat': 35.0,
          'lon': 139.0,
          'name': 'Start',
          'coursePointType': 'GENERIC',
        },
      ],
    };
    final gpx = utf8.decode(buildGpxFromCourseDetail(detail, 'fallback'));
    expect(gpx, contains('<name>Test Course</name>'));
    expect(gpx, contains('lat="35.0" lon="139.0"'));
    expect(gpx, contains('<wpt'));
    expect(gpx, isNot(contains('1970'))); // timestamp converted, not raw epoch
    expect(gpx.startsWith('<?xml'), isTrue);
  });

  test('buildGpxFromCourseDetail uses fallback name', () {
    final detail = {
      'geoPoints': [
        {'latitude': 1.0, 'longitude': 2.0},
      ],
    };
    final gpx = utf8.decode(buildGpxFromCourseDetail(detail, 'Fallback Name'));
    expect(gpx, contains('<name>Fallback Name</name>'));
  });

  test('buildGpxFromCourseDetail without geoPoints throws', () {
    expect(
      () => buildGpxFromCourseDetail({'geoPoints': <dynamic>[]}, 'x'),
      throwsA(isA<StateError>()),
    );
  });
}

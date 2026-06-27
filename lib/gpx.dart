/// GPX construction and format detection helpers.
library;

import 'dart:convert';

/// Escape the XML special characters that ``xml.sax.saxutils.escape`` handles
/// by default: ``&``, ``<`` and ``>``.
String _xmlEscape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// Format a JSON number the way Python's ``str()`` would for GPX coordinates,
/// so doubles like ``35.0`` keep their trailing ``.0``.
String _numStr(dynamic value) {
  if (value is int) return value.toString();
  if (value is double) {
    if (value.isFinite && value == value.truncateToDouble()) {
      return '${value.toInt()}.0';
    }
    return value.toString();
  }
  return value.toString();
}

/// ISO-8601 UTC timestamp matching Python's ``datetime.isoformat()`` output:
/// fractional seconds are omitted when zero, and the offset is rendered ``Z``.
String _isoUtc(int millis) {
  final dt = DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  var iso = dt.toIso8601String(); // e.g. 2023-11-14T22:13:20.000Z
  iso = iso.replaceAll('.000Z', 'Z');
  return iso;
}

/// Guess the route file extension from its source URL and/or content.
String inferExtension(List<int> content, String source) {
  final lowered = source.toLowerCase();
  if (lowered.endsWith('.gpx')) return '.gpx';
  if (lowered.endsWith('.tcx')) return '.tcx';
  if (lowered.endsWith('.fit')) return '.fit';

  final head = latin1.decode(content.take(1000).toList(), allowInvalid: true);
  if (head.trimLeft().startsWith('<?xml')) {
    final first500 = head.length > 500 ? head.substring(0, 500) : head;
    if (first500.toLowerCase().contains('<gpx')) return '.gpx';
    if (head.toLowerCase().contains('<trainingcenterdatabase')) return '.tcx';
  }
  return '.fit';
}

/// Build a GPX document (UTF-8 bytes) from a Garmin course detail payload.
List<int> buildGpxFromCourseDetail(
  Map<String, dynamic> courseDetail,
  String fallbackName,
) {
  final geoPoints = courseDetail['geoPoints'];
  if (geoPoints is! List || geoPoints.isEmpty) {
    throw StateError('Garmin course detail does not contain geoPoints');
  }

  final coursePoints = courseDetail['coursePoints'];
  final waypoints = <String>[];
  if (coursePoints is List) {
    for (final cp in coursePoints) {
      if (cp is! Map) continue;
      final lat = cp['lat'];
      final lon = cp['lon'];
      if (lat == null || lon == null) continue;
      final wptName = (cp['name'] ?? 'POI').toString();
      final wptNote = cp['note'];
      final wptType = cp['coursePointType'];

      final lines = <String>[
        '  <wpt lat="${_numStr(lat)}" lon="${_numStr(lon)}">',
      ];
      final ele = cp['elevation'];
      if (ele != null) lines.add('    <ele>${_numStr(ele)}</ele>');
      lines.add('    <name>${_xmlEscape(wptName)}</name>');
      if (wptNote is String && wptNote.trim().isNotEmpty) {
        lines.add('    <cmt>${_xmlEscape(wptNote)}</cmt>');
      }
      if (wptType is String && wptType.trim().isNotEmpty) {
        lines.add('    <type>${_xmlEscape(wptType)}</type>');
      }
      lines.add('  </wpt>');
      waypoints.add(lines.join('\n'));
    }
  }

  final name = (courseDetail['courseName'] ?? fallbackName).toString();
  final trkpts = <String>[];
  for (final point in geoPoints) {
    if (point is! Map) continue;

    final lat = point['latitude'];
    final lon = point['longitude'];
    if (lat == null || lon == null) continue;

    final parts = <String>[
      '<trkpt lat="${_numStr(lat)}" lon="${_numStr(lon)}">',
    ];
    final ele = point['elevation'];
    if (ele != null) parts.add('<ele>${_numStr(ele)}</ele>');

    final timestampMs = point['timestamp'];
    if (timestampMs is num && timestampMs > 0) {
      parts.add('<time>${_isoUtc(timestampMs.toInt())}</time>');
    }

    parts.add('</trkpt>');
    trkpts.add(parts.join());
  }

  if (trkpts.isEmpty) {
    throw StateError('No valid geoPoints to build GPX');
  }

  final buffer =
      StringBuffer()
        ..write('<?xml version="1.0" encoding="UTF-8"?>\n')
        ..write(
          '<gpx version="1.1" creator="g2i-route-sync" '
          'xmlns="http://www.topografix.com/GPX/1/1">\n',
        );
  if (waypoints.isNotEmpty) {
    buffer.write('${waypoints.join('\n')}\n');
  }
  buffer
    ..write('  <trk><name>${_xmlEscape(name)}</name><trkseg>\n')
    ..write(trkpts.map((t) => '    $t').join('\n'))
    ..write('\n  </trkseg></trk>\n')
    ..write('</gpx>\n');

  return utf8.encode(buffer.toString());
}

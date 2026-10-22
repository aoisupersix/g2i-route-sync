/// Route content fingerprint used to detect changes between syncs.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';

/// Return a SHA-256 fingerprint of a downloaded route file.
///
/// GPX is reduced to point coordinates/elevation and waypoint name/type so
/// that export timestamps and metadata do not register as changes. Other
/// formats (TCX/FIT) fall back to hashing the raw bytes.
String routeFingerprint(List<int> content) {
  final canonical = _canonicalGpx(content);
  if (canonical == null) return sha256.convert(content).toString();
  return sha256.convert(utf8.encode(canonical)).toString();
}

const _pointTags = {'trkpt', 'rtept', 'wpt'};

String? _canonicalGpx(List<int> content) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(utf8.decode(content, allowMalformed: true));
  } on XmlException {
    return null;
  }
  if (doc.rootElement.localName != 'gpx') return null;

  final lines = [
    for (final element in doc.descendantElements)
      if (_pointTags.contains(element.localName)) _canonicalPoint(element),
  ];
  return lines.join('\n');
}

String _canonicalPoint(XmlElement element) {
  final tag = element.localName;
  final fields = [
    tag,
    element.getAttribute('lat'),
    element.getAttribute('lon'),
    _childText(element, 'ele'),
    if (tag == 'wpt') ...[
      _childText(element, 'name'),
      _childText(element, 'type'),
    ],
  ];
  return fields.map((field) => field ?? '').join('|');
}

String? _childText(XmlElement element, String name) {
  for (final child in element.childElements) {
    if (child.localName == name) return child.innerText.trim();
  }
  return null;
}

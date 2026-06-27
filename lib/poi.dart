/// POI (auxiliary point) types and extraction from GPX.
library;

import 'dart:convert';

import 'package:xml/xml.dart';

import 'logging.dart';

/// iGPSPORT auxiliary point types used by editRoutesAuxiliaryPoint API.
enum IgpsportPoiType {
  intersection('Intersection'),
  steepDescentAhead('SteepDescentAhead'),
  sharpBend('SharpBend'),
  dangerousArea('DangerousArea'),
  valley('Valley'),
  tunnel('Tunnel'),
  internetCelebrityClockInPoint('InternetCelebrityClockInPoint'),
  observationDeck('ObservationDeck'),
  rallyPoint('RallyPoint'),
  shop('Shop'),
  equipment('Equipment'),
  medicalAidStation('MedicalAidStation'),
  servicePoint('ServicePoint'),
  waterCloset('WaterCloset'),
  refuseCollectionArea('RefuseCollectionArea'),
  supplyPoint('SupplyPoint'),
  fourLevelClimbing('FourLevelClimbing'),
  threeLevelClimbing('ThreeLevelClimbing'),
  twoLevelClimbing('TwoLevelClimbing'),
  oneLevelClimbing('OneLevelClimbing'),
  hcLevelClimbing('HCLevelClimbing'),
  sprintPoint('SprintPoint'),
  viaPoint('ViaPoint');

  final String value;
  const IgpsportPoiType(this.value);
}

class PoiCandidate {
  final String name;
  final double latitude;
  final double longitude;
  final IgpsportPoiType poiType;
  final String nameOrigin;

  PoiCandidate({
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.poiType,
    required this.nameOrigin,
  });
}

final _nonAlnum = RegExp(r'[^A-Z0-9]');

String _normalizeTypeKey(String value) =>
    value.toUpperCase().replaceAll(_nonAlnum, '');

/// Garmin waypoint types (verified from full-type GPX sample) mapped to iGPSPORT.
const _gpxTypeMap = <String, IgpsportPoiType>{
  'GENERAL DISTANCE': IgpsportPoiType.viaPoint,
  'GENERIC': IgpsportPoiType.viaPoint,
  'MILE MARKER': IgpsportPoiType.viaPoint,
  'INFO': IgpsportPoiType.viaPoint,
  'SERVICE': IgpsportPoiType.servicePoint,
  'AID STATION': IgpsportPoiType.medicalAidStation,
  'FIRST AID': IgpsportPoiType.medicalAidStation,
  'FOOD': IgpsportPoiType.supplyPoint,
  'WATER': IgpsportPoiType.supplyPoint,
  'ENERGY GEL': IgpsportPoiType.supplyPoint,
  'SPORTS DRINK': IgpsportPoiType.supplyPoint,
  'SPRINT': IgpsportPoiType.sprintPoint,
  'HORS CATEGORY': IgpsportPoiType.hcLevelClimbing,
  'FIRST CATEGORY': IgpsportPoiType.oneLevelClimbing,
  'SECOND CATEGORY': IgpsportPoiType.twoLevelClimbing,
  'THIRD CATEGORY': IgpsportPoiType.threeLevelClimbing,
  'FOURTH CATEGORY': IgpsportPoiType.fourLevelClimbing,
  'TOILET': IgpsportPoiType.waterCloset,
  'SHOWER': IgpsportPoiType.servicePoint,
  'GEAR': IgpsportPoiType.equipment,
  'NAVAID': IgpsportPoiType.viaPoint,
  'TRANSPORT': IgpsportPoiType.viaPoint,
  'TRANSITION': IgpsportPoiType.viaPoint,
  'CHECKPOINT': IgpsportPoiType.viaPoint,
  'MEETING SPOT': IgpsportPoiType.rallyPoint,
  'CAMPSITE': IgpsportPoiType.servicePoint,
  'SHELTER': IgpsportPoiType.servicePoint,
  'REST AREA': IgpsportPoiType.servicePoint,
  'RACE OBSTACLE START': IgpsportPoiType.dangerousArea,
  'RACE OBSTACLE END': IgpsportPoiType.dangerousArea,
  'SUMMIT': IgpsportPoiType.hcLevelClimbing,
  'TUNNEL': IgpsportPoiType.tunnel,
  'BRIDGE': IgpsportPoiType.dangerousArea,
  'VALLEY': IgpsportPoiType.valley,
  'OVERLOOK': IgpsportPoiType.observationDeck,
  'STORE': IgpsportPoiType.shop,
  'ALERT': IgpsportPoiType.dangerousArea,
  'DANGER': IgpsportPoiType.dangerousArea,
  'OBSTACLE': IgpsportPoiType.dangerousArea,
  'CROSSING': IgpsportPoiType.intersection,
  'STEEP INCLINE': IgpsportPoiType.steepDescentAhead,
  'SHARP CURVE': IgpsportPoiType.sharpBend,
};

final _normalizedTypeMap = <String, IgpsportPoiType>{
  for (final entry in _gpxTypeMap.entries)
    _normalizeTypeKey(entry.key): entry.value,
};

/// Map a GPX waypoint type to an iGPSPORT POI type, defaulting to ViaPoint.
IgpsportPoiType mapIgpsportPoiType(String? gpxType) {
  final norm = (gpxType ?? '')
      .trim()
      .toUpperCase()
      .split(RegExp(r'\s+'))
      .join(' ');
  final key = _normalizeTypeKey(norm);

  final mapped = _normalizedTypeMap[key];
  if (mapped != null) return mapped;

  if (norm == 'GENERIC' || norm == 'WAYPOINT') return IgpsportPoiType.viaPoint;
  if (norm == 'SUMMIT') return IgpsportPoiType.hcLevelClimbing;

  return IgpsportPoiType.viaPoint;
}

List<PoiCandidate> extractPoisFromGpxBytes(
  List<int> gpxBytes, {
  int? maxPoints,
}) {
  XmlDocument doc;
  try {
    doc = XmlDocument.parse(utf8.decode(gpxBytes, allowMalformed: true));
  } on XmlException catch (exc) {
    logDebug('Failed to parse GPX for POI extraction: $exc');
    return [];
  }

  final pois = <PoiCandidate>[];
  final seen = <String>{};

  void addCandidate(
    String? name,
    double? latitude,
    double? longitude, {
    String? gpxType,
  }) {
    if (latitude == null || longitude == null) return;
    var poiName = (name ?? 'POI').trim();
    if (poiName.isEmpty) poiName = 'POI';
    final key =
        '${(latitude * 1000000).round()},'
        '${(longitude * 1000000).round()},$poiName';
    if (seen.contains(key)) return;
    seen.add(key);
    final clipped = poiName.length > 64 ? poiName.substring(0, 64) : poiName;
    pois.add(
      PoiCandidate(
        name: clipped,
        latitude: latitude,
        longitude: longitude,
        poiType: mapIgpsportPoiType(gpxType),
        nameOrigin: clipped,
      ),
    );
  }

  double? attrDouble(XmlElement el, String name) =>
      double.tryParse(el.getAttribute(name) ?? '');

  String? childText(XmlElement el, String name) {
    final child = el.getElement(name);
    final text = child?.innerText.trim();
    return (text == null || text.isEmpty) ? null : text;
  }

  for (final wpt in doc.findAllElements('wpt')) {
    addCandidate(
      childText(wpt, 'name'),
      attrDouble(wpt, 'lat'),
      attrDouble(wpt, 'lon'),
      gpxType: childText(wpt, 'type'),
    );
  }

  for (final rtept in doc.findAllElements('rtept')) {
    final name = childText(rtept, 'name');
    if (name != null) {
      addCandidate(name, attrDouble(rtept, 'lat'), attrDouble(rtept, 'lon'));
    }
  }

  for (final trkpt in doc.findAllElements('trkpt')) {
    final name = childText(trkpt, 'name');
    if (name != null) {
      addCandidate(name, attrDouble(trkpt, 'lat'), attrDouble(trkpt, 'lon'));
    }
  }

  if (maxPoints == null) return pois;
  if (maxPoints <= 0) return [];
  return pois.length > maxPoints ? pois.sublist(0, maxPoints) : pois;
}

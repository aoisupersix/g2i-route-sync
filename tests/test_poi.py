from g2i_route_sync.poi import (
    IGPSPORTPOIType,
    extract_pois_from_gpx_bytes,
    map_igpsport_poi_type,
)

SAMPLE_GPX = b"""<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
  <wpt lat="35.0" lon="139.0"><name>Water Stop</name><type>Water</type></wpt>
  <wpt lat="35.1" lon="139.1"><name>Top</name><type>Summit</type></wpt>
  <wpt lat="35.0" lon="139.0"><name>Water Stop</name><type>Water</type></wpt>
  <trk><name>route</name><trkseg>
    <trkpt lat="35.2" lon="139.2"><name>Named Track Point</name></trkpt>
    <trkpt lat="35.3" lon="139.3"></trkpt>
  </trkseg></trk>
</gpx>
"""


def test_map_known_type():
    assert map_igpsport_poi_type("Water") == IGPSPORTPOIType.SUPPLY_POINT
    assert map_igpsport_poi_type("Sharp Curve") == IGPSPORTPOIType.SHARP_BEND


def test_map_summit_fallback():
    assert map_igpsport_poi_type("Summit") == IGPSPORTPOIType.HC_LEVEL_CLIMBING


def test_map_unknown_defaults_to_via_point():
    assert map_igpsport_poi_type("totally-unknown") == IGPSPORTPOIType.VIA_POINT
    assert map_igpsport_poi_type(None) == IGPSPORTPOIType.VIA_POINT


def test_extract_pois_dedupes_and_maps():
    pois = extract_pois_from_gpx_bytes(SAMPLE_GPX)
    names = [p.name for p in pois]
    # Duplicate "Water Stop" collapsed; unnamed trkpt excluded.
    assert names == ["Water Stop", "Top", "Named Track Point"]
    assert pois[0].poi_type == IGPSPORTPOIType.SUPPLY_POINT
    assert pois[1].poi_type == IGPSPORTPOIType.HC_LEVEL_CLIMBING


def test_extract_pois_respects_max_points():
    assert extract_pois_from_gpx_bytes(SAMPLE_GPX, max_points=1)[0].name == "Water Stop"
    assert extract_pois_from_gpx_bytes(SAMPLE_GPX, max_points=0) == []


def test_extract_pois_invalid_gpx_returns_empty():
    assert extract_pois_from_gpx_bytes(b"not gpx at all") == []

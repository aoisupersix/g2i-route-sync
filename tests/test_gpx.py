import pytest

from g2i_route_sync.gpx import build_gpx_from_course_detail, infer_extension


def test_infer_extension_by_suffix():
    assert infer_extension(b"", "course.gpx") == ".gpx"
    assert infer_extension(b"", "course.tcx") == ".tcx"
    assert infer_extension(b"", "course.fit") == ".fit"


def test_infer_extension_by_content():
    assert infer_extension(b'<?xml version="1.0"?><gpx></gpx>', "x") == ".gpx"
    assert (
        infer_extension(b'<?xml version="1.0"?><TrainingCenterDatabase>', "x") == ".tcx"
    )
    assert infer_extension(b"\x00\x01binary", "x") == ".fit"


def test_build_gpx_includes_track_and_waypoints():
    detail = {
        "courseName": "Test Course",
        "geoPoints": [
            {"latitude": 35.0, "longitude": 139.0, "elevation": 10},
            {"latitude": 35.1, "longitude": 139.1, "timestamp": 1_700_000_000_000},
        ],
        "coursePoints": [
            {"lat": 35.0, "lon": 139.0, "name": "Start", "coursePointType": "GENERIC"},
        ],
    }
    gpx = build_gpx_from_course_detail(detail, "fallback").decode("utf-8")
    assert "<name>Test Course</name>" in gpx
    assert 'lat="35.0" lon="139.0"' in gpx
    assert "<wpt" in gpx
    assert "1970" not in gpx  # timestamp converted, not raw epoch
    assert gpx.startswith("<?xml")


def test_build_gpx_uses_fallback_name():
    detail = {"geoPoints": [{"latitude": 1.0, "longitude": 2.0}]}
    gpx = build_gpx_from_course_detail(detail, "Fallback Name").decode("utf-8")
    assert "<name>Fallback Name</name>" in gpx


def test_build_gpx_without_geopoints_raises():
    with pytest.raises(RuntimeError):
        build_gpx_from_course_detail({"geoPoints": []}, "x")

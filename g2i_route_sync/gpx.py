"""GPX construction and format detection helpers."""

from __future__ import annotations

import datetime as dt
from typing import Any
from xml.sax.saxutils import escape


def infer_extension(content: bytes, source: str) -> str:
    """Guess the route file extension from its source URL and/or content."""
    lowered = source.lower()
    if lowered.endswith(".gpx"):
        return ".gpx"
    if lowered.endswith(".tcx"):
        return ".tcx"
    if lowered.endswith(".fit"):
        return ".fit"
    if content[:100].lstrip().startswith(b"<?xml"):
        if b"<gpx" in content[:500].lower():
            return ".gpx"
        if b"<trainingcenterdatabase" in content[:1000].lower():
            return ".tcx"
    return ".fit"


def build_gpx_from_course_detail(
    course_detail: dict[str, Any], fallback_name: str
) -> bytes:
    """Build a GPX document from a Garmin course detail payload."""
    geo_points = course_detail.get("geoPoints")
    if not isinstance(geo_points, list) or not geo_points:
        raise RuntimeError("Garmin course detail does not contain geoPoints")

    course_points = course_detail.get("coursePoints")
    waypoints: list[str] = []
    if isinstance(course_points, list):
        for cp in course_points:
            if not isinstance(cp, dict):
                continue
            lat = cp.get("lat")
            lon = cp.get("lon")
            if lat is None or lon is None:
                continue
            wpt_name = str(cp.get("name") or "POI")
            wpt_note = cp.get("note")
            wpt_type = cp.get("coursePointType")

            lines = [f'  <wpt lat="{lat}" lon="{lon}">']
            ele = cp.get("elevation")
            if ele is not None:
                lines.append(f"    <ele>{ele}</ele>")
            lines.append(f"    <name>{escape(wpt_name)}</name>")
            if isinstance(wpt_note, str) and wpt_note.strip():
                lines.append(f"    <cmt>{escape(wpt_note)}</cmt>")
            if isinstance(wpt_type, str) and wpt_type.strip():
                lines.append(f"    <type>{escape(wpt_type)}</type>")
            lines.append("  </wpt>")
            waypoints.append("\n".join(lines))

    name = str(course_detail.get("courseName") or fallback_name)
    trkpts: list[str] = []
    for point in geo_points:
        if not isinstance(point, dict):
            continue

        lat = point.get("latitude")
        lon = point.get("longitude")
        if lat is None or lon is None:
            continue

        line_parts = [f'<trkpt lat="{lat}" lon="{lon}">']
        ele = point.get("elevation")
        if ele is not None:
            line_parts.append(f"<ele>{ele}</ele>")

        timestamp_ms = point.get("timestamp")
        if isinstance(timestamp_ms, (int, float)) and timestamp_ms > 0:
            timestamp = dt.datetime.fromtimestamp(
                float(timestamp_ms) / 1000.0, tz=dt.timezone.utc
            )
            line_parts.append(
                f"<time>{timestamp.isoformat().replace('+00:00', 'Z')}</time>"
            )

        line_parts.append("</trkpt>")
        trkpts.append("".join(line_parts))

    if not trkpts:
        raise RuntimeError("No valid geoPoints to build GPX")

    gpx = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<gpx version="1.1" creator="g2i-route-sync" '
        'xmlns="http://www.topografix.com/GPX/1/1">\n'
        + ("\n".join(waypoints) + "\n" if waypoints else "")
        + f"  <trk><name>{escape(name)}</name><trkseg>\n"
        + "\n".join(f"    {trackpoint}" for trackpoint in trkpts)
        + "\n  </trkseg></trk>\n"
        + "</gpx>\n"
    )
    return gpx.encode("utf-8")

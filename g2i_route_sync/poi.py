"""POI (auxiliary point) types and extraction from GPX."""

from __future__ import annotations

import logging
from dataclasses import dataclass
from enum import Enum

import gpxpy

LOGGER = logging.getLogger("g2i-route-sync")


class IGPSPORTPOIType(str, Enum):
    """iGPSPORT auxiliary point types used by editRoutesAuxiliaryPoint API."""

    INTERSECTION = "Intersection"
    STEEP_DESCENT_AHEAD = "SteepDescentAhead"
    SHARP_BEND = "SharpBend"
    DANGEROUS_AREA = "DangerousArea"
    VALLEY = "Valley"
    TUNNEL = "Tunnel"
    INTERNET_CELEBRITY_CLOCK_IN_POINT = "InternetCelebrityClockInPoint"
    OBSERVATION_DECK = "ObservationDeck"
    RALLY_POINT = "RallyPoint"
    SHOP = "Shop"
    EQUIPMENT = "Equipment"
    MEDICAL_AID_STATION = "MedicalAidStation"
    SERVICE_POINT = "ServicePoint"
    WATER_CLOSET = "WaterCloset"
    REFUSE_COLLECTION_AREA = "RefuseCollectionArea"
    SUPPLY_POINT = "SupplyPoint"
    FOUR_LEVEL_CLIMBING = "FourLevelClimbing"
    THREE_LEVEL_CLIMBING = "ThreeLevelClimbing"
    TWO_LEVEL_CLIMBING = "TwoLevelClimbing"
    ONE_LEVEL_CLIMBING = "OneLevelClimbing"
    HC_LEVEL_CLIMBING = "HCLevelClimbing"
    SPRINT_POINT = "SprintPoint"
    VIA_POINT = "ViaPoint"


@dataclass
class POICandidate:
    name: str
    latitude: float
    longitude: float
    poi_type: IGPSPORTPOIType
    name_origin: str


def _normalize_key(value: str) -> str:
    return "".join(ch for ch in value.upper() if ch.isalnum())


# Garmin waypoint types (verified from full-type GPX sample) mapped to iGPSPORT.
_GPX_TYPE_MAP: dict[str, IGPSPORTPOIType] = {
    "GENERAL DISTANCE": IGPSPORTPOIType.VIA_POINT,
    "GENERIC": IGPSPORTPOIType.VIA_POINT,
    "MILE MARKER": IGPSPORTPOIType.VIA_POINT,
    "INFO": IGPSPORTPOIType.VIA_POINT,
    "SERVICE": IGPSPORTPOIType.SERVICE_POINT,
    "AID STATION": IGPSPORTPOIType.MEDICAL_AID_STATION,
    "FIRST AID": IGPSPORTPOIType.MEDICAL_AID_STATION,
    "FOOD": IGPSPORTPOIType.SUPPLY_POINT,
    "WATER": IGPSPORTPOIType.SUPPLY_POINT,
    "ENERGY GEL": IGPSPORTPOIType.SUPPLY_POINT,
    "SPORTS DRINK": IGPSPORTPOIType.SUPPLY_POINT,
    "SPRINT": IGPSPORTPOIType.SPRINT_POINT,
    "HORS CATEGORY": IGPSPORTPOIType.HC_LEVEL_CLIMBING,
    "FIRST CATEGORY": IGPSPORTPOIType.ONE_LEVEL_CLIMBING,
    "SECOND CATEGORY": IGPSPORTPOIType.TWO_LEVEL_CLIMBING,
    "THIRD CATEGORY": IGPSPORTPOIType.THREE_LEVEL_CLIMBING,
    "FOURTH CATEGORY": IGPSPORTPOIType.FOUR_LEVEL_CLIMBING,
    "TOILET": IGPSPORTPOIType.WATER_CLOSET,
    "SHOWER": IGPSPORTPOIType.SERVICE_POINT,
    "GEAR": IGPSPORTPOIType.EQUIPMENT,
    "NAVAID": IGPSPORTPOIType.VIA_POINT,
    "TRANSPORT": IGPSPORTPOIType.VIA_POINT,
    "TRANSITION": IGPSPORTPOIType.VIA_POINT,
    "CHECKPOINT": IGPSPORTPOIType.VIA_POINT,
    "MEETING SPOT": IGPSPORTPOIType.RALLY_POINT,
    "CAMPSITE": IGPSPORTPOIType.SERVICE_POINT,
    "SHELTER": IGPSPORTPOIType.SERVICE_POINT,
    "REST AREA": IGPSPORTPOIType.SERVICE_POINT,
    "RACE OBSTACLE START": IGPSPORTPOIType.DANGEROUS_AREA,
    "RACE OBSTACLE END": IGPSPORTPOIType.DANGEROUS_AREA,
    "SUMMIT": IGPSPORTPOIType.HC_LEVEL_CLIMBING,
    "TUNNEL": IGPSPORTPOIType.TUNNEL,
    "BRIDGE": IGPSPORTPOIType.DANGEROUS_AREA,
    "VALLEY": IGPSPORTPOIType.VALLEY,
    "OVERLOOK": IGPSPORTPOIType.OBSERVATION_DECK,
    "STORE": IGPSPORTPOIType.SHOP,
    "ALERT": IGPSPORTPOIType.DANGEROUS_AREA,
    "DANGER": IGPSPORTPOIType.DANGEROUS_AREA,
    "OBSTACLE": IGPSPORTPOIType.DANGEROUS_AREA,
    "CROSSING": IGPSPORTPOIType.INTERSECTION,
    "STEEP INCLINE": IGPSPORTPOIType.STEEP_DESCENT_AHEAD,
    "SHARP CURVE": IGPSPORTPOIType.SHARP_BEND,
}

_NORMALIZED_TYPE_MAP = {
    _normalize_key(key): value for key, value in _GPX_TYPE_MAP.items()
}


def map_igpsport_poi_type(gpx_type: str | None) -> IGPSPORTPOIType:
    """Map a GPX waypoint type to an iGPSPORT POI type, defaulting to ViaPoint."""
    gpx_type_norm = " ".join((gpx_type or "").strip().upper().split())
    gpx_type_key = _normalize_key(gpx_type_norm)

    if gpx_type_key in _NORMALIZED_TYPE_MAP:
        return _NORMALIZED_TYPE_MAP[gpx_type_key]

    if gpx_type_norm in {"GENERIC", "WAYPOINT"}:
        return IGPSPORTPOIType.VIA_POINT
    if gpx_type_norm in {"SUMMIT"}:
        return IGPSPORTPOIType.HC_LEVEL_CLIMBING

    return IGPSPORTPOIType.VIA_POINT


def extract_pois_from_gpx_bytes(
    gpx_bytes: bytes, max_points: int | None = None
) -> list[POICandidate]:
    try:
        gpx = gpxpy.parse(gpx_bytes.decode("utf-8", errors="replace"))
    except Exception as exc:  # noqa: BLE001
        LOGGER.debug("Failed to parse GPX for POI extraction: %s", exc)
        return []

    pois: list[POICandidate] = []
    seen: set[tuple[int, int, str]] = set()

    def add_candidate(
        name: str | None,
        latitude: float | None,
        longitude: float | None,
        gpx_type: str | None = None,
    ) -> None:
        if latitude is None or longitude is None:
            return
        poi_name = (name or "POI").strip() or "POI"
        key = (round(latitude * 1_000_000), round(longitude * 1_000_000), poi_name)
        if key in seen:
            return
        seen.add(key)
        pois.append(
            POICandidate(
                name=poi_name[:64],
                latitude=float(latitude),
                longitude=float(longitude),
                poi_type=map_igpsport_poi_type(gpx_type),
                name_origin=poi_name[:64],
            )
        )

    for wpt in gpx.waypoints:
        add_candidate(
            wpt.name,
            wpt.latitude,
            wpt.longitude,
            getattr(wpt, "type", None),
        )

    for route in gpx.routes:
        for point in route.points:
            # Route points with name are generally authored POIs/cues.
            if getattr(point, "name", None):
                add_candidate(point.name, point.latitude, point.longitude)

    for track in gpx.tracks:
        for segment in track.segments:
            for point in segment.points:
                if getattr(point, "name", None):
                    add_candidate(point.name, point.latitude, point.longitude)

    if max_points is None:
        return pois
    if max_points <= 0:
        return []
    return pois[:max_points]

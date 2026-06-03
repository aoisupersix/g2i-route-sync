#!/usr/bin/env python3
"""Sync routes from Garmin Connect to iGPSPORT via API.

This script is intentionally Python-only and does not rely on external tools.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import logging
import mimetypes
import os
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Any
from xml.sax.saxutils import escape

import gpxpy
import requests
from dotenv import load_dotenv
from garminconnect import Garmin


LOGGER = logging.getLogger("g2i-route-sync")

DEFAULT_IGPSPORT_DOMAIN = "prod.en.igpsport.com"
DEFAULT_IGPSPORT_REFERER = "https://login.passport.igpsport.com"
DEFAULT_IGPSPORT_WEB_BASE_URL = "https://i.igpsport.com"
DEFAULT_IGPSPORT_WEB_LOGIN_PATH = "/Auth/Login"
DEFAULT_IGPSPORT_WEB_UPLOAD_URL = "https://i.igpsport.com/Routes/uploadroad"
DEFAULT_IGPSPORT_WEB_REFERER = "https://i.igpsport.com/explorer/upload"
DEFAULT_IGPSPORT_WEB_COOKIE_FILE = ".state/igpsport_web_cookies.json"
DEFAULT_IGPSPORT_UPLOAD_ENDPOINTS = [
    "/web-gateway/web-route/route/import",
    "/web-gateway/web-course/course/import",
    "/web-gateway/web-route/route/upload",
    "/web-gateway/web-course/import",
]
DEFAULT_GARMIN_ROUTE_LIST_ENDPOINTS = [
    "/course-service/course/search",
    "/course-service/course",
]
DEFAULT_GARMIN_ROUTE_DOWNLOAD_ENDPOINTS = [
    "/download-service/export/gpx/course/{route_id}",
    "/download-service/files/course/{route_id}",
    "/download-service/export/tcx/course/{route_id}",
]


@dataclass
class RouteSummary:
    route_id: str
    name: str
    raw: dict[str, Any]


@dataclass
class RoadBookSummary:
    roadbook_id: int
    title: str


@dataclass
class POICandidate:
    name: str
    latitude: float
    longitude: float
    poi_type: "IGPSPORTPOIType"
    name_origin: str


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


class GarminRouteClient:
    def __init__(
        self,
        email: str,
        password: str,
        is_cn: bool,
        session_dir: Path,
        list_endpoints: list[str] | None = None,
        download_endpoints: list[str] | None = None,
    ) -> None:
        self._garmin = Garmin(email=email, password=password, is_cn=is_cn)
        self._session_dir = session_dir
        self._list_endpoints = list_endpoints or DEFAULT_GARMIN_ROUTE_LIST_ENDPOINTS
        self._download_endpoints = (
            download_endpoints or DEFAULT_GARMIN_ROUTE_DOWNLOAD_ENDPOINTS
        )

    def login(self) -> None:
        self._session_dir.mkdir(parents=True, exist_ok=True)
        self._garmin.login(str(self._session_dir))
        LOGGER.info("Authenticated to Garmin Connect")

    def list_routes(self, limit: int) -> list[RouteSummary]:
        params_candidates = [
            {"start": 0, "limit": limit},
            {"page": 1, "pageSize": limit},
            {"offset": 0, "limit": limit},
        ]
        last_error: Exception | None = None

        for endpoint in self._list_endpoints:
            for params in params_candidates:
                try:
                    payload = self._garmin.connectapi(endpoint, params=params)
                    routes = self._extract_route_list(payload)
                    if routes:
                        LOGGER.info(
                            "Found %d routes from Garmin endpoint=%s",
                            len(routes),
                            endpoint,
                        )
                        return routes[:limit]
                except Exception as exc:  # noqa: BLE001
                    last_error = exc
                    LOGGER.debug(
                        "Garmin route list call failed endpoint=%s params=%s err=%s",
                        endpoint,
                        params,
                        exc,
                    )

        if last_error:
            raise RuntimeError(
                "Failed to fetch Garmin routes from all configured endpoints"
            ) from last_error

        raise RuntimeError("No Garmin routes found")

    def download_route(self, route: RouteSummary) -> tuple[bytes, str]:
        direct_urls = [
            route.raw.get("downloadUrl"),
            route.raw.get("gpxDownloadUrl"),
            route.raw.get("fitDownloadUrl"),
            route.raw.get("courseDownloadUrl"),
        ]
        for direct_url in direct_urls:
            if isinstance(direct_url, str) and direct_url:
                try:
                    content = self._garmin.download(direct_url)
                    return content, self._infer_extension(content, direct_url)
                except Exception as exc:  # noqa: BLE001
                    LOGGER.debug(
                        "Direct Garmin route download failed route_id=%s url=%s err=%s",
                        route.route_id,
                        direct_url,
                        exc,
                    )

        last_error: Exception | None = None
        for endpoint_template in self._download_endpoints:
            endpoint = endpoint_template.format(route_id=route.route_id)
            try:
                content = self._garmin.download(endpoint)
                return content, self._infer_extension(content, endpoint)
            except Exception as exc:  # noqa: BLE001
                last_error = exc
                LOGGER.debug(
                    "Garmin route download failed route_id=%s endpoint=%s err=%s",
                    route.route_id,
                    endpoint,
                    exc,
                )

        if last_error:
            LOGGER.debug(
                "Falling back to GPX generation from course detail route_id=%s",
                route.route_id,
            )
        course_detail = self._get_course_detail(route.route_id)
        gpx_bytes = self._build_gpx_from_course_detail(course_detail, route.name)
        return gpx_bytes, ".gpx"

    @staticmethod
    def _extract_route_list(payload: Any) -> list[RouteSummary]:
        if isinstance(payload, list):
            items = payload
        elif isinstance(payload, dict):
            candidate_keys = [
                "rows",
                "items",
                "courseItems",
                "courses",
                "data",
                "result",
            ]
            items = []
            for key in candidate_keys:
                value = payload.get(key)
                if isinstance(value, list):
                    items = value
                    break
        else:
            items = []

        routes: list[RouteSummary] = []
        for item in items:
            if not isinstance(item, dict):
                continue

            route_id = item.get("courseId") or item.get("routeId") or item.get("id")
            if route_id is None:
                continue
            route_name = (
                item.get("courseName") or item.get("name") or f"garmin-route-{route_id}"
            )
            routes.append(RouteSummary(route_id=str(route_id), name=str(route_name), raw=item))
        return routes

    @staticmethod
    def _infer_extension(content: bytes, source: str) -> str:
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

    def _get_course_detail(self, route_id: str) -> dict[str, Any]:
        payload = self._garmin.connectapi(f"/course-service/course/{route_id}")
        if not isinstance(payload, dict):
            raise RuntimeError(
                f"Unexpected Garmin course detail payload type: {type(payload).__name__}"
            )
        return payload

    @staticmethod
    def _build_gpx_from_course_detail(
        course_detail: dict[str, Any], fallback_name: str
    ) -> bytes:
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
            +
            f"  <trk><name>{escape(name)}</name><trkseg>\n"
            + "\n".join(f"    {trackpoint}" for trackpoint in trkpts)
            + "\n  </trkseg></trk>\n"
            +
            "</gpx>\n"
        )
        return gpx.encode("utf-8")


class IGPSportClient:
    def __init__(
        self,
        username: str,
        password: str,
        domain: str,
        referer: str,
        upload_endpoints: list[str] | None = None,
        web_cookie_file: str = DEFAULT_IGPSPORT_WEB_COOKIE_FILE,
    ) -> None:
        self._username = username
        self._password = password
        self._domain = domain
        self._upload_endpoints = upload_endpoints or DEFAULT_IGPSPORT_UPLOAD_ENDPOINTS
        self._web_cookie_file = Path(web_cookie_file)
        self._session = requests.Session()
        self._session.headers.update(
            {
                "user-agent": (
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/136.0.0.0 Safari/537.36"
                ),
                "accept": "application/json, text/plain, */*",
                "origin": referer,
                "referer": referer,
            }
        )
        self._web_session = requests.Session()
        self._web_session.headers.update(
            {
                "user-agent": (
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/136.0.0.0 Safari/537.36"
                ),
                "accept": "*/*",
                "x-requested-with": "XMLHttpRequest",
                "origin": DEFAULT_IGPSPORT_WEB_BASE_URL,
                "referer": DEFAULT_IGPSPORT_WEB_REFERER,
            }
        )

    @property
    def _base_url(self) -> str:
        return f"https://{self._domain}/service"

    def login(self) -> None:
        url = f"{self._base_url}/auth/account/login"
        payload = {
            "username": self._username,
            "password": self._password,
            "appId": "igpsport-web",
        }

        response = self._session.post(url, json=payload, timeout=30)
        response.raise_for_status()
        data = response.json()
        if data.get("code") != 0:
            raise RuntimeError(f"iGPSPORT login failed: {data}")

        token = (
            (data.get("data") or {}).get("access_token")
            or (data.get("data") or {}).get("accessToken")
        )
        if not token:
            raise RuntimeError("iGPSPORT login succeeded but no access token was found")

        self._session.headers.update({"authorization": f"Bearer {token}"})
        LOGGER.info("Authenticated to iGPSPORT")

    def upload_route(self, route_name: str, filename: str, content: bytes) -> None:
        self._upload_route_via_web(route_name, filename, content)
        return

    def get_my_roadbooks(self) -> list[RoadBookSummary]:
        """Return existing roadbooks from iGPSPORT web RoadList API."""
        self._restore_web_cookies_from_disk()
        response = self._web_session.get(
            "https://i.igpsport.com/Routes/RoadList",
            params={"type": "mine"},
            timeout=30,
        )

        if self._looks_like_login_required(response):
            self._web_login_and_persist()
            response = self._web_session.get(
                "https://i.igpsport.com/Routes/RoadList",
                params={"type": "mine"},
                timeout=30,
            )

        response.raise_for_status()
        payload = response.json()
        if not isinstance(payload, dict):
            raise RuntimeError("Unexpected RoadList response type")
        if payload.get("Code") not in (0, "0"):
            raise RuntimeError(f"RoadList API failed: {payload}")

        data = payload.get("Data")
        if not isinstance(data, dict):
            return []
        items = data.get("Items")
        if not isinstance(items, list):
            return []

        roadbooks: list[RoadBookSummary] = []
        for item in items:
            if not isinstance(item, dict):
                continue
            roadbook_id = item.get("RoadBookId")
            title = item.get("Title")
            if roadbook_id is None or not isinstance(title, str) or not title.strip():
                continue
            roadbooks.append(RoadBookSummary(roadbook_id=int(roadbook_id), title=title.strip()))

        return roadbooks

    def set_auxiliary_points(self, roadbook_id: int, points: list[POICandidate]) -> None:
        if not points:
            return

        payload = {
            "roadBookId": roadbook_id,
            "editRoutesAuxiliaryPointRequestDtos": [
                {
                    "auxiliaryPointType": point.poi_type.value,
                    "auxiliaryPointName": point.name,
                    "latitude": point.latitude,
                    "selected": False,
                    "longitude": point.longitude,
                    "auxiliaryPointNameOrigin": point.name_origin,
                }
                for point in points
            ],
        }

        headers = {
            "content-type": "application/json; charset=utf-8",
            "accept": "*/*",
            "qiwu-phone": "iPhone_iPad Pro (12.9-inch) (3rd generation)",
            "qiwu-app-version": "8.06.35",
            "priority": "u=3, i",
            "accept-language": "en",
            "accept-encoding": "br",
            "user-agent": "iPadOS/26.4",
            "timezone": "Asia/Tokyo",
        }

        response = self._session.put(
            f"{self._base_url}/sportg/roadbook4j/road-book/editRoutesAuxiliaryPoint",
            json=payload,
            headers=headers,
            timeout=30,
        )
        response.raise_for_status()
        result = response.json()
        if not isinstance(result, dict) or result.get("code") != 0:
            raise RuntimeError(f"Failed to set POI on iGPSPORT roadbook: {result}")

    def set_route_private(self, roadbook_id: int, title: str) -> None:
        payload = {
            "title": title,
            "status": 0,
            "id": roadbook_id,
        }

        headers = {
            "content-type": "application/json",
            "accept": "application/json, text/plain, */*",
            "accept-language": "ja",
            "qiwu-app-version": "8.07.06",
            "timezone": "Asia/Tokyo",
        }

        response = self._session.put(
            f"{self._base_url}/web/api/Routes/EditRoutesSummary",
            json=payload,
            headers=headers,
            timeout=30,
        )
        response.raise_for_status()
        result = response.json()
        if not isinstance(result, dict) or result.get("code") not in (0, "0"):
            raise RuntimeError(f"Failed to set iGPSPORT route private: {result}")

    def _upload_route_via_web(self, route_name: str, filename: str, content: bytes) -> None:
        self._restore_web_cookies_from_disk()
        content_type = mimetypes.guess_type(filename)[0] or "application/octet-stream"
        files = {"file": (filename, content, content_type)}
        data = {
            "title": route_name,
            "descr": "",
        }

        first = self._web_session.post(
            DEFAULT_IGPSPORT_WEB_UPLOAD_URL,
            data=data,
            files=files,
            timeout=60,
        )

        success, reason = self._is_web_upload_success(first)
        if success:
            self._persist_web_cookies_to_disk()
            return

        # If cookies are stale or server returns an opaque failure code, re-login once and retry.
        if self._looks_like_login_required(first) or reason:
            self._web_login_and_persist()
            second = self._web_session.post(
                DEFAULT_IGPSPORT_WEB_UPLOAD_URL,
                data=data,
                files=files,
                timeout=60,
            )
            success2, reason2 = self._is_web_upload_success(second)
            if success2:
                self._persist_web_cookies_to_disk()
                return
            raise RuntimeError(f"Web upload failed after re-login: {reason2}")

        raise RuntimeError(f"Web upload failed: {reason}")

    def _is_web_upload_success(self, response: requests.Response) -> tuple[bool, str]:
        body_text = response.text[:500]
        try:
            response.raise_for_status()
        except Exception as exc:  # noqa: BLE001
            return False, f"http_error={exc} body={body_text}"

        try:
            payload = response.json()
        except Exception:  # noqa: BLE001
            payload = None

        if isinstance(payload, dict):
            code = payload.get("code")
            if code is None:
                code = payload.get("Code")
            data = payload.get("data")
            if data is None and "Data" in payload:
                data = payload.get("Data")

            if code in (0, "0"):
                if isinstance(data, str) and "not_found" in data.lower():
                    return False, f"json_failure={payload}"
                if data in (True, None, "", 1, "1"):
                    return True, ""
                if isinstance(data, str) and data.strip().lower() in {
                    "true",
                    "ok",
                    "success",
                }:
                    return True, ""

            if str(payload.get("status")) in {"1", "200", "0"}:
                return True, ""
            if str(payload.get("success", "")).lower() in {"true", "1"}:
                return True, ""

            return False, f"json_failure={payload}"

        text = body_text.strip()
        lower_text = text.lower()
        if lower_text in {"ok", "success", "true", "1"}:
            return True, ""
        if text.isdigit() and int(text) >= 0:
            return True, ""
        return False, f"plain_failure={body_text}"

    def _looks_like_login_required(self, response: requests.Response) -> bool:
        if response.status_code in {401, 403}:
            return True
        lower_body = response.text.lower()
        return "auth/login" in lower_body or "please login" in lower_body

    def _web_login_and_persist(self) -> None:
        login_response = self._web_session.post(
            f"{DEFAULT_IGPSPORT_WEB_BASE_URL}{DEFAULT_IGPSPORT_WEB_LOGIN_PATH}",
            json={"username": self._username, "password": self._password},
            timeout=30,
        )
        login_response.raise_for_status()

        payload = login_response.json()
        code = payload.get("Code")
        if code not in (0, "0"):
            raise RuntimeError(f"iGPSPORT web login failed: {payload}")

        self._persist_web_cookies_to_disk()

    def _persist_web_cookies_to_disk(self) -> None:
        cookie_map = requests.utils.dict_from_cookiejar(self._web_session.cookies)
        if not cookie_map:
            return
        self._web_cookie_file.parent.mkdir(parents=True, exist_ok=True)
        self._web_cookie_file.write_text(
            json.dumps(cookie_map, ensure_ascii=False, indent=2), encoding="utf-8"
        )

    def _restore_web_cookies_from_disk(self) -> None:
        if not self._web_cookie_file.exists():
            return
        try:
            cookie_map = json.loads(self._web_cookie_file.read_text(encoding="utf-8"))
        except Exception:  # noqa: BLE001
            return
        if not isinstance(cookie_map, dict):
            return
        normalized = {str(key): str(value) for key, value in cookie_map.items()}
        self._web_session.cookies = requests.utils.cookiejar_from_dict(normalized)


def parse_csv_env(name: str) -> list[str] | None:
    raw = os.getenv(name)
    if not raw:
        return None
    values = [item.strip() for item in raw.split(",")]
    return [value for value in values if value]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Download Garmin Connect routes and upload to iGPSPORT"
    )
    parser.add_argument("--limit", type=int, default=50, help="Max routes to fetch")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be uploaded without calling iGPSPORT upload API",
    )
    parser.add_argument(
        "--state-file",
        default="sync_state.json",
        help="Deprecated and ignored (state-file based dedupe is disabled)",
    )
    parser.add_argument(
        "--garmin-session-dir",
        default="garmin_session",
        help="Directory used by garminconnect to store authentication session",
    )
    parser.add_argument(
        "--log-level",
        default=os.getenv("LOG_LEVEL", "INFO"),
        help="Logging level (DEBUG/INFO/WARNING/ERROR)",
    )
    return parser.parse_args()


def require_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def map_igpsport_poi_type(
    *,
    name: str | None,
    gpx_type: str | None,
    symbol: str | None,
    comment: str | None,
) -> IGPSPORTPOIType:
    """Map GPX POI metadata to iGPSPORT POI type enum."""

    gpx_type_norm = " ".join((gpx_type or "").strip().upper().split())

    def normalize_key(value: str) -> str:
        return "".join(ch for ch in value.upper() if ch.isalnum())

    gpx_type_key = normalize_key(gpx_type_norm)
    gpx_type_map: dict[str, IGPSPORTPOIType] = {
        # Garmin waypoint types (verified from full-type GPX sample).
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
    normalized_type_map = {normalize_key(key): value for key, value in gpx_type_map.items()}
    if gpx_type_key in normalized_type_map:
        return normalized_type_map[gpx_type_key]

    # Additional aliases from Garmin coursePointType style names.
    if gpx_type_key in {
        "FIRSTCATEGORY",
        "FIRSTCATEGORYCLIMB",
        "ONELEVELCLIMBING",
        "LEVEL1",
        "1級",
        "１級",
        "1級山岳",
        "１級山岳",
    }:
        return IGPSPORTPOIType.ONE_LEVEL_CLIMBING
    if gpx_type_key in {
        "SECONDCATEGORY",
        "SECONDCATEGORYCLIMB",
        "TWOLEVELCLIMBING",
        "LEVEL2",
        "2級",
        "２級",
        "2級山岳",
        "２級山岳",
    }:
        return IGPSPORTPOIType.TWO_LEVEL_CLIMBING
    if gpx_type_key in {
        "THIRDCATEGORY",
        "THIRDCATEGORYCLIMB",
        "THREELEVELCLIMBING",
        "LEVEL3",
        "3級",
        "３級",
        "3級山岳",
        "３級山岳",
    }:
        return IGPSPORTPOIType.THREE_LEVEL_CLIMBING
    if gpx_type_key in {
        "FOURTHCATEGORY",
        "FOURTHCATEGORYCLIMB",
        "FOURLEVELCLIMBING",
        "LEVEL4",
        "4級",
        "４級",
        "4級山岳",
        "４級山岳",
    }:
        return IGPSPORTPOIType.FOUR_LEVEL_CLIMBING
    if gpx_type_key in {"DANGER", "DANGEROUSAREA", "ALERT", "OBSTACLE"}:
        return IGPSPORTPOIType.DANGEROUS_AREA
    if gpx_type_key in {"SHARPCURVE", "SHARPBEND", "SHARPTURN"}:
        return IGPSPORTPOIType.SHARP_BEND

    haystack = " ".join(
        (name or "", gpx_type or "", symbol or "", comment or "")
    ).lower()

    if any(token in haystack for token in ["intersection", "cross", "交差点"]):
        return IGPSPORTPOIType.INTERSECTION
    if any(token in haystack for token in ["steep", "descent", "急勾配", "急坂", "下り"]):
        return IGPSPORTPOIType.STEEP_DESCENT_AHEAD
    if any(token in haystack for token in ["sharp", "bend", "turn", "急カーブ", "急旋回"]):
        return IGPSPORTPOIType.SHARP_BEND
    if any(token in haystack for token in ["danger", "hazard", "dangerous", "危険", "注意"]):
        return IGPSPORTPOIType.DANGEROUS_AREA
    if any(token in haystack for token in ["valley", "谷"]):
        return IGPSPORTPOIType.VALLEY
    if any(token in haystack for token in ["tunnel", "トンネル"]):
        return IGPSPORTPOIType.TUNNEL
    if any(token in haystack for token in ["photo", "instagram", "映え", "フォトスポット"]):
        return IGPSPORTPOIType.INTERNET_CELEBRITY_CLOCK_IN_POINT
    if any(token in haystack for token in ["observation", "view", "展望台", "見晴らし"]):
        return IGPSPORTPOIType.OBSERVATION_DECK
    if any(token in haystack for token in ["meeting", "rally", "集合"]):
        return IGPSPORTPOIType.RALLY_POINT
    if any(token in haystack for token in ["shop", "store", "店舗", "売店"]):
        return IGPSPORTPOIType.SHOP
    if any(token in haystack for token in ["equipment", "device", "駐輪場", "機材"]):
        return IGPSPORTPOIType.EQUIPMENT
    if any(token in haystack for token in ["medical", "aid", "救護"]):
        return IGPSPORTPOIType.MEDICAL_AID_STATION
    if any(token in haystack for token in ["service", "サービスポイント", "サービス"]):
        return IGPSPORTPOIType.SERVICE_POINT
    if any(token in haystack for token in ["toilet", "restroom", "wc", "トイレ"]):
        return IGPSPORTPOIType.WATER_CLOSET
    if any(token in haystack for token in ["garbage", "refuse", "trash", "ゴミ", "ごみ"]):
        return IGPSPORTPOIType.REFUSE_COLLECTION_AREA
    if any(token in haystack for token in ["supply", "feed", "補給"]):
        return IGPSPORTPOIType.SUPPLY_POINT
    if any(token in haystack for token in ["level 4", "cat 4", "4級", "レベル4"]):
        return IGPSPORTPOIType.FOUR_LEVEL_CLIMBING
    if any(token in haystack for token in ["level 3", "cat 3", "3級", "レベル3"]):
        return IGPSPORTPOIType.THREE_LEVEL_CLIMBING
    if any(token in haystack for token in ["level 2", "cat 2", "2級", "レベル2"]):
        return IGPSPORTPOIType.TWO_LEVEL_CLIMBING
    if any(token in haystack for token in ["level 1", "cat 1", "1級", "レベル1"]):
        return IGPSPORTPOIType.ONE_LEVEL_CLIMBING
    if any(token in haystack for token in ["sprint", "スプリント"]):
        return IGPSPORTPOIType.SPRINT_POINT
    if any(token in haystack for token in ["waypoint", "via", "経由", "星マーク"]):
        return IGPSPORTPOIType.VIA_POINT
    if any(token in haystack for token in ["hc", "hors categorie", "hc climb", "峠", "登り"]):
        return IGPSPORTPOIType.HC_LEVEL_CLIMBING

    # GPX type fallback.
    if gpx_type_norm in {"GENERIC", "WAYPOINT"}:
        return IGPSPORTPOIType.VIA_POINT
    if gpx_type_norm in {"SUMMIT"}:
        return IGPSPORTPOIType.HC_LEVEL_CLIMBING

    return IGPSPORTPOIType.VIA_POINT


def extract_pois_from_gpx_bytes(gpx_bytes: bytes, max_points: int = 30) -> list[POICandidate]:
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
        symbol: str | None = None,
        comment: str | None = None,
    ) -> None:
        if latitude is None or longitude is None:
            return
        poi_name = (name or "POI").strip() or "POI"
        key = (round(latitude * 1_000_000), round(longitude * 1_000_000), poi_name)
        if key in seen:
            return
        seen.add(key)
        poi_type = map_igpsport_poi_type(
            name=name,
            gpx_type=gpx_type,
            symbol=symbol,
            comment=comment,
        )
        pois.append(
            POICandidate(
                name=poi_name[:64],
                latitude=float(latitude),
                longitude=float(longitude),
                poi_type=poi_type,
                name_origin=poi_name[:64],
            )
        )

    for wpt in gpx.waypoints:
        add_candidate(
            wpt.name,
            wpt.latitude,
            wpt.longitude,
            getattr(wpt, "type", None),
            getattr(wpt, "symbol", None),
            getattr(wpt, "comment", None),
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

    return pois[:max_points]


def main() -> int:
    load_dotenv()
    args = parse_args()

    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    garmin_email = require_env("GARMIN_EMAIL")
    garmin_password = require_env("GARMIN_PASSWORD")
    garmin_cn = os.getenv("GARMIN_CN", "False").lower() == "true"

    igpsport_username = require_env("IGPSPORT_USERNAME")
    igpsport_password = require_env("IGPSPORT_PASSWORD")
    igpsport_domain = os.getenv("IGPSPORT_DOMAIN", DEFAULT_IGPSPORT_DOMAIN)
    igpsport_referer = os.getenv("IGPSPORT_REFERER", DEFAULT_IGPSPORT_REFERER)

    route_list_endpoints = parse_csv_env("GARMIN_ROUTE_LIST_ENDPOINTS")
    route_download_endpoints = parse_csv_env("GARMIN_ROUTE_DOWNLOAD_ENDPOINTS")
    upload_endpoints = parse_csv_env("IGPSPORT_ROUTE_UPLOAD_ENDPOINTS")
    web_cookie_file = os.getenv("IGPSPORT_WEB_COOKIE_FILE", DEFAULT_IGPSPORT_WEB_COOKIE_FILE)

    garmin = GarminRouteClient(
        email=garmin_email,
        password=garmin_password,
        is_cn=garmin_cn,
        session_dir=Path(args.garmin_session_dir),
        list_endpoints=route_list_endpoints,
        download_endpoints=route_download_endpoints,
    )
    igpsport = IGPSportClient(
        username=igpsport_username,
        password=igpsport_password,
        domain=igpsport_domain,
        referer=igpsport_referer,
        upload_endpoints=upload_endpoints,
        web_cookie_file=web_cookie_file,
    )

    garmin.login()
    routes = garmin.list_routes(limit=args.limit)
    if not routes:
        LOGGER.info("No Garmin routes found")
        return 0

    # State-file based dedupe is disabled. We always evaluate all Garmin routes
    # against current iGPSPORT titles so deleted routes can be re-uploaded.
    pending_routes = routes
    LOGGER.info("Routes to evaluate: %d", len(pending_routes))

    if not args.dry_run:
        igpsport.login()
        roadbooks = igpsport.get_my_roadbooks()
        title_to_roadbook_id = {rb.title: rb.roadbook_id for rb in roadbooks}

        LOGGER.info(
            "Loaded iGPSPORT roadbooks: %d",
            len(roadbooks),
        )
    else:
        title_to_roadbook_id: dict[str, int] = {}

    synced = 0
    failed = 0
    skipped = 0
    for route in pending_routes:
        LOGGER.info("Processing route id=%s name=%s", route.route_id, route.name)
        try:
            normalized_title = route.name.strip()
            route_bytes, extension = garmin.download_route(route)
            filename = f"{route.route_id}{extension}"
            uploaded_now = False

            poi_candidates = extract_pois_from_gpx_bytes(route_bytes)
            if poi_candidates:
                LOGGER.info(
                    "Extracted POI candidates from GPX: route_id=%s count=%d",
                    route.route_id,
                    len(poi_candidates),
                )

            if args.dry_run:
                LOGGER.info(
                    "dry-run: skip upload route id=%s file=%s size=%d",
                    route.route_id,
                    filename,
                    len(route_bytes),
                )
                skipped += 1
                continue

            target_roadbook_id = title_to_roadbook_id.get(normalized_title)

            if target_roadbook_id is not None:
                LOGGER.info(
                    "Skip upload (already exists on iGPSPORT by title): route_id=%s title=%s roadbook_id=%s",
                    route.route_id,
                    route.name,
                    target_roadbook_id,
                )
                skipped += 1
            else:
                igpsport.upload_route(route.name, filename, route_bytes)
                refreshed_roadbooks = igpsport.get_my_roadbooks()
                title_to_roadbook_id = {
                    rb.title: rb.roadbook_id for rb in refreshed_roadbooks
                }
                target_roadbook_id = title_to_roadbook_id.get(normalized_title)
                if target_roadbook_id is None:
                    raise RuntimeError(
                        "Route uploaded but could not resolve iGPSPORT roadbook ID by title"
                    )
                uploaded_now = True
                synced += 1
                LOGGER.info(
                    "Synced route id=%s -> roadbook_id=%s",
                    route.route_id,
                    target_roadbook_id,
                )

            if uploaded_now and target_roadbook_id is not None:
                igpsport.set_route_private(target_roadbook_id, normalized_title)
                LOGGER.info(
                    "Set iGPSPORT route private: roadbook_id=%s",
                    target_roadbook_id,
                )

            if target_roadbook_id is not None and poi_candidates:
                igpsport.set_auxiliary_points(target_roadbook_id, poi_candidates)
                LOGGER.info(
                    "Applied POI to iGPSPORT route: roadbook_id=%s count=%d",
                    target_roadbook_id,
                    len(poi_candidates),
                )

        except Exception as exc:  # noqa: BLE001
            LOGGER.error("Failed route id=%s error=%s", route.route_id, exc)
            failed += 1

    LOGGER.info("Sync done. uploaded=%d skipped=%d failed=%d", synced, skipped, failed)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

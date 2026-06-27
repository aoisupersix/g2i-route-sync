"""Garmin Connect route listing and download client."""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Any

from garminconnect import Garmin

from .config import (
    DEFAULT_GARMIN_ROUTE_DOWNLOAD_ENDPOINT,
    DEFAULT_GARMIN_ROUTE_LIST_ENDPOINT,
)
from .gpx import build_gpx_from_course_detail, infer_extension
from .jsonutil import json_get_ci
from .models import RouteSummary

LOGGER = logging.getLogger("g2i-route-sync")


class GarminRouteClient:
    def __init__(
        self,
        email: str,
        password: str,
        is_cn: bool,
        session_dir: Path,
        list_endpoint: str | None = None,
        download_endpoint: str | None = None,
    ) -> None:
        self._garmin = Garmin(email=email, password=password, is_cn=is_cn)
        self._session_dir = session_dir
        self._list_endpoint = list_endpoint or DEFAULT_GARMIN_ROUTE_LIST_ENDPOINT
        self._download_endpoint = (
            download_endpoint or DEFAULT_GARMIN_ROUTE_DOWNLOAD_ENDPOINT
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

        for params in params_candidates:
            try:
                payload = self._garmin.connectapi(self._list_endpoint, params=params)
                routes = self._extract_route_list(payload)
                if routes:
                    LOGGER.info(
                        "Found %d routes from Garmin endpoint=%s",
                        len(routes),
                        self._list_endpoint,
                    )
                    return routes[:limit]
            # Broad on purpose: the param shape that works varies by account, so
            # any failure here just means "try the next candidate".
            except Exception as exc:  # noqa: BLE001
                last_error = exc
                LOGGER.debug(
                    "Garmin route list call failed endpoint=%s params=%s err=%s",
                    self._list_endpoint,
                    params,
                    exc,
                )

        if last_error:
            raise RuntimeError(
                "Failed to fetch Garmin routes from configured endpoint"
            ) from last_error

        raise RuntimeError("No Garmin routes found")

    def download_route(self, route: RouteSummary) -> tuple[bytes, str]:
        direct_url = json_get_ci(route.raw, "downloadUrl")
        if isinstance(direct_url, str) and direct_url:
            try:
                content = self._garmin.download(direct_url)
                return content, infer_extension(content, direct_url)
            # Broad on purpose: any download failure (404, auth, network) should
            # fall through to the next download strategy rather than abort.
            except Exception as exc:  # noqa: BLE001
                LOGGER.debug(
                    "Direct Garmin route download failed route_id=%s url=%s err=%s",
                    route.route_id,
                    direct_url,
                    exc,
                )

        last_error: Exception | None = None
        endpoint = self._download_endpoint.format(route_id=route.route_id)
        try:
            content = self._garmin.download(endpoint)
            return content, infer_extension(content, endpoint)
        # Broad on purpose: fall back to building GPX from the course detail.
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
        gpx_bytes = build_gpx_from_course_detail(course_detail, route.name)
        return gpx_bytes, ".gpx"

    @staticmethod
    def _extract_route_list(payload: Any) -> list[RouteSummary]:
        if isinstance(payload, list):
            items = payload
        elif isinstance(payload, dict):
            value = json_get_ci(payload, "courseItems")
            items = value if isinstance(value, list) else []
        else:
            items = []

        routes: list[RouteSummary] = []
        for item in items:
            if not isinstance(item, dict):
                continue

            route_id = json_get_ci(item, "courseId")
            if route_id is None:
                continue
            route_name = json_get_ci(item, "courseName") or f"garmin-route-{route_id}"
            routes.append(
                RouteSummary(route_id=str(route_id), name=str(route_name), raw=item)
            )
        return routes

    def _get_course_detail(self, route_id: str) -> dict[str, Any]:
        payload = self._garmin.connectapi(f"/course-service/course/{route_id}")
        if not isinstance(payload, dict):
            raise RuntimeError(
                f"Unexpected Garmin course detail payload type: {type(payload).__name__}"
            )
        return payload

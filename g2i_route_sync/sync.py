"""Route ordering helpers and the Garmin -> iGPSPORT sync orchestration."""

from __future__ import annotations

import datetime as dt
import logging
from pathlib import Path
from typing import Any

from .config import AppConfig
from .garmin import GarminRouteClient
from .igpsport import IGPSportClient
from .jsonutil import json_get_ci
from .models import RouteSummary
from .poi import extract_pois_from_gpx_bytes

LOGGER = logging.getLogger("g2i-route-sync")


def _normalize_to_unix_seconds(value: Any) -> float | None:
    if isinstance(value, bool) or value is None:
        return None

    if isinstance(value, (int, float)):
        numeric = float(value)
        if numeric <= 0:
            return None
        if numeric > 1_000_000_000_000:
            return numeric / 1000.0
        return numeric

    if isinstance(value, str):
        text = value.strip()
        if not text:
            return None

        if text.isdigit():
            return _normalize_to_unix_seconds(float(text))

        normalized = text.replace("Z", "+00:00")
        try:
            dt_value = dt.datetime.fromisoformat(normalized)
        except ValueError:
            return None

        if dt_value.tzinfo is None:
            dt_value = dt_value.replace(tzinfo=dt.timezone.utc)
        return dt_value.timestamp()

    return None


def _parse_route_created_timestamp(route: RouteSummary) -> float | None:
    value = json_get_ci(route.raw, "createTime")
    return _normalize_to_unix_seconds(value)


def sort_routes_oldest_first(routes: list[RouteSummary]) -> list[RouteSummary]:
    indexed = list(enumerate(routes))

    def sort_key(item: tuple[int, RouteSummary]) -> tuple[int, float, int]:
        index, route = item
        created_ts = _parse_route_created_timestamp(route)
        if created_ts is None:
            return (1, float("inf"), index)
        return (0, created_ts, index)

    ordered = sorted(indexed, key=sort_key)
    return [route for _, route in ordered]


def run_sync(config: AppConfig, *, limit: int, dry_run: bool, session_dir: str) -> int:
    garmin = GarminRouteClient(
        email=config.garmin_email,
        password=config.garmin_password,
        is_cn=config.garmin_cn,
        session_dir=Path(session_dir),
        list_endpoint=config.route_list_endpoint,
        download_endpoint=config.route_download_endpoint,
    )
    igpsport = IGPSportClient(
        username=config.igpsport_username,
        password=config.igpsport_password,
        domain=config.igpsport_domain,
        referer=config.igpsport_referer,
        web_cookie_file=config.web_cookie_file,
        roadlist_page_size=config.roadlist_page_size,
    )

    garmin.login()
    routes = garmin.list_routes(limit=limit)
    if not routes:
        LOGGER.info("No Garmin routes found")
        return 0

    # State-file based dedupe is disabled. We always evaluate all Garmin routes
    # against current iGPSPORT titles so deleted routes can be re-uploaded.
    pending_routes = sort_routes_oldest_first(routes)
    LOGGER.info("Routes to evaluate: %d", len(pending_routes))

    title_to_roadbook_id: dict[str, int] = {}
    if not dry_run:
        igpsport.login()
        roadbooks = igpsport.get_my_roadbooks()
        title_to_roadbook_id = {rb.title: rb.roadbook_id for rb in roadbooks}
        LOGGER.info("Loaded iGPSPORT roadbooks: %d", len(roadbooks))

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

            if dry_run:
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
                    "Skip upload (already exists on iGPSPORT by title): "
                    "route_id=%s title=%s roadbook_id=%s",
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

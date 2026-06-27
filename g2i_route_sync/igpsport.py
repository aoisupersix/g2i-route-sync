"""iGPSPORT route upload and roadbook client."""

from __future__ import annotations

import json
import logging
import mimetypes
from pathlib import Path
from typing import Any

import requests

from .config import (
    BROWSER_USER_AGENT,
    DEFAULT_IGPSPORT_ROADLIST_PAGE_SIZE,
    DEFAULT_IGPSPORT_WEB_BASE_URL,
    DEFAULT_IGPSPORT_WEB_COOKIE_FILE,
    DEFAULT_IGPSPORT_WEB_LOGIN_PATH,
    DEFAULT_IGPSPORT_WEB_REFERER,
    DEFAULT_IGPSPORT_WEB_ROADLIST_REFERER,
    DEFAULT_IGPSPORT_WEB_ROADLIST_URL,
    DEFAULT_IGPSPORT_WEB_UPLOAD_URL,
)
from .jsonutil import json_get_ci, normalize_key
from .models import RoadBookSummary
from .poi import POICandidate

LOGGER = logging.getLogger("g2i-route-sync")

_ROADLIST_HEADERS = {
    "accept": "*/*",
    "accept-language": "ja,en-US;q=0.9,en;q=0.8",
    "x-requested-with": "XMLHttpRequest",
    "referer": DEFAULT_IGPSPORT_WEB_ROADLIST_REFERER,
    "sec-fetch-dest": "empty",
    "sec-fetch-mode": "cors",
    "sec-fetch-site": "same-origin",
}


class IGPSportClient:
    def __init__(
        self,
        username: str,
        password: str,
        domain: str,
        referer: str,
        web_cookie_file: str = DEFAULT_IGPSPORT_WEB_COOKIE_FILE,
        roadlist_page_size: int = DEFAULT_IGPSPORT_ROADLIST_PAGE_SIZE,
    ) -> None:
        self._username = username
        self._password = password
        self._domain = domain
        self._web_cookie_file = Path(web_cookie_file)
        self._roadlist_page_size = max(1, int(roadlist_page_size))
        self._session = requests.Session()
        self._session.headers.update(
            {
                "user-agent": BROWSER_USER_AGENT,
                "accept": "application/json, text/plain, */*",
                "origin": referer,
                "referer": referer,
            }
        )
        self._web_session = requests.Session()
        self._web_session.headers.update(
            {
                "user-agent": BROWSER_USER_AGENT,
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
        if json_get_ci(data, "code") != 0:
            raise RuntimeError(f"iGPSPORT login failed: {data}")

        token_data = json_get_ci(data, "data")
        token = json_get_ci(token_data, "accessToken")
        if not token:
            raise RuntimeError("iGPSPORT login succeeded but no access token was found")

        self._session.headers.update({"authorization": f"Bearer {token}"})
        LOGGER.info("Authenticated to iGPSPORT")

    def upload_route(self, route_name: str, filename: str, content: bytes) -> None:
        self._upload_route_via_web(route_name, filename, content)

    def _fetch_roadlist_page(self, page_index: int) -> requests.Response:
        return self._web_session.get(
            DEFAULT_IGPSPORT_WEB_ROADLIST_URL,
            params={
                "type": "mine",
                "pageSize": self._roadlist_page_size,
                "pageIndex": page_index,
            },
            headers=_ROADLIST_HEADERS,
            timeout=30,
        )

    def get_my_roadbooks(self) -> list[RoadBookSummary]:
        """Return existing roadbooks from iGPSPORT web RoadList API."""
        self._restore_web_cookies_from_disk()
        page_size = self._roadlist_page_size
        page_index = 1
        all_items: list[Any] = []

        while True:
            response = self._fetch_roadlist_page(page_index)

            if self._looks_like_login_required(response):
                self._web_login_and_persist()
                response = self._fetch_roadlist_page(page_index)

            try:
                response.raise_for_status()
                payload = response.json()
                items = self._extract_roadlist_items(payload)
                total = self._extract_roadlist_total(payload)
            except Exception as exc:  # noqa: BLE001
                debug = self._format_response_debug(response)
                LOGGER.error("Failed to load RoadList: %s", debug)
                raise RuntimeError(f"Failed to load RoadList: {debug}") from exc

            all_items.extend(items)

            # If total is unknown, stop when page is not full.
            if total is None:
                if len(items) < page_size:
                    break
                page_index += 1
                continue

            if len(all_items) >= total:
                break

            if not items:
                break

            page_index += 1

        roadbooks: list[RoadBookSummary] = []
        for item in all_items:
            if not isinstance(item, dict):
                continue
            roadbook_id = json_get_ci(item, "roadbookid")
            title = json_get_ci(item, "title")
            if roadbook_id is None or not isinstance(title, str) or not title.strip():
                continue
            try:
                normalized_id = int(roadbook_id)
            except (TypeError, ValueError):
                continue
            roadbooks.append(
                RoadBookSummary(roadbook_id=normalized_id, title=title.strip())
            )

        return roadbooks

    def _format_response_debug(self, response: requests.Response) -> str:
        content_type = response.headers.get("content-type", "")
        body = response.text.strip().replace("\n", " ")
        if len(body) > 600:
            body = f"{body[:600]}..."
        return (
            f"url={response.url!r} status={response.status_code} "
            f"content_type={content_type!r} body={body!r}"
        )

    def _extract_roadlist_items(self, payload: Any) -> list[Any]:
        if isinstance(payload, str):
            try:
                payload = json.loads(payload)
            except Exception as exc:  # noqa: BLE001
                raise RuntimeError("RoadList payload is not valid JSON string") from exc

        if isinstance(payload, list):
            return payload
        if not isinstance(payload, dict):
            raise RuntimeError(
                f"Unexpected RoadList payload type: {type(payload).__name__}"
            )

        code = json_get_ci(payload, "code")
        if code not in (None, 0, "0"):
            raise RuntimeError(f"RoadList API failed: {payload}")

        containers: list[Any] = [payload]
        data = json_get_ci(payload, "data")
        if data is not None:
            containers.append(data)

        # Empty/null data is a valid "no roadbooks" state.
        if data in (None, {}):
            return []
        if not isinstance(data, (dict, list)):
            raise RuntimeError(f"Unexpected RoadList Data type: {type(data).__name__}")

        for container in containers:
            if isinstance(container, list):
                return container
            if not isinstance(container, dict):
                continue
            if not any(
                isinstance(current_key, str) and normalize_key(current_key) == "items"
                for current_key in container.keys()
            ):
                continue
            value = json_get_ci(container, "items")
            if value is None:
                return []
            if isinstance(value, list):
                return value
            raise RuntimeError(
                f"Unexpected RoadList 'items' type: {type(value).__name__}"
            )

        # If the API reports zero total but omits list fields, treat as empty list.
        payload_total = self._extract_total_value(payload)
        if payload_total == 0:
            return []
        data_total = self._extract_total_value(data)
        if data_total == 0:
            return []

        if payload == {} and code in (None, 0, "0"):
            return []

        raise RuntimeError("Unexpected RoadList response format")

    def _extract_roadlist_total(self, payload: Any) -> int | None:
        if isinstance(payload, str):
            try:
                payload = json.loads(payload)
            except Exception:  # noqa: BLE001
                return None

        if not isinstance(payload, dict):
            return None

        data = json_get_ci(payload, "data")

        payload_total = self._extract_total_value(payload)
        if payload_total is not None:
            return payload_total

        data_total = self._extract_total_value(data)
        if data_total is not None:
            return data_total

        return None

    @staticmethod
    def _extract_total_value(container: Any) -> int | None:
        if not isinstance(container, dict):
            return None
        raw_total = json_get_ci(container, "total")
        if raw_total is None:
            return None
        try:
            return int(raw_total)
        except (TypeError, ValueError):
            return None

    def set_auxiliary_points(
        self, roadbook_id: int, points: list[POICandidate]
    ) -> None:
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
        if not isinstance(result, dict) or json_get_ci(result, "code") != 0:
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
        if not isinstance(result, dict) or json_get_ci(result, "code") not in (0, "0"):
            raise RuntimeError(f"Failed to set iGPSPORT route private: {result}")

    def _upload_route_via_web(
        self, route_name: str, filename: str, content: bytes
    ) -> None:
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
            code = json_get_ci(payload, "code")
            data = json_get_ci(payload, "data")

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

            if str(json_get_ci(payload, "status")) in {"1", "200", "0"}:
                return True, ""
            if str(json_get_ci(payload, "success", "")).lower() in {"true", "1"}:
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
        code = json_get_ci(payload, "code")
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

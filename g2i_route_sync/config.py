"""Constants and environment-driven application configuration."""

from __future__ import annotations

import os
from dataclasses import dataclass

# Shared browser-like user agent for iGPSPORT HTTP sessions.
BROWSER_USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/136.0.0.0 Safari/537.36"
)

DEFAULT_IGPSPORT_DOMAIN = "prod.en.igpsport.com"
DEFAULT_IGPSPORT_REFERER = "https://login.passport.igpsport.com"
DEFAULT_IGPSPORT_WEB_BASE_URL = "https://i.igpsport.com"
DEFAULT_IGPSPORT_WEB_LOGIN_PATH = "/Auth/Login"
DEFAULT_IGPSPORT_WEB_UPLOAD_URL = "https://i.igpsport.com/Routes/uploadroad"
DEFAULT_IGPSPORT_WEB_REFERER = "https://i.igpsport.com/explorer/upload"
DEFAULT_IGPSPORT_WEB_ROADLIST_URL = "https://i.igpsport.com/Routes/RoadList"
DEFAULT_IGPSPORT_WEB_ROADLIST_REFERER = "https://i.igpsport.com/explorer/road?lang=ja"
DEFAULT_IGPSPORT_ROADLIST_PAGE_SIZE = 1000
DEFAULT_IGPSPORT_WEB_COOKIE_FILE = ".state/igpsport_web_cookies.json"
DEFAULT_GARMIN_ROUTE_LIST_ENDPOINT = "/course-service/course"
DEFAULT_GARMIN_ROUTE_DOWNLOAD_ENDPOINT = "/download-service/export/gpx/course/{route_id}"


def require_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def parse_endpoint_env(name: str, default: str) -> str:
    raw = os.getenv(name)
    if not raw:
        return default
    value = raw.strip()
    return value or default


@dataclass(frozen=True)
class AppConfig:
    """Resolved runtime configuration sourced from environment variables."""

    garmin_email: str
    garmin_password: str
    garmin_cn: bool
    igpsport_username: str
    igpsport_password: str
    igpsport_domain: str
    igpsport_referer: str
    route_list_endpoint: str
    route_download_endpoint: str
    web_cookie_file: str
    roadlist_page_size: int

    @classmethod
    def from_env(cls) -> "AppConfig":
        return cls(
            garmin_email=require_env("GARMIN_EMAIL"),
            garmin_password=require_env("GARMIN_PASSWORD"),
            garmin_cn=os.getenv("GARMIN_CN", "False").lower() == "true",
            igpsport_username=require_env("IGPSPORT_USERNAME"),
            igpsport_password=require_env("IGPSPORT_PASSWORD"),
            igpsport_domain=os.getenv("IGPSPORT_DOMAIN", DEFAULT_IGPSPORT_DOMAIN),
            igpsport_referer=os.getenv("IGPSPORT_REFERER", DEFAULT_IGPSPORT_REFERER),
            route_list_endpoint=parse_endpoint_env(
                "GARMIN_ROUTE_LIST_ENDPOINT", DEFAULT_GARMIN_ROUTE_LIST_ENDPOINT
            ),
            route_download_endpoint=parse_endpoint_env(
                "GARMIN_ROUTE_DOWNLOAD_ENDPOINT", DEFAULT_GARMIN_ROUTE_DOWNLOAD_ENDPOINT
            ),
            web_cookie_file=os.getenv(
                "IGPSPORT_WEB_COOKIE_FILE", DEFAULT_IGPSPORT_WEB_COOKIE_FILE
            ),
            roadlist_page_size=int(
                os.getenv(
                    "IGPSPORT_ROADLIST_PAGE_SIZE", str(DEFAULT_IGPSPORT_ROADLIST_PAGE_SIZE)
                )
            ),
        )

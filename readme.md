# g2i-route-sync

A Python script that downloads courses from Garmin Connect and uploads them to iGPSPORT roadbooks via API.

## Usage

Set these required credentials in your `.env` file or environment variables:

```env
GARMIN_EMAIL=your_garmin_email
GARMIN_PASSWORD=your_garmin_password
IGPSPORT_USERNAME=your_igpsport_username
IGPSPORT_PASSWORD=your_igpsport_password
```

Optional settings:

```env
# Region settings
GARMIN_CN=False
IGPSPORT_DOMAIN=prod.en.igpsport.com
IGPSPORT_REFERER=https://login.passport.igpsport.com

# Override Garmin route API endpoints
GARMIN_ROUTE_LIST_ENDPOINT=/course-service/course
GARMIN_ROUTE_DOWNLOAD_ENDPOINT=/download-service/export/gpx/course/{route_id}

# Web cookie file for i.igpsport.com (default: .state/igpsport_web_cookies.json)
IGPSPORT_WEB_COOKIE_FILE=.state/igpsport_web_cookies.json

# iGPSPORT RoadList page size for initial fetch (default: 1000)
IGPSPORT_ROADLIST_PAGE_SIZE=1000

# Log level
LOG_LEVEL=INFO
```

## Development

Install dependencies and run:

```bash
uv sync
uv run python main.py
```

Useful options:

```bash
# Limit number of Garmin routes to fetch
uv run python main.py --limit 20

# Check targets without uploading
uv run python main.py --dry-run

# Deprecated option (accepted but ignored)
uv run python main.py --state-file .state/sync_state.json
```

Run the tests, linter, and type checker:

```bash
uv run pytest
uv run ruff check .
uv run ty check
```

## Project structure

The CLI entrypoint is `main.py`, a thin wrapper around the `g2i_route_sync` package:

| Module | Responsibility |
| --- | --- |
| `g2i_route_sync/config.py` | Constants and `AppConfig` loaded from environment variables |
| `g2i_route_sync/models.py` | `RouteSummary` / `RoadBookSummary` data models |
| `g2i_route_sync/jsonutil.py` | Case-insensitive JSON access helpers |
| `g2i_route_sync/gpx.py` | GPX building and file-format detection |
| `g2i_route_sync/poi.py` | POI types, mapping, and GPX extraction |
| `g2i_route_sync/garmin.py` | `GarminRouteClient` (route listing and download) |
| `g2i_route_sync/igpsport.py` | `IGPSportClient` (upload, roadbooks, POI, privacy) |
| `g2i_route_sync/sync.py` | Route ordering and the sync orchestration |
| `g2i_route_sync/cli.py` | Argument parsing and `main()` |

Tests for the pure helpers (no network) live under `tests/`.

## Required Environment Variables

You must set the following values:

- `GARMIN_EMAIL`
- `GARMIN_PASSWORD`
- `IGPSPORT_USERNAME`
- `IGPSPORT_PASSWORD`

## Specification

- Garmin side:
  - Logs in and fetches route lists from Garmin course APIs.
  - Downloads each route as GPX/TCX/FIT (with fallback behavior when needed).
- iGPSPORT side:
  - Logs in via `/auth/account/login`.
  - Uploads routes through the web upload endpoint.
  - After upload, sets the route to private.
  - Sends extracted GPX POIs to iGPSPORT auxiliary points.
- Duplicate handling:
  - No local upload history file is used.
  - Each run compares against current iGPSPORT roadbooks and skips routes with the same title.

## Notes

- iGPSPORT APIs are not fully documented publicly, and behavior may vary by account or region.
- Web upload is fixed to `/Routes/uploadroad`.
- Web cookies are automatically refreshed via `/Auth/Login` and reused from `IGPSPORT_WEB_COOKIE_FILE`.
- Use `--dry-run` with `LOG_LEVEL=DEBUG` for troubleshooting.
- `.state` is used for runtime/session artifacts (for example, cookies and Garmin session cache), not for route dedup history.

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

# Override Garmin route API endpoints (comma-separated)
GARMIN_ROUTE_LIST_ENDPOINTS=/course-service/course/search,/course-service/course
GARMIN_ROUTE_DOWNLOAD_ENDPOINTS=/download-service/export/gpx/course/{route_id},/download-service/files/course/{route_id}

# Override iGPSPORT upload API endpoints (comma-separated)
IGPSPORT_ROUTE_UPLOAD_ENDPOINTS=/web-gateway/web-route/route/import,/web-gateway/web-course/course/import

# Web cookie file for i.igpsport.com (default: .state/igpsport_web_cookies.json)
IGPSPORT_WEB_COOKIE_FILE=.state/igpsport_web_cookies.json

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
- If needed, override endpoint candidates with `IGPSPORT_ROUTE_UPLOAD_ENDPOINTS`.
- Web upload is fixed to `/Routes/uploadroad`.
- Web cookies are automatically refreshed via `/Auth/Login` and reused from `IGPSPORT_WEB_COOKIE_FILE`.
- Use `--dry-run` with `LOG_LEVEL=DEBUG` for troubleshooting.
- `.state` is used for runtime/session artifacts (for example, cookies and Garmin session cache), not for route dedup history.

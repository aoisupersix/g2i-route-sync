# g2i-route-sync

A Dart CLI that downloads courses from Garmin Connect and uploads them to iGPSPORT roadbooks via API.

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

# iGPSPORT RouteListForWeb page size (default: 100)
IGPSPORT_ROADLIST_PAGE_SIZE=100

# Log level
LOG_LEVEL=INFO
```

## Development

Install dependencies and run:

```bash
dart pub get
dart run bin/g2i_route_sync.dart
```

Useful options:

```bash
# Limit number of Garmin routes to fetch
dart run bin/g2i_route_sync.dart --limit 20

# Check targets without uploading
dart run bin/g2i_route_sync.dart --dry-run

# Deprecated option (accepted but ignored)
dart run bin/g2i_route_sync.dart --state-file .state/sync_state.json
```

Run the tests, analyzer, and formatter:

```bash
dart test
dart analyze
dart format --output none --set-exit-if-changed .
```

Build a standalone executable:

```bash
dart compile exe bin/g2i_route_sync.dart -o g2i-route-sync
```

## Project structure

The CLI entrypoint is `bin/g2i_route_sync.dart`, a thin wrapper around the `g2i_route_sync` library:

| Module | Responsibility |
| --- | --- |
| `lib/config.dart` | Constants and `AppConfig` loaded from environment variables |
| `lib/models.dart` | `RouteSummary` / `RoadBookSummary` data models |
| `lib/json_util.dart` | Case-insensitive JSON access helpers |
| `lib/logging.dart` | Minimal leveled logger |
| `lib/gpx.dart` | GPX building and file-format detection |
| `lib/poi.dart` | POI types, mapping, and GPX extraction |
| `lib/http_session.dart` | Cookie-aware HTTP session (the `requests.Session` equivalent) |
| `lib/garmin_client.dart` | Garmin Connect authentication engine (port of `garminconnect`) |
| `lib/garmin_route_client.dart` | `GarminRouteClient` (route listing and download) |
| `lib/igpsport_client.dart` | `IgpsportClient` (upload, roadbooks, POI, privacy) |
| `lib/sync.dart` | Route ordering and the sync orchestration |
| `lib/cli.dart` | Argument parsing and `run()` |

Tests for the pure helpers (no network) live under `test/`.

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
  - Logs in via `/auth/account/login` (Bearer token, same API as app.igpsport.com).
  - Uploads routes via the OSS signed-URL flow: `GET
    /service/sportg/third-party-server/oss/getSignedUrl` -> `PUT` the file to
    the signed URL -> `POST /service/web/api/Routes/UploadOssGenerateRoutes`.
  - Route generation is asynchronous; the sync polls the route list until the
    uploaded title appears.
  - After upload, sets the route to private.
  - Sends extracted GPX POIs to iGPSPORT auxiliary points.
- Duplicate handling:
  - No local upload history file is used.
  - Each run compares against current iGPSPORT roadbooks and skips routes with the same title.

## Garmin authentication

`lib/garmin_client.dart` is a Dart reimplementation of the `garminconnect`
authentication flow. It tries three login strategies in order until one
succeeds — mobile iOS login, the SSO embed widget, and the portal web login —
then exchanges the resulting CAS service ticket for a DI OAuth2 bearer token
(with a JWT_WEB cookie fallback). Tokens are cached under the
`--garmin-session-dir` directory (`garmin_tokens.json`) and refreshed
automatically when they are about to expire.

The original Python relied on `curl_cffi` for TLS-fingerprint impersonation to
dodge Cloudflare rate limits; that is not available in Dart, so the strategies
run as plain HTTPS requests. Cached tokens are therefore the primary path for
unattended/CI runs.

## Notes

- iGPSPORT APIs are not fully documented publicly, and behavior may vary by account or region.
- The legacy `i.igpsport.com` web app was retired in August 2026 (it now
  redirects to `app.igpsport.com`); everything goes through
  `https://prod.en.igpsport.com/service` with Bearer auth.
- Use `--dry-run` with `LOG_LEVEL=DEBUG` for troubleshooting.
- `.state` is used for runtime/session artifacts (the Garmin session cache), not for route dedup history.

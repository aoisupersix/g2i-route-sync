/// Constants and environment-driven application configuration.
library;

/// Shared browser-like user agent for iGPSPORT HTTP sessions.
const browserUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/136.0.0.0 Safari/537.36';

const defaultIgpsportDomain = 'prod.en.igpsport.com';
const defaultIgpsportReferer = 'https://login.passport.igpsport.com';
const defaultIgpsportWebBaseUrl = 'https://i.igpsport.com';
const defaultIgpsportWebLoginPath = '/Auth/Login';
const defaultIgpsportWebUploadUrl = 'https://i.igpsport.com/Routes/uploadroad';
const defaultIgpsportWebReferer = 'https://i.igpsport.com/explorer/upload';
const defaultIgpsportWebRoadlistUrl = 'https://i.igpsport.com/Routes/RoadList';
const defaultIgpsportWebRoadlistReferer =
    'https://i.igpsport.com/explorer/road?lang=ja';
const defaultIgpsportRoadlistPageSize = 1000;
const defaultIgpsportWebCookieFile = '.state/igpsport_web_cookies.json';
const defaultGarminRouteListEndpoint = '/course-service/course';
const defaultGarminRouteDownloadEndpoint =
    '/download-service/export/gpx/course/{route_id}';

/// Looks up an environment variable by name, returning null when unset.
typedef EnvLookup = String? Function(String name);

String _requireEnv(EnvLookup env, String name) {
  final value = env(name);
  if (value == null || value.isEmpty) {
    throw StateError('Missing required environment variable: $name');
  }
  return value;
}

String _parseEndpointEnv(EnvLookup env, String name, String fallback) {
  final raw = env(name);
  if (raw == null || raw.isEmpty) return fallback;
  final value = raw.trim();
  return value.isEmpty ? fallback : value;
}

/// Resolved runtime configuration sourced from environment variables.
class AppConfig {
  final String garminEmail;
  final String garminPassword;
  final bool garminCn;
  final String igpsportUsername;
  final String igpsportPassword;
  final String igpsportDomain;
  final String igpsportReferer;
  final String routeListEndpoint;
  final String routeDownloadEndpoint;
  final String webCookieFile;
  final int roadlistPageSize;

  const AppConfig({
    required this.garminEmail,
    required this.garminPassword,
    required this.garminCn,
    required this.igpsportUsername,
    required this.igpsportPassword,
    required this.igpsportDomain,
    required this.igpsportReferer,
    required this.routeListEndpoint,
    required this.routeDownloadEndpoint,
    required this.webCookieFile,
    required this.roadlistPageSize,
  });

  factory AppConfig.fromEnv(EnvLookup env) {
    return AppConfig(
      garminEmail: _requireEnv(env, 'GARMIN_EMAIL'),
      garminPassword: _requireEnv(env, 'GARMIN_PASSWORD'),
      garminCn: (env('GARMIN_CN') ?? 'False').toLowerCase() == 'true',
      igpsportUsername: _requireEnv(env, 'IGPSPORT_USERNAME'),
      igpsportPassword: _requireEnv(env, 'IGPSPORT_PASSWORD'),
      igpsportDomain: env('IGPSPORT_DOMAIN') ?? defaultIgpsportDomain,
      igpsportReferer: env('IGPSPORT_REFERER') ?? defaultIgpsportReferer,
      routeListEndpoint: _parseEndpointEnv(
        env,
        'GARMIN_ROUTE_LIST_ENDPOINT',
        defaultGarminRouteListEndpoint,
      ),
      routeDownloadEndpoint: _parseEndpointEnv(
        env,
        'GARMIN_ROUTE_DOWNLOAD_ENDPOINT',
        defaultGarminRouteDownloadEndpoint,
      ),
      webCookieFile:
          env('IGPSPORT_WEB_COOKIE_FILE') ?? defaultIgpsportWebCookieFile,
      roadlistPageSize:
          int.tryParse(env('IGPSPORT_ROADLIST_PAGE_SIZE') ?? '') ??
          defaultIgpsportRoadlistPageSize,
    );
  }
}

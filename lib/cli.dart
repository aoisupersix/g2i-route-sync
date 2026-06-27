/// Command-line entrypoint.
library;

import 'package:args/args.dart';
import 'package:dotenv/dotenv.dart';

import 'config.dart';
import 'logging.dart';
import 'sync.dart';

Future<int> run(List<String> arguments) async {
  final env = DotEnv(includePlatformEnvironment: true)..load();

  final parser =
      ArgParser()
        ..addOption('limit', defaultsTo: '50', help: 'Max routes to fetch')
        ..addFlag(
          'dry-run',
          negatable: false,
          help:
              'Show what would be uploaded without calling iGPSPORT upload API',
        )
        ..addOption(
          'state-file',
          defaultsTo: 'sync_state.json',
          help: 'Deprecated and ignored (state-file based dedupe is disabled)',
        )
        ..addOption(
          'garmin-session-dir',
          defaultsTo: 'garmin_session',
          help: 'Directory used to store the Garmin authentication session',
        )
        ..addOption(
          'log-level',
          defaultsTo: env['LOG_LEVEL'] ?? 'INFO',
          help: 'Logging level (DEBUG/INFO/WARNING/ERROR)',
        )
        ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage');

  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    print(e.message);
    print(parser.usage);
    return 2;
  }

  if (args.flag('help')) {
    print('Download Garmin Connect routes and upload to iGPSPORT');
    print(parser.usage);
    return 0;
  }

  setLogLevel(parseLogLevel(args.option('log-level') ?? 'INFO'));

  final limit = int.tryParse(args.option('limit') ?? '50') ?? 50;

  final AppConfig config;
  try {
    config = AppConfig.fromEnv((name) => env[name]);
  } on StateError catch (e) {
    logError(e.message);
    return 1;
  }

  return runSync(
    config,
    limit: limit,
    dryRun: args.flag('dry-run'),
    sessionDir: args.option('garmin-session-dir') ?? 'garmin_session',
  );
}

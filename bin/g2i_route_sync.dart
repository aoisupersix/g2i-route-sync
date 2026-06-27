/// Sync routes from Garmin Connect to iGPSPORT via API.
///
/// Thin entrypoint; implementation lives in the ``g2i_route_sync`` library.
library;

import 'dart:io';

import 'package:g2i_route_sync/cli.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await run(arguments);
}

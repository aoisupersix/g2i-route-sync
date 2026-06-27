/// Minimal leveled logger mirroring the Python logging usage.
library;

import 'dart:io';

enum LogLevel { debug, info, warning, error }

LogLevel _level = LogLevel.info;

void setLogLevel(LogLevel level) => _level = level;

LogLevel parseLogLevel(String value) {
  switch (value.trim().toUpperCase()) {
    case 'DEBUG':
      return LogLevel.debug;
    case 'WARNING':
    case 'WARN':
      return LogLevel.warning;
    case 'ERROR':
      return LogLevel.error;
    case 'INFO':
    default:
      return LogLevel.info;
  }
}

void _log(LogLevel level, String label, String message) {
  if (level.index < _level.index) return;
  final ts = DateTime.now().toIso8601String();
  stderr.writeln('$ts $label g2i-route-sync: $message');
}

void logDebug(String message) => _log(LogLevel.debug, 'DEBUG', message);
void logInfo(String message) => _log(LogLevel.info, 'INFO', message);
void logWarning(String message) => _log(LogLevel.warning, 'WARNING', message);
void logError(String message) => _log(LogLevel.error, 'ERROR', message);

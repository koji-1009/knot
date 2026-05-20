import 'dart:io';

/// Verbosity for [KnotLogger] output.
enum LogLevel {
  silent(1 << 30),
  error(1000),
  warn(900),
  info(800),
  debug(500),
  trace(300);

  const LogLevel(this.priority);

  /// Higher = more important. A record is emitted when its level's
  /// priority is `>=` the configured threshold.
  final int priority;
}

/// Minimal logger writing to `stdout` (info+) or `stderr` (warn+).
///
/// One per logical subsystem (`knot.install`, `knot.audit`, …). The
/// shared threshold is set once via [KnotLogger.configure] from the
/// CLI's `--verbose` / `--quiet` flags.
class KnotLogger {
  KnotLogger(this.name);

  final String name;

  static LogLevel _threshold = LogLevel.info;

  /// Set the global verbosity threshold. Records below it are dropped.
  static void configure({LogLevel level = LogLevel.info}) {
    _threshold = level;
  }

  void error(String message, [Object? cause, StackTrace? trace]) =>
      _emit(LogLevel.error, message, cause, trace);

  void warn(String message, [Object? cause, StackTrace? trace]) =>
      _emit(LogLevel.warn, message, cause, trace);

  void info(String message) => _emit(LogLevel.info, message);

  void debug(String message) => _emit(LogLevel.debug, message);

  void trace(String message) => _emit(LogLevel.trace, message);

  void _emit(
    LogLevel level,
    String message, [
    Object? cause,
    StackTrace? trace,
  ]) {
    if (level.priority < _threshold.priority) return;
    // ignore: close_sinks
    final out = level.priority >= LogLevel.warn.priority ? stderr : stdout;
    out.writeln('[${level.name}] $name: $message');
    if (cause != null) out.writeln('  cause: $cause');
    if (trace != null) out.writeln(trace);
  }
}

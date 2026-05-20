import 'dart:io';

import 'package:knot/src/core/core.dart';

/// Renders a [ProgressEvent] stream to the terminal.
///
/// Two modes:
/// - Interactive (TTY + not silent): a single rewriting line shows the
///   current activity, plus one-line summaries on completion.
/// - Plain (no TTY, CI, redirected output): per-event lines.
class ProgressRenderer {
  ProgressRenderer({
    required this.level,
    Stdout? out,
    bool? interactive,
    bool? color,
  }) : _out = out ?? stdout,
       _interactive = interactive ?? (out ?? stdout).hasTerminal,
       _color = color ?? _detectColor(out ?? stdout);

  /// Whether ANSI color escape codes are enabled in the renderer.
  final bool _color;

  /// Configured verbosity. `silent` suppresses everything; `verbose`/`debug`
  /// emit per-package events even in interactive mode.
  final LogLevel level;
  final Stdout _out;
  final bool _interactive;

  int _resolved = 0;
  int _fetched = 0;
  int _extracted = 0;
  int _linked = 0;
  String _phase = '';

  void emit(ProgressEvent event) {
    if (level == LogLevel.silent) return;

    switch (event) {
      case ResolutionStarted():
        _phase = 'resolving';
        _verbose('resolving dependencies…');
        _redraw();
      case ResolutionCompleted(:final resolved, :final elapsed):
        _resolved = resolved;
        _phase = 'resolved';
        _line('resolved $resolved packages in ${elapsed.inMilliseconds}ms');
      case TarballFetchStarted(:final package, :final version):
        _phase = 'fetching $package@$version';
        _verbose('fetching $package@$version');
        _redraw();
      case TarballFetchProgress():
        // Byte-level progress: only redraw the line in interactive mode.
        _redraw();
      case TarballFetched(:final package, :final version):
        _fetched++;
        _verbose('fetched $package@$version');
        _redraw();
      case TarballExtracted(:final package, :final version):
        _extracted++;
        _phase = 'extracted $package@$version';
        _verbose('extracted $package@$version');
        _redraw();
      case PackageLinked(:final package, :final version):
        _linked++;
        _phase = 'linking $package@$version';
        _verbose('linked $package@$version');
        _redraw();
      case ScriptStarted(:final package, :final event):
        _phase = '$event($package)';
        _verbose('running $event for $package');
        _redraw();
      case ScriptCompleted(:final package, :final event, :final exitCode):
        if (exitCode != 0) {
          _line(_colored('script $event for $package exited $exitCode', 31));
        } else {
          _verbose('script $event for $package ok');
        }
        _redraw();
      case InstallSummary(:final added, :final removed, :final elapsed):
        _clearLine();
        _out.writeln(
          _colored(
            'installed $added packages '
            '(removed $removed, ${elapsed.inMilliseconds}ms)',
            32,
          ),
        );
    }
  }

  /// Called by the runner when an install finishes (success or fail) to
  /// avoid leaving a partial spinner line behind.
  void close() {
    _clearLine();
  }

  // ---------------------------------------------------------------------------

  void _line(String message) {
    _clearLine();
    _out.writeln(message);
    _redraw();
  }

  void _verbose(String message) {
    if (level == LogLevel.silent) return;
    if (level == LogLevel.debug || level == LogLevel.trace) {
      _clearLine();
      _out.writeln(message);
    } else if (!_interactive && _shouldPrintInPlainMode()) {
      _out.writeln(message);
    }
  }

  bool _shouldPrintInPlainMode() =>
      level == LogLevel.info ||
      level == LogLevel.debug ||
      level == LogLevel.trace;

  String _statusLine() {
    final buf = StringBuffer('$_phase ');
    if (_resolved > 0) buf.write('[res:$_resolved ');
    if (_fetched > 0) buf.write('fetch:$_fetched ');
    if (_extracted > 0) buf.write('extract:$_extracted ');
    if (_linked > 0) buf.write('link:$_linked');
    if (_resolved > 0) buf.write(']');
    return buf.toString().trimRight();
  }

  void _redraw() {
    if (!_interactive) return;
    if (level == LogLevel.silent) return;
    _clearLine();
    _out.write('\r${_statusLine()}');
  }

  void _clearLine() {
    if (!_interactive) return;
    _out.write('\r\x1b[2K');
  }

  String _colored(String text, int code) {
    if (!_color) return text;
    return '\x1b[${code}m$text\x1b[0m';
  }
}

bool _detectColor(Stdout out) {
  if (Platform.environment['NO_COLOR'] != null) return false;
  if (Platform.environment['FORCE_COLOR'] != null) return true;
  return out.hasTerminal;
}

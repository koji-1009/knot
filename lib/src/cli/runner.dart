import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:knot/src/core/core.dart';

import 'commands/add_command.dart';
import 'commands/audit_command.dart';
import 'commands/ci_command.dart';
import 'commands/clean_command.dart';
import 'commands/config_command.dart';
import 'commands/dlx_command.dart';
import 'commands/doctor_command.dart';
import 'commands/exec_command.dart';
import 'commands/install_command.dart';
import 'commands/list_command.dart';
import 'commands/outdated_command.dart';
import 'commands/peers_command.dart';
import 'commands/pkg_command.dart';
import 'commands/remove_command.dart';
import 'commands/run_command.dart';
import 'commands/sbom_command.dart';
import 'commands/update_command.dart';
import 'commands/view_command.dart';
import 'commands/why_command.dart';

/// Current CLI version, also reported by `knot --version`.
const String knotVersion = '0.0.1-dev';

/// Top-level CLI dispatcher. Built on `package:args/command_runner.dart`.
class KnotCommandRunner extends CommandRunner<int> {
  KnotCommandRunner({KnotLogger? logger})
    : super('knot', 'npm-compatible package manager.') {
    argParser
      ..addFlag(
        'version',
        negatable: false,
        help: 'Print the knot version and exit.',
      )
      ..addFlag(
        'silent',
        negatable: false,
        help: 'Suppress progress output; only print summary.',
      )
      ..addFlag(
        'verbose',
        abbr: 'v',
        negatable: false,
        help: 'Print per-package events.',
      )
      ..addOption(
        'loglevel',
        allowed: ['silent', 'error', 'warn', 'info', 'debug', 'trace'],
        help: 'Set log verbosity (overrides --silent/--verbose).',
      )
      ..addFlag(
        'color',
        defaultsTo: true,
        help: 'Colorize output when stdout is a TTY.',
      );

    addCommand(InstallCommand(logger: logger));
    addCommand(CiCommand(logger: logger));
    addCommand(AddCommand(logger: logger));
    addCommand(AuditCommand());
    addCommand(RemoveCommand(logger: logger));
    addCommand(UpdateCommand(logger: logger));
    addCommand(ListCommand());
    addCommand(WhyCommand());
    addCommand(ExecCommand());
    addCommand(RunCommand());
    addCommand(ViewCommand());
    addCommand(OutdatedCommand());
    addCommand(PkgCommand());
    addCommand(DoctorCommand());
    addCommand(ConfigCommand());
    addCommand(CleanCommand());
    addCommand(PeersCommand());
    addCommand(SbomCommand());
    addCommand(DlxCommand());
  }

  @override
  Future<int?> run(Iterable<String> args) async {
    // Use `parse` (inherited from [CommandRunner]) instead of
    // `argParser.parse` so an unknown option on a subcommand surfaces
    // as a `UsageException` (caught by `bin/knot.dart` → exit 64),
    // not as a bare `FormatException` (exit 70).
    final parsed = parse(args);
    if (parsed['version'] as bool) {
      print(knotVersion);
      return 0;
    }
    final level = _resolveLevel(parsed);
    KnotLogger.configure(level: level);
    return super.run(args);
  }

  LogLevel _resolveLevel(ArgResults parsed) {
    final loglevel = parsed['loglevel'] as String?;
    if (loglevel != null) {
      return LogLevel.values.firstWhere((l) => l.name == loglevel);
    }
    if (parsed['silent'] as bool) return LogLevel.silent;
    if (parsed['verbose'] as bool) return LogLevel.debug;
    return LogLevel.info;
  }
}

/// Resolve the effective log level from a [Command]'s `globalResults`.
LogLevel logLevelFor(ArgResults? globalResults) {
  if (globalResults == null) return LogLevel.info;
  final loglevel = globalResults['loglevel'] as String?;
  if (loglevel != null) {
    return LogLevel.values.firstWhere((l) => l.name == loglevel);
  }
  if (globalResults['silent'] as bool? ?? false) return LogLevel.silent;
  if (globalResults['verbose'] as bool? ?? false) return LogLevel.debug;
  return LogLevel.info;
}

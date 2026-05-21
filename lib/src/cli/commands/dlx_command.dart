import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/command_runner.dart';
import 'package:knot/src/core/core.dart';
import 'package:path/path.dart' as p;

import '../install_operation.dart';

/// `knot dlx <pkg> [args...]` — fetch + run a package's binary without
/// touching the user's project. Mirrors `npx` / `bunx` / `pnpm dlx`.
///
/// Caches the temporary install under `~/.knot/dlx/<key>/` so repeated
/// invocations of the same spec reuse the materialised tree (LRU
/// pruning is left to `knot clean`). Lifecycle scripts are disabled
/// here so the dlx target can't run arbitrary code at install time —
/// only its declared bin entry runs, under the caller's control.
class DlxCommand extends Command<int> {
  DlxCommand() {
    argParser
      ..addMultiOption(
        'package',
        abbr: 'p',
        help:
            'Explicit package(s) to install. When omitted, the first '
            'positional is treated as `<pkg>[@<spec>]` and the bin is '
            'inferred from its name.',
      )
      ..addOption(
        'call',
        abbr: 'c',
        help:
            'Override the binary to invoke (defaults to the package '
            'name, stripped of scope).',
      )
      ..addFlag(
        'offline',
        negatable: false,
        help: 'Forbid network access; cache miss fails.',
      );
  }

  @override
  String get name => 'dlx';

  @override
  String get description =>
      'Fetch a package into a temporary cache and run its binary.';

  @override
  Future<int> run() async {
    final results = argResults!;
    final rest = results.rest;
    final packages = (results['package'] as List<String>).toList();
    final callOverride = results['call'] as String?;

    if (packages.isEmpty && rest.isEmpty) {
      throw UsageError('knot dlx: package name required');
    }

    final DlxInvocation invocation;
    if (packages.isEmpty) {
      // Shorthand: first positional is the package; remaining are bin args.
      invocation = DlxInvocation.fromShorthand(
        target: rest.first,
        binArgs: rest.skip(1).toList(),
        callOverride: callOverride,
      );
    } else {
      // `-p <pkg> [-p <pkg>...] <bin> [args...]` form. The first
      // positional is the bin name; remaining are bin args. When no
      // positional is given the bin defaults to the first package.
      invocation = DlxInvocation.fromExplicit(
        packages: packages,
        positional: rest,
        callOverride: callOverride,
      );
    }

    final cacheRoot = _dlxCacheRoot();
    final dir = await _prepareDlxDir(
      cacheRoot: cacheRoot,
      packages: invocation.packages,
    );

    final install = InstallOperation(
      projectRoot: dir.path,
      options: InstallOptions(
        scriptPolicy: ScriptPolicy.none,
        ignoreScripts: true,
        offline: results['offline'] as bool,
        // dlx is ephemeral; we don't want the optimistic skip to ever
        // short-circuit before the install actually materialises the
        // bin shim on a fresh cache directory.
        optimisticRepeatInstall: false,
      ),
    );
    await install.run();

    // Resolve the actual bin name. The caller may have given us only
    // the package name; the package's `bin` field is the authority.
    final resolved = resolveDlxBin(
      dlxDir: dir.path,
      packages: invocation.packages,
      requested: callOverride ?? invocation.binName,
      callOverridden: callOverride != null,
    );

    final binPath = _binPathFor(dir.path, resolved);
    if (!File(binPath).existsSync() && !Link(binPath).existsSync()) {
      throw UsageError(
        'knot dlx: bin "$resolved" not found after install. '
        'Use --call to specify the correct executable.',
      );
    }

    final process = await Process.start(
      binPath,
      invocation.binArgs,
      mode: ProcessStartMode.inheritStdio,
    );
    return process.exitCode;
  }
}

/// Pick the right bin to invoke after install.
///
/// Lookup order:
/// 1. `--call <name>` always wins.
/// 2. The package's own `bin` field, in priority order:
///    a. an entry matching the requested name (default = package name)
///    b. if exactly one bin is declared, use that name
/// 3. Fall back to the requested name (and let the caller surface a
///    "not found" error if it doesn't exist on disk).
String resolveDlxBin({
  required String dlxDir,
  required Map<String, String> packages,
  required String requested,
  required bool callOverridden,
}) {
  if (callOverridden) return requested;
  // We probe only the first package; multi-package dlx callers are
  // expected to pass `--call` or specify the bin positionally.
  final primary = packages.keys.first;
  final manifestPath =
      p.join(dlxDir, 'node_modules', primary, 'package.json');
  final manifest = File(manifestPath);
  if (!manifest.existsSync()) return requested;
  final Object? rawBin;
  try {
    final decoded = jsonDecode(manifest.readAsStringSync());
    if (decoded is! Map) return requested;
    rawBin = decoded['bin'];
  } on FormatException {
    return requested;
  }
  if (rawBin is String) {
    // String form: the bin name equals the package's basename.
    return defaultBinFor(primary);
  }
  if (rawBin is Map) {
    if (rawBin.containsKey(requested)) return requested;
    if (rawBin.length == 1) {
      return rawBin.keys.first.toString();
    }
  }
  return requested;
}

/// One dlx invocation: the package(s) to install + the bin to run + args.
class DlxInvocation {
  const DlxInvocation({
    required this.packages,
    required this.binName,
    required this.binArgs,
  });

  /// `name → version-or-tag` map, fed straight into a temp package.json.
  final Map<String, String> packages;

  /// Bin name to look up under `node_modules/.bin/`.
  final String binName;

  /// Arguments forwarded to the bin.
  final List<String> binArgs;

  /// Shorthand: `knot dlx cowsay hello` or `knot dlx cowsay@2.0.0 hello`.
  factory DlxInvocation.fromShorthand({
    required String target,
    required List<String> binArgs,
    String? callOverride,
  }) {
    final spec = parsePackageSpec(target);
    return DlxInvocation(
      packages: {spec.name: spec.version},
      binName: callOverride ?? defaultBinFor(spec.name),
      binArgs: binArgs,
    );
  }

  /// Explicit `-p` form: `knot dlx -p foo -p bar baz arg1 arg2`.
  /// `positional` is `[bin, ...args]`; if empty, default bin = first pkg.
  factory DlxInvocation.fromExplicit({
    required List<String> packages,
    required List<String> positional,
    String? callOverride,
  }) {
    final specs = packages.map(parsePackageSpec).toList();
    final packageMap = <String, String>{
      for (final s in specs) s.name: s.version,
    };
    final binName = callOverride ??
        (positional.isNotEmpty
            ? positional.first
            : defaultBinFor(specs.first.name));
    final binArgs = positional.isNotEmpty
        ? (callOverride != null ? positional : positional.skip(1).toList())
        : const <String>[];
    return DlxInvocation(
      packages: packageMap,
      binName: binName,
      binArgs: binArgs,
    );
  }
}

/// Parsed `<name>[@<spec>]` form. Defaults to `latest` for a bare name.
class PackageSpec {
  const PackageSpec({required this.name, required this.version});
  final String name;
  final String version;
}

/// Split `<name>[@<spec>]`. Honors scoped names (`@scope/name@1.0`).
PackageSpec parsePackageSpec(String raw) {
  final value = raw.trim();
  if (value.isEmpty) {
    throw UsageError('knot dlx: empty package spec');
  }
  // Scoped: first `@` is part of the name. Look for `@` after the slash.
  if (value.startsWith('@')) {
    final slash = value.indexOf('/');
    if (slash < 0) {
      throw UsageError('knot dlx: malformed scoped name "$value"');
    }
    final at = value.indexOf('@', slash);
    if (at < 0) return PackageSpec(name: value, version: 'latest');
    return PackageSpec(
      name: value.substring(0, at),
      version: value.substring(at + 1),
    );
  }
  final at = value.indexOf('@');
  if (at < 0) return PackageSpec(name: value, version: 'latest');
  return PackageSpec(
    name: value.substring(0, at),
    version: value.substring(at + 1),
  );
}

/// Default bin name when not overridden: strip a leading `@scope/`.
String defaultBinFor(String packageName) {
  if (!packageName.startsWith('@')) return packageName;
  final slash = packageName.indexOf('/');
  if (slash < 0) return packageName;
  return packageName.substring(slash + 1);
}

/// Cache directory key for [packages]. Stable across runs: sha256 of
/// the sorted `name@version` set.
String dlxCacheKey(Map<String, String> packages) {
  final entries = packages.entries.map((e) => '${e.key}@${e.value}').toList()
    ..sort();
  final canonical = entries.join('\n');
  return KnotHash.sha256Hex(Uint8List.fromList(utf8.encode(canonical)))
      .substring(0, 16);
}

String _dlxCacheRoot() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null) {
    throw UsageError('knot dlx: cannot locate HOME for cache directory');
  }
  return p.join(home, '.knot', 'dlx');
}

Future<Directory> _prepareDlxDir({
  required String cacheRoot,
  required Map<String, String> packages,
}) async {
  final key = dlxCacheKey(packages);
  final dir = Directory(p.join(cacheRoot, key));
  await dir.create(recursive: true);
  // Always rewrite the manifest — it's tiny and lets us regenerate
  // after a partial / aborted previous run without staleness checks.
  final manifest = {
    'name': 'knot-dlx-$key',
    'version': '0.0.0',
    'private': true,
    'dependencies': packages,
  };
  await File(p.join(dir.path, 'package.json'))
      .writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));
  return dir;
}

String _binPathFor(String projectRoot, String binName) {
  final binDir = p.join(projectRoot, 'node_modules', '.bin');
  if (Platform.isWindows) return p.join(binDir, '$binName.cmd');
  return p.join(binDir, binName);
}

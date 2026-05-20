import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:knot/src/lockfile/lockfile.dart';
import 'package:knot/src/npmrc/npmrc.dart';
import 'package:knot/src/registry/registry.dart';
import 'package:knot/src/semver/semver.dart';
import 'package:path/path.dart' as p;

import '../package_json.dart';

/// `knot outdated` — print packages whose installed version is below the
/// registry `latest` or below the project's range maximum.
class OutdatedCommand extends Command<int> {
  @override
  String get name => 'outdated';

  @override
  String get description => 'List outdated dependencies.';

  @override
  Future<int> run() async {
    final root = Directory.current.path;
    final pkg = await PackageJson.read(p.join(root, 'package.json'));
    final lock = await readProjectLockfile(root);
    final npmrc = await NpmrcLoader(projectDir: root).load();
    final client = RegistryClient(config: npmrc);

    final declared = <String, String>{
      ...pkg.dependencies,
      ...pkg.devDependencies,
    };
    try {
      stdout.writeln(
        '${'Package'.padRight(28)}'
        '${'Current'.padRight(14)}'
        '${'Wanted'.padRight(14)}'
        'Latest',
      );
      for (final entry in declared.entries) {
        final name = entry.key;
        final range = entry.value;
        final installedVersion = _installedVersion(lock, name);

        final packument = await client
            .packument(name)
            .catchError(
              (_) => const Packument(name: '', versions: {}, distTags: {}),
            );
        if (packument.name.isEmpty) continue;
        final latest = packument.latest ?? 'n/a';
        String wanted;
        try {
          final parsedRange = NpmRange.parse(range);
          final versions = packument.versions.keys
              .map((v) => tryParseVersion(v))
              .whereType<Version>()
              .toList();
          final max = maxSatisfying(versions, parsedRange);
          wanted = max?.toString() ?? 'n/a';
        } on FormatException {
          wanted = range;
        }
        if (installedVersion == latest && wanted == latest) continue;
        stdout.writeln(
          name.padRight(28) +
              (installedVersion ?? 'missing').padRight(14) +
              wanted.padRight(14) +
              latest,
        );
      }
      return 0;
    } finally {
      client.close();
    }
  }

  String? _installedVersion(Lockfile? lock, String name) {
    if (lock == null) return null;
    for (final entry in lock.packages.values) {
      if (entry.name == name) return entry.version;
    }
    return null;
  }
}

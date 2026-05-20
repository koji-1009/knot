import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:knot/src/npmrc/npmrc.dart';
import 'package:knot/src/registry/registry.dart';

/// `knot view <pkg> [field]` — print packument fields, npm-view-compatible
/// for the most common queries.
class ViewCommand extends Command<int> {
  @override
  String get name => 'view';

  @override
  List<String> get aliases => const ['info', 'show'];

  @override
  String get description => 'Print package metadata from the registry.';

  @override
  Future<int> run() async {
    final args = argResults!.rest;
    if (args.isEmpty) {
      usageException('package name is required');
    }
    final pkgSpec = args.first;
    final field = args.length > 1 ? args[1] : null;

    final at = pkgSpec.startsWith('@')
        ? pkgSpec.indexOf('@', 1)
        : pkgSpec.indexOf('@');
    final pkgName = at > 0 ? pkgSpec.substring(0, at) : pkgSpec;

    final npmrc = await NpmrcLoader(projectDir: Directory.current.path).load();
    final client = RegistryClient(config: npmrc);
    try {
      final packument = await client.packument(pkgName);
      final out = _project(packument, field);
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(out));
      return 0;
    } finally {
      client.close();
    }
  }

  Object? _project(Packument packument, String? field) {
    if (field == null) {
      return {
        'name': packument.name,
        'dist-tags': packument.distTags,
        'versions': packument.versions.keys.toList(),
      };
    }
    switch (field) {
      case 'name':
        return packument.name;
      case 'versions':
        return packument.versions.keys.toList();
      case 'dist-tags':
        return packument.distTags;
      case 'latest':
        return packument.latest;
      default:
        // Unsupported dot-path → null.
        return null;
    }
  }
}

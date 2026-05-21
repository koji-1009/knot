import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/command_runner.dart';
import 'package:knot/src/lockfile/lockfile.dart';
import 'package:knot/src/core/core.dart';

/// `knot sbom` — emit a Software Bill of Materials in CycloneDX 1.7
/// or SPDX 2.3 JSON. pnpm-compatible (cli/sbom.md).
///
/// Sources the component list from the project lockfile so generation
/// is fast and offline-friendly. Workspace-only flags (`--prod`,
/// `--dev`, `--no-optional`) are honored as filters on the importer
/// tables in [Lockfile].
class SbomCommand extends Command<int> {
  SbomCommand() {
    argParser
      ..addOption(
        'sbom-format',
        allowed: ['cyclonedx', 'spdx'],
        help: 'Output format. Required.',
      )
      ..addOption(
        'sbom-type',
        help: 'CycloneDX bom-type metadata (library, application, …).',
      )
      ..addOption(
        'sbom-spec-version',
        help: 'Format spec version (e.g. 1.7 for CycloneDX, 2.3 for SPDX).',
      )
      ..addFlag(
        'lockfile-only',
        negatable: false,
        defaultsTo: true,
        help: 'Generate solely from lockfile data (no network).',
      )
      ..addOption(
        'sbom-authors',
        help: 'Comma-separated author names embedded in metadata.',
      )
      ..addOption(
        'sbom-supplier',
        help: 'Supplier organisation name embedded in metadata.',
      )
      ..addFlag('prod', negatable: false, help: 'Include only `dependencies`.')
      ..addFlag(
        'dev',
        negatable: false,
        help: 'Include only `devDependencies`.',
      )
      ..addFlag(
        'no-optional',
        negatable: false,
        help: 'Exclude optionalDependencies.',
      );
  }

  @override
  String get name => 'sbom';

  @override
  String get description =>
      'Generate a CycloneDX or SPDX Software Bill of Materials.';

  @override
  Future<int> run() async {
    final format = argResults!['sbom-format'] as String?;
    if (format == null) {
      throw UsageError('--sbom-format is required (cyclonedx or spdx)');
    }

    final root = Directory.current.path;
    final lockfile = await readProjectLockfile(root);
    if (lockfile == null) {
      throw UsageError('no lockfile at $root/package-lock.json');
    }

    final filter = SbomFilter(
      prodOnly: argResults!['prod'] as bool,
      devOnly: argResults!['dev'] as bool,
      excludeOptional: argResults!['no-optional'] as bool,
    );

    final encoder = const JsonEncoder.withIndent('  ');
    final document = format == 'cyclonedx'
        ? generateCycloneDx(
            lockfile,
            filter: filter,
            bomType: argResults!['sbom-type'] as String? ?? 'library',
            specVersion: argResults!['sbom-spec-version'] as String? ?? '1.7',
            authors: _splitCsv(argResults!['sbom-authors'] as String?),
            supplier: argResults!['sbom-supplier'] as String?,
          )
        : generateSpdx(
            lockfile,
            filter: filter,
            specVersion:
                argResults!['sbom-spec-version'] as String? ?? 'SPDX-2.3',
            authors: _splitCsv(argResults!['sbom-authors'] as String?),
            supplier: argResults!['sbom-supplier'] as String?,
          );

    stdout.writeln(encoder.convert(document));
    return 0;
  }
}

/// Inclusion filter shared by both SBOM formats.
class SbomFilter {
  const SbomFilter({
    this.prodOnly = false,
    this.devOnly = false,
    this.excludeOptional = false,
  });

  final bool prodOnly;
  final bool devOnly;
  final bool excludeOptional;
}

/// Compute the set of package IDs that pass the filter, anchored at
/// each importer's declared deps.
Set<String> _filteredPackageIds(Lockfile lockfile, SbomFilter filter) {
  final keep = <String>{};
  for (final importer in lockfile.importers.values) {
    if (!filter.devOnly) {
      keep.addAll(importer.dependencies.keys);
    }
    if (!filter.prodOnly) {
      keep.addAll(importer.devDependencies.keys);
    }
    if (!filter.excludeOptional && !filter.devOnly && !filter.prodOnly) {
      keep.addAll(importer.optionalDependencies.keys);
    }
  }
  // Empty filters keep everything (a "list all locked packages" view).
  if (keep.isEmpty &&
      !filter.prodOnly &&
      !filter.devOnly &&
      !filter.excludeOptional) {
    for (final entry in lockfile.packages.values) {
      keep.add(entry.name);
    }
  }
  return keep;
}

/// Build a CycloneDX 1.7 JSON document for [lockfile].
Map<String, Object?> generateCycloneDx(
  Lockfile lockfile, {
  required SbomFilter filter,
  required String bomType,
  required String specVersion,
  List<String> authors = const [],
  String? supplier,
}) {
  final keep = _filteredPackageIds(lockfile, filter);
  final components = <Map<String, Object?>>[];
  for (final entry in lockfile.packages.values) {
    if (!keep.contains(entry.name)) continue;
    final purl = _purlFor(entry.name, entry.version);
    components.add({
      'type': bomType,
      'bom-ref': purl,
      'name': entry.name,
      'version': entry.version,
      'purl': purl,
      if (entry.integrity != null)
        'hashes': [_hashFromIntegrity(entry.integrity!)],
    });
  }
  components.sort(
    (a, b) => (a['purl'] as String).compareTo(b['purl'] as String),
  );

  return {
    'bomFormat': 'CycloneDX',
    'specVersion': specVersion,
    'serialNumber': _stableSerial(lockfile),
    'version': 1,
    'metadata': {
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'tools': [
        {'vendor': 'knot', 'name': 'knot'},
      ],
      if (authors.isNotEmpty)
        'authors': [
          for (final a in authors) {'name': a},
        ],
      if (supplier != null) 'supplier': {'name': supplier},
    },
    'components': components,
  };
}

/// Build an SPDX 2.3 JSON document for [lockfile].
Map<String, Object?> generateSpdx(
  Lockfile lockfile, {
  required SbomFilter filter,
  required String specVersion,
  List<String> authors = const [],
  String? supplier,
}) {
  final keep = _filteredPackageIds(lockfile, filter);
  final packages = <Map<String, Object?>>[];
  for (final entry in lockfile.packages.values) {
    if (!keep.contains(entry.name)) continue;
    final spdxId = 'SPDXRef-${_sanitizeSpdxId(entry.name)}-${entry.version}';
    packages.add({
      'SPDXID': spdxId,
      'name': entry.name,
      'versionInfo': entry.version,
      'downloadLocation': 'NOASSERTION',
      'filesAnalyzed': false,
      if (entry.integrity != null)
        'checksums': [_spdxChecksumFromIntegrity(entry.integrity!)],
      'externalRefs': [
        {
          'referenceCategory': 'PACKAGE-MANAGER',
          'referenceType': 'purl',
          'referenceLocator': _purlFor(entry.name, entry.version),
        },
      ],
    });
  }
  packages.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));

  return {
    'spdxVersion': specVersion,
    'dataLicense': 'CC0-1.0',
    'SPDXID': 'SPDXRef-DOCUMENT',
    'name': 'knot-sbom',
    'documentNamespace': 'https://knot.invalid/sbom/${_stableSerial(lockfile)}',
    'creationInfo': {
      'created': DateTime.now().toUtc().toIso8601String(),
      'creators': [
        'Tool: knot',
        for (final a in authors) 'Person: $a',
        if (supplier != null) 'Organization: $supplier',
      ],
    },
    'packages': packages,
  };
}

String _purlFor(String name, String version) {
  if (name.startsWith('@')) {
    final slash = name.indexOf('/');
    final scope = Uri.encodeComponent(name.substring(1, slash));
    final pkg = Uri.encodeComponent(name.substring(slash + 1));
    return 'pkg:npm/%40$scope/$pkg@$version';
  }
  return 'pkg:npm/${Uri.encodeComponent(name)}@$version';
}

Map<String, Object?> _hashFromIntegrity(String integrity) {
  final colon = integrity.indexOf('-');
  if (colon < 0) {
    return {'alg': 'SHA-512', 'content': integrity};
  }
  final algo = integrity.substring(0, colon).toUpperCase();
  final content = integrity.substring(colon + 1);
  return {'alg': algo.replaceFirst('SHA', 'SHA-'), 'content': content};
}

Map<String, Object?> _spdxChecksumFromIntegrity(String integrity) {
  final dash = integrity.indexOf('-');
  if (dash < 0) {
    return {'algorithm': 'SHA512', 'checksumValue': integrity};
  }
  final algo = integrity.substring(0, dash).toUpperCase();
  return {'algorithm': algo, 'checksumValue': integrity.substring(dash + 1)};
}

String _stableSerial(Lockfile lockfile) {
  // Deterministic serial so two runs over the same lockfile match.
  final bodies = <String>[];
  for (final entry in lockfile.packages.values) {
    bodies.add('${entry.name}@${entry.version}|${entry.integrity ?? ''}');
  }
  bodies.sort();
  final hash = KnotHash.sha256Hex(
    Uint8List.fromList(utf8.encode(bodies.join('\n'))),
  );
  return 'urn:knot:sbom:$hash';
}

String _sanitizeSpdxId(String name) =>
    name.replaceAll(RegExp(r'[^a-zA-Z0-9.\-]'), '-');

List<String> _splitCsv(String? raw) {
  if (raw == null || raw.isEmpty) return const [];
  return raw
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
}

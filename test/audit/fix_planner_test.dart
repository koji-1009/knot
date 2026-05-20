import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:knot/src/audit/audit.dart';
import 'package:knot/src/lockfile/lockfile.dart';
import 'package:knot/src/npmrc/npmrc.dart';
import 'package:knot/src/registry/registry.dart';
import 'package:test/test.dart';

Lockfile _lock(Map<String, String> nameToVersion, {Set<String>? topLevel}) {
  topLevel ??= nameToVersion.keys.toSet();
  return Lockfile(
    lockfileVersion: 1,
    importers: {
      '.': Importer(dependencies: {for (final n in topLevel) n: '*'}),
    },
    packages: {
      for (final e in nameToVersion.entries)
        '${e.key}@${e.value}': LockedPackage(
          name: e.key,
          version: e.value,
          resolution: Resolution.tarball(
            tarball: 'https://registry.npmjs.org/${e.key}/-/x.tgz',
          ),
          integrity: 'sha512-x',
        ),
    },
  );
}

AuditReport _report(List<AuditFinding> findings) =>
    AuditReport(findings: findings, advisoryFetchErrors: const []);

AuditFinding _finding({
  required String name,
  required String version,
  required String severity,
  String? patched,
  String vulnerable = '<99',
  String id = 'GHSA-test',
}) {
  return AuditFinding(
    packageName: name,
    installedVersion: version,
    advisory: Advisory(
      id: id,
      severity: severity,
      title: 't',
      vulnerableVersions: vulnerable,
      patchedVersions: patched,
      url: 'https://example.test/$id',
    ),
  );
}

void main() {
  late http.Client mockClient;
  late RegistryClient client;
  late AuditFixPlanner planner;

  void mockPackuments(Map<String, List<String>> nameToVersions) {
    mockClient = http_testing.MockClient((req) async {
      final name = Uri.decodeComponent(req.url.pathSegments.last);
      final versions = nameToVersions[name];
      if (versions == null) {
        return http.Response('{}', 404);
      }
      return http.Response(
        jsonEncode({
          'name': name,
          'dist-tags': const <String, dynamic>{},
          'versions': {
            for (final v in versions)
              v: {
                'name': name,
                'version': v,
                'dist': {
                  'tarball': 'https://registry.npmjs.org/$name/-/x.tgz',
                  'integrity': 'sha512-x',
                },
              },
          },
        }),
        200,
      );
    });
    client = RegistryClient(config: const NpmrcConfig({}), client: mockClient);
    planner = AuditFixPlanner(client: client);
  }

  group('AuditFixPlanner', () {
    test('proposes the minimum patched version for a top-level dep', () async {
      mockPackuments({
        'lodash': ['4.17.0', '4.17.10', '4.17.21', '4.17.22'],
      });
      final plan = await planner.plan(
        report: _report([
          _finding(
            name: 'lodash',
            version: '4.17.0',
            severity: 'high',
            patched: '>=4.17.21',
          ),
        ]),
        lockfile: _lock({'lodash': '4.17.0'}),
      );
      expect(plan.fixes, hasLength(1));
      expect(plan.fixes.first.fromVersion, '4.17.0');
      expect(plan.fixes.first.toVersion, '4.17.21');
      expect(plan.unfixable, isEmpty);
      client.close();
    });

    test('reports unfixable when patched_versions is null', () async {
      mockPackuments({
        'lodash': ['4.17.0', '4.17.21'],
      });
      final plan = await planner.plan(
        report: _report([
          _finding(
            name: 'lodash',
            version: '4.17.0',
            severity: 'high',
            // patched left null
          ),
        ]),
        lockfile: _lock({'lodash': '4.17.0'}),
      );
      expect(plan.fixes, isEmpty);
      expect(plan.unfixable, hasLength(1));
      expect(plan.unfixable.first.reason, contains('no patched_versions'));
      client.close();
    });

    test(
      'reports transitive deps as unfixable (planner refuses to solve)',
      () async {
        mockPackuments({
          'inner': ['1.0.0', '1.0.1'],
        });
        // `inner` is in the lockfile but NOT in the importer's
        // dependencies — it's a transitive dep.
        final plan = await planner.plan(
          report: _report([
            _finding(
              name: 'inner',
              version: '1.0.0',
              severity: 'high',
              patched: '>=1.0.1',
            ),
          ]),
          lockfile: _lock(
            {'inner': '1.0.0', 'outer': '2.0.0'},
            topLevel: {'outer'}, // inner is transitive
          ),
        );
        expect(plan.fixes, isEmpty);
        expect(plan.unfixable, hasLength(1));
        expect(plan.unfixable.first.reason, contains('transitive'));
        client.close();
      },
    );

    test('skips when locked version already in patched range', () async {
      mockPackuments({
        'lodash': ['4.17.21', '4.17.22'],
      });
      final plan = await planner.plan(
        report: _report([
          _finding(
            name: 'lodash',
            version: '4.17.21',
            severity: 'high',
            patched: '>=4.17.21',
          ),
        ]),
        lockfile: _lock({'lodash': '4.17.21'}),
      );
      // Min satisfying patched is 4.17.21 which equals installed.
      expect(plan.fixes, isEmpty);
      expect(plan.unfixable, isEmpty);
      client.close();
    });

    test(
      'reports unfixable when patched_versions has no published version',
      () async {
        mockPackuments({
          'lodash': ['4.17.0', '4.17.20'],
        });
        final plan = await planner.plan(
          report: _report([
            _finding(
              name: 'lodash',
              version: '4.17.0',
              severity: 'high',
              patched: '>=5.0.0',
            ),
          ]),
          lockfile: _lock({'lodash': '4.17.0'}),
        );
        expect(plan.fixes, isEmpty);
        expect(plan.unfixable, hasLength(1));
        expect(
          plan.unfixable.first.reason,
          contains('no published version satisfies'),
        );
        client.close();
      },
    );

    test('dedupes findings sharing (package, advisory.id)', () async {
      mockPackuments({
        'pkg': ['1.0.0', '1.0.1'],
      });
      final plan = await planner.plan(
        report: _report([
          _finding(
            name: 'pkg',
            version: '1.0.0',
            severity: 'high',
            patched: '>=1.0.1',
            id: 'GHSA-dup',
          ),
          _finding(
            name: 'pkg',
            version: '1.0.0',
            severity: 'high',
            patched: '>=1.0.1',
            id: 'GHSA-dup',
          ),
        ]),
        lockfile: _lock({'pkg': '1.0.0'}),
      );
      expect(plan.fixes, hasLength(1));
      client.close();
    });
  });
}

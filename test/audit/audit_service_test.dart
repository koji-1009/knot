import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:knot/src/audit/audit.dart';
import 'package:knot/src/lockfile/lockfile.dart';
import 'package:knot/src/npmrc/npmrc.dart';
import 'package:test/test.dart';

Lockfile _lockOf(Map<String, String> nameToVersion) {
  return Lockfile(
    lockfileVersion: 1,
    importers: {
      '.': Importer(dependencies: {for (final n in nameToVersion.keys) n: '*'}),
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

NpmrcConfig _npmrc({Map<String, String>? entries}) =>
    NpmrcConfig(entries ?? const {});

void main() {
  group('AuditService', () {
    test('returns empty report for empty lockfile', () async {
      final calls = <http.Request>[];
      final service = AuditService(
        config: _npmrc(),
        userAgent: 'knot-test',
        client: http_testing.MockClient((req) async {
          calls.add(req);
          return http.Response('{}', 200);
        }),
      );
      try {
        final report = await service.audit(_lockOf({}));
        expect(report.total, 0);
        expect(calls, isEmpty);
      } finally {
        service.close();
      }
    });

    test('flags installed versions inside vulnerable_versions range', () async {
      final service = AuditService(
        config: _npmrc(),
        userAgent: 'knot-test',
        client: http_testing.MockClient((req) async {
          expect(req.method, 'POST');
          expect(req.url.path, endsWith('-/npm/v1/security/advisories/bulk'));
          final body = jsonDecode(req.body) as Map;
          expect(body['lodash'], contains('4.17.0'));
          return http.Response(
            jsonEncode({
              'lodash': [
                {
                  'id': 'GHSA-test-0001',
                  'severity': 'high',
                  'title': 'Prototype pollution',
                  'module_name': 'lodash',
                  'vulnerable_versions': '<4.17.21',
                  'patched_versions': '>=4.17.21',
                  'url': 'https://example.invalid/advisory/1',
                },
              ],
            }),
            200,
          );
        }),
      );
      try {
        final report = await service.audit(_lockOf({'lodash': '4.17.0'}));
        expect(report.total, 1);
        final f = report.findings.single;
        expect(f.packageName, 'lodash');
        expect(f.installedVersion, '4.17.0');
        expect(f.advisory.severity, 'high');
        expect(f.advisory.patchedVersions, '>=4.17.21');
        expect(report.meetsThreshold(AuditSeverity.high), isTrue);
        expect(report.meetsThreshold(AuditSeverity.critical), isFalse);
      } finally {
        service.close();
      }
    });

    test('re-filters server-returned advisories that do not match installed '
        'versions (defense against private registry drift)', () async {
      final service = AuditService(
        config: _npmrc(),
        userAgent: 'knot-test',
        client: http_testing.MockClient((req) async {
          return http.Response(
            jsonEncode({
              'lodash': [
                {
                  'id': 'stale',
                  'severity': 'critical',
                  'title': 'Was patched',
                  'module_name': 'lodash',
                  // Installed 4.17.21 is OUTSIDE this range.
                  'vulnerable_versions': '<4.17.21',
                  'patched_versions': '>=4.17.21',
                  'url': '',
                },
              ],
            }),
            200,
          );
        }),
      );
      try {
        final report = await service.audit(_lockOf({'lodash': '4.17.21'}));
        expect(report.total, 0);
      } finally {
        service.close();
      }
    });

    test(
      'reports endpoint failures rather than treating them as clean',
      () async {
        final service = AuditService(
          config: _npmrc(),
          userAgent: 'knot-test',
          client: http_testing.MockClient((req) async {
            return http.Response('{"error": "rate limited"}', 429);
          }),
        );
        try {
          final report = await service.audit(_lockOf({'react': '18.2.0'}));
          expect(report.findings, isEmpty);
          expect(report.advisoryFetchErrors, isNotEmpty);
          expect(report.advisoryFetchErrors.first, contains('429'));
        } finally {
          service.close();
        }
      },
    );

    test('groups scoped packages by their scope-specific registry', () async {
      final urls = <Uri>[];
      final service = AuditService(
        config: _npmrc(
          entries: {
            'registry': 'https://registry.public.example/',
            '@private:registry': 'https://registry.private.example/',
          },
        ),
        userAgent: 'knot-test',
        client: http_testing.MockClient((req) async {
          urls.add(req.url);
          return http.Response('{}', 200);
        }),
      );
      try {
        await service.audit(
          _lockOf({'react': '18.0.0', '@private/util': '1.0.0'}),
        );
        expect(urls.length, 2);
        expect(urls.map((u) => u.host).toSet(), {
          'registry.public.example',
          'registry.private.example',
        });
      } finally {
        service.close();
      }
    });

    test('skips non-tarball lockfile entries (workspace/file/git)', () async {
      final lock = Lockfile(
        lockfileVersion: 1,
        importers: const {
          '.': Importer(dependencies: {'local': 'file:./l'}),
        },
        packages: {
          'local@1.0.0': const LockedPackage(
            name: 'local',
            version: '1.0.0',
            // No tarball → not a registry-resolved package.
            resolution: Resolution.tarball(tarball: null, directory: './l'),
          ),
        },
      );
      var calls = 0;
      final service = AuditService(
        config: _npmrc(),
        userAgent: 'knot-test',
        client: http_testing.MockClient((req) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      try {
        final report = await service.audit(lock);
        expect(calls, 0);
        expect(report.total, 0);
      } finally {
        service.close();
      }
    });
  });
}

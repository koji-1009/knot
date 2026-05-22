import 'dart:convert';
import 'dart:io';

import 'package:knot/src/audit/audit.dart';
import 'package:knot/src/lockfile/lockfile.dart';
import 'package:knot/src/npmrc/npmrc.dart';
import 'package:test/test.dart';

import '../_support/loopback.dart';

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
      final calls = <HttpRequest>[];
      final fake = await startLoopback((req) async {
        calls.add(req);
        req.response.statusCode = 200;
        req.response.write('{}');
      });
      final service = AuditService(
        config: _npmrc(entries: {'registry': fake.uri.toString()}),
        userAgent: 'knot-test',
      );
      try {
        final report = await service.audit(_lockOf({}));
        expect(report.total, 0);
        expect(calls, isEmpty);
      } finally {
        service.close();
        await fake.server.close(force: true);
      }
    });

    test('flags installed versions inside vulnerable_versions range', () async {
      final fake = await startLoopback((req) async {
        expect(req.method, 'POST');
        expect(req.uri.path, endsWith('-/npm/v1/security/advisories/bulk'));
        final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
        expect(body['lodash'], contains('4.17.0'));
        req.response.statusCode = 200;
        req.response.write(
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
        );
      });
      final service = AuditService(
        config: _npmrc(entries: {'registry': fake.uri.toString()}),
        userAgent: 'knot-test',
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
        await fake.server.close(force: true);
      }
    });

    test('re-filters server-returned advisories that do not match installed '
        'versions (defense against private registry drift)', () async {
      final fake = await startLoopback((req) async {
        await utf8.decoder.bind(req).join();
        req.response.statusCode = 200;
        req.response.write(
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
        );
      });
      final service = AuditService(
        config: _npmrc(entries: {'registry': fake.uri.toString()}),
        userAgent: 'knot-test',
      );
      try {
        final report = await service.audit(_lockOf({'lodash': '4.17.21'}));
        expect(report.total, 0);
      } finally {
        service.close();
        await fake.server.close(force: true);
      }
    });

    test(
      'reports endpoint failures rather than treating them as clean',
      () async {
        final fake = await startLoopback((req) async {
          await utf8.decoder.bind(req).join();
          req.response.statusCode = 429;
          req.response.write('{"error": "rate limited"}');
        });
        final service = AuditService(
          config: _npmrc(entries: {'registry': fake.uri.toString()}),
          userAgent: 'knot-test',
        );
        try {
          final report = await service.audit(_lockOf({'react': '18.2.0'}));
          expect(report.findings, isEmpty);
          expect(report.advisoryFetchErrors, isNotEmpty);
          expect(report.advisoryFetchErrors.first, contains('429'));
        } finally {
          service.close();
          await fake.server.close(force: true);
        }
      },
    );

    test('groups scoped packages by their scope-specific registry', () async {
      // Two loopback servers so the scope-specific registry mapping
      // actually routes traffic to different endpoints.
      final publicCalls = <Uri>[];
      final privateCalls = <Uri>[];
      final pub = await startLoopback((req) async {
        publicCalls.add(req.uri);
        await utf8.decoder.bind(req).join();
        req.response.statusCode = 200;
        req.response.write('{}');
      });
      final priv = await startLoopback((req) async {
        privateCalls.add(req.uri);
        await utf8.decoder.bind(req).join();
        req.response.statusCode = 200;
        req.response.write('{}');
      });
      final service = AuditService(
        config: _npmrc(
          entries: {
            'registry': pub.uri.toString(),
            '@private:registry': priv.uri.toString(),
          },
        ),
        userAgent: 'knot-test',
      );
      try {
        await service.audit(
          _lockOf({'react': '18.0.0', '@private/util': '1.0.0'}),
        );
        expect(publicCalls, hasLength(1));
        expect(privateCalls, hasLength(1));
      } finally {
        service.close();
        await pub.server.close(force: true);
        await priv.server.close(force: true);
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
            resolution: Resolution.tarball(tarball: null),
          ),
        },
      );
      var calls = 0;
      final fake = await startLoopback((req) async {
        calls++;
        await utf8.decoder.bind(req).join();
        req.response.statusCode = 200;
        req.response.write('{}');
      });
      final service = AuditService(
        config: _npmrc(entries: {'registry': fake.uri.toString()}),
        userAgent: 'knot-test',
      );
      try {
        final report = await service.audit(lock);
        expect(calls, 0);
        expect(report.total, 0);
      } finally {
        service.close();
        await fake.server.close(force: true);
      }
    });
  });
}

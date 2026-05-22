import 'dart:convert';

import 'package:knot/src/cli/registry_provider.dart';
import 'package:knot/src/core/core.dart';
import 'package:knot/src/npmrc/npmrc.dart';
import 'package:knot/src/policy/release_age.dart';
import 'package:knot/src/registry/registry.dart';
import 'package:test/test.dart';

import '../_support/loopback.dart';

/// Build a minimal registry response with a `time` map per version.
String _packumentJson({
  required String name,
  required Map<String, String> versionToTime,
  String? latest,
}) {
  return jsonEncode({
    'name': name,
    'dist-tags': {'latest': ?latest},
    'versions': {
      for (final v in versionToTime.keys) v: {'name': name, 'version': v},
    },
    'time': versionToTime,
  });
}

void main() {
  group('RegistryPackageProvider min-release-age', () {
    test('hides versions younger than the configured cutoff', () async {
      final fake = await startLoopback((req) async {
        req.response.statusCode = 200;
        req.response.write(
          _packumentJson(
            name: 'demo',
            latest: '2.0.0',
            versionToTime: {
              '1.0.0': '2024-01-01T00:00:00Z',
              '1.5.0': '2025-05-01T00:00:00Z',
              '2.0.0': '2026-05-15T00:00:00Z',
            },
          ),
        );
      });
      final client = RegistryClient(
        config: NpmrcConfig({'registry': fake.uri.toString()}),
      );
      try {
        final provider = RegistryPackageProvider(
          client,
          // Frozen "now" = 2026-05-18; cutoff = 7 days before = 2026-05-11.
          // 1.0.0 (2024) → keep, 1.5.0 (2025-05-01) → keep,
          // 2.0.0 (2026-05-15) → blocked (younger than 7d).
          minReleaseAge: const Duration(days: 7),
          now: DateTime.parse('2026-05-18T00:00:00Z'),
        );
        final versions = await provider.versions('demo');
        expect(versions.map((v) => v.toString()), ['1.0.0', '1.5.0']);
      } finally {
        client.close();
        await fake.server.close(force: true);
      }
    });

    test('strict policy: fails when every version is blocked', () async {
      final fake = await startLoopback((req) async {
        req.response.statusCode = 200;
        req.response.write(
          _packumentJson(
            name: 'demo',
            latest: '1.0.0',
            versionToTime: {
              // Both published this week.
              '0.9.0': '2026-05-15T00:00:00Z',
              '1.0.0': '2026-05-17T00:00:00Z',
            },
          ),
        );
      });
      final client = RegistryClient(
        config: NpmrcConfig({'registry': fake.uri.toString()}),
      );
      try {
        final provider = RegistryPackageProvider(
          client,
          releaseAge: const MinReleaseAgePolicy(
            minimum: Duration(days: 7),
            strict: true,
          ),
          now: DateTime.parse('2026-05-18T00:00:00Z'),
        );
        await expectLater(
          () => provider.versions('demo'),
          throwsA(
            isA<NetworkError>().having(
              (e) => e.message,
              'message',
              contains('minimum-release-age'),
            ),
          ),
        );
      } finally {
        client.close();
        await fake.server.close(force: true);
      }
    });

    test(
      'non-strict fallback: returns lowest immature when all blocked',
      () async {
        final fake = await startLoopback((req) async {
          req.response.statusCode = 200;
          req.response.write(
            _packumentJson(
              name: 'demo',
              latest: '1.0.0',
              versionToTime: {
                '0.9.0': '2026-05-15T00:00:00Z',
                '1.0.0': '2026-05-17T00:00:00Z',
              },
            ),
          );
        });
        final client = RegistryClient(
          config: NpmrcConfig({'registry': fake.uri.toString()}),
        );
        try {
          final provider = RegistryPackageProvider(
            client,
            releaseAge: const MinReleaseAgePolicy(
              minimum: Duration(days: 7),
              // strict: false (default) — fallback to the oldest immature
            ),
            now: DateTime.parse('2026-05-18T00:00:00Z'),
          );
          final versions = await provider.versions('demo');
          expect(versions.map((v) => v.toString()), ['0.9.0']);
        } finally {
          client.close();
          await fake.server.close(force: true);
        }
      },
    );

    test(
      'ignoreMissingTime: passes through versions without time entries',
      () async {
        final fake = await startLoopback((req) async {
          req.response.statusCode = 200;
          req.response.write(
            jsonEncode({
              'name': 'demo',
              'dist-tags': {'latest': '1.0.0'},
              'versions': {
                '1.0.0': {'name': 'demo', 'version': '1.0.0'},
              },
              'time': <String, String>{},
            }),
          );
        });
        final client = RegistryClient(
          config: NpmrcConfig({'registry': fake.uri.toString()}),
        );
        try {
          final provider = RegistryPackageProvider(
            client,
            releaseAge: const MinReleaseAgePolicy(
              minimum: Duration(days: 7),
              // ignoreMissingTime defaults to true
            ),
            now: DateTime.parse('2026-05-18T00:00:00Z'),
          );
          final versions = await provider.versions('demo');
          expect(versions.single.toString(), '1.0.0');
        } finally {
          client.close();
          await fake.server.close(force: true);
        }
      },
    );

    test('excludePatterns: package-level bypass of the age check', () async {
      final fake = await startLoopback((req) async {
        req.response.statusCode = 200;
        req.response.write(
          _packumentJson(
            name: 'demo',
            latest: '1.0.0',
            versionToTime: {'1.0.0': '2026-05-17T00:00:00Z'},
          ),
        );
      });
      final client = RegistryClient(
        config: NpmrcConfig({'registry': fake.uri.toString()}),
      );
      try {
        final provider = RegistryPackageProvider(
          client,
          releaseAge: const MinReleaseAgePolicy(
            minimum: Duration(days: 7),
            strict: true,
            excludePatterns: ['demo'],
          ),
          now: DateTime.parse('2026-05-18T00:00:00Z'),
        );
        final versions = await provider.versions('demo');
        expect(versions.single.toString(), '1.0.0');
      } finally {
        client.close();
        await fake.server.close(force: true);
      }
    });

    test('passes everything through when minReleaseAge is null', () async {
      final fake = await startLoopback((req) async {
        req.response.statusCode = 200;
        req.response.write(
          _packumentJson(
            name: 'demo',
            latest: '1.0.0',
            versionToTime: {'1.0.0': '2026-05-17T00:00:00Z'},
          ),
        );
      });
      final client = RegistryClient(
        config: NpmrcConfig({'registry': fake.uri.toString()}),
      );
      try {
        final provider = RegistryPackageProvider(client);
        final versions = await provider.versions('demo');
        expect(versions.single.toString(), '1.0.0');
      } finally {
        client.close();
        await fake.server.close(force: true);
      }
    });
  });
}

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:knot/src/cli/registry_provider.dart';
import 'package:knot/src/core/core.dart';
import 'package:knot/src/npmrc/npmrc.dart';
import 'package:knot/src/policy/release_age.dart';
import 'package:knot/src/registry/registry.dart';
import 'package:test/test.dart';

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
      final mockClient = http_testing.MockClient((req) async {
        return http.Response(
          _packumentJson(
            name: 'demo',
            latest: '2.0.0',
            versionToTime: {
              '1.0.0': '2024-01-01T00:00:00Z',
              '1.5.0': '2025-05-01T00:00:00Z',
              '2.0.0': '2026-05-15T00:00:00Z',
            },
          ),
          200,
        );
      });
      final client = RegistryClient(
        config: const NpmrcConfig({}),
        client: mockClient,
      );
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
      client.close();
    });

    test('strict policy: fails when every version is blocked', () async {
      final mockClient = http_testing.MockClient((req) async {
        return http.Response(
          _packumentJson(
            name: 'demo',
            latest: '1.0.0',
            versionToTime: {
              // Both published this week.
              '0.9.0': '2026-05-15T00:00:00Z',
              '1.0.0': '2026-05-17T00:00:00Z',
            },
          ),
          200,
        );
      });
      final client = RegistryClient(
        config: const NpmrcConfig({}),
        client: mockClient,
      );
      final provider = RegistryPackageProvider(
        client,
        releaseAge: const MinReleaseAgePolicy(
          minimum: Duration(days: 7),
          strict: true,
        ),
        now: DateTime.parse('2026-05-18T00:00:00Z'),
      );
      expect(
        () => provider.versions('demo'),
        throwsA(
          isA<NetworkError>().having(
            (e) => e.message,
            'message',
            contains('minimum-release-age'),
          ),
        ),
      );
      client.close();
    });

    test('non-strict fallback: returns lowest immature when all blocked',
        () async {
      final mockClient = http_testing.MockClient((req) async {
        return http.Response(
          _packumentJson(
            name: 'demo',
            latest: '1.0.0',
            versionToTime: {
              '0.9.0': '2026-05-15T00:00:00Z',
              '1.0.0': '2026-05-17T00:00:00Z',
            },
          ),
          200,
        );
      });
      final client = RegistryClient(
        config: const NpmrcConfig({}),
        client: mockClient,
      );
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
      client.close();
    });

    test('ignoreMissingTime: passes through versions without time entries',
        () async {
      final mockClient = http_testing.MockClient((req) async {
        return http.Response(
          jsonEncode({
            'name': 'demo',
            'dist-tags': {'latest': '1.0.0'},
            'versions': {
              '1.0.0': {'name': 'demo', 'version': '1.0.0'},
            },
            'time': <String, String>{},
          }),
          200,
        );
      });
      final client = RegistryClient(
        config: const NpmrcConfig({}),
        client: mockClient,
      );
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
      client.close();
    });

    test('excludePatterns: package-level bypass of the age check', () async {
      final mockClient = http_testing.MockClient((req) async {
        return http.Response(
          _packumentJson(
            name: 'demo',
            latest: '1.0.0',
            versionToTime: {'1.0.0': '2026-05-17T00:00:00Z'},
          ),
          200,
        );
      });
      final client = RegistryClient(
        config: const NpmrcConfig({}),
        client: mockClient,
      );
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
      client.close();
    });

    test('passes everything through when minReleaseAge is null', () async {
      final mockClient = http_testing.MockClient((req) async {
        return http.Response(
          _packumentJson(
            name: 'demo',
            latest: '1.0.0',
            versionToTime: {'1.0.0': '2026-05-17T00:00:00Z'},
          ),
          200,
        );
      });
      final client = RegistryClient(
        config: const NpmrcConfig({}),
        client: mockClient,
      );
      final provider = RegistryPackageProvider(client);
      final versions = await provider.versions('demo');
      expect(versions.single.toString(), '1.0.0');
      client.close();
    });
  });
}

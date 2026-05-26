import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:knot/src/core/core.dart';
import 'package:knot/src/npmrc/npmrc.dart';
import 'package:knot/src/registry/registry.dart';
import 'package:test/test.dart';

import '../_support/loopback.dart';

/// A minimal packument body for [name] with a single version.
String _packumentJson(String name, {String version = '1.0.0'}) => jsonEncode({
  'name': name,
  'dist-tags': {'latest': version},
  'versions': {
    version: {
      'name': name,
      'version': version,
      'dist': {
        'tarball': 'https://x/$name-$version.tgz',
        'integrity': 'sha512-abc',
      },
    },
  },
});

void main() {
  group('RegistryClient.packument', () {
    test('fetches, then revalidates with a conditional 304', () async {
      // Mirrors gnpm's TestPackumentFetchAndRevalidate: an ETag with no
      // Cache-Control is never "fresh", so the second call must issue a
      // conditional GET and accept the cached body on a 304.
      var hits = 0;
      var conditional = 0;
      final fake = await startLoopback((req) async {
        hits++;
        req.response.headers.set(HttpHeaders.etagHeader, '"v1"');
        if (req.headers.value(HttpHeaders.ifNoneMatchHeader) == '"v1"') {
          conditional++;
          req.response.statusCode = HttpStatus.notModified;
          return;
        }
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType.json;
        req.response.write(_packumentJson('demo'));
      });
      final client = RegistryClient(
        config: NpmrcConfig({'registry': fake.uri.toString()}),
      );
      try {
        final p1 = await client.packument('demo');
        expect(p1.latest, '1.0.0');

        final p2 = await client.packument('demo');
        expect(
          p2.versions['1.0.0'],
          isNotNull,
          reason: 'revalidated packument kept its versions',
        );

        expect(hits, 2, reason: 'one full GET + one conditional GET');
        expect(conditional, 1);
      } finally {
        client.close();
        await fake.server.close(force: true);
      }
    });

    test('Cache-Control: max-age short-circuits revalidation', () async {
      // With a freshness window the second call must not touch the wire.
      var hits = 0;
      final fake = await startLoopback((req) async {
        hits++;
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.set(HttpHeaders.cacheControlHeader, 'max-age=300');
        req.response.write(_packumentJson('demo'));
      });
      final client = RegistryClient(
        config: NpmrcConfig({'registry': fake.uri.toString()}),
      );
      try {
        await client.packument('demo');
        await client.packument('demo');
        expect(
          hits,
          1,
          reason: 'second call served from the fresh in-process cache',
        );
      } finally {
        client.close();
        await fake.server.close(force: true);
      }
    });

    test('404 surfaces a NetworkError with the status code', () async {
      final fake = await startLoopback((req) async {
        req.response.statusCode = HttpStatus.notFound;
      });
      final client = RegistryClient(
        config: NpmrcConfig({'registry': fake.uri.toString()}),
      );
      try {
        await expectLater(
          () => client.packument('ghost'),
          throwsA(
            isA<NetworkError>().having((e) => e.statusCode, 'statusCode', 404),
          ),
        );
      } finally {
        client.close();
        await fake.server.close(force: true);
      }
    });

    test('encodes the scope-separator slash, leaving @ literal', () async {
      // npm emits lowercase `%2f`, pnpm uppercase `%2F`; the registry
      // treats them case-insensitively. knot emits `%2F` because Dart's
      // `Uri` normalizes percent-encoding to uppercase (RFC 3986
      // §6.2.2.1) — see the mode-fidelity note in doc/spec.md.
      String? gotPath;
      final fake = await startLoopback((req) async {
        gotPath = req.uri.path;
        req.response.write(_packumentJson('@scope/pkg'));
      });
      final client = RegistryClient(
        config: NpmrcConfig({'registry': fake.uri.toString()}),
      );
      try {
        await client.packument('@scope/pkg');
        expect(gotPath, '/@scope%2Fpkg');
        // Decoded, the path is the plain scoped name.
        expect(Uri.parse('http://x$gotPath').pathSegments, ['@scope/pkg']);
      } finally {
        client.close();
        await fake.server.close(force: true);
      }
    });

    test('honors a custom in-flight request budget', () async {
      // A low budget must not deadlock or drop requests; all complete.
      var hits = 0;
      final fake = await startLoopback((req) async {
        hits++;
        req.response.write(_packumentJson('demo'));
      });
      final client = RegistryClient(
        config: NpmrcConfig({'registry': fake.uri.toString()}),
        httpConcurrency: 2,
      );
      try {
        await Future.wait([
          client.packument('a'),
          client.packument('b'),
          client.packument('c'),
          client.packument('d'),
        ]);
        expect(hits, 4);
      } finally {
        client.close();
        await fake.server.close(force: true);
      }
    });

    test('preserves a registry path prefix without a trailing slash', () async {
      // Regression: `Uri.resolve` strips the last path segment of a base
      // that lacks a trailing slash, so a registry mounted at
      // `<host>/npm` would lose `/npm`. npm and pnpm both normalize the
      // trailing slash before joining; knot must reach `/npm/<pkg>`.
      String? gotPath;
      final fake = await startLoopback((req) async {
        gotPath = req.uri.path;
        req.response.write(_packumentJson('react'));
      });
      final client = RegistryClient(
        // No trailing slash on purpose.
        config: NpmrcConfig({'registry': '${fake.uri}npm'}),
      );
      try {
        await client.packument('react');
        expect(gotPath, '/npm/react');
      } finally {
        client.close();
        await fake.server.close(force: true);
      }
    });

    test('routes scoped packages to a path-prefixed scoped registry', () async {
      String? gotPath;
      final fake = await startLoopback((req) async {
        gotPath = req.uri.path;
        req.response.write(_packumentJson('@acme/widget'));
      });
      final client = RegistryClient(
        config: NpmrcConfig({
          'registry': 'https://example.invalid/',
          // Scoped registry with a path prefix and no trailing slash.
          '@acme:registry': '${fake.uri}private',
        }),
      );
      try {
        await client.packument('@acme/widget');
        expect(gotPath!.toLowerCase(), '/private/@acme%2fwidget');
      } finally {
        client.close();
        await fake.server.close(force: true);
      }
    });
  });

  group('RegistryClient.tarball', () {
    test('verifies integrity, caches, and rejects a mismatch', () async {
      final payload = Uint8List.fromList(utf8.encode('tarball-bytes'));
      final good = computeIntegrity('sha512', payload).encode();
      var served = 0;
      final fake = await startLoopback((req) async {
        served++;
        req.response.add(payload);
      });
      final tempDir = Directory.systemTemp.createTempSync('knot_tarball_test');
      final client = RegistryClient(
        config: NpmrcConfig({'registry': fake.uri.toString()}),
        cache: RegistryCache(root: tempDir.path),
      );
      try {
        final url = fake.uri.resolve('demo.tgz').toString();

        final first = await client.tarball(url: url, integrity: good);
        expect(first, payload);

        // Second fetch is served from the on-disk cache — no new hit.
        final second = await client.tarball(url: url, integrity: good);
        expect(second, payload);
        expect(served, 1, reason: 'second tarball came from cache');

        // A wrong integrity must be rejected.
        final bad = 'sha512-${base64.encode(Uint8List(64))}';
        await expectLater(
          () => client.tarball(url: url, integrity: bad),
          throwsA(isA<IntegrityError>()),
        );
      } finally {
        client.close();
        await fake.server.close(force: true);
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}

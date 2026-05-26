import 'dart:typed_data';

import 'package:knot/src/registry/registry.dart';
import 'package:test/test.dart';

PackumentVersion _version(String v) => PackumentVersion(
  name: 'demo',
  version: v,
  tarball: 'https://registry.npmjs.org/demo/-/demo-$v.tgz',
  integrity: 'sha512-${'A' * 88}',
  dependencies: {'lodash': '^4.17.0', 'react': '^18.0.0'},
  optionalDependencies: {'fsevents': '^2'},
  peerDependencies: {'react': '>=16', 'less': '*'},
  optionalPeers: {'less'},
  os: ['darwin', 'linux'],
  cpu: ['arm64', 'x64'],
  libc: ['glibc'],
  deprecated: 'use $v.1 instead — älteren Grüße 日本語', // non-ASCII
  hasBin: true,
  bin: {'demo': 'bin/cli.js'},
  scripts: {'postinstall': 'node ./setup.js'},
  engines: {'node': '>=18'},
  bundledDependencies: ['lodash'],
  hasInstallScript: true,
  signatures: [DistSignature(keyid: 'SHA256:abc', sig: 'BASE64SIG==')],
);

void main() {
  group('packument codec round-trip', () {
    test('preserves every field, meta, and multiple versions', () {
      final original = Packument(
        name: '@scope/demo',
        versions: {'1.0.0': _version('1.0.0'), '2.0.0': _version('2.0.0')},
        distTags: {'latest': '2.0.0', 'next': '2.0.0'},
        publishTimes: {
          '1.0.0': DateTime.utc(2024, 1, 2, 3, 4, 5, 678),
          '2.0.0': DateTime.utc(2025, 6, 7, 8, 9, 10, 11),
        },
      );
      final freshUntil = DateTime.utc(2030, 1, 1, 0, 0, 0);

      final bytes = encodePackumentBlob(
        packument: original,
        etag: '"abc123"',
        lastModified: 'Wed, 21 Oct 2025 07:28:00 GMT',
        freshUntil: freshUntil,
      );
      final blob = decodePackumentBlob(bytes)!;

      expect(blob.etag, '"abc123"');
      expect(blob.lastModified, 'Wed, 21 Oct 2025 07:28:00 GMT');
      expect(blob.freshUntil, freshUntil);

      final p = blob.packument;
      expect(p.name, '@scope/demo');
      expect(p.distTags, {'latest': '2.0.0', 'next': '2.0.0'});
      expect(p.publishTimes['1.0.0'], DateTime.utc(2024, 1, 2, 3, 4, 5, 678));
      expect(p.versions.keys.toSet(), {'1.0.0', '2.0.0'});

      final v = p.versions['2.0.0']!;
      final src = _version('2.0.0');
      expect(v.name, src.name);
      expect(v.version, '2.0.0');
      expect(v.tarball, src.tarball);
      expect(v.integrity, src.integrity);
      expect(v.dependencies, src.dependencies);
      expect(v.optionalDependencies, src.optionalDependencies);
      expect(v.peerDependencies, src.peerDependencies);
      expect(v.optionalPeers, src.optionalPeers);
      expect(v.os, src.os);
      expect(v.cpu, src.cpu);
      expect(v.libc, src.libc);
      expect(v.deprecated, src.deprecated); // non-ASCII preserved
      expect(v.bin, src.bin);
      expect(v.hasBin, isTrue);
      expect(v.scripts, src.scripts);
      expect(v.engines, src.engines);
      expect(v.bundledDependencies, src.bundledDependencies);
      expect(v.hasInstallScript, isTrue);
      expect(v.signatures.single.keyid, 'SHA256:abc');
      expect(v.signatures.single.sig, 'BASE64SIG==');
    });

    test('round-trips a minimal packument and null meta', () {
      final original = Packument(
        name: 'x',
        versions: {
          '0.0.0': const PackumentVersion(
            name: 'x',
            version: '0.0.0',
            tarball: null,
            integrity: null,
          ),
        },
        distTags: const {},
      );
      final blob = decodePackumentBlob(
        encodePackumentBlob(packument: original),
      )!;
      expect(blob.etag, isNull);
      expect(blob.lastModified, isNull);
      expect(blob.freshUntil, isNull);
      expect(blob.packument.name, 'x');
      final v = blob.packument.versions['0.0.0']!;
      expect(v.tarball, isNull);
      expect(v.integrity, isNull);
      expect(v.dependencies, isEmpty);
      expect(v.hasBin, isFalse);
      expect(blob.packument.publishTimes, isEmpty);
    });

    test('rejects corrupt bytes as a cache miss (null)', () {
      expect(decodePackumentBlob(Uint8List.fromList([1, 2, 3, 4, 5])), isNull);
      expect(decodePackumentBlob(Uint8List(0)), isNull);
    });

    test('rejects an unknown magic/version byte', () {
      final good = encodePackumentBlob(
        packument: Packument(name: 'x', versions: const {}, distTags: const {}),
      );
      final wrongMagic = Uint8List.fromList(good)..[0] = 0xFF;
      expect(decodePackumentBlob(wrongMagic), isNull);
      final wrongVersion = Uint8List.fromList(good)..[1] = 0x7F;
      expect(decodePackumentBlob(wrongVersion), isNull);
    });

    test('rejects truncated bytes', () {
      final good = encodePackumentBlob(
        packument: Packument(
          name: 'demo',
          versions: {'1.0.0': _version('1.0.0')},
          distTags: const {},
        ),
      );
      expect(decodePackumentBlob(good.sublist(0, good.length - 5)), isNull);
    });
  });
}

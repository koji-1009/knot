import 'dart:io';

import 'package:knot/src/lockfile/lockfile.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('importNpmLockfile parses package-lock.json v3', () async {
    final tmp = await Directory.systemTemp.createTemp('knot_npmlock_test_');
    try {
      final path = p.join(tmp.path, 'package-lock.json');
      await File(path).writeAsString('''
{
  "name": "demo",
  "version": "0.0.0",
  "lockfileVersion": 3,
  "requires": true,
  "packages": {
    "": {
      "name": "demo",
      "version": "0.0.0",
      "dependencies": { "react": "^18.0.0" }
    },
    "node_modules/react": {
      "version": "18.2.0",
      "resolved": "https://registry.npmjs.org/react/-/react-18.2.0.tgz",
      "integrity": "sha512-abc",
      "dependencies": { "loose-envify": "^1.1.0" }
    }
  }
}
''');
      final lf = await importNpmLockfile(path);
      expect(lf.packages.keys, contains('react@18.2.0'));
      final react = lf.packages['react@18.2.0']!;
      expect(react.integrity, 'sha512-abc');
      expect(react.dependencies['loose-envify'], '^1.1.0');
    } finally {
      await tmp.delete(recursive: true);
    }
  });
}

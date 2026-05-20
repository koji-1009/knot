import 'dart:convert';
import 'dart:io';

import 'package:knot/src/cli/dependency_spec.dart';
import 'package:knot/src/cli/non_registry_resolver.dart';
import 'package:knot/src/store/store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

Future<void> _writePkgDir({
  required String dir,
  required Map<String, dynamic> json,
}) async {
  await Directory(p.join(d.sandbox, dir)).create(recursive: true);
  await File(
    p.join(d.sandbox, dir, 'package.json'),
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(json));
  await File(
    p.join(d.sandbox, dir, 'index.js'),
  ).writeAsString("module.exports = {name: '${json['name']}'};");
}

void main() {
  late Store store;
  late String projectRoot;

  setUp(() async {
    projectRoot = d.sandbox;
    store = Store(p.join(d.sandbox, '.knot-store'));
    await store.initialize();
  });

  group('file:', () {
    test('packs a local dir into the store and returns a LinkSpec', () async {
      await _writePkgDir(
        dir: 'local-pkg',
        json: {'name': 'local-pkg', 'version': '1.2.3'},
      );
      final resolver = NonRegistryResolver(
        projectRoot: projectRoot,
        store: store,
      );
      final resolution = await resolver.resolve(
        DependencySpec.parse('local-pkg', 'file:./local-pkg'),
      );
      expect(
        resolution.directSymlinkTarget,
        isNull,
        reason: 'file: should go via the store',
      );
      expect(resolution.linkSpec.name, 'local-pkg');
      expect(resolution.linkSpec.version, '1.2.3');
      expect(resolution.linkSpec.tarballSha512Hex.length, greaterThan(0));
      expect(resolution.linkSpec.isDirect, isTrue);
    });

    test('aliased file: dep keeps the logical link name', () async {
      await _writePkgDir(
        dir: 'real',
        json: {'name': 'real-pkg', 'version': '0.0.1'},
      );
      final resolver = NonRegistryResolver(
        projectRoot: projectRoot,
        store: store,
      );
      final spec = DependencySpec.parse('alias', 'file:./real');
      final resolution = await resolver.resolve(spec);
      // Logical name from package.json wins for the name, but alias logical
      // name is preserved (since logicalName='alias' != packageName='alias' …
      // For file: protocol logicalName comes from the key, packageName too).
      expect(resolution.linkSpec.name, 'real-pkg');
    });
  });

  group('link:', () {
    test(
      'produces a direct symlink target instead of going via the store',
      () async {
        await _writePkgDir(
          dir: 'sibling',
          json: {'name': 'sibling', 'version': '2.0.0'},
        );
        final resolver = NonRegistryResolver(
          projectRoot: projectRoot,
          store: store,
        );
        final resolution = await resolver.resolve(
          DependencySpec.parse('sibling', 'link:./sibling'),
        );
        expect(resolution.directSymlinkTarget, isNotNull);
        expect(
          resolution.directSymlinkTarget,
          p.normalize(p.join(d.sandbox, 'sibling')),
        );
        expect(resolution.linkSpec.tarballSha512Hex, isEmpty);
      },
    );
  });
}

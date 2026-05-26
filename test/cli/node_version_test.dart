import 'dart:io';

import 'package:knot/src/cli/node_version.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late File fakeNode;
  late String cacheFile;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('knot_nodever');
    fakeNode = File(p.join(tmp.path, 'node'))..writeAsStringSync('#!/bin/sh');
    cacheFile = p.join(tmp.path, 'cache', 'node-version.json');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  /// A `node --version` stub that counts how many times it is invoked.
  ({
    Future<ProcessResult> Function(String, List<String>) run,
    int Function() calls,
  })
  stubNode(String stdout, {int exitCode = 0}) {
    var calls = 0;
    return (
      run: (exe, args) async {
        calls++;
        return ProcessResult(0, exitCode, stdout, '');
      },
      calls: () => calls,
    );
  }

  test('cold miss probes node and writes the cache', () async {
    final stub = stubNode('v20.11.0\n');
    final cache = NodeVersionCache(
      cacheFile,
      runProcess: stub.run,
      resolveNode: () => fakeNode.path,
    );

    final v = await cache.detect();
    expect(v.toString(), '20.11.0');
    expect(stub.calls(), 1, reason: 'cold run forks node once');
    expect(File(cacheFile).existsSync(), isTrue);
  });

  test('warm hit returns the cached version without forking', () async {
    final stub = stubNode('v20.11.0\n');
    NodeVersionCache cache() => NodeVersionCache(
      cacheFile,
      runProcess: stub.run,
      resolveNode: () => fakeNode.path,
    );

    await cache().detect(); // populate
    final v = await cache().detect(); // should hit cache
    expect(v.toString(), '20.11.0');
    expect(stub.calls(), 1, reason: 'second run served from disk cache');
  });

  test('a changed node binary invalidates the cache', () async {
    final stub = stubNode('v20.11.0\n');
    NodeVersionCache cache() => NodeVersionCache(
      cacheFile,
      runProcess: stub.run,
      resolveNode: () => fakeNode.path,
    );

    await cache().detect();
    // Simulate a node upgrade: size + mtime change.
    fakeNode.writeAsStringSync('#!/bin/sh\n# upgraded to a longer body');
    await cache().detect();
    expect(stub.calls(), 2, reason: 'identity mismatch re-probes');
  });

  test('bypassCache forces a fresh probe even with a valid cache', () async {
    final stub = stubNode('v20.11.0\n');
    NodeVersionCache cache() => NodeVersionCache(
      cacheFile,
      runProcess: stub.run,
      resolveNode: () => fakeNode.path,
    );

    await cache().detect(); // populate
    final v = await cache().detect(bypassCache: true);
    expect(v.toString(), '20.11.0');
    expect(stub.calls(), 2, reason: '--engine-strict path never trusts cache');
  });

  test('unparseable --version output yields null', () async {
    final stub = stubNode('not-a-version\n');
    final cache = NodeVersionCache(
      cacheFile,
      runProcess: stub.run,
      resolveNode: () => fakeNode.path,
    );
    expect(await cache.detect(), isNull);
    expect(
      File(cacheFile).existsSync(),
      isFalse,
      reason: 'no cache on parse failure',
    );
  });

  test('non-zero exit yields null', () async {
    final stub = stubNode('', exitCode: 1);
    final cache = NodeVersionCache(
      cacheFile,
      runProcess: stub.run,
      resolveNode: () => fakeNode.path,
    );
    expect(await cache.detect(), isNull);
  });
}

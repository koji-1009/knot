import 'dart:io';

import 'package:knot/src/ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('hardlinkSync creates a link that shares contents', () async {
    final tmp = await Directory.systemTemp.createTemp('knot_ffi_test_');
    try {
      final source = File(p.join(tmp.path, 'src'));
      final target = p.join(tmp.path, 'tgt');
      await source.writeAsString('hello');

      hardlinkSync(source.path, target);
      expect(File(target).existsSync(), isTrue);
      expect(await File(target).readAsString(), 'hello');

      await source.writeAsString('updated');
      expect(await File(target).readAsString(), 'updated');
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test(
    'hardlinkOrCopy falls back to copy on cross-device or unsupported',
    () async {
      final tmp = await Directory.systemTemp.createTemp('knot_ffi_test_');
      try {
        final source = File(p.join(tmp.path, 'src'));
        final target = p.join(tmp.path, 'tgt');
        await source.writeAsString('payload');

        final outcome = await hardlinkOrCopy(
          source: source.path,
          target: target,
        );
        expect(
          outcome,
          anyOf(HardlinkOutcome.created, HardlinkOutcome.fallbackCopied),
        );
        expect(await File(target).readAsString(), 'payload');
      } finally {
        await tmp.delete(recursive: true);
      }
    },
  );
}

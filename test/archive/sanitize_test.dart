import 'package:knot/src/archive/archive.dart';
import 'package:knot/src/core/core.dart';
import 'package:test/test.dart';

void main() {
  group('sanitizeArchiveEntry', () {
    const dest = '/tmp/out';

    test('accepts a plain relative path', () {
      final result = sanitizeArchiveEntry('lib/index.js', destination: dest);
      expect(result, '/tmp/out/lib/index.js');
    });

    test('rejects absolute path', () {
      expect(
        () => sanitizeArchiveEntry('/etc/passwd', destination: dest),
        throwsA(isA<IoError>()),
      );
    });

    test('rejects parent traversal', () {
      expect(
        () => sanitizeArchiveEntry('../escape', destination: dest),
        throwsA(isA<IoError>()),
      );
      expect(
        () => sanitizeArchiveEntry('foo/../../escape', destination: dest),
        throwsA(isA<IoError>()),
      );
    });

    test('rejects Windows drive letters', () {
      expect(
        () => sanitizeArchiveEntry(r'C:\foo', destination: dest),
        throwsA(isA<IoError>()),
      );
    });

    test('rejects NUL byte', () {
      expect(
        () => sanitizeArchiveEntry('lib\x00/index.js', destination: dest),
        throwsA(isA<IoError>()),
      );
    });
  });
}

import 'package:knot/src/archive/archive.dart';
import 'package:knot/src/core/core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('sanitizeArchiveEntry', () {
    // Resolved by the sanitizer to a platform-native absolute path.
    // The literal string differs on Windows (`D:\...`) vs POSIX
    // (`/...`), so assertions compose the expected value with
    // `p.join` rather than hard-coding a separator.
    final dest = p.join(p.current, 'tmp', 'out');

    test('accepts a plain relative path', () {
      final result = sanitizeArchiveEntry('lib/index.js', destination: dest);
      expect(result, p.join(dest, 'lib', 'index.js'));
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

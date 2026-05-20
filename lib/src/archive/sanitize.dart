import 'package:knot/src/core/core.dart';
import 'package:path/path.dart' as p;

/// Sanitizer for tar entry paths under a fixed destination root.
///
/// Construct once per archive; `resolve` is then a per-entry check
/// that reuses the cached absolute destination path. The hot path
/// (npm packages have hundreds of entries) skips the
/// `p.normalize(p.absolute(destination))` work that an entry-by-entry
/// helper would repeat.
class ArchiveSanitizer {
  ArchiveSanitizer(String destination)
    : _destAbs = p.normalize(p.absolute(destination));

  final String _destAbs;

  /// Returns the safe absolute path for a tar entry under the
  /// destination this sanitizer was constructed with.
  ///
  /// Throws [IoError] if the entry name attempts traversal (`..`), uses
  /// an absolute path, contains a Windows drive letter, or contains an
  /// embedded NUL byte.
  String resolve(String entryName) {
    if (entryName.codeUnits.contains(0)) {
      throw IoError('archive entry contains NUL byte: $entryName');
    }
    if (entryName.startsWith('/') || _hasDriveLetter(entryName)) {
      throw IoError('archive entry has absolute path: $entryName');
    }

    final normalized = p.posix.normalize(entryName);
    if (normalized == '..' || normalized.split('/').contains('..')) {
      throw IoError('archive entry escapes destination: $entryName');
    }
    final joinedAbs = p.normalize(p.absolute(p.join(_destAbs, normalized)));
    if (!p.isWithin(_destAbs, joinedAbs) && joinedAbs != _destAbs) {
      throw IoError('archive entry escapes destination: $entryName');
    }
    return joinedAbs;
  }
}

/// Convenience for one-shot callers (tests, infrequent paths). Hot loops
/// should construct an [ArchiveSanitizer] once and reuse it.
String sanitizeArchiveEntry(String entryName, {required String destination}) =>
    ArchiveSanitizer(destination).resolve(entryName);

bool _hasDriveLetter(String s) {
  if (s.length < 3) return false;
  final c = s.codeUnitAt(0);
  final isLetter = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
  return isLetter && s[1] == ':' && (s[2] == '/' || s[2] == r'\');
}

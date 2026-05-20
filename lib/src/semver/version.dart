import 'package:pub_semver/pub_semver.dart' as ps;

/// A semantic version. Re-exported from `package:pub_semver` so internal
/// callers can treat npm and pub versions uniformly.
typedef Version = ps.Version;

/// Parse a strict semver string. Throws [FormatException] on failure.
Version parseVersion(String input) => ps.Version.parse(input.trim());

/// Try to parse [input] as a version; returns `null` on failure.
Version? tryParseVersion(String input) {
  try {
    return parseVersion(input);
  } on FormatException {
    return null;
  }
}

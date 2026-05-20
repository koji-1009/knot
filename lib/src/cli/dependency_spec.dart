/// A parsed dependency specifier.
///
/// Captures the gap between *logical* names used in `package.json`
/// (`"react-18"`) and the actual package name to resolve and fetch
/// (`react`). For plain non-aliased entries the two are identical.
class DependencySpec {
  const DependencySpec({
    required this.logicalName,
    required this.packageName,
    required this.range,
    this.protocol = SpecifierProtocol.semver,
    this.url,
  });

  /// Name as it appears in `package.json` — also the directory name under
  /// `node_modules/<logicalName>`.
  final String logicalName;

  /// Real package name on the registry / disk.
  final String packageName;

  /// Range portion (e.g. `^1.0.0`).
  final String range;

  final SpecifierProtocol protocol;

  /// For `https:` / `git+`: the remote URL.
  final String? url;

  bool get isAlias => logicalName != packageName;

  /// Parse a `package.json` value string into a [DependencySpec].
  ///
  /// Recognized prefixes:
  /// - `npm:<name>@<range>` — alias to a different package
  /// - `https://...`        — direct tarball (kept as URL)
  /// - `git+<url>` / `github:user/repo[#ref]` — git source
  /// - `file:<path>`        — local directory
  /// - `link:<path>`        — local link (pnpm specific)
  /// - `workspace:<range>`  — workspace protocol
  /// - everything else      — npm semver range (or dist-tag like `latest`)
  factory DependencySpec.parse(String logicalName, String raw) {
    final value = raw.trim();
    if (value.startsWith('npm:')) {
      final body = value.substring(4);
      final atIndex = body.lastIndexOf('@');
      // Scoped packages start with @, so a leading @ followed by a slash is
      // part of the name. The *separator* @ comes after the slash for them.
      final separator = body.startsWith('@') ? body.indexOf('@', 1) : atIndex;
      if (separator > 0) {
        return DependencySpec(
          logicalName: logicalName,
          packageName: body.substring(0, separator),
          range: body.substring(separator + 1),
        );
      }
      return DependencySpec(
        logicalName: logicalName,
        packageName: body,
        range: 'latest',
      );
    }
    if (value.startsWith('https://') || value.startsWith('http://')) {
      return DependencySpec(
        logicalName: logicalName,
        packageName: logicalName,
        range: '*',
        protocol: SpecifierProtocol.https,
        url: value,
      );
    }
    if (value.startsWith('git+') ||
        value.startsWith('git://') ||
        value.startsWith('github:')) {
      return DependencySpec(
        logicalName: logicalName,
        packageName: logicalName,
        range: '*',
        protocol: SpecifierProtocol.git,
        url: value,
      );
    }
    if (value.startsWith('file:')) {
      return DependencySpec(
        logicalName: logicalName,
        packageName: logicalName,
        range: value.substring(5),
        protocol: SpecifierProtocol.file,
      );
    }
    if (value.startsWith('link:')) {
      return DependencySpec(
        logicalName: logicalName,
        packageName: logicalName,
        range: value.substring(5),
        protocol: SpecifierProtocol.link,
      );
    }
    if (value.startsWith('workspace:')) {
      return DependencySpec(
        logicalName: logicalName,
        packageName: logicalName,
        range: value.substring(10),
        protocol: SpecifierProtocol.workspace,
      );
    }
    return DependencySpec(
      logicalName: logicalName,
      packageName: logicalName,
      range: value.isEmpty ? '*' : value,
    );
  }
}

/// Supported specifier protocols.
enum SpecifierProtocol { semver, workspace, file, link, https, git }

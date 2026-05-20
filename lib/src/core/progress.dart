
/// Discrete progress events emitted during an install.
sealed class ProgressEvent {
  const ProgressEvent();
}

/// Resolution phase started.
final class ResolutionStarted extends ProgressEvent {
  const ResolutionStarted();
}

/// Resolution finished — [resolved] packages will be installed.
final class ResolutionCompleted extends ProgressEvent {
  const ResolutionCompleted({required this.resolved, required this.elapsed});
  final int resolved;
  final Duration elapsed;
}

/// A tarball is being downloaded.
final class TarballFetchStarted extends ProgressEvent {
  const TarballFetchStarted({required this.package, required this.version});
  final String package;
  final String version;
}

/// Tarball download progress (bytes-level).
final class TarballFetchProgress extends ProgressEvent {
  const TarballFetchProgress({
    required this.package,
    required this.version,
    required this.downloaded,
    required this.total,
  });
  final String package;
  final String version;
  final int downloaded;
  final int? total;
}

/// Tarball download completed.
final class TarballFetched extends ProgressEvent {
  const TarballFetched({required this.package, required this.version});
  final String package;
  final String version;
}

/// Extraction completed — tarball is now in the store.
final class TarballExtracted extends ProgressEvent {
  const TarballExtracted({required this.package, required this.version});
  final String package;
  final String version;
}

/// Linker has materialized [package]@[version] into a `node_modules` tree.
final class PackageLinked extends ProgressEvent {
  const PackageLinked({required this.package, required this.version});
  final String package;
  final String version;
}

/// Running a lifecycle script.
final class ScriptStarted extends ProgressEvent {
  const ScriptStarted({required this.package, required this.event});
  final String package;
  final String event;
}

/// Lifecycle script finished.
final class ScriptCompleted extends ProgressEvent {
  const ScriptCompleted({
    required this.package,
    required this.event,
    required this.exitCode,
  });
  final String package;
  final String event;
  final int exitCode;
}

/// Final summary at end of install.
final class InstallSummary extends ProgressEvent {
  const InstallSummary({
    required this.added,
    required this.removed,
    required this.elapsed,
  });
  final int added;
  final int removed;
  final Duration elapsed;
}

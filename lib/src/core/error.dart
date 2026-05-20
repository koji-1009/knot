/// Base class for all errors raised by knot.
sealed class KnotError implements Exception {
  const KnotError(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() {
    final base = '$runtimeType: $message';
    return cause == null ? base : '$base (cause: $cause)';
  }
}

/// Network-level failures: DNS, TLS, connect, timeout, non-2xx HTTP.
final class NetworkError extends KnotError {
  const NetworkError(super.message, {super.cause, this.statusCode, this.uri});

  final int? statusCode;
  final Uri? uri;
}

/// Tarball integrity check or sha512 mismatch.
final class IntegrityError extends KnotError {
  const IntegrityError(
    super.message, {
    super.cause,
    this.expected,
    this.actual,
  });

  final String? expected;
  final String? actual;
}

/// Version solver could not find a valid assignment.
final class ResolutionError extends KnotError {
  const ResolutionError(super.message, {super.cause, this.explanation});

  /// Pubgrub-style human-readable explanation of the conflict.
  final String? explanation;
}

/// Disk I/O failures: permissions, ENOSPC, EXDEV, etc.
final class IoError extends KnotError {
  const IoError(super.message, {super.cause, this.path});
  final String? path;
}

/// Lockfile schema, parse, or round-trip failures.
final class LockfileError extends KnotError {
  const LockfileError(super.message, {super.cause, this.path});
  final String? path;
}

/// Misuse of the CLI or invalid configuration.
final class UsageError extends KnotError {
  const UsageError(super.message, {super.cause});
}

/// Lifecycle script execution failed (non-zero exit, timeout).
final class ScriptError extends KnotError {
  const ScriptError(super.message, {super.cause, this.script, this.exitCode});

  final String? script;
  final int? exitCode;
}

/// Operation cancelled by user or upstream.
final class CancelledError extends KnotError {
  const CancelledError([super.message = 'operation cancelled']);
}

/// Cryptographic signature enforcement levels for `knot install`.
///
/// The registry attaches ECDSA P-256 signatures to every published
/// tarball via `dist.signatures`. They authenticate the tuple
/// `<name>@<version>:<integrity>` against the registry's signing key
/// — *not* the package author. Verifying them defends against
/// registry compromise and man-in-the-middle attacks on installs.
enum SignaturePolicy {
  /// Skip signature verification entirely.
  none,

  /// Verify the signature when one is present; ignore absence. Lets
  /// users protect against tampered tarballs without breaking on
  /// older versions that predate registry signing.
  weak,

  /// Require a valid signature on every tarball. Missing or
  /// mismatched signatures fail the install. Suitable for CI / locked
  /// supply-chain workflows.
  strict,
}

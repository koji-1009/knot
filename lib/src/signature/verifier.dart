import 'dart:convert';
import 'dart:typed_data';

import 'package:boringssl_dart/boringssl_dart.dart';
import 'package:knot/src/core/core.dart';
import 'package:knot/src/registry/registry.dart';

import 'der_signature.dart';
import 'key_store.dart';
import 'policy.dart';

/// What [SignatureVerifier.verify] decided about one tarball.
enum SignatureOutcome {
  /// At least one attached signature matched a known *non-expired*
  /// registry key and verified successfully.
  verified,

  /// At least one signature verified, but against an **expired** key.
  /// The cryptographic proof is still valid — the registry just
  /// stopped using that key for new signatures. Treat as a success
  /// under `SignaturePolicy.weak` and a failure under `strict`.
  verifiedExpired,

  /// The tarball had no `dist.signatures`. Whether that's an error
  /// depends on the [SignaturePolicy] the caller passed.
  missing,

  /// A signature was attached but failed verification (unknown
  /// `keyid`, signature didn't match the body, malformed DER, etc.).
  failed,
}

class SignatureCheck {
  SignatureCheck({required this.outcome, this.reason});
  final SignatureOutcome outcome;
  final String? reason;
}

/// Verifies registry-attached ECDSA P-256 signatures against the
/// public keys at `<registry>/-/npm/v1/keys`.
///
/// The signed message is `<name>@<version>:<integrity>` — exactly the
/// tuple the lockfile pins. A verified signature therefore certifies
/// that the registry's signing key was applied to the same content
/// hash we're about to extract, so a malicious mirror can't hand us
/// a different tarball with the same name and version.
class SignatureVerifier {
  /// [keyStoreFor] resolves the right [RegistryKeyStore] for a given
  /// package name — scoped packages (`@private/foo`) may live on a
  /// different registry than the default, each with its own keys.
  SignatureVerifier({required this.keyStoreFor});

  final RegistryKeyStore Function(String packageName) keyStoreFor;

  /// Verify [signatures] against the canonical message
  /// `name@version:integrity`. Returns a [SignatureCheck] describing
  /// the outcome; *interpretation* (strict vs weak) is left to the
  /// caller.
  Future<SignatureCheck> verify({
    required String name,
    required String version,
    required String integrity,
    required List<DistSignature> signatures,
  }) async {
    if (signatures.isEmpty) {
      return SignatureCheck(
        outcome: SignatureOutcome.missing,
        reason: 'no dist.signatures attached',
      );
    }
    final keys = await keyStoreFor(name).keys();
    final message = utf8.encode('$name@$version:$integrity');

    final reasons = <String>[];
    String? expiredKeyReason;
    for (final entry in signatures) {
      final key = keys[entry.keyid];
      if (key == null) {
        reasons.add('unknown keyid ${entry.keyid}');
        continue;
      }
      final Uint8List derSig;
      try {
        derSig = base64.decode(entry.sig);
      } on FormatException {
        reasons.add('keyid ${entry.keyid}: signature is not valid base64');
        continue;
      }
      final raw = derEcdsaSignatureToRaw(derSig, curveByteSize: 32);
      if (raw == null) {
        reasons.add('keyid ${entry.keyid}: malformed DER ECDSA signature');
        continue;
      }
      final ok = Ecdsa.verify(key.ecKey, raw, message, 'SHA-256');
      if (!ok) {
        reasons.add(
          'keyid ${entry.keyid}: signature did not verify against '
          '$name@$version:$integrity',
        );
        continue;
      }
      // Crypto verified. If the key is expired, remember it but keep
      // looking — a non-expired sibling signature would still trump.
      // npm leaves old keys in `/-/npm/v1/keys` after rotation so
      // legacy tarballs can still be verified; rejecting outright on
      // expiration would break installs of any package signed before
      // the most recent rotation.
      if (key.isExpired) {
        expiredKeyReason ??=
            'keyid ${entry.keyid} verified but key expired ${key.expires}';
        continue;
      }
      return SignatureCheck(outcome: SignatureOutcome.verified);
    }

    if (expiredKeyReason != null) {
      return SignatureCheck(
        outcome: SignatureOutcome.verifiedExpired,
        reason: expiredKeyReason,
      );
    }
    return SignatureCheck(
      outcome: SignatureOutcome.failed,
      reason: reasons.join('; '),
    );
  }

  /// Convenience helper that applies [policy] to a verification
  /// outcome and either returns cleanly or throws an [IntegrityError]
  /// the install path can surface to the user.
  ///
  /// Returns an optional warning string for the caller to log when
  /// the install proceeds despite a non-ideal outcome (typically
  /// `verifiedExpired` under `weak` policy).
  String? enforce({
    required SignaturePolicy policy,
    required String name,
    required String version,
    required SignatureCheck result,
  }) {
    if (policy == SignaturePolicy.none) return null;
    switch (result.outcome) {
      case SignatureOutcome.verified:
        return null;
      case SignatureOutcome.verifiedExpired:
        if (policy == SignaturePolicy.strict) {
          throw IntegrityError(
            '$name@$version: --verify-signatures=strict and '
            '${result.reason ?? 'signing key has expired'}',
          );
        }
        return '$name@$version: ${result.reason ?? 'signed with expired key'}';
      case SignatureOutcome.missing:
        if (policy == SignaturePolicy.strict) {
          throw IntegrityError(
            '$name@$version: --verify-signatures=strict but no '
            'dist.signatures was attached',
          );
        }
        return null;
      case SignatureOutcome.failed:
        throw IntegrityError(
          '$name@$version: signature check failed '
          '(${result.reason ?? 'no detail'})',
        );
    }
  }
}

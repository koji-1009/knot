import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:boringssl_dart/boringssl_dart.dart';
import 'package:http/http.dart' as http;
import 'package:knot/src/core/core.dart';
import 'package:path/path.dart' as p;

/// One npm registry signing key.
///
/// The registry advertises `keyid` and `scheme` alongside the key
/// material; we only carry the parsed public key + expiry through to
/// verification (the keyid is the map index and the scheme has
/// already been filtered by [RegistryKeyStore]).
class RegistryKey {
  RegistryKey({required this.ecKey, required this.expires});
  final EcKey ecKey;
  final DateTime? expires;

  bool get isExpired {
    final e = expires;
    return e != null && DateTime.now().toUtc().isAfter(e);
  }
}

/// Caches the public keys the registry uses to sign tarballs.
///
/// The registry exposes `GET /-/npm/v1/keys` which returns a JSON
/// object with a `keys` array of `{keyid, key, scheme, expires}`.
/// `key` is the base64-encoded SPKI of an ECDSA P-256 public key
/// (when `scheme == "ecdsa-sha2-nistp256"`).
///
/// Two-tier caching:
/// 1. In-process map per [RegistryKeyStore] instance (lifetime of
///    the install).
/// 2. On-disk JSON at `<cacheDir>/keys/<host>.json` when [cacheDir]
///    is supplied — survives across installs so warm invocations
///    skip the ~80 ms HTTP round-trip to the registry.
class RegistryKeyStore {
  RegistryKeyStore({
    required this.client,
    required this.registry,
    Map<String, String> Function(Uri)? authHeadersFor,
    this.cacheDir,
    this._cacheTtl = const Duration(hours: 24),
  }) : _authHeadersFor = authHeadersFor ?? ((_) => const {});

  final http.Client client;

  /// Registry root (e.g. `https://registry.npmjs.org/`).
  final Uri registry;

  /// On-disk cache root (typically `~/.knot/cache`). When null, only
  /// the in-process cache is used.
  final String? cacheDir;
  final Duration _cacheTtl;

  final Map<String, String> Function(Uri) _authHeadersFor;

  Future<Map<String, RegistryKey>>? _inflight;
  Map<String, RegistryKey>? _keys;

  /// Returns the cached key set, fetching it on the first call.
  Future<Map<String, RegistryKey>> keys() {
    final cached = _keys;
    if (cached != null) return Future.value(cached);
    final inflight = _inflight;
    if (inflight != null) return inflight;
    final future = _load();
    _inflight = future;
    return future.whenComplete(() => _inflight = null);
  }

  Future<Map<String, RegistryKey>> _load() async {
    // 1) Try the on-disk JSON.
    final diskBody = await _readDisk();
    if (diskBody != null) {
      try {
        final parsed = _parseKeys(diskBody, source: 'cache');
        _keys = parsed;
        return parsed;
      } on Object {
        // Cache corrupted — fall through to a network fetch.
      }
    }

    // 2) Network. On success, persist to disk for the next process.
    final uri = registry.resolve('-/npm/v1/keys');
    final response = await client.get(uri, headers: _authHeadersFor(uri));
    if (response.statusCode >= 400) {
      throw NetworkError(
        'failed to fetch registry signing keys '
        '(HTTP ${response.statusCode})',
        statusCode: response.statusCode,
        uri: uri,
      );
    }
    final parsed = _parseKeys(response.body, source: 'network');
    await _writeDisk(response.body);
    _keys = parsed;
    return parsed;
  }

  Map<String, RegistryKey> _parseKeys(String body, {required String source}) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw NetworkError(
        'keys endpoint returned non-object ($source)',
        uri: registry,
      );
    }
    final rawKeys = decoded['keys'];
    if (rawKeys is! List) {
      throw NetworkError(
        'keys endpoint returned no `keys` array ($source)',
        uri: registry,
      );
    }
    final out = <String, RegistryKey>{};
    for (final raw in rawKeys) {
      if (raw is! Map) continue;
      final keyid = raw['keyid'] as String?;
      final scheme = raw['scheme'] as String?;
      final keyBase64 = raw['key'] as String?;
      if (keyid == null || scheme == null || keyBase64 == null) continue;
      // The registry currently signs with ECDSA P-256. Refuse other
      // schemes so a future addition doesn't silently degrade
      // verification — we'd rather error visibly than wave it through.
      if (scheme != 'ecdsa-sha2-nistp256') continue;
      // base64.decode normally returns a Uint8List, but its concrete
      // shape (typed-data view vs heap-allocated list) has tripped
      // up FFI marshalling on AOT builds in the past. Eagerly copy
      // into a fresh contiguous Uint8List to side-step that.
      final spki = Uint8List.fromList(base64.decode(keyBase64));
      final EcKey ecKey;
      try {
        ecKey = EcKey.importSpki(spki, 'P-256');
      } on Object catch (e) {
        // Skip unparseable keys rather than aborting the whole audit
        // — a single garbled entry shouldn't disable verification
        // for every other key in the set.
        // ignore: avoid_print
        print('warning: skipped unparseable registry key $keyid: $e');
        continue;
      }
      final expiresRaw = raw['expires'] as String?;
      out[keyid] = RegistryKey(
        ecKey: ecKey,
        expires: expiresRaw == null ? null : DateTime.tryParse(expiresRaw),
      );
    }
    return out;
  }

  /// Read the disk-cached body when it exists and is fresh.
  Future<String?> _readDisk() async {
    final dir = cacheDir;
    if (dir == null) return null;
    final file = File(_diskPath(dir));
    if (!await file.exists()) return null;
    final stat = await file.stat();
    final age = DateTime.now().difference(stat.modified);
    if (age > _cacheTtl) return null;
    try {
      return await file.readAsString();
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _writeDisk(String body) async {
    final dir = cacheDir;
    if (dir == null) return;
    final path = _diskPath(dir);
    try {
      await Directory(p.dirname(path)).create(recursive: true);
      await File(path).writeAsString(body, flush: true);
    } on FileSystemException {
      // Best-effort: a broken cache write shouldn't fail the verify.
    }
  }

  String _diskPath(String root) =>
      p.join(root, 'keys', '${registry.host}.json');
}

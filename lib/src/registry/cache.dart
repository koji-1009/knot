import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'packument.dart';
import 'packument_codec.dart';

/// On-disk persistent cache for packuments and raw tarball bytes.
///
/// Layout:
/// - `<root>/packuments/<safe-name>.kpack`       — slim packument, binary
///                                                  (meta folded in)
/// - `<root>/packuments/<safe-name>.json`        — legacy slim JSON (read
///                                                  for back-compat only)
/// - `<root>/packuments/<safe-name>.meta.json`   — legacy etag / freshUntil
/// - `<root>/tarballs/<sha512>.tgz`              — verified tarball bytes
///
/// Only the fields the resolver and linker consume are stored, not the
/// verbatim registry response (npm packuments carry multi-MB readme /
/// contributor blobs the resolver never reads). The `.kpack` binary form
/// (see `packument_codec.dart`) decodes ~10× faster than `jsonDecode` of
/// the equivalent JSON — the dominant cost of a warm-cache resolve — and
/// is ~2.6× smaller on disk. Old `.json` entries are still read so an
/// upgrade keeps working offline; the next network fetch rewrites the
/// entry as `.kpack`.
class RegistryCache {
  RegistryCache({required this.root});

  /// Cache root directory. Typically `~/.knot/cache`.
  final String root;

  String _packumentDir() => p.join(root, 'packuments');
  String _tarballDir() => p.join(root, 'tarballs');

  String _packumentBinPath(String name) =>
      p.join(_packumentDir(), '${_safeName(name)}.kpack');

  String _packumentPath(String name) =>
      p.join(_packumentDir(), '${_safeName(name)}.json');

  String _packumentMetaPath(String name) =>
      p.join(_packumentDir(), '${_safeName(name)}.meta.json');

  String _tarballPath(String sha512) => p.join(_tarballDir(), '$sha512.tgz');

  Future<void> initialize() async {
    await Directory(_packumentDir()).create(recursive: true);
    await Directory(_tarballDir()).create(recursive: true);
  }

  // --- packument layer ---------------------------------------------------

  /// Load a cached packument with its revalidation metadata, if present.
  ///
  /// Returns `null` on any read or parse failure — a malformed cache
  /// entry is treated as a miss so the caller falls through to network.
  Future<CachedPackumentBlob?> readPackument(String name) async {
    // Fast path: the binary `.kpack` entry.
    final binFile = File(_packumentBinPath(name));
    if (await binFile.exists()) {
      try {
        final blob = decodePackumentBlob(await binFile.readAsBytes());
        if (blob != null) {
          return CachedPackumentBlob(
            packument: blob.packument,
            etag: blob.etag,
            lastModified: blob.lastModified,
            freshUntil: blob.freshUntil,
          );
        }
        // Corrupt/unknown-version `.kpack` → fall through to legacy/miss.
      } on FileSystemException {
        // fall through
      }
    }
    return _readLegacyJson(name);
  }

  /// Read a pre-`.kpack` JSON cache entry (+ its sidecar meta). Kept so an
  /// upgrade does not force an offline re-fetch of every cached package;
  /// the next online fetch rewrites the entry as `.kpack`.
  Future<CachedPackumentBlob?> _readLegacyJson(String name) async {
    final file = File(_packumentPath(name));
    if (!await file.exists()) return null;
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } on FileSystemException {
      return null;
    }
    final Object? json;
    try {
      json = packumentJsonDecoder.convert(bytes);
    } on FormatException {
      return null;
    }
    if (json is! Map) return null;
    final meta = await _readMeta(name);
    final freshUntilRaw = meta?['freshUntil'] as String?;
    return CachedPackumentBlob(
      packument: Packument.fromJson(Map<String, dynamic>.from(json)),
      etag: meta?['etag'] as String?,
      lastModified: meta?['lastModified'] as String?,
      freshUntil: freshUntilRaw == null
          ? null
          : DateTime.tryParse(freshUntilRaw),
    );
  }

  /// Write the slim form of [packument] to disk in the binary `.kpack`
  /// format (revalidation metadata folded in — see `packument_codec.dart`).
  ///
  /// [freshUntil] records the moment the response stops being usable
  /// without revalidation, derived from `Cache-Control: max-age` per
  /// RFC 7234. While it's in the future, callers can return the
  /// cached body without contacting the registry — npm's packument
  /// responses currently advertise `max-age=300`.
  Future<void> writePackument({
    required Packument packument,
    String? etag,
    String? lastModified,
    DateTime? freshUntil,
  }) async {
    final file = File(_packumentBinPath(packument.name));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(
      encodePackumentBlob(
        packument: packument,
        etag: etag,
        lastModified: lastModified,
        freshUntil: freshUntil,
      ),
      flush: true,
    );
  }

  Future<Map<String, dynamic>?> _readMeta(String name) async {
    final file = File(_packumentMetaPath(name));
    if (!await file.exists()) return null;
    try {
      final json = jsonDecode(await file.readAsString());
      return json is Map ? Map<String, dynamic>.from(json) : null;
    } on FormatException {
      return null;
    }
  }

  // --- tarball layer -----------------------------------------------------

  Future<Uint8List?> readTarball(String integrity) async {
    final file = File(_tarballPath(_normalizeIntegrity(integrity)));
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  Future<void> writeTarball({
    required String integrity,
    required Uint8List bytes,
  }) async {
    final file = File(_tarballPath(_normalizeIntegrity(integrity)));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  static String _safeName(String name) => name.replaceAll('/', '+');

  static String _normalizeIntegrity(String integrity) {
    // Strip the `sha512-` prefix from an SRI string; pass a bare hex
    // digest through unchanged. The body is base64 — map the three
    // characters that aren't filename-safe on POSIX/Windows
    // (`/`, `+`, `=`) to a safe alphabet.
    final dash = integrity.indexOf('-');
    final start = dash > 0 ? dash + 1 : 0;
    final buf = StringBuffer();
    for (var i = start; i < integrity.length; i++) {
      final c = integrity.codeUnitAt(i);
      switch (c) {
        case 0x2f: // '/'
          buf.writeCharCode(0x5f); // '_'
        case 0x2b: // '+'
          buf.writeCharCode(0x2d); // '-'
        case 0x3d: // '='
          break;
        default:
          buf.writeCharCode(c);
      }
    }
    return buf.toString();
  }
}

class CachedPackumentBlob {
  CachedPackumentBlob({
    required this.packument,
    this.etag,
    this.lastModified,
    this.freshUntil,
  });
  final Packument packument;
  final String? etag;
  final String? lastModified;

  /// Wall-clock time at which this cached body stops being usable
  /// without registry revalidation. `null` means "always revalidate".
  final DateTime? freshUntil;
}

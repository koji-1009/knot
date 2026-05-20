import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'packument.dart';

/// On-disk persistent cache for packuments and raw tarball bytes.
///
/// Layout:
/// - `<root>/packuments/<safe-name>.json`        — slim packument JSON
/// - `<root>/packuments/<safe-name>.meta.json`   — etag, last-modified,
///                                                  freshUntil
/// - `<root>/tarballs/<sha512>.tgz`              — verified tarball bytes
///
/// The packument disk format is the slim `Packument.toJson()` output, not
/// the verbatim registry response. npm packuments include the full version
/// history with multi-megabyte readme / contributor blobs that the
/// resolver never reads; serializing only the fields we use cuts disk
/// size by ~50x and JSON parse time on warm installs proportionally.
class RegistryCache {
  RegistryCache({required this.root});

  /// Cache root directory. Typically `~/.knot/cache`.
  final String root;

  String _packumentDir() => p.join(root, 'packuments');
  String _tarballDir() => p.join(root, 'tarballs');

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
    final file = File(_packumentPath(name));
    if (!await file.exists()) return null;
    final String body;
    try {
      body = await file.readAsString();
    } on FileSystemException {
      return null;
    }
    final Object? json;
    try {
      json = jsonDecode(body);
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

  /// Write the slim form of [packument] to disk along with revalidation
  /// metadata. The disk format must be compatible with
  /// [Packument.fromJson] — see [Packument.toJson].
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
    final file = File(_packumentPath(packument.name));
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(packument.toJson()));
    await _writeMeta(packument.name, {
      'etag': ?etag,
      'lastModified': ?lastModified,
      'freshUntil': ?freshUntil?.toUtc().toIso8601String(),
    });
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

  Future<void> _writeMeta(String name, Map<String, dynamic> meta) async {
    if (meta.isEmpty) return;
    final file = File(_packumentMetaPath(name));
    await file.parent.create(recursive: true);
    await file.writeAsString(const JsonEncoder().convert(meta));
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

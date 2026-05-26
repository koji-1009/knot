import 'dart:convert';
import 'dart:typed_data';

import 'packument.dart';

/// Compact binary on-disk format for cached packuments (`.kpack`).
///
/// The cache previously stored the slim packument as JSON. `jsonDecode`
/// of a multi-MB packument (react ships ~2800 versions) dominated the
/// warm-cache resolve path at ~20 ms; decoding the same data from this
/// length-prefixed binary layout is ~1.8 ms (measured, >10×) and the file
/// is ~2.6× smaller. The format carries exactly the fields the slim JSON
/// did, so a round-trip is byte-equivalent in meaning to the JSON one.
///
/// Layout (all integers unsigned LEB128 varints; strings are
/// `varint(byteLen) + UTF-8 bytes`; optional strings use
/// `varint(0)=null`, else `varint(len+1) + bytes`):
///
/// ```
/// magic   : 1 byte  (0x6B = 'k')
/// version : 1 byte  (format version; bump to invalidate old files)
/// etag         : optString
/// lastModified : optString
/// freshUntil   : optString  (ISO-8601 UTC, or null)
/// name      : string
/// distTags  : map
/// times     : map  (version -> ISO-8601)
/// versions  : varint count, then per version: <see _writeVersion>
/// ```
const int _magic = 0x6b; // 'k'
const int _version = 1;

/// One decoded cache entry: the packument plus its revalidation metadata.
typedef PackumentBlob = ({
  Packument packument,
  String? etag,
  String? lastModified,
  DateTime? freshUntil,
});

/// Serialize [packument] and its revalidation metadata to the `.kpack`
/// binary format.
Uint8List encodePackumentBlob({
  required Packument packument,
  String? etag,
  String? lastModified,
  DateTime? freshUntil,
}) {
  final w = _Writer()
    ..byte(_magic)
    ..byte(_version)
    ..optStr(etag)
    ..optStr(lastModified)
    ..optStr(freshUntil?.toUtc().toIso8601String())
    ..str(packument.name)
    ..map(packument.distTags)
    ..map({
      for (final e in packument.publishTimes.entries)
        e.key: e.value.toUtc().toIso8601String(),
    });
  w.varint(packument.versions.length);
  for (final entry in packument.versions.entries) {
    _writeVersion(w, entry.key, entry.value);
  }
  return w.takeBytes();
}

/// Decode a `.kpack` blob, or `null` when the bytes are not a `.kpack`
/// of a supported version or are truncated/corrupt (treated as a cache
/// miss by the caller).
PackumentBlob? decodePackumentBlob(Uint8List bytes) {
  try {
    final r = _Reader(bytes);
    if (r.byte() != _magic || r.byte() != _version) return null;
    final etag = r.optStr();
    final lastModified = r.optStr();
    final freshUntilRaw = r.optStr();
    final name = r.str();
    final distTags = r.map();
    final times = <String, DateTime>{};
    final rawTimes = r.map();
    for (final e in rawTimes.entries) {
      final dt = DateTime.tryParse(e.value);
      if (dt != null) times[e.key] = dt;
    }
    final count = r.varint();
    final versions = <String, PackumentVersion>{};
    for (var i = 0; i < count; i++) {
      final (key, slice) = _readVersion(r);
      versions[key] = slice;
    }
    if (!r.atEnd) return null; // trailing garbage → treat as corrupt
    return (
      packument: Packument(
        name: name,
        versions: versions,
        distTags: distTags,
        publishTimes: times,
      ),
      etag: etag,
      lastModified: lastModified,
      freshUntil: freshUntilRaw == null
          ? null
          : DateTime.tryParse(freshUntilRaw),
    );
  } on Object {
    // Any malformed entry is a miss, not a crash — the caller re-fetches.
    return null;
  }
}

void _writeVersion(_Writer w, String key, PackumentVersion v) {
  w
    ..str(key)
    ..str(v.name)
    ..str(v.version)
    ..optStr(v.tarball)
    ..optStr(v.integrity)
    ..optStr(v.deprecated)
    ..boolean(v.hasInstallScript)
    ..map(v.dependencies)
    ..map(v.optionalDependencies)
    ..map(v.peerDependencies)
    ..stringList(v.optionalPeers.toList())
    ..stringList(v.os)
    ..stringList(v.cpu)
    ..stringList(v.libc)
    ..map(v.bin)
    ..map(v.scripts)
    ..map(v.engines)
    ..stringList(v.bundledDependencies);
  w.varint(v.signatures.length);
  for (final s in v.signatures) {
    w
      ..str(s.keyid)
      ..str(s.sig);
  }
}

(String, PackumentVersion) _readVersion(_Reader r) {
  final key = r.str();
  final name = r.str();
  final version = r.str();
  final tarball = r.optStr();
  final integrity = r.optStr();
  final deprecated = r.optStr();
  final hasInstallScript = r.boolean();
  final dependencies = r.map();
  final optionalDependencies = r.map();
  final peerDependencies = r.map();
  final optionalPeers = r.stringList().toSet();
  final os = r.stringList();
  final cpu = r.stringList();
  final libc = r.stringList();
  final bin = r.map();
  final scripts = r.map();
  final engines = r.map();
  final bundledDependencies = r.stringList();
  final sigCount = r.varint();
  final signatures = <DistSignature>[];
  for (var i = 0; i < sigCount; i++) {
    signatures.add(DistSignature(keyid: r.str(), sig: r.str()));
  }
  return (
    key,
    PackumentVersion(
      name: name,
      version: version,
      tarball: tarball,
      integrity: integrity,
      dependencies: dependencies,
      optionalDependencies: optionalDependencies,
      peerDependencies: peerDependencies,
      optionalPeers: optionalPeers,
      os: os,
      cpu: cpu,
      libc: libc,
      deprecated: deprecated,
      // Mirrors `fromJson`: a non-empty bin map implies the version
      // declared bins. (The slim format never stored the original
      // `bin == null` vs `bin == {}` distinction either.)
      hasBin: bin.isNotEmpty,
      bin: bin,
      scripts: scripts,
      engines: engines,
      bundledDependencies: bundledDependencies,
      hasInstallScript: hasInstallScript,
      signatures: signatures,
    ),
  );
}

class _Writer {
  final BytesBuilder _b = BytesBuilder(copy: false);

  void byte(int v) => _b.addByte(v);

  void boolean(bool v) => _b.addByte(v ? 1 : 0);

  void varint(int v) {
    var x = v;
    while (x >= 0x80) {
      _b.addByte((x & 0x7f) | 0x80);
      x >>= 7;
    }
    _b.addByte(x);
  }

  void str(String s) {
    final bytes = utf8.encode(s);
    varint(bytes.length);
    _b.add(bytes);
  }

  void optStr(String? s) {
    if (s == null) {
      varint(0);
      return;
    }
    final bytes = utf8.encode(s);
    varint(bytes.length + 1);
    _b.add(bytes);
  }

  void map(Map<String, String> m) {
    varint(m.length);
    for (final e in m.entries) {
      str(e.key);
      str(e.value);
    }
  }

  void stringList(List<String> l) {
    varint(l.length);
    for (final s in l) {
      str(s);
    }
  }

  Uint8List takeBytes() => _b.takeBytes();
}

class _Reader {
  _Reader(this._d);

  final Uint8List _d;
  int _p = 0;
  static const Utf8Decoder _utf8 = Utf8Decoder();

  bool get atEnd => _p == _d.length;

  int byte() => _d[_p++];

  bool boolean() => _d[_p++] != 0;

  int varint() {
    var x = 0, shift = 0;
    while (true) {
      final c = _d[_p++];
      x |= (c & 0x7f) << shift;
      if (c < 0x80) return x;
      shift += 7;
    }
  }

  String str() {
    final n = varint();
    final start = _p;
    _p += n;
    // Decode straight off the backing buffer (no sublist allocation).
    return _utf8.convert(_d, start, _p);
  }

  String? optStr() {
    final n = varint();
    if (n == 0) return null;
    final len = n - 1;
    final start = _p;
    _p += len;
    return _utf8.convert(_d, start, _p);
  }

  Map<String, String> map() {
    final n = varint();
    if (n == 0) return const {};
    final out = <String, String>{};
    for (var i = 0; i < n; i++) {
      out[str()] = str();
    }
    return out;
  }

  List<String> stringList() {
    final n = varint();
    if (n == 0) return const [];
    return [for (var i = 0; i < n; i++) str()];
  }
}

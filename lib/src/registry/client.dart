import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, Platform;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as http;
import 'package:knot/src/core/core.dart';
import 'package:knot/src/npmrc/npmrc.dart';
import 'package:knot/src/signature/signature.dart' as sig;
import 'package:pool/pool.dart';

import 'cache.dart';
import 'integrity.dart';
import 'packument.dart';

/// A cached packument with the ETag/Last-Modified server returned and
/// (when known) the deadline beyond which a revalidation is required.
class CachedPackument {
  CachedPackument({
    required this.packument,
    this.etag,
    this.lastModified,
    this.freshUntil,
  });
  final Packument packument;
  String? etag;
  String? lastModified;

  /// Wall-clock time at which this cached body must be revalidated
  /// (derived from `Cache-Control: max-age`). `null` means the
  /// freshness window is unknown — always revalidate.
  DateTime? freshUntil;

  bool get isFresh {
    final d = freshUntil;
    return d != null && DateTime.now().toUtc().isBefore(d);
  }
}

/// Parse `Cache-Control: max-age=N` from [headers] and return the
/// resulting freshness deadline. Returns `null` when the header is
/// missing, contains `no-cache`/`no-store`, or has no usable `max-age`.
DateTime? _freshUntilFromHeaders(Map<String, String> headers) {
  final cc = headers['cache-control'];
  if (cc == null) return null;
  // Lowercase for case-insensitive directive matching.
  final lower = cc.toLowerCase();
  if (lower.contains('no-cache') || lower.contains('no-store')) {
    return null;
  }
  final match = RegExp(r'max-age\s*=\s*(\d+)').firstMatch(lower);
  if (match == null) return null;
  final seconds = int.tryParse(match.group(1)!);
  if (seconds == null || seconds <= 0) return null;
  return DateTime.now().toUtc().add(Duration(seconds: seconds));
}

/// npm registry client. Implements packument fetch with ETag revalidation
/// and tarball fetch with sha512 integrity verification.
class RegistryClient {
  RegistryClient({
    required this.config,
    http.Client? client,
    int concurrency = 64,
    this.userAgent = 'knot/0.0.0',
    this.cache,
    this.offline = false,
    this.preferOffline = false,
  }) : _client = client ?? _buildClient(concurrency),
       _pool = Pool(concurrency);

  /// Build an HTTP client tuned for high-concurrency registry access.
  ///
  /// `dart:io`'s `HttpClient` with `maxConnectionsPerHost = $concurrency`
  /// (default cap is 6, which serializes parallel fetches and dominates
  /// install time).
  static http.Client _buildClient(int concurrency) {
    final io = HttpClient()
      ..maxConnectionsPerHost = concurrency
      ..idleTimeout = const Duration(seconds: 30);
    return http.IOClient(io);
  }

  final NpmrcConfig config;
  final http.Client _client;
  final Pool _pool;
  final String userAgent;

  /// Optional persistent on-disk cache. When set, packuments and tarballs
  /// are written there and consulted on subsequent runs.
  final RegistryCache? cache;

  /// Forbid network access; cache miss → fail.
  final bool offline;

  /// Prefer cached values over network round-trips.
  final bool preferOffline;

  final Map<String, CachedPackument> _packumentCache = {};
  final Map<Uri, sig.RegistryKeyStore> _keyStoresByRegistry = {};

  /// Lazily build (and cache) a [sig.RegistryKeyStore] that talks to
  /// the same registry as `name`. The store fetches `/-/npm/v1/keys`
  /// once per process and reuses the result across every signature
  /// verification for tarballs from that registry.
  sig.RegistryKeyStore keyStoreFor(String name) {
    final registry = _registryForName(name);
    return _keyStoresByRegistry.putIfAbsent(
      registry,
      () => sig.RegistryKeyStore(
        client: _client,
        registry: registry,
        authHeadersFor: _authHeaders,
        cacheDir: cache?.root,
      ),
    );
  }

  /// Profile counters (KNOT_PROFILE=1).
  int packumentInProcessHits = 0;
  int packumentDiskHits = 0;
  int packumentNetworkFetches = 0;
  int packument304s = 0;
  int packumentNetworkBytes = 0;
  int tarballCacheHits = 0;
  int tarballNetworkFetches = 0;
  int tarballNetworkBytes = 0;

  /// Close the underlying HTTP client and free pool resources.
  void close() {
    _client.close();
    _pool.close();
  }

  Uri _packumentUrl(String name) {
    final registry = _registryForName(name);
    return registry.resolve(Uri.encodeComponent(name).replaceAll('%40', '@'));
  }

  Uri _registryForName(String name) {
    if (name.startsWith('@')) {
      final slash = name.indexOf('/');
      final scope = slash > 0 ? name.substring(0, slash) : name;
      final scoped = config.registryFor(scope);
      if (scoped != null) return Uri.parse(scoped);
    }
    return Uri.parse(config.registry);
  }

  Map<String, String> _authHeaders(Uri uri) {
    final headers = <String, String>{'user-agent': userAgent};
    final token = config.authTokenFor(uri);
    if (token != null) {
      headers['authorization'] = 'Bearer $token';
      return headers;
    }
    final basic = config.basicAuthFor(uri);
    if (basic != null) {
      final encoded = base64.encode(
        utf8.encode('${basic.username}:${basic.password}'),
      );
      headers['authorization'] = 'Basic $encoded';
      return headers;
    }
    final legacy = config.legacyAuthFor(uri);
    if (legacy != null) {
      headers['authorization'] = 'Basic $legacy';
    }
    return headers;
  }

  /// Fetch [name]'s packument with ETag revalidation. Returns the cached
  /// value when the registry responds with 304.
  ///
  /// When [requirePublishTimes] is true, the request asks for the full
  /// packument (`application/json`) because the slim install-time
  /// format omits the per-version `time` map. Disk and in-process
  /// cache entries that lack publish times are treated as a miss for
  /// that call, so callers using `minimum-release-age` always get the
  /// data they need.
  Future<Packument> packument(
    String name, {
    bool requirePublishTimes = false,
  }) async {
    final uri = _packumentUrl(name);

    bool isUsable(Packument p) =>
        !requirePublishTimes || p.publishTimes.isNotEmpty;

    // 1) Fast path: in-process cache.
    final inProcess = _packumentCache[name];
    if (inProcess != null &&
        (preferOffline || inProcess.isFresh) &&
        isUsable(inProcess.packument)) {
      packumentInProcessHits++;
      return inProcess.packument;
    }

    // 2) On-disk cache.
    CachedPackumentBlob? diskHit;
    if (cache != null && inProcess == null) {
      diskHit = await cache!.readPackument(name);
      if (diskHit != null) {
        final entry = CachedPackument(
          packument: diskHit.packument,
          etag: diskHit.etag,
          lastModified: diskHit.lastModified,
          freshUntil: diskHit.freshUntil,
        );
        _packumentCache[name] = entry;
        // Honor RFC 7234 `Cache-Control: max-age` — when the registry
        // told us the body is good for N seconds and N hasn't elapsed,
        // a revalidation 304 is wire waste. npm's packument endpoint
        // currently advertises `max-age=300`, so this short-circuits
        // every cache-warm install within the freshness window.
        if ((preferOffline || offline || entry.isFresh) &&
            isUsable(diskHit.packument)) {
          packumentDiskHits++;
          return diskHit.packument;
        }
      }
    }

    if (offline) {
      throw NetworkError('--offline: no cached packument for $name', uri: uri);
    }

    return _pool.withResource(() async {
      // The loop runs at most twice: once for the conditional GET,
      // and once more if the 304 response was unusable because the
      // caller needs publish times that the cached body lacks. In
      // that second pass conditional headers have been cleared and we
      // ask for a full body. Transient 429/5xx are NOT retried here —
      // knot's cache makes a rerun cheap, and CI step retries cover
      // the rest.
      for (var attempt = 0; attempt < 2; attempt++) {
        final cached = _packumentCache[name];
        final headers = {
          ..._authHeaders(uri),
          // Full packument when we need `time`; slim by default.
          'accept': requirePublishTimes
              ? 'application/json'
              : 'application/vnd.npm.install-v1+json;q=1.0, '
                    'application/json;q=0.5',
        };
        if (cached?.etag != null) {
          headers['if-none-match'] = cached!.etag!;
        }
        if (cached?.lastModified != null) {
          headers['if-modified-since'] = cached!.lastModified!;
        }
        packumentNetworkFetches++;
        // ignore: avoid_print
        if (Platform.environment['KNOT_PROFILE_HEADERS'] == '1') {
          print(
            'GET $uri etag=${cached?.etag} '
            'ifmod=${cached?.lastModified}',
          );
        }
        final response = await _client.get(uri, headers: headers);
        if (Platform.environment['KNOT_PROFILE_HEADERS'] == '1') {
          // ignore: avoid_print
          print(
            '  ← ${response.statusCode} '
            'etag=${response.headers['etag']} '
            '${response.bodyBytes.length}B',
          );
        }
        if (response.statusCode == 304 && cached != null) {
          packument304s++;
          // If the cached body lacks the publish-times map and the
          // caller needs it, the 304 isn't usable — drop the
          // conditional headers and ask for a full body on the next
          // loop iteration.
          if (requirePublishTimes &&
              cached.packument.publishTimes.isEmpty &&
              attempt == 0) {
            cached.etag = null;
            cached.lastModified = null;
            continue;
          }
          // A 304 means "still valid" — refresh the disk freshness
          // window so future calls within `max-age` don't even
          // round-trip a 304.
          final fresh = _freshUntilFromHeaders(response.headers);
          if (fresh != null) {
            cached.freshUntil = fresh;
            if (cache != null) {
              await cache!.writePackument(
                packument: cached.packument,
                etag: cached.etag,
                lastModified: cached.lastModified,
                freshUntil: fresh,
              );
            }
          }
          return cached.packument;
        }
        packumentNetworkBytes += response.bodyBytes.length;
        if (response.statusCode == 404) {
          throw NetworkError(
            'package not found: $name',
            statusCode: 404,
            uri: uri,
          );
        }
        if (response.statusCode >= 400) {
          throw NetworkError(
            'GET $uri failed (${response.statusCode})',
            statusCode: response.statusCode,
            uri: uri,
          );
        }
        final decoded = jsonDecode(response.body);
        if (decoded is! Map) {
          throw NetworkError('packument is not a JSON object', uri: uri);
        }
        final pkg = Packument.fromJson(Map<String, dynamic>.from(decoded));
        final fresh = _freshUntilFromHeaders(response.headers);
        _packumentCache[name] = CachedPackument(
          packument: pkg,
          etag: response.headers['etag'],
          lastModified: response.headers['last-modified'],
          freshUntil: fresh,
        );
        if (cache != null) {
          await cache!.writePackument(
            packument: pkg,
            etag: response.headers['etag'],
            lastModified: response.headers['last-modified'],
            freshUntil: fresh,
          );
        }
        return pkg;
      }
      // Unreachable: the loop returns on every path.
      throw StateError('packument loop exhausted for $uri');
    });
  }

  /// Download and verify a tarball by its integrity. Returns the raw bytes.
  ///
  /// The response body is hashed through an [IncrementalHash] as it
  /// streams in, so the integrity check costs no extra pass over the
  /// buffer once the download finishes.
  Future<Uint8List> tarball({
    required String url,
    required String integrity,
  }) async {
    final uri = Uri.parse(url);
    final expected = Integrity.parse(integrity);

    // Cache hit?
    if (cache != null) {
      final cached = await cache!.readTarball(integrity);
      if (cached != null) {
        try {
          expected.verify(cached);
          tarballCacheHits++;
          return cached;
        } on Object {
          // fall through to network
        }
      }
    }

    if (offline) {
      throw NetworkError('--offline: no cached tarball for $url', uri: uri);
    }

    // Transient 429/5xx are NOT retried here — knot's tarball cache
    // makes a rerun cheap (already-downloaded packages stay in the
    // store), and CI step retries cover the rest.
    return _pool.withResource(() async {
      tarballNetworkFetches++;
      final request = http.Request('GET', uri);
      _authHeaders(uri).forEach((k, v) => request.headers[k] = v);
      final response = await _client.send(request);
      if (response.statusCode >= 400) {
        // Drain to free the socket back to the pool.
        await response.stream.drain<void>();
        throw NetworkError(
          'GET $uri failed (${response.statusCode})',
          statusCode: response.statusCode,
          uri: uri,
        );
      }
      final hasher = IncrementalHash.forAlgorithm(expected.algorithm);
      // Honor the server-declared content length when present:
      // one upfront allocation, then setRange each chunk into
      // place. The BytesBuilder path concatenates chunks at
      // takeBytes(), briefly doubling peak memory; pre-allocating
      // keeps the peak at 1x for large tarballs.
      final declared = response.contentLength;
      final Uint8List bytes;
      if (declared != null && declared > 0) {
        final buf = Uint8List(declared);
        var offset = 0;
        await for (final chunk in response.stream) {
          hasher.update(chunk);
          if (offset + chunk.length > declared) {
            throw NetworkError(
              'GET $uri returned more bytes than Content-Length advertised',
              uri: uri,
            );
          }
          buf.setRange(offset, offset + chunk.length, chunk);
          offset += chunk.length;
        }
        // Under-delivery is caught by the hash check below.
        bytes = offset == declared
            ? buf
            : Uint8List.sublistView(buf, 0, offset);
      } else {
        final builder = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          builder.add(chunk);
          hasher.update(chunk);
        }
        bytes = builder.takeBytes();
      }
      tarballNetworkBytes += bytes.length;
      final digestBase64 = base64.encode(hasher.finish());
      if (digestBase64 != expected.digestBase64) {
        throw IntegrityError(
          'integrity mismatch (${expected.algorithm})',
          expected: expected.encode(),
          actual: '${expected.algorithm}-$digestBase64',
        );
      }
      if (cache != null) {
        await cache!.writeTarball(integrity: integrity, bytes: bytes);
      }
      return bytes;
    });
  }
}

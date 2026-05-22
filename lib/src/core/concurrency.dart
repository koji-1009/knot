import 'dart:io';

/// Process-wide concurrency budget for knot, sized off the host's
/// CPU count.
///
/// Tuning rationale:
/// - **HTTP fetches** are latency-bound. Roughly N tarball downloads
///   can be in flight per core before CPU starts to limit the rate
///   at which we can hash + ingest them. 4x matches the install
///   fetch pool sizing and the `RegistryClient` HttpClient's
///   `maxConnectionsPerHost`.
/// - **File reads** are blocking-async. 2x lets the kernel pipeline
///   reads while one isolate is decoding tar headers.
/// - **Worker isolates** do CPU-bound JSON / hash work. One per core.
///
/// All three values share a single source of truth so the install
/// pipeline doesn't end up with one stage over-provisioned and the
/// next stage as the real ceiling.
final int knotHttpConcurrency = Platform.numberOfProcessors * 4;
final int knotFileReadConcurrency = Platform.numberOfProcessors * 2;
final int knotWorkerPoolSize = Platform.numberOfProcessors;

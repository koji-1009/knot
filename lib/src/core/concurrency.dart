import 'dart:io';

/// Default budget of in-flight registry requests (packuments + tarballs).
///
/// This is a **network** property, not a CPU one, so — unlike the worker
/// pool and file-read budgets below — it is a fixed constant rather than
/// derived from the core count. A fetch spends its time waiting on the
/// registry (RTT) and the shared pipe; how many usefully overlap is set
/// by RTT-hiding and the registry CDN's per-host limits, none of which
/// scale with local cores. Deriving it from `numberOfProcessors` (knot
/// previously used `cores * 4`, i.e. 40 on a 10-core box) opens far more
/// connections than the registry rewards: Dart's `HttpClient` is HTTP/1.1
/// only (no multiplexing), so each in-flight request is its own socket
/// and its own TLS handshake — dozens of them cost handshake latency and
/// invite server-side throttling without adding throughput once the pipe
/// and CDN saturate.
///
/// 16 is the value npm (`maxsockets`, default 15), pnpm
/// (`network-concurrency`, default 16) and gnpm (a fixed 16, HTTP/2) all
/// independently land on. Overridable per project via the active mode's
/// native config key — see `resolveNetworkConcurrency`.
const int defaultHttpConcurrency = 16;

/// CPU-bound worker-isolate pool size: JSON decode, gzip, sha512, link
/// batches. One per core — this work is genuinely parallel on the host's
/// cores, so it tracks the core count.
final int knotWorkerPoolSize = Platform.numberOfProcessors;

/// File-read fan-out (linker/store). Blocking-async I/O: 2x lets the
/// kernel pipeline reads while an isolate decodes tar headers.
final int knotFileReadConcurrency = Platform.numberOfProcessors * 2;

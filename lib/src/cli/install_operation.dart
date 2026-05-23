import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:knot/src/audit/audit.dart';
import 'package:knot/src/core/core.dart';
import 'package:knot/src/ffi/ffi.dart';
import 'package:knot/src/linker/linker.dart';
import 'package:knot/src/lockfile/lockfile.dart';
import 'package:knot/src/npmrc/npmrc.dart';
import 'package:knot/src/config_deps/config_dependencies.dart' as config_deps;
import 'package:knot/src/policy/build_script_gate.dart';
import 'package:knot/src/policy/pm_on_fail.dart';
import 'package:knot/src/project/project.dart' as project;
import 'package:knot/src/workspace_state/workspace_state.dart' as ws;
import 'package:knot/src/registry/registry.dart';
import 'package:knot/src/resolver/resolver.dart';
import 'package:knot/src/scripts/scripts.dart';
import 'package:knot/src/semver/semver.dart';
import 'package:knot/src/signature/signature.dart';
import 'package:knot/src/store/store.dart';
import 'package:path/path.dart' as p;
import 'package:pool/pool.dart';

import 'dependency_spec.dart';
import 'non_registry_resolver.dart';
import 'package_json.dart';
import 'registry_provider.dart';
import 'runner.dart' show knotVersion;
import 'workspace.dart';

/// Which install-time scripts to run.
///
/// `allowlist` matches pnpm v9+: only packages explicitly listed in
/// `package.json#onlyBuiltDependencies` get their `preinstall` /
/// `install` / `postinstall` / `prepare` scripts executed. A missing
/// or empty allowlist means "trust nothing" — install scripts are the
/// most common supply-chain attack vector, so deny-by-default is the
/// safer baseline.
enum ScriptPolicy {
  /// Skip every install-time script (= `--ignore-scripts`).
  none,

  /// Run scripts only for packages in `onlyBuiltDependencies`.
  allowlist,

  /// Run every script that a package defines — legacy npm behavior.
  /// Use only when you trust every dep transitively.
  all,
}

/// Flags controlling install behavior.
class InstallOptions {
  const InstallOptions({
    this.frozenLockfile = false,
    this.preferOffline = false,
    this.offline = false,
    this.ignoreScripts = false,
    this.scriptPolicy = ScriptPolicy.allowlist,
    this.production = false,
    this.engineStrict = false,
    this.minReleaseAge,
    this.signaturePolicy = SignaturePolicy.none,
    this.auditLevel,
    this.storeRoot,
    this.cacheRoot,
    this.pmOnFail = PmOnFailPolicy.warn,
    this.strictDepBuilds = false,
    this.dangerouslyAllowAllBuilds = false,
    this.optimisticRepeatInstall = true,
  });

  final bool frozenLockfile;
  final bool preferOffline;

  /// Forbid network access; cache miss fails the install.
  final bool offline;

  /// Legacy alias for `scriptPolicy = none`. Kept so existing call
  /// sites and tests don't have to learn the new enum; preserved as a
  /// dedicated flag because it shows up by that exact name in CI
  /// scripts that mirror `npm install --ignore-scripts`.
  final bool ignoreScripts;

  /// Determines which packages' lifecycle scripts may run. Ignored
  /// when [ignoreScripts] is true.
  final ScriptPolicy scriptPolicy;
  final bool production;

  /// Fail when a package's `engines.node` does not satisfy the running Node.
  final bool engineStrict;

  /// Refuse to install package versions younger than this. Mirrors
  /// `pnpm install --minimum-release-age=<duration>`: a published
  /// version is considered installable only once its registry-recorded
  /// publish time is older than `now - minReleaseAge`. Defends against
  /// freshly-published malicious packages.
  final Duration? minReleaseAge;

  /// How strictly to enforce registry-attached ECDSA signatures on
  /// downloaded tarballs. `none` is the default for backwards-compat;
  /// `weak` opts into verification when a signature exists; `strict`
  /// fails the install when one is missing or invalid.
  final SignaturePolicy signaturePolicy;

  /// Run the audit endpoint after install completes and fail the
  /// install when any advisory is at least this severity. `null`
  /// disables the auto-audit (default — keeps cold path free of an
  /// extra network round-trip). Mirrors `npm install --audit-level`.
  final AuditSeverity? auditLevel;

  final String? storeRoot;
  final String? cacheRoot;

  /// Controls what happens when the project pins a knot version this
  /// binary does not satisfy. See [PmOnFailPolicy].
  final PmOnFailPolicy pmOnFail;

  /// Phase E: when true, install fails for any unreviewed dependency
  /// that carries install-time build triggers (preinstall/install/
  /// postinstall, `binding.gyp`, `.hooks/`). pnpm v11 default is
  /// `true`; knot keeps it `false` until callers opt in.
  final bool strictDepBuilds;

  /// Phase C escape hatch: skips both [strictDepBuilds] and the
  /// allowBuilds gate. Reviewing a freshly imported lockfile sometimes
  /// requires this; production projects should not leave it set.
  final bool dangerouslyAllowAllBuilds;

  /// Phase J: when true, skip the full install pipeline if the
  /// workspace state hash matches the recorded one. Cheap to compute
  /// (≪ 1 ms on warm filesystems) and pairs with `verifyDepsBeforeRun`
  /// so `knot run` and a re-`knot install` agree on staleness.
  final bool optimisticRepeatInstall;

  ScriptPolicy get effectiveScriptPolicy =>
      ignoreScripts ? ScriptPolicy.none : scriptPolicy;
}

/// Outcome of an install run. Only the warnings list survives — the
/// other fields (resolved count, added count, duration) were
/// produced but never consumed by the CLI layer, which reads only
/// `warnings` for surfacing to the user.
class InstallReport {
  InstallReport({required this.warnings});
  final List<String> warnings;
}

/// End-to-end install orchestration — pure logic, no CLI parsing.
class InstallOperation {
  InstallOperation({
    required this.projectRoot,
    required this.options,
    KnotLogger? logger,
    this._onEvent,
  }) : _logger = logger ?? KnotLogger('knot.install');

  final String projectRoot;
  final InstallOptions options;
  final KnotLogger _logger;
  final void Function(ProgressEvent)? _onEvent;

  void _emit(ProgressEvent event) => _onEvent?.call(event);

  Future<InstallReport> run() async {
    final stopwatch = Stopwatch()..start();
    final profile = Platform.environment['KNOT_PROFILE'] == '1';
    final boot = Stopwatch()..start();
    void mark(String label) {
      if (!profile) return;
      // ignore: avoid_print
      print('  PHASE $label: ${boot.elapsedMilliseconds}ms');
      boot.reset();
    }

    final pkg = await PackageJson.read(p.join(projectRoot, 'package.json'));
    _checkPackageManager(pkg);

    // Phase J: short-circuit when the workspace-state hash matches the
    // recorded one. Cheap (~ 1 ms) and lets warm re-installs return
    // before any expensive resolve / store I/O kicks off.
    //
    // We read the lockfile bytes once here and reuse them downstream
    // for the parsed in-memory shape (see the `existingLock` path
    // below) — the workspace-state fingerprint (sha256) and the JSON
    // decode both run off the same buffer.
    final engineKey = _engineKeyFor(pkg);
    final mode = project.detectProjectMode(projectRoot);
    final lockfilePath = p.join(projectRoot, projectLockfileName(mode));
    final lockfileFile = File(lockfilePath);
    final Uint8List? lockfileBytes = await lockfileFile.exists()
        ? await lockfileFile.readAsBytes()
        : null;
    final lockfileFingerprint = lockfileBytes == null
        ? ws.lockfileFingerprintAbsent
        : ws.lockfileFingerprintFromBytes(lockfileBytes);
    final freshHash = await ws.computeWorkspaceHash(
      projectRoot: projectRoot,
      pkg: pkg,
      lockfileFingerprint: lockfileFingerprint,
      engineKey: engineKey,
    );
    if (options.optimisticRepeatInstall && !options.frozenLockfile) {
      final existing = await ws.readWorkspaceState(projectRoot);
      if (existing != null &&
          existing.hash == freshHash &&
          existing.engineKey == engineKey) {
        _logger.info(
          'workspace state matches recorded hash — '
          'skipping install (optimisticRepeatInstall=true)',
        );
        return InstallReport(warnings: const []);
      }
    }

    final workspaces = await WorkspaceResolver(
      projectRoot,
    ).resolve(pkg.workspaces);
    mark('read package.json + workspaces');

    final npmrc = await NpmrcLoader(projectDir: projectRoot).load();
    final storeRoot = options.storeRoot ?? _defaultStoreRoot();
    final store = Store(storeRoot);
    await store.initialize();

    final cacheRoot = options.cacheRoot ?? _defaultCacheRoot();
    final regCache = RegistryCache(root: cacheRoot);
    await regCache.initialize();
    mark('npmrc + store + cache init');

    // Single worker isolate pool for *all* blocking work in this install:
    // tarball ingest (gzip + tar + sha512), hardlink / clonefile batches,
    // and packument JSON decode all travel through this pool. Spawned
    // lazily so a fully-warm locked install with no extraction and few
    // link tasks pays no isolate cost. Declared before [RegistryClient]
    // so the accessor can be injected for packument decode.
    WorkerPool? workerPool;
    Future<WorkerPool> getWorkerPool() async {
      return workerPool ??= await WorkerPool.spawn(size: knotWorkerPoolSize);
    }

    final client = RegistryClient(
      config: npmrc,
      cache: regCache,
      offline: options.offline,
      preferOffline: options.preferOffline,
      getWorkerPool: getWorkerPool,
    );

    // Kick off `node --version` ahead of everything else so its
    // ~45 ms fork+exec runs concurrently with reading lockfiles and
    // packuments. Consumed by `_checkEngines` near the end.
    final nodeVersionFuture = _detectNodeVersionAsync();

    try {
      final provider = RegistryPackageProvider(
        client,
        minReleaseAge: options.minReleaseAge,
      );
      final preferred = <String, Version>{};
      // Parse the project's `package-lock.json` from the bytes we
      // already read at the top of `run` (for Phase J's fingerprint).
      // Returns null when the repo has none yet.
      final existingLock = lockfileBytes == null
          ? null
          : parseProjectLockfile(
              lockfileBytes,
              path: lockfilePath,
              mode: mode,
              registry: Uri.parse(npmrc.registry),
            );
      mark('read lockfile');

      // Fast path: if the lockfile is fully consistent with package.json
      // (every declared dep present with the same range, no workspaces,
      // no non-registry specifiers), skip the resolver and packument
      // re-fetch entirely. Matches the `pnpm install` / `bun install`
      // locked-install pattern.
      if (existingLock != null &&
          workspaces.isEmpty &&
          _lockfileMatchesPackageJson(pkg, existingLock, options)) {
        try {
          final report = await _runLocked(
            pkg: pkg,
            lockfile: existingLock,
            store: store,
            client: client,
            getWorkerPool: getWorkerPool,
            npmrc: npmrc,
            stopwatch: stopwatch,
            nodeVersionFuture: nodeVersionFuture,
          );
          await _materializeConfigDeps(client: client, pkg: pkg);
          await _writeWorkspaceState(hash: freshHash, engineKey: engineKey);
          return report;
        } finally {
          await workerPool?.dispose();
        }
      }
      if (existingLock != null) {
        for (final entry in existingLock.packages.values) {
          final v = tryParseVersion(entry.version);
          if (v != null) preferred[entry.name] = v;
        }
      }

      final declared = <String, String>{
        ...pkg.dependencies,
        if (!options.production) ...pkg.devDependencies,
      };
      // Union workspaces' declared deps into the same input. `workspace:`
      // protocol entries are stripped — they become local symlinks rather
      // than registry fetches.
      for (final ws in workspaces) {
        for (final d in ws.packageJson.dependencies.entries) {
          declared.putIfAbsent(d.key, () => d.value);
        }
        if (!options.production) {
          for (final d in ws.packageJson.devDependencies.entries) {
            declared.putIfAbsent(d.key, () => d.value);
          }
        }
      }

      // Translate `npm:<pkg>@<range>` aliases and other protocols into the
      // (packageName, range) pairs the resolver understands, keeping a map
      // back to the *logical* (`package.json`) names for direct-dep linking.
      final specs = <String, DependencySpec>{};
      final deps = <String, String>{};
      final aliasByPackage = <String, String>{};
      final workspaceNames = {for (final w in workspaces) w.name};
      final nonRegistrySpecs = <DependencySpec>[];
      for (final entry in declared.entries) {
        final spec = DependencySpec.parse(entry.key, entry.value);
        specs[entry.key] = spec;
        if (spec.protocol == SpecifierProtocol.workspace ||
            workspaceNames.contains(spec.packageName)) {
          continue;
        }
        if (spec.protocol == SpecifierProtocol.file ||
            spec.protocol == SpecifierProtocol.link ||
            spec.protocol == SpecifierProtocol.https ||
            spec.protocol == SpecifierProtocol.git) {
          nonRegistrySpecs.add(spec);
          continue;
        }
        final resolvedRange = await _resolveDistTagIfAny(
          provider,
          spec.packageName,
          spec.range,
        );
        deps[spec.packageName] = resolvedRange;
        if (spec.isAlias) {
          aliasByPackage[spec.packageName] = spec.logicalName;
        }
      }

      _emit(const ResolutionStarted());
      mark('parse deps + dist-tags');

      // Warm the in-process packument cache in parallel before the
      // resolver starts asking serially. We pass the *declared range*
      // for each name so the speculative cascade walks the same
      // version branch pubgrub will end up picking — without the
      // range, `latest`-version deps drag in unrelated branches
      // (vite@8/rolldown when the project actually resolves vite@5/
      // rollup) and we waste ~40 prefetches per install.
      //
      // Lockfile entries provide an exact-version pin (`=<version>`)
      // so the cascade walks exactly the version the lockfile last
      // chose — usually the same one we'll choose this time too.
      final warmupSeeds = <String, String>{...deps};
      if (existingLock != null) {
        for (final entry in existingLock.packages.values) {
          warmupSeeds.putIfAbsent(entry.name, () => '=${entry.version}');
        }
      }
      await provider.warmup(warmupSeeds);
      mark('warmup packuments (${warmupSeeds.length})');

      // Speculative tarball pre-fetch: pubgrub fires `onDecide` the
      // moment it commits to `name@version`. We kick off the tarball
      // download right then so the network work overlaps with the
      // rest of resolution. By the time `solve()` returns the
      // tarball is usually already in the store cache — the post-
      // solve fetch loop just awaits the Future. Backtracked
      // decisions leave their tarball behind as a future-run cache
      // hit (cheap).
      //
      // We reserve the map slot **synchronously** at decision time so
      // a fast solver (or the post-solve loop racing the speculative
      // path) sees the in-flight Future instead of starting a second
      // identical request. The Future's body internally awaits the
      // slice lookup and the network fetch.
      final tarballFutures = <String, Future<Uint8List>>{};
      void prefetchTarball(String name, Version version) {
        final id = '$name@$version';
        if (tarballFutures.containsKey(id)) return;
        tarballFutures[id] = () async {
          final slice = await provider.sliceOf(name, version);
          if (slice == null ||
              slice.tarball == null ||
              slice.integrity == null) {
            throw StateError('no tarball metadata for $id');
          }
          // Skip the network call for packages that won't be
          // installed on this host (esbuild's 22 optional
          // platform-specific siblings dominate this list for the
          // vite-react fixture; without the guard we'd download
          // ~3 MB of tarballs we'd immediately discard).
          if (!_matchesCurrentPlatform(slice)) {
            throw StateError('platform mismatch for $id');
          }
          return client.tarball(
            url: slice.tarball!,
            integrity: slice.integrity!,
          );
        }();
        // Attach an empty error handler so a thrown speculative
        // future (platform mismatch, transient network blip) does
        // not surface as an "unhandled async exception". The post-
        // solve loop reads the map only for packages it actually
        // installs and skips platform-incompatible ones up-front,
        // so a failing entry never gets awaited in that path.
        tarballFutures[id]!.then((_) => null, onError: (_) => null);
      }

      final solver = PubgrubSolver(
        SolverRequest(
          dependencies: deps,
          provider: provider,
          optionalDependencies: pkg.optionalDependencies,
          overrides: pkg.overrides,
          nestedOverrides: pkg.nestedOverrides,
          preferred: preferred,
          onDecide: prefetchTarball,
        ),
      );
      final solution = await solver.solve();
      mark('resolver (packument fetches + solve)');
      _emit(
        ResolutionCompleted(
          resolved: solution.assignments.length,
          elapsed: stopwatch.elapsed,
        ),
      );

      if (options.frozenLockfile && existingLock != null) {
        _verifyFrozen(solution, existingLock, projectLockfileName(mode));
      }

      final fetchPool = Pool(knotHttpConcurrency);
      final linkSpecs = <LinkSpec>[];
      final lockPackages = <String, LockedPackage>{};
      final SignatureVerifier? signatureVerifier =
          options.signaturePolicy == SignaturePolicy.none
          ? null
          : SignatureVerifier(keyStoreFor: client.keyStoreFor);

      final fetchFutures = <Future<void>>[];
      try {
        for (final entry in solution.assignments.entries) {
          final name = entry.key;
          final version = entry.value;
          fetchFutures.add(
            fetchPool.withResource(() async {
              final slice = await provider.sliceOf(name, version);
              if (slice == null ||
                  slice.tarball == null ||
                  slice.integrity == null) {
                throw NetworkError('no tarball/integrity for $name@$version');
              }
              if (!_matchesCurrentPlatform(slice)) {
                _logger.debug(
                  'skipping $name@$version: platform mismatch '
                  '(os=${slice.os}, cpu=${slice.cpu}, libc=${slice.libc})',
                );
                return;
              }
              // Skip transitive deps that the package bundles itself —
              // they ship inside the tarball, so we must not try to fetch
              // and link them separately.
              final bundled = slice.bundledDependencies.toSet();
              _emit(
                TarballFetchStarted(package: name, version: version.toString()),
              );
              // Pick up the speculative pre-fetch fired from
              // `onDecide` when one exists; otherwise fetch now.
              final id = '$name@$version';
              final bytes =
                  await (tarballFutures[id] ??
                      client.tarball(
                        url: slice.tarball!,
                        integrity: slice.integrity!,
                      ));
              _emit(TarballFetched(package: name, version: version.toString()));
              if (signatureVerifier != null) {
                final check = await signatureVerifier.verify(
                  name: name,
                  version: version.toString(),
                  integrity: slice.integrity!,
                  signatures: slice.signatures,
                );
                final warn = signatureVerifier.enforce(
                  policy: options.signaturePolicy,
                  name: name,
                  version: version.toString(),
                  result: check,
                );
                if (warn != null) solver.warnings.add(warn);
              }
              final pool = await getWorkerPool();
              await pool.ingest(
                storeRoot: storeRoot,
                bytes: bytes,
                tarballSha512Hex: slice.integrity!,
              );
              _emit(
                TarballExtracted(package: name, version: version.toString()),
              );
              linkSpecs.add(
                LinkSpec(
                  name: name,
                  version: version.toString(),
                  tarballSha512Hex: slice.integrity!,
                  dependencies: {
                    for (final d in slice.dependencies.entries)
                      if (!bundled.contains(d.key) &&
                          solution.assignments[d.key] != null)
                        d.key: solution.assignments[d.key]!.toString(),
                  },
                  isDirect: deps.containsKey(name),
                  linkAlias: aliasByPackage[name],
                  bin: slice.bin,
                  scripts: slice.scripts,
                  engines: slice.engines,
                ),
              );
              lockPackages['$name@$version'] = LockedPackage(
                name: name,
                version: version.toString(),
                resolution: Resolution.tarball(tarball: slice.tarball),
                integrity: slice.integrity,
                dependencies: slice.dependencies,
                optionalDependencies: slice.optionalDependencies,
                peerDependencies: slice.peerDependencies,
                os: slice.os,
                cpu: slice.cpu,
                hasBin: slice.hasBin,
                hasInstallScript: slice.hasInstallScript,
                bin: slice.bin,
                scripts: slice.scripts,
                engines: slice.engines,
                signatures: [
                  for (final s in slice.signatures)
                    LockedSignature(keyid: s.keyid, sig: s.sig),
                ],
              );
            }),
          );
        }
        await Future.wait(fetchFutures);
      } finally {
        await fetchPool.close();
      }
      mark('fetch tarballs + ingest (${solution.assignments.length} pkgs)');

      // Resolve and materialize non-registry specifiers (file:/link:/https/git).
      final directLinkOverrides = <String, String>{};
      if (nonRegistrySpecs.isNotEmpty) {
        final nonReg = NonRegistryResolver(
          projectRoot: projectRoot,
          store: store,
        );
        try {
          for (final spec in nonRegistrySpecs) {
            final resolution = await nonReg.resolve(spec);
            linkSpecs.add(resolution.linkSpec);
            if (resolution.directSymlinkTarget != null) {
              directLinkOverrides[resolution.linkSpec.topLevelName] =
                  resolution.directSymlinkTarget!;
            }
          }
        } finally {
          nonReg.close();
        }
      }

      // Default to npm-compatible flat layout. Set `node-linker=isolated`
      // in `.npmrc` for pnpm-style strict node_modules.
      final linkerKind = npmrc['node-linker'] ?? 'hoisted';
      final layout = linkerKind == 'isolated'
          ? LinkerKind.isolated
          : LinkerKind.hoisted;
      // Materialized link: specifiers replace node_modules/<name> with a
      // direct symlink to the local source dir — skip them during the
      // regular store-backed link step.
      final linkSpecsForLinker = linkSpecs
          .where((s) => !directLinkOverrides.containsKey(s.topLevelName))
          .toList();
      final pool = await getWorkerPool();
      final materializer = StoreMaterializer.forPlatform(
        store,
        workerPool: pool,
      );
      if (linkerKind == 'hoisted') {
        final hoisted = HoistedLinker(materializer: materializer);
        await hoisted.link(
          projectRoot: projectRoot,
          packages: linkSpecsForLinker,
          warnings: solver.warnings,
        );
      } else {
        final linker = NodeModulesLinker(materializer: materializer);
        await linker.link(
          projectRoot: projectRoot,
          packages: linkSpecsForLinker,
        );
      }
      // Apply `link:` direct symlinks after the regular link step.
      for (final entry in directLinkOverrides.entries) {
        await _applyDirectLink(
          nodeModulesRoot: p.join(projectRoot, 'node_modules'),
          name: entry.key,
          target: entry.value,
        );
      }
      for (final spec in linkSpecs) {
        _emit(PackageLinked(package: spec.name, version: spec.version));
      }
      mark('linker (materialize ${linkSpecs.length} pkgs)');
      if (profile) {
        // ignore: avoid_print
        print(
          '  COUNTERS packument: '
          'in-process=${client.packumentInProcessHits} '
          'disk=${client.packumentDiskHits} '
          'net=${client.packumentNetworkFetches} '
          '(304=${client.packument304s}, '
          'bytes=${(client.packumentNetworkBytes / 1024).round()}KB)',
        );
        // ignore: avoid_print
        print(
          '  COUNTERS tarball:   '
          'cache=${client.tarballCacheHits} '
          'net=${client.tarballNetworkFetches} '
          '(bytes=${(client.tarballNetworkBytes / 1024).round()}KB)',
        );
      }

      // Workspaces: per-workspace node_modules, plus reciprocal
      // workspace-to-workspace symlinks.
      if (workspaces.isNotEmpty) {
        await _linkWorkspaces(
          workspaces: workspaces,
          rootPackage: pkg,
          allLinkSpecs: linkSpecs,
          layout: layout,
        );
      }

      _checkEngines(
        linkSpecs,
        solver.warnings,
        nodeVer: await nodeVersionFuture,
      );

      if (options.effectiveScriptPolicy != ScriptPolicy.none) {
        await _runLifecycleScripts(
          rootPackage: pkg,
          linkSpecs: linkSpecs,
          warnings: solver.warnings,
          layout: layout,
        );
      }

      final lockfile = Lockfile(
        lockfileVersion: knotLockfileVersion,
        importers: {
          '.': Importer(
            dependencies: pkg.dependencies,
            devDependencies: pkg.devDependencies,
            optionalDependencies: pkg.optionalDependencies,
            peerDependencies: pkg.peerDependencies,
          ),
        },
        packages: lockPackages,
      );
      await writeProjectLockfile(
        projectRoot: projectRoot,
        lockfile: lockfile,
        projectName: pkg.name,
        projectVersion: pkg.version,
        mode: mode,
      );

      await _runPostInstallAudit(
        lockfile: lockfile,
        npmrc: npmrc,
        warnings: solver.warnings,
      );

      stopwatch.stop();
      _emit(
        InstallSummary(
          added: linkSpecs.length,
          removed: 0,
          elapsed: stopwatch.elapsed,
        ),
      );
      _logger.info(
        'resolved ${solution.assignments.length} packages '
        'in ${stopwatch.elapsed.inMilliseconds}ms',
      );
      await _materializeConfigDeps(client: client, pkg: pkg);
      await _writeWorkspaceState(hash: freshHash, engineKey: engineKey);
      return InstallReport(warnings: solver.warnings);
    } finally {
      client.close();
      await workerPool?.dispose();
    }
  }

  /// When `options.auditLevel` is set, query the registry's advisory
  /// endpoint and surface any finding at or above that severity. Any
  /// finding ≥ level is appended to [warnings] and bubbled into an
  /// `IntegrityError` so the CLI returns non-zero — matching
  /// `npm install --audit-level=<level>` semantics.
  Future<void> _runPostInstallAudit({
    required Lockfile lockfile,
    required NpmrcConfig npmrc,
    required List<String> warnings,
  }) async {
    final level = options.auditLevel;
    if (level == null) return;
    final service = AuditService(config: npmrc, userAgent: 'knot/$knotVersion');
    try {
      final report = await service.audit(lockfile);
      // Network blips during the audit don't fail the install — the
      // tarballs are already extracted and the lockfile is committed.
      // Just surface them as warnings.
      for (final err in report.advisoryFetchErrors) {
        warnings.add('audit: $err');
      }
      if (!report.meetsThreshold(level)) {
        if (report.total > 0) {
          warnings.add(
            'audit: ${report.total} advisor${report.total == 1 ? "y" : "ies"} '
            'found, all below --audit-level=${level.name}',
          );
        }
        return;
      }
      // Compose a compact, deterministic finding list — show only the
      // findings that triggered the failure (≥ threshold). The
      // remaining sub-threshold findings are still in the report but
      // would dilute the actionable message; users can run
      // `knot audit` for the full list.
      final lines = <String>[];
      final seen = <String>{};
      var blocking = 0;
      for (final f in report.findings) {
        if (!AuditSeverity.parse(f.advisory.severity).atLeast(level)) continue;
        final id = '${f.packageName}#${f.advisory.id}';
        if (!seen.add(id)) continue;
        blocking++;
        final sev = f.advisory.severity.toUpperCase();
        lines.add(
          '  $sev ${f.packageName}@${f.installedVersion}: '
          '${f.advisory.title} (${f.advisory.url})',
        );
      }
      final totalsByLevel = report.countsBySeverity;
      final breakdown = <String>[];
      for (final s in AuditSeverity.values.reversed) {
        final c = totalsByLevel[s] ?? 0;
        if (c > 0) breakdown.add('$c ${s.name}');
      }
      throw IntegrityError(
        'audit: $blocking advisor${blocking == 1 ? "y" : "ies"} '
        '≥ --audit-level=${level.name} '
        '(of ${report.total} total: ${breakdown.join(", ")})\n'
        '${lines.join("\n")}',
      );
    } finally {
      service.close();
    }
  }

  Future<void> _runLifecycleScripts({
    required PackageJson rootPackage,
    required List<LinkSpec> linkSpecs,
    required List<String> warnings,
    required LinkerKind layout,
  }) async {
    final runner = ScriptRunner();
    final topLevelBin = NodeModulesLinker.topLevelBinPath(projectRoot);

    // Root preinstall
    await _maybeRunRootScript(
      runner,
      rootPackage,
      LifecycleEvent.preinstall,
      topLevelBin,
    );

    // Per-package install / postinstall / prepare in topological dep order.
    // Knot's default is pnpm v9+ semantics: deny unless the package is
    // explicitly reviewed. `ScriptPolicy.all` opts out of the gate
    // (legacy npm behavior); the empty [_runLifecycleScripts] entry
    // path catches `none` upstream.
    final pnpmWs = await project.readPnpmWorkspaceConfig(projectRoot);
    final reviewed = [
      ...rootPackage.onlyBuiltDependencies,
      ...rootPackage.allowBuilds,
      ...pnpmWs.allowBuilds,
    ];
    final gate = BuildScriptPolicy(
      allowBuilds: reviewed,
      strictDepBuilds: options.strictDepBuilds,
      dangerouslyAllowAllBuilds: options.dangerouslyAllowAllBuilds,
    );
    final enforceAllowlist =
        options.effectiveScriptPolicy == ScriptPolicy.allowlist;
    final ordered = _topologicalOrder(linkSpecs);
    for (final spec in ordered) {
      if (spec.scripts.isEmpty) continue;
      if (enforceAllowlist) {
        final triggers = BuildScriptTriggers.fromScripts(spec.scripts);
        final decision = gate.evaluate(spec.name, triggers);
        if (decision == BuildScriptDecision.fail) {
          throw UsageError(
            'install refused: ${spec.id} ships install-time build '
            'scripts but is not in package.json#knot.allowBuilds. '
            'Add it after review, or set '
            '`dangerouslyAllowAllBuilds: true` to bypass.',
          );
        }
        if (decision == BuildScriptDecision.skip) {
          warnings.add(
            'skipped install scripts for ${spec.id}: not in '
            'allowBuilds '
            '(use --allow-scripts=all to override)',
          );
          continue;
        }
        // noTrigger / allow → fall through
      }
      final workingDir = NodeModulesLinker.linkedPathOf(
        projectRoot,
        spec,
        kind: layout,
      );
      final binDir = NodeModulesLinker.binPathFor(
        projectRoot,
        spec,
        kind: layout,
      );
      for (final event in const [
        LifecycleEvent.preinstall,
        LifecycleEvent.install,
        LifecycleEvent.postinstall,
        LifecycleEvent.prepare,
      ]) {
        final command = spec.scripts[event.scriptKey];
        if (command == null) continue;
        _emit(ScriptStarted(package: spec.name, event: event.scriptKey));
        try {
          final result = await runner.run(
            LifecycleScript(
              event: event,
              packageName: spec.name,
              packageVersion: spec.version,
              workingDir: workingDir,
              command: command,
            ),
            binDir: binDir,
          );
          _emit(
            ScriptCompleted(
              package: spec.name,
              event: event.scriptKey,
              exitCode: result.exitCode,
            ),
          );
        } on ScriptError catch (e) {
          _emit(
            ScriptCompleted(
              package: spec.name,
              event: event.scriptKey,
              exitCode: e.exitCode ?? 1,
            ),
          );
          warnings.add(
            'script ${event.scriptKey} for ${spec.id} failed: ${e.message}',
          );
        }
      }
    }

    // Root install / postinstall / prepare
    for (final event in const [
      LifecycleEvent.install,
      LifecycleEvent.postinstall,
      LifecycleEvent.prepare,
    ]) {
      await _maybeRunRootScript(runner, rootPackage, event, topLevelBin);
    }
  }

  Future<void> _maybeRunRootScript(
    ScriptRunner runner,
    PackageJson root,
    LifecycleEvent event,
    String binDir,
  ) async {
    final command = root.scripts[event.scriptKey];
    if (command == null) return;
    _emit(ScriptStarted(package: root.name, event: event.scriptKey));
    final result = await runner.run(
      LifecycleScript(
        event: event,
        packageName: root.name,
        packageVersion: root.version,
        workingDir: projectRoot,
        command: command,
      ),
      binDir: binDir,
    );
    _emit(
      ScriptCompleted(
        package: root.name,
        event: event.scriptKey,
        exitCode: result.exitCode,
      ),
    );
  }

  /// Post-order DFS — deepest dependencies first.
  List<LinkSpec> _topologicalOrder(List<LinkSpec> specs) {
    final byId = {for (final s in specs) s.id: s};
    final out = <LinkSpec>[];
    final visited = <String>{};
    void visit(LinkSpec spec) {
      if (!visited.add(spec.id)) return;
      for (final dep in spec.dependencies.entries) {
        final dependency = byId['${dep.key}@${dep.value}'];
        if (dependency != null) visit(dependency);
      }
      out.add(spec);
    }

    for (final s in specs) {
      visit(s);
    }
    return out;
  }

  /// Returns true when every `package.json` dep maps cleanly onto the
  /// lockfile's root importer. Non-registry specifiers (file:/link:/git/
  /// https) force a re-resolve since the lockfile doesn't track their
  /// source-of-truth.
  bool _lockfileMatchesPackageJson(
    PackageJson pkg,
    Lockfile lock,
    InstallOptions options,
  ) {
    final importer = lock.importers['.'];
    if (importer == null) return false;

    bool sameMap(Map<String, String> a, Map<String, String> b) {
      if (a.length != b.length) return false;
      for (final e in a.entries) {
        if (b[e.key] != e.value) return false;
      }
      return true;
    }

    bool hasNonRegistry(Map<String, String> deps) {
      for (final entry in deps.entries) {
        final spec = DependencySpec.parse(entry.key, entry.value);
        if (spec.protocol != SpecifierProtocol.semver) return true;
      }
      return false;
    }

    if (!sameMap(pkg.dependencies, importer.dependencies)) return false;
    if (!options.production &&
        !sameMap(pkg.devDependencies, importer.devDependencies)) {
      return false;
    }
    if (!sameMap(pkg.optionalDependencies, importer.optionalDependencies)) {
      return false;
    }
    if (!sameMap(pkg.peerDependencies, importer.peerDependencies)) return false;

    if (hasNonRegistry(pkg.dependencies)) return false;
    if (!options.production && hasNonRegistry(pkg.devDependencies)) {
      return false;
    }
    if (hasNonRegistry(pkg.optionalDependencies)) return false;

    // Every locked package must have integrity + tarball; otherwise we
    // can't materialize without re-resolving.
    for (final entry in lock.packages.values) {
      if (entry.integrity == null) return false;
      if (entry.resolution.tarball == null) return false;
    }
    return true;
  }

  /// Backfill path for older lockfiles that didn't cache bin/scripts/
  /// engines. Reads the package.json out of the store index. Returns
  /// null when the index is missing or doesn't contain a package.json.
  Future<PackageJson?> _readPackageJsonFromStore(
    Store store,
    String integrity,
  ) async {
    final manifest = await store.readIndex(integrity);
    if (manifest == null) return null;
    for (final f in manifest.files) {
      if (f.relativePath != 'package.json') continue;
      final body = await File(
        store.layout.filePath(f.sha512Hex),
      ).readAsString();
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      return PackageJson.fromJson(Map<String, dynamic>.from(decoded));
    }
    return null;
  }

  /// Locked install: no resolver, no packument fetch. Re-uses the cached
  /// integrity → tarball mapping straight out of `package-lock.json`.
  Future<InstallReport> _runLocked({
    required PackageJson pkg,
    required Lockfile lockfile,
    required Store store,
    required RegistryClient client,
    required Future<WorkerPool> Function() getWorkerPool,
    required NpmrcConfig npmrc,
    required Stopwatch stopwatch,
    required Future<Version?> nodeVersionFuture,
  }) async {
    final profile = Platform.environment['KNOT_PROFILE'] == '1';
    final phase = Stopwatch()..start();
    void mark(String label) {
      if (!profile) return;
      // ignore: avoid_print
      print('  PHASE $label: ${phase.elapsedMilliseconds}ms');
      phase.reset();
    }

    _emit(const ResolutionStarted());
    _emit(
      ResolutionCompleted(
        resolved: lockfile.packages.length,
        elapsed: stopwatch.elapsed,
      ),
    );
    mark('emit');

    final SignatureVerifier? signatureVerifier =
        options.signaturePolicy == SignaturePolicy.none
        ? null
        : SignatureVerifier(keyStoreFor: client.keyStoreFor);

    // Single warnings list spanning fetch (signature checks) + linker
    // + lifecycle scripts. Declared up front so the parallel tarball
    // fetch loop can append signature warnings before the engines
    // check or script runner kicks in.
    final lifecycleWarnings = <String>[];

    // Fetch any missing tarballs in parallel; ingest into the store.
    final fetchPool = Pool(knotHttpConcurrency);
    final futures = <Future<void>>[];
    try {
      for (final entry in lockfile.packages.values) {
        futures.add(
          fetchPool.withResource(() async {
            // Always verify the lockfile-recorded `(name, version,
            // integrity, signatures)` tuple, even when the tarball is
            // already in the store. Without this, a tampered lockfile
            // entry would slip through on warm installs (the tarball
            // download — and its sha512 check — would be skipped).
            if (signatureVerifier != null) {
              final check = await signatureVerifier.verify(
                name: entry.name,
                version: entry.version,
                integrity: entry.integrity!,
                signatures: [
                  for (final s in entry.signatures)
                    DistSignature(keyid: s.keyid, sig: s.sig),
                ],
              );
              final warn = signatureVerifier.enforce(
                policy: options.signaturePolicy,
                name: entry.name,
                version: entry.version,
                result: check,
              );
              if (warn != null) lifecycleWarnings.add(warn);
            }
            if (await store.hasTarball(entry.integrity!)) return;
            _emit(
              TarballFetchStarted(package: entry.name, version: entry.version),
            );
            final bytes = await client.tarball(
              url: entry.resolution.tarball!,
              integrity: entry.integrity!,
            );
            _emit(TarballFetched(package: entry.name, version: entry.version));
            final pool = await getWorkerPool();
            await pool.ingest(
              storeRoot: store.layout.root,
              bytes: bytes,
              tarballSha512Hex: entry.integrity!,
            );
            _emit(
              TarballExtracted(package: entry.name, version: entry.version),
            );
          }),
        );
      }
      await Future.wait(futures);
    } finally {
      await fetchPool.close();
    }
    mark('fetch+ingest (likely 0 when warm)');

    // Build LinkSpecs from locked entries. bin/scripts/engines come from
    // each package's `package.json` inside the store. Read in parallel —
    // for 50+ packages serial I/O dominates the locked install path.
    final directNames = <String>{
      ...pkg.dependencies.keys,
      if (!options.production) ...pkg.devDependencies.keys,
    };
    final lockedVersionByName = <String, String>{
      for (final e in lockfile.packages.values) e.name: e.version,
    };
    // bin/scripts/engines come straight from the lockfile (cached at
    // resolve time). Two cases force a manifest fallback:
    //
    // - `hasBin: true` with empty `bin` map: lockfile predates the
    //   bin cache.
    // - `hasInstallScript: true` with empty `scripts` map: npm's slim
    //   packument signals that scripts exist but omits the bodies,
    //   so we have to read the package.json from the store to know
    //   what to run.
    //
    // Empty manifestFallback is the common case (no bin / no install
    // scripts), so this typically saves ~16 ms across 58 packages.
    final manifestFallback = [
      for (final entry in lockfile.packages.values)
        if ((entry.hasBin && entry.bin.isEmpty) ||
            (entry.hasInstallScript && entry.scripts.isEmpty))
          entry,
    ];
    final fallbackData = <String, PackageJson?>{};
    if (manifestFallback.isNotEmpty) {
      final readPool = Pool(knotFileReadConcurrency);
      try {
        await Future.wait([
          for (final entry in manifestFallback)
            readPool.withResource(() async {
              fallbackData[entry.integrity!] = await _readPackageJsonFromStore(
                store,
                entry.integrity!,
              );
            }),
        ]);
      } finally {
        await readPool.close();
      }
    }
    final linkSpecs = <LinkSpec>[
      for (final entry in lockfile.packages.values)
        () {
          final fallback = fallbackData[entry.integrity];
          return LinkSpec(
            name: entry.name,
            version: entry.version,
            tarballSha512Hex: entry.integrity!,
            dependencies: {
              for (final d in entry.dependencies.entries)
                d.key: lockedVersionByName[d.key] ?? d.value,
            },
            isDirect: directNames.contains(entry.name),
            bin: entry.bin.isNotEmpty ? entry.bin : fallback?.bin ?? const {},
            scripts: entry.scripts.isNotEmpty
                ? entry.scripts
                : fallback?.scripts ?? const {},
            engines: entry.engines.isNotEmpty
                ? entry.engines
                : fallback?.engines ?? const {},
          );
        }(),
    ];
    mark(
      'build LinkSpecs (read ${linkSpecs.length} manifests + parse pkg.json)',
    );

    final linkerKind = npmrc['node-linker'] ?? 'hoisted';
    final layout = linkerKind == 'isolated'
        ? LinkerKind.isolated
        : LinkerKind.hoisted;
    final pool = await getWorkerPool();
    mark('WorkerPool.spawn');
    final materializer = StoreMaterializer.forPlatform(store, workerPool: pool);
    if (linkerKind == 'hoisted') {
      final hoisted = HoistedLinker(materializer: materializer);
      await hoisted.link(projectRoot: projectRoot, packages: linkSpecs);
    } else {
      final linker = NodeModulesLinker(materializer: materializer);
      await linker.link(projectRoot: projectRoot, packages: linkSpecs);
    }
    mark('linker (mkdirs + hardlinks)');
    for (final spec in linkSpecs) {
      _emit(PackageLinked(package: spec.name, version: spec.version));
    }

    // engines.node compatibility check. Cold install ran this before
    // writing the lockfile; warm/locked path was silently skipping it
    // so an upgrade of the host node version that violated a locked
    // package's range was never surfaced.
    _checkEngines(
      linkSpecs,
      lifecycleWarnings,
      nodeVer: await nodeVersionFuture,
    );
    if (options.effectiveScriptPolicy != ScriptPolicy.none) {
      await _runLifecycleScripts(
        rootPackage: pkg,
        linkSpecs: linkSpecs,
        warnings: lifecycleWarnings,
        layout: layout,
      );
    }

    await _runPostInstallAudit(
      lockfile: lockfile,
      npmrc: npmrc,
      warnings: lifecycleWarnings,
    );

    stopwatch.stop();
    _emit(
      InstallSummary(
        added: linkSpecs.length,
        removed: 0,
        elapsed: stopwatch.elapsed,
      ),
    );
    _logger.info(
      'locked install of ${linkSpecs.length} packages '
      'in ${stopwatch.elapsed.inMilliseconds}ms',
    );
    return InstallReport(warnings: lifecycleWarnings);
  }

  String _engineKeyFor(PackageJson pkg) {
    int? major;
    final runtime = pkg.devEnginesRuntime;
    if (runtime != null && runtime.name == 'node') {
      // Best-effort: pull the leading major. `^22`, `>=22 <23`,
      // `22.11.0` all map to `22`. When the range is exotic we fall
      // back to the running host (handled by [workspaceEngineKey]).
      final match = RegExp(r'(\d+)').firstMatch(runtime.version);
      if (match != null) major = int.tryParse(match.group(1)!);
    }
    return ws.workspaceEngineKey(nodeMajor: major);
  }

  Future<void> _materializeConfigDeps({
    required RegistryClient client,
    required PackageJson pkg,
  }) async {
    final pnpmWs = await project.readPnpmWorkspaceConfig(projectRoot);
    final merged = <String, String>{
      ...pkg.configDependencies,
      ...pnpmWs.configDependencies,
    };
    if (merged.isEmpty) return;
    final deps = [
      for (final entry in merged.entries)
        config_deps.ConfigDependency(name: entry.key, version: entry.value),
    ];
    await config_deps.materializeConfigDependencies(
      projectRoot: projectRoot,
      client: client,
      dependencies: deps,
    );
  }

  Future<void> _writeWorkspaceState({
    required String hash,
    required String engineKey,
  }) async {
    try {
      await ws.writeWorkspaceState(
        projectRoot: projectRoot,
        state: ws.WorkspaceState(
          hash: hash,
          engineKey: engineKey,
          installedAt: DateTime.now().toUtc(),
          knotVersion: knotVersion,
        ),
      );
    } on FileSystemException catch (e) {
      _logger.warn('could not write workspace state: ${e.message}');
    }
  }

  void _checkPackageManager(PackageJson pkg) {
    final result = evaluatePmOnFail(
      pkg: pkg,
      knotVersion: knotVersion,
      policy: options.pmOnFail,
    );
    switch (result.action) {
      case PmOnFailAction.proceed:
        return;
      case PmOnFailAction.ignore:
        return;
      case PmOnFailAction.warn:
        if (result.foreignManager != null) {
          _logger.warn(
            'package.json pins packageManager to "${result.foreignManager}'
            '@${result.requiredRange}" but this is knot; mismatched '
            'package managers can produce different lockfiles.',
          );
        } else {
          _logger.warn(
            'knot $knotVersion does not satisfy required range '
            '"${result.requiredRange}".',
          );
        }
      case PmOnFailAction.fail:
        throw UsageError(
          'knot $knotVersion does not satisfy required range '
          '"${result.requiredRange}" (pmOnFail=error).',
        );
    }
  }

  /// If [range] looks like a dist-tag (alphabetic, e.g. `latest`, `next`),
  /// translate it to `=<version>` via the packument; otherwise pass through.
  Future<String> _resolveDistTagIfAny(
    RegistryPackageProvider provider,
    String pkg,
    String range,
  ) async {
    final trimmed = range.trim();
    if (trimmed.isEmpty) return '*';
    // Heuristic: dist-tags don't contain spaces, comparators, or version
    // characters. They're typically `latest`, `next`, `beta`, `canary`, etc.
    final isWord = RegExp(r'^[a-zA-Z][a-zA-Z0-9._-]*$').hasMatch(trimmed);
    if (!isWord) return trimmed;
    try {
      final resolved = await provider.resolveDistTag(pkg, trimmed);
      if (resolved != null) return resolved;
    } on Object {
      // Network failures during dist-tag resolution fall back to the raw
      // string so the resolver can produce a clearer error.
    }
    return trimmed;
  }

  Future<void> _applyDirectLink({
    required String nodeModulesRoot,
    required String name,
    required String target,
  }) async {
    final linkPath = p.join(nodeModulesRoot, name);
    await Directory(p.dirname(linkPath)).create(recursive: true);
    // Remove any prior materialized entry (regular linker may have created one).
    final existingLink = Link(linkPath);
    if (await existingLink.exists()) await existingLink.delete();
    final existingDir = Directory(linkPath);
    if (await existingDir.exists()) await existingDir.delete(recursive: true);
    await createDirSymlinkOrJunction(
      linkPath: linkPath,
      target: p.relative(target, from: nodeModulesRoot),
    );
  }

  Future<void> _linkWorkspaces({
    required List<Workspace> workspaces,
    required PackageJson rootPackage,
    required List<LinkSpec> allLinkSpecs,
    required LinkerKind layout,
  }) async {
    final workspaceByName = {for (final w in workspaces) w.name: w};
    final nodeModulesRoot = p.join(projectRoot, 'node_modules');

    // 1) `<root>/node_modules/<workspaceName>` → workspace dir (read-only
    //    convenience; some tools expect to traverse up to top-level).
    for (final ws in workspaces) {
      final linkPath = p.join(nodeModulesRoot, ws.name);
      await Directory(p.dirname(linkPath)).create(recursive: true);
      if (Link(linkPath).existsSync() ||
          Directory(linkPath).existsSync() ||
          File(linkPath).existsSync()) {
        continue;
      }
      await createDirSymlinkOrJunction(
        linkPath: linkPath,
        target: p.relative(ws.rootPath, from: nodeModulesRoot),
      );
    }

    // 2) For each workspace, populate its own `node_modules` with the
    //    deps it declares — symlinked to the store-backed locations the
    //    main linker already produced under `<root>/node_modules/.knot/`.
    for (final ws in workspaces) {
      final wsNodeModules = Directory(p.join(ws.rootPath, 'node_modules'));
      await wsNodeModules.create(recursive: true);

      final wsDeps = <String, String>{
        ...ws.packageJson.dependencies,
        if (!options.production) ...ws.packageJson.devDependencies,
      };
      for (final entry in wsDeps.entries) {
        final spec = DependencySpec.parse(entry.key, entry.value);
        final linkPath = p.join(wsNodeModules.path, spec.logicalName);
        await Directory(p.dirname(linkPath)).create(recursive: true);
        if (Link(linkPath).existsSync() ||
            Directory(linkPath).existsSync() ||
            File(linkPath).existsSync()) {
          continue;
        }
        // Workspace-to-workspace dep.
        final targetWs = workspaceByName[spec.packageName];
        if (spec.protocol == SpecifierProtocol.workspace || targetWs != null) {
          if (targetWs == null) continue;
          await createDirSymlinkOrJunction(
            linkPath: linkPath,
            target: p.relative(targetWs.rootPath, from: p.dirname(linkPath)),
          );
          continue;
        }
        // Otherwise: link to the materialized store entry by name.
        final material = allLinkSpecs
            .where((s) => s.name == spec.packageName)
            .toList();
        if (material.isEmpty) continue;
        // The store-backed target path; relative-to the link's parent dir.
        final knot = NodeModulesLinker.linkedPathOf(
          projectRoot,
          material.first,
          kind: layout,
        );
        await createDirSymlinkOrJunction(
          linkPath: linkPath,
          target: p.relative(knot, from: p.dirname(linkPath)),
        );
      }
    }
  }

  void _checkEngines(
    List<LinkSpec> specs,
    List<String> warnings, {
    required Version? nodeVer,
  }) {
    // `nodeVer` is resolved by [_detectNodeVersionAsync] before the
    // linker phase so the ~45 ms `node --version` fork+exec overlaps
    // with the linker's syscalls instead of stacking after them.
    if (nodeVer == null) return;
    final hasNodeReq = specs.any(
      (s) => (s.engines['node']?.isNotEmpty ?? false),
    );
    if (!hasNodeReq) return;
    for (final spec in specs) {
      final requirement = spec.engines['node'];
      if (requirement == null || requirement.isEmpty) continue;
      final NpmRange range;
      try {
        range = NpmRange.parse(requirement);
      } on FormatException {
        continue;
      }
      if (range.satisfies(nodeVer)) continue;
      final msg =
          '${spec.id} requires node $requirement, '
          'running node $nodeVer';
      if (options.engineStrict) {
        throw UsageError(msg);
      }
      warnings.add(msg);
    }
  }

  /// Dispatch `node --version` asynchronously so the ~45 ms fork+exec
  /// can overlap with other install-time work. The result feeds
  /// [_checkEngines].
  Future<Version?> _detectNodeVersionAsync() async {
    try {
      final result = await Process.run('node', ['--version']);
      if (result.exitCode != 0) return null;
      final raw = (result.stdout as String).trim();
      final body = raw.startsWith('v') ? raw.substring(1) : raw;
      return tryParseVersion(body);
    } on ProcessException {
      return null;
    } on Object {
      return null;
    }
  }

  bool _matchesCurrentPlatform(PackumentVersion slice) {
    final osOk = _platformList(slice.os, currentOs);
    final cpuOk = _platformList(slice.cpu, currentCpu);
    final libcOk = slice.libc.isEmpty || _platformList(slice.libc, currentLibc);
    return osOk && cpuOk && libcOk;
  }

  void _verifyFrozen(SolverResult result, Lockfile lock, String lockfileName) {
    final mismatches = <String>[];
    for (final entry in result.assignments.entries) {
      final id = '${entry.key}@${entry.value}';
      if (!lock.packages.containsKey(id)) mismatches.add(id);
    }
    if (mismatches.isNotEmpty) {
      throw UsageError(
        '--frozen-lockfile requested but resolution diverges from '
        '$lockfileName (${mismatches.length} new entries)',
      );
    }
  }

  String _defaultStoreRoot() {
    final home = _homeDir();
    return p.join(home, '.knot', 'store');
  }

  String _defaultCacheRoot() {
    final home = _homeDir();
    return p.join(home, '.knot', 'cache');
  }

  String _homeDir() =>
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.current.path;
}

/// Current OS in npm's vocabulary.
String get currentOs {
  if (Platform.isMacOS) return 'darwin';
  if (Platform.isWindows) return 'win32';
  if (Platform.isLinux) return 'linux';
  if (Platform.isAndroid) return 'android';
  if (Platform.isFuchsia) return 'fuchsia';
  return Platform.operatingSystem;
}

/// Current CPU arch in npm's vocabulary.
String get currentCpu {
  final arch = Platform.version.toLowerCase();
  if (arch.contains('arm64') || arch.contains('aarch64')) return 'arm64';
  if (arch.contains('x64') || arch.contains('amd64')) return 'x64';
  if (arch.contains('ia32') || arch.contains('x86')) return 'ia32';
  if (arch.contains('arm')) return 'arm';
  // Fallback: best effort via uname-style probe.
  return _archFromEnv();
}

String _archFromEnv() {
  final raw =
      Platform.environment['PROCESSOR_ARCHITECTURE'] ??
      Platform.environment['HOSTTYPE'] ??
      '';
  final lower = raw.toLowerCase();
  if (lower.contains('arm64') || lower.contains('aarch64')) return 'arm64';
  if (lower.contains('amd64') || lower.contains('x86_64')) return 'x64';
  if (lower.contains('x86')) return 'ia32';
  return 'unknown';
}

/// Current libc (Linux only). Returns `glibc` outside Linux.
String get currentLibc {
  if (!Platform.isLinux) return 'glibc';
  // Heuristic: musl distros (Alpine) ship /lib/ld-musl-*.so.1
  if (Directory('/lib').existsSync()) {
    final hasMusl = Directory(
      '/lib',
    ).listSync(followLinks: false).any((e) => e.path.contains('ld-musl-'));
    if (hasMusl) return 'musl';
  }
  return 'glibc';
}

/// Match an npm-style platform list (positive entries + `!`-prefixed exclusions).
bool _platformList(List<String> entries, String current) {
  if (entries.isEmpty) return true;
  final positive = entries.where((e) => !e.startsWith('!')).toList();
  final negative = entries
      .where((e) => e.startsWith('!'))
      .map((e) => e.substring(1));
  if (negative.contains(current)) return false;
  if (positive.isEmpty) return true;
  return positive.contains(current);
}

/// Version solver based on the pubgrub data model (Weizenbaum 2018) with
/// CDCL-style conflict-driven learning.
///
/// Constraints are recorded as [Incompatibility]s — conjunctions of [Term]s
/// that cannot all hold. The solver alternates:
/// - **Unit propagation**: every almost-satisfied incompatibility derives
///   the negation of its remaining unsatisfied term.
/// - **Conflict driven learning**: when a fully-satisfied incompatibility is
///   detected (no solution along the current decision path), the highest-
///   level satisfying *decision* is rolled back, a unary incompatibility
///   forbidding that specific (package, version) pair is learned, and the
///   solver retries.
///
/// The conflict-driven-learning loop is provably terminating: each conflict
/// adds at least one forbidden (package, version) pair, and the total set is
/// finite (bounded by registry version counts).
library;

import 'package:knot/src/core/core.dart';
import 'package:knot/src/semver/semver.dart';

import 'incompatibility.dart';
import 'provider.dart';
import 'solver.dart' show SolverRequest, SolverResult;
import 'term.dart';

const String _rootPackage = r'$root';

/// Pubgrub-style version solver.
class PubgrubSolver {
  PubgrubSolver(this.request);
  final SolverRequest request;

  /// Non-fatal messages collected during solve.
  final List<String> warnings = [];

  // Mutable solver state.
  final List<_Assignment> _solution = [];
  final Map<String, List<_Assignment>> _assignmentsByPkg = {};
  final List<Incompatibility> _incompatibilities = [];
  final Set<String> _changed = <String>{};
  int _decisionLevel = 0;

  // Per-package forbidden versions, learned from conflicts.
  final Map<String, Set<String>> _forbiddenVersions = {};

  // Cached metadata.
  final Map<String, List<Version>> _versionsCache = {};
  final Map<String, Map<Version, PackageDependencies>> _depsCache = {};

  Future<SolverResult> solve() async {
    _registerRoot();

    String? next = _rootPackage;
    var iterations = 0;
    while (next != null) {
      iterations++;
      if (iterations > 50000) {
        throw ResolutionError(
          'pubgrub exceeded ${iterations - 1} iterations',
          explanation: _explainRecent(),
        );
      }
      await _unitPropagate(next);
      next = await _makeDecision();
    }

    final out = <String, Version>{};
    for (final a in _solution) {
      if (a.kind == _AssignmentKind.decision && a.package != _rootPackage) {
        out[a.package] = a.version!;
      }
    }
    return SolverResult(out);
  }

  // --- setup --------------------------------------------------------------

  void _registerRoot() {
    _decisionLevel = 0;
    final rootAssignment = _Assignment.decision(
      package: _rootPackage,
      version: Version(0, 0, 0),
      level: 0,
    );
    _solution.add(rootAssignment);
    _assignmentsByPkg[_rootPackage] = [rootAssignment];
    _changed.add(_rootPackage);

    final allDeps = <MapEntry<String, String>>[
      ...request.dependencies.entries,
      ...request.optionalDependencies.entries,
    ];
    for (final entry in allDeps) {
      final effective = _effective(
        entry.key,
        entry.value,
        parent: _rootPackage,
      );
      _addIncompatibility(
        Incompatibility([
          Term(package: _rootPackage, range: NpmRange.any, isPositive: true),
          Term(
            package: entry.key,
            range: _parseRangeOrEmpty(effective),
            isPositive: false,
          ),
        ], 'root depends on ${entry.key}@$effective'),
      );
    }
  }

  String _effective(String pkg, String declared, {String? parent}) {
    if (parent != null) {
      final scoped = request.nestedOverrides[parent]?[pkg];
      if (scoped != null) return scoped;
    }
    return request.overrides[pkg] ?? declared;
  }

  NpmRange _parseRangeOrEmpty(String raw) {
    try {
      return NpmRange.parse(raw);
    } on FormatException {
      return NpmRange.any;
    }
  }

  // --- unit propagation ---------------------------------------------------

  Future<void> _unitPropagate(String startPackage) async {
    _changed.add(startPackage);
    while (_changed.isNotEmpty) {
      final pkg = _changed.first;
      _changed.remove(pkg);

      // Iterate from newest incompat backward — learned facts first.
      for (var i = _incompatibilities.length - 1; i >= 0; i--) {
        final inc = _incompatibilities[i];
        if (!inc.terms.any((t) => t.package == pkg)) continue;

        final result = _check(inc);
        switch (result.status) {
          case _IncompatStatus.satisfied:
            // Conflict — backtrack and learn.
            final escalated = _onConflict(inc);
            if (escalated) return; // Backtracked; restart propagation outside.
          case _IncompatStatus.almostSatisfied:
            final term = result.unsatisfied!;
            _derive(term.invert(), inc);
            _changed.add(term.package);
          case _IncompatStatus.contradicted:
          case _IncompatStatus.inconclusive:
            break;
        }
      }
    }
  }

  /// Returns true when the propagation loop should exit because the solver
  /// just backtracked (the caller should re-enter via `solve()`'s outer loop).
  bool _onConflict(Incompatibility conflicted) {
    _Assignment? culprit;
    for (final t in conflicted.terms) {
      final assignments = _assignmentsByPkg[t.package] ?? const [];
      for (final a in assignments) {
        if (a.kind != _AssignmentKind.decision) continue;
        if (!_termSatisfiedBy(t, a)) continue;
        if (culprit == null || a.level > culprit.level) {
          culprit = a;
        }
      }
    }
    if (culprit == null || culprit.level == 0) {
      // No decision to undo → unsat.
      throw ResolutionError(
        'version solving failed: ${conflicted.cause}',
        explanation: _explainRecent(),
      );
    }
    _forbiddenVersions
        .putIfAbsent(culprit.package, () => <String>{})
        .add(culprit.version!.toString());
    // Learned unary: this exact (package, version) pair is incompatible.
    _addIncompatibility(
      Incompatibility(
        [
          Term(
            package: culprit.package,
            range: NpmRange.parse('=${culprit.version}'),
            isPositive: true,
          ),
        ],
        '${culprit.package}@${culprit.version} '
        'conflicts with ${conflicted.cause}',
      ),
    );
    _backtrackTo(culprit.level - 1);
    _changed
      ..clear()
      ..add(culprit.package);
    return true;
  }

  // --- decision -----------------------------------------------------------

  Future<String?> _makeDecision() async {
    final candidates = <_PackageCandidate>[];
    for (final pkg in _undecidedPackages()) {
      final range = _currentPositiveRange(pkg);
      if (range == null) continue;
      final all = await _versions(pkg);
      final forbidden = _forbiddenVersions[pkg] ?? const <String>{};
      final viable =
          all
              .where(range.satisfies)
              .where((v) => !forbidden.contains(v.toString()))
              .toList()
            ..sort((a, b) => b.compareTo(a));
      candidates.add(_PackageCandidate(pkg, range, viable));
    }
    if (candidates.isEmpty) return null;

    candidates.sort((a, b) => a.viable.length.compareTo(b.viable.length));
    final pick = candidates.first;

    if (pick.viable.isEmpty) {
      _addIncompatibility(
        Incompatibility([
          Term(package: pick.package, range: pick.range, isPositive: true),
        ], 'no versions of ${pick.package} satisfy ${pick.range}'),
      );
      _changed.add(pick.package);
      return pick.package;
    }

    final preferred = request.preferred[pick.package];
    final version = preferred != null && pick.viable.contains(preferred)
        ? preferred
        : pick.viable.first;

    _decisionLevel++;
    final decision = _Assignment.decision(
      package: pick.package,
      version: version,
      level: _decisionLevel,
    );
    _solution.add(decision);
    _assignmentsByPkg.putIfAbsent(pick.package, () => []).add(decision);
    // Notify the install path so it can speculatively start the
    // tarball fetch in parallel with the remaining resolution. Fire
    // synchronously; the listener returns immediately and dispatches
    // its own background work.
    request.onDecide?.call(pick.package, version);

    final deps = await _dependenciesOf(pick.package, version);
    for (final d in deps.dependencies.entries) {
      _addPackageDepIncompat(pick.package, version, d.key, d.value);
    }
    // Propagate transitive `optionalDependencies` — these are the
    // platform-specific native binary siblings (e.g. esbuild's
    // `@esbuild/darwin-arm64`, rollup's `@rollup/rollup-darwin-arm64`,
    // fsevents). Without this the resolver never picks them; the
    // install path's `_matchesCurrentPlatform` then has nothing to
    // narrow down to, and esbuild ships without its native binary →
    // runtime failure.
    //
    // Soft semantics: if no resolvable version exists (registry 404,
    // or no version satisfies the declared range), silently skip
    // instead of failing the whole solve. Matches npm's "best
    // effort" treatment of optionalDependencies.
    for (final d in deps.optionalDependencies.entries) {
      if (!await _hasSatisfyingVersion(d.key, d.value)) continue;
      _addPackageDepIncompat(pick.package, version, d.key, d.value);
    }
    if (request.autoInstallPeers) {
      for (final d in deps.peerDependencies.entries) {
        // Peers flagged `{optional: true}` in `peerDependenciesMeta`
        // are "use if present" — don't force-install. They still get
        // installed when some other package depends on them through
        // hard `dependencies`. Without this skip the resolver pulls
        // in vite's CSS-preprocessor peers (`less`, `sass`, …) on
        // every install.
        if (deps.optionalPeers.contains(d.key)) continue;
        _addPackageDepIncompat(pick.package, version, d.key, d.value);
      }
    } else {
      for (final d in deps.peerDependencies.entries) {
        if (deps.optionalPeers.contains(d.key)) continue;
        if (_assignmentsByPkg[d.key] == null) {
          warnings.add(
            'unmet peer dependency: ${pick.package}@$version → '
            '${d.key}@${d.value}',
          );
        }
      }
    }

    _changed.add(pick.package);
    return pick.package;
  }

  void _addPackageDepIncompat(
    String parent,
    Version parentVersion,
    String dep,
    String range,
  ) {
    final effective = _effective(dep, range, parent: parent);
    final NpmRange parsed;
    try {
      parsed = NpmRange.parse(effective);
    } on FormatException {
      _addIncompatibility(
        Incompatibility([
          Term(
            package: parent,
            range: NpmRange.parse('=$parentVersion'),
            isPositive: true,
          ),
        ], '$parent@$parentVersion declares unparseable range $dep@$range'),
      );
      return;
    }
    _addIncompatibility(
      Incompatibility([
        Term(
          package: parent,
          range: NpmRange.parse('=$parentVersion'),
          isPositive: true,
        ),
        Term(package: dep, range: parsed, isPositive: false),
      ], '$parent@$parentVersion depends on $dep@$effective'),
    );
  }

  // --- backtracking -------------------------------------------------------

  void _backtrackTo(int level) {
    while (_solution.isNotEmpty && _solution.last.level > level) {
      final a = _solution.removeLast();
      _assignmentsByPkg[a.package]?.remove(a);
      if (_assignmentsByPkg[a.package]?.isEmpty ?? false) {
        _assignmentsByPkg.remove(a.package);
      }
    }
    _decisionLevel = level;
  }

  // --- helpers ------------------------------------------------------------

  void _addIncompatibility(Incompatibility inc) {
    if (inc.terms.isEmpty) return;
    _incompatibilities.add(inc);
  }

  void _derive(Term term, Incompatibility cause) {
    final a = _Assignment.derivation(
      package: term.package,
      term: term,
      level: _decisionLevel,
      cause: cause,
    );
    _solution.add(a);
    _assignmentsByPkg.putIfAbsent(term.package, () => []).add(a);
  }

  Iterable<String> _undecidedPackages() {
    final undecided = <String>{};
    for (final a in _solution) {
      if (a.kind != _AssignmentKind.derivation) continue;
      if (a.package == _rootPackage) continue;
      if (_hasDecision(a.package)) continue;
      if ((a.term?.isPositive ?? false)) {
        undecided.add(a.package);
      }
    }
    return undecided;
  }

  bool _hasDecision(String pkg) {
    final list = _assignmentsByPkg[pkg];
    if (list == null) return false;
    return list.any((a) => a.kind == _AssignmentKind.decision);
  }

  NpmRange? _currentPositiveRange(String pkg) {
    final assignments = _assignmentsByPkg[pkg];
    if (assignments == null) return null;
    NpmRange? positive;
    for (final a in assignments) {
      if (a.kind != _AssignmentKind.derivation) continue;
      final t = a.term!;
      if (!t.isPositive) continue;
      positive = positive == null ? t.range : positive.intersect(t.range);
    }
    return positive ?? NpmRange.any;
  }

  Future<List<Version>> _versions(String pkg) async {
    final cached = _versionsCache[pkg];
    if (cached != null) return cached;
    final v = await request.provider.versions(pkg);
    final sorted = [...v]..sort();
    _versionsCache[pkg] = sorted;
    return sorted;
  }

  Future<PackageDependencies> _dependenciesOf(String pkg, Version v) async {
    final cached = _depsCache[pkg]?[v];
    if (cached != null) return cached;
    final d = await request.provider.dependenciesOf(pkg, v);
    _depsCache.putIfAbsent(pkg, () => {})[v] = d;
    return d;
  }

  /// True when [pkg] has at least one published version that satisfies
  /// the [range] declared for it. Used to give transitive
  /// `optionalDependencies` "best-effort" semantics — a missing
  /// optional must not abort the solve.
  Future<bool> _hasSatisfyingVersion(String pkg, String range) async {
    final candidates = await _versions(pkg);
    if (candidates.isEmpty) return false;
    final NpmRange parsed;
    try {
      parsed = NpmRange.parse(_effective(pkg, range));
    } on FormatException {
      return false;
    }
    return candidates.any(parsed.satisfies);
  }

  _CheckResult _check(Incompatibility inc) {
    Term? unsatisfied;
    var countSatisfied = 0;
    for (final t in inc.terms) {
      final status = _termStatus(t);
      switch (status) {
        case _TermStatus.satisfied:
          countSatisfied++;
        case _TermStatus.contradicted:
          return const _CheckResult(_IncompatStatus.contradicted);
        case _TermStatus.inconclusive:
          if (unsatisfied != null) {
            return const _CheckResult(_IncompatStatus.inconclusive);
          }
          unsatisfied = t;
      }
    }
    if (unsatisfied == null) {
      return const _CheckResult(_IncompatStatus.satisfied);
    }
    if (countSatisfied == inc.terms.length - 1) {
      return _CheckResult(
        _IncompatStatus.almostSatisfied,
        unsatisfied: unsatisfied,
      );
    }
    return const _CheckResult(_IncompatStatus.inconclusive);
  }

  _TermStatus _termStatus(Term t) {
    final assignments = _assignmentsByPkg[t.package];
    if (assignments == null || assignments.isEmpty) {
      return _TermStatus.inconclusive;
    }
    NpmRange positive = NpmRange.any;
    final negatives = <NpmRange>[];
    Version? decided;
    for (final a in assignments) {
      if (a.kind == _AssignmentKind.decision) {
        decided = a.version;
        continue;
      }
      final dt = a.term!;
      if (dt.isPositive) {
        positive = positive.intersect(dt.range);
      } else {
        negatives.add(dt.range);
      }
    }

    if (decided != null) {
      final inRange = t.range.satisfies(decided);
      final ok = t.isPositive ? inRange : !inRange;
      return ok ? _TermStatus.satisfied : _TermStatus.contradicted;
    }

    if (t.isPositive) {
      // Contradicted if no version of `t.range` survives positive ∩ ¬negs.
      if (positive.intersect(t.range).isEmpty) {
        return _TermStatus.contradicted;
      }
      for (final neg in negatives) {
        if (_subsetOf(t.range, neg)) return _TermStatus.contradicted;
      }
      if (_subsetOf(positive, t.range) &&
          negatives.every((n) => n.intersect(positive).isEmpty)) {
        return _TermStatus.satisfied;
      }
      return _TermStatus.inconclusive;
    } else {
      // t says NOT in t.range.
      if (_subsetOf(positive, t.range) &&
          negatives.every((n) => !_subsetOf(positive, n))) {
        return _TermStatus.contradicted;
      }
      if (positive.intersect(t.range).isEmpty) {
        return _TermStatus.satisfied;
      }
      for (final neg in negatives) {
        if (_subsetOf(t.range, neg)) return _TermStatus.satisfied;
      }
      return _TermStatus.inconclusive;
    }
  }

  bool _subsetOf(NpmRange a, NpmRange b) {
    final inter = a.intersect(b);
    if (inter.isEmpty) return a.isEmpty;
    return inter.underlying.toString() == a.underlying.toString();
  }

  bool _termSatisfiedBy(Term t, _Assignment a) {
    if (a.kind == _AssignmentKind.decision) {
      final inRange = t.range.satisfies(a.version!);
      return t.isPositive ? inRange : !inRange;
    }
    final derived = a.term!;
    if (derived.package != t.package) return false;
    if (derived.isPositive && t.isPositive) {
      return _subsetOf(derived.range, t.range);
    }
    if (derived.isPositive && !t.isPositive) {
      return derived.range.intersect(t.range).isEmpty;
    }
    if (!derived.isPositive && t.isPositive) {
      return false;
    }
    return _subsetOf(t.range, derived.range);
  }

  String _explainRecent() {
    final sb = StringBuffer()..writeln('Recent incompatibilities:');
    for (final inc in _incompatibilities.reversed.take(20)) {
      sb.writeln('  - ${inc.cause}');
    }
    return sb.toString();
  }
}

// --- private types ---------------------------------------------------------

enum _AssignmentKind { decision, derivation }

class _Assignment {
  _Assignment.decision({
    required this.package,
    required Version this.version,
    required this.level,
  }) : kind = _AssignmentKind.decision,
       term = null,
       cause = null;

  _Assignment.derivation({
    required this.package,
    required Term this.term,
    required this.level,
    required Incompatibility this.cause,
  }) : kind = _AssignmentKind.derivation,
       version = null;

  final _AssignmentKind kind;
  final String package;
  final Version? version;
  final Term? term;
  final int level;
  final Incompatibility? cause;
}

enum _IncompatStatus { satisfied, almostSatisfied, contradicted, inconclusive }

class _CheckResult {
  const _CheckResult(this.status, {this.unsatisfied});
  final _IncompatStatus status;
  final Term? unsatisfied;
}

enum _TermStatus { satisfied, contradicted, inconclusive }

class _PackageCandidate {
  _PackageCandidate(this.package, this.range, this.viable);
  final String package;
  final NpmRange range;
  final List<Version> viable;
}

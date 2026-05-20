import 'package:knot/src/semver/semver.dart';

/// A constraint on a specific package: positive (must be satisfied) or
/// negative (must NOT be satisfied).
class Term {
  const Term({
    required this.package,
    required this.range,
    this.isPositive = true,
  });

  final String package;
  final NpmRange range;
  final bool isPositive;

  Term invert() =>
      Term(package: package, range: range, isPositive: !isPositive);

  @override
  bool operator ==(Object other) =>
      other is Term &&
      other.package == package &&
      other.range.raw == range.raw &&
      other.isPositive == isPositive;

  @override
  int get hashCode => Object.hash(package, range.raw, isPositive);

  @override
  String toString() => '${isPositive ? '' : 'NOT '}$package@${range.raw}';
}

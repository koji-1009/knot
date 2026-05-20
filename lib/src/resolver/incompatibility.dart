
import 'term.dart';

/// A conjunction of terms that cannot all hold simultaneously. Encodes the
/// fact that "if all of these are true, the solution is unsatisfiable".
class Incompatibility {
  const Incompatibility(this.terms, this.cause);

  final List<Term> terms;

  /// Free-form reason used for human-readable conflict explanations.
  final String cause;

  @override
  String toString() => 'Incompatibility(${terms.join(' & ')}) <- $cause';
}

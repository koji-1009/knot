/// pnpm v11 `catalogs` + `catalog:` protocol (Phase O).
///
/// A catalog is a project-wide registry of pinned dependency versions
/// that workspace packages can reference by alias. Two on-disk shapes
/// in pnpm:
///
/// ```yaml
/// # short form: default catalog
/// catalog:
///   react: ^18.0.0
///
/// # named form
/// catalogs:
///   ui:
///     react: ^18.0.0
/// ```
///
/// Consumers reference entries with:
/// - `"react": "catalog:"`     — pull from the default catalog
/// - `"react": "catalog:ui"`   — pull from the named `ui` catalog
///
/// In knot the catalog tables live under `package.json#knot.catalogs`
/// (npm/knot-mode) or `pnpm-workspace.yaml#catalog(s)` (pnpm-mode);
/// either side feeds [CatalogSet] via the config loader.
library;

/// Reserved catalog name used by the unnamed `catalog:` reference.
const String defaultCatalogName = 'default';

/// Behavior knot applies when a workspace package's dep range diverges
/// from the catalog entry it shadows (pnpm v11 `catalogMode`).
enum CatalogMode {
  /// No automatic catalog use; catalogs apply only when explicitly
  /// referenced via `catalog:`.
  manual,

  /// Refuse to install when a workspace package declares a range that
  /// differs from the catalog entry. Forces strict catalog use.
  strict,

  /// Prefer the catalog entry whenever one exists for a name, falling
  /// back to the workspace-declared range otherwise.
  prefer,
}

/// Parse `.npmrc` / `pnpm-workspace.yaml` value into a [CatalogMode].
CatalogMode parseCatalogMode(String? raw) {
  if (raw == null) return CatalogMode.manual;
  switch (raw.trim().toLowerCase()) {
    case '':
    case 'manual':
      return CatalogMode.manual;
    case 'strict':
      return CatalogMode.strict;
    case 'prefer':
      return CatalogMode.prefer;
    default:
      throw FormatException('unknown catalogMode: "$raw"');
  }
}

/// One catalog table — `{packageName → range}` keyed by catalog name.
class CatalogSet {
  CatalogSet(Map<String, Map<String, String>> tables)
    : tables = Map<String, Map<String, String>>.unmodifiable({
        for (final entry in tables.entries)
          entry.key: Map<String, String>.unmodifiable(entry.value),
      });

  final Map<String, Map<String, String>> tables;

  static final CatalogSet empty = CatalogSet({});

  /// All known catalog names (including `default` if present).
  Iterable<String> get names => tables.keys;

  /// Lookup [packageName] in [catalogName]. Returns null on miss.
  String? lookup({
    String catalogName = defaultCatalogName,
    required String packageName,
  }) => tables[catalogName]?[packageName];

  /// Build a CatalogSet from the shorthand + long form found in a
  /// project file. Both keys are optional; mismatched types are
  /// ignored to keep the parser tolerant of stray YAML / JSON shapes.
  ///
  /// `shortForm` is `{packageName → range}` (the default catalog);
  /// `namedForm` is `{catalogName → {packageName → range}}`. Same-name
  /// keys in the long form override the short form.
  factory CatalogSet.fromConfig({Object? shortForm, Object? namedForm}) {
    final tables = <String, Map<String, String>>{};
    if (shortForm is Map) {
      tables[defaultCatalogName] = _stringMap(shortForm);
    }
    if (namedForm is Map) {
      for (final entry in namedForm.entries) {
        if (entry.key is! String) continue;
        final value = entry.value;
        if (value is! Map<dynamic, dynamic>) continue;
        tables[entry.key as String] = _stringMap(value);
      }
    }
    return CatalogSet(tables);
  }

  static Map<String, String> _stringMap(Map<dynamic, dynamic> raw) {
    final out = <String, String>{};
    for (final entry in raw.entries) {
      if (entry.key is! String) continue;
      out[entry.key as String] = '${entry.value}';
    }
    return out;
  }
}

/// Parsed `catalog:` protocol reference. [name] is `default` when the
/// raw form was just `catalog:`; otherwise it carries the explicit
/// catalog identifier.
class CatalogReference {
  const CatalogReference({required this.name});
  final String name;

  /// Parse `catalog:`, `catalog:ui`, etc. Returns null when [raw] does
  /// not start with the `catalog:` prefix so callers can fall through
  /// to other specifier handlers.
  static CatalogReference? tryParse(String raw) {
    if (!raw.startsWith('catalog:')) return null;
    final body = raw.substring(8).trim();
    return CatalogReference(name: body.isEmpty ? defaultCatalogName : body);
  }
}

/// Resolve [reference] against [catalogs] returning the underlying
/// range, or null when no entry exists. Callers translate the null
/// into a user-facing "catalog entry missing" error.
String? resolveCatalogReference({
  required CatalogReference reference,
  required CatalogSet catalogs,
  required String packageName,
}) => catalogs.lookup(catalogName: reference.name, packageName: packageName);

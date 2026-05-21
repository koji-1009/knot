# knot

Normative reference for the knot package manager. Applies to knot `0.0.1-dev`.

knot is an AOT-compiled CLI that installs npm packages. It reads and writes `package.json` + `package-lock.json` as its native at-rest formats and consumes pnpm artifacts (`pnpm-lock.yaml`, `pnpm-workspace.yaml`) transparently when a project is already on pnpm. This document specifies its commands, settings, file formats, and behavior. Anything not described here is unspecified.

The companion README covers installation and a quick tour; this document is the contract.

---

## Contents

1. [Project modes](#1-project-modes)
2. [Configuration](#2-configuration)
3. [Dependency specifiers](#3-dependency-specifiers)
4. [Lockfiles](#4-lockfiles)
5. [CLI commands](#5-cli-commands)
6. [Lifecycle scripts](#6-lifecycle-scripts)
7. [Audit](#7-audit)
8. [Workspaces](#8-workspaces)
9. [Catalogs](#9-catalogs)
10. [dlx](#10-dlx)

---

## 1. Project modes

knot decides where it reads and writes configuration / lockfile data from the on-disk file presence at the project root, not from a flag.

| Mode | Trigger | Reads | Writes |
|---|---|---|---|
| `pnpm` | `pnpm-workspace.yaml` OR `pnpm-lock.yaml` is present | `pnpm-workspace.yaml`, `pnpm-lock.yaml`, auth-only entries from `.npmrc` | `pnpm-lock.yaml` |
| `npm` | `package-lock.json` is present, OR `.npmrc` contains a non-auth entry, AND `pnpm` mode does not match | `package.json#knot`, full `.npmrc`, `package-lock.json` | `package-lock.json` |
| `knot` | no file from either category above | same sources as `npm` mode | `package-lock.json` |

**Auth keys** that do not count as "non-auth" for `npm` mode detection (matched case-insensitively): `_auth`, `email`, and any key containing `:_authtoken`, `:_password`, `:username`, or `:_auth`.

The `knot` and `npm` modes share their on-disk surface; the distinction exists only to label projects that have never been touched by an npm-ecosystem tool. knot does not introduce a new lockfile format.

---

## 2. Configuration

### 2.1 Sources and precedence

Settings are read from the first source that defines them, highest priority first:

1. CLI flag (per-command, e.g. `--min-release-age=1440`)
2. Environment variable: `KNOT_CONFIG_<UPPER_SNAKE_KEY>=<value>`
3. Project `.npmrc` (walked from the project root up to the filesystem root; the first `.npmrc` found wins)
4. User `.npmrc` (`~/.npmrc`)
5. Global `.npmrc` (`/etc/npmrc`)
6. In `pnpm` mode, `pnpm-workspace.yaml` keys merge into the `.npmrc`-level entries.
7. In `npm` / `knot` mode, the `knot` object inside `package.json` is read for keys that the npm / pnpm `.npmrc` schema does not cover (`allowBuilds`, `auditConfig.ignoreGhsas`).

`KNOT_CONFIG_*` is the only environment-variable prefix knot reads. `npm_config_*` and `NPM_CONFIG_*` are deliberately ignored so an ambient configuration belonging to another package manager cannot silently override knot's behavior.

### 2.2 Auth-only `.npmrc` (`pnpm` mode)

In `pnpm` mode, `.npmrc` is treated as containing only credentials. Non-auth keys in `.npmrc` are read but do not influence behavior; configuration of policies lives in `pnpm-workspace.yaml`. This is so projects that share an `.npmrc` between pnpm and other tooling do not have their policy settings interpreted twice.

### 2.3 Separated auth file

```
# in .npmrc (any layer)
npmrc-auth-file=~/.knot/auth.npmrc
```

When `npmrc-auth-file` is set, knot reads the referenced file as an additional `.npmrc` layer inserted **beneath** every user-authored layer. Explicit entries in the project / user / global `.npmrc` still override the auth file. Paths starting with `~/` are resolved against the user's home directory; relative paths are resolved against the project root; absolute paths are used as-is.

The auth file is silently ignored if it does not exist.

### 2.4 Settings reference

Each setting below documents: **Type**, **Default**, **Source**, and **Behavior**. Examples are shown in the form they appear in the listed source.

#### `minimumReleaseAge`

- **Type**: non-negative integer (minutes)
- **Default**: `0` (filter disabled)
- **Source**: `.npmrc minimum-release-age=` or CLI `--min-release-age=`

When the value is greater than `0`, a candidate version `v` of a package is filtered out of the resolver's candidate list when the registry's `time[v]` is more recent than `now - <value> minutes`. The filter requires the full packument (not the slim form); knot requests it automatically when the filter is on. `0` (or empty / unset) disables the filter. Unit suffixes (`24h`, `7d`, etc.) are rejected — pnpm's `minimumReleaseAge` is plain minutes, and accepting suffixes would make the same `pnpm-workspace.yaml` value behave differently under knot.

```
# .npmrc — wait 1 day before installing a newly published version
minimum-release-age=1440
```

#### `minimumReleaseAgeStrict`

- **Type**: boolean
- **Default**: `false`
- **Source**: `.npmrc minimum-release-age-strict=`

When every version of a needed package is younger than the `minimumReleaseAge` cutoff: `true` fails the install with a `NetworkError`. `false` falls back to the lowest-versioned otherwise-filtered candidate so installs do not stall on a freshly published package.

#### `minimumReleaseAgeIgnoreMissingTime`

- **Type**: boolean
- **Default**: `true`
- **Source**: `.npmrc minimum-release-age-ignore-missing-time=`

How to treat a candidate version whose packument has no `time[v]` entry. `true` admits it (some legacy / mirrored registries omit `time`); `false` rejects it as "too new to verify".

#### `minimumReleaseAgeExclude`

- **Type**: list of patterns (`name`, `@scope/name`, `@scope/*`)
- **Default**: empty
- **Source**: `.npmrc minimum-release-age-exclude=` (comma-separated)

Packages matching any pattern bypass the `minimumReleaseAge` filter.

#### `allowBuilds`

- **Type**: list of patterns (`name`, `name*`, `@scope/*`)
- **Default**: empty
- **Source**:
  - `npm` / `knot` mode: `package.json#knot.allowBuilds`
  - `pnpm` mode: `pnpm-workspace.yaml#allowBuilds`

A reviewed allowlist of packages whose install-time scripts may run. See [§6 Lifecycle scripts](#6-lifecycle-scripts) for the gate. The legacy pnpm key `package.json#onlyBuiltDependencies` is also accepted and unioned with `allowBuilds`.

```jsonc
// package.json
{
  "knot": {
    "allowBuilds": ["esbuild", "@swc/*"]
  }
}
```

#### `strictDepBuilds`

- **Type**: boolean
- **Default**: `false`
- **Source**: `.npmrc strict-dep-builds=`

`true` upgrades an unreviewed build-script-bearing dependency from a silent skip-with-warning to a hard install failure. pnpm v11 ships `true` by default; knot keeps `false` so existing pnpm projects can migrate without re-running an install audit.

#### `dangerouslyAllowAllBuilds`

- **Type**: boolean
- **Default**: `false`
- **Source**: `.npmrc dangerously-allow-all-builds=` or CLI `--allow-scripts=all`

Skips the [build-script gate](#6-lifecycle-scripts) entirely. Every package's `preinstall` / `install` / `postinstall` runs. The flag is named to discourage casual use.

#### `blockExoticSubdeps`

- **Type**: boolean
- **Default**: `false`
- **Source**: `.npmrc block-exotic-subdeps=` or `pnpm-workspace.yaml#blockExoticSubdeps`

When `true`, a **transitive** dependency declared via a git or https-tarball specifier is rejected unless its repository is on the `trustedExoticRepos` allowlist (currently `nodejs/node`, `oven-sh/bun`, `denoland/deno`). A **direct** exotic dependency declared in the root `package.json` is always allowed; the project author opted in explicitly.

#### `trustPolicy`

- **Type**: `off` | `no-downgrade`
- **Default**: `off`
- **Source**: `.npmrc trust-policy=` or `pnpm-workspace.yaml#trustPolicy`

`no-downgrade` refuses to resolve to a version below the highest version the project has previously installed for the same package. History is persisted alongside the lockfile. Defends against republish-based downgrade attacks.

#### `trustPolicyIgnoreAfter`

- **Type**: duration
- **Default**: unset (history kept forever)
- **Source**: `.npmrc trust-policy-ignore-after=`

Drop trust records older than this duration when evaluating `trustPolicy=no-downgrade`.

#### `signaturePolicy`

- **Type**: `none` | `weak` | `strict`
- **Default**: `none`
- **Source**: CLI `--enforce-signatures=`

Registry-attached ECDSA P-256 signatures over `<name>@<version>:<integrity>` are checked against the registry's public key.

- `none`: signatures are not verified.
- `weak`: when a signature is present it must verify; absence is allowed.
- `strict`: every tarball must carry a valid signature.

Signatures authenticate the registry, not the publisher.

#### `pmOnFail`

- **Type**: `ignore` | `warn` | `error`
- **Default**: `warn`
- **Source**: `.npmrc pm-on-fail=` or `pnpm-workspace.yaml#pmOnFail`

What knot does when `package.json#packageManager` or `package.json#devEngines.packageManager` pins a manager and version range that this knot binary does not satisfy.

| Value | Behavior |
|---|---|
| `ignore` | proceed |
| `warn` | emit a warning, proceed |
| `error` | fail the install |

`devEngines.packageManager.onFail`, when present, overrides this setting for the project where it appears.

#### `optimisticRepeatInstall`

- **Type**: boolean
- **Default**: `true`
- **Source**: knot internal default (no public flag)

When `true`, an `install` invocation hashes the project's `(package.json deps, package-lock.json bytes, engine key)` and compares to `node_modules/.knot/workspace-state.json`. On match, install returns successfully without running the resolver or touching the store. Suppressed when `--frozen-lockfile` is in effect.

#### `verifyDepsBeforeRun`

- **Type**: `off` | `warn` | `error` | `install` | `prompt`
- **Default**: `install`
- **Source**: `.npmrc verify-deps-before-run=` or `pnpm-workspace.yaml#verifyDepsBeforeRun`

Run by `knot run` / `knot exec` before invoking the requested script / binary. Computes the same hash as `optimisticRepeatInstall` and, on mismatch:

| Value | Behavior |
|---|---|
| `off` | proceed without checking |
| `warn` | print a warning, proceed |
| `error` | abort |
| `install` | run a fresh `knot install` first, then proceed |
| `prompt` | ask interactively (TTY only; non-TTY uses `error` semantics) |

#### `catalogMode`

- **Type**: `manual` | `strict` | `prefer`
- **Default**: `manual`
- **Source**: `.npmrc catalog-mode=` or `pnpm-workspace.yaml#catalogMode`

Governs how catalogs interact with workspace `package.json` ranges. See [§9 Catalogs](#9-catalogs).

#### `namedRegistries`

- **Type**: map `<alias>` → URL
- **Default**: `{ gh: "https://npm.pkg.github.com/" }`
- **Source**: `.npmrc named-registry-<alias>=<url>` (one line per alias) or `pnpm-workspace.yaml#namedRegistries`

Defines short aliases usable in registry selectors and dependency URLs. User entries are unioned with the built-in `gh:` alias; user values override the built-in for the same alias name.

#### `configDependencies`

- **Type**: map (`name` → `version` shorthand, or `name` → `{version, integrity}`)
- **Default**: empty
- **Source**: `package.json#configDependencies` (npm / knot mode) or `pnpm-workspace.yaml#configDependencies` (pnpm mode)

Declares packages that ship shared configuration (lint rules, prettier config, etc.) to be materialized under `node_modules/.knot-config/<name>/` rather than the standard `node_modules/`.

### 2.5 Lifecycle script environment

Lifecycle scripts (run by `knot install` / `knot run`) do not receive a copy of the host environment. knot forwards the following variables from `Platform.environment` when set, plus `PATH` (with the project's `node_modules/.bin` prepended) and the npm-style metadata variables:

| Forwarded | Set per-script |
|---|---|
| `HOME`, `USER`, `LOGNAME`, `SHELL`, `TERM`, `PWD`, `LANG`, `LC_ALL`, `LC_CTYPE`, `LC_MESSAGES`, `TMPDIR` (POSIX) | `npm_lifecycle_event` |
| `USERPROFILE`, `USERNAME`, `COMPUTERNAME`, `SYSTEMROOT`, `WINDIR`, `TEMP`, `TMP` (Windows) | `npm_package_name` |
| `NODE_OPTIONS`, `CI` | `npm_package_version` |
| `PATH` (with `node_modules/.bin` prepended) | `INIT_CWD` |

`npm_package_json` is not set even when present in the host environment. Any other variable is dropped.

---

## 3. Dependency specifiers

A value in `dependencies` / `devDependencies` / `optionalDependencies` / `peerDependencies` matches one of the following forms.

| Form | Example | Meaning |
|---|---|---|
| Semver range | `^1.2.0`, `>=2 <3`, `1.2.3` | Resolve via the configured registry against the named package's published versions. |
| Alias | `npm:react-native@^0.74.0` | Same as semver, but the resolved package's name is overridden by the alias prefix. |
| Workspace | `workspace:^`, `workspace:*` | Link to a workspace package (see [§8 Workspaces](#8-workspaces)). |
| File | `file:../shared-lib` | Pack the local directory into the store and link from there. |
| Link | `link:../shared-lib` | Create a direct symlink (no store copy). |
| HTTPS tarball | `https://example.com/pkg.tgz` | Download and ingest. |
| Git | `git+https://github.com/owner/repo.git#ref`, `github:owner/repo#ref` | Clone and pack. |
| Catalog | `catalog:`, `catalog:testing` | Resolve via the named catalog table (see [§9 Catalogs](#9-catalogs)). |

---

## 4. Lockfiles

### 4.1 `package-lock.json` (npm v3 shape)

Read and written in `npm` / `knot` mode. knot preserves two extensions on each package entry:

- `_signatures`: list of `{keyid, sig}` pairs captured at resolution time, used by [`signaturePolicy`](#signaturepolicy) to verify warm installs against the registry's signing key.
- `_scripts`: a copy of the package's `scripts` map for entries whose packument-slim form omits the bodies. Used so a warm install knows what to run without re-fetching the manifest.

Both fields are tolerated by npm; lockfiles round-trip without breaking interoperability.

### 4.2 `pnpm-lock.yaml`

Read in `pnpm` mode. The reader preserves every unknown top-level key so a subsequent write does not silently drop unfamiliar fields.

The writer produces block-style YAML. Output is **semantic-equivalent to input**, not byte-equivalent: comments, blank lines, and key ordering inside a map may change. Workflows that rely on stable diffs across pnpm-to-knot round trips are unsupported.

Recognized top-level sections: `lockfileVersion`, `settings`, `importers`, `packages`, `snapshots`, `catalogs`. Settings inside `settings` are interpreted as if they were in `pnpm-workspace.yaml`.

### 4.3 Workspace state

`<projectRoot>/node_modules/.knot/workspace-state.json` is written after every successful install. Schema:

```json
{
  "schemaVersion": 1,
  "hash": "<sha256 hex>",
  "engineKey": "<platform>;<arch>;node<major>",
  "installedAt": "<ISO 8601 UTC>",
  "knotVersion": "<semver>"
}
```

`hash` is the sha256 of canonical JSON of:

```
{
  "dependencies":         <sorted map>,
  "devDependencies":      <sorted map>,
  "optionalDependencies": <sorted map>,
  "peerDependencies":     <sorted map>,
  "lockfile":             "absent" | "sha256:<hex of lockfile bytes>",
  "engineKey":            "<engineKey>"
}
```

`engineKey`'s `<major>` is the major version pinned by `devEngines.runtime` when present, the value of `KNOT_HOST_NODE_MAJOR` otherwise, and `?` when neither is set. knot does not invoke `node` to detect a host major.

Consumers: [`optimisticRepeatInstall`](#optimisticrepeatinstall) and [`verifyDepsBeforeRun`](#verifydepsbeforerun).

---

## 5. CLI commands

Common conventions:

- Exit code `0` on success, `1` on a recoverable failure (failed install, audit findings ≥ configured level), `64` on usage error.
- Global flags: `--silent`, `--verbose` (`-v`), `--loglevel <silent|error|warn|info|debug|trace>`, `--json`, `--color`, `--version`.

| Command | Synopsis | Behavior |
|---|---|---|
| `install` | `knot install [--frozen-lockfile] [--ignore-scripts] [--allow-scripts=<none\|allowlist\|all>] [--min-release-age=<minutes>] [--enforce-signatures=<none\|weak\|strict>] [--audit-level=<low\|moderate\|high\|critical>] [--offline] [--prefer-offline] [--production] [--engine-strict]` | Resolve, fetch, ingest, link. Writes lockfile + workspace state. |
| `ci` | `knot ci` | Locked install. Equivalent to `install --frozen-lockfile`; aborts when the lockfile and `package.json` diverge. |
| `add` | `knot add <pkg>[@<spec>]...` | Add dependencies to `package.json` and install. |
| `remove` | `knot remove <pkg>...` | Remove from `package.json` and install. |
| `update` | `knot update [<pkg>...]` | Bump within declared ranges. |
| `list` | `knot list [<pkg>]` | Print the installed dependency tree. |
| `why` | `knot why <pkg>` | Print reverse-dependency paths leading to a package. |
| `outdated` | `knot outdated` | Print packages with newer versions available. |
| `view` | `knot view <pkg>[@<spec>] [<field>]` | Print packument data. |
| `pkg` | `knot pkg {get,set} <path> [<value>]` | Read or write fields in `package.json`. |
| `run` | `knot run <script> [-- <args...>]` | Run a script entry from `package.json#scripts`. Honors [`verifyDepsBeforeRun`](#verifydepsbeforerun). |
| `exec` | `knot exec <bin> [<args...>]` | Run a binary from `node_modules/.bin`. |
| `audit` | `knot audit [--ignore-ghsas=<csv>] [--level=<sev>] [--json]` | See [§7 Audit](#7-audit). |
| `doctor` | `knot doctor` | Print project mode, resolved registry, named registries, registry reachability. |
| `config` | `knot config {get,set,delete} <key> [<value>]` | Read or write `.npmrc` entries. |
| `clean` | `knot clean [--delete-lockfile] [--dry-run]` | Remove `node_modules/`; optionally remove the lockfile. |
| `peers` | `knot peers check` | Print unsatisfied or mis-versioned peer dependencies. Non-zero exit when any non-optional peer is unsatisfied. |
| `sbom` | `knot sbom [--format=<cyclonedx\|spdx>] [-o <file>]` | Emit CycloneDX 1.7 or SPDX 2.3 JSON. |
| `dlx` | `knot dlx [-p <pkg>...] [-c <bin>] [--offline] <pkg> [<args...>]` | See [§10 dlx](#10-dlx). |

---

## 6. Lifecycle scripts

knot runs three classes of lifecycle scripts:

- **Root preinstall** — `package.json#scripts.preinstall` of the project itself, before any resolution.
- **Per-dependency install-time** — `preinstall`, `install`, `postinstall` declared by an installed dependency.
- **Per-dependency prepare** — `prepare` declared by an installed dependency, after `install` / `postinstall`.

### 6.1 Build-script gate

A dependency is **build-script-bearing** if any of the following is true:

- `scripts.preinstall` is non-empty
- `scripts.install` is non-empty
- `scripts.postinstall` is non-empty
- a `binding.gyp` file exists at the package root
- a `.hooks/` directory exists at the package root

`prepare` is not a trigger.

Given the `scriptPolicy` (CLI `--allow-scripts`, default `allowlist`):

| `scriptPolicy` | `dangerouslyAllowAllBuilds` | Trigger? | In `allowBuilds`? | Action |
|---|---|---|---|---|
| `none` | — | — | — | skip all install-time scripts |
| `all` | — | — | — | run |
| `allowlist` | `true` | — | — | run |
| `allowlist` | `false` | no | — | run (no trigger to gate) |
| `allowlist` | `false` | yes | yes | run |
| `allowlist` | `false` + `strictDepBuilds=false` | yes | no | skip, emit warning |
| `allowlist` | `false` + `strictDepBuilds=true` | yes | no | fail the install |

### 6.2 Pattern matching for `allowBuilds`

A pattern matches the package's logical name if it is:

- An exact equality (`react` matches `react`).
- A scope wildcard ending `/*` (`@types/*` matches every package inside the `@types` scope).
- A trailing wildcard ending `*` (`@babel/preset-*` matches `@babel/preset-env`).

No other glob syntax is supported.

### 6.3 Script execution environment

See [§2.5 Lifecycle script environment](#25-lifecycle-script-environment).

A script is run via `/bin/sh -c <command>` on POSIX and `cmd.exe /C <command>` on Windows. Timeout defaults to 10 minutes; a script exceeding it is killed with SIGKILL.

---

## 7. Audit

`knot audit` posts a bulk advisory request to `<registry>/-/npm/v1/security/advisories/bulk` for every distinct `name@version` in the lockfile. Scope-specific registries are honored, so audits split across multiple registries when scopes are configured.

### 7.1 Ignore list

The set of GHSA IDs excluded from the report is the **union** of three sources, compared case-insensitively:

- `--ignore-ghsas=<csv>` on the command line
- `.npmrc ignore-ghsas=` (comma-separated)
- `package.json#knot.auditConfig.ignoreGhsas` (string list)

### 7.2 Audit on install

`knot install --audit-level=<sev>` runs an audit after the install completes and fails the install when any finding has severity at least `<sev>`. Default is unset (no post-install audit).

---

## 8. Workspaces

A workspace is declared in the root `package.json#workspaces` (string list or `{packages: [...]}`) or `pnpm-workspace.yaml#packages`. Globs follow the standard `**` / `*` semantics.

### 8.1 `workspace:` protocol

Forms in workspace package `package.json` dependencies:

| Form | Resolved to |
|---|---|
| `workspace:*` | the workspace's current version |
| `workspace:^` | `^<workspace version>` |
| `workspace:~` | `~<workspace version>` |
| `workspace:<range>` | the explicit range |

`workspace:` dependencies are linked rather than fetched from the registry. The destination is `node_modules/<name>` relative to the consuming workspace.

### 8.2 Workspace-to-workspace deps

When workspace `a` declares `workspace:` against workspace `b`, knot creates `a/node_modules/b -> b` (symlink). Transitive imports from `b` resolve via `b/node_modules/` per the standard Node module resolution.

---

## 9. Catalogs

A **catalog** is a `(name → range)` table defined in `pnpm-workspace.yaml`:

```yaml
catalogs:
  default:
    react: ^18.3.0
    react-dom: ^18.3.0
  testing:
    vitest: ^3.0.0
```

`catalogs.default` may also be written at the top level as `catalog` (singular).

### 9.1 Reference

A `package.json` references a catalog entry via the `catalog:` protocol:

| Form | Refers to |
|---|---|
| `catalog:` | the entry in `catalogs.default` |
| `catalog:<name>` | the entry in `catalogs.<name>` |

### 9.2 Modes (`catalogMode`)

| Value | Behavior |
|---|---|
| `manual` | `catalog:` references are resolved. Workspace `package.json` declarations that do not use `catalog:` are not affected. |
| `prefer` | When a package name has a catalog entry, the catalog range is used even if the workspace declared a different range. |
| `strict` | When a workspace declares a range that diverges from the catalog entry for the same name, the install fails. |

---

## 10. dlx

`knot dlx <pkg> [<args>...]` fetches a package into a per-spec cache and runs its binary. The project's `node_modules/` is not modified.

### 10.1 Cache

Cache root: `$HOME/.knot/dlx/<key>/`. `<key>` is the first 16 hex characters of `sha256(sorted "name@version" lines, newline-joined)` across the installed packages. Repeated invocations of the same spec reuse the cache; `knot clean` is responsible for pruning it.

### 10.2 Forms

| Invocation | Installed packages | Bin to run |
|---|---|---|
| `knot dlx <pkg>[@<spec>] [<args>...]` | `<pkg>` (default `latest`) | bin name = stripped scope of `<pkg>` |
| `knot dlx -p <pkg>... <bin> [<args>...]` | every `-p` spec | first positional |
| `knot dlx -p <pkg>... -c <bin> [<args>...]` | every `-p` spec | `<bin>` from `-c` |

`-c` / `--call` always wins; bin resolution otherwise consults the first installed package's `package.json#bin` (an entry matching the requested name, then — if exactly one bin is declared — that one bin's name).

### 10.3 Behavior

- Lifecycle scripts in the dlx target are **always** skipped. `dangerouslyAllowAllBuilds` does not apply.
- `optimisticRepeatInstall` is forced off so the cache directory is always re-linked.
- `--offline` forbids network; a cache miss exits non-zero.

---

Behavior of any command, setting, or file format from npm / pnpm that this document does not name is unspecified.

# tools/

Auxiliary scripts and sub-projects that don't belong inside the knot
package itself. The bucket holds both developer-facing helpers and a
CI-only verification tool.

| Path | Caller | Purpose |
|---|---|---|
| `test.sh` | developer (`./tools/test.sh`) | Builds the AOT `knot` binary once via `dart build cli`, exports `KNOT_TEST_BIN`, then runs `dart test`. CLI integration tests reuse the prebuilt binary instead of paying per-test JIT startup. |
| `aot_smoke/` | CI only (`.github/workflows/ci.yml` `aot-smoke` job) | Standalone Dart package whose binary exercises `boringssl_dart` ECDSA + SPKI parsing under AOT. Catches link-hook visibility / dlsym regressions that `dart test` (JIT) can't see. |
| `compat_test/` | developer (`dart run tools/compat_test/bin/run.dart`) | Runs `knot install` against the fixtures under `compat_test/fixtures/` and reports per-fixture exit codes. Requires `KNOT_NETWORK=1` because it hits the live npm registry. See `compat_test/README.md`. |

## What stays out of git

`.gitignore` here filters the per-fixture install artifacts
(`package-lock.json`, `pnpm-lock.yaml`, `knot-lock.yaml`) that
compat_test regenerates on every run. `node_modules/` and
`.dart_tool/` are already covered by the repo-root `.gitignore`.

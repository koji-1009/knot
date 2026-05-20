# compat_test

Reference projects used to validate knot's behavior against `npm` and `pnpm`.

Each fixture under `fixtures/` is a minimal project. For each one:

1. Install with `npm` (or `pnpm`); record `node_modules` shape + content hashes.
2. Install with `knot`; diff against the recorded baseline.
3. Run a smoke command (`node -e "require('<entrypoint>')"`).

The runner is intentionally separate from the unit-test suite — it depends on
the real npm registry and a working `node` binary on PATH, so it only runs in
CI's nightly job, not on every PR.

## Layout

```
tools/compat_test/
├── README.md              # this file
├── fixtures/
│   ├── next-app/          # Next.js minimal
│   ├── vite-react/        # Vite + React
│   ├── monorepo-pnpm/     # workspaces
│   ├── peer-deps-heavy/   # react ecosystem
│   └── native-modules/    # sharp / better-sqlite3
└── bin/
    └── run.dart           # runner that executes the diff
```

## Running locally

```
dart run tools/compat_test/bin/run.dart --fixture next-app
```

Requires `node`, `npm`, and `pnpm` on `PATH`.

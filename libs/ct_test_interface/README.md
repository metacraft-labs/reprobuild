# ct_test_interface

The cross-framework `TestBinary` contract. Per-framework adapters
(`ct_test_nim_unittest`, `ct_test_cargo`, …) `import ct_test_interface`
and produce typed handles that follow the conventions declared here.

Reprobuild's typed-output machinery (`outputs <field> is <Type>, <path>`)
recognises any output type whose Nim type ultimately satisfies these
conventions — for now, by carrying a `path: string` field and providing
`run`/`list`/`runTest` typed-tool dispatchers via UFCS.

## Types

- `TestBinary` — a base record with `path: string`. Per-framework handle
  types inherit (or otherwise expose a `path` field) so the reprobuild
  wrapper can populate them via `<HandleType>(path: <value>)`.

- `TestResultsHandle` — the typed output produced by `<handle>.run(...)`.
  Carries the path to the results file the test binary wrote.

- `TestCatalogHandle` — the typed output produced by `<handle>.list(...)`.
  Carries the path to the enumeration catalog the test binary wrote.

- `TestId` — a fully-qualified test name (`<suite>::<test>` per the
  codetracer parallel test framework spec).

## Future extensions

Once the `ct-test-runner` ships, this library will export:
- `TestRunSummary` (aggregate of pass/fail/skip counts + per-test results)
- Helpers for parsing `NIMTEST_RESULT_FILE` JSON
- Helpers for `--list-json` catalog parsing

Reprobuild only imports the type declarations; it never depends on
codetracer runtime code.

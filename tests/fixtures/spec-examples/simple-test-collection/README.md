# simple-test-collection

Minimal exercise of the `test` build graph collection plus the
`repro test` verb alias.

## What this fixture demonstrates

- The stdlib `test` template (per Package-Model §"The `test` template")
  auto-enrolls each test edge's *execute* edge into the project-scoped
  `test` build graph collection.
- `repro build test` materializes the union of every member of the
  `test` collection in one engine pass.
- `repro test` is the CLI alias for `repro build test`.
- Named-Targets resolution still works inside the collection: `repro
  build t_smoke` selects only the smoke test's execute edge; `repro test
  t_smoke` is the alias-shaped equivalent.

## Layout

```
simple-test-collection/
├── repro.nim          # The project DSL — two test edges declared via `test` template
├── src/
│   └── lib.nim        # The library under test (`add`, `subtract` procs)
└── tests/
    ├── t_smoke.nim
    └── t_arithmetic.nim
```

## Expected behaviour (once implementation lands)

| Command | Result |
|---|---|
| `repro test` | Compile + run both `t_smoke` and `t_arithmetic`. |
| `repro build test` | Same as `repro test` — the alias resolves to this. |
| `repro test t_smoke` | Compile + run only `t_smoke`. |
| `repro build` (no args) | Falls back to the project's default action (no test execution). |

## What's exercised vs. what's covered elsewhere

- This fixture does NOT use variants. The `test` collection is unaffected
  by variants here, so it isolates the collection-and-alias machinery.
- Per-case selection (`repro test t_smoke::case_x`) is not asserted here;
  it is covered by the test-edges campaign's `repro test foo::case_one`
  contract in Test-Edges-And-Parallel-Runner.milestones.org.

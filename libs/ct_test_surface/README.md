# ct_test_surface

Reads CodeTracer's published `ct test` catalog/provider surface.

`ct test discover` enumerates a source tree through CodeTracer's provider
registry and prints a catalog document. This library locates that binary,
drives it, parses the document, and reconstructs the identity CodeTracer gives
each case so a caller can compare its own case set against the surface's.

## What it is not

It is **not** the runner lookup. `scripts/run_tests.sh` and
`locateCtTestRunner` in `libs/repro_cli_support` resolve an *executor* — a
program handed a directory of compiled test binaries, via `--bin-dir=<dir>`.
`locateCtTestSurface` here resolves a *catalog* — `<bin> test discover
--workspace <root> …`, a program handed a source tree.

The difference that matters is the **input model**: compiled binaries versus
source, so there is no argv translation between the two. (The verb is a weaker
distinction than it looks, and not a reliable one to reason from — the runner
lookup's own two branches disagree about it. `run_tests.sh` passes `run` to a
resolved `ct-test-runner` and no verb at all to the `repro_test_runner`
fallback, which rejects `run`.) They are kept separate on purpose: merging
them would let "this repository consumes the canonical surface" be satisfied
by a rename.

## Lookup order

`$CT_TEST`, then `ct-test` on `PATH`, then `ct`. There is deliberately **no**
fallback to a repository-local runner; `tests/t_ct_test_surface_locator.nim`
pins that absence, because a fallback would let a caller measure the wrong
program and report success.

Set `$CT_TEST` to measure a specific build. The dev shell's `ct-test` comes
from the `codetracer-src` flake input, which the workspace `.envrc`
auto-overrides to a `../codetracer` sibling when one exists — so on a
workspace host it is not necessarily the pinned revision.

## Consumers

- `tests/integration/t_ct_test_surface_case_addressability.nim` — holds the
  tree to `benchmarks/reports/ct-test-surface-addressability.json`.
- `scripts/ct_test_surface_addressability.py` — regenerates that artifact.

## What a reconciliation built on this can and cannot see

`ctTestItemIdFor` lets a caller compare its own case set against the surface's
by identity. Two limits are worth knowing before trusting the resulting
percentage.

- **Discovery is a static scan and is blind to `when` selection.** It keeps
  both arms of a `when defined(…) / else`, so two declarations that can never
  coexist in one build can still reduce to a single identity — a `ct test`
  identity has no configuration dimension. (It does evaluate a literal
  `when false`.)
- **A case is a literal `test "…"` call.** A case declared through a
  project-local template is not in the catalog, and is equally invisible to
  this repository's own inventory scanner — so the two agree, and the case is
  still unaddressable. `benchmarks/reports/ct-test-surface-addressability.md`
  names the instances.

## Ambient execution

This library resolves a binary from `PATH` on purpose: the surface is a tool
the developer's shell provides, not something this repository builds. That is
the spec's PATH-only class, and the class requires the resolution to be
recorded rather than merely performed — so `CtTestSurface` carries the search
path, the resolved executable path, and which lookup step produced the answer,
and the evidence artifact carries the resolved binary's content hash. It is on
`scripts/ambient-execution-baseline.txt` for that reason.

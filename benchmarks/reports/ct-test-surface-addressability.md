# Reprobuild case addressability through the canonical `ct test` surface

Companion prose for `ct-test-surface-addressability.json`, which is the
machine-readable half and the one
`tests/integration/t_ct_test_surface_case_addressability.nim` holds the tree
to. Regenerate both with:

```sh
CT_TEST=<path to a ct-test build> \
CT_TEST_PROVENANCE="<what that build is>" \
  python3 scripts/ct_test_surface_addressability.py
```

## What was measured, and what it is not

CodeTracer publishes a test surface: `ct test discover` / `ct test run`,
driven by a provider registry. Reprobuild has always been able to enumerate
its own cases — a test binary built by the codetracer-nim fork answers
`--list-json` with a row per case — but that is Reprobuild reading a compiler
protocol, not Reprobuild reading CodeTracer's surface. This measurement is
about the surface.

It measures **addressability**: can every case this repository declares be
*named and selected* through `ct test`, under an identity that is stable, with
counts a machine can read? It says nothing about **execution**. The two are
separate and the second is not close: see "What the surface cannot do" below.

## Provenance

| | |
|---|---|
| Repository | `reprobuild`, `origin/dev` at `70801c670afafe9a381dacafb0f2002196d10e37`, plus the working-tree change that added this report and moved this suite's test sources onto `std/unittest` |
| Platform | Linux 6.12.85 x86_64, single host, no contention control |
| Surface | `ct-test`, built from `metacraft-labs/codetracer` `80c097309`, content hash `68f81fdcb9cc…`. That revision carries the import-clause fix described under "the multi-line-import rows" below. It has since landed on CodeTracer's `dev` as `632fdceed` — same tree — and `flake.lock` now pins `codetracer-src` at that commit, so the dev shell reproduces these numbers without `$CT_TEST` |
| Surface build | `nim c --threads:on --mm:orc --nimcache:build/nimcache/ct-test --out:build/bin/ct-test src/ct_test/ct_test.nim`, with `RUNQUOTA_SRC` set: the `ctTestTools` recipe in `flake.nix`, run against a checkout of that revision |
| Command | `ct-test test discover --workspace <repo> --json` |
| Discovery scope | `auto` — the surface's default, which is the workspace's own VCS inventory. Vendored `references/` trees and ignored paths are excluded |
| Ground truth | `benchmarks/reports/reprobuild-suite-m0-inventory-sources.json` (`staticCaseCount`), produced by a different scanner in a different language in a different repository |

**What the ground truth cannot see.** The two sides share no producer, which is
what makes their agreement informative. They do share a *definition*: both count
a case as a literal `test "…"` call in the source, and the checked-in inventory
carries no `--list-json`-derived count at all. A case declared through a
repository-local template appears in neither the numerator nor the denominator.
**94 such cases exist today, in 17 sources** — 13 through `testWithReturn` in
four `tests/integration/t_repro_test_runner_*` sources, and 81 through
`gatedTest`, a template that registers a case unconditionally and skips its
body with a reason on a host that cannot run it. The surface reports zero cases
for all 17, the inventory records zero, the two agree, and none of the 94 is
addressable through `ct test`. They belong to the gap between the percentages
below and "every logical Reprobuild case", and nothing in this measurement can
find them.

This number is worth watching rather than filing away, because the migration
recorded below changes how it reads. All 13 `gatedTest` sources are among the
38 that stopped importing the shim. Before that change they were themselves in
the not-addressable set, so a reader had no reason to credit them with
anything; after it they are discovered, and are reported as zero-case files
whose zero agrees with a zero-case ground truth. Their 81 cases were never in
either the numerator or the denominator and still are not. So the source
percentage rises by 13 sources that carry 81 cases the surface still cannot
name, and it does so without any line in the tables below moving to say so.
That is why the number is stated here: a coverage figure that reported only the
rise would be worth less than a smaller one that reported both.

**The measured binary was built by hand on purpose.** The dev shell also puts a
`ct-test` on `PATH`, and it is *not* necessarily this one: `ctTestTools` builds
from the `codetracer-src` flake input, and the workspace `.envrc`
auto-override redirects that input to a `../codetracer` sibling checkout
whenever one exists. Whichever binary is used, `$CT_TEST` is the supported way
to name it, and the artifact records the content hash rather than a host-local
path, so the numbers below can be tied to a build on any machine.

**The figures move with the surface, so the surface has to be stated.** A
`ct-test` older than `632fdceed` reads a Nim import clause one line at a time
and does not see `unittest` on a continuation line. Against this same tree such
a binary reports **46 fewer sources**: 1,434 of 1,482 (96.76%) and 8,085 cases,
with 48 rows in `unaddressableSources` rather than 2 — measured, not projected,
against the `ct-test` the dev shell puts on `PATH` here (content hash
`7b5d44071c04…`). That difference is not a property of the suite, and a reader
comparing two runs of this report needs the surface identity above to tell the
two causes apart.

**The figures in this report are now the surface this repository pins.** The
import-clause fix landed in CodeTracer as `632fdceed`, it is an ancestor of
CodeTracer's `dev`, and `flake.lock` pins `codetracer-src` at it. So a `ct-test`
the dev shell builds for itself carries the fix, and
`tests/integration/t_ct_test_surface_case_addressability.nim` — which compares
this ledger against whatever surface it finds, in both directions — passes all
six of its cases with no `$CT_TEST` override. This ledger is the repository's
own state rather than a projection of one.

One caveat survives, and it is a property of the workspace rather than of the
pin: the `.envrc` auto-override redirects `codetracer-src` to a `../codetracer`
sibling whenever one exists, so on a workspace host a sibling checked out behind
the pin — not the pin — is what the dev shell builds. If the two cases above
fail there, check the sibling's revision first.

## Result

| Measure | Value |
|---|---|
| Catalogs returned | 3 (`nim-unittest`, `python-unittest`, `assembly-fallback`) |
| Items returned | 10,525 — 8,510 cases, 2,015 suites |
| Error diagnostics | 0 |
| Tracked Nim suite sources | 1,482 |
| …addressable through the surface | **1,480 (99.87%)** |
| Tracked static case count | 8,371 |
| …addressable through the surface | **8,286 (98.98%)** |
| Per-source case-count agreement | 1,479 of 1,480 agree with the independent scanner |
| Distinct case identities vs case items | 8,498 distinct for 8,510 items — **12** collisions |

Per-source case counts are compared against a scanner that shares no code with
the surface, and they agree on 1,479 of 1,480 sources. That is the load-bearing
part of "the counts are machine-readable": they are not merely *emitted*, they
are *right*, checked against a producer that could have disagreed.

**Every case in the gap is accounted for by name**, not by an average. The 85
cases between 8,286 and 8,371 are 82 in the generated bundle (re-attributed, not
lost — see below), 2 in the one source that still speaks the shim protocol, and
1 dead case inside a `when false` that the ground truth counts and the surface
correctly does not.

**The one disagreement resolves in the surface's favour**, which is worth
saying because `caseCountDisagreements` is neutral about who is wrong.
`tests/e2e/m68/t_e2e_repro_home_depends_on_topological.nim` declares a fifth
case inside a `when false:` block — dead code, kept with a comment explaining
what will activate it. The inventory scanner counts it; `ct test` does not. Four
is the right answer, so the row is a defect in the ground truth rather than in
the surface. (Note the asymmetry with the identity collision below: the surface
evaluates a literal `when false` but not a `when defined(…)`, so it drops the
dead case here and keeps *both* arms there.)

## The 2 sources the surface cannot see, by cause

| Cause | Sources | Cases |
|---|---|---|
| Imports the vendored `ct_test_unittest_parallel` shim | 1 | 2 |
| Declares no cases of its own (an auto-generated bundle module) | 1 | 82 |

The full list, with a reason on every row, is `unaddressableSources` in the
JSON.

### What closed, and how

Two causes that between them accounted for 85 of the earlier 86 rows are gone.

**The multi-line-import rows (42 sources, 190 cases) were a defect in the
surface, and it was narrow.** The provider's framework scan was line-oriented:
it looked for a line beginning `import ` and parsed that line. A bracketed
clause such as

```nim
import std/[algorithm, os, osproc, streams, strtabs, strutils,
            tempfiles, times, unittest]
```

put `unittest` on a continuation line the scan never read, so the file was
never recognised as a unittest source and never scanned for declarations at
all — the failure was total per file. It was not silent, but the diagnostic it
emitted said the opposite of the truth: `info: no Nim unittest imports detected
in file`, for a file that plainly does import it, and indistinguishable from the
same line emitted correctly on ordinary non-test files. Reading an import clause
as a statement rather than as a line fixes it; the `ct-test` measured here does
that, and all 42 sources and all 190 cases are in the numerator above.

**The shim rows (43 sources, 57 cases) were this repository's own to close, and
38 of them are now closed.** The provider's `frameworkForImport` matches the
literal module names `unittest`, `unittest2` and `unittest_parallel`; those
files imported `ct_test_unittest_parallel`, which is none of them, so no
framework was detected and they fell through the same generic path as any
non-test source. Implementing `unittest_parallel` support upstream would not
have recovered a single row, because nothing here imports that module under that
name.

What made the shim removable is that it is no longer load-bearing.
`ct_test_unittest_parallel` exists to answer `--list` / `--list-json` / `--run`
and to write `$NIMTEST_RESULT_FILE`; the codetracer-nim fork has since put that
same protocol inside `std/unittest` itself, in a strictly larger form — it adds
`--catalog`, `bodyHash`, `group`, `threadsRequired`, `xfail`, `tags`,
`deterministic` and a column, and it keeps the protocol document off a stdout
that a suite body might also write to. So for a test source, `import
std/unittest` in place of `import ct_test_unittest_parallel` is a one-line
change that gains the fields this repository's own runner already reads. 38
sources took that change; per-source `--list-json` catalogs built before and
after are identical in case name, suite and line for all 38, 115 cases in
total.

One behaviour is narrower rather than wider, and it is named here rather than
rounded off: the shim's `--run` accepts a bare case name, a `suite::` prefix or
an empty selector as well as the full `suite::test`, while `std/unittest`
matches the full name and nothing else. Nothing in this repository relies on the
latitude — `tools/test-runner` passes back the `name` it read from the catalog,
which is always the full form — so no call site changes, but "strictly larger"
is true of the catalog and the result document rather than of the selector.

Four further rows were never shim rows at all. They import `std/unittest` in a
bracketed clause and merely *contain* the string `ct_test_unittest_parallel`,
inside triple-quoted fixture modules they compile at run time. The classifier
that wrote their reason searched the raw bytes of the file and attributed them
to the shim; it now reads a source with its comments and string literals
removed, and tests the bracketed-clause condition first, so a file that is
subject to both is reported under the one that actually binds.
`tests/unit/test_ct_test_surface_addressability.py` holds that behaviour, and
also re-derives every reason in this ledger from the source it names, so the
prose here cannot quietly go stale.

### What remains

**One source still speaks the shim protocol, and should.**
`libs/ct_test_unittest_parallel/tests/t_smoke_ct_test_unittest_parallel.nim` is
the shim's own smoke test: it calls `registeredTests()` and
`currentProtocolMode()` to assert that the shim's `suite`/`test` overrides
register the running binary's cases in-process, with the right file and line.
Moving it to `std/unittest` would not migrate the test, it would delete its
subject — the shim's registry is populated only by the shim's own `test`
override. Its 2 cases are addressable through the shim's `--list-json`, and are
run by this suite; they are not addressable through `ct test`, and will not be
for as long as the shim is worth having a test for.

**The one bundle row is a re-attribution, not a loss.** `tests/bundles/
bundle_repro_solver_pure_unit.nim` is generated, imports 24 solver test
modules and declares nothing itself. All 24 of those modules *are* discovered,
under their own identities, so its 82 cases are addressable — they are simply
not addressable *under the bundle's* name. They are counted as lost above
because the honest denominator is the tracked entry, and double-counting them
would flatter the result. Making the row disappear would need a decision on
which side owns the duplication: the surface would have to follow a Nim
`import` of a test module and re-attribute the imported module's cases to the
importing file, which would put all 82 into the catalog twice under two
different files and turn them into 82 identity collisions; or the inventory
would have to stop attributing member cases to the aggregator, which is a change
to this repository's scanner and not to `ct test`. Neither is attempted here.

## Identity stability

Identities are `<provider>/<language>/<framework>/<file>::<selector>`, e.g.

```
nim-unittest/nim/std/unittest/libs/ct_test_interface/tests/t_smoke_ct_test_interface.nim::t_smoke_ct_test_interface::t_smoke_ct_test_interface
```

Two properties were checked, both by the test rather than by inspection:

* **Stable across invocations and scopes.** For a named six-source subset, the
  ids from the workspace-wide catalog are byte-identical to the ids from a
  per-file `--file` discovery, and each is exactly what the documented mapping
  predicts from that item's own file, suite and case name.
* **Unique across the whole catalog, bar 12 rows, and all 12 are the same
  thing.** The identity is a slug — lowercased, whitespace collapsed to
  hyphens, `--` collapsed — so collisions are possible in principle. Across all
  8,510 case items there are 12, listed with their sites in
  `identityCollisions`. They fall across seven files, and every one of them is a
  pair of declarations in *mutually exclusive* arms of a `when`: `when not
  defined(windows): … else: …` in four files (m74, m75, m76, m83), `when
  defined(vmHarnessAvailable)` in two (`t_r2_iso_boot`, `t_r9_systemd_boot`),
  and `when defined(macosx) or defined(linux)` in the last
  (`t_e2e_repro_watch_multiple_named_targets`). At most one of each pair exists
  in any build — the compiled binary has one case with that name and nothing to
  disambiguate.

  The collisions are therefore an artifact of configuration-blind static
  discovery, which the surface and this repository's own inventory scanner
  share, and not duplications a developer can remove. They cost no coverage;
  what they show is that a `ct test` identity has no configuration dimension, so
  it cannot say *which* `when` arm it names.

  Eleven of the twelve are newly *visible* rather than newly created: the files
  that declare them were not discovered at all before, so their collisions could
  not be counted. Making a source addressable is what exposes this property of
  the identity, which is the honest order for a number to arrive in.

## What the surface cannot do

`ct test run` cannot execute a single case in this repository. This is
declared rather than incidental — the Nim provider's own `TestCapabilities`
carry `canRunProject = false`, `canRunFile = false`, `canRunSingle = false` —
and it was run rather than inferred:

```
$ ct-test test run --workspace <repo> --threads 4 --no-certificate
{"total": 10525, "dispatched": 10525, "executed": 0, "skipped": 0,
 "skipped_by_partition": 0, "passed": 0, "failed": 0, "unrunnable": 10523,
 "wall_time_ms": 111, "threads": 4, "verdict": "nothing-executed"}
errors: "provider 'nim-unittest' cannot run 10409 of the units dispatched to
         it, so they were discovered but never executed"
         "provider 'python-unittest' cannot run 114 …"
exit 2
```

Nothing is hidden: the surface reports the refusal as machine-readable
`unrunnable` counts, a per-provider `errors` array, and a distinct exit code
for "no test ran at all". The capability simply is not there yet.

This is why `scripts/run_tests.sh` was **not** changed to accept `ct-test` as
its runner. That lookup resolves an executor — `<bin> run --bin-dir=<dir>
--summary-json=<p> --results-dir=<d>` — and `ct test` differs from it in the
verb, in the input model (a source tree, not a directory of compiled
binaries), and in whether it can run anything at all. Teaching the lookup to
accept it by name would have produced a suite that executes zero tests. The
lookup now carries that reasoning in a comment where the next reader will find
it.

## Independence from the Reprobuild-only runner

Nothing in this measurement runs, links, or reads output from
`repro_test_runner`. Two structural facts make that checkable rather than
asserted:

1. The ground truth is the inventory artifact, produced by a separate scanner.
2. The test's last case points `$CT_TEST` at `build/bin/repro_test_runner` and
   requires the very first step — obtaining a catalog document — to fail. It
   does: `repro_test_runner test discover --workspace … --json` answers
   `repro_test_runner: unexpected positional: test`. Removing that redirection
   so the real surface is used instead makes the case fail, which is what
   shows the control discriminates rather than passing vacuously.

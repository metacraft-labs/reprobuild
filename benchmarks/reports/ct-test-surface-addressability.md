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
| Repository | `reprobuild`, `origin/dev` at `c1b231baa443d066f74197b4ccc49b99afd1cd31`, plus the working-tree change that added this report |
| Platform | Linux 6.12.85 x86_64, single host, no contention control |
| Surface | `ct-test`, built from `metacraft-labs/codetracer` `e1b5280a2755f4c5016679610d208e5b94d1d5ec` — the `codetracer-src` revision pinned in `flake.lock` at the commit above |
| Surface build | `nim c --threads:on --mm:orc --nimcache:build/nimcache/ct-test --out:build/bin/ct-test src/ct_test/ct_test.nim`, with `RUNQUOTA_SRC` set: the `ctTestTools` recipe in `flake.nix`, run against a checkout of the pin |
| Command | `ct-test test discover --workspace <repo> --json` |
| Discovery scope | `auto` — the surface's default, which is the workspace's own VCS inventory. Vendored `references/` trees and ignored paths are excluded |
| Ground truth | `benchmarks/reports/reprobuild-suite-m0-inventory-sources.json` (`staticCaseCount`), produced by a different scanner in a different language in a different repository |

**What the ground truth cannot see.** The two sides share no producer, which is
what makes their agreement informative. They do share a *definition*: both count
a case as a literal `test "…"` call in the source, and the checked-in inventory
carries no `--list-json`-derived count at all. A case declared through a
repository-local template appears in neither the numerator nor the denominator.
Nine such cases exist today — the `testWithReturn` template in the four
`tests/integration/t_repro_test_runner_*` sources that define it. The surface
reports zero cases for those four files, the inventory records zero, the two
agree, and the cases are still not addressable through `ct test`. They belong to
the gap between the percentages below and "every logical Reprobuild case", and
nothing in this measurement can find them.

**The pinned binary was built by hand on purpose.** The dev shell also puts a
`ct-test` on `PATH`, and it is *not* necessarily this one: `ctTestTools` builds
from the `codetracer-src` flake input, and the workspace `.envrc`
auto-override redirects that input to a `../codetracer` sibling checkout
whenever one exists. On the host this was measured on, that sibling was at
`8bc496724`, which is **not** a descendant of the pin and lacks work the pin
carries. A measurement against it would have been a measurement of one
developer's checkout.

Both builds were nonetheless run against this suite, and the comparison is
worth recording: two `ct-test` binaries with different content hashes
(`bc12a52262e2…` from the pin, `7b5d44071c04…` from the sibling) produce
**byte-identical** `counts`, `reconciliation`, `unaddressableSources`,
`caseCountDisagreements` and `identityCollisions`. Everything below is
therefore a property of the suite and of the provider's scanning rules, not of
one build — but only the pin is a reproducible identity, so the pin is what the
artifact records.

## Result

| Measure | Value |
|---|---|
| Catalogs returned | 3 (`nim-unittest`, `python-unittest`, `assembly-fallback`) |
| Items returned | 10,138 — 8,238 cases, 1,900 suites |
| Error diagnostics | 0 |
| Tracked Nim suite sources | 1,480 |
| …addressable through the surface | **1,394 (94.19%)** |
| Tracked static case count | 8,358 |
| …addressable through the surface | **8,028 (96.05%)** |
| Per-source case-count agreement | 1,393 of 1,394 agree with the independent scanner |
| Distinct case identities vs case items | 8,237 distinct for 8,238 items — **one** collision |

Per-source case counts are compared against a scanner that shares no code with
the surface, and they agree on 1,393 of 1,394 sources. That is the load-bearing
part of "the counts are machine-readable": they are not merely *emitted*, they
are *right*, checked against a producer that could have disagreed.

**The one disagreement resolves in the surface's favour**, which is worth
saying because `caseCountDisagreements` is neutral about who is wrong.
`tests/e2e/m68/t_e2e_repro_home_depends_on_topological.nim` declares a fifth
case inside a `when false:` block — dead code, kept with a comment explaining
what will activate it. The inventory scanner counts it; `ct test` does not. Four
is the right answer, so the row is a defect in the ground truth rather than in
the surface. (Note the asymmetry with the identity collision below: the surface
evaluates a literal `when false` but not a `when defined(…)`, so it drops the
dead case here and keeps *both* arms there.)

## The 86 sources the surface cannot see, by cause

| Cause | Sources | Cases |
|---|---|---|
| Imports the vendored `ct_test_unittest_parallel` shim | 43 | 57 |
| `import std/[… unittest …]` spanning more than one line | 42 | 190 |
| Declares no cases of its own (an auto-generated bundle module) | 1 | 82 |

The full list, with a reason on every row, is `unaddressableSources` in the
JSON.

**The shim rows are not what they were first written up as.** They are the 43
sources that speak this repository's *other*, divergent protocol
implementation — the one whose removal is already the subject of a separate
decision — and that part is right. What is *not* right is "the provider detects
`unittest_parallel` and declares it not implemented". It does no such thing
here. `frameworkForImport` matches the literal module names `unittest`,
`unittest2` and `unittest_parallel`; these files import
`ct_test_unittest_parallel`, which is none of them. No framework is detected,
the "detected but not implemented in M2" warning is never emitted — the
workspace response contains **zero** of them — and the files fall through the
same generic path as any non-test source.

The practical consequence is the opposite of the original framing: implementing
`unittest_parallel` support upstream would **not** recover these 43 rows,
because nothing in this repository imports that module under that name.
Retiring the shim would.

**The 42 multi-line-import rows are a defect in the surface, and it is
narrow.** The provider's framework scan is line-oriented: it looks for a line
beginning `import ` and parses that line. A bracketed clause such as

```nim
import std/[algorithm, os, osproc, streams, strtabs, strutils,
            tempfiles, times, unittest]
```

puts `unittest` on a continuation line the scan never reads, so the file is
never recognised as a unittest source and is never scanned for declarations at
all. The failure is total per file. It is **not silent** — an earlier draft of
this report said it was — but the diagnostic it emits states the opposite of the
truth: `info: no Nim unittest imports detected in file`, for a file that plainly
does import it. That row is one of 206 identical ones in the workspace response —
86 on the sources tabled here and 120 on ordinary non-test files where it is
simply true — so nothing distinguishes a real drop from routine noise. A wrong diagnostic buried in 206
correct ones is not much better than none, but the distinction matters to any
claim about whether the surface reports its refusals. Two variants hit the same
bug — the
`unittest` entry on a later line, and an `import std/[unittest, …` whose
closing bracket is on a later line.

Joining bracketed import clauses before scanning recovers all 42 sources and
190 cases; nothing else about the provider needs to change. That is measured,
not projected: a mechanical bracket-join applied to every one of the 42, with
`discover --file` re-run on each, recovers 42 of 42 — none stays at zero, and
every file lands on exactly the case count the inventory records, 190 in total.

**The one bundle row is a re-attribution, not a loss.** `tests/bundles/
bundle_repro_solver_pure_unit.nim` is generated, imports 24 solver test
modules and declares nothing itself. All 24 of those modules *are* discovered,
under their own identities, so its 82 cases are addressable — they are simply
not addressable *under the bundle's* name. They are counted as lost above
because the honest denominator is the tracked entry, and double-counting them
would flatter the result.

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
* **Unique across the whole catalog, with one exception.** The identity is a
  slug — lowercased, whitespace collapsed to hyphens, `--` collapsed — so
  collisions are possible in principle. Across all 8,238 case items there is
  exactly one: `tests/e2e/watch/t_e2e_repro_watch_multiple_named_targets.nim`
  declares two suite/case pairs with identical titles at lines 211 and 319.

  The two are in *mutually exclusive* arms of a
  `when defined(macosx) or defined(linux): … else: …`, so at most one of them
  exists in any build — the compiled binary has one case with that name and
  nothing to disambiguate. The collision is therefore an artifact of
  configuration-blind static discovery, which the surface and this
  repository's own inventory scanner share, and not a duplication a developer
  can remove. It costs no coverage; what it shows is that a `ct test` identity
  has no configuration dimension, so it cannot say *which* `when` arm it names.
  It is recorded because "stable identities" would otherwise be a claim nobody
  had counted.

## What the surface cannot do

`ct test run` cannot execute a single case in this repository. This is
declared rather than incidental — the Nim provider's own `TestCapabilities`
carry `canRunProject = false`, `canRunFile = false`, `canRunSingle = false` —
and it was run rather than inferred:

```
$ ct-test test run --workspace <repo> --threads 4 --no-certificate
{"total": 10138, "dispatched": 10138, "executed": 0, "skipped": 0,
 "skipped_by_partition": 0, "passed": 0, "failed": 0, "unrunnable": 10136,
 "wall_time_ms": 242, "threads": 4, "verdict": "nothing-executed"}
errors: "provider 'nim-unittest' cannot run 10039 of the units dispatched to
         it, so they were discovered but never executed"
         "provider 'python-unittest' cannot run 97 …"
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

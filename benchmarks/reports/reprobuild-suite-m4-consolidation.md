# Reprobuild Suite M4: Pure-Unit Consolidation Measurement

M4 asks whether merging pure-unit tests into shared protocol-aware binaries
reduces the suite's build cost. This report answers that with measurement.

The answer is a qualified yes: consolidation cuts build cost by roughly an
order of magnitude for the groups measured, **and** it is bounded by a
correctness limit that arrives before the cost optimum does. Two of the three
groups measured produced cases that pass alone and fail merged. The binding
constraint on M4 is therefore isolation, not cost.

## Provenance

| Field | Value |
| --- | --- |
| HEAD | `e0e4b4379d378f8ed3f3dfc9c38c44e71c88507e` |
| Toolchain | the Nim pin in which a failing `check` inside a helper `proc` fails its test |
| Host | 32 logical cores, shared, load average 20-98 across the campaign |
| Compile command | `nim c --threads:on --hints:off --warnings:off --nimcache:<private> --out:<private> <source>` under `nix develop --command` |
| Cost metric | CPU seconds (`user`+`sys`) of the compile process tree |
| Init metric | `getrusage(RUSAGE_CHILDREN)` delta over one child invocation, best of 3 |

Wall-clock is reported where taken but is not the basis of any claim here: the
host carried other users' load throughout, and a measurement whose timings are
a function of our own load is not measuring the tree. CPU seconds are stable
under contention and are what CI is billed for.

Every binary in this report was compiled fresh against the current toolchain
pin. No number here is read from a pre-existing binary.

## Re-derived inventory

Recomputed rather than carried forward, because the graph has moved:

| Metric | Value |
| --- | --- |
| Nim test binaries | 1,239 |
| Test entries (Nim + Python) | 1,244 |
| Cases, catalog-authoritative | 6,966 (6,916 Nim + 50 Python) |
| Pure unit | 628 (624 Nim, 4 Python) |
| Integration | 510 |
| Platform/destructive | 90 |
| Graph-fixture | 16 |
| Consolidation groups (>= 2 members) | 42 |
| Grouped members / cases | 537 / 3,175 |
| Duplicate `suite::test` names, suite-wide | 0 |

The pure-unit count reproduces the campaign's earlier 624. The group count is
**42**, not the 40 carried in planning notes.

### What "pure unit" actually means here

The classifier's `pure unit` is a *residual* class, not a positive test of
purity: an entry is pure unit when it is not on a platform/destructive path,
not under `tests/e2e/` or `tests/integration/`, does not require the `repro`
binary, does not compile a fixture, and contains none of the literals
`build/bin/repro`, `reproBin`, `execCmdEx(`, `startProcess(`, `runShell(`.

It does not test for network use, daemons, temp-directory confinement, or
shared global state. Scanning the 624 Nim pure-unit sources for the stricter
properties M4 cares about:

| Property present | Count of 624 |
| --- | --- |
| spawns a subprocess (incl. `execProcess`, which the classifier misses) | 9 |
| touches a network API | 4 |
| mutates process environment (`putEnv`/`delEnv`) | 48 |
| mutates the working directory | 3 |
| creates threads | 35 |
| writes files | 171 |

So the label is weaker than the criterion M4 needs, and the gap is
load-bearing: both groups in which consolidation produced failures below were
drawn entirely from the pure-unit set.

## The run-side cost, and why it is not free

The test runner executes **one process per case** (`--run "suite::test"`).
Whole-binary execution exists only as a fallback for binaries whose
`--list-json` cannot be enumerated; there is no batching mode for
protocol-aware binaries. Consequently every case in a bundle pays that bundle's
entire module-initialization cost, once per case:

```
run cost = (binaries x init) + (cases x (init + case body))
```

Measured case bodies in these groups are ~1-4 ms, so per-case run cost *is* the
init cost. This is the term that can turn a build win into a net loss.

### Init cost is flat for most groups and explosive for one

| Group | Members | Bundle init CPU | Standalone init CPU |
| --- | --- | --- | --- |
| `libs/repro_solver` | 24 | 0.006 s | 0.006 s |
| `libs/repro_peer_cache` | 48 | 0.009 s | 0.009 s |
| `recipes/packages/source` | 4 | 1.481 s | 0.009 s |
| `recipes/packages/source` | 32 | 1.965 s | 0.009 s |
| `recipes/packages/source` | 40 | 17.367 s | 0.009 s |
| `recipes/packages/source` | 96 | 305.972 s | 0.009 s |
| `recipes/packages/source` | 196 | 825.863 s | 0.009 s |

The from-source recipe family is the outlier, and the cause is specific: each
`package` declaration finalizes its variant context at module init by running
an ASP solve, and the pending-package registry accumulates across every recipe
in the process. Recipe *k*'s solve therefore concretizes packages 1..*k*. One
recipe per process costs 9 ms; 196 in one process cost 826 s.

Nothing outside that family showed any init penalty at all.

## Recipe group: the crossover

196 sources, 1,058 cases. Standalone build cost 174.2 CPU s/test (8 samples).

| n | binaries | build CPU s | run CPU s | total CPU s | vs n=1 | per-case verdict |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 196 | 34,143 | 11 | 34,154 | 1.00x | 8/8 pass |
| 4 | 49 | 14,832 | 1,639 | 16,472 | 2.07x | 22/22 pass |
| 8 | 25 | 7,915 | 1,792 | 9,707 | 3.52x | 58/58 pass |
| 16 | 13 | 4,896 | 2,127 | 7,023 | 4.86x | 106/106 pass |
| 24 | 9 | 3,712 | 1,992 | 5,704 | 5.99x | 145/147 pass, **2 FAIL** |
| 32 | 7 | 3,387 | 2,093 | 5,480 | 6.23x | 191/200 pass, **9 FAIL** |
| 40 | 5 | 3,441 | 18,461 | 21,902 | 1.56x | not run |
| 48 | 5 | 3,488 | 17,747 | 21,235 | 1.61x | not run |
| 96 | 3 | 4,448 | 324,636 | 329,085 | **0.10x** | not run |
| 196 | 1 | 2,598 | 874,589 | 877,187 | **0.04x** | not run |

Two crossovers, and the second one arrives first:

* **Cost crossover.** Consolidating the whole group into one binary is 25.7x
  *worse* in total CPU than not consolidating at all. The cost optimum is near
  n=32.
* **Correctness crossover.** Cases begin failing at n=24 — below the cost
  optimum. The cost optimum is not reachable.

## The failures are contamination, verified by isolation

At n=32, nine cases fail; at n=24, two. All are registry-lookup assertions
(`registeredArtifacts`, `registeredVersions`). Every one of them passes in its
own binary: the standalone `expat` binary runs 8/8, including the two cases
that fail at n=32.

Two hypotheses were tested and both were falsified, which is why the conclusion
is stated as it is:

* *A specific colliding pair (`dbus` + `dbus-broker`).* A 2-member bundle of
  exactly that pair passes 16/16.
* *A property of the member set.* An 8-member window containing that pair and
  its neighbours passes 41/41.

What survives is accumulation: the failure depends on how many recipes share
the process, not on which. That restores a size cap as the right control, but
sets it by correctness at **n <= 16** on this evidence — and n=16 is a bound we
failed to falsify, not one we proved.

`libs/repro_peer_cache` shows a second, independent contamination: all 68 cases
pass individually under `--run`, but the merged binary run whole exits 1 with
67 OK / 1 FAILED — an `OSError` in the multicast CIDR test, which binds a fixed
`MulticastPort` and shares a process-global `asyncdispatch` loop with its
neighbours. That case passes standalone. The runner's per-case path does not
hit this, but its non-enumerable fallback path does, so a merged binary that
ever fails to enumerate would report a failure that does not exist.

## What consolidation buys where it is safe

| Group | Members | Before (CPU s) | After (CPU s) | Ratio | Binaries | Init change | Per-case | Whole-binary |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `libs/repro_solver` | 24 | 1,199 | 127 | **9.4x** | 24 -> 1 | none | 82/82 pass | rc=0 |
| `libs/repro_peer_cache` | 48 | 9,600 | 468 | **20.5x** | 48 -> 1 | none | 68/68 pass | rc=1, 1 FAIL |
| `recipes/...` @ n=16 | 196 | 34,143 | 4,896 | **7.0x** | 196 -> 13 | +2,116 s run | 106/106 pass | not run |

Across the three groups measured — 268 of the 537 grouped members — build cost
falls from 44,943 to 5,492 CPU seconds (**8.2x**) and binaries from 268 to 15.

The per-test standalone figures are sample means (8 recipe, 4 peer cache, 4
solver) extrapolated across each group's membership; the bundle figures are
whole-group measurements, not extrapolations.

The remaining 39 groups were not measured. Nothing here licenses extrapolating
their per-test cost or their isolation behaviour.

### Artifact footprint

Where the build cost goes is visible in the generated C. A single test binary
emits ~220 C files, and almost all of them are the shared library closure
recompiled into that binary's own private nimcache — which is why 1,239
binaries cost what they do.

| Unit | C files | nimcache | binary |
| --- | --- | --- | --- |
| one recipe test, alone | 220 | 3.8 MB | 1.8 MB |
| 32 recipe tests, bundled | 431 | 13 MB | 6.9 MB |
| one peer-cache test, alone | 54-73 | 1.8-3.4 MB | - |
| 48 peer-cache tests, bundled | 143 | 8.4 MB | 5.6 MB |
| one solver test, alone | 26-35 | 0.5-1.0 MB | - |
| 24 solver tests, bundled | 60 | 2.8 MB | 2.0 MB |

Bundling 32 recipe tests replaces ~122 MB of nimcache with 13 MB (9.4x) and 32
binaries totalling ~57 MB with one of 6.9 MB. The peer-cache group replaces
~125 MB with 8.4 MB (15x); the solver group ~18 MB with 2.8 MB (6.5x). The C
file counts show why the saving is structural rather than incidental: 32
bundled recipe tests emit 431 C files where 32 separate binaries emit ~7,000,
because the closure is compiled once instead of 32 times.

## Case identity and addressability survive

For every bundle built, the catalog was compared against the union of its
members' individual catalogs:

| Bundle | Members | Expected union | Enumerated | Missing | Extra |
| --- | --- | --- | --- | --- | --- |
| recipes | 196 | 1,058 | 1,058 | 0 | 0 |
| recipes | 32 | 200 | 200 | 0 | 0 |
| peer cache | 48 | 68 | 68 | 0 | 0 |
| solver | 24 | 82 | 82 | 0 | 0 |

No case is dropped and none is invented. Every case remains individually
selectable: `--run "suite::test"` addressed each one, and all 6,916 Nim case
names in the suite are already globally unique, so the binary boundary was
never carrying identity.

Of the retained protocol fields (`suite`, `name`, `test`, `file`, `line`,
`column`, `kind`, `group`, `threadsRequired`, `xfail`, `tags`, `deterministic`)
exactly one moves: `bodyHash`, for 792 of 1,058 recipe cases, 47 of 68 peer
cache, 55 of 82 solver. That is a one-off re-run of the affected cases for
hash-difference selection, not a loss of identity. `file` is unchanged because
a bundle placed outside the member's directory falls back to the same basename
the member reported on its own.

## Assessment against the M4 exit gate

> M4 exits only after small ownership/dependency-compatible consolidation
> batches preserve every logical identity and case, isolation, selection, and
> regressions while reducing measured binary/artifact cost.

Not met, and the gap is specific:

* **Identity, case count, selection** — met, and measured, for all four bundles.
* **Measured cost reduction** — met for the groups measured: 8.2x build CPU
  over half the grouped population.
* **Isolation** — *not* met. Two of three groups produced cases that pass alone
  and fail merged. Until each candidate group has that property verified, no
  batch should land.
* **Batches landed** — none. This report deliberately changes no build graph.

Two of the milestone's open questions are now answered by measurement rather
than argument: the maximum shared-binary size for the recipe family is <= 16
and is set by correctness, and the recipe family is the only one of the three
measured that has a size limit at all.

## Campaign claims this measurement retires

Two things repeated in this campaign's planning notes are not true of the
current tree, and are recorded here so they stop being cited as constraints:

* **`synthesize{Meson,Cmake}Package` "cannot be called twice per process."**
  Already fixed in-tree. `withOwningPackage` /
  `setCurrentOwningPackageOverride` scopes each synthesized package's implicit
  target exports to the consuming recipe, and the source comment in
  `libs/repro_dsl_stdlib/src/repro_dsl_stdlib/synthesis/from_source_default_build.nim`
  documents the repair. It is not a consolidation blocker.
* **"36 binaries `quit(0)` at module init."** The real figure is 11 files
  containing a module-init `quit(`, of which exactly one is classified pure
  unit (`libs/repro_dsl_stdlib/tests/t_smoke_expand_archive.nim`, which carries
  a self-exec subprocess mode). The rest are integration tests, which are not
  consolidation candidates.

The genuine process-sharing hazards are the ones measured above — the
accumulating module-init solve, and fixed-port/global-dispatcher tests — not
these two.

## Batch landed: `libs/repro_solver`

The solver group is consolidated: 24 sources folded into
`tests/bundles/bundle_repro_solver_pure_unit.nim`, one binary
`build/test-bin/bundle_repro_solver_pure_unit`.

| Property | Before | After |
| --- | --- | --- |
| Nim test binaries (suite-wide) | 1,239 | 1,216 |
| Test entries (suite-wide) | 1,244 | 1,221 |
| Catalog-source bucket | 1,238 | 1,215 |
| **Nim cases (`nim_total`)** | **6,916** | **6,916** |
| **Total cases** | **6,966** | **6,966** |
| Group build cost | 1,199 CPU s | 127 CPU s |
| Consolidation groups | 42 | 41 |

Verified by execution after a rebuild, not read from a pre-existing binary:
82 cases enumerated, exactly the union of the 24 members' catalogs, zero
missing and zero extra; 82/82 pass individually under `--run`; the binary exits
0 run whole; `bodyHash` moves for 55 of 82 and no other protocol field moves.

The static source scan follows a bundle into its members rather than reading
the aggregator flat, so it still corroborates the catalog independently: both
surfaces are unchanged at 6,838 static and 6,916 catalog. Without that, the
static sum would have silently dropped 82 while `nim_total` held — every total
still explainable, and the cross-check gone.

**This batch clears one group. The other 41 are not cleared by it.** Membership
is an explicit list in the generator rather than a directory glob precisely so
a newly added test cannot join a shared process without a human deciding it
tolerates neighbours.

## Recommended next batch

`libs/repro_peer_cache` is the largest measured prize at 20.5x, but it must
first either fix the fixed-port multicast test or model its isolation
explicitly — it is the group whose merged binary exits 1 run whole.

The recipe family should not be consolidated on the strength of this report.
Its 16-per-binary figure is **a bound we failed to falsify, not a measured
limit**: bundles of 4, 8 and 16 ran clean, 24 and 32 did not, and nothing here
establishes that some other set of 16 would pass. Treating 16 as a proven
ceiling would be reading this artifact for more than it says. The accumulating
module-init solve underneath it is also a product-level cost that applies to
any real project declaring many packages in one process; that is worth
understanding before it is worked around with a bundle-size cap.

## Reproduction

The prototype bundles are generated import-only modules — one `import "<member>"`
per line — compiled as ordinary main modules. No member source was edited.
Bundling by `import` rather than `include` is what keeps member module scopes
separate and avoids top-level symbol collisions between test files.

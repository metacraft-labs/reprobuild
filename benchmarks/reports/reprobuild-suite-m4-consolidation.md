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

So the label was weaker than the criterion M4 needs, and the gap was
load-bearing: both groups in which consolidation produced failures below were
drawn entirely from the pure-unit set.

### The predicate that replaced it

`pure unit` is no longer a residual. Membership is granted on evidence, and the
decisive check is an **allowlist of imports** rather than a denylist of
primitives: a test cannot spawn, listen, dlopen or signal without reaching a
module that grants it, so naming the modules a pure unit may use fails closed
against primitives nobody has enumerated. `execProcess` slipping past the old
pattern list is exactly the failure a denylist repeats.

An entry that cannot be shown safe is **refused**, not defaulted to pure:
`unclassified` is a real outcome and keeps the entry out of every consolidation
group, which is the only decision this class feeds.

| Class | Before | After |
| --- | --- | --- |
| pure unit | 605 | 500 |
| unclassified | — | 105 |
| integration / platform / graph-fixture | unchanged | unchanged |
| consolidation groups | 42 | 33 |
| grouped members | 537 | 423 |

Refusals, by reason: 48 mutate the process environment, 27 import
`asyncdispatch` (a process-global event loop), 7 bind a fixed OS-global port, 5
spawn a subprocess, 2 mutate the working directory, and ~16 import a module the
scan cannot resolve — refused rather than assumed.

Verified by mutation: fed the 59 sources independently identified as touching
subprocesses, the network, the environment or the working directory, the
predicate rejects **59 of 59**. The acceptance case is the peer-cache multicast
test, which passed 68/68 under `--run` and failed only when its binary was run
whole: it is now excluded from every consolidation group on the fixed-port
dependency alone, statically, without a run needing to discover it. The
peer-cache group correspondingly drops from 48 candidate members to 13.

`nim_total` is unchanged at 6,916 across the reclassification: this changes
which tests are *eligible* to share a binary, never how many cases exist.

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

## The init cost is an M3 defect, not an M4 one

Following the cost curve to its cause moves it out of this milestone.

`finalizeVariants()` runs a **full clingo ASP solve** at module initialization —
Spack-style concretization over variant values and package versions under
`requires`/`conflicts`/`propagates` constraints, with priority bands as
optimization weights. The `package` macro emits one `finalizeVariants()` call
per package (`macros_b.nim`, `emitVariantDeclarations`), and
`pendingSolverPackages` is a thread-local that accumulates process-wide. So a
bundle of N recipes runs **N solves over a growing package set**, not one
N-package solve: measured directly, 63 clingo grounding blocks at n=8 and 85 at
n=32, and the memo below records 85 distinct solves at n=32 and 768 at n=96.

The result is already capturable and the machinery exists: `finalizeVariants()`
renders the exact inputs it consumed through `renderSolverInputsFixture` when
`REPRO_EMIT_SOLVER_INPUTS` is set, those parse back through
`parseExplainFixture`, and `solutionToLock` turns a solution into a committed
lock. **The runtime consults none of it.** The only cache is
`lastUnifiedSolution`, an in-process memo discarded at exit. Concretization is
therefore captured for lock refresh and recomputed from scratch on every
execution — including every one of the suite's ~6,900 per-case invocations.

Runtime *solving* is the same category as the runtime *compilation* M3 exists
to eliminate, and is arguably worse: it is superlinear in what the process
happens to have imported. M4's cost crossover is a symptom of it.

### Is the solve a pure function of its inputs?

Yes, on the evidence available, and this matters because an impure solve would
mean the committed lock is not reproducible either:

* `REPRO_VARIANTS` is the one ambient input, and it is **captured**: env pairs
  become `prSet` contributions on the node (`applyCliContributionFor`) before
  `buildVariantDecls` runs, so they are rendered into the fixture like any
  other contribution rather than read inside the solver.
* `buildPackageDecls` and the encoders perform no filesystem, clock, or RNG
  reads.
* clingo is driven with no seed, parallel-mode, or configuration call.

One caveat, and it is about key stability rather than soundness: the inputs are
ordered by module-initialization order, so the same package set imported in a
different order renders differently and would key differently. Whether the
*solution* can differ under reordering was not tested.

The natural key is a content hash of `renderSolverInputsFixture` output, which
already exists and is already the lock-refresh capture format. Where the lookup
should live is a real question this measurement does not settle: reprobuild's
CAS is currently unused by test-compile edges (`cacheable = false`), so "put it
in the CAS" may inherit that problem.

### Does a committed lock get consulted at init? No — in any mode

`finalizeVariants()` consults no lock, and there is **no mode branch in that
code path at all**: `grep` for a develop-mode concept across `repro_lock` and
`repro_dsl_stdlib` finds nothing. So this is a missing feature rather than a
deliberate develop-mode carve-out.

But the scoping matters, and it cuts against calling the current behaviour a
bug *here*. `Locking-And-Solver.md`'s constraint-union rule is explicitly
scoped to **non-develop mode**, and its neighbouring per-dependency-coordinates
block is marked "target design — not yet implemented". This workspace is in
develop mode, where sources can change under the build and re-solving is the
defensible thing to do. The conformance gap is therefore the *absent
non-develop path*, not a wrong answer in the path we actually run.

There is also a third option neither the spec nor the lock design covers: a
test binary that only asserts registry contents has no reason to concretize at
all. The suite's cost here is not a lock-lookup problem; it is a
`package`-macro-at-module-init problem.

### What the lock would have to carry

`SolvedGraphLock` (`libs/repro_lock/src/repro_lock.nim`) already carries most
of it, and `lockToSolution` — the reverse direction — is already implemented:

| Needed | Present? |
| --- | --- |
| resolved version per package, keyed by name | **yes**, `packages: seq[LockedPackage{name, version, source}]` |
| resolved variant values, keyed by name | **yes**, `variants: seq[LockedVariant{name, value}]` |
| order independence of the content | **yes**, both lists sorted by name, explicitly so "two solves of the same graph produce byte-identical locks" |
| order independence of *validation* | **no** — `inputsDigest` is a digest of the rendered inputs text, which is emitted in module-initialization order |
| per-dependency checkout coordinates + integrity | **no** — `LockedPackage.source` is a placeholder equal to the name; the spec marks this "not yet implemented" |

Two further gaps a workspace-scoped design has to close, both consequences of
the accumulation:

* **Variant keys are not package-qualified.** They are `scopeDerivedName`s, and
  a collision is disambiguated with a registration-order `#N` suffix. Today
  each package gets a fresh context (`finalizeVariants` finalizes and pops, and
  `ensureAmbientVariantContext` re-creates), so collisions do not arise in
  practice — but a single workspace-scoped table keyed on those names would
  reintroduce exactly the order dependence the sorted lists were designed to
  avoid.
* **Completeness currently rides on the accumulation.** `repro lock refresh`
  re-solves the inputs the provider emitted, and those are complete only
  because the last solve saw every package imported so far. Scope the
  accumulation per package and the union has to be built deliberately instead.

### Measured ceiling: caching helps a lot, and does not remove the cap

An experimental keyed disk memo around `solve()` — hash the rendered inputs,
store and reload the assignments — was built locally to measure the ceiling. It
is deliberately **not** committed.

| Bundle size | init CPU, solving | init CPU, memo warm | speedup | distinct solves |
| --- | --- | --- | --- | --- |
| n=32 | 2.574 s | **0.180 s** | 14.3x | 85 |
| n=96 | 306.706 s | **15.312 s** | 20.0x | 768 |

So caching is worth roughly 14-20x. But it does **not** flatten init: warm cost
still climbs 0.180 s -> 15.312 s from n=32 to n=96, an 85x rise for 3x the
members. The residue is the key computation itself — rendering the solver
inputs is O(size of the accumulated set) per solve, so summed over N solves it
stays quadratic even when every solve is a cache hit.

The consequence for M4 is specific, and it corrects the natural expectation:
**caching alone would not make bundle size stop affecting init cost.** Flatting
it needs the process-wide accumulation scoped per package, not just a cache in
front of it.

### The lock-lookup design, measured by removing the solve entirely

The memo above caches at the wrong granularity — it memoizes each per-package
solve, so computing the key still means rendering an accumulating input set. A
workspace-scoped lock indexed by package inverts that: init resolves its own
entry and never materializes the accumulated set. To measure the ceiling that
design reaches, `finalizeVariants()` was stubbed to skip **both** the solve and
the accumulated `buildVariantDecls`/`buildPackageDecls` rendering. The stub is
env-gated and deliberately **not** committed.

| Bundle | solving | solve removed | speedup | per member |
| --- | --- | --- | --- | --- |
| n=1 | 0.009 s | 0.009 s | 1.0x | — |
| n=32 | 3.181 s | **0.155 s** | 20.5x | 4.8 ms |
| n=96 | 340.566 s | **1.330 s** | 256x | 13.9 ms |
| n=196 | 825.863 s | **9.514 s** | 86.8x | 48.5 ms |

The win is large — up to 256x, far beyond the memo's 14-20x, and it confirms
the granularity argument. **But init is still superlinear.** Removing the
solver entirely leaves a curve that climbs 8.6x from n=32 to n=96 (3x the
members) and 7.2x from n=96 to n=196 (2.04x the members) — an exponent near
2.8, the same shape as before with a roughly 87x smaller constant. Per-member
cost still triples as membership triples.

So the crux reasoning — that a per-package lookup makes cost O(my declared
deps) and the size dependence disappears — **does not survive measurement**.
The solve was the dominant term, not the only accumulating one: the artifact
and version registries the `package` macro writes at module init accumulate
too, and they are what remains. A lock lookup is the right shape for the
dominant term and is worth doing on its own merits; it is not, by itself, the
flat-init fix.

What it would buy M4's cost axis, using the measured stub init:

| n | binaries | build CPU s | run CPU s | total | vs unbundled |
| --- | --- | --- | --- | --- | --- |
| 32 | 7 | 3,387 | 165 | 3,552 | **9.6x** |
| 96 | 3 | 4,448 | 1,411 | 5,859 | 5.8x |
| 196 | 1 | 2,598 | 10,075 | 12,673 | 2.7x |

Better than the 6.2x the solving path reaches, and the catastrophic tail is
gone — but the optimum is still around n=32, and whole-group consolidation is
still 3.5x worse than that optimum. The cost crossover is softened and pushed
out, not removed.

### The isolation cap is independent of all of this

With the solve stubbed out entirely, the n=32 recipe bundle fails **the same 9
of 200 cases**, by name — the `registeredArtifacts` / `registeredVersions`
assertions. Removing concretization does not remove the contamination, because
the contamination was never the solver's: it is the artifact and version
registries colliding as they accumulate.

That settles the relationship between the two axes. **M4's isolation blocker
survives every caching or locking design and must be stated as independent.**
The correctness cap at 24 stands whatever happens to the solve.

### Where this needs a decision

The conformance gap belongs in `reprobuild-specs` (`Locking-And-Solver.md` and
the M2/M3 milestone scoping), not here — this artifact is evidence, not a
ruling. It is deliberately not written there by this change: that repository is
currently on another agent's feature branch with uncommitted work, and adding a
decision note to it would mix this into a review that did not ask for it.

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

## Batch 1 landed: `libs/repro_lock_files` + `libs/repro_peer_cache`

Recorded in full, with per-member figures, in
`reprobuild-suite-m4-consolidation-batch1.json`. Measured at Reprobuild
`16a992fd5`, Nim 2.3.1 from the dev shell, gcc 15.2.0, on the same shared
32-core host at load 75–140. Every binary compiled fresh; nothing below is read
back out of a pre-existing artifact or carried forward from the sections above.

| Group | Members | Cases | Compile CPU s | nimcache MB | C files | Binary MB | Warm per-case run s |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `libs/repro_lock_files` before | 8 | 42 | 710.5 | 38.4 | 336 | 7.86 | 0.80 |
| `libs/repro_lock_files` after | 1 | 42 | **114.6** | **7.8** | **50** | **1.51** | 0.82 |
| `libs/repro_peer_cache` before | 13 | 29 | 2,272.4 | 47.2 | 770 | 11.51 | 0.72 |
| `libs/repro_peer_cache` after | 1 | 29 | **250.4** | **9.4** | **94** | **1.95** | 0.77 |
| **batch total before** | **21** | **71** | **2,982.9** | **85.6** | **1,106** | **19.4** | **1.52** |
| **batch total after** | **2** | **71** | **365.0** | **17.2** | **144** | **3.5** | **1.59** |

Build cost falls **8.2x** in CPU seconds, nimcache **5.0x**, test-binary bytes
**5.6x**, binaries 21 → 2. Both bundles exit 0 run whole and pass 42/42 and
29/29 individually under `--run`. Catalog parity is exact in both directions:
zero missing, zero extra. Of the protocol fields only `bodyHash` moves — 37 of
42 and 26 of 29 — which is a one-off re-run for hash-difference selection, not
a loss of identity; `file`, `line`, `column`, `suite`, `name`, `kind`, `group`,
`threadsRequired`, `xfail`, `tags` and `deterministic` are unchanged.

**The warm run does not get faster, and is very slightly slower**: 1.52 s →
1.59 s over the same 71 cases (+4.6%). That is the per-case module-init term
the section above predicts, and at this bundle size it is small and flat rather
than explosive. Consolidation is a BUILD-cost optimisation; anyone quoting it
as a run-time one is quoting the wrong column.

Suite-wide: 1,528 → 1,510 Nim test binaries. The fall is 18 rather than 19
because the batch brings its own verification binary
(`tests/integration/t_m4_pure_unit_consolidation.nim`) with it; both numbers
are in the ledger rather than netted. Static case count 8,766 → 8,769, the +3
being that verification test's own cases — **consolidation contributes zero**,
which is the point.

### The gates, and the runs that show they can fail

Seven mutations are recorded in the ledger's `mutations` block, with the
verification test's three cases reported separately for each, because a gate
that only ever fails alongside its neighbours is a gate nobody can attribute.
The discriminating one is **M3**: renaming a member's `suite` while keeping its
case count at five turns cases 1 and 3 red and leaves case 2 **green** — case 2
compares counts and bytes, which a rename does not touch. Two more make the
generator's `checkBundleLimits` refuse (a second owner; a 25th member), one
makes the "every declared bundle is measured or named" gate refuse, and one
collapses the new import closure to a no-op and shows
`--check-inventory` reddening on exactly the 31 entries — which is what covers
the closure machinery, since it has no unit test of its own.

`--run` was also shown to discriminate: a name that cannot exist, and a bare
test name with the suite stripped off, both exit non-zero. Without that, every
per-case exit-0 assertion in the verification test would be vacuous.

### The predicate hole this batch found

`libs/repro_lock_gen` (11 members, one owner, one dependency shape, classified
`pure unit`) was the obvious batch and is not in it. Its shared fixture starts
a **real loopback TCP listener on a background thread** —
`libs/repro_lock_gen/tests/loopback_metadata_server.nim` imports `std/net`,
calls `newSocket()`, `bindAddr(Port(0), "127.0.0.1")` and `listen()`, and hands
the socket to `createThread`. The predicate could not see it: all eleven
members of that group reach it through `./nlf_m6_fixture` (which imports
`./loopback_metadata_server` directly), and the allowlist read only the test's
own import clause. Consolidating that group would have put eleven listeners and
their threads in one process.

The hole was not "one hop too shallow"; it had no depth at all. The old
predicate's first branch was `if name.startswith(".") … continue`, so a
**relative import was skipped outright** — three other `repro_lock_gen` tests
import `./loopback_metadata_server` with no intermediate file whatsoever and
were still classified `pure unit`. Anything a test reached by path was
invisible, at any distance.

The predicate is now closed over the test's repository-local path imports, and
a refusal names the file that earned it. Suite-wide effect, all in the refusing
direction: **31 entries move `pure unit` → `unclassified`** (20 `repro_lock_gen`,
4 `repro_deploy_agent`, 2 `repro_binary_cache_client`, 2 `repro_dsl_stdlib`,
2 `repro_peer_cache` mint-cert, 1 `repro_binary_cache_server`), zero move the
other way. Pure unit 619 → 569, unclassified 129 → 160, consolidation groups
56 → 48 (2 consumed by this batch, 6 by the refusals).

The pure-unit figure moves for two reasons at once, so it is decomposed rather
than quoted whole: **619 → 588** is the predicate repair alone, measured by
running both predicates over the *identical* `origin/dev` entry list, and
**588 − 21 + 2 = 569** is this batch removing 21 member entries and adding 2
bundles. Read against the entry list alone the fall is 31; read against the
tree it is 50, and the two are not the same measurement. (Unclassified 129 →
160 is 31 exactly. Eight of the 129/160 are Python entries, which the
predicate never reaches; over Nim entries only it is 123 → 154.)

The refusals break down by reason as: 20 `creates threads`, 5 `binds a fixed
OS-global port`, 2 `spawns a subprocess`, 2 `module initialization reads the
argument vector`, 1 `imports dynlib`, 1 `imports httpclient`.

Known over-approximation, stated rather than hidden: **five** of those refusals
are `binds a fixed OS-global port` earned by `port: Port(DefaultMulticastPort)`
at `libs/repro_peer_cache/src/repro_peer_cache/types.nim:444` — a *types*
module that declares a constant and contains no `bindAddr`, `listen` or
`newSocket` at all. That is a false refusal in the safe direction — it costs
consolidation candidates, never correctness — and it is worth a follow-up, not
a relaxation.

(An earlier revision of this section said "seven". Recomputed at review by
running the `origin/dev` and batch predicates over the identical `origin/dev`
entry list and grouping the 31 refusal reasons: the count is five, and the
`Port(...)` site is the single one named above.)

And the over-approximation turns out to cost nothing at all on this tree, which
is stronger than "false but safe". Deleting the `Port(...)` pattern from
`PURE_UNIT_DISQUALIFYING_SYMBOLS` outright and re-running the predicate leaves
all five entries refused, for `imports nativesockets` through the same
`types.nim` — that module's line 18 is `import std/[hashes, nativesockets, net,
options]`, and both `nativesockets` and `net` are already in
`PURE_UNIT_FORBIDDEN_MODULES`. The refusal is doubly earned, so the follow-up
above buys back **zero** consolidation candidates here; it is worth doing for
the reason the refusal should be attributable, not because anything is blocked
by it.

### A group measured and dropped

`libs/repro_cli_support` (5 members, 22 cases) was measured and excluded:
`test_m2_env_ps1_migration_clean.nim` fails **4 of its 8 cases standalone** on
this tree before any consolidation (`Check failed: line.kind != moUnknown`,
line 211, twelve times), and its binary exits 1 run whole. This is a
pre-existing `origin/dev` failure, not a consolidation effect — but a group
carrying a red case cannot be evidence that consolidation preserved outcomes.

## Batch 2 landed: `libs/repro_lock_files` (second group) + two `libs/repro_core` groups + `libs/repro_dsl_stdlib` catalogs

Recorded in full, with per-member figures, in
`reprobuild-suite-m4-consolidation-batch2.json`. Measured at Reprobuild
`4a9a3070b`, Nim 2.3.1 from the dev shell, gcc 15.2.0, on the same shared
32-core host. Every compile-cost and footprint figure below was taken in one
window at load 65–95; the mutation runs later in the session ran at load
200–300 and contribute no cost figure to this report, only exit codes and
per-case verdicts. Every binary compiled fresh into a private nimcache;
nothing below is read back out of a pre-existing artifact or carried forward
from batch 1 — including batch 1's two bundles, which this batch rebuilt only so
the verification test could run against them, and did not re-record.

Four groups, 22 members, 22 → 4 binaries, 232 logical cases preserved.

| Group | Members | Cases | Compile CPU s | nimcache MB | C files | Binary MB | Per-case warm CPU s |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `libs/repro_lock_files` (2nd group) before | 3 | 24 | 117.4 | 6.04 | 86 | 1.29 | 0.166 |
| `libs/repro_lock_files` (2nd group) after | 1 | 24 | **54.8** | **3.23** | **32** | **0.66** | 0.170 |
| `libs/repro_core` `['repro_core']` before | 3 | 63 | 161.9 | 9.63 | 99 | 2.04 | 0.480 |
| `libs/repro_core` `['repro_core']` after | 1 | 63 | **109.8** | **7.20** | **46** | **1.47** | 0.498 |
| `libs/repro_core` dep-scanners before | 3 | 35 | 218.8 | 12.44 | 118 | 2.64 | 0.282 |
| `libs/repro_core` dep-scanners after | 1 | 35 | **116.7** | **6.99** | **45** | **1.48** | 0.289 |
| `libs/repro_dsl_stdlib` catalogs before | 13 | 110 | 914.8 | 50.46 | 678 | 9.85 | 0.855 |
| `libs/repro_dsl_stdlib` catalogs after | 1 | 110 | **309.2** | **21.47** | **167** | **3.93** | 0.965 |
| **batch total before** | **22** | **232** | **1,412.97** | **78.57** | **981** | **15.82** | **1.783** |
| **batch total after** | **4** | **232** | **590.57** | **38.89** | **290** | **7.54** | **1.922** |

Build cost falls **2.39x** in CPU seconds, nimcache bytes **2.02x**, emitted C
files **3.38x**, test-binary bytes **2.10x**, binaries 22 → 4.

The 2.39x is honestly smaller than batch 1's 8.2x and the reason is
arithmetic, not regression: three of these four groups have only three members,
and a group of N cannot beat N. Read per group, the 13-member
`repro_dsl_stdlib` group returns **2.96x** and the three-member groups return
2.14x, 1.47x and 1.87x. The shared closure that batch 1's 13-member
`repro_peer_cache` group amortised (bearssl, the codec, the cuckoo filter) is
simply larger than what three `repro_core` tests share.

All four bundles exit 0 run whole and pass 24/24, 63/63, 35/35 and 110/110
individually under `--run`. Catalog parity is exact in both directions for all
four: zero missing, zero extra. Thirteen protocol fields were compared per case
(`bodyHash`, `column`, `deterministic`, `file`, `group`, `kind`, `line`, `name`,
`suite`, `tags`, `test`, `threadsRequired`, `xfail`) and **only `bodyHash`
moves** — 24 of 24, 45 of 63, 16 of 35, 99 of 110. Everything that a selector is
made of is unchanged.

**The warm run does not get faster, and is slightly slower**: 1.783 → 1.922 CPU
seconds over the same 232 cases (+7.8%), measured the way batch 1 measured it —
one process per case, `--run "suite::test"`, two passes, the second reported.
The 13-member bundle carries most of it (+12.9%); the three-member bundles are
+2.4%, +2.6% and +3.7%. Consolidation is a BUILD-cost optimisation.

A second run figure is recorded per binary and is *not* the one compared:
running each binary once with no arguments. On that metric the batch gets
**faster** — 0.278 → 0.158 CPU seconds, 1.76x — for the trivial reason that 22
process startups become 4 and each module init is paid once instead of once per
case. It is in the ledger as `wholeBinaryWarm*` so that nobody re-derives it and
quotes it as the run-time win: the M3 runner spends one process per case, so
`perCaseWarm*` is the column that describes what CI pays, and that one is
7.8% worse.

Suite-wide, both sides stated rather than netted: **1,512 → 1,494 Nim test
binaries**, a fall of 18, which is exactly the 22 members minus the 4 bundles
that replaced them. Unlike batch 1 this batch adds **no** binary of its own — the
verification test already exists — so there is nothing to subtract. Test
entries (Nim + Python) 1,520 → 1,502. **Static case sum 8,767 → 8,767,
unchanged**: consolidation contributes zero and this batch adds no test.

Consolidation groups 48 → 46: four consumed, and **two new ones created whose
members are themselves bundles** — `(tests/bundles, ['repro_lock_files'])` now
pairs `bundle_repro_lock_files_pure_unit` with
`bundle_repro_lock_files_cli_pure_unit`, and `(tests/bundles, ['repro_core'])`
pairs the two `repro_core` bundles. Neither is actionable: `checkBundleLimits`
refuses any member under `tests/bundles` by construction. The candidate list
does not know that, so it will keep proposing them; that is a defect in the
candidate list, not in the limit.

### What the verification test had to be changed to say

Extending `tests/integration/t_m4_pure_unit_consolidation.nim` to a second
ledger turned up two assertions that were true only of a one-batch world.

**`declaredSources.len >= after` was false on arrival.** Batch 1 anchored it to
that batch's `nimTestBinariesAfter` on the reasoning that the count only ever
grows. It does not: the next consolidation batch makes it *fall*. It is now
anchored to the newest ledger's `after`, which is the only one that is a lower
bound, because every later batch can only remove more.

**`staticTotal == enumerated` was ill-formed, and batch 1 passed by luck.** It
compared the Python source scan's count of a bundle against the built binary's
own catalog. The static table's own header says the scan "sums every when/else
branch"; `libs/repro_core/tests/t_smoke_repro_core.nim` has six cases under
`when defined(windows)` and one under `else`, so the scan counts 14 where a
Linux binary enumerates 8 — and `bundle_repro_core_pure_unit` went red at 69 vs
63 the first time the verification test ran against it. None of batch 1's 21
members was platform-conditional, so the equality had never been exercised.

The fix keeps two producers and drops the assumption that the scanner is exact:
the scanner's count of the *bundle* must equal the scanner's count of the
*members*, summed, as recorded per member in the ledger
(`staticCaseCountAtBase`) when the batch landed. The over-count is a property of
the member sources and survives the move unchanged, so it cancels on both sides;
a deleted `test` block does not. This is what the file's own header always
claimed — "a loss has to be written into both before this file goes quiet" —
and what the old form did not deliver, since a deletion moved static and
enumerated together and left the equality green. Batch 1's ledger carries no
per-member static counts and therefore keeps the assertion it shipped with,
unrelaxed.

The mutation `M2-static` below exists precisely because that arm was changed and
had to be shown to discriminate.

### Batch 2's gates, and the runs that show they can fail

| Mutation | Verification exit | case 1 list | case 2 footprint | case 3 selectors |
| --- | --- | --- | --- | --- |
| baseline | 0 | OK | OK | OK |
| **M3** rename a member's `suite`, case count held at 24, bundle rebuilt | 1 | **FAILED** | **OK** | **FAILED** |
| M1 delete one `test` block, bundle rebuilt | 1 | FAILED | FAILED | FAILED |
| M2-static delete one `test` block, regenerate the static table, bundle NOT rebuilt | 1 | OK | **FAILED** | OK |
| M6-coverage empty batch 1's `bundlesNotCoveredByThisLedger` | 1 | FAILED | OK | OK |
| M7-ledger-drop remove a member row from batch 2's ledger | 1 | FAILED | FAILED | OK |

**M3 is the discriminating one and it still discriminates.** The rename holds
the bundle at 24 enumerated cases — confirmed by asking the mutated binary — so
case 2, which compares counts and bytes, stays green while cases 1 and 3 go red
on the changed `suite::test` selector. That separation is structural, not luck.

**M2-static isolates the arm that changed.** Deleting a case from a member's
source and regenerating the static table *without* rebuilding the bundle leaves
the binary enumerating 24 against a ledger recording 24 — so cases 1 and 3 are
green — while the scanner now counts 23 in the bundle against 24 summed from the
members. Only case 2 goes red, and only on the new comparison. The old
`staticTotal == enumerated` form would have been green here.

Three generator refusals, exit code read directly from `nim r`:

| Mutation | Generator exit | Message |
| --- | --- | --- |
| M4-gen-owners: add `libs/repro_system_apply/tests/t_b1_dsl_parse.nim` to the `libs/repro_lock_files` bundle | 1 | `spans 2 owners (libs/repro_lock_files, libs/repro_system_apply); MaxBundleOwners=1` |
| M5-gen-size: 25 real, same-owner members in `bundle_repro_dsl_stdlib_catalogs_pure_unit` | 1 | `25 members exceeds MaxBundleMembers=24` |
| M5-control: the same bundle at exactly **24** real members | **0** | *(accepted — the cap is a cap at 25, not an artifact of this batch's 13)* |

The last row is there because a refusal that fires at 25 proves nothing unless
24 is shown to pass; without it `MaxBundleMembers` could be any number at or
below 13 and the M5 run would look identical.

`--run` was confirmed to discriminate against a real batch-2 bundle: a
selector that cannot exist exits 1, a bare test name with the suite stripped off
exits 1, and the full `suite::test` form exits 0. Without that, every per-case
exit-0 assertion in the verification test would be vacuous.

Restoration was an explicit byte snapshot of exactly the files each mutation
touched, not `git checkout --`. `git status --porcelain` matched the
pre-mutation listing exactly afterwards, the rebuilt bundle's md5 was identical
to its pre-mutation value (`794a4a7b…`), and the baseline was re-run at the end
and was green.

### Groups measured and NOT consolidated

`libs/repro_system_apply` (3 members, 30 cases, shape
`['repro_core', 'repro_system_apply']`) was compiled and executed standalone for
this batch and is **clean**: 30/30 cases pass individually, all three binaries
exit 0 run whole. It is out only to keep the batch at four groups. Its
before-side figures are in the ledger under `groupsMeasuredAndDeferred`, so the
next batch inherits a measured "before" and has only the bundle left to measure.

`libs/repro_cas_store` (5 members, 100 cases) was **not** attempted, and the
reason generalises past this group. Its recorded dependency shape is
`['repro_cas_store', 'repro_core']`, and that shape does not name the library
through which its members actually share process-global state:
`t_link_capability_probe.nim` calls `resetGlobalLinkCapabilityCache()` and
asserts `globalProbeCount()` transitions on the global cache defined in
`libs/repro_local_store/src/repro_local_store/link_capability.nim`, while its
three group-mates drive that same global through `casMaterialize` →
`linkCapabilities` (`libs/repro_cas_store/src/repro_cas_store.nim:619`). The
probe test resets before it asserts, so a failure is not certain — this is not a
claim that the group is broken. It is a claim that **"same dependency shape" is
not a statement about shared process-global state**, because
`local_dependency_shape` records direct imports only. That group needs its own
evidence before it earns a process.

`libs/repro_dsl_stdlib`'s *other* group — 22 members, shape
`['repro_dsl_stdlib', 'repro_project_dsl']`, 322 static cases, and therefore the
largest prize still under the 24-member limit — was also refused. It is the
package-declaration family: `t_nde*`, `t_packaging_*`, `t_prefix_layout` and
friends run `repro_project_dsl`'s `package` macro at module init. That is the
same family whose from-source recipe cousins failed merged at 24 and passed at
16 in the crossover section above, and the accumulating per-module solve
underneath it is an unresolved product question rather than a bundle-size one.
The 13-member group this batch *did* take is the complement of exactly that
distinction: not one of its 13 members declares a top-level `package` block,
and neither does the single helper one of them reaches by path import
(`libs/repro_dsl_stdlib/tests/packaging_test_support.nim`, which imports
`repro_project_dsl` but declares only procs).

**Corrected at review:** an earlier revision of this paragraph then said
"nothing in that bundle runs the `package` macro at module init; every member
of the 22-member group does". That is a stronger claim than the evidence
supports, and it is false in both halves. Closing the scan over *library*
imports as well as path imports — `repro_dsl_stdlib/packages/*` modules
declare top-level `package` blocks and are pulled in directly and through
`catalog_registry` — **5 of the 13 taken** reach one (`t_catalog_claude_code`,
`t_m67_bulk_catalog`, `t_m8_bulk_catalog`,
`t_packaging_wrapper_vars_match_flake`, `t_versioned_provisioning_schema`) and
**21 of the 22 rejected** do (`t_isonim_ssg_render_edge` does not). The
difference between the two groups is one of density, not of kind: 5/13 against
21/22, and in the taken group the declarations arrive through catalog modules
rather than through the recipe imports and `package`-declaring test bodies that
characterise the rejected family.

What actually licenses taking the 13 is therefore the measurement, not the
taxonomy: all 13 were compiled and run standalone first, the bundle exits 0 run
whole, and all 110 cases pass individually. The rejection of the 22 rests on
the from-source recipe cousins failing merged at 24 and passing at 16, plus the
absence of any measurement of the 22 merged — which is a reason to defer, and
is how it should have been stated.

### What batch 2 ran, and what it did not

The bar for a suite-wide change is a full green local run. **This batch does not
meet that bar and does not claim to.** What follows is the exact boundary, so
nobody reads a bounded substitute as though it were the suite. The same list is
in the ledger under `executionScope`.

**Executed.**

* **25 member sources**, compiled standalone from scratch and executed: this
  batch's 22 plus `libs/repro_system_apply`'s 3. Each run whole — 25 of 25 exit
  0 — and every case run in its own process via `--run "suite::test"`: **262
  case executions, every one exit 0**. This is the `before` side, and it is also
  the red-on-`dev` check batch 1 established: none of the 25 is red standalone
  on this tree.
* **The 4 bundles**, compiled from scratch: all exit 0 run whole, plus **232
  per-case `--run` executions, every one exit 0**.
* **`tests/integration/t_m4_pure_unit_consolidation.nim`**: 3/3, exit 0. It
  internally drives all six bundles named across both ledgers — batch 1's 71
  cases and batch 2's 232 — for **303 further per-case `--run` executions** plus
  the two negative controls.
* **The mutation campaign**: 8 runs, per-case verdicts tabulated above.
* **Gates, every exit code read directly and never through a pipe**:
  `--check-inventory` 0, `--check-static-case-counts` 0,
  `check_test_body_helper_compilation.py` 0, `check_vacuous_test_cases.py` 0,
  `just build` 0 (all nine app entrypoints — which is what compiles the
  generated `repro_tests.nim` into the graph), `check_repo_requirements.sh` 0,
  `check_ambient_execution.sh` 0, `check_dev_shell_env.sh` 0,
  `check_shell_command_strings.sh` 0 and `--self-test` 0, `check_workflows.sh` 0.

**Not executed.**

* **The full test suite.** `just test` / `scripts/run_tests.sh` was not run.
  Nothing outside the 25 member sources, the 6 bundles and the verification test
  was executed at all, and no claim in this section covers any other test. This
  batch therefore contributes **no** independent observation of the known-red
  set on `dev`.
* **`just lint` as a whole.** Ten of its eleven steps were run individually to
  exit 0 (listed above). The eleventh, `scripts/check_nim_sources.sh` — a
  `nim check` sweep over all 82 libraries and 9 app entrypoints — was still
  running at hand-off — it had cleared the first 31 of 82 libraries with zero
  errors when this was written — on a host at load 145–260 from another
  session's concurrent full-suite measurement. **A reviewer must run it.** This
  batch modifies no
  file under `libs/` and no app entrypoint, so that step's outcome is
  structurally independent of the change. That is a reason to expect it green,
  not evidence that it is.
* **The graph-driven build of the bundles.** The four bundle binaries were
  compiled with a direct `nim c` matching this report's compile command, not
  through `repro build`. What is established about the generated edges is that
  `repro_tests.nim` compiles into the graph and that the generator is
  idempotent. That the four new test edges execute correctly **under the
  engine** is not established here.
* **Anything about a rebased tree.** This batch is based on `4a9a3070b`;
  `origin/dev` had advanced to `251ae56b6` by hand-off. The suite-wide pair
  1,512 → 1,494 is a dated fact about `4a9a3070b`. A rebase that adds tests
  needs `repro_tests.nim`, the static-case-count TSV and the source inventory
  regenerated; the verification test's live invariant
  (`declaredSources.len >= the newest ledger's after`) tolerates that in the
  growing direction.

### A note on batch 1's ledger

Two things in it are worth correcting for the record, neither of which changes
any of batch 1's measured figures:

* **ONE** of its bundles records `"dependencyShape": []`, not both.
  (Corrected at review. An earlier revision of this bullet said both, and the
  batch-2 ledger's `limits.enforcementPoints` repeated it; the file on disk at
  the only commit that ever wrote it — `a7798b480` — records `[]` for
  `bundle_repro_lock_files_pure_unit` and `['repro_peer_cache']` for
  `bundle_repro_peer_cache_pure_unit`. So the peer-cache half of the original
  claim was simply wrong, and the corrected form is narrower.)
  For `bundle_repro_lock_files_pure_unit` the `[]` is what the shape function
  returns — its eight members reach `repro_lock_files` through
  `./nlf_m8_fixture`, and the shape function does not follow path imports, so
  the group's recorded shape genuinely was `[]`. The effect on the gate is
  real but confined to that one bundle: an empty list makes
  `check bundle["dependencyShape"].len <= maxDeps` assert nothing for it. This
  batch records the real shapes (1, 1, 2, 1 roots against a limit of 4), so the
  assertion has something to bite on for every bundle it covers.
* `local_dependency_shape` is **not** closed over repository-local path imports,
  although `pure_unit_verdict` now is. That asymmetry is why
  `libs/repro_lock_files` presented as two groups: the eight fixture-using
  members scored `[]` and the three direct importers scored
  `['repro_lock_files']`. Closing it would not have merged them —
  `nlf_m8_fixture` imports `repro_solver` as well, so the eight would score
  `['repro_lock_files', 'repro_solver']` — but the split is currently an
  accident of how far the scan looks rather than a fact about the tests, and the
  next batch should not rely on it.

## Recommended next batch

`libs/repro_peer_cache` was the largest measured prize at 20.5x and is now
landed — the fixed-port multicast test that made its merged binary exit 1 is
excluded by the predicate rather than by hand, so the 13 members that remain
are the ones the scan can show tolerate neighbours.

Batch 2 took the three groups this paragraph named — `libs/repro_lock_files`'
second group and both `libs/repro_core` groups — plus the 13-member
`libs/repro_dsl_stdlib` catalog group.

After batch 2 the list stands at 46 groups, two of which are the
bundle-against-bundle artifacts described above and are not actionable. The next
batch should take `libs/repro_system_apply` (3 members, 30 cases), whose
before-side is already measured and clean in batch 2's ledger, and then decide
about `libs/repro_cas_store` (5 members, 100 cases) — which needs an answer to
the shared `repro_local_store` link-capability global before it earns a process.
`libs/repro_project_dsl`'s 41- and 38-member groups, and
`libs/repro_dsl_stdlib`'s 22-member package-declaration group, are all over or
at the limit and all belong to the package-declaration family; none should be
attempted before the module-init solve question below is settled.

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

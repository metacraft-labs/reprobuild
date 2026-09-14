# Idiomatic Reprobuild

> **Status:** ✓ Current. Every claim below is cited to a file, symbol or
> commit in this workspace, checked 2026-09-14 against
> `reprobuild@dac7edc1`, `codetracer@5ca36353` and `io-mon@ac3e5b97`.
> Section 7 describes a **pattern with no primitive behind it** and is
> marked ☐ throughout.

This is a teaching page, not a specification. The specs say what
reprobuild *does*; this says how to use it *well* — and, more usefully,
describes the mistakes that look exactly like correct use. Nearly every
rule here was learned by getting it wrong first, and several are rules a
later reader will try to "fix" in good faith. Where that is so, the page
says which guard stops it.

Read [Getting Started](getting-started.md) and [The Three
Modes](three-modes.md) first if you have never written a `repro.nim`.
The worked examples come from `codetracer/repro.nim`, a real sibling
repo in this workspace, so you can open them.

## Contents

1. [Granularity is what buys caching and parallelism](#1-granularity)
2. [Declare inputs narrowly — and know what declared inputs are for](#2-inputs)
3. [Collections, and what a bare `repro build` must not run](#3-collections)
4. [Non-determinism: remove it, or bless the tool that emitted it](#4-nondeterminism)
5. [Uncacheable is safe; falsely-cacheable is not](#5-uncacheable)
6. [Observability is a property of how you invoke](#6-observability)
7. [☐ Environment facts and capability probes](#7-facts)
8. [Adopt non-destructively](#8-adoption)
9. [Measure honestly](#9-measuring)

---

## <a name="1-granularity"></a>1. Granularity is what buys caching and parallelism

The engine can only cache, parallelise, skip and explain at the
granularity of an **action**. A test lane expressed as one opaque `bash`
blob is one action: the engine cannot cache a partial result inside it,
cannot run two halves of it concurrently, and cannot skip it when only
the half it does not touch has changed.

CodeTracer's gate scripts were in exactly that shape — reachable only
from `just` recipes and CI workflow steps. The commit that put them in
the graph (`codetracer@996f9b12`) opens with the measurement:

> CodeTracer's gate scripts were reachable only from `just` recipes and
> CI workflow steps, so reprobuild could see none of them: a full `repro
> build` schedules 30 actions and not one is a test.

The fix is **one node per gate**, not one node per lane:

```nim
let gateBuildAlignment = ctShell(
  actionIdValue = "codetracer.gate.build-alignment",
  commandValue = "bash scripts/test-build-alignment.sh",
  extraInputsValue = @["scripts/test-build-alignment.sh"],
  cacheableValue = true,
  extraEnvValue = GateEnv)
target("gate-build-alignment", gateBuildAlignment)
```

(`codetracer/repro.nim:1865`. `ctShell` is a local template in that file
wrapping the stdlib's `shell(...)`; `target(...)` gives the edge its own
selectable name so one gate can be run alone.)

The recipe's own comment says why per-gate is the granularity that pays
(`codetracer/repro.nim:1667`):

> One edge per gate is the smallest change that fixes that, and per-gate
> is the granularity that pays: the engine monitors each script's reads,
> so editing `flake.lock` re-runs exactly the gates that read it and
> leaves the rest cached.

**Where to look for the next seam.** A lane→files mapping that already
exists in shell is a ready-made list of finer edges.
`codetracer/ci/lib/test-lane-files.sh` is 1059 lines declaring 30 lane
ids and a `test_lane_files <id>` function resolving each to a file set —
the natural input to a graph with one edge per lane rather than one edge
per suite. Nothing consumes it that way yet; it is named here because it
is the obvious next step, and because a mapping like it usually already
exists in any repo that has grown a `just test`.

> **Granularity is not node count.** Splitting an edge whose halves share
> one input set buys nothing and costs a process launch. The test is
> whether the two halves have *different* inputs, so that a change can
> invalidate one without the other.

---

## <a name="2-inputs"></a>2. Declare inputs narrowly — and know what declared inputs are for

This is the most commonly over-applied field in a recipe, because
"declare more, be safer" is true in most build systems and false in this
one.

**What declared inputs actually do.** Reprobuild's baseline for opaque
tools is `dgAutomaticMonitor` — the engine runs the action under io-mon
and records what it *really* read
(`libs/repro_core/src/repro_core/dependency_gathering.nim`). That
observed read set is what the action-cache key is built from. Declared
inputs (`extraInputs` on `shell(...)`) exist to **order the edge in the
graph before any monitored run of it exists**, and to name files it is
pointless to rediscover. They are a scheduling hint, not the dependency
set. CodeTracer's recipe states it (`codetracer/repro.nim:1715`):

> `cacheable = true` under `ctShell`'s default automatic-monitor policy:
> the engine records every file each gate actually reads, so a verdict is
> keyed on observed evidence rather than on the declared list. The
> declared inputs are the script itself plus the data files it is
> pointless to rediscover; they make the edge order correctly before any
> monitored run of it exists.

**So a declared input you did not need is pure cost.** It enters the
invalidation set without contributing to correctness, and re-runs the
edge for changes whose outcome it cannot depend on. Two worked
subtractions, both in `codetracer/repro.nim`:

```nim
let gateFlakePinAlignment = ctShell(
  actionIdValue = "codetracer.gate.flake-pin-alignment",
  commandValue = "bash ci/test/flake-pin-alignment-test.sh",
  # A CONTRACT SUITE, so its inputs are itself and the guard it drives
  # over fixtures -- NOT this repo's `flake.nix` / `flake.lock`, which it
  # never reads. Declaring those would have made every lock bump re-run a
  # suite whose verdict cannot depend on it.
  extraInputsValue = @[
    "ci/test/flake-pin-alignment-test.sh",
    "scripts/test-flake-pin-alignment.sh"],
  cacheableValue = true,
  extraEnvValue = GateEnv)
```

(`codetracer/repro.nim:1766`. The suite exercises its guard over
*fixtures*; it never opens the repo's own lock. `flake.nix` and
`flake.lock` do appear at lines 56–57 of the same file, in
`CodeTracerDevEnvInputFiles` — a different thing, the dev-env
definition, where they belong.)

The same reasoning removed the ledger from `gate-known-failures`
(`codetracer/repro.nim:1827`):

```nim
  # The ledger this drives is a fixture the gate writes into a temp dir;
  # `ci/lib/known-test-failures.tsv` is deliberately NOT declared because
  # the gate never reads it.
  extraInputsValue = @[
    "ci/test/known-failures-gate.sh", "ci/lib/known_failures.py"],
```

`ci/lib/known-test-failures.tsv` exists in that repo and is declared
nowhere.

### The thing you must never reach for

If declared inputs are only a hint, the tempting next thought is "then
let me declare the *real* set and skip monitoring". Reprobuild
deliberately has no such mode, and the refusal is written into the enum
itself (`dependency_gathering.nim:11`):

> NOTE: there is intentionally NO "declared-only" / "no runtime
> dependencies" gathering kind, in any form — narrow ones included. […] A
> mode that tracked only the statically declared inputs and marked the
> action complete/cacheable — silently letting depended-on files change
> without a rebuild — was re-introduced more than once by agents without
> approval (first as `dgDeclaredOnly` / `dgNoRuntimeDependencies`, then
> via the recipe-facing `declaredOnlyDependencyPolicy` and the
> `REPRO_MACOS_DISABLE_ACTION_MONITOR` opt-in). It contradicts the
> automatic-monitoring baseline for opaque tools and is a soundness hole,
> so it is REMOVED and MUST NOT be re-added.

A fourth attempt, `dgTrustedDeclaredInputs` — pitched as a narrow
exception where the author writes the input list *and a justification*
inline — was added and removed again, for the reason the same comment
gives: nothing anywhere could recompute or re-check the list.

The **sanctioned** route for an action that genuinely cannot be monitored
is a depfile (`dgRecognizedFormat` via `makeDepfilePolicy`), because
there the input set is *derived* rather than *asserted*: some edge
produces it, it can be regenerated, and the engine reads it back as real
evidence. Failing that, make the action `cacheable = false`. See §5.

---

## <a name="3-collections"></a>3. Collections, and what a bare `repro build` must not run

`collect(name, actions)` registers a **build graph collection** — a named
set of graph nodes the engine materialises as a unit
(`libs/repro_project_dsl/src/repro_project_dsl/runtime_core.nim:1861`).
The conventional names are `default`, `test`, `bench`, `docs`, `lint`
and `package` (`reprobuild-specs/Build-Graph-Collections.md`
§"Conventional Collections Shipped By Stdlib").

> **Read that spec's normative rules, not its status line.** Its header
> still says *"Draft design, not yet implemented"*, which is stale:
> `collect` is implemented, and so is the exclude rule below.

### `test` versus `lint`

The spec's distinction: `test` is "every test-binary run-edge in the
project"; `lint` is "static-analysis and quality-gate checks […]
Distinct from `test` because lint failures often gate merge but do not
exercise behavior."

CodeTracer applies it with a criterion you can reuse verbatim
(`codetracer/repro.nim:1683`):

> The assertion suites drive a routine through pass AND failure arms and
> count what they asserted, so they are tests; the consistency and
> coverage guards compare declarations across the tree and exercise no
> behaviour, so they are lint.

Seven of its ten gates land in `test`, three in `lint`:

```nim
discard collect("test", ctGateTestActions)
discard collect("lint", ctGateLintActions)
```

### Keeping them out of a bare `repro build`

The engine implements the spec's **Generic Build Exclude Rules** in
`lowerProviderSnapshot`
(`libs/repro_cli_support/src/repro_cli_support.nim`, around line 3676):
on the **no-selector** path it gathers every action id belonging to a
target named `test`, `bench`, `lint` or a `<package>:`-qualified
variant, and lowers everything else. (`docs` and `package` are *not*
excluded.)

Two caveats matter more than the rule:

- It fires **only when no positional selector was supplied**, and only on
  the "build everything" fallback. A project that pins its own
  `defaultBuildAction(...)` never reaches it.
- It excludes only a collection's **direct** members, not transitive
  closures.

So the recipe-level idiom is the one that always works: **do not put the
edge in the aggregate you hand to `defaultBuildAction`.** CodeTracer does
exactly that — its gate edges are never appended to `codetracerActions`,
and the aggregate built from that list is the default build action.

> **A correction worth knowing.** `auxiliaryActionIds` in
> `codetracer/repro.nim` is **not** a reprobuild DSL feature. It is a
> plain local `var auxiliaryActionIds: seq[string] = @[]` (line 1162)
> read in exactly one place — line 2034, inside that repo's
> *source-subset checkout* fallback, where the aggregate is synthesised
> from `registeredBuildActions()` and a deny-list is the only way to keep
> the gates out. In a full checkout it does nothing, because the gates
> were never in the list. Copy the pattern only when you too are building
> an aggregate from "everything registered" — never as an engine concept.

### Selecting them from the CLI

Two gotchas, both real, both easy to get backwards.

**Gotcha 1 — at most one path/fragment selector, and it must come
first.** `parseAndResolveSelectors` (`repro_cli_support.nim:928`) takes
the first path-shaped positional as the project anchor and raises on a
second:

```text
repro build: multiple path / fragment selectors are not supported in M3
  (got '.#a' and '.#b'); name-shaped selectors may follow a single path anchor
```

So `repro build .#a .#b` is an error and `repro build .#a b` works. But
the *common* form — and the only one under test, in
`tests/e2e/local-build-engine/t_e2e_repro_build_multiple_named_targets.nim`
— is plain `repro build a b c`: with no path anchor the CLI synthesises
`.#a` itself. Learn the rule rather than one instance of it: **one
path/fragment selector maximum, first; bare names after it.**

**Gotcha 2 — a bare name that matches something on disk is a path.**
`classifyBuildSelector` (`repro_cli_support.nim:812`) classifies a
selector as path-shaped if it contains `/`, `\`, `.` or `#`, **or names
an existing path on disk**:

```nim
  if fileExists(extendedPath(raw)) or dirExists(extendedPath(raw)):
    result.kind = bskPath
    return
```

CodeTracer has a `test/` directory, so from its repo root a bare `repro
build test` resolves to that directory and never reaches the collection
resolver. The escape hatch is the fragment form, and the recipe says so
at the declaration (`codetracer/repro.nim:1700`):

> SELECT THEM AS `repro build .#test` / `repro build .#lint`. The
> fragment form is REQUIRED for `test`, not decoration: this repo has a
> `test/` directory […] `lint` has no such directory today, but is
> spelled the same way so the two lines cannot drift apart the day one is
> added.

Spelling both the same way when only one needs it is the idiom worth
copying. But `.#` is a **workaround for a repo layout**, not a general
rule: in a repo with no colliding directory, `repro build test` and the
verb alias `repro test` are both fine.

> Note the character scan runs *before* the disk probe, so a selector
> containing a `.` is path-shaped even when no such file exists.

---

## <a name="4-nondeterminism"></a>4. Non-determinism: remove it, or bless the tool that emitted it

io-mon records `mrNonDeterministic` when a monitored process reads an
entropy source. That record is **not** a monitoring loss — io-mon saw
the read; nothing is missing from the capture. What it costs the action
is decided by `NonDeterminismPolicy` (`dependency_gathering.nim:56`),
whose default `ndpUnblessed` is the fail-closed one: the action still
**succeeds** and its result is used; it is simply not remembered in the
action cache.

There is no specification document for any of this. The authoritative
prose lives in the source comments and test headers cited below, and the
engine's own diagnostics point operators at a spec file
(`Windows-Build-Correctness-Bitness-And-Capabilities.milestones.org`)
that does not exist in this workspace. That gap is why this section is
long.

### 4.1 Bless in the tool's own module, once

The blessing is a property of the **tool**, not of the edge. Declare it
in the tool's `cli:` block and every recipe invoking that tool inherits
it with nothing on the edge.
`libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/nim.nim:125` is the
model, and its comment explains the design better than a summary can:

> Windows-Build-Correctness M6 — the entropy blessing, declared HERE, on
> the tool, once. Every `nim.c(...)` and `nim.js(...)` edge in every
> recipe inherits it with nothing on the edge, which is the whole design:
> a recipe author writes `nim.c(...)` and gets the right answer without
> knowing that entropy exists.
>
> The blessing is scoped to ENTROPY, not to determinism in general. It
> says an `mrNonDeterministic` record from a nim process is not a reason
> to withhold a cache entry. It does not touch the file, library-load,
> ipc or external-content evidence that decides whether the capture is
> complete, and it says nothing about clock reads (`mrTimeRead`), which
> are a separate signal for exactly the reason that blessing them would
> mean blessing every program alive.

The corollary is that **a recipe cannot bless a tool it happens to
call.** The generated wrapper hard-codes the tool's declaration rather
than exposing it as an overridable parameter
(`dependency_gathering.nim:70`), and
`libs/repro_dsl_stdlib/tests/t_shell_entropy_is_not_blessed.nim:161`
pins that with `check not compiles(shell(..., nonDeterminism =
ndpEntropyBlessed))`.

### 4.2 The justification is empirical, and the compiler enforces it

`nonDeterminism entropyBlessed` with no justification is a **compile
error** (`libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim:355`):

```text
nonDeterminism entropyBlessed requires justification = "...": state what
this tool draws randomness FOR and why it cannot reach the tool's output.
An unjustified blessing silently restores cache publication for a tool
whose results may not be reproducible.
```

The rationale at `macros_a.nim:322` is the part to internalise: *"'Do not
bless anything you cannot justify' is only a rule if the compiler asks
for the reason."* A misspelt policy word is likewise an error rather than
a silent fallback, because a misspelling that inherited a blessing from
an enclosing scope would not be safe.

What a good justification looks like: nim's names the measurement (*"a
full monitored `nim c` (nim driving gcc and ld, 25 206 records,
mcComplete, eventLoss=0) in fact emitted ZERO mrNonDeterministic records
at all"*) and then says why the declaration is still worth making —
*"it must be in place before a nim or CRT revision starts drawing
entropy on a path that does not affect the output."* `mktemp`'s and
`git`'s, in `packages/mktemp.nim` and `packages/git.nim`, have the same
shape: the exact commands measured, the record counts, and the argument
that the random bytes designate a *location* or a *lock name* and never
the content of a product.

### 4.3 Never bless an interpreter

This is the trap, and it is a trap precisely because the fix looks like
plumbing repair.

Policy is **action**-scoped (`BuildAction.nonDeterminism`); evidence is
**process-tree**-scoped. For a compiler the two coincide — the tree under
`nim` is nim, gcc and ld, all of it "what nim does". For a shell they
come apart: the tree is chosen by the *script*. Measured on both the
Linux `linux-preload-hooks` and the Windows `windows-interpose-hooks`
backends (`packages/sh.nim:51`,
`t_shell_entropy_is_not_blessed.nim:16`):

- `bash` emits **zero** `mrNonDeterministic` records of its own. `bash -c
  'echo hello'` produces none on either platform — MSYS bash under
  `msys-2.0.dll` included, which refutes the "the Cygwin runtime seeds
  itself at startup" theory the blessing request rested on.
- `$RANDOM` emits **zero** records. A script whose whole output is `echo
  $RANDOM > out.txt` is genuinely unreproducible and leaves no entropy
  evidence at all. **So the entropy signal was never what guarded against
  script-level non-determinism**, and a shell blessing cannot be defended
  as waiving a signal that was not load-bearing. (Nor does `od -An -N8
  -tx1 /dev/urandom > out.txt`, per the same test header.)
- Every record a gate action does emit comes from a **child the script
  chose**. Across CodeTracer's ten gates: 45 records, all `getrandom`,
  all attributed by their own pids to `mktemp` (23) and `git` (22) —
  never to the shell.

The decisive artefact is a pair of records differing in no field but the
emitting pid (`t_shell_entropy_is_not_blessed.nim:54`):

```text
non-deterministic pid=1650509 path=getrandom
  detail=non-deterministic entropy source
  [mktemp -- names a scratch file, then throws the name away]
non-deterministic pid=1650533 path=getrandom
  detail=non-deterministic entropy source
  [uuidgen -- the drawn bytes ARE the declared output]
```

A blessing that waives the first waives the second. A gate that later
grew a `uuidgen > out.txt` line would publish a cache entry for a product
that differs on every run.

**Now the part that makes this a trap and not merely a rule.** A blessing
written in `sh.nim`'s `cli:` block *does not reach the edges it would be
written for*. Measured: it makes the **generated** wrapper `sh(command=,
args=)` come back `ndpEntropyBlessed` and leaves `shell()` — the proc
every gate goes through — at `ndpUnblessed`, because the blessing is
spliced into the generated wrapper's `recordToolInvocation` call and
`shell()` is hand-written and calls it without one. `packages/sh.nim:46`:

> So an author who blesses the shell here sees no change, reads it as
> broken plumbing, and repairs it — which is how the waiver would
> actually get made, by someone who by then believes they are only fixing
> a leak.

That is why the refusal is written at three separate sites — the `cli:`
block of `packages/sh.nim`, the `shell()` docstring at line 160, and
`packages/bash.nim`'s module header, which notes that `bash` is
provisioning-only so a blessing written *there* would compile and reach
nothing — and guarded by `t_shell_entropy_is_not_blessed.nim`, which
asserts **both wrappers separately** because one assertion would leave
the other open.

### 4.4 Prefer removing non-determinism to waiving it

When the entropy genuinely can reach output, a blessing is not merely
unwise — it is false. The right move is to make the run deterministic.

CodeTracer's five python-running gates were blocked by CPython's startup
`getrandom`. The remedy is not a `python3` blessing; it is one declared
environment variable (`codetracer/repro.nim:1765`):

```nim
const GateEnv = [("PYTHONHASHSEED", "0")]
```

The comment above it (`codetracer/repro.nim:1729`) is the clearest
statement of the whole principle in this workspace:

> A blessing says "this tool's entropy cannot reach its output". That is
> true of `mktemp` (the random suffix names a file nobody's verdict
> depends on) and of `git` (its entropy seeds internal hashing, not what
> it prints). It is FALSE of the hash seed: the seed decides `set` and
> `dict` iteration order, which is exactly the kind of thing a script
> prints, sorts by, or picks a "first" element out of. Entropy that
> genuinely can reach output must not be waived.
>
> So the nondeterminism is REMOVED instead of waived. Pinning the seed
> makes CPython skip the entropy read altogether -- there is no record
> left to grade -- and simultaneously makes the iteration order the gates
> observe a function of the recipe rather than of the run. The cache key
> improves because the RUN became deterministic, not because the evidence
> was silenced.

Two details of *how* it is declared are themselves idiomatic:

- **Declared, not merely exported.** `shell(..., extraEnv = ...)` layers
  the value over the inherited environment and a declared name *replaces*
  the inherited one, so a developer with `PYTHONHASHSEED` already set
  gets the same run as CI; and the `(name, value)` pair is folded into
  the action's weak fingerprint by `keyedOnActionEnvironment`, so a
  future change of the value cannot serve a result computed under the old
  one (`packages/sh.nim:115`). An environment variable a script *reads*
  but the action does not *declare* still reaches the script and
  contributes nothing to the key — which is the silent-wrong-answer case.
- **On all ten gates, not only the five that run python today.** The
  property asserted is about the family — "no gate's verdict depends on
  CPython's hash seed" — so a gate that grows a `python3` line later does
  not silently stop caching. A constant pair shifts every key once and
  then never again.

> A related constraint from the same docstring: `extraEnv` **values must
> be a function of the recipe, not of the host.** The provider snapshot
> and the lowered-graph cache are reused across invocations that differ
> only in the ambient environment, so a value read with `getEnv` at
> recipe-evaluation time is snapshotted at the first build and served to
> every later one. Where a build must be switchable, declare two actions,
> or route the choice through a variant — variants *are* folded into the
> lowered-graph cache key. See §7.

### 4.5 Per-emitting-image attribution is what makes a blessing checkable

A CLI spec is compiled into the recipe *provider* and reaches the engine
only as `BuildAction.nonDeterminism` — one slot, for the one tool the
action invoked. An engine grading a shell capture must ask about a tool
the action never invoked. `reprobuild@3909094c` added the other half:
each entropy record is attributed to the image that emitted it.

`EntropyObservation` grows an `image`, resolved at fold time from
`MonitorRecord.osPid` against the capture's own `mrProcessExec` records —
last exec before the read wins, absolute paths only, `execstatus=failed`
ignored. An unresolvable pid yields the **empty string**, and
`entropyBlessedTool("")` is `none`, so an unattributable read keeps its
full consequence. The per-image table is
`libs/repro_core/src/repro_core/entropy_blessings.nim`
(`EntropyBlessedTools`, today exactly `mktemp` and `git`).

The property that keeps the table honest, from its own header (line 23):

> `libs/repro_dsl_stdlib/tests/t_entropy_image_blessings.nim` asserts
> entry-for-entry that each image listed below is backed by a real
> `nonDeterminism entropyBlessed` in that tool's own CLI spec, carrying
> the SAME justification text. An entry whose spec stops blessing fails
> that test; the table cannot become a second, independent authority.

That test reads the justification off a **registered `BuildActionDef`**,
not off source text, so it fails the same way a recipe would if the
declaration ever stopped reaching the wrapper. It compares for
**equality**, not containment. And an image the test cannot build an edge
for *fails* rather than being skipped — "adding a blessing without adding
its check is the thing that must not be possible."

Grading is **unanimous, not a filter**: with the invoking tool unblessed,
every observation is asked separately and one unattributable or
unblessed record withholds the entry, because the entry is a promise
about the whole action's output.

The control that proves the mechanism works is two CodeTracer gate edges
differing in one line (`reprobuild@3909094c`):

```text
gate-entropy-control-mktemp   (mktemp -d)              cdHit   published
gate-entropy-control-uuidgen  (mktemp -d; uuidgen >f)  cdMiss  withheld
```

### 4.6 What a blessing is *not* scoped to

Entropy only (`mrNonDeterministic`). Clock reads (`mrTimeRead`) are a
separate signal that this engine deliberately does not grade for any
tool, "for exactly the reason that blessing them would mean blessing
every program alive". `git commit`'s object hash depends on its committer
timestamp, and nothing in `git`'s blessing waives that; the spec text
says so explicitly.

---

## <a name="5-uncacheable"></a>5. Uncacheable is safe; falsely-cacheable is not

The rule, from `entropy_blessings.nim:64`: *"ADDING AN ENTRY IS A
SOUNDNESS DECISION, NOT A CONVENIENCE. […] uncacheable is safe,
falsely-cacheable is not."* A lost cache hit costs a re-run. A wrongly
published entry serves a stale artefact indefinitely.

### The grade ladder

`MonitorEvidenceStatus`
(`libs/repro_build_engine/src/repro_build_engine.nim:933`) implements the
four-rung ladder from `reprobuild-specs/Failure-Semantics.md`
§"Monitoring Failures":

| Grade | Level | What the engine does |
|---|---|---|
| `mesComplete` | 0 | Publishes the action-cache record. |
| `mesKnownScopeLoss` | 1 | The action **still publishes**; the loss is handled by invalidating a narrow path set for downstream consumers. |
| `mesUnknownScopeLoss` | 2 | The action succeeds, but the publish is **skipped** and cache hits are disabled for the session. |
| `mesMonitorUnavailable` | 3 | The action **fails**. |

Level 2's diagnostic is the one you will meet in a log:

```text
monitor depfile is incomplete (unknown-scope loss); action-cache publish
skipped this session per Failure-Semantics.md §Monitoring Failures
```

Only one loss class is Level 1 today — kill-before-flush
(`classifyEventLossDetail`, `repro_build_engine.nim:5203`). Everything
else, including any detail string the classifier does not recognise,
defaults to Level 2, which is the fail-closed direction.
`reprobuild-specs/Monitor-Loss-Path-Invalidation.md` calls narrowing a
class to Level 1 a **soundness gate**: it demands a written proof for
that class, and "without a row here, the classifier defaults to Level 2".

> ⚠ **Two comments in `repro_build_engine.nim` are stale and say the
> opposite.** Line 949 annotates `mesKnownScopeLoss` as *"Level 1
> (currently treated as Level 2)"*, and the block at line 6726 says Level
> 1 "currently uses the same Level-2 handling until Gap II's narrow
> path-set invalidation ships". Gap II shipped (M9.R.73.2): the code at
> line 6322 publishes at Level 1, and `registerEvidenceInvalidation`
> (line 12709) deliberately excludes Level 1 from the session bit. Trust
> the code, not those two comments.

### The failure mode, stated concretely

**A better-looking grade over an incomplete record set is the failure
mode, not the goal.** The dangerous shape of a "fix" is one that moves an
action from Level 2 to Level 1, or from zero observations to one, without
the evidence actually improving — because both moves flip the engine from
*refusing to publish* to *publishing*.

The zero-observation guard is the other half of this, and it is narrow on
purpose (`repro_build_engine.nim:6225`). An action with **no observation
of any kind** — no read, no write, no probe, no directory enumeration, no
depfile input — gets `disableCacheHits` and `cirEmptyEvidence`: the same
publish refusal as Level 2. **One observation of any kind and it
publishes.** So a change that takes an action's observed set from 0 to 1 —
one incidental path, the working directory, anything — has moved it
across that line; and if the monitoring gap that produced the zero is
still there, the result is *strictly worse* than before: the same missing
evidence, now with a cache entry behind it.

Note also that `monitorObservedNoReads` does *not* test
`monitorReads.len == 0`. `collectEvidence` folds the action's own
argv-resolved root image, which resolves for essentially every monitored
action, so the guard excludes it explicitly; its one measured blind spot
is documented in place, along with why it is a cost rather than a hole.

### The test-design lesson

Two io-mon commits put it better than an abstract rule could.
`io-mon@87143d6`:

> `test_io_mon_cross_thread_sweep_sentinel` asserts the PAIRING, not the
> absence of losses, because a test that only demanded "no
> kill-before-flush after a sweep" would pass equally against a merge
> that had stopped detecting the loss at all — the regression that turns
> an honestly incomplete capture into a silently publishable one.

And `io-mon@3e12f24`, on strengthening a case "from the grade to the
thing that earns it":

> Checking only the grade would be satisfied by a merge that had stopped
> noticing the missing child, which is the one regression that must never
> ship.

**Assert the evidence, never the grade.**

### When the honest answer is "this edge does not cache"

CodeTracer's tenth gate cannot publish, and the recipe records why rather
than leaving the next reader to re-derive it
(`codetracer/repro.nim:1838`). Its port-busy scenario makes a real TCP
connection; `SO_PEERCRED` returns no pid for `AF_INET`, so io-mon reports
`peer=0` and both layers treat that as final. Making it publish would
mean relaxing a rule so that a connect counts as in-tree on weaker
evidence than a kernel-supplied peer identity — "the same class of act as
blessing `sh` for entropy, and it is refused here for the same reason".

The comment then names the honest alternative, which is the idiom to take
away:

> The available honest move, if this miss ever costs enough to matter, is
> to SPLIT the port-busy scenario into its own `cacheable = false` edge —
> which relocates the uncacheable work rather than pretending it is not
> there.

`cacheable` (a plain `bool` field on the action;
`repro_build_engine.nim:289`) is the only spelling — there is no
`uncacheable` and no `alwaysRun`. It means "never publish or consult the
action cache", which is a different axis from "re-run even when outputs
are current".

> **A reading trap in that same file.** All ten gates declare
> `cacheableValue = true`, including the one whose comment says it cannot
> publish. That is correct: `cacheable` expresses the recipe's *policy*,
> while the engine withholds the capture on the *evidence*. A skim that
> reads `cacheable = true` next to "STILL CANNOT PUBLISH" and concludes
> one of them is wrong has misread the split.

---

## <a name="6-observability"></a>6. Observability is a property of how you invoke, not only what you invoke

A native action is observable. The same work behind a shell wrapper may
not be — and on Windows, for a long time, it was not.

Concretely: `msys-2.0.dll` imports both `kernel32!ReadFile` and
`ntdll!NtReadFile`, and uses the NT export for ordinary disk files.
io-mon hooked only the Win32 layer, so a monitored MSYS child produced
opens, path probes and library loads and **not one `file-read` record** —
and reads are exactly what an action cache keys on. `io-mon@63692f5`:

```text
before  0 file-read records anywhere in the capture
after   grep reads data.txt: 12 bytes, then EOF, under grep's OWN pid
```

Two further failures in the same family: an injected Cygwin child whose
environment block never carried `REPRO_MONITOR_FRAGMENT_DIR` dropped
every record it produced (`io-mon@e0ec803`), and a blanket refusal to
inject any child with a Cygwin fork runtime next to its image left every
MSYS child uninstrumented (`io-mon@3e12f24`). Each took a week-class
investigation to characterise.

**Do not re-derive any of this.** The systemic constraint behind it —
Cygwin's `fork()` requiring identical DLL virtual addresses in parent and
child; the bare `STATUS_INVALID_FILE_FOR_SECTION` (`0xC0000020`) exit
with no stdout, no stderr and no debugger stop; four independent triggers
with the same signature; and a fifth failure that *hangs* instead — is
written up in
`codetracer-specs/Architecture/Hooking-Cygwin-Binaries-On-Windows.md`.
Read that before concluding a monitoring gap is in your recipe.

The practical idiom: **when an edge will not cache, ask what process tree
it actually created before you touch the recipe.** `repro debug io
monitor` and `io-mon inspect --format text` answer that directly, and
both commits above are cases where the answer was "your recipe is fine;
the shim could not see the child".

---

## <a name="7-facts"></a>7. ☐ Environment facts and capability probes — a pattern, not yet a primitive

**Reprobuild has no fact / probe / skip-reason primitive today.** A
search of the DSL and engine finds none, and nothing in this section
describes an API you can call. It is written down because the shape is
right and because the cost of the workaround is worth knowing before you
pay it.

Three near-misses are worth naming so you do not mistake them for the
thing:

- `libs/repro_fs_facts/` is a table of *static, cited* OS and filesystem
  constants. Its own header says it "does not probe".
- `requires:` on `DslServiceDef`
  (`repro_project_dsl/dsl_port_runtime.nim:1363`) is a systemd unit
  `Requires=` field, not a build precondition.
- `gevHostFact`
  (`libs/repro_provider_runtime/src/repro_provider_runtime/types.nim:43`)
  is an enum case in `GraphEvaluationInputKind` with **exactly one
  occurrence in the repo: its own declaration.** Zero producers, zero
  consumers — a protocol placeholder.

Host-fact `when` predicates *do* exist, but only in the Home-Profile
Intent layer (`reprobuild-specs/Home-Profile-Intent-Layer.md`,
`libs/repro_home_intent/`), where they select packages in an activity
rather than build actions, and evaluate against a fixed fact set you
cannot extend by running a command.

### The pattern

A capability question — *is this port free?*, *is `rr` usable?*, *is
Hyper-V present?* — should be **its own edge that computes a fact**, with
the expensive test edge taking that fact as an **input**. Two properties
make it work:

- The fact enters the downstream cache key, so **a skip can never be
  cached as a pass.** If the fact flips, the key changes and the verdict
  computed under the old fact is not served.
- The fact's value is *stable on a healthy machine*, so the expensive
  downstream edge still hits cache while the tiny uncacheable probe
  re-runs each time.

The mechanism the fact must travel through is an ordinary output file
named as a downstream input. Path strings wire the edge implicitly:

```nim
let configureAction = sh.runAction(
  actionId = "reprobuild-nix-daemon.configure",
  argv = @["cmake", "-S", ".", "-B", "build", "-DCMAKE_BUILD_TYPE=Debug"],
  inputs = @["CMakeLists.txt", "src/main.cpp"],
  outputs = @["build/Makefile"])

discard sh.runAction(
  actionId = "reprobuild-nix-daemon.build",
  argv = @["cmake", "--build", "build"],
  inputs = @["build/Makefile", "src/main.cpp"],
  outputs = @["build/reprobuild-nix-daemon"])
```

(`reprobuild-nix-daemon/repro.nim:18`.) The **content digest** of each
input file — not just its path — is mixed into the strong fingerprint by
`computeStrongFingerprint`
(`libs/repro_local_store/src/repro_local_store.nim:2223`), which is what
makes a fact file change a downstream key. Note the contrast with `after
= @[...]`, which is a pure ordering edge and contributes no content.

There is no stdout capture: `captureStdout` and friends do not exist. The
probe writes a **file**, and the consumer lists it.

### The hazard, stated as loudly as the pattern

**A skip is a pass that did not run.** Fact-driven skipping is only an
improvement if the reason is a first-class artefact — recorded, reported
as "N skipped because X", and failing in CI unless explicitly allowed.
Four real failures from this workspace's campaigns, each caused or hidden
by a silent skip:

- `python3` absent from `PATH` produced **two separate wrong
  measurements**. `reprobuild@3909094c`'s message records the correction
  to its own predecessor: *"the earlier capture was taken on a host with
  no `python3` on PATH, so four gates exited 127 and python never ran"* —
  a measurement of 45 entropy records, all excusable, that was really a
  measurement of four gates not running.
- `rr` was present only through one developer's `~/.nix-profile`, which
  was the sole reason 14 tests ever ran.
- Hyper-V was recorded as *host-blocked* when it was *build-blocked*.
- A sibling probe checked an umbrella module that had existed forever,
  and so passed silently for weeks.

### What the pattern costs today ⚠

Without a primitive you can still build it, but you own the parts:

- The probe is an edge whose output is a file, declared `cacheable =
  false` — its whole purpose is to re-observe the host. That is fine; it
  is cheap.
- The downstream edge takes that file as a declared input **and must
  actually read it**, because the monitored read set is what keys the
  cache (§2). A declared-but-unread fact file orders the edge and nothing
  more.
- The skip decision, the skip *reason*, and the "N skipped because X"
  report are yours to write and yours to gate in CI. Nothing in the
  engine does it for you, and nothing will notice if you stop.
- There is no typed vocabulary for "this edge requires capability C", so
  the requirement is expressible only as a convention between two edges.

The nearest supported alternative is a **variant** — a
solver-participating `Configurable` resolved at stage 2 and folded into
the lowered-graph cache key (`reprobuild-specs/Configurable-System.md`;
the `shell()` docstring points at it for exactly this purpose). A variant
is a recipe-level switch, not a host observation, so it answers "build it
two ways" and not "is `rr` usable here". Where the capability can be
*decided by the person invoking the build* rather than probed, a variant
is the supported mechanism and this whole section is unnecessary.

> Related but distinct, and also unfinished:
> `reprobuild-specs/Edge-Determinism-And-Soft-Rebuild.md` proposes a typed
> per-edge `determinism` property (`strong` / `weak` / `host-bound` /
> `volatile`) with a `soft-rebuild` / `hard-rebuild` CLI. It is marked
> ☐ **"Status: Design draft"** and is not implemented. Do not write
> `determinism …` in a recipe expecting it to do anything.

---

## <a name="8-adoption"></a>8. Adopt non-destructively

When you move an existing gate, lane or script into the graph, **keep the
script authoritative and add the edge alongside it**. CodeTracer's gate
block states the discipline (`codetracer/repro.nim:1674`):

> NON-DESTRUCTIVE, DELIBERATELY. The scripts stay authoritative and
> unmodified: the edge runs the same `bash <script>` the recipe runs,
> from the same working directory, and the process's exit status is the
> verdict -- so the node cannot disagree with the script it mirrors.

Three concrete consequences:

- **Nothing existing changes.** `just`, the CI workflows and the repo's
  own reachability gate (`ci/test/shell-gate-coverage.sh`, which measures
  reachability from CI workflow lanes and the `just` recipes those lanes
  call) are untouched, so the new edges neither satisfy nor disturb that
  guard. A gate wired into the graph is still required to be wired into
  CI.
- **No existence guard on the script path, on purpose.** A missing gate
  script must be a loud failure naming the path, not an edge that
  silently disappears from the graph (`codetracer/repro.nim:1710`).
- **Prove equivalence on a pass *and* on an induced failure.** A node
  observed agreeing with its script only on green is not verified — it
  has been shown to produce exit 0 when the script produces exit 0, and
  nothing else. Induce the failure and watch both report it.

The strongest form of that last point is the mutation evidence in
`codetracer@5ca36353`, where two changes were reverted one at a time,
each revert sha256-verified against the pristine file, each killing
exactly its own target:

> * name the declared variable `CT_GATE_ENV_PROBE` instead of
>   `PYTHONHASHSEED`, changing nothing else […] and exactly the five
>   python gates return to `unblessed-entropy` and miss: warm 9 -> 5.
> * hand awk the same bytes as a here-string again […] the 18 losses and
>   `mcIncomplete` come back, while the gate still exits 0 and passes all
>   16 contracts. **The gate's assertions never saw the difference; only
>   the evidence did.**

---

## <a name="9-measuring"></a>9. Measure honestly

### Cold versus warm, with a fresh cache root

Use `--action-cache-root=PATH` for a genuinely cold arm; do not
approximate one by touching files. A cold arm has nothing to hit, so it
is `0 hit / N miss` by construction — its value is the wall time, not the
hit count. `codetracer@5ca36353` reports the shape to copy:

```text
Measured on Linux, python3 on PATH, all ten exiting 0 throughout:

  cold  0 hit / 10 miss   (before and after; a cold cache has nothing to hit)
  warm  4 hit /  6 miss   before
  warm  9 hit /  1 miss   after
```

### Every gate must exit 0 before a hit count means anything

This is the most expensive measurement error in this campaign, and it
happened twice. A host with no `python3` on `PATH` — a WSL shell not
inheriting it — made four gates exit 127. They still produced cache
numbers. One of those runs appeared to cache *better* than the corrected
one, because four gates that never ran also never emitted the entropy
records that were blocking the rest. `reprobuild@3909094c` had to publish
a correction to its own predecessor's headline measurement for exactly
this reason.

**Check exit statuses before you report hit counts.** And say in the
report which host, which monitoring backend, and whether the tools under
test were actually present.

### Other traps in the same family

- **A single `df` reading is not capacity.** One sample of free space
  tells you nothing about whether a build will fit: the store reclaims,
  quarantines and grants concurrently with your build. Measure a trend,
  or measure after the store has settled.
- **A queued build is not a hung build.** `repro build` admits actions
  through runquota, and a legitimately-queued candidate can sit behind a
  long-running predecessor for far longer than any deadline.
  `waitForQueuedGrant`
  (`libs/repro_runquota/src/repro_runquota.nim:390`) emits a heartbeat
  every 5 s so the wait is never silent:

  ```text
  runquota.waiting <id> still waiting for a RunQuota grant waitedMs=<n>
  ```

  That line goes **directly to stderr** and is **not** suppressed by
  `--progress=quiet` — `repro_runquota` does not import the module where
  `BuildProgressMode` lives, so there is no path by which the mode could
  be consulted. If you see it, the build is queued, not wedged. If you
  see nothing at all for minutes, that is what the bounded deadline is
  for: after 10 minutes of genuine transport silence (no grant frame
  *and* no successful status probe) the client raises an actionable
  `ReproRunQuotaError` instead of waiting forever.

  The code comment records what this replaced: *"The previous
  implementation polled here forever with no timeout and no output, so a
  wedged/mid-restart daemon that never delivered a grant froze the whole
  build silently (observed: a `just test` frozen for hours)."* If you are
  on an older client, that silent hang is the behaviour you will see, and
  a queued build really is indistinguishable from a wedged one.

> **Agents, note:** `configuredBuildProgressMode`
> (`repro_cli_support.nim:6913`) defaults to `bpmQuiet` whenever
> `IN_AGENT_SHELL` is set. So an agent's `repro build` is quiet by
> default — but, per the above, still not silent about runquota.

### Useful flags when a number surprises you

- `repro build --list-targets [--json]` — what a selector actually
  resolves to.
- `repro why <package-or-action>` — why an edge rebuilt, with dirty
  inputs.
- `repro graph <target> --view=inputs|dependents|blast-radius` — what a
  change reaches.
- `repro build --measure=cache-evidence` and `--write-report` — the
  evidence behind a cache decision, which is what §5 says to assert on.

---

## What is not settled

| Topic | Status | Note |
|---|---|---|
| Capability facts / probes / skip reasons (§7) | ☐ Not implemented | Pattern only; no DSL vocabulary. `gevHostFact` is a placeholder with no producers or consumers. |
| Typed per-edge `determinism` (§7) | ☐ Design draft | `reprobuild-specs/Edge-Determinism-And-Soft-Rebuild.md`. |
| A spec for entropy blessings (§4) | ☐ Missing | Engine diagnostics cite `Windows-Build-Correctness-Bitness-And-Capabilities.milestones.org`, which does not exist in this workspace. The source comments are the authority. |
| `Build-Graph-Collections.md` status header (§3) | ⚠ Stale | Says "not yet implemented"; `collect` and the exclude rule ship. |
| `mesKnownScopeLoss` comments (§5) | ⚠ Stale | Two comments say Level 1 is treated as Level 2; the code publishes at Level 1. |
| `--progress=quiet` vs runquota output (§9) | ⚠ Divergent | `reprobuild-specs/CLI/build.md` says quiet "disables all progress output"; `runquota.waiting` is emitted regardless, per `docs/runquota-policy.md` and `Interactive-UX-And-Progress.md` Principle 1. Nobody has reconciled the three. |

## Related documentation

- [Recipes](recipes/README.md) — short how-tos for individual tasks.
- [The Three Modes](three-modes.md) — which shape of project file to
  write.
- [Trace-Based Incremental Testing](incremental-testing.md) — `repro
  watch --ct-incremental`.
- [Reprobuild for Experienced Developers & AI
  Agents](../agents/Repro-Intro-for-Agents.md).
- `reprobuild-specs/Build-Graph-Collections.md` — collections, exclude
  rules, CLI resolution.
- `reprobuild-specs/Failure-Semantics.md` §"Monitoring Failures" and
  `reprobuild-specs/Monitor-Loss-Path-Invalidation.md` — the grade
  ladder.
- `reprobuild-specs/Compiles-Are-Normal-Edges.md` — why the monitor, and
  not a declared list, supplies inputs.
- `codetracer-specs/Architecture/Hooking-Cygwin-Binaries-On-Windows.md` —
  the Windows/Cygwin observability constraint.

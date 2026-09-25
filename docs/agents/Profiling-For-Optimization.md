# Profiling For Optimization

Principles for making this codebase faster without making it wrong. The
mechanics at the end are repo-specific; everything before them is not.

## 1. Ask whether the step must run before asking how to make it faster

These are different questions and the second one is the weaker one.

For any hot term, first trace what consumes its output — end to end, to a real
caller, not to a plausible one. Work whose consumer is conditional, or absent
on the path being measured, is not a performance problem. It is a design
defect that shows up as one.

The three shapes this takes, in descending order of value:

- **Nothing reads it here.** Build it on demand instead of always. The
  guarantee is preserved by changing *when*, not *whether*.
- **Something reads far less than is produced.** Produce the summary, not the
  population; the cheaper predicate often already exists on disk or in a
  header.
- **It is genuinely needed.** Now make it faster.

Removing work is also more reliable than accelerating it, because it cannot be
undone by the next change to the surrounding code.

## 2. An estimate derived by subtraction is not a measurement

Sizing a term by subtracting known costs from a total, or by counting call
sites and multiplying, produces a number with no evidence in it. Such estimates
in this repo have been wrong by an order of magnitude in both directions, and
the errors are not random: they are largest exactly where the reasoning felt
most solid.

Measure the term directly, in situ, under the access pattern it really sees.
The same operation can differ by 20× purely by how it is reached — a probe of
the same path costs one thing in a tight loop and another when each call lands
on a different directory.

## 3. Counters find what you already suspect; profiles find what is there

Purpose-built instrumentation is shaped by a hypothesis. That makes it precise
and makes it blind: it will happily report five decimal places about a term
that is not the problem, while the actual top cost has no counter at all
because nobody thought to add one.

Profile first to find where the time is. Use counters second, to decompose a
term you have already located. Precision on the wrong term is zero information.

## 4. The harness is part of the measurement

Reproducing the command is not reproducing the run. Anything the program
resolves from its environment — `PATH`, environment variables, the working
directory, the presence of a daemon or socket — can send it down a branch it
never takes in production, and a profile of that branch is fiction that looks
like data.

Before believing any profile, ask: *is this process seeing what a real one
sees?* A fallback path taken only because the harness under-specified the
environment is the most convincing wrong answer available.

When such a fallback turns out to be ruinously expensive, that is a real
finding of a different kind — a performance cliff gated on inherited
environment is a defect even when it did not cause your number.

## 5. State what the measurement is *of*, or it is not transferable

A number is meaningless without the conditions that produced it. The ones that
have mattered here:

- **Cache age.** A young cache and a mature one differ by multiples on the same
  code, because cached state accumulates. A measurement on a fresh root is not
  a measurement about a machine anyone actually uses.
- **Warm versus cold.** Verify warmth structurally rather than assuming it —
  see the mechanics below.
- **Build mode, host load, graph size.** An effect that grows with graph size
  is a different finding from one that does not; measure at more than one
  scale before generalising.

Conclusions drawn without these conditions have retired whole avenues of
investigation incorrectly. When you record a result, record its conditions in
the same sentence.

## 6. Optimisations can introduce failure modes the slow version could not have

This is the most important principle here, because it cuts against the instinct
that a faster version of the same computation is the same computation.

Replacing a self-describing structure with a faster one can silently remove a
check that was doing work nobody had named. A structure that grows as it is
filled reveals a short write by being short; a pre-sized one absorbs the same
bug in silence. When you make something faster, ask what the old shape was
accidentally guaranteeing — and whether the corpus you are testing against can
even distinguish the failure.

The corollary: a test corpus assembled from data the system produces itself may
be unable to exercise paths that only hostile or foreign input reaches. Data
arriving from a shared cache, another machine, or an older version is not
constrained by the invariants your writer happens to maintain.

## 7. Verify the artifact, not the build

Confirm that the binary you measured contains the change you are measuring, by
a literal that is actually used — dead code is eliminated and proves nothing.
Stale binaries are the single most common source of confident wrong results,
and they fail in the most dangerous direction: they report success.

Never read a build's success through a pipe; the pipeline's exit status is the
last command's, and a failed build reads green.

## 8. Read numbers conservatively

- Under contention, prefer the minimum. Noise only adds time, so the minimum is
  the robust estimator; medians move by tens of percent on a loaded machine.
- Establish the floor. If a trivial process costs about as much as the effect
  you are chasing, nothing measured in that window is real.
- Alternate arms rather than running all of A then all of B, and repeat the
  first arm at the end. Drift is common; that repeat is what detects it.
- Price the instrument itself and subtract it explicitly. Timing at scale is
  not free and belongs in the accounting.
- **Report what you can support and decline what you cannot.** A precisely
  measured component cost with an honest "I could not isolate the end-to-end
  effect" is worth more than a plausible total. Declining to quote a number is
  always available and is never the weaker result.

## 9. Gaps and disagreements are findings

When a total exceeds the sum of its parts, the difference is unattributed work,
not rounding. When two code paths that should agree about the same state give
different answers, that is a correctness question that outranks whatever
performance question led you there — chase it first and report it before
continuing.

Performance work is unusually good at surfacing correctness defects, because it
forces you to establish what the code actually does rather than what it is
believed to do. Expect this, and treat such a finding as the more valuable
output.

## Mechanics (this repo, macOS)

**Sampling profile.** `xctrace` is not on the devshell `PATH`, and
`xcode-select` may point at a nix SDK, so invoke it absolutely with an explicit
developer dir:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xctrace record --template 'Time Profiler' \
    --all-processes --time-limit 14s --output prof.trace
```

Run the workload in a background loop while that records. `--launch` profiles
only the launching shell, not its children. `--all-processes` captures the whole
machine, so filter by process name when parsing. A single build step is far too
short to sample — loop it.

**Parsing.** Export the `time-profile` table with `xctrace export --xpath`. The
XML is **reference-compressed**: a value appears once with `fmt="…"` and later
rows refer to it by `ref="…"`. A parser that counts only `fmt=` occurrences
undercounts by orders of magnitude. Build an id→value table first, then resolve
references. Leaf frames say what is hot; walking each stack up to the nearest
frame in our own modules says who called it, which is the part that turns a
symbol into a fix.

**A warm no-op must be verified, not assumed.** Any change to the engine binary
invalidates a fixture's warm state, and the first run after a rebuild
re-executes actions. Run the workload two or three times and confirm the timing
table shows **no `process wait` row** before reading anything.

**A no-op needs a reachable `runquotad`.** Without one, every invocation spawns
its own and the measurement is dominated by daemon startup — roughly an order of
magnitude. Point `RUNQUOTA_SOCKET` at a running daemon on a short path.

**Prefer `--show=timing` rows to wall clock.** They decompose the total and stay
stable when wall clock does not.

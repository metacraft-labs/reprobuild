# Build Stats

`repro build` can print Ninja-like timing diagnostics for scheduler and
Reprobuild CLI phases:

```sh
repro build --show=timing
repro build --show=none
```

`--show` is the presentation axis of the measurement model
(`reprobuild-specs/CLI/README.md` §"Measurement: Collect, Present, Persist").
`--show=timing` also implies `--measure=timing`: you cannot render what was
never gathered. The `REPROBUILD_SHOW` environment variable takes the same
category list and sets the default; an explicit `--show=` flag replaces it.

The text output uses the same column shape as Ninja's `-d stats` output:

```text
metric                               count   avg (us)        total (ms)
repro provider compile                   1    12450.5        12.5
repro scheduler total                    1    25100.0        25.1
```

The build report's `stats.metrics` array carries the same `name`, `count`,
`avgUs`, and `totalMs` fields so benchmark tooling can compare Reprobuild and
Ninja without scraping terminal output. It is populated when `timing` is
measured and the report is persisted (`repro build --measure=timing
--write-report`).

## Per-execution rows go to RunQuota (`ext_repro_action`)

Raw per-execution rows are not Reprobuild's to store. Every action RunQuota
admitted gets one `ext_repro_action` row on RunQuota's execution spine,
carrying what RunQuota cannot see: the stable action id, the action
compatibility key, the cache decision and why it missed, tool identity,
output size, and the dependency-evidence counts. The extension is registered
as owner `reprobuild`, extension id `repro_action`, schema version 1 — the
three registry columns that together spell `reprobuild.action.v1`.

Reprobuild does not define a database for these rows, does not choose their
location, and does not manage their retention. Read them back through
RunQuota's query interface, which returns host-qualified rows:

```sh
runquota observations --json          # counters, including refused rows
```

Two things a reader must know before counting anything:

- **There is no row for a cache hit.** A hit is the case where nothing
  executed, so there is no execution for a row to be joined to. The
  `cache_outcome` column therefore records the decision that led to a
  *launch*; counting hits from this table alone will undercount them.
- **`strong_fingerprint` is often NULL, and that is honest.** The
  action-cache lookup clears the strong fingerprint on its metadata-only
  fast path and returns no record at all on most miss arms, so on those
  paths the key genuinely does not exist at the moment the row is written.
  A row reports the value the lookup compared against when there was one.

Built-in actions (`fs.copyFile` and friends) run inside the engine's own
process, take no lease, and so produce no rows at all.

## Test executions go to the same store (`ext_test_execution`)

The parallel test runner is the store's second writer. Every test execution it
runs takes a RunQuota lease, so it gets the same execution spine row a compile
or a link gets — start and finish, duration, exit status, termination kind,
peak resident size, host and hardware profile — and then two extension rows on
top of it.

**`ext_test_execution` is framework-neutral and owned by no test framework.**
Owner `reprobuild`, extension id `test_execution`, schema version 1. It
carries only what every test framework has: `test_id`, `suite`, `status` (one
of `pass`, `fail`, `skip`, `xfail`, `xpass`, `leak`, `timeout`), the case's own
`duration_ms`, `attempt`/`retry_of`, `error_message`, `skip_reason`, and the
two output sizes. Three of those are `not null` — `test_id`, `status`,
`attempt` — and nothing else is required, so a runner for some other framework
records a complete outcome without inventing a single value.

**`ext_codetracer_test` carries what only this runner has.** Owner
`codetracer`, extension id `codetracer_test`, schema version 1: the trace facts
(`recording_path`, `trace_id`, `trace_format_version`, `recorder`,
`replay_ok`) and the Tier-1 binary protocol's own (`protocol_aware`,
`run_name`, `body_hash`, `checkpoint_count`, `status_disagreement`,
`harness_error`). Every column is nullable. A runner that never declares this
extension still writes a complete generic row.

The split is not organisational. A generic layer only one runner can populate
would become that runner's schema by default, and every other framework under
Reprobuild would then either record nothing or distort itself to fit.

**And it is not a claim: a second runner populates the same table.**
`repro_tap_test_runner` (`tools/tap-test-runner`) runs TAP 13 producers —
shell scripts, `node:test`, perl's `prove`, pytest-tap, anything that prints
the protocol — through the adapter in
[`reprobuild-test-adapters`](https://github.com/metacraft-labs/reprobuild-test-adapters).
It declares `test_execution` from the *same* constants CodeTracer's reporter
declares it from (`ct_test_interface`, imported by both, spelled by neither),
writes the same `ext_test_execution` rows, and declares no other extension at
all. TAP has no suite and no per-case output split, so those columns are NULL
in its rows rather than `''` and `0` — the absences the generic schema was
made nullable for, exercised by a runner that genuinely has them.

```sh
repro_tap_test_runner --bin-dir=build/tap-test-bin --summary-json=tap-run.json
```

## `stats flaky` and `stats duration` read the generic layer, and only it

```sh
repro_test_runner stats flaky --json
repro_test_runner stats duration --json
```

Both answer from `ext_test_execution` over `runquotad`'s query interface, and
from no other table. They therefore cannot tell which runner produced a row —
two runners with the same pass/fail pattern produce byte-identical entries
apart from the test's own name, which is what invariant OS-8 is worth. The
framework layer stays distinguishable where it should be: a query for
`ext_codetracer_test` returns rows for exactly the CodeTracer executions.

- `flaky` lists tests that have BOTH passed and failed in the window. A test
  that only ever failed is broken, not flaky, and is not listed.
- `duration` reports mean, median, p90 and p99 over the case durations the
  runners reported. Executions whose runner reported no duration are excluded
  from the sample rather than counted as zero, and `samples` says how many
  were left.
- With no daemon the window reads `unavailable` rather than empty, and the
  exit code stays 0: a missing daemon is not an error.

## `stats last-pass` and `stats new-failures` answer point-in-time questions

```sh
repro_test_runner stats last-pass "suite::case" --json
repro_test_runner stats new-failures --json
```

`last-pass` reports the most recent PASSING execution of one test: its
timestamp, the revision it ran at, and the host it ran on. It has three
answers, not two — "never ran here", "ran here and never passed", and "passed
at T" — because the first two are different problems and a reader who cannot
tell them apart reads a mistyped test name as a broken test. A test whose
runner recorded no revision reports `unknown`, never an empty string.

`new-failures` partitions the current failures into **new** (there is a passing
execution in the window) and **long-standing** (there is not), which is the
difference between a regression worth bisecting and a test that was already
red.

**It reports the partition per host as well as pooled, and names where the two
disagree.** A test that passes on every machine but one is a host problem, not
a regression — but pooled across hosts it looks exactly like a regression,
because the window does contain a pass. The `disagreements` array lists every
test whose pooled verdict differs from a host's, with which kind:

- `age-differs` — pooled says `new`, the host that is actually failing it says
  `long-standing` (or the reverse).
- `not-failing-everywhere` — pooled says the test is currently failing; on at
  least one host its most recent execution passed.

Reading only the pooled column is what the array exists to stop.

## Adaptive timeouts and duration sharding read the same rows

Both are off unless asked for, and both fall back rather than guess.

```sh
repro_test_runner --adaptive-timeout --test-timeout=60 --bin-dir=...
repro_test_runner --partition=slice:1/4 --shard-strategy=duration --bin-dir=...
```

`--adaptive-timeout` derives each case's timeout from the store:
`max(minimum, metric x multiplier)`, capped at `--test-timeout`. Defaults are
metric `p99`, multiplier `3.0`, minimum `5s`, window `20` executions per test;
each is overridable (`--adaptive-timeout-metric`, `-multiplier`, `-minimum`,
`-runs`). **A case the store has never seen keeps `--test-timeout`** — the
runner's own configured default — rather than a value derived from nothing.
The fallback is keyed on the SAMPLE COUNT, not on the metric: a test that has
always run in under a millisecond has a metric of zero and real history, and
must not be treated as unknown.

`--shard-strategy=duration` bin-packs `--partition` by estimated wall-clock
time (greedy: longest first, into the lightest shard) instead of by case count.
**When no case in the run has duration history it falls back to `count` and
says so** — the run summary records `appliedStrategy` alongside
`requestedStrategy` and a `fellBack` flag, because a count split wearing the
name `duration` is indistinguishable from a real bin-pack in the case set
alone.

Both read through the same query interface every `stats` subcommand uses; there
is no second store and no second reader. With no daemon reachable the runner
says so on stderr, uses its configured defaults, and runs — a missing daemon is
not an error.

**`termination` is what separates an OOM kill from an assertion failure.** Both
are non-zero exits and an exit status cannot tell them apart, which matters
most under a parallel runner: an OOM correlates with how much else was running,
not with the test. The runner does not guess. With
`--test-memory-limit-mb=N` (env `REPRO_TEST_MEMORY_LIMIT_MB`) it samples the
resident size of each test's whole process tree, kills a test that crosses the
ceiling, and reports the kill to RunQuota — which records
`termination = oom_killed` where an ordinary failure records `exited`. The
ceiling is also the memory the test reserved from RunQuota, so the two rows
agree about what the test was admitted for. Without the flag no ceiling is
enforced and no execution is ever labelled `oom_killed`.

**There is no `.nimtest/history.db`.** The per-runner history backend is
retired, not migrated: nothing read it, and the shared store answers the same
questions across builds and tests at once. The runner never opens the store's
database file either — `runquotad` is the only sanctioned reader.

Capture needs no flag. With no daemon reachable the runner records nothing,
says so in its summary as `"runquota_history": false`, and runs exactly as it
did before; a missing daemon is never an error. Admission never gates the
runner's own concurrency: a lease the daemon queues is abandoned rather than
waited for, because an observation that delays the work it observes has
already cost more than it is worth. Turn recording off outright with
`--no-runquota-history` or `REPRO_TEST_NO_RUNQUOTA_HISTORY=1`.

## `repro stats` reads that store, and nothing else

`repro stats` renders from RunQuota's observation store, over `runquotad`'s
query interface. It never opens the store's database file: `runquotad` is the
only sanctioned reader.

Every reported statistic carries the qualification the store's invariants
require — the time window it covers, how many spine rows it was computed
over, and the host/hardware profile it describes:

```sh
repro stats status
repro stats overview
repro stats rank --scope=actions --by=cache-miss-count --json
```

**The window says whose rows it covers.** One host-wide `runquotad` holds every
user's executions, so a query has to name a scope. `repro stats` asks for
`scope: owner` — the calling uid, taken by the daemon from peer credentials and
never from anything the CLI declares. Widening to the whole host is a real
question with a real answer, but it has to be asked for; a human surface that
widened silently would show you a colleague's builds on a shared machine with
nothing to say so. The scope the rows were actually selected under is rendered
on every surface, `--json` and text alike.

**An empty window is never rendered as zeros.** Four different states produce
"no figures", and `repro stats` names which one it is rather than printing a
ranking of nothing:

| state | what it means | what to do |
| --- | --- | --- |
| `unavailable` | no `runquotad` answered | start the daemon |
| `query-failed` | a daemon answered and the query did not | report it |
| `capture-disabled` | the daemon is recording nothing | enable capture |
| `empty` | the daemon knows nothing for this scope yet | build something |

**A store with counted drops renders as `incomplete`, never as a thin
`complete`.** `runquotad` counts every observation it lost — a full writer
queue, a write failure, a refused self-report, a refused extension row — and
`repro stats` reads those counters back through the `observations` inspection
subject and labels the sample accordingly. Statistics over a silently
truncated window read as authoritative, which is worse than having none.

Two views do not have a shared-store answer, and say so instead of inventing
one:

- `--scope=targets`: RunQuota's spine has no Reprobuild *target* dimension and
  `ext_repro_action` v1 does not carry one. Rank by `--scope=tools` (RunQuota's
  stats key) or `--scope=actions` instead.
- `repro graph --view=critical-path --run=last`: the query interface does not
  expose the `runs` table, so there is no last run id to resolve.

## The project-local store holds derived rollups only

`.repro/stats/observations.jsonl` and `.repro/stats/summary.json` are retired,
along with the schema ids `reprobuild.daemon.stats-observation.v1` and
`reprobuild.daemon.stats-summary.v1`. Nothing read them but `repro stats`,
which now reads the shared store, so they are **superseded rather than
migrated**: an existing file is left where it is and never imported. Importing
it would inject rows carrying no host identity and no hardware profile into a
store whose OS-6 invariant refuses aggregates that lack them.

`--write-stats` survives with a narrower job: it names the project-local
*derived* store, `.repro/stats/derived/`, which holds rollups computed **from**
RunQuota's rows and no raw samples of its own. Its SQLite backend is not linked
yet, so queued rollup inputs are discarded — and the discard is **counted** and
reported by `repro stats status`, rather than presented as an empty store.

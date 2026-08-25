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

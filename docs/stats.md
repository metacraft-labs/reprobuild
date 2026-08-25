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

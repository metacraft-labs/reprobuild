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

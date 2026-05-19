# Build Stats

`repro build` can print Ninja-like timing diagnostics for scheduler and
Reprobuild CLI phases:

```sh
repro build --stats
repro build --stats=text
repro build --stats=none
```

`--stats` is the same as `--stats=text`. The `REPROBUILD_STATS` environment
variable accepts `1`, `true`, `yes`, `on`, `text`, or `stats` to enable the
table, and `0`, `false`, `no`, `off`, or `none` to disable it. An explicit
`--stats=` flag overrides the environment.

The text output uses the same column shape as Ninja's `-d stats` output:

```text
metric                               count   avg (us)        total (ms)
repro provider compile                   1    12450.5        12.5
repro scheduler total                    1    25100.0        25.1
```

Each build report also contains a `stats.metrics` array with `name`, `count`,
`avgUs`, and `totalMs` fields so benchmark tooling can compare Reprobuild and
Ninja without scraping terminal output.

# Build Introspection

`repro build` writes a structured build report when `--report=full` is active
and exposes a non-mutating scheduler/cache walk through `--dry-run`:

```sh
repro build --dry-run --progress=quiet --log=actions
repro build --dry-run --diagnostics=.repro/build/reprobuild/dry-run.log
```

Dry run mode resolves the project, lowers the selected graph, checks declared
outputs, probes the action cache, and reports which actions would execute. It
does not spawn build actions and does not write action outputs. Actions that
would execute are reported with:

- `status: "asWouldRun"`
- `launched: false`
- `wouldLaunch: true`
- `cacheDecision`
- `reason`

The `reason` field is intended for cache invalidation diagnosis. Typical values
include:

- `dependency-launched`
- `missing-output`
- `not-cacheable`
- `policy-requires-execution`
- `input changed: PATH`
- `no cache record for weak fingerprint`

The same fields are present in normal build reports for actions that do execute
or are skipped. Normal builds also keep the scheduler `trace` array, which
records cache-skipped events such as `dependency-launched` and `missing-output`.

For quiet terminal output with full diagnostics, combine:

```sh
repro build --progress=quiet --log=quiet \
  --diagnostics=.repro/build/reprobuild/diagnostics.log
```

`--diagnostics=PATH` records summary/action lines that would otherwise be printed
to the terminal. It is a debugging artifact, not a persistent state file.

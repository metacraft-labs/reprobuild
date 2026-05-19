# Build Progress

`repro build` reports scheduler progress with:

```sh
repro build --progress=auto
repro build --progress=plain
repro build --progress=none
```

`auto` is the default. It renders a single updating progress line when stderr
is an interactive terminal, and stays silent for redirected output so existing
logs and benchmark parsers remain stable.

`plain` forces the progress line even when output is captured. This is useful
for tests and wrappers that want deterministic progress output.

`none` disables progress output. The `REPROBUILD_PROGRESS` environment variable
accepts the same values and is overridden by an explicit `--progress=` flag.

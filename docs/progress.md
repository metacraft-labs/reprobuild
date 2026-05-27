# Build Progress

`repro build` reports scheduler progress on stderr. The selected mode is
controlled by `--progress=`:

```sh
repro build --progress=bar-line
repro build --progress=line
repro build --progress=lines
repro build --progress=lines-bar
repro build --progress=dots
repro build --progress=quiet
```

`bar-line` is the default. It renders a Ninja-like single updating line with a
fixed-width progress bar on the left:

```text
repro [########............] 12/28 42% running=3 ready=5 started gcc -c ...
```

On ANSI-capable terminals, progress bars use color by default: completed
segments are highlighted, pending segments are dimmed, and the plain ASCII shape
is preserved for logs and limited terminals. Set `NO_COLOR` or
`REPROBUILD_COLOR=never` to disable color in the default `auto` mode. Set
`REPROBUILD_COLOR=always` to force color, including when output is captured by a
wrapper that still interprets ANSI escapes. `REPROBUILD_COLOR=auto` is the
default.

The progress line is redrawn with carriage returns. When captured by tools that
do not interpret terminal control characters, every redraw may appear as a
separate physical line. Commands shown in progress output are normalized to one
physical line before truncation.

Available modes:

| Mode | Aliases | Behavior |
| --- | --- | --- |
| `quiet` | `silent`, `none`, `off` | Prints no progress output. The process exit code is the build result. |
| `line` | `ninja`, `single-line` | Prints one redrawn Ninja-like progress line without a progress bar. |
| `bar-line` | `bar`, `ninja-bar`, `auto`, `plain` | Prints one redrawn progress line with a fixed-width progress bar. This is the default. |
| `lines` | `tup`, `per-line` | Prints one line per progress event, without a persistent progress bar. |
| `lines-bar` | `tup-bar`, `per-line-bar` | Prints one line per progress event and keeps a dynamically sized progress bar at the bottom. |
| `dots` | `dot` | Prints one dot per completed action. |

`REPROBUILD_PROGRESS` accepts the same mode names and aliases. An explicit
`--progress=` flag overrides the environment.

Quiet progress can be combined with diagnostics output when detailed build
information is needed without terminal chatter:

```sh
repro build --progress=quiet --diagnostics=.repro/build/reprobuild/diagnostics.log
```

`--diagnostics=PATH` writes the detailed provider, scheduler, and action summary
that verbose terminal output would otherwise expose. `--log=quiet` suppresses
action-summary terminal logs; `--log=summary` and `--log=actions` are intended
for debugging and CI diagnostics.

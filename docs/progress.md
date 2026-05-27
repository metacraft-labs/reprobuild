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
repro check[######....] build[#####.....] checked=12/28 42% built=9/28 exec=3 running=3 ready=5 started gcc -c ...
```

The progress fraction counts selected scheduler actions that have been checked
or completed, not command executions. A steady-state no-op build still visits
the selected graph to verify invalidation state, so it may finish at
`checked=30/30` while launching zero commands. Actual execution is indicated by
`started` and `executed` events, with `running=` showing how many actions are
currently launched. `up-to-date` and `cache-hit` events did not execute the
shown action during that build invocation.

The default bar-line renderer shows two progress bars:

- `check[...]` tracks actions whose run/skip decision has been reached.
- `build[...]` tracks actions whose build state has settled. Skipped
  `up-to-date` and `cache-hit` actions settle immediately; launched actions
  settle when their command completes.

While the scheduler is still discovering the run/skip decisions, both bars are
scaled to the selected graph size. For example, if 25 of 40 actions have been
checked and their decisions are "execute 4, skip 21", the check bar is `25/40`
and the build bar is `21/40` until those four commands finish. Once all
decisions are known and commands are still running, the second bar switches to
execution scale and the `exec=X/Y` counter reports completed command executions
out of planned command executions. This execution-scale mode can later use
RunQuota duration estimates when the RunQuota protocol exposes an
acknowledge-and-wait phase; without those estimates, it uses the planned
execution count.

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

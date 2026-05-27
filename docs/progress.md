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
repro build --progress-bars=overlay
repro build --progress-bars=split
```

`bar-line` is the default. It renders a Ninja-like single updating line with a
fixed-width progress bar on the left:

```text
▕████████▓▓▓▓░░░░░░░░░░░░▏ checked=12/28 running=3 gcc -c ...
```

The progress fraction counts selected scheduler actions that have been checked
or completed, not command executions. A steady-state no-op build still visits
the selected graph to verify invalidation state, so it may finish at
`checked=30/30` while launching zero commands. Actual execution is indicated by
`started` and `executed` events, with `running=` showing how many actions are
currently launched. `up-to-date` and `cache-hit` events did not execute the
shown action during that build invocation.

The default bar-line renderer shows one overlaid progress bar:

- The solid segment tracks actions whose build state has settled. Skipped
  `up-to-date` and `cache-hit` actions settle immediately; launched actions
  settle when their command completes.
- The striped segment overlays the additional actions whose run/skip decision
  has been reached but whose execution, if any, has not settled yet.
- The dim segment is the part of the selected graph that has not yet reached a
  run/skip decision.

While the scheduler is still discovering run/skip decisions, the bar is scaled
to the selected graph size. For example, if 25 of 40 actions have been checked
and their decisions are "execute 4, skip 21", the solid segment is `21/40` and
the solid-plus-striped overlay is `25/40` until those four commands finish. Once
all decisions are known and commands are still running, the bar switches to a
third color and an execution scale: `exec=X/Y` reports completed command
executions out of planned command executions. Progress counters are padded to
the selected graph or execution-plan width so the rest of the line remains
stable while counts advance. This execution-scale mode can
later use RunQuota duration estimates when the RunQuota protocol exposes an
acknowledge-and-wait phase; without those estimates, it uses the planned
execution count.

When ANSI color is enabled, the bar uses Unicode block glyphs by default. In
non-color output, such as dumb terminals or most captured logs, it falls back to
plain ASCII characters.

Supported terminals can also show native progress in their tab, window, or
taskbar UI through the OSC 9;4 sequence. Reprobuild emits this side-channel in
`auto` mode only for terminals known to support it, including Windows Terminal,
iTerm2, Ghostty, WezTerm, Konsole, ConEmu, and mintty. Set
`REPROBUILD_TERMINAL_PROGRESS=never` to disable it or
`REPROBUILD_TERMINAL_PROGRESS=always` to force it for an ANSI-capable terminal.

`--progress-bars=split` keeps the checking and execution views separate:

```text
▕████████████░░░░░░░░▏ checked=25/40 ▕███░░░░░░▏ built=1/4 running=3 gcc -c ...
```

The first bar is dedicated to checking and is always scaled to the selected
graph. The execution bar appears as soon as the scheduler discovers at least
one command that must run. Its denominator is the number of discovered commands
that must execute, so it can rescale while the scheduler is still finding more
work. Once the run/skip plan is complete, the execution denominator is stable.
The checked counter is displayed after the check bar. When the execution bar is
visible, the built counter is displayed after that second bar and reports
completed command executions out of planned command executions. The line keeps
only `running=N` as the queue summary, followed by one currently executing
command, preferring the most recently started active command. This mode is
intended for side-by-side experience with the overlaid model; set
`REPROBUILD_PROGRESS_BARS=split` to make it the default locally.

The checking scale is currently scheduler actions, not individual filesystem
metadata probes. That is why checking can still advance unevenly when one action
has a large input set and another has a small one. A future file-check progress
layer should be driven from the cache/input-verification code path once it can
report a total and completed probe count before each expensive scan.

Before the scheduler knows the graph size, the progress renderer prints phase
status such as `preparing build`, `loading project interface`, `resolving
tool identities`, `checking provider compile`, `refreshing project provider
graph`, and `lowering project graph`. These phase lines are intentionally drawn
before each potentially slow operation so a stuck build reports the phase it was
entering.

On ANSI-capable terminals, progress bars use color by default: settled,
checked-but-unsettled, execution-scale, and pending segments use distinct
colors. Set `NO_COLOR` or
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

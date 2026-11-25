## When to give up on a compiler that has not exited yet.
##
## On Windows `runCommand` waits for a `nim c` whose merged output goes to a
## temp-file sink. A wedged compile -- its gcc children can deadlock on
## Windows; the 0.1.4 release lost a runner for more than four hours on the
## full-closure interface extraction -- must be killed with whatever it wrote,
## never waited on forever.
##
## The wait used to stop at a fixed total of 1800 s. That cannot tell a wedged
## compile from a slow one. On a windows-arm64 runner the dev-env provider
## compile normally takes about 1320 s, so a host 1.4x slower was killed while
## it was still printing gcc commands, and a genuinely wedged compile still
## held the runner for the full 30 minutes. Raising the number moves the same
## trade-off: it kills fewer slow hosts and holds wedged ones longer.
##
## A working compile writes to the sink as it goes: Nim prints a progress dot
## per module during semantic analysis, a `CC:` line (or, with `--listCmd`,
## the full command) per C file, and a `[Link]` hint. A wedged one writes
## nothing. So the primary rule is a STALL window: give up when the sink has
## not changed size for `stallSeconds`. The overall CEILING stays, far above
## any legitimate compile, only so a process that wedges while still writing
## (a loop that prints) cannot hold the slot indefinitely.
##
## This module is the decision alone, over observed sink sizes and clock
## readings, so it is portable and unit-tested on every host; the Windows wait
## loop in `runCommand` feeds it.

import std/strutils

const
  CompileCeilingEnv* = "REPRO_INTERFACE_COMPILE_TIMEOUT_SECONDS"
    ## The overall ceiling, in seconds, on one compiler process. A value
    ## `<= 0` removes the ceiling. Unset or unparsable: `DefaultCompileCeilingSeconds`.
  CompileStallEnv* = "REPRO_INTERFACE_COMPILE_STALL_SECONDS"
    ## How long, in seconds, the sink may stay the same size before the
    ## compile is declared wedged. A value `<= 0` turns stall detection off.
    ## Unset or unparsable: `DefaultCompileStallSeconds`. Setting BOTH
    ## variables to `<= 0` restores the unbounded wait.
  DefaultCompileCeilingSeconds* = 14_400
    ## 4 h: about eleven times the slowest legitimate compile measured (the
    ## windows-arm64 provider compile, ~1320 s), and still under a GitHub
    ## Actions job's 6 h limit, so the kill and its diagnostic happen inside
    ## the job rather than the runner being reaped without one.
  DefaultCompileStallSeconds* = 900
    ## 15 min of an unchanged sink. The longest gap between two output lines
    ## measured in a `nim c` on a windows-arm64 runner was 16 s (a link), and
    ## the frontend prints a dot per module, so a working compile is nowhere
    ## near it; a wedged one is caught in half the time the old fixed cap took.
  CompileWatchdogPollMilliseconds* = 5_000
    ## How often the waiting side samples the sink. Bounds how late a verdict
    ## can be, not how soon the wait ends when the process exits.

type
  CompileWatchdogPolicy* = object
    ## Limits for one compiler process. A field `<= 0` disables that limit.
    stallSeconds*: int
    ceilingSeconds*: int

  CompileWatchdogVerdict* = enum
    cwvKeepWaiting
      ## Still within both limits.
    cwvStalled
      ## The sink has not changed for `stallSeconds`: treat as wedged.
    cwvCeilingReached
      ## The process has run for `ceilingSeconds`, progressing or not.

  CompileWatchdog* = object
    ## The running state of one wait: when it started, and when and at what
    ## size the sink last changed.
    policy*: CompileWatchdogPolicy
    startedAt*: float
    lastProgressAt*: float
    lastSinkSize*: int64

proc parseLimitSeconds(raw: string; default: int): int =
  ## `raw` as an integer number of seconds, or `default` when it is empty or
  ## not an integer (the convention the ceiling variable always had).
  let text = raw.strip()
  if text.len == 0:
    return default
  try:
    parseInt(text)
  except ValueError:
    default

proc compileWatchdogPolicy*(ceilingRaw, stallRaw: string):
    CompileWatchdogPolicy =
  ## The policy the two environment values (`CompileCeilingEnv`,
  ## `CompileStallEnv`) describe, given as their raw text; empty means unset.
  CompileWatchdogPolicy(
    ceilingSeconds: parseLimitSeconds(ceilingRaw,
      DefaultCompileCeilingSeconds),
    stallSeconds: parseLimitSeconds(stallRaw, DefaultCompileStallSeconds))

proc isUnbounded*(policy: CompileWatchdogPolicy): bool =
  ## True when neither limit applies, so the caller may simply wait.
  policy.ceilingSeconds <= 0 and policy.stallSeconds <= 0

proc startCompileWatchdog*(policy: CompileWatchdogPolicy; now: float;
                           sinkSize: int64 = 0): CompileWatchdog =
  ## Begin watching a process spawned at `now` (seconds, any monotonic-enough
  ## clock) whose sink currently holds `sinkSize` bytes.
  CompileWatchdog(policy: policy, startedAt: now, lastProgressAt: now,
    lastSinkSize: sinkSize)

proc observe*(watchdog: var CompileWatchdog; now: float;
              sinkSize: int64): CompileWatchdogVerdict =
  ## Record a sample of the sink and decide. Any change of size counts as
  ## progress -- growth is the only change a writer makes, but a shrink is
  ## not evidence of a wedge either. A negative `sinkSize` means the size
  ## could not be read this time; it is not progress, and the previous size
  ## stays the reference for the next sample.
  if sinkSize >= 0 and sinkSize != watchdog.lastSinkSize:
    watchdog.lastSinkSize = sinkSize
    watchdog.lastProgressAt = now
  if watchdog.policy.ceilingSeconds > 0 and
      now - watchdog.startedAt >= float(watchdog.policy.ceilingSeconds):
    return cwvCeilingReached
  if watchdog.policy.stallSeconds > 0 and
      now - watchdog.lastProgressAt >= float(watchdog.policy.stallSeconds):
    return cwvStalled
  cwvKeepWaiting

proc verdictMessage*(watchdog: CompileWatchdog;
                     verdict: CompileWatchdogVerdict; now: float): string =
  ## The first line of the diagnostic for a killed compile: which limit
  ## fired, the values that tripped it, and the variable that changes it.
  let ran = int(now - watchdog.startedAt)
  case verdict
  of cwvStalled:
    "runCommand: STALLED -- no output for " &
      $int(now - watchdog.lastProgressAt) & "s (limit " &
      $watchdog.policy.stallSeconds & "s, " & CompileStallEnv &
      ") after " & $ran & "s, so the nim/gcc process tree was killed. " &
      "Partial sink output follows; with --listCmd the LAST command shown " &
      "is the one that wedged."
  of cwvCeilingReached:
    "runCommand: TIMED OUT after " & $ran & "s (ceiling " &
      $watchdog.policy.ceilingSeconds & "s, " & CompileCeilingEnv &
      "), so the nim/gcc process tree was killed. Partial sink output " &
      "follows; with --listCmd the LAST command shown is the one running."
  of cwvKeepWaiting:
    ""

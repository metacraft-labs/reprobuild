## Waiting on a `repro watch` transcript, for the e2e gates that drive a real
## watch session (`tests/e2e/hcr-watch/`).
##
## The gates start `repro watch` in a fresh project and wait for a line in its
## log before they act as the HCR agent. The first such line comes after the
## baseline cycle, and the baseline cycle is the expensive part: it extracts
## the interface of a project the action cache has never seen (the
## extraction's compile is keyed on the project's own path, so every fresh
## temporary project pays it) before it builds anything.
##
## How long that takes depends on the host, not on the code under test.
## Measured at reprobuild `28f1e43dcaf`, alone on the Linux workstation at
## load average ~200: the interface extraction took ~7.5 min and the build
## of the five actions ~1 min; `hcr waiting for agent socket=` appeared after
## 554 s. In full-suite runs 40-53 the three watch gates took 114-585 s, and
## runs 42, 47 and 53 lost one or all three to the 600 s that each gate's
## first wait used to allow; in run 53 the watch was alive and its build at
## 3/5 when the wait gave up.
##
## So the first wait gets `WatchBaselineBudgetMs`, sized against the suite
## runner's own deadlines rather than against a quiet host, and every wait
## stops as soon as the watch process has exited: a session that died is
## reported at once with its transcript, never after the budget runs out.

import std/[monotimes, os, osproc, strutils, times]

const WatchBaselineBudgetMs* = 1_500_000
  ## How long a gate waits for the baseline cycle of a fresh project: 25 min.
  ## Below the suite runner's no-progress deadline (`--test-timeout`, 1800 s)
  ## so the gate's own diagnostic, which carries the watch log, is what a
  ## real stall produces -- not a runner kill that carries nothing.

proc readLog(logPath: string): string =
  if fileExists(logPath): readFile(logPath) else: ""

proc waitForLogContains*(logPath, needle, context: string;
                         timeoutMs = 30_000; watch: Process = nil) =
  ## Return once `logPath` contains `needle`. Raises `ValueError` carrying
  ## the whole log when `timeoutMs` passes first, or -- when `watch` is given
  ## -- as soon as that process has exited without writing `needle`.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    if readLog(logPath).contains(needle):
      return
    if watch != nil and not watch.running():
      # Read once more: the line may have landed just before the exit.
      let log = readLog(logPath)
      if log.contains(needle):
        return
      raise newException(ValueError,
        "repro watch exited (code " & $watch.peekExitCode() &
        ") before " & context & ": " & needle & "\n" & log)
    sleep(50)
  raise newException(ValueError,
    "timed out after " & $(timeoutMs div 1000) & " s waiting for " &
    context & ": " & needle & "\n" & readLog(logPath))

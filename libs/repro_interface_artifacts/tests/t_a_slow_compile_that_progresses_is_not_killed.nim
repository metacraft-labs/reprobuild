## A compile that is still making progress is not killed; a silent one is.
##
## The Windows wait on a provider or interface `nim c` used to stop at a fixed
## 1800 s. On a windows-arm64 runner that compile normally takes ~1320 s, and
## a runner 1.4x slower had its compile killed while it was still printing
## gcc commands. The wait now decides by lack of progress (an unchanged sink)
## with a ceiling far above any legitimate compile; `compile_watchdog` has the
## rationale. These cases drive the decision with synthetic sink samples, so
## they run on every host, not only on Windows where the wait loop lives.
##
## No mocks: the unit under test is the pure decision procedure, fed exactly
## the (time, sink size) samples the Windows loop would read.

import std/[strutils, unittest]

import repro_interface_artifacts/compile_watchdog

const poll = float(CompileWatchdogPollMilliseconds) / 1000.0

proc runUntilVerdict(policy: CompileWatchdogPolicy; durationSeconds: float;
                     sizeAt: proc (t: float): int64):
    tuple[verdict: CompileWatchdogVerdict, at: float] =
  ## Sample a simulated compile every poll interval for `durationSeconds`
  ## (after which it "exits"), returning the first non-waiting verdict, or
  ## `cwvKeepWaiting` if the process exited first.
  var watchdog = startCompileWatchdog(policy, 0.0, sizeAt(0.0))
  var t = poll
  while t <= durationSeconds:
    let verdict = watchdog.observe(t, sizeAt(t))
    if verdict != cwvKeepWaiting:
      return (verdict, t)
    t += poll
  (cwvKeepWaiting, durationSeconds)

proc steadyWriter(bytesPerSecond: float): proc (t: float): int64 =
  ## A compile that writes continuously, like `nim c` printing a line per
  ## C file every few seconds.
  result = proc (t: float): int64 = int64(t * bytesPerSecond)

proc writesThenWedges(wedgeAt: float): proc (t: float): int64 =
  ## A compile that writes until `wedgeAt` and then never again.
  result = proc (t: float): int64 =
    int64(min(t, wedgeAt) * 50.0)

const defaults = compileWatchdogPolicy("", "")
const oldFixedCap = CompileWatchdogPolicy(ceilingSeconds: 1800, stallSeconds: 0)
  ## The policy before this change: a fixed 1800 s total, nothing else.

suite "compile watchdog":
  test "the old fixed cap killed a compile that was still progressing":
    # The control: the observed failure, reproduced against the old policy.
    # A 1.4x-slower windows-arm64 runner needs ~1850 s for the provider.
    let r = runUntilVerdict(oldFixedCap, 1850.0, steadyWriter(40.0))
    check r.verdict == cwvCeilingReached

  test "the default policy lets the same progressing compile finish":
    let r = runUntilVerdict(defaults, 1850.0, steadyWriter(40.0))
    check r.verdict == cwvKeepWaiting

  test "a much slower host that keeps writing still finishes":
    # Three times the slowest measured compile.
    let r = runUntilVerdict(defaults, 3 * 1320.0, steadyWriter(5.0))
    check r.verdict == cwvKeepWaiting

  test "output gaps shorter than the stall window are not a wedge":
    # Bursts every 600 s: a long single C file or link on a slow host.
    let bursty = proc (t: float): int64 = int64(t / 600.0) * 100
    let r = runUntilVerdict(defaults, 3000.0, bursty)
    check r.verdict == cwvKeepWaiting

  test "a compile that goes silent is killed once the stall window passes":
    let r = runUntilVerdict(defaults, 20_000.0, writesThenWedges(300.0))
    check r.verdict == cwvStalled
    check r.at >= 300.0 + float(DefaultCompileStallSeconds)
    check r.at < 300.0 + float(DefaultCompileStallSeconds) + 2 * poll
    # ...and well before the old fixed cap would have fired.
    check r.at < 1800.0

  test "a compile silent from the start is killed after the stall window":
    let silent = proc (t: float): int64 = 0
    let r = runUntilVerdict(defaults, 20_000.0, silent)
    check r.verdict == cwvStalled
    check r.at < float(DefaultCompileStallSeconds) + 2 * poll

  test "a process that never stops writing still meets the ceiling":
    let r = runUntilVerdict(defaults, 20_000.0, steadyWriter(10.0))
    check r.verdict == cwvCeilingReached
    check r.at >= float(DefaultCompileCeilingSeconds)

  test "an unreadable size is not progress":
    var w = startCompileWatchdog(
      CompileWatchdogPolicy(ceilingSeconds: 0, stallSeconds: 60), 0.0, 10)
    check w.observe(30.0, -1) == cwvKeepWaiting
    check w.observe(61.0, -1) == cwvStalled
    var w2 = startCompileWatchdog(
      CompileWatchdogPolicy(ceilingSeconds: 0, stallSeconds: 60), 0.0, 10)
    check w2.observe(30.0, -1) == cwvKeepWaiting
    check w2.observe(50.0, 11) == cwvKeepWaiting
    check w2.observe(100.0, 11) == cwvKeepWaiting
    check w2.observe(111.0, 11) == cwvStalled

  test "the stall diagnostic names the limit and its variable":
    var w = startCompileWatchdog(defaults, 0.0, 0)
    let at = float(DefaultCompileStallSeconds) + 1.0
    let v = w.observe(at, 0)
    check v == cwvStalled
    let msg = w.verdictMessage(v, at)
    check "STALLED" in msg
    check CompileStallEnv in msg
    check $DefaultCompileStallSeconds in msg

suite "compile watchdog policy from the environment":
  test "unset values give the defaults":
    check defaults.ceilingSeconds == DefaultCompileCeilingSeconds
    check defaults.stallSeconds == DefaultCompileStallSeconds
    check not defaults.isUnbounded

  test "an explicit ceiling is honoured and stall detection stays on":
    let p = compileWatchdogPolicy(" 2400 ", "")
    check p.ceilingSeconds == 2400
    check p.stallSeconds == DefaultCompileStallSeconds

  test "a value <= 0 disables that limit; both <= 0 is the unbounded wait":
    let noCeiling = compileWatchdogPolicy("0", "")
    check noCeiling.ceilingSeconds == 0
    check not noCeiling.isUnbounded
    check compileWatchdogPolicy("0", "-1").isUnbounded
    let r = runUntilVerdict(compileWatchdogPolicy("0", "0"), 50_000.0,
      proc (t: float): int64 = 0)
    check r.verdict == cwvKeepWaiting

  test "an unparsable value falls back to the default":
    let p = compileWatchdogPolicy("soon", "later")
    check p.ceilingSeconds == DefaultCompileCeilingSeconds
    check p.stallSeconds == DefaultCompileStallSeconds

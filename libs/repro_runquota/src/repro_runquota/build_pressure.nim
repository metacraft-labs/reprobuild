## Build-wait pressure of one build invocation: how much of its wall time
## its commands spent held up, in the manner of Linux PSI
## (<https://docs.kernel.org/accounting/psi.html>), with commands in place
## of tasks.
##
## WHAT IS COUNTED. A command (an action the engine runs under a RunQuota
## lease) is READY from the moment it is offered to RunQuota until its
## grant, and RUNNING from the grant until it is reaped. At each instant:
##
## * a ready command is held up at level 1 (it waits for its lease);
## * a running command is held up at level h = max(0, 1 - expected/actual),
##   its slowdown against the expected uncontended duration spread evenly
##   over its run (30 s against an expected 20 s is h = 1/3: 10 s held
##   up), and at level 0 while that is not known -- before its finish, or
##   when the daemon knows no expected duration.
##
## *some* at an instant is the largest level among the ready-or-running
## commands, *full* the smallest; an instant with no ready-or-running
## command counts in neither (the build was idle, not held up). With levels
## of 0 and 1 only, this is exactly PSI's "at least one" and "all". The
## counters are the integrals of the two over the invocation's wall time.
##
## LIVE AND SETTLED. A running command's level is known only at its finish
## and only ever rises from the provisional 0, so the counters taken at any
## moment are a lower bound later readings only add to. The time before the
## earliest grant of a command still running is SETTLED (every command that
## overlaps it has a known level) and is integrated once; the time after it
## is recomputed at each reading. Commands wholly in the settled past are
## forgotten, so memory is bounded by the commands overlapping the oldest
## running one.
##
## PURE. Every entry point takes the time (monotonic microseconds) from its
## caller, so a test can state a schedule exactly; the engine passes its
## own clock. Nothing here sends anything: `takeReport` hands the caller
## the report to send.

import std/[algorithm, tables]

import runquota_protocol

const
  ReportIntervalMicros* = 1_000_000'i64
    ## At most one report a second from the scheduler loop.
  MinReportedWaitMicros* = 1_000_000'i64
    ## Waits shorter than a second are in the counters but not reported
    ## one by one.

type
  TrackedCommand = object
    readyAt: int64
    grantedAt: int64
      ## `high(int64)` while ready.
    endAt: int64
      ## `high(int64)` while ready or running.
    level: float64
      ## The running level once known (at the finish).

  BuildPressure* = object
    enabled*: bool
    startedAt*: int64
    unixOffsetMillis*: int64
      ## Unix ms minus monotonic ms, for the waits' start times.
    commands: Table[string, TrackedCommand]
    settledAt: int64
    settledSome, settledFull: float64
      ## Microseconds held up in [startedAt, settledAt).
    reportedAt: int64
    reportedSome, reportedFull: uint64
    waits: seq[PressureWait]
    queueOnly: bool
    dirty: bool

proc initBuildPressure*(enabled: bool; nowMicros: int64;
                        unixNowMillis: int64): BuildPressure =
  ## A tracker for an invocation starting at `nowMicros`. `enabled` is the
  ## `pressure-reports` switch; a disabled tracker does nothing at all.
  result.enabled = enabled
  result.startedAt = nowMicros
  result.settledAt = nowMicros
  result.reportedAt = nowMicros
  result.unixOffsetMillis = unixNowMillis - nowMicros div 1000

proc unixMillisAt(p: BuildPressure; micros: int64): uint64 =
  uint64(max(0'i64, p.unixOffsetMillis + micros div 1000))

proc noteReady*(p: var BuildPressure; id: string; nowMicros: int64) =
  ## `id` was offered to RunQuota.
  if not p.enabled: return
  p.commands[id] = TrackedCommand(readyAt: nowMicros, grantedAt: high(int64),
    endAt: high(int64))
  p.dirty = true

proc noteGranted*(p: var BuildPressure; id: string; nowMicros: int64) =
  ## `id`'s lease was granted (at once, or after queueing).
  if not p.enabled or not p.commands.hasKey(id): return
  var c = addr p.commands[id]
  if c.grantedAt != high(int64): return
  c.grantedAt = max(nowMicros, c.readyAt)
  let waited = c.grantedAt - c.readyAt
  if waited >= MinReportedWaitMicros:
    p.waits.add(PressureWait(startedAtUnixMillis: p.unixMillisAt(c.readyAt),
      lengthMillis: uint64(waited div 1000), kind: pwkQueue))
  p.dirty = true

proc noteFinished*(p: var BuildPressure; id: string; nowMicros: int64;
                   durationMillis, expectedMillis: uint64) =
  ## `id` finished after running `durationMillis` (the launcher's figure);
  ## `expectedMillis` is the daemon's expected uncontended duration at its
  ## width, 0 when unknown.
  if not p.enabled or not p.commands.hasKey(id): return
  var c = addr p.commands[id]
  if c.endAt != high(int64): return
  if c.grantedAt == high(int64):
    c.grantedAt = max(nowMicros, c.readyAt)
  c.endAt = max(nowMicros, c.grantedAt)
  if expectedMillis == 0'u64:
    p.queueOnly = true
  elif durationMillis > expectedMillis:
    c.level = 1.0 - float64(expectedMillis) / float64(durationMillis)
    let slowMicros = int64(durationMillis - expectedMillis) * 1000
    if slowMicros >= MinReportedWaitMicros:
      p.waits.add(PressureWait(startedAtUnixMillis: p.unixMillisAt(c.grantedAt),
        lengthMillis: durationMillis - expectedMillis, kind: pwkSlowdown))
  p.dirty = true

proc noteWithdrawn*(p: var BuildPressure; id: string; nowMicros: int64) =
  ## `id` left without finishing a run: its request was withdrawn or
  ## failed while queued, or it was cancelled while running.
  if not p.enabled or not p.commands.hasKey(id): return
  var c = addr p.commands[id]
  if c.endAt != high(int64): return
  if c.grantedAt == high(int64):
    let waited = nowMicros - c.readyAt
    if waited >= MinReportedWaitMicros:
      p.waits.add(PressureWait(startedAtUnixMillis: p.unixMillisAt(c.readyAt),
        lengthMillis: uint64(waited div 1000), kind: pwkQueue))
    c.grantedAt = max(nowMicros, c.readyAt)
  c.endAt = max(nowMicros, c.grantedAt)
  p.dirty = true

proc levelAt(c: TrackedCommand; t: int64; active: var bool): float64 =
  ## The command's level at instant `t` (in its elementary interval).
  active = false
  if t < c.readyAt or t >= c.endAt:
    return 0.0
  active = true
  if t < c.grantedAt: 1.0 else: c.level

proc integrate(p: BuildPressure; a, b: int64): tuple[some, full: float64] =
  ## The integrals of *some* and *full* over [a, b), from the commands'
  ## current levels.
  if b <= a: return
  var cuts = @[a, b]
  for c in p.commands.values:
    for t in [c.readyAt, c.grantedAt, c.endAt]:
      if t > a and t < b:
        cuts.add(t)
  cuts.sort()
  for i in 0 ..< cuts.len - 1:
    let t0 = cuts[i]
    let t1 = cuts[i + 1]
    if t1 <= t0: continue
    var anyActive = false
    var hi = 0.0
    var lo = 1.0
    for c in p.commands.values:
      var active: bool
      let level = c.levelAt(t0, active)
      if active:
        anyActive = true
        hi = max(hi, level)
        lo = min(lo, level)
    if anyActive:
      let span = float64(t1 - t0)
      result.some += hi * span
      result.full += lo * span

proc settle(p: var BuildPressure; nowMicros: int64) =
  ## Integrate up to the earliest grant of a command still running (or
  ## now) and forget the commands wholly before it.
  var horizon = nowMicros
  for c in p.commands.values:
    if c.grantedAt != high(int64) and c.endAt == high(int64):
      horizon = min(horizon, c.grantedAt)
  if horizon <= p.settledAt: return
  let (some, full) = p.integrate(p.settledAt, horizon)
  p.settledSome += some
  p.settledFull += full
  p.settledAt = horizon
  var gone: seq[string]
  for id, c in p.commands.pairs:
    if c.endAt <= horizon:
      gone.add(id)
  for id in gone:
    p.commands.del(id)

proc counters*(p: var BuildPressure; nowMicros: int64):
    tuple[some, full: uint64] =
  ## The invocation's cumulative held-up microseconds up to `nowMicros`:
  ## a lower bound that later readings only raise.
  if not p.enabled: return
  p.settle(nowMicros)
  let (some, full) = p.integrate(p.settledAt, nowMicros)
  result.some = uint64(max(0.0, p.settledSome + some))
  result.full = uint64(max(0.0, p.settledFull + full))

proc activeCommands*(p: BuildPressure): int =
  for c in p.commands.values:
    if c.endAt == high(int64): inc result

proc reportDue*(p: BuildPressure; nowMicros: int64): bool =
  ## Whether the scheduler loop should report now: a second since the
  ## previous report, and something changed or is still ready or running.
  p.enabled and nowMicros - p.reportedAt >= ReportIntervalMicros and
    (p.dirty or p.activeCommands > 0 or p.waits.len > 0)

proc takeReport*(p: var BuildPressure; nowMicros: int64):
    PressureReportMessage =
  ## What the counters grew by since the previous report, the wall time
  ## that covers, and the waits gathered since (at most
  ## `MaxPressureWaitsPerReport`; the rest wait for the next report). The
  ## session id is the caller's to fill.
  let (some, full) = p.counters(nowMicros)
  let wall = max(0'i64, nowMicros - p.reportedAt)
  result.wallMicros = uint64(wall)
  # Monotonic by construction, but never let a rounding step go negative.
  result.someMicros = (if some > p.reportedSome: some - p.reportedSome else: 0'u64)
  result.fullMicros = (if full > p.reportedFull: full - p.reportedFull else: 0'u64)
  result.someMicros = min(result.someMicros, result.wallMicros)
  result.fullMicros = min(result.fullMicros, result.someMicros)
  result.queueOnly = p.queueOnly
  let count = min(p.waits.len, MaxPressureWaitsPerReport)
  result.waits = p.waits[0 ..< count]
  p.waits = p.waits[count .. ^1]
  # What a report could not carry (held-up time a finish revealed for a
  # stretch longer than this report's wall time, which the daemon would
  # clamp) is carried to the next report rather than lost.
  p.reportedSome += result.someMicros
  p.reportedFull += result.fullMicros
  p.reportedAt = nowMicros
  p.queueOnly = false
  p.dirty = false

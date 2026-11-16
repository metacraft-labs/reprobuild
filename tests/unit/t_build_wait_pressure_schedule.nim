## Build-wait pressure as Reprobuild computes it, over scripted schedules
## (`repro_runquota/build_pressure`).
##
## WHY AN INJECTED CLOCK. The figures are integrals over time of which
## commands were ready or running, and the checks compare them with values
## worked out by hand from the schedule. Driving that with real processes
## would put the host's scheduling noise into both the schedule and the
## result; and the 310 s wait would take five minutes. The tracker takes
## every time from its caller (the engine passes its monotonic clock), so
## the test states the schedule exactly. The real engine, a real daemon and
## real queued actions are exercised in
## `tests/integration/t_build_wait_pressure_reported`.
##
## WHAT IS GUARDED, and the mutation each check fails under:
##
## * A schedule with queue waits, slowdowns, a command with no expected
##   duration and two idle stretches yields *some* = 16.5 s and *full* =
##   7.5 s over 30 s, within 2%. Mutation: count idle time (no ready or
##   running command) as held up -- `integrate` adding the span at level 1
##   when no command is active -- and *some* is 25.5 s.
## * Reports taken during the schedule are lower bounds that only grow, and
##   their deltas add up to the final counters. Mutation: report the
##   counters instead of what they grew by, and the sum is too large.
## * The waits are reported with their kind and length: three queue waits
##   and two slowdowns of a second or more, none shorter.
## * A request held 310 s is reported as one queue wait of 310 000 ms, which
##   the daemon counts as long (that half is tested in runquota's
##   `t_pressure_metrics`). Mutation: report the wait's length from the
##   grant to the next report instead of from ready to grant.
##
## NO MOCKS: values in, values out.

import std/unittest

import runquota_protocol
import repro_runquota/build_pressure

const S = 1_000_000'i64
  ## One second in the tracker's microseconds.

proc within(actual, expected: float64; fraction = 0.02): bool =
  abs(actual - expected) <= fraction * expected

proc schedule(p: var BuildPressure; upTo: int64; after = -1'i64) =
  ## The schedule of the header: its events after `after` and at or before
  ## `upTo` seconds.
  ## (A: 0-10 s, 5 s expected; B: queued 0-4, runs to 8 as expected; C:
  ## queued 2-12, runs to 15, no expected duration; idle 15-20; D: 20-26,
  ## 3 s expected; E: queued 22-25, runs to 26 as expected; idle 26-30.)
  type Event = tuple[at: int64, kind: string, id: string, dur, exp: uint64]
  let events: seq[Event] = @[
    (0'i64, "ready", "A", 0'u64, 0'u64), (0'i64, "grant", "A", 0'u64, 0'u64),
    (0'i64, "ready", "B", 0'u64, 0'u64),
    (2'i64, "ready", "C", 0'u64, 0'u64),
    (4'i64, "grant", "B", 0'u64, 0'u64),
    (8'i64, "finish", "B", 4000'u64, 4000'u64),
    (10'i64, "finish", "A", 10000'u64, 5000'u64),
    (12'i64, "grant", "C", 0'u64, 0'u64),
    (15'i64, "finish", "C", 3000'u64, 0'u64),
    (20'i64, "ready", "D", 0'u64, 0'u64), (20'i64, "grant", "D", 0'u64, 0'u64),
    (22'i64, "ready", "E", 0'u64, 0'u64),
    (25'i64, "grant", "E", 0'u64, 0'u64),
    (26'i64, "finish", "D", 6000'u64, 3000'u64),
    (26'i64, "finish", "E", 1000'u64, 1000'u64)]
  for e in events:
    if e.at > upTo or e.at <= after: continue
    let t = e.at * S
    case e.kind
    of "ready": p.noteReady(e.id, t)
    of "grant": p.noteGranted(e.id, t)
    of "finish": p.noteFinished(e.id, t, e.dur, e.exp)

suite "some and full over a scripted schedule":
  test "they match the schedule's computed values within 2%":
    var p = initBuildPressure(true, 0, 1_700_000_000_000)
    p.schedule(30)
    let (some, full) = p.counters(30 * S)
    checkpoint "some=" & $some & " full=" & $full
    check within(float64(some), 16.5 * float64(S))
    check within(float64(full), 7.5 * float64(S))

  test "reports are lower bounds that add up to the final counters":
    var p = initBuildPressure(true, 0, 1_700_000_000_000)
    var sumSome, sumFull, sumWall: uint64
    var previous = 0'u64
    var waits: seq[PressureWait]
    p.schedule(0)
    for second in 1 .. 30:
      p.schedule(int64(second), int64(second - 1))
      let (some, _) = p.counters(int64(second) * S)
      check some >= previous
      previous = some
      if second mod 3 == 0:
        let report = p.takeReport(int64(second) * S)
        sumSome += report.someMicros
        sumFull += report.fullMicros
        sumWall += report.wallMicros
        waits.add(report.waits)
    check sumWall == uint64(30 * S)
    check within(float64(sumSome), 16.5 * float64(S))
    check within(float64(sumFull), 7.5 * float64(S))
    var queue, slow: seq[uint64]
    for w in waits:
      if w.kind == pwkQueue: queue.add(w.lengthMillis)
      elif w.kind == pwkSlowdown: slow.add(w.lengthMillis)
    check queue == @[4000'u64, 10000'u64, 3000'u64]
    check slow == @[5000'u64, 3000'u64]

  test "a finish with no expected duration marks the report queue-only":
    var p = initBuildPressure(true, 0, 0)
    p.schedule(15)
    let report = p.takeReport(15 * S)
    check report.queueOnly
    let next = p.takeReport(16 * S)
    check not next.queueOnly

  test "an idle invocation is held up for none of its time":
    var p = initBuildPressure(true, 0, 0)
    let (some, full) = p.counters(60 * S)
    check some == 0 and full == 0

  test "a disabled tracker records and reports nothing":
    var p = initBuildPressure(false, 0, 0)
    p.schedule(30)
    check p.counters(30 * S) == (0'u64, 0'u64)
    check not p.reportDue(30 * S)

suite "long waits":
  test "a request held 310 s is reported as one 310 s queue wait":
    var p = initBuildPressure(true, 0, 1_700_000_000_000)
    p.noteReady("held", 5 * S)
    p.noteGranted("held", 315 * S)
    p.noteFinished("held", 316 * S, 1000, 0)
    let report = p.takeReport(320 * S)
    check report.waits.len == 1
    check report.waits[0].kind == pwkQueue
    check report.waits[0].lengthMillis == 310_000'u64
    check report.waits[0].startedAtUnixMillis == 1_700_000_005_000'u64
    # Held up for the whole wait, and in neither before nor after it.
    check report.someMicros == uint64(310 * S)
    check report.fullMicros == uint64(310 * S)

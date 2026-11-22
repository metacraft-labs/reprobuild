## ``contain`` lets a running tick finish before it records (ReproOS Add-On
## Mode spec §13 decision 51; A11 round 23b).
##
## The off-host check reads a tick heartbeat that reaches the sink after the
## containment record as DET-AO-8 ``ticked-while-contained``: the
## containment did not hold. So no heartbeat of the agent's own may follow
## the record. ``contain`` therefore first makes the agent's units
## unstartable (the marker and the runtime drop-ins; nothing stops), then
## waits until a tick already running has exited, and only then records
## and ships, before it stops anything. A ``contain`` that stopped before
## its record leaves a marker naming none, and running it again finishes
## the containment instead of reporting it done.
##
## Falsifying builds: ``contain-records-before-quiesce`` (the record is made
## while the tick still runs, so the heartbeat follows it),
## ``contain-resume-reports-already`` (a marker naming no record reads as a
## containment made, so the interrupted contain is never finished: the
## resume case goes red) and ``contain-busy-unknown-is-idle`` (a tick unit
## whose state systemctl cannot report reads as idle).
##
## Mocks: ``ContainOps`` stands in for systemctl and for the sink, because a
## unit test has no PID 1 whose units it could block, observe or stop, and no
## sink; it records each effect in order and plays a tick that writes its
## heartbeat when it exits. The drill gate (``e2e_addon_drill_fetch_compromise``)
## runs the real units and sink, and its step "the check alerts exactly the
## refusals the drill caused" goes red on a ``ticked-while-contained``
## alert. The state directory and the marker are real files.

import std/[os, strutils, unittest]

import repro_addon/containment

let root = getTempDir() / ("addon-contain-quiesce-" & $getCurrentProcessId())
removeDir(root)
createDir(root)

proc newState(name: string): string =
  result = root / name
  createDir(result)
  writeFile(result / "addon-ledger", "")

type Bed = ref object
  log: seq[string]          ## the effects, in order
  tickPolls: int            ## the tick runs for this many busy polls
  blocked: bool

proc ops(b: Bed): ContainOps =
  ContainOps(
    blockStarts: proc(markerPath: string): seq[string] =
      b.blocked = fileExists(markerPath)
      b.log.add("block"),
    busyUnits: proc(): seq[string] =
      if b.tickPolls > 0:
        dec b.tickPolls
        if b.tickPolls == 0:
          # The tick exits: its heartbeat is the last thing it writes.
          b.log.add("heartbeat")
        else:
          return @["repro-agent-apply.service"]
      @[],
    sleepMs: proc(ms: int) = discard,
    record: proc(): string =
      b.log.add("record")
      "/var/lib/repro/system/addon/evidence/x-contained.json",
    ship: proc(): tuple[shipped: bool; error: string] =
      b.log.add("ship")
      (true, ""),
    stop: proc(): seq[string] =
      b.log.add("stop"))

suite "contain lets a running tick finish before it records":
  test "a tick running at contain writes its heartbeat before the record":
    let st = newState("running")
    let b = Bed(tickPolls: 3)
    let r = runContainWith(ops(b), "drill", "compromised compiler", st)
    check b.log == @["block", "heartbeat", "record", "ship", "stop"]
    check b.blocked           # the marker existed when the starts were blocked
    check r.busyAtRecord.len == 0
    check r.shipped
    check containmentRecorded(st)

  test "an idle agent: blocked, recorded, shipped, then stopped":
    let st = newState("idle")
    let b = Bed(tickPolls: 0)
    discard runContainWith(ops(b), "drill", "reason", st)
    check b.log == @["block", "record", "ship", "stop"]

  test "a tick that outlives the wait is named, and stopped after the record":
    let st = newState("hung")
    let b = Bed(tickPolls: 1_000_000)
    let r = runContainWith(ops(b), "drill", "reason", st, quiesceMs = 1000)
    check r.busyAtRecord == @["repro-agent-apply.service"]
    check b.log == @["block", "record", "ship", "stop"]

  test "a contain that stopped before its record is finished by the next":
    let st = newState("resumed")
    createDir(st / "addon")
    # Step 1 of a run that went no further: a marker naming no record.
    writeFile(containedMarkerPath(st), "operator=drill\nreason=r\nat=x\n")
    check isContained(st)
    check not containmentRecorded(st)
    let b = Bed(tickPolls: 0)
    let r = runContainWith(ops(b), "drill", "reason", st)
    check not r.already
    check "record" in b.log
    check containmentRecorded(st)
    check "record=" & r.record in readFile(containedMarkerPath(st))

  test "a recorded containment is not made again":
    let st = newState("done")
    let b = Bed(tickPolls: 0)
    discard runContainWith(ops(b), "drill", "reason", st)
    let b2 = Bed(tickPolls: 0)
    let r = runContainWith(ops(b2), "drill", "again", st)
    check r.already
    check b2.log.len == 0

suite "contain's wait counts a unit it cannot read as running":
  test "an unreadable unit is waited for, an inactive or absent one is not":
    let states = {"fetch": (true, "inactive"), "apply": (false, ""),
                  "gone": (true, ""), "tick": (true, "activating")}
    proc ask(u: string): tuple[ok: bool; state: string] =
      for (n, v) in states:
        if n == u: return v
      (false, "")
    check busyAgentUnitsWith(["fetch", "apply", "gone", "tick"], ask) ==
      @["apply", "tick"]

  test "a contain whose systemctl never answers names the units it waited for":
    let st = newState("unanswered")
    let b = Bed(tickPolls: 0)
    var o = ops(b)
    o.busyUnits = proc(): seq[string] =
      busyAgentUnitsWith(["repro-agent-fetch.service"],
        proc(u: string): tuple[ok: bool; state: string] = (false, ""))
    let r = runContainWith(o, "drill", "reason", st, quiesceMs = 1000)
    check r.busyAtRecord == @["repro-agent-fetch.service"]

removeDir(root)

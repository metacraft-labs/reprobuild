## NPC-M10 verification `test_npc_m10_detector_silence_alerts` (threat
## model G30; DET-4, DET-5).
##
## The catalog's detectors -- the store scrub, the independent
## regeneration and the egress-denial reporter -- each heartbeat to the
## evidence sink only after their own positive control passed (the scrub's
## planted object found, the regeneration completed, the metadata address
## refused by the egress policy). All three run and report: each is
## `live-idle` (alive, nothing detected). Then each is stopped in turn, and
## once three of its intervals have passed the sink's liveness report has
## it `silent` while the others stay `live-idle`: silence is reported, and
## is distinct from "nothing detected". The canary detector, which this
## build does not run, is `never-reported` when the operator expects it. A
## scrub whose control is not found reports `control-missed` and sends no
## heartbeat.
##
## The detectors' runs are driven here one after another; running them on
## a schedule is the deployment's (its timers).
##
## Falsifying mutation (recorded in the plan): removing the heartbeat check
## leaves the stopped scrub unreported, and fails the test.

import std/[os, tempfiles, unittest]

import repro_domain_types/nimble_index
import repro_nimble_generator

import ./fetch_fixtures
import ./npc_sink_fixtures

const IntervalMs = 400

proc statusOf(s: NpcSink; detector: string;
              expected: seq[ExpectedDetector] = @[]): LivenessStatus =
  result = lsNeverReported
  var found = false
  for row in livenessReport(s.sink.dir, nowMs(), 3, expected):
    if row.detector == detector:
      result = row.status
      found = true
  if not found: result = lsNeverReported

suite "NPC-M10: a stopped detector is reported silent":

  test "each stopped detector goes silent; running ones stay live-idle":
    let f = newFixture("m10-silence")
    let work = createTempDir("npc-m10-silence-", "")
    let store = parseMirror(work / "store")
    let s0 = f.package("owner/alpha.git", @[nimbleFile("alpha"),
      file("src/alpha.nim", "discard\n")])
    store.putSource(s0)
    let control = work / "control"
    plantScrubControl(control)
    let log = work / "captures.log"
    appendCaptures(log, [CaptureRecord(class: ccEgressRefusal,
      package: "alpha", observed: "address", source: "https://10.0.0.1/x",
      detail: "private address", at: 1)])
    var offset = 0'i64

    var s = startNpcSink("npc-m10-silence-sink")
    defer: s.stop()
    let app = s.appender()
    for d in [ScrubDetector, RegenerationDetector, EgressDenialDetector]:
      app.registerDetector(d, IntervalMs, probed = true)
    let agrees = RegenerationCheck(verdict: rvAgrees)
    var round = 0
    proc runAll(scrub, regen, egress: bool) =
      inc round
      if scrub:
        discard runScrubDetector(store, control, work / ("scratch-" & $round),
          app)
      if regen: reportRegeneration(agrees, app)
      if egress:
        discard runEgressDenialReporter(log, offset, defaultPolicy(), app)
      check app.drain()

    # All three running: alive, and the scrub and regeneration detected
    # nothing (the egress reporter forwarded one refusal).
    runAll(true, true, true)
    check s.statusOf(ScrubDetector) == lsLiveIdle
    check s.statusOf(RegenerationDetector) == lsLiveIdle
    check s.statusOf(EgressDenialDetector) == lsLiveDetecting
    let expectCanary = @[(s.writer.identity.hostId, CanaryDetector)]
    check s.statusOf(CanaryDetector, expectCanary) == lsNeverReported

    # The scrub stops.
    sleep(4 * IntervalMs)
    runAll(false, true, true)
    check s.statusOf(ScrubDetector) == lsSilent
    check s.statusOf(RegenerationDetector) == lsLiveIdle
    check s.statusOf(EgressDenialDetector) == lsLiveDetecting

    # The regeneration stops.
    sleep(4 * IntervalMs)
    runAll(false, false, true)
    check s.statusOf(RegenerationDetector) == lsSilent
    check s.statusOf(EgressDenialDetector) == lsLiveDetecting

    # The egress-denial reporter stops.
    sleep(4 * IntervalMs)
    check s.statusOf(EgressDenialDetector) == lsSilent

    # A scrub whose control is not found does not heartbeat.
    let empty = work / "empty-control"
    createDir(empty)
    discard runScrubDetector(store, empty, work / "scratch-x", app)
    check app.drain()
    check s.sink.detections("control-missed").len == 1
    check s.statusOf(ScrubDetector) == lsSilent
    app.close()

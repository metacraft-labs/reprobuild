## The add-on's evidence leaves the host (spec §10.4; DET-5, DET-6,
## EVID-2; threat model G22): a record is written locally and to the
## outbox, the shipping run appends the outbox to the Evidence sink in
## order and deletes an entry only once the sink acknowledged it; while the
## sink is unreachable every entry stays queued and the run does not fail;
## the run heartbeats with the boot id and dpkg's last run; the apt hook
## wrapper's own events become records; a host bootstrapped without a sink
## writes local records only and never an outbox entry.
##
## Falsifying build: ``ship-deletes-before-ack`` -- entries are deleted as
## soon as they are handed to the appender, so a run against an
## unreachable sink loses them; the "stays queued" step goes red.
##
## Mocks: none (see ``addon_evidence_fixture``).

import std/[os, strutils, unittest]

import repro_peer_cache/evidence
import repro_peer_cache/types

import repro_addon/evidence as addonEvidence
import repro_addon/evidence_ship

import ./addon_evidence_fixture

let root = getTempDir() / ("addon-evidence-ship-" & $getCurrentProcessId())
removeDir(root)
createDir(root)

proc records(sink: SinkFixture; detector: string): seq[EvidenceEntry] =
  for e in sink.entries():
    if e.kind == ekRecord and e.record.detector == detector: result.add(e)

suite "evidence ships off-host":
  let sink = startSink(root)
  var h = newHost(root, "host-a", sink, endpoint = "127.0.0.1:" & $closedPort())
  sink.enrol(h)

  test "a record lands locally and in the outbox":
    let p = recordEvidence(EvidenceEvent(detector: edApplyRefusal,
      category: ecDetection, trigger: "apply-refused",
      fields: @[("message", "first")]), h.evidence)
    check fileExists(p)
    check "\"detector\": \"addon-apply-refusal\"" in readFile(p)
    discard recordEvidence(EvidenceEvent(detector: edRollback,
      category: ecDetection, trigger: "rolled-back",
      fields: @[("message", "second")]), h.evidence)
    check outboxEntries(h.site.outbox).len == 2

  test "an unreachable sink leaves every entry queued, and the run does not fail":
    let r = runEvidenceShip(h.site, h.conf, "host-a")
    check r.shipped == 0
    check r.pending == 2
    check r.error.len > 0
    check outboxEntries(h.site.outbox).len == 2

  test "a reachable sink takes them in order, then the heartbeat; the outbox empties":
    h.pointAt(sink.endpoint)
    writeFile(h.site.dpkgLog,
      "2026-11-04 10:00:00 startup archives unpack\n" &
      "2026-11-04 10:00:01 install foo:amd64 <none> 1.0\n" &
      "2026-11-04 10:05:00 startup packages configure\n")
    let r = runEvidenceShip(h.site, h.conf, "host-a")
    check r.error == ""
    check r.shipped == 2
    check r.heartbeat
    check outboxEntries(h.site.outbox).len == 0
    var order: seq[string]
    for e in sink.entries():
      if e.kind == ekRecord:
        check $e.senderHostId == h.credentialHost
        order.add(e.record.trigger & e.record.field("message"))
    check order[0 .. 1] == @["apply-refusedfirst", "rolled-backsecond"]
    let beats = sink.records("addon-evidence-ship")
    check beats.len == 1
    check beats[0].record.category == ecHeartbeat
    check beats[0].record.field("intervalMs") == "300000"
    check beats[0].record.field("bootId") == "boot-host-a"
    check beats[0].record.field("dpkgLastRun") == "2026-11-04 10:05:00"

  test "nothing queued and a recent heartbeat: the run sends nothing":
    let before = sink.entries().len
    let r = runEvidenceShip(h.site, h.conf, "host-a")
    check r.shipped == 0 and not r.heartbeat
    check sink.entries().len == before

  test "the apt hook wrapper's events become DET-AO-6 records":
    writeFile(h.site.aptHookLog,
      "2026-11-04T10:06:00Z verify-timeout exit=137 timeout=60s\n" &
      "2026-11-04T10:07:00Z drift 1 finding(s)\n")
    let r = runEvidenceShip(h.site, h.conf, "host-a", forceHeartbeat = true)
    check r.hookEvents == 1
    var timeouts = 0
    for e in sink.records("addon-apt-hook"):
      if e.record.trigger == "verify-timeout" and
          e.record.category == ecDetection: inc timeouts
    check timeouts == 1
    # The cursor moved on: the same line is not reported twice.
    check runEvidenceShip(h.site, h.conf, "host-a").hookEvents == 0

  test "a host without a sink writes local records only":
    var local = h.evidence
    local.confPath = root / "no-such-evidence.conf"
    local.outbox = root / "no-outbox"
    discard recordEvidence(EvidenceEvent(detector: edApplyRefusal,
      category: ecDetection, trigger: "apply-refused"), local)
    check not dirExists(local.outbox)
    # A heartbeat goes off-host only: on such a host it is written nowhere.
    check recordEvidence(EvidenceEvent(detector: edAgentTick,
      category: ecHeartbeat, offHostOnly: true), local) == ""

  sink.server.stop()

removeDir(root)

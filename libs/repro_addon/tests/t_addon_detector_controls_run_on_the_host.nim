## DET-4 on a deployed host: the positive controls of DET-AO-1 and DET-AO-6
## run every time their detector runs, and the off-host check alerts when a
## detector heartbeats while no control of it tripped (spec §10.4
## "Scheduled positive controls"; threat model §9 "Scheduled controls";
## reprobuild-pm issue
## ``2026-11-12-detector-positive-controls-run-once-not-on-a-schedule-as-det-4-requires.md``).
## DET-AO-3's control, which needs a real table and a real cgroup, is
## ``t_addon_egress_control_proves_the_observer``.
##
## * DET-AO-1: ``manifestControl`` hands the agent's own selection a
##   manifest signed by a key generated for the control, with the host's
##   anchors; every tick heartbeat carries the result.
## * DET-AO-6: ``dpkgOwnershipControl`` asks the hook's collision driver who
##   owns ``/usr/bin/dpkg`` through the finding's own routine; every
##   ``hook-run`` record carries the result. The driver reads a dpkg database
##   laid out under a scratch root (``newDpkgDriver(root)``, the driver's
##   own relocation for tests): the build host need not be a Debian.
##
## The off-host half runs the production check over a real sink's store. A
## host with a short tick interval (1 s) lets the window (three tick
## intervals) pass within the test.
##
## Falsifying builds: ``manifest-control-skipped`` (the tick runs no
## control: the DET-AO-1 cases go red), ``hook-control-skipped`` (the hook
## runs none: the DET-AO-6 cases go red), ``check-ignores-controls`` (the
## off-host check never judges one: the alert cases go red).
##
## Mocks: none. The dpkg database is a real one in layout, laid out by the
## test because the build host has none.

import std/[os, sequtils, strutils, times, unittest]

import repro_peer_cache/auth as peerAuth
import repro_peer_cache/evidence
import repro_peer_cache/types
import repro_deploy_agent/agent
import repro_deploy_agent/tick_status

import repro_addon/agent_split
import repro_addon/apt_hook
import repro_addon/collision
import repro_addon/egress_observer
import repro_addon/evidence as addonEvidence
import repro_addon/evidence_check
import repro_addon/evidence_ship
import repro_addon/tick_evidence

import ./addon_evidence_fixture

let root = getTempDir() / ("addon-detector-controls-" & $getCurrentProcessId())
removeDir(root)
createDir(root)

let producer = peerAuth.generateKeypair()
writeFile(root / "deploy-signers.anchors",
          peerAuth.publicKeyHex(producer.publicKey) & "\n")
let anchors = peerAuth.loadTrustAnchors(root / "deploy-signers.anchors")

proc dpkgRoot(name: string; owns: bool): string =
  ## A base's dpkg database: ``/usr/bin/dpkg`` listed by package dpkg
  ## (``owns``), or a database in which nothing lists it.
  result = root / name
  createDir(result / "var/lib/dpkg/info")
  writeFile(result / "var/lib/dpkg/status", "Package: dpkg\nStatus: install ok installed\n")
  writeFile(result / "var/lib/dpkg/info/dpkg.list",
    "/.\n/usr\n/usr/bin\n" & (if owns: "/usr/bin/dpkg\n" else: "") &
    "/usr/bin/dpkg-query\n")

proc quickHost(name: string; sink: SinkFixture): HostFixture =
  ## A host whose tick interval is 1 s.
  result = newHost(root, name, sink)
  writeFile(result.site.confPath, readFile(result.site.confPath).replace(
    "tick-interval = 330", "tick-interval = 1"))
  result.conf = loadEvidenceConf(result.site.confPath)
  layGeneration(result.evidence.stateDir, "g0", "ledger 0\n", "")
  sink.enrol(result)

proc ship(h: HostFixture) =
  let r = runEvidenceShip(h.site, h.conf, h.evidence.host, forceHeartbeat = true)
  doAssert r.error == "", r.error

proc beat(h: HostFixture; tickAnchors: TrustAnchors; egress: string) =
  ## One tick (DET-AO-1's control over ``tickAnchors``) and one egress
  ## check whose control is ``egress``, shipped.
  recordTickEvidence(RecordedTick(outcome: AgentOutcome(kind: aoWaiting,
    target: "h1")), AgentApplyContext(), h.evidence, tickAnchors)
  recordEgressCheck(EgressCheck(present: true, control: egress), h.evidence,
                    1000)
  h.ship()

proc check(sink: SinkFixture; hosts: seq[HostFixture]): CheckReport =
  runEvidenceCheck(CheckInputs(storeDir: sink.storeDir,
    hosts: hosts.mapIt(EnrolledHost(hostId: it.credentialHost, target: "h1")),
    nowMs: int64(epochTime() * 1000), silenceFactor: 3))

proc alertsOf(r: CheckReport; h: HostFixture; det: string): seq[Alert] =
  r.alerts.filterIt(it.host == h.credentialHost and it.detector == det)

proc statusOf(r: CheckReport; h: HostFixture; det: string): string =
  for s in r.statuses:
    if s.host == h.credentialHost and s.detector == det: return s.status
  "absent"

proc fieldsOf(sink: SinkFixture; h: HostFixture; detector, trigger: string):
    seq[string] =
  ## The ``control`` field of every record of ``detector``/``trigger`` that
  ## ``h`` shipped.
  for e in sink.entries():
    if e.kind == ekRecord and $e.senderHostId == h.credentialHost and
        e.record.detector == detector and e.record.trigger == trigger:
      result.add(e.record.field("control"))

suite "DET-AO-1's control runs with the host's anchors":
  test "a manifest signed by a key generated for the control is refused":
    check manifestControl("h1", anchors) == "tripped"

  test "without anchors there is nothing to prove, and no target is a miss":
    check manifestControl("h1", nil) == "not-run"
    check manifestControl("", anchors).startsWith("missed")

suite "DET-AO-6's control reads the base's package database":
  test "dpkg's own binary is found owned by package dpkg":
    check dpkgOwnershipControl(newDpkgDriver(dpkgRoot("base-ok", true))) ==
      "tripped"

  test "a database that no longer lists it misses, and says why":
    let c = dpkgOwnershipControl(newDpkgDriver(dpkgRoot("base-blind", false)))
    checkpoint c
    check c.startsWith("missed")
    check "/usr/bin/dpkg" in c

  test "an unreadable database misses":
    let r = root / "base-damaged"
    createDir(r / "var/lib/dpkg")
    writeFile(r / "var/lib/dpkg/status", "")
    check dpkgOwnershipControl(newDpkgDriver(r)).startsWith("missed")

suite "the off-host check alerts on a detector whose control never trips":
  let sink = startSink(root)
  let proven = quickHost("proven", sink)
  let unproven = quickHost("unproven", sink)
  # Four tick intervals: past the three the window allows. ``proven`` trips
  # its controls on every beat; ``unproven`` heartbeats just as often and
  # never proves a thing (a binary from before the controls, say).
  for i in 0 ..< 5:
    proven.beat(anchors, "tripped")
    unproven.beat(nil, "idle")
    sleep(1000)
  let r = sink.check(@[proven, unproven])
  checkpoint render(r)

  test "the tick heartbeat carries DET-AO-1's control":
    let controls = sink.entries().filterIt(
      it.record.detector == "addon-agent-tick" and
      it.record.category == ecHeartbeat).mapIt(it.record.field("control"))
    check "tripped" in controls
    check "not-run" in controls

  test "a heartbeating detector whose control never tripped is unproven":
    check r.alertsOf(unproven, "DET-AO-1").anyIt(it.trigger == "control-missing")
    check r.alertsOf(unproven, "DET-AO-3").anyIt(it.trigger == "control-missing")
    check r.statusOf(unproven, "addon-manifest") == "unproven"
    check r.statusOf(unproven, "addon-egress") == "unproven"

  test "a detector whose control trips is not":
    check not r.alertsOf(proven, "DET-AO-1").anyIt(it.trigger == "control-missing")
    check not r.alertsOf(proven, "DET-AO-3").anyIt(it.trigger == "control-missing")
    check r.statusOf(proven, "addon-manifest") == "live-idle"
    check r.statusOf(proven, "addon-egress") == "live-idle"

  test "the apt hook's run carries DET-AO-6's control, and a miss alerts":
    discard runAfterDpkgCli(proven.evidence.stateDir / "no-ledger-here",
      logPath = proven.root / "apt-hook.log", site = proven.evidence,
      dpkgLog = proven.site.dpkgLog,
      driver = newDpkgDriver(dpkgRoot("base-proven", true)))
    discard runAfterDpkgCli(unproven.evidence.stateDir / "no-ledger-here",
      logPath = unproven.root / "apt-hook.log", site = unproven.evidence,
      dpkgLog = unproven.site.dpkgLog,
      driver = newDpkgDriver(dpkgRoot("base-unproven", false)))
    proven.ship()
    unproven.ship()
    check sink.fieldsOf(proven, "addon-apt-hook", "hook-run") == @["tripped"]
    check sink.fieldsOf(unproven, "addon-apt-hook", "hook-run").allIt(
      it.startsWith("missed"))
    let after = sink.check(@[proven, unproven])
    checkpoint render(after)
    check not after.alertsOf(proven, "DET-AO-6").anyIt(
      it.trigger == "control-missing")
    check after.alertsOf(unproven, "DET-AO-6").anyIt(
      it.trigger == "control-missing")
    # The miss is a detection of its own, reported where it happened.
    check after.alertsOf(unproven, "DET-AO-6").anyIt(
      it.trigger == "hook-control-missed")

  sink.server.stop()

removeDir(root)

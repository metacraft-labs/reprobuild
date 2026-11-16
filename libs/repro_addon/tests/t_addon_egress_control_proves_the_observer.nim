## The egress observer (DET-AO-3) proves on the host that it still sees the
## fetch unit's slice (DET-4: a positive control on a schedule, not once at
## implementation; spec §10.4 "Scheduled positive controls", threat model
## §9 "Scheduled controls"; reprobuild-pm issue
## ``2026-11-12-detector-positive-controls-run-once-not-on-a-schedule-as-det-4-requires.md``).
##
## The observer is a table whose rules match the slice with ``socket
## cgroupv2``, which keeps the cgroup it resolved when the rule was loaded.
## A slice created again at the same path, or rules flushed from the table,
## leave the table loaded and the check heartbeating ``present`` while
## nothing from the slice is counted any more. Before the fix nothing told
## that apart from "nothing refused": the off-host check reported DET-AO-3
## ``live-detecting`` / ``live-idle`` and raised nothing.
##
## Here the rendered table is loaded for real into a user and network
## namespace (``unshare -rn``). Where a systemd user manager exists, the
## test runs in a delegated scope (``systemd-run --user --scope -p
## Delegate=yes``) and points the table's cgroup match at a cgroup it
## creates there, so it can remove and create the matched cgroup again,
## exactly as the kernel sees a slice created again. Without one, the match
## names this process's own level-2 cgroup, as ``t_addon_egress_observer``
## does: every case but the re-creation runs, and that one is skipped with
## the reason. The "fetch unit" is this binary re-executed in the matched
## cgroup, running the production fetch (``agent_split.runAgentFetch``) and
## then sending one datagram outside the allow-list. The production check
## (``checkEgress`` / ``recordEgressCheck``), the production tick recorder,
## the real shipping run, a real Evidence sink and the production off-host
## check (``runEvidenceCheck``) do the rest.
##
## Each phase asserts first that the observer is blind (a refused datagram
## from the slice is not counted) and then that the off-host check says so:
## a DET-AO-3 ``control-missing`` alert and the status ``unproven``. While
## the observer still matches, the control trips and nothing of the kind is
## raised (the test is not vacuous in either direction).
##
## Falsifying builds: ``egress-control-not-sent`` (the fetch sends no
## control: the intact phase goes red), ``check-ignores-controls`` (the
## off-host check never judges a control: both blind phases go red).
##
## Mocks: none. Every step is a production code path; the only stand-ins are
## the places (a scratch state, a delegated cgroup standing for
## ``system.slice/system-reproagent.slice``, a sink on loopback).

import std/[os, osproc, sequtils, strutils, times, unittest]
import std/posix except Time

import repro_test_support/reasoned_skip

import repro_peer_cache/auth as peerAuth
import repro_peer_cache/evidence
import repro_deploy_agent/agent
import repro_deploy_agent/tick_status

import repro_addon/agent_split
import repro_addon/egress_observer
import repro_addon/evidence as addonEvidence
import repro_addon/evidence_check
import repro_addon/evidence_ship
import repro_addon/generation0
import repro_addon/nft_tables

import ./addon_evidence_fixture

const
  ModeVar = "REPRO_TEST_EGRESS_CONTROL_MODE"
    ## How this binary was re-executed: unset (the suite runs it), "inside"
    ## (in the namespaces) or "fetch" (the fetch unit). Not argv:
    ## ``std/unittest`` reads the arguments as test filters.
  DelegatedVar = "REPRO_TEST_EGRESS_CONTROL_DELEGATED"
    ## "1" inside a delegated scope; otherwise why there is none.
  TickSec = 2
    ## The fixture host's tick interval: the off-host check judges the
    ## control over ``silenceFactor`` (3) of them.

proc sendUdp(address: string) =
  ## One datagram from this process; ``IPAddressDeny=`` would drop it in a
  ## unit, and nothing listens here.
  let r = execCmdEx("python3 -c " & quoteShell(
    "import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); " &
    "s.sendto(b'x', ('" & address & "', 9))"))
  doAssert r.exitCode == 0, r.output

proc fetchUnitMain(procs, stagingRoot, refused: string) =
  ## The fetch unit, in the matched cgroup (``procs``: moved into it; "":
  ## already there): the production fetch (which sends the control first),
  ## then a datagram outside its allow-list.
  if procs.len > 0: writeFile(procs, $getCurrentProcessId())
  let anchors = peerAuth.newTrustAnchors()
  discard runAgentFetch(AgentConf(target: "h1"), anchors, stagingRoot,
                        AgentDeps())
  sendUdp(refused)

proc outerMain() =
  ## Re-run this binary in a user and network namespace of its own, inside
  ## a delegated scope where a systemd user manager gives one. The
  ## namespace tools are required: a test the suite runs must run, so a
  ## missing one is a failure with its reason.
  for tool in ["unshare", "nft", "python3", "ip"]:
    if findExe(tool).len == 0:
      echo "t_addon_egress_control_proves_the_observer: ", tool,
        " is required and not on PATH"
      quit 1
  putEnv(ModeVar, "inside")
  var args = @["-rn", getAppFilename()]
  var exe = "unshare"
  if findExe("systemd-run").len == 0:
    putEnv(DelegatedVar, "no systemd-run on PATH")
  else:
    let probe = execCmdEx("systemd-run --user --scope -q -p Delegate=yes -- true")
    if probe.exitCode == 0:
      putEnv(DelegatedVar, "1")
      exe = "systemd-run"
      args = @["--user", "--scope", "-q", "-p", "Delegate=yes", "--",
               "unshare"] & args
    else:
      putEnv(DelegatedVar, "no systemd user manager gives a delegated scope " &
        "here (" & probe.output.strip() & ")")
  let p = startProcess(exe, args = args, options = {poUsePath, poParentStreams})
  let code = p.waitForExit()
  p.close()
  quit code

if getEnv(ModeVar) == "fetch":
  fetchUnitMain(paramStr(1), paramStr(2), paramStr(3))
  quit 0
if getEnv(ModeVar) != "inside":
  outerMain()

let root = getTempDir() / ("addon-egress-control-" & $getCurrentProcessId())
removeDir(root)
createDir(root)

proc ownCgroup(): string =
  for l in readFile("/proc/self/cgroup").splitLines():
    if l.startsWith("0::/"): return l[3 .. ^1]
  ""

let nft = findExe("nft")
let delegated = getEnv(DelegatedVar) == "1"
var slice, rel, procs: string
if delegated:
  let scopeCgroup = ownCgroup()    # before this process moves to the leaf
  let scope = "/sys/fs/cgroup" & scopeCgroup
  # This process leaves the scope's own cgroup for a leaf, so the scope may
  # have children (cgroup v2: no processes in an inner node with
  # controllers), and the slice holds the fetch unit alone.
  createDir(scope / "leaf")
  writeFile(scope / "leaf" / "cgroup.procs", $getCurrentProcessId())
  slice = scope / "slice"
  createDir(slice)
  rel = (scopeCgroup & "/slice")[1 .. ^1]
  procs = slice / "cgroup.procs"
else:
  # This process's own level-2 cgroup, which the fetch unit inherits.
  let parts = ownCgroup()[1 .. ^1].split('/')
  doAssert parts.len >= 2, ownCgroup()
  rel = parts[0] & "/" & parts[1]
let level = rel.split('/').len
doAssert execCmdEx("ip link set lo up").exitCode == 0

# The sink stands for the fetch unit's allowed origin: this process's
# connections to it are not refused destinations (and, without a delegated
# scope, this process is in the matched cgroup).
let production = renderEgressNft(@["10.0.2.2", "127.0.0.1"])
let matchOf = "socket cgroupv2 level 2 \"" & AgentSliceCgroup & "\""
doAssert matchOf in production
let tablePath = root / "egress.nft"
writeFile(tablePath, production.replace(matchOf,
  "socket cgroupv2 level " & $level & " \"" & rel & "\""))

proc loadTable() =
  let r = execCmdEx(quoteShell(nft) & " -f " & quoteShell(tablePath))
  doAssert r.exitCode == 0, r.output

proc recreateSlice() =
  ## The matched cgroup removed and created again at the same path: what
  ## the kernel sees when the slice is created again.
  # A cgroup directory is removed with rmdir(2) alone: its files are the
  # kernel's interface, not files to delete.
  doAssert posix.rmdir(slice.cstring) == 0, "rmdir " & slice & ": " &
    osErrorMsg(osLastError())
  createDir(slice)

let sink = startSink(root)
var host = newHost(root, "h", sink)
sink.enrol(host)
writeFile(host.site.confPath, readFile(host.site.confPath).replace(
  "tick-interval = 330", "tick-interval = " & $TickSec))
host.conf = loadEvidenceConf(host.site.confPath)
layGeneration(host.evidence.stateDir, "g0", "ledger 0\n", "")
let statePath = root / "egress-refused.state"
let stagingRoot = root / "fetch-staging"

var refusedNo = 0
proc fetch(): string =
  ## One run of the fetch unit in the slice; the destination it refused.
  inc refusedNo
  result = "127.1.2." & $refusedNo
  let r = execCmdEx(ModeVar & "=fetch " & quoteShell(getAppFilename()) & " " &
    quoteShell(procs) & " " & quoteShell(stagingRoot) & " " & result)
  doAssert r.exitCode == 0, r.output

proc tickAndCheck(): EgressCheck =
  ## A tick, the check the fetch's ``OnSuccess=`` starts, and shipping.
  recordTickEvidence(RecordedTick(outcome: AgentOutcome(kind: aoWaiting,
    target: "h1")), AgentApplyContext(), host.evidence)
  result = checkEgress(nft, statePath)
  doAssert result.error == "", result.error
  recordEgressCheck(result, host.evidence, TickSec * 1000)
  let s = runEvidenceShip(host.site, host.conf, host.evidence.host,
                          forceHeartbeat = true)
  doAssert s.error == "", s.error

proc offHost(): CheckReport =
  runEvidenceCheck(CheckInputs(storeDir: sink.storeDir,
    hosts: @[EnrolledHost(hostId: host.credentialHost, target: "h1")],
    nowMs: int64(epochTime() * 1000), silenceFactor: 3))

proc egressAlerts(r: CheckReport): seq[Alert] =
  r.alerts.filterIt(it.host == host.credentialHost and
                    it.detector == "DET-AO-3")

proc egressStatus(r: CheckReport): string =
  for s in r.statuses:
    if s.host == host.credentialHost and s.detector == "addon-egress":
      return s.status
  "absent"

proc runFor(seconds: int): seq[tuple[refused: string; seen: bool]] =
  ## A fetch, a tick and a check every second for ``seconds``.
  let until = epochTime() + float(seconds)
  while epochTime() < until:
    let d = fetch()
    let c = tickAndCheck()
    result.add((d, c.refused.anyIt(it.address == d)))
    sleep(1000)

loadTable()

suite "the egress observer proves on the host that it sees the fetch slice":
  test "while it matches, the control trips and nothing is unproven":
    let runs = runFor(TickSec * 4)
    # Not vacuous: the observer counts what the slice sends.
    check runs.allIt(it.seen)
    let r = offHost()
    checkpoint render(r)
    check not r.egressAlerts.anyIt(it.trigger == "control-missing")
    check r.egressStatus in ["live-idle", "live-detecting"]

  test "a slice created again is blind, and the off-host check says so":
    if not delegated:
      skip("creating the matched cgroup again needs a delegated cgroup: " &
           getEnv(DelegatedVar))
      return
    recreateSlice()
    let runs = runFor(TickSec * 4)
    # The table is loaded and the check heartbeats, but nothing from the
    # new cgroup is counted: the rule still names the old one.
    check not runs.anyIt(it.seen)
    let r = offHost()
    checkpoint render(r)
    check r.egressAlerts.anyIt(it.trigger == "control-missing")
    check r.egressStatus == "unproven"

  test "a table loaded again sees the slice again, and the control trips":
    loadTable()
    let runs = runFor(TickSec * 4)
    check runs.allIt(it.seen)
    let r = offHost()
    checkpoint render(r)
    check not r.egressAlerts.anyIt(it.trigger == "control-missing")
    check r.egressStatus in ["live-idle", "live-detecting"]

  test "rules flushed from a loaded table are blind, and the check says so":
    let f = execCmdEx(quoteShell(nft) & " flush chain inet " &
                      EgressTableName & " output")
    check f.exitCode == 0
    let runs = runFor(TickSec * 4)
    check not runs.anyIt(it.seen)
    let r = offHost()
    checkpoint render(r)
    check r.egressAlerts.anyIt(it.trigger == "control-missing")
    check r.egressStatus == "unproven"

sink.server.stop()
removeDir(root)

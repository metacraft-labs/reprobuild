## The deploy agent's egress observer (owner decision 2026-11-04; threat
## model DET-AO-3, G40): the add-on's own nftables table counts every packet
## the fetch unit's slice sends outside its allow-list, the check turns each
## new or grown destination into a DET-AO-3 record, and a base that cannot
## carry the table is refused by name.
##
## The table is loaded for real -- the rendered ``egress.nft``, with its
## cgroup match pointed at this test process's own cgroup -- into a network
## namespace of a user namespace (``unshare -rn``), where this process has
## ``CAP_NET_ADMIN`` over that namespace only; a UDP datagram to a TEST-NET
## address is sent from it, and the table's set read back as JSON. Nothing
## outside the namespace is touched.
##
## Falsifying builds: ``egress-state-survives-reload`` (the reload step);
## ``egress-observer-not-installed`` -- the observer unit
## never loads the table; the unit step goes red.
##
## Mocks: none.

import std/[os, osproc, sequtils, strutils, unittest]

import repro_addon/egress_observer
import repro_addon/evidence as addonEvidence
import repro_addon/generation0
import repro_addon/nft_tables

let root = getTempDir() / ("addon-egress-" & $getCurrentProcessId())
removeDir(root)
createDir(root)

proc ownCgroupLevel2(): string =
  ## The first two components of this process's cgroup (v2).
  for l in readFile("/proc/self/cgroup").splitLines():
    if l.startsWith("0::/"):
      let parts = l[4 .. ^1].split('/')
      if parts.len >= 2: return parts[0] & "/" & parts[1]
  ""

suite "the egress observer's table":
  let nft = findExe("nft")
  test "the rendered table loads, counts a refused destination, and reads back":
    check nft.len > 0
    let cg = ownCgroupLevel2()
    check cg.len > 0
    let text = renderEgressNft(@["10.0.2.2"]).replace(AgentSliceCgroup, cg)
    writeFile(root / "egress.nft", text)
    let script = "set -e; ip link set lo up; ip route add 192.0.2.0/24 dev lo; ip route add 10.0.2.0/24 dev lo; " &
      quoteShell(nft) & " -f " & quoteShell(root / "egress.nft") & "; " &
      "python3 -c 'import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); " &
      "s.sendto(b\"x\", (\"192.0.2.7\", 9)); s.sendto(b\"x\", (\"10.0.2.2\", 9))'; " &
      quoteShell(nft) & " -j list set inet " & EgressTableName & " refused4"
    let (output, code) = execCmdEx("unshare -rn sh -c " & quoteShell(script))
    checkpoint output
    check code == 0
    let refused = parseRefusedSet(output.splitLines().filterIt(
      it.startsWith("{")).join(""))
    check refused.anyIt(it.address == "192.0.2.7" and it.packets >= 1)
    # The allow-listed origin is not counted.
    check not refused.anyIt(it.address == "10.0.2.2")

  test "a new or grown destination is fresh once":
    let st = root / "state"
    let a = freshSince(@[("192.0.2.7", 1'i64)], st)
    check a.len == 1
    check freshSince(@[("192.0.2.7", 1'i64)], st).len == 0
    check freshSince(@[("192.0.2.7", 3'i64)], st).len == 1

  test "after a table reload a refused destination is reported again (F3)":
    let st = root / "state-reload"
    check freshSince(@[("192.0.2.10", 3'i64)], st, "7").len == 1
    check freshSince(@[("192.0.2.10", 3'i64)], st, "7").len == 0
    # Reloaded (a new handle): its counters start at zero.
    check freshSince(@[("192.0.2.10", 2'i64)], st, "9").len == 1

  test "a fresh destination is a DET-AO-3 detection; a missing table too":
    writeFile(root / "evidence.conf", "sink = 127.0.0.1:1\n")
    let site = EvidenceSite(stateDir: root / "s", dir: root / "ev",
      outbox: root / "ev" / "outbox", confPath: root / "evidence.conf",
      attestationKey: root / "none", host: "h", journal: false)
    recordEgressCheck(EgressCheck(present: true,
      refused: @[("192.0.2.7", 1'i64)], fresh: @[("192.0.2.7", 1'i64)]),
      site, 30_000)
    check evidenceRecords("egress-refused", site.dir).len == 1
    recordEgressCheck(EgressCheck(present: false), site, 30_000)
    check evidenceRecords("egress-observer-missing", site.dir).len == 1
    check outboxEntries(site.outbox).anyIt(it.endsWith("-egress-check.evr"))

  test "a base without nft is refused by name":
    check egressObserverProblem("").startsWith(EgressObserverUnavailable)
    check egressObserverProblem(root / "no-such-nft").startsWith(
      EgressObserverUnavailable)

  test "the observer unit loads the table and deletes it when stopped":
    let u = egressUnit("/usr/sbin/nft")
    check "ExecStart=/usr/sbin/nft -f " & EgressNftPath & "\n" in u
    check "ExecStop=/usr/sbin/nft delete table inet " & EgressTableName in u
    check "CapabilityBoundingSet=CAP_NET_ADMIN\n" in u
    let f = agentFetchUnit("/repro/store/x/bin/repro", AgentUnitsInputs(
      target: "t", allowedAddresses: @["10.0.2.2"]), observed = true)
    check "Slice=" & AgentSlice & "\n" in f
    check "Requires=" & EgressUnit & "\n" in f
    check "OnFailure=" & EgressCheckUnit & "\n" in f
    check observeFetchUnit(agentFetchUnit("/repro/store/x/bin/repro",
      AgentUnitsInputs(target: "t", allowedAddresses: @["10.0.2.2"]))) == f

removeDir(root)

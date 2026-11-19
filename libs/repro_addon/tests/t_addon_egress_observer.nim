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
## The table's reach is probed too, because the threat model's DET-AO-3 row
## once claimed a connect from the apply or re-assert unit as a detection
## (reprobuild-pm issue
## ``2026-11-12-det-ao-3-claims-to-detect-connects-from-the-apply-and-re-assert-units-no-mechanism-can.md``).
## The same rendered table is loaded and two connects it must not see are
## made: one from a network namespace nested inside the table's (what
## ``PrivateNetwork=yes`` gives the apply and re-assert units), and one from
## a process outside the matched slice (what a ``systemd-run`` transient unit
## of the host's systemd is). Neither is counted: those units' egress is
## not detected. That the apply and re-assert units' egress is prevented is
## held by their own no-network gates, not by this test (threat model §9,
## "What DET-AO-3 sees").
##
## Falsifying builds: ``egress-state-survives-reload`` and
## ``egress-instance-ignores-boot`` (the reload step);
## ``egress-observer-not-installed`` -- the observer unit
## never loads the table; the unit step goes red.
##
## Mocks: one, a stand-in ``nft`` in the read-race case, justified there.

import std/[algorithm, os, osproc, sequtils, strutils, unittest]

import repro_addon/egress_observer
import repro_addon/evidence as addonEvidence
import repro_addon/generation0
import repro_addon/nft_tables

const InnerCheckEnv = "REPRO_ADDON_EGRESS_TEST_CHECK_STATE"
  ## Set to a state path, this binary runs one ``checkEgress`` against the
  ## table of the network namespace it was started in, prints what the check
  ## found, and exits: the suite's cases start it inside the ``unshare -rn``
  ## namespace that holds the real table (``checkEgress`` runs ``nft``
  ## itself, so it has to run where the table is).
if existsEnv(InnerCheckEnv):
  let c = checkEgress(findExe("nft"), getEnv(InnerCheckEnv))
  echo "CHECK present=", c.present, " setFull=", c.setFull,
       " unattributed=", c.unattributed, " fresh=", c.fresh.len,
       " refused=", c.refused.len,
       (if c.error.len > 0: " error=" & c.error else: "")
  quit(0)

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

  test "it sees only its slice, in its own namespace (DET-AO-3's reach)":
    check nft.len > 0
    let own = ownCgroupLevel2()
    check own.len > 0
    # Another level-2 cgroup that exists and does not hold this process: the
    # match resolves its path when the table loads, so it must exist. It
    # stands for the fetch unit's slice as seen by a process outside it.
    # journald's unit is preferred because it lives as long as the host;
    # otherwise the first in sorted order. A transient unit picked here could
    # vanish before the table loads, which fails the load (red, not a pass).
    # A host or container whose cgroup tree holds no level-2 directory but
    # this process's own fails ``other.len > 0``: it cannot run this probe.
    var candidates: seq[string]
    for top in walkDirs("/sys/fs/cgroup/*"):
      for d in walkDirs(top / "*"):
        let rel = d.relativePath("/sys/fs/cgroup")
        if rel != own: candidates.add rel
    candidates.sort()
    let journald = "system.slice/systemd-journald.service"
    let other =
      if journald in candidates: journald
      elif candidates.len > 0: candidates[0]
      else: ""
    checkpoint "own cgroup: " & own & "; outside cgroup: " & other
    check other.len > 0
    # ``SEND <address>``: one UDP datagram to port 9 of the address.
    writeFile(root / "send.py", "import socket, sys\n" &
      "socket.socket(socket.AF_INET, socket.SOCK_DGRAM)" &
      ".sendto(b'x', (sys.argv[1], 9))\n")
    let send = "python3 " & quoteShell(root / "send.py")
    proc run(text: string; inner: string): seq[RefusedDestination] =
      ## Loads ``text`` into a fresh network namespace of a user namespace,
      ## runs ``inner`` there, and reads the table's refused set back.
      writeFile(root / "reach.nft", text)
      let script = "set -e; ip link set lo up; " &
        "ip route add 192.0.2.0/24 dev lo; " &
        quoteShell(nft) & " -f " & quoteShell(root / "reach.nft") & "; " &
        inner & "; " &
        quoteShell(nft) & " -j list set inet " & EgressTableName & " refused4"
      let (output, code) = execCmdEx("unshare -rn sh -c " &
        quoteShell(script))
      checkpoint output
      check code == 0
      parseRefusedSet(output.splitLines().filterIt(
        it.startsWith("{")).join(""))
    # A private network namespace inside the observed one (the apply and
    # re-assert units' ``PrivateNetwork=yes``), in the observed cgroup and
    # with a route, so its datagram does leave the socket. Vacuity: the same
    # datagram from the observed namespace is counted.
    let nested = run(renderEgressNft(@[]).replace(AgentSliceCgroup, own),
      send & " 192.0.2.7; unshare -n sh -c " & quoteShell(
        "set -e; ip link set lo up; ip route add 192.0.2.0/24 dev lo; " &
        send & " 192.0.2.8"))
    check nested.anyIt(it.address == "192.0.2.7" and it.packets >= 1)
    check not nested.anyIt(it.address == "192.0.2.8")
    # A process outside the matched slice, in the observed namespace (a
    # transient unit a root unit starts through the host's systemd): its
    # datagram is not counted, and the set stays empty.
    let outside = run(renderEgressNft(@[]).replace(AgentSliceCgroup, other),
      send & " 192.0.2.9")
    check outside.len == 0

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
    # Reloaded at the next boot: the kernel's handle counter started again,
    # so the table has the handle it had before; the boot id differs.
    let listed = """{"nftables": [{"metainfo": {"json_schema_version": 1}},
      {"table": {"family": "inet", "name": "repro_addon_egress",
                 "handle": 1}}]}"""
    let bootA = instanceKey(listed, "5e3e48b1-d51d-4b32-a113-c194f6566aba")
    let bootB = instanceKey(listed, "0f1c2d3e-4b5a-6978-8a9b-acbdcedf0011")
    check bootA.len > 0
    check bootA != bootB
    check instanceKey(listed, "") == "1"
    check instanceKey("""{"nftables": []}""", "x") == ""
    let sb = root / "state-reboot"
    check freshSince(@[("192.0.2.10", 3'i64)], sb, bootA).len == 1
    check freshSince(@[("192.0.2.10", 3'i64)], sb, bootA).len == 0
    check freshSince(@[("192.0.2.10", 2'i64)], sb, bootB).len == 1

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
    # ``-``: a stop or restart after a flush nothing repaired finds the
    # table gone and must not leave the unit failed.
    check "ExecStop=-/usr/sbin/nft delete table inet " & EgressTableName in u
    check "CapabilityBoundingSet=CAP_NET_ADMIN\n" in u
    let f = agentFetchUnit("/repro/store/x/bin/repro", AgentUnitsInputs(
      target: "t", allowedAddresses: @["10.0.2.2"]), observed = true)
    check "Slice=" & AgentSlice & "\n" in f
    check "Requires=" & EgressUnit & "\n" in f
    check "OnFailure=" & EgressCheckUnit & "\n" in f
    check observeFetchUnit(agentFetchUnit("/repro/store/x/bin/repro",
      AgentUnitsInputs(target: "t", allowedAddresses: @["10.0.2.2"]))) == f

  test "the observer unit follows the host's nftables.service":
    # Reprobuild-pm issue
    # 2026-11-16-addon-egress-table-stays-deleted-after-nftables-service-flushes-the-ruleset.md:
    # Debian's and Ubuntu's nftables.service flushes the whole ruleset at
    # start, reload and stop (and an upgrade try-restarts it), deleting the
    # table while this RemainAfterExit= unit stays active. Tied by reference
    # (within spec §13 decision 43), the unit loads after it, restarts and stops
    # with it, and reloads the table when it reloads. Red under
    # ``egress-unit-ignores-host-ruleset``.
    let ls = egressUnit("/usr/sbin/nft", "ab").splitLines()
    checkpoint ls.join("\n")
    let unitEnd = ls.find("[Service]")
    check unitEnd > 0
    for want in ["After=" & HostNftablesUnit, "PartOf=" & HostNftablesUnit,
                 "ReloadPropagatedFrom=" & HostNftablesUnit]:
      check ls.find(want) in 0 ..< unitEnd
    check ls.find("ExecReload=/usr/sbin/nft -f " & EgressNftPath) > unitEnd
    # No [Install] link reaches the management-path unit: the tie is this
    # unit's own [Unit] section only.
    check not ls.anyIt(it.startsWith("WantedBy=" & HostNftablesUnit) or
                       it.startsWith("RequiredBy=" & HostNftablesUnit))

  # ``egress-set-full`` means a full set, never a read race (reprobuild-pm
  # issue
  # ``2026-11-17-addon-egress-check-reports-set-full-for-one-unattributed-packet.md``):
  # the counter and the sets are separate ``nft`` reads, and packets keep
  # arriving between them.
  test "a packet the sets hold is attributed whichever read saw it first":
    let st = root / "state-race"
    var un = -1'i64
    # The counter, read first, saw 1 packet; the sets, read after it, already
    # hold a second one that arrived in between.
    discard freshSince(@[("192.0.2.20", 2'i64)], st, "t", 1, addr un)
    check un == 0
    # The next check's counter catches up with what the sets already showed:
    # nothing is unattributed (a per-check difference of growths read 1).
    discard freshSince(@[("192.0.2.20", 2'i64)], st, "t", 2, addr un)
    check un == 0
    # A full set: 5 packets counted that no element grew by -- reported once.
    discard freshSince(@[("192.0.2.20", 2'i64)], st, "t", 7, addr un)
    check un == 5
    discard freshSince(@[("192.0.2.20", 2'i64)], st, "t", 7, addr un)
    check un == 0
    # One more unattributed packet, while a known element also grows.
    discard freshSince(@[("192.0.2.20", 3'i64)], st, "t", 9, addr un)
    check un == 1
    # A check whose counter read failed keeps what was reported.
    un = -1
    discard freshSince(@[("192.0.2.20", 3'i64)], st, "t", -1, addr un)
    check un == -1
    discard freshSince(@[("192.0.2.20", 3'i64)], st, "t", 9, addr un)
    check un == 0
    # A reload starts the table's counters, and the count reported, at zero.
    discard freshSince(@[("192.0.2.20", 1'i64)], st, "u", 4, addr un)
    check un == 3

  # ``FLOOD <count> <first> <packets>``: ``packets`` datagrams to each of
  # ``count`` addresses from 10.<first>.0.0 on.
  writeFile(root / "flood.py", "import socket, sys\n" &
    "s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)\n" &
    "n, first, k = (int(a) for a in sys.argv[1:4])\n" &
    "for i in range(n):\n" &
    "    for _ in range(k):\n" &
    "        s.sendto(b'x', ('10.%d.%d.%d' % (first, i // 256, i % 256), 9))\n")
  let flood = "python3 " & quoteShell(root / "flood.py")

  proc realChecks(name, steps: string): seq[string] =
    ## Loads the rendered table (matching this process's cgroup) into a
    ## fresh network namespace, runs ``steps`` there, and returns the
    ## ``CHECK`` lines of the checks they made. In ``steps``, ``CHECK`` runs
    ## one ``checkEgress`` on the state ``name`` (this binary, started again
    ## inside the namespace: ``InnerCheckEnv``).
    writeFile(root / (name & ".nft"),
      renderEgressNft(@[]).replace(AgentSliceCgroup, ownCgroupLevel2()))
    let checkNow = InnerCheckEnv & "=" & quoteShell(root / ("state-" & name)) &
      " " & quoteShell(getAppFilename())
    let script = "set -e; ip link set lo up; ip route add 10.0.0.0/8 dev lo; " &
      quoteShell(nft) & " -f " & quoteShell(root / (name & ".nft")) & "; " &
      steps.replace("CHECK", checkNow)
    let (output, code) = execCmdEx("unshare -rn sh -c " & quoteShell(script))
    checkpoint output
    check code == 0
    output.splitLines().filterIt(it.startsWith("CHECK "))

  test "a check reads a full set, and counts what it did not add":
    # Reprobuild-pm issue
    # 2026-11-19-addon-egress-check-cannot-read-a-set-of-more-than-64-kib.md:
    # the check kept the first 64 KiB of ``nft -j list set``, so a set of
    # more than some 800 destinations failed to parse and the check recorded
    # nothing but its own error. The real table, filled to its size (4096)
    # and sent five packets it cannot add: the check reads every element,
    # says the set is full, and counts the five. Reported once.
    check nft.len > 0
    check ownCgroupLevel2().len > 0
    let checks = realChecks("full", flood & " " & $EgressSetSize & " 2 1; " &
      flood & " 5 3 1; CHECK; CHECK")
    check checks == @[
      "CHECK present=true setFull=true unattributed=5 fresh=" &
        $EgressSetSize & " refused=" & $EgressSetSize,
      # The destinations past the per-check cap, owed by the first check.
      "CHECK present=true setFull=true unattributed=0 fresh=" &
        $(EgressSetSize - EgressDetectionsMax) & " refused=" & $EgressSetSize]
    # The table's instance was read too (the listing it comes from holds
    # both sets): the state is keyed to a boot id and a handle, not to "-".
    let keyed = readFile(root / "state-full").splitLines().filterIt(
      it.startsWith("table "))
    checkpoint keyed.join(" | ")
    check keyed.len == 1 and '/' in keyed[0]

  test "the control datagram between the check's reads is no egress-set-full":
    # Mock: a stand-in ``nft`` answering from a file. The race is between
    # the check's separate reads of the kernel's counters and a packet sent
    # in between; a real table cannot be made to interleave on demand (and
    # needs ``CAP_NET_ADMIN``), so the stand-in sends "a control datagram"
    # -- the named counter and the control element both grow by one --
    # before every answer: the interleaving the drill met at a fetch.
    let dir = root / "fake-nft"
    createDir(dir)
    let fake = dir / "nft"
    let pk = dir / "packets"
    writeFile(pk, "0")
    let reload = dir / "reload"
    # ``$v`` is the count since the table's load: a reload (from the call
    # numbered in ``reload`` on) starts the counter and the set's elements
    # at zero again, and gives the table a new handle.
    # Shell builtins only: ``runHostTool`` runs it with ``HostToolPath``,
    # which holds no ``cat`` on a NixOS host -- a stand-in that shelled out
    # to one read ``n`` as empty, never counted a packet, and passed
    # without the fix.
    writeFile(fake, "#!/bin/sh\n" &
      "read n < " & quoteShell(pk) & "; n=$((n + 1)); echo $n > " &
        quoteShell(pk) & "\n" &
      "h=3; v=$n\n" &
      "if [ -e " & quoteShell(reload) & " ]; then\n" &
      "  read r < " & quoteShell(reload) & "\n" &
      "  if [ $n -ge $r ]; then h=4; v=$((n - r + 1)); fi\nfi\n" &
      "case \"$*\" in\n" &
      "  'list tables') echo 'table " & EgressTableFamily & " " &
        EgressTableName & "' ;;\n" &
      "  *'list set'*refused4) echo '{\"nftables\": [{\"set\": {\"elem\": " &
        "[{\"elem\": {\"val\": \"" & EgressControlAddress & "\", " &
        "\"counter\": {\"packets\": '$v'}}}]}}]}' ;;\n" &
      "  *'list set'*refused6) echo '{\"nftables\": [{\"set\": {}}]}' ;;\n" &
      "  *'list counter'*) echo '{\"nftables\": [{\"counter\": " &
        "{\"packets\": '$v'}}]}' ;;\n" &
      "  *'list table'*) echo '{\"nftables\": [{\"table\": " &
        "{\"handle\": '$h'}}]}' ;;\n" &
      "  *) exit 1 ;;\n" &
      "esac\n")
    setFilePermissions(fake, {fpUserRead, fpUserWrite, fpUserExec})
    let st = root / "state-control"
    var lastControl = 0'i64
    for i in 1 .. 3:
      let c = checkEgress(fake, st)
      check c.error.len == 0
      check c.present
      # Positive control: the stand-in did send datagrams during the check.
      check c.controlPackets > lastControl
      lastControl = c.controlPackets
      check not c.setFull
      check c.unattributed == 0
      check c.fresh.len == 0
    # The table reloaded between the check's reads of the counter and of
    # the sets: the old instance's counter (large) against the new
    # instance's sets (near empty) would read as unattributed packets. The
    # reads are taken again, within one instance, and nothing is.
    let n = parseInt(readFile(pk).strip())
    # This check's calls: tables, table, counter, set refused4, ... -- the
    # reload lands on the set read.
    writeFile(reload, $(n + 4))
    let r = checkEgress(fake, st)
    check r.error.len == 0
    check r.unattributed == 0
    check r.counted >= 0

removeDir(root)

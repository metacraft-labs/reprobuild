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
## ``egress-ignores-counter-reset`` (the two counter-reset cases);
## ``egress-shortfall-while-set-not-full``,
## ``egress-reset-bound-ignores-set-reset`` and
## ``egress-unread-instance-compared`` (the set-reset case);
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
       (if c.counterReset.len > 0: " reset=" & c.counterReset else: ""),
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

  test "a destination the listing repeats is one destination":
    # The kernel's dump of a set that grows while it is read repeats
    # elements: one destination, with the largest count listed.
    let listed = """{"nftables": [{"set": {"elem": [
      {"elem": {"val": "192.0.2.7", "counter": {"packets": 2}}},
      {"elem": {"val": "192.0.2.8", "counter": {"packets": 1}}},
      {"elem": {"val": "192.0.2.7", "counter": {"packets": 3}}}]}}]}"""
    check parseRefusedSet(listed) ==
      @[("192.0.2.7", 3'i64), ("192.0.2.8", 1'i64)]

  test "a new or grown destination is fresh once":
    # Within one table instance ("t"). An instance that could not be read
    # ("-", the default) matches none: see the set-reset case below.
    let st = root / "state"
    let a = freshSince(@[("192.0.2.7", 1'i64)], st, "t")
    check a.len == 1
    check freshSince(@[("192.0.2.7", 1'i64)], st, "t").len == 0
    check freshSince(@[("192.0.2.7", 3'i64)], st, "t").len == 1

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

  test "refused packets after a reset of the counter are still counted":
    # Reprobuild-pm issue
    # 2026-11-18-addon-egress-counter-reset-hides-unattributed-packets-until-the-shortfall-regrows.md:
    # ``nft reset counter`` zeroes the named counter and keeps the table's
    # handle and the sets' elements, so the counter falls below what the
    # sets hold, and packets a full set did not add afterwards were hidden
    # until they made up that gap. The real table: twenty control datagrams
    # (every fetch sends one, and their element keeps its count through the
    # reset too), nine refused packets and a check; the counter reset by
    # hand and a check; the set filled, and five packets it cannot add. The
    # check after counts those five, and the one after it five more.
    check nft.len > 0
    check ownCgroupLevel2().len > 0
    writeFile(root / "control.py", "import socket\n" &
      "s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)\n" &
      "for _ in range(20):\n" &
      "    s.sendto(b'c', ('" & EgressControlAddress & "', " &
        $EgressControlPort & "))\n")
    let checks = realChecks("reset",
      "python3 " & quoteShell(root / "control.py") & "; " &
      flood & " 1 1 9; CHECK; " &
      quoteShell(nft) & " reset counter inet " & EgressTableName &
        " refused >/dev/null; CHECK; " &
      # The set holds the control's element and one destination.
      flood & " " & $(EgressSetSize - 2) & " 2 1; " & flood & " 5 3 1; " &
      "CHECK; " & flood & " 5 4 1; CHECK")
    check checks == @[
      "CHECK present=true setFull=false unattributed=0 fresh=1 refused=1",
      # The check that sees the reset says so, and starts over.
      "CHECK present=true setFull=false unattributed=0 fresh=0 refused=1 " &
        "reset=the counter of refused packets fell from 29 to 0",
      "CHECK present=true setFull=true unattributed=5 fresh=" &
        $(EgressSetSize - 2) & " refused=" & $(EgressSetSize - 1),
      "CHECK present=true setFull=true unattributed=5 fresh=" &
        $(EgressSetSize - 2 - EgressDetectionsMax) & " refused=" &
        $(EgressSetSize - 1)]

  test "a count that went down in place makes the check start over":
    # The accounting of the case above, and what else can go down. Red
    # under ``egress-ignores-counter-reset``.
    let st = root / "state-went-down"
    var un = -1'i64
    var reset = "?"
    var controlWas = -1'i64
    proc step(refused: seq[RefusedDestination]; counted: int64;
              table = "t"; control = 0'i64;
              kernel = -1'i64): seq[RefusedDestination] =
      freshSince(refused, st, table, counted, addr un,
                 controlPackets = control, controlBefore = addr controlWas,
                 kernelCounted = kernel, counterReset = addr reset)
    # A full set: 12 packets counted, 9 held, 3 reported.
    discard step(@[("192.0.2.30", 9'i64)], 12)
    check (un, reset) == (3'i64, "")
    # The counter reset to zero and two packets since, which the full set
    # did not add: the reset is named, and the two are counted, since the
    # counter's new value was all counted after the reset and the set
    # gained nothing. What no set added before the reset cannot be told.
    discard step(@[("192.0.2.30", 9'i64)], 2)
    check un == 2
    check reset == "the counter of refused packets fell from 12 to 2"
    # From here on every unattributed packet is counted, one for one, though
    # the counter is still far below what the set holds.
    discard step(@[("192.0.2.30", 9'i64)], 7)
    check (un, reset) == (5'i64, "")
    discard step(@[("192.0.2.30", 9'i64)], 7)
    check (un, reset) == (0'i64, "")
    # A counter that could not be read keeps what the last reading was, so
    # a reset meanwhile is seen by the next check that reads it.
    discard step(@[("192.0.2.30", 9'i64)], -1)
    check reset == ""
    discard step(@[("192.0.2.30", 9'i64)], 1)
    check (un, reset) ==
      (1'i64, "the counter of refused packets fell from 7 to 1")
    discard step(@[("192.0.2.30", 9'i64)], 2)
    check (un, reset) == (1'i64, "")
    # A destination's count lowered in place: it is recorded again by its
    # new count, and the shortfall that opened (the counter kept its 2) is
    # not reported as packets.
    let again = step(@[("192.0.2.30", 4'i64)], 2)
    check again == @[("192.0.2.30", 4'i64)]
    check (un, reset) == (0'i64, "the count of 192.0.2.30 fell from 9 to 4")
    # The control's element reset: its earlier count is zero, so the
    # control still reads as tripped by what was sent since.
    discard step(@[("192.0.2.30", 4'i64)], 2, control = 6, kernel = 8)
    check (un, reset, controlWas) == (0'i64, "", 0'i64)
    discard step(@[("192.0.2.30", 4'i64)], 7, control = 1, kernel = 8)
    check (un, controlWas) == (0'i64, 0'i64)
    check reset == "the control address's count fell from 6 to 1"
    # A control datagram between the check's reads lowers the counter LESS
    # the control's element (7, then 6) while the kernel's counter grew
    # (8, then 9): no reset.
    discard step(@[("192.0.2.30", 4'i64)], 6, control = 3, kernel = 9)
    check (un, reset) == (0'i64, "")
    # The counter reset while the control's element keeps a count above
    # it: the counter less the element is below zero, which ``counted``
    # (it stops at zero) does not show. The shortfall follows the kernel's
    # counter, so the next two packets no set added are counted. (Taken
    # from ``counted`` they were hidden until the counter passed the
    # control's count.)
    discard step(@[("192.0.2.30", 4'i64)], 0, control = 3, kernel = 0)
    check (un, reset) ==
      (0'i64, "the counter of refused packets fell from 9 to 0")
    # (A reset counter that a packet the set DID add has raised again
    # proves nothing unattributed: 5 counted, and the set gained 5.)
    discard step(@[("192.0.2.30", 9'i64)], 2, control = 3, kernel = 5)
    discard step(@[("192.0.2.30", 14'i64)], 2, control = 3, kernel = 5)
    check (un, reset) == (0'i64, "")
    discard step(@[("192.0.2.30", 4'i64)], 0, control = 3, kernel = 0)
    check reset.startsWith("the counter of refused packets fell from 5 to 0")
    discard step(@[("192.0.2.30", 4'i64)], 0, control = 3, kernel = 2)
    check (un, reset) == (2'i64, "")
    # A destination deleted from its set (the sets have no timeout): the
    # check starts over, and the packets it held are not reported as ones a
    # full set did not add.
    discard step(@[("192.0.2.30", 4'i64), ("192.0.2.31", 6'i64)], 5,
                 control = 3, kernel = 8)
    check (un, reset) == (0'i64, "")
    discard step(@[("192.0.2.30", 4'i64)], 5, control = 3, kernel = 8)
    check (un, reset) ==
      (0'i64, "the destination 192.0.2.31 (6 packet(s)) left its set")
    # A count that went down at a check that could not read the counter:
    # the next check that reads it starts over, and reports nothing for
    # the gap the reset opened.
    discard step(@[("192.0.2.30", 1'i64)], -1, control = 3)
    check reset == "the count of 192.0.2.30 fell from 4 to 1"
    check "starting-over 1" in readFile(st)
    discard step(@[("192.0.2.30", 1'i64)], 6, control = 3, kernel = 9)
    check (un, reset) == (0'i64, "")
    check "starting-over" notin readFile(st)
    discard step(@[("192.0.2.30", 1'i64)], 7, control = 3, kernel = 10)
    check (un, reset) == (1'i64, "")
    # A reload is a new instance, never a reset: lower counts are expected.
    discard step(@[("192.0.2.30", 1'i64)], 1, table = "u", kernel = 1)
    check (un, reset, controlWas) == (0'i64, "", 0'i64)
    # An instance that could not be read is "-" at every load: lower counts
    # there may be a reload's, and are not called a reset.
    discard step(@[("192.0.2.30", 5'i64)], 5, table = "-", kernel = 5)
    discard step(@[("192.0.2.30", 1'i64)], 1, table = "-", kernel = 1)
    check reset == ""
    # A state written before the counter was kept as the kernel gave it
    # kept the counter less the control's element, which was never above
    # the counter. A counter that grew past it is no reset ...
    let before = EgressStateHeader & "\ntable u\ncheck 9\ncontrol 4\n" &
      "192.0.2.30 1\ncounter refused 50\nunattributed 49\n"
    writeFile(st, before)
    discard step(@[("192.0.2.30", 1'i64)], 51, table = "u", control = 4,
                 kernel = 55)
    check (un, reset) == (1'i64, "")
    # ... and one below it has fallen: a host whose counter was reset
    # before the upgrade starts over at its first check, and counts the
    # three packets no set added since.
    writeFile(st, before)
    discard step(@[("192.0.2.30", 1'i64)], 0, table = "u", control = 4,
                 kernel = 3)
    check (un, reset) ==
      (3'i64, "the counter of refused packets fell from 50 to 3")
    discard step(@[("192.0.2.30", 1'i64)], 0, table = "u", control = 4,
                 kernel = 2)
    check reset == "the counter of refused packets fell from 3 to 2"
    # It is printed by the check, and is no detection of its own (an open
    # owner decision: reprobuild-pm issue
    # 2026-11-19-addon-egress-counter-reset-is-not-a-detection.md).
    writeFile(root / "evidence.conf", "sink = 127.0.0.1:1\n")
    let site = EvidenceSite(stateDir: root / "sr", dir: root / "evr",
      outbox: root / "evr" / "outbox", confPath: root / "evidence.conf",
      attestationKey: root / "none", host: "h", journal: false)
    recordEgressCheck(EgressCheck(present: true, counterReset: reset), site,
                      30_000)
    check toSeq(walkFiles(site.dir / "*.json")).len == 0

  test "a reset of the sets is no shortfall, and an unread instance no match":
    # Reprobuild-pm issue
    # 2026-11-21-addon-egress-check-reports-packets-a-set-held-after-a-set-reset-and-compares-two-unread-instances.md.
    # ``nft reset set`` zeroes the elements' counts (confirmed on nft 1.1.6
    # in ``unshare -rn``); an element sent more packets since than it held
    # before shows no fall, so the reset is not seen. Red under
    # ``egress-shortfall-while-set-not-full`` (cases 1 and 3),
    # ``egress-reset-bound-ignores-set-reset`` (the full-set variants of
    # case 1) and ``egress-unread-instance-compared`` (case 2).
    var un = -1'i64
    var reset = "?"
    proc step(st: string; refused: seq[RefusedDestination]; counted: int64;
              full: bool; table = "t"): seq[RefusedDestination] =
      freshSince(refused, st, table, counted, addr un, kernelCounted = counted,
                 counterReset = addr reset, setFull = full)
    # 1. The counter and the set reset in one interval, then ten packets to
    # 192.0.2.1, which the set (not full) added: none is unattributed,
    # though 192.0.2.1 outgrew its old count of five.
    block:
      let st = root / "state-set-reset-1"
      discard step(st, @[("192.0.2.1", 5'i64), ("192.0.2.2", 995'i64)], 1000,
                   false)
      check un == 0
      discard step(st, @[("192.0.2.1", 10'i64), ("192.0.2.2", 0'i64)], 10,
                   false)
      check un == 0
      check reset.startsWith("the counter of refused packets fell from 1000 to 10")
    # The same with a full set: 192.0.2.2's fall shows the set was reset, so
    # 192.0.2.1 may have gained all ten since the reset. The least provable
    # is the counter less what the set holds: none. (Its gain since the last
    # check, five, read five as unattributed.)
    block:
      let st = root / "state-set-reset-1-full"
      discard step(st, @[("192.0.2.1", 5'i64), ("192.0.2.2", 995'i64)], 1000,
                   true)
      discard step(st, @[("192.0.2.1", 10'i64), ("192.0.2.2", 0'i64)], 10,
                   true)
      check un == 0
      # And from there on a packet the full set does not add is counted.
      discard step(st, @[("192.0.2.1", 10'i64), ("192.0.2.2", 0'i64)], 12,
                   true)
      check (un, reset) == (2'i64, "")
    # A full set whose counter fell by less than it holds: the counter's
    # twelve, less the twelve the set holds, is none proven; two more past
    # what the set holds are proven unattributed.
    block:
      let st = root / "state-set-reset-1-proven"
      discard step(st, @[("192.0.2.1", 5'i64), ("192.0.2.2", 995'i64)], 1000,
                   true)
      discard step(st, @[("192.0.2.1", 12'i64), ("192.0.2.2", 0'i64)], 14,
                   true)
      check un == 2
    # A destination that left its set took the packets it was sent since
    # the reset with it: none is proven unattributed. (Its gain since the
    # last check, none, read ten.)
    block:
      let st = root / "state-set-reset-left"
      discard step(st, @[("192.0.2.1", 5'i64), ("192.0.2.2", 995'i64)], 1000,
                   true)
      discard step(st, @[("192.0.2.1", 5'i64)], 10, true)
      check un == 0
      check reset.startsWith("the counter of refused packets fell from 1000 to 10")
    # Only the counter fell, the set kept its counts: the two packets it
    # did not add are still counted at the check that sees the fall.
    block:
      let st = root / "state-counter-reset-only"
      discard step(st, @[("192.0.2.1", 5'i64)], 8, true)
      discard step(st, @[("192.0.2.1", 6'i64)], 3, true)
      check (un, reset) ==
        (2'i64, "the counter of refused packets fell from 8 to 3")
    # 3. The set reset and outgrown, the counter not: counter 100 and
    # 192.0.2.1 100, then 150 packets to it. Nothing fell, and a set that
    # is not full added all of them. The gap is no shortfall, and is not
    # reported once the set is full either; three packets the full set
    # does not add are.
    block:
      let st = root / "state-set-reset-3"
      discard step(st, @[("192.0.2.1", 100'i64)], 100, false)
      discard step(st, @[("192.0.2.1", 150'i64)], 250, false)
      check (un, reset) == (0'i64, "")
      discard step(st, @[("192.0.2.1", 150'i64)], 253, true)
      check (un, reset) == (3'i64, "")
    # 2. Two checks that could not read the table's instance, a reload
    # between them: the second compares nothing with the first. 192.0.2.1
    # is recorded again, and the new instance's shortfall is reported whole
    # (the first's eleven hid all but one of its twelve).
    block:
      let st = root / "state-unread-twice"
      check step(st, @[("192.0.2.1", 9'i64)], 20, true, table = "-") ==
        @[("192.0.2.1", 9'i64)]
      check un == 11
      check step(st, @[("192.0.2.1", 3'i64)], 15, true, table = "-") ==
        @[("192.0.2.1", 3'i64)]
      check (un, reset) == (12'i64, "")
      # A readable instance after it compares nothing with it either.
      check step(st, @[("192.0.2.1", 3'i64)], 15, true, table = "v") ==
        @[("192.0.2.1", 3'i64)]

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
      "if [ -e " & quoteShell(dir / "churn") & " ]; then h=$n; fi\n" &
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
      # Nor does a healthy table's counter, read amid datagrams, ever read
      # as one that went down.
      check c.counterReset == ""
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
    check r.counterReset == ""
    # A reload at every attempt (a new handle at every read): the check
    # gives up on the counter, and keys what it read to no instance, since
    # its sets may be an earlier instance's. Keyed to the newest one, the
    # next check read that instance's lower counts as a change in place and
    # reported none of its unattributed packets.
    writeFile(dir / "churn", "")
    let g = checkEgress(fake, st)
    check g.error.len == 0
    check g.counted == -1
    check "\ntable -\n" in readFile(st)
    removeFile(dir / "churn")
    let h = checkEgress(fake, st)
    check h.error.len == 0
    check h.counterReset == ""
    check "\ntable -\n" notin readFile(st)

removeDir(root)

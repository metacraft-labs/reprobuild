## Unit tests for the add-on switch's second round of hardening (ReproOS
## Add-On Mode §4.3, §5.2, §7.1, §7.3): exclusive units decided on their
## control group rather than ``ActiveState`` (a ``failed`` unit whose
## process lives on is running), their predecessors (a removed exclusive
## unit, the ``.service`` units ``Conflicts=`` names) and paused triggers
## carried on the transitions, the strict transition parser with the
## ``exclusive`` flag round-tripping, the slice-to-cgroup path systemd
## uses, the sysctl precedence observer over a fixture tree, retention's
## choice of the generations a running unit may run from, the plan id,
## and the mode a managed copy is written with.
##
## *Mocking.* None: pure functions over value types, a fixture sysctl.d
## tree under a temporary directory, and the real writer on real files.
## The behaviour against a real systemd and kernel is the VM gates' job
## (``tests/e2e/addon``).

import std/[os, posix, sets, strutils, tables, unittest]

import repro_elevation/nofollow_write
import repro_elevation/posix_system_driver
import repro_local_store/store
import repro_addon/[addon_apply, host_exec, ledger, store_root, switch, sysctl_precedence,
                    transitions]

proc unitFacts(unit: string; active = true; exclusive = false): UnitFacts =
  UnitFacts(unit: unit, address: "systemUnit:" & unit, owned: true,
            enabled: true, active: active,
            activeState: (if active: "active" else: "inactive"),
            exclusive: exclusive)

proc verbsOf(ts: seq[Transition]): seq[string] =
  for t in ts: result.add($t.verb & " " & t.unit)

suite "exclusive units are decided on their control group (§7.3)":
  test "a failed exclusive unit whose group is populated is stopped and started, never just started":
    var f = unitFacts("v.service", active = false, exclusive = true)
    f.activeState = "failed"
    f.alive = uaPopulated
    f.fileChanged = true
    let ts = planTransitions(@[f])
    check ts.len == 1 and ts[0].verb == tvStopStart and ts[0].exclusive
    check "failed" in ts[0].reason
    # The same unit with an empty group is started.
    f.alive = uaEmpty
    let started = planTransitions(@[f])
    check started.len == 1 and started[0].verb == tvStart

  test "an unknown population counts as alive":
    var f = unitFacts("v.service", active = false, exclusive = true)
    f.alive = uaUnknown
    f.fileChanged = true
    check planTransitions(@[f])[0].verb == tvStopStart

  test "a removed exclusive unit in failed with a live group is stopped (exclusive)":
    var old = unitFacts("old.service", active = false, exclusive = true)
    old.removed = true
    old.activeState = "failed"
    old.alive = uaPopulated
    var successor = unitFacts("new.service", active = false, exclusive = true)
    successor.isNew = true
    successor.fileChanged = true
    let ts = planTransitions(@[old, successor])
    check ts.len == 2
    check ts[0].verb == tvStop and ts[0].unit == "old.service" and ts[0].exclusive
    check ts[1].verb == tvStart and ts[1].predecessors == @["old.service"]
    check "after confirming old.service exited" in ts[1].reason

  test "a non-exclusive failed unit is still judged by ActiveState":
    var f = unitFacts("plain.service", active = false)
    f.removed = true
    f.alive = uaPopulated
    check planTransitions(@[f]).len == 0

  test "Conflicts= names the predecessors, services only":
    let content = "[Unit]\nDescription=x\nConflicts=old.service shutdown.target\n" &
      "Conflicts=older.service\n\n[Service]\nConflicts=ignored.service\n"
    check conflictsServices(content, "n.service") == @["old.service", "older.service"]
    var f = unitFacts("n.service", active = false, exclusive = true)
    f.isNew = true
    f.fileChanged = true
    f.predecessors = conflictsServices(content, "n.service")
    check planTransitions(@[f])[0].predecessors == @["old.service", "older.service"]

  test "Conflicts= follows systemd's syntax: drop-ins, resets, continuations, specifiers":
    let content = "[Unit]\nConflicts=a.service \\\n  b.service\n"
    check conflictsServices(content, "n.service") == @["a.service", "b.service"]
    # A drop-in adds, and an empty assignment resets what came before.
    check conflictsServices(content, "n.service",
      ["[Unit]\nConflicts=c.service\n"]) == @["a.service", "b.service", "c.service"]
    check conflictsServices(content, "n.service",
      ["[Unit]\nConflicts=\nConflicts=d.service\n"]) == @["d.service"]
    # Instance specifiers expand against the unit's own name.
    check conflictsServices("[Unit]\nConflicts=old-%i.service %p-legacy@%i.service\n",
      "val@k1.service") == @["old-k1.service", "val-legacy@k1.service"]
    # An unsupported specifier fails closed.
    expect ConflictsParseError:
      discard conflictsServices("[Unit]\nConflicts=%H.service\n", "n.service")

  test "a stop-start carries the active triggers it pauses":
    var f = unitFacts("s.service", exclusive = true)
    f.alive = uaPopulated
    f.fileChanged = true
    f.triggers = @["s.socket"]
    let ts = planTransitions(@[f])
    check ts[0].verb == tvStopStart and ts[0].triggers == @["s.socket"]
    check "pauses s.socket" in ts[0].reason

suite "stops and restarts propagate along PartOf=/BindsTo= (§7.3)":
  test "an exclusive PartOf= dependent of a restarted unit is a confirmed stop-start after it":
    var x = unitFacts("x.service")
    x.fileChanged = true
    x.dependents = @["e.service"]
    var e = unitFacts("e.service", exclusive = true)
    e.alive = uaPopulated
    let ts = planTransitions(@[x, e])
    check verbsOf(ts) == @["restart x.service", "stop-start e.service"]
    check ts[1].exclusive and "propagating dependency" in ts[1].reason
  test "a dependent of a stop-start unit is started again after it":
    var x = unitFacts("x.service", exclusive = true)
    x.alive = uaPopulated
    x.fileChanged = true
    x.dependents = @["d.service"]
    let d = unitFacts("d.service")
    let ts = planTransitions(@[x, d])
    check verbsOf(ts) == @["stop-start x.service", "stop-start d.service"]
    check verbsOf(startEntries(ts)) == @["stop-start x.service", "stop-start d.service"]
  test "a removed unit's dependents stop with it, transitively; a held restart cannot hold":
    var x = unitFacts("x.service")
    x.removed = true
    x.dependents = @["d.service"]
    var d = unitFacts("d.service")
    d.dependents = @["d2.service"]
    let d2 = unitFacts("d2.service")
    check verbsOf(planTransitions(@[x, d, d2])) ==
      @["stop x.service", "stop d.service", "stop d2.service"]
    var y = unitFacts("y.service")
    y.fileChanged = true
    y.dependents = @["h.service"]
    var h = unitFacts("h.service")
    h.fileChanged = true
    h.restartHeld = true
    check verbsOf(planTransitions(@[y, h])) ==
      @["restart y.service", "stop-start h.service"]
  test "Requires= (RequiredBy) and a path through a target propagate; PropagatesStopTo stops":
    var x = unitFacts("x.service")
    x.fileChanged = true
    x.dependents = @["t.target"]
    x.stopDependents = @["s.service"]
    var t = unitFacts("t.target")
    t.dependents = @["e.service"]
    var e = unitFacts("e.service", exclusive = true)
    e.alive = uaPopulated
    let s = unitFacts("s.service")
    let ts = planTransitions(@[x, t, e, s])
    check "restart x.service" in verbsOf(ts)
    check "stop-start e.service" in verbsOf(ts)    # through the target
    check "stop s.service" in verbsOf(ts)          # PropagatesStopTo: stopped, not restarted
    check verbsOf(ts).len == 3                     # the target itself is not planned
    for tr in ts:
      if tr.unit == "e.service": check "t.target" in tr.reason and tr.exclusive

  test "an inactive dependent is left alone":
    var x = unitFacts("x.service")
    x.fileChanged = true
    x.dependents = @["d.service"]
    check verbsOf(planTransitions(@[x, unitFacts("d.service", active = false)])) ==
      @["restart x.service"]

suite "the transition section parses strictly (§7.1)":
  test "exclusive round-trips":
    var f = unitFacts("v.service", exclusive = true)
    f.alive = uaPopulated
    f.fileChanged = true
    var r = unitFacts("old.service")
    r.removed = true
    let ts = planTransitions(@[r, f])
    let back = parseTransitions("ledger diff: no change\n" & renderTransitions(ts))
    check back.len == ts.len
    for i in 0 ..< ts.len:
      check back[i].unit == ts[i].unit and back[i].verb == ts[i].verb and
        back[i].exclusive == ts[i].exclusive and back[i].reason == ts[i].reason
    check back[1].exclusive and not back[0].exclusive

  test "an unknown verb is an error, never `leave`":
    expect TransitionParseError:
      discard parseTransitions("service transitions:\n  bounce\tx.service\twhy\n")

  test "a malformed record or an unknown flag is an error":
    expect TransitionParseError:
      discard parseTransitions("service transitions:\n  start\tx.service\n")
    expect TransitionParseError:
      discard parseTransitions("service transitions:\n  start\tx.service\twhy\tfast\n")

  test "none parses to nothing":
    check parseTransitions("service transitions: none\n").len == 0

suite "cgroup paths":
  test "a group systemd names but that is missing is unknown, not empty":
    let cg = getTempDir() / ("repro-addon-cg-" & $getCurrentProcessId())
    removeDir(cg)
    createDir(cg / "system.slice/up.service")
    writeFile(cg / "cgroup.controllers", "cpu\n")
    writeFile(cg / "system.slice/up.service/cgroup.events", "populated 1\nfrozen 0\n")
    proc props(group: string): Table[string, string] =
      result = {"LoadState": "loaded", "ControlGroup": group,
                "Slice": "system.slice"}.toTable
    check alivenessFrom("up.service", props("/system.slice/up.service"), cg) == uaPopulated
    check alivenessFrom("gone.service", props("/system.slice/gone.service"), cg) == uaUnknown
    # No group named and the would-be group absent: nothing runs.
    check alivenessFrom("idle.service", props(""), cg) == uaEmpty
    # No LoadState, or no unified hierarchy: unknown.
    check alivenessFrom("up.service", {"ControlGroup": "/system.slice/up.service"}.toTable, cg) == uaUnknown
    removeFile(cg / "cgroup.controllers")
    check alivenessFrom("up.service", props("/system.slice/up.service"), cg) == uaUnknown
    removeDir(cg)

  test "slices nest by their dash-separated prefixes":
    check sliceCgroupPath("system.slice") == "system.slice"
    check sliceCgroupPath("a-b-c.slice") == "a.slice/a-b.slice/a-b-c.slice"
    check sliceCgroupPath("-.slice") == ""

let root = getTempDir() / ("repro-addon-round2-" & $getCurrentProcessId())
removeDir(root)

suite "sysctl precedence (§4.3, §7.2 step 6)":
  setup:
    removeDir(root)
    createDir(root / "etc/sysctl.d")
    createDir(root / "usr/lib/sysctl.d")
  test "a later base fragment that sets another value refuses":
    writeFile(root / "etc/sysctl.d/99-zz.conf", "# c\nnet.core.somaxconn = 1234\n")
    let why = sysctlPrecedenceRefusal("net.core.somaxconn", "4096",
      "/etc/sysctl.d/90-repro-net-core-somaxconn.conf", root)
    check "99-zz.conf sets net.core.somaxconn = 1234" in why
  test "the same value, an earlier fragment or a hidden name is no collision":
    writeFile(root / "etc/sysctl.d/99-zz.conf", "net.core.somaxconn =  4096\n")
    writeFile(root / "etc/sysctl.d/10-early.conf", "net.core.somaxconn = 1\n")
    # The /usr/lib copy of a name /etc also has is hidden by /etc's.
    writeFile(root / "usr/lib/sysctl.d/99-zz.conf", "net.core.somaxconn = 7\n")
    check sysctlPrecedenceRefusal("net.core.somaxconn", "4096",
      "/etc/sysctl.d/90-repro-net-core-somaxconn.conf", root) == ""
  test "slash separators and a '-' prefix match; a later glob never beats an explicit setting":
    writeFile(root / "usr/lib/sysctl.d/95-x.conf",
              "-net/ipv4/ip_forward = 0\nnet.ipv4.conf.*.rp_filter = 2\n")
    check sysctlPrecedenceRefusal("net.ipv4.ip_forward", "1",
      "/etc/sysctl.d/90-repro-net-ipv4-ip_forward.conf", root).len > 0
    check sysctlPrecedenceRefusal("net.ipv4.conf.all.rp_filter", "1",
      "/etc/sysctl.d/90-repro-net-ipv4-conf-all-rp_filter.conf", root) == ""
  test "a VLAN interface's key keeps its dot (systemd's first-separator rule)":
    check sysctlNormalize("net.ipv4.conf.eth0/100.forwarding") == "net/ipv4/conf/eth0.100/forwarding"
    check sysctlNormalize("net/ipv4/conf/eth0.100/forwarding") == "net/ipv4/conf/eth0.100/forwarding"
    check sysctlKeyPath("net.ipv4.ip_forward") == "/proc/sys/net/ipv4/ip_forward"
    check sysctlFingerprintKey("net/ipv4/conf/eth0.100/forwarding") == "net.ipv4.conf.eth0.100.forwarding"
    writeFile(root / "usr/lib/sysctl.d/95-v.conf", "net/ipv4/conf/eth0.100/forwarding = 0\n")
    check sysctlPrecedenceRefusal("net.ipv4.conf.eth0/100.forwarding", "1",
      "/etc/sysctl.d/90-repro-v.conf", root).len > 0
    check sysctlPrecedenceRefusal("net.ipv4.conf.eth0.100.forwarding", "1",
      "/etc/sysctl.d/90-repro-v.conf", root) == ""
  test "/etc/sysctl.conf counts as later, once even when linked from sysctl.d":
    writeFile(root / "etc/sysctl.conf", "net.ipv4.ip_forward=0\n")
    discard symlink(cstring("../sysctl.conf"), cstring(root / "etc/sysctl.d/99-sysctl.conf"))
    let later = laterAssignments("net.ipv4.ip_forward",
      "/etc/sysctl.d/90-repro-net-ipv4-ip_forward.conf", root)
    check later.len == 1
  test "only the add-on's own fragment is skipped, by its exact name":
    writeFile(root / "etc/sysctl.d/90-repro-net-core-somaxconn.conf", "net.core.somaxconn = 4096\n")
    writeFile(root / "etc/sysctl.d/90-repro-zz.conf", "net.core.somaxconn = 1\n")
    check "90-repro-zz.conf" in sysctlPrecedenceRefusal("net.core.somaxconn", "4096",
      "/etc/sysctl.d/90-repro-net-core-somaxconn.conf", root)
  test "networkd's forwarding settings refuse a forwarding key while networkd is in use":
    createDir(root / "run/systemd/network")
    createDir(root / "usr/lib/systemd/network")
    createDir(root / "run/systemd/netif/links")
    writeFile(root / "run/systemd/network/10-eth.network", "[Match]\nName=eth0\n[Network]\nIPForward=yes\n")
    # A shipped template that matches no link configures nothing.
    writeFile(root / "usr/lib/systemd/network/80-container-ve.network",
              "[Match]\nName=ve-*\n[Network]\nIPMasquerade=both\n")
    check networkdRefusal("net.ipv4.ip_forward", "0", true, root) == ""
    writeFile(root / "run/systemd/netif/links/2",
              "ADMIN_STATE=configured\nNETWORK_FILE=/run/systemd/network/10-eth.network\n")
    # Only a value networkd would overwrite is refused, per family.
    check "IPForward=yes" in networkdRefusal("net.ipv4.ip_forward", "0", true, root)
    check networkdRefusal("net.ipv4.ip_forward", "1", true, root) == ""
    check "80-container-ve" notin networkdRefusal("net.ipv4.ip_forward", "0", true, root)
    check networkdRefusal("net.ipv4.ip_forward", "0", false, root) == ""
    check networkdRefusal("net.core.somaxconn", "1", true, root) == ""
    check networkdRefusal("net.ipv6.conf.all.forwarding", "0", true, root).len > 0
    # networkd >= 256 ignores IPForward= (deprecated); before 256 it only
    # ever turns forwarding on.
    check networkdRefusal("net.ipv4.ip_forward", "0", true, root, 255).len > 0
    check networkdRefusal("net.ipv4.ip_forward", "0", true, root, 257) == ""
    writeFile(root / "run/systemd/network/10-eth.network",
              "[Match]\nName=eth0\n[Network]\nIPv6Forwarding=yes\n")
    # A per-link setting (>= 256) writes the link's own key only; before
    # 256 the key does not exist.
    check networkdRefusal("net.ipv6.conf.all.forwarding", "0", true, root, 257) == ""
    check networkdRefusal("net.ipv6.conf.all.forwarding", "0", true, root, 252) == ""
  test "IPForward=no never turns forwarding off (networkd before 256)":
    createDir(root / "run/systemd/network")
    createDir(root / "run/systemd/netif/links")
    writeFile(root / "run/systemd/network/10-eth.network",
              "[Match]\nName=eth0\n[Network]\nIPForward=no\n")
    writeFile(root / "run/systemd/netif/links/2",
              "ADMIN_STATE=configured\nNETWORK_FILE=/run/systemd/network/10-eth.network\n")
    for v in [0, 252, 255, 256, 257, 258]:
      check networkdRefusal("net.ipv4.ip_forward", "1", true, root, v) == ""
      check networkdRefusal("net.ipv6.conf.all.forwarding", "1", true, root, v) == ""
    # A drop-in of the file in use counts like the file.
    createDir(root / "etc/systemd/network/10-eth.network.d")
    writeFile(root / "etc/systemd/network/10-eth.network.d/50-fwd.conf",
              "[Network]\nIPForward=ipv4\n")
    check "50-fwd.conf" in networkdRefusal("net.ipv4.ip_forward", "0", true, root, 252)
    check networkdRefusal("net.ipv6.conf.all.forwarding", "0", true, root, 252) == ""
    check networkdRefusal("net.ipv4.ip_forward", "0", true, root, 256) == ""
  test "networkd.conf's IPv4Forwarding= is global from 256 on, either way":
    createDir(root / "etc/systemd/networkd.conf.d")
    writeFile(root / "etc/systemd/networkd.conf.d/50-fwd.conf",
              "[Network]\nIPv4Forwarding=no\n")
    check "IPv4Forwarding=no" in networkdRefusal("net.ipv4.ip_forward", "1", true, root, 257)
    check "IPv4Forwarding=no" in networkdRefusal("net.ipv4.conf.all.forwarding", "1", true, root, 256)
    check networkdRefusal("net.ipv4.ip_forward", "0", true, root, 257) == ""
    check networkdRefusal("net.ipv6.conf.all.forwarding", "1", true, root, 257) == ""
    # Before 256 networkd.conf has no forwarding setting.
    check networkdRefusal("net.ipv4.ip_forward", "1", true, root, 252) == ""
    check networkdRefusal("net.ipv4.ip_forward", "1", true, root, 255) == ""
    # Unknown version: whatever either behaviour would overwrite.
    check networkdRefusal("net.ipv4.ip_forward", "1", true, root, 0).len > 0
  test "IPMasquerade= turns the global knob on before 256 and from 257 when networkd.conf is silent":
    createDir(root / "run/systemd/network")
    createDir(root / "run/systemd/netif/links")
    writeFile(root / "run/systemd/network/10-eth.network",
              "[Match]\nName=eth0\n[Network]\nIPMasquerade=ipv4\n")
    writeFile(root / "run/systemd/netif/links/2",
              "ADMIN_STATE=configured\nNETWORK_FILE=/run/systemd/network/10-eth.network\n")
    check networkdRefusal("net.ipv4.ip_forward", "0", true, root, 252).len > 0
    check networkdRefusal("net.ipv4.ip_forward", "0", true, root, 256) == ""
    check networkdRefusal("net.ipv4.ip_forward", "0", true, root, 257).len > 0
    check networkdRefusal("net.ipv6.conf.all.forwarding", "0", true, root, 257) == ""
    createDir(root / "etc/systemd/networkd.conf.d")
    writeFile(root / "etc/systemd/networkd.conf.d/50-fwd.conf",
              "[Network]\nIPv4Forwarding=no\n")
    # networkd.conf decides: masquerade no longer sets the global knob.
    check networkdRefusal("net.ipv4.ip_forward", "0", true, root, 257) == ""
  test "a per-link key of a link networkd manages is refused, whatever it is":
    createDir(root / "run/systemd/netif/links")
    createDir(root / "sys/class/net/eth0")
    createDir(root / "sys/class/net/eth1")
    writeFile(root / "sys/class/net/eth0/ifindex", "2\n")
    writeFile(root / "sys/class/net/eth1/ifindex", "3\n")
    writeFile(root / "run/systemd/netif/links/2",
              "ADMIN_STATE=configured\nNETWORK_FILE=/run/systemd/network/10-eth.network\n")
    check networkdManagedLinks(root) == @["eth0"]
    check "manages eth0" in networkdRefusal("net.ipv6.conf.eth0.accept_ra", "0", true, root)
    check "manages eth0" in networkdRefusal("net/ipv4/conf/eth0/rp_filter", "1", true, root)
    check networkdRefusal("net.ipv6.conf.eth1.accept_ra", "0", true, root) == ""
    check networkdRefusal("net.ipv4.conf.all.rp_filter", "1", true, root) == ""

suite "retention keeps what running units use (§5.2)":
  test "the invocation table follows instances, not clocks":
    let table = {"inv-old": "g1"}.toTable
    let running = @[
      RunningUnit(unit: "held.service", definition: "d2", invocationId: "inv-old"),
      RunningUnit(unit: "fresh.service", definition: "d2", invocationId: "inv-new"),
      RunningUnit(unit: "outside.service", definition: "d2", invocationId: "inv-out")]
    let before = {"held.service": "inv-old", "fresh.service": "inv-prev",
                  "outside.service": "inv-out"}.toTable
    let t = invocationsAfterSwitch(table, running, before,
      ["fresh.service"].toHashSet, "g5", "g4")
    check t["inv-old"] == "g1"         # kept its instance: what the table said
    check t["inv-new"] == "g5"         # started by this switch
    check t["inv-out"] == "g4"         # started outside a switch: what was on disk
    check t.len == 3                   # entries of ended instances are dropped
    # Started during the switch but not by it: either definition.
    let other = invocationsAfterSwitch(table, running, before,
      initHashSet[string](), "g5", "g4")
    check other["inv-new"] == "g4,g5"
    # No table yet (the first switch after an upgrade): unknown, any.
    let first = invocationsAfterSwitch(initTable[string, string](), running,
      before, ["fresh.service"].toHashSet, "g5", "g4", tableExisted = false)
    check first["inv-old"] == AnyRetainedGeneration
    check first["inv-new"] == "g5"

  test "only a generation that gave the running unit another definition is held":
    proc lookup(id, unit: string): tuple[ledgerFound, unitFound: bool; definition: string] =
      case id
      of "g1": (true, true, "old")        # started it with another definition
      of "g2": (true, true, "new")        # the same definition
      else: (false, false, "")            # no ledger
    let table = {"i1": "g1", "i2": "g2", "i3": "g9", "i4": "g5"}.toTable
    proc held(inv: string): HashSet[string] =
      generationsHeldBy(@[RunningUnit(unit: "u.service", definition: "new",
        invocationId: inv)], table, "g5", lookup)
    check held("i1") == ["g1"].toHashSet
    check held("i2").len == 0
    check held("i3") == ["g9"].toHashSet      # no ledger: kept
    check held("i4").len == 0                 # the current generation
    check held("unknown").len == 0            # started after the last switch
    let t2 = {"both": "g1,g2", "any": AnyRetainedGeneration}.toTable
    check generationsHeldBy(@[RunningUnit(unit: "u.service", definition: "new",
      invocationId: "both")], t2, "g5", lookup) == ["g1"].toHashSet
    check generationsHeldBy(@[RunningUnit(unit: "u.service", definition: "new",
      invocationId: "any")], t2, "g5", lookup, retained = @["g1", "g2", "g5", "g9"]) ==
      ["g1", "g9"].toHashSet

  test "the table is written durably and read back":
    let dir = getTempDir() / ("repro-addon-inv-" & $getCurrentProcessId())
    removeDir(dir)
    createDir(dir)
    writeInvocationTable(dir / "invocations", {"a": "g1", "b": "*"}.toTable)
    check readInvocationTable(dir / "invocations") == {"a": "g1", "b": "*"}.toTable
    var leftovers = 0
    for f in walkDir(dir):
      if extractFilename(f.path) != "invocations": inc leftovers
    check leftovers == 0
    removeDir(dir)

  test "a unit's definition covers its file and its drop-ins":
    var l = Ledger()
    l.entries.add(LedgerEntry(class: lcUnit, unit: "a.service", resource: "r", sha256: "u1",
                              path: "/etc/systemd/system/a.service"))
    l.entries.add(LedgerEntry(class: lcDropIn, unit: "cron.service", resource: "d",
      path: "/etc/systemd/system/cron.service.d/50-repro-x.conf", sha256: "d1"))
    check unitDefinition(l, "a.service") == "unit u1"
    check unitDefinition(l, "cron.service") ==
      "dropIn /etc/systemd/system/cron.service.d/50-repro-x.conf d1"
    check unitDefinition(l, "none.service") == ""

suite "the add-on plan id (§7.1)":
  test "is a digest of the observation records, sensitive to each":
    let a = planIdOf(["unit\tx.service\tactive\tempty\t"])
    check a.len == 32
    check a == planIdOf(["unit\tx.service\tactive\tempty\t"])
    check a != planIdOf(["unit\tx.service\tfailed\tempty\t"])

suite "the managed-file writer (copy form)":
  test "an existing file's setuid/setgid/sticky bits are not carried over; its permission bits are":
    check managedCopyMode(lkFile, 0o6640, 0o644) == 0o640
    check managedCopyMode(lkFile, 0o4755, 0o644) == 0o755
    check managedCopyMode(lkFile, 0o1600, 0o644) == 0o600
    check managedCopyMode(lkAbsent, 0, 0o644) == 0o644
    check managedCopyMode(lkFile, 0o7000, 0o644) == 0o644

removeDir(root)

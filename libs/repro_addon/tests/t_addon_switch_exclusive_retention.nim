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

import std/[os, posix, sets, strutils, unittest]

import repro_elevation/nofollow_write
import repro_elevation/posix_system_driver
import repro_local_store/store
import repro_addon/[addon_apply, store_root, switch, sysctl_precedence,
                    transitions]

proc unitFacts(unit: string; active = true; exclusive = false): UnitFacts =
  UnitFacts(unit: unit, address: "systemUnit:" & unit, owned: true,
            enabled: true, active: active,
            activeState: (if active: "active" else: "inactive"),
            exclusive: exclusive)

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
    check conflictsServices(content) == @["old.service", "older.service"]
    var f = unitFacts("n.service", active = false, exclusive = true)
    f.isNew = true
    f.fileChanged = true
    f.predecessors = conflictsServices(content)
    check planTransitions(@[f])[0].predecessors == @["old.service", "older.service"]

  test "a stop-start carries the active triggers it pauses":
    var f = unitFacts("s.service", exclusive = true)
    f.alive = uaPopulated
    f.fileChanged = true
    f.triggers = @["s.socket"]
    let ts = planTransitions(@[f])
    check ts[0].verb == tvStopStart and ts[0].triggers == @["s.socket"]
    check "pauses s.socket" in ts[0].reason

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
  test "slash separators, a '-' prefix and globs match":
    writeFile(root / "usr/lib/sysctl.d/95-x.conf",
              "-net/ipv4/ip_forward = 0\nnet.ipv4.conf.*.rp_filter = 2\n")
    check sysctlPrecedenceRefusal("net.ipv4.ip_forward", "1",
      "/etc/sysctl.d/90-repro-net-ipv4-ip_forward.conf", root).len > 0
    check sysctlPrecedenceRefusal("net.ipv4.conf.all.rp_filter", "1",
      "/etc/sysctl.d/90-repro-net-ipv4-conf-all-rp_filter.conf", root).len > 0
  test "/etc/sysctl.conf counts as later, once even when linked from sysctl.d":
    writeFile(root / "etc/sysctl.conf", "net.ipv4.ip_forward=0\n")
    discard symlink(cstring("../sysctl.conf"), cstring(root / "etc/sysctl.d/99-sysctl.conf"))
    let later = laterAssignments("net.ipv4.ip_forward",
      "/etc/sysctl.d/90-repro-net-ipv4-ip_forward.conf", root)
    check later.len == 1
  test "the add-on's own fragments are not the base's":
    writeFile(root / "etc/sysctl.d/90-repro-zz.conf", "net.core.somaxconn = 1\n")
    check sysctlPrecedenceRefusal("net.core.somaxconn", "4096",
      "/etc/sysctl.d/90-repro-net-core-somaxconn.conf", root) == ""

suite "retention keeps what running units use (§5.2)":
  proc row(id: string; at: int64): RootRow =
    RootRow(rootId: RootIdPrefix & id, kind: "profile", createdAtUnix: at)
  let rows = @[row("g0", 100), row("g1", 200), row("g2", 300), row("g3", 400)]
  test "a unit started by a generation's step 7 keeps that generation and the one before":
    check generationsUsedAt(rows, 250) == @["g1", "g2"]
  test "a start exactly at a commit and before or after every commit":
    check generationsUsedAt(rows, 300) == @["g2", "g2"]
    check generationsUsedAt(rows, 50) == @["g0"]
    check generationsUsedAt(rows, 500) == @["g3"]

  test "only a generation that gave the running unit another definition is held":
    proc lookup(id, unit: string): tuple[ledgerFound, unitFound: bool; sha256: string] =
      case id
      of "g1": (true, false, "")          # did not carry the unit
      of "g2": (true, true, "old")        # started it with another definition
      of "g3": (true, true, "new")
      else: (false, false, "")            # no ledger
    let held = generationsHeldBy(rows, @[RunningUnit(unit: "u.service",
      sha256: "new", startedAt: @[250'i64])], lookup)
    check held.len == 1 and "g2" in held
    let same = generationsHeldBy(rows, @[RunningUnit(unit: "u.service",
      sha256: "new", startedAt: @[450'i64])], lookup)
    check same.len == 0
    let noLedger = generationsHeldBy(rows, @[RunningUnit(unit: "u.service",
      sha256: "new", startedAt: @[50'i64])], lookup)
    check "g0" in noLedger
    let unknown = generationsHeldBy(rows, @[RunningUnit(unit: "u.service")], lookup)
    check unknown.len == 4

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

## The add-on after the A9 review's round 21 (ReproOS Add-On Mode spec
## §6.2 step 4, §10.1; §13 decision 172 as amended by the owner on
## 2026-11-21, "Drop `-`"; threat model C103 and G55):
##
## - M4: the boot-hold unit's ``ExecStart=`` has no ``-`` prefix, so a kill,
##   a failed exec of the fail-closed ``sleep`` or any other unexpected exit
##   fails the unit; the conservative branch reads ``ls``'s status, so a
##   listing that fails is not "nothing to hold" (the script waits to fail
##   the unit instead);
## - L1: holds lifted while a switch is pending replace the record with a
##   record of none in one rename: the record's name is never deleted
##   while the marker is there;
## - L7: the triggers' start holds are in the boot-hold record before any
##   trigger is stopped;
## - the EnvironmentFile= traversal (reprobuild-pm issue
##   2026-11-05-environment-file-parent-symlink-check-omits-traversed-directories):
##   every directory a resolution passes through is checked, on both sides
##   of every link;
## - M1, M2, M3, L2, L4: the confinement gate's table -- every unit it runs
##   sets every setting the table tries but those it has a stated reason
##   not to; the deny side of the syscall filter, ProtectProc=invisible and
##   an unprivileged unit's RestrictSUIDSGID= each have a row; a kill is a
##   filter's only with SIGSYS.
##
## Falsifying builds, red here: ``boot-hold-dash-prefix``,
## ``boot-hold-ls-failure-ignored``, ``boot-hold-list-write-failure-ignored``
## (round 22), ``boot-hold-clear-record-two-step``,
## ``boot-hold-triggers-before-record``,
## ``environment-file-traversal-lexical``, ``fetch-unit-without-mdwe``.
##
## *Mocking.* The boot-hold script runs in ``boot_hold_sandbox`` (stand-ins
## for ``systemctl``, ``sleep`` and, in its case, ``ls``; see there). The
## traversal walker is given a metadata table (``TraversalProbe``) instead of
## the file system: the metadata it must refuse -- a root-owned link into a
## directory another user may write, root-owned files under it -- cannot be
## made by the unprivileged user the tests run as. The same production
## walker runs on the real file system in the last of its cases, and in
## every ``environmentFileProblem`` call of the floor's other tests. The
## record cases use the real file system and Linux inotify(7) to see each
## change of the record's name. The trigger case passes a ``stop`` closure
## that reads the record as it stands when the stop would run. The VM gates
## ``t_e2e_addon_boot_hold_is_required`` and
## ``t_e2e_addon_confinement_settings_each_hold`` run the unit and the
## table on real guests.

import std/[inotify, os, posix, strutils, tables, tempfiles, unittest]

import repro_infra/start_holds
import repro_addon/addon_apply
import repro_addon/boot_holds
import repro_addon/effective_floor
import repro_addon/generation0
import repro_addon/static_tree

import ../../../tests/e2e/addon/confinement_rows
import ./boot_hold_sandbox

const Exe = "/repro/store/prefixes/repro-addon/0.2.99-aaaaaaaaaaaaaaaa/bin/repro"

suite "A9 review round 21: the boot-hold unit has no `-` (decision 172, 2026-11-21)":
  test "ExecStart= carries no prefix: an unexpected exit fails the unit":
    let u = bootHoldUnit()
    check "ExecStart=/bin/sh -c '" in u
    check "ExecStart=-" notin u
    # Every path the script means ends in ``exit 0`` or the fail-closed
    # wait; nothing in it relies on ``-`` to turn a status into success.
    check "exec /usr/bin/sleep " & $(BootHoldTimeoutSec * 2) in bootHoldScript()
  test "a listing of the units to hold that fails is not nothing to hold":
    let s = setup()
    defer: removeDir(s.tmp)
    for n in ["x.socket", "y.timer"]:
      writeFile(s.etc / n, "[Unit]\n")
    # A pending marker with no record: the script holds conservatively,
    # and the listing it holds from fails.
    s.standIn("ls", "echo ls: cannot open directory >&2\nexit 2")
    let o = run(s)
    checkpoint o
    check "cannot list the units to hold" in o
    check "SLEEP 120" in o
    check "nothing to hold" notin o
    check "systemd reloaded" notin o
    check not dirExists(s.root / "x.socket.d")
  test "a line of the list that cannot be written fails closed (round 22)":
    let s = setup()
    defer: removeDir(s.tmp)
    # The last entry is no activator, so the loop's own status would be 0.
    for n in ["x.socket", "zz.service"]:
      writeFile(s.etc / n, "[Unit]\n")
    createDir(parentDir(s.written))
    # Every write to /dev/full fails (ENOSPC). Under the falsifying build
    # the script goes on to read it, which never ends: bounded.
    createSymlink("/dev/full", parentDir(s.written) / "boot-hold-list")
    let o = run(s, limitSec = 20)
    checkpoint o
    check "cannot list the units to hold" in o
    check "SLEEP 120" in o
    check "nothing to hold" notin o
  test "the same listing that succeeds still holds the activators":
    let s = setup()
    defer: removeDir(s.tmp)
    for n in ["x.socket", "y.timer", "w.service"]:
      writeFile(s.etc / n, "[Unit]\n")
    let o = run(s)
    checkpoint o
    check fileExists(s.root / "x.socket.d" / StartHoldName)
    check fileExists(s.root / "y.timer.d" / StartHoldName)
    check "held 2 unit drop-in directories, systemd reloaded" in o
    check "SLEEP" notin o

proc recordNameEvents(stateDir: string; act: proc ()): seq[tuple[mask: uint32; name: string]] =
  ## The inotify(7) events on the record's directory while ``act`` runs.
  let dir = parentDir(bootHoldRecordPath(stateDir))
  let fd = inotify_init1(O_NONBLOCK)
  doAssert fd >= 0
  defer: discard posix.close(fd)
  doAssert inotify_add_watch(fd, dir.cstring,
    IN_CREATE or IN_DELETE or IN_MOVED_FROM or IN_MOVED_TO) >= 0
  act()
  var buf = newString(65536)
  let n = posix.read(fd, addr buf[0], buf.len)
  if n <= 0: return
  for e in inotify_events(addr buf[0], n):
    result.add((e[].mask, $cast[cstring](addr e[].name)))

suite "A9 review round 21: the record of none replaces the record in one step (L1)":
  test "while the marker is there, the record's name is never deleted":
    let d = createTempDir("a9r21-", "-state")
    defer: removeDir(d)
    writeBootHoldRecord(d, ["/run/systemd/system/a.socket.d/" & StartHoldName])
    writePendingMarker(d, PendingMarker(fromGeneration: "g0", step: ssRealise))
    let rec = extractFilename(bootHoldRecordPath(d))
    let ev = recordNameEvents(d, proc () = clearBootHoldRecord(d))
    checkpoint $ev
    var deleted, replaced = false
    for (m, name) in ev:
      if name == rec and (m and IN_DELETE) != 0: deleted = true
      if name == rec and (m and IN_MOVED_TO) != 0: replaced = true
    check not deleted
    check replaced
    check fileExists(bootHoldRecordPath(d))
    check readFile(bootHoldRecordPath(d)) == ""
  test "without a marker the record goes":
    let d = createTempDir("a9r21-", "-state")
    defer: removeDir(d)
    writeBootHoldRecord(d, ["/run/systemd/system/a.socket.d/" & StartHoldName])
    clearBootHoldRecord(d)
    check not fileExists(bootHoldRecordPath(d))

suite "A9 review round 21: triggers stop only once their holds are recorded (L7)":
  test "each stop finds every trigger's hold in the record":
    let d = createTempDir("a9r21-", "-state")
    defer: removeDir(d)
    let held = [startHoldPath("a.service")]
    writeBootHoldRecord(d, held)
    writePendingMarker(d, PendingMarker(fromGeneration: "g0", step: ssRealise))
    var seen: seq[seq[string]]
    stopTriggersRecorded(d, held, ["a.socket", "a.path"], ["a.socket"],
      proc (t: string) = seen.add(readBootHoldRecord(d)))
    check seen.len == 1
    if seen.len == 1:
      check "a.service.d" in seen[0]
      check "a.socket.d" in seen[0]
      check "a.path.d" in seen[0]
  test "no trigger to hold leaves the record as it is":
    let d = createTempDir("a9r21-", "-state")
    defer: removeDir(d)
    writeBootHoldRecord(d, [startHoldPath("a.service")])
    stopTriggersRecorded(d, [startHoldPath("a.service")], [], [],
      proc (t: string) = discard)
    check readBootHoldRecord(d) == @["a.service.d"]

type FakeFs = object
  meta: Table[string, PathMeta]
  links: Table[string, string]

proc dir(f: var FakeFs; p: string; uid = 0; mode = 0o755) =
  f.meta[p] = (pkDir, uid, mode)
proc file(f: var FakeFs; p: string; uid = 0; mode = 0o644) =
  f.meta[p] = (pkRegular, uid, mode)
proc link(f: var FakeFs; p, target: string; uid = 0) =
  f.meta[p] = (pkLink, uid, 0o777)
  f.links[p] = target

proc probe(f: FakeFs): TraversalProbe =
  let m = f.meta
  let l = f.links
  result.meta = proc (p: string): PathMeta {.closure, gcsafe.} =
    {.cast(gcsafe).}: m.getOrDefault(p, (pkMissing, -1, 0))
  result.readlink = proc (p: string): string {.closure, gcsafe.} =
    {.cast(gcsafe).}: l.getOrDefault(p, "")

proc base(): FakeFs =
  result.dir("/")
  result.dir("/trusted")
  result.dir("/safe")
  result.file("/safe/env")

suite "A9 review round 21: every directory a resolution passes through is checked":
  test "a directory reached through a link in the middle of the path":
    # /trusted/alias -> /mutable; /mutable/env is root's, /mutable is not.
    var f = base()
    f.dir("/mutable", mode = 0o777)
    f.file("/mutable/env")
    f.link("/trusted/alias", "/mutable")
    let (why, _) = ownedTraversal("/trusted/alias/env", probe(f))
    checkpoint why
    check "/mutable" in why and "writable" in why
  test "a directory a link's own target passes through, though it ends somewhere safe":
    # /trusted/link -> /mutable/alias/env, /mutable/alias -> /safe: the
    # file is /safe/env, but whoever writes /mutable can swap the alias.
    var f = base()
    f.dir("/mutable", uid = 1000)
    f.link("/mutable/alias", "/safe")
    f.link("/trusted/link", "/mutable/alias/env")
    let (why, _) = ownedTraversal("/trusted/link", probe(f))
    checkpoint why
    check "/mutable" in why and "not owned by root" in why
  test "the safe companions resolve, to the file they name":
    var f = base()
    f.link("/trusted/alias", "/safe")
    f.link("/trusted/link", "/trusted/alias/env")
    f.link("/trusted/rel", "../safe/env")
    check ownedTraversal("/trusted/alias/env", probe(f)) == ("", "/safe/env")
    check ownedTraversal("/trusted/link", probe(f)) == ("", "/safe/env")
    check ownedTraversal("/trusted/rel", probe(f)) == ("", "/safe/env")
    check ownedTraversal("/safe/env", probe(f)) == ("", "/safe/env")
  test "a link another user owns, a loop, a dangling link, a file as a directory":
    var f = base()
    f.link("/trusted/theirs", "/safe/env", uid = 1000)
    f.link("/trusted/a", "/trusted/b")
    f.link("/trusted/b", "/trusted/a")
    f.link("/trusted/gone", "/nowhere/env")
    check "the link /trusted/theirs is not owned by root" in
      ownedTraversal("/trusted/theirs", probe(f)).problem
    check "more than " & $MaxTraversalLinks & " links" in
      ownedTraversal("/trusted/a", probe(f)).problem
    check "/nowhere" in ownedTraversal("/trusted/gone", probe(f)).problem
    check "is not a directory" in ownedTraversal("/safe/env/x", probe(f)).problem
    check "not absolute" in ownedTraversal("safe/env", probe(f)).problem
  test "the root and a writable directory above the file":
    var f = base()
    f.dir("/", mode = 0o777)
    check "its directory / " in ownedTraversal("/safe/env", probe(f)).problem
    var g = base()
    g.dir("/safe", mode = 0o775)
    check "/safe is writable" in ownedTraversal("/safe/env", probe(g)).problem
  test "on the real file system: a directory not closed to others is refused by name":
    let d = createTempDir("a9r21-", "-walk")
    defer: removeDir(d)
    writeFile(d / "env", "A=1\n")
    createSymlink(d, d & "-alias")
    defer: removeFile(d & "-alias")
    let (why, _) = ownedTraversal(d & "-alias/env")
    checkpoint why
    # The first such directory on the way: the temporary root (sticky and
    # writable by all) or the test user's own.
    check "its directory " in why
    # Under root's own directories: the last component is what is missing.
    check "it does not exist" in ownedTraversal("/etc/a9r21-no-such-file").problem
    check ownedTraversal("/etc").problem == ""

proc ownUnits(): seq[(string, string)] =
  for o in generation0Objects(Gen0Inputs(reproExe: Exe,
      agent: AgentUnitsInputs(target: "https://deploy.example/h",
        sources: @["https://deploy.example/m"], allowedAddresses: @["192.0.2.1"]),
      evidence: EvidenceUnitsInputs(sinkAddress: "192.0.2.7:7443"))):
    if o.kind == ookUnit and o.unit.endsWith(".service"):
      result.add((o.unit, o.content))

# ``GateUnits`` is ``confinement_rows``': the gate's own list (round 22).

suite "A9 review round 21: the confinement table (M1, M2, M3, L2, L4)":
  let units = ownUnits()
  proc unit(name: string): string =
    for (n, c) in units:
      if n == name: return c
    ""
  test "every unit the gate runs sets every setting the table tries, but those it has a reason not to":
    for u in GateUnits:
      let text = unit(u)
      checkpoint u
      check text.len > 0
      check missingSettings(u, text).len == 0
      checkpoint u & " lacks " & missingSettings(u, text).join(", ")
  test "the gate's units are every service unit generation 0 renders but the egress check's":
    # A unit added to generation 0 is in the gate, or named here as not.
    const NotRun = ["repro-addon-egress-check.service"]
    for (n, _) in units:
      checkpoint n
      check n in GateUnits or n in NotRun
    for u in PrivilegedUnits: check u in GateUnits
  test "each reason not to set a setting names a unit the gate runs":
    for (u, k, why) in UnsetByDesign:
      check u in GateUnits
      check why.len > 0
      check k notin expectedSettings(u)
  test "the deny side of the filter: REMOVED drops only the ~ line":
    let apply = unit("repro-agent-apply.service")
    let fetch = unit("repro-agent-fetch.service")
    for row in ProbeRows:
      if not row.denyLinesOnly: continue
      check rowApplies(row, apply, true).ok
      check rowApplies(row, fetch, true).ok
      # The boot-hold unit's filter is the allow list alone.
      check not rowApplies(row, unit("repro-addon-boot-hold.service"), true).ok
      let r = removedLines(row, apply)
      check r[0] == "SystemCallFilter="
      for l in r[1 .. ^1]:
        check not l.startsWith("SystemCallFilter=~")
        check ("\n" & l & "\n") in apply
      check r.len == 3          # the allow line and the one that adds back
      check removedLines(row, fetch) == @["SystemCallFilter=",
                                          "SystemCallFilter=@system-service"]
  test "ProtectProc=invisible is tried where it can be seen":
    for row in ProbeRows:
      if row.name != "protect-proc": continue
      for u in ["repro-agent-fetch.service", "repro-addon-evidence.service"]:
        checkpoint u
        check rowApplies(row, unit(u), true).ok
      # Root is unaffected by it, whatever its bounding set.
      for u in ["repro-agent-apply.service", "repro-addon-boot-hold.service"]:
        let (ok, why) = rowApplies(row, unit(u), true)
        checkpoint u & ": " & why
        check not ok
        check why.startsWith("not observable") and "root is unaffected" in why
  test "an unprivileged unit's RestrictSUIDSGID= has a row of its own":
    var found = false
    for row in ProbeRows:
      if row.name != "restrict-suid-sgid-unprivileged": continue
      found = true
      check rowApplies(row, unit("repro-agent-fetch.service"), true).ok
      check rowApplies(row, unit("repro-addon-evidence.service"), true).ok
      check not rowApplies(row, unit("repro-agent-apply.service"), true).ok
    check found
  test "a kill is the filter's only with SIGSYS":
    check parseOutcome("", "x", "signal", "31").killed
    check parseOutcome("", "x", "core-dump", "31").killed
    check not parseOutcome("", "x", "signal", "15").killed
    check not parseOutcome("", "x", "signal", "9").killed
    check not parseOutcome("", "x", "signal").killed
    check not heldOk(exBlocked, parseOutcome("", "x", "signal", "11"))
  test "a line is the row's probe's only when it names that probe (round 22)":
    # A setup step that failed prints its own name: neither blocked nor
    # let through, so the pair is red whatever it says.
    let setup = parseOutcome("A9PROBE mdwe-setup -1 12", "mdwe", "success")
    check not setup.ran
    check not heldOk(exBlocked, setup)
    check not removedOk(exBlocked, parseOutcome("A9PROBE affinity-setup 0 0",
                                                "affinity", "success"))
    check parseOutcome("A9PROBE mdwe -1 1", "mdwe", "success").ran

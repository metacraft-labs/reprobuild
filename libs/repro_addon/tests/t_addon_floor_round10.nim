## The hardening floor after A9's review round 10 (ReproOS Add-On Mode spec
## §10.1, *Amended 2026-11-07 (A9 adversarial review, round 10)*; §13
## decisions 67 to 70), from the reviewer's probe (``zz_a9rev10_probe``):
##
## - "created for the unit" is provenance alone: the add-on's record of the
##   unit's own start, or the ledger; never ownership (a dynamic id, a root
##   link into ``private/``, the unit's static account); and a unit names
##   only its own stem (decision 67; finding 1);
## - the record is written per unit start, keyed on the directory's
##   identity, dropped once the directory is gone or replaced, and written
##   durably (decision 68; finding 2);
## - the activator's reached units are held to decision 55 by the same walk
##   as the service's (finding 3);
## - every refusal line carries its rule, and the gate counts one without a
##   tag (finding 4);
## - a unit named after a base tree is refused by its name (decision 70).
##
## Falsifying builds: ``ownership-as-provenance``, ``own-names-by-prefix``,
## ``created-dirs-by-path``, ``created-dirs-per-step``,
## ``activator-reach-unchecked``, ``refusal-lines-untagged``,
## ``untagged-lines-skipped``, ``base-tree-units-by-directory``,
## ``created-dirs-not-rerecorded``, and for §13 decision 71, one per
## condition: ``recreated-unrecorded-accepted``, ``recreated-any-path``,
## ``recreated-systemd-unchecked``; and ``accepted-not-rerecorded``; and for
## §13 decision 72: ``migration-reruns``, ``migration-any-path``,
## ``corrupt-record-as-absent``, ``migration-any-unit``.
##
## Mocks: as in ``t_addon_floor_round9``. Real temporary directories, links
## and the real ``lstat`` where the test is about a path's identity or
## owner; a stand-in for PID 1's view only where the host's own paths
## (``/var/lib``) cannot be written by a test.

import std/[os, posix, sets, strutils, tables, tempfiles, unittest]

import repro_infra/profile
import repro_infra/errors
import repro_infra/service_floor
import repro_addon/addon_apply
import repro_addon/effective_floor
import repro_addon/ledger

const
  Prefix = "/repro/store/prefixes/svc/1.0"
  Src = currentSourcePath().parentDir.parentDir / "src" / "repro_addon"
  EffectiveSource = staticRead(Src / "effective_floor.nim")
  ApplySource = staticRead(Src / "addon_apply.nim")
  FloorSource = staticRead(currentSourcePath().parentDir.parentDir.parentDir /
    "repro_infra" / "src" / "repro_infra" / "service_floor.nim")
  ProfileSource = staticRead(currentSourcePath().parentDir.parentDir.parentDir /
    "repro_infra" / "src" / "repro_infra" / "profile.nim")

proc unitStanza(name, service: string; unitExtra = ""; extra = ""): string =
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"[Unit]\n" &
    "Description=x\n" & unitExtra & "\n[Service]\n" & service & "\n[Install]\n" &
    "WantedBy=multi-user.target\n\"\n" & extra & "}\n"

proc rawUnit(name, content: string): string =
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"" &
    content & "\"\n}\n"

proc refused(text: string): string =
  try:
    discard parseAddOnUserProfile(text)
  except ESystemProfileInvalid as e:
    return e.msg
  ""

proc rendered(text: string; name = "a.service"): string =
  for r in parseAddOnUserProfile(text).resources:
    if r.kind == srkSystemdSystemUnit and r.suName == name:
      return renderedSystemUnitContent(r)

let svc = "User=a\nExecStart=" & Prefix & "/bin/svc\n"
let plain = unitStanza("a.service", svc)
let ru = rendered(plain)
let fragment = "/etc/systemd/system/a.service"

proc goodInput(): EffectiveInput =
  var s = parseShow("LoadState=loaded\nUser=a\nDynamicUser=no\n" &
    "FragmentPath=" & fragment & "\n" &
    "SystemCallFilter=read write close openat\n" &
    "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX\n" &
    "StandardInput=null\nStandardOutput=journal\nStandardError=inherit\n" &
    "KeyringMode=private\nSecureBits=0\n")
  for k, vs in floorBlock(ru):
    if k notin ["SystemCallFilter", "NoExecPaths", "ExecPaths",
                "RestrictAddressFamilies"]:
      s[k] = vs[^1]
  var ne: seq[string]
  for l in floorBlock(ru)["NoExecPaths"]: ne.add(l.splitWhitespace())
  s["NoExecPaths"] = ne.join(" ")
  s["ExecPaths"] = floorBlock(ru)["ExecPaths"].join(" ")
  result = EffectiveInput(unit: "a.service", rendered: ru,
    version: FloorVersion, show: s, fragment: fragment,
    denied: toHashSet(["memfd_create", "mount"]), partialShow: true)
  result.uidOf = proc (n: string): int =
    case n
    of "root": 0
    of "a": 1000
    else: -1
  result.groupsOf = proc (n: string): seq[string] = @[n]
  result.gidOf = proc (g: string): int =
    case g
    of "root": 0
    of "a": 1000
    else: -1
  result.inspectFile = proc (p: string): string = ""
  result.inspectPath = proc (p: string; uid: int; dynamic: bool): string = ""
  result.lines["ExecStartEx"] = @["{ path=" & Prefix & "/bin/svc ; argv[]=" &
    Prefix & "/bin/svc ; flags= ; start_time=[n/a] }"]
  result.loaded = @[(path: fragment, content: ru)]

proc problemsOf(e: EffectiveInput): string = effectiveFloorProblems(e).join("\n")

proc withLines(content, unitLines, serviceLines: string): string =
  ## ``content`` (a rendered unit) with ``unitLines`` at the top of
  ## ``[Unit]`` and ``serviceLines`` before the floor's block: the unit as a
  ## generation the parse-time half let through would install it.
  result = content.replace("[Unit]\n", "[Unit]\n" & unitLines)
  result = result.replace(FloorMarker, serviceLines & FloorMarker)

proc existing(paths: openArray[string]): proc (p: string; uid: int; dynamic: bool): string =
  let s = toHashSet(paths)
  result = proc (p: string; uid: int; dynamic: bool): string =
    if p in s: "it exists and belongs to uid 0, not to the unit's own account" else: ""


suite "round 10: the baseline":
  test "a unit that holds its floor has no problem, and parses":
    check problemsOf(goodInput()) == ""
    check refused(plain) == ""

suite "round 10, finding 1 (§13 decision 67): provenance, never ownership":
  test "an existing directory the unit's own account owns is not provenance":
    let d = createTempDir("a9r10-", "-owned")
    defer: removeDir(d)
    check managerPathProblem(d, int(getuid()), false).len > 0
  test "a dynamic id's directory, or a root link into private/, is not either":
    let d = createTempDir("a9r10-", "-dyn")
    defer: removeDir(d)
    createSymlink("private/alloy", d / "alloy")
    # Not root's here, but the dynamic branch is what is under test: no
    # owner of any kind makes a path the unit's.
    check managerPathProblem(d / "alloy", -1, true).len > 0
    check managerPathProblem(d, -1, true).len > 0
  test "only the record, for this unit and this directory, or the ledger":
    let now: PathIdentity = (true, 7'u64, 42'u64, 99'i64)
    let rec = {"/run/a": CreatedDir(unit: "a.service", dev: 7, ino: 42, btime: 99)}.toTable
    check createdForUnit("/run/a", "a.service", now, rec, initHashSet[string]())
    check not createdForUnit("/run/a", "b.service", now, rec, initHashSet[string]())
    check not createdForUnit("/run/b", "a.service", now, rec, initHashSet[string]())
    check createdForUnit("/run/b", "a.service", now, rec, toHashSet(["/run/b"]))
  test "the effective check refuses an owned but unrecorded tree":
    var e = goodInput()
    e.show["RuntimeDirectory"] = "a"
    e.inspectPath = nil               # the real managerPathProblem
    let d = createTempDir("a9r10-", "-run")
    defer: removeDir(d)
    # managerPathProblem reads the real path: stand a directory the test
    # owns in for /run/a through the identity and the inspection.
    e.inspectPath = proc (p: string; uid: int; dynamic: bool): string =
      managerPathProblem(d, int(getuid()), false)
    e.pathIdentity = proc (p: string): PathIdentity = identityOfPath(d)
    check "[rule:existing-tree key:RuntimeDirectory]" in problemsOf(e)
    let id = identityOfPath(d)
    e.createdDirs = {"/run/a": CreatedDir(unit: "a.service", dev: id.dev, ino: id.ino, btime: id.btime)}.toTable
    check "[rule:existing-tree" notin problemsOf(e)
  test "a unit names only its own stem":
    check ownNamed("foo", "foo")
    for n in ["foo-bar", "foo.bar", "foo_bar"]:
      checkpoint n
      check not ownNamed("foo", n)
    check "is not" in refused(unitStanza("a.service", "RuntimeDirectory=a-rt\n" & svc))
    check refused(unitStanza("a.service", "RuntimeDirectory=a/rt\n" & svc)) == ""

suite "round 10, finding 2 (§13 decision 68): the record of a unit's own start":
  test "only the started unit's own pending directories are recorded":
    let state = createTempDir("a9r10-", "-state")
    defer: removeDir(state)
    createDir(state / "addon")
    let pa = state / "rt-a"
    let pb = state / "rt-b"
    createDir(pa)
    createDir(pb)          # b's start has not run; something else made it
    recordCreatedDirs(state, "a.service", [(pa, "a.service"), (pb, "b.service")])
    let r = readCreatedDirs(state)
    check r.getOrDefault(pa).unit == "a.service"
    check pb notin r
  test "a recorded directory removed and made again is no longer the unit's":
    let state = createTempDir("a9r10-", "-state")
    defer: removeDir(state)
    createDir(state / "addon")
    let p = state / "rt-a"
    createDir(p)
    recordCreatedDirs(state, "a.service", [(p, "a.service")])
    check createdForUnit(p, "a.service", identityOfPath(p), readCreatedDirs(state),
                         initHashSet[string]())
    let placeholder = state / "keep-inode"
    removeDir(p)
    createDir(placeholder)  # keep the old inode number from being reused at once
    createDir(p)            # another package's tree at the same name
    check not createdForUnit(p, "a.service", identityOfPath(p), readCreatedDirs(state),
                             initHashSet[string]())
    # The next record drops the stale entry.
    recordCreatedDirs(state, "b.service", [])
    removeDir(p)
    recordCreatedDirs(state, "b.service", [])
    check p notin readCreatedDirs(state)
  test "a directory the unit's own restart makes again is recorded again":
    # The confirm-or-revert gate's sequence: the switch restarts a running
    # unit, systemd removes its RuntimeDirectory and makes it again with a
    # new inode; the next apply must still find it the unit's.
    let state = createTempDir("a9r10-", "-state")
    defer: removeDir(state)
    createDir(state / "addon")
    let p = state / "rt-a"
    check startMayCreate(p, "a.service", identityOfPath(p), initTable[string, CreatedDir]())
    createDir(p)
    recordCreatedDirs(state, "a.service", [(p, "a.service")])
    # The next switch's check: it is the unit's recorded directory.
    let rec = readCreatedDirs(state)
    check startMayCreate(p, "a.service", identityOfPath(p), rec)
    check not startMayCreate(p, "b.service", identityOfPath(p), rec)
    # The restart.
    let keep = state / "keep-inode"
    removeDir(p)
    createDir(keep)
    createDir(p)
    recordCreatedDirs(state, "a.service", [(p, "a.service")])
    check createdForUnit(p, "a.service", identityOfPath(p), readCreatedDirs(state),
                         initHashSet[string]())
  test "written with its identity, durably, with no temporary left":
    let state = createTempDir("a9r10-", "-state")
    defer: removeDir(state)
    createDir(state / "addon")
    let p = state / "rt-a"
    createDir(p)
    recordCreatedDirs(state, "a.service", [(p, "a.service")])
    let line = readFile(createdDirsPath(state)).strip(chars = {'\n'})
    check line.split('\t').len == 6
    check not fileExists(createdDirsPath(state) & ".tmp")
    # Round 9's two-field lines carry no identity and record nothing.
    writeFile(createdDirsPath(state), p & "\ta.service\n")
    check readCreatedDirs(state).len == 0
    check "proc writeLines" notin ApplySource
    check "fsync(" in ApplySource

suite "round 10, finding 3: the activator's reached units":
  test "the effective activator check holds them to decision 55":
    let show = parseShow("FragmentPath=/etc/systemd/system/a.timer\n" &
      "Wants=x.target\nTriggers=a.service\n")
    let own = toHashSet(["a.service", "a.timer", "x.target"])
    let p = activatorProblems("a.timer", show, initTable[string, seq[string]](),
      "/etc/systemd/system/a.timer", [], [],
      proc (u: string): seq[string] = @[], own,
      proc (u: string): seq[string] =
        if u == "x.target": @["ssh.service"] else: @[]).join("\n")
    check "x.target (reached from a.timer): Conflicts=ssh.service names" in p
    check "[rule:conflicts key:Conflicts]" in p
  test "the parse-time half refuses the same profile":
    let t = unitStanza("a.service", svc) &
      rawUnit("a.timer", "[Unit]\nWants=x.target\n\n[Timer]\nOnCalendar=daily\n\n[Install]\nWantedBy=timers.target\n") &
      rawUnit("x.target", "[Unit]\nConflicts=ssh.service\n")
    check "names a unit the profile does not define" in refused(t)
  test "the two halves reach the same units from an activator (the counterpart)":
    let t = unitStanza("a.service", svc) &
      rawUnit("a.timer", "[Unit]\nWants=x.target\n\n[Timer]\nOnCalendar=daily\n\n[Install]\nWantedBy=timers.target\n") &
      rawUnit("x.target", "[Unit]\nWants=y.target\n") & rawUnit("y.target", "[Unit]\n")
    let p = parseSystemProfile(t, addOnDefaults = true)
    let parseReach = reachedUnits(["a.timer"],
      proc (u: string): seq[string] = profileStartsOf(p, u)).units
    let show = parseShow("Wants=x.target\nTriggers=a.service\n")
    let own = toHashSet(["a.service", "a.timer", "x.target", "y.target"])
    let effReach = reachedUnits(["a.timer"], depsFrom("a.timer", show,
      proc (u: string): seq[string] = profileStartsOf(p, u), own, triggers = true)).units
    checkpoint "parse " & parseReach.join(" ") & " / effective " & effReach.join(" ")
    check toHashSet(effReach) == toHashSet(parseReach)
    check "y.target" in effReach

suite "round 10, finding 4: no refusal without its rule":
  test "a refusal the check reports itself is tagged":
    check refusalLine("a.service", "show", "-", "x") == "a.service: x [rule:show key:-]"
  test "effectiveFloorCheck adds no untagged line":
    let a = ApplySource.find("proc effectiveFloorCheck*")
    let b = ApplySource.find("\nproc ", a + 10)
    let body = ApplySource[a ..< b]
    var untagged: seq[string]
    var i = body.find("result.add(")
    while i >= 0:
      var depth = 0
      var j = i + "result.add".len
      while j < body.len:
        if body[j] == '(': inc depth
        elif body[j] == ')':
          dec depth
          if depth == 0: break
        inc j
      let stmt = body[i .. min(j, body.len - 1)]
      if "[rule:" notin stmt and "Problems(" notin stmt and "refusalLine(" notin stmt:
        untagged.add(stmt.splitWhitespace().join(" "))
      i = body.find("result.add(", j)
    checkpoint untagged.join("\n")
    check untagged.len == 0
  test "the gate counts a line with no tag, and a refusal that stops every unit":
    let output = "x\nEAddOnFloorNotEffective:\n  a.service: bad [rule:pam key:PAMName]\n" &
      "  b.service: other [rule:limits key:LimitNOFILE]\n" &
      "  the unit search path: gone [rule:search-path key:DropInPaths]\n" &
      "  b.service: no tag here\n  nothing was started\nafter: [rule:zz key:x]\n"
    let codes = refusalRuleCodes(output, "a")
    checkpoint codes.join(" ")
    check "pam" in codes
    check "search-path" in codes
    check "untagged" in codes
    check "limits" notin codes
    check "zz" notin codes

suite "round 10 (§13 decision 70): a unit named after a base tree":
  test "refused by its name, with no directory, in both halves":
    check "is named after ssh" in refused(unitStanza("ssh.service", svc))
    check "is named after udev" in refused(unitStanza("udev@.service", svc))
    var e = goodInput()
    e.unit = "ssh.service"
    check "[rule:unit-name key:Id]" in problemsOf(e)

suite "round 10 (§13 decisions 71 and 77): made again by systemd outside a switch":
  # The record says the add-on's start in a switch made /run/a (identity
  # 1/2, born 50, invocation I1); it is gone and made again (identity 1/3,
  # born 1 ms after Start) by the unit's invocation I2, which began at
  # Start. Times in nanoseconds since the epoch: since round 12 the window
  # before a start is 100 ms (§13 decision 82).
  const Start = 1_794_000_000_000_000_000'i64
  let rec = {"/run/a": CreatedDir(unit: "a.service", dev: 1, ino: 2, btime: 50,
                                  invocation: "I1")}.toTable
  let madeAgain: PathIdentity = (true, 1'u64, 3'u64, Start + 1_000_000)
  proc restarted(): SystemdView =
    SystemdView(dynamicUid: -1, owner: 1000, btime: Start + 1_000_000, ctime: 0,
                invocationId: "I2", invocationStart: Start)
  proc input(dirs = "a"; view = restarted(); r = rec; dynamic = false): EffectiveInput =
    result = goodInput()
    result.show["RuntimeDirectory"] = dirs
    if dynamic:
      result.show["DynamicUser"] = "yes"
      result.show["User"] = "a"
    result.inspectPath = existing(["/run/a"])
    result.pathIdentity = proc (p: string): PathIdentity = madeAgain
    result.createdDirs = r
    let v = view
    result.systemdView = proc (p, u: string; s: ShowProps): SystemdView = v
    result.onRecreated = proc (p, u: string; v: SystemdView): bool = true
  test "a restart outside a switch (Restart=, an operator) is the unit's again":
    var e = input()
    var seen: seq[string]
    e.onRecreated = proc (p, u: string; v: SystemdView): bool =
      seen.add(p & " " & u & " " & v.invocationId)
      true
    check "[rule:existing-tree" notin problemsOf(e)
    check seen == @["/run/a a.service I2"]
  test "so is one its socket or timer made, once a switch recorded it":
    # The same evidence: the directory born after its invocation began.
    check "[rule:existing-tree" notin problemsOf(input())
  test "a directory never recorded stays refused, whatever systemd says":
    check "[rule:existing-tree" in problemsOf(input(r = initTable[string, CreatedDir]()))
  test "condition 1: recorded for this same unit":
    let other = {"/run/a": CreatedDir(unit: "b.service", dev: 1, ino: 2, btime: 50,
                                      invocation: "I1")}.toTable
    check "[rule:existing-tree" in problemsOf(input(r = other))
    check systemdRecreated("/run/a", "a.service", ["/run/a"], other, false,
                           restarted()) == "the record names it for b.service"
  test "condition 2: exactly a directory the unit declares":
    # /run/a is only the parent of the declared a/rt.
    check "[rule:existing-tree" in problemsOf(input(dirs = "a/rt"))
    check systemdRecreated("/run/a", "a.service", ["/run/a/rt"], rec, false,
                           restarted()) == "it is not exactly a directory the unit declares"
  test "condition 3 (§13 decision 77): born no earlier than the invocation":
    var v = restarted()
    v.btime = Start - 500_000_000         # born half a second before it began
    check "[rule:existing-tree" in problemsOf(input(view = v))
    v = restarted()
    v.btime = 0                           # no birth time reported
    check "[rule:existing-tree" in problemsOf(input(view = v))
    v = restarted()
    v.invocationStart = 0                 # no start reported
    check "[rule:existing-tree" in problemsOf(input(view = v))
    # A dynamic user by the same evidence, and no other.
    var d = SystemdView(dynamicUid: 61200, owner: 61200, btime: Start + 1_000_000,
                        invocationId: "I2", invocationStart: Start)
    check "[rule:existing-tree" notin problemsOf(input(view = d, dynamic = true))
    d.btime = Start - 500_000_000
    check "[rule:existing-tree" in problemsOf(input(view = d, dynamic = true))
  test "systemd's view follows its own private/ link and no other":
    let d = createTempDir("a9r10-", "-lib")
    defer: removeDir(d)
    createDir(d / "private")
    createDir(d / "private" / "a")
    createSymlink("private/a", d / "a")
    createSymlink("../etc", d / "b")
    let show = parseShow("DynamicUser=no\n")
    check hostSystemdView(d / "a", "a.service", show).owner == int(getuid())
    check hostSystemdView(d / "a", "a.service", show).btime == birthTimeOf(d / "private" / "a")
    check hostSystemdView(d / "b", "b.service", show).owner == -1
  test "one accepted in this switch is recorded again after its restart":
    # Accepted by decision 71 at the check, then made again by the
    # switch's own restart: the record follows the restart.
    let other: PathIdentity = (true, 9'u64, 9'u64, 9'i64)
    check startMayCreate("/run/a", "a.service", other, rec, ["/run/a"])
    check not startMayCreate("/run/a", "a.service", other, rec, [])
  test "an accepted directory is recorded again under its new identity":
    let state = createTempDir("a9r10-", "-state")
    defer: removeDir(state)
    createDir(state / "addon")
    let p = state / "rt-a"
    createDir(p)
    recordCreatedDirs(state, "a.service", [(p, "a.service")], invocation = "I1")
    check readCreatedDirs(state)[p].invocation == "I1"
    let keep = state / "keep-inode"
    removeDir(p)
    createDir(keep)
    createDir(p)
    acceptRecreated(state, p, "a.service", "I2")
    let r = readCreatedDirs(state)
    check r[p].invocation == "I2"
    check createdForUnit(p, "a.service", identityOfPath(p), r, initHashSet[string]())

suite "round 10 (§13 decision 72): the one-time migration":
  # A host an older engine left: a committed generation without the
  # record-kept marker, a ledger naming its floored unit files, and no
  # record file.
  proc host(declares = "RuntimeDirectory=a\n"): tuple[state, unitFile: string; ledger: Ledger] =
    result.state = createTempDir("a9r10-", "-mig")
    createDir(result.state / "addon")
    result.unitFile = result.state / "a.service"
    writeFile(result.unitFile, "[Service]\n" & declares & FloorMarker & "\nDynamicUser=yes\n")
    result.ledger = Ledger(entries: @[LedgerEntry(class: lcUnit,
      path: result.unitFile, unit: "a.service")])
  let present = proc (paths: openArray[string]): proc (p: string): PathIdentity =
    let s = @paths
    result = proc (p: string): PathIdentity =
      if p in s: (true, 5'u64, uint64(s.find(p) + 10), 99'i64) else: (false, 0'u64, 0'u64, 0'i64)
  proc showing(dirs: string): proc (u: string): ShowProps =
    result = proc (u: string): ShowProps = parseShow("RuntimeDirectory=" & dirs & "\n")
  let inv = proc (u: string): string = "I0"
  let logged = proc (p: string; c: CreatedDir): bool = true
  test "it records the committed unit's declared directory, once, and logs it":
    let h = host()
    defer: removeDir(h.state)
    var seen: seq[string]
    let m = migrateCreatedDirs(h.state, "g1", h.ledger, inv,
      proc (p: string; c: CreatedDir): bool =
        seen.add(p)
        true,
      present(["/run/a"]))
    check m.len == 1
    check m[0].path == "/run/a" and m[0].entry.unit == "a.service" and m[0].entry.ino == 10
    check seen == @["/run/a"]
    check readCreatedDirs(h.state)["/run/a"].invocation == "I0"
  test "it never runs again once the record file exists, even empty":
    let h = host()
    defer: removeDir(h.state)
    check migrateCreatedDirs(h.state, "g1", h.ledger, inv, logged,
                             present([])).len == 0           # nothing to take
    check fileExists(createdDirsPath(h.state))
    check migrateCreatedDirs(h.state, "g1", h.ledger, inv, logged,
                             present(["/run/a"])).len == 0
  test "a corrupt record is present: it fails closed and never starts the migration":
    let h = host()
    defer: removeDir(h.state)
    writeFile(createdDirsPath(h.state), "not a record\n")
    check not createdDirsAbsent(h.state)
    check migrateCreatedDirs(h.state, "g1", h.ledger, inv, logged,
                             present(["/run/a"])).len == 0
    check readFile(createdDirsPath(h.state)) == "not a record\n"
  test "only exactly declared directories, never a parent or a prefix":
    let h = host("RuntimeDirectory=a/rt\n")
    defer: removeDir(h.state)
    # a/rt declared: /run/a is only its parent.
    check migrateCreatedDirs(h.state, "g1", h.ledger, inv, logged,
                             present(["/run/a", "/run/a/rt"]),
                             showOf = showing("a/rt")).len == 0
  test "only units the committed generation installed":
    let h = host()
    defer: removeDir(h.state)
    let m = migrateCreatedDirs(h.state, "g1", h.ledger, inv, logged, present(["/run/b"]),
      showOf = proc (u: string): ShowProps =
        if u == "b.service": parseShow("RuntimeDirectory=b\n") else: parseShow(""),
      alsoUnits = ["b.service"])
    check m.len == 0
  test "not a unit named after a base tree, nor one without the floor":
    let h = host()
    defer: removeDir(h.state)
    writeFile(h.unitFile, "[Service]\nRuntimeDirectory=a\n")     # no floor block
    check migrateCreatedDirs(h.state, "g1", h.ledger, inv, logged,
                             present(["/run/a"])).len == 0
    let h2 = host("RuntimeDirectory=ssh\n")
    defer: removeDir(h2.state)
    let ssh = Ledger(entries: @[LedgerEntry(class: lcUnit, path: h2.unitFile, unit: "ssh.service")])
    check migrateCreatedDirs(h2.state, "g1", ssh, inv, logged,
                             present(["/run/ssh"])).len == 0
  test "with no committed generation it only writes the empty record":
    let h = host()
    defer: removeDir(h.state)
    check migrateCreatedDirs(h.state, "", h.ledger, inv, logged,
                             present(["/run/a"])).len == 0
    check fileExists(createdDirsPath(h.state))
    check readCreatedDirs(h.state).len == 0

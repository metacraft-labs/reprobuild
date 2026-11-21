## The hardening floor after A9's review round 9 (ReproOS Add-On Mode spec
## §10.1, *Amended 2026-11-07 (A9 adversarial review, round 9)*; §13
## decision 57), from the reviewer's probe (``zz_a9rev9_probe``):
##
## - a floored unit's directories are its own, never an existing tree: a
##   unit named after a base tree, every reviewer example, an existing tree
##   not created for the unit, the unit's own directory, and a tree another
##   package installs after the first apply refused at the next (1);
## - one reach for both halves: a test fails if the effective reach differs
##   from the parse-time one (2);
## - every refusal carries its rule and key, and the parse-time rules' rerun
##   does not report a setting a dedicated rule refused (3).
##
## Falsifying builds: ``base-tree-names-allowed``, ``existing-trees-allowed``,
## ``created-dirs-ignored``, ``reach-stops-at-base-units``,
## ``rerun-not-suppressed``, ``implicit-conflicts-refused``,
## ``secrets-read-in-own-namespace``, ``writable-env-judged-twice``.
##
## Mocks: as in ``t_addon_floor_round7``; a host path's existence is a stub
## (``inspectPath``) where the test is about the rule, and real temporary
## directories where it is about the record.

import std/[os, posix, sets, strutils, tables, tempfiles, unittest]

import repro_infra/profile
import repro_infra/errors
import repro_infra/service_floor
import repro_addon/addon_apply
import repro_addon/effective_floor

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

suite "round 9: the baseline":
  test "a unit that holds its floor has no problem, and parses":
    check problemsOf(goodInput()) == ""
    check refused(plain) == ""

suite "round 9, finding 1 (§13 decision 57): never an existing tree":
  const examples = [
    ("systemd.service", "RuntimeDirectory=systemd/system/ssh.service.d"),
    ("systemd@x.service", "RuntimeDirectory=systemd/system/ssh.service.d"),
    ("systemd.service", "ConfigurationDirectory=systemd/system/ssh.service.d"),
    ("systemd.service", "StateDirectory=systemd/x"),
    ("udev.service", "RuntimeDirectory=udev/rules.d"),
    ("tmpfiles.service", "RuntimeDirectory=tmpfiles.d"),
    ("sysctl.service", "RuntimeDirectory=sysctl.d"),
    ("modules-load.service", "RuntimeDirectory=modules-load.d")]
  test "every reviewer example, at parse time":
    for (u, d) in examples:
      checkpoint u & " " & d
      # Round 10 (§13 decision 67): a name longer than the unit's stem is
      # refused by the shape rule before decision 57's list is consulted
      # (modules-load.d for modules-load.service); either refuses it.
      let why = refused(unitStanza(u, d & "\n" & svc))
      check "a tree the base system owns" in why or "named for it" in why
  test "every reviewer example, in the effective check":
    for (u, d) in examples:
      var e = goodInput()
      e.unit = u
      let eq = d.find('=')
      e.show[d[0 ..< eq]] = d[eq + 1 .. ^1]
      checkpoint u & " " & d
      let p = problemsOf(e)
      check "a tree the base system owns" in p or "named for it" in p
  test "a conventional name stays allowed":
    check refused(unitStanza("nginx.service", "RuntimeDirectory=nginx\nStateDirectory=nginx/cache\n" & svc)) == ""
  test "the base trees are the measured ones":
    let dir = currentSourcePath().parentDir / "fixtures" / "base_trees"
    var n = 0
    for kind, f in walkDir(dir):
      inc n
      for l in lines(f):
        if l.len == 0 or l[0] == '#': continue
        let name = l.split('\t')[1]
        if name.startsWith("."): continue
        checkpoint f.extractFilename & ": " & name
        check name in BaseSystemTreeNames
    check n == 4
  test "an existing tree not created for the unit is refused":
    var e = goodInput()
    e.show["RuntimeDirectory"] = "a"
    e.inspectPath = existing(["/run/a"])
    check "it exists and was not created for this unit" in problemsOf(e)
  test "the unit's own existing directory is allowed: recorded for it":
    # Round 10 (§13 decision 67): recorded for this unit and still that
    # directory; ownership alone no longer counts (t_addon_floor_round10).
    let here: PathIdentity = (true, 1'u64, 2'u64, 3'i64)
    var e = goodInput()
    e.show["RuntimeDirectory"] = "a"
    e.inspectPath = existing(["/run/a"])
    e.pathIdentity = proc (p: string): PathIdentity = here
    e.createdDirs = {"/run/a": CreatedDir(unit: "a.service", dev: 1, ino: 2, btime: 3)}.toTable
    check "[rule:existing-tree" notin problemsOf(e)
    e.createdDirs = {"/run/a": CreatedDir(unit: "b.service", dev: 1, ino: 2, btime: 3)}.toTable
    check "it exists and was not created for this unit" in problemsOf(e)
  test "a tree installed after the first apply is refused at the next":
    let state = createTempDir("a9r9-", "-state")
    defer: removeDir(state)
    createDir(state / "addon")
    let created = state / "unit-made"
    let later = state / "package-made"
    # The first apply: both absent at the check; the unit's start creates
    # one of them, and the record is written right after the start.
    createDir(created)
    recordCreatedDirs(state, "a.service", [(created, "a.service"), (later, "a.service")])
    check readCreatedDirs(state).getOrDefault(created).unit == "a.service"
    check later notin readCreatedDirs(state)
    # A package installs the other tree after that; the next apply's check
    # finds it existing and unrecorded.
    createDir(later)
    var e = goodInput()
    e.show["RuntimeDirectory"] = "a"
    e.show["StateDirectory"] = "a"
    e.inspectPath = existing(["/run/a", "/var/lib/a"])
    let rec = readCreatedDirs(state)[created]
    e.pathIdentity = proc (p: string): PathIdentity =
      if p == "/run/a": identityOfPath(created) else: identityOfPath(later)
    e.createdDirs = {"/run/a": rec}.toTable   # recorded at its start
    let p = problemsOf(e)
    check "StateDirectory /var/lib/a: it exists" in p
    check "RuntimeDirectory /run/a:" notin p

suite "round 9, finding 2: one reach for both halves":
  # The profile of the reviewer's probe "r9 C": a floored unit that wants a
  # base target, and a profile target the base target pulls in.
  let text = unitStanza("a.service", svc, "Wants=timers.target\n") &
    rawUnit("x.target", "[Unit]\nConflicts=ssh.service\n\n[Install]\nWantedBy=timers.target\n") &
    "  "
  let profileText = text[0 ..< text.len - 2].replace("WantedBy=timers.target\n\"\n}",
    "WantedBy=timers.target\n\"\n  enabled = true\n}")
  test "the parse-time half refuses it":
    check "names a unit the profile does not define" in refused(profileText)
  test "the effective half refuses it, through the base unit":
    var e = goodInput()
    e.ownUnits = toHashSet(["a.service", "x.target"])
    e.show["Wants"] = "timers.target"
    e.startsOf = proc (u: string): seq[string] =
      if u == "timers.target": @["x.target"] else: @[]
    e.conflictsOf = proc (u: string): seq[string] =
      if u == "x.target": @["shutdown.target", "ssh.service"] else: @[]
    check "x.target (reached from a.service): Conflicts=ssh.service" in problemsOf(e)
  test "the two halves reach the same units (the counterpart)":
    # The effective half's report, simulated from the same profile as
    # systemd builds it: a base unit pulls in the profile units whose
    # [Install] names it; a profile unit starts what its [Unit] names.
    # The same profile without x.target's Conflicts= (which the parse-time
    # half refuses), so it parses and its reach can be compared.
    let p = parseSystemProfile(profileText.replace("Conflicts=ssh.service\n", ""),
                               addOnDefaults = true)
    let parseReach = reachedUnits(["a.service"],
      proc (u: string): seq[string] = profileStartsOf(p, u)).units
    var e = goodInput()
    e.ownUnits = toHashSet(["a.service", "x.target"])
    e.show["Wants"] = "timers.target"
    e.startsOf = proc (u: string): seq[string] =
      if u == "a.service": @[] else: profileStartsOf(p, u)
    checkpoint "parse " & parseReach.join(" ") & " / effective " & effectiveReach(e).join(" ")
    check toHashSet(effectiveReach(e)) == toHashSet(parseReach)
    check "x.target" in parseReach

suite "round 9, finding 3: each refusal names its rule and key":
  test "a dedicated rule, and no rerun beside it":
    var e = goodInput()
    e.show["PAMName"] = "login"
    e.loaded = @[(path: fragment, content: withLines(ru, "", "PAMName=login\n"))]
    let p = problemsOf(e)
    check "[rule:pam key:PAMName]" in p
    check "[rule:parse-rule key:PAMName]" notin p
    check "[rule:file-keys" notin p
  test "the rerun is the backstop for what systemd's report hides":
    var e = goodInput()
    e.loaded = @[(path: fragment, content: withLines(ru, "", "PermissionsStartOnly=yes\n"))]
    check "[rule:file-keys key:PermissionsStartOnly]" in problemsOf(e)
  test "the key of a parse-time refusal":
    check refusedKeyOf("/etc/x.conf, by the floor's rules: a drop-in's [Service] StateDirectory=a is not") == "StateDirectory"
    check refusedKeyOf("by the floor's rules: User=: an empty value") == "User"
    check refusedKeyOf("by the floor's rules: [Unit] OnFailure=reboot.target starts") == "OnFailure"
    check refusedKeyOf("no key here") == ""

suite "round 9: what the delta's VM pilot found":
  test "the Conflicts= systemd adds itself are not the unit's":
    # Every floored unit reaches multi-user.target and through it the
    # add-on's store mount, which carries Conflicts=umount.target.
    var e = goodInput()
    e.ownUnits = toHashSet(["a.service", "repro-store.mount"])
    e.show["Conflicts"] = "shutdown.target"
    e.show["Wants"] = "repro-store.mount"
    e.conflictsOf = proc (u: string): seq[string] =
      if u == "repro-store.mount": @["umount.target"] else: @[]
    check "[rule:conflicts" notin problemsOf(e)
    e.conflictsOf = proc (u: string): seq[string] =
      if u == "repro-store.mount": @["umount.target", "ssh.service"] else: @[]
    check "repro-store.mount (reached from a.service): Conflicts=ssh.service" in problemsOf(e)
  test "an activator's dedicated rule, and no rerun beside it":
    let socket = "[Socket]\nListenStream=127.0.0.1:18091\nMark=1\n"
    let show = parseShow("FragmentPath=/etc/systemd/system/a.socket\nMark=1\n")
    let p = activatorProblems("a.socket", show, initTable[string, seq[string]](),
      "/etc/systemd/system/a.socket", [],
      loaded = [(path: "/etc/systemd/system/a.socket", content: socket)]).join("\n")
    check "[rule:socket-option key:Mark]" in p
    check "[rule:parse-rule" notin p
  test "the service's own secret is read in PID 1's mount namespace":
    # The switch may run in a private namespace where /run/repro/secrets is
    # empty; the check reads the file through PID 1's root. A directory
    # stands in for that root here.
    let root = createTempDir("a9r9-", "-pid1root")
    defer: removeDir(root)
    let path = CredentialRoot & "/a9t-own/env"
    createDir(root & CredentialRoot & "/a9t-own")
    writeFile(root & path, "A=1\n")
    setFilePermissions(root & path, {fpUserRead})
    check not fileExists(path)
    let why = environmentFileProblem(path, service = "a9t-own", hostRoot = root)
    checkpoint why
    check why == (if getuid() == 0: "" else: "it is not owned by root")
  test "a foreign drop-in names its unit and its rule":
    check "[rule:foreign-drop-in key:DropInPaths]" in ApplySource
  test "a listener refused by its rule is not reported again by the rerun":
    let socket = "[Socket]\nListenSpecial=/etc/a9e-target\n"
    let show = parseShow("FragmentPath=/etc/systemd/system/a.socket\n")
    let lines = parseShowLines("Listen=/etc/a9e-target (Special)\n")
    let p = activatorProblems("a.socket", show, lines,
      "/etc/systemd/system/a.socket", [],
      loaded = [(path: "/etc/systemd/system/a.socket", content: socket)]).join("\n")
    check "[rule:listener key:Listen," in p
    check "[rule:parse-rule" notin p
  test "an EnvironmentFile= in a writable place is refused by that rule alone":
    var e = goodInput()
    e.show["EnvironmentFiles"] = "/run/repro/secrets/a/env (ignore_errors=no)"
    e.otherWritable = @["/run/repro/secrets/a"]
    e.inspectFile = proc (p: string): string = "it does not exist (or cannot be read)"
    let p = problemsOf(e)
    check "[rule:environment-file-writable key:EnvironmentFile]" in p
    check "[rule:environment-file key:EnvironmentFile]" notin p

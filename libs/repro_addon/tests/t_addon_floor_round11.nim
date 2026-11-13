## The hardening floor after A9's review round 11 (ReproOS Add-On Mode spec
## §10.1, *Amended 2026-11-08 (A9 adversarial review, round 11)*; §13
## decisions 76 to 78), from the reviewer's probes (``zz_a9rev11_*``):
##
## - a directory's identity is its device, inode and birth time, and on
##   ext4, which hands a freed inode number to the next directory, a
##   directory removed and made again is not the recorded one (decision 76;
##   finding 2);
## - systemd made a recorded directory again only when it was born no
##   earlier than the unit's current invocation, for every user (decision
##   77; finding 3): a tree systemd took over, or one written after the
##   unit started, is not;
## - an activator's listener is named for the service it starts, never for
##   a base tree, never at an existing path not created for it, and the
##   activator itself is never named after a base tree (decision 78;
##   finding 1);
## - a template's instances share its directories, and a unit a dependency
##   started during the switch is recorded by systemd's evidence (finding
##   4);
## - the migration runs only over a generation an older engine wrote, and
##   reads the generation's own files (finding 5);
## - an acceptance or a migration is never made unlogged, and a no-op
##   try-restart records nothing (finding 6).
##
## Falsifying builds: ``identity-without-btime``,
## ``recreated-by-ctime-or-owner``, ``listener-named-for-socket``,
## ``base-tree-activators-allowed``, ``existing-listeners-allowed``,
## ``instances-not-shared``, ``dependency-starts-unrecorded``,
## ``migration-ignores-engine``, ``migration-reads-systemd``,
## ``unlogged-acceptance``, ``unlogged-migration``,
## ``record-after-noop-restart``.
##
## Mocks: as in ``t_addon_floor_round10``. The ext4 test runs on a real ext4
## image (``mkfs.ext4``, mounted by ``fuse2fs`` as the user, both in the
## development shell): it is the allocator under test, so it is not mocked.

import std/[os, osproc, posix, sets, strutils, tables, tempfiles, unittest]

import repro_infra/profile
import repro_infra/errors
import repro_infra/service_floor
import repro_addon/addon_apply
import repro_addon/effective_floor
import repro_addon/ledger
import repro_addon/switch

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



suite "round 11 (§13 decision 76): a directory's identity":
  test "on ext4, a directory removed and made again at the same path is not the unit's":
    let mkfs = findExe("mkfs.ext4")
    let fuse2fs = findExe("fuse2fs")
    checkpoint "mkfs.ext4=" & mkfs & " fuse2fs=" & fuse2fs &
      " (both come with the development shell)"
    require mkfs.len > 0 and fuse2fs.len > 0
    let d = createTempDir("a9r11-", "-ext4")
    defer: removeDir(d)
    let img = d / "img"
    let mnt = d / "mnt"
    createDir(mnt)
    check execCmd(mkfs & " -q -F " & img & " 8M") == 0
    require execCmd(fuse2fs & " " & img & " " & mnt & " -o fakeroot") == 0
    defer: discard execCmd("fusermount3 -u " & mnt & " || fusermount -u " & mnt)
    let state = d / "state"
    createDir(state)
    createDir(state / "addon")
    let p = mnt / "foo"
    createDir(p)
    let before = identityOfPath(p)
    recordCreatedDirs(state, "foo.service", [(p, "foo.service")])
    removeDir(p)
    createDir(p)                      # another tree at the same path
    writeFile(p / "theirs", "x")
    let now = identityOfPath(p)
    checkpoint "inode " & $before.ino & " then " & $now.ino & "; birth " &
      $before.btime & " then " & $now.btime
    check now.ino == before.ino       # ext4 reused the number: the case at issue
    check not createdForUnit(p, "foo.service", now, readCreatedDirs(state),
                             initHashSet[string]())
  test "no birth time, no match: such a directory is neither recorded nor accepted":
    let state = createTempDir("a9r11-", "-state")
    defer: removeDir(state)
    createDir(state / "addon")
    let noBirth = proc (p: string): PathIdentity = (true, 1'u64, 2'u64, 0'i64)
    recordCreatedDirs(state, "a.service", [("/run/a", "a.service")], noBirth)
    check "/run/a" notin readCreatedDirs(state)
    let rec = {"/run/a": CreatedDir(unit: "a.service", dev: 1, ino: 2, btime: 0)}.toTable
    check not createdForUnit("/run/a", "a.service", noBirth("/run/a"), rec,
                             initHashSet[string]())

suite "round 11 (§13 decision 77): systemd made it for this invocation":
  # Recorded at the add-on's start (invocation I1); the unit now runs
  # invocation I2, begun at Start (nanoseconds; the window before a start
  # is 100 ms since round 12, §13 decision 82).
  const Start = 1_794_000_000_000_000_000'i64
  let rec = {"/run/a": CreatedDir(unit: "a.service", dev: 1, ino: 2, btime: 50,
                                  invocation: "I1")}.toTable
  test "a tree systemd took over (chowned, moved into private/) is not":
    # Born well before the invocation; the adoption set its owner and ctime.
    let v = SystemdView(dynamicUid: 61200, owner: 61200, btime: Start - 500_000_000,
                        ctime: Start div 1_000_000_000 + 1, invocationId: "I2",
                        invocationStart: Start)
    check systemdRecreated("/run/a", "a.service", ["/run/a"], rec, true, v) ==
      "it was born more than 100 ms before the unit's last run began"
    var s = v
    s.dynamicUid = -1
    check systemdRecreated("/run/a", "a.service", ["/run/a"], rec, false, s).len > 0
  test "a tree written after the unit started is not":
    let v = SystemdView(dynamicUid: -1, owner: 1000, btime: Start - 500_000_000,
                        ctime: Start div 1_000_000_000 + 1, invocationId: "I2",
                        invocationStart: Start)
    check systemdRecreated("/run/a", "a.service", ["/run/a"], rec, false, v).len > 0
  test "one born after the invocation began is, for a static and a dynamic user":
    let v = SystemdView(dynamicUid: -1, owner: 1000, btime: Start + 1_000_000,
                        invocationId: "I2", invocationStart: Start)
    check systemdRecreated("/run/a", "a.service", ["/run/a"], rec, false, v) == ""
    check systemdRecreated("/run/a", "a.service", ["/run/a"], rec, true, v) == ""

suite "round 11, finding 4: a template's instances share its directories":
  let here: PathIdentity = (true, 4'u64, 5'u64, 6'i64)
  proc tplInput(name: string): EffectiveInput =
    result = goodInput()
    result.unit = name
    result.show["RuntimeDirectory"] = "foo"
    result.inspectPath = existing(["/run/foo"])
    result.pathIdentity = proc (p: string): PathIdentity = here
    result.createdDirs = {"/run/foo": CreatedDir(unit: "foo@x.service", dev: 4,
                                                 ino: 5, btime: 6)}.toTable
  test "recorded for one instance, it is the observation instance's and every other's":
    for n in ["foo@repro-addon-observe.service", "foo@x.service", "foo@y.service"]:
      checkpoint n
      check "[rule:existing-tree" notin problemsOf(tplInput(n))
    check flooredKey("foo@y.service") == "foo@.service"
    check flooredKey("bar.service") == "bar.service"
  test "a unit a dependency started during the switch is recorded":
    # Since round 12 (spec §10.1, round 12): absent at the check, present after
    # the start step, whatever the unit's start time says.
    let state = createTempDir("a9r11-", "-state")
    defer: removeDir(state)
    createDir(state / "addon")
    let ident = proc (p: string): PathIdentity =
      if p == "/run/foo": (true, 4'u64, 5'u64, 150'i64) else: (false, 0'u64, 0'u64, 0'i64)
    let invOf = proc (u: string): tuple[id: string; start: int64] = ("I9", 100'i64)
    recordStartedSince(state, [("/run/foo", "foo@1.service"), ("/run/bar", "bar.service")],
                       invOf, ident)
    let r = readCreatedDirs(state)
    check r.getOrDefault("/run/foo").unit == "foo@1.service"
    check r.getOrDefault("/run/foo").invocation == "I9"
    check "/run/bar" notin r           # not made by the start

suite "round 11, finding 5: the migration's trigger and its source":
  proc host(declares = "RuntimeDirectory=a\n"): tuple[state, unitFile: string; ledger: Ledger] =
    result.state = createTempDir("a9r11-", "-mig")
    createDir(result.state / "addon")
    result.unitFile = result.state / "a.service"
    writeFile(result.unitFile, "[Service]\n" & declares & FloorMarker & "\nDynamicUser=yes\n")
    result.ledger = Ledger(entries: @[LedgerEntry(class: lcUnit,
      path: result.unitFile, unit: "a.service")])
  let present = proc (paths: openArray[string]): proc (p: string): PathIdentity =
    let s = @paths
    result = proc (p: string): PathIdentity =
      if p in s: (true, 5'u64, uint64(s.find(p) + 10), 99'i64) else: (false, 0'u64, 0'u64, 0'i64)
  let inv = proc (u: string): string = "I0"
  let logged = proc (p: string; c: CreatedDir): bool = true
  test "not over a generation an engine that keeps the record wrote":
    let h = host()
    defer: removeDir(h.state)
    createDir(parentDir(recordKeptMarker(h.state, "g1")))
    writeFile(recordKeptMarker(h.state, "g1"), "")
    check migrateCreatedDirs(h.state, "g1", h.ledger, inv, logged,
                             present(["/run/a"])).len == 0
    check readCreatedDirs(h.state).len == 0
  test "the directories the generation's own files declare, not systemd's view":
    let h = host()
    defer: removeDir(h.state)
    # A drop-in the generation did not write adds StateDirectory=a.
    let m = migrateCreatedDirs(h.state, "g1", h.ledger, inv, logged,
      present(["/run/a", "/var/lib/a"]),
      showOf = proc (u: string): ShowProps =
        parseShow("RuntimeDirectory=a\nStateDirectory=a\n"))
    check m.len == 1 and m[0].path == "/run/a"

suite "round 11, finding 6: logged or not made; a no-op restart records nothing":
  test "an acceptance whose record or log cannot be written is not made":
    var e = goodInput()
    e.show["RuntimeDirectory"] = "a"
    e.inspectPath = existing(["/run/a"])
    e.pathIdentity = proc (p: string): PathIdentity = (true, 1'u64, 3'u64, 2000'i64)
    e.createdDirs = {"/run/a": CreatedDir(unit: "a.service", dev: 1, ino: 2, btime: 50,
                                          invocation: "I1")}.toTable
    e.systemdView = proc (p, u: string; s: ShowProps): SystemdView =
      SystemdView(dynamicUid: -1, btime: 2000, invocationId: "I2", invocationStart: 1999)
    e.onRecreated = proc (p, u: string; v: SystemdView): bool = false
    check "could not be recorded and logged" in problemsOf(e)
  test "a migrated entry whose audit record cannot be written is not recorded":
    let state = createTempDir("a9r11-", "-mig")
    defer: removeDir(state)
    createDir(state / "addon")
    let f = state / "a.service"
    writeFile(f, "[Service]\nRuntimeDirectory=a\n" & FloorMarker & "\n")
    let l = Ledger(entries: @[LedgerEntry(class: lcUnit, path: f, unit: "a.service")])
    check migrateCreatedDirs(state, "g1", l, proc (u: string): string = "I0",
      proc (p: string; c: CreatedDir): bool = false,
      proc (p: string): PathIdentity = (true, 1'u64, 2'u64, 3'i64)).len == 0
    check readCreatedDirs(state).len == 0
  test "a try-restart records only when the unit was running":
    check not restartRecords(false)
    check restartRecords(true)

suite "round 11 (§13 decision 78): an activator's listeners":
  let svcUnit = unitStanza("a.service", svc)
  proc sock(name, listen: string): string =
    svcUnit & rawUnit(name, "[Socket]\nListenStream=" & listen &
      "\nService=a.service\n\n[Install]\nWantedBy=sockets.target\n")
  test "named for the service it starts, not for the socket":
    check refused(sock("other.socket", "/run/a/x")) == ""
    check "not named for the unit" in refused(sock("other.socket", "/run/other/x"))
  test "an activator named after a base tree is refused, whatever it listens on":
    check "named after udev" in refused(sock("udev.socket", "/run/a/x"))
    check "named after systemd" in refused(sock("systemd.socket", "/run/a/x"))
  test "a listener inside a base tree is refused":
    check refused(sock("other.socket", "/run/udev/control")).len > 0
    check listenerRefusal("dbus.socket", "/run/dbus/system_bus_socket").len > 0
  test "the effective half: its name, its service's name, and an existing path":
    let base = "FragmentPath=/etc/systemd/system/X\nTriggers=a.service\n"
    proc probs(name, listen: string; prov: proc (p: string): string = nil): string =
      activatorProblems(name, parseShow(base.replace("X", name)),
        parseShowLines("Listen=" & listen & " (Stream)\n"),
        "/etc/systemd/system/" & name, [], listenerProvenance = prov).join("\n")
    check "[rule:unit-name key:Id]" in probs("udev.socket", "/run/a/x")
    check "[rule:listener" notin probs("other.socket", "/run/a/x")
    check "[rule:listener" in probs("other.socket", "/run/other/x")
    check "[rule:existing-listener" in probs("other.socket", "/run/a/x",
      proc (p: string): string = "it exists")
    check "[rule:existing-listener" notin probs("other.socket", "/run/a/x",
      proc (p: string): string = "")

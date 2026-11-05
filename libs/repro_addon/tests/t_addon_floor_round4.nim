## The hardening floor after A9's review round 4 (ReproOS Add-On Mode spec
## §10.1, *Amended 2026-11-05*): the effective-unit check as the authority
## -- default-deny over every property ``systemctl show`` reports, the
## commands and their flags against the generation's own rendering, the
## files systemd loaded, every group the service runs with, and no drop-in
## the add-on did not write (vendor, type-wide and an unnamed template
## instance's included) -- and the parse-time rules that go with it: an
## exception names only a key of the floor's list and never lifts root or
## a privileged group, a read-only bind is not a writable place, an
## instance's drop-in over a template of the same generation is accepted.
##
## Falsifying builds (each turns its own cases red):
## ``properties-not-default-denied``, ``dropins-from-the-distribution-trusted``,
## ``exception-lifts-root``, ``instance-dropin-needs-provider``.
##
## Mocks: the effective-unit cases feed the pure comparison
## ``effectiveFloorProblems`` with ``systemctl show`` text written out here
## in the forms systemd 252-259 print (measured by the review's VM
## experiment, e.g. ``ExecStartPreEx={ path=/bin/true ; argv[]=/bin/true a ;
## flags=privileged ; ... }``), because what systemd prints is the input
## under test; the accounts come from a stub instead of the build host's
## /etc/group. The VM gate ``e2e_addon_floor_effective_unit_is_checked``
## reads both from a real base. The drop-in scan walks a real directory
## tree in a temporary directory.

import std/[os, sets, strutils, tables, tempfiles, unittest]

import repro_infra/profile
import repro_infra/errors
import repro_infra/service_floor
import repro_addon/addon_apply
import repro_addon/effective_floor

const Prefix = "/repro/store/prefixes/svc/1.0"

proc unitStanza(name, service: string; extra = ""): string =
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"[Unit]\n" &
    "Description=x\n\n[Service]\n" & service & "\n[Install]\n" &
    "WantedBy=multi-user.target\n\"\n" & extra & "}\n"

proc dropInStanza(unit, content: string): string =
  "systemd.systemDropIn {\n  unit = \"" & unit & "\"\n  name = \"x\"\n" &
    "  content = \"" & content & "\"\n}\n"

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

let plain = unitStanza("a.service", "User=a\nExecStart=" & Prefix & "/bin/svc\n")
let ru = rendered(plain)
let fragment = "/etc/systemd/system/a.service"

proc goodShow(): ShowProps =
  ## What systemd shows for ``plain`` when it holds its floor (with a few
  ## of the runtime and policy properties every unit reports).
  result = parseShow("LoadState=loaded\nUser=a\nDynamicUser=no\n" &
    "FragmentPath=" & fragment & "\n" &
    "SystemCallFilter=read write close openat\n" &
    "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX\n" &
    "ActiveState=inactive\nSubState=dead\nType=simple\nRestart=no\n" &
    "After=basic.target\nTimeoutStopUSec=1min 30s\nLimitNOFILE=524288\n" &
    "LimitNOFILESoft=1024\nMemoryMax=infinity\nStandardInput=null\n" &
    "StandardOutput=journal\nStandardError=inherit\nKeyringMode=private\n" &
    "SecureBits=0\nExecMainStartTimestamp=\nUnitFileState=enabled\n" &
    "ExecStart={ path=" & Prefix & "/bin/svc ; argv[]=" & Prefix &
      "/bin/svc ; ignore_errors=no }\n")
  for k, vs in floorBlock(ru):
    if k notin ["SystemCallFilter", "NoExecPaths", "ExecPaths",
                "RestrictAddressFamilies"]:
      result[k] = vs[^1]
  var ne: seq[string]
  for l in floorBlock(ru)["NoExecPaths"]: ne.add(l.splitWhitespace())
  result["NoExecPaths"] = ne.join(" ")
  result["ExecPaths"] = floorBlock(ru)["ExecPaths"].join(" ")

proc goodInput(): EffectiveInput =
  result = EffectiveInput(unit: "a.service", rendered: ru,
    version: FloorVersion, show: goodShow(), fragment: fragment,
    denied: toHashSet(["memfd_create", "mount"]))
  result.uidOf = proc (n: string): int = (if n == "root": 0 else: 1000)
  result.groupsOf = proc (n: string): seq[string] = @[n]
  result.readableByAll = proc (p: string): bool = not p.startsWith("/etc/shadow")
  result.lines["ExecStartEx"] = @["{ path=" & Prefix & "/bin/svc ; argv[]=" &
    Prefix & "/bin/svc ; flags= ; start_time=[n/a] }"]
  result.loaded = @[(path: fragment, content: ru)]

proc problemsOf(e: EffectiveInput): string = effectiveFloorProblems(e).join("\n")

suite "round 4: the effective-unit check is the authority":
  test "a unit that holds its floor has no problem":
    check problemsOf(goodInput()) == ""

  test "finding 1: every group the service runs with":
    var e = goodInput()
    e.show["Group"] = "shadow"
    check "privileged group shadow" in problemsOf(e)
    # A static account that /etc/group puts in a privileged group
    # (User=syslog is in adm on Ubuntu).
    e = goodInput()
    e.groupsOf = proc (n: string): seq[string] = @[n, "adm"]
    check "privileged group adm" in problemsOf(e)
    e = goodInput()
    e.show["SupplementaryGroups"] = "disk"
    check "privileged group disk" in problemsOf(e)
    # A dynamic user is in no group /etc/group names.
    e = goodInput()
    e.show["DynamicUser"] = "yes"
    e.groupsOf = proc (n: string): seq[string] = @["shadow"]
    check problemsOf(e) == ""

  test "finding 3: a property neither compared nor reviewed refuses":
    var e = goodInput()
    e.show["SomeSettingANewerSystemdAdds"] = "yes"
    check "SomeSettingANewerSystemdAdds=yes is neither compared" in problemsOf(e)

  test "finding 3: commands and their flags against the rendering":
    var e = goodInput()
    e.lines["ExecStartPreEx"] = @["{ path=" & Prefix & "/bin/svc ; argv[]=x ; " &
      "flags=privileged ; start_time=[n/a] }"]
    let p = problemsOf(e)
    check "carries the flag privileged" in p
    check "ExecStartPre runs 1 command(s), the generation's rendering 0" in p
    for f in ["no-setuid", "ambient"]:
      e = goodInput()
      e.lines["ExecStartEx"] = @["{ path=" & Prefix & "/bin/svc ; flags=" & f & " }"]
      check ("carries the flag " & f) in problemsOf(e)
    e = goodInput()
    e.lines["ExecStartEx"] = @["{ path=/usr/bin/id ; flags= }"]
    check "runs /usr/bin/id, the rendering" in problemsOf(e)
    check "outside ExecPaths=" in problemsOf(e)
    # The flags a floored command may carry.
    e = goodInput()
    e.lines["ExecStartEx"] = @["{ path=" & Prefix & "/bin/svc ; " &
      "flags=ignore-failure no-env-expand }"]
    check problemsOf(e) == ""

  test "finding 3: files the manager opens as root":
    var e = goodInput()
    e.show["OpenFile"] = "/etc/a9:t"
    check "OpenFile=/etc/a9:t opens a file as root" in problemsOf(e)
    for (k, v) in [("StandardOutput", "truncate"), ("StandardError", "append"),
                   ("StandardOutput", "file"), ("StandardInput", "file"),
                   ("StandardInput", "tty")]:
      e = goodInput()
      e.show[k] = v
      check (k & "=" & v & " opens a file or terminal") in problemsOf(e)
    e = goodInput()
    e.show["EnvironmentFiles"] = "/etc/shadow (ignore_errors=no)"
    check "is read as root and is not readable by every user" in problemsOf(e)
    e = goodInput()
    e.show["LoadCredential"] = "x:/etc/shadow"
    check "outside the service's own credentials" in problemsOf(e)
    e = goodInput()
    e.show["LoadCredential"] = "x:" & CredentialRoot & "/a/x"
    check problemsOf(e) == ""

  test "finding 3: a setting systemd does not report (PermissionsStartOnly=)":
    var e = goodInput()
    e.loaded = @[(path: fragment, content: ru),
      (path: "/etc/systemd/system/a.service.d/x.conf",
       content: "[Service]\nPermissionsStartOnly=yes\n")]
    e.show["DropInPaths"] = "/etc/systemd/system/a.service.d/x.conf"
    e.ownDropIns = @[(path: "/etc/systemd/system/a.service.d/x.conf",
                      content: "[Service]\nPermissionsStartOnly=yes\n")]
    check "sets PermissionsStartOnly=" in problemsOf(e)

  test "finding 3: provenance -- the unit file and only the add-on's drop-ins":
    var e = goodInput()
    e.show["DropInPaths"] = "/usr/lib/systemd/system/a.service.d/v.conf"
    check "not one the add-on installed" in problemsOf(e)
    e = goodInput()
    e.show["DropInPaths"] = "/usr/lib/systemd/system/service.d/zz.conf"
    check "not one the add-on installed" in problemsOf(e)
    e = goodInput()
    e.show["FragmentPath"] = "/usr/lib/systemd/system/a.service"
    check "not the unit file the add-on wrote" in problemsOf(e)
    # The switch's own start hold is the add-on's.
    e = goodInput()
    let hold = startHoldPath("a.service")
    e.show["DropInPaths"] = hold
    e.ownDropIns = @[(path: hold, content: StartHoldText)]
    e.loaded.add((path: hold, content: StartHoldText))
    check problemsOf(e) == ""

  test "finding 5: a read-only bind is not a writable place":
    var e = goodInput()
    e.show["BindReadOnlyPaths"] = "/repro/store/prefixes/apt-closure-x/1/usr:/usr:rbind"
    check writablePlaces(e.show).len == 0
    check "writable place" notin problemsOf(e)
    e.show["BindPaths"] = "/var/lib/x:/srv/y:rbind"
    check "/srv/y" in writablePlaces(e.show)

suite "round 4: drop-ins the generation did not write":
  test "which directories systemd reads for a unit or a template":
    check dropInDirApplies("a.service", "a.service")
    check dropInDirApplies("service", "a.service")              # type-wide
    check dropInDirApplies("a-.service", "a-b.service")         # dashed prefix
    check dropInDirApplies("t@.service", "t@.service")
    check dropInDirApplies("t@2.service", "t@.service")         # an instance
    check dropInDirApplies("t-.service", "t-x@.service")
    check not dropInDirApplies("b.service", "a.service")
    check not dropInDirApplies("t@2.socket", "t@.service")
    check not dropInDirApplies("u@2.service", "t@.service")

  test "the scan finds a host's drop-in on an instance no one named":
    let root = createTempDir("a9r4-", "-paths")
    defer: removeDir(root)
    createDir(root / "t@2.service.d")
    writeFile(root / "t@2.service.d" / "host.conf", "[Service]\nUser=\n")
    createDir(root / "t@1.service.d")
    writeFile(root / "t@1.service.d" / "x.conf", "[Service]\nEnvironment=A=1\n")
    createDir(root / "other.service.d")
    writeFile(root / "other.service.d" / "y.conf", "[Service]\n")
    let own = toHashSet([root / "t@1.service.d" / "x.conf"])
    check foreignDropInsFor(["t@.service"], own, [root]) ==
      @[root / "t@2.service.d" / "host.conf"]

  test "an instance's drop-in over a template of the same generation":
    let declared = toHashSet(["t@.service", "a.service"])
    check declaredByProfile("t@1.service", declared)
    check declaredByProfile("a.service", declared)
    check not declaredByProfile("u@1.service", declared)

  test "one start hold covers every instance of a template":
    check startHoldPath("t@1.service") ==
      "/run/systemd/system/t@.service.d/" & StartHoldName
    check startHoldPath("a.service") ==
      "/run/systemd/system/a.service.d/" & StartHoldName

suite "round 4: exceptions name only the floor's keys, never root":
  test "a key outside the floor's list cannot be named":
    for k in ["OpenFile", "PermissionsStartOnly", "StandardOutput", "Bogus"]:
      checkpoint k
      check "names no serviceFloor setting" in refused(unitStanza("a.service",
        "User=a\nExecStart=" & Prefix & "/bin/svc\n",
        "  floorExceptions = [\"" & k & ": a reason\"]\n"))

  test "a User or DynamicUser exception never lets the service run as root":
    check "runs the service as root" in refused(unitStanza("a.service",
      "User=root\nExecStart=" & Prefix & "/bin/svc\n",
      "  floorExceptions = [\"User: needs root\"]\n"))
    check "runs the service as root" in refused(unitStanza("a.service",
      "ExecStart=" & Prefix & "/bin/svc\n",
      "  floorExceptions = [\"DynamicUser: needs root\"]\n"))
    check "privileged group" in refused(unitStanza("a.service",
      "User=a\nSupplementaryGroups=shadow\nExecStart=" & Prefix & "/bin/svc\n",
      "  floorExceptions = [\"SupplementaryGroups: reads hashes\"]\n"))
    check "privileged group shadow" in refused(unitStanza("a.service",
      "User=a\nGroup=shadow\nExecStart=" & Prefix & "/bin/svc\n"))
    # The whole-floor waiver is the one way to run as root.
    check refused(unitStanza("a.service", "User=root\nExecStart=/bin/sh\n",
      "  floorExceptions = [\"serviceFloor: the host's own controller\"]\n")) == ""

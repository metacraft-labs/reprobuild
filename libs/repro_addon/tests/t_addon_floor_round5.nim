## The hardening floor after A9's review round 5 (ReproOS Add-On Mode spec
## §10.1, *Amended 2026-11-05 (round 5)*), from the reviewer's probe
## (``zz_a9rev5_probe``): each test is a finding the probe recorded red.
##
## - ``EnvironmentFile=`` (finding 1): no wildcard, nowhere a service or an
##   unprivileged user can write (the unit's own writable places, another
##   floored unit's, ``/tmp`` ...), and -- in the effective check -- an
##   existing, root-owned file under root-owned parents no one else can
##   write; a path that cannot be read refuses.
## - sockets, timers and path units that activate a floored service
##   (finding 2): only network and unix-socket listeners under ``/run``, no
##   command line, ``Sockets=`` naming only the profile's sockets, and no
##   command line in a drop-in onto any socket, timer or path unit.
## - realtime scheduling, the reboot actions and the resource limits
##   (finding 3), and every property classified by name.
## - privileged groups by gid (finding 4).
## - the start hold's removal keeps other drop-ins, and stale holds are
##   cleared (finding 5).
##
## Falsifying builds (each turns its own cases red):
## ``floor-round5-static-off``, ``environment-files-trusted``,
## ``inert-families-by-pattern``, ``privileged-groups-by-name``,
## ``start-hold-removes-directory``, ``stale-start-holds-kept``.
##
## Mocks: as in ``t_addon_floor_round4``, ``systemctl show`` text written
## out here and stubs for the accounts and the manager's limits, because the
## comparison is under test. ``environmentFileProblem`` and the hold
## removal run against the real file system (/etc, and a temporary
## directory).

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

proc rawUnit(name, content: string): string =
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"" &
    content & "\"\n}\n"

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
    "KeyringMode=private\nSecureBits=0\nCPUSchedulingPolicy=0\n" &
    "IOSchedulingClass=2\nFailureAction=none\nLimitNOFILE=524288\n" &
    "LimitNOFILESoft=1024\nLimitMEMLOCK=8388608\n")
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
    denied: toHashSet(["memfd_create", "mount"]))
  result.uidOf = proc (n: string): int = (if n == "root": 0 else: 1000)
  result.groupsOf = proc (n: string): seq[string] = @[n]
  result.gidOf = proc (g: string): int =
    case g
    of "root", "toor": 0
    of "shadow", "shade": 42
    of "ssl-cert": 110
    of "a": 1000
    else: -1
  result.inspectFile = proc (p: string): string = ""
  result.limitCeilings = {"DefaultLimitNOFILE": "524288",
    "DefaultLimitNOFILESoft": "1024", "DefaultLimitMEMLOCK": "8388608"}.toTable
  result.lines["ExecStartEx"] = @["{ path=" & Prefix & "/bin/svc ; argv[]=" &
    Prefix & "/bin/svc ; flags= ; start_time=[n/a] }"]
  result.loaded = @[(path: fragment, content: ru)]

proc problemsOf(e: EffectiveInput): string = effectiveFloorProblems(e).join("\n")

suite "round 5: the baseline":
  test "a unit that holds its floor has no problem":
    check problemsOf(goodInput()) == ""

suite "round 5, finding 1: EnvironmentFile= is read by the manager as root":
  test "parse time: no wildcard, nowhere a service or a user can write":
    check "wildcard" in refused(unitStanza("a.service",
      "EnvironmentFile=/etc/*/a.env\n" & svc))
    check "own writable place" in refused(unitStanza("a.service",
      "StateDirectory=a\nEnvironmentFile=-/var/lib/a/env\n" & svc))
    check "lies under /tmp" in refused(unitStanza("a.service",
      "EnvironmentFile=/tmp/a.env\n" & svc))
    check "b.service's writable place" in refused(unitStanza("a.service",
      "EnvironmentFile=/var/lib/b/env\n" & svc) &
      unitStanza("b.service", "User=a\nStateDirectory=b\nExecStart=" & Prefix &
                 "/bin/svc\n"))
    check refused(unitStanza("a.service", "EnvironmentFile=/etc/a/env\n" & svc)) == ""

  test "the effective check: wildcard, writable places, the file itself":
    var e = goodInput()
    e.show["EnvironmentFiles"] = "/etc/*/a.env (ignore_errors=no)"
    check "wildcard" in problemsOf(e)
    e = goodInput()
    e.show["StateDirectory"] = "a"
    e.show["EnvironmentFiles"] = "/var/lib/a/env (ignore_errors=yes)"
    check "lies in the writable place /var/lib/a" in problemsOf(e)
    e = goodInput()
    e.otherWritable = @["/var/lib/b"]
    e.show["EnvironmentFiles"] = "/var/lib/b/env (ignore_errors=no)"
    check "lies in the writable place /var/lib/b" in problemsOf(e)
    e = goodInput()
    e.inspectFile = nil         # the real check
    e.show["EnvironmentFiles"] = "/nonexistent/a9r5.env (ignore_errors=yes)"
    check "it does not exist" in problemsOf(e)

  test "the real file check: root-owned, under root-owned parents":
    check environmentFileProblem("/nonexistent/a9r5.env").len > 0
    let dir = createTempDir("a9r5-", "-env")
    defer: removeDir(dir)
    writeFile(dir / "e", "A=1\n")
    # Not root-owned (the test runs unprivileged) or under a writable
    # parent: refused either way.
    check environmentFileProblem(dir / "e").len > 0
    # A root-owned file under root-owned, non-writable parents (/etc and /
    # on any build host).
    if getFileInfo("/etc/passwd").id.device >= 0 and
        fileExists("/etc/passwd"):
      check environmentFileProblem("/etc/passwd") == ""

suite "round 5, finding 2: sockets and other activators":
  test "Sockets= names only the profile's own socket units":
    check "not a socket unit of this profile" in refused(unitStanza(
      "a.service", "Sockets=dbus.socket\n" & svc))
    var e = goodInput()
    e.show["Sockets"] = "dbus.socket"
    check "Sockets=dbus.socket is not a socket unit the add-on installed" in
      problemsOf(e)
    e.ownUnits = toHashSet(["dbus.socket"])
    check problemsOf(e) == ""

  test "a floored service's socket: network and /run unix listeners only":
    check "activates a floored service" in refused(plain & rawUnit("a.socket",
      "[Socket]\nListenSpecial=/etc/a-target\nWritable=yes\n" &
      "Service=a.service\n\n[Install]\nWantedBy=sockets.target\n"))
    check "activates a floored service" in refused(plain & rawUnit("a.socket",
      "[Socket]\nListenFIFO=/run/a.fifo\n"))
    check "under /run" in refused(plain & rawUnit("a.socket",
      "[Socket]\nListenStream=/etc/a.sock\n"))
    check refused(plain & rawUnit("a.socket",
      "[Socket]\nListenStream=/run/a.sock\nListenStream=127.0.0.1:8080\n" &
      "\n[Install]\nWantedBy=sockets.target\n")) == ""
    # A timer and a path unit that start it: watch-only keys.
    check "activates a floored service" in refused(plain & rawUnit("a.path",
      "[Path]\nPathExists=/etc/x\nMakeDirectory=yes\n"))
    check refused(plain & rawUnit("a.timer", "[Timer]\nOnCalendar=daily\n")) == ""

  test "no command line in a drop-in onto any socket, timer or path unit":
    check "carries a command line" in refused(rawUnit("b.socket",
      "[Socket]\nListenStream=/run/b.sock\n") &
      dropInStanza("b.socket", "[Socket]\nExecStartPre=/bin/true\n"))

  test "the effective check of an activator":
    var show = parseShow("FragmentPath=/etc/systemd/system/a.socket\n" &
      "DropInPaths=\n")
    var lines = parseShowLines("Listen=/run/a.sock (Stream)\n" &
      "Listen=/etc/a-target (Special)\n")
    let p = activatorProblems("a.socket", show, lines,
      "/etc/systemd/system/a.socket", [])
    check p.len == 1
    check "/etc/a-target (Special) is opened as root" in p.join()
    show["ExecStartPre"] = "{ path=/bin/true ; argv[]=/bin/true }"
    show["FragmentPath"] = "/usr/lib/systemd/system/a.socket"
    let q = activatorProblems("a.socket", show, lines,
      "/etc/systemd/system/a.socket", []).join()
    check "runs a command as root" in q
    check "not a unit file the add-on wrote" in q

suite "round 5, finding 3: realtime, actions, limits, every name":
  test "realtime scheduling under RestrictRealtime=yes":
    check "realtime scheduling" in refused(unitStanza("a.service",
      "CPUSchedulingPolicy=fifo\nCPUSchedulingPriority=99\n" & svc))
    check "realtime scheduling" in refused(unitStanza("a.service",
      "IOSchedulingClass=realtime\n" & svc))
    var e = goodInput()
    e.show["CPUSchedulingPolicy"] = "1"
    check "CPUSchedulingPolicy=1 is realtime" in problemsOf(e)
    e = goodInput()
    e.show["IOSchedulingClass"] = "1"
    check "IOSchedulingClass=1 is realtime" in problemsOf(e)

  test "the reboot actions are compared with none":
    for k in ["FailureAction", "SuccessAction", "StartLimitAction",
              "JobTimeoutAction"]:
      var e = goodInput()
      e.show[k] = "reboot-force"
      check (k & "=reboot-force") in problemsOf(e)

  test "a resource limit may not raise the manager's default":
    var e = goodInput()
    e.show["LimitMEMLOCK"] = "infinity"
    check "LimitMEMLOCK=infinity raises the manager's default" in problemsOf(e)
    e = goodInput()
    e.show["LimitNPROC"] = "100"
    check "no manager default to compare with" in problemsOf(e)
    e = goodInput()
    e.show["LimitNOFILESoft"] = "512"
    check problemsOf(e) == ""

  test "no family is inert by its name's shape":
    check not isInertProp("FooTimestamp")
    check not isInertProp("LimitNEWTHING")
    var e = goodInput()
    e.show["LimitNEWTHING"] = "1"
    check "LimitNEWTHING=1 is neither compared" in problemsOf(e)

suite "round 5, finding 4: privileged groups by gid":
  test "a second name for a privileged gid, an unknown group, ssl-cert":
    var e = goodInput()
    e.groupsOf = proc (n: string): seq[string] = @["toor"]
    check "privileged group toor (gid 0)" in problemsOf(e)
    e = goodInput()
    e.show["SupplementaryGroups"] = "shade"
    check "privileged group shade (gid 42)" in problemsOf(e)
    e = goodInput()
    e.show["SupplementaryGroups"] = "nosuchgroup"
    check "which getent does not know" in problemsOf(e)
    check "ssl-cert" in PrivilegedGroups
    # A dynamic user's own group is systemd's to allocate, not getent's.
    e = goodInput()
    e.show["DynamicUser"] = "yes"
    e.show["User"] = "a-dyn"
    e.show["Group"] = "a-dyn"
    check problemsOf(e) == ""
    e.show["Group"] = "toor"
    check "privileged group toor" in problemsOf(e)

suite "round 5, finding 5: the start holds":
  test "removing a hold keeps every other drop-in":
    let root = createTempDir("a9r5-", "-holds")
    defer: removeDir(root)
    let d = root / "a.service.d"
    createDir(d)
    writeFile(d / StartHoldName, StartHoldText)
    writeFile(d / "50-other.conf", "[Service]\n")
    removeStartHolds([d / StartHoldName])
    check not fileExists(d / StartHoldName)
    check fileExists(d / "50-other.conf")
    # A directory the hold was alone in goes.
    let d2 = root / "b.service.d"
    createDir(d2)
    writeFile(d2 / StartHoldName, StartHoldText)
    removeStartHolds([d2 / StartHoldName])
    check not dirExists(d2)

  test "stale holds an earlier switch left are cleared":
    let root = createTempDir("a9r5-", "-stale")
    defer: removeDir(root)
    for u in ["a.service", "t@.service"]:
      createDir(root / (u & ".d"))
      writeFile(root / (u & ".d") / StartHoldName, StartHoldText)
    createDir(root / "c.service.d")
    writeFile(root / "c.service.d" / "50-other.conf", "[Service]\n")
    let cleared = clearStaleStartHolds(root)
    check cleared.len == 2
    check fileExists(root / "c.service.d" / "50-other.conf")
    check not fileExists(root / "a.service.d" / StartHoldName)

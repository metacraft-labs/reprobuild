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
##   command line in a drop-in onto any socket, timer or path unit; what a
##   trigger activates is read from its unit file and the profile's
##   drop-ins onto it, as systemd reads it.
## - realtime scheduling, the reboot actions and the resource limits
##   (finding 3), and every property classified by name.
## - privileged groups by gid (finding 4).
## - the start hold's removal keeps other drop-ins, and stale holds are
##   cleared (finding 5).
##
## Falsifying builds (each turns its own cases red):
## ``floor-round5-static-off``, ``environment-files-trusted``,
## ``inert-families-by-pattern``, ``privileged-groups-by-name``,
## ``start-hold-removes-directory``, ``stale-start-holds-kept``,
## ``activator-own-file-only`` (a profile drop-in's ``Service=`` or
## ``Unit=`` not read: reprobuild-pm issue
## 2026-11-15-floor-activator-check-ignores-a-profile-drop-in-that-sets-service),
## ``activator-timer-resources-skipped`` and ``reach-timer-resources-skipped``
## (a ``systemd.systemTimer`` resource not judged as an activator, or not a
## root of the reach check: issue
## 2026-11-15-floor-activator-checks-skip-a-systemd-system-timer-resource).
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
    denied: toHashSet(["memfd_create", "mount"]), partialShow: true)
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
    # Since §13 decision 50 (round 7) every one of these is refused by the
    # default-deny rule before the round-5 rules are reached.
    const deny = "is neither in the add-on's store"
    check deny in refused(unitStanza("a.service",
      "StateDirectory=a\nEnvironmentFile=-/var/lib/a/env\n" & svc))
    check deny in refused(unitStanza("a.service",
      "EnvironmentFile=/tmp/a.env\n" & svc))
    check deny in refused(unitStanza("a.service",
      "EnvironmentFile=/var/lib/b/env\n" & svc) &
      unitStanza("b.service", "User=a\nStateDirectory=b\nExecStart=" & Prefix &
                 "/bin/svc\n"))
    check deny in refused(unitStanza("a.service", "EnvironmentFile=/etc/a/env\n" & svc))
    # A file the profile installs (a link into the store) is accepted.
    check refused("fs.systemFile {\n  path = \"/etc/a/env\"\n  content = \"A=1\"\n}\n" &
      unitStanza("a.service", "EnvironmentFile=/etc/a/env\n" & svc)) == ""

  test "the effective check: wildcard, writable places, the file itself":
    var e = goodInput()
    e.show["EnvironmentFiles"] = "/etc/*/a.env (ignore_errors=no)"
    check "wildcard" in problemsOf(e)
    # Since §13 decision 50 (round 7): refused by the default-deny form
    # rule before the round-5 writable-place rule.
    e = goodInput()
    e.show["StateDirectory"] = "a"
    e.show["EnvironmentFiles"] = "/var/lib/a/env (ignore_errors=yes)"
    check "is neither in the add-on's store" in problemsOf(e)
    e = goodInput()
    e.otherWritable = @["/var/lib/b"]
    e.show["EnvironmentFiles"] = "/var/lib/b/env (ignore_errors=no)"
    check "is neither in the add-on's store" in problemsOf(e)
    # A store path in another floored unit's writable place is still caught.
    e = goodInput()
    e.otherWritable = @["/repro/store/prefixes/x"]
    e.show["EnvironmentFiles"] = "/repro/store/prefixes/x/1/env (ignore_errors=no)"
    check "lies in the writable place /repro/store/prefixes/x" in problemsOf(e)
    e = goodInput()
    e.inspectFile = nil         # the real check
    e.show["EnvironmentFiles"] = "/run/repro/secrets/a/a9r5.env (ignore_errors=yes)"
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
    # Since §13 decision 50 (round 7) only where it resolves decides, owner
    # and mode aside: refused with no owned object, accepted inside one
    # (the owner checks still pass on /etc and / on any build host).
    if fileExists("/etc/passwd"):
      check "neither in a store object" in environmentFileProblem("/etc/passwd")
      check environmentFileProblem("/etc/passwd", "", ["/etc"]) == ""
    # A link the user owns, in a directory the user owns: refused before
    # its target is even looked at.
    createSymlink("/etc/passwd", dir / "l")
    check "not owned by root" in environmentFileProblem(dir / "l")

suite "round 5, finding 2: sockets and other activators":
  test "Sockets= names only the profile's own socket units":
    check "not a socket unit of this profile" in refused(unitStanza(
      "a.service", "Sockets=dbus.socket\n" & svc))
    var e = goodInput()
    e.loaded = @[(path: fragment, content: ru.replace("[Install]", "Sockets=dbus.socket\n\n[Install]"))]
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
      "[Socket]\nListenStream=/run/a/a.sock\nListenStream=127.0.0.1:8080\n" &
      "\n[Install]\nWantedBy=sockets.target\n")) == ""
    # A timer and a path unit that start it: watch-only keys.
    check "activates a floored service" in refused(plain & rawUnit("a.path",
      "[Path]\nPathExists=/etc/x\nMakeDirectory=yes\n"))
    check refused(plain & rawUnit("a.timer", "[Timer]\nOnCalendar=daily\n")) == ""

  test "a profile drop-in that points a trigger at a floored service makes it an activator":
    # systemd reads a socket's Service= and a timer's or path unit's Unit=
    # from the unit file and from its drop-ins (systemd.unit(5),
    # "Description"), so a drop-in can make a trigger start a floored
    # service that its own file does not name (reprobuild-pm issue
    # 2026-11-15-floor-activator-check-ignores-a-profile-drop-in-that-
    # sets-service). b.socket's own file starts b.service, which the
    # profile does not define; the drop-in points it at a.service.
    let toA = dropInStanza("b.socket", "[Socket]\nService=a.service\n")
    # The socket's own listeners are judged as an activator's.
    check "'b.socket' activates a floored service" in refused(plain &
      rawUnit("b.socket", "[Socket]\nListenFIFO=/run/b.fifo\n") & toA)
    check "'b.socket' activates a floored service" in refused(plain &
      rawUnit("b.socket", "[Socket]\nListenSpecial=/etc/b-target\n" &
        "Service=other.service\n") & toA)
    # The drop-in is judged as one onto an activator, not for command
    # lines alone.
    check "which activates a floored service" in refused(plain &
      rawUnit("b.socket", "[Socket]\nListenStream=/run/a/b.sock\n") &
      dropInStanza("b.socket", "[Socket]\nService=a.service\n" &
        "ListenFIFO=/run/b.fifo\n"))
    # A timer's and a path unit's Unit= in a drop-in, too.
    check "'b.path' activates a floored service" in refused(plain &
      rawUnit("b.path", "[Path]\nPathExists=/etc/x\nMakeDirectory=yes\n") &
      dropInStanza("b.path", "[Path]\nUnit=a.service\n"))
    # And the route to a system-state unit (§13 decision 49) is judged
    # from it, as from any unit that activates a floored service.
    let viaX = rawUnit("b.socket", "[Unit]\nWants=x.target\n\n" &
      "[Socket]\nListenStream=/run/a/b.sock\n") &
      rawUnit("x.target", "[Unit]\nWants=reboot.target\n")
    check "'b.socket' starts reboot.target" in refused(plain & viaX & toA)
    check refused(plain & viaX) == ""
    # Controls: the same socket with a drop-in that names no floored
    # service, and the same drop-in over a socket with only /run
    # listeners, are accepted.
    check refused(plain & rawUnit("b.socket",
      "[Socket]\nListenFIFO=/run/b.fifo\n") &
      dropInStanza("b.socket", "[Socket]\nService=other.service\n")) == ""
    check refused(plain & rawUnit("b.socket",
      "[Socket]\nListenStream=/run/a/b.sock\n") & toA) == ""
    # The last valid Service= wins: a drop-in that points a floored
    # service's socket elsewhere leaves it no activator.
    check refused(plain & rawUnit("b.socket",
      "[Socket]\nListenFIFO=/run/b.fifo\nService=a.service\n") &
      dropInStanza("b.socket", "[Socket]\nService=other.service\n")) == ""
    # Any unit the trigger starts being floored makes it an activator: an
    # Accept=yes socket with a listener that cannot accept triggers both
    # its template and its namesake (``profile.triggeredUnits``), and here
    # only the namesake is floored.
    check "'a.socket' activates a floored service" in refused(plain &
      rawUnit("a.socket", "[Socket]\nAccept=yes\n" &
        "ListenStream=/run/a/a.sock\nListenFIFO=/etc/a.fifo\n"))

  test "a systemd.systemTimer resource is a timer unit of the profile":
    # A timer may be declared as a systemd.systemUnit or as a
    # systemd.systemTimer resource; both install a timer of the profile
    # that starts its Unit=, so both are activators (reprobuild-pm issue
    # 2026-11-15-floor-activator-checks-skip-a-systemd-system-timer-
    # resource).
    proc timerRes(name, content: string): string =
      "systemd.systemTimer {\n  name = \"" & name & "\"\n  content = \"" &
        content & "\"\n}\n"
    let reach = "[Unit]\nWants=reboot.target\n\n[Timer]\nOnCalendar=daily\n"
    # Its [Unit] is judged as an activator's (a route to a system-state
    # unit), as it is for a timer declared as a systemd.systemUnit.
    let asUnit = refused(plain & rawUnit("t.timer", reach & "Unit=a.service\n"))
    check "activates a floored service" in asUnit
    check "starts reboot.target" in asUnit
    check "systemd.systemTimer 't.timer' activates a floored service: " &
      "[Unit] Wants=reboot.target starts reboot.target" in refused(plain &
      timerRes("t.timer", reach & "Unit=a.service\n"))
    # By its namesake, and through a profile drop-in's Unit=.
    check "systemd.systemTimer 'a.timer' activates a floored service" in
      refused(plain & timerRes("a.timer", reach))
    check "systemd.systemTimer 't.timer' activates a floored service" in refused(plain &
      timerRes("t.timer", reach) &
      dropInStanza("t.timer", "[Timer]\nUnit=a.service\n"))
    # Its own settings are judged as an activator's.
    check "'t.timer' activates a floored service" in refused(plain &
      timerRes("t.timer", "[Timer]\nOnCalendar=daily\nUnit=a.service\n" &
        "RandomizedDelaySec=1h\nOnClockChange=yes\nUnknownTimerKey=1\n"))
    # The reach check takes it as a root too: Conflicts= may name only the
    # profile's own units (§13 decision 55), which the activator rules do
    # not judge.
    check "systemd.systemTimer 't.timer': " in refused(plain &
      timerRes("t.timer", "[Unit]\nConflicts=nope.service\n\n[Timer]\n" &
        "OnCalendar=daily\nUnit=a.service\n"))
    check refused(plain & timerRes("t.timer", "[Unit]\nConflicts=nope.service\n\n" &
      "[Timer]\nOnCalendar=daily\nUnit=other.service\n")) == ""
    # The boot-ordering walk reads it as a unit of the profile (not as a
    # systemd.systemUnit, whose fields it does not have: a FieldDefect).
    # With default dependencies a timer is ordered before timers.target,
    # which the boot re-assertion waits for, so a timer ordered after the
    # floored service -- by its own After= or the service's Before= -- is
    # an ordering cycle, refused for either kind of declaration alike.
    let after = "[Unit]\nAfter=a.service\n\n[Timer]\nOnCalendar=daily\n" &
      "Unit=other.service\n"
    let cycle = "(a.service -> t.timer -> timers.target)"
    check cycle in refused(plain & timerRes("t.timer", after))
    check cycle in refused(plain & rawUnit("t.timer", after))
    let before = "systemd.systemUnit {\n  name = \"a.service\"\n  content = \"[Unit]\n" &
      "Description=x\nBefore=t.timer\n\n[Service]\n" & svc & "\n[Install]\n" &
      "WantedBy=multi-user.target\n\"\n}\n"
    let plainTimer = "[Timer]\nOnCalendar=daily\nUnit=other.service\n"
    check cycle in refused(before & timerRes("t.timer", plainTimer))
    check cycle in refused(before & rawUnit("t.timer", plainTimer))
    # Without default dependencies there is no cycle, and it is accepted.
    check refused(before & timerRes("t.timer",
      "[Unit]\nDefaultDependencies=no\n\n" & plainTimer)) == ""
    # Controls: the same timers starting nothing floored, and a plain timer
    # of the floored service, are accepted.
    check refused(plain & timerRes("t.timer", reach & "Unit=other.service\n")) == ""
    check refused(plain & timerRes("t.timer",
      "[Timer]\nOnCalendar=daily\nUnit=a.service\n")) == ""

  test "no command line in a drop-in onto any socket, timer or path unit":
    check "carries a command line" in refused(rawUnit("b.socket",
      "[Socket]\nListenStream=/run/b/b.sock\n") &
      dropInStanza("b.socket", "[Socket]\nExecStartPre=/bin/true\n"))

  test "the effective check of an activator":
    var show = parseShow("FragmentPath=/etc/systemd/system/a.socket\nAfter=sysinit.target\n" &
      "DropInPaths=\n")
    var lines = parseShowLines("Listen=/run/a/a.sock (Stream)\n" &
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
    e.uidOf = proc (n: string): int = -1      # no static account of that name
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

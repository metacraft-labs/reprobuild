## The hardening floor after A9's review round 7 (ReproOS Add-On Mode spec
## §10.1, *Amended 2026-11-06 (A9 adversarial review, round 7)*; §13
## decisions 49 and 50), from the reviewer's probe (``zz_a9rev7_probe``):
## each test is a class of finding the probe recorded red.
##
## - ``EnvironmentFile=`` is default-deny: a store object of the generation
##   or the service's own secrets, by its form and by where it resolves (1);
## - the start hold cannot be satisfied, and nothing the manager creates for
##   a floored unit or its activator lies in the add-on's trees, nor is an
##   existing path of someone else's (2);
## - each activator socket option by its own rule from systemd.socket(5) (3);
## - a system-state unit reached by any route, the extended list, the job
##   modes and isolation, for activators too (4);
## - the effective half applies every parse-time rule: a source scan that
##   fails when a parse-time refusal has no effective counterpart, and a
##   corpus of parse-time refusals each refused by the effective half alone;
##   the read-only bind source compared by component against owned objects
##   (5);
## - the profile's own memberships at parse time (6).
##
## Falsifying builds (each turns its own cases red):
## ``environment-files-by-mode``, ``hold-path-creatable``,
## ``manager-paths-unchecked``, ``listeners-anywhere-under-run``,
## ``socket-options-by-list``, ``state-routes-direct-only``,
## ``activator-show-unjudged``, ``effective-skips-parse-rules``,
## ``bind-sources-by-prefix``, ``profile-memberships-ignored``,
## ``printed-file-settings-trusted``, ``adopted-files-unverified``, ``getent-errors-as-absent``,
## ``conflicts-unchecked`` (§13 decision 55). Finding 7 is the tick helper's, a VM
## gate (``e2e_addon_tick_observes_a_fresh_cycle``).
##
## Mocks: as in ``t_addon_floor_round6``, ``systemctl show`` text and stubs
## for the accounts and the host's paths, because the comparison is under
## test. The ``EnvironmentFile=`` resolution runs on this host's real files.

import std/[os, sets, strutils, tables, tempfiles, unittest]

import repro_infra/profile
import repro_infra/errors
import repro_infra/service_floor
import repro_addon/addon_apply
import repro_addon/effective_floor
from repro_addon/fingerprint import sha256OfFile, sha256Hex

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

suite "round 7: the baseline":
  test "a unit that holds its floor has no problem, and parses":
    check problemsOf(goodInput()) == ""
    check refused(plain) == ""

suite "round 7, finding 1: EnvironmentFile= is default-deny":
  test "the real resolution: a root-only host file is refused":
    for p in ["/etc/shadow", "/etc/passwd", "/etc/ssh/ssh_host_ed25519_key"]:
      if fileExists(p):
        checkpoint p
        check environmentFileProblem(p).len > 0
        check environmentFileProblem(p, "a", []).len > 0
  test "a link resolving outside an owned object is refused":
    let dir = createTempDir("a9r7-", "-env")
    defer: removeDir(dir)
    createSymlink("/etc/passwd", dir / "l")
    check environmentFileProblem(dir / "l", "a", ["/etc"]).len > 0
  test "inside an owned object it is accepted (owner checks pass on /etc)":
    if fileExists("/etc/passwd"):
      check environmentFileProblem("/etc/passwd", "", ["/etc"]) == ""
      check environmentFileProblem("/etc/passwd", "", ["/et"]).len > 0
  test "by its form: another service's secrets, /etc, a host file":
    check environmentFileRefusal("a.service", "/run/repro/secrets/b/env", []).len > 0
    check environmentFileRefusal("a.service", "/run/repro/secrets/a/env", []) == ""
    check environmentFileRefusal("a.service", "/run/repro/secrets/a/../b/env", []).len > 0
    check environmentFileRefusal("a@x.service", "/run/repro/secrets/a@x/env", []).len > 0
    check environmentFileRefusal("a.service", "/etc/default/a", []).len > 0
    check environmentFileRefusal("a.service", "/etc/default/a", ["/etc/default/a"]) == ""
    check environmentFileRefusal("a.service", "-" & Prefix & "/etc/env", []) == ""
  test "parse time and the effective check":
    check "neither in the add-on's store" in refused(unitStanza("a.service",
      "EnvironmentFile=/run/repro/secrets/b/env\n" & svc))
    check "neither in the add-on's store" in refused(unitStanza("a.service",
      "EnvironmentFile=/etc/shadow\n" & svc))
    var e = goodInput()
    e.show["EnvironmentFiles"] = "/run/repro/secrets/b/env (ignore_errors=no)"
    check "neither in the add-on's store" in problemsOf(e)
    e = goodInput()
    e.ownFiles = @["/etc/a/env"]
    e.show["EnvironmentFiles"] = "/etc/a/env (ignore_errors=no)"
    check problemsOf(e) == ""

suite "round 7, finding 1: an adopted EnvironmentFile= (§13 decision 50, amended)":
  # The owner's third case: a file the generation adopts, whose current
  # bytes are the ones its ledger records. Falsifier: adopted-files-unverified.
  test "adopted with the ledger's digest: accepted":
    if fileExists("/etc/passwd"):
      let digest = sha256OfFile("/etc/passwd")
      check environmentFileProblem("/etc/passwd", "a", [],
        {"/etc/passwd": digest}.toTable) == ""
  test "the same path not adopted, or with other bytes, is refused":
    if fileExists("/etc/passwd"):
      check "neither in a store object" in environmentFileProblem("/etc/passwd", "a")
      let why = environmentFileProblem("/etc/passwd", "a", [],
        {"/etc/passwd": sha256Hex("other bytes")}.toTable)
      check "has changed since it was adopted" in why
      check "repro system adopt <its address> --profile <file>" in why
  test "an adopted path that is a link is refused":
    let dir = createTempDir("a9r7-", "-adopt")
    defer: removeDir(dir)
    createSymlink("/etc/passwd", dir / "l")
    check "not a regular file" in environmentFileProblem(dir / "l", "a", [],
      {dir / "l": sha256OfFile("/etc/passwd")}.toTable)
  test "through the effective check":
    if fileExists("/etc/passwd"):
      var e = goodInput()
      e.inspectFile = nil
      e.ownFiles = @["/etc/passwd"]
      e.adoptedFiles = {"/etc/passwd": sha256OfFile("/etc/passwd")}.toTable
      e.show["EnvironmentFiles"] = "/etc/passwd (ignore_errors=no)"
      check problemsOf(e) == ""
      e.adoptedFiles = {"/etc/passwd": sha256Hex("x")}.toTable
      check "has changed since it was adopted" in problemsOf(e)

suite "round 7, finding 2: the start hold and the paths the manager creates":
  test "the hold asserts that / does not exist":
    check "AssertPathExists=!/" in StartHoldText
    check "/run/repro" notin StartHoldText
  test "parse time: listeners, directories and links in the add-on's trees":
    check refused(plain & rawUnit("a.socket",
      "[Socket]\nListenStream=/run/repro/floor-hold/never\n")).len > 0
    check refused(plain & rawUnit("a.socket",
      "[Socket]\nListenStream=/run/repro/x.sock\n")).len > 0
    for d in ["RuntimeDirectory=repro/floor-hold/never",
              "StateDirectory=repro", "RuntimeDirectory=repro-agent-x",
              "RuntimeDirectory=a:systemd/system/x.service.d",
              "CacheDirectory=a:../x"]:
      checkpoint d
      check refused(unitStanza("a.service", d & "\n" & svc)).len > 0
    check refused(unitStanza("a.service", "RuntimeDirectory=a-rt:a-link\n" & svc)) == ""
  test "the effective check: the add-on's trees, links, someone else's path":
    var e = goodInput()
    e.show["RuntimeDirectory"] = "repro/floor-hold/never"
    check "in the add-on's own tree" in problemsOf(e)
    e = goodInput()
    e.show["RuntimeDirectorySymlink"] = "a-rt:systemd/system/x.service.d"
    check "a directory's link is one name" in problemsOf(e)
    e = goodInput()
    e.show["RuntimeDirectory"] = "systemd"
    e.inspectPath = nil           # the real host: /run/systemd is root's
    if dirExists("/run/systemd"):
      check "belongs to uid 0" in problemsOf(e)
    check managerPathProblem("/nonexistent/a9r7", 1000, false) == ""
  test "the effective activator check refuses a listener in the add-on's tree":
    let show = parseShow("FragmentPath=/etc/systemd/system/a.socket\nDropInPaths=\n")
    let lines = parseShowLines("Listen=/run/repro/floor-hold/never (Stream)\n")
    check activatorProblems("a.socket", show, lines,
      "/etc/systemd/system/a.socket", []).len > 0

suite "round 7, finding 3: each socket option by its rule":
  test "capability-gated and path options are refused":
    for opt in ["Mark=1", "Transparent=yes", "Priority=7", "FreeBind=yes",
                "BindToDevice=eth0", "PassSecurity=yes", "ReusePort=yes",
                "ReceiveBuffer=8M", "TCPCongestion=bbr", "Symlinks=/run/a-l",
                "Writable=yes", "SmackLabel=x"]:
      checkpoint opt
      check refused(plain & rawUnit("a.socket",
        "[Socket]\nListenStream=127.0.0.1:8080\n" & opt & "\n")).len > 0
  test "a unix listener is named for the unit":
    check refused(plain & rawUnit("a.socket",
      "[Socket]\nListenStream=/run/dbus/system_bus_socket\nRemoveOnStop=yes\n")).len > 0
    check refused(plain & rawUnit("a.socket",
      "[Socket]\nListenStream=/run/systemd/a.sock\nDirectoryMode=0777\n")).len > 0
    check refused(plain & rawUnit("a.socket",
      "[Socket]\nListenStream=/run/a/a.sock\nDirectoryMode=0750\n" &
      "RemoveOnStop=yes\nSocketUser=a\nSocketMode=0660\nPriority=6\n")) == ""
  test "the effective check judges the reported options":
    let base = "FragmentPath=/etc/systemd/system/a.socket\nDropInPaths=\n"
    for (k, v) in [("Mark", "1"), ("Transparent", "yes"), ("Priority", "7"),
                   ("ReceiveBuffer", "8388608"), ("Symlinks", "/etc/a.sock"),
                   ("BindToDevice", "eth0"), ("SocketUser", "root")]:
      checkpoint k & "=" & v
      check activatorProblems("a.socket", parseShow(base & k & "=" & v & "\n"),
        parseShowLines("Listen=/run/a.sock (Stream)\n"),
        "/etc/systemd/system/a.socket", []).len > 0
    check activatorProblems("a.socket", parseShow(base & "Mark=-1\nPriority=-1\n"),
      parseShowLines("Listen=/run/a.sock (Stream)\n"),
      "/etc/systemd/system/a.socket", []).len == 0
    check activatorProblems("a.path", parseShow("FragmentPath=/etc/systemd/system/a.path\n" &
      "DropInPaths=\nMakeDirectory=yes\n"), parseShowLines("Paths=PathExists /etc/x\n"),
      "/etc/systemd/system/a.path", []).len > 0
    check activatorProblems("a.socket", parseShow(base),
      parseShowLines("Listen=/etc/a.sock (Stream)\n"),
      "/etc/systemd/system/a.socket", []).len > 0
  test "each refused option's allowed value is what systemd prints for a unit that does not set it":
    const Fixtures = currentSourcePath().parentDir / "fixtures" / "systemd_properties"
    var n = 0
    for kind, f in walkDir(Fixtures):
      let name = f.extractFilename
      if not (name.startsWith("show-all-socket-min-") or
              name.startsWith("show-all-timer-min-") or
              name.startsWith("show-all-path-min-")): continue
      inc n
      var vals = initTable[string, string]()
      for l in lines(f):
        if l.len > 0 and l[0] != '#' and '=' in l:
          vals[l.split('=', 1)[0]] = l.split('=', 1)[1]
      for (k, allowed) in ActivatorDefaults:
        if k in vals:
          checkpoint name & ": " & k & "=" & vals[k]
          check vals[k] in allowed
      if "Priority" in vals: check vals["Priority"] == "-1"
    check n == 12     # socket, timer, path on systemd 252, 255, 257, 259

  test "the effective check applies the parse-time rules to its files":
    let base = "FragmentPath=/etc/systemd/system/a.socket\nDropInPaths=\n"
    check activatorProblems("a.socket", parseShow(base),
      parseShowLines("Listen=/run/a.sock (Stream)\n"),
      "/etc/systemd/system/a.socket", [],
      [(path: "/etc/systemd/system/a.socket",
        content: "[Socket]\nListenStream=/run/a.sock\nFreeBind=yes\n")]).len > 0

suite "round 7, finding 4: system-state units by any route":
  test "through a unit of the profile, at parse time":
    check refused(unitStanza("a.service", svc, "Wants=x.target\n") &
      rawUnit("x.target", "[Unit]\nWants=reboot.target\n")).len > 0
    check refused(unitStanza("a.service", svc, "OnFailure=x.target\n") &
      rawUnit("x.target", "[Unit]\nWants=reboot.target\n")).len > 0
    check refused(unitStanza("a.service", svc, "Wants=x.service\n") &
      rawUnit("x.service", "[Unit]\nOnFailure=x.target\n[Service]\nExecStart=/bin/true\n") &
      rawUnit("x.target", "[Unit]\nRequires=poweroff.target\n")).len > 0
    check refused(unitStanza("a.service", svc, "Wants=x.target\n") &
      rawUnit("x.target", "[Unit]\nWants=y.target\n")) == ""
  test "the extended list, at parse time and in the effective check":
    for t in ["shutdown.target", "final.target", "umount.target",
              "sleep.target", "suspend.target", "hibernate.target",
              "hybrid-sleep.target", "suspend-then-hibernate.target",
              "systemd-suspend.service", "systemd-hibernate.service",
              "runlevel6.target"]:
      checkpoint t
      check refused(unitStanza("a.service", svc, "Wants=" & t & "\n")).len > 0
      var e = goodInput()
      e.show["Wants"] = t
      check "changes the whole system's state" in problemsOf(e)
  test "the effective check follows what reached units start":
    var e = goodInput()
    e.show["Wants"] = "x.target"
    e.startsOf = proc (u: string): seq[string] =
      if u == "x.target": @["y.target"] elif u == "y.target": @["reboot.target"] else: @[]
    check "a.service -> x.target -> y.target -> reboot.target" in problemsOf(e)
  test "job modes and isolation":
    check refused(unitStanza("a.service", svc, "OnFailure=x.target\n") &
      rawUnit("x.target", "[Unit]\nOnFailureJobMode=isolate\n")).len > 0
    check refused(unitStanza("a.service", svc, "Wants=x.target\n") &
      rawUnit("x.target", "[Unit]\nAllowIsolate=yes\n")).len > 0
    for (k, v) in [("OnFailureJobMode", "isolate"), ("OnSuccessJobMode", "flush"),
                   ("AllowIsolate", "yes")]:
      var e = goodInput()
      e.show[k] = v
      checkpoint k
      check problemsOf(e).len > 0
  test "an activator's [Unit], at parse time and in the effective check":
    check refused(plain & rawUnit("a.socket",
      "[Unit]\nOnFailure=reboot.target\n\n[Socket]\nListenStream=/run/a.sock\n")).len > 0
    check refused(plain & rawUnit("a.socket",
      "[Unit]\nWants=x.target\n\n[Socket]\nListenStream=/run/a.sock\n") &
      rawUnit("x.target", "[Unit]\nWants=halt.target\n")).len > 0
    check activatorProblems("a.socket", parseShow("FragmentPath=/etc/systemd/system/a.socket\n" &
      "DropInPaths=\nOnFailure=reboot.target\n"), parseShowLines("Listen=/run/a.sock (Stream)\n"),
      "/etc/systemd/system/a.socket", []).len > 0

suite "round 7, finding 5: the effective half is the authority":
  test "every parse-time refusal has an effective counterpart (source scan)":
    # Every exported refusal of service_floor is called by the effective
    # half -- directly, or by one it calls (named here).
    const CalledInside = {"managerPathRefusal": "floorRefusal",
                          "socketOptionRefusal": "activatorRefusal"}.toTable
    var missing: seq[string]
    var n = 0
    for line in FloorSource.splitLines():
      if not line.startsWith("proc ") or "Refusal*" notin line: continue
      let name = line[5 ..< line.find('*')]
      inc n
      let via = CalledInside.getOrDefault(name, name)
      if (via & "(") notin EffectiveSource: missing.add(name & " (via " & via & ")")
    check n >= 6
    # Every profile-level parse-time check, with what the effective half
    # does instead.
    const Counterparts = {"checkFloorDropIns": "foreignDropInsFor",
      "checkFloorActivators": "activatorProblems",
      "checkFloorReach": "systemStateRoute",
      "checkFloorAccounts": "accountProblems"}.toTable
    for line in ProfileSource.splitLines() & ApplySource.splitLines():
      if not line.startsWith("proc checkFloor"): continue
      let name = line[5 ..< line.find('*')]
      if name notin Counterparts:
        missing.add(name & " (no effective counterpart is named)")
      elif (Counterparts[name] & "(") notin EffectiveSource & ApplySource:
        missing.add(name & " -> " & Counterparts[name])
    check "floorAccountRefusal(" in ApplySource and "accountProblems(" in EffectiveSource
    checkpoint missing.join("; ")
    check missing.len == 0

  test "each parse-time refusal is refused by the effective half alone":
    # (unit lines, service lines): each refused at parse time, then put in
    # the loaded fragment the way a generation the parse-time half let
    # through would install it.
    let corpus = @[
      ("", "User=\n"), ("", "DynamicUser=n\n"), ("", "PAMName=login\n"),
      ("", "TemporaryFileSystem=/srv/t:exec\n"), ("", "EnvironmentFile=/etc/*/a.env\n"),
      ("", "CPUSchedulingPolicy=fifo\n"), ("FailureAction=reboot\n", ""),
      ("", "RuntimeDirectory=repro/x\n"),
      ("", "RuntimeDirectory=a:systemd/system/x.service.d\n"),
      ("OnFailure=reboot.target\n", ""), ("Wants=shutdown.target\n", ""),
      ("OnFailureJobMode=isolate\n", ""), ("", "Group=shadow\n"),
      ("", "SupplementaryGroups=disk\n"), ("JoinsNamespaceOf=x.service\n", ""),
      ("", "ExecStartPost=+/bin/true\n"), ("", "OpenFile=/etc/shadow\n"),
      ("Conflicts=sshd.service\n", ""),
      ("", "RuntimeDirectory=systemd/system/x.service.d\n"),
      ("", "RuntimeDirectory=udev/rules.d\n")]
    for (u, sv) in corpus:
      checkpoint u & sv
      check refused(unitStanza("a.service", svc & sv, u)).len > 0
      var e = goodInput()
      e.loaded = @[(path: fragment, content: withLines(ru, u, sv))]
      check problemsOf(e).len > 0

  test "the read-only bind source, by component, in an owned object":
    var e = goodInput()
    e.show["BindReadOnlyPaths"] = "/repro/store/../../srv/x:" & Prefix
    check "`..`" in problemsOf(e)
    e = goodInput()
    e.show["BindReadOnlyPaths"] = "/repro/store/:" & Prefix
    check "over the executable path" in problemsOf(e)
    e = goodInput()
    e.show["BindReadOnlyPaths"] = "/repro/store/prefixes/other/1/usr:" & Prefix
    check "over the executable path" in problemsOf(e)
    e = goodInput()
    e.storeObjects = @["/repro/store/prefixes/apt-closure-x/1"]
    e.show["BindReadOnlyPaths"] = "/repro/store/prefixes/apt-closure-x/1/usr:" & Prefix
    check problemsOf(e) == ""

  test "a file-judged setting systemd prints is refused":
    var e = goodInput()
    e.show["Sockets"] = "dbus.socket"
    check "this systemd prints it" in problemsOf(e)
    e.show["Sockets"] = "[unprintable]"
    check problemsOf(e) == ""

suite "A13 round 5's caveat: getent's \"not found\" is not an error":
  # Under DynamicUser=yes an authoritative "not found" allocates a dynamic
  # user, so a lookup that failed must refuse. Falsifier:
  # getent-errors-as-absent. The fake getents are scripts in a temporary
  # directory: what is under test is the exit-code reading.
  test "exit 2 is not found; any other failure raises":
    let dir = createTempDir("a9r7-", "-getent")
    defer: removeDir(dir)
    for (n, body) in [("found", "echo 'a:x:1000:1000::/:/bin/false'"),
                      ("absent", "exit 2"), ("broken", "echo nss down >&2; exit 1")]:
      writeFile(dir / n, "#!/bin/sh\n" & body & "\n")
      setFilePermissions(dir / n, {fpUserRead, fpUserWrite, fpUserExec})
    check getentAt(dir / "found", "passwd", "a").found
    check getentAt(dir / "found", "passwd", "a").fields[2] == "1000"
    check not getentAt(dir / "absent", "passwd", "a").found
    expect AccountLookupFailed:
      discard getentAt(dir / "broken", "passwd", "a")
    expect AccountLookupFailed:
      discard getentAt("", "passwd", "a")
  test "a lookup that fails refuses the unit":
    var e = goodInput()
    e.show["DynamicUser"] = "yes"
    e.show["User"] = "a-dyn"
    e.show["Group"] = ""
    e.uidOf = proc (n: string): int = raise newException(AccountLookupFailed, "nss down")
    check "the account databases cannot be read" in problemsOf(e)

suite "A13 round 5: a template instance's dynamic account is the prefix's":
  # systemd's user_from_unit_name(): DynamicUser=yes with no User= names
  # the account after the unit's prefix, so root@x.service runs as root.
  test "parse time and the effective check":
    check "root" in refused(unitStanza("root@x.service",
      "DynamicUser=yes\nExecStart=" & Prefix & "/bin/svc\n", "",
      "  floorExceptions = [\"DynamicUser: allocated\"]\n"))
    var e = goodInput()
    e.unit = "root@x.service"
    e.show["DynamicUser"] = "yes"
    e.show["User"] = ""
    e.show["Group"] = ""
    check "runs as root" in problemsOf(e)
    e.unit = "app@root.service"
    check "runs as root" notin problemsOf(e)

suite "§13 decision 55: Conflicts= names only the profile's own units":
  # Falsifier: conflicts-unchecked.
  test "parse time":
    for t in ["multi-user.target", "sshd.service", "shutdown.target"]:
      checkpoint t
      check "names a unit the profile does not define" in refused(
        unitStanza("a.service", svc, "Conflicts=" & t & "\n"))
    check refused(unitStanza("a.service", svc, "Conflicts=b.service\n") &
      unitStanza("b.service", svc)) == ""
    check refused(unitStanza("a.service", svc, "Conflicts=t@x.service\n") &
      rawUnit("t@.service", "[Service]\nUser=a\nExecStart=" & Prefix & "/bin/svc\n")) == ""
  test "parse time, an activator":
    check "names a unit the profile does not define" in refused(plain &
      rawUnit("a.socket", "[Unit]\nConflicts=ssh.socket\n\n[Socket]\nListenStream=/run/a.sock\n"))
  test "the effective check, from systemd's report and from the files":
    var e = goodInput()
    e.show["Conflicts"] = "shutdown.target"          # what systemd adds itself
    check problemsOf(e) == ""
    e.show["Conflicts"] = "shutdown.target sshd.service"
    check "Conflicts=sshd.service names a unit the generation does not install" in problemsOf(e)
    e.ownUnits = toHashSet(["a.service", "sshd.service"])
    check problemsOf(e) == ""
    e = goodInput()
    e.loaded = @[(path: fragment, content: withLines(ru, "Conflicts=shutdown.target\n", ""))]
    check "names a unit the profile does not define" in problemsOf(e)
  test "the effective check of an activator":
    let base = "FragmentPath=/etc/systemd/system/a.socket\nDropInPaths=\n"
    check activatorProblems("a.socket", parseShow(base & "Conflicts=shutdown.target ssh.socket\n"),
      parseShowLines("Listen=/run/a.sock (Stream)\n"), "/etc/systemd/system/a.socket", []).len > 0
    check activatorProblems("a.socket", parseShow(base & "Conflicts=shutdown.target\n"),
      parseShowLines("Listen=/run/a.sock (Stream)\n"), "/etc/systemd/system/a.socket", []).len == 0

suite "§13 decision 55: the exclusive-predecessor exception is withdrawn":
  # The owner withdrew it (A9 review round 8, finding 2): the predecessor
  # was taken from the unit's own Conflicts=. A floored exclusive successor
  # conflicts only with the profile's units. Falsifier: conflicts-unchecked.
  let excl = "  exclusive = true\n"
  test "parse time: refused, a .service as much as a target":
    for t in ["old.service", "systemd-timedated.service", "multi-user.target"]:
      checkpoint t
      check "names a unit the profile does not define" in refused(unitStanza(
        "a.service", svc, "Conflicts=" & t & "\n", excl))
    check refused(unitStanza("a.service", svc, "Conflicts=b.service\n", excl) &
      unitStanza("b.service", svc)) == ""
  test "the effective check: refused from the files and from systemd's report":
    var e = goodInput()
    e.loaded = @[(path: fragment, content: withLines(ru, "Conflicts=old.service\n", ""))]
    check "names a unit the profile does not define" in problemsOf(e)
    e = goodInput()
    e.show["Conflicts"] = "shutdown.target systemd-timedated.service"
    check "Conflicts=systemd-timedated.service names a unit the generation does not install" in problemsOf(e)

suite "round 7, finding 6: the profile's own memberships at parse time":
  test "passwd.user groups and passwd.group members":
    for pre in ["passwd.user {\n  name = \"a\"\n  groups = [\"sudo\"]\n}\n",
                "passwd.user {\n  name = \"a\"\n  groups = [\"shadow\"]\n}\n",
                "passwd.group {\n  name = \"sudo\"\n  members = [\"a\"]\n}\n"]:
      checkpoint pre
      check "privileged group" in refused(pre & plain)
    check refused("passwd.user {\n  name = \"a\"\n  groups = [\"a-data\"]\n}\n" &
      "passwd.group {\n  name = \"a-data\"\n}\n" & plain) == ""

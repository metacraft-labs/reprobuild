## The hardening floor after A9's review round 6 (ReproOS Add-On Mode spec
## §10.1, *Amended 2026-11-06*), from the reviewer's probe
## (``zz_a9rev6_probe``): each test is a finding the probe recorded red.
##
## - the account systemd uses: ``DynamicUser=yes`` with a ``User=`` naming
##   an existing account is that static account, and it is judged (1);
## - every line of a multi-line property is judged, and the parser keeps
##   every value of every property systemd prints on several lines, in the
##   ``systemctl show --all`` output of systemd 252, 255, 257 and 259 (2);
## - a compared property that is absent refuses (3);
## - every compared property has a rule and appears in systemd's output;
##   the settings systemd prints as ``[unprintable]`` are judged from the
##   files it loaded; a read-only bind over the executable paths (4);
## - a dependency that starts a system-state target (5);
## - and the falsifiers for round 5's store-link acceptance and activator
##   options.
##
## Finding 1 resolves the account with the shared resolver
## (``repro_infra/service_account``) in both halves; its falsifying build
## ``account-as-written`` turns the specifier and uid-alias cases red.
##
## Falsifying builds (each turns its own cases red): ``dynamic-user-trusted``,
## ``show-last-line-only``, ``absent-property-passes``,
## ``file-only-settings-unread``, ``read-only-binds-unjudged``,
## ``state-targets-allowed``, ``activator-options-unchecked``,
## ``environment-file-links-unchecked``.
##
## Mocks: as in ``t_addon_floor_round5``, ``systemctl show`` text (here also
## real ``systemctl show --all`` output, committed as fixtures) and stubs for
## the accounts, because the comparison is under test.

import std/[os, sets, strutils, tables, tempfiles, unittest]

import repro_infra/profile
import repro_infra/errors
import repro_infra/service_floor
import repro_addon/addon_apply
import repro_addon/effective_floor

const
  Prefix = "/repro/store/prefixes/svc/1.0"
  Fixtures = currentSourcePath().parentDir / "fixtures" / "systemd_properties"
  Source = staticRead(currentSourcePath().parentDir.parentDir / "src" /
                      "repro_addon" / "effective_floor.nim")

proc unitStanza(name, service: string; extra = ""): string =
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"[Unit]\n" &
    "Description=x\n\n[Service]\n" & service & "\n[Install]\n" &
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
let ru = rendered(unitStanza("a.service", svc))
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
    of "root", "toor": 0
    of "a", "admx": 1000
    else: -1
  result.groupsOf = proc (n: string): seq[string] = @[n]
  result.gidOf = proc (g: string): int =
    case g
    of "root", "toor": 0
    of "sudo": 27
    of "a", "admx": 1000
    else: -1
  result.inspectFile = proc (p: string): string = ""
  result.userOfUid = proc (uid: int): string = (if uid == 0: "root" else: "")
  result.lines["ExecStartEx"] = @["{ path=" & Prefix & "/bin/svc ; argv[]=" &
    Prefix & "/bin/svc ; flags= ; start_time=[n/a] }"]
  result.loaded = @[(path: fragment, content: ru)]

proc problemsOf(e: EffectiveInput): string = effectiveFloorProblems(e).join("\n")

proc fixtureFiles(): seq[string] =
  for kind, f in walkDir(Fixtures):
    let n = f.extractFilename
    # A service unit's output (round 7 adds socket, timer and path units').
    if n.startsWith("show-all-") and not n.startsWith("show-all-minimal-") and
        not n.startsWith("show-all-socket-") and not n.startsWith("show-all-timer-") and
        not n.startsWith("show-all-path-"): result.add(f)

suite "round 6: the baseline":
  test "a unit that holds its floor has no problem":
    check problemsOf(goodInput()) == ""

suite "round 6, finding 1: the account systemd uses":
  test "DynamicUser=yes with a User= naming a static account in sudo":
    var e = goodInput()
    e.show["DynamicUser"] = "yes"
    e.show["User"] = "admx"
    e.show["Group"] = "admx"
    e.groupsOf = proc (n: string): seq[string] = @["admx", "sudo"]
    check "privileged group sudo" in problemsOf(e)
  test "DynamicUser=yes with a User= naming a uid-0 alias":
    var e = goodInput()
    e.show["DynamicUser"] = "yes"
    e.show["User"] = "toor"
    e.show["Group"] = "toor"
    check "runs as root" in problemsOf(e)
  test "a truly dynamic account is not looked up":
    var e = goodInput()
    e.show["DynamicUser"] = "yes"
    e.show["User"] = "a-dyn"
    e.show["Group"] = "a-dyn"
    check problemsOf(e) == ""
  test "a static group of the configured name wins over DynamicUser=yes":
    var e = goodInput()
    e.show["DynamicUser"] = "yes"
    e.show["User"] = "a-dyn"
    e.show["Group"] = "sudo"
    check "privileged group sudo" in problemsOf(e)
  test "the effective half expands specifiers: %U, %u, an instance named root":
    for (unit, u) in [("a.service", "%U"), ("a.service", "%u"),
                      ("a@root.service", "%i")]:
      var e = goodInput()
      e.unit = unit
      e.show["User"] = u
      e.show["Group"] = ""
      checkpoint unit & " User=" & u
      check "runs as root" in problemsOf(e)
  test "an account getent does not know is refused":
    var e = goodInput()
    e.show["User"] = "ghost"
    e.show["Group"] = "ghost"
    check "which getent does not know" in problemsOf(e)

  # The parse-time half: a User exception lifts the spelling rules (a
  # specifier is not a literal account), never the account systemd uses.
  let userEx = "  floorExceptions = [\"User: an instance account\"]\n"
  test "parse time: %U, %u and %g resolve to root":
    for (k, v) in [("User", "%U"), ("User", "%u"), ("Group", "%g"),
                   ("Group", "%G")]:
      let service = (if k == "User": "User=" & v & "\n" else: "User=a\nGroup=" &
        v & "\n") & "ExecStart=" & Prefix & "/bin/svc\n"
      checkpoint k & "=" & v
      let why = refused(unitStanza("a.service", service, userEx))
      check "root" in why or "gid 0" in why
  test "parse time: %i in a template's own file does not resolve":
    let service = "User=%i\nExecStart=" & Prefix & "/bin/svc\n"
    check "cannot resolve" in refused(unitStanza("a@.service", service, userEx))
    check "runs the service as root" in refused(unitStanza("a@root.service",
      service, userEx))
    check refused(unitStanza("a@app.service", service, userEx)) == ""
  test "parse time: DynamicUser=yes for a unit named like root":
    check "runs the service as root" in refused(unitStanza("root.service",
      "DynamicUser=yes\nExecStart=" & Prefix & "/bin/svc\n",
      "  floorExceptions = [\"DynamicUser: allocated\"]\n"))

suite "round 6, finding 2: every line of a multi-line property":
  test "the first of two EnvironmentFiles and of two symlinks is judged":
    var e = goodInput()
    let text = "EnvironmentFiles=/etc/a/first.env (ignore_errors=no)\n" &
               "EnvironmentFiles=/etc/a/second.env (ignore_errors=no)\n"
    for k, v in parseShow(text): e.show[k] = v
    e.inspectFile = proc (p: string): string =
      (if p == "/etc/a/first.env": "it is not owned by root" else: "")
    check "first.env" in problemsOf(e)
    e = goodInput()
    for k, v in parseShow("StateDirectorySymlink=a:/outside\n" &
                          "StateDirectorySymlink=b:inside\n"): e.show[k] = v
    check "a:/outside" in problemsOf(e)

  test "every value of every multi-line property systemd prints":
    let files = fixtureFiles()
    check files.len >= 2     # systemd 252 and 257 at least
    for f in files:
      var lines: seq[string]
      for l in lines(f):
        if l.len > 0 and l[0] != '#': lines.add(l)
      let parsed = parseShow(lines.join("\n"))
      var count = initCountTable[string]()
      for l in lines: count.inc(l.split('=', 1)[0])
      var multi = 0
      for l in lines:
        let k = l.split('=', 1)[0]
        let v = l.split('=', 1)[1]
        if count[k] > 1 and v.len > 0:
          inc multi
          checkpoint f & ": " & l
          check v in parsed[k]
      check multi > 0

suite "round 6, finding 3: an absent compared property refuses":
  test "a unit with no SystemCallFilter":
    var e = goodInput()
    e.show.del("SystemCallFilter")
    check "SystemCallFilter is missing" in problemsOf(e)
  test "every required property is printed for a unit that sets nothing":
    var n = 0
    for kind, f in walkDir(Fixtures):
      if not f.extractFilename.startsWith("show-all-minimal-"): continue
      inc n
      var seen = initHashSet[string]()
      for l in lines(f):
        if l.len > 0 and l[0] != '#': seen.incl(l.split('=', 1)[0])
      for k in RequiredProps:
        checkpoint f & ": " & k
        check k in seen
    check n >= 2

  test "in real output, a property every systemd prints":
    var e = goodInput()
    e.partialShow = false
    check "TTYPath is missing" in problemsOf(e)

suite "round 6, finding 4: every compared property has a rule and a source":
  test "each compared property is read by a rule":
    var unread: seq[string]
    let body = Source[Source.find("proc writablePlaces*") .. ^1]
    var byTable = initHashSet[string]()
    for k in ScalarFloorKeys: byTable.incl(k)        # one loop compares them
    for (k, _) in DirectoryRoots:
      byTable.incl(k)
      byTable.incl(k & "Symlink")                    # read as k & "Symlink"
    for k in ComparedProps:
      if k in byTable: continue
      if ("\"" & k & "\"") notin body: unread.add(k)
    checkpoint unread.join(" ")
    check unread.len == 0

  test "each compared property appears in systemd's own output":
    var seen = initHashSet[string]()
    for f in fixtureFiles():
      for l in lines(f):
        if l.len > 0 and l[0] != '#': seen.incl(l.split('=', 1)[0])
    var missing: seq[string]
    for k in ComparedProps:
      if k notin seen and k notin ["Transient", "SourcePath"]: missing.add(k)
    checkpoint missing.join(" ")
    check missing.len == 0
    # And the ones it prints as [unprintable] are judged from the files.
    for f in fixtureFiles():
      for l in lines(f):
        if l.endsWith("=[unprintable]"):
          let k = l.split('=', 1)[0]
          check k notin ComparedProps

  test "an [unprintable] value is never judged as a value":
    var e = goodInput()
    for k in FileJudgedProps: e.show[k] = "[unprintable]"
    check problemsOf(e) == ""

  test "LoadCredential, ImportCredential, NFTSet from the loaded files":
    var e = goodInput()
    e.loaded.add((path: "/etc/systemd/system/a.service.d/x.conf",
      content: "[Service]\nLoadCredential=k:/etc/shadow\nImportCredential=*\n" &
               "NFTSet=cgroup:inet:filter:x\n"))
    let p = problemsOf(e)
    check "LoadCredential reads /etc/shadow" in p
    check "ImportCredential=*" in p
    check "NFTSet=cgroup:inet:filter:x" in p

  test "a read-only bind over the executable paths":
    var e = goodInput()
    e.show["BindReadOnlyPaths"] = "/var/lib/x:" & Prefix & "/bin:rbind"
    check "over the executable path" in problemsOf(e)
    e = goodInput()
    e.show["BindReadOnlyPaths"] = "/repro/store/prefixes/apt-closure-x/1/usr:/usr:rbind"
    check problemsOf(e) == ""

suite "round 6, finding 5: a dependency on a system-state target":
  test "OnFailure=reboot.target and the like":
    for (k, t) in [("OnFailure", "reboot.target"), ("OnSuccess", "poweroff.target"),
                   ("Wants", "emergency.target"), ("Upholds", "kexec.target")]:
      checkpoint k & "=" & t
      check "changes the whole system's state" in refused(unitStanza("a.service",
        svc).replace("Description=x\n", "Description=x\n" & k & "=" & t & "\n"))
      var e = goodInput()
      e.show[k] = t
      check "changes the whole system's state" in problemsOf(e)
    check refused(unitStanza("a.service", svc).replace("Description=x\n",
      "Description=x\nOnFailure=a-failed.service\n")) == ""

suite "round 6: falsifiers for round 5's links and activator options":
  test "a link the service's user could swap is refused":
    let dir = createTempDir("a9r6-", "-link")
    defer: removeDir(dir)
    createSymlink("/etc/passwd", dir / "l")
    check "not owned by root" in environmentFileProblem(dir / "l")
  test "an activator's socket options are judged":
    let plain = unitStanza("a.service", svc)
    check "activates a floored service" in refused(plain & rawUnit("a.socket",
      "[Socket]\nListenStream=/run/a.sock\nSymlinks=/etc/a.sock\n"))
    check "activates a floored service" in refused(plain & rawUnit("a.socket",
      "[Socket]\nListenFIFO=/run/a.fifo\n"))

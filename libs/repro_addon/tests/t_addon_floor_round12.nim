## The hardening floor after A9's review round 12 (ReproOS Add-On Mode spec
## §10.1, *Amended 2026-11-13 (A9 adversarial review, round 12)*; §13
## decisions 82 to 85), from the reviewer's probes (``zz_a9rev12_*``):
##
## - a restart outside a switch is accepted only when the unit's
##   InvocationID changed since the record and the directory was born no
##   earlier than 100 ms before the start systemd reports (decision 82;
##   finding 1); in a switch, what was absent at the check and exists after
##   the start is recorded, for a unit started by a dependency or by its
##   activator alike (spec §10.1, round 12; finding 3);
## - a stopped unit's directory passes only if it was born within the
##   unit's last run (decision 83);
## - the run is read in one call (finding 5);
## - a template's directory is judged against the instance that ran
##   (finding 4), and every name of a template reaches one verdict: the
##   same candidate instances whichever name is checked, and a directory
##   refused for one name not accepted for a later one in the same check,
##   and an acceptance written once, after every name, only if no name
##   refused it (issue 2026-11-13-floor-template-observation-instance-refuses-a-
##   directory-its-instance-restart-made);
## - a statx error other than ENOENT/ENOTDIR is not "absent" (finding 6);
## - a reused inode with a new birth time is not the recorded directory
##   (finding 7; decision 76);
## - a listener below a directory its service can write is refused, in both
##   halves (decision 84; finding 2);
## - the one-time migration records existing activator listeners
##   (decision 85).
##
## Falsifying builds, each red on its own test: ``recreated-same-invocation``,
## ``recreated-window-exact``, ``recreated-while-stopped``,
## ``dependency-starts-unrecorded``, ``view-two-calls``,
## ``observation-instance-judged-alone``, ``statx-errors-absent``,
## ``same-identity-ignores-btime``, ``listener-below-writable-allowed``,
## ``migration-skips-listeners``, ``start-step-records-first-unit``,
## ``record-keeps-old-invocation``, ``template-instances-unjudged``,
## ``template-refusal-forgotten``, ``template-acceptance-per-name``,
## ``template-refused-written``, ``revert-holds-any-subject``.
##
## Mocks: as in ``t_addon_floor_round10``: systemd's view and the path
## identities are stand-ins built from what systemd and statx report, since
## the unit test has no service manager of its own to restart a unit; the
## identity and statx-error tests use the real file system, and the view
## test feeds ``hostSystemdView`` a stand-in for ``systemctl show`` that
## changes state between two reads, the race finding 5 names.

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


const Start = 1_794_000_000_000_000_000'i64     # a start, ns since the epoch
const Ms = 1_000_000'i64

let rec = {"/run/a": CreatedDir(unit: "a.service", dev: 1, ino: 2, btime: 50,
                                invocation: "I1")}.toTable

proc view(btime: int64; id = "I2"; stopped = false; stop = 0'i64): SystemdView =
  SystemdView(dynamicUid: -1, btime: btime, invocationId: id,
              invocationStart: Start, stopped: stopped, lastStop: stop)

proc recreated(v: SystemdView): string =
  systemdRecreated("/run/a", "a.service", ["/run/a"], rec, false, v)

suite "round 12 (§13 decision 82): a restart outside a switch":
  test "born up to 100 ms before the start systemd reports, it is the unit's":
    # systemd 252 makes it in the child before it stamps the start: 17.6 ms
    # measured on debian-12.
    check recreated(view(Start - 18 * Ms)) == ""
    check recreated(view(Start - 99 * Ms)) == ""
    check recreated(view(Start + 5 * Ms)) == ""
  test "born earlier than that, it is not":
    check recreated(view(Start - 101 * Ms)) ==
      "it was born more than 100 ms before the unit's last run began"
  test "with the InvocationID the add-on recorded, no new run made it":
    check "the same InvocationID" in recreated(view(Start + 5 * Ms, id = "I1"))
  test "no InvocationID, no start: refused":
    check recreated(view(Start + 5 * Ms, id = "")).len > 0
    var v = view(Start + 5 * Ms)
    v.invocationStart = 0
    check recreated(v).len > 0

suite "round 12 (§13 decision 83): a stopped unit":
  test "born within its last run, it passes":
    check recreated(view(Start + 5 * Ms, stopped = true, stop = Start + 900 * Ms)) == ""
  test "born after its last run ended, it does not":
    check recreated(view(Start + 950 * Ms, stopped = true, stop = Start + 900 * Ms)) ==
      "the unit is not running, and the tree was born after its last run ended"
  test "no end reported, it does not":
    check recreated(view(Start + 5 * Ms, stopped = true)).len > 0

suite "round 12 (spec §10.1): recorded at the start step":
  let state = createTempDir("a9r12-", "-rec")
  createDir(state / "addon")
  test "absent at the check, made by the start: recorded, whenever the run began":
    let ident = proc (p: string): PathIdentity =
      if p in ["/run/t", "/run/sk"]: (true, 4'u64, uint64(p.len), 77'i64)
      else: (false, 0'u64, 0'u64, 0'i64)
    # A template instance a Wants= pulled in (its start stamped after the
    # directory was born), and a socket-activated service whose socket's
    # start made /run/sk and which has not run (finding 3).
    let invOf = proc (u: string): tuple[id: string; start: int64] =
      if u == "t@1.service": ("I5", Start) else: ("", 0'i64)
    recordStartedSince(state, [("/run/t", "t@1.service"), ("/run/sk", "sk.service"),
                               ("/run/gone", "g.service")], invOf, ident)
    let r = readCreatedDirs(state)
    check r.getOrDefault("/run/t").unit == "t@1.service"
    check r.getOrDefault("/run/sk").unit == "sk.service"
    check "/run/gone" notin r
  removeDir(state)

suite "round 12 (§13 decision 82): a start refreshes the run on the record":
  test "a switch's start records its run for an unchanged directory, so a later tree in that run is refused":
    let state = createTempDir("a9r12-", "-inv")
    defer: removeDir(state)
    createDir(state / "addon")
    let ident = proc (p: string): PathIdentity = (true, 4'u64, 5'u64, 77'i64)
    # Recorded for run I1 (an acceptance of a remade directory) ...
    recordCreatedDirs(state, "a.service", [("/var/lib/a", "a.service")], ident,
                      invocation = "I1")
    check readCreatedDirs(state)["/var/lib/a"].invocation == "I1"
    # ... then this switch restarted the unit: run I2, the same directory.
    recordCreatedDirs(state, "a.service", [("/var/lib/a", "a.service")], ident,
                      invocation = "I2")
    let r = readCreatedDirs(state)
    check r["/var/lib/a"].invocation == "I2"
    # A tree made later in run I2 has the same InvocationID as the record.
    check "the same InvocationID" in systemdRecreated("/var/lib/a", "a.service",
      ["/var/lib/a"], r, false, view(Start + 5 * Ms, id = "I2"))
  test "so does the start step for a unit it did not start by name":
    let state = createTempDir("a9r12-", "-inv2")
    defer: removeDir(state)
    createDir(state / "addon")
    let ident = proc (p: string): PathIdentity = (true, 4'u64, 5'u64, 77'i64)
    recordCreatedDirs(state, "t@1.service", [("/run/t", "t@1.service")], ident,
                      invocation = "I1")
    recordStartedSince(state, [("/run/t", "t@1.service")],
      proc (u: string): tuple[id: string; start: int64] = ("I3", Start), ident)
    check readCreatedDirs(state)["/run/t"].invocation == "I3"

suite "round 12: what a revert holds":
  let own = toHashSet(["a.service", "t@.service", "a.socket", "ctl.service"])
  let floored = @["a.service", "t@.service"]
  test "a refused unit of the generation, a template for its instance":
    check revertHeldUnits(["a.service: x [rule:existing-tree key:RuntimeDirectory]",
                           "t@1.service: y [rule:existing-tree key:RuntimeDirectory]",
                           "t@repro-addon-observe.service: y [rule:existing-tree]"],
                          own, floored) == @["a.service", "t@.service"]
  test "an activator of the generation is held by its own name":
    check revertHeldUnits(["a.socket: listener /run/a: it exists [rule:existing-listener]"],
                          own, floored) == @["a.socket"]
  test "a subject the generation does not install holds its floored units, never itself":
    # A host's type-wide drop-in is reported under `service`; a hold named
    # so would keep every service on the host from starting.
    let h = revertHeldUnits(["service: /run/systemd/system/service.d/x.conf: a drop-in " &
                             "the add-on did not install [rule:foreign-drop-in key:DropInPaths]",
                             "the unit search path: e [rule:search-path]"], own, floored)
    check h == @["a.service", "t@.service"]
    check "service" notin h

suite "round 12, finding 5: the run in one snapshot":
  test "the start, the stop and the state come from the same read":
    let d = createTempDir("a9r12-", "-view")
    defer: removeDir(d)
    createDir(d / "a")
    var n = 0
    # First read: stopped after its last run; any later read: running again
    # (a socket started it in between).
    let fake = proc (args: seq[string]): tuple[exitCode: int; output: string] =
      inc n
      if n == 1:
        (0, "InvocationID=I1\nInactiveExitTimestamp=Fri 2026-11-13 02:00:00.000000 UTC\n" &
            "InactiveEnterTimestamp=Fri 2026-11-13 02:00:01.000000 UTC\nActiveState=inactive\n")
      else:
        (0, "InvocationID=I3\nInactiveExitTimestamp=Fri 2026-11-13 02:10:00.000000 UTC\n" &
            "InactiveEnterTimestamp=Fri 2026-11-13 02:00:01.000000 UTC\nActiveState=active\n")
    let v = hostSystemdView(d / "a", "a.service", initTable[string, string](), fake)
    check v.invocationId == "I1"
    check v.stopped                     # the state of the run whose start it holds
    check v.lastStop > v.invocationStart
  test "parseUnitRun reads the four fields":
    let r = parseUnitRun("InvocationID=abc\nInactiveExitTimestamp=Fri 2026-11-13 02:00:00.500000 UTC\n" &
      "InactiveEnterTimestamp=\nActiveState=activating\n")
    check r.id == "abc" and r.running and r.stop == 0 and r.start > 0

suite "round 12, finding 4: a template's directory, judged by the instance that ran":
  test "the observation instance does not refuse what an instance's restart made":
    for n in ["foo@repro-addon-observe.service", "foo@1.service"]:
      checkpoint n
      var e = goodInput()
      e.unit = n
      e.show["RuntimeDirectory"] = "foo"
      e.inspectPath = existing(["/run/foo"])
      e.pathIdentity = proc (p: string): PathIdentity = (true, 4'u64, 9'u64, Start + 5 * Ms)
      e.createdDirs = {"/run/foo": CreatedDir(unit: "foo@1.service", dev: 4, ino: 5,
                                              btime: 6, invocation: "I1")}.toTable
      # Only the instance that ran has a run; the observation instance never
      # starts.
      e.systemdView = proc (p, u: string; s: ShowProps): SystemdView =
        if u == "foo@1.service": view(Start + 5 * Ms)
        else: SystemdView(dynamicUid: -1, btime: Start + 5 * Ms, stopped: true)
      var seen: seq[string]
      e.onRecreated = proc (p, u: string; v: SystemdView): bool =
        seen.add(u)
        true
      check "[rule:existing-tree" notin problemsOf(e)
      check seen == @["foo@1.service"]   # recorded for the instance that ran

suite "round 12, finding 4: recorded for the observation instance":
  test "a directory recorded for the observation instance is judged by the instance running":
    var e = goodInput()
    e.unit = "foo@repro-addon-observe.service"
    e.show["RuntimeDirectory"] = "foo"
    e.inspectPath = existing(["/run/foo"])
    e.pathIdentity = proc (p: string): PathIdentity = (true, 4'u64, 9'u64, Start + 5 * Ms)
    e.createdDirs = {"/run/foo": CreatedDir(unit: "foo@repro-addon-observe.service",
                                            dev: 4, ino: 5, btime: 6)}.toTable
    e.systemdView = proc (p, u: string; s: ShowProps): SystemdView =
      if u == "foo@2.service": view(Start + 5 * Ms)
      else: SystemdView(dynamicUid: -1, btime: Start + 5 * Ms, stopped: true)
    e.runningInstances = proc (t: string): seq[string] =
      check t == "foo@.service"
      @["foo@2.service"]
    var seen: seq[string]
    e.onRecreated = proc (p, u: string; v: SystemdView): bool =
      seen.add(u)
      true
    check "[rule:existing-tree" notin problemsOf(e)
    check seen == @["foo@2.service"]
  test "the start step records a template's directory for the instance that ran":
    let state = createTempDir("a9r12-", "-obs")
    defer: removeDir(state)
    createDir(state / "addon")
    let ident = proc (p: string): PathIdentity = (true, 4'u64, 5'u64, 77'i64)
    let invOf = proc (u: string): tuple[id: string; start: int64] =
      if u == "foo@1.service": ("I7", Start) else: ("", 0'i64)
    recordStartedSince(state, [("/run/foo", "foo@repro-addon-observe.service"),
                               ("/run/foo", "foo@1.service")], invOf, ident)
    let c = readCreatedDirs(state).getOrDefault("/run/foo")
    check c.unit == "foo@1.service" and c.invocation == "I7"

proc templateInput(name, recUnit: string;
                   viewOf: proc (u: string): SystemdView;
                   seen: ref seq[string]): EffectiveInput =
  ## One name of the template ``foo@.service`` with ``/run/foo`` recorded
  ## for ``recUnit`` and made again since; ``seen`` collects each unit
  ## ``onRecreated`` is called with.
  result = goodInput()
  result.unit = name
  result.show["RuntimeDirectory"] = "foo"
  result.inspectPath = existing(["/run/foo"])
  result.pathIdentity = proc (p: string): PathIdentity = (true, 4'u64, 9'u64, Start + 5 * Ms)
  result.createdDirs = {"/run/foo": CreatedDir(unit: recUnit, dev: 4, ino: 5,
                                               btime: 6, invocation: "I1")}.toTable
  result.systemdView = proc (p, u: string; s: ShowProps): SystemdView = viewOf(u)
  result.runningInstances = proc (t: string): seq[string] = @[]
  result.onRecreated = proc (p, u: string; v: SystemdView): bool =
    seen[].add(u)
    true

suite "round 12, finding 4 (issue 2026-11-13): one verdict for every name of a template":
  test "recorded for the observation instance, its instance stopped after the run that made it":
    # Written by an engine that recorded a template's directory for its
    # observation instance; foo@x, which the generation names, ran, systemd
    # made the directory in that run, and it has stopped since (§13
    # decision 83). Nothing runs now, so only the generation's instances
    # name the instance that ran.
    let vo = proc (u: string): SystemdView =
      if u == "foo@x.service": view(Start + 5 * Ms, stopped = true, stop = Start + 900 * Ms)
      else: SystemdView(dynamicUid: -1, btime: Start + 5 * Ms, stopped: true)
    for n in ["foo@repro-addon-observe.service", "foo@x.service"]:
      checkpoint n
      let seen = new seq[string]
      var e = templateInput(n, "foo@repro-addon-observe.service", vo, seen)
      e.templateInstances = @["foo@x.service"]
      check "[rule:existing-tree" notin problemsOf(e)
      check seen[] == @["foo@x.service"]   # recorded for the instance that ran
  test "a directory refused for one name is not accepted for a later name of the same check":
    # systemd's state changes between the two names' reads: refused for the
    # observation instance (foo@x's run is the recorded one), then foo@x
    # restarted, which would accept it for foo@x.
    var restarted = false
    let vo = proc (u: string): SystemdView =
      if u == "foo@x.service" and restarted: view(Start + 5 * Ms)
      elif u == "foo@x.service": view(Start + 5 * Ms, id = "I1")
      else: SystemdView(dynamicUid: -1, btime: Start + 5 * Ms, stopped: true)
    # Without the shared set the second name accepts: the split is real.
    block:
      restarted = false
      let seen = new seq[string]
      var a = templateInput("foo@repro-addon-observe.service", "foo@x.service", vo, seen)
      a.runningInstances = proc (t: string): seq[string] = @["foo@x.service"]
      check "[rule:existing-tree" in problemsOf(a)
      restarted = true
      var b = templateInput("foo@x.service", "foo@x.service", vo, seen)
      b.runningInstances = proc (t: string): seq[string] = @["foo@x.service"]
      check "[rule:existing-tree" notin problemsOf(b)
      check seen[] == @["foo@x.service"]
    # Shared, as effectiveFloorCheck shares it between a template's names.
    restarted = false
    let refusedSet = new HashSet[string]
    refusedSet[] = initHashSet[string]()
    let seen = new seq[string]
    var a = templateInput("foo@repro-addon-observe.service", "foo@x.service", vo, seen)
    a.runningInstances = proc (t: string): seq[string] = @["foo@x.service"]
    a.templateRefused = refusedSet
    check "[rule:existing-tree" in problemsOf(a)
    check "/run/foo" in refusedSet[]
    restarted = true
    var b = templateInput("foo@x.service", "foo@x.service", vo, seen)
    b.runningInstances = proc (t: string): seq[string] = @["foo@x.service"]
    b.templateRefused = refusedSet
    check "[rule:existing-tree" in problemsOf(b)
    check seen[].len == 0             # the record is not rewritten
  test "the effective check shares one refused set between a template's names":
    # (Read into a flag: a failed check would print the whole source.)
    let sharesRefused = "templateRefused: tmplRefused" in ApplySource
    let passesInstances = "templateInstances: tmplInstances" in ApplySource
    let commitsOnce = "commitRecreatedProblems(tentative, tmplRefused[]," in ApplySource
    check sharesRefused
    check passesInstances
    check commitsOnce

proc heldInput(name: string; vo: proc (u: string): SystemdView;
               refusedSet: ref HashSet[string];
               held: ref seq[RecreatedAcceptance]): EffectiveInput =
  ## A name of ``foo@.service`` as ``effectiveFloorCheck`` checks it: an
  ## acceptance is held (``noteRecreated``), not written, until every name
  ## has been checked.
  result = templateInput(name, "foo@x.service", vo, new seq[string])
  result.runningInstances = proc (t: string): seq[string] = @["foo@x.service"]
  result.templateRefused = refusedSet
  result.onRecreated = proc (p, u: string; v: SystemdView): bool =
    noteRecreated(held[], name, p, u, "RuntimeDirectory", v)
    true

suite "round 12, finding 4 (issue 2026-11-13): a template's acceptance written once, after every name":
  test "accepted under both names: recorded and logged once":
    let vo = proc (u: string): SystemdView =
      if u == "foo@x.service": view(Start + 5 * Ms)
      else: SystemdView(dynamicUid: -1, btime: Start + 5 * Ms, stopped: true)
    let refusedSet = new HashSet[string]
    refusedSet[] = initHashSet[string]()
    let held = new seq[RecreatedAcceptance]
    for n in ["foo@repro-addon-observe.service", "foo@x.service"]:
      check "[rule:existing-tree" notin problemsOf(heldInput(n, vo, refusedSet, held))
    var writes: seq[string]
    var written: seq[RecreatedAcceptance]
    let problems = commitRecreatedProblems(held[], refusedSet[],
      proc (p, u: string; v: SystemdView): bool =
        writes.add(p & " " & u)
        true, written)
    check writes == @["/run/foo foo@x.service"]   # one record, one audit line
    check written.len == 1 and problems.len == 0
    check written[0].names == @["foo@repro-addon-observe.service", "foo@x.service"]
  test "accepted under the first name, refused under a later one: nothing written":
    var restarted = true
    let vo = proc (u: string): SystemdView =
      if u == "foo@x.service" and restarted: view(Start + 5 * Ms)
      elif u == "foo@x.service": view(Start + 5 * Ms, id = "I1")
      else: SystemdView(dynamicUid: -1, btime: Start + 5 * Ms, stopped: true)
    let refusedSet = new HashSet[string]
    refusedSet[] = initHashSet[string]()
    let held = new seq[RecreatedAcceptance]
    check "[rule:existing-tree" notin
      problemsOf(heldInput("foo@repro-addon-observe.service", vo, refusedSet, held))
    # systemd now reports the recorded run: no run made it, so refused.
    restarted = false
    check "[rule:existing-tree" in problemsOf(heldInput("foo@x.service", vo, refusedSet, held))
    var writes = 0
    var written: seq[RecreatedAcceptance]
    discard commitRecreatedProblems(held[], refusedSet[],
      proc (p, u: string; v: SystemdView): bool =
        inc writes
        true, written)
    check writes == 0                 # the refused check rewrites no record
    check written.len == 0
  test "a write that fails refuses the directory under each name that accepted it":
    var held: seq[RecreatedAcceptance]
    noteRecreated(held, "foo@repro-addon-observe.service", "/run/foo", "foo@x.service",
                  "RuntimeDirectory", view(Start + 5 * Ms))
    noteRecreated(held, "foo@x.service", "/run/foo", "foo@x.service",
                  "RuntimeDirectory", view(Start + 5 * Ms))
    var written: seq[RecreatedAcceptance]
    let problems = commitRecreatedProblems(held, initHashSet[string](),
      proc (p, u: string; v: SystemdView): bool = false, written)
    check written.len == 0
    check problems.len == 2
    for l in problems:
      check "could not be recorded and logged" in l
      check l.endsWith("[rule:existing-tree key:RuntimeDirectory]")

suite "round 12, finding 6: a statx error is not absent":
  test "ENOENT and ENOTDIR are absent; ELOOP is a path with no known identity":
    let d = createTempDir("a9r12-", "-statx")
    defer: removeDir(d)
    writeFile(d / "f", "x")
    createSymlink(d / "l2", d / "l1")
    createSymlink(d / "l1", d / "l2")
    check not identityOfPath(d / "none").exists
    check not identityOfPath(d / "f" / "x").exists          # ENOTDIR
    let loop = identityOfPath(d / "l1" / "x")               # ELOOP
    check loop.exists and loop.btime == 0 and loop.ino == 0
    # Such a path is never the unit's and never taken as absent.
    check not createdForUnit(d / "l1" / "x", "a.service", loop, rec,
                             initHashSet[string]())
    check not startMayCreate(d / "l1" / "x", "a.service", loop, rec)

suite "round 12, finding 7 (§13 decision 76): a reused inode with a new birth time":
  test "the same device and inode, born again, is not the recorded directory":
    let r = {"/run/a": CreatedDir(unit: "a.service", dev: 7, ino: 14,
                                  btime: Start, invocation: "I1")}.toTable
    let reused: PathIdentity = (true, 7'u64, 14'u64, Start + 16 * Ms)
    check not createdForUnit("/run/a", "a.service", reused, r, initHashSet[string]())
    let same: PathIdentity = (true, 7'u64, 14'u64, Start)
    check createdForUnit("/run/a", "a.service", same, r, initHashSet[string]())

suite "round 12 (§13 decision 84): a listener below a place its service can write":
  test "below /run/<stem>/<dir>/ with RuntimeDirectory=<stem>: refused":
    let w = floorWritablePlaces(serviceDirectives("[Service]\nRuntimeDirectory=a\n"))
    check "§13 decision 84" in listenerRefusal("a.socket", "/run/a/sub/control",
                                               "a.service", w)
    check "§13 decision 84" in listenerRefusal("a.socket", "/run/a/sub/control",
      "a.service", floorWritablePlaces(serviceDirectives("[Service]\nReadWritePaths=/run/a/sub\n")))
  test "directly at /run/<stem>/<name>, or with nothing writable on the path: allowed":
    let w = floorWritablePlaces(serviceDirectives("[Service]\nRuntimeDirectory=a\n"))
    check listenerRefusal("a.socket", "/run/a/control", "a.service", w) == ""
    check listenerRefusal("a.socket", "/run/a/sub/control", "a.service", []) == ""
    check listenerRefusal("a.socket", "/run/a/sub/control", "a.service",
      floorWritablePlaces(serviceDirectives("[Service]\nStateDirectory=a\n"))) == ""
  test "the effective half reads the service's writable places from systemd":
    check writablePlacesOf(parseShow("RuntimeDirectory=a\nReadWritePaths=-/run/a/x\n")) ==
      @["/run/a/x", "/run/a"]
  test "the parse half refuses the reviewer's activator":
    let svc12 = "User=a\nRuntimeDirectory=a\nExecStart=" & Prefix & "/bin/svc\n"
    let sock = rawUnit("a.socket", "[Socket]\nListenStream=/run/a/sub/control\n" &
                       "Service=a.service\nRemoveOnStop=yes\n")
    check "§13 decision 84" in refused(unitStanza("a.service", svc12) & sock)
    let sock1 = rawUnit("a.socket", "[Socket]\nListenStream=/run/a/control\n" &
                        "Service=a.service\n")
    check refused(unitStanza("a.service", svc12) & sock1) == ""

suite "round 12 (§13 decision 85): the migration records existing listeners":
  test "an older engine's activator listener is recorded for the activator":
    let state = createTempDir("a9r12-", "-mig")
    defer: removeDir(state)
    createDir(state / "addon")
    let svcFile = state / "a.service"
    writeFile(svcFile, "[Service]\nUser=a\n" & FloorMarker & "\n")
    let sockFile = state / "a.socket"
    writeFile(sockFile, "[Socket]\nListenStream=/run/a\nListenStream=/run/b/x\n" &
                        "ListenStream=8080\nService=a.service\n")
    let l = Ledger(entries: @[LedgerEntry(class: lcUnit, path: svcFile, unit: "a.service"),
                              LedgerEntry(class: lcUnit, path: sockFile, unit: "a.socket")])
    let ident = proc (p: string): PathIdentity =
      if p in ["/run/a", "/run/b/x"]: (true, 3'u64, uint64(p.len), 99'i64)
      else: (false, 0'u64, 0'u64, 0'i64)
    let m = migrateCreatedDirs(state, "g1", l, proc (u: string): string = "I0",
      proc (p: string; c: CreatedDir): bool = true, ident)
    let r = readCreatedDirs(state)
    check r.getOrDefault("/run/a").unit == "a.socket"
    check "/run/b/x" notin r            # not named for the service: never recorded
    check m.len == 1

## The hardening floor after A9's review round 8 (ReproOS Add-On Mode spec
## §10.1, *Amended 2026-11-06 (A9 adversarial review, round 8)*; §13
## decision 55 with its exception withdrawn), from the reviewer's probe
## (``zz_a9rev8_probe``):
##
## - every component of every ``*Directory=`` value, in both halves (1);
## - the exclusive-predecessor exception withdrawn (2; ``t_addon_floor_round7``);
## - owned store objects never fall back to the unit's own references, and
##   a host with no recorded digest refuses with its remedy (3);
## - a profile unit a floored unit reaches is held to decision 55 (the
##   reviewer's open question).
##
## Falsifying builds: ``directory-names-unchecked``,
## ``owned-objects-fall-back``, ``reached-conflicts-unchecked``.
##
## Mocks: as in ``t_addon_floor_round7``.

import std/[os, sets, strutils, tables, unittest]

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

suite "round 8: the baseline":
  test "a unit that holds its floor has no problem, and parses":
    check problemsOf(goodInput()) == ""
    check refused(plain) == ""

suite "round 8, finding 1: every component of a *Directory= value":
  const bad = ["RuntimeDirectory=systemd/system/zz-a9r8.service.d",
               "RuntimeDirectory=udev/rules.d",
               "ConfigurationDirectory=systemd/system/zz-a9r8.service.d",
               "StateDirectory=other", "CacheDirectory=a-c/../../x",
               "LogsDirectory=a/b:c", "RuntimeDirectory=a-rt:other",
               "StateDirectory=%n",
               # §13 decision 67: a longer name is another unit's.
               "StateDirectory=a-st", "CacheDirectory=a.c", "LogsDirectory=a_l",
               "RuntimeDirectory=a-rt:a-link"]
  test "parse time":
    for d in bad:
      checkpoint d
      check refused(unitStanza("a.service", d & "\n" & svc)).len > 0
    for d in ["RuntimeDirectory=a", "StateDirectory=a/st", "CacheDirectory=a/c",
              "LogsDirectory=a/l", "StateDirectory=a/sub", "ConfigurationDirectory=a"]:
      checkpoint d
      check refused(unitStanza("a.service", d & "\n" & svc)) == ""
  test "the effective check, from systemd's report":
    for (k, v) in [("RuntimeDirectory", "systemd/system/zz-a9r8.service.d"),
                   ("RuntimeDirectory", "udev/rules.d"),
                   ("ConfigurationDirectory", "systemd/system/zz-a9r8.service.d"),
                   ("StateDirectorySymlink", "a/st:other")]:
      var e = goodInput()
      e.show[k] = v
      checkpoint k & "=" & v
      check problemsOf(e).len > 0
    var e = goodInput()
    e.show["RuntimeDirectory"] = "a/rt a/sub"
    check "is the unit's own" notin problemsOf(e)
    check "plain name" notin problemsOf(e)
  test "the effective check, from the loaded files (the counterpart)":
    var e = goodInput()
    e.loaded = @[(path: fragment, content: ru.replace(FloorMarker,
      "RuntimeDirectory=udev/rules.d\n" & FloorMarker))]
    check "udev is not" in problemsOf(e)
  test "a template's instance is named for its prefix":
    check managerDirectoryRefusal("a@x.service", "RuntimeDirectory", "a/x") == ""
    check managerDirectoryRefusal("a@x.service", "RuntimeDirectory", "a-x").len > 0
    check managerDirectoryRefusal("a@x.service", "RuntimeDirectory", "x").len > 0

suite "round 8, finding 3: owned store objects only, never the unit's say-so":
  test "a bind source among the unit's own references, no digest anywhere":
    var e = goodInput()
    e.storeObjects = @[]
    e.show["BindReadOnlyPaths"] = "/repro/store/prefixes/other/1.0:" & Prefix
    let p = problemsOf(e)
    check "over the executable path" in p
    check "store-verify --adopt-unverified" in p
    e.storeObjects = @["/repro/store/prefixes/other/1.0"]
    check problemsOf(e) == ""
  test "an EnvironmentFile= in the store, no digest anywhere":
    var e = goodInput()
    e.storeObjects = @[]
    e.inspectFile = proc (p: string): string = "it resolves to " & p &
      ", which is neither in a store object this generation owns"
    e.show["EnvironmentFiles"] = Prefix & "/etc/env (ignore_errors=no)"
    check "store-verify --adopt-unverified" in problemsOf(e)

suite "round 8: a profile unit a floored unit reaches (decision 55)":
  test "parse time":
    check "names a unit the profile does not define" in refused(
      unitStanza("a.service", svc, "Wants=x.target\n") &
      rawUnit("x.target", "[Unit]\nConflicts=multi-user.target\n"))
    check "names a unit the profile does not define" in refused(
      unitStanza("a.service", svc, "OnFailure=x.target\n") &
      rawUnit("x.target", "[Unit]\nWants=y.target\n") &
      rawUnit("y.target", "[Unit]\nConflicts=sshd.service\n"))
    check refused(unitStanza("a.service", svc, "Wants=x.target\n") &
      rawUnit("x.target", "[Unit]\nConflicts=y.target\n") &
      rawUnit("y.target", "[Unit]\nDescription=y\n")) == ""
  test "the effective check":
    var e = goodInput()
    e.ownUnits = toHashSet(["a.service", "x.target"])
    e.show["Wants"] = "x.target"
    e.startsOf = proc (u: string): seq[string] = @[]
    e.conflictsOf = proc (u: string): seq[string] =
      if u == "x.target": @["shutdown.target", "multi-user.target"] else: @[]
    check "x.target (reached from a.service): Conflicts=multi-user.target" in problemsOf(e)
    e.conflictsOf = proc (u: string): seq[string] = @["shutdown.target"]
    check problemsOf(e) == ""

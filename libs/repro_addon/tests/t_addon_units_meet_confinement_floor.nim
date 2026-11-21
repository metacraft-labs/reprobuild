## Gate ``t_addon_units_meet_confinement_floor`` (ReproOS Add-On Mode,
## milestone A9; spec §10.1; deployment security policy CONF-1, CONF-4;
## threat model G10, G12).
##
## ``systemd-analyze security --offline=yes`` over every unit text the
## add-on renders -- its own service units (the deploy agent's fetch and
## apply units, the re-assert and secrets units) and a service under the
## ``serviceFloor`` default, from a store prefix and from an apt closure --
## must stay at or below the exposure each one is committed to here
## (``Thresholds``). The score is systemd's own, on the unit text exactly as
## rendered, so a regression in the rendered confinement is a failing check
## rather than a discovery (CONF-4). It is a proxy -- it cannot see whether
## ``ReadWritePaths=`` is overbroad -- so the test also asserts the settings
## the score cannot weigh: the apply unit's ``ReadWritePaths=``, the
## ``serviceFloor``'s exec confinement and its ``NoExecPaths=``.
##
## Falsifying mutation (``-d:reproAddonMutation=apply-unit-without-protect-system``,
## ``scripts/run_addon_unit_mutation.sh t_addon_units_meet_confinement_floor
## apply-unit-without-protect-system``): the apply unit loses
## ``ProtectSystem=strict``, its exposure rises above its threshold: red.
##
## Needs ``systemd-analyze`` with ``--offline`` (systemd 250 or later) on
## ``PATH``: a missing tool is a failure, never a skip. The thresholds use
## systemd's ``--threshold=`` scale (the printed level times ten).
##
## *Mocking.* None: the real renderers, systemd's real analyser.

import std/[os, osproc, strutils, unittest]

import repro_infra/profile
import repro_addon/addon_apply
import repro_addon/generation0

const
  ReproExe = "/repro/store/prefixes/repro-addon/0123456789abcdef/bin/repro"
  ServicePrefix = "/repro/store/prefixes/a9-service/1.0"

  Thresholds = [
    (AgentFetchUnit, 12),
    (AgentApplyUnit, 25),
    (ReassertUnit, 25),
    (SecretsUnit, 25),
    ("a9-store.service", 14),
    ("a9-closure.service", 14)]
    ## Each unit's committed exposure, on ``--threshold=``'s scale: the
    ## level measured with systemd 260 when the floor landed. Lower it when
    ## a unit is hardened further; raising one is a reviewed weakening.

  ClosureLock = staticRead("../../repro_dsl_stdlib/tests/fixtures/" &
                           "apt_closure/debian-trixie-20261001-armhf-node-exporter.lock")

let work = getTempDir() / ("addon-confinement-floor-" & $getCurrentProcessId())
removeDir(work)
createDir(work)

proc analyser(): string =
  result = findExe("systemd-analyze")
  doAssert result.len > 0, "systemd-analyze is not on PATH: this gate " &
    "needs systemd's offline security analyser (systemd 250 or later)"

proc exposure(unitFile: string): tuple[level: string; withinOf: proc(t: int): bool] =
  ## The level systemd prints, and a check against a threshold.
  let exe = analyser()
  let (o, c) = execCmdEx(quoteShellCommand([exe, "security", "--offline=yes",
    "--no-pager", unitFile]))
  doAssert c == 0, "systemd-analyze security failed on " & unitFile & ": " & o
  for l in o.splitLines():
    if "Overall exposure level" in l:
      result.level = l.split(':')[^1].strip()
  let f = unitFile
  result.withinOf = proc(t: int): bool =
    let (_, rc) = execCmdEx(quoteShellCommand([exe, "security",
      "--offline=yes", "--no-pager", "--threshold=" & $t, f]))
    rc == 0

proc ownUnits(): seq[(string, string)] =
  let inp = Gen0Inputs(reproExe: ReproExe,
    agent: AgentUnitsInputs(target: "h1",
      sources: @["http://10.0.2.2:8080/h1/latest.rdm"],
      allowedAddresses: @["10.0.2.2"]))
  for o in generation0Objects(inp):
    if o.kind == ookUnit and o.unit.endsWith(".service"):
      result.add((o.unit, o.content))

proc floorUnits(): seq[(string, string)] =
  ## Two services as the add-on renders them under its default: one that
  ## runs from a store prefix, one that runs an apt closure's binary.
  let text = "systemd.systemUnit {\n  name = \"a9-store.service\"\n" &
    "  content = \"[Unit]\nDescription=A9\n\n[Service]\nUser=a9\n" &
    "ExecStart=" & ServicePrefix & "/bin/a9-service --serve\n\n" &
    "[Install]\nWantedBy=multi-user.target\n\"\n}\n" &
    "systemd.systemUnit {\n  name = \"a9-closure.service\"\n" &
    "  content = \"[Service]\nExecStart=/usr/bin/prometheus-node-exporter\n\"\n" &
    "  aptClosureLock = \"" & ClosureLock & "\"\n}\n"
  for r in parseAddOnUserProfile(text).resources:
    result.add((r.suName, renderedSystemUnitContent(r)))

suite "t_addon_units_meet_confinement_floor":
  test "every rendered add-on unit stays within its committed exposure":
    var all = ownUnits() & floorUnits()
    var seen: seq[string]
    for (name, content) in all:
      let path = work / name
      writeFile(path, content)
      var threshold = -1
      for (n, t) in Thresholds:
        if n == name: threshold = t
      checkpoint name
      check threshold >= 0          # a service unit with no committed level
      if threshold < 0: continue
      let e = exposure(path)
      checkpoint name & ": " & e.level & ", threshold " & $threshold
      echo name, ": ", e.level
      check e.withinOf(threshold)
      seen.add(name)
    for (n, _) in Thresholds:
      checkpoint "rendered: " & n
      check n in seen

  test "what the score cannot weigh":
    var apply, store, closure = ""
    for (n, c) in ownUnits():
      if n == AgentApplyUnit: apply = c
    for (n, c) in floorUnits():
      if n == "a9-store.service": store = c
      if n == "a9-closure.service": closure = c
    check "ProtectSystem=strict\n" in apply
    check "ReadWritePaths=" & PrivilegedWritablePaths & "\n" in apply
    for c in [store, closure]:
      check "NoExecPaths=/\n" in c
      check "MemoryDenyWriteExecute=yes\n" in c
    check "ExecPaths=" & ServicePrefix & "\n" in store
    check "ExecPaths=/repro/store/prefixes/apt-closure-" in closure
    check " /usr\n" in closure
    # No User= in the closure's unit: the floor makes it a dynamic user.
    check "DynamicUser=yes\n" in closure
    check "DynamicUser=yes" notin store

removeDir(work)

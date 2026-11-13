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
## Needs the dev shell's pinned ``systemd-analyze`` (``$REPRO_SYSTEMD_ANALYZE``,
## flake.nix), never the host's on ``PATH``: the score is a function of the
## analyser's version. A missing one is a failure, never a skip. The thresholds
## use systemd's ``--threshold=`` scale (the printed level times ten).
##
## *Each unit is scored alone.* Without ``--root`` an offline analysis loads the
## HOST's unit search path (``/etc``, ``/run``, ``/usr/lib`` ``systemd/system``
## and ``$SYSTEMD_UNIT_PATH``) and applies the drop-ins it finds there -- LXC
## writes ``service.d/zzz-lxc-service.conf`` into every container, relaxing
## ProtectControlGroups, ProtectKernelTunables, ProtectProc and ProcSubset for
## every service. And without ``--security-policy`` it reads the host's
## ``systemd-analyze-security.policy`` from ``/etc/systemd``, ``/run/systemd``,
## ``/usr/local/lib/systemd`` and ``/usr/lib/systemd`` whatever the root, which
## re-weights or drops checks. So each unit is written alone into a private
## root's ``etc/systemd/system``, named rather than passed as a path, and
## analysed with an explicit empty policy and ``$SYSTEMD_UNIT_PATH`` removed
## from the analyser's environment (reprobuild-pm issues
## 2026-11-05-conf-4s-virtualized-class-holds-hosts-that-measure-2-6 and
## 2026-11-12-the-add-on-units-conf-4-gate-scores-the-hosts-drop-ins-with-the-unit).
## https://www.freedesktop.org/software/systemd/man/systemd-analyze.html
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
  result = getEnv("REPRO_SYSTEMD_ANALYZE")
  doAssert result.len > 0 and fileExists(result),
    "REPRO_SYSTEMD_ANALYZE does not name the dev shell's pinned " &
    "systemd-analyze (got '" & result & "'): this gate needs systemd's " &
    "offline security analyser, and the host's would make the score a " &
    "function of the host's systemd version"

proc privateRoot(name, content: string): string =
  ## A root holding only ``name`` and an empty security policy.
  result = work / ("root-" & name)
  removeDir(result)
  createDir(result / "etc/systemd/system")
  writeFile(result / "etc/systemd/system" / name, content)
  writeFile(result / "security-policy.json", "{}\n")

proc analyse(root, name: string; extra: openArray[string] = []): (string, int) =
  ## ``systemd-analyze security`` of ``name`` alone under ``root``.
  var argv = @["env", "-u", "SYSTEMD_UNIT_PATH", analyser(), "security",
    "--offline=yes", "--no-pager", "--root=" & root,
    "--security-policy=" & root / "security-policy.json"]
  argv.add extra
  argv.add name
  execCmdEx(quoteShellCommand(argv))

proc level(output: string): string =
  for l in output.splitLines():
    if "Overall exposure level" in l:
      result = l.split(':')[^1].strip()

proc exposure(name, content: string): tuple[level: string; withinOf: proc(t: int): bool] =
  ## The level systemd prints, and a check against a threshold.
  let root = privateRoot(name, content)
  let (o, c) = analyse(root, name)
  doAssert c == 0, "systemd-analyze security failed on " & name & ": " & o
  result.level = level(o)
  doAssert result.level.len > 0, "no exposure verdict for " & name & ": " & o
  result.withinOf = proc(t: int): bool =
    let (_, rc) = analyse(root, name, ["--threshold=" & $t])
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
      var threshold = -1
      for (n, t) in Thresholds:
        if n == name: threshold = t
      checkpoint name
      check threshold >= 0          # a service unit with no committed level
      if threshold < 0: continue
      let e = exposure(name, content)
      checkpoint name & ": " & e.level & ", threshold " & $threshold
      echo name, ": ", e.level
      check e.withinOf(threshold)
      seen.add(name)
    for (n, _) in Thresholds:
      checkpoint "rendered: " & n
      check n in seen

  test "a host drop-in does not enter a unit's score":
    # LXC's own drop-in, verbatim (distrobuilder lxc.generator,
    # fix_systemd_override_unit, systemd >= 256, unprivileged), on the host's
    # unit search path through $SYSTEMD_UNIT_PATH -- read exactly as
    # /run/systemd/system is, so the case needs neither root nor a container.
    let dropins = work / "host-units" / "service.d"
    createDir(dropins)
    writeFile(dropins / "zzz-lxc-service.conf", "[Service]\nProcSubset=all\n" &
      "ProtectProc=default\nProtectControlGroups=no\nProtectKernelTunables=no\n" &
      "NoNewPrivileges=no\nLoadCredential=\nPrivateNetwork=no\nImportCredential=\n")
    var apply = ""
    for (n, c) in ownUnits():
      if n == AgentApplyUnit: apply = c
    check apply.len > 0
    let clean = exposure(AgentApplyUnit, apply).level
    let saved = getEnv("SYSTEMD_UNIT_PATH")
    let hadSaved = existsEnv("SYSTEMD_UNIT_PATH")
    putEnv("SYSTEMD_UNIT_PATH", work / "host-units" & ":")
    try:
      # Positive control: the unit file passed as a path, with no root, takes
      # the host's drop-in -- the invocation this gate used to make.
      let path = work / AgentApplyUnit
      writeFile(path, apply)
      let (o, _) = execCmdEx(quoteShellCommand([analyser(), "security",
        "--offline=yes", "--no-pager", path]))
      checkpoint "without a private root: " & level(o) & ", alone: " & clean
      check level(o).len > 0
      # The drop-in relaxes settings, so it can only raise the exposure.
      check parseFloat(level(o).split(' ')[0]) > parseFloat(clean.split(' ')[0])
      check exposure(AgentApplyUnit, apply).level == clean
    finally:
      if hadSaved: putEnv("SYSTEMD_UNIT_PATH", saved)
      else: delEnv("SYSTEMD_UNIT_PATH")

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

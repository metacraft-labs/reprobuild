## The plan derived from a record run gives each unit the command line,
## working directory and environment cargo gives it in a real build, and the
## edges built from the plan run exactly those.
##
## THE CONTRACT (the part of it the plan alone completes). The record run
## (`repro-rustc-wrapper --cargo-plan`, the process of the record-only
## graph-production edge) plans the workspace without compiling anything.
## For every unit that takes nothing from a build script's output (an UNFED
## unit: no slot in its argv or environment), the plan's argv, working
## directory and environment, with Reprobuild's paths mapped back to cargo's
## target directory, must equal what a logging `RUSTC_WRAPPER` sees in a real
## cargo build of the same workspace: the transparency oracle of the thin
## cargo edge's wrapper cases. Every unit of the real build must be a unit of
## the plan (same crate, same `-C extra-filename`), and every unit's
## `--extern` links must be the real build's.
##
## THE FIRST CASE, the plan. The five-package workspace of
## `rqe_cg5_plan_fixture` (`writePlanWorkspace`), with build scripts that
## really run in the real build (they print a cfg, a check-cfg, an env and a
## rerun-if directive). The record run and the real build get the same
## closed environment and the same compiler; the real build uses `-j 1`, as
## the record run does, so that cargo's `NUM_JOBS` and jobserver are alike.
## The logger is a shell script; the four variables a shell sets for itself
## (`_`, `SHLVL`, `PWD`, `OLDPWD`) are left out on both sides, and so are
## the certificate variables cargo's own process sets
## (`CargoProcessVariables`), which the plan drops. The same plan is then
## refused as a whole by the edge emitter (`plan_units.planUnitEdges`): it
## holds build scripts, fed units and a proc-macro, which these edges do not
## build yet, and a workspace is never built partly by them. The refusal
## names exactly those, and no unit's directory is created.
##
## THE SECOND CASE, the edges. A workspace whose members declare features
## (`writeFeatureWorkspace`: default features, a feature another member
## asks for, a feature enabling an optional crates.io dependency) and have no
## build script: every unit is a library or binary unit the plan completes.
## Its plan becomes one rustc edge per unit, members and the registry crate
## alike, and the edges run through the real engine and monitor. Each edge's
## argv, working directory and environment, mapped back, must equal what the
## logging wrapper saw in the real build, with the registry crate's remap as
## the one difference; the binaries the edges link must print what cargo's
## print, which names `feat`'s unified features (`fast extra leaf5`). Each
## edge is launched from its declared environment alone: cargo's variables
## without those the dev shell's cargo wrapper changed for itself (`PATH`,
## `SHLVL`, `PWD`, `OLDPWD`, `_`, checked absent), and the toolchain's
## variables, whose `PATH` differs from the record run's and is the only
## `PATH` an edge has. (The dev shell's rustc names its linker itself, so a
## link does not show which `PATH` an edge had; the environment checks
## do.) Planned again
## with another record-run `PATH`, which moves the wrapper's `PATH` in every
## unit's difference, every edge keeps its weak fingerprint.
##
## THE THIRD CASE, through the Rust convention's Mode A path. A workspace
## whose members declare no feature and depend on crates.io crates
## (`writeRegistryWorkspace`: a registry crate with features and a registry
## dependency of its own), emitted by the production Rust convention with the
## registry lift switched on (`REPRO_CARGO_MODE_A_REGISTRY=on`), which runs
## the fetch wave and the record run itself. Every action of the fragment is
## a rustc edge of the plan, and each, as the fragment declares it (argv,
## working directory, environment), mapped back, must equal what the logging
## wrapper saw in a real `cargo build --release --workspace` (the selection
## the convention plans), with the registry crates' remap as the one
## difference and the toolchain's `PATH` as the one variable beyond cargo's.
## Built through the engine and monitor, the binaries print what cargo's
## print.
##
## KNOWN DIFFERENCE, compared explicitly: the plan gives every unit its own
## output directory, so cargo's one `-L dependency=<deps>` becomes one
## `-L dependency=` per unit of the closure (checked against the closure),
## and a `deps` (or profile) directory on the dynamic-library path becomes
## the closure's directories (the real value is expanded the same way and
## compared exactly).
##
## FED UNITS (a slot, or an `OUT_DIR`) are compared too, on everything but
## their slots: the plan's side without its slot tokens, the real side
## without the values the fixture's build scripts printed.
##
## WHAT IS LEFT for later deliverables: completing the fed units (the slots
## filled from the build-script run edges' output by the launcher), the
## directive table's real values with `OUT_DIR` paths, `DEP_*` reaching the
## direct and not the transitive dependent, and the order of slots.
##
## REGISTRY CRATES. Both workspaces depend on crates.io crates in a store
## root (`setupRegistry`); the first on one with a build script. The record
## run is given their prefixes; the real build reads them from the test's
## own copy of each prefix in a vendor directory, so a prefix in the plan
## (and in an edge) maps back to that copy. Their units compare like any
## other.
##
## Falsifying mutations (applied, observed to fail, reverted; see the
## change's reports): mapping a vendor entry to a prefix path guessed from
## the crate's name and version fails the registry units; rewriting a
## `--extern` path by re-deriving the file name (always the `.rmeta`) instead
## of reading the placeholder cargo named fails the unfed build-script compile
## of `mid`, which links `helper`'s `.rlib`; dropping the feature cfgs from
## an edge's argv fails the second case's argv comparison and its binaries'
## output; letting a fed unit through the emitter fails the first case's
## refusal; dropping the registry crate's remap fails the second case (its
## argv check, and the embedded-path scan of its rlib and rmeta); keeping
## the cargo wrapper's variables in an edge's environment fails the second
## case's PATH, wrapper-variable and fingerprint checks; leaving the
## toolchain's variables out of the launch fails its environment checks;
## dropping the registry crates' remap from the convention's edges (passing
## `cargoArgv` instead of the edge's argv) fails the third case's argv
## check.
##
## NO MOCKS: real cargo and rustc, the real wrapper, the real engine and
## monitor. The logging wrapper runs the real compiler with the arguments it
## was given and changes nothing.

import std/[algorithm, os, osproc, sequtils, sets, strutils, tables,
            tempfiles, unittest]

import repro_build_engine
import repro_build_engine/embedded_root_scan
import repro_cargo_edge/[cargo_plan, plan_run, plan_units, record_mode]
import repro_project_dsl
import repro_test_support
import repro_standard_provider/conventions/rust_plan_mode

import ./rqe_cg5_plan_fixture
import ./rqe_cg5_mode_a_support

const
  ShellVariables = ["_", "SHLVL", "PWD", "OLDPWD"]
  PathListVariables = ["LD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH"]
    ## The dynamic-library search paths cargo extends with its `deps` and
    ## profile directories.

proc writeOracleLogger(path, logDir: string) =
  ## A `RUSTC_WRAPPER` that, for every unit line (one naming a crate other
  ## than cargo's `___` probe), writes its argv, working directory and
  ## environment into a new directory under `logDir`, then runs
  ## `"$@"` (rustc, with cargo's arguments) unchanged.
  writeFile(path, "#!/bin/sh\n" &
    "case \" $* \" in\n" &
    "  *\" --crate-name ___ \"*) exec \"$@\" ;;\n" &
    "  *\" --crate-name \"*) ;;\n" &
    "  *) exec \"$@\" ;;\n" &
    "esac\n" &
    "d=$(mktemp -d " & quoteShell(logDir & "/u.XXXXXX") & ")\n" &
    "line=\nfor a in \"$@\"; do line=\"$line$a" & ArgSeparator &
    "\"; done\n" &
    "printf '%s' \"$line\" > \"$d/argv\"\n" &
    "pwd -P > \"$d/cwd\"\n" &
    "env -0 > \"$d/env\"\n" &
    "exec \"$@\"\n")
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

type OracleUnit = object
  argv: seq[string]
  cwd: string
  env: Table[string, string]

proc readOracle(logDir: string): seq[OracleUnit] =
  for dir in walkDirs(logDir / "u.*"):
    var u = OracleUnit(cwd: readFile(dir / "cwd").strip(chars = {'\n'}))
    u.argv = readFile(dir / "argv").split(ArgSeparator).filterIt(it.len > 0)
    for entry in readFile(dir / "env").split('\0'):
      let eq = entry.find('=')
      if eq > 0: u.env[entry[0 ..< eq]] = entry[eq + 1 .. ^1]
    result.add u

proc flag(argv: openArray[string]; name: string): string =
  for i, arg in argv:
    if arg == name and i + 1 < argv.len: return argv[i + 1]

proc codegen(argv: openArray[string]; key: string): string =
  for i, arg in argv:
    if arg == "-C" and i + 1 < argv.len and argv[i + 1].startsWith(key & "="):
      return argv[i + 1][key.len + 1 .. ^1]

proc externs(argv: openArray[string]): seq[string] =
  for i, arg in argv:
    if arg == "--extern" and i + 1 < argv.len: result.add argv[i + 1]
  result.sort()

proc withoutDependencySearch(argv: openArray[string]): seq[string] =
  var i = 0
  while i < argv.len:
    if argv[i] == "-L" and i + 1 < argv.len and
        argv[i + 1].startsWith("dependency="):
      i += 2
      continue
    result.add argv[i]
    inc i

proc dependencySearch(argv: openArray[string]): seq[string] =
  for i, arg in argv:
    if arg == "-L" and i + 1 < argv.len and
        argv[i + 1].startsWith("dependency="):
      result.add argv[i + 1]["dependency=".len .. ^1]
  result.sort()

type
  Tools = object
    wrapper, cargo, rustc: string

  Oracle = object
    ## A real cargo build of a workspace through the logging wrapper.
    units: seq[OracleUnit]
    target, logger: string
    base: Table[string, string]
      ## the build's own environment, as a process started with it sees it

proc homeEnv(dir: string): seq[(string, string)] =
  createDir(dir / "cargo-home")
  createDir(dir / "home")
  @[("CARGO_HOME", dir / "cargo-home"), ("HOME", dir / "home")]

proc findTools(): Tools =
  let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
  result.wrapper = requireBinary(
    reproBinaryPath(repoRoot, "repro-rustc-wrapper"),
    "reprobuild.apps.repro-rustc-wrapper")
  result.cargo = findExe("cargo")
  result.rustc = findExe("rustc")
  doAssert result.cargo.len > 0 and result.rustc.len > 0,
    "cargo and rustc must be on PATH"

proc recordPlan(t: Tools; ws: string; reg: RegistrySetup;
                crates: openArray[CratePrefix];
                devEnv: seq[(string, string)]; work: string;
                cargoArgs: seq[string] = @[]; planDir = ".plan"): CargoPlan =
  ## Lock the workspace, then plan it as the edge does.
  let lock = runClosed(@[t.cargo] & reg.sourceArgs &
    @["generate-lockfile", "--offline"], ws,
    devEnv & homeEnv(work / "lock"))
  checkpoint lock.output
  doAssert lock.code == 0, "cargo generate-lockfile failed"
  let planRel = planDir & "/app.rbsz"
  var recordArgv = @[t.wrapper, "--cargo-plan", "--plan", planRel,
    "--scratch", planDir & "/scratch", "--cargo", t.cargo, "--rustc", t.rustc,
    "--store-root", reg.store]
  for c in crates: recordArgv.add ["--crate", crateArg(c)]
  recordArgv.add "--"
  recordArgv.add cargoArgs
  let record = runClosed(recordArgv, ws, devEnv)
  checkpoint record.output
  doAssert record.code == 0, "the record run failed"
  readCargoPlan(ws / planRel)

proc oracleBuild(t: Tools; ws: string; reg: RegistrySetup;
                 devEnv: seq[(string, string)]; work: string;
                 cargoArgs: seq[string] = @[]): Oracle =
  result.target = work / "oracle-target"
  let logDir = work / "oracle-log"
  createDir(logDir)
  result.logger = work / "oracle-logger"
  writeOracleLogger(result.logger, logDir)
  let oracleEnv = devEnv & homeEnv(work / "oracle")
  let real = runClosed(@[t.cargo,
    "--config", "build.rustc=\"" & t.rustc & "\"",
    "--config", "build.rustc-wrapper=\"" & result.logger & "\"",
    # The record run's two other `--config` values, which cargo mixes
    # into its unit hashes.
    "--config", "build.rustc-workspace-wrapper=\"\"",
    "--config", "build.build-dir=\"" & result.target & "\""] & reg.sourceArgs &
    @["build", "--offline", "--locked", "-j", "1",
    "--target-dir", result.target] & cargoArgs, ws, oracleEnv)
  checkpoint real.output
  doAssert real.code == 0, "the real cargo build failed"
  result.units = readOracle(logDir)
  # The real build's own environment, as a process started with it
  # receives it (a process tracer around the test may add variables to
  # every child; the record run's own environment carries them too).
  let envProbe = runClosed([findExe("env", followSymlinks = false), "-0"], ws,
    oracleEnv)
  checkpoint envProbe.output[0 ..< min(envProbe.output.len, 300)]
  doAssert envProbe.code == 0
  for entry in envProbe.output.split('\0'):
    let eq = entry.find('=')
    if eq > 0: result.base[entry[0 ..< eq]] = entry[eq + 1 .. ^1]

proc matchUnits(plan: CargoPlan; oracle: Oracle): Table[string, OracleUnit] =
  ## Each plan unit's real invocation: the same crate and `-C
  ## extra-filename`, exactly one of each.
  for o in oracle.units:
    let crate = flag(o.argv, "--crate-name")
    let extra = codegen(o.argv, "extra-filename")
    var found = 0
    for u in plan.units:
      if u.crateName == crate and "-" & u.id.split('-')[^1] == extra:
        inc found
        result[u.id] = o
    checkpoint crate & extra
    check found == 1
  check result.len == plan.units.len

type Mapper = object
  ## Reprobuild's paths back to the real build's: each (from, to) pair
  ## replaced, longest first, then the plan's root tokens expanded.
  pairs: seq[(string, string)]
  roots: seq[RecordRoot]

proc mapBack(mp: Mapper; s: string): string =
  var t = s
  for (token, path) in mp.pairs: t = t.replace(token, path)
  expandRecorded(mp.roots, t)

proc mapper(plan: CargoPlan; oracle: Oracle; reg: RegistrySetup; ws: string;
            outRoot = "${out}"; storeRoot = "${store}"): Mapper =
  ## `outRoot` and `storeRoot` are the spellings the mapped text uses for
  ## the output and store roots: the plan's tokens, or an edge's paths.
  for u in plan.units:
    if u.cargoIncrementalDir.len > 0:
      result.pairs.add (outRoot & "/" & u.id & "/incremental",
        oracle.target / u.cargoIncrementalDir)
    result.pairs.add (outRoot & "/" & u.id, oracle.target / u.cargoOutDir)
  for r in plan.runs:
    result.pairs.add (outRoot & r.outDir["${out}".len .. ^1],
      oracle.target / r.cargoOutDir)
  # A registry crate's prefix, in the real build, is the test's own copy
  # of it in its vendor directory.
  for c in reg.crates:
    result.pairs.add (storeRoot & c.prefix[reg.store.len .. ^1],
      reg.testVendor / (c.name & "-" & c.version))
  result.pairs.sort(proc (a, b: (string, string)): int =
    cmp(b[0].len, a[0].len))
  result.roots = parseRecordRoots("project=" & ws &
    (if dirExists("/nix/store"): "\nnix=/nix/store" else: ""))

proc isDirectiveValue(args: openArray[string]; i: int): bool =
  ## The values the fixture's build scripts print: exactly
  ## `rustc-cfg=built_<pkg>` and `rustc-check-cfg=cfg(built_<pkg>)`.
  (args[i] == "--cfg" and i + 1 < args.len and
    args[i + 1].startsWith("built_")) or
  (args[i] == "--check-cfg" and i + 1 < args.len and
    args[i + 1].startsWith("cfg(built_"))

proc compareToOracle(argv: seq[string]; cwd: string;
                     env: seq[(string, string)]; closureDirs: seq[string];
                     fed: bool; o: OracleUnit; oracle: Oracle; mp: Mapper;
                     edge = false) =
  ## One unit's command line, working directory and environment (the
  ## plan's, or an edge's) against the real build's. `closureDirs` are the
  ## closure's directories as `argv` spells them. For a fed unit the slots
  ## are left out of the plan's side and the build scripts' printed values
  ## out of the real side. For an EDGE nothing is hidden on its side: the
  ## variables the dev shell's cargo wrapper and the logging shell set
  ## (`CargoWrapperVariables`) must be absent from it, and are left out of
  ## the real side only, because the edge drops them by design.
  if edge:
    for (name, _) in env:
      checkpoint "edge variable " & name
      check name notin CargoWrapperVariables
  check dependencySearch(argv) == closureDirs
  let planArgv = withoutDependencySearch(argv).filterIt(
    not it.startsWith("${slot:")).mapIt(mp.mapBack(it))
  var realArgv: seq[string]
  block:
    let raw = withoutDependencySearch(o.argv)
    var i = 0
    while i < raw.len:
      if fed and isDirectiveValue(raw, i):
        i += 2
        continue
      realArgv.add raw[i]
      inc i
  checkpoint "plan: " & planArgv.join(" ")
  checkpoint "real: " & realArgv.join(" ")
  check planArgv == realArgv
  check mp.mapBack(cwd) == o.cwd
  # The environment, as a difference from each run's own; the variables
  # cargo documents setting for a crate are kept even when equal.
  var planEnv = initTable[string, string]()
  for (name, value) in env:
    if name in PathListVariables:
      # Closure directories stay as they are; a slot entry has no value in
      # the real build (its scripts print no link-search path).
      var parts: seq[string]
      for entry in value.split(':'):
        if entry.startsWith("${slot:"): continue
        parts.add(if entry in closureDirs: entry else: mp.mapBack(entry))
      planEnv[name] = parts.join(":")
    else:
      planEnv[name] = mp.mapBack(value)
  let depsDirs = toHashSet([oracle.target / "debug" / "deps",
    oracle.target / "debug", oracle.target / "release" / "deps",
    oracle.target / "release"])
  var realEnv = initTable[string, string]()
  for name, value in o.env:
    if name in ShellVariables or name in CargoProcessVariables: continue
    if edge and name in CargoWrapperVariables: continue
    if oracle.base.getOrDefault(name, "\0") == value and
        not cargoSetsVariable(name, false):
      continue
    if name == "CARGO_MAKEFLAGS": continue
    if name == "RUSTC_WRAPPER" and value == oracle.logger: continue
    if fed and name.startsWith("BUILT_"): continue
    if name in PathListVariables:
      # cargo's one `deps` (or profile) directory is, in the plan, the
      # closure's directories: expand it here and compare exactly.
      var parts: seq[string]
      for entry in value.split(':'):
        if entry in depsDirs:
          for dir in closureDirs:
            if dir notin parts: parts.add dir
        else:
          parts.add entry
      realEnv[name] = parts.join(":")
    else:
      realEnv[name] = value
  for name in toSeq(planEnv.keys) & toSeq(realEnv.keys):
    if not edge and name in ShellVariables: continue
    let p = planEnv.getOrDefault(name, "<unset>")
    let r = realEnv.getOrDefault(name, "<unset>")
    checkpoint name & ": plan " & p & " | real " & r
    check p == r

proc realRemoved(o: OracleUnit; oracle: Oracle): seq[string] =
  for name in oracle.base.keys:
    if name notin o.env and name notin ShellVariables:
      result.add name
  result.sort()

proc envPairsOf(entries: openArray[string]): seq[(string, string)] =
  for e in entries:
    let eq = e.find('=')
    result.add (e[0 ..< eq], e[eq + 1 .. ^1])

suite "the plan of a record run":

  test "test_rqe_cg5_plan_completes_to_cargos_argv: every unfed unit's " &
      "argv, working directory and environment equal a real cargo build's":
    let t = findTools()
    let work = createTempDir("cg5-plan-argv-", "")
    defer: removeTestTree(work)   # the store's prefixes are read-only
    let ws = work / "ws"
    writePlanWorkspace(ws, smReal, registry = true)
    let reg = setupRegistry(work, smReal)
    let devEnv = @[("PATH", storeOnlyPath()),
      ("TMPDIR", getEnv("TMPDIR", work))]
    let plan = recordPlan(t, ws, reg, reg.crates, devEnv, work)
    let oracle = oracleBuild(t, ws, reg, devEnv, work)
    let mp = mapper(plan, oracle, reg, ws)

    # The same units as the real build.
    check plan.units.len == 15
    check oracle.units.len == plan.units.len
    let matched = matchUnits(plan, oracle)

    # Every unit's links are the real build's.
    for u in plan.units:
      if u.id notin matched: continue
      checkpoint u.id
      check externs(u.argv).mapIt(mp.mapBack(it)) == externs(matched[u.id].argv)
      if u.outDirRun.len > 0:
        var outDir = ""
        for (name, value) in u.env:
          if name == "OUT_DIR": outDir = mp.mapBack(value)
        check outDir == matched[u.id].env.getOrDefault("OUT_DIR")

    # The unfed units: complete as the plan holds them.
    var unfed: seq[string]
    for u in plan.units:
      if not u.isFed: unfed.add u.crateName
    unfed.sort()
    checkpoint "unfed: " & unfed.join(" ")
    check unfed == @["build_script_build", "build_script_build",
      "build_script_build", "build_script_build", "helper", "helper", "pm",
      "regleaf"]
    # Every unit, fed or not: everything but the slots must be equal.
    for u in plan.units:
      if u.id notin matched: continue
      let o = matched[u.id]
      checkpoint "unit " & u.id & (if u.isFed: " (fed)" else: "")
      var closureDirs: seq[string]
      for c in u.closure: closureDirs.add "${out}/" & c
      closureDirs.sort()
      compareToOracle(u.argv, u.cwd, u.env, closureDirs, u.isFed, o, oracle, mp)
      check u.envRemoved.filterIt(it notin ShellVariables) ==
        realRemoved(o, oracle)

    # The edges: this plan holds units they do not build yet, so it is
    # refused as a whole, naming each, and nothing is created.
    let outRoot = work / "edges-out"
    var refused: seq[(string, string)]
    try:
      discard planUnitEdges(plan, PlanUnitsConfig(projectRoot: ws,
        storeRoot: reg.store, outRoot: outRoot, registryCrates: reg.rows,
        toolchainEnv: @["PATH=" & storeOnlyPath()]))
      checkpoint "the plan was not refused"
      check false
    except PlanUnitsRefusal as err:
      checkpoint err.msg
      refused = err.refused
    var expected: seq[string]
    for r in plan.runs: expected.add r.id
    for u in plan.units:
      if u.buildScriptCompile or u.isFed or u.crateName == "pm":
        expected.add u.id
    expected.sort()
    check refused.mapIt(it[0]) == expected
    for (id, why) in refused:
      let u = plan.units.filterIt(it.id == id)
      if u.len == 1 and u[0].isFed and not u[0].buildScriptCompile:
        check "fed by a build script" in why
      if u.len == 1 and u[0].crateName == "pm":
        check "proc-macro" in why
    for u in plan.units:
      if u.crateName in ["helper", "regleaf"]:
        check u.id notin refused.mapIt(it[0])
    check not dirExists(outRoot)

  test "test_rqe_cg5_plan_completes_to_cargos_argv: the edges built from " &
      "the plan of a workspace whose members declare features run cargo's " &
      "argv and link what cargo links":
    let t = findTools()
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let work = createTempDir("cg5-plan-edges-", "")
    defer: removeTestTree(work)
    let ws = work / "ws"
    writeFeatureWorkspace(ws)
    let reg = setupRegistry(work, smReal)
    # Only the plain registry crate is in this workspace's lock.
    let crates = reg.crates.filterIt(it.name == "regleaf")
    let rows = reg.rows.filterIt(it.name == "regleaf")
    let devEnv = @[("PATH", storeOnlyPath()),
      ("TMPDIR", getEnv("TMPDIR", work))]
    # `--workspace`: the root is a package, so cargo would otherwise build
    # it and its dependencies only, and not `util`'s binary.
    let plan = recordPlan(t, ws, reg, crates, devEnv, work, @["--workspace"])
    let oracle = oracleBuild(t, ws, reg, devEnv, work, @["--workspace"])
    check plan.runs.len == 0
    var names: seq[string]
    for u in plan.units:
      names.add u.crateName
      check not u.isFed
    names.sort()
    check names == @["app", "feat", "regleaf", "util", "util"]
    check oracle.units.len == plan.units.len
    let matched = matchUnits(plan, oracle)

    let outRoot = work / "edges-out"
    # The toolchain's PATH differs from the record run's: a directory of
    # its own holding the linker driver, ahead of the store entries. It is
    # the only PATH an edge gets.
    let tcBin = work / "toolchain-bin"
    createDir(tcBin)
    let cc = findExe("cc")
    require cc.len > 0
    createSymlink(cc, tcBin / "cc")
    let toolchain = @["PATH=" & tcBin & ":" & storeOnlyPath()]
    check toolchain[0] != "PATH=" & storeOnlyPath()
    let edges = planUnitEdges(plan, PlanUnitsConfig(projectRoot: ws,
      storeRoot: reg.store, outRoot: outRoot, registryCrates: rows,
      toolchainEnv: toolchain))
    check edges.len == plan.units.len
    let mp = mapper(plan, oracle, reg, ws, outRoot = outRoot,
      storeRoot = reg.store)
    var ids = initHashSet[string]()
    for e in edges:
      ids.incl e.action.id
    for e in edges:
      let u = e.unit
      checkpoint "edge " & e.action.id
      check e.action.id == "cargo.rustc/" & u.package & "@" & u.version &
        "-" & u.id.split('-')[^1]
      # The edge runs cargo's command line, plus the remap for the registry
      # crate and nothing for a member.
      check e.action.argv == e.cargoArgv & e.argvDifference
      if e.registry:
        check u.package == "regleaf"
        check e.argvDifference.len == 1 and
          e.argvDifference[0].startsWith("--remap-path-prefix=" & reg.store &
            "/prefixes/regleaf/") and
          e.argvDifference[0].endsWith("=regleaf-0.1.0")
      else:
        check e.argvDifference.len == 0
      # Launched from its declared environment alone: cargo's variables and
      # the toolchain's. The toolchain's PATH is the only PATH (the one the
      # dev shell's cargo wrapper put in the unit's difference is dropped).
      check e.action.isolateHostEnvironment
      check e.action.env.sorted == (e.env & toolchain).sorted
      check e.action.env.filterIt(it.startsWith("PATH=")) == toolchain
      check e.depInfo notin e.action.outputs
      for d in e.action.deps: check d in ids
      var closureDirs: seq[string]
      for c in u.closure: closureDirs.add outRoot / c
      closureDirs.sort()
      compareToOracle(e.cargoArgv, e.action.cwd, envPairsOf(e.env),
        closureDirs, false, matched[u.id], oracle, mp, edge = true)

    # The record run's PATH does not reach an edge's key: planned again
    # with another PATH (the wrapper's PATH in each unit's difference moves
    # with it, the positive control), every edge keeps its weak fingerprint.
    let extraBin = ws / "extra-bin"
    createDir(extraBin)
    let devEnv2 = @[("PATH", storeOnlyPath() & ":" & extraBin),
      ("TMPDIR", getEnv("TMPDIR", work))]
    let plan2 = recordPlan(t, ws, reg, crates, devEnv2, work, @["--workspace"],
      planDir = ".plan2")
    proc unitPaths(p: CargoPlan): seq[string] =
      for u in p.units:
        for (name, value) in u.env:
          if name == "PATH": result.add u.id & " " & value
    checkpoint "plan PATHs: " & unitPaths(plan).join(" | ")
    check unitPaths(plan).len > 0
    check unitPaths(plan) != unitPaths(plan2)
    let edges2 = planUnitEdges(plan2, PlanUnitsConfig(projectRoot: ws,
      storeRoot: reg.store, outRoot: outRoot, registryCrates: rows,
      toolchainEnv: toolchain))
    check edges2.len == edges.len
    for e in edges:
      for e2 in edges2:
        if e2.action.id == e.action.id:
          checkpoint "fingerprint of " & e.action.id
          check e2.action.weakFingerprint == e.action.weakFingerprint

    # Through the real engine and monitor.
    let tools = prepareMonitorTools(repoRoot, work / "monitor",
      "cg5-plan-edges")
    putEnv("REPRO_MONITOR_SHIM_LIB", tools.shim)
    let config = BuildEngineConfig(
      cacheRoot: work / "engine-cache",
      runQuotaCliPath: tools.monitorCliPath,
      monitorCliPath: tools.monitorCliPath,
      monitorCliArgs: tools.monitorCliArgs,
      maxParallelism: 1'u32,
      stdoutLimit: 1024 * 1024,
      stderrLimit: 1024 * 1024,
      bypassRunQuota: true)
    var actions: seq[BuildAction]
    for e in edges: actions.add e.action
    let run = runBuild(graph(actions), config)
    check run.results.len == edges.len
    for r in run.results:
      checkpoint r.id & ": " & $r.status & " " & r.reason &
        (if r.stderr.len > 0: "\nstderr: " & r.stderr else: "")
      check r.status == asSucceeded
    for e in edges:
      for o in e.action.outputs:
        checkpoint o
        check fileExists(o) and getFileSize(o) > 0
        # The registry crate's outputs name no store path: the remap is in
        # its argv (the cache's embedded-path scan).
        if e.registry:
          let f = scanOutputForEmbeddedRoots(o, [EmbeddedRootNeedle(
            label: "store", path: absolutePath(reg.store))])
          checkpoint "scan: found=" & $f.found & " " & f.where
          check not f.found

    # The binaries the edges linked print what cargo's print: `feat`'s
    # features as cargo unified them across the build.
    for (crate, bin) in [("app", "app"), ("util", "util")]:
      var built = ""
      for e in edges:
        if e.unit.crateName == crate and "bin" in crateTypes(e.cargoArgv):
          for o in e.action.outputs:
            if extractFilename(o).startsWith(crate & "-"): built = o
      checkpoint crate & ": " & built
      require built.len > 0
      let ours = execProcess(built, options = {})
      let theirs = execProcess(oracle.target / "debug" / bin, options = {})
      checkpoint "edges: " & ours & "cargo: " & theirs
      check ours == theirs
      check "fast extra leaf5 0.1.0" in ours

  test "test_rqe_cg5_plan_completes_to_cargos_argv: the Rust convention's " &
      "Mode A edges for a crates.io workspace run cargo's argv and link " &
      "what cargo links":
    let t = findTools()
    let work = createTempDir("cg5-plan-convention-", "")
    defer: removeTestTree(work)
    let ws = work / "ws"
    writeRegistryWorkspace(ws)
    let reg = setupRegistry(work, smReal, withRegmid = true)
    lockWorkspace(ws, work, reg)
    let env = prepareModeAEnv(work, "cg5-plan-convention")
    putEnv("REPRO_STORE_ROOT", reg.store)
    putEnv(ModeARegistrySwitch, "on")
    defer: delEnv(ModeARegistrySwitch)
    let fragment = emitWorkspace(ws)
    let defs = actionDefs(fragment)
    checkpoint "actions: " & defs.mapIt(it.id).join(" ")
    check defs.len == 5
    let plan = readCargoPlan(ws / PlanFileRel)
    check plan.runs.len == 0
    check plan.units.len == defs.len
    let devEnv = @[("PATH", storeOnlyPath()),
      ("TMPDIR", getEnv("TMPDIR", work))]
    let oracle = oracleBuild(t, ws, reg, devEnv, work, @PlanCargoArgs)
    check oracle.units.len == plan.units.len
    let matched = matchUnits(plan, oracle)
    let outRoot = ws / UnitsOutRel
    let mp = mapper(plan, oracle, reg, ws, outRoot = outRoot,
      storeRoot = reg.store)
    for def in defs:
      checkpoint "edge " & def.id
      var unit: PlanUnit
      var found = false
      for u in plan.units:
        if planUnitEdgeId(u) == def.id:
          unit = u
          found = true
      require found
      check def.isolateHostEnvironment
      let argv = inlineArgvOf(def)
      let registry = unit.cwd.startsWith("${store}/")
      var cargoArgv = argv
      if registry:
        # The one difference from cargo's command line: the remap that keeps
        # the store path out of the crate's outputs.
        check argv.len > 0 and argv[^1].startsWith("--remap-path-prefix=" &
          reg.store & "/prefixes/" & unit.package & "/") and
          argv[^1].endsWith("=" & unit.package & "-" & unit.version)
        cargoArgv = argv[0 ..< ^1]
      else:
        check not argv.anyIt(it.startsWith("--remap-path-prefix="))
      # The environment: cargo's variables, and the toolchain's PATH as the
      # only PATH.
      var cargoEnv: seq[(string, string)]
      var paths = 0
      for (name, value) in def.env:
        if name == "PATH": inc paths
        else: cargoEnv.add (name, value)
      check paths == 1
      var closureDirs: seq[string]
      for c in unit.closure: closureDirs.add outRoot / c
      closureDirs.sort()
      compareToOracle(cargoArgv, def.callArg("cwd"), cargoEnv, closureDirs,
        false, matched[unit.id], oracle, mp, edge = true)

    let run = buildFragment(env, fragment, ws, work / "engine-cache")
    for r in run.results:
      checkpoint r.id & ": " & $r.status & " " & r.reason &
        (if r.stderr.len > 0: "\nstderr: " & r.stderr else: "")
      check r.status == asSucceeded
    for crate in ["app", "util"]:
      var built = ""
      for def in defs:
        if "bin" in inlineArgvOf(def) and
            ("cargo.rustc/" & crate & "@") in def.id:
          for o in def.outputs:
            if extractFilename(o).startsWith(crate & "-") and
                not o.endsWith(".rlib"):
              built = o
      checkpoint crate & ": " & built
      require built.len > 0
      let ours = execProcess(built, options = {})
      let theirs = execProcess(oracle.target / "release" / crate,
        options = {})
      checkpoint "edges: " & ours & "cargo: " & theirs
      check ours == theirs

## The plan derived from a record run gives each unit the command line,
## working directory and environment cargo gives it in a real build.
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
## HOW IT IS OBSERVED. The five-package workspace of `rqe_cg5_plan_fixture`,
## with build scripts that really run in the real build (they print a cfg, a
## check-cfg, an env and a rerun-if directive). The record run and the real
## build get the same closed environment and the same compiler; the real
## build uses `-j 1`, as the record run does, so that cargo's `NUM_JOBS` and
## jobserver are alike. The logger is a shell script; the four variables a
## shell sets for itself (`_`, `SHLVL`, `PWD`, `OLDPWD`) are left out on both
## sides.
##
## KNOWN DIFFERENCE, checked separately rather than compared: the plan gives
## every unit its own output directory, so cargo's one `-L dependency=<deps>`
## becomes one `-L dependency=` per unit of the closure, and a `deps` (or
## profile) directory on the dynamic-library path becomes the closure's
## directories. Those entries are compared as a set against the unit's
## closure and left out of the sequence comparison.
##
## WHAT IS LEFT for later deliverables: the FED units (a slot from a build
## script's directive) are completed by the build-script run edges and the
## launcher that fills the slots; their comparison with the oracle, the
## directive table's real values with `OUT_DIR` paths, `DEP_*` reaching the
## direct and not the transitive dependent, and the order of slots, are
## theirs. Registry dependencies are not in the fixture: the record run does
## not serve cargo the fetched store prefixes yet.
##
## Falsifying mutation (applied, observed to fail, reverted; see the change's
## report): rewriting a `--extern` path by re-deriving the file name (always
## the `.rmeta`) instead of reading the placeholder cargo named fails the
## unfed build-script compile of `mid`, which links `helper`'s `.rlib`.
##
## NO MOCKS: real cargo and rustc, the real wrapper. The logging wrapper runs
## the real compiler with the arguments it was given and changes nothing.

import std/[algorithm, os, sequtils, sets, strutils, tables, tempfiles,
            unittest]

import repro_cargo_edge/[cargo_plan, record_mode]
import repro_test_support

import ./rqe_cg5_plan_fixture

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

suite "the plan of a record run":

  test "test_rqe_cg5_plan_completes_to_cargos_argv: every unfed unit's " &
      "argv, working directory and environment equal a real cargo build's":
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let wrapper = requireBinary(
      reproBinaryPath(repoRoot, "repro-rustc-wrapper"),
      "reprobuild.apps.repro-rustc-wrapper")
    let cargo = findExe("cargo")
    let rustc = findExe("rustc")
    require cargo.len > 0 and rustc.len > 0
    let work = createTempDir("cg5-plan-argv-", "")
    defer: removeDir(work)
    let ws = work / "ws"
    writePlanWorkspace(ws, smReal)
    let devEnv = @[("PATH", getEnv("PATH")),
      ("TMPDIR", getEnv("TMPDIR", work))]
    proc homeEnv(dir: string): seq[(string, string)] =
      createDir(dir / "cargo-home")
      createDir(dir / "home")
      @[("CARGO_HOME", dir / "cargo-home"), ("HOME", dir / "home")]
    let lock = runClosed([cargo, "generate-lockfile", "--offline"], ws,
      devEnv & homeEnv(work / "lock"))
    checkpoint lock.output
    require lock.code == 0

    # The record run, as the edge runs it.
    let planRel = ".plan/app.rbsz"
    let record = runClosed([wrapper, "--cargo-plan", "--plan", planRel,
      "--scratch", ".plan/scratch", "--cargo", cargo, "--rustc", rustc, "--"],
      ws, devEnv)
    checkpoint record.output
    require record.code == 0
    let plan = readCargoPlan(ws / planRel)

    # The real build, with the logging wrapper.
    let oracleTarget = work / "oracle-target"
    let logDir = work / "oracle-log"
    createDir(logDir)
    let logger = work / "oracle-logger"
    writeOracleLogger(logger, logDir)
    let oracleEnv = devEnv & homeEnv(work / "oracle")
    let real = runClosed([cargo,
      "--config", "build.rustc=\"" & rustc & "\"",
      "--config", "build.rustc-wrapper=\"" & logger & "\"",
      "build", "--offline", "--locked", "-j", "1",
      "--target-dir", oracleTarget], ws, oracleEnv)
    checkpoint real.output
    require real.code == 0
    let oracle = readOracle(logDir)
    # The real build's own environment, as a process started with it
    # receives it (a process tracer around the test may add variables to
    # every child; the record run's own environment carries them too).
    let envProbe = runClosed([findExe("env", followSymlinks = false), "-0"], ws, oracleEnv)
    checkpoint envProbe.output[0 ..< min(envProbe.output.len, 300)]
    require envProbe.code == 0
    var oracleBase = initTable[string, string]()
    for entry in envProbe.output.split('\0'):
      let eq = entry.find('=')
      if eq > 0: oracleBase[entry[0 ..< eq]] = entry[eq + 1 .. ^1]

    # Reprobuild's paths mapped back to the real build's target directory.
    var back: seq[(string, string)]
    for u in plan.units:
      if u.cargoIncrementalDir.len > 0:
        back.add ("${out}/" & u.id & "/incremental",
          oracleTarget / u.cargoIncrementalDir)
      back.add ("${out}/" & u.id, oracleTarget / u.cargoOutDir)
    for r in plan.runs:
      back.add (r.outDir, oracleTarget / r.cargoOutDir)
    back.sort(proc (a, b: (string, string)): int = cmp(b[0].len, a[0].len))
    let roots = parseRecordRoots("project=" & ws)
    proc mapBack(s: string): string =
      var t = s
      for (token, path) in back: t = t.replace(token, path)
      expandRecorded(roots, t)
    let depsDirs = toHashSet([oracleTarget / "debug" / "deps",
      oracleTarget / "debug"])
    proc pathListWithoutDeps(value: string): string =
      value.split(':').filterIt(it notin depsDirs).join(":")

    # The same units as the real build.
    check plan.units.len == 10
    check oracle.len == plan.units.len
    var matched = initTable[string, OracleUnit]()
    for o in oracle:
      let crate = flag(o.argv, "--crate-name")
      let extra = codegen(o.argv, "extra-filename")
      var found = 0
      for u in plan.units:
        if u.crateName == crate and "-" & u.id.split('-')[^1] == extra:
          inc found
          matched[u.id] = o
      checkpoint crate & extra
      check found == 1
    check matched.len == plan.units.len

    # Every unit's links are the real build's.
    for u in plan.units:
      if u.id notin matched: continue
      checkpoint u.id
      check externs(u.argv).mapIt(mapBack(it)) == externs(matched[u.id].argv)
      if u.outDirRun.len > 0:
        var outDir = ""
        for (name, value) in u.env:
          if name == "OUT_DIR": outDir = mapBack(value)
        check outDir == matched[u.id].env.getOrDefault("OUT_DIR")

    # The unfed units: complete as the plan holds them.
    var unfed: seq[string]
    for u in plan.units:
      if not u.isFed: unfed.add u.crateName
    unfed.sort()
    check unfed == @["build_script_build", "build_script_build",
      "build_script_build", "helper", "helper", "pm"]
    for u in plan.units:
      if u.isFed or u.id notin matched: continue
      let o = matched[u.id]
      checkpoint "unit " & u.id
      # The closure, as one search directory per unit.
      var closureDirs: seq[string]
      for c in u.closure: closureDirs.add "${out}/" & c
      closureDirs.sort()
      check dependencySearch(u.argv) == closureDirs
      let planArgv = withoutDependencySearch(u.argv).mapIt(mapBack(it))
      let realArgv = withoutDependencySearch(o.argv)
      checkpoint "plan: " & planArgv.join(" ")
      checkpoint "real: " & realArgv.join(" ")
      check planArgv == realArgv
      check mapBack(u.cwd) == o.cwd
      # The environment, as a difference from each run's own.
      var planEnv = initTable[string, string]()
      for (name, value) in u.env:
        planEnv[name] = mapBack(value)
      var realEnv = initTable[string, string]()
      for name, value in o.env:
        if name in ShellVariables: continue
        if oracleBase.getOrDefault(name, "\0") == value: continue
        if name == "CARGO_MAKEFLAGS": continue
        if name == "RUSTC_WRAPPER" and value == logger: continue
        realEnv[name] = value
      for name in toSeq(planEnv.keys) & toSeq(realEnv.keys):
        if name in ShellVariables: continue
        let p = planEnv.getOrDefault(name, "<unset>")
        let r = realEnv.getOrDefault(name, "<unset>")
        checkpoint name & ": plan " & p & " | real " & r
        if name in PathListVariables:
          check pathListWithoutDeps(p) == pathListWithoutDeps(r)
        else:
          check p == r
      var realRemoved: seq[string]
      for name in oracleBase.keys:
        if name notin o.env and name notin ShellVariables:
          realRemoved.add name
      realRemoved.sort()
      check u.envRemoved.filterIt(it notin ShellVariables) == realRemoved

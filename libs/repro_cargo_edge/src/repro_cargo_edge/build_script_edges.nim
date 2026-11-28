## Build-graph edges for one build script of cargo's plan: its compile and
## its run.
##
## In a workspace Reprobuild builds from cargo's plan (`cargo_plan`), a build
## script is two edges:
##
## - THE COMPILE EDGE `cargo.build-script-compile/<package>@<version>-<hash>`
##   (cargo's hash of the unit): the recorded host `bin` unit of the
##   package's `custom-build` target, compiled like any unit of the plan
##   (`plan_units`): cargo's argv with the plan's roots expanded, in cargo's
##   working directory, from the variables cargo set for the unit and the
##   caller's toolchain variables, content-checked and gathered by the
##   monitor. A registry crate's script is compiled from the crate's store
##   prefix with the remap of the registry crate's edge
##   (`crate_compile.remapFlag`), its one argv difference from cargo's. Its
##   output is the script's executable.
## - THE RUN EDGE `cargo.build-script-run/<package>@<version>-<hash>` (the
##   hash of the directory cargo made for the run): the executable run
##   through the run-edge half of the directive interpreter
##   (`build_script_output`, the wrapper's `--build-script-run`), monitored,
##   content-checked (`hybrid`), with the network denied (the engine's
##   default, `netDenied`).
##
## THE RUN EDGE'S ENVIRONMENT. One closed environment serves graph production
## and the run edges: the variables of the project's development
## environment (`BuildScriptEdgesConfig.devEnv`, the environment the record
## run was given, against which the plan stores each run's difference),
## overlaid with the variables cargo set for the run as the plan recorded
## them, without the ones cargo removed. So the script sees what it would see
## under cargo, with these rewritten:
##
## - `OUT_DIR` names the edge's own OUT_DIR, an OPAQUE OUTPUT DIRECTORY
##   (removed before each run, recorded whole, restored exactly);
## - `RUSTC` names the store-root rustc (`BuildScriptEdgesConfig.rustc`);
## - `TMPDIR` names a scratch directory of the edge, emptied before each run
##   and never evidence, so a script's temporary files, or those of a `cc` it
##   runs, are neither outputs nor inputs;
## - `CC`, `CXX` and `AR` name the C toolchain (`CToolchain`): the store-root
##   C toolchain's driver on Linux x86_64, the dev environment's compiler
##   elsewhere, which on macOS must be a wrapped Nix clang, never a system
##   compiler under `/usr/bin` or `/bin`, followed through symbolic links (a
##   platform binary the monitor cannot inject into); its directory goes
##   first on `PATH`, so a script that runs `cc` finds the same driver. The
##   variables that would choose another compiler ahead of `CC` are removed
##   (`isToolchainSelector`): the `cc` crate reads `CC_<target>` (with the
##   target's `-` or `_`), `TARGET_CC` and `HOST_CC` before `CC`, and the
##   same for `CXX`, `AR` and `RANLIB`, and cargo reads
##   `CARGO_TARGET_<TRIPLE>_LINKER`
##   (https://docs.rs/cc/latest/cc/#external-configuration-via-environment-variables,
##   https://doc.rust-lang.org/cargo/reference/config.html#targettriplelinker);
## - `NUM_JOBS` is 1, the edge's one slot, and `CARGO_MAKEFLAGS`, `MAKEFLAGS`
##   and `MFLAGS` are not set: the edge serves no jobserver;
## - the variables a shell sets for itself (`PWD`, `OLDPWD`, `SHLVL`, `_`)
##   are taken from neither the dev environment nor the recorded run, and
##   the recorded `PATH`, which the dev shell's cargo wrapper changes for
##   itself, gives way to the dev environment's: a dev-shell bump that
##   changes only those changes no run edge's key, as for the compile edges.
##   (The engine still sets `PWD` and its own launch variables at launch,
##   outside the key.)
##
## WHAT THE RUN EDGE WRITES. Its `OUT_DIR`; the script's standard output,
## normalised; one normalised directive file per kind
## (`build_script_output.DirectiveKinds`), which the units the run feeds
## read; and the outcome record (`build_script_output.OutcomeFileName`),
## from which, and not from the exit status, a reader tells a refusal from
## a build error. The interpreter has a scratch directory of its own besides
## the script's `TMPDIR`.
## It reads the executable and the interpreter (whose code turns the script's
## output into those files, so it is a declared, content-checked input), and
## whatever the monitor records the script reading, with the
## `rerun-if-changed` paths folded in.
##
## REFUSED HERE, each until the change that builds it, with a message
## naming it (`BuildScriptRefusal`):
##
## - a run that is FED (its dynamic-library path carries another run's
##   link-search output), or whose compile unit is fed: the fed units and
##   their launcher come next;
## - a run that receives `links` metadata (`DEP_<LINKS>_*`) from a provider:
##   its propagation comes after the fed units;
## - a build-script compile with no run (a `links` override in cargo's
##   configuration makes cargo skip the script), which graph production
##   sends to cargo as a whole;
## - a compile unit that is not a host `bin` unit (one passing `--target`,
##   a crate type other than `bin`), writes split debug information or
##   passes `-C prefer-dynamic`, or that cargo gave a toolchain variable, as
##   for any unit of the plan;
## - a registry crate's script with no lock row, not in the store, or not
##   compiled and run from the crate's store prefix.
##
## CREATED-ACTION FORM. Each edge is a `CreatedActionSpec` and the engine's
## own `createdAction` of it, under the caller's governing lock identity, as
## `plan_units`' unit edges are, so an edge built here and one the engine
## creates from its `create-action` record have one key. The run edge's
## spec states every field of it but one: `OUT_DIR` as an opaque output
## directory (`removeBeforeRun`), which no record can carry
## (`BuildScriptEdge.runSpecLacks`).
##
## A workspace is built either wholly by these edges and `plan_units`' or
## wholly by cargo: `buildScriptEdges` returns the edges of every build script
## of the plan or raises `BuildScriptRefusal` naming every one it refuses,
## and creates nothing before every check has passed.
## `buildScriptEdgesOf` gives one run's edges, for a caller that builds part
## of a plan (a test of the edges of one script).

import std/[algorithm, os, sequtils, strutils, tables]

import repro_build_engine
import repro_core/input_check_policy
import repro_lock/identity
import repro_local_store
import repro_cargo_fetch/[crate_compile, crate_rows, crate_store]

import ./[build_script_output, cargo_plan, plan_units, record_mode]

const
  BuildScriptCompileEdgePrefix* = "cargo.build-script-compile/"
  BuildScriptRunEdgePrefix* = "cargo.build-script-run/"
  BuildScriptCompileStatsId* = "rust.build-script-compile"
  BuildScriptRunStatsId* = "rust.build-script-run"
  RunOutDirName* = "out"
  RunDirectivesDir* = "directives"
  RunStdoutFile* = "stdout"
  RunTmpDir* = "tmp"
  RunWorkDir* = "interpreter-tmp"
  ShellVariables = ["PWD", "OLDPWD", "SHLVL", "_"]
    ## `plan_units.CargoWrapperVariables` without `PATH`, which the dev
    ## environment gives a run edge.
  SelectableTools = ["CC", "CXX", "AR", "RANLIB"]
  JobserverVariables = ["CARGO_MAKEFLAGS", "MAKEFLAGS", "MFLAGS"]
  SystemCompilerDirs = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

type
  CToolchain* = object
    ## The C toolchain a run edge's script is given.
    cc*, cxx*, ar*: string  ## absolute paths: `CC`, `CXX` and `AR`
    binDir*: string
      ## An absolute directory whose `cc` is the same driver, put first on
      ## the run's `PATH`.

  BuildScriptEdgesConfig* = object
    units*: PlanUnitsConfig
      ## The roots, the registry crates' lock rows and the toolchain
      ## variables of the compile edges, as for the plan's other units.
    devEnv*: seq[string]
      ## `NAME=value`: the closed environment graph production ran the
      ## record run with, which the plan's run differences are taken
      ## against.
    rustc*: string        ## absolute: the run's `RUSTC`
    cToolchain*: CToolchain
    interpreter*: string
      ## absolute: the `repro-rustc-wrapper` whose `--build-script-run` is
      ## the run edge's process

  BuildScriptRefusal* = object of CatchableError
    ## Build scripts of the plan these edges do not build.
    refused*: seq[(string, string)]
      ## (plan id of the run or compile unit, why), sorted by id

  BuildScriptEdge* = object
    ## One build script's two edges and what a caller or test needs of them.
    run*: PlanRun
    compileUnit*: PlanUnit
    registry*: bool
    compileCargoArgv*: seq[string]
      ## cargo's command line for the compile, expanded on this host
    compileArgvDifference*: seq[string]
      ## what the compile edge adds: the remap of a registry crate
    compileEnv*: seq[string]  ## the variables cargo set for the compile
    executable*: string
    runDir*, outDir*, directivesDir*, stdoutFile*, tmpDir*, workDir*: string
    runArgv*: seq[string]
      ## the script and its arguments, as the interpreter runs them
    runCwd*: string
    runEnv*: seq[string]      ## the run edge's whole environment
    compileSpec*, runSpec*: CreatedActionSpec
      ## the two edges as their `create-action` records state them
      ## (`repro_build_engine.createActionRecord`)
    runSpecLacks*: seq[string]
      ## the fields of `runAction` that `runSpec` cannot state (see `build`)
    compile*, runAction*: BuildAction
      ## `createdAction` of each spec under the configured lock identity,
      ## the run's with `runSpecLacks` set besides

proc buildScriptCompileEdgeId*(u: PlanUnit): string =
  BuildScriptCompileEdgePrefix & u.package & "@" & u.version & "-" &
    u.id[u.id.rfind('-') + 1 .. ^1]

proc buildScriptRunEdgeId*(r: PlanRun): string =
  BuildScriptRunEdgePrefix & r.package & "@" & r.version & "-" &
    r.id[r.id.rfind('-') + 1 .. ^1]

proc directivePath*(directivesDir, kind: string): string =
  directivesDir / directiveFileName(kind)

proc isSystemCompiler*(path: string): bool =
  ## Whether ``path``, followed through symbolic links, is a system binary
  ## under `/usr/bin`, `/bin`, `/usr/sbin` or `/sbin`: on macOS a platform
  ## binary the monitor cannot inject into.
  var real = path
  try:
    real = expandFilename(path)
  except OSError:
    discard
  for p in [path, real]:
    for dir in SystemCompilerDirs:
      if p.startsWith(dir & "/") or p == dir: return true

proc isToolchainSelector*(name, target, host: string): bool =
  ## Whether ``name`` chooses a C toolchain or linker ahead of `CC`, `CXX`,
  ## `AR` and cargo's own linker setting, for a run whose `TARGET` and `HOST`
  ## are ``target`` and ``host`` (see the module docstring).
  for tool in SelectableTools:
    if name in ["TARGET_" & tool, "HOST_" & tool]: return true
    for triple in [target, host]:
      if triple.len == 0: continue
      if name in [tool & "_" & triple, tool & "_" & triple.replace('-', '_')]:
        return true
  for triple in [target, host]:
    if triple.len > 0 and name == "CARGO_TARGET_" &
        triple.toUpperAscii.replace('-', '_').replace('.', '_') & "_LINKER":
      return true

proc checkConfig(cfg: BuildScriptEdgesConfig) =
  ## Raises `ValueError` for a configuration the edges cannot be built from.
  for (what, path) in [("rustc", cfg.rustc),
                       ("interpreter", cfg.interpreter),
                       ("C compiler", cfg.cToolchain.cc),
                       ("C++ compiler", cfg.cToolchain.cxx),
                       ("archiver", cfg.cToolchain.ar)]:
    if path.len == 0 or not path.isAbsolute or not fileExists(path):
      raise newException(ValueError, "the build-script edges need an " &
        "absolute, existing " & what & ", not " & path.escape())
  let bin = cfg.cToolchain.binDir
  if bin.len == 0 or not bin.isAbsolute or not fileExists(bin / "cc"):
    raise newException(ValueError, "the C toolchain's directory must be " &
      "absolute and hold its cc: " & bin.escape())
  when defined(macosx):
    for path in [cfg.cToolchain.cc, cfg.cToolchain.cxx, cfg.cToolchain.ar,
                 bin / "cc"]:
      if isSystemCompiler(path):
        raise newException(ValueError, "the C toolchain of a run edge " &
          "on macOS must be a wrapped Nix clang, not the system's " &
          path & ": the monitor cannot inject into a platform binary")
  for entry in cfg.devEnv:
    if entry.find('=') <= 0:
      raise newException(ValueError, "a development-environment variable " &
        "must be NAME=value: " & entry.escape())

proc expandIn(roots: openArray[RecordRoot]; text, where: string): string =
  try:
    expandRecorded(roots, text)
  except RecordModeError as err:
    raise newException(CargoPlanError, where & ": " & err.msg)

proc registryPrefix(row: CrateRow; storeRoot: string): string =
  ## The verified store prefix of ``row``, or "" when the store lacks it.
  var s = openStore(if storeRoot.len > 0: absolutePath(storeRoot)
                    else: resolveStoreRoot())
  defer: s.close()
  s.presentCratePrefix(row)

proc samePath(a, b: string): bool =
  a == b or (dirExists(a) and dirExists(b) and sameFile(a, b))

proc setVar(env: var seq[(string, string)]; name, value: string) =
  for i in 0 ..< env.len:
    if env[i][0] == name:
      env[i][1] = value
      return
  env.add (name, value)

proc delVar(env: var seq[(string, string)]; name: string) =
  var kept: seq[(string, string)]
  for pair in env:
    if pair[0] != name: kept.add pair
  env = kept

type Prepared = object
  ## One build script's edges, computed in the checking pass, before
  ## anything is written: every field of `BuildScriptEdge` but the actions.
  run: PlanRun
  compileUnit: PlanUnit
  registry: bool
  compileCargoArgv, compileArgvDifference, compileEnv: seq[string]
  executable, runDir, outDir, directivesDir, stdoutFile, tmpDir,
    workDir: string
  runArgv: seq[string]
  runCwd: string
  runEnv: seq[string]
  row: CrateRow
  compileArgv, compileOutputs, compileInputs, compileDeps,
    compileScratch, compileLaunchEnv: seq[string]
  compileCwd, compileOutDir: string

proc prepare(r: PlanRun; cfg: BuildScriptEdgesConfig;
             roots: openArray[RecordRoot];
             byId: Table[string, PlanUnit];
             rows: Table[string, CrateRow];
             refused: var seq[(string, string)]): (bool, Prepared) =
  ## Every check of one run and its compile, and everything its edges
  ## declare, writing nothing. Adds each refusal to ``refused``.
  var p: Prepared
  let before = refused.len
  if r.compileUnit notin byId:
    refused.add (r.id, "names the compile unit " & r.compileUnit &
      ", which the plan does not hold")
    return (false, p)
  let u = byId[r.compileUnit]
  p.run = r
  p.compileUnit = u
  if r.isFed:
    refused.add (r.id, "is fed by the build-script runs " &
      r.fedBy.join(", ") & " (their link-search output on its " &
      "dynamic-library path), and a run is filled from another run's " &
      "output with the fed units, which are not built as edges yet")
  if r.providers.len > 0:
    var names: seq[string]
    for pr in r.providers: names.add "DEP_" & pr.links & "_* from " &
      pr.provider
    refused.add (r.id, "receives links metadata (" & names.join(", ") &
      "), and DEP_* variables are not passed to a run edge yet")
  if not u.buildScriptCompile:
    refused.add (r.id, "runs the unit " & u.id & ", which is not a " &
      "build-script compile")
  if u.isFed:
    refused.add (u.id, "is the compile of a build script that takes part " &
      "of its command line or environment from the build-script runs " &
      u.fedBy.join(", ") & ", and units fed by a build script are not " &
      "built as edges yet")
  if "--target" in u.argv or u.argv.anyIt(it.startsWith("--target=")):
    refused.add (u.id, "is a build-script compile for a --target, not a " &
      "host unit")
  if crateTypes(u.argv) != @["bin"]:
    refused.add (u.id, "is a build-script compile whose crate type is not " &
      "bin: " & crateTypes(u.argv).join(","))
  let split = effectiveSplitDebuginfo(u.argv)
  if split != "off":
    refused.add (u.id, "writes split debug information (-C " &
      "split-debuginfo=" & split & "), whose side files are not declared " &
      "outputs yet")
  let dynamic = codegenOption(u.argv, "prefer-dynamic")
  if dynamic.found and dynamic.value notin ["no", "n", "off", "false"]:
    refused.add (u.id, "passes -C prefer-dynamic")
  p.registry = u.cwd.startsWith("${store}/")
  if p.registry != r.cwd.startsWith("${store}/"):
    refused.add (r.id, "runs in " & r.cwd & " but its script is compiled " &
      "in " & u.cwd)
  if p.registry:
    let key = u.package & "@" & u.version
    if key notin rows:
      refused.add (u.id, "compiles the build script of the registry crate " &
        key & ", for which no lock row was given")
    else:
      p.row = rows[key]
  if refused.len > before: return (false, p)

  let where = "the build-script compile " & u.id
  for a in u.argv: p.compileArgv.add expandIn(roots, a, where)
  p.compileCwd = expandIn(roots, u.cwd, where)
  var named: seq[string]
  for (name, value) in u.env:
    if name in CargoWrapperVariables: continue
    p.compileEnv.add name & "=" & expandIn(roots, value,
      where & " (" & name & ")")
    named.add name
  for entry in cfg.units.toolchainEnv:
    let name = entry[0 ..< entry.find('=')]
    if name in named or name in u.envRemoved:
      refused.add (u.id, "is given or has removed " & name & " by cargo, " &
        "and the toolchain variables name it too")
      return (false, p)
  p.compileLaunchEnv = p.compileEnv & cfg.units.toolchainEnv
  p.compileOutDir = cfg.units.outRoot / u.id
  for o in u.outputs:
    let path = expandIn(roots, o, where)
    if not path.endsWith(".d"): p.compileOutputs.add path
  p.executable = expandIn(roots, u.executable, where)
  # A build script links: the files `--extern` names and the rlib of every
  # other unit of its closure order it.
  p.compileInputs = externPaths(p.compileArgv)
  for c in u.closure:
    for o in byId[c].outputs:
      if o.endsWith(".rlib"):
        let path = expandIn(roots, o, where)
        if path notin p.compileInputs: p.compileInputs.add path
  for c in u.consumes: p.compileDeps.add planUnitEdgeId(byId[c])
  if u.cargoIncrementalDir.len > 0:
    p.compileScratch.add p.compileOutDir / "incremental"
  p.compileCargoArgv = p.compileArgv
  if p.registry:
    let prefix = registryPrefix(p.row, cfg.units.storeRoot)
    if prefix.len == 0:
      refused.add (u.id, "compiles the build script of the registry crate " &
        p.row.label & ", which is not in the store; its cargo.fetch edge " &
        "must run first")
      return (false, p)
    let runCwd = expandIn(roots, r.cwd, "the build-script run " & r.id)
    if not samePath(p.compileCwd, prefix) or not samePath(runCwd, prefix):
      refused.add (u.id, "is not compiled and run in the crate's store " &
        "prefix " & prefix)
      return (false, p)
    p.compileArgvDifference = @[remapFlag(p.row, p.compileCwd)]

  # The run.
  let rwhere = "the build-script run " & r.id
  p.runDir = cfg.units.outRoot / r.id
  p.outDir = expandIn(roots, r.outDir, rwhere)
  if p.outDir != p.runDir / RunOutDirName:
    refused.add (r.id, "has an OUT_DIR outside its directory: " & p.outDir)
    return (false, p)
  p.directivesDir = p.runDir / RunDirectivesDir
  p.stdoutFile = p.runDir / RunStdoutFile
  p.tmpDir = p.runDir / RunTmpDir
  p.workDir = p.runDir / RunWorkDir
  p.runCwd = expandIn(roots, r.cwd, rwhere)
  if r.argv.len == 0 or r.argv[0] != u.executable:
    refused.add (r.id, "does not run its compile unit's executable")
    return (false, p)
  p.runArgv = @[p.executable]
  for a in r.argv[1 .. ^1]: p.runArgv.add expandIn(roots, a, rwhere)
  var env: seq[(string, string)]
  for entry in cfg.devEnv:
    let eq = entry.find('=')
    if entry[0 ..< eq] in ShellVariables: continue
    env.setVar(entry[0 ..< eq], entry[eq + 1 .. ^1])
  var target, host: string
  for (name, value) in r.env:
    if name in CargoWrapperVariables: continue
    if name == "TARGET": target = value
    if name == "HOST": host = value
    env.setVar(name, expandIn(roots, value, rwhere & " (" & name & ")"))
  for name in r.envRemoved: env.delVar(name)
  for name in JobserverVariables: env.delVar(name)
  var selectors: seq[string]
  for (name, _) in env:
    if isToolchainSelector(name, target, host): selectors.add name
  for name in selectors: env.delVar(name)
  env.setVar("OUT_DIR", p.outDir)
  env.setVar("RUSTC", cfg.rustc)
  env.setVar("TMPDIR", p.tmpDir)
  env.setVar("NUM_JOBS", "1")
  env.setVar("CC", cfg.cToolchain.cc)
  env.setVar("CXX", cfg.cToolchain.cxx)
  env.setVar("AR", cfg.cToolchain.ar)
  var path = cfg.cToolchain.binDir
  for (name, value) in env:
    if name == "PATH" and value.len > 0: path.add ":" & value
  env.setVar("PATH", path)
  env.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))
  for (name, value) in env:
    if SlotTokenPrefix in value:
      refused.add (r.id, "still carries a slot in " & name)
      return (false, p)
    p.runEnv.add name & "=" & value
  (true, p)

proc interpreterArgv(p: Prepared; cfg: BuildScriptEdgesConfig): seq[string] =
  result = @[cfg.interpreter, BuildScriptRunFlag,
    "--package", p.run.package & "@" & p.run.version,
    "--run", p.run.id,
    "--out-dir", p.outDir, "--directives", p.directivesDir,
    "--stdout", p.stdoutFile, "--tmp", p.tmpDir, "--work", p.workDir]
  for root in planRoots(cfg.units):
    result.add ["--root", root.label & "=" & root.path]
  result.add "--"
  result.add p.runArgv

proc runSpecOf(p: Prepared; compileId: string;
               cfg: BuildScriptEdgesConfig): CreatedActionSpec =
  ## The run edge as a created-action spec: monitored (the automatic
  ## monitor), content-checked (`hybrid`), cacheable, one slot (the spec's
  ## default `cpuMilli`), isolated, with its two scratch directories. The
  ## network is denied because a created action has no other mode (the
  ## engine's zero value).
  result = initCreatedActionSpec(buildScriptRunEdgeId(p.run),
    interpreterArgv(p, cfg))
  result.cwd = p.runCwd
  result.deps = @[compileId]
  # Its inputs are content: the script's executable, the interpreter and
  # what the monitor records the script reading.
  result.inputs = @[p.executable, cfg.interpreter]
  result.outputs = @[p.outDir, p.stdoutFile]
  for name in outputFileNames():
    result.outputs.add p.directivesDir / name
  result.env = p.runEnv
  result.commandStatsId = BuildScriptRunStatsId
  result.cacheable = true
  result.actionCachePolicy = ffpHybrid
  result.policyKind = CreatedActionAutomaticMonitor
  result.isolateHostEnvironment = true
  result.scratchDirs = @[p.tmpDir, p.workDir]

proc build(p: Prepared; cfg: BuildScriptEdgesConfig): BuildScriptEdge =
  ## The two actions of a checked run, each the engine's created action of
  ## its spec, creating their directories unless the engine is to
  ## (`PlanUnitsConfig.deferOutputDirs`).
  if not cfg.units.deferOutputDirs:
    createDir(p.compileOutDir)
    createDir(p.runDir)
  let lock = cfg.units.governingLockIdentity
  let compileSpec = rustcUnitSpec(buildScriptCompileEdgeId(p.compileUnit),
    p.compileArgv & p.compileArgvDifference, cwd = p.compileCwd,
    deps = p.compileDeps, inputs = p.compileInputs,
    outputs = p.compileOutputs, env = p.compileLaunchEnv,
    commandStatsId = BuildScriptCompileStatsId,
    isolateHostEnvironment = true, scratchDirs = p.compileScratch)
  let compile = rustcUnitAction(compileSpec, lock)
  let runSpec = runSpecOf(p, compile.id, cfg)
  var run = createdAction(runSpec, lock)
  # The one field the created-action form cannot state: `OUT_DIR` as an
  # opaque output directory, removed before each run. A `create-action`
  # record has no field for it, and a fragment's `opaque-output` record
  # applies to the fragment's producer, not to an action it creates. So it
  # is set on this action only (`runSpecLacks`), and an action created from
  # `runSpec`'s record would keep an earlier run's `OUT_DIR`, which the
  # interpreter refuses (it requires an empty one).
  run.removeBeforeRun = @[p.outDir]
  BuildScriptEdge(run: p.run, compileUnit: p.compileUnit,
    registry: p.registry, compileCargoArgv: p.compileCargoArgv,
    compileArgvDifference: p.compileArgvDifference,
    compileEnv: p.compileEnv, executable: p.executable, runDir: p.runDir,
    outDir: p.outDir, directivesDir: p.directivesDir,
    stdoutFile: p.stdoutFile, tmpDir: p.tmpDir, workDir: p.workDir,
    runArgv: p.runArgv, runCwd: p.runCwd, runEnv: p.runEnv,
    compileSpec: compileSpec, runSpec: runSpec,
    runSpecLacks: @["removeBeforeRun"], compile: compile, runAction: run)

proc refusalMessage(refused: seq[(string, string)]): string =
  result = "the cargo plan holds build scripts these edges do not build, " &
    "so the workspace is built by cargo as a whole:"
  for (id, why) in refused:
    result.add "\n  " & id & " " & why

proc raiseRefusal(refused: var seq[(string, string)]) {.noreturn.} =
  refused.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))
  var e = newException(BuildScriptRefusal, refusalMessage(refused))
  e.refused = refused
  raise e

proc setup(plan: CargoPlan; cfg: BuildScriptEdgesConfig):
    (seq[RecordRoot], Table[string, PlanUnit], Table[string, CrateRow]) =
  checkConfig(cfg)
  if ($cfg.units.governingLockIdentity).len == 0:
    raise newException(ValueError, "the build-script edges need the " &
      "governing lock identity they are built under")
  for (what, path) in [("workspace root", cfg.units.projectRoot),
                       ("output root", cfg.units.outRoot)]:
    if path.len == 0 or not path.isAbsolute:
      raise newException(ValueError, "the build-script edges need an " &
        "absolute " & what & ", not " & path.escape())
  for entry in cfg.units.toolchainEnv:
    if entry.find('=') <= 0:
      raise newException(ValueError, "a toolchain variable must be " &
        "NAME=value: " & entry.escape())
  validatePlan(plan)
  var byId = initTable[string, PlanUnit]()
  for u in plan.units: byId[u.id] = u
  var rows = initTable[string, CrateRow]()
  for row in cfg.units.registryCrates: rows[row.label] = row
  (planRoots(cfg.units), byId, rows)

proc buildScriptEdgesOf*(plan: CargoPlan; runId: string;
                         cfg: BuildScriptEdgesConfig): BuildScriptEdge =
  ## The compile and run edges of the plan's run ``runId`` (see the module
  ## docstring). Raises `BuildScriptRefusal` naming every reason the run or
  ## its compile is refused, before anything is created; `KeyError` for a
  ## run the plan does not hold; `ValueError` for a configuration the edges
  ## cannot be built from; `CargoPlanError` for a plan naming a root this
  ## host lacks. Creates the compile unit's and the run's directories.
  let (roots, byId, rows) = setup(plan, cfg)
  let r = plan.runById(runId)
  var refused: seq[(string, string)]
  let (ok, p) = prepare(r, cfg, roots, byId, rows, refused)
  if not ok: raiseRefusal(refused)
  build(p, cfg)

proc buildScriptEdges*(plan: CargoPlan; cfg: BuildScriptEdgesConfig):
    seq[BuildScriptEdge] =
  ## The edges of every build script of ``plan``, sorted by run id, or
  ## `BuildScriptRefusal` naming every run and compile unit refused,
  ## including a build-script compile that no run executes (a `links`
  ## override). Nothing is created unless every build script passes.
  let (roots, byId, rows) = setup(plan, cfg)
  var refused: seq[(string, string)]
  var ran: seq[string]
  for r in plan.runs: ran.add r.compileUnit
  for u in plan.units:
    if u.buildScriptCompile and u.id notin ran:
      refused.add (u.id, "is a build script that cargo does not run (a " &
        "links override in cargo's configuration), which these edges do " &
        "not model")
  var prepared: seq[Prepared]
  for r in plan.runs:
    let (ok, p) = prepare(r, cfg, roots, byId, rows, refused)
    if ok: prepared.add p
  if refused.len > 0: raiseRefusal(refused)
  for p in prepared:
    result.add build(p, cfg)

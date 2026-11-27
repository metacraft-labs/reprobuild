## Shared pieces of the cases that build a crates.io workspace through the
## Rust convention's Mode A path: the environment the convention is run in,
## the emitted fragment's actions, and the engine run of those actions.
##
## WHAT IS RE-DONE HERE, AND WHY. The Rust convention emits `BuildActionDef`s
## into a provider fragment; `repro build` lowers each through the CLI's
## `lowerGraphAction`, which is private to `repro_cli_support`.
## `toEngineAction` passes the emitted argv, working directory, ordering,
## inputs, outputs, environment, scratch directories and the
## `isolateHostEnvironment` flag to the engine's `action` constructor
## unchanged, with the policies the emitter states (content-checked,
## gathered by the automatic monitor). It is the step the Rust Mode A cases
## already re-do (`t_rust_mode_a_depfile_is_read_not_cached`). Everything
## else is real: `cargo metadata`, the emitter, the fetch wave, the record
## run under the io monitor, the plan, the engine and its monitor, cargo and
## rustc.

import std/[os, sequtils, strutils]

import repro_build_engine
import repro_core/dependency_gathering
import repro_core/input_check_policy
import repro_lock/identity
import repro_provider_runtime
import repro_project_dsl
import repro_test_support
import repro_cargo_edge/wrapper_env
import repro_standard_provider/conventions/rust as rust_convention
import repro_standard_provider/conventions/rust_plan_mode

import ./rqe_cg5_plan_fixture

proc dummyRequest*(projectRoot: string): ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider",
    entryPointId: "standardProvider.root",
    entryPointBodyHash: "test-body-hash",
    reason: girExplicitUserRequest,
    arguments: projectRoot,
    namespace: "project")

proc emitWorkspace*(projectRoot: string): GraphFragment =
  ## The production emitter over `projectRoot`.
  rustConvention().emitFragment(projectRoot, dummyRequest(projectRoot))

proc actionDefs*(fragment: GraphFragment): seq[BuildActionDef] =
  ## Every action of the fragment, decoded from its payload as the CLI
  ## decodes it.
  for node in fragment.nodes:
    if node.kind == gnkAction:
      var bytes = newSeq[byte](node.payload.len)
      for i, c in node.payload: bytes[i] = byte(c)
      result.add decodeBuildActionPayload(bytes)

proc callArg*(def: BuildActionDef; name: string): string =
  for arg in def.call.arguments:
    if arg.name == name: return arg.encodedValue

proc inlineArgvOf*(def: BuildActionDef): seq[string] =
  let encoded = def.callArg("argv")
  if encoded.len == 0: return
  encoded.split("\x1f")

proc runsCargo*(def: BuildActionDef): bool =
  ## Whether the action runs cargo, directly or through the thin cargo edge.
  let argv = inlineArgvOf(def)
  argv.anyIt(isCargoProgram(it)) or EdgeHelperFlag in argv

proc envEntries*(def: BuildActionDef): seq[string] =
  for (name, value) in def.env: result.add name & "=" & value

proc toEngineAction*(def: BuildActionDef; projectRoot: string): BuildAction =
  ## The emitted edge as the engine sees it (see the module header).
  let argv = inlineArgvOf(def)
  doAssert argv.len > 0, "edge " & def.id & " has no inline argv"
  let cwd = block:
    let declared = def.callArg("cwd")
    if declared.len > 0: declared else: projectRoot
  doAssert def.actionCachePolicy == acfpHybrid, def.id
  doAssert def.dependencyPolicy.kind == bdpAutomaticMonitor, def.id
  result = action(def.id, argv,
    cwd = cwd,
    deps = def.deps,
    inputs = def.inputs,
    outputs = def.outputs,
    pool = def.pool,
    cacheable = def.cacheable,
    commandStatsId = def.commandStatsId,
    actionCachePolicy = ffpHybrid,
    dependencyPolicy = automaticMonitorGatheringPolicy(),
    isolateHostEnvironment = def.isolateHostEnvironment,
    env = def.envEntries,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  result.scratchDirs = def.scratchDirs

type ModeAEnv* = object
  ## What the convention needs from its process to plan a workspace.
  tools*: MonitorTools
  wrapper*: string

proc prepareModeAEnv*(work, tag: string): ModeAEnv =
  ## Make this process an environment the convention can plan in, and in
  ## which nothing reaches cargo but what the case sets: the record wrapper
  ## named by `REPRO_RUSTC_WRAPPER_PATH`, the monitor shim, a `PATH` of Nix
  ## store directories only (the convention resolves its tools there), no
  ## dynamic-library path, and an empty `CARGO_HOME`. The variables through
  ## which a shell steers cargo (`RUSTFLAGS`, `CARGO_BUILD_*`, ...) are NOT
  ## cleared: the record run's closed environment is what keeps them out,
  ## and `exportCargoSteering` sets them on purpose.
  let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
  result.wrapper = requireBinary(
    reproBinaryPath(repoRoot, "repro-rustc-wrapper"),
    "reprobuild.apps.repro-rustc-wrapper")
  putEnv(WrapperPathEnv, result.wrapper)
  result.tools = prepareMonitorTools(repoRoot, work / "monitor", tag)
  putEnv("REPRO_MONITOR_SHIM_LIB", result.tools.shim)
  putEnv("PATH", storeOnlyPath())
  # Cargo extends the dynamic-library path it is given; the real build the
  # cases compare with is given none, and neither is the record run.
  delEnv("LD_LIBRARY_PATH")
  createDir(work / "cargo-home")
  putEnv("CARGO_HOME", work / "cargo-home")

const SteeringMarker* = "steered_by_the_host"

proc exportCargoSteering*() =
  ## Export, in this process, variables through which a shell would steer
  ## cargo's plan if it reached cargo: extra rustc flags naming
  ## `SteeringMarker`, another release opt-level, a target directory and a
  ## rustc wrapper. None of them may shape a unit.
  putEnv("RUSTFLAGS", "--cfg " & SteeringMarker)
  putEnv("CARGO_ENCODED_RUSTFLAGS", "--cfg\x1f" & SteeringMarker)
  putEnv("CARGO_BUILD_RUSTFLAGS", "--cfg " & SteeringMarker)
  putEnv("CARGO_PROFILE_RELEASE_OPT_LEVEL", "1")
  putEnv("CARGO_TARGET_DIR", "/nonexistent/steered-target")

proc steeredUnits*(argvs: openArray[seq[string]]): seq[string] =
  ## The command lines that show a steering variable: the marker, or
  ## `opt-level=1` (cargo's release profile passes `opt-level=3`).
  for argv in argvs:
    for a in argv:
      if SteeringMarker in a or a == "opt-level=1":
        result.add argv.join(" ")
        break

proc lockWorkspace*(ws, work: string; reg: RegistrySetup) =
  ## Write the workspace's `Cargo.lock` against the registry's crates.
  let lock = runClosed(@[findExe("cargo")] & reg.sourceArgs &
    @["generate-lockfile", "--offline"], ws,
    @[("PATH", storeOnlyPath()), ("CARGO_HOME", work / "lock-home"),
      ("HOME", work / "lock-home")])
  doAssert lock.code == 0, "cargo generate-lockfile failed:\n" & lock.output

proc engineConfig*(env: ModeAEnv; cacheRoot: string): BuildEngineConfig =
  BuildEngineConfig(
    cacheRoot: cacheRoot,
    runQuotaCliPath: env.tools.monitorCliPath,
    monitorCliPath: env.tools.monitorCliPath,
    monitorCliArgs: env.tools.monitorCliArgs,
    maxParallelism: 1'u32,
    stdoutLimit: 1024 * 1024,
    stderrLimit: 1024 * 1024,
    bypassRunQuota: true)

proc isPlanEdge*(def: BuildActionDef): bool = def.id.startsWith("cargo.rustc/")

proc buildFragment*(env: ModeAEnv; fragment: GraphFragment;
                    projectRoot, cacheRoot: string): BuildRunResult =
  ## Build the fragment's default target: its plan edges (the `test`
  ## target, Mode B's, is not run).
  var actions: seq[BuildAction]
  for def in actionDefs(fragment):
    if def.isPlanEdge: actions.add toEngineAction(def, projectRoot)
  runBuild(graph(actions), engineConfig(env, cacheRoot))

proc switchInputDigest*(fragment: GraphFragment): string =
  ## The digest the fragment recorded for the registry lift's switch, or
  ## "<absent>" when it recorded none.
  result = "<absent>"
  for input in fragment.evaluationInputs:
    if input.kind == gevHostFact and
        input.identity == EnvironmentHostFactPrefix & ModeARegistrySwitch:
      return input.digest

proc rlibsUnder*(dir: string): seq[string] =
  ## Every `.rlib` file below `dir`, the store prefixes' read-only trees
  ## included.
  for path in walkDirRec(dir, yieldFilter = {pcFile, pcLinkToFile}):
    if path.endsWith(".rlib"): result.add path

type RlibProvenance* = object
  ## Where every rlib of a build came from.
  edgeOutputs*: seq[string]
    ## the rlibs the fragment's Reprobuild rustc edges declare
  linked*: seq[string]
    ## every rlib a binary edge was given: its `--extern` files and the
    ## rlibs in its `-L dependency=` directories
  foreign*: seq[string]
    ## rlibs linked, or lying in the workspace outside the record run's
    ## scratch directory, that no Reprobuild rustc edge declares
  cargoEdges*: seq[string]
    ## the fragment's actions that run cargo, other than its `test` target
    ## (Mode B's `cargo test`, which links only what cargo builds itself)
  scratchCompiled*: seq[string]
    ## non-empty rlibs in the record run's scratch directory (its
    ## placeholders are empty: nothing is compiled there)

proc rlibProvenance*(fragment: GraphFragment; ws: string): RlibProvenance =
  let defs = actionDefs(fragment)
  for def in defs:
    if def.runsCargo and not def.id.startsWith("crude-test"):
      result.cargoEdges.add def.id
    if def.id.startsWith("cargo.rustc/"):
      for o in def.outputs:
        if o.endsWith(".rlib"): result.edgeOutputs.add o
  for def in defs:
    let argv = inlineArgvOf(def)
    if "bin" notin argv: continue
    for i, a in argv:
      if i + 1 >= argv.len: break
      let value = argv[i + 1]
      if a == "--extern" and '=' in value:
        let path = value[value.find('=') + 1 .. ^1]
        if path.endsWith(".rlib") and path notin result.linked:
          result.linked.add path
      elif a == "-L" and value.startsWith("dependency="):
        let dir = value["dependency=".len .. ^1]
        if dirExists(dir):
          for path in rlibsUnder(dir):
            if path notin result.linked: result.linked.add path
  let scratch = ws / PlanDirRel
  for path in rlibsUnder(ws):
    if path.startsWith(scratch & "/"):
      if getFileSize(path) > 0: result.scratchCompiled.add path
    elif path notin result.edgeOutputs and path notin result.foreign:
      result.foreign.add path
  for path in result.linked:
    if path notin result.edgeOutputs and path notin result.foreign:
      result.foreign.add path

## Shared pieces of the cases that look at the Rust convention's Mode A path
## for a crates.io workspace: the environment the convention is run in, the
## emitted fragment's actions, the actions its units edge created, and where
## the rlibs of a build came from.
##
## The fragment of a workspace built from cargo's plan holds its
## graph-production edges (`rust_plan_mode`); the unit edges are created
## while the build runs, from the units edge's fragment, so the cases build
## with `repro build` (`rqe_cg5_repro_build_support`) and read the created
## actions from that fragment (`unitRecords`). Everything is real: `cargo
## metadata`, the emitter, the CLI, the engine and its monitor, cargo and
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

proc cargoSteering*(): seq[(string, string)] =
  ## Variables through which a shell would steer cargo's plan if they
  ## reached cargo: extra rustc flags naming `SteeringMarker`, another
  ## release opt-level and a target directory. None of them may shape a unit.
  @[("RUSTFLAGS", "--cfg " & SteeringMarker),
    ("CARGO_ENCODED_RUSTFLAGS", "--cfg\x1f" & SteeringMarker),
    ("CARGO_BUILD_RUSTFLAGS", "--cfg " & SteeringMarker),
    ("CARGO_PROFILE_RELEASE_OPT_LEVEL", "1"),
    ("CARGO_TARGET_DIR", "/nonexistent/steered-target")]

proc exportCargoSteering*() =
  ## Export `cargoSteering` in this process.
  for (k, v) in cargoSteering(): putEnv(k, v)

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

const GraphProductionPrefixes* = ["cargo.fetch/", "cargo.plan/",
  "cargo.mode-b-record/", "cargo.plan-units/", "cargo.workspace/"]
  ## The ids of a workspace's graph-production edges (`rust_plan_mode`).

proc isGraphProductionEdge*(def: BuildActionDef): bool =
  for prefix in GraphProductionPrefixes:
    if def.id.startsWith(prefix): return true
  false

proc unitRecords*(ws: string): seq[CreatedActionSpec] =
  ## The actions the units edge's fragment creates, as its records state
  ## them, after a build of the workspace.
  for line in readFile(ws / UnitsFragmentRel).splitLines():
    if line.startsWith("create-action\t"):
      result.add parseCreatedActionSpec(line["create-action\t".len .. ^1])

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

proc rlibProvenance*(units: openArray[CreatedActionSpec];
                     ws: string): RlibProvenance =
  ## Where every rlib of a build of ``ws`` came from, given the actions the
  ## units edge created (`unitRecords`).
  for u in units:
    if u.argv.anyIt(isCargoProgram(it)) or EdgeHelperFlag in u.argv:
      result.cargoEdges.add u.id
    if u.id.startsWith("cargo.rustc/"):
      for o in u.outputs:
        if o.endsWith(".rlib"): result.edgeOutputs.add o
  for u in units:
    let argv = u.argv
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

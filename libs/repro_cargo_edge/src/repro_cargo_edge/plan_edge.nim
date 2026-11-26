## The record-only graph-production edge: cargo's plan as a monitored,
## cacheable build-graph edge that compiles nothing.
##
## `cargoPlanEdge` declares the edge whose process is `plan_run` (the record
## wrapper's `--cargo-plan` command). Its shape:
##
## - **Process.** argv[0] is the record wrapper, so the wrapper that decides
##   what is recorded is an input of the edge (its image is read when it is
##   executed, and the monitor records the read). It runs in the workspace
##   root.
## - **Ordering.** It `deps` on the `cargo.fetch` edges and declares their
##   store prefixes as inputs: cargo cannot plan a build without every
##   package's manifest, and the fetch edges come from `Cargo.lock` alone,
##   without running cargo. It also declares the workspace's `Cargo.toml` and
##   `Cargo.lock`, which only order it; its key comes from what the monitor
##   records it reading (dependency gathering by the automatic monitor,
##   inputs checked by content).
## - **One output.** The plan, at a path relative to the working directory.
## - **Scratch.** One scratch directory, relative to the working directory,
##   which the engine empties before the run and never treats as evidence:
##   the recordings, the placeholders, the scratch target directory, the
##   saved `cargo metadata`, and the edge-private `CARGO_HOME` and `HOME`.
## - **Environment.** Closed: the edge is launched from the declared
##   variables alone (the project's development environment, which the
##   caller passes), never from the engine's own environment. The edge's
##   process sets `CARGO_HOME` and `HOME` to the empty edge-private
##   directories itself.
## - **Network.** Denied (the default for a process edge, which no argument
##   here changes): it downloads nothing.
##
## - **Relocatable.** The edge computes the same plan wherever the workspace
##   lies, given the same content at the same workspace-relative places (the
##   plan names the workspace only as `${project}`). So it is declared
##   relocatable, with the workspace root as its working directory: its key
##   holds the depth of the working directory instead of its spelling, its
##   argv and recorded inputs are named relative to the workspace, and two
##   checkouts of one workspace share its record. The tools and stores it
##   reaches by absolute path (the wrapper's, cargo's and rustc's
##   directories, the store root, the fetched prefixes and the Nix store
##   where it exists) are its relocation anchors, named by absolute path.
##   Relative paths in the argv and outputs keep the checkout's path off the
##   command line.
## - **Cargo arguments** are the build's selection only
##   (`plan_run.validateCargoArgs`); anything else is refused when the edge
##   is declared.

import std/os

import repro_build_engine
import repro_core/dependency_gathering
import repro_core/input_check_policy
import repro_lock/identity

import ./plan_run

const
  CargoPlanEdgePrefix* = "cargo.plan/"

type
  CargoPlanEdgeConfig* = object
    name*: string
      ## Names the edge: `cargo.plan/<name>` (the workspace's name).
    projectRoot*: string
      ## The workspace root, absolute: the edge's working directory.
    planFile*: string
      ## The plan, relative to `projectRoot`.
    scratchDir*: string
      ## The edge's scratch directory, relative to `projectRoot`. It must
      ## not contain the plan, `Cargo.toml` or `Cargo.lock`.
    wrapper*: string
      ## The record wrapper (`repro-rustc-wrapper`).
    cargo*, rustc*: string
    storeRoot*: string
      ## The store root, recorded as the `store` logical root ("" = none).
    cargoArgs*: seq[string]
      ## The build's profile, target and package selection, given to
      ## `cargo build` after the edge's own flags.
    devEnv*: seq[string]
      ## The closed environment, `NAME=value` per entry.
    fetchEdges*: seq[string]
      ## The ids of the `cargo.fetch` edges of the workspace's lock.
    prefixes*: seq[string]
      ## Their store prefixes.

proc cargoPlanEdgeId*(name: string): string = CargoPlanEdgePrefix & name

proc cargoPlanArgv*(cfg: CargoPlanEdgeConfig): seq[string] =
  result = @[cfg.wrapper, PlanRunFlag, "--plan", cfg.planFile, "--scratch",
    cfg.scratchDir, "--cargo", cfg.cargo, "--rustc", cfg.rustc]
  if cfg.storeRoot.len > 0:
    result.add ["--store-root", cfg.storeRoot]
  result.add "--"
  result.add cfg.cargoArgs

proc cargoPlanEdge*(cfg: CargoPlanEdgeConfig): BuildAction =
  ## The edge (see the module docstring). Raises `ValueError` on a
  ## configuration that names no workspace, plan or scratch directory.
  if cfg.name.len == 0 or cfg.projectRoot.len == 0 or cfg.planFile.len == 0 or
      cfg.scratchDir.len == 0:
    raise newException(ValueError, "a cargo plan edge needs a name, a " &
      "workspace root, a plan file and a scratch directory")
  let problem = validateCargoArgs(cfg.cargoArgs)
  if problem.len > 0:
    raise newException(ValueError, "cargo plan edge " & cfg.name & ": " &
      problem)
  var inputs = @["Cargo.toml", "Cargo.lock"]
  inputs.add cfg.prefixes
  var anchors: seq[string]
  for tool in [cfg.wrapper, cfg.cargo, cfg.rustc]:
    if tool.isAbsolute: anchors.add parentDir(tool)
  if cfg.storeRoot.len > 0: anchors.add cfg.storeRoot
  anchors.add cfg.prefixes
  if dirExists("/nix/store"): anchors.add "/nix/store"
  result = action(cargoPlanEdgeId(cfg.name), cargoPlanArgv(cfg),
    cwd = cfg.projectRoot,
    deps = cfg.fetchEdges,
    inputs = inputs,
    outputs = [cfg.planFile],
    commandStatsId = "cargo.plan",
    cacheable = true,
    actionCachePolicy = ffpHybrid,
    dependencyPolicy = automaticMonitorGatheringPolicy(),
    isolateHostEnvironment = true,
    env = cfg.devEnv,
    relocatable = true,
    relocationAnchors = anchors,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  result.scratchDirs = @[cfg.scratchDir]

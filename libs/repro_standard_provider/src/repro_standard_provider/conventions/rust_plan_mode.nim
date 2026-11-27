## Rust Mode A for a workspace with crates.io dependencies: the workspace is
## built from cargo's own plan.
##
## Rust.md § Recognition item 6 keeps a workspace with a registry dependency
## out of Mode A's own emission: that emission compiles workspace members
## only, from `cargo metadata --no-deps`, and has no unit to pass `--extern`
## for a registry crate. A workspace whose external dependencies all come
## from crates.io can instead be built from cargo's PLAN (the record-only
## graph-production edge, `repro_cargo_edge/plan_edge` and `plan_run`), in
## which every library and binary unit, members and registry crates alike,
## has the command line, working directory and environment cargo gave it.
##
## THE GATE. The lift is behind the switch `REPRO_CARGO_MODE_A_REGISTRY`,
## which only the exact value `on` turns on; it is off by default. With it
## off, item 6 keeps its registry condition and such a workspace stays in
## Mode B. The Rust convention reads the switch where it decides the
## workspace's mode, and reports the variable as an evaluation input of the
## fragment it emits (`environmentInput`, a host fact keyed by a digest of
## the value), so turning the switch on or off re-decides the workspace.
##
## GRAPH PRODUCTION IS EDGES. Evaluating the workspace runs nothing: it
## declares, from `Cargo.lock` and the toolchain alone,
##
## 1. one `cargo.fetch/<name>@<version>` edge per locked crates.io crate
##    (`repro_cargo_fetch`, executed by `repro build` itself), which puts the
##    crate's prefix in the store, or finds it there;
## 2. the plan edge `cargo.plan/<workspace>`, the record-only `cargo build`
##    over those prefixes, whose one output is the plan. It is relocatable
##    and keyed on what it reads, so an unchanged workspace reuses its plan
##    and two checkouts of it share one;
## 3. the Mode B record edge, which writes the record of the workspace's
##    Mode B build edge (`repro_cargo_edge/mode_b.modeBBuildSpec`, the edge
##    the static Mode B fragment declares);
## 4. the units edge `cargo.plan-units/<workspace>`
##    (`repro_cargo_edge/plan_units_edge`), which reads the plan and writes a
##    dynamic graph fragment: one `create-action` record per unit
##    (`plan_units.planUnitEdges`), or, when the plan holds a unit these
##    edges do not build or the record run refused the workspace, the Mode B
##    edge's record. A workspace is built either wholly by these edges or
##    wholly by cargo;
## 5. the collector `cargo.workspace/<workspace>`, in the default target,
##    whose `dynamicDepsFile` is that fragment: the engine creates the
##    fragment's actions when the collector is about to run, and the
##    collector waits for them.
##
## What evaluation still decides is only what needs no tool run: the lock's
## sources (a package from any other source keeps the workspace in Mode B)
## and whether the record wrapper is installed.
##
## The record run plans `cargo build --release --workspace`, the selection
## and profile of Mode B's delegated build, so the workspace builds the same
## units in either mode.

import std/[os, strutils]

import repro_provider_runtime
import repro_cargo_fetch
import repro_cargo_edge/[plan_edge, plan_run, plan_units_edge, wrapper_env]
import repro_local_store/store

const
  ModeARegistrySwitch* = "REPRO_CARGO_MODE_A_REGISTRY"
    ## The temporary gate on item 6's registry lift. Only `on` turns it on.
  ModeARegistrySwitchOn* = "on"
  PlanDirRel* = ".repro/build/cargo-plan"
    ## The graph-production edges' files under the workspace root.
  PlanFileRel* = PlanDirRel & "/plan.rbsz"
    ## The plan edge's one output.
  PlanScratchRel* = PlanDirRel & "/scratch"
    ## The plan edge's scratch directory.
  ModeBRecordRel* = PlanDirRel & "/mode-b.record"
    ## The Mode B edge's `create-action` record.
  UnitsFragmentRel* = PlanDirRel & "/units.rbdyn"
    ## The units edge's fragment.
  UnitsOutRel* = ".repro/build/cargo-units"
    ## `${out}`: the root of the plan's per-unit output directories.
  FetchStateRel* = ".repro/build/cargo-fetch"
    ## The fetch edges' receipts.
  PlanCargoArgs* = ["--release", "--workspace"]
  StoreRootEvaluationVariables* = [StoreRootEnvVar, "HOME", "XDG_CACHE_HOME",
                                   "LOCALAPPDATA", "USERPROFILE"]
    ## What the store root is resolved from (`resolveStoreRoot`): the fetch
    ## edges and the plan edge name it, so each is an evaluation input.

proc modeARegistryLiftOn*(): bool =
  ## Whether the switch turns the lift on: exactly `on`, nothing else.
  getEnv(ModeARegistrySwitch) == ModeARegistrySwitchOn

proc modeARegistrySwitchInput*(): GraphEvaluationInput =
  ## The switch as an evaluation input of the fragment that read it.
  environmentInput(ModeARegistrySwitch)

type
  PlanToolchain* = object
    ## The tools graph production runs and the edges are given, resolved by
    ## the caller and keyed by it (`toolchainEvaluationInputs`).
    cargo*, rustc*: string
    cc*: string
      ## The C driver rustc links with ("" when there is none).

proc toolchainPath*(t: PlanToolchain): string =
  ## The `PATH` of the plan edge's closed environment and of every unit
  ## edge: the directories of cargo, rustc and the C driver, nothing else.
  var dirs: seq[string]
  for exe in [t.cargo, t.rustc, t.cc]:
    if exe.len > 0 and parentDir(exe) notin dirs:
      dirs.add parentDir(exe)
  dirs.join($PathSep)

proc toolchainEvaluationInputs*(t: PlanToolchain): seq[GraphEvaluationInput] =
  ## What the toolchain was resolved from and what it is: the `PATH` it was
  ## found on, and the content of each tool. A change of either re-evaluates
  ## the workspace.
  result.add environmentInput("PATH")
  for exe in [t.cargo, t.rustc, t.cc]:
    if exe.len > 0: result.add fileReadInput(exe)

type
  PlanFetchEdge* = object
    ## One `cargo.fetch` edge of the workspace's lock.
    row*: CrateRow
    receipt*: string    ## its one output, absolute

  PlanGraph* = object
    ## The graph-production edges of one workspace, or why it is not built
    ## from the plan.
    ok*: bool
    reason*: string
      ## Why the workspace is built by cargo, when not `ok`.
    name*: string
      ## The workspace's name in the edges' ids.
    storeRoot*: string
    fetches*: seq[PlanFetchEdge]
    planEdge*: CargoPlanEdgeConfig
    units*: PlanUnitsOptions
      ## The units edge's arguments; its fragment, plan and Mode B record
      ## are relative to the workspace root.
    helper*: string
      ## The standard provider's image, which runs the units edge, the
      ## collector and the thin cargo edge.
    wrapper*: string
      ## The record wrapper, the plan edge's process.

proc receiptPath*(root: string; row: CrateRow): string =
  ## Where the fetch edge of ``row`` writes its receipt.
  root / FetchStateRel / "receipts" / (row.name & "@" & row.version &
    ".receipt")

proc edgeName*(root: string): string =
  ## The workspace's name in its edges' ids: its directory's name, with
  ## anything outside `[A-Za-z0-9._-]` spelt `_`.
  for ch in root.extractFilename:
    result.add(if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}: ch
               else: '_')
  if result.len == 0: result = "workspace"

proc planWorkspace*(projectRoot: string; tools: PlanToolchain;
                    helper: string): PlanGraph =
  ## The graph-production edges of the workspace at `projectRoot` (the
  ## module docstring). Runs no tool and writes nothing. Never raises for a
  ## workspace it cannot build from the plan: it returns `ok = false` with
  ## the reason.
  let root = absolutePath(projectRoot)
  result.name = edgeName(root)
  result.helper = helper
  when not defined(posix):
    result.reason = "the record run is not supported on this platform"
    return
  # The lock's crates.io rows.
  var locked: LockedCrates
  try:
    locked = lockedCratesOf(readFile(root / "Cargo.lock"))
  except CatchableError as err:
    result.reason = "Cargo.lock cannot be read as a lock of crates.io " &
      "crates: " & err.msg
    return
  if locked.unfetched.len > 0:
    let p = locked.unfetched[0]
    result.reason = "Cargo.lock holds " & p.name & "@" & p.version &
      " from " & p.source & " (" & p.reason & "); only crates.io crates " &
      "are built from the plan"
    return
  result.wrapper = wrapperBinaryPath(parentDir(getAppFilename()),
    getEnv(WrapperPathEnv))
  if result.wrapper.len == 0:
    result.reason = "the record wrapper (" & WrapperBinaryName & ") is " &
      "not installed beside " & getAppFilename() & " and " & WrapperPathEnv &
      " names none"
    return
  result.storeRoot = resolveStoreRoot()
  var crates: seq[CratePrefix]
  var fetchIds: seq[string]
  for row in locked.rows:
    result.fetches.add PlanFetchEdge(row: row, receipt: receiptPath(root, row))
    fetchIds.add crateFetchEdgeId(row)
    crates.add CratePrefix(name: row.name, version: row.version,
      prefix: cratePrefixPath(result.storeRoot, row))
  result.planEdge = CargoPlanEdgeConfig(name: result.name, projectRoot: root,
    planFile: PlanFileRel, scratchDir: PlanScratchRel,
    wrapper: result.wrapper, cargo: tools.cargo, rustc: tools.rustc,
    storeRoot: result.storeRoot, cargoArgs: @PlanCargoArgs,
    devEnv: @["PATH=" & toolchainPath(tools)], fetchEdges: fetchIds,
    crates: crates)
  result.units = PlanUnitsOptions(planFile: PlanFileRel,
    fragmentFile: UnitsFragmentRel, modeBFile: ModeBRecordRel,
    collector: planCollectorId(result.name), projectRoot: root,
    storeRoot: result.storeRoot, outRoot: root / UnitsOutRel,
    toolchainEnv: @["PATH=" & toolchainPath(tools)], crates: locked.rows)
  result.ok = true

## Rust Mode A for a workspace with crates.io dependencies: the workspace is
## built from cargo's own plan.
##
## Rust.md § Recognition item 6 keeps a workspace with a registry dependency
## out of Mode A's own emission: that emission compiles workspace members
## only, from `cargo metadata --no-deps`, and has no unit to pass `--extern`
## for a registry crate. A workspace whose external dependencies all come
## from crates.io can instead be built from cargo's PLAN (the record-only
## graph-production run of `repro_cargo_edge/plan_run`), in which every
## library and binary unit, members and registry crates alike, has the
## command line, working directory and environment cargo gave it.
##
## THE GATE. The lift is behind the switch `REPRO_CARGO_MODE_A_REGISTRY`,
## which only the exact value `on` turns on; it is off by default. With it
## off, item 6 keeps its registry condition and such a workspace stays in
## Mode B. The Rust convention reads the switch where it decides the
## workspace's mode, and reports the variable as an evaluation input of the
## fragment it emits (`environmentInput`, a host fact keyed by a digest of
## the value), so turning the switch on or off re-decides the workspace.
##
## GRAPH PRODUCTION, in this order, each step a reason for Mode B when it
## cannot be taken (`PlanGraph.reason`):
##
## 1. The lock's crates.io rows (`crate_rows`). A package from any other
##    source keeps the workspace in Mode B.
## 2. The fetch wave (`repro_cargo_fetch.fetchLockedCrates`): each crate's
##    store prefix, from the store root when it is there, else from the
##    configured locations (crates.io's origin; no mirror is configured
##    yet). Its receipts and engine cache are the project's own, under
##    `.repro/build/cargo-fetch`.
## 3. The record run (`plan_run`, the process of the record-only edge,
##    `plan_edge.cargoPlanArgv`), run under the io monitor in the workspace
##    root, from a closed environment (`closedRecordEnv`: the toolchain's
##    `PATH` and a private `TMPDIR`), in a directory of its own. What it read, outside its own scratch directory and plan, is
##    reported as the fragment's evaluation inputs, so a change of a
##    manifest, the lock, a prefix or a tool re-runs graph production, as
##    does a change of the toolchain or the `PATH` it was resolved from
##    (`toolchainEvaluationInputs`). Its directory is never evidence.
## 4. The plan's edges (`plan_units.planUnitEdges`). A plan with a unit these
##    edges do not build (a build script, a fed unit, a proc-macro, ...) is
##    refused as a whole, and the workspace goes to Mode B: it is built
##    either wholly by these edges or wholly by cargo.
##
## The record run plans `cargo build --release --workspace`, the selection
## and profile of Mode B's delegated build, so the workspace builds the same
## units in either mode.

import std/[os, strutils, tables, tempfiles, times]

import repro_provider_runtime
import repro_cargo_fetch
import repro_cargo_edge/[cargo_plan, plan_edge, plan_run, plan_units,
                         wrapper_env]

import repro_standard_provider/conventions/observed_reads

const
  ModeARegistrySwitch* = "REPRO_CARGO_MODE_A_REGISTRY"
    ## The temporary gate on item 6's registry lift. Only `on` turns it on.
  ModeARegistrySwitchOn* = "on"
  PlanDirRel* = ".repro/build/cargo-plan"
    ## The record run's directory under the workspace root.
  PlanFileRel* = PlanDirRel & "/plan.rbsz"
  UnitsOutRel* = ".repro/build/cargo-units"
    ## `${out}`: the root of the plan's per-unit output directories.
  FetchStateRel* = ".repro/build/cargo-fetch"
  PlanCargoArgs* = ["--release", "--workspace"]

proc modeARegistryLiftOn*(): bool =
  ## Whether the switch turns the lift on: exactly `on`, nothing else.
  getEnv(ModeARegistrySwitch) == ModeARegistrySwitchOn

proc modeARegistrySwitchInput*(): GraphEvaluationInput =
  ## The switch as an evaluation input of the fragment that read it.
  environmentInput(ModeARegistrySwitch)

type
  PlanGraph* = object
    ## The outcome of graph production for one workspace.
    ok*: bool
    reason*: string
      ## Why the workspace is not built from the plan, when not `ok`.
    edges*: seq[PlanUnitEdge]
    planFile*: string
    observed*: ObservedReads
      ## What the record run read (empty when it did not run).
    stamps*: Table[string, string]
      ## Their states, taken after the run.
    reusable*: bool
      ## False when the run's reads are not a key (an incomplete capture, an
      ## input that changed while it ran).

proc underAny(path: string; roots: openArray[string]): bool =
  for root in roots:
    if path == root or path.startsWith(root & "/"):
      return true
  false

proc withoutOwnPaths(observed: ObservedReads;
                     own: openArray[string]): ObservedReads =
  ## The record run's reads without its scratch directory, its plan and the
  ## monitor's capture files, which are the edge's own and never evidence.
  result.incomplete = observed.incomplete
  result.envNames = observed.envNames
  for f in observed.files:
    if not f.underAny(own): result.files.add f
  for d in observed.directories:
    if not d.underAny(own): result.directories.add d
  for w in observed.rewritten:
    if not w.underAny(own): result.rewritten.add w

proc emptyDir(path: string) =
  ## Remove `path` (read-only entries included) so the record run finds its
  ## scratch directory empty, as the engine leaves an edge's.
  if not dirExists(path): return
  for entry in walkDirRec(path, yieldFilter = {pcDir}):
    try: setFilePermissions(entry, getFilePermissions(entry) + {fpUserWrite})
    except OSError: discard
  removeDir(path)

type
  PlanToolchain* = object
    ## The tools graph production runs and the edges are given, resolved by
    ## the caller and keyed by it (`toolchainEvaluationInputs`).
    cargo*, rustc*: string
    cc*: string
      ## The C driver rustc links with ("" when there is none).

proc toolchainPath*(t: PlanToolchain): string =
  ## The `PATH` of the record run's closed environment and of every unit
  ## edge: the directories of cargo, rustc and the C driver, nothing else.
  var dirs: seq[string]
  for exe in [t.cargo, t.rustc, t.cc]:
    if exe.len > 0 and parentDir(exe) notin dirs:
      dirs.add parentDir(exe)
  dirs.join($PathSep)

proc toolchainEvaluationInputs*(t: PlanToolchain): seq[GraphEvaluationInput] =
  ## What the toolchain was resolved from and what it is: the `PATH` it was
  ## found on, and the content of each tool. A change of either re-runs
  ## graph production.
  result.add environmentInput("PATH")
  for exe in [t.cargo, t.rustc, t.cc]:
    if exe.len > 0: result.add fileReadInput(exe)

proc closedRecordEnv*(t: PlanToolchain; tmp: string): seq[string] =
  ## The record run's closed environment (`plan_run --env`): the
  ## toolchain's `PATH` and a private `TMPDIR`. The run adds the edge-private
  ## `CARGO_HOME` and `HOME`; nothing of the provider's environment reaches
  ## cargo, so no variable cargo reads (`RUSTFLAGS`, `CARGO_PROFILE_*`,
  ## `CARGO_BUILD_*`, `CARGO_TARGET_<triple>_*`, ...) shapes the plan.
  @["PATH=" & toolchainPath(t), "TMPDIR=" & tmp]

proc publishPlan(runPlan, planFile: string) =
  ## Copy the run's plan to `planFile`, the workspace's last plan, for
  ## inspection; replaced in one rename, so a concurrent reader sees a whole
  ## plan.
  createDir(parentDir(planFile))
  let staged = runPlan & ".publish"
  copyFile(runPlan, staged)
  moveFile(staged, planFile)

proc planWorkspace*(projectRoot: string; tools: PlanToolchain): PlanGraph =
  ## Graph production for the workspace at `projectRoot` (the module
  ## docstring). Never raises for a workspace it cannot build from the plan:
  ## it returns `ok = false` with the reason.
  ##
  ## Each record run has a directory of its own under `PlanDirRel`
  ## (`run-*`), holding its scratch directory, the monitor's capture files,
  ## its temporary directory and its plan, and removed when the run is done:
  ## two evaluations of one workspace at once never empty each other's
  ## state. The plan is then copied to `PlanFileRel`.
  let root = absolutePath(projectRoot)
  result.planFile = root / PlanFileRel
  when not defined(posix):
    result.reason = "the record run is not supported on this platform"
    return
  # 1. The lock's crates.io rows.
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
  let wrapper = wrapperBinaryPath(parentDir(getAppFilename()),
    getEnv(WrapperPathEnv))
  if wrapper.len == 0:
    result.reason = "the record wrapper (" & WrapperBinaryName & ") is " &
      "not installed beside " & getAppFilename() & " and " & WrapperPathEnv &
      " names none"
    return
  # 2. The fetch wave.
  var fetchCfg = defaultCrateFetchConfig(root / FetchStateRel, @[])
  fetchCfg.originBase = CratesIoOrigin
  let store = storeRootOf(fetchCfg)
  var crates: seq[CratePrefix]
  try:
    let fetched = fetchLockedCrates(locked.rows, fetchCfg)
    if not fetched.ok:
      for c in fetched.crates:
        if c.state == csFailed:
          result.reason = "the crate " & c.row.label & " could not be " &
            "fetched: " & failureText(c)
          return
      result.reason = "the fetch wave failed"
      return
    for c in fetched.crates:
      crates.add CratePrefix(name: c.row.name, version: c.row.version,
        prefix: c.prefix)
  except CatchableError as err:
    result.reason = "the fetch wave failed: " & err.msg
    return
  # 3. The record run, in a directory of its own.
  var runDir = ""
  try:
    createDir(root / PlanDirRel)
    runDir = createTempDir("run-", "", root / PlanDirRel)
    createDir(runDir / "tmp")
  except OSError as err:
    result.reason = "the record run's directory cannot be made: " & err.msg
    return
  defer:
    try: emptyDir(runDir)
    except OSError: discard
  let runPlan = runDir / "plan.rbsz"
  let argv = cargoPlanArgv(CargoPlanEdgeConfig(name: "workspace",
    projectRoot: root, planFile: relativePath(runPlan, root),
    scratchDir: relativePath(runDir / "scratch", root),
    wrapper: wrapper, cargo: tools.cargo, rustc: tools.rustc,
    storeRoot: store, cargoArgs: @PlanCargoArgs, crates: crates,
    closedEnv: closedRecordEnv(tools, runDir / "tmp")))
  var observed: ObservedReads
  let started = getTime()
  var run: MonitoredRun
  try:
    run = runMonitoredTool(argv, root, runDir / "capture", "record",
      "cargo plan", observed)
  except MonitorUnavailableError as err:
    result.reason = err.msg
    return
  result.observed = observed.withoutOwnPaths([runDir, result.planFile])
  result.stamps = observedStamps(result.observed)
  result.reusable = result.observed.incomplete.len == 0 and
    unstableObservedReads(result.observed, initTable[string, string](),
      result.stamps, started).len == 0
  if run.exitCode != 0:
    result.reason = "the record run could not plan the workspace: " &
      (run.stderr & run.stdout).strip()
    return
  # 4. The plan's edges.
  try:
    let plan = readCargoPlan(runPlan)
    publishPlan(runPlan, result.planFile)
    result.edges = planUnitEdges(plan, PlanUnitsConfig(projectRoot: root,
      storeRoot: store, outRoot: root / UnitsOutRel,
      registryCrates: locked.rows,
      toolchainEnv: @["PATH=" & toolchainPath(tools)]))
  except PlanUnitsRefusal as err:
    result.reason = err.msg
    return
  except CatchableError as err:
    result.reason = "the plan cannot be built as edges: " & err.msg
    return
  result.ok = true

proc observedEvaluationInputs*(observed: ObservedReads;
                               stamps: Table[string, string];
                               reusable: bool;
                               unobservedIdentity: string):
    seq[GraphEvaluationInput] =
  ## `registerObservedReads` as a list, for a fragment built outside the
  ## build proc that registers inputs (the Mode B fragment of a workspace
  ## whose plan was refused).
  for file in observed.files:
    if file in stamps:
      if stamps[file] != "directory":
        result.add recordedFileReadInput(file, stamps[file])
    elif not dirExists(file):
      result.add fileReadInput(file)
  for dir in observed.directories:
    result.add recordedDirectoryEnumerationInput(dir, directoryMemberNames(dir))
  for name in observed.envNames:
    result.add environmentInput(name)
  if observed.incomplete.len > 0 or not reusable:
    result.add unobservedEvaluationInput(unobservedIdentity)

## Build-graph edges for the library and binary units of cargo's plan.
##
## The record-only graph-production edge (`plan_edge`, `plan_run`) writes the
## PLAN: every unit cargo would compile, with the command line, working
## directory and environment cargo gave it (`cargo_plan`). This module turns
## the plan's units into rustc edges, one per unit, so that in a workspace
## these edges cover EVERY library and binary unit comes from the plan:
## workspace members as well as registry crates. A member's features and
## cfgs are the result of cargo's feature unification across the whole
## build, so they are read from what cargo passed, never derived from the
## manifests or from `cargo metadata`.
##
## WHAT AN EDGE RUNS. The unit's argv exactly as cargo wrote it, with the
## plan's root tokens expanded on this host (`${project}`, the workspace root;
## `${store}`, the store root; `${nix}`, the Nix store; `${out}`, the output
## root the caller gives), in the working directory cargo used. The one
## difference from cargo's command line is the registry crate's remap
## (`crate_compile.registryCrateUnitEdge`); a member's edge runs cargo's
## command line unchanged. The plan already gives every unit its own output
## directory (`${out}/<package>-<version>-<hash>`, cargo's own hash) and puts
## each unit of its closure on the search path as `-L dependency=`.
##
## THE ENVIRONMENT. An edge is launched from its declared environment alone
## (`isolateHostEnvironment`): the variables cargo set for the unit (the
## plan's difference from the record run's own environment, which keeps
## every variable cargo documents setting for a crate) and the TOOLCHAIN
## variables the caller names (`PlanUnitsConfig.toolchainEnv`, such as the
## `PATH` that finds the linker a binary is linked with). The project's
## development environment is not given to a compile: a registry crate's key
## must not move with a project's shell. A name the unit sets is the unit's,
## and the toolchain's value of it is not given.
##
## INCREMENTAL STATE. Cargo passes `-C incremental=<dir>` for a workspace
## member in a profile with incremental compilation. The argv keeps it (it
## is cargo's), and the directory is a SCRATCH directory of the edge: emptied
## before every run and never evidence, so a run never reads the state an
## earlier run left and its outputs depend on its declared inputs alone.
##
## OUTPUTS AND ORDERING. The declared outputs are the files the unit's
## `--emit` writes, except the dep-info file, which rustc still writes and
## which is not an output (as for the registry-crate edge: its paths are
## physical, and the monitor's evidence replaces it). An edge `deps` on the
## edges of the units it consumes (`PlanUnit.consumes`) and declares, to
## order it, the files its `--extern` flags name and, for each other unit
## of its closure, the file a compile of its kind reads (a binary links the
## rlibs; a library reads the rmetas). Its key comes from what the monitor
## records it reading, checked by content (`crate_compile.rustcUnitAction`).
##
## ONE WORKSPACE, ONE BUILDER. A workspace is built either wholly by these
## edges or wholly by cargo, never a mix. So `planUnitEdges` returns an edge
## for every unit of the plan or raises `PlanUnitsRefusal`, which names every
## unit it cannot build and why, and creates no edge. Refused today, each
## until the change that builds it:
##
## - a build script's compile, and each build-script run;
## - a FED unit (`cargo_plan.isFed`): one whose command line or environment
##   takes part of its value from a build script's output (a slot or an
##   `OUT_DIR`);
## - a proc-macro, and any crate type other than `lib`, `rlib` and `bin`;
## - a test target (`--test`);
## - a registry crate the caller gives no lock row for, or one
##   `registryCrateUnitEdge` refuses (not fetched, a manifest that needs a
##   build script, a proc-macro or `links`, a unit that does not compile
##   the crate from its prefix).

import std/[algorithm, os, sets, strutils, tables]

import repro_build_engine
import repro_cargo_fetch/[crate_compile, crate_rows]

import ./[cargo_plan, record_mode]

const
  MemberUnitStatsId* = "rust.rustc-member"
    ## The statistics id of a workspace member's unit edge.
  BuildableCrateTypes = ["lib", "rlib", "bin"]

type
  PlanUnitsRefusal* = object of CatchableError
    ## The plan holds units these edges do not build, so the workspace is
    ## built by cargo as a whole.
    refused*: seq[(string, string)]
      ## (plan id of the unit or run, why), sorted by id

  PlanUnitsConfig* = object
    projectRoot*: string
      ## The workspace root, absolute: `${project}` in the plan.
    storeRoot*: string
      ## The store root, absolute: `${store}` in the plan ("" = none).
    outRoot*: string
      ## The root of the units' output directories, absolute: `${out}`.
    registryCrates*: seq[CrateRow]
      ## The lock rows of the crates.io crates the plan's registry units
      ## compile (name, version and checksum, as the fetch wave read them).
    toolchainEnv*: seq[string]
      ## `NAME=value` variables every edge is given besides cargo's, for the
      ## toolchain itself (the `PATH` that finds the linker).

  PlanUnitEdge* = object
    ## One unit's edge and what a caller or test needs to see of it.
    unit*: PlanUnit
    registry*: bool
      ## a crates.io crate compiled from its store prefix
    cargoArgv*: seq[string]
      ## cargo's command line for the unit, expanded on this host
    argvDifference*: seq[string]
      ## what the edge's argv adds to `cargoArgv`: the remap of a registry
      ## crate, nothing for a member
    env*: seq[string]
      ## the variables cargo set for the unit, expanded (`NAME=value`)
    outDir*: string
    depInfo*: string
      ## the dep-info file rustc writes, not an output ("" when not emitted)
    action*: BuildAction

proc planUnitEdgeId*(u: PlanUnit): string =
  ## `cargo.rustc/<package>@<version>-<hash>`, cargo's own hash: the id a
  ## registry crate's edge has had since it was built from the store.
  RegistryCrateEdgePrefix & u.package & "@" & u.version & "-" &
    u.id[u.id.rfind('-') + 1 .. ^1]

proc crateTypes*(argv: openArray[string]): seq[string] =
  ## The `--crate-type` values of a rustc command line, in order.
  var i = 0
  while i < argv.len:
    var value = ""
    if argv[i] == "--crate-type" and i + 1 < argv.len:
      value = argv[i + 1]
      inc i
    elif argv[i].startsWith("--crate-type="):
      value = argv[i]["--crate-type=".len .. ^1]
    for t in value.split(','):
      if t.len > 0: result.add t
    inc i

proc staticRefusal(u: PlanUnit): string =
  ## Why the plan alone says this unit is not built as an edge, or "".
  if u.buildScriptCompile:
    return "is the compile of a build script, and build scripts are not " &
      "built as edges yet"
  if u.isFed:
    var feeders = u.fedBy
    if u.outDirRun.len > 0 and u.outDirRun notin feeders:
      feeders.add u.outDirRun
    for s in u.envSlots:
      if s.run notin feeders: feeders.add s.run
    feeders.sort()
    return "takes part of its command line or environment from the output " &
      "of the build-script run " & feeders.join(", ") & ", and units fed " &
      "by a build script are not built as edges yet"
  if "--test" in u.argv:
    return "is a test target, and test targets are not built from the plan " &
      "yet"
  let types = crateTypes(u.argv)
  if types.len == 0:
    return "names no crate type"
  for t in types:
    if t == "proc-macro":
      return "is a proc-macro, and proc-macros are not built as edges yet"
    if t notin BuildableCrateTypes:
      return "has crate type " & t & ", and only " &
        BuildableCrateTypes.join(", ") & " units are built from the plan"
  ""

proc refusalMessage(refused: seq[(string, string)]): string =
  result = "the cargo plan holds units these edges do not build, so the " &
    "workspace is built by cargo as a whole:"
  for (id, why) in refused:
    result.add "\n  " & id & " " & why

proc raiseRefusal(refused: var seq[(string, string)]) {.noreturn.} =
  refused.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))
  var e = newException(PlanUnitsRefusal, refusalMessage(refused))
  e.refused = refused
  raise e

proc planRoots(cfg: PlanUnitsConfig): seq[RecordRoot] =
  var text = "project=" & cfg.projectRoot & "\n" & OutRootLabel & "=" &
    cfg.outRoot
  if cfg.storeRoot.len > 0: text.add "\nstore=" & cfg.storeRoot
  if dirExists("/nix/store"): text.add "\nnix=/nix/store"
  parseRecordRoots(text)

proc expand(roots: openArray[RecordRoot]; text, where: string): string =
  try:
    expandRecorded(roots, text)
  except RecordModeError as err:
    raise newException(CargoPlanError, where & ": " & err.msg)

proc externPaths(argv: openArray[string]): seq[string] =
  ## The files a command line's `--extern name=path` flags name.
  var i = 0
  while i < argv.len:
    var value = ""
    if argv[i] == "--extern" and i + 1 < argv.len:
      value = argv[i + 1]
      inc i
    elif argv[i].startsWith("--extern="):
      value = argv[i]["--extern=".len .. ^1]
    let eq = value.find('=')
    if eq > 0: result.add value[eq + 1 .. ^1]
    inc i

proc planUnitEdges*(plan: CargoPlan; cfg: PlanUnitsConfig): seq[PlanUnitEdge] =
  ## One rustc edge per unit of ``plan`` (see the module docstring), sorted
  ## by the units' plan ids. Raises `PlanUnitsRefusal`, creating no edge,
  ## when any unit or run of the plan is one these edges do not build;
  ## `CargoPlanError` when the plan names a root this host does not have
  ## (`${nix}` without a Nix store, `${store}` with no store root given);
  ## `ValueError` for a configuration without the absolute roots it needs.
  ## Each unit's output directory is created; nothing else is written.
  for (what, path) in [("workspace root", cfg.projectRoot),
                       ("output root", cfg.outRoot)]:
    if path.len == 0 or not path.isAbsolute:
      raise newException(ValueError, "the plan's units need an absolute " &
        what & ", not " & path.escape())
  if cfg.storeRoot.len > 0 and not cfg.storeRoot.isAbsolute:
    raise newException(ValueError, "the store root must be absolute: " &
      cfg.storeRoot)
  validatePlan(plan)
  let roots = planRoots(cfg)
  var rows = initTable[string, CrateRow]()
  for row in cfg.registryCrates: rows[row.name & "@" & row.version] = row

  # 1. What the plan alone says is not built here.
  var refused: seq[(string, string)]
  for r in plan.runs:
    refused.add (r.id, "is a build-script run, and build scripts are not " &
      "built as edges yet")
  for u in plan.units:
    let why = staticRefusal(u)
    if why.len > 0: refused.add (u.id, why)
    elif u.cwd.startsWith("${store}/") and
        u.package & "@" & u.version notin rows:
      refused.add (u.id, "compiles the registry crate " & u.package & "@" &
        u.version & ", for which no lock row was given")
  if refused.len > 0: raiseRefusal(refused)

  # 2. The edges.
  var byId = initTable[string, PlanUnit]()
  for u in plan.units: byId[u.id] = u
  for u in plan.units:
    let where = "the unit " & u.id
    let argv = block:
      var s: seq[string]
      for a in u.argv: s.add expand(roots, a, where)
      s
    let cwd = expand(roots, u.cwd, where)
    var env: seq[string]
    var named = initHashSet[string]()
    for (name, value) in u.env:
      env.add name & "=" & expand(roots, value, where & " (" & name & ")")
      named.incl name
    var launchEnv = env
    for entry in cfg.toolchainEnv:
      let eq = entry.find('=')
      if eq <= 0:
        raise newException(ValueError, "a toolchain variable must be " &
          "NAME=value: " & entry.escape())
      if entry[0 ..< eq] notin named: launchEnv.add entry
    let outDir = cfg.outRoot / u.id
    var outputs: seq[string]
    for o in u.outputs: outputs.add expand(roots, o, where)
    var depInfo = ""
    var declared: seq[string]
    for o in outputs:
      if o.endsWith(".d"): depInfo = o
      else: declared.add o
    # Ordering: the files `--extern` names, and the matching file of every
    # other unit of the closure.
    let links = "bin" in crateTypes(u.argv)
    var inputs = externPaths(argv)
    for c in u.closure:
      for o in byId[c].outputs:
        if o.endsWith(if links: ".rlib" else: ".rmeta"):
          let path = expand(roots, o, where)
          if path notin inputs: inputs.add path
    var deps: seq[string]
    for c in u.consumes: deps.add planUnitEdgeId(byId[c])
    var scratch: seq[string]
    if u.cargoIncrementalDir.len > 0: scratch.add outDir / "incremental"
    if u.cwd.startsWith("${store}/"):
      let row = rows[u.package & "@" & u.version]
      try:
        let e = registryCrateUnitEdge(row, cfg.storeRoot, RegistryCrateUnit(
          hash: u.id[u.id.rfind('-') + 1 .. ^1], crateName: u.crateName,
          argv: argv, cwd: cwd, env: launchEnv, outDir: outDir,
          outputs: outputs, deps: deps, inputs: inputs,
          scratchDirs: scratch, isolateHostEnvironment: true))
        result.add PlanUnitEdge(unit: u, registry: true, cargoArgv: argv,
          argvDifference: e.argvDifference, env: env, outDir: outDir,
          depInfo: depInfo, action: e.action)
      except RegistryCrateRefusal as err:
        refused.add (u.id, "is refused as a registry crate: " & err.msg)
    else:
      createDir(outDir)
      result.add PlanUnitEdge(unit: u, cargoArgv: argv, env: env,
        outDir: outDir, depInfo: depInfo,
        action: rustcUnitAction(planUnitEdgeId(u), argv, cwd = cwd,
          deps = deps, inputs = inputs, outputs = declared, env = launchEnv,
          commandStatsId = MemberUnitStatsId, isolateHostEnvironment = true,
          scratchDirs = scratch))
  if refused.len > 0: raiseRefusal(refused)

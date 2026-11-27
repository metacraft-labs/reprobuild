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
## must not move with a project's shell. The variables the dev shell's cargo
## wrapper changes for itself (`CargoWrapperVariables`: `PATH`, `SHLVL`,
## `PWD`, `OLDPWD`, `_`), which cargo does not set for a compile, are dropped
## from the difference, so the toolchain's `PATH` is an edge's only `PATH`.
## A toolchain variable that cargo also set for the unit, or removed from
## it, is refused: the edge would no longer get what cargo gave the unit.
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
## unit it cannot build and why, and creates no edge and no directory (every
## check, the registry crates' too, is made before anything is written). Refused today, each
## until the change that builds it:
##
## - a build script's compile, and each build-script run;
## - a FED unit (`cargo_plan.isFed`): one whose command line or environment
##   takes part of its value from a build script's output (a slot or an
##   `OUT_DIR`);
## - a proc-macro, and any crate type other than `lib`, `rlib` and `bin`;
## - a test target (`--test`);
## - a unit that writes split debug information (`-C split-debuginfo`
##   other than `off`, explicitly or as rustc's default for an Apple or a
##   Windows MSVC target with debug information on), whose side files
##   (`.dwo`, `.dwp`, `.dSYM`, `.pdb`) are not declared outputs yet;
## - a unit passing `-C prefer-dynamic`;
## - a unit given a toolchain variable that cargo set or removed for it;
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
  CargoWrapperVariables* = ["PATH", "SHLVL", "PWD", "OLDPWD", "_"]
    ## Variables a unit's recorded difference can carry that cargo does not
    ## set for a compile on Linux and macOS: the dev shell's `cargo` is a
    ## shell script around the real one, which changes them for itself, and
    ## every process cargo starts inherits the change. They are not given
    ## to an edge, so a dev-shell bump does not change a unit's key, and the
    ## toolchain's `PATH` (`PlanUnitsConfig.toolchainEnv`) picks the linker.
    ## (Cargo extends `PATH` on Windows as its dynamic-library path; the
    ## record mode is refused there.)

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

proc codegenOption*(argv: openArray[string]; key: string):
    tuple[found: bool, value: string] =
  ## The last `-C <key>[=<value>]` of a rustc command line (rustc takes the
  ## last), with "" for a key given without a value.
  var i = 0
  while i < argv.len:
    var opt = ""
    if argv[i] in ["-C", "--codegen"] and i + 1 < argv.len:
      opt = argv[i + 1]
      inc i
    elif argv[i].startsWith("-C") and argv[i].len > 2:
      opt = argv[i][2 .. ^1]
    elif argv[i].startsWith("--codegen="):
      opt = argv[i]["--codegen=".len .. ^1]
    if opt == key:
      result = (true, "")
    elif opt.startsWith(key & "="):
      result = (true, opt[key.len + 1 .. ^1])
    inc i

proc effectiveSplitDebuginfo*(argv: openArray[string]): string =
  ## The `-C split-debuginfo` a rustc command line compiles with: the value
  ## it passes, or, when it passes none, rustc's default for the target
  ## (`off` on Linux; `packed` for an Apple or a Windows MSVC target, where
  ## rustc writes a `.dSYM` or a `.pdb` beside a linked output) when it
  ## asks for debug information at all; `off` when it asks for none.
  ## https://doc.rust-lang.org/rustc/codegen-options/index.html#split-debuginfo
  let explicit = codegenOption(argv, "split-debuginfo")
  if explicit.found: return explicit.value
  let debug = codegenOption(argv, "debuginfo")
  var wantsDebug = debug.found and debug.value notin ["0", "none"]
  if "-g" in argv: wantsDebug = true
  if not wantsDebug: return "off"
  var target = ""
  for i, a in argv:
    if a == "--target" and i + 1 < argv.len: target = argv[i + 1]
    elif a.startsWith("--target="): target = a["--target=".len .. ^1]
  if target.len == 0:
    target = (when defined(macosx): "apple"
              elif defined(windows): "windows-msvc"
              else: "")
  if "apple" in target or "windows-msvc" in target: "packed" else: "off"

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
  let split = effectiveSplitDebuginfo(u.argv)
  if split != "off":
    return "writes split debug information (-C split-debuginfo=" & split &
      "), whose side files are not declared outputs yet"
  let dynamic = codegenOption(u.argv, "prefer-dynamic")
  if dynamic.found and dynamic.value notin ["no", "n", "off", "false"]:
    return "passes -C prefer-dynamic, which links the standard library " &
      "dynamically from the toolchain, and is not built from the plan"
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

type
  Prepared = object
    ## One unit's edge, computed in the checking pass, before anything is
    ## written.
    unit: PlanUnit
    registry: bool
    row: CrateRow
    argv, env, launchEnv, outputs, declared, inputs, deps, scratch: seq[string]
    cwd, outDir, depInfo: string

proc registryUnit(p: Prepared): RegistryCrateUnit =
  RegistryCrateUnit(hash: p.unit.id[p.unit.id.rfind('-') + 1 .. ^1],
    crateName: p.unit.crateName, argv: p.argv, cwd: p.cwd,
    env: p.launchEnv, outDir: p.outDir, outputs: p.outputs, deps: p.deps,
    inputs: p.inputs, scratchDirs: p.scratch, isolateHostEnvironment: true)

proc planUnitEdges*(plan: CargoPlan; cfg: PlanUnitsConfig): seq[PlanUnitEdge] =
  ## One rustc edge per unit of ``plan`` (see the module docstring), sorted
  ## by the units' plan ids. Raises `PlanUnitsRefusal` when any unit or run
  ## of the plan is one these edges do not build; `CargoPlanError` when the
  ## plan names a root this host does not have (`${nix}` without a Nix
  ## store, `${store}` with no store root given); `ValueError` for a
  ## configuration without the absolute roots it needs or with a malformed
  ## toolchain variable. Every check, the registry crates' included, is made
  ## before anything is written, so a refused or failed plan creates no
  ## directory; an accepted one creates each unit's output directory.
  for (what, path) in [("workspace root", cfg.projectRoot),
                       ("output root", cfg.outRoot)]:
    if path.len == 0 or not path.isAbsolute:
      raise newException(ValueError, "the plan's units need an absolute " &
        what & ", not " & path.escape())
  if cfg.storeRoot.len > 0 and not cfg.storeRoot.isAbsolute:
    raise newException(ValueError, "the store root must be absolute: " &
      cfg.storeRoot)
  var toolchainNames: seq[string]
  for entry in cfg.toolchainEnv:
    let eq = entry.find('=')
    if eq <= 0:
      raise newException(ValueError, "a toolchain variable must be " &
        "NAME=value: " & entry.escape())
    toolchainNames.add entry[0 ..< eq]
  validatePlan(plan)
  let roots = planRoots(cfg)
  var rows = initTable[string, CrateRow]()
  for row in cfg.registryCrates: rows[row.name & "@" & row.version] = row
  var byId = initTable[string, PlanUnit]()
  for u in plan.units: byId[u.id] = u

  # 1. Every check, writing nothing.
  var refused: seq[(string, string)]
  for r in plan.runs:
    refused.add (r.id, "is a build-script run, and build scripts are not " &
      "built as edges yet")
  var prepared: seq[Prepared]
  for u in plan.units:
    let why = staticRefusal(u)
    if why.len > 0:
      refused.add (u.id, why)
      continue
    var p = Prepared(unit: u, registry: u.cwd.startsWith("${store}/"))
    if p.registry:
      if u.package & "@" & u.version notin rows:
        refused.add (u.id, "compiles the registry crate " & u.package & "@" &
          u.version & ", for which no lock row was given")
        continue
      p.row = rows[u.package & "@" & u.version]
    let where = "the unit " & u.id
    for a in u.argv: p.argv.add expand(roots, a, where)
    p.cwd = expand(roots, u.cwd, where)
    var named: seq[string]
    for (name, value) in u.env:
      # What the dev shell's cargo wrapper changed for itself, which cargo
      # does not set for a compile: not given to the edge, so the
      # toolchain's `PATH` is the edge's only `PATH`.
      if name in CargoWrapperVariables: continue
      p.env.add name & "=" & expand(roots, value, where & " (" & name & ")")
      named.add name
    var clash = ""
    for name in toolchainNames:
      if name in named:
        clash = "is given " & name & " by cargo, and the toolchain " &
          "variables name it too"
      elif name in u.envRemoved:
        clash = "has " & name & " removed by cargo, and the toolchain " &
          "variables set it"
    if clash.len > 0:
      refused.add (u.id, clash)
      continue
    p.launchEnv = p.env & cfg.toolchainEnv
    p.outDir = cfg.outRoot / u.id
    for o in u.outputs: p.outputs.add expand(roots, o, where)
    for o in p.outputs:
      if o.endsWith(".d"): p.depInfo = o
      else: p.declared.add o
    # Ordering: the files `--extern` names, and the matching file of every
    # other unit of the closure.
    let links = "bin" in crateTypes(u.argv)
    p.inputs = externPaths(p.argv)
    for c in u.closure:
      for o in byId[c].outputs:
        if o.endsWith(if links: ".rlib" else: ".rmeta"):
          let path = expand(roots, o, where)
          if path notin p.inputs: p.inputs.add path
    for c in u.consumes: p.deps.add planUnitEdgeId(byId[c])
    if u.cargoIncrementalDir.len > 0: p.scratch.add p.outDir / "incremental"
    if p.registry:
      try:
        discard checkRegistryCrateUnit(p.row, cfg.storeRoot,
          registryUnit(p))
      except RegistryCrateRefusal as err:
        refused.add (u.id, "is refused as a registry crate: " & err.msg)
        continue
    prepared.add p
  if refused.len > 0: raiseRefusal(refused)

  # 2. The edges.
  for p in prepared:
    if p.registry:
      let e = registryCrateUnitEdge(p.row, cfg.storeRoot, registryUnit(p))
      result.add PlanUnitEdge(unit: p.unit, registry: true,
        cargoArgv: p.argv, argvDifference: e.argvDifference, env: p.env,
        outDir: p.outDir, depInfo: p.depInfo, action: e.action)
    else:
      createDir(p.outDir)
      result.add PlanUnitEdge(unit: p.unit, cargoArgv: p.argv, env: p.env,
        outDir: p.outDir, depInfo: p.depInfo,
        action: rustcUnitAction(planUnitEdgeId(p.unit), p.argv, cwd = p.cwd,
          deps = p.deps, inputs = p.inputs, outputs = p.declared,
          env = p.launchEnv, commandStatsId = MemberUnitStatsId,
          isolateHostEnvironment = true, scratchDirs = p.scratch))

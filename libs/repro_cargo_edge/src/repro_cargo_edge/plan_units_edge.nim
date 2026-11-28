## The units edge: turns cargo's plan into build-graph edges while the build
## runs.
##
## A workspace built from cargo's plan has, in its static graph, the fetch
## edges of its lock, the record-only plan edge (`plan_edge`, whose one output
## is the plan), this edge, and a COLLECTOR. This edge reads the plan and
## writes a `repro-dynamic-graph-v1` fragment; the collector names the
## fragment as its `dynamicDepsFile`, so the engine creates the fragment's
## actions when the collector is about to run, and the collector waits for
## them. Nothing about the units is known when the graph is evaluated: the
## plan is the product of an edge, cached and shared like any other.
##
## WHAT THE FRAGMENT HOLDS.
##
## - For a plan these edges build, one `create-action` record per unit
##   (`plan_units.planUnitEdges`, each record `createActionRecord` of the
##   unit's spec, so the engine creates exactly the action `planUnitEdges`
##   built, key included), and the collector's dependency on each.
## - For a plan they do not build as a whole (`PlanUnitsRefusal`: a build
##   script, a proc-macro, a fed unit, ...) or one the record run refused
##   (`CargoPlan.refusal`), the record of the workspace's Mode B build edge
##   (`mode_b.modeBBuildSpec`), and the collector's dependency on it. The
##   record is read from the file the graph's evaluation wrote it to, so it
##   is the Mode B edge the workspace would have had if it had been sent to
##   Mode B statically. No unit edge exists then: a workspace is built either
##   wholly by these edges or wholly by cargo.
##
## The edge is monitored and cacheable: its key is its argv and what it
## reads (the plan and the Mode B record). It writes nothing but the
## fragment; the units' output directories are created by the engine before
## each unit runs.

import std/[os, strutils, tables]

import repro_build_engine
import repro_lock/identity
import repro_cargo_fetch/crate_rows

import ./[cargo_plan, plan_units]

const
  PlanUnitsFlag* = "--cargo-plan-units"
    ## The standard provider's units-edge command (the image that already
    ## runs the thin cargo edge; the record wrapper, which cargo runs for
    ## every rustc invocation, does not link the engine).
  PlanCollectFlag* = "--cargo-plan-collect"
    ## The standard provider's collector command: checks the fragment exists.
  PlanUnitsEdgePrefix* = "cargo.plan-units/"
  PlanCollectorPrefix* = "cargo.workspace/"
  DynamicGraphHeader* = "repro-dynamic-graph-v1"
  PlanUnitsUsage* = "usage: repro-standard-provider " & PlanUnitsFlag &
    " --plan FILE --fragment FILE --mode-b FILE --collector ID" &
    " --project-root DIR --out-root DIR [--store-root DIR]" &
    " [--toolchain-env NAME=VALUE]... [--crate NAME@VERSION=CKSUM]...\n"

type
  PlanUnitsEdgeError* = object of CatchableError

  PlanUnitsOptions* = object
    ## The units edge's arguments (`PlanUnitsUsage`).
    planFile*, fragmentFile*, modeBFile*: string
    collector*: string
    projectRoot*, storeRoot*, outRoot*: string
    toolchainEnv*: seq[string]
    crates*: seq[CrateRow]

  PlanUnitsOutcome* = object
    ## What the edge wrote.
    modeB*: bool
      ## the workspace is built by cargo as a whole
    reason*: string
      ## why, when `modeB`
    createdIds*: seq[string]

proc planUnitsEdgeId*(name: string): string = PlanUnitsEdgePrefix & name
proc planCollectorId*(name: string): string = PlanCollectorPrefix & name

proc crateRowArg*(r: CrateRow): string =
  r.name & "@" & r.version & "=" & r.cksum

proc parseCrateRowArg(arg: string): CrateRow =
  let at = arg.find('@')
  let eq = arg.find('=')
  if at <= 0 or eq <= at + 1 or eq == arg.high:
    raise newException(PlanUnitsEdgeError, "--crate takes " &
      "NAME@VERSION=CKSUM, not " & arg.escape())
  result = CrateRow(name: arg[0 ..< at], version: arg[at + 1 ..< eq],
    cksum: arg[eq + 1 .. ^1])
  try: validateRow(result)
  except CatchableError as err:
    raise newException(PlanUnitsEdgeError, "--crate " & arg & ": " & err.msg)

proc planUnitsArgv*(helper: string; o: PlanUnitsOptions): seq[string] =
  ## The units edge's command line, run by ``helper`` (the standard
  ## provider's image).
  result = @[helper, PlanUnitsFlag, "--plan", o.planFile, "--fragment",
    o.fragmentFile, "--mode-b", o.modeBFile, "--collector", o.collector,
    "--project-root", o.projectRoot, "--out-root", o.outRoot]
  if o.storeRoot.len > 0:
    result.add ["--store-root", o.storeRoot]
  for e in o.toolchainEnv:
    result.add ["--toolchain-env", e]
  for r in o.crates:
    result.add ["--crate", crateRowArg(r)]

proc parsePlanUnitsArgs*(args: seq[string]): PlanUnitsOptions =
  ## The options after `PlanUnitsFlag`. Raises `PlanUnitsEdgeError`.
  var i = 0
  proc value(name: string): string =
    if i + 1 >= args.len:
      raise newException(PlanUnitsEdgeError, name & " needs a value")
    inc i
    args[i]
  while i < args.len:
    let a = args[i]
    case a
    of "--plan": result.planFile = value(a)
    of "--fragment": result.fragmentFile = value(a)
    of "--mode-b": result.modeBFile = value(a)
    of "--collector": result.collector = value(a)
    of "--project-root": result.projectRoot = value(a)
    of "--store-root": result.storeRoot = value(a)
    of "--out-root": result.outRoot = value(a)
    of "--toolchain-env": result.toolchainEnv.add value(a)
    of "--crate": result.crates.add parseCrateRowArg(value(a))
    else:
      raise newException(PlanUnitsEdgeError, "unexpected argument " &
        a.escape())
    inc i
  for (name, v) in [("--plan", result.planFile),
                    ("--fragment", result.fragmentFile),
                    ("--mode-b", result.modeBFile),
                    ("--collector", result.collector),
                    ("--project-root", result.projectRoot),
                    ("--out-root", result.outRoot)]:
    if v.len == 0:
      raise newException(PlanUnitsEdgeError, name & " is required")

proc unitsConfig*(o: PlanUnitsOptions;
                  governingLockIdentity: LockIdentity): PlanUnitsConfig =
  ## The `planUnitEdges` configuration the edge plans with. A caller that
  ## wants the keys the engine will give the created actions passes the
  ## collector's lock identity (they inherit their producer's).
  PlanUnitsConfig(projectRoot: o.projectRoot, storeRoot: o.storeRoot,
    outRoot: o.outRoot, registryCrates: o.crates,
    toolchainEnv: o.toolchainEnv, deferOutputDirs: true,
    governingLockIdentity: governingLockIdentity)

proc modeBRecord(o: PlanUnitsOptions): CreatedActionSpec =
  ## The Mode B edge's record as the graph's evaluation wrote it.
  let text =
    try: readFile(o.modeBFile).strip()
    except IOError as err:
      raise newException(PlanUnitsEdgeError, "the Mode B record " &
        o.modeBFile & " cannot be read: " & err.msg)
  try:
    parseCreatedActionSpec(text)
  except ValueError as err:
    raise newException(PlanUnitsEdgeError, "the Mode B record " &
      o.modeBFile & " is not a create-action record: " & err.msg)

proc inDependencyOrder(specs: seq[CreatedActionSpec]): seq[CreatedActionSpec] =
  ## ``specs`` with every spec after the specs it `deps` on, and otherwise in
  ## the given order: the engine registers a fragment's records one by one
  ## and refuses one that depends on an action it does not know yet. A
  ## dependency outside ``specs`` is left to the engine to judge. Raises
  ## `PlanUnitsEdgeError` on a cycle.
  var index = initTable[string, int]()
  for i, spec in specs: index[spec.id] = i
  var state = newSeq[int](specs.len)  # 0 new, 1 on the stack, 2 placed
  var ordered: seq[CreatedActionSpec]
  proc visit(i: int) =
    if state[i] == 2: return
    if state[i] == 1:
      raise newException(PlanUnitsEdgeError, "the plan's units depend on " &
        "each other in a cycle through " & specs[i].id)
    state[i] = 1
    for dep in specs[i].deps:
      if dep in index: visit(index[dep])
    state[i] = 2
    ordered.add specs[i]
  for i in 0 ..< specs.len: visit(i)
  ordered

proc unitsFragment*(o: PlanUnitsOptions): (string, PlanUnitsOutcome) =
  ## The fragment's text and what it holds (see the module docstring).
  ## Raises `CargoPlanError` for a plan that cannot be read or names a root
  ## this host lacks, `PlanUnitsEdgeError` for a Mode B record that cannot be
  ## read, `ValueError` for a malformed configuration.
  let plan = readCargoPlan(o.planFile)
  var outcome: PlanUnitsOutcome
  var specs: seq[CreatedActionSpec]
  if plan.refusal.len > 0:
    outcome.modeB = true
    outcome.reason = plan.refusal
  else:
    try:
      # The identity only completes the actions `planUnitEdges` returns;
      # the records carry none, and the engine gives the created actions
      # the collector's.
      for e in planUnitEdges(plan, unitsConfig(o,
          lockIdentityOutsideSolvedGraph())):
        specs.add e.spec
    except PlanUnitsRefusal as err:
      outcome.modeB = true
      outcome.reason = err.msg
  if outcome.modeB:
    specs = @[modeBRecord(o)]
  specs = inDependencyOrder(specs)
  var text = DynamicGraphHeader & "\n"
  for spec in specs:
    text.add "create-action\t" & createActionRecord(spec) & "\n"
  for spec in specs:
    text.add "dep\t" & o.collector & "\t" & spec.id & "\n"
    outcome.createdIds.add spec.id
  (text, outcome)

proc runPlanUnits*(o: PlanUnitsOptions): PlanUnitsOutcome =
  ## The edge's process: write the fragment, replaced in one rename.
  let (text, outcome) = unitsFragment(o)
  let path = absolutePath(o.fragmentFile)
  createDir(parentDir(path))
  let partial = path & ".partial"
  writeFile(partial, text)
  moveFile(partial, path)
  outcome

proc runPlanUnitsCommand*(args: openArray[string]): int =
  ## `args` are the arguments after `PlanUnitsFlag`.
  var o: PlanUnitsOptions
  try:
    o = parsePlanUnitsArgs(@args)
  except PlanUnitsEdgeError as err:
    stderr.writeLine "repro-standard-provider " & PlanUnitsFlag & ": " & err.msg
    stderr.write PlanUnitsUsage
    return 2
  try:
    let outcome = runPlanUnits(o)
    if outcome.modeB:
      # One line naming the reason (Rust.md § Recognition): the workspace is
      # built by cargo as a whole.
      stderr.writeLine "repro-standard-provider " & PlanUnitsFlag & ": the " &
        "workspace is built by cargo as a whole (Mode B): " & outcome.reason
    0
  except CatchableError as err:
    stderr.writeLine "repro-standard-provider " & PlanUnitsFlag & ": " & err.msg
    1

proc runPlanCollectCommand*(args: openArray[string]): int =
  ## The collector's process: the engine has created and run the
  ## fragment's actions before it; it checks the fragment is there.
  if args.len != 1:
    stderr.writeLine "usage: repro-standard-provider " & PlanCollectFlag &
      " FRAGMENT"
    return 2
  if not fileExists(args[0]):
    stderr.writeLine "repro-standard-provider " & PlanCollectFlag & ": no " &
      "fragment at " & args[0]
    return 1
  0

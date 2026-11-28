## The units edge writes, for each unit of cargo's plan, a `create-action`
## record from which the engine creates exactly the action `planUnitEdges`
## built for it: same id, argv, environment, scratch directories and weak
## fingerprint, under the lock identity of the fragment's producer (which a
## created action inherits, Named-Lock-Files §4.1).
##
## So the key a unit's edge has does not depend on whether it was declared
## from the plan directly or created from the fragment, and a record a build
## publishes for one is served to the other. And when the plan is one these
## edges do not build, the fragment holds the Mode B edge's record and no
## unit at all.
##
## No mocks: the real units edge (`unitsFragment`) over plans written by
## hand in the shape the derivation writes (as `t_plan_units` does), the
## engine's own record parser and constructor. Nothing is run.
##
## Falsifying mutations: `planUnitEdges` building its actions under
## `lockIdentityOutsideSolvedGraph()` instead of the identity it is given
## fails the first case (every key differs); writing the records in the
## plan's order instead of dependency order fails its ordering checks.

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_cargo_edge/[cargo_plan, mode_b, plan_units, plan_units_edge]
import repro_lock/identity

proc libUnit(name, hash: string; types = "lib";
             consumes: seq[string] = @[]): PlanUnit =
  let id = name & "-1.0.0-" & hash
  result = PlanUnit(id: id, package: name, version: "1.0.0",
    crateName: name, cargoOutDir: "debug/deps", cwd: "${project}",
    consumes: consumes, closure: consumes)
  result.argv = @["${project}/rustc", "--crate-name", name, "--crate-type",
    types, "--emit=dep-info,metadata,link", "-C",
    "extra-filename=-" & hash, "--out-dir", "${out}/" & id]
  for c in consumes:
    result.argv.add ["-L", "dependency=${out}/" & c, "--extern",
      c.split('-')[0] & "=${out}/" & c & "/lib" & c.split('-')[0] & "-" &
      c.split('-')[^1] & ".rmeta"]
  result.env = @[("CARGO_PKG_NAME", name), ("CARGO_PKG_VERSION", "1.0.0")]
  let stem = name & "-" & hash
  result.outputs = @["${out}/" & id & "/" & stem & ".d"]
  if types == "bin":
    result.outputs.add "${out}/" & id & "/" & stem
  else:
    result.outputs.add ["${out}/" & id & "/lib" & stem & ".rlib",
      "${out}/" & id & "/lib" & stem & ".rmeta"]

proc options(work: string): PlanUnitsOptions =
  createDir(work / "ws")
  PlanUnitsOptions(planFile: work / "plan.rbsz",
    fragmentFile: work / "units.rbdyn", modeBFile: work / "mode-b.record",
    collector: planCollectorId("ws"), projectRoot: work / "ws",
    storeRoot: work / "store", outRoot: work / "out",
    toolchainEnv: @["PATH=/toolchain/bin"])

proc writeModeB(o: PlanUnitsOptions): CreatedActionSpec =
  result = modeBBuildSpec("crude-build-ws", "/helper", "/toolchain/cargo",
    o.projectRoot, "ws", [o.projectRoot / "Cargo.toml"])
  writeFile(o.modeBFile, createActionRecord(result) & "\n")

proc records(fragment: string): seq[CreatedActionSpec] =
  for line in fragment.splitLines():
    if line.startsWith("create-action\t"):
      result.add parseCreatedActionSpec(line["create-action\t".len .. ^1])

proc deps(fragment: string): seq[string] =
  for line in fragment.splitLines():
    if line.startsWith("dep\t"): result.add line

let ProducerLock = LockIdentity("blake3:" & '7'.repeat(64))
  ## Stands for the collector's lock identity: any identity other than the
  ## one `planUnitEdges` would use by default shows the key follows it.

suite "a unit created from the units edge's record has planUnitEdges' key":

  test "every unit's created action has its planned key":
    let work = createTempDir("rqe-cg5-keys-", "")
    defer: removeDir(work)
    let o = options(work)
    discard writeModeB(o)
    # The binary sorts before the library it links, so the plan's order is
    # not dependency order and the units edge must reorder the records.
    let a = libUnit("zed", "0000000000000001")
    var b = libUnit("app", "0000000000000002", types = "bin", consumes = @[a.id])
    b.argv.add ["-C", "incremental=${out}/" & b.id & "/incremental"]
    b.cargoIncrementalDir = "debug/incremental"
    let plan = CargoPlan(units: @[b, a])   # sorted by id, as derived
    writeCargoPlan(o.planFile, plan)
    let (text, outcome) = unitsFragment(o)
    check not outcome.modeB
    let planned = planUnitEdges(plan, unitsConfig(o, ProducerLock))
    let created = records(text)
    require created.len == planned.len
    for e in planned:
      var spec: CreatedActionSpec
      var found = false
      for c in created:
        if c.id == e.action.id:
          spec = c
          found = true
      checkpoint e.action.id
      require found
      let action = createdAction(spec, ProducerLock)
      checkpoint e.action.id
      check action.id == e.action.id
      check action.weakFingerprint == e.action.weakFingerprint
      check action.argv == e.action.argv
      check action.env == e.action.env
      check action.scratchDirs == e.action.scratchDirs
      check action.isolateHostEnvironment
    var expectedDeps: seq[string]
    for c in created: expectedDeps.add "dep\t" & o.collector & "\t" & c.id
    check deps(text) == expectedDeps
    check planned[0].action.id.startsWith("cargo.rustc/app@")
    check created[0].id.startsWith("cargo.rustc/zed@")
    # Every record comes after the records of the units it depends on: the
    # engine refuses one naming an action it has not registered yet.
    var seen: seq[string]
    for c in created:
      for dep in c.deps: check dep in seen
      seen.add c.id
    # The units edge writes the fragment and nothing else: the engine makes
    # each unit's directory before it runs.
    check not dirExists(o.outRoot)

  test "a plan these edges do not build gives the Mode B edge alone":
    let work = createTempDir("rqe-cg5-keys-refused-", "")
    defer: removeDir(work)
    let o = options(work)
    let modeB = writeModeB(o)
    let plan = CargoPlan(units: @[libUnit("a", "0000000000000001",
      types = "proc-macro")])
    writeCargoPlan(o.planFile, plan)
    let (text, outcome) = unitsFragment(o)
    check outcome.modeB
    check "proc-macro" in outcome.reason
    check records(text) == @[modeB]
    check deps(text) == @["dep\t" & o.collector & "\t" & modeB.id]

  test "a plan the record run refused gives the Mode B edge alone":
    let work = createTempDir("rqe-cg5-keys-run-refused-", "")
    defer: removeDir(work)
    let o = options(work)
    let modeB = writeModeB(o)
    writeCargoPlan(o.planFile, CargoPlan(refusal: "a [patch] table"))
    let (text, outcome) = unitsFragment(o)
    check outcome.modeB
    check outcome.reason == "a [patch] table"
    check records(text) == @[modeB]

  test "a refused plan cannot carry units":
    expect CargoPlanError:
      validatePlan(CargoPlan(refusal: "x",
        units: @[libUnit("a", "0000000000000001")]))

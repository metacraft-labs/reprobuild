## The edges of a plan's library and binary units (`plan_units`), on plans
## written by hand: what each edge declares, and that a plan holding any unit
## these edges do not build is refused as a whole, naming every such unit.
##
## The edges built from a real record run, compared with a real cargo build
## and run through the engine, are the integration case
## `tests/integration/t_rqe_cg5_plan_completes_to_cargos_argv`.
##
## No mocks. The plans are written by hand in the shape the derivation writes
## them, because what is tested is the emitter's handling of unit kinds a
## record run of one fixture does not all produce (a test target, a cdylib, a
## registry unit with no lock row). Nothing is run.
##
## Falsifying mutations (applied, observed to fail, reverted): not making the
## incremental directory a scratch directory fails the first case; letting
## the toolchain's value replace a variable cargo set fails the second;
## letting a test target through fails the third.

import std/[os, sequtils, strutils, tempfiles, unittest]

import repro_build_engine
import repro_cargo_edge/[cargo_plan, plan_units]
import repro_cargo_fetch/crate_rows
import repro_test_support/reasoned_skip

proc libUnit(name, hash: string; types = "lib"; extra: seq[string] = @[];
             consumes: seq[string] = @[]; cwd = "${project}"): PlanUnit =
  let id = name & "-1.0.0-" & hash
  result = PlanUnit(id: id, package: name, version: "1.0.0",
    crateName: name, cargoOutDir: "debug/deps", cwd: cwd,
    consumes: consumes, closure: consumes)
  result.argv = @["${nix}/bin/rustc", "--crate-name", name, "--crate-type",
    types, "--emit=dep-info,metadata,link", "-C",
    "extra-filename=-" & hash, "--out-dir", "${out}/" & id]
  for c in consumes:
    result.argv.add ["-L", "dependency=${out}/" & c, "--extern",
      c.split('-')[0] & "=${out}/" & c & "/lib" & c.split('-')[0] & "-" &
      c.split('-')[^1] & ".rmeta"]
  result.argv.add extra
  result.env = @[("CARGO_PKG_NAME", name), ("CARGO_PKG_VERSION", "1.0.0")]
  let stem = name & "-" & hash
  result.outputs = @["${out}/" & id & "/" & stem & ".d"]
  if types == "bin":
    result.outputs.add "${out}/" & id & "/" & stem
  else:
    result.outputs.add ["${out}/" & id & "/lib" & stem & ".rlib",
      "${out}/" & id & "/lib" & stem & ".rmeta"]

proc config(work: string): PlanUnitsConfig =
  PlanUnitsConfig(projectRoot: work / "ws", storeRoot: work / "store",
    outRoot: work / "out", toolchainEnv: @["PATH=/toolchain/bin"])

proc refusedIds(plan: CargoPlan; cfg: PlanUnitsConfig): seq[string] =
  try:
    discard planUnitEdges(plan, cfg)
  except PlanUnitsRefusal as err:
    checkpoint err.msg
    return err.refused.mapIt(it[0])
  checkpoint "the plan was not refused"
  check false

suite "the edges of a plan's units":
  test "a library and the binary that links it":
    if not dirExists("/nix/store"):
      skip("no Nix store on this host: the plans name rustc under ${nix}")
    else:
      let work = createTempDir("plan-units-", "")
      defer: removeDir(work)
      let a = libUnit("a", "0000000000000001")
      var b = libUnit("b", "0000000000000002", types = "bin",
        consumes = @[a.id])
      b.argv.add ["-C", "incremental=${out}/" & b.id & "/incremental"]
      b.cargoIncrementalDir = "debug/incremental"
      b.env.add ("CARGO", "${nix}/bin/cargo")
      let plan = CargoPlan(units: @[a, b])
      let edges = planUnitEdges(plan, config(work))
      check edges.len == 2
      let eb = edges[1]
      check eb.action.id == "cargo.rustc/b@1.0.0-0000000000000002"
      check eb.action.deps == @["cargo.rustc/a@1.0.0-0000000000000001"]
      check eb.action.argv == eb.cargoArgv
      check eb.argvDifference.len == 0
      check eb.cargoArgv[0] == "/nix/store/bin/rustc"
      check ("dependency=" & work / "out" / a.id) in eb.cargoArgv
      check eb.action.cwd == work / "ws"
      check eb.action.isolateHostEnvironment
      check "CARGO=/nix/store/bin/cargo" in eb.action.env
      check "PATH=/toolchain/bin" in eb.action.env
      # A binary links the rlib; the dep-info file is not an output.
      check (work / "out" / a.id / "liba-0000000000000001.rlib") in
        eb.action.inputs
      check eb.action.outputs == @[work / "out" / b.id / "b-0000000000000002"]
      check eb.depInfo == work / "out" / b.id / "b-0000000000000002.d"
      check eb.action.scratchDirs == @[work / "out" / b.id / "incremental"]
      check edges[0].action.scratchDirs.len == 0
      check dirExists(work / "out" / a.id)

  test "a toolchain variable the unit sets is the unit's":
    if not dirExists("/nix/store"):
      skip("no Nix store on this host: the plans name rustc under ${nix}")
    else:
      let work = createTempDir("plan-units-", "")
      defer: removeDir(work)
      var a = libUnit("a", "0000000000000001")
      a.env.add ("PATH", "/cargo/set/this")
      let edges = planUnitEdges(CargoPlan(units: @[a]), config(work))
      check "PATH=/cargo/set/this" in edges[0].action.env
      check "PATH=/toolchain/bin" notin edges[0].action.env

  test "the plan is refused as a whole, naming every unit not built here":
    let work = createTempDir("plan-units-", "")
    defer: removeDir(work)
    let ok = libUnit("ok", "0000000000000001")
    let tst = libUnit("t", "0000000000000002", types = "bin",
      extra = @["--test"])
    let pm = libUnit("pm", "0000000000000003", types = "proc-macro")
    let cdy = libUnit("c", "0000000000000004", types = "cdylib")
    var fed = libUnit("f", "0000000000000005")
    let run = PlanRun(id: "f-1.0.0-00000000000000aa", package: "f",
      version: "1.0.0", compileUnit: ok.id, argv: @["${out}/x"],
      cwd: "${project}", outDir: "${out}/f-1.0.0-00000000000000aa/out")
    fed.outDirRun = run.id
    let reg = libUnit("r", "0000000000000006",
      cwd = "${store}/prefixes/r/1.0.0-x")
    let plan = CargoPlan(units: @[cdy, fed, ok, pm, reg, tst], runs: @[run])
    check refusedIds(plan, config(work)) == @[cdy.id, fed.id,
      run.id, pm.id, reg.id, tst.id]
    check not dirExists(work / "out")

  test "a plan naming a root this host lacks is an error, not a refusal":
    let work = createTempDir("plan-units-", "")
    defer: removeDir(work)
    var a = libUnit("a", "0000000000000001")
    a.argv[0] = "${elsewhere}/rustc"
    expect CargoPlanError:
      discard planUnitEdges(CargoPlan(units: @[a]), config(work))
    var cfg = config(work)
    cfg.outRoot = "relative"
    expect ValueError:
      discard planUnitEdges(CargoPlan(units: @[a]), cfg)

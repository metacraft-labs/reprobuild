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
## incremental directory a scratch directory fails the first case; keeping
## the cargo wrapper's variables (the unit's `PATH` winning) fails the
## second; dropping the clash and removed-variable checks fails the third;
## dropping the split-debuginfo or prefer-dynamic refusal fails the fourth;
## creating a member's directory while checking (before the registry
## crate's refusal) fails the fifth; letting a test target through fails
## the sixth.

import std/[os, sequtils, strutils, tempfiles, unittest]

import repro_build_engine
import repro_cargo_edge/[cargo_plan, plan_units]
import repro_cargo_fetch/crate_rows

proc libUnit(name, hash: string; types = "lib"; extra: seq[string] = @[];
             consumes: seq[string] = @[]; cwd = "${project}"): PlanUnit =
  let id = name & "-1.0.0-" & hash
  result = PlanUnit(id: id, package: name, version: "1.0.0",
    crateName: name, cargoOutDir: "debug/deps", cwd: cwd,
    consumes: consumes, closure: consumes)
  result.argv = @["${project}/rustc", "--crate-name", name, "--crate-type",
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
    let work = createTempDir("plan-units-", "")
    defer: removeDir(work)
    let a = libUnit("a", "0000000000000001")
    var b = libUnit("b", "0000000000000002", types = "bin",
      consumes = @[a.id])
    b.argv.add ["-C", "incremental=${out}/" & b.id & "/incremental"]
    b.cargoIncrementalDir = "debug/incremental"
    b.env.add ("CARGO", "${project}/cargo")
    let plan = CargoPlan(units: @[a, b])
    let edges = planUnitEdges(plan, config(work))
    check edges.len == 2
    let eb = edges[1]
    check eb.action.id == "cargo.rustc/b@1.0.0-0000000000000002"
    check eb.action.deps == @["cargo.rustc/a@1.0.0-0000000000000001"]
    check eb.action.argv == eb.cargoArgv
    check eb.argvDifference.len == 0
    check eb.cargoArgv[0] == work / "ws" / "rustc"
    check ("dependency=" & work / "out" / a.id) in eb.cargoArgv
    check eb.action.cwd == work / "ws"
    check eb.action.isolateHostEnvironment
    check ("CARGO=" & work / "ws" / "cargo") in eb.action.env
    check "PATH=/toolchain/bin" in eb.action.env
    # A binary links the rlib; the dep-info file is not an output.
    check (work / "out" / a.id / "liba-0000000000000001.rlib") in
      eb.action.inputs
    check eb.action.outputs == @[work / "out" / b.id / "b-0000000000000002"]
    check eb.depInfo == work / "out" / b.id / "b-0000000000000002.d"
    check eb.action.scratchDirs == @[work / "out" / b.id / "incremental"]
    check edges[0].action.scratchDirs.len == 0
    check dirExists(work / "out" / a.id)

  test "the cargo wrapper's variables are not given; the toolchain's PATH " &
      "is the only PATH, and the key does not move with the dev shell":
    let work = createTempDir("plan-units-", "")
    defer: removeDir(work)
    proc withShell(path: string): PlanUnit =
      result = libUnit("a", "0000000000000001")
      result.env.add [("OLDPWD", "/old"), ("PATH", path), ("PWD", "/here"),
        ("SHLVL", "2"), ("_", "/wrapper/cargo")]
    let one = planUnitEdges(CargoPlan(units: @[withShell("/dev/shell/1")]),
      config(work))[0]
    for name in CargoWrapperVariables:
      check one.env.allIt(not it.startsWith(name & "="))
    check one.action.env.filterIt(it.startsWith("PATH=")) ==
      @["PATH=/toolchain/bin"]
    for name in ["OLDPWD", "PWD", "SHLVL", "_"]:
      check one.action.env.allIt(not it.startsWith(name & "="))
    let two = planUnitEdges(CargoPlan(units: @[withShell("/dev/shell/2")]),
      config(work))[0]
    check two.action.weakFingerprint == one.action.weakFingerprint
    # The toolchain's variables are in the key.
    var other = config(work)
    other.toolchainEnv = @["PATH=/another/toolchain"]
    let three = planUnitEdges(CargoPlan(units: @[withShell("/dev/shell/1")]),
      other)[0]
    check three.action.weakFingerprint != one.action.weakFingerprint

  test "a toolchain variable cargo set or removed for a unit is refused":
    let work = createTempDir("plan-units-", "")
    defer: removeDir(work)
    var a = libUnit("a", "0000000000000001")
    a.env.add ("CARGO", "/cargo/set/this")
    var b = libUnit("b", "0000000000000002")
    b.envRemoved = @["FOO"]
    let c = libUnit("c", "0000000000000003")
    var cfg = config(work)
    cfg.toolchainEnv.add ["CARGO=/toolchain/cargo", "FOO=1"]
    check refusedIds(CargoPlan(units: @[a, b, c]), cfg) == @[a.id, b.id]
    check not dirExists(work / "out")

  test "split debug information and prefer-dynamic are refused":
    let work = createTempDir("plan-units-", "")
    defer: removeDir(work)
    let packed = libUnit("p", "0000000000000001",
      extra = @["-C", "split-debuginfo=packed"])
    let unpacked = libUnit("u", "0000000000000002",
      extra = @["-C", "split-debuginfo=unpacked"])
    let apple = libUnit("m", "0000000000000003",
      extra = @["-C", "debuginfo=2", "--target", "aarch64-apple-darwin"])
    let msvc = libUnit("w", "0000000000000004",
      extra = @["-C", "debuginfo=2", "--target", "x86_64-pc-windows-msvc"])
    let linux = libUnit("l", "0000000000000005",
      extra = @["-C", "debuginfo=2", "--target", "x86_64-unknown-linux-gnu"])
    let appleOff = libUnit("o", "0000000000000006",
      extra = @["-C", "debuginfo=2", "--target", "aarch64-apple-darwin",
        "-C", "split-debuginfo=off"])
    let appleNoDebug = libUnit("n", "0000000000000007",
      extra = @["--target", "aarch64-apple-darwin"])
    let dyn = libUnit("d", "0000000000000008",
      extra = @["-C", "prefer-dynamic"])
    let dynNo = libUnit("e", "0000000000000009",
      extra = @["-C", "prefer-dynamic=no"])
    let plan = CargoPlan(units: @[dyn, dynNo, linux, apple, appleNoDebug,
      appleOff, packed, unpacked, msvc])
    check refusedIds(plan, config(work)) == @[dyn.id, apple.id, packed.id,
      unpacked.id, msvc.id]
    check not dirExists(work / "out")

  test "a registry crate refused after the static checks creates nothing":
    let work = createTempDir("plan-units-", "")
    defer: removeDir(work)
    let ok = libUnit("ok", "0000000000000001")
    let reg = libUnit("r", "0000000000000002",
      cwd = "${store}/prefixes/r/1.0.0-x")
    var cfg = config(work)
    # A lock row, but the store holds no prefix for it: refused by the
    # registry crate's own checks, after every unit passed the plan's.
    cfg.registryCrates = @[CrateRow(name: "r", version: "1.0.0",
      cksum: repeat('0', 64))]
    var why = ""
    try:
      discard planUnitEdges(CargoPlan(units: @[ok, reg]), cfg)
    except PlanUnitsRefusal as err:
      check err.refused.mapIt(it[0]) == @[reg.id]
      why = err.msg
    checkpoint why
    check "is not in the store" in why
    check not dirExists(work / "out")

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

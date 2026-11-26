## The cargo plan's pure parts and the record run's start-up checks: the
## binary record round-trips and refuses what is not a plan; the derivation
## places what cargo wrote and refuses what it cannot place; the record run
## refuses a record directory that is not empty and an environment that would
## make cargo compile for real.
##
## The record run itself, through the engine, and the plan against a real
## cargo build are the integration cases
## `tests/integration/t_rqe_cg5_record_run_compiles_nothing` and
## `tests/integration/t_rqe_cg5_plan_completes_to_cargos_argv`.
##
## No mocks. The recordings below are written by hand in the shape the record
## mode writes them (`RecordedInvocation`), because what is tested is the
## derivation's handling of a path it cannot place, which a real cargo run
## does not produce on demand. The start-up checks run the real
## `runCargoPlan` in a temporary directory and stop before it starts cargo.

import std/[os, strutils, tempfiles, unittest]

import repro_core/codec
import repro_cargo_edge/[cargo_plan, plan_run, record_mode]

proc unitRec(extraArgs: seq[string] = @[];
             env: seq[(string, string)] = @[]): RecordedInvocation =
  RecordedInvocation(kind: rkUnit,
    argv: @["rustc", "--crate-name", "a", "--crate-type", "lib",
      "--emit=dep-info,metadata,link", "-C", "extra-filename=-0123abcd",
      "--out-dir", "${target}/debug/deps"] & extraArgs,
    cwd: "${project}",
    env: @[("CARGO_PKG_NAME", "a"), ("CARGO_PKG_VERSION", "1.0.0")] & env,
    placeholders: @["${target}/debug/deps/liba-0123abcd.rlib",
      "${target}/debug/deps/liba-0123abcd.rmeta"])

proc samplePlan(): CargoPlan =
  result.units.add PlanUnit(id: "a-1.0.0-0123abcd", package: "a",
    version: "1.0.0", crateName: "a", cargoOutDir: "debug/deps",
    cargoIncrementalDir: "debug/incremental",
    argv: @["rustc", "--crate-name", "a", "${slot:rustc-cfg:b-1.0.0-ff}"],
    cwd: "${project}", env: @[("CARGO_PKG_NAME", "a"), ("OUT_DIR", "x")],
    envRemoved: @["GONE"],
    envSlots: @[PlanSlot(kind: "rustc-env", run: "b-1.0.0-ff")],
    outputs: @["${out}/a-1.0.0-0123abcd/liba-0123abcd.rlib"],
    consumes: @["c-1"], closure: @["c-1", "d-1"], fedBy: @["b-1.0.0-ff"],
    outDirRun: "b-1.0.0-ff")
  result.units.add PlanUnit(id: "b-1.0.0-ee", package: "b", version: "1.0.0",
    crateName: "build_script_build", buildScriptCompile: true,
    executable: "${out}/b-1.0.0-ee/build_script_build-ee")
  result.runs.add PlanRun(id: "b-1.0.0-ff", package: "b", version: "1.0.0",
    compileUnit: "b-1.0.0-ee", argv: @["${out}/b-1.0.0-ee/build_script_build-ee"],
    cwd: "${project}/b", env: @[("NUM_JOBS", "1")], outDir: "${out}/b-1.0.0-ff/out",
    cargoOutDir: "debug/build/b-ff/out", manifest: "${project}/b/Cargo.toml",
    manifestFrom: "CARGO_MANIFEST_PATH", provider: "${project}/b",
    providers: @[PlanProvider(links: "C", provider: "c@1.0.0")])

suite "the plan's binary record":

  test "a plan round-trips through its record":
    let plan = samplePlan()
    check decodeCargoPlan(encodeCargoPlan(plan)) == plan

  test "a record that is not a plan is refused":
    let good = encodeCargoPlan(samplePlan())
    var wrongMagic: seq[byte]
    wrongMagic.writeString("reprobuild.somethingElse.v1")
    wrongMagic.add good[4 + CargoPlanMagic.len .. ^1]
    expect CargoPlanError: discard decodeCargoPlan(wrongMagic)
    var wrongVersion = good
    wrongVersion[4 + CargoPlanMagic.len] = 99
    expect CargoPlanError: discard decodeCargoPlan(wrongVersion)
    expect CargoPlanError: discard decodeCargoPlan(good[0 ..< good.len - 1])
    expect CargoPlanError: discard decodeCargoPlan(good & @[0'u8])
    expect CargoPlanError: discard decodeCargoPlan(good[0 ..< 3])

suite "the derivation places what cargo wrote":

  test "a unit's directory and outputs are rewritten under ${out}":
    let plan = derivePlan([unitRec()], [], "/wrapper")
    check plan.units.len == 1
    let u = plan.units[0]
    check u.id == "a-1.0.0-0123abcd"
    check u.cargoOutDir == "debug/deps"
    check "${out}/a-1.0.0-0123abcd" in u.argv
    check u.outputs == @["${out}/a-1.0.0-0123abcd/liba-0123abcd.rlib",
      "${out}/a-1.0.0-0123abcd/liba-0123abcd.rmeta"]
    check not u.isFed

  test "a target-directory path no rule places is refused":
    expect CargoPlanError:
      discard derivePlan([unitRec(@["-L", "native=${target}/elsewhere"])],
        [], "/wrapper")

  test "a scratch path left in the environment is refused":
    expect CargoPlanError:
      discard derivePlan([unitRec(env = @[("X", "${scratch}/home")])], [],
        "/wrapper")

  test "the record run's own variables are not in the difference":
    let plan = derivePlan([unitRec(env = @[
      ("CARGO_MAKEFLAGS", "-j --jobserver-fds=7,8"),
      ("RUSTC_WRAPPER", "/wrapper"), ("KEPT", "1"), ("SAME", "base")])],
      [("SAME", "base"), ("DROPPED_BY_CARGO", "v")], "/wrapper")
    let u = plan.units[0]
    var names: seq[string]
    for (name, _) in u.env: names.add name
    check "KEPT" in names
    check "CARGO_MAKEFLAGS" notin names
    check "RUSTC_WRAPPER" notin names
    check "SAME" notin names
    check u.envRemoved == @["DROPPED_BY_CARGO"]

suite "the record run's start-up checks":

  template keepingHome(body: untyped) =
    # `runCargoPlan` points this process's `HOME` and `CARGO_HOME` at its
    # edge-private directories (it is the edge's whole process); put them
    # back.
    let savedHome = getEnv("HOME")
    let savedCargoHome = getEnv("CARGO_HOME")
    try:
      body
    finally:
      putEnv("HOME", savedHome)
      if savedCargoHome.len > 0: putEnv("CARGO_HOME", savedCargoHome)
      else: delEnv("CARGO_HOME")

  proc options(): PlanRunOptions =
    PlanRunOptions(planFile: "plan.rbsz", scratch: "scratch",
      cargo: "/no/cargo", rustc: "/no/rustc")

  test "a record directory that is not empty is refused":
    let dir = createTempDir("cg5-plan-run-", "")
    defer: removeDir(dir)
    let saved = getCurrentDir()
    setCurrentDir(dir)
    defer: setCurrentDir(saved)
    # Control: with an empty scratch directory the run gets past the
    # checks and fails only where it starts cargo, which does not exist.
    var reached = ""
    keepingHome:
      try: discard runCargoPlan(options())
      except CatchableError as err: reached = err.msg
    checkpoint reached
    check "cargo metadata" in reached or "cannot start" in reached
    writeFile(dir / "scratch" / RecordSubdir / "left-over.json", "{}")
    var refused = ""
    keepingHome:
      try: discard runCargoPlan(options())
      except PlanRunError as err: refused = err.msg
    checkpoint refused
    check "not empty" in refused and RecordSubdir in refused

  test "an environment variable that outranks the record wrapper is " &
      "refused":
    let dir = createTempDir("cg5-plan-run-env-", "")
    defer: removeDir(dir)
    let saved = getCurrentDir()
    setCurrentDir(dir)
    defer: setCurrentDir(saved)
    putEnv("RUSTC_WRAPPER", "/some/other/wrapper")
    defer: delEnv("RUSTC_WRAPPER")
    var refused = ""
    keepingHome:
      try: discard runCargoPlan(options())
      except PlanRunError as err: refused = err.msg
    checkpoint refused
    check "RUSTC_WRAPPER" in refused

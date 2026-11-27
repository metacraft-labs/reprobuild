## The cargo shim (`repro-cargo-shim`, installed as `cargo`) records a live set
## from the cargo invocations that compile, and only from the ones that
## succeed.
##
## NO MOCKS: real cargo and rustc build small fixture crates (three libraries,
## a build script and a binary), the shim is the real binary, and the
## expectations are measured on real output. `t_rqe_cg2_shim_is_transparent`
## holds the byte-for-byte comparison with bare cargo; the cases here check
## what is RECORDED, and compare the human output once more where a case asks
## for it.
##
## Falsifying mutations, each applied once to `libs/repro_cargo_gc/src/
## repro_cargo_gc/shim.nim`, the case observed to fail, and reverted (the
## observed failure text is in the commit message):
##   records_live_set         drop the injected `--message-format`; and send
##                            plain `json` instead of `json-render-diagnostics`
##   failed_build             record before checking the exit status
##   tees_caller_format       consume the stream in the shim (forward nothing)
##   gc_after_shim            (the janitor's) delete the `.fingerprint` of live
##                            units, as the existing next-build-is-fresh case

import std/[json, os, sequtils, strutils, unittest]

import repro_test_support
import repro_cargo_gc
import rqe_cg2_shim_fixture

const Quiet = ["--color", "never", "--offline", "--jobs", "1"]

proc arguments(verb: string; more: varargs[string]): seq[string] =
  @[verb] & @Quiet & @more

proc freshFlags(stdout: string): seq[bool] =
  for line in stdout.splitLines:
    if line.startsWith("{"):
      let node = parseJson(line)
      if node{"reason"}.getStr == "compiler-artifact":
        result.add node{"fresh"}.getBool

suite "the cargo shim records a live set":

  test "test_rqe_cg2_shim_records_live_set":
    ## a build and a test through the shim each leave one live set equal to the
    ## oracle, and the human output equals bare cargo's
    let rig = newShimRig("records")
    defer: rig.cleanup()
    # Bare cargo first, in an empty target directory: the output to match.
    rig.freshTarget()
    let bareBuild = rig.runCargo(false, arguments("build"))
    require bareBuild.code == 0
    rig.freshTarget()
    let build = rig.runCargo(true, arguments("build"))
    check build.code == 0
    check normalizeTimings(build.stderr) == normalizeTimings(bareBuild.stderr)
    check build.stdout == bareBuild.stdout
    check build.stderr.contains("Compiling")
    let afterBuild = liveSetFiles(rig.target)
    require afterBuild.len == 1
    # In a target directory that only ran this build, every fingerprinted
    # unit is live: the oracle needs neither the recorder nor the stream.
    let oracleBuild = fingerprintUnits(rig.target)
    check oracleBuild.len >= 6 # four crates, the build script and its run
    check recordedUnits(afterBuild[0]) == oracleBuild

    # `cargo test` compiles the test profile's units and not the plain
    # binary, so its oracle is a target directory that ran ONLY the test
    # (bare cargo), and its live set is that of the invocation alone.
    # `--test-threads=1`: libtest otherwise prints its results in the order
    # its threads finish, which differs from run to run of bare cargo.
    let testArgs = arguments("test", "--", "--test-threads=1")
    rig.freshTarget()
    let bareTest = rig.runCargo(false, testArgs)
    require bareTest.code == 0
    let oracleTest = fingerprintUnits(rig.target)
    rig.freshTarget()
    let testRun = rig.runCargo(true, testArgs)
    check testRun.code == 0
    check normalizeTimings(testRun.stdout) == normalizeTimings(bareTest.stdout)
    check normalizeTimings(testRun.stderr) == normalizeTimings(bareTest.stderr)
    check testRun.stdout.contains("test result: ok")
    let testSets = liveSetFiles(rig.target)
    require testSets.len == 1
    check recordedUnits(testSets[0]) == oracleTest
    check oracleTest != oracleBuild # the two invocations are not the same set
    # Both in one target directory: one live set per invocation.
    check rig.runCargo(true, arguments("build")).code == 0
    check liveSetFiles(rig.target).len == 2
    check leftoverStreams(rig.target).len == 0

  test "test_rqe_cg2_shim_failed_build_records_nothing":
    ## a failing build exits with cargo's status, prints its diagnostics and
    ## stores no set
    let rig = newShimRig("failed", FailSource)
    defer: rig.cleanup()
    let bare = rig.runCargo(false, arguments("build"))
    require bare.code != 0
    rig.freshTarget()
    let build = rig.runCargo(true, arguments("build"))
    check build.code == bare.code
    check build.code == 101
    check build.stdout == bare.stdout
    check normalizeTimings(build.stderr) == normalizeTimings(bare.stderr)
    check build.stderr.contains("error[E0308]")
    check liveSetFiles(rig.target).len == 0
    check leftoverStreams(rig.target).len == 0
    # The same project, repaired, records: the absence above is the shim's
    # decision about the failure, not a project that could never record.
    writeFile(rig.project / "src" / "main.rs", WarnSource)
    check rig.runCargo(true, arguments("build")).code == 0
    check liveSetFiles(rig.target).len == 1

  test "test_rqe_cg2_shim_tees_a_caller_supplied_message_format":
    ## with --message-format=json the caller receives the identical stream and
    ## the live set is recorded
    let rig = newShimRig("tee")
    defer: rig.cleanup()
    let format = "--message-format=json"
    let bare = rig.runCargo(false, arguments("build", format))
    require bare.code == 0
    require bare.stdout.contains("\"reason\":\"compiler-artifact\"")
    rig.freshTarget()
    let build = rig.runCargo(true, arguments("build", format))
    check build.code == 0
    # Byte for byte, with `--jobs 1` fixing the order cargo reports in.
    check build.stdout == bare.stdout
    check normalizeTimings(build.stderr) == normalizeTimings(bare.stderr)
    let sets = liveSetFiles(rig.target)
    require sets.len == 1
    check recordedUnits(sets[0]) == fingerprintUnits(rig.target)
    # The shim did not add an option of its own to the caller's argv: a
    # second form of the same request, `--message-format json`, behaves alike.
    rig.freshTarget()
    let spaced = rig.runCargo(true, arguments("build", "--message-format",
      "json-render-diagnostics"))
    let bareSpaced = rig.runCargo(false, arguments("build", "--message-format",
      "json-render-diagnostics"))
    check spaced.code == 0 and bareSpaced.code == 0
    check liveSetFiles(rig.target).len == 1

  test "test_rqe_cg2_gc_after_shim_keeps_the_next_build_fresh":
    ## with every build run through the shim, gc deletes the old units and the
    ## next build reports every live unit fresh
    ## The existing `test_rqe_cg2_next_build_is_fresh` flow, driven by the shim
    ## instead of by recordLiveSet. K = 2 reaches the shim through
    ## `REPRO_CARGO_GC_KEEP_SETS`, the resolver the CLI uses.
    ## Falsifying mutation (the janitor's): also delete the `.fingerprint` of
    ## live units; cargo then rebuilds them and the `fresh` assertions fail.
    let rig = newShimRig("fresh")
    defer: rig.cleanup()
    let keep = [("REPRO_CARGO_GC_KEEP_SETS", "2")]
    proc configure(version: int) =
      # A new version of one library: new unit hashes for it and its dependents.
      let manifest = rig.project / "chain_a" / "Cargo.toml"
      writeFile(manifest,
        "[package]\nname = \"chain_a\"\nversion = \"0.1." & $version &
        "\"\nedition = \"2021\"\n[features]\nextra = []\n" &
        "[dependencies]\nchain_b = { path = \"../chain_b\" }\n")
    for i in 0 ..< 4:
      configure(i)
      let features = if i mod 2 == 1: @["--features", "chain_a/extra"] else: @[]
      let release = if i == 2: @["--release"] else: @[]
      let res = rig.runCargo(true, arguments("build", features & release), keep)
      require res.code == 0
    check liveSetFiles(rig.target).len == 3 # round 0 is in no profile's last 2
    let report = collectGarbage(rig.target,
      GcConfig(keepSets: 2, minAgeSeconds: 0, dryRun: false))
    check report.errors.len == 0
    check report.unitsDeleted > 0
    # The last two configurations: round 2 (release) and round 3 (extra, dev).
    configure(2)
    let r2 = rig.runCargo(true, arguments("build", "--release",
      "--message-format=json"), keep)
    check r2.code == 0
    check freshFlags(r2.stdout).len >= 3
    check freshFlags(r2.stdout).allIt(it)
    configure(3)
    let r3 = rig.runCargo(true, arguments("build", "--features", "chain_a/extra",
      "--message-format=json"), keep)
    check r3.code == 0
    check freshFlags(r3.stdout).len >= 3
    check freshFlags(r3.stdout).allIt(it)
    check r3.stdout.contains("build-script-executed")

## The cargo shim is invisible: the same standard output, standard error and
## exit status as bare cargo, and it leaves alone every invocation whose
## standard output must stay a terminal or that is not a compile.
## The first two properties are what the byte-identity cases check; the third,
## `test_rqe_cg2_shim_leaves_run_and_foreign_verbs_alone`, is the shim standing
## aside where it must not interpose.
##
## METHOD. Every comparison runs the SAME argv, in the same project directory
## and the same target directory PATH, twice: through bare cargo and through
## the shim. Each run starts from an empty target directory (it is removed
## between the two), so both builds are cold and every path cargo prints is
## the same. `--jobs 1` fixes the order of cargo's progress lines and of the
## JSON messages, so no ordering has to be normalised. The only text rewritten
## is the elapsed time cargo and libtest print (`Finished ... in 0.48s`,
## `test result: ... finished in 0.00s`): `normalizeTimings`. Standard output
## and standard error are captured separately, so the comparison covers each
## stream and the exit status, not their interleaving (which two pipes cannot
## define).
##
## NO MOCKS: real cargo, real rustc, the real shim binary; the terminal cases
## use a real pseudo-terminal (python's `pty`).
##
## Falsifying mutation of `test_rqe_cg2_shim_leaves_run_and_foreign_verbs_alone`
## (applied once to shim.nim, observed to fail, reverted): add `run` to the
## compiling verbs. The program's standard output is then a pipe and the pty
## case reads `tty=false`.

import std/[os, strutils, unittest]

import repro_test_support
import rqe_cg2_shim_fixture

const Quiet = ["--color", "never", "--offline", "--jobs", "1"]

proc arguments(verb: string; more: varargs[string]): seq[string] =
  @[verb] & @Quiet & @more

proc identical(rig: ShimRig; args: seq[string]; label: string;
               expectCode = 0): tuple[stdout, stderr: string] =
  ## Bare cargo, then the shim, each from an empty target directory.
  rig.freshTarget()
  let bare = rig.runCargo(false, args)
  rig.freshTarget()
  let shimmed = rig.runCargo(true, args)
  checkpoint label & " bare stderr:\n" & bare.stderr & "\nshim stderr:\n" &
    shimmed.stderr
  check bare.code == expectCode
  check shimmed.code == bare.code
  check normalizeTimings(shimmed.stdout) == normalizeTimings(bare.stdout)
  check normalizeTimings(shimmed.stderr) == normalizeTimings(bare.stderr)
  (bare.stdout, bare.stderr)

suite "the cargo shim changes nothing the caller can see":

  test "test_rqe_cg2_shim_is_byte_identical":
    ## build, check, doc, test, --nocapture, a failing build, warnings, and a
    ## caller's own --message-format give bare cargo's stdout, stderr and exit
    ## status
    let rig = newShimRig("identical")
    defer: rig.cleanup()
    let built = rig.identical(arguments("build"), "build")
    check built.stderr.contains("Compiling")
    discard rig.identical(arguments("check"), "check")
    discard rig.identical(arguments("doc", "--no-deps"), "doc")
    discard rig.identical(arguments("test", "--", "--test-threads=1"), "test")
    # `-- --nocapture`: the test binary writes to both streams, and what
    # follows `--` belongs to it, not to the shim.
    let nocapture = rig.identical(arguments("test", "--", "--nocapture",
      "--test-threads=1"), "test --nocapture")
    check nocapture.stdout.contains("stdout from the test")
    check nocapture.stderr.contains("stderr from the test")
    # The caller's own JSON format, in each spelling: forwarded unchanged.
    let json = rig.identical(arguments("build", "--message-format=json"),
      "build --message-format=json")
    check json.stdout.contains("\"reason\":\"compiler-artifact\"")
    discard rig.identical(arguments("build", "--message-format",
      "json-diagnostic-short"), "build --message-format json-diagnostic-short")
    # A non-JSON format is the caller's: nothing is injected.
    discard rig.identical(arguments("build", "--message-format=short"),
      "build --message-format=short")
    # Global options before the verb, and a `+toolchain` that is not one.
    discard rig.identical(@["--color", "never", "-q", "build", "--offline",
      "--jobs", "1"], "global options before the verb")
    # Verbs the shim leaves alone are the real cargo's own output.
    discard rig.identical(@["--version"], "--version")
    discard rig.identical(@["build", "--help"], "build --help")
    discard rig.identical(@["no-such-verb"], "unknown verb", expectCode = 101)

  test "test_rqe_cg2_shim_is_byte_identical_with_warnings":
    ## a build that warns, built twice (the second replays cargo's cached
    ## warnings)
    let rig = newShimRig("warn", WarnSource)
    defer: rig.cleanup()
    rig.freshTarget()
    let bare1 = rig.runCargo(false, arguments("build"))
    let bare2 = rig.runCargo(false, arguments("build"))
    rig.freshTarget()
    let shim1 = rig.runCargo(true, arguments("build"))
    let shim2 = rig.runCargo(true, arguments("build"))
    require bare1.stderr.contains("warning: unused variable")
    require bare2.stderr.contains("warning: unused variable") # replayed
    for (a, b) in [(bare1, shim1), (bare2, shim2)]:
      check b.code == a.code
      check b.stdout == a.stdout
      check normalizeTimings(b.stderr) == normalizeTimings(a.stderr)

  test "test_rqe_cg2_shim_is_byte_identical_failing_build":
    ## the diagnostics and status of a build that does not compile
    let rig = newShimRig("failing", FailSource)
    defer: rig.cleanup()
    let failed = rig.identical(arguments("build"), "failing build",
      expectCode = 101)
    check failed.stderr.contains("error[E0308]")
    discard rig.identical(arguments("check"), "failing check", expectCode = 101)
    discard rig.identical(arguments("test"), "failing test", expectCode = 101)

  test "test_rqe_cg2_shim_leaves_run_and_foreign_verbs_alone":
    ## cargo run keeps a terminal on standard output (under a pty), cargo test on
    ## a terminal is passed through, and run, fetch, metadata, install and
    ## REPRO_CARGO_RECORD=0 record nothing
    let rig = newShimRig("alone")
    defer: rig.cleanup()
    # `cargo run` under a pseudo-terminal: the program must find a terminal.
    let run = rig.runUnderPty(rig.shim,
      arguments("run") & @["--quiet"])
    check run.code == 0
    check run.output.contains("tty=true")
    # `cargo test` on a terminal: a test binary keeps its terminal, so the
    # shim stands aside and records nothing.
    let testRun = rig.runUnderPty(rig.shim,
      arguments("test", "--", "--nocapture", "--test-threads=1"))
    check testRun.code == 0
    check testRun.output.contains("test-tty=true")
    check liveSetFiles(rig.target).len == 0
    # Foreign verbs, and the switch.
    check rig.runCargo(true, @["fetch", "--offline"]).code == 0
    let meta = rig.runCargo(true, @["metadata", "--offline",
      "--format-version", "1", "--no-deps"])
    check meta.code == 0
    check meta.stdout.startsWith("{\"packages\"")
    let installRoot = rig.root / "install-root"
    let install = rig.runCargo(true, @["install", "--offline", "--path", ".",
      "--root", installRoot, "--target-dir", rig.root / "install-target",
      "--jobs", "1", "--color", "never"])
    check install.code == 0
    check fileExists(installRoot / "bin" / "cg2_app")
    rig.freshTarget() # the earlier run and test built these units already
    let disabled = rig.runCargo(true, arguments("build"),
      [("REPRO_CARGO_RECORD", "0")])
    check disabled.code == 0
    check disabled.stderr.contains("Compiling")
    check liveSetFiles(rig.target).len == 0
    check liveSetFiles(rig.root / "install-target").len == 0
    # The control: the same shim, switch off again, records the same build.
    check rig.runCargo(true, arguments("check")).code == 0
    check liveSetFiles(rig.target).len == 1

  test "test_rqe_cg2_shim_finds_the_next_cargo_on_path":
    ## with no REPRO_CARGO_REAL the shim skips itself and its own directory
    let rig = newShimRig("path")
    defer: rig.cleanup()
    let path = rig.shimDir & ":" & rig.realCargo.parentDir & ":" &
      getEnv("PATH")
    let res = runShellSplit(shellCommand(@[rig.shim] & arguments("check"),
      [("PATH", path), ("CARGO_HOME", rig.cargoHome),
       ("CARGO_TARGET_DIR", rig.target)]), rig.project, timeoutMs = 1_500_000)
    checkpoint res.stderr
    check res.code == 0
    check res.stderr.contains("Finished")
    check liveSetFiles(rig.target).len == 1 # it was the shim that ran
    # Nested: a cargo started by cargo's own children passes straight through
    # (the guard variable), so it neither recurses nor records.
    let nested = runShellSplit(shellCommand(@[rig.shim] & arguments("build"),
      [("PATH", path), ("CARGO_HOME", rig.cargoHome),
       ("CARGO_TARGET_DIR", rig.target), ("REPRO_CARGO_SHIM_ACTIVE", "1")]),
      rig.project, timeoutMs = 1_500_000)
    check nested.code == 0
    check liveSetFiles(rig.target).len == 1

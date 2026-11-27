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
## Falsifying mutations (each applied once to shim.nim, observed to fail,
## reverted; the observed failure text is in the commit message):
##   leaves_run_and_foreign_verbs_alone  add `run` to the compiling verbs: the
##                                       program's standard output is then a
##                                       pipe and the pty case reads `tty=false`
##   byte_identical                      inject plain `json` instead of
##                                       `json-render-diagnostics`: the
##                                       diagnostics leave standard error
##   byte_identical (--no-run)           drop the `--no-run` rule: the
##                                       `Executable ...` lines are missing
##   forwards_a_signal                   forwardSignal does nothing: the shim
##                                       outlives the SIGTERM sent to it
##   one_file_for_both_streams           stop recognising `2>&1`: a test run
##                                       into one file is recorded, not passed
##                                       through

import std/[os, osproc, strutils, unittest]
from std/posix import Pid, SIGKILL, kill

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
    # `--no-run` makes cargo name the test executables on standard error, which
    # it does not do in a JSON message format: the shim leaves that to cargo.
    let noRun = rig.identical(arguments("test", "--no-run"), "test --no-run")
    check noRun.stderr.contains("Executable")
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

  test "test_rqe_cg2_shim_ignores_a_cargo_wrapper_in_front_of_it":
    ## a repository's own wrapper (agent-harbor's dev-bin/cargo) sits first on
    ## PATH and takes the first `cargo` that is not itself: the shim, when the
    ## shim comes after it. The shim must then take the next one after ITSELF,
    ## not the first on PATH, which is that wrapper again: the two would call
    ## each other until the test's timeout. Wrapper -> shim -> real cargo.
    let rig = newShimRig("wrapper")
    defer: rig.cleanup()
    let wrapperDir = rig.root / "wrapper-bin"
    createDir(wrapperDir)
    let wrapper = wrapperDir / "cargo"
    writeFile(wrapper, "#!/bin/sh\n" &
      "self=$(cd \"$(dirname \"$0\")\" && pwd)\n" &
      "IFS=:\n" &
      "for d in $PATH; do\n" &
      "  [ \"$d\" = \"$self\" ] && continue\n" &
      "  [ -x \"$d/cargo\" ] && exec \"$d/cargo\" \"$@\"\n" &
      "done\n" &
      "exit 127\n")
    setFilePermissions(wrapper, {fpUserRead, fpUserWrite, fpUserExec,
                                 fpGroupRead, fpGroupExec,
                                 fpOthersRead, fpOthersExec})
    let path = wrapperDir & ":" & rig.shimDir & ":" & rig.realCargo.parentDir &
      ":" & getEnv("PATH")
    let res = runShellSplit(shellCommand(@[wrapper] & arguments("check"),
      [("PATH", path), ("CARGO_HOME", rig.cargoHome),
       ("CARGO_TARGET_DIR", rig.target)]), rig.project, timeoutMs = 300_000)
    checkpoint res.stderr
    check res.code == 0
    check res.stderr.contains("Finished")
    check liveSetFiles(rig.target).len == 1 # the shim ran and recorded

  test "test_rqe_cg2_shim_is_byte_identical_on_a_terminal":
    ## with a terminal on both streams (colour on, as a person sees it) a
    ## recorded build or check prints what bare cargo prints
    ## CARGO_TERM_PROGRESS_WHEN=never: the progress bar is redrawn on a timer,
    ## so two bare runs differ from each other; nothing else is normalised
    ## but the elapsed time.
    let rig = newShimRig("terminal")
    defer: rig.cleanup()
    let env = [("CARGO_TERM_PROGRESS_WHEN", "never")]
    for verb in ["build", "check"]:
      let args = @[verb, "--offline", "--jobs", "1"]
      rig.freshTarget()
      let bare = rig.runUnderPty(rig.realCargo, args, env)
      rig.freshTarget()
      let shimmed = rig.runUnderPty(rig.shim, args, env)
      checkpoint verb & " bare:\n" & bare.output & "\nshim:\n" & shimmed.output
      check bare.code == 0
      check shimmed.code == bare.code
      check "\27[" in bare.output # colour was on: the terminal was seen
      check normalizeTimings(shimmed.output) == normalizeTimings(bare.output)
      check liveSetFiles(rig.target).len == 1 # recorded on a terminal too

  test "test_rqe_cg2_shim_test_into_one_file_is_passed_through":
    ## `cargo test ... 2>&1` (one file for both streams) prints what bare cargo
    ## prints, including the order of the two streams, because the shim does not
    ## stand between the test binary and the file
    let rig = newShimRig("merged")
    defer: rig.cleanup()
    # `runShell` gives the child ONE pipe for both streams, as `2>&1` does.
    let testArgs = arguments("test", "--", "--nocapture", "--test-threads=1")
    rig.freshTarget()
    let bare = runShell(shellCommand(@[rig.realCargo] & testArgs, rig.cargoEnv),
      rig.project, timeoutMs = 1_500_000)
    rig.freshTarget()
    let shimmed = runShell(shellCommand(@[rig.shim] & testArgs, rig.cargoEnv),
      rig.project, timeoutMs = 1_500_000)
    check bare.code == 0
    check shimmed.code == 0
    check "stdout from the test" in bare.output
    check "stderr from the test" in bare.output
    check normalizeTimings(shimmed.output) == normalizeTimings(bare.output)
    check liveSetFiles(rig.target).len == 0
    # The control: a build into one file IS recorded (nothing of its own
    # reaches standard output, so there is no order to disturb).
    rig.freshTarget()
    let build = runShell(shellCommand(@[rig.shim] & arguments("build"),
      rig.cargoEnv), rig.project, timeoutMs = 1_500_000)
    check build.code == 0
    check liveSetFiles(rig.target).len == 1

  test "test_rqe_cg2_shim_forwards_a_signal_and_leaves_no_orphan":
    ## SIGTERM sent to the shim ends it with the status bare cargo has under
    ## the same signal (128+15), and the cargo it started is gone
    let rig = newShimRig("signal")
    defer: rig.cleanup()
    let marker = rig.root / "build-script-running"
    # A build script that says who it is and who started it (cargo), then
    # waits for as long as the case needs to signal.
    writeFile(rig.project / "build.rs",
      "fn main() {\n" &
      "    let ppid = std::os::unix::process::parent_id();\n" &
      "    std::fs::write(std::env::var(\"CG2_MARKER\").unwrap(), " &
      "format!(\"{} {}\", ppid, std::process::id())).unwrap();\n" &
      "    std::thread::sleep(std::time::Duration::from_secs(600));\n}\n")
    putEnv("CG2_MARKER", marker)
    defer:
      for name in ["CG2_MARKER", "CARGO_HOME", "CARGO_TARGET_DIR",
                   "REPRO_CARGO_REAL"]:
        delEnv(name)
    proc alive(pid: int): bool = kill(Pid(pid), 0) == 0
    proc signalled(viaShim: bool): tuple[code: int; cargoPid, scriptPid,
                                         shimPid: int; exited: bool] =
      rig.freshTarget()
      removeFile(marker)
      for (n, v) in rig.cargoEnv: putEnv(n, v)
      let p = startProcess(if viaShim: rig.shim else: rig.realCargo,
        workingDir = rig.project, args = arguments("build"), options = {})
      result.shimPid = p.processID
      var waited = 0
      while not fileExists(marker) or readFile(marker).split(' ').len < 2:
        sleep 500
        waited += 500
        if waited > 1_200_000 or not p.running: break
      doAssert fileExists(marker), "the build script never started"
      let ids = readFile(marker).split(' ')
      result.cargoPid = parseInt(ids[0])
      result.scriptPid = parseInt(ids[1])
      p.terminate() # SIGTERM to what the caller started
      for i in 0 ..< 120:
        if not p.running: break
        sleep 500
      result.exited = not p.running
      result.code = if result.exited: p.peekExitCode else: -1
      for i in 0 ..< 40: # the cargo the shim started must be going too
        if not alive(result.cargoPid) or result.cargoPid == result.shimPid: break
        sleep 250
      if not result.exited: discard kill(Pid(result.shimPid), SIGKILL)
      p.close()
    let bare = signalled(false)
    discard kill(Pid(bare.scriptPid), SIGKILL) # the orphaned build script
    let shimmed = signalled(true)
    discard kill(Pid(shimmed.scriptPid), SIGKILL)
    discard kill(Pid(shimmed.cargoPid), SIGKILL) # only matters if the case failed
    check bare.exited
    check bare.code == 128 + 15
    check shimmed.exited
    check shimmed.code == bare.code
    check shimmed.cargoPid != shimmed.shimPid # a cargo of its own was started
    check not alive(shimmed.cargoPid)

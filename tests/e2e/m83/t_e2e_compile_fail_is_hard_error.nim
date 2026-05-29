## M83 Phase F3 gate: profile compilation failure is a HARD ERROR
## across every apply-path entry point.
##
## Phase F3 retired the auto-fallback to the legacy text parser. The
## compile-then-adapt path is now the ONLY apply path; a profile that
## fails `nim c` produces a uniform actionable diagnostic on stderr
## (pointing at `Profile-Migration-Patterns.md`, forwarding the Nim
## error verbatim, and suggesting the matching `plan` subcommand) and
## the process exits non-zero. No legacy-parser fallback runs; no
## generation is recorded.
##
## Drives the public `repro home apply`, `repro home plan`, and
## `repro home apply --plan` CLIs against the `home_compile_fail.nim`
## fixture (deliberately broken Phase A profile) and asserts:
##   * exit code is non-zero;
##   * stderr names the file, includes the verbatim Nim diagnostic,
##     points at the migration recipe, and suggests the plan
##     subcommand;
##   * no generation was committed to the state dir.

when not defined(windows):
  echo "[platform N/A] t_e2e_compile_fail_is_hard_error: " &
    "validated on Windows; the apply-path harness uses Windows " &
    "stow / launcher / state-dir layout"
  quit(0)
else:
  import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

  import repro_home_generations

  const ProjectRoot = currentSourcePath().parentDir().parentDir()
    .parentDir().parentDir()
  const FixtureSrc = currentSourcePath().parentDir().parentDir()
    .parentDir() / "fixtures" / "m83" / "home_compile_fail.nim"

  proc reproBinary(): string =
    let exeName = when defined(windows): "repro.exe" else: "repro"
    let candidate = ProjectRoot / "build" / "bin" / exeName
    doAssert fileExists(candidate),
      "repro binary not found at " & candidate &
      "; build with `nim c --out:build/bin/repro.exe apps/repro/repro.nim`"
    candidate

  proc runRepro(envOverrides: openArray[tuple[k, v: string]];
                args: openArray[string]):
      tuple[exitCode: int; output: string] =
    var processEnv = newStringTable(modeCaseSensitive)
    for k, v in envPairs():
      processEnv[k] = v
    for kv in envOverrides:
      processEnv[kv.k] = kv.v
    let p = startProcess(reproBinary(), args = @args, env = processEnv,
      options = {poUsePath, poStdErrToStdOut})
    let stream = p.outputStream()
    var combined = ""
    while not stream.atEnd():
      let chunk = stream.readAll()
      if chunk.len == 0: break
      combined.add chunk
    let code = p.waitForExit()
    p.close()
    result = (exitCode: code, output: combined)

  proc setup(tempRoot: string): seq[tuple[k, v: string]] =
    let stateDir = tempRoot / "state"
    let storeRoot = tempRoot / "store"
    let homeDir = tempRoot / "home"
    let profileDir = tempRoot / "profile"
    createDir(stateDir)
    createDir(storeRoot)
    createDir(homeDir)
    createDir(profileDir)
    copyFile(FixtureSrc, profileDir / "home.nim")
    result = @[
      (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
      (k: "REPRO_HOME_STATE_DIR", v: stateDir),
      (k: "REPRO_STORE_ROOT", v: storeRoot),
      (k: "HOME", v: homeDir),
      (k: "USERPROFILE", v: homeDir),
      (k: "REPRO_HOST", v: "compile-fail-host"),
      (k: "REPRO_HOME_PACKAGE_CATALOG", v: "neovim,tmux")]

  template assertHardErrorOutput(out0: string) =
    ## Every apply-path entry surfaces the same uniform diagnostic
    ## shape (formatted by `cli_home.formatProfileCompileError`).
    check out0.contains("profile compilation failed for")
    check out0.contains("home.nim")
    # The Nim diagnostic is forwarded verbatim — `nope_undefined_predicate`
    # is the offending identifier in the fixture.
    check out0.contains("nope_undefined_predicate")
    # The hints (migration recipe + plan suggestion) are stable.
    check out0.contains("Profile-Migration-Patterns.md")
    check out0.contains("`repro home plan`")

  suite "M83 Phase F3 gate: profile compile failure is a HARD error":

    test "repro home apply hard-errors on a broken Phase A profile":
      let tempRoot = createTempDir("repro-m83-f3-apply-", "")
      defer:
        try: removeDir(tempRoot) except OSError: discard
      let env = setup(tempRoot)
      let res = runRepro(env, ["home", "apply"])
      check res.exitCode != 0
      assertHardErrorOutput(res.output)
      # No generation was recorded.
      let stateDir = tempRoot / "state"
      let records = enumerateGenerations(stateDir)
      check records.len == 0
      check readCurrentGenerationId(stateDir).len == 0

    test "repro home apply --plan hard-errors on a broken Phase A profile":
      let tempRoot = createTempDir("repro-m83-f3-applyplan-", "")
      defer:
        try: removeDir(tempRoot) except OSError: discard
      let env = setup(tempRoot)
      let res = runRepro(env, ["home", "apply", "--plan"])
      check res.exitCode != 0
      assertHardErrorOutput(res.output)

    test "repro home plan hard-errors on a broken Phase A profile":
      let tempRoot = createTempDir("repro-m83-f3-plan-", "")
      defer:
        try: removeDir(tempRoot) except OSError: discard
      let env = setup(tempRoot)
      let res = runRepro(env, ["home", "plan"])
      check res.exitCode != 0
      assertHardErrorOutput(res.output)

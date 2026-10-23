## Real CLI, monitor, Nim compiler and C wrapper: no mocked cache evidence.
## A caller may delete its private temp directory after repro exec returns;
## that directory is compiler scratch, never an input to the provider.
import std/[os, osproc, strtabs, strutils, unittest]
import repro_test_support
import repro_test_support/process_fixtures

suite "provider compile scratch belongs to the engine":
  test "repro exec reuses the provider after the caller removes compile-time temp":
    # exec is handled by the engine; the thin client delegates this verb.
    let cli = requireHostBinary(getEnv("REPRO_TEST_PROVIDER_TEMP_CLI",
      reproBinaryPath(stem = "reprobuild")))
    let root = getTempDir() / ("repro-provider-temp-" & $getCurrentProcessId())
    require not dirExists(root)
    releaseDirAtProcessExit(root)
    createDir(root)
    defer: removeDir(root)
    let project = root / "project"
    createDir(project)
    let recipe = project / "repro.nim"
    writeFile(recipe, "import repro_project_dsl\npackage fixture:\n" &
      "  devEnv:\n    setEnv \"SCRATCH_REGRESSION\", \"one\"\n")
    let firstTemp = root / "caller-a"
    let nextTemp = root / "caller-b"
    createDir(firstTemp)
    createDir(nextTemp)
    var env = newStringTable(modeCaseSensitive)
    for name, value in envPairs():
      if not name.startsWith("__REPRO_"):
        env[name] = value
    env["REPROBUILD_ACTION_CACHE_ROOT"] = root / "action-cache"
    env["XDG_CACHE_HOME"] = root / "user-cache"
    env["LOCALAPPDATA"] = root / "user-cache"
    env["REPRO_ACTION_CACHE_SHM"] = "0"
    env["REPRO_DAEMON"] = "off"
    env["REPRO_PROGRESS"] = "lines"
    env["REPRO_PROVIDER_PARALLEL_BUILD"] = "2"
    # Exercise the dev shell's real toolchain without provisioning another
    # one or starting a long-lived Nix helper inside this fixture's cache.
    if not env.hasKey("REPRO_NIM_COMPILER") or env["REPRO_NIM_COMPILER"].len == 0:
      env["REPRO_NIM_COMPILER"] = findExe("nim", followSymlinks = false)
    if not env.hasKey("REPRO_BOOTSTRAP_CC") or env["REPRO_BOOTSTRAP_CC"].len == 0:
      let cc = when defined(windows): "gcc" else: "cc"
      env["REPRO_BOOTSTRAP_CC"] = findExe(cc, followSymlinks = false)
    proc enter(temp: string): string =
      for name in ["TMPDIR", "TMP", "TEMP", "TEMPDIR"]:
        env[name] = temp
      let res = execCmdEx(quoteShell(cli) & " exec " & quoteShell(project) &
        " -- " & quoteShell(cli) & " --version", env = env,
        options = {poStdErrToStdOut})
      checkpoint(res.output)
      require res.exitCode == 0
      res.output
    # Prove we actually compiled, and that changing only the caller's temp
    # does not already invalidate the record while its old directory exists.
    check "provider compiled" in enter(firstTemp)
    check "provider reused" in enter(nextTemp)
    removeDir(firstTemp)
    require not dirExists(firstTemp)
    check "provider reused" in enter(nextTemp)
    # Positive control: genuine recipe input changes must still compile.
    writeFile(recipe, readFile(recipe).replace("\"one\"", "\"two\""))
    check "provider compiled" in enter(nextTemp)

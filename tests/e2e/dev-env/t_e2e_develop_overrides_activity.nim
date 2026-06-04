import std/[json, os, osproc, sequtils, strtabs, streams, strutils, tempfiles,
    unittest]

import repro_dev_env_artifacts
import repro_provider_runtime
import repro_test_support

proc q(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc compileNim(repoRoot, sourcePath, outputPath, cacheName: string;
                appLib = false) =
  var args = @[
    "nim", "c", "--threads:on", "--verbosity:0", "--hints:off",
    "--nimcache:" & repoRoot / "build" / "nimcache" / cacheName,
    "--out:" & outputPath
  ]
  if appLib:
    args.insert("--app:lib", 2)
  args.add(sourcePath)
  discard requireSuccess(shellCommand(args), repoRoot)

# prepareMonitorTools is exported from libs/repro_test_support.

proc compileRepro(repoRoot, tempRoot: string): string =
  result = tempRoot / "bin" / addFileExt("repro", ExeExt)
  createDir(parentDir(result))
  compileNim(repoRoot, repoRoot / "apps" / "repro" / "repro.nim",
    result, "m7-dev-env-repro")

proc appProviderText(): string =
  "import std/[os, strutils]\n" &
    "import repro_project_dsl\n\n" &
    "package app:\n" &
    "  devEnv:\n" &
    "    activity \"default\"\n" &
    "    activity \"debug\"\n" &
    "    let libPath = developOverridePath(\"fixture-lib\")\n" &
    "    if libPath.len > 0:\n" &
    "      setEnv \"FIXTURE_LIB_PATH\", libPath\n" &
    "      prependPath \"PATH\", libPath / \"tools\" / \"bin\"\n" &
    "    else:\n" &
    "      setEnv \"FIXTURE_LIB_PATH\", \"published\"\n" &
    "    setEnv \"APP_BASE\", \"base\"\n" &
    "    setEnv \"DEBUG_ONLY\", \"enabled\", activities = [\"debug\"]\n" &
    "    task \"debug-task\", command = \"debug-cmd\", activities = [\"debug\"]\n"

proc writeAppFixture(dir: string) =
  createDir(dir)
  writeFile(dir / "reprobuild.nim", appProviderText())
  discard requireSuccess(shellCommand(@["git", "init"]), dir)
  discard requireSuccess(shellCommand(@["git", "add", "reprobuild.nim"]), dir)
  discard requireSuccess(shellCommand(@[
    "git",
    "-c", "user.email=reprobuild@example.invalid",
    "-c", "user.name=Reprobuild Test",
    "-c", "commit.gpgsign=false",
    "commit", "-m", "initial app fixture"
  ]), dir)

proc writeLibFixture(dir: string) =
  createDir(dir)
  createDir(dir / "tools" / "bin")
  writeFile(dir / "reprobuild.nim",
    "import repro_project_dsl\n\n" &
      "package `fixture-lib`:\n" &
      "  devEnv:\n" &
      "    activity \"default\"\n")
  let tool = dir / "tools" / "bin" / "lib-tool"
  writeFile(tool,
    "#!/bin/sh\n" &
      "printf 'lib:%s|%s|%s|%s\\n' \"$FIXTURE_LIB_PATH\" \"$APP_BASE\" \"${DEBUG_ONLY-unset}\" \"$REPRO_DEV_ENV_TASKS\"\n")
  setFilePermissions(tool, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

type
  M7Case = object
    tempRoot: string
    appRoot: string
    libRoot: string
    repoRoot: string
    reproBin: string
    fsSnoop: string
    shim: string

proc prepareCase(prefix: string): M7Case =
  result.repoRoot = getCurrentDir()
  result.tempRoot = createTempDir(prefix, "")
  result.appRoot = result.tempRoot / "app"
  result.libRoot = result.tempRoot / "fixture-lib"
  writeAppFixture(result.appRoot)
  writeLibFixture(result.libRoot)
  result.reproBin = compileRepro(result.repoRoot, result.tempRoot)
  when isFsSnoopSupported:
    let monitor = prepareMonitorTools(result.repoRoot, result.tempRoot, "m5-develop-overrides")
    result.fsSnoop = monitor.fsSnoop
    result.shim = monitor.shim

proc envFor(c: M7Case): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  result["REPROBUILD_SOURCE_ROOT"] = c.repoRoot
  result["REPRO_MONITOR_SHIM_LIB"] = c.shim
  result["REPRO_FS_SNOOP"] = c.fsSnoop

proc runProgram(program: string; args: openArray[string]; cwd: string;
                env: StringTableRef = nil): tuple[exitCode: int; output: string] =
  var process = startProcess(program,
    args = @args,
    workingDir = cwd,
    env = env,
    options = {poUsePath, poStdErrToStdOut})
  let output =
    if process.outputStream != nil: process.outputStream.readAll()
    else: ""
  let exitCode = process.waitForExit()
  process.close()
  (exitCode: exitCode, output: output)

proc runRepro(c: M7Case; args: openArray[string]; cwd = ""):
    tuple[exitCode: int; output: string] =
  runProgram(c.reproBin, args,
    if cwd.len > 0: cwd else: c.repoRoot, c.envFor())

proc requireRepro(c: M7Case; args: openArray[string]; cwd = ""): string =
  let res = runRepro(c, args, cwd)
  if res.exitCode != 0:
    raise newException(OSError,
      "repro command failed with exit " & $res.exitCode & ": " &
        args.join(" ") & "\n" & res.output)
  res.output

proc firstNonEmptyLine(text: string): string =
  for line in text.splitLines:
    if line.len > 0:
      return line
  ""

proc artifactPathFromStats(path: string): string =
  parseJson(readFile(path))["artifactPath"].getStr()

proc findShellOp(artifact: DevEnvArtifact; name: string): DevEnvShellOp =
  for op in artifact.shellOps:
    if op.name == name:
      return op
  raise newException(ValueError, "missing shell op " & name)

proc posixSourceValue(path, cwd: string): string =
  let res = runProgram("sh", @[
    "-c", ". " & q(path) &
      "; printf '%s|%s|%s\\n' \"$APP_BASE\" \"${DEBUG_ONLY-unset}\" \"$REPRO_DEV_ENV_TASKS\""
  ], cwd)
  if res.exitCode != 0:
    raise newException(OSError,
      "POSIX shell source failed with exit " & $res.exitCode & ": " &
        res.output)
  res.output.firstNonEmptyLine()

suite "e2e_develop_overrides_activity":
  when isFsSnoopSupported:
    test "e2e_develop_override_rebinds_dev_env":
      let c = prepareCase("repro-m7-develop-override")
      defer: removeDir(c.tempRoot)

      let projectBefore = readFile(c.appRoot / "reprobuild.nim")
      let developOutput = requireRepro(c,
        @["develop", "fixture-lib", "--into", c.tempRoot], cwd = c.appRoot)
      check developOutput.contains("fixture-lib\t" & c.libRoot)

      let metadataPath = c.appRoot / ".git" / "reprobuild" /
        "develop-overrides.json"
      check fileExists(metadataPath)
      check not fileExists(c.appRoot / ".repro" / "local" /
        "develop-overrides.json")
      check readFile(c.appRoot / "reprobuild.nim") == projectBefore
      check requireSuccess(shellCommand(@["git", "status", "--short",
        "--untracked-files=all"]), c.appRoot).strip() == ""
      let metadata = parseJson(readFile(metadataPath))
      check metadata["schemaId"].getStr() == "reprobuild.develop-overrides.v1"
      check metadata["overrides"][0]["node"].getStr() == "fixture-lib"
      check metadata["overrides"][0]["path"].getStr() == c.libRoot

      let listOutput = requireRepro(c, @["develop", "--list"], cwd = c.appRoot)
      check listOutput.strip() == "fixture-lib\t" & c.libRoot

      let statsPath = c.tempRoot / "override-stats.json"
      let execOutput = requireRepro(c, @[
        "exec", c.appRoot, "--dev-env-stats=" & statsPath,
        "--", "lib-tool"
      ]).firstNonEmptyLine()
      check execOutput == "lib:" & c.libRoot & "|base|unset|"

      let artifact = readDevEnvArtifact(artifactPathFromStats(statsPath))
      check artifact.findShellOp("FIXTURE_LIB_PATH").value == c.libRoot
      check artifact.evaluationInputs.anyIt(
        it.kind == gevDevelopModeOverride and it.identity == "fixture-lib")
      check artifact.evaluationInputs.anyIt(
        it.kind == gevFileRead and it.identity == metadataPath)

    test "e2e_develop_activity_changes_artifact":
      let c = prepareCase("repro-m7-activity-artifact")
      defer: removeDir(c.tempRoot)

      let defaultStats = c.tempRoot / "default-stats.json"
      let defaultOutput = requireRepro(c, @[
        "exec", c.appRoot, "--dev-env-stats=" & defaultStats,
        "--", "sh", "-c",
        "printf '%s|%s|%s\\n' \"$APP_BASE\" \"${DEBUG_ONLY-unset}\" \"$REPRO_DEV_ENV_TASKS\""
      ]).firstNonEmptyLine()
      check defaultOutput == "base|unset|"
      let defaultArtifactPath = artifactPathFromStats(defaultStats)
      let defaultArtifact = readDevEnvArtifact(defaultArtifactPath)
      check defaultArtifact.selectedActivities == @["default"]
      check not defaultArtifact.shellOps.anyIt(it.name == "DEBUG_ONLY")
      check defaultArtifact.tasks.len == 0

      let debugStats = c.tempRoot / "debug-stats.json"
      let debugOutput = requireRepro(c, @[
        "exec", c.appRoot, "--activity=debug",
        "--dev-env-stats=" & debugStats,
        "--", "sh", "-c",
        "printf '%s|%s|%s\\n' \"$APP_BASE\" \"${DEBUG_ONLY-unset}\" \"$REPRO_DEV_ENV_TASKS\""
      ]).firstNonEmptyLine()
      check debugOutput == "base|enabled|debug-task"
      let debugArtifactPath = artifactPathFromStats(debugStats)
      let debugArtifact = readDevEnvArtifact(debugArtifactPath)
      check debugArtifact.selectedActivities == @["debug"]
      check debugArtifact.findShellOp("DEBUG_ONLY").value == "enabled"
      check debugArtifact.tasks.mapIt(it.name) == @["debug-task"]
      check debugArtifactPath != defaultArtifactPath
      check readFile(defaultArtifactPath) != readFile(debugArtifactPath)

      let defaultShell = requireRepro(c,
        @["shell", "--print-env=posix", c.appRoot])
      check not defaultShell.contains("DEBUG_ONLY")

      let debugShellStats = c.tempRoot / "debug-shell-stats.json"
      let debugShell = requireRepro(c, @[
        "shell", "--print-env=posix", "--activity=debug", c.appRoot,
        "--dev-env-stats=" & debugShellStats
      ])
      let debugShellPath = c.tempRoot / "debug-env.sh"
      writeFile(debugShellPath, debugShell)
      check posixSourceValue(debugShellPath, c.appRoot) ==
        "base|enabled|debug-task"
      check artifactPathFromStats(debugShellStats) == debugArtifactPath

import std/[json, os, osproc, sequtils, strtabs, streams, strutils, tempfiles,
    unittest]

proc q(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc shellCommand(args: openArray[string]): string =
  args.mapIt(q(it)).join(" ")

proc requireSuccess(command: string; cwd = getCurrentDir()): string =
  let res = execCmdEx(command, workingDir = cwd)
  if res.exitCode != 0:
    raise newException(OSError,
      "command failed with exit " & $res.exitCode & ": " & command &
        "\n" & res.output)
  res.output

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

when defined(linux) or defined(macosx):
  proc prepareMonitorTools(repoRoot, tempRoot: string):
      tuple[fsSnoop: string; shim: string] =
    let binDir = tempRoot / "bin"
    let libDir = tempRoot / "lib"
    createDir(binDir)
    createDir(libDir)
    result.fsSnoop = binDir / "repro-fs-snoop"
    result.shim =
      when defined(linux):
        libDir / "librepro_monitor_shim.so"
      else:
        libDir / "librepro_monitor_shim.dylib"
    let shimSource =
      when defined(linux):
        repoRoot / "libs" / "repro_monitor_shim" / "src" /
          "repro_monitor_shim" / "linux_preload.nim"
      else:
        repoRoot / "libs" / "repro_monitor_shim" / "src" /
          "repro_monitor_shim" / "macos_interpose.nim"
    compileNim(repoRoot, shimSource, result.shim, "m5-dev-env-monitor-shim",
      appLib = true)
    compileNim(repoRoot,
      repoRoot / "apps" / "repro-fs-snoop" / "repro_fs_snoop.nim",
      result.fsSnoop, "m5-dev-env-fs-snoop")

proc compileRepro(repoRoot, tempRoot: string): string =
  result = tempRoot / "bin" / addFileExt("repro", ExeExt)
  createDir(parentDir(result))
  compileNim(repoRoot, repoRoot / "apps" / "repro" / "repro.nim",
    result, "m5-dev-env-repro")

proc providerText(modeValue: string): string =
  "import std/strutils\n" &
    "import repro_project_dsl\n\n" &
    "package fixture:\n" &
    "  uses:\n" &
    "    \"nim >=2.2 <3.0\"\n" &
    "  devEnv:\n" &
    "    activity \"default\"\n" &
    "    setEnv \"FIXTURE_MODE\", \"" & modeValue & "\"\n" &
    "    setEnv \"AUX_VALUE\", readDevEnvFile(\"dev-env-value.txt\").strip()\n" &
    "    prependPath \"PATH\", \"tools/bin\"\n" &
    "    task \"build\", command = \"fixture-tool --build\", description = \"Build fixture\"\n" &
    "    diagnostic \"dev env ready\"\n"

proc writeFixture(dir: string; modeValue = "dev") =
  createDir(dir)
  createDir(dir / "tools" / "bin")
  writeFile(dir / "dev-env-value.txt", "alpha\n")
  writeFile(dir / "reprobuild.nim", providerText(modeValue))
  let toolPath = dir / "tools" / "bin" / "fixture-tool"
  writeFile(toolPath,
    "#!/bin/sh\n" &
    "printf 'tool:%s:%s\\n' \"$AUX_VALUE\" \"$FIXTURE_MODE\"\n")
  setFilePermissions(toolPath, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  discard execCmdEx("git init -q", workingDir = dir)

type
  M5Case = object
    tempRoot: string
    projectRoot: string
    repoRoot: string
    reproBin: string
    fsSnoop: string
    shim: string
    direnvBin: string

proc requireDirenv(): string =
  result = findExe("direnv")
  if result.len == 0:
    raise newException(OSError,
      "M5 direnv gate requires a real direnv binary on PATH")

proc prepareCase(prefix: string): M5Case =
  result.repoRoot = getCurrentDir()
  result.tempRoot = createTempDir(prefix, "")
  result.projectRoot = result.tempRoot / "project"
  writeFixture(result.projectRoot)
  result.reproBin = compileRepro(result.repoRoot, result.tempRoot)
  result.direnvBin = requireDirenv()
  when defined(linux) or defined(macosx):
    let monitor = prepareMonitorTools(result.repoRoot, result.tempRoot)
    result.fsSnoop = monitor.fsSnoop
    result.shim = monitor.shim
  else:
    raise newException(OSError,
      "dev-env direnv hook tests require fs-snoop support")

proc envFor(c: M5Case): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  result["HOME"] = c.tempRoot / "home"
  result["XDG_CONFIG_HOME"] = c.tempRoot / "xdg-config"
  result["XDG_CACHE_HOME"] = c.tempRoot / "xdg-cache"
  result["XDG_DATA_HOME"] = c.tempRoot / "xdg-data"
  result["DIRENV_LOG_FORMAT"] = ""
  result["REPROBUILD_SOURCE_ROOT"] = c.repoRoot
  result["REPROBUILD_REPRO"] = c.reproBin
  result["REPRO_MONITOR_SHIM_LIB"] = c.shim
  result["REPRO_FS_SNOOP"] = c.fsSnoop
  result["PATH"] = parentDir(c.reproBin) & $PathSep & getEnv("PATH")

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

proc runRepro(c: M5Case; args: openArray[string]):
    tuple[exitCode: int; output: string] =
  runProgram(c.reproBin, args, c.repoRoot, c.envFor())

proc requireRepro(c: M5Case; args: openArray[string]): string =
  let res = runRepro(c, args)
  if res.exitCode != 0:
    raise newException(OSError,
      "repro command failed with exit " & $res.exitCode & ": " &
        args.join(" ") & "\n" & res.output)
  res.output

proc allowDirenv(c: M5Case) =
  let res = runProgram(c.direnvBin, @["allow", "."], c.projectRoot, c.envFor())
  if res.exitCode != 0:
    raise newException(OSError, "direnv allow failed: " & res.output)

proc runDirenv(c: M5Case; statsPath, script: string):
    tuple[exitCode: int; output: string] =
  let env = c.envFor()
  if statsPath.len > 0:
    env["REPRO_DIRENV_STATS"] = statsPath
  runProgram(c.direnvBin, @["exec", c.projectRoot, "sh", "-c", script],
    c.projectRoot, env)

proc requireDirenvValue(c: M5Case; statsPath: string): string =
  let res = runDirenv(c, statsPath,
    "printf 'DIR:%s|%s|%s|%s\\n' \"$AUX_VALUE\" \"$FIXTURE_MODE\" " &
      "\"$(basename \"$REPRO_DEV_ENV_ARTIFACT\")\" \"$(fixture-tool)\"")
  if res.exitCode != 0:
    raise newException(OSError, "direnv exec failed: " & res.output)
  for line in res.output.splitLines:
    if line.startsWith("DIR:"):
      return line
  raise newException(OSError, "direnv output did not contain marker: " &
    res.output)

proc jsonArrayHasSuffix(node: JsonNode; suffix: string): bool =
  for item in node:
    if item.getStr().replace('\\', '/').endsWith(suffix):
      return true

proc evidenceMentionsInput(stats: JsonNode; suffix: string): bool =
  let evidence = stats["introspectionAction"]["evidence"]
  for key in ["monitorReads", "monitorProbes", "depfileInputs"]:
    if evidence[key].jsonArrayHasSuffix(suffix):
      return true

proc requireNavigatorHotPath(stats: JsonNode) =
  check stats["shellNavigatorStats"].kind == JObject
  let nav = stats["shellNavigatorStats"]
  check nav["shellOpRecordsDecoded"].getInt() > 0
  check nav["taskRecordsDecoded"].getInt() == 0
  check nav["serviceRecordsDecoded"].getInt() == 0
  check nav["payloadHeaderBytesRead"].getInt() > 0
  check nav["shellOpsSectionEnd"].getInt() <= nav["tasksSectionStart"].getInt()
  check nav["maxDecodedPayloadOffset"].getInt() == nav["shellOpsSectionEnd"].getInt()
  check nav["maxDecodedPayloadOffset"].getInt() <= nav["tasksSectionStart"].getInt()

proc hooksDir(c: M5Case): string =
  c.projectRoot / ".git" / "hooks"

proc isExecutable(path: string): bool =
  let permissions = getFilePermissions(path)
  fpUserExec in permissions

proc writeExecutable(path, content: string) =
  writeFile(path, content)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc requireVcsHooksInstalled(c: M5Case): tuple[prePush: string; postCommit: string] =
  let dir = c.hooksDir()
  for hookName in ["pre-push", "post-commit"]:
    let dispatcher = dir / hookName
    let managed = dir / (hookName & ".repro-managed")
    if not fileExists(dispatcher):
      raise newException(OSError, "missing VCS hook dispatcher: " & dispatcher)
    if not fileExists(managed):
      raise newException(OSError, "missing managed VCS hook: " & managed)
    check dispatcher.isExecutable()
    check managed.isExecutable()
    check readFile(dispatcher).contains("reprobuild hook dispatcher")
    check readFile(dispatcher).contains(hookName & ".repro-local")
    check readFile(dispatcher).contains(hookName & ".repro-managed")
    check readFile(managed).contains("reprobuild managed " & hookName & " hook")
    check readFile(managed).contains("__hook " & hookName)
  result.prePush = readFile(dir / "pre-push")
  result.postCommit = readFile(dir / "post-commit")

suite "e2e_hooks_shell_direnv":
  test "e2e_hooks_shell_direnv_real_activation":
    let c = prepareCase("repro-m5-direnv-real")
    defer: removeDir(c.tempRoot)

    discard requireRepro(c, @["hooks", "ensure", "--shell-direnv",
      c.projectRoot])
    allowDirenv(c)

    let statsPath = c.tempRoot / "direnv-real-stats.json"
    check requireDirenvValue(c, statsPath) == "DIR:alpha|dev|dev-env.rbde|tool:alpha:dev"
    let envrc = readFile(c.projectRoot / ".envrc")
    check "repro-managed:repro-dev-env-direnv" in envrc
    check "__repro-direnv-activate" in envrc
    check "hooks ensure --vcs" in envrc
    let hooksAfterDirenv = c.requireVcsHooksInstalled()
    discard requireRepro(c, @["hooks", "ensure", "--vcs", c.projectRoot])
    let hooksAfterExplicitEnsure = c.requireVcsHooksInstalled()
    check hooksAfterExplicitEnsure == hooksAfterDirenv

    let stats = parseJson(readFile(statsPath))
    check stats["command"].getStr() == "hooks shell-direnv"
    check fileExists(stats["artifactPath"].getStr())
    check stats["stats"]["providerIntrospectionLaunched"].getBool()
    check stats["stats"]["artifactWriteLaunched"].getBool()
    check stats["stats"]["shellRenderingLaunched"].getBool()
    check stats.evidenceMentionsInput("dev-env-value.txt")
    stats.requireNavigatorHotPath()

  test "e2e_hooks_shell_direnv_noop_is_fast":
    let c = prepareCase("repro-m5-direnv-noop")
    defer: removeDir(c.tempRoot)

    discard requireRepro(c, @["hooks", "ensure", "--shell-direnv",
      c.projectRoot])
    allowDirenv(c)

    let firstStatsPath = c.tempRoot / "direnv-first-stats.json"
    check requireDirenvValue(c, firstStatsPath) == "DIR:alpha|dev|dev-env.rbde|tool:alpha:dev"
    let firstStats = parseJson(readFile(firstStatsPath))
    let artifactPath = firstStats["artifactPath"].getStr()
    let artifactBytes = readFile(artifactPath)
    check firstStats["stats"]["providerIntrospectionLaunched"].getBool()
    check firstStats["stats"]["shellRenderingLaunched"].getBool()
    firstStats.requireNavigatorHotPath()

    let secondStatsPath = c.tempRoot / "direnv-second-stats.json"
    check requireDirenvValue(c, secondStatsPath) == "DIR:alpha|dev|dev-env.rbde|tool:alpha:dev"
    let secondStats = parseJson(readFile(secondStatsPath))
    check secondStats["artifactPath"].getStr() == artifactPath
    check readFile(artifactPath) == artifactBytes
    check not secondStats["stats"]["providerIntrospectionLaunched"].getBool()
    check secondStats["stats"]["providerIntrospectionCacheHit"].getBool()
    check secondStats["stats"]["artifactWriteSkipped"].getBool()
    check not secondStats["stats"]["shellRenderingLaunched"].getBool()
    check secondStats["stats"]["shellRenderingCacheHit"].getBool()
    check secondStats.evidenceMentionsInput("dev-env-value.txt")
    secondStats.requireNavigatorHotPath()

  test "e2e_hooks_shell_direnv_conflict_and_uninstall":
    let c = prepareCase("repro-m5-direnv-conflict")
    defer: removeDir(c.tempRoot)

    let envrcPath = c.projectRoot / ".envrc"
    let userBytes = "export USER_OWNED=1\n# tail user bytes\n"
    writeFile(envrcPath, userBytes)

    discard requireRepro(c, @["hooks", "ensure", "--shell-direnv",
      c.projectRoot])
    let withBlock = readFile(envrcPath)
    check withBlock.contains(userBytes)
    check withBlock.contains("repro-managed:repro-dev-env-direnv")

    discard requireRepro(c, @["hooks", "ensure", "--shell-direnv",
      c.projectRoot])
    check readFile(envrcPath) == withBlock

    discard requireRepro(c, @["hooks", "uninstall", "--shell-direnv",
      c.projectRoot])
    check readFile(envrcPath) == userBytes

    let conflictBytes =
      "eval \"$(repro shell --print-env=posix .)\"\n# keep my conflict\n"
    writeFile(envrcPath, conflictBytes)
    let conflict = runRepro(c, @["hooks", "ensure", "--shell-direnv",
      c.projectRoot])
    check conflict.exitCode != 0
    check conflict.output.contains("conflicting unmanaged .envrc")
    check readFile(envrcPath) == conflictBytes

    let hooks = c.hooksDir()
    let userPrePush =
      "#!/bin/sh\nprintf 'user pre-push hook\\n'\n"
    let userPostCommit =
      "#!/bin/sh\nprintf 'user post-commit hook\\n'\n"
    writeExecutable(hooks / "pre-push", userPrePush)
    writeExecutable(hooks / "post-commit", userPostCommit)

    discard requireRepro(c, @["hooks", "ensure", "--vcs", c.projectRoot])
    discard c.requireVcsHooksInstalled()
    check readFile(hooks / "pre-push.repro-local") == userPrePush
    check readFile(hooks / "post-commit.repro-local") == userPostCommit

    let dispatcherPrePush = readFile(hooks / "pre-push")
    let dispatcherPostCommit = readFile(hooks / "post-commit")
    discard requireRepro(c, @["hooks", "ensure", "--vcs", c.projectRoot])
    check readFile(hooks / "pre-push") == dispatcherPrePush
    check readFile(hooks / "post-commit") == dispatcherPostCommit
    check readFile(hooks / "pre-push.repro-local") == userPrePush
    check readFile(hooks / "post-commit.repro-local") == userPostCommit

    discard requireRepro(c, @["hooks", "uninstall", "--vcs", c.projectRoot])
    check readFile(hooks / "pre-push") == userPrePush
    check readFile(hooks / "post-commit") == userPostCommit
    check not fileExists(hooks / "pre-push.repro-managed")
    check not fileExists(hooks / "post-commit.repro-managed")

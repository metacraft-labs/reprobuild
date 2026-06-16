import std/[json, os, osproc, sequtils, strtabs, streams, strutils, tempfiles,
    unittest]

import repro_test_support

proc q(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

# prepareMonitorTools is exported from libs/repro_test_support.

# Test-Fixtures-In-Build-Graph M1: ``repro`` is a build-graph artifact
# (``reprobuild.apps.repro`` → ``build/bin/repro``, built by ``just bootstrap``
# / the apps collection before tests run). Assert it exists and use it instead
# of recompiling ``apps/repro/repro.nim`` at test runtime.
proc reproBinary(): string =
  requireBinary(getCurrentDir() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

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
    "printf 'tool:%s:%s:%s\\n' \"$AUX_VALUE\" \"$FIXTURE_MODE\" \"$REPRO_DEV_ENV_TASKS\"\n")
  setFilePermissions(toolPath, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

type
  M4Case = object
    tempRoot: string
    projectRoot: string
    repoRoot: string
    reproBin: string
    fsSnoop: string
    shim: string

proc prepareCase(prefix: string): M4Case =
  result.repoRoot = getCurrentDir()
  # Resolve symlinks (e.g. /tmp -> /private/tmp on macOS) so that paths the
  # test passes into child processes match the paths the kernel reports back
  # via getcwd / realpath. Without this, equality checks against c.projectRoot
  # fail under `nix develop` where TMPDIR=/tmp/nix-shell.X but the OS resolves
  # /tmp to /private/tmp at every syscall boundary.
  result.tempRoot = expandFilename(createTempDir(prefix, ""))
  result.projectRoot = result.tempRoot / "project"
  writeFixture(result.projectRoot)
  result.reproBin = reproBinary()
  when isFsSnoopSupported:
    let monitor = prepareMonitorTools(result.repoRoot, result.tempRoot, "m4-exec-shell")
    result.fsSnoop = monitor.fsSnoop
    result.shim = monitor.shim

proc envFor(c: M4Case): StringTableRef =
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

proc runRepro(c: M4Case; args: openArray[string]):
    tuple[exitCode: int; output: string] =
  runProgram(c.reproBin, args, c.repoRoot, c.envFor())

proc requireRepro(c: M4Case; args: openArray[string]): string =
  let res = runRepro(c, args)
  if res.exitCode != 0:
    raise newException(OSError,
      "repro command failed with exit " & $res.exitCode & ": " &
        args.join(" ") & "\n" & res.output)
  res.output

proc jsonArrayHasSuffix(node: JsonNode; suffix: string): bool =
  for item in node:
    if item.getStr().replace('\\', '/').endsWith(suffix):
      return true

proc evidenceMentionsInput(stats: JsonNode; suffix: string): bool =
  let evidence = stats["introspectionAction"]["evidence"]
  for key in ["monitorReads", "monitorProbes", "depfileInputs"]:
    if evidence[key].jsonArrayHasSuffix(suffix):
      return true

proc requireShellCacheStats(statsPath, expectedArtifactPath: string) =
  let stats = parseJson(readFile(statsPath))
  check stats["command"].getStr() == "shell"
  check stats["artifactPath"].getStr() == expectedArtifactPath
  check not stats["stats"]["providerIntrospectionLaunched"].getBool()
  check stats["stats"]["providerIntrospectionCacheHit"].getBool()
  check stats["stats"]["artifactWriteSkipped"].getBool()
  check stats.evidenceMentionsInput("dev-env-value.txt")

proc firstNonEmptyLine(text: string): string =
  for line in text.splitLines:
    if line.len > 0:
      return line

proc shellValueViaExec(c: M4Case): string =
  requireRepro(c, @[
    "exec", c.projectRoot, "--", "sh", "-c",
    "printf '%s|%s|%s\\n' \"$AUX_VALUE\" \"$FIXTURE_MODE\" \"$REPRO_DEV_ENV_TASKS\""
  ]).firstNonEmptyLine()

proc posixSourceValue(path, cwd: string): string =
  let res = runProgram("sh", @[
    "-c", ". " & q(path) &
      "; printf '%s|%s|%s\\n' \"$AUX_VALUE\" \"$FIXTURE_MODE\" \"$REPRO_DEV_ENV_TASKS\""
  ], cwd)
  if res.exitCode != 0:
    raise newException(OSError,
      "POSIX shell source failed: " & res.output)
  res.output.firstNonEmptyLine()

proc fishQuote(value: string): string =
  "'" & value.replace("\\", "\\\\").replace("'", "\\'") & "'"

proc fishSourceValue(fish, path, cwd: string): string =
  let res = runProgram(fish, @[
    "-c", "source " & fishQuote(path) &
      "; printf '%s|%s|%s\\n' $AUX_VALUE $FIXTURE_MODE $REPRO_DEV_ENV_TASKS"
  ], cwd)
  if res.exitCode != 0:
    raise newException(OSError, "Fish source failed: " & res.output)
  res.output.firstNonEmptyLine()

when defined(windows):
  proc psQuote(value: string): string =
    "'" & value.replace("'", "''") & "'"

  proc powerShellSourceValue(pwsh, path, cwd: string): string =
    let res = runProgram(pwsh, @[
      "-NoProfile", "-Command",
      ". " & psQuote(path) &
        "; Write-Output \"$env:AUX_VALUE|$env:FIXTURE_MODE|$env:REPRO_DEV_ENV_TASKS\""
    ], cwd)
    if res.exitCode != 0:
      raise newException(OSError, "PowerShell source failed: " & res.output)
    res.output.firstNonEmptyLine()

when isNixSupported:
  proc nixFish(): string =
    let nix = findExe("nix")
    if nix.len == 0:
      return ""
    let res = runShell(shellCommand(@[
      nix, "build", "--no-link", "--print-out-paths", "nixpkgs#fish",
      "--extra-experimental-features", "nix-command flakes"
    ]))
    if res.code != 0:
      return ""
    for line in res.output.splitLines():
      let candidate = line.strip()
      if candidate.startsWith("/nix/store/") and
          fileExists(candidate / "bin" / "fish"):
        return candidate / "bin" / "fish"

  proc requireFish(): string =
    result = findExe("fish")
    if result.len > 0:
      return
    result = nixFish()
    if result.len > 0:
      return
    raise newException(OSError,
      "M4 shell print gate requires a real fish binary; PATH has none " &
        "and `nix build nixpkgs#fish` did not provide one")

suite "e2e_repro_exec_shell_artifact_consumers":
  when isFsSnoopSupported:
    test "e2e_repro_exec_uses_cached_dev_env_artifact":
      let c = prepareCase("repro-m4-exec-cache")
      defer: removeDir(c.tempRoot)

      let firstStatsPath = c.tempRoot / "first-stats.json"
      let first = runRepro(c, @[
        "exec", c.projectRoot, "--dev-env-stats=" & firstStatsPath,
        "--", "fixture-tool"
      ])
      check first.exitCode == 0
      check first.output.contains("tool:alpha:dev:build")
      let firstStats = parseJson(readFile(firstStatsPath))
      let artifactPath = firstStats["artifactPath"].getStr()
      let firstArtifact = readFile(artifactPath)
      check firstStats["stats"]["providerIntrospectionLaunched"].getBool()
      check firstStats["stats"]["artifactWriteLaunched"].getBool()
      check firstStats.evidenceMentionsInput("dev-env-value.txt")

      let secondStatsPath = c.tempRoot / "second-stats.json"
      let second = runRepro(c, @[
        "exec", c.projectRoot, "--dev-env-stats=" & secondStatsPath,
        "--", "fixture-tool"
      ])
      check second.exitCode == 0
      check second.output.contains("tool:alpha:dev:build")
      let secondStats = parseJson(readFile(secondStatsPath))
      check secondStats["artifactPath"].getStr() == artifactPath
      check readFile(artifactPath) == firstArtifact
      check not secondStats["stats"]["providerIntrospectionLaunched"].getBool()
      check secondStats["stats"]["providerIntrospectionCacheHit"].getBool()
      check secondStats["stats"]["artifactWriteSkipped"].getBool()
      check secondStats.evidenceMentionsInput("dev-env-value.txt")

    test "e2e_repro_shell_print_env_sources_successfully":
      let c = prepareCase("repro-m4-shell-print")
      defer: removeDir(c.tempRoot)
      let expected = shellValueViaExec(c)

      let posixStatsPath = c.tempRoot / "posix-stats.json"
      let posixText = requireRepro(c, @[
        "shell", "--print-env=posix", c.projectRoot,
        "--dev-env-stats=" & posixStatsPath
      ])
      let artifactPath = parseJson(readFile(posixStatsPath))["artifactPath"].getStr()
      check artifactPath.len > 0
      requireShellCacheStats(posixStatsPath, artifactPath)
      let posixPath = c.tempRoot / "dev-env.sh"
      writeFile(posixPath, posixText)
      check posixSourceValue(posixPath, c.projectRoot) == expected

      let jsonStatsPath = c.tempRoot / "json-stats.json"
      let jsonText = requireRepro(c, @[
        "shell", "--print-env=json", c.projectRoot,
        "--dev-env-stats=" & jsonStatsPath
      ])
      requireShellCacheStats(jsonStatsPath, artifactPath)
      let jsonView = parseJson(jsonText)
      check jsonView["projectRoot"].getStr() == c.projectRoot
      check jsonView["tasks"][0]["name"].getStr() == "build"

      when isNixSupported:
        let fish = requireFish()
        let fishStatsPath = c.tempRoot / "fish-stats.json"
        let fishText = requireRepro(c, @[
          "shell", "--print-env=fish", c.projectRoot,
          "--dev-env-stats=" & fishStatsPath
        ])
        requireShellCacheStats(fishStatsPath, artifactPath)
        let fishPath = c.tempRoot / "dev-env.fish"
        writeFile(fishPath, fishText)
        check fishSourceValue(fish, fishPath, c.projectRoot) == expected

      when defined(windows):
        let pwsh =
          if findExe("pwsh").len > 0: findExe("pwsh") else: findExe("powershell")
        if pwsh.len == 0:
          raise newException(OSError,
            "M4 PowerShell shell print gate requires a real PowerShell binary")
        let psStatsPath = c.tempRoot / "powershell-stats.json"
        let psText = requireRepro(c, @[
          "shell", "--print-env=powershell", c.projectRoot,
          "--dev-env-stats=" & psStatsPath
        ])
        requireShellCacheStats(psStatsPath, artifactPath)
        let psPath = c.tempRoot / "dev-env.ps1"
        writeFile(psPath, psText)
        check powerShellSourceValue(pwsh, psPath, c.projectRoot) == expected
      else:
        let psStatsPath = c.tempRoot / "powershell-render-stats.json"
        let psText = requireRepro(c, @[
          "shell", "--print-env=powershell", c.projectRoot,
          "--dev-env-stats=" & psStatsPath
        ])
        requireShellCacheStats(psStatsPath, artifactPath)
        check psText.contains("$env:AUX_VALUE")
        check psText.contains("$env:FIXTURE_MODE")

    test "e2e_repro_exec_exit_status_and_cwd":
      let c = prepareCase("repro-m4-exec-status")
      defer: removeDir(c.tempRoot)

      let special = "semi;dollar$arg and quote' marker"
      let script =
        "pwd\n" &
        "printf 'arg1=<%s>\\n' \"$1\"\n" &
        "printf 'arg2=<%s>\\n' \"$2\"\n" &
        "exit 17\n"
      let res = runRepro(c, @[
        "exec", c.projectRoot, "--", "sh", "-c", script,
        "repro-test", "space arg", special
      ])
      check res.exitCode == 17
      check res.output.splitLines()[0] == c.projectRoot
      check res.output.contains("arg1=<space arg>")
      check res.output.contains("arg2=<" & special & ">")

    test "e2e_repro_shell_spawn_uses_cached_dev_env_artifact":
      let c = prepareCase("repro-m4-shell-spawn")
      defer: removeDir(c.tempRoot)

      let markerPath = c.projectRoot / "shell-spawn.txt"
      let shellPath = c.tempRoot / "spawn-shell"
      writeFile(shellPath,
        "#!/bin/sh\n" &
        "printf 'spawn:%s:%s:%s:%s\\n' \"$PWD\" \"$AUX_VALUE\" " &
          "\"$FIXTURE_MODE\" \"$REPRO_DEV_ENV_ARTIFACT\" > " &
          q(markerPath) & "\n")
      setFilePermissions(shellPath, {fpUserRead, fpUserWrite, fpUserExec,
        fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

      let statsPath = c.tempRoot / "spawn-stats.json"
      let res = runRepro(c, @[
        "shell", c.projectRoot, "--shell=" & shellPath,
        "--dev-env-stats=" & statsPath
      ])
      check res.exitCode == 0
      let stats = parseJson(readFile(statsPath))
      let artifactPath = stats["artifactPath"].getStr()
      check artifactPath.len > 0
      check stats["command"].getStr() == "shell"
      check stats["stats"]["providerIntrospectionLaunched"].getBool()
      check stats["stats"]["artifactWriteLaunched"].getBool()
      check stats.evidenceMentionsInput("dev-env-value.txt")
      check readFile(markerPath).strip() ==
        "spawn:" & c.projectRoot & ":alpha:dev:" & artifactPath

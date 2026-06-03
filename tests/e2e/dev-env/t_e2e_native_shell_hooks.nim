import std/[json, os, osproc, sequtils, strtabs, streams, strutils, tempfiles,
    unittest]

import repro_test_support

proc q(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

when defined(windows):
  proc psQuote(value: string): string =
    "'" & value.replace("'", "''") & "'"

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

when defined(linux) or defined(macosx) or defined(windows):
  proc prepareMonitorTools(repoRoot, tempRoot: string):
      tuple[fsSnoop: string; shim: string] =
    let binDir = tempRoot / "bin"
    let libDir = tempRoot / "lib"
    createDir(binDir)
    createDir(libDir)
    result.fsSnoop = binDir / addFileExt("repro-fs-snoop", ExeExt)
    result.shim =
      when defined(linux):
        libDir / "librepro_monitor_shim.so"
      elif defined(windows):
        libDir / "repro_monitor_shim.dll"
      else:
        libDir / "librepro_monitor_shim.dylib"
    let shimSource =
      when defined(linux):
        repoRoot / "libs" / "repro_monitor_shim" / "src" /
          "repro_monitor_shim" / "linux_preload.nim"
      elif defined(windows):
        repoRoot / "libs" / "repro_monitor_shim" / "src" /
          "repro_monitor_shim" / "windows_interpose.nim"
      else:
        repoRoot / "libs" / "repro_monitor_shim" / "src" /
          "repro_monitor_shim" / "macos_interpose.nim"
    compileNim(repoRoot, shimSource, result.shim, "m6-dev-env-monitor-shim",
      appLib = true)
    compileNim(repoRoot,
      repoRoot / "apps" / "repro-fs-snoop" / "repro_fs_snoop.nim",
      result.fsSnoop, "m6-dev-env-fs-snoop")

proc compileRepro(repoRoot, tempRoot: string): string =
  result = tempRoot / "bin" / addFileExt("repro", ExeExt)
  createDir(parentDir(result))
  compileNim(repoRoot, repoRoot / "apps" / "repro" / "repro.nim",
    result, "m6-dev-env-repro")

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

proc writeFixture(dir, modeValue, auxValue: string) =
  createDir(dir)
  createDir(dir / "tools" / "bin")
  writeFile(dir / "dev-env-value.txt", auxValue & "\n")
  writeFile(dir / "reprobuild.nim", providerText(modeValue))
  let toolPath = dir / "tools" / "bin" / "fixture-tool"
  writeFile(toolPath,
    "#!/bin/sh\n" &
    "printf 'tool:%s:%s\\n' \"$AUX_VALUE\" \"$FIXTURE_MODE\"\n")
  setFilePermissions(toolPath, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

type
  M6Case = object
    tempRoot: string
    homeDir: string
    xdgConfig: string
    projectA: string
    projectB: string
    repoRoot: string
    reproBin: string
    fsSnoop: string
    shim: string

proc prepareCase(prefix: string): M6Case =
  result.repoRoot = getCurrentDir()
  result.tempRoot = createTempDir(prefix, "")
  result.homeDir = result.tempRoot / "home"
  result.xdgConfig = result.tempRoot / "xdg-config"
  result.projectA = result.tempRoot / "project-a"
  result.projectB = result.tempRoot / "project-b"
  createDir(result.homeDir)
  createDir(result.xdgConfig)
  writeFixture(result.projectA, "one", "alpha")
  writeFixture(result.projectB, "two", "beta")
  result.reproBin = compileRepro(result.repoRoot, result.tempRoot)
  # The on-disk monitor shim path is only consumed by Linux/macOS
  # tests (REPRO_MONITOR_SHIM_LIB plumbing). The Windows shim build
  # depends on ct_interpose sources that ``compileNim`` here doesn't
  # know how to wire; the Windows PowerShell hook test path itself is
  # gated below via ``when defined(windows):`` so it never reaches the
  # shim fields. Setting up ``fsSnoop`` / ``shim`` is therefore only
  # meaningful on platforms where the full fs-snoop integration is
  # also available — gate via ``isFsSnoopSupported`` like the rest
  # of the dev-env suite.
  when isFsSnoopSupported:
    let monitor = prepareMonitorTools(result.repoRoot, result.tempRoot)
    result.fsSnoop = monitor.fsSnoop
    result.shim = monitor.shim

proc envFor(c: M6Case): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  result["HOME"] = c.homeDir
  result["USERPROFILE"] = c.homeDir
  result["ZDOTDIR"] = c.homeDir
  result["XDG_CONFIG_HOME"] = c.xdgConfig
  result["XDG_CACHE_HOME"] = c.tempRoot / "xdg-cache"
  result["XDG_DATA_HOME"] = c.tempRoot / "xdg-data"
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

proc runRepro(c: M6Case; args: openArray[string]):
    tuple[exitCode: int; output: string] =
  runProgram(c.reproBin, args, c.repoRoot, c.envFor())

proc requireRepro(c: M6Case; args: openArray[string]): string =
  let res = runRepro(c, args)
  if res.exitCode != 0:
    raise newException(OSError,
      "repro command failed with exit " & $res.exitCode & ": " &
        args.join(" ") & "\n" & res.output)
  res.output

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
      "M6 native shell gate requires a real fish binary; PATH has none " &
        "and `nix build nixpkgs#fish` did not provide one")

proc requireShellValue(output, prefix, expected: string) =
  for line in output.splitLines():
    if line.startsWith(prefix):
      check line == expected
      return
  raise newException(OSError,
    "missing shell marker " & prefix & " in output:\n" & output)

proc requireNativeStats(statsPath: string) =
  let stats = parseJson(readFile(statsPath))
  check stats["command"].getStr() == "hooks shell-native"
  check fileExists(stats["artifactPath"].getStr())
  check stats["stats"].kind == JObject
  check not stats["stats"]["providerIntrospectionLaunched"].getBool()
  check stats["stats"]["providerIntrospectionCacheHit"].getBool()
  check stats["stats"]["artifactWriteSkipped"].getBool()
  check not stats["stats"]["shellRenderingLaunched"].getBool()
  check stats["stats"]["shellRenderingCacheHit"].getBool()

proc reproPathWithSpaces(c: M6Case): string =
  let dir = c.tempRoot / "bin with spaces"
  createDir(dir)
  result = dir / addFileExt("repro", ExeExt)
  if not fileExists(result):
    copyFile(c.reproBin, result)
    setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc installNativeHooks(c: M6Case) =
  discard requireRepro(c, @["hooks", "ensure", "--shell", "bash"])
  discard requireRepro(c, @["hooks", "ensure", "--shell", "zsh"])
  discard requireRepro(c, @["hooks", "ensure", "--shell", "fish"])
  check readFile(c.homeDir / ".bashrc").contains(
    "repro-managed:repro-dev-env-native-bash")
  check readFile(c.homeDir / ".zshrc").contains(
    "repro-managed:repro-dev-env-native-zsh")
  check readFile(c.xdgConfig / "fish" / "config.fish").contains(
    "repro-managed:repro-dev-env-native-fish")
  check "__repro-native-shell-activate" in readFile(c.homeDir / ".bashrc")
  check "__repro-native-shell-activate" in readFile(c.homeDir / ".zshrc")
  check "__repro-native-shell-activate" in
    readFile(c.xdgConfig / "fish" / "config.fish")

proc posixProbeScript(projectA, projectB: string): string =
  "cd " & q(projectA) & "\n" &
    "printf 'A:%s|%s|%s|%s\\n' \"$AUX_VALUE\" \"$FIXTURE_MODE\" \"$REPRO_DEV_ENV_PROJECT_ROOT\" \"$(fixture-tool)\"\n" &
    "cd " & q(projectB) & "\n" &
    "printf 'B:%s|%s|%s|%s\\n' \"$AUX_VALUE\" \"$FIXTURE_MODE\" \"$REPRO_DEV_ENV_PROJECT_ROOT\" \"$(fixture-tool)\"\n" &
    "cd " & q(parentDir(projectA)) & "\n" &
    "printf 'OUT:%s|%s|%s\\n' \"${AUX_VALUE-unset}\" \"${FIXTURE_MODE-unset}\" \"${REPRO_DEV_ENV_PROJECT_ROOT-unset}\"\n" &
    "cd " & q(projectA) & "\n" &
    "printf 'A2:%s|%s|%s|%s\\n' \"$AUX_VALUE\" \"$FIXTURE_MODE\" \"$REPRO_DEV_ENV_PROJECT_ROOT\" \"$(fixture-tool)\"\n"

proc fishProbeScript(projectA, projectB: string): string =
  "cd " & q(projectA) & "\n" &
    "printf 'A:%s|%s|%s|%s\\n' \"$AUX_VALUE\" \"$FIXTURE_MODE\" \"$REPRO_DEV_ENV_PROJECT_ROOT\" (fixture-tool)\n" &
    "cd " & q(projectB) & "\n" &
    "printf 'B:%s|%s|%s|%s\\n' \"$AUX_VALUE\" \"$FIXTURE_MODE\" \"$REPRO_DEV_ENV_PROJECT_ROOT\" (fixture-tool)\n" &
    "cd " & q(parentDir(projectA)) & "\n" &
    "printf 'OUT:%s|%s|%s\\n' \"$AUX_VALUE\" \"$FIXTURE_MODE\" \"$REPRO_DEV_ENV_PROJECT_ROOT\"\n" &
    "cd " & q(projectA) & "\n" &
    "printf 'A2:%s|%s|%s|%s\\n' \"$AUX_VALUE\" \"$FIXTURE_MODE\" \"$REPRO_DEV_ENV_PROJECT_ROOT\" (fixture-tool)\n"

proc requireBashHook(c: M6Case) =
  let env = c.envFor()
  let statsPath = c.tempRoot / "bash-native-stats.json"
  env["REPRO_NATIVE_SHELL_STATS"] = statsPath
  env["REPROBUILD_REPRO"] = reproPathWithSpaces(c)
  let res = runProgram(findExe("bash"), @[
    "--rcfile", c.homeDir / ".bashrc", "-i", "-c",
    posixProbeScript(c.projectA, c.projectB)
  ], c.tempRoot, env)
  check res.exitCode == 0
  requireShellValue(res.output, "A:",
    "A:alpha|one|" & c.projectA & "|tool:alpha:one")
  requireShellValue(res.output, "B:",
    "B:beta|two|" & c.projectB & "|tool:beta:two")
  requireShellValue(res.output, "OUT:", "OUT:unset|unset|unset")
  requireShellValue(res.output, "A2:",
    "A2:alpha|one|" & c.projectA & "|tool:alpha:one")
  requireNativeStats(statsPath)

proc requireZshHook(c: M6Case) =
  let zsh = findExe("zsh")
  if zsh.len == 0:
    raise newException(OSError,
      "M6 native shell gate requires a real zsh binary on PATH")
  let env = c.envFor()
  let statsPath = c.tempRoot / "zsh-native-stats.json"
  env["REPRO_NATIVE_SHELL_STATS"] = statsPath
  env["REPROBUILD_REPRO"] = reproPathWithSpaces(c)
  let res = runProgram(zsh, @["-i", "-c", posixProbeScript(c.projectA,
    c.projectB)], c.tempRoot, env)
  check res.exitCode == 0
  requireShellValue(res.output, "A:",
    "A:alpha|one|" & c.projectA & "|tool:alpha:one")
  requireShellValue(res.output, "B:",
    "B:beta|two|" & c.projectB & "|tool:beta:two")
  requireShellValue(res.output, "OUT:", "OUT:unset|unset|unset")
  requireShellValue(res.output, "A2:",
    "A2:alpha|one|" & c.projectA & "|tool:alpha:one")
  requireNativeStats(statsPath)

proc requireFishHook(c: M6Case; fish: string) =
  let env = c.envFor()
  let statsPath = c.tempRoot / "fish-native-stats.json"
  env["REPRO_NATIVE_SHELL_STATS"] = statsPath
  let res = runProgram(fish, @["-i", "-c", fishProbeScript(c.projectA,
    c.projectB)], c.tempRoot, env)
  check res.exitCode == 0
  requireShellValue(res.output, "A:",
    "A:alpha|one|" & c.projectA & "|tool:alpha:one")
  requireShellValue(res.output, "B:",
    "B:beta|two|" & c.projectB & "|tool:beta:two")
  requireShellValue(res.output, "OUT:", "OUT:||")
  requireShellValue(res.output, "A2:",
    "A2:alpha|one|" & c.projectA & "|tool:alpha:one")
  requireNativeStats(statsPath)

when isNixSupported:
  suite "e2e_native_shell_hooks":
    when isNixSupported:
      test "e2e_native_shell_hooks_bash_zsh_fish":
        let c = prepareCase("repro-m6-native-shells")
        defer: removeDir(c.tempRoot)
        let fish = requireFish()

        installNativeHooks(c)
        requireBashHook(c)
        requireZshHook(c)
        requireFishHook(c, fish)

        let bashWithUserBytes = "export USER_OWNED=1\n" & readFile(c.homeDir / ".bashrc")
        writeFile(c.homeDir / ".bashrc", bashWithUserBytes)
        discard requireRepro(c, @["hooks", "uninstall", "--shell", "bash"])
        check readFile(c.homeDir / ".bashrc") == "export USER_OWNED=1\n"

      test "e2e_native_shell_hooks_nix_managed_rc_refused":
        let c = prepareCase("repro-m6-native-nix-rc")
        defer: removeDir(c.tempRoot)

        let storeDir = c.tempRoot / "nix" / "store" / "fake-home-manager"
        createDir(storeDir)
        let storeRc = storeDir / "bashrc"
        let storeBytes = "# managed by home-manager\n"
        writeFile(storeRc, storeBytes)
        setFilePermissions(storeRc, {fpUserRead, fpGroupRead, fpOthersRead})
        createSymlink(storeRc, c.homeDir / ".bashrc")

        let res = runRepro(c, @["hooks", "ensure", "--shell", "bash"])
        check res.exitCode != 0
        check res.output.contains("Nix-managed symlink")
        check res.output.contains("home-switch")
        check symlinkExists(c.homeDir / ".bashrc")
        check expandSymlink(c.homeDir / ".bashrc") == storeRc
        check readFile(storeRc) == storeBytes

    when defined(windows):
      test "e2e_native_shell_hooks_powershell":
        let c = prepareCase("repro-m6-native-powershell")
        defer: removeDir(c.tempRoot)
        let pwsh =
          if findExe("pwsh").len > 0: findExe("pwsh") else: findExe("powershell")
        if pwsh.len == 0:
          raise newException(OSError,
            "M6 PowerShell gate requires a real PowerShell binary")
        discard requireRepro(c, @["hooks", "ensure", "--shell", "powershell"])
        let env = c.envFor()
        let statsPath = c.tempRoot / "powershell-native-stats.json"
        env["REPRO_NATIVE_SHELL_STATS"] = statsPath
        let script =
          "cd " & psQuote(c.projectA) & "; " &
          "Write-Output \"A:$env:AUX_VALUE|$env:FIXTURE_MODE|$env:REPRO_DEV_ENV_PROJECT_ROOT\"; " &
          "cd " & psQuote(parentDir(c.projectA)) & "; " &
          "Write-Output \"OUT:$env:AUX_VALUE|$env:FIXTURE_MODE|$env:REPRO_DEV_ENV_PROJECT_ROOT\""
        let res = runProgram(pwsh, @["-NoLogo", "-Command", script],
          c.tempRoot, env)
        check res.exitCode == 0
        requireShellValue(res.output, "A:",
          "A:alpha|one|" & c.projectA)
        requireShellValue(res.output, "OUT:", "OUT:||")
        requireNativeStats(statsPath)

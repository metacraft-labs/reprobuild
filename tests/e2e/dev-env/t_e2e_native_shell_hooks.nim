from repro_core/process_streams import drainStream
import std/[json, os, osproc, sequtils, strtabs, streams, strutils, tempfiles,
    unittest]

import repro_core/cli_images
import repro_test_support
when defined(windows):
  import repro_test_support/real_file_guard

proc q(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

when defined(windows):
  proc psQuote(value: string): string =
    "'" & value.replace("'", "''") & "'"

  proc windowsDocumentsFromPowerShell(pwsh: string): string =
    ## The Documents folder as Windows reports it, asked of PowerShell
    ## itself (not computed by the code under test).
    let res = execCmdEx(quoteShellCommand([pwsh, "-NoProfile",
      "-NonInteractive", "-Command",
      "[Environment]::GetFolderPath('MyDocuments')"]))
    doAssert res.exitCode == 0 and res.output.strip().len > 0, res.output
    res.output.strip()

# prepareMonitorTools is exported from libs/repro_test_support and now
# threads the ct_interpose source path through the Windows shim build.

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
    "  defaultToolProvisioning \"path\"\n" &
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
    monitorCliPath: string
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
  createDir(result.tempRoot / "runtime-libs")
  writeFixture(result.projectA, "one", "alpha")
  writeFixture(result.projectB, "two", "beta")
  result.reproBin = reproBinary()
  # The on-disk monitor shim path is only consumed by Linux/macOS
  # tests (REPRO_MONITOR_SHIM_LIB plumbing). The Windows shim build
  # depends on ct_interpose sources that ``prepareMonitorTools`` here
  # doesn't know how to wire; the Windows PowerShell hook test path itself is
  # gated below via ``when defined(windows):`` so it never reaches the
  # shim fields. Setting up monitor/shim paths is therefore only
  # meaningful on platforms where the full io-monitor integration is
  # also available — gate via ``isIoMonitorSupported`` like the rest
  # of the dev-env suite.
  when isIoMonitorSupported:
    let monitor = prepareMonitorTools(result.repoRoot, result.tempRoot,
      "m6-native-shell-hooks")
    result.monitorCliPath = monitor.monitorCliPath
    result.shim = monitor.shim

proc envFor(c: M6Case): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if key.startsWith("__REPRO_"):
      continue
    # The invoking shell's own direnv state must not leak in: the native
    # hook reads DIRENV_DIR to stand down.
    if key.startsWith("DIRENV_"):
      continue
    result[key] = value
  result["HOME"] = c.homeDir
  result["USERPROFILE"] = c.homeDir
  result["ZDOTDIR"] = c.homeDir
  result["XDG_CONFIG_HOME"] = c.xdgConfig
  result["XDG_CACHE_HOME"] = c.tempRoot / "xdg-cache"
  result["XDG_DATA_HOME"] = c.tempRoot / "xdg-data"
  result["REPROBUILD_SOURCE_ROOT"] = c.repoRoot
  result["REPROBUILD_ACTION_CACHE_ROOT"] = c.tempRoot / "action-cache"
  result["REPRO_DEV_ENV_AUTO_ALLOW"] = "1"
  result["REPRO_DAEMON"] = "off"
  result["REPRO_DAEMON_ENDPOINT"] =
    daemonSocketEndpoint("repro-m6-native-shell-hooks-" &
      $getCurrentProcessId() & "-" & c.tempRoot.extractFilename)
  result["REPRO_DAEMON_STATE_DIR"] = c.tempRoot / "daemon-state"
  result["REPROBUILD_REPRO"] = c.reproBin
  result["REPRO_MONITOR_SHIM_LIB"] = c.shim
  # Exercise the monitored-direct runtime-loader deferral regardless of the
  # caller's environment. Keep any real caller paths after the fixture path so
  # Nix-built binaries still find their required runtime libraries.
  result["LD_LIBRARY_PATH"] = c.tempRoot / "runtime-libs" &
    (if existsEnv("LD_LIBRARY_PATH"):
      $PathSep & getEnv("LD_LIBRARY_PATH") else: "")
  result["PATH"] = parentDir(c.reproBin) & $PathSep & getEnv("PATH")
  createDir(result["XDG_CACHE_HOME"])
  createDir(result["XDG_DATA_HOME"])
  createDir(result["REPROBUILD_ACTION_CACHE_ROOT"])
  createDir(result["REPRO_DAEMON_STATE_DIR"])

proc runProgram(program: string; args: openArray[string]; cwd: string;
                env: StringTableRef = nil): tuple[exitCode: int; output: string] =
  var process = startProcess(program,
    args = @args,
    workingDir = cwd,
    env = env,
    options = {poUsePath, poStdErrToStdOut})
  let output =
    if process.outputStream != nil: drainStream(process.outputStream)
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
      if line != expected:
        raise newException(OSError,
          "unexpected shell marker " & prefix & "\nexpected: " & expected &
            "\nactual: " & line & "\noutput:\n" & output)
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
  ## A relocated ``repro`` install whose directory contains spaces, so the
  ## rendered hooks are proven to quote the path they invoke.
  ##
  ## ``repro`` is the thin daemon client: everything it does not route to the
  ## daemon -- including ``__repro-native-shell-activate`` -- it ``execv``s to
  ## the ENGINE image, which it resolves as a sibling in its OWN directory
  ## (``resolveFullCli`` in ``apps/repro-client/repro_client.nim``). An
  ## install is therefore the PAIR, and relocating the client alone produces
  ## a ``repro`` that can only print "no reprobuild image to fall back to".
  ## Both images are copied, not symlinked: the client names its directory
  ## through ``getAppFilename``, which resolves a symlink back to
  ## ``build/bin`` and would silently stop exercising the spaced path.
  let dir = c.tempRoot / "bin with spaces"
  createDir(dir)
  result = dir / addFileExt("repro", ExeExt)
  let engineSrc = parentDir(c.reproBin) / reprobuildEngineExeName()
  let engineDst = dir / reprobuildEngineExeName()
  for (src, dst) in [(c.reproBin, result), (engineSrc, engineDst)]:
    if not fileExists(dst):
      copyFile(src, dst)
      setFilePermissions(dst, {fpUserRead, fpUserWrite, fpUserExec,
        fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc installNativeHooks(c: M6Case) =
  discard requireRepro(c, @["hooks", "ensure", "--shell", "bash"])
  discard requireRepro(c, @["hooks", "ensure", "--shell", "zsh"])
  discard requireRepro(c, @["hooks", "ensure", "--shell", "fish"])
  check readFile(c.homeDir / ".bashrc").contains(
    "repro:home:repro-dev-env-native-bash")
  check readFile(c.homeDir / ".zshrc").contains(
    "repro:home:repro-dev-env-native-zsh")
  check readFile(c.xdgConfig / "fish" / "config.fish").contains(
    "repro:home:repro-dev-env-native-fish")
  check "__repro-native-shell-activate" in readFile(c.homeDir / ".bashrc")
  check "__repro-native-shell-activate" in readFile(c.homeDir / ".zshrc")
  check "__repro-native-shell-activate" in
    readFile(c.xdgConfig / "fish" / "config.fish")

proc posixProbeScript(projectA, projectB: string): string =
  # PATHRESTORED: leaving every project must give back the PATH the shell
  # started with. Checked explicitly because the OUT line cannot see PATH:
  # an unload that removes nothing leaves the prepended entries behind, one
  # more copy per activation, and nothing else in this probe notices.
  "__repro_probe_path0=$PATH\n" &
    "cd " & q(projectA) & "\n" &
    "printf 'A:%s|%s|%s|%s\\n' \"$AUX_VALUE\" \"$FIXTURE_MODE\" \"$REPRO_DEV_ENV_PROJECT_ROOT\" \"$(fixture-tool)\"\n" &
    "cd " & q(projectB) & "\n" &
    "printf 'B:%s|%s|%s|%s\\n' \"$AUX_VALUE\" \"$FIXTURE_MODE\" \"$REPRO_DEV_ENV_PROJECT_ROOT\" \"$(fixture-tool)\"\n" &
    "cd " & q(parentDir(projectA)) & "\n" &
    "printf 'OUT:%s|%s|%s\\n' \"${AUX_VALUE-unset}\" \"${FIXTURE_MODE-unset}\" \"${REPRO_DEV_ENV_PROJECT_ROOT-unset}\"\n" &
    "if [ \"$PATH\" = \"$__repro_probe_path0\" ]; then echo PATHRESTORED:yes; else printf 'PATHRESTORED:no:%s\\n' \"$PATH\"; fi\n" &
    "cd " & q(projectA) & "\n" &
    "printf 'A2:%s|%s|%s|%s\\n' \"$AUX_VALUE\" \"$FIXTURE_MODE\" \"$REPRO_DEV_ENV_PROJECT_ROOT\" \"$(fixture-tool)\"\n"

proc fishProbeScript(projectA, projectB: string): string =
  # PATHRESTORED: see ``posixProbeScript``. Both sides are joined with
  # ``string join``: fish joins a quoted PATH with ":" but a quoted list
  # whose name does not end in PATH with spaces, so comparing the two
  # quoted variables directly could never be equal.
  "set -g __repro_probe_path0 (string join : $PATH)\n" &
    "cd " & q(projectA) & "\n" &
    "printf 'A:%s|%s|%s|%s\\n' \"$AUX_VALUE\" \"$FIXTURE_MODE\" \"$REPRO_DEV_ENV_PROJECT_ROOT\" (fixture-tool)\n" &
    "cd " & q(projectB) & "\n" &
    "printf 'B:%s|%s|%s|%s\\n' \"$AUX_VALUE\" \"$FIXTURE_MODE\" \"$REPRO_DEV_ENV_PROJECT_ROOT\" (fixture-tool)\n" &
    "cd " & q(parentDir(projectA)) & "\n" &
    "printf 'OUT:%s|%s|%s\\n' \"$AUX_VALUE\" \"$FIXTURE_MODE\" \"$REPRO_DEV_ENV_PROJECT_ROOT\"\n" &
    "if test (string join : $PATH) = \"$__repro_probe_path0\"; echo PATHRESTORED:yes; else; printf 'PATHRESTORED:no:%s\\n' \"$PATH\"; end\n" &
    "cd " & q(projectA) & "\n" &
    "printf 'A2:%s|%s|%s|%s\\n' \"$AUX_VALUE\" \"$FIXTURE_MODE\" \"$REPRO_DEV_ENV_PROJECT_ROOT\" (fixture-tool)\n"

proc requireBashHook(c: M6Case) =
  let env = c.envFor()
  let statsPath = c.tempRoot / "bash-native-stats.json"
  env["REPRO_NATIVE_SHELL_STATS"] = statsPath
  env["REPROBUILD_REPRO"] = reproPathWithSpaces(c)
  let res = runProgram(findExe("bash"), @[
    "--noprofile", "--norc", "-c",
    "source " & q(c.homeDir / ".bashrc") & "\n" &
      posixProbeScript(c.projectA, c.projectB)
  ], c.tempRoot, env)
  check res.exitCode == 0
  requireShellValue(res.output, "A:",
    "A:alpha|one|" & c.projectA & "|tool:alpha:one")
  requireShellValue(res.output, "B:",
    "B:beta|two|" & c.projectB & "|tool:beta:two")
  requireShellValue(res.output, "OUT:", "OUT:unset|unset|unset")
  requireShellValue(res.output, "PATHRESTORED:", "PATHRESTORED:yes")
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
  let res = runProgram(zsh, @["-f", "-c",
    "source " & q(c.homeDir / ".zshrc") & "\n" &
      posixProbeScript(c.projectA, c.projectB)], c.tempRoot, env)
  check res.exitCode == 0
  requireShellValue(res.output, "A:",
    "A:alpha|one|" & c.projectA & "|tool:alpha:one")
  requireShellValue(res.output, "B:",
    "B:beta|two|" & c.projectB & "|tool:beta:two")
  requireShellValue(res.output, "OUT:", "OUT:unset|unset|unset")
  requireShellValue(res.output, "PATHRESTORED:", "PATHRESTORED:yes")
  requireShellValue(res.output, "A2:",
    "A2:alpha|one|" & c.projectA & "|tool:alpha:one")
  requireNativeStats(statsPath)

proc requireFishHook(c: M6Case; fish: string) =
  let env = c.envFor()
  let statsPath = c.tempRoot / "fish-native-stats.json"
  env["REPRO_NATIVE_SHELL_STATS"] = statsPath
  let res = runProgram(fish, @["--no-config", "-c",
    "source " & q(c.xdgConfig / "fish" / "config.fish") & "\n" &
      fishProbeScript(c.projectA, c.projectB)], c.tempRoot, env)
  check res.exitCode == 0
  requireShellValue(res.output, "A:",
    "A:alpha|one|" & c.projectA & "|tool:alpha:one")
  requireShellValue(res.output, "B:",
    "B:beta|two|" & c.projectB & "|tool:beta:two")
  requireShellValue(res.output, "OUT:", "OUT:||")
  requireShellValue(res.output, "PATHRESTORED:", "PATHRESTORED:yes")
  requireShellValue(res.output, "A2:",
    "A2:alpha|one|" & c.projectA & "|tool:alpha:one")
  requireNativeStats(statsPath)


# ---------------------------------------------------------------------------
# Standing down for direnv (a bare `repro hooks ensure` installs both the
# direnv `.envrc` block and the native hook; in a directory direnv manages
# the native hook does nothing).
# ---------------------------------------------------------------------------

proc requireDirenv(): string =
  result = findExe("direnv")
  if result.len == 0:
    raise newException(OSError,
      "the direnv stand-down gate requires a real direnv binary on PATH")

proc direnvEnv(c: M6Case): StringTableRef =
  result = c.envFor()
  result["DIRENV_LOG_FORMAT"] = ""

proc prepareDirenvProjects(c: M6Case; direnv: string) =
  ## project-a: the generated `.envrc`, allowed, so direnv manages it.
  ## project-b: the same `.envrc`, NOT allowed, so direnv loads nothing there
  ## and the native hook must activate.
  for project in [c.projectA, c.projectB]:
    discard requireRepro(c, @["hooks", "ensure", "--shell-direnv", project])
    check "__repro-direnv-activate" in readFile(project / ".envrc")
  let res = runProgram(direnv, @["allow", "."], c.projectA, c.direnvEnv())
  if res.exitCode != 0:
    raise newException(OSError, "direnv allow failed: " & res.output)

proc posixStandDownProbe(c: M6Case; shell, direnv: string): string =
  ## Loads direnv's hook, then the native block, then visits project-a
  ## (direnv's), project-b (blocked `.envrc`: native) and leaves.
  let hook = "eval \"$(" & q(direnv) & " hook " & shell & ")\"\n"
  let rc = if shell == "zsh": c.homeDir / ".zshrc" else: c.homeDir / ".bashrc"
  let count = "printf '%s' \"$PATH\" | tr ':' '\\n' | grep -c 'tools/bin$'"
  hook & "source " & q(rc) & "\n" &
    "__repro_probe_path0=$PATH\n" &
    "cd " & q(c.projectA) & "\n" &
    "printf 'DA:%s|%s|%s|%s|%s\\n' \"$AUX_VALUE\" \"$FIXTURE_MODE\" \"${DIRENV_DIR-unset}\" \"$(" & count & ")\" \"$(fixture-tool)\"\n" &
    "printf 'DASTATS:%s\\n' \"$(test -e \"$REPRO_NATIVE_SHELL_STATS\" && echo native || echo none)\"\n" &
    "cd " & q(c.projectB) & "\n" &
    "printf 'NB:%s|%s|%s|%s|%s\\n' \"$AUX_VALUE\" \"$FIXTURE_MODE\" \"${DIRENV_DIR-unset}\" \"$(" & count & ")\" \"$(fixture-tool)\"\n" &
    "cd " & q(parentDir(c.projectA)) & "\n" &
    "printf 'OUT:%s|%s|%s\\n' \"${AUX_VALUE-unset}\" \"${FIXTURE_MODE-unset}\" \"${DIRENV_DIR-unset}\"\n" &
    "if [ \"$PATH\" = \"$__repro_probe_path0\" ]; then echo PATHRESTORED:yes; else printf 'PATHRESTORED:no:%s\\n' \"$PATH\"; fi\n"

proc fishStandDownProbe(c: M6Case; direnv: string): string =
  let count = "(count (string match -- '*tools/bin' $PATH))"
  q(direnv) & " hook fish | source\n" &
    "source " & q(c.xdgConfig / "fish" / "config.fish") & "\n" &
    "set -g __repro_probe_path0 (string join : $PATH)\n" &
    "cd " & q(c.projectA) & "\n" &
    "printf 'DA:%s|%s|%s|%s|%s\\n' \"$AUX_VALUE\" \"$FIXTURE_MODE\" \"$DIRENV_DIR\" " & count & " (fixture-tool)\n" &
    "if test -e \"$REPRO_NATIVE_SHELL_STATS\"; echo DASTATS:native; else; echo DASTATS:none; end\n" &
    "cd " & q(c.projectB) & "\n" &
    "printf 'NB:%s|%s|%s|%s|%s\\n' \"$AUX_VALUE\" \"$FIXTURE_MODE\" \"$DIRENV_DIR\" " & count & " (fixture-tool)\n" &
    "cd " & q(parentDir(c.projectA)) & "\n" &
    "printf 'OUT:%s|%s|%s\\n' \"$AUX_VALUE\" \"$FIXTURE_MODE\" \"$DIRENV_DIR\"\n" &
    "if test (string join : $PATH) = \"$__repro_probe_path0\"; echo PATHRESTORED:yes; else; printf 'PATHRESTORED:no:%s\\n' \"$PATH\"; end\n"

proc requireStandDown(c: M6Case; shell, program: string;
                      args: seq[string]; unset: string) =
  ## In project-a direnv activates once and the native hook writes no stats;
  ## in project-b (blocked `.envrc`) the native hook activates; leaving
  ## restores PATH.
  let env = c.direnvEnv()
  let nativeStats = c.tempRoot / (shell & "-standdown-native-stats.json")
  let direnvStats = c.tempRoot / (shell & "-standdown-direnv-stats.json")
  env["REPRO_NATIVE_SHELL_STATS"] = nativeStats
  env["REPRO_DIRENV_STATS"] = direnvStats
  let res = runProgram(program, args, c.tempRoot, env)
  checkpoint(shell & " stand-down probe:\n" & res.output)
  check res.exitCode == 0
  # Activated once, by direnv: its values, ONE tools/bin on PATH, direnv's
  # stats written and the native hook's not.
  requireShellValue(res.output, "DA:",
    "DA:alpha|one|-" & c.projectA & "|1|tool:alpha:one")
  requireShellValue(res.output, "DASTATS:", "DASTATS:none")
  check fileExists(direnvStats)
  # A blocked `.envrc` activates nothing, so the native hook does. direnv
  # still sets DIRENV_DIR for it (the blocked directory), which is why the
  # stand-down also asks `direnv status` whether that RC is allowed.
  requireShellValue(res.output, "NB:",
    "NB:beta|two|-" & c.projectB & "|1|tool:beta:two")
  check fileExists(nativeStats)
  if fileExists(nativeStats):
    let stats = parseJson(readFile(nativeStats))
    check stats["command"].getStr() == "hooks shell-native"
  requireShellValue(res.output, "OUT:",
    "OUT:" & unset & "|" & unset & "|" & unset)
  requireShellValue(res.output, "PATHRESTORED:", "PATHRESTORED:yes")

proc direnvLoadedVars(c: M6Case; direnv, project: string):
    seq[tuple[name, value: string]] =
  ## What a real direnv exports once it has loaded `project`'s `.envrc`:
  ## `DIRENV_FILE` and `DIRENV_WATCHES`, the two variables `direnv status`
  ## reads to describe the loaded RC (`LoadedRC` in direnv's
  ## `internal/cmd/config.go`). Read from `direnv export json`, stdout only
  ## (the `.envrc`'s own diagnostics go to stderr).
  var process = startProcess(direnv, args = @["export", "json"],
    workingDir = project, env = c.direnvEnv(), options = {poUsePath})
  let output = drainStream(process.outputStream)
  let code = process.waitForExit()
  process.close()
  if code != 0 or output.strip().len == 0:
    raise newException(OSError, "direnv export json failed in " & project &
      " (exit " & $code & "):\n" & output)
  let exported = parseJson(output)
  for name in ["DIRENV_FILE", "DIRENV_WATCHES"]:
    if not exported.hasKey(name) or exported[name].kind != JString:
      raise newException(OSError, "direnv export json set no " & name &
        " in " & project & ":\n" & output)
    result.add((name: name, value: exported[name].getStr()))

proc pathWithout(c: M6Case; exe, path: string): string =
  ## `path` with every directory that holds `exe` replaced by a directory of
  ## links to everything else in it, so `exe` alone is missing.
  var dirs: seq[string]
  for dir in path.split(PathSep):
    if dir.len > 0 and fileExists(dir / exe):
      let farm = c.tempRoot / ("path-without-" & exe & "-" & $dirs.len)
      createDir(farm)
      for _, entry in walkDir(dir):
        let name = entry.extractFilename
        if name != exe and not symlinkExists(farm / name):
          createSymlink(entry, farm / name)
      dirs.add(farm)
    else:
      dirs.add(dir)
  dirs.join($PathSep)

proc requireHelperStandsDown(c: M6Case; shell: string;
                             loaded: seq[tuple[name, value: string]];
                             withoutDirenvPath = "") =
  ## The activation helper itself, as every template runs it. It stands down
  ## (prints nothing) only when BOTH halves hold: `DIRENV_DIR` names the
  ## directory or an ancestor, and `direnv status` reports the loaded RC
  ## allowed. `loaded` is what a real direnv exported for project-a's
  ## allowed `.envrc` (empty where no direnv drives the case: then nothing
  ## is loaded and no case stands down). `withoutDirenvPath`, when given, is
  ## a `PATH` with no direnv on it, for the case where `direnv status`
  ## cannot be run.
  type HelperCase = tuple[direnvDir, cwd: string; withLoaded: bool;
                          path: string; standsDown: bool]
  let canStand = loaded.len > 0
  var cases: seq[HelperCase] = @[
    ("-" & c.projectA, c.projectA, true, "", canStand),
    ("-" & c.projectA, c.projectA / "tools", true, "", canStand),
    ("-" & parentDir(c.projectA), c.projectA, true, "", canStand),
    ("-" & c.projectB, c.projectA, true, "", false),
    # "project" is a string prefix of "project-a", not an ancestor.
    ("-" & c.tempRoot / "project", c.projectA, true, "", false),
    # DIRENV_DIR alone, with no RC loaded (as a shell that inherited it
    # carries it): direnv does not confirm anything, so the hook activates.
    ("-" & c.projectA, c.projectA, false, "", false)]
  if withoutDirenvPath.len > 0:
    # direnv is not on PATH: `direnv status` cannot be run, so the hook
    # activates even with an allowed RC described.
    cases.add(("-" & c.projectA, c.projectA, true, withoutDirenvPath, false))
  for (direnvDir, cwd, withLoaded, path, standsDown) in cases:
    let env = c.direnvEnv()
    env["DIRENV_DIR"] = direnvDir
    if withLoaded:
      for (name, value) in loaded:
        env[name] = value
    if path.len > 0:
      env["PATH"] = path
    var process = startProcess(c.reproBin,
      args = @["__repro-native-shell-activate", cwd, "--shell", shell],
      workingDir = c.repoRoot, env = env, options = {poUsePath})
    let output = drainStream(process.outputStream)
    let code = process.waitForExit()
    process.close()
    checkpoint(shell & " DIRENV_DIR=" & direnvDir & " cwd=" & cwd &
      " loaded=" & $withLoaded & " path=" & path & ":\n" & output)
    check code == 0
    if standsDown:
      check output.len == 0
    else:
      check "AUX_VALUE" in output

# The suite also runs on Windows, for its PowerShell case (the other cases
# are gated on Nix inside it); until it did, that case never ran anywhere.
when isNixSupported or defined(windows):
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

      test "e2e_native_shell_hooks_stand_down_where_direnv_manages":
        # Both cases of the stand-down, in each shell direnv supports: a
        # directory direnv manages is activated once, by direnv, the native
        # hook doing nothing; a directory direnv does not manage (its
        # `.envrc` blocked) is activated by the native hook.
        let c = prepareCase("repro-m7b-native-direnv")
        defer: removeDir(c.tempRoot)
        let fish = requireFish()
        let direnv = requireDirenv()
        installNativeHooks(c)
        prepareDirenvProjects(c, direnv)
        let loaded = c.direnvLoadedVars(direnv, c.projectA)
        requireHelperStandsDown(c, "bash", loaded,
          c.pathWithout("direnv", c.envFor()["PATH"]))
        c.requireStandDown("bash", findExe("bash"), @["--noprofile",
          "--norc", "-c", posixStandDownProbe(c, "bash", direnv)], "unset")
        let zsh = findExe("zsh")
        if zsh.len == 0:
          raise newException(OSError,
            "the direnv stand-down gate requires a real zsh binary on PATH")
        c.requireStandDown("zsh", zsh, @["-f", "-c",
          posixStandDownProbe(c, "zsh", direnv)], "unset")
        c.requireStandDown("fish", fish, @["--no-config", "-c",
          fishStandDownProbe(c, direnv)], "")
        # Each shell's direnv run activated project-a and each native run
        # project-b: both kinds of statistics are there for every shell.
        for shell in ["bash", "zsh", "fish"]:
          check fileExists(c.tempRoot / (shell & "-standdown-direnv-stats.json"))
          check fileExists(c.tempRoot / (shell & "-standdown-native-stats.json"))

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
        # `hooks ensure --shell powershell` writes the profile under the
        # Documents folder Windows reports, which no environment variable
        # redirects: this leg WRITES THE INVOKING USER'S REAL PowerShell
        # profiles, saved to an on-disk journal first and restored after
        # (`repro_test_support/real_file_guard`).
        let c = prepareCase("repro-m6-native-powershell")
        defer: removeDir(c.tempRoot)
        let pwsh =
          if findExe("pwsh").len > 0: findExe("pwsh") else: findExe("powershell")
        if pwsh.len == 0:
          raise newException(OSError,
            "M6 PowerShell gate requires a real PowerShell binary")
        let docs = windowsDocumentsFromPowerShell(pwsh)
        withRealFilesSaved([docs / "PowerShell" / "Profile.ps1",
            docs / "PowerShell" / "Microsoft.PowerShell_profile.ps1",
            docs / "WindowsPowerShell" / "Profile.ps1",
            docs / "WindowsPowerShell" / "Microsoft.PowerShell_profile.ps1"],
            defaultRealFilesJournal("native-shell-hooks-powershell-profiles")):
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
          # DIRENV_DIR alone (no RC that direnv reports loaded and allowed)
          # does not stand the hook down: it activates as before.
          let aloneStats = c.tempRoot / "powershell-direnv-dir-alone-stats.json"
          let aloneEnv = c.envFor()
          aloneEnv["REPRO_NATIVE_SHELL_STATS"] = aloneStats
          aloneEnv["DIRENV_DIR"] = "-" & c.projectA
          let alone = runProgram(pwsh, @["-NoLogo", "-Command", script],
            c.tempRoot, aloneEnv)
          checkpoint(alone.output)
          check alone.exitCode == 0
          requireShellValue(alone.output, "A:", "A:alpha|one|" & c.projectA)
          check fileExists(aloneStats)
          requireHelperStandsDown(c, "powershell", @[])
          discard requireRepro(c, @["hooks", "uninstall", "--shell",
            "powershell"])

from repro_core/process_streams import drainStream
import std/[hashes, json, os, osproc, sequtils, strtabs, streams, strutils,
    tempfiles, unittest]
import repro_core/process_env

import repro_core/cli_images
import repro_test_support
when defined(posix):
  import repro_test_support/terminal_fixtures
when defined(windows):
  import repro_test_support/real_file_guard

proc q(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

when defined(windows):
  proc psQuote(value: string): string =
    "'" & value.replace("'", "''") & "'"

  proc windowsDocumentsFromPowerShell(pwsh: string;
                                      env: StringTableRef): string =
    ## The Documents folder as Windows reports it, asked of PowerShell
    ## itself (not computed by the code under test), in `env`: the case's
    ## environment, whose redirected `USERPROFILE` moves the folder when the
    ## registry value is `%USERPROFILE%\Documents` (the default), for repro
    ## and for the PowerShell the case starts alike.
    var process = startProcess(pwsh, args = ["-NoProfile",
      "-NonInteractive", "-Command",
      "[Environment]::GetFolderPath('MyDocuments')"], env = env,
      options = {poUsePath, poStdErrToStdOut})
    let output = drainStream(process.outputStream)
    let code = process.waitForExit()
    process.close()
    doAssert code == 0 and output.strip().len > 0, output
    output.strip()

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
  when defined(windows):
    # The Documents folder every Windows user profile has. Both repro's
    # `SHGetFolderPathW` and `[Environment]::GetFolderPath('MyDocuments')`
    # verify that the folder exists and report nothing when it does not;
    # with it present they resolve it through the same verified call, so
    # `windowsDocumentsFromPowerShell` names the folder repro writes to.
    createDir(result.homeDir / "Documents")
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
  result = newEnvTable()
  for key, value in inheritedEnvTable():
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

proc holds(verdict: var bool; condition: bool; what: string) =
  ## Records a failed condition of a helper that returns its verdict to the
  ## test body: a checkpoint naming it, and `verdict` false. A `check` in a
  ## proc called from a test would fail only the program's exit status (its
  ## `fail` sees no test status to set), not the case it ran in, so the
  ## helpers return a verdict and the test body checks it.
  if not condition:
    checkpoint("FAILED: " & what)
    verdict = false

proc nativeStatsDecision(statsPath, label: string): string =
  ## What decided whether each edge of one activation re-ran, from the
  ## statistics file the native hook wrote (`--dev-env-stats`): per action its
  ## status, the cache decision, why the lookup missed, why no record was
  ## published, and the evidence diagnostics (an entropy refusal, a monitor
  ## gap). A failed warm check prints this, so a run on a host the suite
  ## cannot reproduce (Windows) says which input or refusal made the edge
  ## re-run instead of only that it did.
  result = "decision of " & label & " (" & statsPath & "):"
  if not fileExists(statsPath):
    return result & " no statistics file was written"
  let stats =
    try: parseJson(readFile(statsPath))
    except CatchableError as err:
      return result & " unreadable: " & err.msg
  if stats.hasKey("stats"):
    result.add("\n  stats: " & $stats["stats"])
  for key in ["providerCompileAction", "introspectionAction",
              "shellRenderAction"]:
    if not stats.hasKey(key) or stats[key].kind != JObject:
      result.add("\n  " & key & ": absent")
      continue
    let a = stats[key]
    proc field(name: string): string =
      if a.hasKey(name): $a[name] else: "-"
    result.add("\n  " & key & ": status=" & field("status") &
      " launched=" & field("launched") &
      " cacheDecision=" & field("cacheDecision") &
      "\n    cacheMissReason=" & field("cacheMissReason") &
      "\n    cachePublishSkipReason=" & field("cachePublishSkipReason") &
      "\n    reason=" & field("reason"))
    if a.hasKey("evidence") and a["evidence"].kind == JObject:
      let e = a["evidence"]
      for channel in ["declaredInputs", "monitorReads", "monitorProbes"]:
        if e.hasKey(channel) and e[channel].kind == JArray:
          result.add("\n    " & channel & ": " & $e[channel].len & " path(s)")
      if e.hasKey("diagnostics") and e["diagnostics"].kind == JArray:
        for d in e["diagnostics"]:
          result.add("\n    diagnostic: " & d.getStr())

proc redactedKeyInput(line: string): string =
  ## One line of a determinism-probe `.inputs` record, safe to print. Paths
  ## and content digests are printed as they are; an environment line
  ## (`NAME=<present>:<value>`, the engine's spelling) keeps its name and
  ## presence but shows the value only as its length and hash. The test
  ## environment inherits the invoking host's, so a keyed variable could hold
  ## a credential; the hash still shows which variable moved between two
  ## records, which is all the comparison needs.
  let eq = line.find('=')
  if eq <= 0 or line[0] notin IdentStartChars or
      not line[0 ..< eq].allCharsInSet(IdentChars):
    return line
  let colon = line.find(':', eq + 1)
  if colon < 0 or line[eq + 1 ..< colon] notin ["true", "false"]:
    return line
  let value = line[colon + 1 .. ^1]
  line[0 .. colon] & "<" & $value.len & " chars, hash " &
    toHex(hash(value).int64) & ">"

proc determinismProbeReport(projectRoot: string): string =
  ## The engine's determinism-probe records under the project's dev-env
  ## state. One is written only for an action refused publication solely
  ## for unblessed entropy (`determinismProbeAdmits`): its first line is the
  ## verdict (`candidate`, `verified`, `nondeterministic`), and its
  ## `.inputs` sibling lists what the key was made of, so two records for one
  ## action name the input that moved between two runs. Environment values
  ## are redacted (`redactedKeyInput`).
  result = "determinism-probe records under " & projectRoot / ".repro" & ":"
  var found = false
  if dirExists(projectRoot / ".repro"):
    for path in walkDirRec(projectRoot / ".repro"):
      if path.parentDir.extractFilename != "determinism-probe":
        continue
      found = true
      let text =
        try: readFile(path)
        except CatchableError as err: "<unreadable: " & err.msg & ">"
      if path.endsWith(".inputs"):
        result.add("\n  " & path & " (key inputs):")
        for line in text.splitLines():
          if line.len > 0:
            result.add("\n    " & redactedKeyInput(line))
      else:
        let verdict = text.splitLines()[0]
        result.add("\n  " & path & ": " & verdict)
  if not found:
    result.add(" none")

proc requireNativeStats(statsPath: string): bool =
  ## The native hook's statistics of a warm activation: no provider
  ## introspection and no shell rendering launched, both served from the
  ## cache, the artifact not rewritten. True when all of that held; when it
  ## did not, the activation's decisions (`nativeStatsDecision`) are printed.
  result = true
  defer:
    if not result:
      checkpoint(nativeStatsDecision(statsPath, "the warm activation"))
  let stats = parseJson(readFile(statsPath))
  result.holds(stats["command"].getStr() == "hooks shell-native",
    statsPath & ": command is " & stats["command"].getStr())
  result.holds(fileExists(stats["artifactPath"].getStr()),
    statsPath & ": no artifact at " & stats["artifactPath"].getStr())
  result.holds(stats["stats"].kind == JObject, statsPath & ": no stats object")
  if stats["stats"].kind == JObject:
    let s = stats["stats"]
    result.holds(not s["providerIntrospectionLaunched"].getBool(),
      statsPath & ": provider introspection was launched")
    result.holds(s["providerIntrospectionCacheHit"].getBool(),
      statsPath & ": provider introspection missed the cache")
    result.holds(s["artifactWriteSkipped"].getBool(),
      statsPath & ": the artifact was rewritten")
    result.holds(not s["shellRenderingLaunched"].getBool(),
      statsPath & ": shell rendering was launched")
    result.holds(s["shellRenderingCacheHit"].getBool(),
      statsPath & ": shell rendering missed the cache")

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
  ##
  ## The engine's graph helper image is copied with them: the engine runs the
  ## activation's introspection and render edges with the
  ## ``reprobuild-helper`` beside its own image, and refuses the activation
  ## when that is missing.
  let dir = c.tempRoot / "bin with spaces"
  createDir(dir)
  result = dir / addFileExt("repro", ExeExt)
  let engineSrc = parentDir(c.reproBin) / reprobuildEngineExeName()
  let engineDst = dir / reprobuildEngineExeName()
  let helperSrc = parentDir(c.reproBin) / reprobuildHelperExeName()
  let helperDst = dir / reprobuildHelperExeName()
  for (src, dst) in [(c.reproBin, result), (engineSrc, engineDst),
                     (helperSrc, helperDst)]:
    if not fileExists(dst):
      copyFile(src, dst)
      setFilePermissions(dst, {fpUserRead, fpUserWrite, fpUserExec,
        fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc installNativeHooks(c: M6Case): bool =
  ## Installs the native block for bash, zsh and fish. True when each rc file
  ## holds its marked block and the activation call.
  result = true
  discard requireRepro(c, @["hooks", "ensure", "--shell", "bash"])
  discard requireRepro(c, @["hooks", "ensure", "--shell", "zsh"])
  discard requireRepro(c, @["hooks", "ensure", "--shell", "fish"])
  for (shell, rc) in [("bash", c.homeDir / ".bashrc"),
                      ("zsh", c.homeDir / ".zshrc"),
                      ("fish", c.xdgConfig / "fish" / "config.fish")]:
    let text = readFile(rc)
    result.holds(text.contains("repro:home:repro-dev-env-native-" & shell),
      rc & " holds no native " & shell & " block")
    result.holds("__repro-native-shell-activate" in text,
      rc & " does not call __repro-native-shell-activate")

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

proc requireBashHook(c: M6Case): bool =
  ## The bash probe: enter A, enter B, leave, re-enter A. True when the exit
  ## code and the warm statistics held (a wrong marker raises).
  result = true
  let env = c.envFor()
  let statsPath = c.tempRoot / "bash-native-stats.json"
  env["REPRO_NATIVE_SHELL_STATS"] = statsPath
  env["REPROBUILD_REPRO"] = reproPathWithSpaces(c)
  let res = runProgram(findExe("bash"), @[
    "--noprofile", "--norc", "-c",
    "source " & q(c.homeDir / ".bashrc") & "\n" &
      posixProbeScript(c.projectA, c.projectB)
  ], c.tempRoot, env)
  result.holds(res.exitCode == 0, "probe exit code " & $res.exitCode &
    ":\n" & res.output)
  requireShellValue(res.output, "A:",
    "A:alpha|one|" & c.projectA & "|tool:alpha:one")
  requireShellValue(res.output, "B:",
    "B:beta|two|" & c.projectB & "|tool:beta:two")
  requireShellValue(res.output, "OUT:", "OUT:unset|unset|unset")
  requireShellValue(res.output, "PATHRESTORED:", "PATHRESTORED:yes")
  requireShellValue(res.output, "A2:",
    "A2:alpha|one|" & c.projectA & "|tool:alpha:one")
  result.holds(requireNativeStats(statsPath), "warm statistics " & statsPath)

proc requireZshHook(c: M6Case): bool =
  ## The zsh probe, as `requireBashHook`.
  result = true
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
  result.holds(res.exitCode == 0, "probe exit code " & $res.exitCode &
    ":\n" & res.output)
  requireShellValue(res.output, "A:",
    "A:alpha|one|" & c.projectA & "|tool:alpha:one")
  requireShellValue(res.output, "B:",
    "B:beta|two|" & c.projectB & "|tool:beta:two")
  requireShellValue(res.output, "OUT:", "OUT:unset|unset|unset")
  requireShellValue(res.output, "PATHRESTORED:", "PATHRESTORED:yes")
  requireShellValue(res.output, "A2:",
    "A2:alpha|one|" & c.projectA & "|tool:alpha:one")
  result.holds(requireNativeStats(statsPath), "warm statistics " & statsPath)

proc requireFishHook(c: M6Case; fish: string): bool =
  ## The fish probe, as `requireBashHook`.
  result = true
  let env = c.envFor()
  let statsPath = c.tempRoot / "fish-native-stats.json"
  env["REPRO_NATIVE_SHELL_STATS"] = statsPath
  let res = runProgram(fish, @["--no-config", "-c",
    "source " & q(c.xdgConfig / "fish" / "config.fish") & "\n" &
      fishProbeScript(c.projectA, c.projectB)], c.tempRoot, env)
  result.holds(res.exitCode == 0, "probe exit code " & $res.exitCode &
    ":\n" & res.output)
  requireShellValue(res.output, "A:",
    "A:alpha|one|" & c.projectA & "|tool:alpha:one")
  requireShellValue(res.output, "B:",
    "B:beta|two|" & c.projectB & "|tool:beta:two")
  requireShellValue(res.output, "OUT:", "OUT:||")
  requireShellValue(res.output, "PATHRESTORED:", "PATHRESTORED:yes")
  requireShellValue(res.output, "A2:",
    "A2:alpha|one|" & c.projectA & "|tool:alpha:one")
  result.holds(requireNativeStats(statsPath), "warm statistics " & statsPath)


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

proc prepareDirenvProjects(c: M6Case; direnv: string): bool =
  ## project-a: the generated `.envrc`, allowed, so direnv manages it.
  ## project-b: the same `.envrc`, NOT allowed, so direnv loads nothing there
  ## and the native hook must activate. True when both `.envrc` files hold
  ## the activation call (a failed `direnv allow` raises).
  result = true
  for project in [c.projectA, c.projectB]:
    discard requireRepro(c, @["hooks", "ensure", "--shell-direnv", project])
    result.holds("__repro-direnv-activate" in readFile(project / ".envrc"),
      project / ".envrc" & " does not call __repro-direnv-activate")
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
                      args: seq[string]; unset: string): bool =
  ## In project-a direnv activates once and the native hook writes no stats;
  ## in project-b (blocked `.envrc`) the native hook activates; leaving
  ## restores PATH. True when all of that held (see `holds`).
  result = true
  let env = c.direnvEnv()
  let nativeStats = c.tempRoot / (shell & "-standdown-native-stats.json")
  let direnvStats = c.tempRoot / (shell & "-standdown-direnv-stats.json")
  env["REPRO_NATIVE_SHELL_STATS"] = nativeStats
  env["REPRO_DIRENV_STATS"] = direnvStats
  let res = runProgram(program, args, c.tempRoot, env)
  checkpoint(shell & " stand-down probe:\n" & res.output)
  result.holds(res.exitCode == 0, shell & " stand-down probe exit code " &
    $res.exitCode)
  # Activated once, by direnv: its values, ONE tools/bin on PATH, direnv's
  # stats written and the native hook's not.
  requireShellValue(res.output, "DA:",
    "DA:alpha|one|-" & c.projectA & "|1|tool:alpha:one")
  requireShellValue(res.output, "DASTATS:", "DASTATS:none")
  result.holds(fileExists(direnvStats), shell & ": direnv wrote no statistics")
  # A blocked `.envrc` activates nothing, so the native hook does. direnv
  # still sets DIRENV_DIR for it (the blocked directory), which is why the
  # stand-down also asks `direnv status` whether that RC is allowed.
  requireShellValue(res.output, "NB:",
    "NB:beta|two|-" & c.projectB & "|1|tool:beta:two")
  result.holds(fileExists(nativeStats), shell &
    ": the native hook wrote no statistics in project-b")
  if fileExists(nativeStats):
    let stats = parseJson(readFile(nativeStats))
    result.holds(stats["command"].getStr() == "hooks shell-native", shell &
      ": native statistics name command " & stats["command"].getStr())
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
                             withoutDirenvPath = ""): bool =
  ## The activation helper itself, as every template runs it. It stands down
  ## (prints nothing) only when BOTH halves hold: `DIRENV_DIR` names the
  ## directory or an ancestor, and `direnv status` reports the loaded RC
  ## allowed. `loaded` is what a real direnv exported for project-a's
  ## allowed `.envrc` (empty where no direnv drives the case: then nothing
  ## is loaded and no case stands down). `withoutDirenvPath`, when given, is
  ## a `PATH` with no direnv on it, for the case where `direnv status`
  ## cannot be run. True when every case behaved (see `holds`).
  result = true
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
    let label = shell & " DIRENV_DIR=" & direnvDir & " cwd=" & cwd &
      " loaded=" & $withLoaded & " path=" & path
    checkpoint(label & ":\n" & output)
    result.holds(code == 0, label & ": exit code " & $code)
    if standsDown:
      result.holds(output.len == 0, label & ": did not stand down")
    else:
      result.holds("AUX_VALUE" in output, label & ": did not activate")


# ---------------------------------------------------------------------------
# Starting a shell inside a directory direnv manages. The rc file may load
# repro's native block before or after direnv's hook; either way the
# directory is activated once, by direnv. A real interactive shell on a
# pseudo-terminal is needed: direnv acts at the prompt, and only an
# interactive shell on a terminal runs every shell's prompt hook.
# ---------------------------------------------------------------------------

when isNixSupported:
  const StartPrompt = "SHELL-READY> "

  proc writeStartRc(c: M6Case; shell, direnv: string; nativeFirst,
                    bashArray: bool) =
    ## The shell's rc file: a prompt hook of the user's own, then the native
    ## block `hooks ensure` wrote and direnv's hook, in the given order, then
    ## a prompt the session waits for. The user's hook (`__user_prompt`,
    ## counting its runs) is registered first, so the case can show that the
    ## deferred start-up hook neither replaces it when it registers itself
    ## nor when it takes itself out: in bash as a scalar PROMPT_COMMAND, or
    ## as an array one when `bashArray` (bash 5.1 and later); in zsh in
    ## `precmd_functions`; in fish as a `fish_prompt` event handler.
    let rc = case shell
      of "zsh": c.homeDir / ".zshrc"
      of "fish": c.xdgConfig / "fish" / "config.fish"
      else: c.homeDir / ".bashrc"
    # The block as `hooks ensure` wrote it, kept aside the first time so
    # each order starts from it.
    let saved = rc & ".native-block"
    if not fileExists(saved):
      copyFile(rc, saved)
    let native = readFile(saved).strip(leading = false) & "\n"
    let hook = case shell
      of "fish": q(direnv) & " hook fish | source\n"
      else: "eval \"$(" & q(direnv) & " hook " & shell & ")\"\n"
    let prompt = case shell
      of "fish": "function fish_prompt; printf '%s' '" & StartPrompt & "'; end\n"
      of "zsh": "PROMPT='" & StartPrompt & "'\n"
      else: "PS1='" & StartPrompt & "'\n"
    let user = case shell
      of "fish":
        "set -g __user_prompt_runs 0\n" &
          "function __user_prompt --on-event fish_prompt\n" &
          "  set -g __user_prompt_runs (math $__user_prompt_runs + 1)\n" &
          "end\n"
      of "zsh":
        "__user_prompt() { (( __user_prompt_runs++ )); }\n" &
          "typeset -ag precmd_functions\nprecmd_functions=(__user_prompt)\n"
      else:
        "__user_prompt() { __user_prompt_runs=$(( ${__user_prompt_runs:-0} + 1 )); }\n" &
          (if bashArray: "PROMPT_COMMAND=(__user_prompt)\n"
           else: "PROMPT_COMMAND=__user_prompt\n")
    writeFile(rc, user & (if nativeFirst: native & hook else: hook & native) &
      prompt)
    if shell == "fish":
      # fish's first interactive start runs `fish_update_completions` as a
      # detached process when `$__fish_cache_dir/generated_completions` does
      # not exist (`__fish_config_interactive`); it outlives the shell and
      # keeps writing under XDG_CACHE_HOME while the case removes it. The
      # directory is made here so fish starts no such process.
      createDir(c.tempRoot / "xdg-cache" / "fish" / "generated_completions")

  proc startProbe(shell: string): string =
    ## How many times the project's tools/bin is on PATH, the project's value
    ## and direnv's DIRENV_DIR, on one `DS:` line; on a `DH:` line, whether
    ## the deferred start-up hook is still registered (it must have taken
    ## itself out at the first prompt), whether the user's prompt hook still
    ## is, and whether it has run; then a marker in lower case, so the
    ## terminal's echo of the typed line does not match it.
    case shell
    of "fish":
      "printf 'DS:%s|%s|%s\\n' (count (string match -- '*tools/bin' $PATH)) " &
        "\"$AUX_VALUE\" \"$DIRENV_DIR\"; " &
        "printf 'DH:%s|%s|%s\\n' (functions -q __repro_native_shell_start; " &
        "and echo 1; or echo 0) (functions --handlers-type generic | " &
        "string match -q 'fish_prompt __user_prompt'; and echo 1; or echo 0) " &
        "(test $__user_prompt_runs -gt 0; and echo 1; or echo 0); " &
        "echo START-PROBE-DONE | tr A-Z a-z\n"
    of "zsh":
      "printf 'DS:%s|%s|%s\\n' \"$(printf %s \"$PATH\" | tr : '\\n' | " &
        "grep -c 'tools/bin$')\" \"$AUX_VALUE\" \"${DIRENV_DIR-unset}\"; " &
        "printf 'DH:%s|%s|%s\\n' $(( ${precmd_functions[(I)__repro_native_shell_start]} > 0 )) " &
        "$(( ${precmd_functions[(I)__user_prompt]} > 0 )) $(( ${__user_prompt_runs:-0} > 0 )); " &
        "echo START-PROBE-DONE | tr A-Z a-z\n"
    else:
      "printf 'DS:%s|%s|%s\\n' \"$(printf %s \"$PATH\" | tr : '\\n' | " &
        "grep -c 'tools/bin$')\" \"$AUX_VALUE\" \"${DIRENV_DIR-unset}\"; " &
        "printf 'DH:%s|%s|%s\\n' \"$(printf '%s\\n' \"${PROMPT_COMMAND[@]}\" | " &
        "grep -c __repro_native_shell_start)\" \"$(printf '%s\\n' " &
        "\"${PROMPT_COMMAND[@]}\" | grep -c __user_prompt)\" " &
        "$(( ${__user_prompt_runs:-0} > 0 )); " &
        "echo START-PROBE-DONE | tr A-Z a-z\n"

  proc startActivatesOnce(c: M6Case; shell, program, direnv: string;
                          nativeFirst: bool; bashArray = false): bool =
    ## A fresh interactive shell started in project-a (allowed `.envrc`):
    ## direnv activates it, once, and the native hook writes no statistics;
    ## the deferred start-up hook is gone after the first prompt and the
    ## user's own prompt hook is still registered and has run.
    ## Returns whether all of that held, so the CASE fails when it does not
    ## (a `check` in a proc called from a test fails only the program's exit
    ## status, not the case it ran in); each failed condition is a
    ## checkpoint.
    let order = (if nativeFirst: "native-first" else: "direnv-first") &
      (if bashArray: "-array" else: "")
    c.writeStartRc(shell, direnv, nativeFirst, bashArray)
    let env = c.direnvEnv()
    let nativeStats = c.tempRoot / (shell & "-start-" & order & "-native.json")
    let direnvStats = c.tempRoot / (shell & "-start-" & order & "-direnv.json")
    env["REPRO_NATIVE_SHELL_STATS"] = nativeStats
    env["REPRO_DIRENV_STATS"] = direnvStats
    env["TERM"] = "dumb"
    # No host `conf.d`: a Nix profile can ship a direnv hook for fish in its
    # `share/fish/vendor_conf.d`, which fish loads before config.fish and
    # which would hide the order under test. fish finds those directories
    # through XDG_DATA_DIRS, and nixpkgs' fish also through NIX_PROFILES.
    let dataDirs = c.tempRoot / "empty-xdg-data-dirs"
    createDir(dataDirs)
    env["XDG_DATA_DIRS"] = dataDirs
    env["NIX_PROFILES"] = ""
    let session = runOnTerminal(program, ["-i"], c.projectA,
      [(waitFor: StartPrompt, send: startProbe(shell)),
       (waitFor: "start-probe-done", send: "exit\n")],
      env, timeoutMs = 300_000)
    let label = shell & " " & order
    checkpoint(label & " start-up session:\n" & session.text)
    result = true
    if session.timedOut:
      checkpoint(label & ": the session timed out")
      result = false
    var probe = ""
    var hooks = ""
    for line in session.text.splitLines():
      let at = line.find("DS:")
      if at >= 0 and at + 3 < line.len and line[at + 3] in Digits:
        probe = line[at .. ^1].strip()
      let hat = line.find("DH:")
      if hat >= 0 and hat + 3 < line.len and line[hat + 3] in Digits:
        hooks = line[hat .. ^1].strip()
    # The start-up hook took itself out; the user's hook is registered and
    # ran.
    if hooks != "DH:0|1|1":
      checkpoint(label & ": hooks " & hooks.escape & ", expected " &
        "\"DH:0|1|1\" (start-up hook registered | user hook registered | " &
        "user hook ran)")
      result = false
    # Once, by direnv: ONE tools/bin on PATH, direnv's statistics written and
    # the native hook's not.
    let expected = "DS:1|alpha|-" & c.projectA
    if probe != expected:
      checkpoint(label & ": probe " & probe.escape & ", expected " &
        expected.escape)
      result = false
    if not fileExists(direnvStats):
      checkpoint(label & ": direnv wrote no statistics")
      result = false
    if fileExists(nativeStats):
      checkpoint(label & ": the native hook activated too (its statistics " &
        "were written)")
      result = false

proc removeCaseDir(dir: string) =
  ## Removes a case's scratch directory without letting the cleanup fail the
  ## case. On Windows a file another process still has open (or that is
  ## pending deletion) keeps its directory from being removed, and the
  ## action cache's `hot-records/*.rbar` directories were seen to do that
  ## right after a PowerShell case. Retries for about ten seconds, then
  ## prints every entry that is left on stderr, so a leftover is reported,
  ## never silently ignored.
  var lastError = ""
  for attempt in 0 ..< 20:
    try:
      removeDir(dir)
      return
    except OSError as err:
      lastError = err.msg
      sleep(500)
  var left: seq[string]
  try:
    for p in walkDirRec(dir, yieldFilter = {pcFile, pcLinkToFile, pcDir,
        pcLinkToDir}):
      left.add(p)
  except OSError:
    discard
  stderr.writeLine("cleanup: could NOT remove " & dir & " (" & lastError &
    "); " & $left.len & " entries left:")
  for p in left:
    stderr.writeLine("cleanup:   " & p)

# The suite also runs on Windows, for its PowerShell case (the other cases
# are gated on Nix inside it); until it did, that case never ran anywhere.
when isNixSupported or defined(windows):
  suite "e2e_native_shell_hooks":
    when isNixSupported:
      test "e2e_native_shell_hooks_bash_zsh_fish":
        let c = prepareCase("repro-m6-native-shells")
        defer: removeDir(c.tempRoot)
        let fish = requireFish()

        check installNativeHooks(c)
        check requireBashHook(c)
        check requireZshHook(c)
        check requireFishHook(c, fish)

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
        check installNativeHooks(c)
        check prepareDirenvProjects(c, direnv)
        let loaded = c.direnvLoadedVars(direnv, c.projectA)
        check requireHelperStandsDown(c, "bash", loaded,
          c.pathWithout("direnv", c.envFor()["PATH"]))
        check c.requireStandDown("bash", findExe("bash"), @["--noprofile",
          "--norc", "-c", posixStandDownProbe(c, "bash", direnv)], "unset")
        let zsh = findExe("zsh")
        if zsh.len == 0:
          raise newException(OSError,
            "the direnv stand-down gate requires a real zsh binary on PATH")
        check c.requireStandDown("zsh", zsh, @["-f", "-c",
          posixStandDownProbe(c, "zsh", direnv)], "unset")
        check c.requireStandDown("fish", fish, @["--no-config", "-c",
          fishStandDownProbe(c, direnv)], "")
        # Each shell's direnv run activated project-a and each native run
        # project-b: both kinds of statistics are there for every shell.
        for shell in ["bash", "zsh", "fish"]:
          check fileExists(c.tempRoot / (shell & "-standdown-direnv-stats.json"))
          check fileExists(c.tempRoot / (shell & "-standdown-native-stats.json"))

      test "e2e_native_shell_hooks_start_inside_direnv_dir_activates_once":
        # A shell started inside a directory direnv manages, with the native
        # block before direnv's hook in the rc file and after it: activated
        # once, by direnv, in bash, zsh and fish.
        let c = prepareCase("repro-native-start")
        defer: removeDir(c.tempRoot)
        let fish = requireFish()
        let direnv = requireDirenv()
        let zsh = findExe("zsh")
        if zsh.len == 0:
          raise newException(OSError,
            "the direnv start-up gate requires a real zsh binary on PATH")
        check installNativeHooks(c)
        check prepareDirenvProjects(c, direnv)
        for (shell, program) in [("bash", findExe("bash")), ("zsh", zsh),
                                 ("fish", fish)]:
          for nativeFirst in [true, false]:
            check c.startActivatesOnce(shell, program, direnv, nativeFirst)
        # bash's PROMPT_COMMAND as an array (bash 5.1 and later), the other
        # form the deferred hook adds itself to and takes itself out of.
        check c.startActivatesOnce("bash", findExe("bash"), direnv,
          nativeFirst = true, bashArray = true)

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
        # Documents folder Windows reports. With the default registry value
        # (`%USERPROFILE%\Documents`) that is inside the case's redirected
        # home, for repro and for the PowerShell started below alike; only a
        # profile that resolves outside the scratch directory is a real file
        # of the invoking user, saved to an on-disk journal first and
        # restored after (`repro_test_support/real_file_guard`).
        let c = prepareCase("repro-m6-native-powershell")
        defer: removeCaseDir(c.tempRoot)
        let pwsh =
          if findExe("pwsh").len > 0: findExe("pwsh") else: findExe("powershell")
        if pwsh.len == 0:
          raise newException(OSError,
            "M6 PowerShell gate requires a real PowerShell binary")
        let docs = windowsDocumentsFromPowerShell(pwsh, c.envFor())
        let outside = pathsOutside([docs / "PowerShell" / "Profile.ps1",
            docs / "PowerShell" / "Microsoft.PowerShell_profile.ps1",
            docs / "WindowsPowerShell" / "Profile.ps1",
            docs / "WindowsPowerShell" / "Microsoft.PowerShell_profile.ps1"],
          c.tempRoot)
        withRealFilesSaved(outside,
            defaultRealFilesJournal("native-shell-hooks-powershell-profiles")):
          discard requireRepro(c, @["hooks", "ensure", "--shell", "powershell"])
          let env = c.envFor()
          let statsPath = c.tempRoot / "powershell-native-stats.json"
          # The first entry's statistics go to a file of their own, so a
          # failed warm check can print both activations' decisions.
          let coldStats = c.tempRoot / "powershell-native-cold-stats.json"
          env["REPRO_NATIVE_SHELL_STATS"] = statsPath
          proc probe(firstStats, warmStats: string): string =
            # The hook reads REPRO_NATIVE_SHELL_STATS when it runs, so each
            # `cd` writes to the file set just before it.
            "$env:REPRO_NATIVE_SHELL_STATS = " & psQuote(firstStats) & "; " &
              "cd " & psQuote(c.projectA) & "; " &
              "Write-Output \"A:$env:AUX_VALUE|$env:FIXTURE_MODE|$env:REPRO_DEV_ENV_PROJECT_ROOT\"; " &
              "cd " & psQuote(parentDir(c.projectA)) & "; " &
              "Write-Output \"OUT:$env:AUX_VALUE|$env:FIXTURE_MODE|$env:REPRO_DEV_ENV_PROJECT_ROOT\"; " &
              # Back into project A: a warm activation, the one whose
              # statistics `requireNativeStats` checks (as the bash probe's
              # A2).
              "$env:REPRO_NATIVE_SHELL_STATS = " & psQuote(warmStats) & "; " &
              "cd " & psQuote(c.projectA) & "; " &
              "Write-Output \"A2:$env:AUX_VALUE|$env:FIXTURE_MODE|$env:REPRO_DEV_ENV_PROJECT_ROOT\""
          let res = runProgram(pwsh, @["-NoLogo", "-Command",
            probe(coldStats, statsPath)], c.tempRoot, env)
          check res.exitCode == 0
          requireShellValue(res.output, "A:",
            "A:alpha|one|" & c.projectA)
          requireShellValue(res.output, "OUT:", "OUT:||")
          requireShellValue(res.output, "A2:",
            "A2:alpha|one|" & c.projectA)
          let warm = requireNativeStats(statsPath)
          if not warm:
            # The warm activation's own decisions are printed by
            # `requireNativeStats`; beside them, the first activation's and
            # the engine's determinism-probe records, which together say
            # whether the first run was refused publication (and why) or the
            # second run's key differed (and in which input).
            checkpoint(nativeStatsDecision(coldStats,
              "the first activation"))
            checkpoint(determinismProbeReport(c.projectA))
          check warm
          # DIRENV_DIR alone (no RC that direnv reports loaded and allowed)
          # does not stand the hook down: it activates as before.
          let aloneStats = c.tempRoot / "powershell-direnv-dir-alone-stats.json"
          let aloneEnv = c.envFor()
          aloneEnv["REPRO_NATIVE_SHELL_STATS"] = aloneStats
          aloneEnv["DIRENV_DIR"] = "-" & c.projectA
          let alone = runProgram(pwsh, @["-NoLogo", "-Command",
            probe(aloneStats, aloneStats)], c.tempRoot, aloneEnv)
          checkpoint(alone.output)
          check alone.exitCode == 0
          requireShellValue(alone.output, "A:", "A:alpha|one|" & c.projectA)
          check fileExists(aloneStats)
          check requireHelperStandsDown(c, "powershell", @[])
          discard requireRepro(c, @["hooks", "uninstall", "--shell",
            "powershell"])

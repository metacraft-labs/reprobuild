## Helper shared across the M76 ``shell hook`` e2e tests.
##
## Provides:
##
## * ``ShellHookCase`` — prepared per-test workspace (temp root,
##   graph-built repro binary, graph-built counting shim, fixture project).
## * ``prepareShellHookCase`` — resolves graph-built binaries and writes the
##   fixture project.
## * ``runBashScenario`` — invokes ``bash`` with the rendered hook in
##   the rc file, executes a sequence of cd/no-op commands, and
##   captures the resulting env block and the shim's spawn counter.
##
## The counting shim is the load-bearing acceptance mechanism for M76:
## the test asserts that the second prompt evaluation inside the same
## project does NOT increment the shim counter — i.e. the hook's
## ``__REPRO_PROJECT_ROOT`` equality check short-circuits before
## spawning ``repro dev-env export``.

import std/[os, osproc, streams, strtabs, strutils, tempfiles]

import repro_test_support

type
  ShellHookCase* = object
    tempRoot*: string
    projectRoot*: string
    repoRoot*: string
    reproBin*: string
    shimBin*: string
    shimCounter*: string  ## file the shim increments on every spawn
    monitorCliPath*: string
    monitorCliArgs*: seq[string]
    monitorShim*: string

  CommandOutcome* = object
    exitCode*: int
    stdout*: string
    stderr*: string

# Test-Fixtures-In-Build-Graph M1: ``repro`` is a build-graph artifact
# (``reprobuild.apps.repro`` → ``build/bin/repro``, built by ``just bootstrap``
# / the apps collection before tests run). Assert it exists and use it instead
# of recompiling ``apps/repro/repro.nim`` at test runtime.
proc reproBinary*(repoRoot: string): string =
  requireBinary(repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc countingShimBinary*(repoRoot: string): string =
  ## Graph-built M76 counting shim. Each spawn appends one byte to
  ## ``$REPRO_M76_SHIM_COUNTER`` and then forwards argv to
  ## ``$REPRO_M76_SHIM_TARGET``. The test reads the counter file size to
  ## assert whether the hook spawned ``repro dev-env export``.
  requireBinary(
    repoRoot / "build" / "test-bin" /
      addFileExt("repro_shell_hook_counting_shim", ExeExt),
    "reprobuild.test_fixtures.shell_hook_counting_shim")

proc providerText*(): string =
  ## Same fixture shape as the M74 export tests so the dev-env edge
  ## resolves under ``readDevEnvFile``.
  "import std/strutils\n" &
    "import repro_project_dsl\n\n" &
    "package fixture:\n" &
    "  defaultToolProvisioning \"path\"\n" &
    "  uses:\n" &
    "    \"nim >=2.2 <3.0\"\n" &
    "  devEnv:\n" &
    "    activity \"default\"\n" &
    "    setEnv \"FIXTURE_MODE\", \"dev\"\n" &
    "    setEnv \"AUX_VALUE\", readDevEnvFile(\"dev-env-value.txt\").strip()\n" &
    "    prependPath \"PATH\", \"tools/bin\"\n" &
    "    task \"build\", command = \"nim c src/main.nim\"," &
       " description = \"Build fixture\"\n" &
    "    diagnostic \"dev env ready\"\n"

proc writeFixture*(dir: string) =
  createDir(dir)
  createDir(dir / "src")
  createDir(dir / "tools" / "bin")
  writeFile(dir / "dev-env-value.txt", "alpha\n")
  writeFile(dir / "src" / "main.nim", "echo \"fixture\"\n")
  writeFile(dir / "reprobuild.nim", providerText())

proc prepareShellHookCase*(prefix: string): ShellHookCase =
  result.repoRoot = getCurrentDir()
  result.tempRoot = expandFilename(createTempDir(prefix, ""))
  result.projectRoot = result.tempRoot / "project"
  writeFixture(result.projectRoot)
  result.reproBin = reproBinary(result.repoRoot)
  result.shimBin = countingShimBinary(result.repoRoot)
  result.shimCounter = result.tempRoot / "shim-counter.bin"
  writeFile(result.shimCounter, "")  # start at zero
  when isIoMonitorSupported:
    let monitor = prepareMonitorTools(result.repoRoot,
      result.tempRoot, "m76-shell-hook")
    result.monitorCliPath = monitor.monitorCliPath
    result.monitorCliArgs = monitor.monitorCliArgs
    result.monitorShim = monitor.shim

proc shimSpawnCount*(c: ShellHookCase): int =
  ## Lengths in bytes of the counter file == number of spawns.
  if fileExists(c.shimCounter):
    getFileSize(c.shimCounter).int
  else:
    0

proc resetShimCounter*(c: ShellHookCase) =
  writeFile(c.shimCounter, "")

proc envEntries*(env: StringTableRef): seq[tuple[name, value: string]] =
  for key, value in env.pairs():
    result.add((key, value))

proc baselineEnvForBash*(c: ShellHookCase): StringTableRef =
  ## Build a clean-ish env block for the bash child. We strip
  ## reprobuild-internal ``__REPRO_*`` vars (so the test asserts the
  ## hook's behaviour from a known starting state) and inject the
  ## counting-shim handles.
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if k.startsWith("__REPRO_"):
      result[k] = ""
      continue
    if k == "PROMPT_COMMAND":
      continue
    result[k] = v
  result["REPROBUILD_SOURCE_ROOT"] = c.repoRoot
  result["REPRO_DEV_ENV_AUTO_ALLOW"] = "1"
  # The shim needs to know which counter to increment and which real
  # binary to dispatch to.
  result["REPRO_M76_SHIM_COUNTER"] = c.shimCounter
  result["REPRO_M76_SHIM_TARGET"] = c.reproBin
  if c.monitorShim.len > 0:
    result["REPRO_MONITOR_SHIM_LIB"] = c.monitorShim
  # Force a stable HOME well outside the project so the bounded walk
  # behaves predictably.
  result["HOME"] = c.tempRoot
  result["XDG_CONFIG_HOME"] = c.tempRoot / "xdg-config"
  result["REPROBUILD_ACTION_CACHE_ROOT"] = c.tempRoot / "action-cache"
  result["REPRO_ACTION_CACHE_SHM"] = "0"
  result["REPRO_DEV_ENV_AUTO_ALLOW"] = "1"
  result["REPRO_DAEMON"] = "off"
  result["REPRO_DAEMON_ENDPOINT"] =
    daemonSocketEndpoint("repro-m76-shell-hook-" & $getCurrentProcessId() &
      "-" & c.tempRoot.extractFilename)
  result["REPRO_DAEMON_STATE_DIR"] = c.tempRoot / "daemon-state"
  createDir(result["XDG_CONFIG_HOME"])
  createDir(result["REPROBUILD_ACTION_CACHE_ROOT"])
  createDir(result["REPRO_DAEMON_STATE_DIR"])
  # Make ps1 deterministic so we don't depend on the host's prompt.
  result["PS1"] = "$ "
  # Disable any locale weirdness.
  result["LANG"] = "C"

proc renderHookForCase*(c: ShellHookCase; shell: string): string =
  ## Spawns ``repro shell hook <shell> --repro-bin <shim>`` against the
  ## case-built repro binary. The shim is what the hook ultimately
  ## execs, so every `repro dev-env export` call increments the
  ## counter.
  var process = startProcess(c.reproBin,
    args = @["shell", "hook", shell, "--repro-bin", c.shimBin],
    workingDir = c.repoRoot,
    options = {poUsePath})
  let outStream = process.outputStream
  let errStream = process.errorStream
  let outText = if outStream != nil: outStream.readAll() else: ""
  let errText = if errStream != nil: errStream.readAll() else: ""
  let code = process.waitForExit()
  process.close()
  if code != 0:
    raise newException(IOError,
      "repro shell hook " & shell & " failed: " & errText)
  outText

proc runBashScript*(c: ShellHookCase; bashPath, rcfilePath, body: string):
    CommandOutcome =
  ## Spawn ``bash --rcfile <wrapper> -i -c 'exit'``. The wrapper
  ## sources the user's rcfile (so the hook is installed +
  ## PROMPT_COMMAND fires for the launching cwd) AND then sources
  ## the test body via ``. <body-path>``. We dispatch through a
  ## wrapper rather than passing the body inline via ``-c`` because
  ## Nim's Windows argv quoter mangles newline-rich strings (each
  ## statement after the first ends up consumed as a separate argv
  ## element rather than a continuation).
  let env = c.baselineEnvForBash()
  let bodyPath = c.tempRoot / "test-script.sh"
  writeFile(bodyPath, body)
  let wrapperPath = c.tempRoot / "bashrc-wrapper.sh"
  let bashEscapedRc = rcfilePath.replace("\\", "/")
  let bashEscapedBody = bodyPath.replace("\\", "/")
  let wrapper =
    ". '" & bashEscapedRc & "'\n" &
    ". '" & bashEscapedBody & "'\n" &
    "exit 0\n"
  writeFile(wrapperPath, wrapper)
  # Merge stderr into stdout to avoid a deadlock where bash blocks
  # writing to a full stderr pipe while the test reads stdout.
  #
  # NOTE: ``readAll`` MUST come AFTER ``waitForExit`` on Windows.
  # Otherwise Nim's pipe-read logic returns early when the bash child
  # has only flushed PARTIAL output (it sees a transient EOF on the
  # half-filled pipe and stops reading). For the tiny test body this
  # is safe — bash buffers at most a few hundred bytes of output, well
  # under the 64KB OS pipe limit, so the parent never blocks the
  # child during waitForExit.
  let res = runShell(shellCommand(@[
    bashPath, "-c", ". '" & wrapperPath.replace("\\", "/") & "'"
  ], env.envEntries), c.tempRoot)
  result.exitCode = res.code
  result.stdout = res.output
  result.stderr = ""

proc findBash*(): string =
  ## Locate bash. Prefers ``bash`` on PATH (covers Linux/macOS hosts
  ## AND Windows Git Bash). Returns "" if no bash is reachable.
  findExe("bash")

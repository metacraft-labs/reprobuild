## Helper shared across the M76 ``shell hook`` e2e tests.
##
## Provides:
##
## * ``ShellHookCase`` — prepared per-test workspace (temp root, repro
##   binary, counting shim, fixture project).
## * ``prepareShellHookCase`` — builds the repro CLI + the counting
##   shim and writes the fixture project.
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
    fsSnoop*: string
    monitorShim*: string

  CommandOutcome* = object
    exitCode*: int
    stdout*: string
    stderr*: string

proc compileNim(repoRoot, sourcePath, outputPath, cacheName: string) =
  var args = @[
    "nim", "c", "--threads:on", "--verbosity:0", "--hints:off",
    "--warnings:off",
    "--nimcache:" & repoRoot / "build" / "nimcache" / cacheName,
    "--out:" & outputPath
  ]
  args.add(sourcePath)
  discard requireSuccess(shellCommand(args), repoRoot)

proc compileRepro*(repoRoot, tempRoot: string): string =
  result = tempRoot / "bin" / addFileExt("repro", ExeExt)
  createDir(parentDir(result))
  compileNim(repoRoot, repoRoot / "apps" / "repro" / "repro.nim",
    result, "m76-shell-hook-repro")

proc shimSource(): string =
  ## Counting shim: opens the file at ``$REPRO_M76_SHIM_COUNTER``,
  ## appends a single byte, flushes; then spawns the real repro at
  ## ``$REPRO_M76_SHIM_TARGET`` with the same argv inheriting our
  ## std handles. Returns the real binary's exit code. Each spawn
  ## adds exactly one byte to the counter file; the test reads the
  ## file's size to get the spawn count.
  result = """
import std/[os, osproc, strtabs]

proc main() =
  let counter = getEnv("REPRO_M76_SHIM_COUNTER")
  let target = getEnv("REPRO_M76_SHIM_TARGET")
  if counter.len > 0:
    var f: File
    if open(f, counter, fmAppend):
      f.write(".")
      f.close()
  if target.len == 0:
    quit("shim: REPRO_M76_SHIM_TARGET not set", 1)
  var args: seq[string] = @[]
  for i in 1 .. paramCount():
    args.add(paramStr(i))
  var envCopy = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    envCopy[k] = v
  var p = startProcess(target, args = args, env = envCopy,
    options = {poParentStreams})
  let rc = p.waitForExit()
  p.close()
  quit(rc)

main()
"""

proc compileShim*(repoRoot, tempRoot: string): string =
  result = tempRoot / "bin" / addFileExt("repro-shim", ExeExt)
  let src = tempRoot / "src" / "repro_shim.nim"
  createDir(parentDir(src))
  createDir(parentDir(result))
  writeFile(src, shimSource())
  compileNim(repoRoot, src, result, "m76-shell-hook-shim")

proc providerText*(): string =
  ## Same fixture shape as the M74 export tests so the dev-env edge
  ## resolves under ``readDevEnvFile``.
  "import std/strutils\n" &
    "import repro_project_dsl\n\n" &
    "package fixture:\n" &
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
  result.reproBin = compileRepro(result.repoRoot, result.tempRoot)
  result.shimBin = compileShim(result.repoRoot, result.tempRoot)
  result.shimCounter = result.tempRoot / "shim-counter.bin"
  writeFile(result.shimCounter, "")  # start at zero
  when isFsSnoopSupported:
    let monitor = prepareMonitorTools(result.repoRoot,
      result.tempRoot, "m76-shell-hook")
    result.fsSnoop = monitor.fsSnoop
    result.monitorShim = monitor.shim

proc shimSpawnCount*(c: ShellHookCase): int =
  ## Lengths in bytes of the counter file == number of spawns.
  if fileExists(c.shimCounter):
    getFileSize(c.shimCounter).int
  else:
    0

proc resetShimCounter*(c: ShellHookCase) =
  writeFile(c.shimCounter, "")

proc baselineEnvForBash*(c: ShellHookCase): StringTableRef =
  ## Build a clean-ish env block for the bash child. We strip
  ## reprobuild-internal ``__REPRO_*`` vars (so the test asserts the
  ## hook's behaviour from a known starting state) and inject the
  ## counting-shim handles.
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if k.startsWith("__REPRO_"):
      continue
    if k == "PROMPT_COMMAND":
      continue
    result[k] = v
  result["REPROBUILD_SOURCE_ROOT"] = c.repoRoot
  # The shim needs to know which counter to increment and which real
  # binary to dispatch to.
  result["REPRO_M76_SHIM_COUNTER"] = c.shimCounter
  result["REPRO_M76_SHIM_TARGET"] = c.reproBin
  if c.fsSnoop.len > 0:
    result["REPRO_FS_SNOOP"] = c.fsSnoop
  if c.monitorShim.len > 0:
    result["REPRO_MONITOR_SHIM_LIB"] = c.monitorShim
  # Force a stable HOME well outside the project so the bounded walk
  # behaves predictably.
  result["HOME"] = c.tempRoot
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
  var process = startProcess(bashPath,
    args = @["-c", ". '" & wrapperPath.replace("\\", "/") & "'"],
    workingDir = c.tempRoot,
    env = env,
    options = {poUsePath, poStdErrToStdOut})
  result.exitCode = process.waitForExit()
  let outStream = process.outputStream
  result.stdout = if outStream != nil: outStream.readAll() else: ""
  result.stderr = ""
  process.close()

proc findBash*(): string =
  ## Locate bash. Prefers ``bash`` on PATH (covers Linux/macOS hosts
  ## AND Windows Git Bash). Returns "" if no bash is reachable.
  findExe("bash")

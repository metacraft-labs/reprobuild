## Shared fixture + helpers for ``t_e2e_dev_env_export_<shell>.nim``.
##
## All five M74 tests follow the same shape:
##   1. Build ``repro.exe`` and the monitor shim/snoop.
##   2. Write a small ``fixture_provider.nim`` declaring a devEnv
##      block (FIXTURE_MODE / AUX_VALUE / prependPath PATH tools/bin).
##   3. Run ``repro dev-env export <shell> --project-root <fixture>``.
##   4. Assert the captured stdout has the per-shell signatures the
##      individual test cares about.
##
## The per-shell test files import the four exported procs from this
## module, then add their own per-shell assertions + syntax-check
## (e.g. ``bash -n`` / ``pwsh -NoProfile -Command``).

import std/[os, osproc, streams, strtabs, strutils, tempfiles]

import repro_dev_env_artifacts
import repro_test_support
import repro_cli_support/dev_env_shell_export

export dev_env_shell_export

type
  M74Case* = object
    tempRoot*: string
    projectRoot*: string
    repoRoot*: string
    reproBin*: string
    fsSnoop*: string
    shim*: string

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
    result, "m74-dev-env-export-repro")

proc providerText*(): string =
  ## The fixture project declares a devEnv with the three signals the
  ## M74 tests care about — a string env var (FIXTURE_MODE), a value
  ## sourced from a project file (AUX_VALUE), and a PATH prepend
  ## (tools/bin). This mirrors ``t_e2e_dev_env_edge_cache.nim``'s
  ## fixture so the M74 tests share the same dev-env edge contract.
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
  # Use the canonical project filename so ``findDevEnvProjectRoot``
  # picks it up via its repro.nim / reprobuild.nim walk.
  writeFile(dir / "reprobuild.nim", providerText())

proc prepareCase*(prefix: string): M74Case =
  result.repoRoot = getCurrentDir()
  result.tempRoot = expandFilename(createTempDir(prefix, ""))
  result.projectRoot = result.tempRoot / "project"
  writeFixture(result.projectRoot)
  result.reproBin = compileRepro(result.repoRoot, result.tempRoot)
  when isFsSnoopSupported:
    let monitor = prepareMonitorTools(result.repoRoot,
      result.tempRoot, "m74-dev-env-export")
    result.fsSnoop = monitor.fsSnoop
    result.shim = monitor.shim

proc envFor*(c: M74Case): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  result["REPROBUILD_SOURCE_ROOT"] = c.repoRoot
  if c.shim.len > 0:
    result["REPRO_MONITOR_SHIM_LIB"] = c.shim
  if c.fsSnoop.len > 0:
    result["REPRO_FS_SNOOP"] = c.fsSnoop

proc runReproExport*(c: M74Case; shell: string): CommandOutcome =
  ## Spawn ``repro dev-env export <shell> --project-root <fixture>``
  ## inside the repoRoot (so the bench-vs-fixture parsing is the same
  ## one a user would hit). stdout and stderr are captured separately.
  ##
  ## Use the canonical fixture provider module via ``moduleForTarget``
  ## semantics — i.e. point ``--project-root`` at the project dir; the
  ## CLI resolves ``fixture_provider.nim`` because we set its module
  ## path via the selector below.
  ##
  var process = startProcess(c.reproBin,
    args = @[
      "dev-env", "export", shell,
      "--project-root", c.projectRoot
    ],
    workingDir = c.repoRoot,
    env = c.envFor(),
    options = {poUsePath})
  let outStream = process.outputStream
  let errStream = process.errorStream
  result.stdout = if outStream != nil: outStream.readAll() else: ""
  result.stderr = if errStream != nil: errStream.readAll() else: ""
  result.exitCode = process.waitForExit()
  process.close()

proc shellAvailable*(name: string): bool =
  findExe(name).len > 0

proc syntaxCheckBash*(stdoutText: string; cwd: string): tuple[ok: bool;
    diag: string] =
  ## ``bash -n <file>``. Writes the script to a temp file, runs the
  ## interpreter in syntax-check-only mode. ``ok`` is true iff bash
  ## reports no errors.
  let scriptPath = cwd / "m74-bash-syntax-check.sh"
  writeFile(scriptPath, stdoutText)
  let bash = findExe("bash")
  if bash.len == 0:
    return (ok: false, diag: "bash not on PATH")
  var proc1 = startProcess(bash,
    args = @["-n", scriptPath],
    workingDir = cwd,
    options = {poUsePath, poStdErrToStdOut})
  let output = if proc1.outputStream != nil: proc1.outputStream.readAll() else: ""
  let code = proc1.waitForExit()
  proc1.close()
  (ok: code == 0, diag: output)

proc syntaxCheckFish*(stdoutText: string; cwd: string): tuple[ok: bool;
    diag: string] =
  let scriptPath = cwd / "m74-fish-syntax-check.fish"
  writeFile(scriptPath, stdoutText)
  let fish = findExe("fish")
  if fish.len == 0:
    return (ok: false, diag: "fish not on PATH")
  var proc1 = startProcess(fish,
    args = @["-n", scriptPath],
    workingDir = cwd,
    options = {poUsePath, poStdErrToStdOut})
  let output = if proc1.outputStream != nil: proc1.outputStream.readAll() else: ""
  let code = proc1.waitForExit()
  proc1.close()
  (ok: code == 0, diag: output)

proc syntaxCheckPwsh*(stdoutText: string; cwd: string): tuple[ok: bool;
    diag: string] =
  ## Use the PSParser via a tiny pwsh -Command snippet. ``ok`` is true
  ## iff pwsh's parser reports zero errors over the script.
  let scriptPath = cwd / "m74-pwsh-syntax-check.ps1"
  writeFile(scriptPath, stdoutText)
  let pwsh =
    if findExe("pwsh").len > 0: findExe("pwsh")
    else: findExe("powershell")
  if pwsh.len == 0:
    return (ok: false, diag: "pwsh/powershell not on PATH")
  var proc1 = startProcess(pwsh,
    args = @[
      "-NoProfile", "-NonInteractive", "-Command",
      "$tokens = $null; $errors = $null; " &
        "[void][System.Management.Automation.Language.Parser]::ParseFile(" &
        "'" & scriptPath.replace("'", "''") &
        "', [ref]$tokens, [ref]$errors); " &
        "if ($errors -and $errors.Count -gt 0) { " &
        "  $errors | ForEach-Object { Write-Error $_.Message }; exit 1 " &
        "} else { exit 0 }"
    ],
    workingDir = cwd,
    options = {poUsePath, poStdErrToStdOut})
  let output = if proc1.outputStream != nil: proc1.outputStream.readAll() else: ""
  let code = proc1.waitForExit()
  proc1.close()
  (ok: code == 0, diag: output)

proc syntheticPlan*(): ExportPlan =
  ## A canonical plan used by the offline (shell-missing) fallback.
  ## Tests assert each shell's formatter produces the expected exact
  ## output for THIS plan. Add ops here judiciously — every change to
  ## the plan is a change to the per-shell golden assertions.
  result = @[]
  result.add(ExportOp(kind: opSet, name: "FIXTURE_MODE", value: "dev"))
  result.add(ExportOp(kind: opSet, name: "AUX_VALUE", value: "alpha"))
  result.add(ExportOp(kind: opPrependPath, pathName: "PATH",
    segment: "/proj/tools/bin", separator: ":"))
  result.appendReproAppliedMarker("deadbeef")

proc emptyPlan*(): ExportPlan = @[]

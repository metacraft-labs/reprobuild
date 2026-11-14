## A compile that calls a provider-mode-only DSL entry point without
## `-d:reproProviderMode` must say that the define is missing.
##
## ## The defect
##
## `buildPackageFragment` and `buildPackageDevEnv` are declared only inside
## `when defined(reproProviderMode):` in
## `libs/repro_project_dsl/src/repro_project_dsl/runtime_provider.nim`. The
## engine, the provider binaries and `scripts/check_nim_sources.sh` all compile
## with that define, and `repro_tests.nim` enrolls every test that reaches
## these entry points with `defines: @["reproProviderMode"]`. A standalone
## compile does not pass it. Before the fix, the reporter of reprobuild-pm
## `issues/2026-11-14-test-from-source-custom-convention-does-not-compile-buildpackagefragment-undeclared.md`
## ran
##
##     nim c libs/repro_standard_provider/tests/test_from_source_custom_convention.nim
##
## and got
##
##     from_source_custom.nim(760, 14) Error: undeclared identifier: 'buildPackageFragment'
##
## followed by spelling suggestions. That reads as a missing import or a
## rename. Nothing in it names the define, so the reader looks in the wrong
## place. The test itself is fine: built with its enrolled define, it passes.
##
## ## What this checks
##
## 1. Without the define, `nim check` of a probe that calls both entry points
##    in the shapes real callers use fails, and reports an error that names
##    `-d:reproProviderMode` on the line of every call. It does not report
##    `undeclared identifier`.
## 2. CONTROL. With the define, the same probe checks clean. If it did not,
##    the probe would be broken for some other reason, and case 1 would pass
##    or fail on that reason instead.
##
## The probe is the checked-in
## `tests/unit/fixtures/build_package_fragment_outside_provider_mode/probe.nim`.
## Its compile is the subject: one compile must fail, so no build edge can
## produce it.
##
## ## NO MOCKS
##
## No mocks are used. Each case runs the real `nim check` on a real source
## file under this checkout, so the repo-root `config.nims` supplies the
## `libs/*/src` paths as it does for any compile here.

import std/[os, osproc, strutils, tempfiles, unittest]

const
  RepoMarker = "repro.nim"
  ProbeRelative =
    "tests/unit/fixtures/build_package_fragment_outside_provider_mode/probe.nim"
  ProviderModeDefine = "-d:reproProviderMode"
  CallMarker = "# CALL:"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc requireNim(): string =
  result = findExe("nim")
  if result.len == 0:
    raise newException(OSError,
      "no `nim` on PATH; this test runs the real compiler")

proc callLines(probe: string): seq[int] =
  ## The 1-based line of every `# CALL:` marker in the probe, i.e. the line
  ## on which each call to a provider-mode-only entry point starts.
  var lineNo = 0
  for line in readFile(probe).splitLines:
    inc lineNo
    if CallMarker in line:
      result.add(lineNo)

proc checkProbe(root: string; extraArgs: openArray[string]):
    tuple[output: string, exitCode: int] =
  ## Runs `nim check` on the probe from the repo root, with a nimcache of
  ## this process's own: the runner runs cases in parallel, and both cases
  ## would otherwise resolve to the same config-derived nimcache directory.
  createDir(root / "build")
  let dir = createTempDir("provider-mode-define-probe-", "", root / "build")
  defer: removeDir(dir)
  var cmd = quoteShell(requireNim()) & " check --hints:off --warnings:off " &
    "--nimcache:" & quoteShell(dir / "nimcache")
  for arg in extraArgs:
    cmd.add(" " & quoteShell(arg))
  cmd.add(" " & quoteShell(root / ProbeRelative))
  checkpoint(cmd)
  execCmdEx(cmd, workingDir = root)

suite "a provider-mode-only DSL entry point names its define":
  test "without the define, every call is refused naming -d:reproProviderMode":
    let root = findRepoRoot()
    let lines = callLines(root / ProbeRelative)
    # The probe has three calls; fewer markers would leave a shape untested.
    check lines.len == 3
    let (output, exitCode) = checkProbe(root, [])
    checkpoint(output)
    check exitCode != 0
    for lineNo in lines:
      let site = "probe.nim(" & $lineNo & ", "
      var named = false
      for line in output.splitLines:
        if site in line and "Error:" in line and ProviderModeDefine in line:
          named = true
          break
      checkpoint("call at probe.nim line " & $lineNo)
      check named
    check "undeclared identifier: 'buildPackageFragment'" notin output
    check "undeclared identifier: 'buildPackageDevEnv'" notin output

  test "control: with the define, the same probe checks clean":
    let root = findRepoRoot()
    let (output, exitCode) = checkProbe(root, [ProviderModeDefine])
    checkpoint(output)
    check exitCode == 0
    check "Error:" notin output

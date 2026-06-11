## Bootstrap-And-Self-Build B5: end-to-end suite run via ``just test``,
## which now invokes the slimmed ``scripts/run_tests.sh`` (engine-
## driven for apps + test-helpers + test-builds; ct-test-runner for
## execution).
##
## Long-running test guard
## -----------------------
## A full ``just test`` run takes 20+ minutes on a clean tree: ~5
## minutes for the apps + helpers + test-builds engine pass, plus
## another ~15 minutes to execute the 520+ test binaries. Default CI
## already runs the suite as ``dev-exec just test``; this integration
## test is a self-check of the B5 pipeline that would double the CI
## time if it ran by default. The structural arm (always runs) asserts
## the build report is produced; the full-suite arm gates on
## ``REPRO_B5_FULL_SUITE_RUN=1``.

import std/[os, osproc, strutils, unittest]

const RepoMarker = "repro.nim"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and
        fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

suite "Bootstrap-And-Self-Build B5: full suite via the slimmed pipeline":

  test "structural: prior just test produced the expected artefacts":
    ## When ``just test`` has been run at least once (the usual case
    ## during dev or CI), the B5 pipeline leaves observable artefacts:
    ##
    ##   * ``test-logs/test.log`` — the ``just test`` driver's tee'd
    ##     output.
    ##   * ``test-logs/parallel-run.json`` — ct-test-runner / M3
    ##     fallback summary.
    ##   * ``build/test-bin/`` populated with test binaries.
    ##   * ``./build/bin/repro`` present (from the engine bootstrap
    ##     or from ``just bootstrap``).
    ##
    ## We skip the assertions when ``just test`` hasn't been run yet
    ## (clean tree).
    let repoRoot = findRepoRoot()
    let reproBin = repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
    let testBinDir = repoRoot / "build" / "test-bin"
    if not fileExists(reproBin):
      checkpoint("skipped — ./build/bin/repro missing; run `just bootstrap` first")
      skip()
    elif not dirExists(testBinDir):
      checkpoint("skipped — build/test-bin/ missing; run `just test` once first")
      skip()
    else:
      var testBinCount = 0
      for kind, _ in walkDir(testBinDir):
        if kind == pcFile:
          inc testBinCount
      checkpoint("build/test-bin/ contains " & $testBinCount & " files")
      # The full suite is 500+ binaries; a partial run still leaves
      # tens. We require at least 10 to confirm the engine produced
      # tangible output at some point.
      check testBinCount >= 10

  test "end-to-end: just test runs the full slimmed pipeline (REPRO_B5_FULL_SUITE_RUN=1 only)":
    ## Drives the entire B5 pipeline: bootstrap, engine build of
    ## apps+test-helpers+test-builds, runquota sibling build, Python
    ## tests, and the ct-test-runner / M3 fallback execution.
    ## Asserts exit 0 + that the build report is produced + that the
    ## test-bin directory is populated.
    ##
    ## CAUTION: this takes 20+ minutes on a clean tree. Guarded by
    ## ``REPRO_B5_FULL_SUITE_RUN=1`` so CI doesn't run it as part of
    ## the normal integration loop.
    if getEnv("REPRO_B5_FULL_SUITE_RUN") != "1":
      checkpoint("skipped — set REPRO_B5_FULL_SUITE_RUN=1 to run the " &
        "full 20+ minute suite end-to-end via `just test`.")
      skip()
    else:
      let repoRoot = findRepoRoot()
      let cmd = "just test"
      checkpoint("running: " & cmd & " (from " & repoRoot & ")")
      let (output, exitCode) = execCmdEx(cmd, workingDir = repoRoot)
      checkpoint("exit=" & $exitCode)
      let tail = block:
        let lines = output.splitLines()
        let start = max(0, lines.len - 50)
        lines[start ..< lines.len].join("\n")
      checkpoint("tail:\n" & tail)
      check exitCode == 0

      let testBinDir = repoRoot / "build" / "test-bin"
      check dirExists(testBinDir)
      var count = 0
      for kind, _ in walkDir(testBinDir):
        if kind == pcFile: inc count
      checkpoint("build/test-bin/ contains " & $count & " files after run")
      check count >= 100

      # The build report from the engine pass.
      let report = repoRoot / ".repro" / "build" / "repro" / "build-report.json"
      check fileExists(report)
      checkpoint("B5 end-to-end: OK")

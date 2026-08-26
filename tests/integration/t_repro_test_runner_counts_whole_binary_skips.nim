## t_repro_test_runner_counts_whole_binary_skips —
## ``skip=0`` in the run summary must mean *zero skips*.
##
## The defect this pins
## --------------------
## The runner has two execution paths. A protocol-aware binary is driven
## one case at a time with ``--run``; the fork's ``std/unittest`` is then
## in ``pmRun``, where it writes a result document and exits 2 for a
## skipped case, so the runner sees the skip on both channels. A binary
## the runner cannot enumerate is executed WHOLE, and ``unittest`` is then
## in ``pmDefault``: it writes no result document at all, and its exit
## code is 1 if some case FAILED and 0 otherwise. **A skipped case exits
## 0.** The runner read that 0 and reported PASS.
##
## So ``summary.skipped`` counted per-case skips only. A whole-binary run
## containing ``skip()`` calls landed in ``passed``, the console printed
## ``[PASS] … (whole-binary)``, and the aggregate line said ``skip=0``
## while the captured stdout of that very case carried ``[SKIPPED]``
## lines. Auditing skips meant grepping a multi-gigabyte log for
## ``[SKIPPED]`` — which is not a gate anyone remembers to run, and is
## exactly how a skip census stops being a census.
##
## Whole-binary execution is not an exotic path. Every downgrade to it is
## a decision the runner takes at probe time about 1200+ binaries: a
## ``--list-json`` probe that times out, exits non-zero, or yields no
## decodable catalog leaves the binary opaque. A single stderr-merge bug
## in that probe once downgraded 170 binaries for an entire campaign.
##
## What is asserted
## ----------------
## 1. A real ``std/unittest`` binary with one passing and one skipped case,
##    executed whole, is reported ``SKIP`` — counted in
##    ``summary.skipped``, named in ``skip_reason``, and printed on the
##    console — instead of ``PASS`` with ``skip=0``.
## 2. A skip may not absorb a failure: a whole binary with both a failing
##    and a skipped case stays ``FAIL``, keeps ``summary.failed == 1``,
##    contributes nothing to ``summary.skipped``, and still fails the run.
##
## Mock justification (per the workspace testing policy)
## ----------------------------------------------------
## None. Both fixtures are real ``std/unittest`` binaries compiled by the
## real toolchain and executed by the real runner. The whole-binary path
## is reached the way production reaches it — by making the ``--list-json``
## probe exceed its own wall-clock bound — rather than by faking the
## classification: the fixture's module initialisation costs more than the
## ``REPRO_TEST_PROBE_TIMEOUT`` the runner is given, so the runner
## downgrades it exactly as it downgrades a slow real binary.

## The cases below are written as plain ``test`` blocks with nested
## guards rather than through a ``proc``-wrapping template that permits
## early ``return``. The static case-count baseline
## (``scripts/reprobuild-suite-static-case-counts.tsv``) counts ``test``
## declarations by source scan, and a wrapped case is invisible to it —
## a file whose cases the baseline records as 0 cannot lose coverage
## detectably.

import std/[json, os, osproc, strutils, tempfiles, unittest]

const RepoRootMarker = "repro.nim"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoRootMarker) and
        fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

const
  ProbeTimeoutSec = 1
    ## What the runner is told a ``--list-json`` probe may cost.
  ModuleInitSleepMs = 5000
    ## What the fixture's module initialisation actually costs. Comfortably
    ## above ``ProbeTimeoutSec`` so the downgrade is decided by the fixture's
    ## own sleep and not by host load; load can only make the probe slower,
    ## i.e. can only reinforce the downgrade, never undo it.
  SkipReasonText = "REPRO_WHOLE_BINARY_SKIP_GATE fixture"
    ## The fixture supplies a reason to ``skip(...)``, and it is
    ## deliberately NOT asserted on. ``unittest``'s console formatter
    ## prints only ``[SKIPPED] <case name>``; the reason travels in the
    ## result document, which a whole-binary run never writes. So the
    ## most a whole-binary skip census can honestly report is WHICH
    ## cases were skipped, and that is what is asserted below. Recovering
    ## the reason too needs the binary to become enumerable, not a
    ## better parser.

const SkipFixtureSource = """
import std/[os, unittest]

# Paid on every start, including the runner's ``--list-json`` probe.
sleep($SLEEP)

suite "gate":
  test "passing case":
    check 1 == 1
  test "skipped case":
    skip("$REASON")
"""

const SkipAndFailFixtureSource = """
import std/[os, unittest]

sleep($SLEEP)

suite "gate":
  test "skipped case":
    skip("$REASON")
  test "failing case":
    check 1 == 2
"""

proc renderFixture(source: string): string =
  source.replace("$SLEEP", $ModuleInitSleepMs).replace("$REASON",
    SkipReasonText)

proc compileFixture(workRoot, source, binary: string): bool =
  let cmd = "nim c --hints:off --warnings:off " &
    "--nimcache:" & quoteShell(workRoot / "nimcache") & " " &
    "--out:" & quoteShell(binary) & " " & quoteShell(source)
  execCmd(cmd) == 0

proc runRunner(runner, binDir, summary, resultsDir: string):
    tuple[exitCode: int; output: string] =
  ## ``execCmdEx`` merges stderr into stdout, and the runner writes both
  ## its per-case progress and its aggregate line to stderr — so the
  ## returned text is the console channel this test asserts on. Progress
  ## is deliberately NOT quiet here for that reason.
  ##
  ## ``REPRO_TEST_PROBE_TIMEOUT`` is the runner's own documented knob for
  ## the discovery probe's wall-clock bound; setting it low is how the
  ## fixture reaches whole-binary execution.
  let cmd = "REPRO_TEST_PROBE_TIMEOUT=" & $ProbeTimeoutSec & " " &
    quoteShell(runner) &
    " --no-build --threads=1" &
    " --bin-dir=" & quoteShell(binDir) &
    " --summary-json=" & quoteShell(summary) &
    " --results-dir=" & quoteShell(resultsDir)
  let (output, exitCode) = execCmdEx(cmd)
  (exitCode, output)

proc entryFor(doc: JsonNode; stem: string): JsonNode =
  result = newJNull()
  for entry in doc["tests"]:
    if entry{"binary_stem"}.getStr() == stem:
      return entry

proc buildFixtureRun(prefix, stem, source: string;
                     tempRoot: var string): tuple[ok: bool;
                                                  exitCode: int;
                                                  console: string;
                                                  doc: JsonNode] =
  ## Compile one fixture into its own bin dir and run the runner over it.
  ## ``ok = false`` means the fixture could not be prepared; the caller
  ## has already asserted the prerequisites that make that a failure.
  result = (ok: false, exitCode: -1, console: "", doc: newJNull())
  let repoRoot = findRepoRoot()
  let runner = repoRoot / "build" / "bin" /
    addFileExt("repro_test_runner", ExeExt)
  if not fileExists(runner):
    return
  tempRoot = createTempDir(prefix, "")
  let binDir = tempRoot / "bin"
  createDir(binDir)
  let src = tempRoot / (stem & ".nim")
  writeFile(src, renderFixture(source))
  if not compileFixture(tempRoot, src, binDir / addFileExt(stem, ExeExt)):
    return
  let summary = tempRoot / "summary.json"
  let (exitCode, console) =
    runRunner(runner, binDir, summary, tempRoot / "results")
  if not fileExists(summary):
    result.console = console
    return
  result = (ok: true, exitCode: exitCode, console: console,
            doc: parseJson(readFile(summary)))

suite "repro_test_runner counts whole-binary unittest skips":

  test "a skipped case in a whole-binary run reaches summary.skipped":
    let repoRoot = findRepoRoot()
    let runner = repoRoot / "build" / "bin" /
      addFileExt("repro_test_runner", ExeExt)
    check fileExists(runner)
    if fileExists(runner):
      const Stem = "t_whole_binary_skip_fixture"
      var tempRoot = ""
      defer:
        if tempRoot.len > 0: removeDir(tempRoot)
      let run = buildFixtureRun("repro-whole-binary-skip-", Stem,
        SkipFixtureSource, tempRoot)
      checkpoint("console: " & run.console)
      check run.ok
      if run.ok:
        # The fixture really did take the whole-binary path — otherwise
        # this test would be asserting the already-working per-case path
        # and would pass for the wrong reason.
        check run.console.contains("treating the binary as opaque")
        let entry = entryFor(run.doc, Stem)
        check entry.kind != JNull
        if entry.kind != JNull:
          check entry{"protocol_aware"}.getBool(true) == false

          # ---- the gate ------------------------------------------------
          # Before the fix: status PASS, summary.skipped 0, console
          # ``[PASS] … (whole-binary)`` — with ``[SKIPPED] skipped case``
          # sitting unread inside the same case's captured stdout.
          check entry{"status"}.getStr() == "SKIP"
          check run.doc{"summary"}{"skipped"}.getInt(-1) == 1
          check run.doc{"summary"}{"passed"}.getInt(-1) == 0

          # A count that cannot say what was skipped is not a census: the
          # reason names the case, so a reader never has to go back to
          # the log.
          check entry.hasKey("skip_reason")
          let reason = entry{"skip_reason"}.getStr()
          checkpoint("skip_reason: " & reason)
          check reason.contains("skipped case")

          # The console channel carries it too — that is where a reader
          # looks first, and the aggregate line is what a gate greps.
          check run.console.contains("[SKIP] " & Stem)
          check run.console.contains("skip=1")

          # Nothing failed, so the run is still green. The fix must make
          # the census honest without making a clean run red.
          check run.doc{"summary"}{"failed"}.getInt(-1) == 0
          check run.exitCode == 0

  test "a skip may not absorb a failure in the same binary":
    let repoRoot = findRepoRoot()
    let runner = repoRoot / "build" / "bin" /
      addFileExt("repro_test_runner", ExeExt)
    check fileExists(runner)
    if fileExists(runner):
      const Stem = "t_whole_binary_skip_and_fail_fixture"
      var tempRoot = ""
      defer:
        if tempRoot.len > 0: removeDir(tempRoot)
      let run = buildFixtureRun("repro-whole-binary-skipfail-", Stem,
        SkipAndFailFixtureSource, tempRoot)
      checkpoint("console: " & run.console)
      check run.ok
      if run.ok:
        check run.console.contains("treating the binary as opaque")
        let entry = entryFor(run.doc, Stem)
        check entry.kind != JNull
        if entry.kind != JNull:
          # The binary exits 1 because a case FAILED. Reclassifying it as
          # a skip because it also printed ``[SKIPPED]`` would be a
          # fail-open, so only a PASS may ever be re-read as a SKIP.
          check entry{"status"}.getStr() == "FAIL"
          check run.doc{"summary"}{"failed"}.getInt(-1) == 1
          check run.doc{"summary"}{"skipped"}.getInt(-1) == 0
          check run.exitCode == 1

## ``repro_tap_test_runner`` — the SECOND RUNNER RunQuota-Observation-Store
## §M20 requires, as a real binary.
##
## Normative specification:
##
## * ``reprobuild-specs/RunQuota-Observation-Store.milestones.org`` §M20
##   — "A non-CodeTracer runner via ``reprobuild-test-adapters`` writes
##   ``ext_test_execution`` rows that ``stats flaky``/``duration`` query
##   indistinguishably from CodeTracer's. Asserts no CodeTracer-specific
##   column is required to record a test outcome.";
## * ``reprobuild-specs/RunQuota-Observation-Store.md`` invariants OS-4,
##   OS-8.
##
## **WHAT IT IS.** A runner for TAP 13 producers. It scans a directory of
## executables, runs each one, parses what it printed, and records one
## ``ext_test_execution`` row per case. The parsing and the runner vtable
## come from ``reprobuild-test-adapters``; the write path comes from
## ``repro_generic_test_recorder``. Nothing in this program links
## CodeTracer's reporter, imports its extension module, or knows any of
## its columns exist.
##
## **WHY A BINARY RATHER THAN A FUNCTION THE TEST CALLS.** M20's gate says
## a runner writes rows. A test that composed the pieces in-process would
## be asserting that the pieces CAN be composed, which is a weaker claim
## and the one that is true by construction. This is a separate process,
## spawned by the integration test exactly as ``repro_test_runner`` is,
## holding its own RunQuota session under its own tool identity.
##
## **IT DECLARES ONE EXTENSION.** There is no second ``declareExtension``
## anywhere on this path, so a run of this binary produces spine rows and
## generic rows and nothing else. That is the executable form of "no
## CodeTracer-specific column is required to record a test outcome": the
## rows it writes are complete, and ``ext_codetracer_test`` is not merely
## empty for them — it was never declared by this client at all.

import std/[algorithm, json, os, strutils]

import repro_test_adapters
import repro_generic_test_recorder

const
  ToolName = "repro-tap-test-runner"
  ToolVersion = "1"

type Options = object
  binDir: string
  summaryPath: string
  historyEnabled: bool
  quiet: bool

proc parseArgs(): Options =
  result.binDir = "build/tap-test-bin"
  result.historyEnabled = getEnv("REPRO_TEST_NO_RUNQUOTA_HISTORY", "") notin
    ["1", "true", "yes"]
  for arg in commandLineParams():
    if arg.startsWith("--bin-dir="):
      result.binDir = arg["--bin-dir=".len .. ^1]
    elif arg.startsWith("--summary-json="):
      result.summaryPath = arg["--summary-json=".len .. ^1]
    elif arg == "--no-runquota-history":
      result.historyEnabled = false
    elif arg == "--quiet":
      result.quiet = true
    else:
      stderr.writeLine "repro_tap_test_runner: unknown argument " & arg
      quit(2)

proc isExecutableFile(path: string): bool =
  if not fileExists(path):
    return false
  when defined(windows):
    path.toLowerAscii().endsWith(".exe") or path.toLowerAscii().endsWith(".bat")
  else:
    fpUserExec in getFilePermissions(path)

proc scanTapBinaries(binDir: string): seq[string] =
  if not dirExists(binDir):
    return @[]
  for kind, path in walkDir(binDir):
    if kind in {pcFile, pcLinkToFile} and isExecutableFile(path):
      result.add(path)
  result.sort()

var recorder: GenericTestRecorder

proc main() =
  let opts = parseArgs()
  let binaries = scanTapBinaries(opts.binDir)
  if binaries.len == 0:
    stderr.writeLine "repro_tap_test_runner: no TAP binaries under " &
      opts.binDir
    quit(1)

  # OS-4: a missing daemon degrades to no capture, is never an error, and
  # never changes what the runner does with the tests themselves.
  var capturing = false
  if opts.historyEnabled:
    capturing = recorder.addr.open(ToolName, ToolVersion)

  var total = 0
  var failed = 0
  var recorded = 0
  for binary in binaries:
    let testBinary = TestBinary(path: binary)
    for outcome in runTapBinary(testBinary, "").outcomes:
      inc total
      if outcome.status in {tsFail, tsTimeout, tsLeak}:
        inc failed
      if not outcome.recordable():
        # A row that cannot fill the three ``not null`` columns would be
        # refused by the store with nothing to say so. Counted as a
        # harness fault rather than dropped quietly.
        stderr.writeLine "repro_tap_test_runner: unrecordable outcome from " &
          binary
        continue
      if not capturing:
        continue
      # THE LEASE SPANS THE RECORDING, NOT THE EXECUTION, AND THE
      # DIFFERENCE IS DECLARED RATHER THAN HIDDEN. A TAP producer runs a
      # whole binary's worth of cases in one process and reports them
      # afterwards, so there is no per-case process for a lease to span.
      # The spine row therefore describes the RECORDING of the case, and
      # the case's own elapsed time is the generic layer's
      # ``duration_ms`` — which is the column §"Generic test-execution
      # extension" provides for exactly this, and which is what
      # ``stats duration`` reads.
      var lease = recorder.addr.acquireLease(outcome.testId)
      recorder.addr.markStarting(lease)
      recorder.addr.markRunning(lease, uint64(getCurrentProcessId()),
        uint64(getCurrentProcessId()))
      recorder.addr.finishExecution(lease, GenericTestOutcomeProcess(
        exitCode: if outcome.status == tsFail: 1 else: 0))
      recorder.addr.recordRow(lease, outcome)
      if lease.captured:
        inc recorded
      recorder.addr.releaseLease(lease)

  let summary = %*{
    "summary": {
      "tool": ToolName,
      "binaries": binaries.len,
      "total": total,
      "failed": failed,
      "recorded": recorded,
      "runquota_history": capturing and recorder.addr.declaredOk(),
      "runquota_history_uncaptured": recorder.addr.uncaptured()
    }
  }
  if opts.summaryPath.len > 0:
    createDir(opts.summaryPath.parentDir)
    writeFile(opts.summaryPath, pretty(summary) & "\n")
  if not opts.quiet:
    echo pretty(summary)

  recorder.addr.close()
  if failed > 0:
    quit(1)
  quit(0)

main()

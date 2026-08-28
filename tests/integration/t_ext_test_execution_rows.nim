## M19: a REAL PARALLEL TEST RUN writes spine + ``ext_test_execution`` +
## ``ext_codetracer_test`` rows into RunQuota's observation store.
##
## Gate (``reprobuild-specs/RunQuota-Observation-Store.milestones.org`` §M19):
## "A real parallel test run writes spine + ``ext_test_execution`` +
## ``ext_codetracer_test`` rows. Asserts ``termination`` distinguishes an
## OOM-killed test from an assertion failure (both non-zero) using a
## deliberately memory-hungry test. Asserts ``.nimtest/history.db`` is not
## created."
##
## The gate also carries the clause moved out of M13 on 2026-08-23: "A REAL
## TEST RUN produces complete, correct rows."
##
## NO MOCKS, AND NOTHING SUBSTITUTED. Every arm starts the real
## ``runquotad`` binary on a real Unix-domain socket, compiles real test
## binaries that link the real ``ct_test_unittest_parallel`` protocol shim,
## drives the real ``repro_test_runner`` across several worker threads, and
## reads the answer back through the real RQSP query interface. Nothing in
## this file writes a row, and nothing in it opens the store's database:
## ``Nim-Parallel-Test-Framework.md`` §17.3 §"How these read" makes
## ``runquotad`` the only sanctioned reader, and a test that read the file
## directly would be asserting against a path the runner is forbidden to
## use.
##
## WHY THE TERMINATION ARM ASSERTS BOTH DIRECTIONS AGAINST EACH OTHER.
## A test asserting only ``termination == "oom_killed"`` for the hungry
## case passes against an implementation that reports ``oom_killed`` for
## everything, and a test asserting only ``termination == "exited"`` for
## the failing case passes against one that never reports ``oom_killed`` at
## all — which is the implementation that existed before this milestone.
## Both arms run IN THE SAME RUN, against the SAME daemon, and the
## assertion is that the two values DIFFER while both exit statuses are
## non-zero. That is the conflation §"executions" describes ("An OOM kill
## and an assertion failure are both non-zero"), reproduced and then
## separated.
##
## WHY THE ABSENCE ARM CARRIES A POSITIVE CONTROL. "``.nimtest/history.db``
## was not created" is trivially true of a run in which nothing would have
## written any history at all — a run with no daemon, or one where the
## reporter never fired. So the absence is asserted only after the same run
## has been shown to have produced history SOMEWHERE ELSE: rows in the
## shared store and ``summary.runquota_history == true``. The path that
## would have written the retired file is the path that did write the rows.

import std/[algorithm, json, os, osproc, posix, sequtils, streams, strutils,
    tables, tempfiles, times, unittest]

import repro_test_support

import runquota_client
import runquota_core
import runquota_protocol

const
  GenericExtensionId = "test_execution"
  CodetracerExtensionId = "codetracer_test"
  NullMarker = "~"
    ## How the store renders SQL NULL on the wire, so a column that was
    ## deliberately left absent stays distinguishable from the empty
    ## string. Pinned here because the difference is load-bearing for
    ## ``stderr_len``.

  GenericColumns = ["test_id", "suite", "status", "duration_ms", "attempt",
    "retry_of", "error_message", "skip_reason", "stdout_len", "stderr_len"]
  CodetracerColumns = ["recording_path", "trace_id", "trace_format_version",
    "recorder", "replay_ok", "protocol_aware", "run_name", "body_hash",
    "checkpoint_count", "status_disagreement", "harness_error"]

  MemoryLimitMb = 200
  HungryTestId = "m19Hungry::memory_hungry"
  FailingTestId = "m19Failing::assertion_failure"

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / "repro.nim") and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError, "cannot locate reprobuild repo root")

proc runnerBin(): string =
  ## ``build/bin/repro_test_runner`` is an INPUT to this test, not an
  ## output of compiling it. A run that recompiled only this file would
  ## drive whatever runner happened to be on disk, so its absence is a
  ## hard error rather than a skip.
  let path = repoRoot() / "build" / "bin" / addFileExt("repro_test_runner", ExeExt)
  if not fileExists(path):
    raise newException(OSError,
      "repro_test_runner missing at " & path &
      "; build it before running this test")
  path

proc socketIsBound(path: string): bool =
  var info: Stat
  lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode)

type DaemonHandle = object
  process: Process

proc startRunQuotaDaemon(socketPath, identityFile: string): DaemonHandle =
  let process = startProcess(requireRunQuotaDaemonBin(repoRoot()),
    args = @["--socket", socketPath,
             "--host-identity-file", identityFile,
             "--ambient-sample-interval-millis", "0"],
    options = {poStdErrToStdOut})
  for _ in 0 ..< 400:
    if socketIsBound(socketPath): break
    sleep(25)
  # The daemon prints exactly three startup lines; reading them keeps the
  # pipe from filling and wedging it on a write nobody is draining.
  for _ in 0 ..< 3:
    discard process.outputStream.readLine()
  DaemonHandle(process: process)

proc stop(handle: var DaemonHandle) =
  if handle.process.running:
    handle.process.terminate()
    discard handle.process.waitForExit(5000)
  if handle.process.running:
    handle.process.kill()
    discard handle.process.waitForExit(5000)
  handle.process.close()

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

proc writePassingFixture(path: string; idx: int) =
  writeFile(path, """
import ct_test_unittest_parallel

suite "m19Passing$IDX":
  test "alpha":
    check 1 == 1
  test "beta":
    check 2 + 2 == 4
""".replace("$IDX", $idx))

proc writeFailingFixture(path: string) =
  ## AN ORDINARY ASSERTION FAILURE. Exit status 1, no signal, nothing
  ## unusual about it — which is exactly what makes it the control the
  ## OOM arm has to be told apart from.
  writeFile(path, """
import ct_test_unittest_parallel

suite "m19Failing":
  test "assertion_failure":
    check 1 == 2
""")

proc writeHungryFixture(path: string) =
  ## DELIBERATELY MEMORY-HUNGRY, and it TOUCHES what it allocates.
  ##
  ## Allocating without writing would leave the pages unfaulted on both
  ## Linux and macOS, so the resident set — which is what the ceiling is
  ## measured against — would stay small while the virtual size grew, and
  ## a test that never crossed the ceiling would report a plain
  ## ``exited``. One store per page is what makes the resident set real.
  ##
  ## It also sleeps between blocks so the growth is observable across
  ## several sampling ticks rather than happening entirely between two of
  ## them.
  ##
  ## THE TOTAL IS BOUNDED AT 1.2 GiB ON PURPOSE, at six times the 200 MiB
  ## ceiling. An unbounded allocator would make every MUTATION of the
  ## ceiling machinery an out-of-memory event for the whole host rather
  ## than a red test — and a clause that cannot be mutated safely cannot
  ## be shown not to be vacuous. Bounded, a runner that never enforces
  ## the ceiling simply lets this case allocate 1.2 GiB and PASS, which
  ## is a loud and harmless failure of the arm below.
  writeFile(path, """
import std/os
import ct_test_unittest_parallel

suite "m19Hungry":
  test "memory_hungry":
    var blocks: seq[seq[byte]] = @[]
    for i in 0 ..< 300:
      var block4m = newSeq[byte](4 * 1024 * 1024)
      for j in countup(0, block4m.len - 1, 4096):
        block4m[j] = byte(i and 0xff)
      blocks.add(block4m)
      sleep(5)
    check blocks.len > 0
""")

proc compileFixture(repoRoot, workRoot, source, binary: string): bool =
  let shimSrc = repoRoot / "libs" / "ct_test_unittest_parallel" / "src"
  let cmd = "nim c --threads:on --hints:off --warnings:off " &
    "--path:" & quoteShell(shimSrc) & " " &
    "--nimcache:" & quoteShell(workRoot / ("nimcache-" & splitFile(source).name)) &
      " " &
    "--out:" & quoteShell(binary) & " " &
    quoteShell(source)
  execCmd(cmd) == 0

# ---------------------------------------------------------------------------
# Reading back over RQSP
# ---------------------------------------------------------------------------

type
  ExtRow = object
    executionId: string
    hostId: string
    profileId: string
    statsKey: string
    values: Table[string, string]

  SpineRow = object
    executionId: string
    statsKey: string
    exitStatus: uint64
    termination: string
    durationMillis: uint64
    peakRssBytes: uint64
    profileId: string

proc readExtRows(socketPath, extensionId: string;
                 columns: openArray[string]): seq[ExtRow] =
  putEnv("RUNQUOTA_SOCKET", socketPath)
  var client = connectDefault()
  defer: client.close()
  let answer = client.queryStats(statsSubjectExtensionRows,
    extensionId = extensionId, extensionColumns = columns)
  for entry in answer.extensionRows:
    var row = ExtRow(
      executionId: entry.executionId,
      hostId: entry.hostId,
      profileId: entry.profile.profileId,
      statsKey: entry.statsKey,
      values: initTable[string, string]())
    for i, name in entry.columns:
      row.values[name] = entry.values[i]
    result.add(row)

proc readSpineRows(socketPath: string): seq[SpineRow] =
  putEnv("RUNQUOTA_SOCKET", socketPath)
  var client = connectDefault()
  defer: client.close()
  let answer = client.queryStats(statsSubjectExecutions)
  for entry in answer.executions:
    result.add(SpineRow(
      executionId: entry.executionId,
      statsKey: entry.statsKey,
      exitStatus: entry.exitStatus,
      termination: entry.termination,
      durationMillis: entry.durationMillis,
      peakRssBytes: entry.peakRssBytes,
      profileId: entry.profile.profileId))

proc waitForExtRows(socketPath, extensionId: string;
                    columns: openArray[string];
                    atLeast: int): seq[ExtRow] =
  ## The observation writer drains on a tick, so a query issued
  ## immediately after the run can legitimately see nothing yet. Polling
  ## for a MINIMUM (never for a maximum) cannot turn an absent row into a
  ## present one.
  let deadline = epochTime() + 30.0
  while epochTime() < deadline:
    result = readExtRows(socketPath, extensionId, columns)
    if result.len >= atLeast:
      return
    sleep(100)

proc rowFor(rows: seq[ExtRow]; testId: string): ExtRow =
  for row in rows:
    if row.values.getOrDefault("test_id") == testId:
      return row
  raise newException(ValueError, "no ext_test_execution row for " & testId)

proc spineFor(rows: seq[SpineRow]; executionId: string): SpineRow =
  for row in rows:
    if row.executionId == executionId:
      return row
  raise newException(ValueError, "no spine row for execution " & executionId)

# ---------------------------------------------------------------------------
# Retired-artifact walk
# ---------------------------------------------------------------------------

proc findRetiredHistoryArtifacts(roots: openArray[string]): seq[string] =
  ## Every ``.nimtest`` directory and every ``history.db`` file under the
  ## given roots.
  ##
  ## A WALK, NOT A LIST OF PATHS. Pinning one expected location would be
  ## satisfied by a runner that wrote the retired store one directory
  ## over; the retired artifact is retired wherever it lands.
  for root in roots:
    if root.len == 0 or not dirExists(root):
      continue
    for path in walkDirRec(root, yieldFilter = {pcFile, pcDir, pcLinkToFile,
        pcLinkToDir}, checkDir = false):
      let name = path.extractFilename
      if name == ".nimtest" or name == "history.db":
        result.add(path)

# ---------------------------------------------------------------------------

type RunEnvironment = object
  tempRoot: string
  socketRoot: string
  socketPath: string
  binDir: string
  resultsDir: string
  summaryPath: string
  daemon: DaemonHandle
  previousSocket: string

proc setUpRun(tag: string): RunEnvironment =
  result.tempRoot = createTempDir("repro-m19-" & tag & "-", "")
  result.previousSocket = getEnv("RUNQUOTA_SOCKET", "")
  # A SHORT SOCKET ROOT, deliberately: a Unix-domain socket path has a
  # ~104 byte ceiling and ``createTempDir``'s root is long enough on some
  # hosts that the daemon dies on ``bindUnix`` with "socket path too long"
  # before it ever listens.
  result.socketRoot = getTempDir() / ("rq-m19-" & tag & "-" &
    $getCurrentProcessId())
  removeDir(result.socketRoot)
  createDir(result.socketRoot)
  result.socketPath = runquotaRendezvousDir(result.socketRoot) / "d.sock"
  let stateDir = result.socketRoot / "state"
  createDir(stateDir)
  result.daemon = startRunQuotaDaemon(result.socketPath, stateDir / "host-id")
  result.binDir = result.tempRoot / "bin"
  result.resultsDir = result.tempRoot / "results"
  result.summaryPath = result.tempRoot / "summary.json"
  createDir(result.binDir)
  createDir(result.tempRoot / "src")

proc tearDown(env: var RunEnvironment) =
  env.daemon.stop()
  putEnv("RUNQUOTA_SOCKET", env.previousSocket)
  removeDir(env.socketRoot)
  removeDir(env.tempRoot)

proc runRunner(env: RunEnvironment; threads: int;
               memoryLimitMb = 0): tuple[output: string; exitCode: int] =
  var cmd = quoteShell(runnerBin()) & " --no-build" &
    " --threads=" & $threads &
    " --quiet" &
    " --test-timeout=120" &
    " --bin-dir=" & quoteShell(env.binDir) &
    " --summary-json=" & quoteShell(env.summaryPath) &
    " --results-dir=" & quoteShell(env.resultsDir)
  if memoryLimitMb > 0:
    cmd.add(" --test-memory-limit-mb=" & $memoryLimitMb)
  putEnv("RUNQUOTA_SOCKET", env.socketPath)
  execCmdEx(cmd)

suite "M19 ext_test_execution + ext_codetracer_test rows":

  test "a real parallel test run writes spine and both extension rows":
    var env = setUpRun("rows")
    defer: tearDown(env)

    const Fixtures = 3
    for i in 0 ..< Fixtures:
      let src = env.tempRoot / "src" / ("t_m19_pass_" & $i & ".nim")
      writePassingFixture(src, i)
      check compileFixture(repoRoot(), env.tempRoot, src,
        env.binDir / addFileExt("t_m19_pass_" & $i, ExeExt))

    let (output, exitCode) = runRunner(env, threads = 3)
    checkpoint("runner exit=" & $exitCode)
    if exitCode != 0:
      checkpoint(output)
    check exitCode == 0

    # A REAL *PARALLEL* RUN. The gate says parallel, and a run the runner
    # executed on one worker would satisfy every row assertion below while
    # proving nothing about the shared session under concurrency.
    let summary = parseJson(readFile(env.summaryPath))
    check summary["summary"]["threads"].getInt() >= 2
    check summary["summary"]["runquota_history"].getBool()
    # Six cases: three binaries, two cases each.
    check summary["summary"]["total"].getInt() == Fixtures * 2

    let generic = waitForExtRows(env.socketPath, GenericExtensionId,
      GenericColumns, Fixtures * 2)
    # NON-VACUITY: six cases ran, so a query that found nothing would fail
    # here rather than making every assertion below pass trivially.
    check generic.len == Fixtures * 2

    let codetracer = waitForExtRows(env.socketPath, CodetracerExtensionId,
      CodetracerColumns, Fixtures * 2)
    check codetracer.len == Fixtures * 2

    let spine = readSpineRows(env.socketPath)
    check spine.len >= Fixtures * 2

    # --- joined correctly to spine rows ---------------------------------
    #
    # Every extension row carries the spine key the daemon joined it by,
    # and the six cases landed on SIX DIFFERENT executions — a join that
    # attached every extension row to one execution would pass an
    # existence check and fail this one.
    var executionIds: seq[string] = @[]
    for row in generic:
      check row.executionId.len > 0
      check row.hostId.len > 0
      # OS-6: every answer is qualified by the hardware it describes.
      check row.profileId.len > 0
      if row.executionId notin executionIds:
        executionIds.add(row.executionId)
    check executionIds.len == Fixtures * 2

    # BOTH EXTENSIONS SIT ON THE SAME SPINE ROWS. Two tables joined to
    # two disjoint sets of executions would satisfy each table's own
    # existence check and still mean the layers describe different runs.
    var codetracerIds: seq[string] = @[]
    for row in codetracer:
      codetracerIds.add(row.executionId)
    codetracerIds.sort()
    var sortedExecutionIds = executionIds
    sortedExecutionIds.sort()
    check codetracerIds == sortedExecutionIds

    # And each of those executions exists on the spine.
    for id in executionIds:
      let row = spineFor(spine, id)
      check row.termination == "exited"
      check row.exitStatus == 0'u64

    # --- complete, correct rows (the clause moved out of M13) -----------
    for row in generic:
      check row.values["test_id"].len > 0
      check row.values["test_id"].startsWith("m19Passing")
      check row.values["suite"].startsWith("m19Passing")
      check row.values["status"] == "pass"
      check row.values["attempt"] == "1"
      # This runner does not retry, so every row is a first attempt and
      # ``retry_of`` is NULL rather than the empty string.
      check row.values["retry_of"] == NullMarker
      # A duration the framework DID report. NULL here would mean the
      # runner never read the case's own result document.
      check row.values["duration_ms"] != NullMarker
      # THE MERGED-STREAM RULE, ASSERTED IN BOTH DIRECTIONS. The runner
      # spawns children with the two streams merged, so it knows the
      # combined size and not the split: ``stdout_len`` is a number and
      # ``stderr_len`` is NULL. An implementation that wrote 0 into
      # ``stderr_len`` would claim the test wrote nothing to stderr, and
      # this is the assertion that tells the two apart.
      check row.values["stdout_len"] != NullMarker
      check row.values["stderr_len"] == NullMarker
      # A passing case has nothing to say, and says nothing rather than
      # saying "".
      check row.values["error_message"] == NullMarker
      check row.values["skip_reason"] == NullMarker

    # --- the CodeTracer layer carries CodeTracer's own facts ------------
    for row in codetracer:
      # Populated: this binary spoke the Tier-1 ``--list-json`` protocol.
      check row.values["protocol_aware"] == "1"
      # ``run_name`` is the catalog's own identifier and the only string
      # that may be handed to ``--run``. Its presence here is what makes
      # this row more than a set of NULLs.
      check row.values["run_name"] != NullMarker
      check row.values["run_name"].len > 0
      check row.values["checkpoint_count"] == "0"
      # Absent for a test that records no trace, which is every test in
      # reprobuild's own suite. NULL, not "".
      check row.values["recording_path"] == NullMarker
      check row.values["trace_id"] == NullMarker
      check row.values["recorder"] == NullMarker

    # --- the generic layer carries NO CodeTracer column -----------------
    #
    # OS-8 in the form this milestone can assert it: the framework-neutral
    # table must not have acquired any of the columns the CodeTracer table
    # owns. M20 asserts the converse — that a second runner can fill the
    # generic layer — and it can only do so if this holds first.
    for row in generic:
      for name in CodetracerColumns:
        check name notin row.values

  test "termination separates an OOM kill from an assertion failure":
    var env = setUpRun("term")
    defer: tearDown(env)

    let failingSrc = env.tempRoot / "src" / "t_m19_failing.nim"
    writeFailingFixture(failingSrc)
    check compileFixture(repoRoot(), env.tempRoot, failingSrc,
      env.binDir / addFileExt("t_m19_failing", ExeExt))

    let hungrySrc = env.tempRoot / "src" / "t_m19_hungry.nim"
    writeHungryFixture(hungrySrc)
    check compileFixture(repoRoot(), env.tempRoot, hungrySrc,
      env.binDir / addFileExt("t_m19_hungry", ExeExt))

    # THE SAME RUN, THE SAME DAEMON, THE SAME CEILING. Running the two
    # arms separately would let an implementation whose termination
    # depends on some per-run state pass both.
    let (output, exitCode) = runRunner(env, threads = 2,
      memoryLimitMb = MemoryLimitMb)
    checkpoint("runner exit=" & $exitCode & " output=" & output)
    # Both cases fail, so the aggregate exit is non-zero. Asserted so a
    # run in which neither case executed cannot reach the row checks.
    check exitCode == 1

    let generic = waitForExtRows(env.socketPath, GenericExtensionId,
      GenericColumns, 2)
    check generic.len == 2

    let hungryRow = rowFor(generic, HungryTestId)
    let failingRow = rowFor(generic, FailingTestId)
    # Distinct executions: otherwise the two "different" terminations
    # below would be one row read twice.
    check hungryRow.executionId != failingRow.executionId

    let spine = readSpineRows(env.socketPath)
    let hungrySpine = spineFor(spine, hungryRow.executionId)
    let failingSpine = spineFor(spine, failingRow.executionId)

    # THE PREMISE OF THE CLAUSE, ASSERTED RATHER THAN ASSUMED. If either
    # of these were zero the two cases would already be distinguishable
    # by exit status and ``termination`` would be carrying nothing.
    check failingSpine.exitStatus != 0'u64
    check hungrySpine.exitStatus != 0'u64

    # THE CLAUSE ITSELF, IN BOTH DIRECTIONS AND AGAINST EACH OTHER.
    #
    # * an implementation that reports ``oom_killed`` for everything
    #   fails the second line;
    # * one that never reports ``oom_killed`` — which is what existed
    #   before this milestone — fails the first;
    # * one that reports some third value for both fails the third.
    check hungrySpine.termination == "oom_killed"
    check failingSpine.termination == "exited"
    check hungrySpine.termination != failingSpine.termination

    # The runner's own account agrees: both are failures, and neither is
    # relabelled into some other status by the kill.
    check hungryRow.values["status"] == "fail"
    check failingRow.values["status"] == "fail"

    # THE KILL WAS A MEMORY KILL AND NOT A TIMEOUT. The generic layer has
    # a ``timeout`` status, and a runner whose ceiling kill went down the
    # timeout path would have written it — which would put an OOM into the
    # bucket "this test hangs" and lose the distinction a second way.
    check hungryRow.values["status"] != "timeout"

    # AND THE PEAK THE RUNNER MEASURED IS ABOVE THE CEILING IT ENFORCED.
    # Without this, "oom_killed" could have been reported by a runner that
    # killed the case for some unrelated reason and labelled it OOM.
    #
    # NOT A THRESHOLD ON A SAMPLED QUANTITY, even though the peak is
    # sampled. The runner updates the peak from the SAME sample it
    # compares against the ceiling and does so before the comparison, so
    # whenever a kill happened the recorded peak is at least the reading
    # that caused it. The inequality is therefore true by construction of
    # the kill, not by the sampler happening to look at a good moment.
    check hungrySpine.peakRssBytes >
      uint64(MemoryLimitMb) * 1024'u64 * 1024'u64
    # The failing case is nowhere near it, so the ceiling did not fire for
    # it and its ``exited`` is not an artefact of the ceiling being off.
    # Safe in the same direction: an unsampled case reports 0, which is
    # below the ceiling, so this cannot fail on a missed sample.
    check failingSpine.peakRssBytes <
      uint64(MemoryLimitMb) * 1024'u64 * 1024'u64

    # The case's own account of WHY it failed reaches the generic layer.
    check failingRow.values["error_message"] != NullMarker
    check failingRow.values["error_message"].contains("1 == 2")

  test "the retired .nimtest/history.db is not created":
    var env = setUpRun("hist")
    defer: tearDown(env)

    let src = env.tempRoot / "src" / "t_m19_hist.nim"
    writePassingFixture(src, 0)
    check compileFixture(repoRoot(), env.tempRoot, src,
      env.binDir / addFileExt("t_m19_hist", ExeExt))

    # The runner is invoked from a directory of this test's own making,
    # so a runner that wrote the retired store RELATIVE TO ITS CWD lands
    # inside a tree this test walks. Without that, a `.nimtest` created
    # next to the repo would be invisible to the walk and the absence
    # assertion would be about the wrong directory.
    let runCwd = env.tempRoot / "cwd"
    createDir(runCwd)
    let previousCwd = getCurrentDir()
    setCurrentDir(runCwd)
    var output = ""
    var exitCode = 0
    try:
      (output, exitCode) = runRunner(env, threads = 2)
    finally:
      setCurrentDir(previousCwd)
    checkpoint("runner exit=" & $exitCode & " output=" & output)
    check exitCode == 0

    # ---- POSITIVE CONTROL, FIRST ---------------------------------------
    #
    # The absence below is only evidence if this run DID exercise the
    # history path. These three lines say it did: the reporter opened, it
    # wrote rows for every case, and the rows came back through the
    # sanctioned reader. An absence assertion after a run that recorded
    # nothing would pass against a runner that still wrote the retired
    # file whenever it recorded anything.
    let summary = parseJson(readFile(env.summaryPath))
    check summary["summary"]["runquota_history"].getBool()
    let generic = waitForExtRows(env.socketPath, GenericExtensionId,
      GenericColumns, 2)
    check generic.len == 2
    let codetracer = waitForExtRows(env.socketPath, CodetracerExtensionId,
      CodetracerColumns, 2)
    check codetracer.len == 2

    # ---- AND THE RETIRED ARTIFACT IS NOWHERE ---------------------------
    let stray = findRetiredHistoryArtifacts(
      [runCwd, env.tempRoot, env.binDir, env.resultsDir, env.socketRoot])
    checkpoint("retired history artifacts found: " & stray.join(", "))
    check stray.len == 0
    # Spelled out for the one location the retired name actually had, so
    # a reader of a failure sees the retired path rather than a count.
    check not fileExists(runCwd / ".nimtest" / "history.db")
    check not dirExists(runCwd / ".nimtest")

## M21: ``stats last-pass`` and ``stats new-failures`` over a REAL shared
## store written by a REAL runner across TWO REAL HOST IDENTITIES, and
## the two schedulers (§17.4 adaptive timeouts, §17.5 duration-based
## sharding) reading the same rows.
##
## Gate (``reprobuild-specs/RunQuota-Observation-Store.milestones.org``
## §M21): "``stats last-pass`` reports the last passing execution with
## timestamp, revision, and host. ``stats new-failures`` partitions
## current failures into new versus long-standing, reported PER HOST as
## well as pooled -- asserted with a fixture where a test passes on one
## host and fails on another, proving the pooled-only answer would have
## been wrong. Adaptive timeouts (§17.4) and duration-based sharding
## (§17.5) read from the shared store, with the documented fallback when
## a test has no history."
##
## NO MOCKS, AND NOTHING SUBSTITUTED. Every arm starts the real
## ``runquotad`` on a real Unix-domain socket over a real SQLite store,
## drives the real ``build/bin/repro_test_runner`` against real compiled
## test binaries, and reads the answers back through the real
## ``stats`` surface invoked as a subprocess. Nothing here writes a row
## and nothing here opens the store's database file.
##
## THE TWO HOSTS ARE TWO HOSTS, NOT TWO LABELS
## -------------------------------------------
##
## ``runquotad`` derives its ``host_id`` from a host identity file and
## records it on every row it writes. Two daemons started over the SAME
## ``--observation-db`` with DIFFERENT ``--host-identity-file`` values
## therefore produce two genuinely distinct ``hosts`` rows, two distinct
## ``host_profiles`` rows, and rows whose ``host_id`` differs — which is
## exactly the store a two-machine CI fleet produces, assembled on one
## machine. Nothing in this file stamps a host id onto a row; the arm
## below asserts the two ids are different and that neither is empty,
## because a fixture in which "two hosts" were one host with two names
## would make every per-host assertion here vacuous.
##
## THE FIXTURE DISAGREES, WHICH IS THE ENTIRE POINT
## ------------------------------------------------
##
## ``m21::hostSplit`` PASSES on host A and FAILS on host B. That is a
## difference in what the test DID, produced by an environment variable
## the fixture reads, not a difference in how it is reported. The
## consequence is the gate's own sentence:
##
## * the POOLED partition sees a current failure with a passing execution
##   in the window, and calls it NEW — "a regression worth bisecting";
## * the PER-HOST partition sees that on the only host failing it, it has
##   never passed — LONG-STANDING, "a test that was already red" on that
##   machine — and that on the other host it is not failing at all.
##
## Those are different verdicts with different owners, and a reader given
## only the pooled column would have spent the debugging session in the
## wrong place. ``m21::regression`` and ``m21::alwaysRed`` are the
## controls that stop this from being something the implementation says
## about everything: both are current failures, both are reported, and
## neither disagrees.
##
## ``build/bin/repro_test_runner`` IS AN INPUT
## -------------------------------------------
##
## It is spawned, not compiled by this file, so a run that rebuilt only
## this test would drive whatever binary happened to be on disk. A
## missing one is a hard error rather than a skip: a skip here would make
## every assertion below vacuous.

import std/[json, os, osproc, posix, sequtils, sets, streams, strtabs,
    strutils, tables, tempfiles, times, unittest]

import repro_test_support

import runquota_client
import runquota_protocol

const
  GenericExtensionId = "test_execution"
  RunContextExtensionId = "test_run_context"
  GenericColumns = ["test_id", "suite", "status", "duration_ms", "attempt",
    "retry_of", "error_message", "skip_reason", "stdout_len", "stderr_len"]
  RunContextColumns = ["git_commit", "git_branch"]

  SplitTestId = "m21::hostSplit"
  RegressionTestId = "m21::regression"
  RedTestId = "m21::alwaysRed"
  GreenTestId = "m21::green"
  FreshTestId = "m21::fresh"
  AbsentTestId = "m21::noSuchTestWasEverRun"

  FixtureStems = ["t_m21_split", "t_m21_regression", "t_m21_red",
    "t_m21_green"]

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

proc requireBin(name: string): string =
  let path = repoRoot() / "build" / "bin" / addFileExt(name, ExeExt)
  if not fileExists(path):
    raise newException(OSError,
      name & " missing at " & path & "; build it before running this test")
  path

proc socketIsBound(path: string): bool =
  var info: Stat
  lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode)

type DaemonHandle = object
  process: Process
  socketPath: string
  running: bool

proc startRunQuotaDaemon(socketPath, identityFile, observationDb: string):
    DaemonHandle =
  ## One daemon, one host identity, one shared store file.
  ##
  ## ``--observation-db`` IS WHAT MAKES THE TWO HOSTS MEET. Without it
  ## each daemon would open its own default store beside its own identity
  ## file, and the "two hosts" fixture would be two separate one-host
  ## stores that no query could compare.
  # THE STALE SOCKET FILE IS REMOVED FIRST, and this is not defensive
  # tidying. The second daemon binds the same path the first one used;
  # a leftover socket inode makes ``bind`` fail with EADDRINUSE, the
  # daemon exits, and every later connection is refused — while
  # ``lstat`` still reports a socket, so a readiness probe based on the
  # file's existence would report the dead daemon as ready and the
  # second host's rows would silently never be written.
  removeFile(socketPath)
  let process = startProcess(requireRunQuotaDaemonBin(repoRoot()),
    args = @["--socket", socketPath,
             "--host-identity-file", identityFile,
             "--observation-db", observationDb,
             "--ambient-sample-interval-millis", "0"],
    options = {poStdErrToStdOut})
  for _ in 0 ..< 400:
    if socketIsBound(socketPath): break
    sleep(25)
  for _ in 0 ..< 3:
    discard process.outputStream.readLine()
  DaemonHandle(process: process, socketPath: socketPath, running: true)

proc stop(handle: var DaemonHandle) =
  if not handle.running:
    return
  if handle.process.running:
    handle.process.terminate()
    discard handle.process.waitForExit(5000)
  if handle.process.running:
    handle.process.kill()
    discard handle.process.waitForExit(5000)
  handle.process.close()
  removeFile(handle.socketPath)
  handle.running = false

# ---------------------------------------------------------------------------
# Fixtures
#
# FOUR SEPARATE BINARIES, so ``--filter`` can decide which cases run in
# which phase without any case having to report a verdict it did not
# reach. A single binary with a per-phase skip would write ``skip`` rows,
# and a ``skip`` is not a verdict — the partition below would then be
# reading rows that say nothing about whether the test works.
# ---------------------------------------------------------------------------

proc writeFixture(path, suiteName, testName, failEnvVar: string;
                  alwaysFail = false; alwaysPass = false) =
  var body = ""
  if alwaysFail:
    body = "    check false"
  elif alwaysPass:
    body = "    check true"
  else:
    body = "    check getEnv(\"" & failEnvVar & "\", \"\") != \"1\""
  writeFile(path, """
import std/os
import ct_test_unittest_parallel

suite "$SUITE":
  test "$TEST":
    # THE SLEEP IS THE MEASUREMENT, NOT PADDING. Without it these cases
    # run in under a millisecond and report ``duration_ms = 0``, which
    # makes every "the duration statistics computed something"
    # assertion unfalsifiable: zero is also what a query that computes
    # nothing returns.
    sleep(40)
$BODY
""".replace("$SUITE", suiteName).replace("$TEST", testName)
   .replace("$BODY", body))

proc compileFixture(workRoot, source, binary: string): bool =
  let shimSrc = repoRoot() / "libs" / "ct_test_unittest_parallel" / "src"
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

type ExtRow = object
  executionId: string
  hostId: string
  values: Table[string, string]

proc readExtRows(socketPath, extensionId: string;
                 columns: openArray[string]): seq[ExtRow] =
  ## ``span = profileSpanWireAll`` IS NOT A WIDENING, IT IS THE QUESTION.
  ## The client's default is ``profileSpanWireSingle``, which restricts
  ## the answer to the ANSWERING DAEMON'S OWN hardware profile — so a
  ## two-host store queried with the default returns only the rows of
  ## whichever host happens to be running, and a per-host assertion made
  ## over it would be comparing one host against itself. This is the
  ## OS-6 dimension being used rather than merely carried, and the
  ## ``stats`` surface under test asks the same way (see
  ## ``repro_test_stats.readGenericTestRows``, whose default is already
  ## ``profileSpanWireAll`` for this reason).
  putEnv("RUNQUOTA_SOCKET", socketPath)
  var client = connectDefault()
  defer: client.close()
  let answer = client.queryStats(statsSubjectExtensionRows,
    span = profileSpanWireAll,
    extensionId = extensionId, extensionColumns = columns)
  for entry in answer.extensionRows:
    var row = ExtRow(
      executionId: entry.executionId,
      hostId: entry.hostId,
      values: initTable[string, string]())
    for i, name in entry.columns:
      row.values[name] = entry.values[i]
    result.add(row)

proc waitForExtRows(socketPath, extensionId: string;
                    columns: openArray[string]; atLeast: int): seq[ExtRow] =
  ## The observation writer drains on a tick, so a query issued
  ## immediately after a run can legitimately see nothing yet. Polling
  ## for a MINIMUM (never a maximum) cannot turn an absent row into a
  ## present one.
  let deadline = epochTime() + 90.0
  while epochTime() < deadline:
    result = readExtRows(socketPath, extensionId, columns)
    if result.len >= atLeast:
      return
    sleep(150)

# ---------------------------------------------------------------------------
# The query surface under test
# ---------------------------------------------------------------------------

proc runStats(socketPath: string; args: seq[string]): JsonNode =
  putEnv("RUNQUOTA_SOCKET", socketPath)
  var command = quoteShell(requireBin("repro_test_runner")) & " stats"
  for arg in args:
    command.add(" " & quoteShell(arg))
  command.add(" --json")
  let (output, code) = execCmdEx(command)
  if code != 0:
    raise newException(ValueError,
      "stats " & args.join(" ") & " exited " & $code & ": " & output)
  parseJson(output)

proc entryFor(rows: JsonNode; testId: string; hostId = ""): JsonNode =
  for row in rows:
    if row{"testId"}.getStr() == testId and
        (hostId.len == 0 or row{"hostId"}.getStr() == hostId):
      return row
  nil

proc present(node: JsonNode): bool = node != nil
  ## ``check e != nil`` CANNOT BE USED ON A ``JsonNode``: ``check``
  ## stringifies its operands when it fails and ``$`` on a nil
  ## ``JsonNode`` segfaults, so the natural formulation turns every red
  ## into a crash with no failing line named.

# ---------------------------------------------------------------------------

type RunEnvironment = object
  tempRoot: string
  socketRoot: string
  socketPath: string
  observationDb: string
  gitRepo: string
  binDir: string
  resultsDir: string
  previousSocket: string
  daemon: DaemonHandle

proc gitIn(repo: string; args: string): string =
  let (output, code) = execCmdEx("git -C " & quoteShell(repo) & " " & args)
  if code != 0:
    raise newException(OSError, "git " & args & " failed: " & output)
  output.strip()

proc setUpRun(tag: string): RunEnvironment =
  result.tempRoot = createTempDir("repro-m21-" & tag & "-", "")
  result.previousSocket = getEnv("RUNQUOTA_SOCKET", "")
  # A SHORT SOCKET ROOT: a Unix-domain socket path has a ~104 byte
  # ceiling and ``createTempDir``'s root is long enough on some hosts
  # that the daemon dies on ``bindUnix`` before it ever listens.
  result.socketRoot = getTempDir() / ("rq-m21-" & tag & "-" &
    $getCurrentProcessId())
  removeDir(result.socketRoot)
  createDir(result.socketRoot)
  createDir(result.socketRoot / "ep")
  setFilePermissions(result.socketRoot / "ep",
    {fpUserRead, fpUserWrite, fpUserExec})
  result.socketPath = result.socketRoot / "ep" / "d.sock"
  createDir(result.socketRoot / "state")
  result.observationDb = result.socketRoot / "state" / "observations.db"
  result.binDir = result.tempRoot / "bin"
  result.resultsDir = result.tempRoot / "results"
  result.gitRepo = result.tempRoot / "checkout"
  createDir(result.binDir)
  createDir(result.gitRepo)
  createDir(result.tempRoot / "src")
  # A REAL WORKING COPY, because the runner resolves the revision it
  # records by asking git about its own working directory. A fake sha
  # written into the store by the test would prove that the test can
  # write a sha.
  discard gitIn(result.gitRepo, "init --initial-branch=main")
  discard gitIn(result.gitRepo, "config user.email m21@example.invalid")
  discard gitIn(result.gitRepo, "config user.name M21")
  discard gitIn(result.gitRepo, "config commit.gpgsign false")

proc commitIn(env: RunEnvironment; content: string): string =
  writeFile(env.gitRepo / "revision.txt", content)
  discard gitIn(env.gitRepo, "add revision.txt")
  discard gitIn(env.gitRepo, "commit -m " & quoteShell(content))
  gitIn(env.gitRepo, "rev-parse HEAD")

proc tearDown(env: var RunEnvironment) =
  env.daemon.stop()
  putEnv("RUNQUOTA_SOCKET", env.previousSocket)
  removeDir(env.socketRoot)
  removeDir(env.tempRoot)

proc buildFixtures(env: RunEnvironment) =
  ## RAISES RATHER THAN RETURNING FALSE. A fixture that did not compile
  ## makes every assertion downstream meaningless.
  let src = env.tempRoot / "src"
  writeFixture(src / "t_m21_split.nim", "m21", "hostSplit", "M21_SPLIT_FAIL")
  writeFixture(src / "t_m21_regression.nim", "m21", "regression",
    "M21_REGRESSION_FAIL")
  writeFixture(src / "t_m21_red.nim", "m21", "alwaysRed", "",
    alwaysFail = true)
  writeFixture(src / "t_m21_green.nim", "m21", "green", "",
    alwaysPass = true)
  for stem in FixtureStems:
    if not compileFixture(env.tempRoot, src / (stem & ".nim"),
        env.binDir / addFileExt(stem, ExeExt)):
      raise newException(OSError, "M21 fixture " & stem & " did not compile")

proc runRunner(env: RunEnvironment; tag: string; filters: seq[string];
               extraEnv: seq[(string, string)] = @[];
               extraArgs: seq[string] = @[];
               binDir = ""; socketPath = ""):
    tuple[output: string; exitCode: int; summary: JsonNode] =
  ## The real runner, in the real checkout, against the real daemon.
  ##
  ## SPAWNED WITH ``workingDir`` SET TO THE FIXTURE CHECKOUT, because
  ## that is how the revision under test gets into the store: the runner
  ## asks git about its own working directory. Passing a revision in
  ## would have tested nothing about the runner.
  let summaryPath = env.tempRoot / ("summary-" & tag & ".json")
  var args = @["--no-build", "--threads=2", "--quiet", "--test-timeout=120",
    "--bin-dir=" & (if binDir.len > 0: binDir else: env.binDir),
    "--summary-json=" & summaryPath,
    "--results-dir=" & (env.resultsDir / tag)]
  for filter in filters:
    args.add("--filter=" & filter)
  for arg in extraArgs:
    args.add(arg)
  var childEnv = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    childEnv[key] = value
  childEnv["RUNQUOTA_SOCKET"] =
    if socketPath.len > 0: socketPath else: env.socketPath
  for pair in extraEnv:
    childEnv[pair[0]] = pair[1]
  let process = startProcess(requireBin("repro_test_runner"),
    workingDir = env.gitRepo, args = args, env = childEnv,
    options = {poStdErrToStdOut})
  let output = process.outputStream.readAll()
  let code = process.waitForExit()
  process.close()
  var summary = newJObject()
  if fileExists(summaryPath):
    summary = parseJson(readFile(summaryPath))
  (output, code, summary)

suite "M21 point-in-time queries over a two-host store":

  test "last-pass and new-failures, and the pooled answer would have misled":
    var env = setUpRun("hosts")
    defer: tearDown(env)
    buildFixtures(env)

    # ---- host A, revision 1 ------------------------------------------
    let revisionOne = commitIn(env, "revision-one")
    env.daemon = startRunQuotaDaemon(env.socketPath,
      env.socketRoot / "state" / "host-a", env.observationDb)
    let phaseA1 = runRunner(env, "a1", @[])
    checkpoint("phase A1: " & phaseA1.output)
    check phaseA1.summary["summary"]["runquota_history"].getBool()
    check phaseA1.summary["summary"]["total"].getInt() == FixtureStems.len
    # Exactly one case failed here — ``alwaysRed`` — so the run really
    # did produce a mixture rather than four of the same verdict.
    check phaseA1.summary["summary"]["failed"].getInt() == 1
    # AND NEITHER SCHEDULING FEATURE WAS ASKED FOR, SO THE PLAN IS
    # ABSENT — not present and empty. A reader finding no ``scheduling``
    # key knows nothing was scheduled from history, which is a different
    # fact from a plan that queried the store and found nothing; the
    # fallback arm at the end of the next suite asserts the second one,
    # and without this line the two would be indistinguishable in the
    # only document either is reported in.
    check not phaseA1.summary["summary"].hasKey("scheduling")

    # ---- host A, revision 2: the regression -------------------------
    let revisionTwo = commitIn(env, "revision-two")
    check revisionTwo != revisionOne
    let phaseA2 = runRunner(env, "a2", @["t_m21_regression"],
      extraEnv = @[("M21_REGRESSION_FAIL", "1")])
    checkpoint("phase A2: " & phaseA2.output)
    check phaseA2.summary["summary"]["total"].getInt() == 1
    check phaseA2.summary["summary"]["failed"].getInt() == 1

    # Wait for host A's five executions BEFORE the daemon is stopped: a
    # query issued after the socket is gone cannot distinguish "the rows
    # were never written" from "nobody is listening".
    let hostARows = waitForExtRows(env.socketPath, GenericExtensionId,
      GenericColumns, 5)
    check hostARows.len == 5
    var hostAIds = initHashSet[string]()
    for row in hostARows:
      hostAIds.incl(row.hostId)
    check hostAIds.len == 1
    let hostA = toSeq(hostAIds.items)[0]
    check hostA.len > 0

    env.daemon.stop()

    # ---- host B, revision 2: the same store, a different machine ----
    env.daemon = startRunQuotaDaemon(env.socketPath,
      env.socketRoot / "state" / "host-b", env.observationDb)
    let phaseB = runRunner(env, "b1",
      @["t_m21_split", "t_m21_red", "t_m21_green"],
      extraEnv = @[("M21_SPLIT_FAIL", "1")])
    checkpoint("phase B: " & phaseB.output)
    # THE SECOND DAEMON REALLY RECORDED. Without this a daemon that
    # failed to bind would leave host B's rows absent, and the per-host
    # partition below would be reading a one-host store while the
    # assertions above about two host ids had already passed on the
    # strength of host A's rows alone.
    check phaseB.summary["summary"]["runquota_history"].getBool()
    check phaseB.summary["summary"]["total"].getInt() == 3
    # ``hostSplit`` and ``alwaysRed`` failed here; ``green`` did not.
    check phaseB.summary["summary"]["failed"].getInt() == 2

    let allRows = waitForExtRows(env.socketPath, GenericExtensionId,
      GenericColumns, 8)
    check allRows.len == 8

    # --- THE FIXTURE IS REALLY TWO HOSTS -----------------------------
    #
    # Without this, every per-host assertion below is satisfied by a
    # store with one host in it.
    var hostIds = initHashSet[string]()
    for row in allRows:
      check row.hostId.len > 0
      hostIds.incl(row.hostId)
    check hostIds.len == 2
    check hostA in hostIds
    let hostB = toSeq(hostIds.items).filterIt(it != hostA)[0]
    check hostB != hostA

    # --- AND THE TEST REALLY BEHAVED DIFFERENTLY ON THEM --------------
    proc statusesOf(testId, hostId: string): seq[string] =
      for row in allRows:
        if row.values.getOrDefault("test_id") == testId and
            row.hostId == hostId:
          result.add(row.values.getOrDefault("status"))
    check statusesOf(SplitTestId, hostA) == @["pass"]
    check statusesOf(SplitTestId, hostB) == @["fail"]

    # --- THE REVISION REACHED THE STORE ------------------------------
    let contextRows = waitForExtRows(env.socketPath, RunContextExtensionId,
      RunContextColumns, 8)
    check contextRows.len == 8
    var recordedRevisions = initHashSet[string]()
    for row in contextRows:
      let commit = row.values.getOrDefault("git_commit")
      check commit.len == 40
      check row.values.getOrDefault("git_branch") == "main"
      recordedRevisions.incl(commit)
    # TWO revisions, not one: the fixture committed between phases and
    # the runner picked the change up. A runner that resolved the
    # revision once per process and cached it globally would still pass
    # this; one that recorded a constant would not.
    check recordedRevisions.len == 2
    check revisionOne in recordedRevisions
    check revisionTwo in recordedRevisions

    # ================= stats last-pass ================================
    let lastPassRegression = runStats(env.socketPath,
      @["last-pass", RegressionTestId])
    check lastPassRegression{"found"}.getBool()
    check lastPassRegression{"everSeen"}.getBool()
    # TIMESTAMP, REVISION AND HOST — the gate's three fields, each
    # asserted to a value the fixture fixed rather than to "non-empty".
    check lastPassRegression{"timestampKnown"}.getBool()
    check lastPassRegression{"timestampUnixMs"}.getBiggestInt() > 0
    check lastPassRegression{"revision"}.getStr() == revisionOne
    check lastPassRegression{"revisionKnown"}.getBool()
    check lastPassRegression{"hostId"}.getStr() == hostA
    check lastPassRegression{"executions"}.getInt() == 2

    # The last pass of the split test is on host A, at revision one —
    # even though its most recent EXECUTION is host B's failure.
    let lastPassSplit = runStats(env.socketPath, @["last-pass", SplitTestId])
    check lastPassSplit{"found"}.getBool()
    check lastPassSplit{"hostId"}.getStr() == hostA
    check lastPassSplit{"revision"}.getStr() == revisionOne

    # A test that ran and never passed, and a test that never ran, are
    # DIFFERENT ANSWERS.
    let lastPassRed = runStats(env.socketPath, @["last-pass", RedTestId])
    check lastPassRed{"everSeen"}.getBool()
    check not lastPassRed{"found"}.getBool()
    check lastPassRed{"executions"}.getInt() == 2
    check lastPassRed{"revision"}.getStr() == "unknown"
    let lastPassAbsent = runStats(env.socketPath, @["last-pass", AbsentTestId])
    check not lastPassAbsent{"everSeen"}.getBool()
    check not lastPassAbsent{"found"}.getBool()
    check lastPassAbsent{"executions"}.getInt() == 0

    # ================= stats new-failures =============================
    let failures = runStats(env.socketPath, @["new-failures"])
    check failures{"window"}{"state"}.getStr() == "known"
    check failures{"window"}{"rowCount"}.getInt() == 8
    check failures{"hostIds"}.len == 2

    let pooledSplit = failures{"pooled"}.entryFor(SplitTestId)
    let pooledSplitPresent = present(pooledSplit)
    check pooledSplitPresent
    # THE POOLED ANSWER, AND IT IS THE WRONG ONE. "New" reads as a
    # regression introduced between revision one and revision two.
    check pooledSplit{"age"}.getStr() == "new"
    check pooledSplit{"lastPassRevision"}.getStr() == revisionOne

    # THE PER-HOST ANSWER, AND IT IS A DIFFERENT VERDICT. On host B the
    # test has never passed: nothing in the window regressed, the
    # machine cannot run it.
    let hostBSplit = failures{"perHost"}.entryFor(SplitTestId, hostB)
    let hostBSplitPresent = present(hostBSplit)
    check hostBSplitPresent
    check hostBSplit{"age"}.getStr() == "long-standing"
    check not hostBSplit{"lastPassKnown"}.getBool()
    check hostBSplit{"lastPassRevision"}.getStr() == "unknown"
    # THE WORDS DIFFER. Asserted directly against the two documents,
    # rather than by reading the implementation's own disagreement list.
    check pooledSplit{"age"}.getStr() != hostBSplit{"age"}.getStr()
    # And on host A it is not a current failure at all, so the pooled
    # sentence "this test is failing" is not true of host A in any sense.
    check not present(failures{"perHost"}.entryFor(SplitTestId, hostA))

    # THE CONTROLS. Both of these are current failures and both are
    # reported; neither disagrees. Without them, "the pooled and
    # per-host answers differ" would be satisfied by an implementation
    # that made them differ for every test.
    let pooledRegression = failures{"pooled"}.entryFor(RegressionTestId)
    check present(pooledRegression)
    check pooledRegression{"age"}.getStr() == "new"
    let hostARegression =
      failures{"perHost"}.entryFor(RegressionTestId, hostA)
    check present(hostARegression)
    check hostARegression{"age"}.getStr() == "new"
    check pooledRegression{"age"}.getStr() == hostARegression{"age"}.getStr()

    let pooledRed = failures{"pooled"}.entryFor(RedTestId)
    check present(pooledRed)
    check pooledRed{"age"}.getStr() == "long-standing"
    for host in [hostA, hostB]:
      let entry = failures{"perHost"}.entryFor(RedTestId, host)
      check present(entry)
      check entry{"age"}.getStr() == "long-standing"

    # THE NEGATIVE CONTROL: a test that passes everywhere is in neither
    # partition. Without it, "current failures" could mean "every test".
    check not present(failures{"pooled"}.entryFor(GreenTestId))
    check not present(failures{"perHost"}.entryFor(GreenTestId))

    # --- and the disagreement is NAMED, for the split test only -------
    var disagreedTests = initHashSet[string]()
    var splitKinds: seq[string] = @[]
    for item in failures{"disagreements"}:
      disagreedTests.incl(item{"testId"}.getStr())
      check item{"detail"}.getStr().len > 0
      if item{"testId"}.getStr() == SplitTestId:
        splitKinds.add(item{"kind"}.getStr())
    check disagreedTests == toHashSet([SplitTestId])
    check "age-differs" in splitKinds
    check "not-failing-everywhere" in splitKinds

    # The pooled-only reading is recoverable from the document and is
    # demonstrably not the per-host one: exactly one test is listed as a
    # NEW pooled failure that no host calls new.
    var pooledNewNoHostNew: seq[string] = @[]
    for entry in failures{"pooled"}:
      if entry{"age"}.getStr() != "new":
        continue
      var anyHostNew = false
      for hostEntry in failures{"perHost"}:
        if hostEntry{"testId"}.getStr() == entry{"testId"}.getStr() and
            hostEntry{"age"}.getStr() == "new":
          anyHostNew = true
      if not anyHostNew:
        pooledNewNoHostNew.add(entry{"testId"}.getStr())
    check pooledNewNoHostNew == @[SplitTestId]

suite "M21 history-fed scheduling reads the shared store":

  test "adaptive timeouts and duration sharding read history, and fall back without it":
    var env = setUpRun("sched")
    defer: tearDown(env)
    buildFixtures(env)
    discard commitIn(env, "revision-one")

    # A FIFTH CASE THE STORE HAS NEVER SEEN. It is compiled into a
    # SECOND bin dir that the populating run never scans, so "no
    # history" is a fact about the store rather than a filter applied to
    # the query.
    let scheduleBinDir = env.tempRoot / "bin-schedule"
    createDir(scheduleBinDir)
    writeFixture(env.tempRoot / "src" / "t_m21_fresh.nim", "m21", "fresh", "",
      alwaysPass = true)
    if not compileFixture(env.tempRoot, env.tempRoot / "src" / "t_m21_fresh.nim",
        scheduleBinDir / addFileExt("t_m21_fresh", ExeExt)):
      raise newException(OSError, "M21 fresh fixture did not compile")
    for stem in FixtureStems:
      copyFileWithPermissions(env.binDir / addFileExt(stem, ExeExt),
        scheduleBinDir / addFileExt(stem, ExeExt))

    env.daemon = startRunQuotaDaemon(env.socketPath,
      env.socketRoot / "state" / "host-a", env.observationDb)

    # ---- populate: two executions of each of the four known cases ----
    for round in 1 .. 2:
      let populate = runRunner(env, "pop" & $round, @[])
      checkpoint("populate " & $round & ": " & populate.output)
      check populate.summary["summary"]["runquota_history"].getBool()
    let populated = waitForExtRows(env.socketPath, GenericExtensionId,
      GenericColumns, 2 * FixtureStems.len)
    check populated.len == 2 * FixtureStems.len

    # ---- §17.4: the minimum, and the fallback ------------------------
    #
    # THE TWO ARE DIFFERENT NUMBERS AND THE DIFFERENCE IS THE EVIDENCE.
    # Every known case takes tens of milliseconds, so p99 x 3 is far
    # below a 30-second floor and lands on the MINIMUM; the fresh case
    # has no history at all and lands on the FALLBACK, which is the
    # runner's own ``--test-timeout``. An implementation that read
    # nothing would report ``fallback`` for all five; one that ignored
    # the absence would report ``minimum`` for all five.
    # EVERY SCHEDULING RUN BELOW RECORDS NOTHING, AND THAT IS LOAD-
    # BEARING RATHER THAN TIDY. These runs execute the same cases they
    # are planning, so a run that recorded would change the history the
    # NEXT one reads — the second shard slice would bin-pack against
    # different estimates than the first, and the "no case appears in two
    # slices" property would fail for a reason that has nothing to do
    # with sharding. Reading is what is under test here; writing is M19's
    # and is asserted in the populating phase above.
    const NoRecord = "--no-runquota-history"
    let adaptive = runRunner(env, "adaptive", @[],
      extraArgs = @[NoRecord, "--adaptive-timeout",
        "--adaptive-timeout-minimum=30",
        "--adaptive-timeout-metric=p99", "--adaptive-timeout-multiplier=3.0"],
      binDir = scheduleBinDir)
    checkpoint("adaptive: " & adaptive.output)
    let plan = adaptive.summary["summary"]["scheduling"]
    check plan{"historyAvailable"}.getBool()
    check plan{"historyRows"}.getInt() >= 2 * FixtureStems.len
    let timeouts = plan{"adaptiveTimeout"}
    check timeouts{"enabled"}.getBool()
    check timeouts{"fromHistory"}.getInt() == FixtureStems.len
    check timeouts{"fromFallback"}.getInt() == 1
    check timeouts{"cases"}.len == FixtureStems.len + 1
    var byTest = initTable[string, JsonNode]()
    for entry in timeouts{"cases"}:
      byTest[entry{"testId"}.getStr()] = entry
    for testId in [SplitTestId, RegressionTestId, RedTestId, GreenTestId]:
      checkpoint("adaptive case " & testId)
      check byTest.hasKey(testId)
      # SAMPLES ARE READ FROM THE STORE, and there are exactly two of
      # each because the populating phase ran twice.
      check byTest[testId]{"samples"}.getInt() == 2
      check byTest[testId]{"source"}.getStr() == "minimum"
      check byTest[testId]{"timeoutSec"}.getInt() == 30
    check byTest.hasKey(FreshTestId)
    check byTest[FreshTestId]{"samples"}.getInt() == 0
    check byTest[FreshTestId]{"source"}.getStr() == "fallback"
    check byTest[FreshTestId]{"timeoutSec"}.getInt() == 120
    check byTest[FreshTestId]{"timeoutSec"}.getInt() !=
      byTest[SplitTestId]{"timeoutSec"}.getInt()

    # ---- and the METRIC is really used ------------------------------
    #
    # With no floor and a x100 multiplier the timeout is derived from the
    # measured p99 itself. The bound below is on a MEASURED quantity with
    # a wide margin — each case sleeps 40ms, so p99 x 100 is at least 4
    # seconds and the assertion is that it cleared 1 — and the load-
    # bearing half of the assertion is the SOURCE, which no sampling
    # decides.
    let derived = runRunner(env, "derived", @[],
      extraArgs = @[NoRecord, "--adaptive-timeout",
        "--adaptive-timeout-minimum=0",
        "--adaptive-timeout-metric=p99", "--adaptive-timeout-multiplier=100"],
      binDir = scheduleBinDir)
    checkpoint("derived: " & derived.output)
    for entry in derived.summary["summary"]["scheduling"]{"adaptiveTimeout"}{"cases"}:
      if entry{"testId"}.getStr() == FreshTestId:
        continue
      checkpoint("derived case " & entry{"testId"}.getStr())
      check entry{"source"}.getStr() in ["history", "capped"]
      check entry{"timeoutSec"}.getInt() >= 1
      check entry{"metricMs"}.getInt() >= 10

    # ---- the derived timeout is APPLIED, not merely reported ---------
    #
    # WITHOUT THIS ARM EVERY ASSERTION ABOVE IS ABOUT A JSON DOCUMENT.
    # The runner could compute a per-case timeout, write it into the
    # summary, and hand the run-wide value to the spawn path; nothing
    # read so far would notice. So one case is made to outlive its own
    # derived timeout and the run's verdict is read instead of its plan.
    #
    # THE MARGIN IS 3x AND NEITHER SIDE IS SAMPLED. The case sleeps six
    # seconds with no output; the derived timeout is the two-second
    # FLOOR (0.05 x a ~6000ms p99 is 300ms, far under it), so the value
    # is a configured constant rather than a percentile. The control is
    # the same binary at the same ``--test-timeout=120`` with the flag
    # off, which passed a moment ago.
    let slowBinDir = env.tempRoot / "bin-slow"
    createDir(slowBinDir)
    writeFile(env.tempRoot / "src" / "t_m21_slow.nim", """
import std/os
import ct_test_unittest_parallel

suite "m21":
  test "slow":
    sleep(6000)
    check true
""")
    if not compileFixture(env.tempRoot, env.tempRoot / "src" / "t_m21_slow.nim",
        slowBinDir / addFileExt("t_m21_slow", ExeExt)):
      raise newException(OSError, "M21 slow fixture did not compile")

    # THE CONTROL, AND IT RUNS FIRST: with no adaptive timeout the case
    # completes and passes under the same 120-second run-wide value.
    let slowControl = runRunner(env, "slowcontrol", @[], binDir = slowBinDir)
    checkpoint("slow control: " & slowControl.output)
    check slowControl.summary["summary"]["total"].getInt() == 1
    check slowControl.summary["summary"]["passed"].getInt() == 1
    check slowControl.summary["summary"]["failed"].getInt() == 0
    check slowControl.summary["summary"]["runquota_history"].getBool()
    # Its duration is now in the store, which is what the derived
    # timeout below is derived from.
    discard waitForExtRows(env.socketPath, GenericExtensionId,
      GenericColumns, 2 * FixtureStems.len + 1)

    let slowKilled = runRunner(env, "slowkill", @[],
      extraArgs = @[NoRecord, "--adaptive-timeout",
        "--adaptive-timeout-minimum=2", "--adaptive-timeout-metric=p99",
        "--adaptive-timeout-multiplier=0.05"],
      binDir = slowBinDir)
    checkpoint("slow killed: " & slowKilled.output)
    let slowPlan =
      slowKilled.summary["summary"]["scheduling"]{"adaptiveTimeout"}
    check slowPlan{"cases"}.len == 1
    check slowPlan{"cases"}[0]{"source"}.getStr() == "minimum"
    check slowPlan{"cases"}[0]{"timeoutSec"}.getInt() == 2
    check slowPlan{"cases"}[0]{"samples"}.getInt() == 1
    # THE VERDICT, NOT THE PLAN. Same binary, same run-wide timeout, one
    # extra flag — and the case is now killed.
    check slowKilled.summary["summary"]["total"].getInt() == 1
    check slowKilled.summary["summary"]["failed"].getInt() == 1
    check slowKilled.summary["summary"]["passed"].getInt() == 0
    check slowKilled.summary["summary"]["passed"].getInt() !=
      slowControl.summary["summary"]["passed"].getInt()

    # ---- §17.5: duration sharding over two slices --------------------
    var shardCases = initHashSet[string]()
    var shardTotal = 0
    for slice in 1 .. 2:
      let sharded = runRunner(env, "shard" & $slice, @[],
        extraArgs = @[NoRecord, "--partition=slice:" & $slice & "/2",
          "--shard-strategy=duration"],
        binDir = scheduleBinDir)
      checkpoint("shard " & $slice & ": " & sharded.output)
      let shard = sharded.summary["summary"]["scheduling"]{"shard"}
      check shard{"requestedStrategy"}.getStr() == "duration"
      # THE STRATEGY ACTUALLY APPLIED, not the one requested. A plan that
      # echoed the request would hide the fallback the next arm proves.
      check shard{"appliedStrategy"}.getStr() == "duration"
      check not shard{"fellBack"}.getBool()
      check shard{"casesWithHistory"}.getInt() == FixtureStems.len
      check shard{"casesWithoutHistory"}.getInt() == 1
      check shard{"casesBefore"}.getInt() == FixtureStems.len + 1
      shardTotal += shard{"casesAfter"}.getInt()
      for entry in sharded.summary["tests"]:
        let name = entry["qualified_name"].getStr()
        # DISJOINT: no case may appear in two slices, which is the one
        # property a sharding bug turns into duplicated or lost work.
        check name notin shardCases
        shardCases.incl(name)
    # AND EXHAUSTIVE: the two slices together are the whole run.
    check shardTotal == FixtureStems.len + 1
    check shardCases == toHashSet([SplitTestId, RegressionTestId, RedTestId,
      GreenTestId, FreshTestId])

    # ---- the documented fallback, with no history to read ------------
    #
    # A socket nothing is bound to. OS-4: this is not an error, the run
    # proceeds, and the plan SAYS it fell back rather than presenting a
    # count split as a duration one.
    let unbound = env.tempRoot / "absent.sock"
    let fellBack = runRunner(env, "fallback", @[],
      extraArgs = @[NoRecord, "--partition=slice:1/2",
        "--shard-strategy=duration",
        "--adaptive-timeout", "--adaptive-timeout-minimum=30"],
      binDir = scheduleBinDir, socketPath = unbound)
    checkpoint("fallback: " & fellBack.output)
    let fallbackPlan = fellBack.summary["summary"]["scheduling"]
    check not fallbackPlan{"historyAvailable"}.getBool()
    check fallbackPlan{"historyRows"}.getInt() == 0
    let fallbackShard = fallbackPlan{"shard"}
    check fallbackShard{"requestedStrategy"}.getStr() == "duration"
    check fallbackShard{"appliedStrategy"}.getStr() == "count"
    check fallbackShard{"fellBack"}.getBool()
    check fallbackShard{"reason"}.getStr().len > 0
    check fallbackShard{"casesWithHistory"}.getInt() == 0
    # Every case takes the configured fallback timeout, not a derived
    # one — "absent history" is not "a measurement of zero". The count is
    # the SHARD's case count, because timeouts are computed after the
    # partition has already removed the cases this slice will not run.
    let fallbackTimeouts = fallbackPlan{"adaptiveTimeout"}
    check fallbackTimeouts{"fromHistory"}.getInt() == 0
    check fallbackTimeouts{"fromFallback"}.getInt() ==
      fallbackShard{"casesAfter"}.getInt()
    check fallbackTimeouts{"cases"}.len > 0
    for entry in fallbackTimeouts{"cases"}:
      check entry{"source"}.getStr() == "fallback"
      check entry{"timeoutSec"}.getInt() == 120
    # A MISSING DAEMON IS NOT AN ERROR (OS-4): "a missing daemon MUST NOT
    # be reported as an error".
    #
    # ASSERTED PER LINE, AND ONLY OVER THE LINES THAT MENTION RUNQUOTA.
    # A whole-output ``"error" notin`` is not the property — the runner's
    # ordinary summary line carries ``error=0`` — and a check that
    # matched it would be red on every correct run. There ARE runquota
    # lines here (the degradation announces itself), so the loop is not
    # over an empty set.
    var runquotaLines = 0
    for line in fellBack.output.splitLines():
      let lower = line.toLowerAscii()
      if "runquota" notin lower:
        continue
      inc runquotaLines
      checkpoint("runquota line: " & line)
      check "error" notin lower
      check "fail" notin lower
    check runquotaLines > 0

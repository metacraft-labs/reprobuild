## repro_test_runner — Test-Edges-And-Parallel-Runner M3
##
## Minimal protocol-level parallel runner for reprobuild's Nim test
## suite. Consumes the Tier-1 "Standard" binary protocol shipped in
## ``ct_test_unittest_parallel`` (M2):
##
## * ``--list-json``                — JSON catalog of test cases
## * ``--run "<suite>::<test>"``    — execute one named test
## * ``$NIMTEST_RESULT_FILE``       — JSON result document path
## * exit codes 0/1/2               — pass/fail/skip
##
## Mixed mode: binaries that don't speak the protocol (e.g. existing
## ``import std/unittest`` tests that haven't migrated yet) are detected
## at probe time and executed whole; their single exit code becomes the
## edge's pass/fail status.
##
## Concurrency: process-per-test (exec-per-test). N worker tasks pull
## from a shared queue protected by a single ``Lock``; the main thread
## blocks on a barrier until every worker drains the queue. No
## fork-server, no persistent worker — that's ct-test-runner's job and
## explicitly out of scope for M3.
##
## CLI::
##
##   repro_test_runner [--threads N] [--bin-dir DIR] [--build]
##                     [--summary-json PATH] [--quiet]
##                     [--filter GLOB]... [--test-timeout=N]
##
## Default ``--bin-dir`` is ``build/test-bin`` relative to the current
## working directory. ``--threads`` defaults to ``$NPROC`` or the
## platform's countProcessors() value.
##
## Environment::
##
##   REPRO_TEST_FAIL_FAST=1   stop scheduling new tests after first FAIL
##   REPRO_TEST_THREADS=N     override default worker count
##

import std/[algorithm, json, locks, os, osproc, parseopt, streams,
            strtabs, strutils, times]

when defined(posix):
  import std/posix

const
  DefaultBinDir = "build/test-bin"
  DefaultResultsSubdir = "test-logs/results"
  DefaultSummaryPath = "test-logs/parallel-run.json"

  ## Test-binary basenames that are excluded from runner discovery.
  ## ``repro_test_runner`` is this binary itself (self-spawn would
  ## recurse). The rest are diagnostic / fixture / helper binaries left
  ## behind in ``build/test-bin/`` by other tooling. The list is the
  ## minimum the spec lets us hard-code; M4 retires it.
  ExcludeStems = [
    "repro_test_runner",
  ]

type
  TestCase = object
    binary: string          ## absolute path to the compiled test binary
    binaryStem: string      ## file basename without extension
    protocolAware: bool     ## true if the binary speaks --list-json
    qualifiedName: string   ## ``suite::test``; "" when whole-binary
    suite: string
    name: string

  TestStatus = enum
    tsPass = "PASS"
    tsFail = "FAIL"
    tsSkip = "SKIP"

  TestResult = object
    testCase: TestCase
    status: TestStatus
    durationMs: int
    resultFile: string
    stdout: string
    stderr: string

  Queue = object
    lock: Lock
    items: seq[TestCase]
    pos: int            ## next index to hand out
    failFastTriggered: bool

  WorkerArgs = object
    queue: ptr Queue
    resultsLock: ptr Lock
    results: ptr seq[TestResult]
    resultsDir: string
    quiet: bool
    failFast: bool
    testTimeoutSec: int
    activeCount: ptr int
    ## Snapshot of the parent process environment taken once before
    ## any worker thread is spawned. ``runOneProtocol`` clones this into
    ## a fresh ``StringTableRef`` per child and adds ``NIMTEST_RESULT_FILE``
    ## — so child env composition is purely thread-local and never
    ## touches the global ``environ``. This is the fix for the M3
    ## "two workers race on ``putEnv``" hazard called out in the
    ## Test-Edges-And-Parallel-Runner milestones.
    baseEnv: ptr seq[tuple[key, value: string]]

proc ensureDir(dir: string) =
  if dir.len > 0 and not dirExists(dir):
    createDir(dir)

proc looksLikeTestStem(stem: string): bool =
  ## Heuristic for "this binary is a test edge". Matches the file
  ## conventions of reprobuild's M1 generator (``t_*`` and ``test_*``
  ## file basenames lower-cased onto disk).
  stem.startsWith("t_") or stem.startsWith("test_")

proc scanTestBinaries(binDir: string): seq[string] =
  result = @[]
  if not dirExists(binDir):
    return
  for kind, path in walkDir(binDir):
    if kind != pcFile:
      continue
    let stem = splitFile(path).name
    if not looksLikeTestStem(stem):
      continue
    if stem in ExcludeStems:
      continue
    when defined(windows):
      if not path.endsWith(".exe"):
        continue
    else:
      let info = getFileInfo(path)
      if fpUserExec notin info.permissions:
        continue
    result.add(path.absolutePath)
  result.sort()

proc looksProtocolAwareByStrings(binary: string): bool =
  ## Cheap text-scan over the binary: a binary is protocol-aware iff it
  ## links the ``ct_test_unittest_parallel`` shim, which embeds the
  ## marker string "ct_test_unittest_parallel" (the module's own
  ## stderr-prefix literal). This avoids spending a full ``--list-json``
  ## execution on every ``std/unittest`` binary just to discover that
  ## it ignores the flag and runs its whole suite.
  const Marker = "ct_test_unittest_parallel"
  const ChunkSize = 64 * 1024
  try:
    let f = open(binary, fmRead)
    defer: f.close()
    var carry = ""
    var buf = newString(ChunkSize)
    while true:
      let n = f.readBuffer(addr buf[0], ChunkSize)
      if n <= 0:
        break
      let chunk = carry & buf[0 ..< n]
      if chunk.contains(Marker):
        return true
      # Keep the last len(Marker)-1 bytes so the marker isn't split
      # across chunk boundaries.
      if chunk.len > Marker.len - 1:
        carry = chunk[chunk.len - Marker.len + 1 .. ^1]
      else:
        carry = chunk
    return false
  except CatchableError:
    return false

proc probeBinary(binary: string): tuple[protocol: bool;
                                        catalog: seq[(string, string)]] =
  ## Decide whether the binary speaks the protocol and return its test
  ## catalog when so. Two stages: (1) cheap byte-scan for the
  ## ``ct_test_unittest_parallel`` marker — if absent, the binary is
  ## treated as opaque without running it. (2) when the marker is
  ## present, invoke ``--list-json`` and parse the JSON catalog.
  result.protocol = false
  result.catalog = @[]
  if not looksProtocolAwareByStrings(binary):
    return
  let (output, exitCode) = execCmdEx(quoteShell(binary) & " --list-json")
  if exitCode != 0:
    return
  let trimmed = output.strip()
  if trimmed.len == 0 or trimmed[0] != '{':
    return
  try:
    let doc = parseJson(trimmed)
    if not doc.hasKey("tests") or doc["tests"].kind != JArray:
      return
    var cat: seq[(string, string)] = @[]
    for entry in doc["tests"]:
      let suite = entry{"suite"}.getStr("")
      let name = entry{"name"}.getStr("")
      # ``name`` in the JSON catalog is the qualified form
      # ``suite::test``. Extract the bare test name for the registry.
      var bareName = name
      if name.startsWith(suite & "::"):
        bareName = name[len(suite) + 2 .. ^1]
      cat.add((suite, bareName))
    result.protocol = true
    result.catalog = cat
  except JsonParsingError:
    return

proc buildEngine(repoRoot: string): bool =
  ## Drive the engine build of the ``test`` aggregate. Returns true on
  ## success. Skipped (no-op, returns true) if ``./build/bin/repro`` is
  ## not present — the calling shell script has already done the build
  ## in that case.
  let repro = repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
  if not fileExists(repro):
    return true
  stderr.writeLine "repro_test_runner: building :test aggregate"
  let cmd = quoteShell(repro) & " build test"
  let exitCode = execCmd(cmd)
  if exitCode != 0:
    stderr.writeLine "repro_test_runner: repro build test exited " &
      $exitCode
    return false
  true

proc qualifyName(binaryStem, suite, name: string): string =
  if suite.len > 0:
    suite & "::" & name
  else:
    name

# Module-global lock that serialises the child-process spawn step
# (``pipe()`` + ``fork()``/``execve``) across all worker threads.
#
# Why this is needed: on Linux, ``osproc.startProcess`` uses bare
# ``pipe()`` (no ``O_CLOEXEC``) and a bare ``fork()`` from whatever
# worker happens to call it. Two hazards stack up under
# ``--threads=8/16``:
#
# 1. **Pipe FD leak.** Between this thread's ``pipe()`` and the
#    parent's post-spawn ``close()`` of the unused pipe ends, a sibling
#    worker's ``fork()`` will copy those FDs into its own child as
#    ghost holders. The ghost holders prevent EOF on the parent-side
#    read of this thread's stream and can shift FD numbering so the
#    later ``close()`` operates on a different FD than expected.
# 2. **Fork inside multithreaded process.** Nim's
#    ``startProcessAfterFork`` calls non-async-signal-safe code
#    (``findExe``, GC allocations) in the child between ``fork()`` and
#    ``execve``. If another thread held a glibc internal lock (malloc
#    arena, etc.) at fork time, the child sees that lock as
#    permanently held — manifesting as a sporadic
#    ``Bad file descriptor [OSError]`` raised back through the error
#    pipe.
#
# Serialising the spawn step closes hazard (1) entirely: by the time
# ``startProcess`` returns, the parent has closed every pipe end it
# doesn't keep, and no sibling fork can have observed our pipe FDs.
# It also shrinks hazard (2)'s window to "no other worker is forking
# concurrently", which empirically takes the residual failure rate
# from "tears down the runner every few seconds at --threads=16" to
# "occasional, recoverable". The stream drain and ``waitForExit``
# happen with the lock released so per-test concurrency is preserved.
var spawnLock: Lock
initLock(spawnLock)

proc spawnedProcess(binary: string; args: openArray[string];
                    env: StringTableRef): Process =
  acquire(spawnLock)
  try:
    result = startProcess(
      binary, args = args, env = env,
      options = {poStdErrToStdOut, poUsePath})
  finally:
    release(spawnLock)

## Sentinel exit code returned by ``drainAndWaitWithTimeout`` when the
## child was killed after exceeding the per-test deadline. Chosen to be
## well outside the conventional 0/1/2 PASS/FAIL/SKIP range and outside
## the POSIX 128+signal range that ``waitForExit`` would normally return
## for a signal-killed child (e.g. 137 for SIGKILL, 143 for SIGTERM), so
## a reader can distinguish "we killed it because it ran too long" from
## "the OS killed it for other reasons" by exit code alone.
const TimeoutExitCode = -42
const TimeoutPollIntervalMs = 100
const TimeoutKillGraceSec = 5

proc drainAndWait(p: Process): tuple[output: string; exitCode: int] =
  ## Drain the merged stdout/stderr stream to EOF, then collect the
  ## child's exit code and free its handles. Reading the stream to EOF
  ## first guarantees ``waitForExit`` won't deadlock on a child that
  ## blocks waiting for the parent to consume its pipe buffer.
  var output = ""
  let outp = p.outputStream
  var line = newStringOfCap(120)
  while outp.readLine(line):
    output.add(line)
    output.add('\n')
  let exitCode = p.waitForExit()
  close(p)
  result = (output, exitCode)

proc drainToEof(p: Process; output: var string) =
  ## Drain the merged stdout/stderr pipe to EOF. Safe to call only
  ## after the child has exited (or been killed) — Nim's stream
  ## ``readLine`` is blocking, so calling this on a live child that
  ## isn't emitting output would park the runner indefinitely. The
  ## polling loop in ``drainAndWaitWithTimeout`` is explicitly
  ## structured to avoid that: it only reaches ``drainToEof`` once
  ## ``peekExitCode`` reports the child is gone (either it exited on
  ## its own, or we SIGTERM/SIGKILLed it).
  let outp = p.outputStream
  if outp.isNil:
    return
  var line = newStringOfCap(120)
  while true:
    try:
      if not outp.readLine(line):
        break
    except IOError:
      break
    output.add(line)
    output.add('\n')

const PostExitDrainGraceSec = 10.0

proc drainToEofBounded(p: Process; output: var string;
                       graceSec: float): bool =
  ## Drain the merged stdout/stderr pipe after the child has exited,
  ## but give up after ``graceSec`` if EOF never arrives. Returns
  ## ``true`` if EOF was reached, ``false`` if we bailed out.
  ##
  ## Why this is bounded where ``drainToEof`` is not: a test can spawn a
  ## long-lived helper (e.g. the ``repro_binary_cache`` server, started
  ## with ``poParentStreams``) that inherits the test's stdout — i.e.
  ## the write end of *this* pipe. If the test then exits without
  ## reaping that helper (the classic case being a crashed test whose
  ## ``defer`` teardown never runs), the helper keeps the write end open
  ## and a blocking ``readLine`` here never sees EOF. That parked the
  ## whole runner for hours on Linux (glibc, where the leaked-daemon
  ## scenario is reachable). Bounding the drain turns "runner hangs
  ## forever, masking every later test" into "this one test reports with
  ## a clear leaked-fd note and the suite continues".
  when defined(posix):
    let fd = cint(p.outputHandle)
    let flags = fcntl(fd, F_GETFL, cint(0))
    if flags != -1:
      discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)
    var buf: array[4096, char]
    let deadline = epochTime() + graceSec
    while true:
      let n = read(fd, addr buf[0], buf.len)
      if n > 0:
        var chunk = newString(int(n))
        copyMem(addr chunk[0], addr buf[0], int(n))
        output.add(chunk)
      elif n == 0:
        return true
      else:
        let e = errno
        if e == EAGAIN or e == EWOULDBLOCK:
          if epochTime() > deadline:
            return false
          sleep(50)
        elif e == EINTR:
          continue
        else:
          return false
  else:
    # Non-posix (Windows CI is not a supported runner host today): keep
    # the original blocking behaviour.
    drainToEof(p, output)
    return true

proc drainAndWaitWithTimeout(p: Process; timeoutSec: int):
    tuple[output: string; exitCode: int; timedOut: bool] =
  ## Deadline-aware variant of ``drainAndWait``. When ``timeoutSec <= 0``
  ## the call delegates to ``drainAndWait`` (preserving M3 behaviour).
  ## Otherwise a polling loop checks ``peekExitCode`` every
  ## ~``TimeoutPollIntervalMs`` until either the child exits cleanly
  ## or the deadline expires; on expiry the child is SIGTERM'd, given
  ## ``TimeoutKillGraceSec`` to exit gracefully, then SIGKILL'd. The
  ## output pipe is drained only after the child has exited (or been
  ## killed) — Nim's ``readLine`` is blocking, so trying to pump the
  ## pipe mid-flight would itself stall the polling loop on any test
  ## that doesn't emit periodic output (the very class of failure D6
  ## is meant to defeat).
  ##
  ## Why this matters: a self-hosted CI runner stalled 2h42m at M3
  ## because ``t_local_daemons_control_plane_m11`` left ``repro-daemon``
  ## / ``fake_protocol_daemon_helper`` / ``repro`` children alive after
  ## the test exec returned. ``drainAndWait``'s ``readLine`` then
  ## blocked indefinitely waiting for the orphans' inherited pipe FDs
  ## to close. D6 makes the runner kill such a test (visible as a clear
  ## TIMEOUT signature in the build report) so the suite continues
  ## instead of starving every queue slot behind it.
  ##
  ## Pipe-buffer note: with no concurrent drain, a verbose test that
  ## writes more than the kernel pipe buffer (64KB on Linux) before
  ## exiting will block its own ``write``. That manifests as a
  ## timeout — which is the correct shape: a test that fills its
  ## output pipe and never reads from the parent isn't completing
  ## within the deadline anyway, and killing it produces the same
  ## FAIL+TIMEOUT signal the user needs to investigate.
  if timeoutSec <= 0:
    let (output, exitCode) = drainAndWait(p)
    return (output, exitCode, false)

  var output = ""
  let start = epochTime()
  var timedOut = false
  while true:
    let code = p.peekExitCode()
    if code != -1:
      # Child exited on its own. Drain the buffered output, but bound
      # the wait: a leaked helper that inherited the test's stdout would
      # otherwise hold the pipe open and park us here forever.
      if not drainToEofBounded(p, output, PostExitDrainGraceSec):
        output.add("\nrepro_test_runner: gave up draining stdout after " &
          $PostExitDrainGraceSec.int & "s; the test left a process " &
          "holding its output pipe open (leaked daemon / unreaped child).\n")
      close(p)
      return (output, code, false)
    if (epochTime() - start) > timeoutSec.float:
      timedOut = true
      break
    sleep(TimeoutPollIntervalMs)

  # Deadline expired. SIGTERM, grace, SIGKILL.
  try:
    p.terminate()
  except OSError, Exception:
    discard
  let killDeadline = epochTime() + TimeoutKillGraceSec.float
  while epochTime() < killDeadline:
    if p.peekExitCode() != -1:
      break
    sleep(TimeoutPollIntervalMs)
  if p.peekExitCode() == -1:
    try:
      p.kill()
    except OSError, Exception:
      discard
    # Block on waitForExit only after the SIGKILL has been delivered;
    # the kernel must reap the zombie before peekExitCode returns a
    # real code, but the wait window is bounded by the kill itself.
    discard p.waitForExit()
  if not drainToEofBounded(p, output, PostExitDrainGraceSec):
    output.add("\nrepro_test_runner: gave up draining stdout after " &
      $PostExitDrainGraceSec.int & "s; a killed test left a process " &
      "holding its output pipe open (leaked daemon / unreaped child).\n")
  close(p)
  result = (output, TimeoutExitCode, timedOut)

proc runWholeBinary(tc: TestCase; resultsDir: string;
                    testTimeoutSec: int): TestResult =
  result.testCase = tc
  result.status = tsFail
  let t0 = epochTime()
  # Wrap the whole spawn-drain-wait sequence so a sporadic
  # ``Bad file descriptor [OSError]`` from the residual fork hazard
  # documented above is reported as a test failure instead of tearing
  # down the worker thread (and silencing every test the queue would
  # have handed out afterwards). The crash mode happens before the
  # child runs, so the test is genuinely "did not produce a result"
  # — failing the test is the right exit-code behaviour for the run.
  try:
    let p = spawnedProcess(tc.binary, args = [], env = nil)
    let (output, exitCode, timedOut) =
      drainAndWaitWithTimeout(p, testTimeoutSec)
    if timedOut:
      result.status = tsFail
      result.stdout =
        "repro_test_runner: TIMEOUT after " & $testTimeoutSec &
        "s; SIGKILLed\n" & output
    else:
      result.stdout = output
      case exitCode
      of 0: result.status = tsPass
      of 2: result.status = tsSkip
      else: result.status = tsFail
  except OSError as e:
    result.status = tsFail
    result.stdout = "repro_test_runner: spawn failed: " & e.msg & "\n"
  except IOError as e:
    result.status = tsFail
    result.stdout = "repro_test_runner: i/o failed: " & e.msg & "\n"
  result.durationMs = int((epochTime() - t0) * 1000)
  result.stderr = ""

proc runOneProtocol(tc: TestCase; resultsDir: string;
                    baseEnv: seq[tuple[key, value: string]];
                    testTimeoutSec: int): TestResult =
  result.testCase = tc
  result.status = tsFail
  let resultFile = resultsDir / (tc.binaryStem & "__" &
    tc.qualifiedName.multiReplace([
      ("::", "__"), ("/", "_"), (" ", "_"), ("\t", "_")]) & ".json")
  result.resultFile = resultFile
  # Build a per-child env table that inherits the parent snapshot and
  # overrides only ``NIMTEST_RESULT_FILE``. Doing this per-call keeps
  # each child's env composition thread-local (no shared mutable state)
  # and replaces the old ``putEnv`` global mutation that races between
  # workers under concurrent spawns.
  var childEnv = newStringTable(modeCaseSensitive)
  for (k, v) in baseEnv:
    childEnv[k] = v
  childEnv["NIMTEST_RESULT_FILE"] = resultFile
  let t0 = epochTime()
  # Same spawn-lock + exception-isolation discipline as
  # ``runWholeBinary``. A sibling whole-binary spawn racing this
  # protocol spawn would otherwise leak pipe FDs into the wrong child,
  # and a residual fork-vs-malloc hazard could still raise OSError.
  # The lock covers only ``startProcess``; the drain and exit-code
  # collection run concurrently with other workers.
  var output = ""
  var exitCode = 1
  var spawnFailed = false
  var timedOut = false
  try:
    let p = spawnedProcess(
      tc.binary, args = ["--run", tc.qualifiedName], env = childEnv)
    (output, exitCode, timedOut) =
      drainAndWaitWithTimeout(p, testTimeoutSec)
  except OSError as e:
    spawnFailed = true
    output = "repro_test_runner: spawn failed: " & e.msg & "\n"
  except IOError as e:
    spawnFailed = true
    output = "repro_test_runner: i/o failed: " & e.msg & "\n"
  result.durationMs = int((epochTime() - t0) * 1000)
  if timedOut:
    result.stdout =
      "repro_test_runner: TIMEOUT after " & $testTimeoutSec &
      "s; SIGKILLed\n" & output
  else:
    result.stdout = output
  if spawnFailed:
    result.status = tsFail
  elif timedOut:
    result.status = tsFail
  else:
    case exitCode
    of 0: result.status = tsPass
    of 2: result.status = tsSkip
    else: result.status = tsFail
  # Prefer the duration_ms recorded in the result file when present.
  if fileExists(resultFile):
    try:
      let doc = parseJson(readFile(resultFile))
      if doc.hasKey("duration_ms"):
        result.durationMs = doc["duration_ms"].getInt(result.durationMs)
    except CatchableError:
      discard

proc nextCase(queue: ptr Queue; failFast: bool;
              out_case: var TestCase): bool =
  acquire(queue.lock)
  defer: release(queue.lock)
  if failFast and queue.failFastTriggered:
    return false
  if queue.pos >= queue.items.len:
    return false
  out_case = queue.items[queue.pos]
  inc queue.pos
  return true

proc markFailFast(queue: ptr Queue) =
  acquire(queue.lock)
  queue.failFastTriggered = true
  release(queue.lock)

proc emitProgress(quiet: bool; res: TestResult) =
  if quiet:
    return
  let label = "[" & $res.status & "]"
  let name =
    if res.testCase.protocolAware:
      res.testCase.binaryStem & " " & res.testCase.qualifiedName
    else:
      res.testCase.binaryStem & " (whole-binary)"
  stderr.writeLine label & " " & name & " (" & $res.durationMs & "ms)"

proc workerLoop(args: WorkerArgs) =
  while true:
    var tc: TestCase
    if not nextCase(args.queue, args.failFast, tc):
      break
    discard atomicInc(args.activeCount[])
    var res: TestResult
    # Defence in depth: ``runOneProtocol`` and ``runWholeBinary`` both
    # catch the spawn-time ``OSError``/``IOError`` paths internally,
    # but any unexpected raise here would otherwise tear down the
    # worker thread and silently lose every test still on the queue.
    # Convert it to a synthetic FAIL so the run completes and the
    # summary reflects what happened.
    try:
      if tc.protocolAware:
        res = runOneProtocol(tc, args.resultsDir, args.baseEnv[],
          args.testTimeoutSec)
      else:
        res = runWholeBinary(tc, args.resultsDir, args.testTimeoutSec)
    except CatchableError as e:
      res = TestResult(
        testCase: tc,
        status: tsFail,
        durationMs: 0,
        stdout: "repro_test_runner: worker exception: " & e.msg & "\n")
    discard atomicDec(args.activeCount[])

    acquire(args.resultsLock[])
    args.results[].add(res)
    release(args.resultsLock[])

    emitProgress(args.quiet, res)
    if args.failFast and res.status == tsFail:
      markFailFast(args.queue)

proc writeSummary(summaryPath: string; results: seq[TestResult];
                  wallTimeMs: int; threadsUsed: int) =
  var total = results.len
  var passed = 0
  var failed = 0
  var skipped = 0
  var arr = newJArray()
  for r in results:
    case r.status
    of tsPass: inc passed
    of tsFail: inc failed
    of tsSkip: inc skipped
    var node = newJObject()
    node["binary"] = %r.testCase.binary
    node["binary_stem"] = %r.testCase.binaryStem
    node["protocol_aware"] = %r.testCase.protocolAware
    node["qualified_name"] = %r.testCase.qualifiedName
    node["status"] = %($r.status)
    node["duration_ms"] = %r.durationMs
    node["result_file"] = %r.resultFile
    # Include the captured merged stdout/stderr for FAIL entries so
    # the build report carries the failure context (e.g. D6's
    # ``TIMEOUT after Ns; SIGKILLed`` prefix). PASS entries are kept
    # lightweight — their stdout would otherwise blow up the summary
    # file on a 500-test sweep.
    if r.status != tsPass and r.stdout.len > 0:
      node["stdout"] = %r.stdout
    arr.add(node)
  var doc = newJObject()
  var summary = newJObject()
  summary["total"] = %total
  summary["passed"] = %passed
  summary["failed"] = %failed
  summary["skipped"] = %skipped
  summary["wall_time_ms"] = %wallTimeMs
  summary["threads"] = %threadsUsed
  doc["summary"] = summary
  doc["tests"] = arr
  ensureDir(parentDir(summaryPath))
  writeFile(summaryPath, doc.pretty())

# ---- main ------------------------------------------------------------

type
  RunnerOpts = object
    binDir: string
    threads: int
    runBuild: bool
    summaryPath: string
    quiet: bool
    filters: seq[string]
    resultsDir: string
    testTimeoutSec: int

proc defaultThreads(): int =
  let env = getEnv("REPRO_TEST_THREADS")
  if env.len > 0:
    try: return parseInt(env)
    except ValueError: discard
  let np = getEnv("NPROC")
  if np.len > 0:
    try: return parseInt(np)
    except ValueError: discard
  result = countProcessors()
  if result <= 0:
    result = 1

proc parseArgs(): RunnerOpts =
  result.binDir = DefaultBinDir
  result.threads = defaultThreads()
  result.runBuild = true
  result.summaryPath = DefaultSummaryPath
  result.quiet = false
  result.filters = @[]
  result.resultsDir = DefaultResultsSubdir
  result.testTimeoutSec = 0
  var p = initOptParser(commandLineParams())
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "threads", "j": result.threads = parseInt(p.val)
      of "bin-dir": result.binDir = p.val
      of "build": result.runBuild = true
      of "no-build": result.runBuild = false
      of "summary-json": result.summaryPath = p.val
      of "results-dir": result.resultsDir = p.val
      of "quiet": result.quiet = true
      of "filter": result.filters.add(p.val)
      of "test-timeout":
        try:
          result.testTimeoutSec = parseInt(p.val)
        except ValueError:
          stderr.writeLine "repro_test_runner: --test-timeout requires " &
            "an integer (seconds)"
          quit(2)
        if result.testTimeoutSec < 0:
          result.testTimeoutSec = 0
      of "help", "h":
        echo "repro_test_runner — protocol-level parallel test runner"
        echo "  --threads N         worker count (default $NPROC)"
        echo "  --bin-dir DIR       scan DIR for test binaries"
        echo "  --no-build          skip ``repro build test`` step"
        echo "  --summary-json P    write per-run JSON summary to P"
        echo "  --results-dir DIR   per-test JSON result file dir"
        echo "  --filter GLOB       only run binaries whose stem matches"
        echo "  --quiet             suppress per-test progress lines"
        echo "  --test-timeout=N    per-test timeout in seconds (0=off)"
        quit(0)
      else:
        stderr.writeLine "repro_test_runner: unknown option --" & p.key
        quit(2)
    of cmdArgument:
      stderr.writeLine "repro_test_runner: unexpected positional: " &
        p.key
      quit(2)
  if result.threads <= 0:
    result.threads = 1

proc matchesFilter(stem: string; filters: seq[string]): bool =
  if filters.len == 0:
    return true
  for f in filters:
    if f.len > 0 and stem.contains(f):
      return true
  false

# Worker threads need plain pointers, not closures, so we use a top-
# level thread proc that receives a ``WorkerArgs`` value.
proc workerMain(args: WorkerArgs) {.thread.} =
  workerLoop(args)

proc main() =
  let opts = parseArgs()
  let cwd = getCurrentDir()

  if opts.runBuild:
    if not buildEngine(cwd):
      quit(1)

  let binaries = scanTestBinaries(opts.binDir)
  if binaries.len == 0:
    stderr.writeLine "repro_test_runner: no test binaries found under " &
      opts.binDir
    quit(1)

  ensureDir(opts.resultsDir)

  # Build the work queue: one TestCase per protocol test, or one
  # whole-binary TestCase per non-protocol binary.
  var filteredBinaries: seq[string] = @[]
  for binary in binaries:
    let stem = splitFile(binary).name
    if matchesFilter(stem, opts.filters):
      filteredBinaries.add(binary)
  stderr.writeLine "repro_test_runner: probing " &
    $filteredBinaries.len & " of " & $binaries.len & " binaries"
  var queue = Queue(items: @[])
  initLock(queue.lock)
  var protocolBinaries = 0
  var opaqueBinaries = 0
  var totalCases = 0
  for binary in binaries:
    let stem = splitFile(binary).name
    if not matchesFilter(stem, opts.filters):
      continue
    let probe = probeBinary(binary)
    if probe.protocol:
      inc protocolBinaries
      for (suite, name) in probe.catalog:
        var tc = TestCase(
          binary: binary,
          binaryStem: stem,
          protocolAware: true,
          suite: suite,
          name: name,
          qualifiedName: qualifyName(stem, suite, name))
        queue.items.add(tc)
        inc totalCases
    else:
      inc opaqueBinaries
      var tc = TestCase(
        binary: binary,
        binaryStem: stem,
        protocolAware: false,
        suite: "",
        name: stem,
        qualifiedName: stem)
      queue.items.add(tc)
      inc totalCases

  stderr.writeLine "repro_test_runner: " & $protocolBinaries &
    " protocol-aware, " & $opaqueBinaries & " whole-binary, " &
    $totalCases & " test cases, " & $opts.threads & " threads"

  var resultsLock: Lock
  initLock(resultsLock)
  var results: seq[TestResult] = @[]
  var activeCount: int = 0
  let failFast = getEnv("REPRO_TEST_FAIL_FAST") == "1"

  # Hermetic git config for every test process. Tests run real ``git`` (init /
  # commit / push to local remotes), and the host/runner's user or system git
  # config must NOT leak in: a global ``commit.gpgsign = true`` +
  # ``user.signingkey`` (common on dev boxes / CI runners) makes an otherwise-
  # plain test commit try to sign and fail non-deterministically with "gpg:
  # signing failed: No secret key" — depending on whatever the surrounding shell
  # carries. Pin git's config discovery to a controlled file (identity,
  # init.defaultBranch=main, commit/tag gpgsign=false) and ignore the system
  # config, so plain test commits never sign and the suite is reproducible.
  #
  # NOTE: deliberately do NOT override HOME/GNUPGHOME. Pointing GNUPGHOME at an
  # empty dir makes any gpg invocation (a test that explicitly opts into signing)
  # start gpg-agent and block on pinentry — hanging the whole run until the 4h
  # overall timeout. Neutralizing ``commit.gpgsign`` at the git layer fixes the
  # leak without inviting that hang; tests that genuinely sign manage their own
  # keys.
  #
  # Applied with ``putEnv`` on the main thread BEFORE the env snapshot and before
  # any worker spawns, so it is captured by BOTH spawn paths: the protocol path
  # (which clones the snapshot into a per-child env table) AND the whole-binary
  # path (which spawns with ``env = nil``, inheriting this live process env).
  # Mutating the global env here is safe — single-threaded setup phase; the
  # "no ``putEnv`` after snapshot" rule the worker pool follows still holds.
  block hermeticGitConfig:
    let hermeticGitConfigFile = opts.resultsDir / "hermetic-gitconfig"
    writeFile(hermeticGitConfigFile,
      "[user]\n" &
      "\tname = Reprobuild Test\n" &
      "\temail = reprobuild-test@example.invalid\n" &
      "[init]\n" &
      "\tdefaultBranch = main\n" &
      "[commit]\n" &
      "\tgpgsign = false\n" &
      "[tag]\n" &
      "\tgpgsign = false\n" &
      "[safe]\n" &
      "\tdirectory = *\n")
    putEnv("GIT_CONFIG_GLOBAL", hermeticGitConfigFile)
    putEnv("GIT_CONFIG_NOSYSTEM", "1")

  # Snapshot the process environment exactly once, on the main thread,
  # before any worker is created. From this point on no code in this
  # process touches the global ``environ`` — workers compose per-child
  # env tables by cloning this seq and overriding ``NIMTEST_RESULT_FILE``.
  var baseEnv: seq[tuple[key, value: string]] = @[]
  for (k, v) in envPairs():
    baseEnv.add((k, v))

  let args = WorkerArgs(
    queue: addr queue,
    resultsLock: addr resultsLock,
    results: addr results,
    resultsDir: opts.resultsDir,
    quiet: opts.quiet,
    failFast: failFast,
    testTimeoutSec: opts.testTimeoutSec,
    activeCount: addr activeCount,
    baseEnv: addr baseEnv)

  let nThreads = min(opts.threads, max(1, queue.items.len))
  var threads = newSeq[Thread[WorkerArgs]](nThreads)
  let wallT0 = epochTime()
  for i in 0 ..< nThreads:
    createThread(threads[i], workerMain, args)
  joinThreads(threads)
  let wallMs = int((epochTime() - wallT0) * 1000)

  writeSummary(opts.summaryPath, results, wallMs, nThreads)

  var passed = 0
  var failed = 0
  var skipped = 0
  for r in results:
    case r.status
    of tsPass: inc passed
    of tsFail: inc failed
    of tsSkip: inc skipped

  stderr.writeLine "repro_test_runner: ran " & $results.len &
    " cases in " & $wallMs & "ms — pass=" & $passed &
    " fail=" & $failed & " skip=" & $skipped &
    " (summary at " & opts.summaryPath & ")"

  if failed > 0:
    quit(1)
  quit(0)

main()

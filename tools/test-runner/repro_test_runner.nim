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
##                     [--filter GLOB]...
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

import std/[algorithm, json, locks, os, osproc, parseopt, strtabs,
            strutils, times]

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

proc runWholeBinary(tc: TestCase; resultsDir: string): TestResult =
  result.testCase = tc
  result.status = tsFail
  let t0 = epochTime()
  let (output, exitCode) = execCmdEx(quoteShell(tc.binary))
  result.durationMs = int((epochTime() - t0) * 1000)
  result.stdout = output
  result.stderr = ""
  case exitCode
  of 0: result.status = tsPass
  of 2: result.status = tsSkip
  else: result.status = tsFail

proc runOneProtocol(tc: TestCase; resultsDir: string;
                    baseEnv: seq[tuple[key, value: string]]): TestResult =
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
  let (output, exitCode) = execCmdEx(
    quoteShell(tc.binary) & " --run " &
    quoteShell(tc.qualifiedName),
    env = childEnv)
  result.durationMs = int((epochTime() - t0) * 1000)
  result.stdout = output
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
    if tc.protocolAware:
      res = runOneProtocol(tc, args.resultsDir, args.baseEnv[])
    else:
      res = runWholeBinary(tc, args.resultsDir)
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
      of "help", "h":
        echo "repro_test_runner — protocol-level parallel test runner"
        echo "  --threads N         worker count (default $NPROC)"
        echo "  --bin-dir DIR       scan DIR for test binaries"
        echo "  --no-build          skip ``repro build test`` step"
        echo "  --summary-json P    write per-run JSON summary to P"
        echo "  --results-dir DIR   per-test JSON result file dir"
        echo "  --filter GLOB       only run binaries whose stem matches"
        echo "  --quiet             suppress per-test progress lines"
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

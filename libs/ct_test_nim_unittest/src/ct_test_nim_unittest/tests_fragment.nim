## ct_test_nim_unittest/tests_fragment — a test binary's tests, one created
## action per test.
##
## A test binary built with ``nim-entrypoints`` answers its ``tests`` entry:
##
## * ``<binary> --entrypoint=tests --list`` prints the name of every test,
##   one per line, and runs nothing (in a build that carries ``main``);
## * ``<binary> --entrypoint=tests --run-exact=<name>`` runs exactly the test
##   ``--list`` printed as ``<name>``, never reading it as a pattern.
##
## (https://github.com/metacraft-labs/nim-entrypoints, README §"Tests".)
##
## This module turns the first answer into a ``repro-dynamic-graph-v1``
## fragment whose ``create-action`` records each run the second, so the build
## graph runs, caches and reports a binary's tests one by one. It is the
## library half of the ``repro-tests-fragment`` program
## (``apps/repro-tests-fragment``), which the listing edge of
## ``NimUnittestBinary.runPerTest`` (``ct_test_nim_unittest``) runs, and it
## also holds the command lines the engine lowers that edge and its collector
## to, so the program and the engine cannot disagree about them.
##
## THE RECORD. Every test gets one record:
##
## * ``id``: ``<prefix>.test.<name>``, with every character of the name
##   outside ``[A-Za-z0-9_-]`` replaced by ``_``, and ``-2``, ``-3``, ... on
##   a collision, in listing order;
## * ``argv``: ``[<binary>, "--entrypoint=tests", "--run-exact=<name>"]``;
## * ``inputs``: ``[<binary>]``;
## * ``dependencyPolicy``: the automatic monitor;
## * ``cacheable``: true;
## * ``commandStatsId``: ``<stats name>::<name>``, so RunQuota keeps a
##   duration per test.
##
## and a ``dep`` record makes the collector wait for it. So a created run is
## keyed as a declared execute edge is: on its argv (which names the test),
## its input's content (the binary) and what the monitor saw it read
## (``repro_build_engine``'s ``parseCreateActionRecord``). That is why the
## record names a policy: a cacheable record without one is refused there.
##
## ONE BINARY PER TEST. With ``runPerTest(perTestBinaries = true)`` the
## request also carries the compile of the listed binary, as the engine
## lowered it (``PerTestCompile``), and every test gets a compile of its own
## ahead of its run:
##
## * ``id``: ``<prefix>.compile.<key>``, where ``<key>`` is the part of the
##   run's id after ``.test.``;
## * ``argv``: the listed binary's compile with ``-d:entrypointsTest=<name>``
##   added, ``--out:<dir>/<file>`` moved to
##   ``--out:<dir>/<stem>.per-test/<key>/<file>`` and ``--nimcache:<dir>`` to
##   ``--nimcache:<dir>.per-test/<key>`` (``perTestCompileArgv``);
## * ``cwd``, ``env``, ``envPassthrough`` and ``inputs``: the listed binary's
##   compile's;
## * ``outputs``: the test's binary;
## * ``dependencyPolicy``: the automatic monitor; ``cacheable`` and
##   ``actionCachePolicy`` as the listed binary's compile has them.
##
## The run then launches the test's binary, takes it as its input, depends
## on its compile, and checks its inputs with the ``hybrid`` policy.
## nim-entrypoints builds a ``-d:entrypointsTest=<name>`` binary from that
## one ``testCase``
## (https://github.com/metacraft-labs/nim-entrypoints, README §"Tests"), so
## the binary of a test whose code did not change comes out byte-identical.
## Its compile ran again (the source changed) and wrote it anew, so its
## metadata moved; under the ``hybrid`` policy the engine then re-hashes it,
## finds the content it recorded, and serves the run from the cache (under
## the default ``timestamp`` policy the new metadata alone would rerun it).
## So an edit of one test reruns that test only. A test that is not a
## ``testCase`` (one of a ``tests:`` block) cannot be built alone, so in
## this mode the producer also runs ``<binary> --entrypoint=tests --list
## --list-test-cases`` and fails the listing edge, naming every listed test
## that it does not print, before any compile is created
## (``notBuildableAlone``).
##
## WHAT IS REFUSED, AND WHY. The listing is the only thing that says what
## the binary's tests are, so a listing this module cannot turn into one
## exact run per test fails the listing edge instead of producing a graph
## that silently runs less than it should:
##
## * a listing command that exits non-zero (the binary has no ``tests``
##   entry, or a test name cannot be written on one line: exit 70);
## * an empty listing: a collection that runs no test is not a passing run;
## * an empty name, which ``--run-exact=`` cannot select;
## * a name listed twice. Two tests with one name both run under
##   ``--run-exact=<name>``, so the two records would run the same pair of
##   tests twice and neither would be the test its id names. The binary has
##   to give them distinct names.

import std/[json, os, osproc, sets, strutils]

import repro_core/ambient_execution

when defined(posix):
  import std/posix
else:
  import repro_core/process_streams

const
  TestsFragmentProducerName* = "repro-tests-fragment"
    ## The program's name in ``apps/entrypoints.txt``. The engine finds it
    ## beside its own image, as it finds its other helper programs.
  TestsEntryArg* = "--entrypoint=tests"
    ## Selects a binary's ``tests`` entry at run time.
  TestsEntryListArg* = "--list"
  TestsEntryListTestCasesArg* = "--list-test-cases"
    ## Lists only the ``testCase`` names, the tests a
    ## ``-d:entrypointsTest=<name>`` build can be made for.
  TestsEntryRunExactPrefix* = "--run-exact="
  DynamicGraphHeader = "repro-dynamic-graph-v1"
  CreatedRunPolicyKind = "automaticMonitor"
    ## ``dependencyPolicy.kind`` of every created run: the engine's
    ## ``CreatedActionAutomaticMonitor``, the DSL's
    ## ``automaticMonitorPolicy()``. Spelled here rather than imported so
    ## the producer program does not link the build engine.

type
  TestsFragmentError* = object of CatchableError
    ## A listing that cannot become one exact run per test, a fragment that
    ## cannot be read back, or a malformed command line.

  PerTestCompile* = object
    ## The compile of the listed binary, as the engine lowered it: the
    ## template of every test's own compile (see "ONE BINARY PER TEST" in
    ## the module header). An empty ``argv`` means one binary for every
    ## test.
    argv*: seq[string]
    cwd*: string
    env*: seq[string]
      ## ``NAME=value`` entries.
    envPassthrough*: seq[string]
    inputs*: seq[string]
    uncacheable*: bool
      ## The listed binary's compile is not cacheable, so neither is a
      ## test's.
    actionCachePolicy*: string
      ## The listed binary's compile's input-check policy, in the
      ## ``create-action`` spelling (``timestamp``, ``hybrid``,
      ## ``checksum``); "" for the engine's default.

  PerTestRequest* = object
    ## What the listing edge knows when it runs the producer.
    binary*: string
      ## The test binary, as the created runs launch it (absolute).
    fragment*: string
      ## Where the fragment is written.
    idPrefix*: string
      ## The prefix of every created action's id.
    collectorId*: string
      ## The action that waits for every created run.
    statsName*: string
      ## The binary's name in ``commandStatsId`` (the path the recipe
      ## declared, not the absolute one, so durations are kept per test
      ## whichever checkout ran them).
    cwd*: string
      ## The created runs' working directory.
    compile*: PerTestCompile
      ## Set for one binary per test.

  ProducerCommandKind* = enum
    pckList   ## list the binary's tests and write the fragment
    pckCheck  ## read a fragment back and report how many runs it creates

  ProducerCommand* = object
    case kind*: ProducerCommandKind
    of pckList:
      request*: PerTestRequest
    of pckCheck:
      fragment*: string

proc runExactArgv*(binary, name: string): seq[string] =
  ## The command line that runs the test ``--list`` printed as ``name``.
  @[binary, TestsEntryArg, TestsEntryRunExactPrefix & name]

proc listArgv*(binary: string): seq[string] =
  ## The command line that lists ``binary``'s tests.
  @[binary, TestsEntryArg, TestsEntryListArg]

proc listTestCasesArgv*(binary: string): seq[string] =
  ## The command line that lists ``binary``'s ``testCase`` tests alone.
  ## ``--list`` comes first, so a binary whose tests entry predates
  ## ``--list-test-cases`` still only lists (it prints every name) and runs
  ## nothing.
  @[binary, TestsEntryArg, TestsEntryListArg, TestsEntryListTestCasesArg]

proc parseTestListing*(output: string; binary = ""): seq[string] =
  ## The test names in ``output``, the standard output of
  ## ``<binary> --entrypoint=tests --list``, in the order listed. Refuses an
  ## empty listing, an empty name and a name listed twice (see the module
  ## header); ``binary`` only names the binary in the message.
  let who = if binary.len > 0: binary else: "the test binary"
  var lines = output.split('\n')
  # The listing ends with a line break, so its last piece is empty.
  if lines.len > 0 and lines[^1].len == 0:
    lines.setLen(lines.len - 1)
  var seen = initHashSet[string]()
  var duplicates: seq[string] = @[]
  for index, raw in lines:
    # A carriage return can only be the line ending of a text-mode stream:
    # the tests entry refuses a name that contains one.
    let name = if raw.endsWith('\r'): raw[0 ..< raw.high] else: raw
    if name.len == 0:
      raise newException(TestsFragmentError, who & " listed an empty test " &
        "name (line " & $(index + 1) & "), which --run-exact= cannot select")
    if seen.containsOrIncl(name):
      if name notin duplicates:
        duplicates.add(name)
      continue
    result.add(name)
  if duplicates.len > 0:
    var quoted: seq[string] = @[]
    for name in duplicates:
      quoted.add(name.escape())
    raise newException(TestsFragmentError, who & " lists " &
      quoted.join(", ") & " more than once. Every test of a binary run " &
      "per test needs a name of its own: --run-exact=<name> runs every " &
      "test with that name, so one run per listed name would run the same " &
      "tests twice and neither run would be the test it names. Rename the " &
      "tests so each name is listed once")
  if result.len == 0:
    raise newException(TestsFragmentError, who & " lists no tests. A " &
      "per-test collection of a binary that has none would run nothing " &
      "and pass; declare the binary's tests (testCase, or a tests: block) " &
      "or run it as a whole")

proc notBuildableAlone*(names, testCases: openArray[string];
                        binary = ""): string =
  ## "" when every listed name in ``names`` is one of ``testCases`` (what
  ## ``--list-test-cases`` printed); otherwise the refusal of one binary per
  ## test, naming each test that is not a ``testCase``. Such a test belongs
  ## to a ``tests:`` block, whose framework runs the whole block, so
  ## nim-entrypoints cannot compile it alone and its per-test compile would
  ## fail. ``binary`` only names the binary in the message.
  let who = if binary.len > 0: binary else: "the test binary"
  let buildable = toHashSet(testCases)
  var refused: seq[string] = @[]
  for name in names:
    if name notin buildable:
      refused.add(name.escape())
  if refused.len == 0:
    return ""
  who & ": one binary per test (perTestBinaries = true) builds each test " &
    "with -d:entrypointsTest=<name>, which compiles a testCase alone, and " &
    "these tests are not testCases (they belong to a tests: block, whose " &
    "framework runs the whole block): " & refused.join(", ") & ". Declare " &
    "them with testCase, or turn perTestBinaries off to run every test " &
    "from one binary"

proc testActionIdPart*(name: string): string =
  ## ``name`` spelled with the characters an action id part keeps.
  for ch in name:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '-'}:
      result.add(ch)
    else:
      result.add('_')

proc perTestActionIds*(idPrefix: string; names: openArray[string]):
    seq[string] =
  ## The created action's id for each of ``names``, in order. Two names that
  ## spell the same (``a b`` and ``a_b``) get ``-2``, ``-3``, ... in listing
  ## order, so every id is unique and the same listing always gives the same
  ## ids (they are part of each run's cache key).
  var taken = initHashSet[string]()
  for name in names:
    let base = idPrefix & ".test." & testActionIdPart(name)
    var candidate = base
    var suffix = 2
    while taken.contains(candidate):
      candidate = base & "-" & $suffix
      inc suffix
    taken.incl(candidate)
    result.add(candidate)

const
  NimOutFlag = "--out:"
  NimNimcacheFlag = "--nimcache:"
  EntrypointsTestDefine* = "-d:entrypointsTest="
    ## nim-entrypoints' define for a binary of one ``testCase``.
  PerTestRunCachePolicy* = "hybrid"
    ## The input-check policy of a run of a test's own binary: its binary
    ## is rewritten whenever the source changes, and is a hit when the
    ## bytes are the recorded ones (see "ONE BINARY PER TEST").

proc perTestCompileArgv*(argv: openArray[string]; name, key: string):
    tuple[argv: seq[string]; output: string] =
  ## The compile of the test ``name``'s own binary, from the compile of the
  ## listed binary (``argv``): ``-d:entrypointsTest=<name>`` added ahead of
  ## ``--out:``, the output moved to ``<dir>/<stem>.per-test/<key>/<file>``
  ## and the nimcache to ``<nimcache>.per-test/<key>``, so no two tests'
  ## compiles share a file. Returns the new command line and the output as
  ## it spells it (relative to the compile's working directory, or
  ## absolute). Refuses a compile without exactly one ``--out:`` and one
  ## ``--nimcache:``, and one that already selects a test.
  if name.len == 0 or key.len == 0:
    raise newException(TestsFragmentError,
      "a per-test compile needs the test's name and key")
  var outAt = -1
  var cacheAt = -1
  for i, arg in argv:
    if arg.startsWith(NimOutFlag):
      if outAt >= 0:
        raise newException(TestsFragmentError, "the test binary's compile " &
          "names its output twice (" & NimOutFlag & "); cannot build one " &
          "binary per test from it")
      outAt = i
    elif arg.startsWith(NimNimcacheFlag):
      if cacheAt >= 0:
        raise newException(TestsFragmentError, "the test binary's compile " &
          "names its nimcache twice (" & NimNimcacheFlag & "); cannot " &
          "build one binary per test from it")
      cacheAt = i
    elif arg.startsWith(EntrypointsTestDefine):
      raise newException(TestsFragmentError, "the test binary's compile " &
        "already selects one test (" & arg & "); the listed binary must " &
        "carry every test")
  if outAt < 0 or cacheAt < 0:
    raise newException(TestsFragmentError, "the test binary's compile has " &
      "no " & (if outAt < 0: NimOutFlag else: NimNimcacheFlag) & " argument " &
      "(" & argv.join(" ") & "); one binary per test needs a nim compile " &
      "that names both")
  let output = argv[outAt][NimOutFlag.len .. ^1]
  let cache = argv[cacheAt][NimNimcacheFlag.len .. ^1]
  if output.len == 0 or cache.len == 0:
    raise newException(TestsFragmentError, "the test binary's compile " &
      "names an empty output or nimcache")
  let (dir, stem, _) = splitFile(output)
  result.output = dir / (stem & ".per-test") / key / extractFilename(output)
  for i, arg in argv:
    if i == outAt:
      result.argv.add(EntrypointsTestDefine & name)
      result.argv.add(NimOutFlag & result.output)
    elif i == cacheAt:
      result.argv.add(NimNimcacheFlag & ((cache & ".per-test") / key))
    else:
      result.argv.add(arg)

proc perTestFragmentText*(request: PerTestRequest;
                          names: openArray[string]): string =
  ## The ``repro-dynamic-graph-v1`` fragment for ``names``: one
  ## ``create-action`` record per test (and, for one binary per test, one
  ## for its compile ahead of it; see the module header) and the
  ## collector's ``dep`` on each run.
  if request.collectorId.len == 0:
    raise newException(TestsFragmentError,
      "a per-test fragment needs the collector's action id")
  let ids = perTestActionIds(request.idPrefix, names)
  let perTestBinaries = request.compile.argv.len > 0
  let runPrefix = request.idPrefix & ".test."
  result = DynamicGraphHeader & "\n"
  for i, name in names:
    var binary = request.binary
    var deps: seq[string] = @[]
    if perTestBinaries:
      let key = ids[i][runPrefix.len .. ^1]
      let compiled = perTestCompileArgv(request.compile.argv, name, key)
      let compileId = request.idPrefix & ".compile." & key
      binary =
        if compiled.output.isAbsolute: compiled.output
        else: normalizedPath(request.compile.cwd / compiled.output)
      let compileRecord = %*{
        "id": compileId,
        "argv": compiled.argv,
        "cwd": request.compile.cwd,
        "env": request.compile.env,
        "envPassthrough": request.compile.envPassthrough,
        "inputs": request.compile.inputs,
        "outputs": [compiled.output],
        "dependencyPolicy": {"kind": CreatedRunPolicyKind},
        "cacheable": not request.compile.uncacheable,
        "commandStatsId": request.statsName & "::" & name & "::compile"
      }
      if request.compile.actionCachePolicy.len > 0:
        compileRecord["actionCachePolicy"] =
          %request.compile.actionCachePolicy
      result.add("create-action\t" & $compileRecord & "\n")
      deps.add(compileId)
    let record = %*{
      "id": ids[i],
      "argv": runExactArgv(binary, name),
      "cwd": request.cwd,
      "inputs": [binary],
      "dependencyPolicy": {"kind": CreatedRunPolicyKind},
      "cacheable": true,
      "commandStatsId": request.statsName & "::" & name
    }
    if perTestBinaries:
      record["deps"] = %deps
      record["actionCachePolicy"] = %PerTestRunCachePolicy
    # `$` renders a JsonNode on one line, escaping any line break or tab a
    # string holds, as the fragment's line-oriented grammar requires.
    result.add("create-action\t" & $record & "\n")
  for id in ids:
    result.add("dep\t" & request.collectorId & "\t" & id & "\n")

proc appendBytes(sink: var string; buffer: openArray[char]; n: int) =
  let start = sink.len
  sink.setLen(start + n)
  copyMem(addr sink[start], unsafeAddr buffer[0], n)

proc captureSplit(program: string; args: openArray[string]):
    tuple[code: int; stdout, stderr: string] =
  ## Run ``program`` with its standard output and error captured apart. The
  ## listing's standard output is the machine-read list; its error stream
  ## is what to show when the listing fails.
  ##
  ## ``program`` is the test binary: the listing edge's declared input, run
  ## by its absolute path (no ``PATH`` search) under that edge's monitor,
  ## so what it is and what it reads are the edge's evidence. There is no
  ## typed execution profile for a binary the build itself produced, hence
  ## the explicit ``uncontrolledStartProcess``.
  let process = uncontrolledStartProcess(program, args = args, options = {})
  defer: process.close()
  when defined(posix):
    # Both pipes are drained as they fill, so a child that writes much to
    # one stream while this reads the other cannot block on a full pipe.
    var fds = [
      TPollfd(fd: process.outputHandle.cint, events: POLLIN),
      TPollfd(fd: process.errorHandle.cint, events: POLLIN)]
    var open = 2
    var buffer: array[8192, char]
    while open > 0:
      let ready = poll(addr fds[0], Tnfds(fds.len), -1)
      if ready < 0:
        if errno == EINTR:
          continue
        raiseOSError(osLastError(), "waiting for " & program)
      for i in 0 .. fds.high:
        if fds[i].fd < 0 or fds[i].revents == 0:
          continue
        let n = read(fds[i].fd, addr buffer[0], buffer.len)
        if n > 0:
          if i == 0:
            appendBytes(result.stdout, buffer, n)
          else:
            appendBytes(result.stderr, buffer, n)
        elif n == 0 or errno != EINTR:
          # End of the stream (or an error reading it): poll ignores a
          # negative descriptor from now on.
          fds[i].fd = -1
          dec open
    result.code = process.waitForExit()
  else:
    # Windows: pipes cannot be polled. The listing writes to its error
    # stream only when it fails, so standard output is read to its end
    # first. `drainStream` reads to the write end's close, not to the
    # first short read, which on a Windows pipe is only the writer pausing.
    result.stdout = drainStream(process.outputStream)
    result.stderr = drainStream(process.errorStream)
    result.code = process.waitForExit()

proc runListing(argv: openArray[string]): string =
  ## The standard output of the listing command ``argv``. Raises
  ## ``TestsFragmentError`` when it cannot run or exits non-zero.
  var outcome: tuple[code: int; stdout, stderr: string]
  try:
    outcome = captureSplit(argv[0], argv[1 .. ^1])
  except OSError as err:
    raise newException(TestsFragmentError,
      "cannot run " & argv.join(" ") & ": " & err.msg)
  if outcome.code != 0:
    var message = argv.join(" ") & " exited with code " & $outcome.code
    let detail = outcome.stderr.strip()
    if detail.len > 0:
      message.add(":\n" & detail)
    if outcome.code == 64:
      message.add("\n(64 is the selector's usage error: a binary run per " &
        "test must register the tests entry, `import entrypoints/tests`)")
    raise newException(TestsFragmentError, message)
  outcome.stdout

proc listTests*(binary: string): seq[string] =
  ## ``binary``'s tests, as ``<binary> --entrypoint=tests --list`` names
  ## them. Raises ``TestsFragmentError`` when the listing fails or cannot be
  ## run per test (``parseTestListing``).
  parseTestListing(runListing(listArgv(binary)), binary)

proc listTestCases*(binary: string): seq[string] =
  ## The names ``<binary> --entrypoint=tests --list --list-test-cases``
  ## prints: its ``testCase`` tests. May be empty.
  for line in runListing(listTestCasesArgv(binary)).split('\n'):
    let name = if line.endsWith('\r'): line[0 ..< line.high] else: line
    if name.len > 0:
      result.add(name)

proc writePerTestFragment*(request: PerTestRequest): int =
  ## List ``request.binary``'s tests and write their fragment to
  ## ``request.fragment``. Returns the number of tests.
  let names = listTests(request.binary)
  if request.compile.argv.len > 0:
    # One binary per test: refuse a test that cannot be compiled alone here,
    # naming it, rather than let its compile fail.
    let refusal = notBuildableAlone(names, listTestCases(request.binary),
      request.binary)
    if refusal.len > 0:
      raise newException(TestsFragmentError, refusal)
  let text = perTestFragmentText(request, names)
  let dir = request.fragment.parentDir
  if dir.len > 0:
    createDir(dir)
  writeFile(request.fragment, text)
  names.len

proc countFragmentRuns*(path: string): int =
  ## The number of runs the fragment at ``path`` makes the collector wait
  ## for (its ``dep`` records; a test's compile is not one), after checking
  ## its header. What the collector reports.
  if not fileExists(path):
    raise newException(TestsFragmentError,
      "per-test fragment missing: " & path)
  let lines = readFile(path).splitLines()
  if lines.len == 0 or lines[0] != DynamicGraphHeader:
    raise newException(TestsFragmentError,
      path & ": missing " & DynamicGraphHeader & " header")
  for line in lines:
    if line.startsWith("dep\t"):
      inc result

# ---------------------------------------------------------------------------
# The producer's command line. The engine builds it (``producerListArgv``,
# ``producerCheckArgv``) and the program parses it (``parseProducerArgs``).
# ---------------------------------------------------------------------------

const
  BinaryFlag = "--binary="
  OutFlag = "--out="
  IdPrefixFlag = "--id-prefix="
  CollectorFlag = "--collector="
  StatsNameFlag = "--stats-name="
  CwdFlag = "--cwd="
  CheckFlag = "--check="
  CompileArgFlag = "--compile-arg="
    ## Repeated, in order: the listed binary's compile command line.
  CompileCwdFlag = "--compile-cwd="
  CompileEnvFlag = "--compile-env="
  CompileEnvPassthroughFlag = "--compile-env-passthrough="
  CompileInputFlag = "--compile-input="
  CompileUncacheableFlag = "--compile-uncacheable"
  CompileCachePolicyFlag = "--compile-cache-policy="

proc producerListArgv*(producer: string; request: PerTestRequest):
    seq[string] =
  ## The listing edge's command line.
  result = @[producer,
    BinaryFlag & request.binary,
    OutFlag & request.fragment,
    IdPrefixFlag & request.idPrefix,
    CollectorFlag & request.collectorId,
    StatsNameFlag & request.statsName,
    CwdFlag & request.cwd]
  if request.compile.argv.len > 0:
    for arg in request.compile.argv:
      result.add(CompileArgFlag & arg)
    result.add(CompileCwdFlag & request.compile.cwd)
    for entry in request.compile.env:
      result.add(CompileEnvFlag & entry)
    for name in request.compile.envPassthrough:
      result.add(CompileEnvPassthroughFlag & name)
    for input in request.compile.inputs:
      result.add(CompileInputFlag & input)
    if request.compile.uncacheable:
      result.add(CompileUncacheableFlag)
    if request.compile.actionCachePolicy.len > 0:
      result.add(CompileCachePolicyFlag & request.compile.actionCachePolicy)

proc producerCheckArgv*(producer, fragment: string): seq[string] =
  ## The collector's command line.
  @[producer, CheckFlag & fragment]

proc parseProducerArgs*(args: openArray[string]): ProducerCommand =
  ## Parse ``repro-tests-fragment``'s arguments. Raises
  ## ``TestsFragmentError`` naming what is wrong.
  var request = PerTestRequest()
  var check = ""
  var sawList = false
  for arg in args:
    template take(flag: string; field: untyped) =
      field = arg[flag.len .. ^1]
      sawList = true
    if arg.startsWith(BinaryFlag): take(BinaryFlag, request.binary)
    elif arg.startsWith(OutFlag): take(OutFlag, request.fragment)
    elif arg.startsWith(IdPrefixFlag): take(IdPrefixFlag, request.idPrefix)
    elif arg.startsWith(CollectorFlag):
      take(CollectorFlag, request.collectorId)
    elif arg.startsWith(StatsNameFlag): take(StatsNameFlag, request.statsName)
    elif arg.startsWith(CwdFlag): take(CwdFlag, request.cwd)
    elif arg.startsWith(CompileArgFlag):
      request.compile.argv.add(arg[CompileArgFlag.len .. ^1])
      sawList = true
    elif arg.startsWith(CompileCwdFlag):
      take(CompileCwdFlag, request.compile.cwd)
    elif arg.startsWith(CompileEnvFlag):
      request.compile.env.add(arg[CompileEnvFlag.len .. ^1])
      sawList = true
    elif arg.startsWith(CompileEnvPassthroughFlag):
      request.compile.envPassthrough.add(
        arg[CompileEnvPassthroughFlag.len .. ^1])
      sawList = true
    elif arg.startsWith(CompileInputFlag):
      request.compile.inputs.add(arg[CompileInputFlag.len .. ^1])
      sawList = true
    elif arg == CompileUncacheableFlag:
      request.compile.uncacheable = true
      sawList = true
    elif arg.startsWith(CompileCachePolicyFlag):
      take(CompileCachePolicyFlag, request.compile.actionCachePolicy)
    elif arg.startsWith(CheckFlag): check = arg[CheckFlag.len .. ^1]
    else:
      raise newException(TestsFragmentError, "unknown argument: " & arg)
  if check.len > 0:
    if sawList:
      raise newException(TestsFragmentError,
        CheckFlag & " takes no other argument")
    return ProducerCommand(kind: pckCheck, fragment: check)
  var missing: seq[string] = @[]
  for (flag, value) in [(BinaryFlag, request.binary),
      (OutFlag, request.fragment), (IdPrefixFlag, request.idPrefix),
      (CollectorFlag, request.collectorId)]:
    if value.len == 0:
      missing.add(flag & "<value>")
  if missing.len > 0:
    raise newException(TestsFragmentError, "missing " & missing.join(", "))
  let compile = request.compile
  if compile.argv.len == 0 and (compile.cwd.len > 0 or compile.env.len > 0 or
      compile.envPassthrough.len > 0 or compile.inputs.len > 0 or
      compile.uncacheable or compile.actionCachePolicy.len > 0):
    raise newException(TestsFragmentError, "the --compile-* arguments " &
      "describe a compile, and need its command line (" & CompileArgFlag &
      "<arg>, repeated)")
  if compile.argv.len > 0 and compile.cwd.len == 0:
    raise newException(TestsFragmentError, "missing " & CompileCwdFlag &
      "<dir>: a test's compile runs where the listed binary's did")
  if request.statsName.len == 0:
    request.statsName = request.binary
  if request.cwd.len == 0:
    request.cwd = getCurrentDir()
  ProducerCommand(kind: pckList, request: request)

const ProducerUsage* = TestsFragmentProducerName & " --binary=<test binary> " &
  "--out=<fragment> --id-prefix=<id> --collector=<id> " &
  "[--stats-name=<name>] [--cwd=<dir>]\n" &
  "  [--compile-arg=<arg>... --compile-cwd=<dir> [--compile-env=<NAME=value>]... " &
  "[--compile-env-passthrough=<NAME>]... [--compile-input=<path>]... " &
  "[--compile-uncacheable] [--compile-cache-policy=<policy>]]\n" &
  TestsFragmentProducerName & " --check=<fragment>"

proc runProducer*(args: openArray[string]): int =
  ## The program's behaviour, as a library call: 0 on success, 64 on a
  ## malformed command line, 1 when the listing or the fragment is refused.
  ## Diagnostics go to standard error and the result line to standard
  ## output. ``--help`` (or ``-h``) prints the usage and returns 0.
  if args.len == 1 and args[0] in ["--help", "-h"]:
    stdout.writeLine("usage: " & ProducerUsage)
    return 0
  var command: ProducerCommand
  try:
    command = parseProducerArgs(args)
  except TestsFragmentError as err:
    stderr.writeLine(TestsFragmentProducerName & ": " & err.msg)
    stderr.writeLine("usage: " & ProducerUsage)
    return 64
  try:
    case command.kind
    of pckList:
      let count = writePerTestFragment(command.request)
      stdout.writeLine(TestsFragmentProducerName & ": " & $count &
        " tests of " & command.request.binary & " -> " &
        command.request.fragment)
    of pckCheck:
      let count = countFragmentRuns(command.fragment)
      stdout.writeLine(TestsFragmentProducerName & ": " & $count &
        " tests collected from " & command.fragment)
  except TestsFragmentError, IOError, OSError:
    stderr.writeLine(TestsFragmentProducerName & ": " &
      getCurrentExceptionMsg())
    return 1
  0

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

proc perTestFragmentText*(request: PerTestRequest;
                          names: openArray[string]): string =
  ## The ``repro-dynamic-graph-v1`` fragment for ``names``: one
  ## ``create-action`` record per test (see the module header) and the
  ## collector's ``dep`` on each.
  if request.collectorId.len == 0:
    raise newException(TestsFragmentError,
      "a per-test fragment needs the collector's action id")
  let ids = perTestActionIds(request.idPrefix, names)
  result = DynamicGraphHeader & "\n"
  for i, name in names:
    let record = %*{
      "id": ids[i],
      "argv": runExactArgv(request.binary, name),
      "cwd": request.cwd,
      "inputs": [request.binary],
      "dependencyPolicy": {"kind": CreatedRunPolicyKind},
      "cacheable": true,
      "commandStatsId": request.statsName & "::" & name
    }
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

proc listTests*(binary: string): seq[string] =
  ## ``binary``'s tests, as ``<binary> --entrypoint=tests --list`` names
  ## them. Raises ``TestsFragmentError`` when the listing fails or cannot be
  ## run per test (``parseTestListing``).
  let argv = listArgv(binary)
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
  parseTestListing(outcome.stdout, binary)

proc writePerTestFragment*(request: PerTestRequest): int =
  ## List ``request.binary``'s tests and write their fragment to
  ## ``request.fragment``. Returns the number of tests.
  let names = listTests(request.binary)
  let text = perTestFragmentText(request, names)
  let dir = request.fragment.parentDir
  if dir.len > 0:
    createDir(dir)
  writeFile(request.fragment, text)
  names.len

proc countFragmentRuns*(path: string): int =
  ## The number of ``create-action`` records in the fragment at ``path``,
  ## after checking its header. What the collector reports.
  if not fileExists(path):
    raise newException(TestsFragmentError,
      "per-test fragment missing: " & path)
  let lines = readFile(path).splitLines()
  if lines.len == 0 or lines[0] != DynamicGraphHeader:
    raise newException(TestsFragmentError,
      path & ": missing " & DynamicGraphHeader & " header")
  for line in lines:
    if line.startsWith("create-action\t"):
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

proc producerListArgv*(producer: string; request: PerTestRequest):
    seq[string] =
  ## The listing edge's command line.
  @[producer,
    BinaryFlag & request.binary,
    OutFlag & request.fragment,
    IdPrefixFlag & request.idPrefix,
    CollectorFlag & request.collectorId,
    StatsNameFlag & request.statsName,
    CwdFlag & request.cwd]

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
  if request.statsName.len == 0:
    request.statsName = request.binary
  if request.cwd.len == 0:
    request.cwd = getCurrentDir()
  ProducerCommand(kind: pckList, request: request)

const ProducerUsage* = TestsFragmentProducerName & " --binary=<test binary> " &
  "--out=<fragment> --id-prefix=<id> --collector=<id> " &
  "[--stats-name=<name>] [--cwd=<dir>]\n" &
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

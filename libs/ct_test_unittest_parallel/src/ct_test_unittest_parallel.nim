## ct_test_unittest_parallel — Tier-1 "Standard" binary-runner
## protocol shim around ``std/unittest``.
##
## Implements the protocol surface specified by
## `codetracer-specs/Planned-Features/Nim-Parallel-Test-Framework.md §3.6`
## ("Standard" tier):
##
## * ``--list`` — print one ``<suite>::<test>`` per line, exit 0
## * ``--list-json`` — print a JSON catalog (``tests`` array with
##   ``name``, ``suite``, ``file``, ``line``), exit 0
## * ``--run "<suite>::<test>"`` — run a single test, exit 0/1/2
##   (pass/fail/skip)
## * ``$NIMTEST_RESULT_FILE`` — if set, write JSON results
##   (``status``, ``duration_ms``, ``checkpoints``, ``exception``, and
##   ``skipReason`` when a case used the reason-carrying ``skip``)
##   before exiting. ``skipReason`` is present only when non-empty, so
##   consumers must tolerate its absence.
## * default (no protocol flag) — behave EXACTLY like ``std/unittest``:
##   run every registered test sequentially with the standard console
##   formatter.
##
## The shim is implemented by overriding ``suite`` and ``test``
## templates so registration happens at module-init time. The overrides
## fall through to ``std/unittest`` for execution in the default mode,
## and short-circuit (record only, no execution) in ``--list`` /
## ``--list-json`` mode.
##
## Backward compatibility:
##
## * Test files that ``import ct_test_unittest_parallel`` get the full
##   ``std/unittest`` surface re-exported (``check``, ``expect``,
##   ``setup``, ``teardown``, ``skip``, ``require``, ``fail``, …).
##   Only ``suite`` and ``test`` are shadowed by our overrides; in the
##   default mode they delegate straight to ``std/unittest``.
## * Tests that ``import std/unittest`` directly (without going through
##   this library) are completely unaffected — the protocol surface
##   only attaches to binaries that explicitly link this module.
##
## Coexistence with the protocol-carrying ``std/unittest``
## ------------------------------------------------------
##
## Since the codetracer-nim fork landed the same Tier-1 protocol inside
## ``std/unittest`` itself, this shim is no longer the only thing in the
## process that answers ``--list`` / ``--list-json``. ``std/unittest``'s
## own ``suite`` template calls its ``ensureProtocolExitProc``, so the
## moment a shim-linked binary expands ONE suite the stdlib installs an
## exit hook that will emit a catalog of everything IT registered.
##
## The two implementations must therefore not both emit. Because the
## shim's ``test`` override registers only into ``gRegistry``, the
## stdlib's registry stays empty, and an unguarded run printed an empty
## stdlib catalog followed by the shim's populated one — two JSON
## documents on stdout, which no consumer can parse, and which silently
## demoted every shim-linked binary to whole-binary execution in
## ``repro_test_runner``.
##
## The shim stays the single emitter, and it wins by *registration
## order*. ``std/exitprocs`` runs hooks LIFO, and ``quit`` from inside a
## hook terminates the process without running the ones still queued
## behind it. ``std/unittest`` installs its hook from inside its
## ``suite`` template, i.e. before the suite body expands; the shim
## therefore defers its own ``addExitProc`` to the first ``test``
## expansion — which is inside that body, hence strictly later, hence
## strictly first to run. It emits the catalog and quits, and the
## stdlib hook never fires.
##
## Delegating listing to ``std/unittest`` instead is NOT equivalent:
## its ``test`` template resolves ``instantiationInfo`` at its own
## expansion site, so forwarding to it from inside the shim's ``test``
## template records every case as living in this file rather than in
## the test source, losing the ``file``/``line`` fidelity the catalog
## exists to carry.
##
## ``--run`` needs no such care: it is the shim's hook that writes
## ``$NIMTEST_RESULT_FILE`` and picks the 0/1/2 exit code, and quitting
## first only makes that more certain.
##
## The tests entry
## ---------------
##
## A build tool lists and runs a binary's tests through nim-entrypoints'
## ``tests`` entry (https://github.com/metacraft-labs/nim-entrypoints, README
## "Tests"): the run-time selector ``--entrypoint=tests`` as the FIRST
## argument, then
##
## * ``--list``: every test's name on standard output, one per line, nothing
##   run. A name is ``<suite>::<test>``, or ``<test>`` for a test outside a
##   suite (nim-entrypoints' spelling; the ``--list`` protocol above writes
##   ``::<test>`` there). A name with a line break cannot be listed: it is
##   named on stderr and the exit code is 70, before any name is printed.
## * ``--list-test-cases``: the names a ``-d:entrypointsTest=<name>`` build
##   can be made for. No test of this shim is one (a framework's tests are
##   not ``testCase`` s), so it prints nothing.
## * ``--run-exact=<name>`` (repeatable): run exactly the tests listed as
##   those names, never reading a name as a pattern. A name ``--list`` does
##   not print exits with 64, as does ``--run-exact`` together with
##   ``--run``.
## * ``--run=<name>`` / ``--run <name>``: refused with 64, nothing run.
##   The protocol-carrying ``std/unittest`` reads that ``--run`` as its own
##   and then runs only the test whose full name is exactly ``<name>``, so
##   the shim's ``--run`` matching above (``<suite>::``, a bare test name)
##   would select tests the fork then skips. ``--run-exact=<name>`` selects
##   one test; the ``--run`` protocol above does too, without the selector.
## * nothing else: run every test.
##
## Under the entry the exit code is ``std/unittest``'s: 1 when a test that
## ran failed, else 0 (a skipped test does not fail the run). Its other
## arguments are not test filters: ``std/unittest`` does not see the
## selector as a filter that matches nothing.
##
## ``--entrypoint=list`` prints nim-entrypoints' entry list
## (``{"schema":"entrypoints/1", ...}``) naming ``main`` (run every test, the
## binary's default) and ``tests``, whose ``entries`` are the test names.
## A tool reads it to tell a binary that answers the tests entry from one
## that does not. Any other entry name exits with 64.
##
## A program built with nim-entrypoints (``import entrypoints``) already has
## the entry, its list and its dispatcher, and they answer instead: put the
## shim's ``suite`` / ``test`` in a ``tests:`` block, where nim-entrypoints
## lists them and guards each for ``--run-exact``. The shim then only runs
## the tests it is asked to, with ``std/unittest``'s filtering off, and
## installs no exit hook under the entry, so nim-entrypoints' exit code
## stands. Which case applies is decided where a ``test`` expands: when
## nim-entrypoints' ``entryArgs`` and ``parseSelector`` are visible there,
## nim-entrypoints owns the entry.
##
## For such a program the shim also undoes the fork's redirection under
## ``--entrypoint=tests --list``: a fork before ``4fda9ccd`` reads that
## ``--list`` as its own and points descriptor 1 at stderr, and
## nim-entrypoints prints the list on descriptor 1 (see ``protocol_output``).
## From ``4fda9ccd`` on, the fork's ``std/unittest`` knows the selector and
## leaves descriptor 1 alone whenever it is given, so the undoing changes
## nothing there; it stays for binaries built with an older fork. Import this
## module before anything that imports ``std/unittest``, so the original
## descriptor 1 is still there to keep; the shim re-exports ``std/unittest``.
##
## A program that imports ``std/unittest`` without this shim answers the
## entry through ``std/unittest`` itself from fork ``4fda9ccd`` on, in the
## same protocol, except that it reads ``--run=<pattern>`` under
## the entry as a filter pattern instead of refusing it. Where this shim is
## linked, that ``std/unittest`` stands down and the shim answers, as above.

# Import this leaf before ``std/unittest``: its module initialiser preserves the
# real stdout before the protocol-carrying fork redirects descriptor 1.
from ct_test_unittest_parallel/protocol_output import writeShimProtocolLine,
  entrySelectorName, restoreEntryStdout, divertStdoutToStderr

import std/[compilesettings, exitprocs, json, os, strutils, times]
import std/unittest as stdUnittest
# ``skip`` joins ``suite``/``test`` as an override rather than a
# re-export: the shim writes ``$NIMTEST_RESULT_FILE`` from its own
# formatter, and the reason a case passes to ``skip`` is otherwise
# recorded in a private ``std/unittest`` threadvar the shim cannot
# read. Overriding is what lets the shim's result document carry the
# same ``skipReason`` the protocol-carrying ``std/unittest`` emits.
export stdUnittest except suite, test, skip

type
  TestEntry* = object
    ## Metadata for a single registered test case. Populated at module
    ## init time by the ``test`` template override.
    suite*: string
    name*: string
    file*: string
    line*: int

  ProtocolMode* = enum
    pmDefault       ## No protocol flag — run via std/unittest as usual.
    pmListPlain     ## --list — print one ``suite::test`` per line.
    pmListJson      ## --list-json — print the JSON catalog.
    pmRunOne        ## --run "<name>" — run a single named test.
    pmEntryList     ## --entrypoint=tests --list — the tests entry's list.
    pmEntryListTestCases
      ## --entrypoint=tests --list-test-cases — lists nothing: no test of
      ## the shim can be built alone.
    pmEntryRun
      ## --entrypoint=tests, alone or with --run-exact= (or --run=, which
      ## the shim refuses and nim-entrypoints answers); also
      ## --entrypoint=main (every test).
    pmEntryDescribe ## --entrypoint=list — the entrypoints/1 entry list.
    pmEntryUnknown  ## --entrypoint=<an entry this binary does not have>.
    pmEntryUsage    ## --entrypoint=tests with --run-exact= and --run=.

  CapturedResult = object
    suite: string
    name: string
    status: stdUnittest.TestStatus
    checkpoints: seq[string]
    exception: string
    skipReason: string
      ## Human-readable reason recorded by ``skip(reason)``. Empty for a
      ## bare ``skip()`` and for every non-skipped outcome; the result
      ## file omits the ``skipReason`` key entirely when it is empty.
    durationMs: int
    started: float
    matched: bool
    inFlight: bool
      ## Set by ``testStarted``, cleared by ``testEnded``. Still set when
      ## the exit hook runs means the case left the process from inside
      ## its body — see ``abortedCaseResult``.
    failureSeen: bool
      ## ``failureOccurred`` fired for this case, i.e. a ``check``,
      ## ``require`` or ``fail`` failed.

  ProtocolFormatter = ref object of stdUnittest.OutputFormatter
    ## Custom formatter that captures pass/fail/skip results without
    ## printing the standard console output. Used in ``--run`` mode.
    current: CapturedResult
    currentSuite: string

  SilentFormatter = ref object of stdUnittest.OutputFormatter
    ## Drop-everything formatter used in ``--list`` / ``--list-json``
    ## mode so ``std/unittest``'s ``ensureInitialized`` cannot re-add
    ## the default console formatter and pollute the JSON output.

var
  gProtocolMode {.threadvar.}: ProtocolMode
  gRegistry {.threadvar.}: seq[TestEntry]
  gRunFilter {.threadvar.}: string
  gCapturedResult {.threadvar.}: CapturedResult
  gProtocolInitialized {.threadvar.}: bool
  gProtocolExitHookQueued {.threadvar.}: bool
  gRunFormatter {.threadvar.}: ProtocolFormatter
    ## The formatter installed for ``--run``, kept so the exit hook can
    ## read a case that started and never reached ``testEnded``.
  gExactNames {.threadvar.}: seq[string]
    ## The ``--run-exact=<name>`` names under the tests entry.
  gEntryName {.threadvar.}: string
    ## The entry ``--entrypoint=`` named, for ``pmEntryUnknown``'s message.
  gEntryRunGiven {.threadvar.}: bool
    ## ``--run`` was given under the tests entry. The shim refuses it (see
    ## "The tests entry" in the module header); in a program built with
    ## nim-entrypoints, nim-entrypoints matches it and guards the tests.
  gSkipReason* {.threadvar.}: string
    ## Reason recorded by the ``skip`` override below and read back by
    ## ``testEnded``. It is a module global rather than a formatter
    ## field because ``skip`` expands inside the *test body*, which has
    ## no handle on the active formatter. Exported so the template can
    ## ``bind`` it from a foreign instantiation scope.

template skip*(reason = "") =
  ## ``std/unittest.skip``, plus capture of the reason.
  ##
  ## Signature-compatible with both the stock no-argument ``skip()``
  ## and the protocol-carrying fork's ``skip(reason = "")``, so every
  ## existing call site keeps working unchanged. The reason is stashed
  ## for ``testEnded`` and ends up in the result document, which is what
  ## makes a skip census say *why* rather than merely *that*.
  ##
  ## Status assignment and checkpoint clearing are delegated to
  ## ``std/unittest`` rather than reimplemented, so this cannot drift
  ## from the stdlib's notion of what a skip is. The ``compiles``
  ## branch keeps the shim usable against a stock ``std/unittest``
  ## whose ``skip`` takes no argument.
  bind gSkipReason
  gSkipReason = reason
  when compiles(stdUnittest.skip(reason)):
    stdUnittest.skip(reason)
  else:
    stdUnittest.skip()

proc currentProtocolMode*(): ProtocolMode =
  ## Return the active protocol mode for the current process. Resolved
  ## by parsing argv on first call.
  gProtocolMode

proc registeredTests*(): seq[TestEntry] =
  ## Return the list of every test seen by the shim's ``suite``/``test``
  ## overrides up to this point. Populated incrementally as suite
  ## blocks expand at module-init time.
  gRegistry

method suiteStarted*(formatter: ProtocolFormatter, suiteName: string) =
  formatter.currentSuite = suiteName

method testStarted*(formatter: ProtocolFormatter, testName: string) =
  # Clear any reason left by a previously executed case so a bare
  # ``skip()`` can never inherit an earlier case's reason.
  gSkipReason = ""
  formatter.current = CapturedResult(
    suite: formatter.currentSuite,
    name: testName,
    status: stdUnittest.TestStatus.OK,
    checkpoints: @[],
    exception: "",
    skipReason: "",
    started: epochTime(),
    matched: true,
    inFlight: true)

method failureOccurred*(formatter: ProtocolFormatter,
                       checkpoints: seq[string], stackTrace: string) =
  formatter.current.failureSeen = true
  for cp in checkpoints:
    formatter.current.checkpoints.add(cp)
  if stackTrace.len > 0 and formatter.current.exception.len == 0:
    # Heuristic: first non-empty line of the stack trace tends to be
    # the most useful summary. The full trace is left on stderr by the
    # standard formatter; protocol consumers can read it there.
    for line in stackTrace.splitLines():
      if line.strip().len > 0:
        formatter.current.exception = line.strip()
        break

method testEnded*(formatter: ProtocolFormatter,
                 testResult: stdUnittest.TestResult) =
  formatter.current.inFlight = false
  formatter.current.status = testResult.status
  if testResult.status == stdUnittest.TestStatus.SKIPPED:
    formatter.current.skipReason = gSkipReason
  formatter.current.durationMs =
    int((epochTime() - formatter.current.started) * 1000)
  gCapturedResult = formatter.current

method suiteEnded*(formatter: ProtocolFormatter) =
  formatter.currentSuite = ""

const
  EntryModes* = {pmEntryList, pmEntryListTestCases, pmEntryRun,
    pmEntryDescribe, pmEntryUnknown, pmEntryUsage}
    ## The modes the run-time selector (``--entrypoint=<name>``) chose.
  EntryUsageExitCode* = 64
    ## nim-entrypoints' ``usageExitCode`` (EX_USAGE): an unknown entry, an
    ## unknown ``--run-exact`` name, ``--run-exact`` with ``--run``.
  EntryUnlistableExitCode* = 70
    ## nim-entrypoints' ``unlistableNameExitCode`` (EX_SOFTWARE): a test
    ## name that ``--list`` cannot print on one line.
  EntryProgramName = querySetting(SingleValueSetting.projectName)
    ## The ``program`` of the entry list, as nim-entrypoints spells it.

proc entryTestName*(suite, name: string): string =
  ## A test's name under the tests entry: ``<suite>::<test>``, or the bare
  ## test name outside a suite, as nim-entrypoints lists a ``tests:``
  ## block's tests.
  if suite.len > 0: suite & "::" & name else: name

proc detectEntryMode(selector: tuple[name: string; taken: int]):
    ProtocolMode =
  ## The mode the run-time selector chose; see "The tests entry" in the
  ## module header. Stores the ``--run-exact`` names and whether ``--run``
  ## was given (``gEntryRunGiven``).
  case selector.name
  of "list":
    return pmEntryDescribe
  of "main":
    return pmEntryRun
  of "tests":
    var list = false
    var testCasesOnly = false
    var runGiven = false
    var i = selector.taken + 1
    while i <= paramCount():
      let p = paramStr(i)
      if p == "--list":
        list = true
      elif p == "--list-test-cases":
        list = true
        testCasesOnly = true
      elif p.startsWith("--run-exact="):
        gExactNames.add(p["--run-exact=".len .. ^1])
      elif p == "--run":
        runGiven = true
        if i + 1 <= paramCount():
          inc i
      elif p.startsWith("--run="):
        runGiven = true
      inc i
    gEntryRunGiven = runGiven
    # The listing wins over a run, as in nim-entrypoints.
    if list:
      return (if testCasesOnly: pmEntryListTestCases else: pmEntryList)
    if runGiven and gExactNames.len > 0:
      return pmEntryUsage
    return pmEntryRun
  else:
    gEntryName = selector.name
    return pmEntryUnknown

proc detectProtocolMode(): ProtocolMode =
  ## Parse argv and decide the protocol mode. Stores the ``--run``
  ## filter in ``gRunFilter`` when applicable.
  let selector = entrySelectorName()
  if selector.taken > 0:
    return detectEntryMode(selector)
  result = pmDefault
  var i = 1
  while i <= paramCount():
    let p = paramStr(i)
    case p
    of "--list":
      return pmListPlain
    of "--list-json":
      return pmListJson
    of "--run":
      if i + 1 <= paramCount():
        gRunFilter = paramStr(i + 1)
      return pmRunOne
    else:
      if p.startsWith("--run="):
        gRunFilter = p[len("--run=") .. ^1]
        return pmRunOne
    inc i

proc emitListPlain() =
  for entry in gRegistry:
    writeShimProtocolLine(entry.suite & "::" & entry.name)

proc emitListJson() =
  var tests = newJArray()
  for entry in gRegistry:
    var node = newJObject()
    node["name"] = %(entry.suite & "::" & entry.name)
    node["suite"] = %entry.suite
    node["file"] = %entry.file
    node["line"] = %entry.line
    tests.add(node)
  var doc = newJObject()
  doc["tests"] = tests
  var summary = newJObject()
  summary["total"] = %gRegistry.len
  doc["summary"] = summary
  writeShimProtocolLine(doc.pretty())

proc registeredEntryNames(): seq[string] =
  for entry in gRegistry:
    result.add(entryTestName(entry.suite, entry.name))

proc emitEntryList() =
  ## The tests entry's ``--list``. Every name is checked before any is
  ## printed, so a tool never reads a partial list as the whole.
  let names = registeredEntryNames()
  for name in names:
    if '\n' in name or '\r' in name:
      stderr.writeLine("ct_test_unittest_parallel: the test name " &
        name.escape & " cannot be listed: it holds a line break, and " &
        "--entrypoint=tests --list prints one name per line; rename the test")
      quit(EntryUnlistableExitCode)
  for name in names:
    writeShimProtocolLine(name)

proc emitEntryDescribe() =
  ## nim-entrypoints' entry list (schema ``entrypoints/1``) for a binary that
  ## has the shim's entries only. Both are chosen at run time; neither has a
  ## ``-d:entrypoint=<name>`` build.
  let doc = %*{
    "schema": "entrypoints/1",
    "program": EntryProgramName,
    "default": "main",
    "entries": [
      {"name": "main", "doc": "run every test", "select": ["runtime"]},
      {"name": "tests", "doc": "run the program's tests",
       "select": ["runtime"],
       "args": "[--list] [--list-test-cases] [--run-exact=<name>]...",
       "entries": registeredEntryNames()}]}
  writeShimProtocolLine($doc)

proc finishEntryRun() =
  ## The end of a run under the tests entry, in a binary whose entry the shim
  ## answers. A ``--run-exact`` name no test has, or ``--run`` (which the shim
  ## refuses; no test ran), is a usage error; otherwise the exit code is the
  ## one ``std/unittest`` set (1 when a test that ran failed).
  if gExactNames.len > 0:
    let known = registeredEntryNames()
    for name in gExactNames:
      if name notin known:
        stderr.writeLine("ct_test_unittest_parallel: --run-exact: no test " &
          "is named exactly " & name.escape & " (the name is compared as " &
          "written, not as a pattern, and must be one that " &
          "--entrypoint=tests --list prints); the tests are: " &
          known.join(", "))
        quit(EntryUsageExitCode)
  elif gEntryRunGiven:
    stderr.writeLine("ct_test_unittest_parallel: --entrypoint=tests does " &
      "not take --run here (the protocol-carrying std/unittest would read " &
      "it as its own exact --run); select a test with --run-exact=<name>, " &
      "one of: " & registeredEntryNames().join(", "))
    quit(EntryUsageExitCode)

proc entryRunWanted*(suite, name: string;
                     entrypointsLinked = false): bool =
  ## Whether the test ``name`` of ``suite`` runs under the tests entry
  ## (``pmEntryRun``): with ``--run-exact``, exactly the tests listed as one
  ## of its names; with ``--run``, none when the shim answers the entry (it
  ## refuses ``--run``) and, in a program built with nim-entrypoints
  ## (``entrypointsLinked``), every test nim-entrypoints' guard lets through
  ## (it matches ``--run`` as it documents); else every test.
  if gExactNames.len > 0:
    entryTestName(suite, name) in gExactNames
  elif gEntryRunGiven:
    entrypointsLinked
  else:
    true

proc writeResultFile(path: string; status: string;
                     durationMs: int; checkpoints: seq[string];
                     exception: string;
                     skipReason: string = "") =
  var doc = newJObject()
  doc["status"] = %status
  doc["duration_ms"] = %durationMs
  var cps = newJArray()
  for cp in checkpoints:
    cps.add(%cp)
  doc["checkpoints"] = cps
  if exception.len > 0:
    doc["exception"] = %exception
  else:
    doc["exception"] = newJNull()
  if skipReason.len > 0:
    doc["skipReason"] = %skipReason
  try:
    writeFile(path, doc.pretty())
  except CatchableError:
    discard  # best-effort

proc statusToString(s: stdUnittest.TestStatus): string =
  case s
  of stdUnittest.TestStatus.OK: "PASS"
  of stdUnittest.TestStatus.FAILED: "FAIL"
  of stdUnittest.TestStatus.SKIPPED: "SKIP"

proc statusToExitCode(s: stdUnittest.TestStatus): int =
  case s
  of stdUnittest.TestStatus.OK: 0
  of stdUnittest.TestStatus.FAILED: 1
  of stdUnittest.TestStatus.SKIPPED: 2

proc abortedCaseResult(current: CapturedResult): CapturedResult =
  ## The result of a case that left the process from inside its body.
  ##
  ## ``std/unittest``'s ``require`` is ``check`` with ``abortOnError``
  ## forced on, and a failed check under ``abortOnError`` ends in
  ## ``fail``'s ``quit(1)`` — AFTER it has reported the failure (and its
  ## checkpoints) to ``failureOccurred``, but from inside the body, so
  ## the ``finally`` that calls ``testEnded`` never runs: ``quit`` does
  ## not unwind. A ``quit`` written in the body takes the same exit.
  ## Either way ``gCapturedResult`` was never filled, and the hook used to
  ## report the case as "test not found" — a case that ran, recorded
  ## checkpoints and failed, described as one that did not exist.
  ##
  ## Always FAIL, whatever code the body quit with: the case did not
  ## finish, so no verdict it might have reached exists.
  result = current
  result.status = stdUnittest.TestStatus.FAILED
  result.inFlight = false
  result.durationMs = int((epochTime() - current.started) * 1000)
  if current.failureSeen:
    # ``check`` records ``<file>(<line>, <col>): Check failed: <expr>``
    # first, then one checkpoint per operand value; name the condition.
    var failedCheck = ""
    for cp in current.checkpoints:
      if ": Check failed: " in cp:
        failedCheck = cp
    result.exception = "require failed (a failed check aborted the " &
      "process before the case ended)" &
      (if failedCheck.len > 0: ": " & failedCheck else: "")
  else:
    # ``checkpoint`` text is held in a private ``std/unittest`` threadvar
    # until a failure reports it, so a bare ``quit`` leaves none to read.
    result.exception = "the case exited the process (quit) before it " &
      "ended; checkpoints not attached to a failure are not recoverable"

proc handleProtocolExit() {.noconv.} =
  ## Exit hook installed for every protocol mode. Dispatches to the
  ## per-mode output emission and quits with the right code.
  ##
  ## Every branch ends in ``quit``. That is load-bearing, not just
  ## tidy: it is what stops the protocol-carrying ``std/unittest``'s
  ## own exit hook — queued behind this one — from appending a second
  ## payload. See the module header.
  case gProtocolMode
  of pmDefault:
    discard
  of pmListPlain:
    emitListPlain()
    quit(0)
  of pmListJson:
    emitListJson()
    quit(0)
  of pmRunOne:
    let resultFile = getEnv("NIMTEST_RESULT_FILE")
    var captured = gCapturedResult
    if gRunFormatter != nil and gRunFormatter.current.inFlight:
      # Checked before ``matched``: under a suite-wide filter an EARLIER
      # case may have ended normally, and its result must not stand in
      # for the one that aborted.
      captured = abortedCaseResult(gRunFormatter.current)
    if not captured.matched:
      # Requested test did not run — exit non-zero with a clear error.
      if resultFile.len > 0:
        writeResultFile(resultFile, "FAIL", 0,
          @["test not found: " & gRunFilter],
          "test not found")
      stderr.writeLine "ct_test_unittest_parallel: test not found: " &
        gRunFilter
      quit(1)
    if resultFile.len > 0:
      # Emit the reason the case itself supplied via ``skip(reason)``.
      # A bare ``skip()`` carries none, and the writer then omits the
      # ``skipReason`` key entirely rather than inventing the
      # content-free placeholder this used to write for every skip.
      writeResultFile(resultFile, statusToString(captured.status),
                      captured.durationMs, captured.checkpoints,
                      captured.exception, captured.skipReason)
    quit(statusToExitCode(captured.status))
  of pmEntryList:
    emitEntryList()
    quit(0)
  of pmEntryListTestCases:
    quit(0)
  of pmEntryDescribe:
    emitEntryDescribe()
    quit(0)
  of pmEntryUnknown:
    stderr.writeLine("ct_test_unittest_parallel: " &
      (if gEntryName.len == 0: "--entrypoint needs an entry name"
       else: "unknown entry '" & gEntryName & "'") &
      "; the entries are: main, tests")
    quit(EntryUsageExitCode)
  of pmEntryUsage:
    stderr.writeLine("ct_test_unittest_parallel: --run-exact cannot be " &
      "combined with --run: --run-exact selects listed names exactly, " &
      "--run matches them")
    quit(EntryUsageExitCode)
  of pmEntryRun:
    # Returns unless the run is a usage error: the exit code of a run is
    # std/unittest's, and no other hook is queued behind this one (the
    # protocol-carrying std/unittest queues one only for its own --list,
    # --list-json, --run and --catalog, which the selector's mode is not).
    finishEntryRun()

proc queueProtocolExitHook*(entrypointsLinked = false) =
  ## Install ``handleProtocolExit`` — but deliberately LATE, on the
  ## first ``test`` expansion rather than at module init.
  ##
  ## ``std/exitprocs`` runs hooks LIFO, and the protocol-carrying
  ## ``std/unittest`` installs its own hook from inside its ``suite``
  ## template, i.e. before the suite body expands. Registering here —
  ## from inside that body — therefore puts this hook *after* the
  ## stdlib's in registration order and *before* it in execution order,
  ## which is what lets ``handleProtocolExit``'s ``quit`` stop the
  ## stdlib from appending a second payload.
  ##
  ## Registering at module-init time instead would invert the order and
  ## reintroduce the double emission. Idempotent; a no-op outside a
  ## protocol mode.
  ##
  ## ``entrypointsLinked`` says nim-entrypoints is visible where the
  ## ``test`` expanded (see "The tests entry" in the module header). Then
  ## nim-entrypoints answers the selector's entries, ends the process itself
  ## when it lists, and sets the exit code of a run, so no hook is queued
  ## for a selector's mode: a hook that quit would replace that exit code.
  if gProtocolMode == pmDefault or gProtocolExitHookQueued:
    return
  if entrypointsLinked and gProtocolMode in EntryModes:
    return
  gProtocolExitHookQueued = true
  addExitProc(handleProtocolExit)

proc initProtocol*() =
  ## Initialize the protocol shim. Runs once at module-init time.
  ## Safe to call multiple times.
  if gProtocolInitialized:
    return
  gProtocolInitialized = true
  gProtocolMode = detectProtocolMode()

  case gProtocolMode
  of pmDefault:
    discard
  of pmListPlain, pmListJson:
    # In list mode, we don't want std/unittest to execute any test
    # body. The ``test`` template override checks ``gProtocolMode`` and
    # skips body execution; we still need to suppress the default
    # console formatter so stdout stays clean for JSON output. Install
    # a SilentFormatter so ``ensureInitialized`` cannot re-add the
    # default console formatter when ``suite``'s body fires
    # ``suiteStarted`` / ``suiteEnded``.
    stdUnittest.disableParamFiltering()
    stdUnittest.resetOutputFormatters()
    stdUnittest.addOutputFormatter(SilentFormatter())
  of pmRunOne:
    stdUnittest.disableParamFiltering()
    stdUnittest.resetOutputFormatters()
    gRunFormatter = ProtocolFormatter()
    stdUnittest.addOutputFormatter(gRunFormatter)
  of pmEntryRun:
    # The selector and the entry's own arguments are not test filters: a
    # filter that matches nothing would skip every test and pass. The shim
    # selects the tests itself (``entryRunWanted``), and the console
    # formatter reports them as in an ordinary run.
    stdUnittest.disableParamFiltering()
  of pmEntryList, pmEntryListTestCases, pmEntryDescribe:
    stdUnittest.disableParamFiltering()
    stdUnittest.resetOutputFormatters()
    stdUnittest.addOutputFormatter(SilentFormatter())
    # Whoever prints the document (nim-entrypoints, in a program built with
    # it) writes on descriptor 1, which the protocol-carrying std/unittest
    # of a fork before 4fda9ccd pointed at stderr when it saw ``--list``
    # (from 4fda9ccd on it leaves it alone). When the shim prints it
    # instead, ``suite`` diverts descriptor 1 again (``divertStdoutToStderr``).
    restoreEntryStdout()
  of pmEntryUnknown, pmEntryUsage:
    stdUnittest.disableParamFiltering()
    stdUnittest.resetOutputFormatters()
    stdUnittest.addOutputFormatter(SilentFormatter())

# Initialize protocol mode as soon as the module is loaded. Module
# init runs before any ``suite``/``test`` top-level blocks in importing
# modules, so this hook installs in time.
initProtocol()

template suite*(suiteName, body: untyped) =
  ## ``suite`` override — exposes ``testSuiteName`` so nested ``test``
  ## overrides can read the current suite, and delegates to
  ## ``std/unittest.suite`` for execution / output.
  ##
  ## Pattern matches std/unittest's contract: nested ``test`` calls
  ## read ``testSuiteName`` to know which suite they belong to. We
  ## inject our own copy at the OUTER block scope so the registry
  ## records the suite even in list mode (where the inner
  ## ``std/unittest.suite`` body never runs).
  ##
  ## While the shim prints a document for the tests entry, the suite's
  ## output goes to stderr (``divertStdoutToStderr``), as the
  ## protocol-carrying ``std/unittest`` does for its own ``--list``. Not in
  ## a program built with nim-entrypoints, which prints that document on
  ## descriptor 1 itself.
  bind gProtocolMode, divertStdoutToStderr
  block:
    when not (declared(entryArgs) and declared(parseSelector)):
      if gProtocolMode in {pmEntryList, pmEntryListTestCases,
          pmEntryDescribe}:
        divertStdoutToStderr()
    let testSuiteName {.inject, used.} = suiteName
    stdUnittest.suite(suiteName):
      body

template test*(testName, body: untyped) =
  ## ``test`` override — records the test in the protocol registry,
  ## then delegates to ``std/unittest.test`` in the modes where the
  ## body should actually run.
  bind gRegistry, gProtocolMode, gRunFilter,
       gCapturedResult, TestEntry, ProtocolMode, queueProtocolExitHook,
       entryRunWanted
  block:
    # Must run before anything else in the expansion: it is the
    # relative registration order against std/unittest's own exit hook
    # that decides which implementation gets to emit. Whether
    # nim-entrypoints owns the selector's entries is decided here, where
    # the test's own module is in scope (see the module header).
    queueProtocolExitHook(
      entrypointsLinked = declared(entryArgs) and declared(parseSelector))
    let ctpInfo = instantiationInfo()
    let ctpSuite = when declared(testSuiteName): testSuiteName else: ""
    gRegistry.add(TestEntry(
      suite: ctpSuite,
      name: testName,
      file: ctpInfo.filename,
      line: ctpInfo.line))
    case gProtocolMode
    of pmListPlain, pmListJson, pmEntryList, pmEntryListTestCases,
        pmEntryDescribe, pmEntryUnknown, pmEntryUsage:
      discard  # registration only — do not execute the body.
    of pmRunOne:
      let want = gRunFilter
      let fq = ctpSuite & "::" & testName
      if want == fq or want == testName or
          want == ctpSuite & "::" or
          (want == "" and testName != ""):
        stdUnittest.test(testName, body)
    of pmEntryRun:
      if entryRunWanted(ctpSuite, testName, entrypointsLinked =
          declared(entryArgs) and declared(parseSelector)):
        stdUnittest.test(testName, body)
    of pmDefault:
      stdUnittest.test(testName, body)

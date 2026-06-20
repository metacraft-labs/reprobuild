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
##   (``status``, ``duration_ms``, ``checkpoints``, ``exception``)
##   before exiting
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

import std/[exitprocs, json, os, strutils, times]
import std/unittest as stdUnittest
export stdUnittest except suite, test

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

  CapturedResult = object
    suite: string
    name: string
    status: stdUnittest.TestStatus
    checkpoints: seq[string]
    exception: string
    durationMs: int
    started: float
    matched: bool

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
  formatter.current = CapturedResult(
    suite: formatter.currentSuite,
    name: testName,
    status: stdUnittest.TestStatus.OK,
    checkpoints: @[],
    exception: "",
    started: epochTime(),
    matched: true)

method failureOccurred*(formatter: ProtocolFormatter,
                       checkpoints: seq[string], stackTrace: string) =
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
  formatter.current.status = testResult.status
  formatter.current.durationMs =
    int((epochTime() - formatter.current.started) * 1000)
  gCapturedResult = formatter.current

method suiteEnded*(formatter: ProtocolFormatter) =
  formatter.currentSuite = ""

proc detectProtocolMode(): ProtocolMode =
  ## Parse argv and decide the protocol mode. Stores the ``--run``
  ## filter in ``gRunFilter`` when applicable.
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
    echo entry.suite & "::" & entry.name

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
  echo doc.pretty()

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

proc handleProtocolExit() {.noconv.} =
  ## Exit hook installed for every protocol mode. Dispatches to the
  ## per-mode output emission and quits with the right code.
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
    let captured = gCapturedResult
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
      let skipReason =
        if captured.status == stdUnittest.TestStatus.SKIPPED:
          "skipped"
        else:
          ""
      writeResultFile(resultFile, statusToString(captured.status),
                      captured.durationMs, captured.checkpoints,
                      captured.exception, skipReason)
    quit(statusToExitCode(captured.status))

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
    addExitProc(handleProtocolExit)
  of pmRunOne:
    stdUnittest.disableParamFiltering()
    stdUnittest.resetOutputFormatters()
    stdUnittest.addOutputFormatter(ProtocolFormatter())
    addExitProc(handleProtocolExit)

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
  block:
    let testSuiteName {.inject, used.} = suiteName
    stdUnittest.suite(suiteName):
      body

template test*(testName, body: untyped) =
  ## ``test`` override — records the test in the protocol registry,
  ## then delegates to ``std/unittest.test`` in the modes where the
  ## body should actually run.
  bind gRegistry, gProtocolMode, gRunFilter,
       gCapturedResult, TestEntry, ProtocolMode
  block:
    let ctpInfo = instantiationInfo()
    let ctpSuite = when declared(testSuiteName): testSuiteName else: ""
    gRegistry.add(TestEntry(
      suite: ctpSuite,
      name: testName,
      file: ctpInfo.filename,
      line: ctpInfo.line))
    case gProtocolMode
    of pmListPlain, pmListJson:
      discard  # registration only — do not execute the body.
    of pmRunOne:
      let want = gRunFilter
      let fq = ctpSuite & "::" & testName
      if want == fq or want == testName or
          want == ctpSuite & "::" or
          (want == "" and testName != ""):
        stdUnittest.test(testName, body)
    of pmDefault:
      stdUnittest.test(testName, body)

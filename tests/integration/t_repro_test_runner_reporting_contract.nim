## t_repro_test_runner_reporting_contract — the runner's summary must be
## able to name what it ran, and must not report harness faults as test
## results.
##
## Four defects, all found by auditing suite runs against their own
## ``test-logs`` artifacts, all of them defects in what the run REPORTED
## rather than in what it executed. The first three came from a completed
## 5923-case run against ``parallel-run.json``; the fourth from a run that
## never completed at all.
##
## 1. **A spawn fault was recorded as a test FAILURE.** One case was
##    recorded ``FAIL`` at 83 ms with the stdout tail
##    ``repro_test_runner: spawn failed: Bad file descriptor``. No child
##    ever ran, so nothing was observed about the code under test; the
##    same case passed on the next isolated execution. The runner had a
##    reserved exit status for exactly this (126, written by
##    ``processGroupWrapperMain`` after its own spawn retries are
##    exhausted) but nothing consumed it: the exit-code switch had no
##    126 arm, so it fell through to ``else: tsFail``. Harness faults now
##    have their own outcome — ``ERROR`` — which is counted separately in
##    the summary, carries its reason in ``harness_error``, and forces a
##    non-zero aggregate exit exactly as ``status_disagreement`` does.
##    Neither absorbing it into ``passed`` (fail-open) nor into ``failed``
##    (asserting an unobserved fact about the tree) is acceptable.
##
## 2. **The summary could not identify a case.** Every entry carried
##    ``qualified_name`` and nothing else — no ``name``, no ``suite``, and
##    no ``run_name``. Splitting ``suite::name`` back apart is not
##    round-trip safe (see ``TestCase.runName`` in the runner: a
##    suite-less case is catalogued as ``::testname`` and the bare
##    ``testname`` is rejected by its own ``--run`` matcher), so a gate
##    consuming only the machine-readable artifact could not reliably
##    name, group or re-run a case, and verification fell back to
##    grepping the console log.
##
## 3. **Protocol detection lost 170 binaries.** The ``--list-json`` probe
##    redirected the child's stderr into the file it then parsed as the
##    catalog. Every test binary linking the clingo solver writes
##    ``<block>:22:1-26: info: ...`` to stderr during module
##    initialisation, so the probe read ``<`` where it required ``{`` and
##    silently downgraded the binary to whole-binary execution. The cases
##    still ran — a whole-binary run runs all of them — but 898 of them
##    stopped being individually addressable in the summary.
##
## 4. **A run that was CUT SHORT reported its in-flight cases as test
##    FAILURES.** An outer wall-clock backstop fired at case 4430 of 8711
##    with eight cases running. All eight were killed by the runner's own
##    shutdown, and all eight were recorded ``FAIL`` — while the summary
##    said ``error=0``. Two of them passed on the next isolated execution;
##    eleven of that run's 84 reported failures were not failures. Nothing
##    was observed about any of the eight, so ``fail`` asserts a property
##    of the tree that the run never measured — the same fault as defect 1,
##    arriving by a different door. Worse, the summary described a
##    4430-case sample as if it were the whole suite: ``total`` was the
##    number of cases that RAN, and nothing said the run had been stopped.
##    In-flight cases are now ERROR flagged ``cancelled``, excluded from
##    ``failed``, and the run says — before the counts, as the build
##    backstop does — that it did not complete and at which case it
##    stopped.
##
## Mock justification (per the workspace testing policy)
## -----------------------------------------------------
## Every fixture here is compiled by the real toolchain and executed by
## the real ``repro_test_runner`` binary; no component is replaced by a
## double. The hand-rolled fixtures are not stand-ins for anything — they
## ARE the faults under test, and a conforming ``std/unittest`` binary
## cannot produce any of them by construction:
##
##   * a conforming binary cannot report "the harness could not start
##     me", because a binary that reports anything has started;
##   * a conforming binary emits a clean catalog, so the pollution the
##     probe has to survive can only come from a fixture that pollutes;
##     and
##   * a conforming binary finishes, so the state defect 4 lives in — a
##     case still running when the runner is told to stop — can only be
##     held open by a fixture that refuses to finish.
##
## The shutdown itself is not simulated either: the test SIGTERMs the real
## runner, and waits on sentinel files for the cases to be demonstrably in
## flight first, so the signal cannot land on an idle runner and report a
## green shutdown that proves nothing.
##
## The clingo stderr noise is reproduced verbatim from a real probe of
## ``build/test-bin/t_dsl_shell_action``.

import std/[json, os, osproc, strutils, tempfiles, unittest]

when defined(posix):
  # Only the cut-short tests below need a clock, and they are POSIX-only:
  # the runner's shutdown path is a signal path, and ``cutShortSignal``
  # is defined to be 0 everywhere else.
  import std/times

template testWithReturn(name: string; body: untyped) =
  test name:
    proc runTestBody() =
      body
    runTestBody()

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

# ---------------------------------------------------------------------
# Fixture 1: a catalog buried in noise on BOTH streams.
#
# ``stderrNoise`` is the real clingo banner, byte for byte. ``stdoutNoise``
# covers the separately-recorded case of a source with a top-level
# ``echo`` interleaving its own output with the payload; separating the
# streams does not help there, so the extractor has to cope too.
# ---------------------------------------------------------------------
const NoisyFixtureSource = """
import std/[json, os]

const
  Marker = "unittest: --run requires a test name"
  SuiteName = "noisy"

proc emitCatalog() =
  # Exactly the banner a clingo-linked test binary writes during module
  # initialisation, on stderr, before main runs.
  stderr.write("<block>:22:1-26: info: no atoms over signature occur in program:\n")
  stderr.write("  variant_assigned/2\n\n")
  stderr.flushFile()
  # And a stray stdout line, ahead of the payload on the payload's own
  # stream.
  echo "noisy fixture: incidental stdout line"
  var tests = newJArray()
  for caseName in ["alpha case", "beta case"]:
    var node = newJObject()
    node["name"] = %(SuiteName & "::" & caseName)
    node["suite"] = %SuiteName
    node["file"] = %"noisy_fixture.nim"
    node["line"] = %1
    tests.add(node)
  var doc = newJObject()
  doc["tests"] = tests
  # Compact, single-line, exactly as ct_test_unittest_parallel emits it.
  echo $doc

proc writeResult(status: string) =
  let path = getEnv("NIMTEST_RESULT_FILE")
  if path.len == 0:
    return
  var doc = newJObject()
  doc["status"] = %status
  doc["duration_ms"] = %1
  doc["checkpoints"] = newJArray()
  doc["exception"] = newJNull()
  writeFile(path, $doc)

proc main() =
  let args = commandLineParams()
  if args.len == 0:
    stderr.writeLine Marker
    quit(2)
  if args[0] == "--list-json":
    emitCatalog()
    quit(0)
  if args[0] == "--run" and args.len >= 2:
    writeResult("PASS")
    quit(0)
  stderr.writeLine Marker
  quit(2)

main()
"""

# ---------------------------------------------------------------------
# Fixture 1b: stderr SPLICED INTO the middle of the catalog.
#
# This is the case that a tolerant extractor cannot rescue and that only
# stream separation fixes. stdout to a file is block-buffered while
# stderr is unbuffered, so a binary that flushes stdout mid-document and
# then writes a diagnostic lands those bytes *inside* the JSON when both
# streams share one file descriptor. No amount of leading/trailing-noise
# tolerance recovers a document with a hole punched through it.
#
# A real binary reaches this state whenever a library logs during
# catalog emission rather than only during module initialisation, which
# is the same class of behaviour as the clingo banner and not something
# the runner gets to forbid.
# ---------------------------------------------------------------------
const SplicedFixtureSource = """
import std/[json, os, strutils]

const
  Marker = "unittest: --run requires a test name"
  SuiteName = "spliced"

proc emitCatalog() =
  var tests = newJArray()
  for caseName in ["gamma case", "delta case"]:
    var node = newJObject()
    node["name"] = %(SuiteName & "::" & caseName)
    node["suite"] = %SuiteName
    node["file"] = %"spliced_fixture.nim"
    node["line"] = %1
    tests.add(node)
  var doc = newJObject()
  doc["tests"] = tests
  let payload = $doc
  # Split at a structural boundary, never inside a string literal, so
  # the interleaved bytes land in JSON syntax rather than inside a value
  # where a lenient parser might swallow them.
  const Head = "{\"tests\":["
  doAssert payload.startsWith(Head)
  stdout.write(Head)
  stdout.flushFile()
  stderr.write("<block>:22:1-26: info: no atoms over signature occur in program:\n")
  stderr.flushFile()
  stdout.write(payload[Head.len .. ^1])
  stdout.write("\n")
  stdout.flushFile()

proc main() =
  let args = commandLineParams()
  if args.len == 0:
    stderr.writeLine Marker
    quit(2)
  if args[0] == "--list-json":
    emitCatalog()
    quit(0)
  if args[0] == "--run" and args.len >= 2:
    let path = getEnv("NIMTEST_RESULT_FILE")
    if path.len > 0:
      var doc = newJObject()
      doc["status"] = %"PASS"
      doc["duration_ms"] = %1
      doc["checkpoints"] = newJArray()
      doc["exception"] = newJNull()
      writeFile(path, $doc)
    quit(0)
  stderr.writeLine Marker
  quit(2)

main()
"""

# ---------------------------------------------------------------------
# Fixture 2: the harness-fault shape.
#
# ``--run`` exits with the reserved harness status without writing a
# result document — the same observable state the process-group wrapper
# leaves behind when its own spawn retries are exhausted. Only the
# wrapper can legitimately produce this status; the fixture stands in for
# an exhausted spawn because a genuine one is a race that cannot be
# scheduled on demand.
# ---------------------------------------------------------------------
const HarnessFaultFixtureSource = """
import std/[json, os, strutils]

const
  Marker = "unittest: --run requires a test name"
  SuiteName = "faulty"

proc emitCatalog() =
  var tests = newJArray()
  for caseName in ["runs fine", "cannot be started"]:
    var node = newJObject()
    node["name"] = %(SuiteName & "::" & caseName)
    node["suite"] = %SuiteName
    node["file"] = %"harness_fault_fixture.nim"
    node["line"] = %1
    tests.add(node)
  var doc = newJObject()
  doc["tests"] = tests
  echo $doc

proc main() =
  let args = commandLineParams()
  if args.len == 0:
    stderr.writeLine Marker
    quit(2)
  if args[0] == "--list-json":
    emitCatalog()
    quit(0)
  if args[0] == "--run" and args.len >= 2:
    if args[1].endsWith("cannot be started"):
      # No result document at all: the harness never got a verdict.
      stderr.writeLine "repro_test_runner: HARNESS ERROR - child spawn failed"
      quit(126)
    let path = getEnv("NIMTEST_RESULT_FILE")
    if path.len > 0:
      var doc = newJObject()
      doc["status"] = %"PASS"
      doc["duration_ms"] = %1
      doc["checkpoints"] = newJArray()
      doc["exception"] = newJNull()
      writeFile(path, $doc)
    quit(0)
  stderr.writeLine Marker
  quit(2)

main()
"""

# ---------------------------------------------------------------------
# Fixture 3: cases that are still running when the run is cut short.
#
# Each case announces itself by creating a sentinel file and then sleeps
# for longer than the test is willing to wait. The sentinel is what makes
# the kill DETERMINISTIC rather than timing-based: the test waits until
# exactly as many cases as there are workers have started, and only then
# signals the runner. A sleep-and-hope kill would race the probe on a
# loaded host and would either kill an idle runner (proving nothing) or
# be flaky, and a flaky test for a misreporting defect is worse than no
# test — it teaches a reader to ignore the signal.
#
# The sleep is deliberately far longer than the whole test: a case that
# could finish on its own would let the runner reach a real verdict, and
# the property under test is precisely what happens when it cannot.
# ---------------------------------------------------------------------
const SleepingFixtureSource = """
import std/[json, os, strutils]

const
  Marker = "unittest: --run requires a test name"
  SuiteName = "sleeper"

proc emitCatalog() =
  var tests = newJArray()
  for i in 0 ..< 6:
    var node = newJObject()
    node["name"] = %(SuiteName & "::case " & $i)
    node["suite"] = %SuiteName
    node["file"] = %"sleeping_fixture.nim"
    node["line"] = %1
    tests.add(node)
  var doc = newJObject()
  doc["tests"] = tests
  echo $doc

proc main() =
  let args = commandLineParams()
  if args.len == 0:
    stderr.writeLine Marker
    quit(2)
  if args[0] == "--list-json":
    emitCatalog()
    quit(0)
  if args[0] == "--run" and args.len >= 2:
    let sentinelDir = getEnv("REPRO_TEST_SHUTDOWN_SENTINELS")
    if sentinelDir.len > 0:
      writeFile(sentinelDir / args[1].multiReplace([
        ("::", "__"), (" ", "_")]) & ".started", "1")
    sleep(600_000)
    let path = getEnv("NIMTEST_RESULT_FILE")
    if path.len > 0:
      var doc = newJObject()
      doc["status"] = %"PASS"
      doc["duration_ms"] = %1
      doc["checkpoints"] = newJArray()
      doc["exception"] = newJNull()
      writeFile(path, $doc)
    quit(0)
  stderr.writeLine Marker
  quit(2)

main()
"""

# ---------------------------------------------------------------------
# Fixture 4: one ordinary case and one that makes no progress at all.
#
# The second case burns no CPU and writes nothing, which is exactly the
# shape ``--test-timeout`` is defined against (it is a NO-PROGRESS
# deadline, not a wall-clock budget). It exists to pin the OTHER half of
# the rule: a case the runner killed on its own deadline is still a FAIL,
# and only a cancellation is not. Without this fixture the shutdown fix
# could be "passed" by relabelling every kill as ERROR, which would move
# real hangs out of the count a gate reads.
# ---------------------------------------------------------------------
const HangingFixtureSource = """
import std/[json, os, strutils]

const
  Marker = "unittest: --run requires a test name"
  SuiteName = "hanging"

proc emitCatalog() =
  var tests = newJArray()
  for caseName in ["finishes", "makes no progress"]:
    var node = newJObject()
    node["name"] = %(SuiteName & "::" & caseName)
    node["suite"] = %SuiteName
    node["file"] = %"hanging_fixture.nim"
    node["line"] = %1
    tests.add(node)
  var doc = newJObject()
  doc["tests"] = tests
  echo $doc

proc main() =
  let args = commandLineParams()
  if args.len == 0:
    stderr.writeLine Marker
    quit(2)
  if args[0] == "--list-json":
    emitCatalog()
    quit(0)
  if args[0] == "--run" and args.len >= 2:
    if args[1].endsWith("makes no progress"):
      sleep(600_000)
      quit(0)
    let path = getEnv("NIMTEST_RESULT_FILE")
    if path.len > 0:
      var doc = newJObject()
      doc["status"] = %"PASS"
      doc["duration_ms"] = %1
      doc["checkpoints"] = newJArray()
      doc["exception"] = newJNull()
      writeFile(path, $doc)
    quit(0)
  stderr.writeLine Marker
  quit(2)

main()
"""

# ---------------------------------------------------------------------
# Fixture 5: an OPAQUE binary that never finishes.
#
# It refuses the catalog probe, so the runner executes it whole-binary —
# one summary entry standing for every case inside it. That is why this
# path needs its own coverage rather than inheriting the per-case one: a
# whole-binary entry called FAIL on a shutdown asserts a defect about all
# of its cases at once, on the strength of a kill the runner ordered.
# ---------------------------------------------------------------------
const OpaqueSleepingFixtureSource = """
import std/os

proc main() =
  let args = commandLineParams()
  if args.len > 0 and args[0] == "--list-json":
    # No catalog, and nothing a probe could mistake for one.
    stderr.writeLine "this binary has no case catalog"
    quit(1)
  let sentinelDir = getEnv("REPRO_TEST_SHUTDOWN_SENTINELS")
  if sentinelDir.len > 0:
    writeFile(sentinelDir / "whole_binary.started", "1")
  sleep(600_000)

main()
"""

proc compileFixture(workRoot, source, binary: string): bool =
  let cmd = "nim c --threads:on --hints:off --warnings:off " &
    "--nimcache:" & quoteShell(workRoot / "nimcache") & " " &
    "--out:" & quoteShell(binary) & " " & quoteShell(source)
  execCmd(cmd) == 0

proc runnerPath(): string =
  findRepoRoot() / "build" / "bin" / addFileExt("repro_test_runner", ExeExt)

proc runRunner(runner, binDir, summary, resultsDir: string;
               testTimeoutSec = 0): tuple[exitCode: int; output: string] =
  let cmd = quoteShell(runner) &
    " --no-build --threads=1 --quiet" &
    (if testTimeoutSec > 0: " --test-timeout=" & $testTimeoutSec else: "") &
    " --bin-dir=" & quoteShell(binDir) &
    " --summary-json=" & quoteShell(summary) &
    " --results-dir=" & quoteShell(resultsDir)
  let (output, exitCode) = execCmdEx(cmd)
  (exitCode, output)

proc entryFor(doc: JsonNode; qualified: string): JsonNode =
  result = newJNull()
  for entry in doc["tests"]:
    if entry{"qualified_name"}.getStr() == qualified:
      return entry

proc buildAndRun(stem, source: string;
                 doc: var JsonNode; exitCode: var int;
                 testTimeoutSec = 0): bool =
  ## Compile one fixture into a private bin dir, run the real runner
  ## over it, and parse the summary. Returns false (with checkpoints
  ## already recorded) if any prerequisite is missing.
  doc = newJNull()
  exitCode = -1
  let runner = runnerPath()
  if not fileExists(runner):
    checkpoint("runner not built at " & runner)
    return false
  let tempRoot = createTempDir("repro-runner-report-", "")
  let binDir = tempRoot / "bin"
  createDir(binDir)
  let src = tempRoot / (stem & ".nim")
  writeFile(src, source)
  if not compileFixture(tempRoot, src, binDir / addFileExt(stem, ExeExt)):
    checkpoint("fixture failed to compile: " & stem)
    return false
  let summary = tempRoot / "summary.json"
  let (code, output) = runRunner(runner, binDir, summary,
                                 tempRoot / "results", testTimeoutSec)
  exitCode = code
  if not fileExists(summary):
    checkpoint("no summary written; runner said: " & output)
    return false
  doc = parseJson(readFile(summary))
  removeDir(tempRoot)
  true

when defined(posix):
  const SentinelEnv = "REPRO_TEST_SHUTDOWN_SENTINELS"

  proc countSentinels(dir: string): int =
    for kind, _ in walkDir(dir):
      if kind == pcFile:
        inc result

  proc buildAndCutShort(stem, source: string; threads: int;
                        doc: var JsonNode; exitCode: var int;
                        output: var string): bool =
    ## Start the real runner over a fixture whose cases never finish, wait
    ## until ``threads`` of them are demonstrably IN FLIGHT, and only then
    ## SIGTERM the runner — the same thing an outer wall-clock backstop, a
    ## Ctrl-C or an operator kill does to a suite run.
    ##
    ## The wait is on sentinel files rather than on a sleep because the
    ## property under test only exists while cases are running: signalling
    ## an idle runner would produce a green shutdown and prove nothing, and
    ## on a host at load 200 a fixed sleep is exactly that coin flip.
    doc = newJNull()
    exitCode = -1
    output = ""
    let runner = runnerPath()
    if not fileExists(runner):
      checkpoint("runner not built at " & runner)
      return false
    let tempRoot = createTempDir("repro-runner-cutshort-", "")
    let binDir = tempRoot / "bin"
    let sentinels = tempRoot / "sentinels"
    createDir(binDir)
    createDir(sentinels)
    let src = tempRoot / (stem & ".nim")
    writeFile(src, source)
    if not compileFixture(tempRoot, src, binDir / addFileExt(stem, ExeExt)):
      checkpoint("fixture failed to compile: " & stem)
      return false
    let summary = tempRoot / "summary.json"
    let logPath = tempRoot / "runner.log"
    putEnv(SentinelEnv, sentinels)
    # ``exec`` so the shell is REPLACED by the runner: the pid this test
    # holds has to be the runner's own or the SIGTERM below would land on
    # ``/bin/sh`` and the runner would never see the signal under test.
    # Output is redirected inside the shell rather than read through a pipe
    # so a full pipe buffer cannot wedge the child we are about to signal.
    let cmd = "exec " & quoteShell(runner) &
      " --no-build --threads=" & $threads &
      " --bin-dir=" & quoteShell(binDir) &
      " --summary-json=" & quoteShell(summary) &
      " --results-dir=" & quoteShell(tempRoot / "results") &
      " > " & quoteShell(logPath) & " 2>&1"
    # ``poDaemon`` is setpgid on POSIX: the runner leads its own process
    # group, so neither its own group-wide kills nor ours can reach this
    # test process.
    var p = startProcess(cmd, options = {poEvalCommand, poDaemon})
    let deadline = epochTime() + 180.0
    var inFlight = 0
    while true:
      inFlight = countSentinels(sentinels)
      if inFlight >= threads:
        break
      if not p.running:
        break
      if epochTime() > deadline:
        break
      sleep(100)
    checkpoint("cases in flight when the runner was signalled: " & $inFlight)
    p.terminate()  # SIGTERM to the runner only, not to its children
    exitCode = p.waitForExit()
    p.close()
    delEnv(SentinelEnv)
    if fileExists(logPath):
      output = readFile(logPath)
    if not fileExists(summary):
      checkpoint("no summary written; runner said: " & output)
      return false
    doc = parseJson(readFile(summary))
    if inFlight < threads:
      checkpoint("only " & $inFlight & " of " & $threads &
        " cases started; the signal did not land on a busy runner")
      return false
    true

suite "repro_test_runner reporting contract":

  testWithReturn "a stderr-polluted --list-json still enumerates individual cases":
    # The regression this pins: the probe used to merge the child's
    # stderr into the stream it parsed, so a binary whose libraries chat
    # on stderr was classified opaque and reported as ONE whole-binary
    # entry instead of its actual cases.
    var doc: JsonNode
    var exitCode = -1
    if not buildAndRun("t_noisy_catalog_fixture", NoisyFixtureSource,
                       doc, exitCode):
      check false
      return

    check exitCode == 0
    check doc{"summary"}{"total"}.getInt(-1) == 2
    check doc{"summary"}{"passed"}.getInt(-1) == 2

    let alpha = entryFor(doc, "noisy::alpha case")
    let beta = entryFor(doc, "noisy::beta case")
    check alpha.kind != JNull
    check beta.kind != JNull
    if alpha.kind == JNull or beta.kind == JNull:
      # A single whole-binary entry is the exact failure shape.
      for entry in doc["tests"]:
        checkpoint("entry: " & entry{"qualified_name"}.getStr() &
          " protocol_aware=" & $entry{"protocol_aware"}.getBool())
      return
    check alpha{"protocol_aware"}.getBool() == true
    check beta{"protocol_aware"}.getBool() == true

  testWithReturn "stderr spliced into the catalog does not hide the cases":
    # Separation of the two streams, isolated: this fixture's stdout is
    # a valid catalog and its stderr is noise, but the two interleave
    # into an unparseable file the moment they share a descriptor.
    var doc: JsonNode
    var exitCode = -1
    if not buildAndRun("t_spliced_catalog_fixture", SplicedFixtureSource,
                       doc, exitCode):
      check false
      return

    check exitCode == 0
    check doc{"summary"}{"total"}.getInt(-1) == 2
    let gamma = entryFor(doc, "spliced::gamma case")
    check gamma.kind != JNull
    if gamma.kind == JNull:
      for entry in doc["tests"]:
        checkpoint("entry: " & entry{"qualified_name"}.getStr() &
          " protocol_aware=" & $entry{"protocol_aware"}.getBool())
      return
    check gamma{"protocol_aware"}.getBool() == true

  testWithReturn "every summary entry carries name, suite and run_name":
    var doc: JsonNode
    var exitCode = -1
    if not buildAndRun("t_noisy_catalog_fixture", NoisyFixtureSource,
                       doc, exitCode):
      check false
      return

    # The blanket invariant: no entry may be nameless. This is the
    # assertion that makes the artifact usable by a gate at all.
    # ``entry{key}`` yields nil for an absent key and ``.kind`` on nil
    # segfaults, so every probe goes through ``hasKey`` first — the
    # assertion has to survive the very absence it is asserting against.
    for entry in doc["tests"]:
      for key in ["name", "suite", "run_name"]:
        checkpoint("entry " & entry{"qualified_name"}.getStr() &
          " key " & key)
        check entry.hasKey(key)
        if entry.hasKey(key):
          check entry[key].kind == JString
      # ``suite`` and ``run_name`` are legitimately empty for a
      # whole-binary entry; ``name`` never is.
      check entry{"name"}.getStr().len > 0

    let alpha = entryFor(doc, "noisy::alpha case")
    check alpha.kind != JNull
    if alpha.kind == JNull:
      return
    check alpha{"name"}.getStr() == "alpha case"
    check alpha{"suite"}.getStr() == "noisy"
    # ``run_name`` is the catalog's verbatim ``name`` — the only string
    # the binary's own ``--run`` matcher is guaranteed to accept — and is
    # therefore NOT the same field as ``name``.
    check alpha{"run_name"}.getStr() == "noisy::alpha case"

  testWithReturn "a harness fault is ERROR, not FAIL, and fails the run":
    var doc: JsonNode
    var exitCode = -1
    if not buildAndRun("t_harness_fault_fixture", HarnessFaultFixtureSource,
                       doc, exitCode):
      check false
      return

    let ok = entryFor(doc, "faulty::runs fine")
    let broken = entryFor(doc, "faulty::cannot be started")
    check ok.kind != JNull
    check broken.kind != JNull
    if ok.kind == JNull or broken.kind == JNull:
      return

    check ok{"status"}.getStr() == "PASS"

    # The load-bearing three assertions.
    #
    # (a) its own label — not FAIL, which would assert a property of the
    #     code that nothing observed, and not PASS, which would be a
    #     fail-open;
    check broken{"status"}.getStr() == "ERROR"
    check broken.hasKey("harness_error")
    check broken{"harness_error"}.getStr().len > 0

    # (b) its own count, kept out of both other buckets, so a triage
    #     script reading only the summary can separate "the tree is
    #     broken" from "this host could not run it";
    check doc{"summary"}{"harness_errors"}.getInt(-1) == 1
    check doc{"summary"}{"failed"}.getInt(-1) == 0
    check doc{"summary"}{"passed"}.getInt(-1) == 1
    check doc{"summary"}{"total"}.getInt(-1) == 2

    # (c) and a non-zero aggregate exit, because a run that could not
    #     execute part of itself has not passed. Recording the fault and
    #     then exiting 0 is the same fail-open the status-disagreement
    #     rule already closes.
    checkpoint("runner exit=" & $exitCode)
    check exitCode != 0

    # A harness error must never be dressed up as a protocol
    # disagreement: no verdict was produced, so there is nothing to
    # disagree with. In particular a stale result document left by an
    # earlier run of the same case must not be read back over it.
    check not broken.hasKey("status_disagreement")
    check doc{"summary"}{"status_disagreements"}.getInt(-1) == 0

  # The two cut-short tests are POSIX-only by construction: the runner's
  # shutdown path is a signal path, and ``cutShortSignal`` is defined to
  # be 0 on every other platform, so there is no cut-short state to
  # observe. Signalling and the shell redirect below would also mean
  # something different on Windows.
  when defined(posix):
    testWithReturn "a run cut short reports its in-flight cases as ERROR, not FAIL":
      # The defect, measured on a real 8711-case run: the outer wall-clock
      # backstop fired at case 4430 with eight cases running. All eight were
      # recorded ``FAIL`` while the summary said ``error=0``; two of them
      # passed on the next isolated execution. Eleven of that run's 84
      # reported failures were not failures — the runner had asserted a
      # property of the tree that nothing had observed, and the count a gate
      # reads for defects carried it.
      var doc: JsonNode
      var exitCode = -1
      var output = ""
      if not buildAndCutShort("t_sleeping_fixture", SleepingFixtureSource, 4,
                              doc, exitCode, output):
        check false
        return

      let summary = doc{"summary"}
      let total = summary{"total"}.getInt(-1)
      let planned = summary{"planned_total"}.getInt(-1)
      checkpoint("total=" & $total & " planned=" & $planned &
        " failed=" & $summary{"failed"}.getInt(-1) &
        " errors=" & $summary{"harness_errors"}.getInt(-1) &
        " cancelled=" & $summary{"cancelled"}.getInt(-1))

      # (a) THE COUNT. Not one of the killed cases may appear in ``failed``.
      #     This is the assertion the defect violated, and the only one that
      #     matters to a gate reading the artifact rather than the log.
      check summary{"failed"}.getInt(-1) == 0
      check summary{"cancelled"}.getInt(-1) == total
      check summary{"harness_errors"}.getInt(-1) == total

      # (b) THE LABEL, per entry. ERROR, flagged ``cancelled``, and carrying
      #     both a reason and a runner-authored diagnosis — the eight real
      #     entries had none of the four.
      for entry in doc["tests"]:
        checkpoint("entry " & entry{"qualified_name"}.getStr() &
          " status=" & entry{"status"}.getStr())
        check entry{"status"}.getStr() == "ERROR"
        check entry{"cancelled"}.getBool() == true
        check entry{"harness_error"}.getStr().len > 0
        check entry{"runner_diagnosis"}.getStr().len > 0
        # The word the reader must not find on a case nobody observed.
        check not entry{"runner_diagnosis"}.getStr().contains("this is a verdict")

      # (c) THE RUN, said in the artifact: cut short, and at which case. A
      #     consumer must not have to infer it by comparing two numbers, and
      #     ``total`` must stop being readable as the size of the suite.
      check summary{"cut_short"}.getBool() == true
      check planned > total
      check summary.hasKey("cut_short_detail")
      if summary.hasKey("cut_short_detail"):
        let cut = summary["cut_short_detail"]
        check cut{"signal_name"}.getStr() == "SIGTERM"
        check cut{"cases_run"}.getInt(-1) == total
        check cut{"cases_planned"}.getInt(-1) == planned
        check cut{"cases_never_started"}.getInt(-1) == planned - total
        check cut{"note"}.getStr().contains("did NOT complete")

      # (d) THE RUN, said on the console, ahead of the counts. Same sentence
      #     and same placement as the build backstop's "the build did NOT
      #     fail, it ran out of wall clock" — a reader who meets the counts
      #     first reads a sample as a census.
      checkpoint("runner said:\n" & output)
      check output.contains("THIS RUN DID NOT COMPLETE")
      check output.contains("it stopped at case " & $total & " of " & $planned)
      check output.contains("CUT SHORT at " & $total & "/" & $planned)
      check not output.contains("[FAIL]")

      # (e) And the run still does not pass. Recording the cases as ERROR
      #     must not become a way to exit green on a run that never finished.
      checkpoint("runner exit=" & $exitCode)
      check exitCode != 0

    testWithReturn "a whole-binary entry cut short is ERROR, not FAIL":
      # The same rule on the path where the stakes are highest: this one
      # entry stands for every case in the binary, so mislabelling it FAIL
      # asserts a defect about all of them from a kill the runner ordered.
      var doc: JsonNode
      var exitCode = -1
      var output = ""
      if not buildAndCutShort("t_opaque_sleeper_fixture",
                              OpaqueSleepingFixtureSource, 1,
                              doc, exitCode, output):
        check false
        return

      let summary = doc{"summary"}
      checkpoint("failed=" & $summary{"failed"}.getInt(-1) &
        " errors=" & $summary{"harness_errors"}.getInt(-1) &
        " cancelled=" & $summary{"cancelled"}.getInt(-1))
      check summary{"failed"}.getInt(-1) == 0
      check summary{"harness_errors"}.getInt(-1) == 1
      check summary{"cancelled"}.getInt(-1) == 1
      check summary{"cut_short"}.getBool() == true
      for entry in doc["tests"]:
        check entry{"status"}.getStr() == "ERROR"
        check entry{"cancelled"}.getBool() == true
        check entry{"harness_error"}.getStr().len > 0
      check output.contains("THIS RUN DID NOT COMPLETE")
      check exitCode != 0

  testWithReturn "a case killed on its own deadline is still a FAIL":
    # The other half of the rule, and the reason this file needs a second
    # fixture: the fix above could be "passed" by relabelling every kill
    # as ERROR, which would quietly move real hangs out of ``failed``.
    # ``--test-timeout`` is a NO-PROGRESS deadline the runner enforces
    # against ONE case while the run is healthy, so the runner did observe
    # this case misbehaving and owes a verdict about it.
    var doc: JsonNode
    var exitCode = -1
    if not buildAndRun("t_hanging_fixture", HangingFixtureSource,
                       doc, exitCode, testTimeoutSec = 5):
      check false
      return

    let summary = doc{"summary"}
    checkpoint("failed=" & $summary{"failed"}.getInt(-1) &
      " errors=" & $summary{"harness_errors"}.getInt(-1) &
      " cancelled=" & $summary{"cancelled"}.getInt(-1))
    check summary{"passed"}.getInt(-1) == 1
    check summary{"failed"}.getInt(-1) == 1
    check summary{"harness_errors"}.getInt(-1) == 0
    # Nothing cut this run short; the distinction has to survive that.
    check summary{"cancelled"}.getInt(-1) == 0
    check summary{"cut_short"}.getBool() == false
    check not summary.hasKey("cut_short_detail")

    let hung = entryFor(doc, "hanging::makes no progress")
    check hung.kind != JNull
    if hung.kind == JNull:
      return
    check hung{"status"}.getStr() == "FAIL"
    check not hung.hasKey("cancelled")
    # And it is owed an account too — a deadline kill used to reach the
    # console as a bare labelled line for the same reason a cancellation
    # did: its explanation was written to ``stdout``, which the progress
    # line never prints.
    check hung{"runner_diagnosis"}.getStr().contains("its own deadline")

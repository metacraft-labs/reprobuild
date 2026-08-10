## t_repro_test_runner_reporting_contract — the runner's summary must be
## able to name what it ran, and must not report harness faults as test
## results.
##
## Three defects, all found by auditing a completed 5923-case suite run
## against ``test-logs/parallel-run.json``, all of them defects in what
## the run REPORTED rather than in what it executed:
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
## Mock justification (per the workspace testing policy)
## -----------------------------------------------------
## Every fixture here is compiled by the real toolchain and executed by
## the real ``repro_test_runner`` binary; no component is replaced by a
## double. The two hand-rolled fixtures are not stand-ins for anything —
## they ARE the faults under test, and a conforming ``std/unittest``
## binary cannot produce either of them by construction:
##
##   * a conforming binary cannot report "the harness could not start
##     me", because a binary that reports anything has started; and
##   * a conforming binary emits a clean catalog, so the pollution the
##     probe has to survive can only come from a fixture that pollutes.
##
## The clingo stderr noise is reproduced verbatim from a real probe of
## ``build/test-bin/t_dsl_shell_action``.

import std/[json, os, osproc, strutils, tempfiles, unittest]

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

proc compileFixture(workRoot, source, binary: string): bool =
  let cmd = "nim c --threads:on --hints:off --warnings:off " &
    "--nimcache:" & quoteShell(workRoot / "nimcache") & " " &
    "--out:" & quoteShell(binary) & " " & quoteShell(source)
  execCmd(cmd) == 0

proc runnerPath(): string =
  findRepoRoot() / "build" / "bin" / addFileExt("repro_test_runner", ExeExt)

proc runRunner(runner, binDir, summary, resultsDir: string):
    tuple[exitCode: int; output: string] =
  let cmd = quoteShell(runner) &
    " --no-build --threads=1 --quiet" &
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
                 doc: var JsonNode; exitCode: var int): bool =
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
                                 tempRoot / "results")
  exitCode = code
  if not fileExists(summary):
    checkpoint("no summary written; runner said: " & output)
    return false
  doc = parseJson(readFile(summary))
  removeDir(tempRoot)
  true

suite "repro_test_runner reporting contract":

  test "a stderr-polluted --list-json still enumerates individual cases":
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

  test "stderr spliced into the catalog does not hide the cases":
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

  test "every summary entry carries name, suite and run_name":
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

  test "a harness fault is ERROR, not FAIL, and fails the run":
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

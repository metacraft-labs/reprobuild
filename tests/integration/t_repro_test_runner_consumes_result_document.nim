## t_repro_test_runner_consumes_result_document —
## the runner must read the whole ``$NIMTEST_RESULT_FILE`` document.
##
## The protocol has a test binary write a JSON result document with
## ``status``, ``duration_ms``, ``checkpoints``, ``exception`` and — only
## when non-empty — ``skipReason``. The runner used to open that document
## and read exactly one field, ``duration_ms``, deriving everything else
## from the child's exit code. Two consequences:
##
##  * a skip's reason was written by the binary and then discarded, so no
##    run summary could ever say *why* anything was skipped; and
##  * the two status channels (document vs exit code) were never
##    compared, so a binary whose channels disagreed was silently
##    reported by whichever one the runner happened to consult.
##
## What this test guarantees
## -------------------------
## Case 1 (real toolchain, no mocking): a fixture with one pass, one
## fail, one ``skip("reason")`` and one bare ``skip()`` round-trips
## through the runner with every status correct, the reason surfaced as
## ``skip_reason`` in the summary, the bare skip carrying **no**
## ``skip_reason`` key, and the failing case's ``checkpoint_count``
## reaching the summary. The absent-key assertion is load-bearing: the
## reader must tolerate absence rather than fault on it.
##
## Case 2: a binary whose document contradicts its exit code is reported
## by the document, and the contradiction is recorded verbatim in
## ``status_disagreement`` rather than being silently reconciled away.
##
## Case 3 (the load-bearing one): that contradiction must also FAIL THE
## RUN. Recording a disagreement and then exiting 0 is a fail-open. The
## fork writes the result document from ``testEnded``, i.e. before the
## process exits, so "document says PASS, process exits non-zero" is
## exactly the shape of a case that passed and then died in a destructor,
## a ``defer``, an exit proc or a teardown segfault. The old behaviour
## labelled that PASS, never incremented ``failed``, and exited 0 — a
## crash that no gate could see. The aggregate exit code is therefore
## asserted non-zero here, and the summary must carry
## ``status_disagreements``.
##
## Mock justification (per the workspace testing policy)
## ----------------------------------------------------
## Case 1 uses no mock at all — it is a real ``std/unittest`` binary
## compiled by the real toolchain and executed by the real runner.
##
## Case 2 uses a hand-rolled binary because the thing under test is the
## runner's response to a **protocol-violating peer**, and a conforming
## toolchain cannot, by construction, produce one. The fixture is not
## standing in for a component; it is the fault being detected.

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

const SkipReasonText = "REPRO_M2_RESULT_DOC_GATE not set"

const OutcomesFixtureSource = """
import std/unittest

suite "outcomes":
  test "passing case":
    check 1 == 1
  test "failing case":
    check 1 == 2
  test "skipped with reason":
    skip("$REASON")
  test "skipped bare":
    skip()
"""

const DisagreeingFixtureSource = """
## Protocol-violating fixture: its result document says PASS while the
## process exits 1. A conforming binary cannot do this; the runner is
## required to trust the document and report the contradiction.
import std/[json, os]

const
  # One of repro_test_runner's ProtocolMarkers, on the ordinary
  # argv-error path so no optimisation level can elide it.
  Marker = "unittest: --run requires a test name"
  CaseName = "disagree::case"

proc emitCatalog() =
  var node = newJObject()
  node["name"] = %CaseName
  node["suite"] = %"disagree"
  node["file"] = %"disagreeing_fixture.nim"
  node["line"] = %1
  var tests = newJArray()
  tests.add(node)
  var doc = newJObject()
  doc["tests"] = tests
  var summary = newJObject()
  summary["total"] = %1
  doc["summary"] = summary
  echo doc.pretty()

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
      doc["duration_ms"] = %7
      doc["checkpoints"] = newJArray()
      doc["exception"] = newJNull()
      writeFile(path, doc.pretty())
    # Deliberately contradict the document.
    quit(1)
  stderr.writeLine Marker
  quit(2)

main()
"""

proc compileFixture(workRoot, source, binary: string): bool =
  let cmd = "nim c --threads:on --hints:off --warnings:off " &
    "--nimcache:" & quoteShell(workRoot / "nimcache") & " " &
    "--out:" & quoteShell(binary) & " " & quoteShell(source)
  execCmd(cmd) == 0

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

suite "repro_test_runner consumes the whole result document":
  test "pass/fail/skip-with-reason/bare-skip all round-trip":
    let repoRoot = findRepoRoot()
    let runner = repoRoot / "build" / "bin" /
      addFileExt("repro_test_runner", ExeExt)
    check fileExists(runner)
    if not fileExists(runner):
      return

    let tempRoot = createTempDir("repro-m2-resultdoc-", "")
    defer: removeDir(tempRoot)
    let binDir = tempRoot / "bin"
    createDir(binDir)

    const Stem = "t_outcomes_fixture"
    let src = tempRoot / (Stem & ".nim")
    writeFile(src, OutcomesFixtureSource.replace("$REASON", SkipReasonText))
    let compiled =
      compileFixture(tempRoot, src, binDir / addFileExt(Stem, ExeExt))
    check compiled
    if not compiled:
      return

    let summary = tempRoot / "summary.json"
    let (exitCode, output) =
      runRunner(runner, binDir, summary, tempRoot / "results")
    # One case fails on purpose, so the aggregate exit code is 1.
    checkpoint("runner exit=" & $exitCode)
    if not fileExists(summary):
      checkpoint(output)
    check exitCode == 1
    check fileExists(summary)
    if not fileExists(summary):
      return

    let doc = parseJson(readFile(summary))
    check doc{"summary"}{"total"}.getInt(-1) == 4
    check doc{"summary"}{"passed"}.getInt(-1) == 1
    check doc{"summary"}{"failed"}.getInt(-1) == 1
    check doc{"summary"}{"skipped"}.getInt(-1) == 2

    let passing = entryFor(doc, "outcomes::passing case")
    check passing.kind != JNull
    check passing{"status"}.getStr() == "PASS"

    let failing = entryFor(doc, "outcomes::failing case")
    check failing.kind != JNull
    check failing{"status"}.getStr() == "FAIL"
    # ``checkpoints`` reached the summary: the failed ``check`` recorded
    # at least one diagnostic line in the document.
    check failing{"checkpoint_count"}.getInt(0) >= 1

    let skippedWithReason = entryFor(doc, "outcomes::skipped with reason")
    check skippedWithReason.kind != JNull
    check skippedWithReason{"status"}.getStr() == "SKIP"
    check skippedWithReason{"skip_reason"}.getStr() == SkipReasonText

    let skippedBare = entryFor(doc, "outcomes::skipped bare")
    check skippedBare.kind != JNull
    check skippedBare{"status"}.getStr() == "SKIP"
    # Absence, not emptiness: the protocol omits the key for a bare
    # skip and the reader must cope without faulting.
    check not skippedBare.hasKey("skip_reason")

    # Nothing here contradicted itself, so nothing may be reported as a
    # disagreement — neither per case nor in the aggregate. The aggregate
    # zero is what proves the new exit rule did not simply start failing
    # every run.
    for entry in doc["tests"]:
      check not entry.hasKey("status_disagreement")
    check doc{"summary"}{"status_disagreements"}.getInt(-1) == 0

  test "a document contradicting the exit code wins and is reported":
    let repoRoot = findRepoRoot()
    let runner = repoRoot / "build" / "bin" /
      addFileExt("repro_test_runner", ExeExt)
    check fileExists(runner)
    if not fileExists(runner):
      return

    let tempRoot = createTempDir("repro-m2-resultdoc-dis-", "")
    defer: removeDir(tempRoot)
    let binDir = tempRoot / "bin"
    createDir(binDir)

    const Stem = "t_disagreeing_fixture"
    let src = tempRoot / (Stem & ".nim")
    writeFile(src, DisagreeingFixtureSource)
    let compiled =
      compileFixture(tempRoot, src, binDir / addFileExt(Stem, ExeExt))
    check compiled
    if not compiled:
      return

    let summary = tempRoot / "summary.json"
    let (exitCode, output) =
      runRunner(runner, binDir, summary, tempRoot / "results")
    checkpoint("runner exit=" & $exitCode)
    if not fileExists(summary):
      checkpoint(output)
    check fileExists(summary)
    if not fileExists(summary):
      return

    let doc = parseJson(readFile(summary))
    check doc{"summary"}{"total"}.getInt(-1) == 1
    let entry = entryFor(doc, "disagree::case")
    check entry.kind != JNull
    if entry.kind == JNull:
      return
    # The document said PASS; the exit code said FAIL. The document wins.
    check entry{"status"}.getStr() == "PASS"
    # And the contradiction is on the record, naming both channels.
    check entry.hasKey("status_disagreement")
    let disagreement = entry{"status_disagreement"}.getStr()
    check disagreement.contains("PASS")
    check disagreement.contains("exit code 1")
    # The runner also took the document's duration over its own clock.
    check entry{"duration_ms"}.getInt(-1) == 7

    # ---- the fail-open gate --------------------------------------------
    # The case's LABEL is PASS (asserted above) and the run's aggregate
    # summary therefore reports one pass and zero failures...
    check doc{"summary"}{"passed"}.getInt(-1) == 1
    check doc{"summary"}{"failed"}.getInt(-1) == 0
    # ...but the disagreement is counted in its own right,
    check doc{"summary"}{"status_disagreements"}.getInt(-1) == 1
    # and it alone decides the exit code. This is the assertion that
    # distinguishes "the runner noticed" from "the runner acted": before
    # this change the runner wrote status_disagreement into the summary,
    # exited 0, and every gate above it read a green run. A process that
    # dies non-zero after its own PASS document has been written must not
    # be able to produce a passing suite.
    check exitCode != 0
    check exitCode == 1

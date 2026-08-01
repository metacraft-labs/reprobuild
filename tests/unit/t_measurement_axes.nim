## t_measurement_axes — the three measurement axes as specified in
## ``reprobuild-specs/CLI/README.md`` §"Measurement: Collect, Present, Persist".
##
## What this test owns
## -------------------
## The axis SEMANTICS, exercised against the real parsers, writers, and
## renderers in ``repro_cli_support`` — no mocks and no stubbed filesystem.
## Specifically:
##
##   1. ``--measure`` additivity across repeated occurrences, and the ``all``
##      / ``none`` special values (``none`` CLEARS rather than omits, which is
##      what makes ``--measure=none,timing`` an exact-set idiom).
##   2. Rejection of unknown categories, with the vocabulary in the message.
##   3. The failure report is SHAPED for failure: failing and blocked actions
##      only, never the successes, and it carries the cache/fingerprint state
##      that led there.
##   4. The presenters render only what they are given.
##   5. PERSIST is outcome-dependent: a successful run writes nothing, a
##      failed run writes unasked, and ``--no-write-report`` defeats both.
##
## Deliberately NOT owned here: the CLI wiring from argv to engine config
## (``t_measurement_flags_cli.nim``) and the engine's own collection switches
## (``t_integration_build_engine_api_ready_queue.nim``).

import std/[json, os, strutils, tempfiles, unittest]

import repro_cli_support
import repro_build_engine

suite "measurement axes: COLLECT (--measure)":

  test "the default set is the cheap diagnostic subset":
    # ``trace`` and ``cache-evidence`` are on because measurement is what
    # makes a failure explicable; ``timing`` is off because it instruments
    # the invalidation and cache-lookup hot paths.
    check DefaultMeasureSet == {mcTrace, mcCacheEvidence}
    check mcTiming notin DefaultMeasureSet

  test "a category list is parsed into exactly those categories":
    check parseMeasureCategories({}, "trace", "--measure") == {mcTrace}
    check parseMeasureCategories({}, "trace,timing", "--measure") ==
      {mcTrace, mcTiming}
    check parseMeasureCategories({}, "cache-evidence", "--measure") ==
      {mcCacheEvidence}
    # Whitespace and case are tolerated; the vocabulary is not.
    check parseMeasureCategories({}, " TRACE , timing ", "--measure") ==
      {mcTrace, mcTiming}

  test "repeated occurrences are ADDITIVE, not last-wins":
    # This is the property that makes the flag composable in wrapper scripts:
    # appending another --measure can only ever widen the set.
    var selection: MeasureSet = {}
    selection = parseMeasureCategories(selection, "trace", "--measure")
    selection = parseMeasureCategories(selection, "timing", "--measure")
    selection = parseMeasureCategories(selection, "cache-evidence", "--measure")
    check selection == {mcTrace, mcTiming, mcCacheEvidence}
    # Re-naming a category already present is a no-op, not an error.
    selection = parseMeasureCategories(selection, "trace", "--measure")
    check selection == {mcTrace, mcTiming, mcCacheEvidence}

  test "all selects every category":
    check parseMeasureCategories({}, "all", "--measure") ==
      {mcTrace, mcCacheEvidence, mcTiming}
    # ``all`` reached through an additive occurrence widens to everything.
    check parseMeasureCategories({mcTrace}, "all", "--measure") ==
      {mcTrace, mcCacheEvidence, mcTiming}

  test "none CLEARS the set rather than omitting from it":
    check parseMeasureCategories({mcTrace, mcTiming}, "none", "--measure") == {}
    check parseMeasureCategories(DefaultMeasureSet, "none", "--measure") == {}
    # The exact-set idiom: reset, then name what you want.
    check parseMeasureCategories(DefaultMeasureSet, "none,timing",
      "--measure") == {mcTiming}
    # Order matters within one occurrence, and that is the point of the rule:
    # a trailing ``none`` clears everything before it.
    check parseMeasureCategories({}, "timing,none", "--measure") == {}

  test "an unknown category is rejected with the vocabulary in the message":
    var raised = false
    try:
      discard parseMeasureCategories({}, "bogus", "--measure")
    except ValueError as err:
      raised = true
      check err.msg.contains("--measure=bogus")
      check err.msg.contains("trace")
      check err.msg.contains("cache-evidence")
      check err.msg.contains("timing")
      check err.msg.contains("all")
      check err.msg.contains("none")
    check raised

  test "an empty value and an empty entry are both rejected":
    expect ValueError:
      discard parseMeasureCategories({}, "", "--measure")
    expect ValueError:
      discard parseMeasureCategories({}, "trace,,timing", "--measure")

  test "the retired flag vocabularies are NOT accepted as categories":
    # ``--report=full`` / ``--stats=text`` are retired names. Their values must
    # not survive as category spellings, or a stale script would be silently
    # accepted while measuring something different from what it asked for.
    for stale in ["full", "text", "stats", "1", "true", "on", "off", "0"]:
      expect ValueError:
        discard parseMeasureCategories({}, stale, "--measure")

  test "measureSetText round-trips through the parser":
    for selection in [{mcTrace}, {mcTrace, mcTiming},
                      {mcTrace, mcCacheEvidence, mcTiming}, MeasureSet({})]:
      let text = measureSetText(selection)
      check parseMeasureCategories({}, text, "--measure") == selection

suite "measurement axes: PRESENT (--show)":

  test "the presenters render only the category they are given":
    var runResult: BuildRunResult
    runResult.results.add(ActionResult(id: "alpha", status: asSucceeded))
    let trace = renderBuildTrace(runResult)
    # An empty trace says so rather than rendering a misleading blank.
    check trace.contains("scheduler trace")
    let evidence = renderBuildCacheEvidence(runResult)
    check evidence.contains("cache evidence")
    check evidence.contains("alpha")
    check evidence.contains("declaredInputs=0")
    # The evidence presenter must not invent trace lines, or vice versa.
    check not evidence.contains("scheduler trace")

suite "measurement axes: PERSIST (--write-report and the failure report)":

  test "the failure report enumerates failures, never successes":
    let scratch = createTempDir("repro-measure-failure-", "")
    defer: removeDir(scratch)
    let path = scratch / "build-failure-report.json"

    var runResult: BuildRunResult
    runResult.results.add(ActionResult(id: "compile-ok",
      status: asSucceeded, exitCode: 0, launched: true))
    runResult.results.add(ActionResult(id: "compile-cached",
      status: asCacheHit, cacheDecision: cdHit))
    runResult.results.add(ActionResult(id: "compile-broken",
      status: asFailed, exitCode: 2, launched: true,
      cacheDecision: cdMiss, reason: "input-changed",
      stderr: "src/broken.nim(3, 5) Error: undeclared identifier"))
    runResult.results.add(ActionResult(id: "link",
      status: asBlocked, blockedBy: "compile-broken",
      reason: "dependency failed"))

    let actions = @[
      BuildAction(id: "compile-broken",
        argv: @["nim", "c", "src/broken.nim"],
        cwd: "/work", inputs: @["src/broken.nim"],
        outputs: @["build/broken"], cacheable: true),
      BuildAction(id: "compile-ok", argv: @["nim", "c", "src/ok.nim"])]

    writeBuildFailureReport(path, runResult, actions,
      "/work#default", "/work", "/work/.repro/build/x", 1)

    check fileExists(path)
    let node = parseJson(readFile(path))
    check node["schemaId"].getStr == BuildFailureReportSchemaId
    check node["exitCode"].getInt == 1
    check node["target"].getStr == "/work#default"

    # Counts describe the shape of the run without listing it.
    check node["counts"]["total"].getInt == 4
    check node["counts"]["failed"].getInt == 1
    check node["counts"]["blocked"].getInt == 1
    check node["counts"]["cacheHit"].getInt == 1
    check node["counts"]["succeeded"].getInt == 2

    # Exactly the failure, with what it was and what it said.
    check node["failedActions"].len == 1
    let failed = node["failedActions"][0]
    check failed["id"].getStr == "compile-broken"
    check failed["exitCode"].getInt == 2
    check failed["stderr"].getStr.contains("undeclared identifier")
    check failed["reason"].getStr == "input-changed"
    check failed["cacheDecision"].getStr == $cdMiss
    # The action's identity and the cache state that led the scheduler here.
    check failed["argv"].len == 3
    check failed["inputs"][0].getStr == "src/broken.nim"
    check failed["outputs"][0].getStr == "build/broken"
    check failed.hasKey("weakFingerprint")

    # Blocked actions are listed separately so a reader never mistakes one
    # for a broken one.
    check node["blockedActions"].len == 1
    check node["blockedActions"][0]["id"].getStr == "link"
    check node["blockedActions"][0]["blockedBy"].getStr == "compile-broken"

    # The successes are NOT in the document. This is the whole reason the
    # failure report is a separate shape.
    let body = readFile(path)
    check not body.contains("compile-ok")
    check not body.contains("compile-cached")

  test "reportDestination is opt-in and honours --no-write-report":
    let root = "/ws"
    check reportDestination(ReportSpec(), root, "sync").len == 0
    check reportDestination(ReportSpec(requested: true), root, "sync") ==
      root / ".repro" / "build" / "reports" / "sync-report.json"
    check reportDestination(ReportSpec(requested: true,
      path: "/tmp/exact.json"), root, "sync") == "/tmp/exact.json"
    # ``--no-write-report`` wins over ``--write-report``: an explicit refusal
    # to touch the tree is the stronger statement.
    check reportDestination(ReportSpec(requested: true, suppressed: true),
      root, "sync").len == 0

  test "the failure destination appears on failure only":
    let root = "/ws"
    let spec = ReportSpec()
    # Success: nothing, even though no flag said not to.
    check failureReportDestination(spec, root, "sync", 0).len == 0
    # Failure: written without being asked.
    check failureReportDestination(spec, root, "sync", 1) ==
      root / ".repro" / "build" / "reports" / "sync-failure-report.json"
    check failureReportDestination(spec, root, "sync", 2).len > 0
    # Suppression defeats it on every outcome — the hermetic/CI escape hatch.
    check failureReportDestination(ReportSpec(suppressed: true), root,
      "sync", 1).len == 0

  test "a staged workspace report is flushed only when the command failed":
    let scratch = createTempDir("repro-measure-staged-", "")
    defer: removeDir(scratch)
    let dest = scratch / ".repro" / "build" / "reports" /
      "sync-failure-report.json"

    # (1) staged, then a SUCCESSFUL exit: nothing on disk.
    stageFailureReport(ReportSpec(), scratch, "sync", %*{"repos": []})
    flushStagedFailureReport(0)
    check not fileExists(dest)

    # (2) staged, then a FAILED exit: the envelope appears unasked.
    stageFailureReport(ReportSpec(), scratch, "sync",
      %*{"repos": [{"path": "lib-a", "outcome": "refused"}]})
    flushStagedFailureReport(2)
    check fileExists(dest)
    let node = parseJson(readFile(dest))
    check node["schemaId"].getStr == WorkspaceFailureReportSchemaId
    check node["verb"].getStr == "sync"
    check node["exitCode"].getInt == 2
    check node["report"]["repos"][0]["outcome"].getStr == "refused"

    # (3) the flush consumes the staging slot, so a later exit code cannot
    # resurrect a stale document.
    removeFile(dest)
    flushStagedFailureReport(2)
    check not fileExists(dest)

    # (4) --no-write-report suppresses it even on failure.
    stageFailureReport(ReportSpec(suppressed: true), scratch, "sync",
      %*{"repos": []})
    flushStagedFailureReport(2)
    check not fileExists(dest)

## The production benchmark gate's refusal must carry the cache decision and
## the evidence behind it, for the measured build AND the warm-up before it.
##
## THE DEFECT THIS PINS. A warm no-op build that came back `asSucceeded`
## stopped the gate with
##
##   noop-0 status=asSucceeded exit=0 stderr=
##
## and nothing else. The engine result it was built from also carried the
## cache decision, the miss reason, the withheld-publish reason and the
## monitoring evidence, and none of them reached the message. "This action
## had no record", "its record was withheld for monitor loss" and "its
## record was withheld for unblessed entropy" were therefore the same line,
## and the job that failed could not be attributed without re-running it.
##
## The refusal is the evidence of a failed run, so these cases grade the
## rendered TEXT: an accepted status, a renamed field or a missing warm-up
## line is what a reader of the CI log would lose.
##
## WHAT THIS DOES NOT CHANGE. The accepted statuses stay the caller's: an
## `asSucceeded` warm no-op is still refused, and nothing here reaches the
## engine's cache-publication decision.

import std/[strutils, unittest]

import repro_build_engine

import "../../benchmarks/lib/m23_gate_refusal"

const
  WithheldForLoss = "reasons=monitor-loss; this edge will re-run on every " &
    "build until the cause is removed"
  LossDiagnostic = "monitor loss: detached-descendant quiescence cannot " &
    "be established run=7"

proc withheldWarmup(): ActionResult =
  ## What the warm-up's first build looks like when its publication was
  ## withheld: it ran, exited 0, and left no record behind.
  result = ActionResult(id: "noop-0", status: asSucceeded, exitCode: 0,
    launched: true, cacheDecision: cdMiss, reason: "exit=0",
    cacheMissReason: "no cache record for weak fingerprint",
    cachePublishSkipReason: WithheldForLoss)
  result.evidence.declaredOutputs = @["noop/0.txt"]
  result.evidence.diagnostics = @[LossDiagnostic]

proc rerunAfterWithheld(): ActionResult =
  ## The measured build: the lookup finds nothing, so the action runs again
  ## and its publication is withheld again for the same cause.
  withheldWarmup()

suite "M23 gate refusal attribution":
  test "a refused warm no-op names its cache decision and evidence":
    let measured = BuildRunResult(results: @[rerunAfterWithheld()])
    let warmup = BuildRunResult(results: @[withheldWarmup()])
    let text = gateRefusal("noop", measured, {asUpToDate, asCacheHit},
      warmup)
    checkpoint(text)
    # The parts the old line already had stay.
    check "noop-0" in text
    check "status=asSucceeded" in text
    check "exit=0" in text
    # The parts it dropped.
    check "cache=cdMiss" in text
    check "cache-miss=no cache record for weak fingerprint" in text
    check "cache-publish-skipped=" & WithheldForLoss in text
    check LossDiagnostic in text
    check "declared-outputs:1" in text
    # The accepted set is named, so the reader knows what was required.
    check "asUpToDate" in text
    check "asCacheHit" in text

  test "the warm-up's result for the refused action is reported too":
    ## The measured build of a withheld edge says only that no record was
    ## found. WHY none was written is decided by the warm-up, so the gate
    ## keeps the warm-up's result and reports it beside the measured one.
    let measured = BuildRunResult(results: @[rerunAfterWithheld()])
    var warm = withheldWarmup()
    warm.cachePublishSkipReason = "reasons=unblessed-entropy; warm-up only"
    let text = gateRefusal("noop", measured, {asUpToDate, asCacheHit},
      BuildRunResult(results: @[warm]))
    checkpoint(text)
    check "warm-up:" in text
    check "reasons=unblessed-entropy; warm-up only" in text

  test "a refusal with no warm-up says so rather than staying silent":
    let measured = BuildRunResult(results: @[rerunAfterWithheld()])
    let text = gateRefusal("noop", measured, {asUpToDate, asCacheHit})
    check "warm-up: none" in text

  test "empty fields are rendered as absent, not omitted":
    ## A field that is missing from the line and a field that was empty are
    ## different facts; only the second says the engine had nothing to add.
    let measured = BuildRunResult(results: @[ActionResult(id: "noop-1",
      status: asFailed, exitCode: 3, launched: true, cacheDecision: cdMiss)])
    let text = gateRefusal("noop", measured, {asUpToDate, asCacheHit})
    checkpoint(text)
    check "cache-publish-skipped=<none>" in text
    check "cache-miss=<none>" in text
    check "diagnostics=<none>" in text

  test "accepted statuses are not refused, and asSucceeded is not admitted":
    let warm = BuildRunResult(results: @[ActionResult(id: "noop-0",
      status: asUpToDate, cacheDecision: cdHit, reason: "outputs-present")])
    check gateRefusal("noop", warm, {asUpToDate, asCacheHit}).len == 0
    expect ValueError:
      requireAll("noop", BuildRunResult(results: @[rerunAfterWithheld()]),
        {asUpToDate, asCacheHit})
    requireAll("noop", warm, {asUpToDate, asCacheHit})

  test "the raised error carries the same attribution":
    let measured = BuildRunResult(results: @[rerunAfterWithheld()])
    var raised = ""
    try:
      requireAll("noop", measured, {asUpToDate, asCacheHit},
        BuildRunResult(results: @[withheldWarmup()]))
    except ValueError as error:
      raised = error.msg
    check raised == gateRefusal("noop", measured, {asUpToDate, asCacheHit},
      BuildRunResult(results: @[withheldWarmup()]))
    check "cache=cdMiss" in raised

  test "every refused action is counted, and the detail is bounded":
    var measured = BuildRunResult()
    for i in 0 ..< 20:
      var item = rerunAfterWithheld()
      item.id = "noop-" & $i
      measured.results.add(item)
    let text = gateRefusal("noop", measured, {asUpToDate, asCacheHit})
    checkpoint(text)
    check "20 of 20" in text
    check "noop-19" in text
    check text.count("cache-publish-skipped=") == RefusalDetailLimit

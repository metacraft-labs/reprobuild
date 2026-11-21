## TC-8e — a test command the action cache answered may be attested only when
## its cache record covers the inputs (test-certificates Standard §6.2.1,
## decision D16): the action's key must cover every input the monitor
## observed it reading.
##
## The end-to-end TC-8e test's fixture has only monitored edges, so it never
## reaches the ``keyCoversObservedReads`` refusal (recorded as uncovered in
## Test-Certificates.milestones.org TC-8e). This test pins both halves of it
## where they are decided:
##
##   1. ``actionKeyCoversObservedReads`` — the classification
##      ``executedActionRecords`` copies into every record — is true ONLY for
##      a cacheable process action under a MONITORED policy that elides no
##      input prefix. A recognised-format or post-build-converter policy
##      (keyed on what was reported, not what was read), an ignored input
##      prefix, a non-cacheable action and a builtin action are all false.
##   2. ``reusedResultRefusal`` refuses a key-matched, locally observed,
##      successful record exactly when that classification is false, and
##      names the reason; with it true the same record is attestable.
##
## Falsifiability: return ``true`` from ``actionKeyCoversObservedReads`` (or
## drop the ``keyCoversObservedReads`` check from ``reusedResultRefusal``)
## and the refusal rows fail.
##
## Pure functions over constructed values: no build runs, because what is
## under test is the decision, and the engine run that feeds it is covered by
## t_repro_test_workspace_mode_issues_a_content_bound_certificate.

import std/[strutils, unittest]

import repro_cli_support
import repro_build_engine
import repro_core/dependency_gathering

proc processAction(kind: DependencyGatheringKind; cacheable = true;
                   ignored: seq[string] = @[]): BuildAction =
  BuildAction(governingLockIdentity: lockIdentityOutsideSolvedGraph(),
    id: "unit", argv: @["./unit"], cwd: "/work", cacheable: cacheable,
    kind: bakProcess,
    dependencyPolicy: DependencyGatheringPolicy(kind: kind,
      ignoredInputPrefixes: ignored))

proc reusedRecord(keyCovers: bool): ExecutedActionRecord =
  ## A record that satisfies every OTHER condition of §6.2.1: a key-matched
  ## hit, from an execution this host observed, of an action that succeeded.
  ExecutedActionRecord(id: "unit", kind: bakProcess, argv: @["./unit"],
    status: asCacheHit, launched: false, cacheDecision: cdHit,
    cacheRecordObservedHere: true, keyCoversObservedReads: keyCovers)

suite "TC-8e — reused results the cache key does not cover":

  test "t_reused_result_refused_when_key_does_not_cover_reads":
    # ---- 1. the classification ------------------------------------------
    for kind in [dgAutomaticMonitor, dgRecognizedFormatValidatedByMonitor,
                 dgPostBuildConverterValidatedByMonitor]:
      checkpoint("monitored: " & $kind)
      check actionKeyCoversObservedReads(processAction(kind))
    for kind in [dgRecognizedFormat, dgPostBuildConverter]:
      checkpoint("not monitored: " & $kind)
      check not actionKeyCoversObservedReads(processAction(kind))
    check not actionKeyCoversObservedReads(
      processAction(dgAutomaticMonitor, ignored = @["/opt/vendor"]))
    check not actionKeyCoversObservedReads(
      processAction(dgAutomaticMonitor, cacheable = false))
    var builtin = processAction(dgAutomaticMonitor)
    builtin.kind = bakWriteText
    check not actionKeyCoversObservedReads(builtin)

    # ---- 2. the refusal --------------------------------------------------
    let refused = reusedResultRefusal(reusedRecord(keyCovers = false))
    checkpoint("refusal: " & refused)
    check refused.len > 0
    check "does not cover every input the monitor observed" in refused
    check reusedResultRefusal(reusedRecord(keyCovers = true)) == ""
    # The classification and the refusal agree end to end: a record built
    # the way ``executedActionRecords`` builds it, from a recognised-format
    # action, is refused.
    var fromAction = reusedRecord(keyCovers = actionKeyCoversObservedReads(
      processAction(dgRecognizedFormat)))
    check reusedResultRefusal(fromAction).len > 0
    fromAction.keyCoversObservedReads = actionKeyCoversObservedReads(
      processAction(dgAutomaticMonitor))
    check reusedResultRefusal(fromAction) == ""

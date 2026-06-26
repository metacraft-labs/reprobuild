## Windows-System-Resources Phase G — ``runInfraApply`` action-edge
## dispatch tests.
##
## Pins the contract between ``runInfraApply`` and the injected
## ``buildActionDispatcher`` closure:
##
##   1. Empty ``buildActions`` ⇒ dispatcher is NOT invoked (no
##      spurious call when there's nothing to do).
##   2. Non-empty ``buildActions`` + nil dispatcher ⇒ ``EProtocol``
##      raised BEFORE any live-state mutation (fail-closed; no
##      silent skip).
##   3. Non-empty ``buildActions`` + non-nil dispatcher ⇒ each
##      ``ProfileBuildAction`` reaches the closure in declaration
##      order; the live-state half of the apply runs AFTER.
##   4. Per-edge outcomes fold into ``ApplyResult`` tallies:
##      ``asSucceeded``-like outcomes → ``appliedCount``;
##      cache-hits → ``noOpCount``; failures → ``errorCount`` AND a
##      diagnostic line.
##   5. The action-edge dispatch order matches the profile's
##      declaration order (Phase-G first cut runs all action edges
##      before the live-state half).
##
## We use a MOCK dispatcher that records the input + returns
## scripted outcomes. The real ``mkBuildActionDispatcher`` (which
## actually wraps ``runBuild`` + the broker hook) is exercised by
## the integration test under ``libs/repro_profile_compile/tests/``.

import std/[os, strutils, tables, tempfiles, unittest]

import repro_elevation
import repro_infra
import repro_profile

# ---------------------------------------------------------------------------
# Recording mock dispatcher.
# ---------------------------------------------------------------------------

type
  DispatchCapture = ref object
    invocationCount: int
    receivedActions: seq[seq[ProfileBuildAction]]
    scriptedOutcomes: seq[BuildActionApplyOutcome]
    raiseOnDispatch: bool

proc newCapture(): DispatchCapture =
  DispatchCapture(invocationCount: 0,
    receivedActions: @[],
    scriptedOutcomes: @[],
    raiseOnDispatch: false)

proc mkRecordingDispatcher(capture: DispatchCapture): BuildActionDispatcher =
  result = proc(actions: seq[ProfileBuildAction]):
      seq[BuildActionApplyOutcome] {.gcsafe.} =
    {.cast(gcsafe).}:
      inc capture.invocationCount
      capture.receivedActions.add(actions)
      if capture.raiseOnDispatch:
        raise newException(EProtocol, "mock dispatcher refused dispatch")
      # If the scripted outcomes were provided, return them; otherwise
      # auto-generate a success-per-edge default so the live-state half
      # gets to run.
      if capture.scriptedOutcomes.len > 0:
        return capture.scriptedOutcomes
      for a in actions:
        result.add(BuildActionApplyOutcome(
          id: a.id,
          address: a.id,
          ok: true,
          requiresElevation: a.requiresElevation,
          cacheHit: false,
          diagnostic: ""))

# ---------------------------------------------------------------------------
# Test profile fixture — a minimal system-scope profile with NO
# live-state resources (so the apply summary tallies reflect ONLY
# the action-edge half) and a deterministic plan.
# ---------------------------------------------------------------------------

const EmptyProfileText = ""

proc mkApplyOptions(stateDir: string): ApplyOptions =
  result.stateDir = stateDir
  result.hostIdentity = "phaseG-test-host"
  result.reproExe = "/usr/bin/false"  # never spawned in these tests
  result.planId = ""
  result.elevationMode = emNoElevate  # never broker-dispatch
  result.noPreview = true

# ---------------------------------------------------------------------------
# Tests.
# ---------------------------------------------------------------------------

suite "Windows-System-Resources Phase G — runInfraApply action-edge dispatch":

  test "empty buildActions: dispatcher is NOT invoked":
    let tmp = createTempDir("phaseG-apply-empty-", "")
    defer:
      try: removeDir(tmp)
      except CatchableError: discard
    let capture = newCapture()
    var opts = mkApplyOptions(tmp)
    opts.buildActions = @[]
    opts.buildActionDispatcher = mkRecordingDispatcher(capture)
    let res = runInfraApply(EmptyProfileText, opts)
    check capture.invocationCount == 0
    check res.buildActionResults.len == 0
    check res.appliedCount == 0
    check res.errorCount == 0

  test "non-empty buildActions + nil dispatcher raises EProtocol":
    let tmp = createTempDir("phaseG-apply-nil-disp-", "")
    defer:
      try: removeDir(tmp)
      except CatchableError: discard
    var opts = mkApplyOptions(tmp)
    opts.buildActions = @[ProfileBuildAction(
      id: "extractRunner",
      argv: @["/bin/true"],
      requiresElevation: true,
      cacheable: true)]
    opts.buildActionDispatcher = nil
    var raised = false
    try:
      discard runInfraApply(EmptyProfileText, opts)
    except EProtocol as e:
      raised = true
      check "buildActionDispatcher" in e.msg
      check "no silent fallback" in e.msg
    check raised

  test "dispatcher receives buildActions in declaration order":
    let tmp = createTempDir("phaseG-apply-order-", "")
    defer:
      try: removeDir(tmp)
      except CatchableError: discard
    let capture = newCapture()
    var opts = mkApplyOptions(tmp)
    opts.buildActions = @[
      ProfileBuildAction(id: "edgeA", argv: @["/bin/true"],
        cacheable: true),
      ProfileBuildAction(id: "edgeB", argv: @["/bin/true"],
        cacheable: true),
      ProfileBuildAction(id: "edgeC", argv: @["/bin/true"],
        cacheable: true)]
    opts.buildActionDispatcher = mkRecordingDispatcher(capture)
    let res = runInfraApply(EmptyProfileText, opts)
    check capture.invocationCount == 1
    check capture.receivedActions.len == 1
    let received = capture.receivedActions[0]
    check received.len == 3
    check received[0].id == "edgeA"
    check received[1].id == "edgeB"
    check received[2].id == "edgeC"
    # Auto-generated default outcomes: all succeeded.
    check res.appliedCount == 3
    check res.errorCount == 0
    check res.buildActionResults.len == 3

  test "per-edge cache-hit outcome lands in noOpCount":
    let tmp = createTempDir("phaseG-apply-cachehit-", "")
    defer:
      try: removeDir(tmp)
      except CatchableError: discard
    let capture = newCapture()
    capture.scriptedOutcomes = @[
      BuildActionApplyOutcome(id: "edgeA", address: "edgeA",
        ok: true, cacheHit: true,
        requiresElevation: true),
      BuildActionApplyOutcome(id: "edgeB", address: "edgeB",
        ok: true, cacheHit: false,
        requiresElevation: false)]
    var opts = mkApplyOptions(tmp)
    opts.buildActions = @[
      ProfileBuildAction(id: "edgeA", argv: @["/bin/true"],
        cacheable: true),
      ProfileBuildAction(id: "edgeB", argv: @["/bin/true"],
        cacheable: true)]
    opts.buildActionDispatcher = mkRecordingDispatcher(capture)
    let res = runInfraApply(EmptyProfileText, opts)
    check res.appliedCount == 1     # edgeB
    check res.noOpCount == 1        # edgeA (cache hit)
    check res.errorCount == 0
    check res.buildActionResults.len == 2
    check res.buildActionResults[0].cacheHit
    check not res.buildActionResults[1].cacheHit

  test "per-edge failure outcome lands in errorCount AND diagnostics":
    let tmp = createTempDir("phaseG-apply-failure-", "")
    defer:
      try: removeDir(tmp)
      except CatchableError: discard
    let capture = newCapture()
    capture.scriptedOutcomes = @[
      BuildActionApplyOutcome(id: "edgeFails", address: "edgeFails",
        ok: false, requiresElevation: true,
        diagnostic: "broker dispatch failed: spawn refused"),
      BuildActionApplyOutcome(id: "edgePasses", address: "edgePasses",
        ok: true, requiresElevation: false)]
    var opts = mkApplyOptions(tmp)
    opts.buildActions = @[
      ProfileBuildAction(id: "edgeFails", argv: @["/bin/false"],
        requiresElevation: true, cacheable: true),
      ProfileBuildAction(id: "edgePasses", argv: @["/bin/true"],
        cacheable: true)]
    opts.buildActionDispatcher = mkRecordingDispatcher(capture)
    let res = runInfraApply(EmptyProfileText, opts)
    check res.errorCount == 1
    check res.appliedCount == 1
    var sawDiag = false
    for d in res.diagnostics:
      if "edgeFails" in d and "broker dispatch failed" in d:
        sawDiag = true
    check sawDiag
    # The failure does NOT abort the apply — the live-state half
    # still got a chance to run (empty profile here, but the
    # generation-commit ran below).
    check res.generationId.len > 0

  test "dispatcher exception propagates and aborts the apply":
    let tmp = createTempDir("phaseG-apply-throw-", "")
    defer:
      try: removeDir(tmp)
      except CatchableError: discard
    let capture = newCapture()
    capture.raiseOnDispatch = true
    var opts = mkApplyOptions(tmp)
    opts.buildActions = @[
      ProfileBuildAction(id: "edge", argv: @["/bin/true"],
        cacheable: true)]
    opts.buildActionDispatcher = mkRecordingDispatcher(capture)
    var raised = false
    try:
      discard runInfraApply(EmptyProfileText, opts)
    except EProtocol as e:
      raised = true
      check "mock dispatcher refused" in e.msg
    check raised
    check capture.invocationCount == 1

  test "action-edge dispatch runs BEFORE the live-state plan computation":
    # The dispatcher must fire BEFORE producePlan reads the live
    # state; otherwise a profile that extracts a binary then
    # registers a service against it would observe "service binary
    # missing" at plan time.
    #
    # We can't easily reach into producePlan to assert ordering, but
    # we CAN assert via a dispatcher that records the apply state
    # at invocation time — when the dispatcher fires, the apply
    # must NOT have committed the generation pointer yet (which
    # happens at the very end of runInfraApply).
    let tmp = createTempDir("phaseG-apply-ordering-", "")
    defer:
      try: removeDir(tmp)
      except CatchableError: discard
    let capture = newCapture()
    var generationDirExistsAtDispatch = false
    let recordingDisp: BuildActionDispatcher = proc(actions: seq[ProfileBuildAction]):
        seq[BuildActionApplyOutcome] {.gcsafe.} =
      {.cast(gcsafe).}:
        # The apply has NOT yet derived a generationId at this point
        # — it happens in step 4 of runInfraApply. We probe by
        # listing the state dir; the per-generation subdir should be
        # absent.
        for kind, _ in walkDir(tmp):
          if kind == pcDir:
            generationDirExistsAtDispatch = true
        inc capture.invocationCount
        for a in actions:
          result.add(BuildActionApplyOutcome(
            id: a.id, address: a.id, ok: true))
    var opts = mkApplyOptions(tmp)
    opts.buildActions = @[
      ProfileBuildAction(id: "edge", argv: @["/bin/true"],
        cacheable: true)]
    opts.buildActionDispatcher = recordingDisp
    let res = runInfraApply(EmptyProfileText, opts)
    check capture.invocationCount == 1
    # At dispatch time, the only directories under stateDir come
    # from acquireApplyLock (locks/) at most; the generation dir
    # gets created in step 4 AFTER everything else.
    check not generationDirExistsAtDispatch
    # The live-state half ran AFTER (no resources -> empty
    # operations, but the generation pointer is committed).
    check res.generationId.len > 0

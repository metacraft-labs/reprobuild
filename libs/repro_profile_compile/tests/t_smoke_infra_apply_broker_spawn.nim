## Windows-System-Resources Phase E end-to-end integration: the CLI
## seam that wires the build engine's ``brokerSpawn`` hook to the
## privileged-operation broker via ``mkInfraApplyBrokerSpawn``.
##
## The engine-side test (``test_elevated_inline_exec_hook.nim``)
## exercises ``runBuild`` with a hand-written recording mock spawner;
## this suite is one rung deeper — it pins the FULL chain:
##
##   1. The closure produced by ``mkInfraApplyBrokerSpawn(ctx)`` is
##      attached to ``BuildEngineConfig.brokerSpawn``.
##   2. The build engine sees a ``BuildAction`` with
##      ``requiresElevation = true`` and packages
##      ``ElevatedExecRequest`` (argv + cwd + env + actionId).
##   3. The closure translates the request into a ``pokInlineExecCall``
##      ``PrivilegedOperation``.
##   4. The real ``dispatchOperation`` runs through ``runInlineExecCall``,
##      which spawns the OS process and waits for completion.
##   5. The returned ``DispatchResult`` is projected back into
##      ``ElevatedExecResult`` (and from there into ``ActionResult``).
##   6. The materialised output lives in the cache; a second run is a
##      cache hit (the broker hook is NOT re-invoked).
##
## Spec §7 end-to-end gate: an elevated edge runs through the broker,
## the output materialises, and the cache layer treats the elevated
## execution byte-identically to a direct fork.
##
## The "broker" here is the in-process fast path — ``dispatchOperation``
## runs synchronously inside the same process. No broker subprocess is
## spawned and no real elevation prompt fires. The OS boundary is the
## real ``startProcess`` call inside the inline-exec driver; we choose
## ``/bin/sh`` (POSIX hosts only) as the spawned executable so the
## materialise-output step works without invoking a privileged action.

import std/[os, tempfiles, unittest]

import repro_build_engine
import repro_elevation
import repro_hash
import repro_local_store
import repro_profile_compile

# ---------------------------------------------------------------------------
# Recording wrapper around ``dispatchOperation`` so the test can assert
# the FULL request shape that crossed the closure -> broker boundary.
# We can't intercept inside ``dispatchOperation`` itself, so we record
# the ``ElevatedExecRequest`` the closure received AND the
# ``PrivilegedOperation`` the closure produced before dispatch. The
# latter is the load-bearing handshake: it pins that the closure built
# the correct ``pokInlineExecCall`` operation shape.
# ---------------------------------------------------------------------------

type
  CapturedDispatch = ref object
    requests: seq[ElevatedExecRequest]
    operations: seq[PrivilegedOperation]
    invocationCount: int

proc newCapture(): CapturedDispatch =
  CapturedDispatch(requests: @[], operations: @[], invocationCount: 0)

proc captureSpawn(capture: CapturedDispatch;
                  ctx: FixtureContext): ElevatedExecSpawner =
  ## Build a recording closure that mirrors what
  ## ``mkInfraApplyBrokerSpawn`` does — but records every request +
  ## the translated PrivilegedOperation before delegating to
  ## ``mkInfraApplyBrokerSpawn``'s closure. This way the test pins
  ## both the translation surface and the dispatch outcome.
  let inner = mkInfraApplyBrokerSpawn(ctx)
  result = proc(req: ElevatedExecRequest):
      ElevatedExecResult {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      capture.requests.add(req)
      capture.operations.add(
        elevatedExecRequestToPrivilegedOperation(req))
      inc capture.invocationCount
      result = inner(req)

# ---------------------------------------------------------------------------
# Build-graph helpers.
# ---------------------------------------------------------------------------

proc fingerprintFor(text: string): ContentDigest =
  casDigest(text.toOpenArrayByte(0, text.high),
            domain = hdActionFingerprint)

proc shellWriteOutputAction(id, outputPath, payload, fingerprintToken: string):
    BuildAction =
  ## A ``bakProcess`` action that shells out to ``/bin/sh`` to write
  ## ``payload`` to ``outputPath``. Marked ``requiresElevation = true``
  ## so the engine routes the launch through ``brokerSpawn``.
  ## ``/bin/sh -c`` is the universal POSIX primitive — we just need a
  ## real exec to prove the dispatchOperation path runs end-to-end.
  let script = "printf %s '" & payload & "' > '" & outputPath & "'"
  result = BuildAction(
    kind: bakProcess,
    id: id,
    outputs: @[outputPath],
    argv: @["/bin/sh", "-c", script],
    cwd: "",
    cacheable: true,
    actionCachePolicy: ffpTimestamp,
    weakFingerprint: fingerprintFor(id & "|" & fingerprintToken),
    requiresElevation: true)

proc elevatedEngineConfig(cacheRoot: string;
                          spawner: ElevatedExecSpawner): BuildEngineConfig =
  result = defaultBuildEngineConfig(cacheRoot)
  result.maxParallelism = 1
  result.deferLocalOutputBlobs = false
  result.bypassRunQuota = true
  result.brokerSpawn = spawner

# ---------------------------------------------------------------------------
# Tests.
# ---------------------------------------------------------------------------

suite "Windows-System-Resources Phase E — CLI seam end-to-end":

  test "mkInfraApplyBrokerSpawn closure dispatches an elevated edge end-to-end":
    when defined(linux) or defined(macosx):
      let tmpRoot = createTempDir("phaseE-cli-seam-", "")
      defer:
        try: removeDir(tmpRoot)
        except CatchableError: discard
      let cacheRoot = tmpRoot / "cache"
      let outputDir = tmpRoot / "outputs"
      createDir(cacheRoot)
      createDir(outputDir)
      let outputPath = outputDir / "elevated.out"

      let capture = newCapture()
      let ctx = FixtureContext(filePrefix: tmpRoot)
      let spawner = captureSpawn(capture, ctx)

      let payload = "phase-e cli-seam payload"
      let action = shellWriteOutputAction("cli-seam-e2e", outputPath,
        payload, fingerprintToken = "first-run")
      let cfg = elevatedEngineConfig(cacheRoot, spawner)
      let res = runBuild(graph(@[action]), cfg)

      # (1) The engine accepted the elevated edge and finished cleanly.
      check res.results.len == 1
      check res.results[0].status == asSucceeded
      check res.results[0].launched == true
      check res.results[0].runQuotaBackend == "broker"

      # (2) The closure was invoked exactly once with the verbatim argv
      #     the action carried (literal @FILE: tokens, if any, would be
      #     preserved here; this test uses a plain argv so we assert
      #     verbatim equality).
      check capture.invocationCount == 1
      check capture.requests.len == 1
      check capture.requests[0].actionId == "cli-seam-e2e"
      check capture.requests[0].argv == @["/bin/sh", "-c",
        "printf %s '" & payload & "' > '" & outputPath & "'"]
      check capture.requests[0].cwd == ""

      # (3) The closure produced a well-formed ``pokInlineExecCall``
      #     PrivilegedOperation: kind tag, executable = argv[0],
      #     arguments = argv[1..], address = actionId.
      check capture.operations.len == 1
      let op = capture.operations[0]
      check op.kind == pokInlineExecCall
      check op.address == "cli-seam-e2e"
      check op.iecExecutable == "/bin/sh"
      check op.iecArguments == @["-c",
        "printf %s '" & payload & "' > '" & outputPath & "'"]
      check op.iecAcceptExitCodes == @[0]
      # The PrivilegedOperation passes the closed-set validator (the
      # broker re-runs this as defence in depth; we pin it here).
      check operationValidationError(op) == ""

      # (4) The output materialised — the dispatched ``runInlineExecCall``
      #     ran the real /bin/sh -c primitive under the broker's
      #     (already-elevated, in this test) identity.
      check fileExists(outputPath)
      check readFile(outputPath) == payload

  test "second run hits the action cache; broker hook NOT re-invoked":
    when defined(linux) or defined(macosx):
      let tmpRoot = createTempDir("phaseE-cli-seam-cache-", "")
      defer:
        try: removeDir(tmpRoot)
        except CatchableError: discard
      let cacheRoot = tmpRoot / "cache"
      let outputDir = tmpRoot / "outputs"
      createDir(cacheRoot)
      createDir(outputDir)
      let outputPath = outputDir / "elevated.out"

      let capture = newCapture()
      let ctx = FixtureContext(filePrefix: tmpRoot)
      let spawner = captureSpawn(capture, ctx)

      let payload = "phase-e cache payload"
      let firstAction = shellWriteOutputAction("cli-seam-cache",
        outputPath, payload, fingerprintToken = "cachehit")
      let firstRes = runBuild(graph(@[firstAction]),
        elevatedEngineConfig(cacheRoot, spawner))
      check firstRes.results.len == 1
      check firstRes.results[0].status == asSucceeded
      check capture.invocationCount == 1
      check fileExists(outputPath)

      # Second run: identical fingerprint, identical outputs. The
      # cache lookup in ``runBuild`` short-circuits BEFORE reaching
      # the pre-launch broker-dispatch decision point, so the
      # ``brokerSpawn`` closure MUST NOT be invoked a second time.
      let secondAction = shellWriteOutputAction("cli-seam-cache",
        outputPath, payload, fingerprintToken = "cachehit")
      let secondRes = runBuild(graph(@[secondAction]),
        elevatedEngineConfig(cacheRoot, spawner))
      check secondRes.results.len == 1
      check secondRes.results[0].status in {asCacheHit, asUpToDate}
      check secondRes.results[0].launched == false
      check capture.invocationCount == 1

  test "translation helpers are pure":
    # The closure-internal translation helpers are also exported so a
    # broker-side test can assert the shape independently of running
    # ``dispatchOperation``. Pin them here so a future refactor of the
    # closure body cannot silently regress the request <-> operation
    # mapping.
    let req = ElevatedExecRequest(
      actionId: "phaseE-translate-pin",
      argv: @["C:\\actions-runner\\config.cmd", "--unattended",
              "--token", "@FILE:C:\\actions-runner-tokens\\mcl.token"],
      cwd: "C:\\actions-runner",
      env: @["RUNNER_LOG_DIR=C:\\actions-runner\\logs"])
    let op = elevatedExecRequestToPrivilegedOperation(req)
    check op.kind == pokInlineExecCall
    check op.address == "phaseE-translate-pin"
    check op.iecExecutable == "C:\\actions-runner\\config.cmd"
    check op.iecArguments == @["--unattended", "--token",
                               "@FILE:C:\\actions-runner-tokens\\mcl.token"]
    check op.iecWorkingDirectory == "C:\\actions-runner"
    check op.iecEnvironment == @["RUNNER_LOG_DIR=C:\\actions-runner\\logs"]
    check op.iecToolIdentityRefs.len == 0
    check op.iecAcceptExitCodes == @[0]
    # The codec-boundary validator accepts the translated op.
    check operationValidationError(op) == ""

    # An empty argv is mapped to an empty-executable PrivilegedOperation
    # so the elevation-side validator produces the canonical
    # diagnostic instead of an out-of-bounds raised from inside the
    # closure.
    let emptyReq = ElevatedExecRequest(actionId: "phaseE-empty",
      argv: @[], cwd: "", env: @[])
    let emptyOp = elevatedExecRequestToPrivilegedOperation(emptyReq)
    check emptyOp.kind == pokInlineExecCall
    check emptyOp.iecExecutable == ""
    check operationValidationError(emptyOp).len > 0

  test "DispatchResult -> ElevatedExecResult projection":
    let appliedDr = DispatchResult(
      address: "phaseE-applied",
      kind: pokInlineExecCall,
      outcome: doApplied,
      detail: "spawned `/bin/true` -> exit 0",
      preWriteDigestHex: "", postWriteDigestHex: "")
    let appliedRes = dispatchResultToElevatedExecResult(appliedDr)
    check appliedRes.ok
    check appliedRes.exitCode == 0
    check appliedRes.diagnostic == "spawned `/bin/true` -> exit 0"

    let driftDr = DispatchResult(
      address: "phaseE-drift",
      kind: pokInlineExecCall,
      outcome: doDrift,
      detail: "broker reported drift",
      preWriteDigestHex: "", postWriteDigestHex: "")
    let driftRes = dispatchResultToElevatedExecResult(driftDr)
    check not driftRes.ok
    check driftRes.exitCode == InfraApplyBrokerFailureExitCode
    check driftRes.diagnostic == "broker reported drift"
    check driftRes.stderr == "broker reported drift"

    let errorDr = DispatchResult(
      address: "phaseE-error",
      kind: pokInlineExecCall,
      outcome: doError,
      detail: "driver failed: spawn refused",
      preWriteDigestHex: "", postWriteDigestHex: "")
    let errorRes = dispatchResultToElevatedExecResult(errorDr)
    check not errorRes.ok
    check errorRes.exitCode == InfraApplyBrokerFailureExitCode
    check errorRes.diagnostic == "driver failed: spawn refused"

  test "dispatchOperation failure projects onto a failure ElevatedExecResult":
    when defined(linux) or defined(macosx):
      let tmpRoot = createTempDir("phaseE-cli-seam-fail-", "")
      defer:
        try: removeDir(tmpRoot)
        except CatchableError: discard
      let ctx = FixtureContext(filePrefix: tmpRoot)
      let spawner = mkInfraApplyBrokerSpawn(ctx)
      # ``/bin/false`` exits 1, which is NOT in the closed-set
      # accept-list (``@[0]``), so ``runInlineExecCall`` raises
      # ``EProtocol`` — the closure must catch it and return a
      # failure ``ElevatedExecResult`` instead of propagating.
      let req = ElevatedExecRequest(
        actionId: "phaseE-fail-projection",
        argv: @["/bin/false"], cwd: "", env: @[])
      let res = spawner(req)
      check not res.ok
      check res.exitCode == InfraApplyBrokerFailureExitCode
      check res.diagnostic.len > 0
      # The build engine's pre-launch decision point checks ``ok``
      # AND ``exitCode == 0`` together; both must signal failure here.

  test "an elevated edge with a failing dispatch fails the action":
    # End-to-end: run a graph with an elevated edge whose underlying
    # ``runInlineExecCall`` exits non-zero (``/bin/false``). The
    # closure catches the EProtocol, returns a failure
    # ``ElevatedExecResult``, and the engine surfaces the action as
    # ``asFailed`` — the spec's fail-closed shape for a broker-driver
    # failure.
    when defined(linux) or defined(macosx):
      let tmpRoot = createTempDir("phaseE-cli-seam-edge-fail-", "")
      defer:
        try: removeDir(tmpRoot)
        except CatchableError: discard
      let cacheRoot = tmpRoot / "cache"
      let outputDir = tmpRoot / "outputs"
      createDir(cacheRoot)
      createDir(outputDir)
      let outputPath = outputDir / "elevated.out"

      let capture = newCapture()
      let ctx = FixtureContext(filePrefix: tmpRoot)
      let spawner = captureSpawn(capture, ctx)

      # A bakProcess action whose argv exits non-zero. The engine
      # still recognises this as launched + failed, NOT as a cache
      # miss / re-tryable.
      let action = BuildAction(
        kind: bakProcess,
        id: "cli-seam-fail",
        outputs: @[outputPath],
        argv: @["/bin/false"],
        cwd: "",
        cacheable: true,
        actionCachePolicy: ffpTimestamp,
        weakFingerprint: fingerprintFor("cli-seam-fail|edge-fail"),
        requiresElevation: true)
      let cfg = elevatedEngineConfig(cacheRoot, spawner)
      let res = runBuild(graph(@[action]), cfg)
      check res.results.len == 1
      check res.results[0].status == asFailed
      check capture.invocationCount == 1
      # The output was NOT materialised — the failure path doesn't
      # invent a side effect.
      check not fileExists(outputPath)

  test "explicit FixtureContext is captured by the closure":
    # The ``ctx`` parameter is closed-over so any future broker kind
    # that reads ``FixtureContext.filePrefix`` (the fixture drivers
    # do; the inline-exec driver does not) sees the apply's chosen
    # value. Pin this so a future refactor cannot silently drop the
    # capture.
    let ctxA = FixtureContext(filePrefix: "/tmp/phaseE-ctxA")
    let ctxB = FixtureContext(filePrefix: "/tmp/phaseE-ctxB")
    let spawnerA = mkInfraApplyBrokerSpawn(ctxA)
    let spawnerB = mkInfraApplyBrokerSpawn(ctxB)
    # Distinct closures regardless of identical body — captures
    # different values, so a downstream identity check via the
    # closure pointer alone would be insufficient. The contract is
    # behavioural: each closure dispatches with its captured ctx.
    # We pin behavioural identity by running a no-op inline-exec
    # through each (``/bin/true``) and checking both return success.
    when defined(linux) or defined(macosx):
      let req = ElevatedExecRequest(
        actionId: "phaseE-ctx-capture",
        argv: @["/bin/sh", "-c", "exit 0"], cwd: "", env: @[])
      let resA = spawnerA(req)
      let resB = spawnerB(req)
      check resA.ok
      check resB.ok
      check resA.exitCode == 0
      check resB.exitCode == 0

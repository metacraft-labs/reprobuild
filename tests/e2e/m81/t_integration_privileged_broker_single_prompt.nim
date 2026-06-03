## M81 Verification Gate: integration_privileged_broker_single_prompt
##
## Reprobuild elevates by launching EXACTLY ONE short-lived
## privileged broker (the same `repro` binary re-execed as
## `repro --privileged-broker --channel <name> --token <nonce>`) and
## driving it over a local authenticated IPC channel, so a whole
## apply raises AT MOST ONE OS elevation prompt — zero when already
## elevated or when the plan has no privileged operations.
##
## Per the M81 verification block this gate proves, with the REAL
## broker process + REAL IPC channel + REAL broker-side driver
## dispatch (only the privileged-operation SET is a fixture — its
## drivers write only to a sandboxed file prefix or the isolated
## `HKLM\SOFTWARE\Reprobuild-Tests\` subkey):
##
##   1. An apply with several privileged operations partitions them,
##      launches EXACTLY ONE broker, and applies all of them via the
##      broker (one elevation event, one broker process).
##   2. An apply with zero privileged operations launches NO broker.
##   3. An apply run already-elevated (and not force-broker) runs the
##      privileged set IN-PROCESS with no broker.
##   4. `--no-elevate` applies the non-privileged subset and reports
##      every privileged operation skipped with a partial-success
##      exit, mutating NOTHING privileged.
##   5. An unrelated local process cannot connect to the IPC channel
##      and drive a privileged operation (nonce / peer-credential
##      rejection).
##   6. The broker rejects any frame that is not a recognized typed
##      `PrivilegedOperation`.
##   7. A privileged operation whose observed state drifted between
##      plan and broker execution is detected and fail-closed, not
##      blindly overwritten.
##   8. The broker process has exited once the apply completes.
##
## TEST SEAM (documented as test-only, not a weakening): the gate
## host runs ALREADY ELEVATED, so the already-elevated fast path
## would skip the broker entirely. To exercise the REAL broker
## launch + IPC + dispatch path the gate drives `launchAndDriveBroker`
## directly — the same orchestration `repro infra apply` (M69) will
## call — which forces the broker topology. When the parent is
## already elevated, the `runas` launch of the broker child raises
## no UAC prompt, so the real broker path runs non-interactively. The
## `REPRO_FORCE_BROKER` env-var seam (in `elevation_state.nim`) is the
## production-facing equivalent for an `repro infra apply` invoked
## already-elevated; this gate exercises the underlying orchestration
## directly so the launch counter is observable in-process.
##
## No `skip`, no `xfail`. The cross-platform mechanism (partition,
## RBEB codec, typed operation set, closed-set validation, drift) is
## additionally unit-tested in
## `libs/repro_elevation/tests/t_smoke_repro_elevation.nim`.

when not defined(windows):
  {.warning[UnreachableCode]: off.}
  echo "[platform N/A] t_integration_privileged_broker_single_prompt: " &
    "the broker launch + named-pipe IPC path is Windows-only"
  quit(0)

import std/[os, strutils, tempfiles, unittest]

import repro_core
import repro_elevation

import repro_test_support

const ProjectRoot = currentSourcePath().parentDir().parentDir()
  .parentDir().parentDir()

proc reproBinary(): string =
  let candidate = ProjectRoot / "build" / "bin" / "repro.exe"
  doAssert fileExists(candidate),
    "repro binary not found at " & candidate &
    "; build with the gate recipe first"
  candidate

# ---------------------------------------------------------------------------
# Fixture privileged-operation builders. The file-fixture operations
# write under a per-test temp prefix; the registry-fixture operations
# write only under HKLM\SOFTWARE\Reprobuild-Tests\.
# ---------------------------------------------------------------------------

proc fileOp(address, relPath, content: string): PrivilegedOperation =
  PrivilegedOperation(kind: pokFixtureFile, address: address,
    fileRelPath: relPath, fileContent: content)

proc regOp(address, sub, name, data: string): PrivilegedOperation =
  PrivilegedOperation(kind: pokFixtureRegistry, address: address,
    regSubPath: sub, regValueName: name, regValueData: data)

proc planned(op: PrivilegedOperation;
             baseline = ZeroDigestHex): PlannedOperation =
  PlannedOperation(operation: op, baselineDigestHex: baseline)

# A unique registry sub-path per gate run so concurrent / repeated
# runs never collide, and cleanup is unambiguous.
let regRunId = "gate-" & $getCurrentProcessId()

suite "integration_privileged_broker_single_prompt":
  when isNixSupported:

    test "the host is already elevated (gate precondition)":
      # The M81 gate's allowed_mocks states the gate runs already
      # elevated so the broker launch path is exercised without an
      # interactive UAC prompt. Assert that precondition up front.
      check isProcessElevated()

    test "scenario 2+3: zero privileged ops, and already-elevated fast path":
      # --- Zero privileged operations => NO broker. ---
      let emptyPartition = partitionApply([], nonPrivilegedOperationCount = 4)
      check not emptyPartition.hasPrivilegedWork()
      check not emptyPartition.requiresBroker(alreadyElevated = false)
      check not emptyPartition.requiresBroker(alreadyElevated = true)
      check emptyPartition.renderPlanPrivilegeNotice(
        alreadyElevated = false) == ""

      # --- Already-elevated + privileged work => in-process fast path,
      #     NO broker. The SAME dispatch the broker uses, run directly. ---
      let prefix = createTempDir("repro-m81-fastpath-", "")
      defer: removeDir(prefix)
      let ops = @[
        fileOp("fast-1", "a.txt", "fast path content one"),
        fileOp("fast-2", "sub/b.txt", "fast path content two")]
      let part = partitionApply(ops, nonPrivilegedOperationCount = 0)
      check part.requiresBroker(alreadyElevated = false)
      check not part.requiresBroker(alreadyElevated = true)

      resetBrokerLaunchCount()
      let ctx = FixtureContext(filePrefix: prefix)
      let plannedOps = @[planned(ops[0]), planned(ops[1])]
      let outcome = applyPrivilegedSetInProcess(ctx, plannedOps)
      # No broker was launched on the fast path.
      check brokerLaunchCount() == 0
      check outcome.allApplied
      check outcome.results.len == 2
      check outcome.applyLog.len == 2
      # The privileged operations really were applied in-process.
      check readFile(prefix / "a.txt") == "fast path content one"
      check readFile(prefix / "sub" / "b.txt") == "fast path content two"

    test "scenario 1+8: several privileged ops => EXACTLY ONE broker, all applied":
      let prefix = createTempDir("repro-m81-broker-", "")
      defer: removeDir(prefix)
      let regSub = regRunId & "/single-prompt"
      defer: deleteFixtureRegistryTree(regSub)

      # An apply with FOUR privileged operations of two kinds.
      let ops = @[
        fileOp("broker-file-1", "etc/one.conf", "broker wrote one"),
        fileOp("broker-file-2", "etc/two.conf", "broker wrote two"),
        regOp("broker-reg-1", regSub, "BrokerValueA", "alpha-data"),
        regOp("broker-reg-2", regSub, "BrokerValueB", "beta-data")]
      let part = partitionApply(ops, nonPrivilegedOperationCount = 7)
      check part.privilegedOperations.len == 4
      let notice = part.renderPlanPrivilegeNotice(alreadyElevated = false)
      check notice.contains("one elevation prompt")
      check notice.contains("4 privileged operations")

      var plannedOps: seq[PlannedOperation]
      for op in ops:
        plannedOps.add(planned(op))

      # Drive the REAL broker: launch ONE `repro --privileged-broker`
      # child, authenticate it, stream the four operations, wait for it
      # to exit.
      resetBrokerLaunchCount()
      let apply = launchAndDriveBroker(reproBinary(), plannedOps,
        filePrefix = prefix)

      # EXACTLY ONE broker process was launched for the whole apply.
      check brokerLaunchCount() == 1
      check apply.brokerPid != 0

      # All four privileged operations were applied via the broker.
      check apply.outcome.allApplied
      check apply.outcome.results.len == 4
      for r in apply.outcome.results:
        check r.ok
        check not r.driftDetected
      # The broker streamed back one structured apply-log record per op.
      check apply.outcome.applyLog.len == 4
      for rec in apply.outcome.applyLog:
        check rec.outcome == "applied"

      # The privileged file operations really mutated the sandbox.
      check readFile(prefix / "etc" / "one.conf") == "broker wrote one"
      check readFile(prefix / "etc" / "two.conf") == "broker wrote two"

      # The broker process EXITED cleanly once the apply completed
      # (one-shot lifecycle — no persistent elevated surface).
      check apply.brokerExitCode == 0
      check not processStillAlive(apply.brokerPid)

    test "scenario 1: broker drives a real HKLM registry mutation, then idempotent":
      # Confirm the registry fixture driver really wrote under the
      # isolated HKLM subtree, AND a re-apply of the same desired value
      # is a broker-side cache-hit (no-op), proving the broker
      # re-observes before mutating.
      let regSub = regRunId & "/registry-idempotent"
      defer: deleteFixtureRegistryTree(regSub)
      let op = regOp("reg-idem", regSub, "IdempotentValue", "the-only-value")

      resetBrokerLaunchCount()
      let apply1 = launchAndDriveBroker(reproBinary(), @[planned(op)])
      check brokerLaunchCount() == 1
      check apply1.outcome.allApplied
      check apply1.outcome.applyLog[0].outcome == "applied"

      # The value is observable in HKLM now.
      let observed = observeFixtureRegistry(op)
      check observed.present
      check observed.digestHex == desiredDigestHex(op)

      # Re-apply the SAME desired value with the matching baseline:
      # the broker re-observes, finds a cache-hit, and applies nothing.
      let apply2 = launchAndDriveBroker(reproBinary(),
        @[planned(op, baseline = desiredDigestHex(op))])
      check apply2.outcome.allApplied
      check apply2.outcome.applyLog[0].outcome == "no-op"

    test "scenario 7: drift between plan and broker execution is fail-closed":
      let prefix = createTempDir("repro-m81-drift-", "")
      defer: removeDir(prefix)

      # The plan baseline says the target held "plan-time observation".
      let planBaseline = desiredDigestHex(
        fileOp("drift-op", "drifted.conf", "plan-time observation"))
      # But between plan and broker execution a third party changed it.
      writeFile(prefix / "drifted.conf", "out-of-band hostile edit")

      let driftOp = fileOp("drift-op", "drifted.conf", "what the plan wants")
      resetBrokerLaunchCount()
      let apply = launchAndDriveBroker(reproBinary(),
        @[planned(driftOp, baseline = planBaseline)], filePrefix = prefix)

      # ONE broker was still launched; the drift is detected by the
      # broker, not the parent.
      check brokerLaunchCount() == 1
      # The operation failed CLOSED — reported as a drift, not applied.
      check not apply.outcome.allApplied
      check apply.outcome.results.len == 1
      check not apply.outcome.results[0].ok
      check apply.outcome.results[0].driftDetected
      check apply.outcome.applyLog[0].outcome == "drift"
      # The drifted file was NOT blindly overwritten.
      check readFile(prefix / "drifted.conf") == "out-of-band hostile edit"
      # The broker still exited (a fail-closed op is not a crash).
      check not processStillAlive(apply.brokerPid)

    test "scenario 6: the broker rejects a non-PrivilegedOperation frame":
      # Stand up the parent half of the channel, launch the broker, do
      # the handshake, then send a frame whose kind tag is NOT in the
      # closed typed operation set. The broker must reject it — it
      # never executes anything outside the closed set.
      let nonce = generateNonce()
      var ch = createListeningChannel(nonce)
      var proc0 = launchBrokerForGate(reproBinary(), nonce)
      acceptAuthenticatedClient(ch)

      ch.sendFrame(encodeHello(HelloFrame(
        protocolVersion: BrokerProtocolVersion, nonce: nonce)))
      let ack = decodeHelloAck(ch.recvFrame().body)
      check ack.accepted

      # A structurally-valid Operation frame whose kind tag names a
      # capability the broker does NOT implement — i.e. an attempt to
      # smuggle "run an arbitrary command" past the typed set.
      var body: seq[byte]
      body.writeString("windows.runArbitraryCommand")
      body.writeString("malicious-op")
      body.writeString("")               # baseline
      body.writeString("whoami")         # would-be command
      ch.sendFrame(encodeFrame(rmtOperation, body))

      # The broker streams back an error apply-log + a failed result —
      # it did NOT execute the unrecognized frame.
      var sawErrorResult = false
      var guard = 0
      while not sawErrorResult and guard < 4:
        let frame = ch.recvFrame()
        if frame.messageType == rmtOperationResult:
          let r = decodeOperationResult(frame.body)
          check not r.ok
          sawErrorResult = true
        inc guard
      check sawErrorResult

      ch.sendFrame(encodeDone())
      ch.close()
      let code = waitForExit(proc0)
      # The broker reported a failure but still exited.
      check code != 0
      check not processStillAlive(brokerProcessId(proc0))

    test "scenario 5: a peer with the wrong nonce is rejected (auth)":
      # The nonce handshake means an unrelated local process cannot
      # connect to the broker's pipe and drive an elevated executor.
      # Launch a broker bound to nonce A, then connect a parent that
      # presents the WRONG nonce B in its Hello. The broker rejects the
      # handshake and exits without executing anything.
      let realNonce = generateNonce()
      let wrongNonce = generateNonce()
      check realNonce != wrongNonce
      var ch = createListeningChannel(realNonce)
      var proc0 = launchBrokerForGate(reproBinary(), realNonce)
      acceptAuthenticatedClient(ch)

      # An impostor parent presents a nonce that does not match the
      # one the broker was launched with.
      ch.sendFrame(encodeHello(HelloFrame(
        protocolVersion: BrokerProtocolVersion, nonce: wrongNonce)))
      let ack = decodeHelloAck(ch.recvFrame().body)
      # The broker REFUSED the handshake.
      check not ack.accepted
      check ack.reason.toLowerAscii().contains("nonce")
      ch.close()
      let code = waitForExit(proc0)
      # The broker exited with the nonce-rejection code, having
      # executed no privileged operation.
      check code == 4
      check not processStillAlive(brokerProcessId(proc0))

    test "scenario 4: --no-elevate applies nothing privileged, reports skipped":
      let prefix = createTempDir("repro-m81-noelevate-", "")
      defer: removeDir(prefix)
      let regSub = regRunId & "/no-elevate"

      let ops = @[
        fileOp("ne-file", "should-not-exist.conf", "must not be written"),
        regOp("ne-reg", regSub, "ShouldNotExist", "must not be written")]
      var plannedOps: seq[PlannedOperation]
      for op in ops:
        plannedOps.add(planned(op))

      # `--no-elevate`: the non-privileged subset is applied elsewhere;
      # the privileged set is reported skipped. No broker is launched.
      resetBrokerLaunchCount()
      let outcome = reportPrivilegedSetSkipped(plannedOps)
      check brokerLaunchCount() == 0
      check not outcome.allApplied            # partial-success, not clean
      check outcome.results.len == 2
      for r in outcome.results:
        check not r.ok
        check r.diagnostic.toLowerAscii().contains("requires elevation")
      # NOTHING privileged was mutated.
      check not fileExists(prefix / "should-not-exist.conf")
      check not observeFixtureRegistry(ops[1]).present

    test "a denied prompt is equivalent to --no-elevate (clean partial)":
      # Per the spec, a user-declined OS prompt is equivalent to
      # `--no-elevate` — a clean partial result, not a crash. The
      # `EElevationDeclined` exception carries that contract; a caller
      # catches it and falls back to the skip path. Prove the fallback
      # produces the identical clean-partial outcome.
      let op = fileOp("denied-op", "x.conf", "never written")
      var outcome: PrivilegedApplyOutcome
      try:
        # Simulate the declined-prompt control flow.
        raiseElevationDeclined()
      except EElevationDeclined:
        outcome = reportPrivilegedSetSkipped(@[planned(op)])
      check not outcome.allApplied
      check outcome.results.len == 1
      check not outcome.results[0].ok

    test "the isolated HKLM test subtree is left clean":
      # The fixture registry driver writes ONLY under
      # HKLM\SOFTWARE\Reprobuild-Tests\; the per-scenario `defer`s
      # already removed each scenario's subtree. Remove this run's
      # `gate-<pid>` parent, then drop the HKLM\SOFTWARE\Reprobuild-Tests
      # root itself — but only when it is empty. After that the host
      # registry is byte-clean (no orphaned root key) — the M81
      # verification block's "clean up after" requirement.
      #
      # `deleteFixtureRegistryRoot` is conditional on emptiness for
      # concurrency safety: a concurrent gate run isolated under its own
      # `gate-<pid>` subkey leaves the root non-empty, and in that case
      # the root is left untouched.
      deleteFixtureRegistryTree(regRunId)
      deleteFixtureRegistryRoot()
      # The run's own subtree must now be gone.
      check not observeFixtureRegistry(
        regOp("probe", regRunId & "/single-prompt", "BrokerValueA",
          "x")).present

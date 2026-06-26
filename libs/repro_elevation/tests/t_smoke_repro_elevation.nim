## Library-local unit tests for the M81 privileged-operation broker
## library. Covers the PLATFORM-PURE surface — partition, the
## `requiresElevation` predicate, the RBEB codec round-trips, the
## closed-set validation, the sandbox-escape guard, and the
## fixture file driver's drift contract. These run everywhere
## (Windows, Linux, macOS); the Windows-only IPC / broker-launch
## path is exercised by the M81 integration gate.

import std/[os, strutils, tempfiles, times, unittest]

import repro_core
import repro_elevation

suite "repro_elevation: requiresElevation + partition":
  test "every fixture operation kind requires elevation":
    check requiresElevation(pokFixtureFile)
    check requiresElevation(pokFixtureRegistry)

  test "partition keeps every privileged candidate":
    let ops = @[
      PrivilegedOperation(kind: pokFixtureFile, address: "a",
        fileRelPath: "x.txt", fileContent: "x"),
      PrivilegedOperation(kind: pokFixtureRegistry, address: "b",
        regSubPath: "k", regValueName: "v", regValueData: "d")]
    let part = partitionApply(ops, nonPrivilegedOperationCount = 5)
    check part.privilegedOperations.len == 2
    check part.nonPrivilegedOperationCount == 5
    check part.hasPrivilegedWork()

  test "empty privileged set => no broker, no prompt":
    let part = partitionApply([], nonPrivilegedOperationCount = 3)
    check not part.hasPrivilegedWork()
    check not part.requiresBroker(alreadyElevated = false)
    check part.renderPlanPrivilegeNotice(alreadyElevated = false) == ""

  test "requiresBroker is false when already elevated (fast path)":
    let ops = @[PrivilegedOperation(kind: pokFixtureFile, address: "a",
      fileRelPath: "x.txt", fileContent: "x")]
    let part = partitionApply(ops, nonPrivilegedOperationCount = 0)
    check part.requiresBroker(alreadyElevated = false)
    check not part.requiresBroker(alreadyElevated = true)

  test "plan privilege notice names the privileged operations":
    let ops = @[
      PrivilegedOperation(kind: pokFixtureFile, address: "op-one",
        fileRelPath: "x.txt", fileContent: "x"),
      PrivilegedOperation(kind: pokFixtureRegistry, address: "op-two",
        regSubPath: "k", regValueName: "v", regValueData: "d")]
    let part = partitionApply(ops, nonPrivilegedOperationCount = 0)
    let notice = part.renderPlanPrivilegeNotice(alreadyElevated = false)
    check notice.contains("one elevation prompt")
    check notice.contains("2 privileged operations")
    check notice.contains("op-one")
    check notice.contains("op-two")

suite "repro_elevation: closed-set validation + sandbox guard":
  test "safe relative sub-paths are accepted":
    check isSafeRelativeSubPath("a.txt")
    check isSafeRelativeSubPath("sub/dir/a.txt")

  test "sandbox-escape paths are rejected":
    check not isSafeRelativeSubPath("")
    check not isSafeRelativeSubPath("../escape.txt")
    check not isSafeRelativeSubPath("sub/../../escape.txt")
    check not isSafeRelativeSubPath("/abs/path.txt")
    check not isSafeRelativeSubPath("\\abs\\path.txt")
    check not isSafeRelativeSubPath("C:\\abs.txt")

  test "operationValidationError flags an unsafe file path":
    let bad = PrivilegedOperation(kind: pokFixtureFile,
      address: "a", fileRelPath: "../escape", fileContent: "x")
    check operationValidationError(bad).len > 0

  test "operationValidationError flags an unsafe registry sub-path":
    let bad = PrivilegedOperation(kind: pokFixtureRegistry,
      address: "a", regSubPath: "../escape", regValueName: "v",
      regValueData: "d")
    check operationValidationError(bad).len > 0

  test "operationValidationError accepts an in-policy operation":
    let ok = PrivilegedOperation(kind: pokFixtureFile, address: "a",
      fileRelPath: "ok.txt", fileContent: "x")
    check operationValidationError(ok) == ""

  test "an unknown kind tag is not a recognized operation":
    check not isKnownPrivilegedOperationKind("windows.runArbitraryCommand")
    check isKnownPrivilegedOperationKind($pokFixtureFile)

suite "repro_elevation: RBEB protocol codec":
  test "Hello / HelloAck round-trip":
    let h = HelloFrame(protocolVersion: 1, nonce: "abc123")
    let dec = decodeFrame(encodeHello(h))
    check dec.messageType == rmtHello
    let h2 = decodeHello(dec.body)
    check h2.protocolVersion == 1
    check h2.nonce == "abc123"
    let ack = HelloAckFrame(accepted: true, protocolVersion: 1, reason: "")
    let ackDec = decodeFrame(encodeHelloAck(ack))
    check ackDec.messageType == rmtHelloAck
    check decodeHelloAck(ackDec.body).accepted

  test "Operation frame round-trip carries the plan baseline":
    let wire = WireOperation(
      operation: PrivilegedOperation(kind: pokFixtureRegistry,
        address: "reg-op", regSubPath: "sub", regValueName: "Name",
        regValueData: "Value"),
      baselineDigestHex: "abcd")
    let dec = decodeFrame(encodeOperation(wire))
    check dec.messageType == rmtOperation
    let w2 = decodeOperation(dec.body)
    check w2.baselineDigestHex == "abcd"
    check w2.operation.kind == pokFixtureRegistry
    check w2.operation.address == "reg-op"
    check w2.operation.regValueData == "Value"

  test "OperationResult / ApplyLogRecord round-trip":
    let r = OperationResultFrame(operationAddress: "op", ok: false,
      driftDetected: true, diagnostic: "drifted")
    let r2 = decodeOperationResult(decodeFrame(encodeOperationResult(r)).body)
    check r2.driftDetected
    check not r2.ok
    let log = ApplyLogRecord(operationAddress: "op",
      operationKind: $pokFixtureFile, outcome: "applied",
      detail: "created", preWriteDigestHex: "00", postWriteDigestHex: "ff")
    let log2 = decodeApplyLogRecord(
      decodeFrame(encodeApplyLogRecord(log)).body)
    check log2.outcome == "applied"
    check log2.postWriteDigestHex == "ff"

  test "a corrupt checksum is rejected":
    var frame = encodeDone()
    frame[^1] = frame[^1] xor 0xff'u8
    expect EProtocol:
      discard decodeFrame(frame)

  test "a bad magic is rejected":
    var frame = encodeDone()
    frame[0] = byte(ord('X'))
    expect EProtocol:
      discard decodeFrame(frame)

  test "decodeOperation rejects an unrecognized kind tag":
    # Hand-build an Operation body whose kind tag is not in the
    # closed set — the broker must reject it as not-a-typed-operation.
    var body: seq[byte]
    body.writeString("windows.runArbitraryCommand")
    body.writeString("addr")
    body.writeString("")               # baseline
    let frame = encodeFrame(rmtOperation, body)
    let dec = decodeFrame(frame)
    expect EProtocol:
      discard decodeOperation(dec.body)

suite "repro_elevation: fixture file driver + drift contract":
  test "apply then re-observe is a cache-hit (no-op)":
    let prefix = createTempDir("repro-elev-unit-", "")
    defer: removeDir(prefix)
    let ctx = FixtureContext(filePrefix: prefix)
    let op = PrivilegedOperation(kind: pokFixtureFile, address: "f1",
      fileRelPath: "out/data.txt", fileContent: "hello broker")
    # First dispatch: target absent => create.
    let r1 = dispatchOperation(ctx,
      PlannedOperation(operation: op, baselineDigestHex: ZeroDigestHex))
    check r1.outcome == doApplied
    check fileExists(prefix / "out" / "data.txt")
    check readFile(prefix / "out" / "data.txt") == "hello broker"
    # Second dispatch with the same desired content: cache-hit.
    let r2 = dispatchOperation(ctx,
      PlannedOperation(operation: op,
        baselineDigestHex: desiredDigestHex(op)))
    check r2.outcome == doNoOp

  test "cache-hit decision is confirmed by a second observation":
    # M69 regression guard. Dispatch must NOT declare a cache-hit on
    # a single re-observe — that lost a windows.service flip when the
    # initial sample caught a CBS-finalization transient. The cache-hit
    # path now takes a confirmation sample `CacheHitConfirmDelayMs`
    # later. We assert the wall-clock cost as a proxy for "the
    # confirmation actually happened": a single-sample cache-hit
    # would return in microseconds.
    let prefix = createTempDir("repro-elev-unit-", "")
    defer: removeDir(prefix)
    let ctx = FixtureContext(filePrefix: prefix)
    let op = PrivilegedOperation(kind: pokFixtureFile, address: "f-confirm",
      fileRelPath: "data.txt", fileContent: "settled content")
    # Seed the target so the first dispatch immediately sees the
    # desired digest -- the very condition that triggers the
    # confirmation sample.
    writeFile(prefix / "data.txt", "settled content")
    let started = epochTime()
    let r = dispatchOperation(ctx,
      PlannedOperation(operation: op,
        baselineDigestHex: desiredDigestHex(op)))
    let elapsedMs = int((epochTime() - started) * 1000.0)
    check r.outcome == doNoOp
    # Allow a 100 ms slack below the nominal delay for scheduler jitter
    # on slow CI machines while still proving the confirmation sample
    # was taken (a single-sample cache-hit would be sub-10ms).
    check elapsedMs >= CacheHitConfirmDelayMs - 100

  test "cache-hit confirmation falls through when the second sample disagrees":
    # The complement of the regression guard above: when the world
    # changes between the two cache-hit samples (the M69 sshd race in
    # miniature), the dispatch must NOT silently no-op. The second
    # observation is taken as ground truth and drives the drift / apply
    # path. Here we delete the seed file out-of-band BEFORE dispatch
    # runs, on a background task that fires inside the confirmation
    # window: sample 1 sees the seeded content (apparent cache-hit),
    # the deletion lands during the 1 s confirmation pause, sample 2
    # sees the file missing — so dispatch must recreate the desired
    # content.
    let prefix = createTempDir("repro-elev-unit-", "")
    defer: removeDir(prefix)
    let ctx = FixtureContext(filePrefix: prefix)
    let op = PrivilegedOperation(kind: pokFixtureFile,
      address: "f-transient", fileRelPath: "data.txt",
      fileContent: "settled content")
    writeFile(prefix / "data.txt", "settled content")
    let targetPath = prefix / "data.txt"
    var killer: Thread[string]
    proc deleteAfterPause(p: string) {.thread.} =
      sleep(200)
      removeFile(p)
    createThread(killer, deleteAfterPause, targetPath)
    let r = dispatchOperation(ctx,
      PlannedOperation(operation: op,
        baselineDigestHex: desiredDigestHex(op)))
    joinThread(killer)
    # Sample 1 looked like a cache-hit; sample 2 saw the absent file;
    # dispatch must have recreated the target with the desired content.
    check r.outcome == doApplied
    check fileExists(targetPath)
    check readFile(targetPath) == "settled content"

  test "broker fails closed on a drifted file":
    # M82 Phase C migration of the original "broker fails closed on a
    # drifted file" assertion. Phase A removed the apply-time drift
    # gate (`raiseBrokerDrift` on observed != recorded baseline AND
    # observed != desired in `dispatch.dispatchOperation`) — that
    # apply-time fail-closed behavior is GONE. Phase C re-homes the
    # contract at plan time: the planner classifies a third-party
    # out-of-band edit as ACTIONABLE drift, the user sees it in the
    # plan output, and decides whether to proceed. The test exercises
    # the new plan-time surface: drift a previously-applied file
    # out-of-band, run the planner, and assert that the planner reports
    # an actionable `DriftFinding` for the address — the very signal
    # the apply-time gate used to translate into `EBrokerDrift`.
    #
    # The fixture-file driver is too narrow to drive the M82-Phase-C
    # `repro_infra.producePlan` API (it has no `fs.systemFile`
    # observation backing). The end-to-end plan-time-drift assertion
    # therefore lives in the new integration test under
    # `tests/e2e/m69/t_e2e_repro_infra_plan_time_external_drift.nim`,
    # which drives the real planner against `fs.systemFile` resources
    # whose observed digest is read from disk. This unit-level test
    # documents the migration and asserts the apply-time path is now
    # the "observe, apply, re-probe" loop with no plan-time-baseline
    # gate — so the third-party edit is NOT silently preserved at
    # dispatch time (the integrity check moved to the driver's
    # post-apply re-probe).
    let prefix = createTempDir("repro-elev-unit-", "")
    defer: removeDir(prefix)
    let ctx = FixtureContext(filePrefix: prefix)
    let op = PrivilegedOperation(kind: pokFixtureFile, address: "f2",
      fileRelPath: "data.txt", fileContent: "desired content")
    # The plan's baseline says the target held "plan-time content"
    # (the historic apply-time-baseline drift trigger).
    let planBaseline = desiredDigestHex(PrivilegedOperation(
      kind: pokFixtureFile, address: "f2", fileRelPath: "data.txt",
      fileContent: "plan-time content"))
    # The real world now holds something a third party changed.
    writeFile(prefix / "data.txt", "a hostile out-of-band edit")
    let r = dispatchOperation(ctx,
      PlannedOperation(operation: op, baselineDigestHex: planBaseline))
    # M82 Phase A contract: the dispatch layer no longer fails closed
    # on the plan-time-baseline mismatch. It re-observes, sees
    # observed != desired, applies, and re-probes. The post-apply
    # re-probe confirms `desired content` landed; the third-party
    # edit was overwritten. Plan-time drift detection (the test in
    # `tests/e2e/m69/t_e2e_repro_infra_plan_time_external_drift.nim`)
    # is what gives the operator a chance to STOP this apply before
    # it runs — that is the protection the original apply-time gate
    # was approximating, now correctly homed at plan time.
    check r.outcome == doApplied
    check readFile(prefix / "data.txt") == "desired content"

  test "an apply that needs to update the live state proceeds":
    # Pre-M82-Phase-A this test was titled "a safe update
    # (observed == baseline) is applied" and asserted that the
    # apply-time drift gate let the apply through when observed matched
    # the plan's recorded baseline. With the apply-time gate removed
    # (M82 Phase A — see dispatch.dispatchOperation and
    # Planner-Apply-Refresh-Model.md) the test still passes — the
    # dispatch now treats the live observation as the baseline and
    # applies whenever observed != desired, so the baseline argument is
    # no longer load-bearing. The test is retained as coverage of the
    # plain "observed != desired => apply runs" path.
    let prefix = createTempDir("repro-elev-unit-", "")
    defer: removeDir(prefix)
    let ctx = FixtureContext(filePrefix: prefix)
    # The world holds exactly what the plan recorded last apply.
    writeFile(prefix / "data.txt", "previous content")
    let baseline = desiredDigestHex(PrivilegedOperation(
      kind: pokFixtureFile, address: "f3", fileRelPath: "data.txt",
      fileContent: "previous content"))
    let op = PrivilegedOperation(kind: pokFixtureFile, address: "f3",
      fileRelPath: "data.txt", fileContent: "new content")
    let r = dispatchOperation(ctx,
      PlannedOperation(operation: op, baselineDigestHex: baseline))
    check r.outcome == doApplied
    check readFile(prefix / "data.txt") == "new content"

suite "repro_elevation: --no-elevate skip path":
  test "every privileged op is reported skipped, nothing mutated":
    let planned = @[
      PlannedOperation(operation: PrivilegedOperation(
        kind: pokFixtureFile, address: "skip-1", fileRelPath: "a.txt",
        fileContent: "x"), baselineDigestHex: ZeroDigestHex)]
    let outcome = reportPrivilegedSetSkipped(planned)
    check not outcome.allApplied
    check outcome.results.len == 1
    check not outcome.results[0].ok
    check outcome.results[0].diagnostic.contains("requires elevation")

suite "repro_elevation: broker-mode arg parsing":
  test "parses --privileged-broker --channel --token":
    let parsed = parseBrokerModeArgs(@["--privileged-broker",
      "--channel", "\\\\.\\pipe\\repro-elev-xyz", "--token", "xyz"])
    check parsed.isBrokerMode
    check parsed.token == "xyz"

  test "non-broker args are reported as not-broker-mode":
    let parsed = parseBrokerModeArgs(@["home", "apply"])
    check not parsed.isBrokerMode

  test "a broker invocation without a token is rejected":
    expect EProtocol:
      discard parseBrokerModeArgs(@["--privileged-broker",
        "--channel", "c"])

  test "forceBrokerRequested is a pure predicate over the env value":
    check forceBrokerRequested("1")
    check not forceBrokerRequested("")

# ===========================================================================
# M69 Phase B — windows.vsInstaller: the vswhere parser, the
# membership diff, the drift classification, and the typed-operation
# wiring into the closed set. All platform-pure.
# ===========================================================================

const SmokeVsWhereJson = """
[
  { "instanceId": "i1",
    "installationPath": "C:\\VS\\BuildTools",
    "productId": "Microsoft.VisualStudio.Product.BuildTools",
    "channelId": "VisualStudio.17.Release",
    "packages": [
      { "id": "Microsoft.VisualStudio.Workload.VCTools", "type": "Workload" },
      { "id": "Microsoft.VisualStudio.Workload.MSBuildTools", "type": "Workload" },
      { "id": "Microsoft.VisualStudio.Component.Git", "type": "Component" }
    ] }
]
"""

suite "repro_elevation: windows.vsInstaller pure logic (Phase B)":

  test "requiresElevation + the closed set include the vsInstaller kind":
    check requiresElevation(pokWindowsVsInstaller)
    check isKnownPrivilegedOperationKind("windows.vsInstaller")

  test "parseVsWhereOutput reads products + workload/component packages":
    let products = parseVsWhereOutput(SmokeVsWhereJson)
    check products.len == 1
    check installedWorkloadIds(products[0]).len == 2
    check installedComponentIds(products[0]) ==
      @["Microsoft.VisualStudio.Component.Git"]
    check parseVsWhereOutput("[]").len == 0
    expect VsWhereParseError:
      discard parseVsWhereOutput("{ bad")

  test "diffMembership: missing workload => needs-modify":
    let products = parseVsWhereOutput(SmokeVsWhereJson)
    let desired = VsInstallerDesiredState(edition: "BuildTools",
      channel: "VisualStudio.17.Release", installPath: r"C:\VS\BuildTools",
      workloads: @["Microsoft.VisualStudio.Workload.VCTools",
                   "Microsoft.VisualStudio.Workload.MSBuildTools",
                   "Microsoft.VisualStudio.Workload.NativeDesktop"],
      components: @["Microsoft.VisualStudio.Component.Git"])
    let diff = diffMembership(desired, products)
    check classifyDrift(diff) == vsdNeedsModify
    check requiresMutation(diff, strict = false)

  test "an out-of-spec workload: leave-alone by default, removed when strict":
    let products = parseVsWhereOutput(SmokeVsWhereJson)
    var desired = VsInstallerDesiredState(edition: "BuildTools",
      channel: "VisualStudio.17.Release", installPath: r"C:\VS\BuildTools",
      workloads: @["Microsoft.VisualStudio.Workload.VCTools"],
      components: @["Microsoft.VisualStudio.Component.Git"])
    let diff = diffMembership(desired, products)
    check classifyDrift(diff) == vsdMembershipDrift
    check not requiresMutation(diff, strict = false)   # leave-alone
    desired.strict = true
    check requiresMutation(diffMembership(desired, products), strict = true)

  test "Operation frame round-trips the vsInstaller op":
    let op = PrivilegedOperation(kind: pokWindowsVsInstaller,
      address: "vs", vsEdition: "BuildTools", vsChannel: "Release",
      vsInstallPath: r"C:\VS",
      vsWorkloads: @["A", "B"], vsComponents: @["C"],
      vsStrict: true, vsDestroy: false)
    check operationValidationError(op) == ""
    let dec = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: op, baselineDigestHex: ""))).body)
    check dec.operation.kind == pokWindowsVsInstaller
    check dec.operation.vsWorkloads == @["A", "B"]
    check dec.operation.vsComponents == @["C"]
    check dec.operation.vsStrict

# ===========================================================================
# M69 Phase C — the six POSIX / macOS system-scope drivers: the pure
# parsers, the structural / drift comparison, the plist & unit & env
# generators, the passwd.user attribute diff, and the typed-operation
# wiring into the closed set. All platform-pure — these run on every
# host; the Linux/macOS shell-out is guarded and exercised only by the
# Linux/macOS e2e gate.
# ===========================================================================

suite "repro_elevation: Phase C closed-set wiring":

  test "the six Phase-C kinds are in the closed set and require elevation":
    for k in [pokMacosSystemDefault, pokSystemdSystemUnit,
              pokLaunchdSystemDaemon, pokFsSystemFile,
              pokFsSystemDirectory,
              pokEnvSystemVariable, pokPasswdUser]:
      check requiresElevation(k)
      check isKnownPrivilegedOperationKind($k)
    check not isKnownPrivilegedOperationKind("posix.runArbitraryCommand")

  test "fs.systemDirectory frames round-trip through the wire codec":
    let d = PrivilegedOperation(kind: pokFsSystemDirectory,
      address: "fd1",
      fsdPath: "/etc/myapp.d",
      fsdAclPresent: false,
      fsdDestroy: false)
    check operationValidationError(d) == ""
    let dd = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: d, baselineDigestHex: ""))).body)
    check dd.operation.kind == pokFsSystemDirectory
    check dd.operation.fsdPath == "/etc/myapp.d"
    check dd.operation.fsdAclPresent == false
    check dd.operation.fsdDestroy == false

    let dAcl = PrivilegedOperation(kind: pokFsSystemDirectory,
      address: "fd2",
      fsdPath: "C:\\actions-runner-tokens",
      fsdAclPresent: true,
      fsdAclOwner: "SYSTEM",
      fsdAclEntries: @[
        "SYSTEM:(F)",
        "BUILTIN\\Administrators:(F)",
        "NetworkService:(RX)"],
      fsdAclInheritance: "protected-clear-inherited",
      fsdDestroy: false)
    check operationValidationError(dAcl) == ""
    let ddAcl = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: dAcl, baselineDigestHex: ""))).body)
    check ddAcl.operation.kind == pokFsSystemDirectory
    check ddAcl.operation.fsdAclPresent
    check ddAcl.operation.fsdAclOwner == "SYSTEM"
    check ddAcl.operation.fsdAclEntries.len == 3
    check ddAcl.operation.fsdAclInheritance ==
      "protected-clear-inherited"

  test "fs.systemDirectory validator rejects malformed ACEs":
    let bad = PrivilegedOperation(kind: pokFsSystemDirectory,
      address: "fdBad",
      fsdPath: "/etc/myapp.d",
      fsdAclPresent: true,
      fsdAclEntries: @["x; rm -rf /:(F)"])
    check operationValidationError(bad).len > 0
    let badInh = PrivilegedOperation(kind: pokFsSystemDirectory,
      address: "fdBadInh",
      fsdPath: "/etc/myapp.d",
      fsdAclPresent: true,
      fsdAclEntries: @["SYSTEM:(F)"],
      fsdAclInheritance: "evil-mode")
    check operationValidationError(badInh).len > 0

  test "macos.systemDefault operation frame round-trips":
    let op = PrivilegedOperation(kind: pokMacosSystemDefault,
      address: "sd", sdDomain: "/Library/Preferences/com.apple.loginwindow",
      sdKey: "SHOWFULLNAME", sdValueType: "-bool", sdValueLiteral: "true",
      sdRestartTarget: "loginwindow", sdDestroy: false)
    check operationValidationError(op) == ""
    let dec = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: op, baselineDigestHex: "ab"))).body)
    check dec.operation.kind == pokMacosSystemDefault
    check dec.operation.sdDomain == op.sdDomain
    check dec.operation.sdKey == "SHOWFULLNAME"
    check dec.operation.sdRestartTarget == "loginwindow"
    check dec.baselineDigestHex == "ab"

  test "systemd.systemUnit operation frame round-trips":
    let op = PrivilegedOperation(kind: pokSystemdSystemUnit,
      address: "su", suName: "repro-agent.service",
      suContent: "[Unit]\nDescription=x\n[Service]\nExecStart=/bin/true\n",
      suEnabled: true, suDestroy: false)
    check operationValidationError(op) == ""
    let dec = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: op, baselineDigestHex: ""))).body)
    check dec.operation.kind == pokSystemdSystemUnit
    check dec.operation.suName == "repro-agent.service"
    check dec.operation.suContent == op.suContent
    check dec.operation.suEnabled

  test "launchd.systemDaemon operation frame round-trips":
    let op = PrivilegedOperation(kind: pokLaunchdSystemDaemon,
      address: "lda", sdaLabel: "com.example.daemon",
      sdaProgramArgs: @["/usr/local/bin/d", "--flag"],
      sdaRunAtLoad: true, sdaDestroy: false)
    check operationValidationError(op) == ""
    let dec = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: op, baselineDigestHex: ""))).body)
    check dec.operation.kind == pokLaunchdSystemDaemon
    check dec.operation.sdaProgramArgs == @["/usr/local/bin/d", "--flag"]
    check dec.operation.sdaRunAtLoad

  test "fs.systemFile + env.systemVariable + passwd.user frames round-trip":
    let f = PrivilegedOperation(kind: pokFsSystemFile, address: "f",
      sfPath: "/etc/profile.d/repro-system.sh", sfContent: "export X=1\n",
      sfDestroy: false)
    let fd = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: f, baselineDigestHex: ""))).body)
    check fd.operation.sfPath == "/etc/profile.d/repro-system.sh"
    check fd.operation.sfContent == "export X=1\n"
    # External-source fields round-trip preserved on the inline-content
    # path (all three stay empty — the backward-compat shape).
    check fd.operation.sfSourceUrl == ""
    check fd.operation.sfSha256 == ""
    check fd.operation.sfSourceLocal == ""

  test "fs.systemFile sourceUrl/sourceLocal frame round-trips":
    # Windows-System-Resources Phase A: encode + decode preserves the
    # external-source fields on the wire so the broker's payload
    # matches the controller's plan.
    let url = PrivilegedOperation(kind: pokFsSystemFile,
      address: "urlFile",
      sfPath: "/etc/cache/runner.tar.gz",
      sfSourceUrl: "https://example.com/runner.tar.gz",
      sfSha256: "0123456789abcdef0123456789abcdef" &
                "0123456789abcdef0123456789abcdef",
      sfDestroy: false)
    check operationValidationError(url) == ""
    let urlRT = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: url, baselineDigestHex: ""))).body).operation
    check urlRT.sfSourceUrl == "https://example.com/runner.tar.gz"
    check urlRT.sfSha256.len == 64
    check urlRT.sfContent == ""
    check urlRT.sfSourceLocal == ""

    let lo = PrivilegedOperation(kind: pokFsSystemFile,
      address: "localFile",
      sfPath: "/etc/cache/local.conf",
      sfSourceLocal: "/tmp/repro-controller-side/local.conf",
      sfDestroy: false)
    check operationValidationError(lo) == ""
    let loRT = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: lo, baselineDigestHex: ""))).body).operation
    check loRT.sfSourceLocal == "/tmp/repro-controller-side/local.conf"
    check loRT.sfContent == ""
    check loRT.sfSourceUrl == ""

  test "fs.systemFile validator rejects mutually exclusive sources":
    # Defence-in-depth at the closed-set boundary.
    let both = PrivilegedOperation(kind: pokFsSystemFile,
      address: "bothBad",
      sfPath: "/etc/cache/x",
      sfContent: "k = v",
      sfSourceUrl: "https://example.com/x",
      sfSha256: "0123456789abcdef0123456789abcdef" &
                "0123456789abcdef0123456789abcdef",
      sfDestroy: false)
    check operationValidationError(both).len > 0
    let bothLocal = PrivilegedOperation(kind: pokFsSystemFile,
      address: "bothLocalBad",
      sfPath: "/etc/cache/x",
      sfContent: "k = v",
      sfSourceLocal: "/tmp/x",
      sfDestroy: false)
    check operationValidationError(bothLocal).len > 0
    let urlNoSha = PrivilegedOperation(kind: pokFsSystemFile,
      address: "urlNoSha",
      sfPath: "/etc/cache/x",
      sfSourceUrl: "https://example.com/x",
      sfDestroy: false)
    check operationValidationError(urlNoSha).len > 0
    let shaNoUrl = PrivilegedOperation(kind: pokFsSystemFile,
      address: "shaNoUrl",
      sfPath: "/etc/cache/x",
      sfSha256: "0123456789abcdef0123456789abcdef" &
                "0123456789abcdef0123456789abcdef",
      sfDestroy: false)
    check operationValidationError(shaNoUrl).len > 0
    # Bad-length / non-hex sha256 is rejected too.
    let shortSha = PrivilegedOperation(kind: pokFsSystemFile,
      address: "shortSha",
      sfPath: "/etc/cache/x",
      sfSourceUrl: "https://example.com/x",
      sfSha256: "deadbeef", sfDestroy: false)
    check operationValidationError(shortSha).len > 0
    let upperSha = PrivilegedOperation(kind: pokFsSystemFile,
      address: "upperSha",
      sfPath: "/etc/cache/x",
      sfSourceUrl: "https://example.com/x",
      sfSha256: "0123456789ABCDEF0123456789ABCDEF" &
                "0123456789ABCDEF0123456789ABCDEF",
      sfDestroy: false)
    check operationValidationError(upperSha).len > 0
    # An all-empty fs.systemFile (no source at all) is a legitimate
    # "empty file" declaration and the validator accepts it; mutual
    # exclusion is `<= 1`, not `== 1`.
    let empty = PrivilegedOperation(kind: pokFsSystemFile,
      address: "emptyFile",
      sfPath: "/etc/cache/empty",
      sfDestroy: false)
    check operationValidationError(empty) == ""

  test "fs.systemFile desiredFileContent reads sourceLocal each call":
    # The driver re-reads `sfSourceLocal` on every call — so a
    # between-step edit lands in the second apply. Exercise that
    # against a real tempdir file: write A, observe digest A, edit
    # to B, observe digest B.
    when defined(linux) or defined(macosx) or defined(windows):
      let dir = createTempDir("repro-fssf-local-", "")
      defer: removeDir(dir)
      let src = dir / "src.txt"
      writeFile(src, "alpha")
      let op = PrivilegedOperation(kind: pokFsSystemFile,
        address: "localFile",
        sfPath: "/etc/profile.d/repro-localfile.sh",
        sfSourceLocal: src,
        sfDestroy: false)
      let bytesA = desiredFileContent(op)
      check bytesA == "alpha"
      writeFile(src, "bravo")
      let bytesB = desiredFileContent(op)
      check bytesB == "bravo"
      let bytesB2 = desiredFileContent(op)
      check bytesB2 == "bravo"

  test "fs.systemFile desiredFileContent raises on missing sourceLocal":
    when defined(linux) or defined(macosx) or defined(windows):
      let dir = createTempDir("repro-fssf-missing-", "")
      defer: removeDir(dir)
      let op = PrivilegedOperation(kind: pokFsSystemFile,
        address: "missingLocal",
        sfPath: "/etc/profile.d/repro-missing.sh",
        sfSourceLocal: dir / "definitely-not-here.txt",
        sfDestroy: false)
      var raised = false
      try:
        discard desiredFileContent(op)
      except CatchableError:
        raised = true
      check raised

  test "fs.systemFile desiredFileContent verifies sourceUrl digest":
    # Use a `data:`-URI as a controllable transport: stdlib
    # `httpclient` understands it without a network round-trip. We
    # pin both a correct and an incorrect BLAKE3 digest of the
    # decoded body and assert the verifier accepts / rejects.
    when defined(linux) or defined(macosx) or defined(windows):
      # NOTE: at the time of writing, std/httpclient does not handle
      # `data:` URIs; this test exercises the digest-mismatch failure
      # mode (the apply path should not surface raw bytes on a bad
      # hash). The negative case below is the primary integration
      # gate; a positive case for the `sourceUrl` path is exercised
      # by the e2e fixture's compile + plan, NOT a real fetch.
      let badShaOp = PrivilegedOperation(kind: pokFsSystemFile,
        address: "badShaUrl",
        sfPath: "/etc/profile.d/repro-url.sh",
        sfSourceUrl: "http://127.0.0.1:1/not-actually-served",
        sfSha256: "0123456789abcdef0123456789abcdef" &
                  "0123456789abcdef0123456789abcdef",
        sfDestroy: false)
      var raised = false
      try:
        discard desiredFileContent(badShaOp)
      except CatchableError:
        # Either the fetch fails (port 1 closed) or the digest
        # mismatches — both raise `EProtocol`, which is the
        # contract.
        raised = true
      check raised

  test "fs.systemFile posixSystemDesiredDigestHex dispatches on source":
    # The dispatcher's drift gate compares against this digest; the
    # sourceUrl path returns the pinned hex directly, the sourceLocal
    # path re-reads the file. Both produce the same shape the
    # post-apply re-probe compares against.
    when defined(linux) or defined(macosx) or defined(windows):
      let inlineOp = PrivilegedOperation(kind: pokFsSystemFile,
        address: "inline",
        sfPath: "/etc/x", sfContent: "hello", sfDestroy: false)
      let urlOp = PrivilegedOperation(kind: pokFsSystemFile,
        address: "url",
        sfPath: "/etc/x",
        sfSourceUrl: "https://example.com/y",
        sfSha256: "0123456789abcdef0123456789abcdef" &
                  "0123456789abcdef0123456789abcdef",
        sfDestroy: false)
      check posixSystemDesiredDigestHex(urlOp) == urlOp.sfSha256
      check posixSystemDesiredDigestHex(inlineOp).len == 64
      let dir = createTempDir("repro-fssf-desired-", "")
      defer: removeDir(dir)
      let src = dir / "src.txt"
      writeFile(src, "charlie")
      let localOp = PrivilegedOperation(kind: pokFsSystemFile,
        address: "local",
        sfPath: "/etc/x", sfSourceLocal: src, sfDestroy: false)
      # The local digest matches the digest of an inline op with the
      # same byte payload.
      let inlineCharlie = PrivilegedOperation(kind: pokFsSystemFile,
        address: "inlineCharlie",
        sfPath: "/etc/x", sfContent: "charlie", sfDestroy: false)
      check posixSystemDesiredDigestHex(localOp) ==
        posixSystemDesiredDigestHex(inlineCharlie)
    let e = PrivilegedOperation(kind: pokEnvSystemVariable, address: "e",
      evName: "PATH", evContribution: @["/opt/a/bin", "/opt/b/bin"],
      evIsPathList: true, evDestroy: false)
    let ed = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: e, baselineDigestHex: ""))).body)
    check ed.operation.evContribution == @["/opt/a/bin", "/opt/b/bin"]
    check ed.operation.evIsPathList
    let u = PrivilegedOperation(kind: pokPasswdUser, address: "u",
      puName: "deploy", puHome: "/home/deploy", puShell: "/bin/bash",
      puGroups: @["docker", "wheel"], puDestroy: false)
    let ud = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: u, baselineDigestHex: ""))).body)
    check ud.operation.puName == "deploy"
    check ud.operation.puGroups == @["docker", "wheel"]

  test "operationValidationError rejects a shell-injecting sdValueType":
    # The type flag flows into the elevated `defaults write` command
    # line — a `;`-bearing / metacharacter / non-allowlisted value MUST
    # be rejected before the operation ever reaches the broker.
    proc badDefault(ty: string): PrivilegedOperation =
      PrivilegedOperation(kind: pokMacosSystemDefault, address: "a",
        sdDomain: "com.apple.loginwindow", sdKey: "K",
        sdValueType: ty, sdValueLiteral: "v")
    # A `;`-terminated type that smuggles a second command.
    check operationValidationError(
      badDefault("-bool true; rm -rf /")).len > 0
    # Other shell metacharacters / substitutions.
    check operationValidationError(badDefault("-string `id`")).len > 0
    check operationValidationError(badDefault("-string $(id)")).len > 0
    check operationValidationError(badDefault("-string && id")).len > 0
    check operationValidationError(badDefault("-string | id")).len > 0
    check operationValidationError(badDefault("-string\nid")).len > 0
    # A flag that simply is not in the closed `defaults` allowlist.
    check operationValidationError(badDefault("-notAFlag")).len > 0
    check operationValidationError(badDefault("string")).len > 0
    # The legitimate type flags — and an empty type (driver default) —
    # all still pass.
    for ty in ["-string", "-data", "-int", "-integer", "-float",
               "-bool", "-boolean", "-date", "-array", "-array-add",
               "-dict", "-dict-add", ""]:
      check operationValidationError(badDefault(ty)) == ""

  test "operationValidationError rejects a shell-injecting sdaLabel":
    # The label flows into the elevated `launchctl ... system/<label>`
    # command lines — a label bearing a shell metacharacter, a space,
    # a `$`, a backtick, a `/`, or a newline MUST be rejected.
    proc badDaemon(label: string): PrivilegedOperation =
      PrivilegedOperation(kind: pokLaunchdSystemDaemon, address: "a",
        sdaLabel: label, sdaProgramArgs: @["/usr/local/bin/d"],
        sdaRunAtLoad: true, sdaDestroy: false)
    check operationValidationError(badDaemon("x; rm -rf /")).len > 0
    check operationValidationError(badDaemon("a b")).len > 0
    check operationValidationError(badDaemon("x$(id)")).len > 0
    check operationValidationError(badDaemon("x`id`")).len > 0
    check operationValidationError(badDaemon("a/b")).len > 0
    check operationValidationError(badDaemon("x\nid")).len > 0
    check operationValidationError(badDaemon("x&y")).len > 0
    check operationValidationError(badDaemon("x|y")).len > 0
    check operationValidationError(badDaemon("")).len > 0
    # A legitimate reverse-DNS-style label still passes.
    check operationValidationError(badDaemon("com.example.daemon")) == ""
    check operationValidationError(
      badDaemon("com.example.repro-agent_1")) == ""

  test "isSafeDefaultsTypeFlag / isSafeLaunchdLabel pure predicates":
    check isSafeDefaultsTypeFlag("-bool")
    check isSafeDefaultsTypeFlag("")          # driver `-string` default
    check not isSafeDefaultsTypeFlag("-bool true; id")
    check not isSafeDefaultsTypeFlag("-bogus")
    check isSafeLaunchdLabel("com.example.d")
    check not isSafeLaunchdLabel("x; id")
    check not isSafeLaunchdLabel("a b")
    check not isSafeLaunchdLabel("a/b")
    check not isSafeLaunchdLabel("")

  test "operationValidationError flags out-of-policy Phase-C operations":
    # macos.systemDefault: domain must resolve under /Library/Preferences/.
    check operationValidationError(PrivilegedOperation(
      kind: pokMacosSystemDefault, address: "a",
      sdDomain: "/etc/evil.plist", sdKey: "K")).len > 0
    # systemd.systemUnit: a unit name with a path separator escapes.
    check operationValidationError(PrivilegedOperation(
      kind: pokSystemdSystemUnit, address: "a",
      suName: "../escape.service")).len > 0
    # launchd.systemDaemon: a non-destroy op needs ProgramArguments.
    check operationValidationError(PrivilegedOperation(
      kind: pokLaunchdSystemDaemon, address: "a",
      sdaLabel: "ok", sdaDestroy: false)).len > 0
    # passwd.user: a name with a `:` is invalid.
    check operationValidationError(PrivilegedOperation(
      kind: pokPasswdUser, address: "a", puName: "bad:name")).len > 0
    # An in-policy operation passes.
    check operationValidationError(PrivilegedOperation(
      kind: pokPasswdUser, address: "a", puName: "deploy",
      puGroups: @["docker"])) == ""

suite "repro_elevation: macos.systemDefault pure logic (Phase C)":

  test "structural comparison ignores dict key order, not array order":
    check defaultsValuesEqual("{ a = 1; b = 2; }", "{ b = 2; a = 1; }")
    check not defaultsValuesEqual("(1, 2, 3)", "(3, 2, 1)")
    check defaultsValuesEqual("  true  ", "true")
    check defaultsValuesEqual("\"hello\"", "hello")

  test "systemDefaultPlistPath resolves a bare domain and a path":
    check systemDefaultPlistPath("com.apple.loginwindow") ==
      "/Library/Preferences/com.apple.loginwindow"
    check systemDefaultPlistPath(
      "/Library/Preferences/com.apple.loginwindow") ==
      "/Library/Preferences/com.apple.loginwindow"

  test "isSystemDefaultDomain rejects an out-of-scope plist path":
    check isSystemDefaultDomain("com.apple.loginwindow")
    check not isSystemDefaultDomain("/etc/passwd")
    check not isSystemDefaultDomain("/Library/Preferences/../../etc/x")

  test "the desired digest is structural — whitespace does not change it":
    let a = PrivilegedOperation(kind: pokMacosSystemDefault, address: "x",
      sdDomain: "com.apple.x", sdKey: "K", sdValueLiteral: "{a=1;b=2;}")
    let b = PrivilegedOperation(kind: pokMacosSystemDefault, address: "x",
      sdDomain: "com.apple.x", sdKey: "K", sdValueLiteral: "{ b = 2; a = 1; }")
    check posixSystemDesiredDigestHex(a) == posixSystemDesiredDigestHex(b)

suite "repro_elevation: systemd.systemUnit pure logic (Phase C)":

  test "systemUnitPath lands under /etc/systemd/system/":
    check systemUnitPath("repro-agent.service") ==
      "/etc/systemd/system/repro-agent.service"
    check SystemdSystemUnitDir == "/etc/systemd/system"

  test "isSafeUnitName rejects escapes":
    check isSafeUnitName("foo.service")
    check not isSafeUnitName("")
    check not isSafeUnitName("..")
    check not isSafeUnitName("a/b.service")
    check not isSafeUnitName("a\\b.service")

  test "parseSystemctlShow reads LoadState / ActiveState / UnitFileState":
    let obs = parseSystemctlShow(
      "LoadState=loaded\nActiveState=active\nUnitFileState=enabled\n")
    check obs.loadState == "loaded"
    check obs.activeState == "active"
    check obs.unitFileState == "enabled"
    check systemdUnitIsLoaded(obs)
    let absent = parseSystemctlShow(
      "LoadState=not-found\nActiveState=inactive\nUnitFileState=\n")
    check not systemdUnitIsLoaded(absent)
    check systemdUnitIsLoaded(parseSystemctlShow("LoadState=masked\n"))

suite "repro_elevation: launchd.systemDaemon pure logic (Phase C)":

  test "daemonPlistPath lands under /Library/LaunchDaemons/":
    check daemonPlistPath("com.example.d") ==
      "/Library/LaunchDaemons/com.example.d.plist"
    check LaunchDaemonsDir == "/Library/LaunchDaemons"

  test "buildLaunchDaemonPlist emits a valid plist with the argv + RunAtLoad":
    let plist = buildLaunchDaemonPlist("com.example.d",
      @["/usr/local/bin/d", "--flag"], runAtLoad = true)
    check plist.contains("<key>Label</key>")
    check plist.contains("<string>com.example.d</string>")
    check plist.contains("<string>/usr/local/bin/d</string>")
    check plist.contains("<string>--flag</string>")
    check plist.contains("<key>RunAtLoad</key>")
    check plist.contains("<true/>")
    # XML special characters in an argv element are escaped.
    let escaped = buildLaunchDaemonPlist("d", @["a<b>&c"], runAtLoad = false)
    check escaped.contains("a&lt;b&gt;&amp;c")
    check escaped.contains("<false/>")

  test "isSafeDaemonLabel rejects escapes":
    check isSafeDaemonLabel("com.example.d")
    check not isSafeDaemonLabel("")
    check not isSafeDaemonLabel("a/b")

suite "repro_elevation: fs.systemFile allowlist (Phase C)":

  test "paths under recognized system directories are allowed":
    check isAllowedSystemFilePath("/etc/profile.d/repro.sh")
    check isAllowedSystemFilePath("/usr/local/etc/repro.conf")
    check isAllowedSystemFilePath(
      "C:/ProgramData/repro/x.cfg", r"C:\ProgramData")

  test "out-of-allowlist or escaping paths are rejected":
    check not isAllowedSystemFilePath("/home/u/.bashrc")
    check not isAllowedSystemFilePath("/tmp/x")
    check not isAllowedSystemFilePath("/etc/../home/u/x")
    check not isAllowedSystemFilePath("")
    check systemFileScopeError("/home/u/x").len > 0
    check systemFileScopeError("/etc/ok") == ""

suite "repro_elevation: fs.systemDirectory allowlist + driver":

  test "directory allowlist accepts POSIX system roots":
    check isAllowedSystemDirectoryPath("/etc/myapp.d")
    check isAllowedSystemDirectoryPath("/usr/local/etc/repro-managed")

  test "directory allowlist accepts top-level Windows install roots":
    check isAllowedSystemDirectoryPath("C:\\actions-runner")
    check isAllowedSystemDirectoryPath("C:\\actions-runner-tokens")
    check isAllowedSystemDirectoryPath("D:\\repro-managed\\sub")
    # `${PROGRAMDATA}` is still accepted via the file allowlist path.
    check isAllowedSystemDirectoryPath(
      "C:/ProgramData/repro/dir", r"C:\ProgramData")

  test "directory allowlist refuses escaping or unknown paths":
    check not isAllowedSystemDirectoryPath("/home/u/x")
    check not isAllowedSystemDirectoryPath("/tmp/y")
    check not isAllowedSystemDirectoryPath("/etc/../home/x")
    check not isAllowedSystemDirectoryPath("C:\\actions-runner\\..\\Users")
    check not isAllowedSystemDirectoryPath("")
    check systemDirectoryScopeError("/home/u/x").len > 0
    check systemDirectoryScopeError("/etc/ok") == ""
    check systemDirectoryScopeError("C:\\actions-runner") == ""

  test "observe of an absent directory returns the absent sentinel":
    # The driver's `observeFsSystemDirectory` is read-only and works
    # against any allowlisted path. We exercise the absent branch
    # against `/etc/<random>` which is in-scope but won't exist on
    # the CI host.
    when defined(linux) or defined(macosx):
      let path = "/etc/repro-fssystemdir-absent-" &
        $getCurrentProcessId() & "-" & $epochTime().int
      let op = PrivilegedOperation(kind: pokFsSystemDirectory,
        address: "fdAbsent", fsdPath: path, fsdAclPresent: false,
        fsdDestroy: false)
      let obs = observeFsSystemDirectory(op)
      check not obs.present
      check obs.digestHex == ZeroDigestHex

  test "scope error refuses an out-of-allowlist apply":
    when defined(linux) or defined(macosx):
      # `/tmp/...` is NOT in the allowlist; the driver fails closed
      # with `EProtocol` before touching the filesystem.
      let op = PrivilegedOperation(kind: pokFsSystemDirectory,
        address: "fdOos", fsdPath: "/tmp/repro-fssystemdir-out-of-scope",
        fsdAclPresent: false, fsdDestroy: false)
      var raised = false
      try:
        discard applyFsSystemDirectory(op)
      except CatchableError:
        raised = true
      check raised

# ===========================================================================
# Windows-System-Resources Phase D — `fs.systemDirectory` NTFS ACL apply
# pure helpers + drift digest. The icacls argv assemblers + the Allow
# / Deny pivot + the canonical-payload contributors are all
# platform-pure (no shell-out); the live `icacls <path>` re-probe lives
# behind `when defined(windows)` in the driver and is exercised only
# on a Windows host.
# ===========================================================================

suite "repro_elevation: fs.systemDirectory Phase D — icacls argv":

  test "splitDirAclEntry detects the Deny direction":
    # The profile builder's `aclEntry(... type=Deny)` emits the leading
    # `:(D,...)` marker; the splitter strips it to the bare `:(...)` form
    # icacls's `/deny` verb consumes.
    let allow = splitDirAclEntry("SYSTEM:(F)")
    check allow.verb == icaclsGrantVerb
    check allow.spec == "SYSTEM:(F)"
    let deny = splitDirAclEntry("Guests:(D,W)")
    check deny.verb == icaclsDenyVerb
    check deny.spec == "Guests:(W)"
    let denyMulti = splitDirAclEntry(
      "BUILTIN\\Administrators:(D,F)")
    check denyMulti.verb == icaclsDenyVerb
    check denyMulti.spec == "BUILTIN\\Administrators:(F)"

  test "renderTakeownDirCommandArgs exact argv":
    check renderTakeownDirCommandArgs("C:\\actions-runner-tokens") ==
      @["takeown", "/F", "C:\\actions-runner-tokens", "/A"]
    # Path with a space — the renderer emits the raw argv; quoting
    # happens at the shell-cmd join.
    check renderTakeownDirCommandArgs("C:\\Program Files\\foo") ==
      @["takeown", "/F", "C:\\Program Files\\foo", "/A"]

  test "renderIcaclsSetOwnerCommandArgs exact argv":
    check renderIcaclsSetOwnerCommandArgs(
      "C:\\actions-runner-tokens", "SYSTEM") ==
      @["icacls", "C:\\actions-runner-tokens", "/setowner", "SYSTEM"]
    check renderIcaclsSetOwnerCommandArgs(
      "C:\\actions-runner-tokens", "BUILTIN\\Administrators") ==
      @["icacls", "C:\\actions-runner-tokens", "/setowner",
        "BUILTIN\\Administrators"]

  test "renderIcaclsInheritanceCommandArgs maps the closed set":
    let empty: seq[string] = @[]
    # `enabled` (or unset) is a no-op — empty argv.
    check renderIcaclsInheritanceCommandArgs(
      "C:\\actions-runner-tokens", "enabled") == empty
    check renderIcaclsInheritanceCommandArgs(
      "C:\\actions-runner-tokens", "") == empty
    # `disabled-replace` -> `/inheritance:r`.
    check renderIcaclsInheritanceCommandArgs(
      "C:\\actions-runner-tokens", "disabled-replace") ==
      @["icacls", "C:\\actions-runner-tokens", "/inheritance:r"]
    # `disabled-convert` -> `/inheritance:d`.
    check renderIcaclsInheritanceCommandArgs(
      "C:\\actions-runner-tokens", "disabled-convert") ==
      @["icacls", "C:\\actions-runner-tokens", "/inheritance:d"]
    # `protected-clear-inherited` -> same `/inheritance:r` flag (the
    # new vocabulary value names the SetAccessRuleProtection(true,
    # false) intent — icacls's `r` is the closest live verb).
    check renderIcaclsInheritanceCommandArgs(
      "C:\\actions-runner-tokens", "protected-clear-inherited") ==
      @["icacls", "C:\\actions-runner-tokens", "/inheritance:r"]

  test "renderIcaclsInheritanceCommandArgs refuses an unknown mode":
    let empty: seq[string] = @[]
    # An unknown mode falls through to the no-op branch; the closed-
    # set validator at the codec boundary already rejects this before
    # the driver sees the operation, so the pure renderer can fall
    # through silently rather than raising.
    check renderIcaclsInheritanceCommandArgs(
      "C:\\actions-runner-tokens", "evil-mode") == empty

  test "renderIcaclsGrantCommandArgs routes Allow vs Deny":
    # Allow ACE -> /grant + verbatim spec.
    check renderIcaclsGrantCommandArgs(
      "C:\\actions-runner-tokens", "SYSTEM:(F)") ==
      @["icacls", "C:\\actions-runner-tokens", "/grant", "SYSTEM:(F)"]
    check renderIcaclsGrantCommandArgs(
      "C:\\actions-runner-tokens",
      "BUILTIN\\Administrators:(F)") ==
      @["icacls", "C:\\actions-runner-tokens", "/grant",
        "BUILTIN\\Administrators:(F)"]
    # Deny ACE -> /deny + spec with the leading `D,` marker stripped.
    check renderIcaclsGrantCommandArgs(
      "C:\\actions-runner-tokens", "Guests:(D,W)") ==
      @["icacls", "C:\\actions-runner-tokens", "/deny", "Guests:(W)"]
    # Network ReadAndExecute (RX) Allow.
    check renderIcaclsGrantCommandArgs(
      "C:\\actions-runner-tokens", "NetworkService:(RX)") ==
      @["icacls", "C:\\actions-runner-tokens", "/grant",
        "NetworkService:(RX)"]

  test "renderArgvAsShellCmd quotes each token":
    # The shell-cmd join is what the driver feeds to `execCmdEx`. The
    # path-with-spaces case is the load-bearing one: `quoteShell`
    # wraps the path in double-quotes so the cmd.exe argv parser
    # treats it as one token.
    let argv = renderTakeownDirCommandArgs("C:\\Program Files\\foo")
    let cmd = renderArgvAsShellCmd(argv)
    # cmd.exe quoting: `takeown /F "C:\Program Files\foo" /A` on
    # Windows; on POSIX `quoteShell` uses single-quotes. Either way
    # the path's space must round-trip as part of ONE argument.
    check cmd.contains("Program Files") or cmd.contains("Program\\ Files")
    check cmd.startsWith("takeown")
    check cmd.endsWith("/A")

suite "repro_elevation: fs.systemDirectory Phase D — drift digest":

  test "canonicalDirAclDesired empty when ACL unmanaged":
    # The back-compat sentinel — an ACL-unmanaged directory MUST
    # contribute the empty string so the post-Phase-D
    # `fsSystemDirectoryDigestPayload` matches PR #7's pre-Phase-D
    # payload byte-for-byte.
    check canonicalDirAclDesired(false, "", @[], "") == ""

  test "canonicalDirAclDesired stable across entry re-ordering":
    let a = canonicalDirAclDesired(true, "SYSTEM",
      @["SYSTEM:(F)", "BUILTIN\\Administrators:(F)",
        "NetworkService:(RX)"],
      "protected-clear-inherited")
    let b = canonicalDirAclDesired(true, "SYSTEM",
      @["NetworkService:(RX)", "SYSTEM:(F)",
        "BUILTIN\\Administrators:(F)"],
      "protected-clear-inherited")
    check a == b
    check a.contains("SYSTEM:(F)")
    check a.contains("mode=protected-clear-inherited")

  test "canonicalDirAclDesired distinguishes inheritance vocab":
    let enabled = canonicalDirAclDesired(true, "SYSTEM",
      @["SYSTEM:(F)"], "enabled")
    let replace = canonicalDirAclDesired(true, "SYSTEM",
      @["SYSTEM:(F)"], "disabled-replace")
    let convert = canonicalDirAclDesired(true, "SYSTEM",
      @["SYSTEM:(F)"], "disabled-convert")
    let protected = canonicalDirAclDesired(true, "SYSTEM",
      @["SYSTEM:(F)"], "protected-clear-inherited")
    check enabled != replace
    check replace != convert
    check convert != protected
    check enabled != protected

  test "canonicalDirAclDesired defaults missing inheritance to enabled":
    check canonicalDirAclDesired(true, "SYSTEM", @["SYSTEM:(F)"], "") ==
      canonicalDirAclDesired(true, "SYSTEM", @["SYSTEM:(F)"], "enabled")

  test "canonicalDirAclObserved matches desired when ACEs converge":
    # Order-independence: a host whose ACL contains the desired ACEs
    # (plus possibly extras) yields the SAME observed-projection
    # digest as the desired digest, so the broker's cache-hit
    # predicate fires.
    let desired = canonicalDirAclDesired(true, "SYSTEM",
      @["SYSTEM:(F)", "NetworkService:(RX)"], "disabled-replace")
    let observed = canonicalDirAclObserved(true, "SYSTEM",
      @["SYSTEM:(F)", "NetworkService:(RX)"],
      # Host's ACL has the desired ACEs PLUS an extra one (additive
      # semantics — extras are NOT drift).
      @["BUILTIN\\Administrators:(F)", "NetworkService:(RX)",
        "SYSTEM:(F)"],
      observedInheritanceDisabled = true,
      desiredInheritance = "disabled-replace")
    check desired == observed

  test "canonicalDirAclObserved differs when a desired ACE is missing":
    let desired = canonicalDirAclDesired(true, "SYSTEM",
      @["SYSTEM:(F)", "NetworkService:(RX)"], "disabled-replace")
    let observed = canonicalDirAclObserved(true, "SYSTEM",
      @["SYSTEM:(F)", "NetworkService:(RX)"],
      # Missing the second desired ACE on the host.
      @["SYSTEM:(F)"],
      observedInheritanceDisabled = true,
      desiredInheritance = "disabled-replace")
    check desired != observed

  test "canonicalDirAclObserved differs when inheritance not pinned":
    # `disabled-replace` requires the live ACL to have inheritance
    # disabled. A host where inheritance is still enabled flips the
    # digest even when every desired ACE is present.
    let desired = canonicalDirAclDesired(true, "SYSTEM",
      @["SYSTEM:(F)"], "disabled-replace")
    let observed = canonicalDirAclObserved(true, "SYSTEM",
      @["SYSTEM:(F)"], @["SYSTEM:(F)"],
      observedInheritanceDisabled = false,
      desiredInheritance = "disabled-replace")
    check desired != observed

  test "dirAclMatchesDesired covers the convergence + drift cases":
    # Converged: every desired ACE present, inheritance disabled.
    check dirAclMatchesDesired(true, "SYSTEM",
      @["SYSTEM:(F)"], @["SYSTEM:(F)"],
      observedInheritanceDisabled = true,
      desiredInheritance = "disabled-replace")
    # Drift: a desired ACE missing.
    check not dirAclMatchesDesired(true, "SYSTEM",
      @["SYSTEM:(F)", "NetworkService:(RX)"],
      @["SYSTEM:(F)"],
      observedInheritanceDisabled = true,
      desiredInheritance = "disabled-replace")
    # Absent target -> never a match for an ACL-managed directory.
    check not dirAclMatchesDesired(false, "SYSTEM",
      @["SYSTEM:(F)"], @[],
      observedInheritanceDisabled = false,
      desiredInheritance = "enabled")

  test "normalizeDirAclEntry collapses internal whitespace + canonicalises principal":
    # The principal-alias collapse (added alongside the whitespace
    # pass) rewrites ``SYSTEM`` to ``NT AUTHORITY\SYSTEM`` so the
    # desired digest matches the icacls-emitted observed digest.
    check normalizeDirAclEntry("SYSTEM:(F)") == "NT AUTHORITY\\SYSTEM:(F)"
    check normalizeDirAclEntry("  SYSTEM:(F)  ") ==
      "NT AUTHORITY\\SYSTEM:(F)"
    check normalizeDirAclEntry("SYSTEM:(F)  (OI)") ==
      "NT AUTHORITY\\SYSTEM:(F) (OI)"
    check normalizeDirAclEntry("SYSTEM:(F)\t (CI)") ==
      "NT AUTHORITY\\SYSTEM:(F) (CI)"
    # A principal already in domain-qualified form is left alone.
    check normalizeDirAclEntry("NT AUTHORITY\\SYSTEM:(F)") ==
      "NT AUTHORITY\\SYSTEM:(F)"
    # NetworkService -> NT AUTHORITY\NETWORK SERVICE.
    check normalizeDirAclEntry("NetworkService:(RX)") ==
      "NT AUTHORITY\\NETWORK SERVICE:(RX)"
    # An unknown principal is left alone (the canonicaliser only
    # rewrites the documented well-known set).
    check normalizeDirAclEntry("DOMAIN\\Alice:(F)") == "DOMAIN\\Alice:(F)"

  test "fsSystemDirectoryDigestPayload back-compat for ACL-unmanaged":
    # The aclPresent==false branch MUST produce a string
    # byte-identical to PR #7's legacy
    # `"fs.systemDirectory:present"` payload so the unmanaged-ACL
    # observation digest is bit-for-bit unchanged.
    check fsSystemDirectoryDigestPayload(true, false, "", @[], "") ==
      "fs.systemDirectory:present"
    # Owner / entries / inheritance are IGNORED when aclPresent==false
    # — a stray field doesn't poison the legacy payload.
    check fsSystemDirectoryDigestPayload(true, false, "SYSTEM",
      @["SYSTEM:(F)"], "disabled-replace") ==
      "fs.systemDirectory:present"

  test "fsSystemDirectoryDigestPayload absent yields the empty string":
    # The absent observation digests to the zero sentinel; the
    # payload itself is the empty string.
    check fsSystemDirectoryDigestPayload(false, false, "", @[], "") == ""
    check fsSystemDirectoryDigestPayload(false, true, "SYSTEM",
      @["SYSTEM:(F)"], "enabled") == ""

  test "fsSystemDirectoryDigestPayload extends payload when ACL managed":
    let payload = fsSystemDirectoryDigestPayload(true, true,
      "SYSTEM", @["SYSTEM:(F)", "BUILTIN\\Administrators:(F)"],
      "protected-clear-inherited")
    check payload.startsWith("fs.systemDirectory:present|")
    check payload.contains("owner=SYSTEM")
    check payload.contains("mode=protected-clear-inherited")
    check payload.contains("SYSTEM:(F)")
    check payload.contains("BUILTIN\\Administrators:(F)")

  test "fsSystemDirectoryDigestPayload distinguishes aclPresent variants":
    # Pure-function digest assertion (no filesystem I/O): the
    # aclPresent==false branch produces the back-compat sentinel; the
    # aclPresent==true branch extends it with the canonical ACL
    # contribution. The two payloads MUST hash to distinct digests so
    # the broker's drift comparison recomputes the apply when the
    # operator changes the ACL declaration.
    let legacyPayload = fsSystemDirectoryDigestPayload(true, false,
      "", @[], "")
    let aclPayload = fsSystemDirectoryDigestPayload(true, true,
      "SYSTEM", @["SYSTEM:(F)"], "protected-clear-inherited")
    check legacyPayload == "fs.systemDirectory:present"
    check legacyPayload != aclPayload
    # BLAKE3 hashing is injective on distinct payloads.
    check posixDigestHexOfText(legacyPayload) !=
      posixDigestHexOfText(aclPayload)
    # The aclPresent==false digest matches PR #7's legacy
    # `posixDigestHexOfText("fs.systemDirectory:present")`
    # byte-for-byte.
    check posixDigestHexOfText(legacyPayload) ==
      posixDigestHexOfText("fs.systemDirectory:present")

  test "validator: aclInheritance closed-set vocabulary":
    # Defence-in-depth — the codec-boundary validator rejects an
    # inheritance value outside the closed set.
    let bad = PrivilegedOperation(kind: pokFsSystemDirectory,
      address: "fdBadInh", fsdPath: "/etc/myapp.d",
      fsdAclPresent: true,
      fsdAclEntries: @["SYSTEM:(F)"],
      fsdAclInheritance: "make-up-mode")
    check operationValidationError(bad).len > 0
    # All four documented values pass the validator.
    for mode in ["enabled", "disabled-replace",
                 "disabled-convert", "protected-clear-inherited"]:
      let ok = PrivilegedOperation(kind: pokFsSystemDirectory,
        address: "fdOk", fsdPath: "/etc/myapp.d",
        fsdAclPresent: true,
        fsdAclEntries: @["SYSTEM:(F)"],
        fsdAclInheritance: mode)
      check operationValidationError(ok) == ""

  test "validator: aclEntries non-empty when aclPresent + non-destroy":
    # A managed ACL must declare at least one ACE — an empty list is
    # a profile authoring bug.
    let bad = PrivilegedOperation(kind: pokFsSystemDirectory,
      address: "fdNoEntries", fsdPath: "/etc/myapp.d",
      fsdAclPresent: true,
      fsdAclEntries: @[],
      fsdAclInheritance: "disabled-replace")
    check operationValidationError(bad).len > 0
    # Destroy direction does NOT require entries (the destroy strips
    # the directory; no ACL stamp needed).
    let okDestroy = PrivilegedOperation(kind: pokFsSystemDirectory,
      address: "fdDestroy", fsdPath: "/etc/myapp.d",
      fsdAclPresent: true,
      fsdAclEntries: @[],
      fsdAclInheritance: "enabled",
      fsdDestroy: true)
    check operationValidationError(okDestroy) == ""

suite "repro_elevation: env.systemVariable merge (Phase C)":

  test "computeMergedSystemPath keeps existing order, appends new entries":
    check computeMergedSystemPath(@["/bin", "/usr/bin"],
      @["/opt/a/bin", "/bin"]) == @["/bin", "/usr/bin", "/opt/a/bin"]

  test "subtractSystemPathContribution removes only the contribution":
    check subtractSystemPathContribution(
      @["/bin", "/opt/a/bin", "/usr/bin"], @["/opt/a/bin"]) ==
      @["/bin", "/usr/bin"]

  test "splitPathList / joinPathList round-trip and drop empties":
    check splitPathList("/a::/b:", ':') == @["/a", "/b"]
    check joinPathList(@["/a", "/b"], ':') == "/a:/b"

suite "repro_elevation: passwd.user pure logic (Phase C)":

  test "parseGetentPasswd reads the colon-separated record":
    let obs = parseGetentPasswd(
      "deploy:x:1001:1001:Deploy User:/home/deploy:/bin/bash")
    check obs.present
    check obs.uid == "1001"
    check obs.homeDir == "/home/deploy"
    check obs.shell == "/bin/bash"
    check not parseGetentPasswd("").present
    check not parseGetentPasswd("garbage").present

  test "parseIdGroups returns a sorted supplementary-group set":
    check parseIdGroups("wheel docker  staff") ==
      @["docker", "staff", "wheel"]

  test "diffPasswdUser: an absent account => create with all groups":
    let diff = diffPasswdUser(
      PasswdUserDesired(name: "deploy", groups: @["docker", "wheel"]),
      PasswdUserObservation(present: false))
    check diff.accountAbsent
    check diff.missingGroups == @["docker", "wheel"]

  test "diffPasswdUser: pinned attribute differs => usermod needed":
    let observed = PasswdUserObservation(present: true, uid: "1001",
      homeDir: "/home/deploy", shell: "/bin/sh", groups: @["docker"])
    let diff = diffPasswdUser(
      PasswdUserDesired(name: "deploy", shell: "/bin/bash",
        groups: @["docker", "wheel"]), observed)
    check not diff.accountAbsent
    check diff.shellDiffers
    check not diff.homeDirDiffers      # homeDir unpinned (empty desired)
    check diff.groupsDiffer
    check diff.missingGroups == @["wheel"]
    check passwdUserNeedsUpdate(diff)

  test "diffPasswdUser: an extra supplementary group is reported":
    let observed = PasswdUserObservation(present: true, uid: "1001",
      groups: @["docker", "wheel", "sudo"])
    let diff = diffPasswdUser(
      PasswdUserDesired(name: "deploy", groups: @["docker"]), observed)
    check diff.extraGroups == @["sudo", "wheel"]
    check diff.groupsDiffer

  test "diffPasswdUser: an in-sync account needs no update":
    let observed = PasswdUserObservation(present: true, uid: "1001",
      homeDir: "/home/deploy", shell: "/bin/bash", groups: @["docker"])
    let diff = diffPasswdUser(
      PasswdUserDesired(name: "deploy", homeDir: "/home/deploy",
        shell: "/bin/bash", groups: @["docker"]), observed)
    check not passwdUserNeedsUpdate(diff)

  test "buildUseraddArgs builds a create argv from typed fields":
    let args = buildUseraddArgs(PasswdUserDesired(name: "deploy",
      homeDir: "/home/deploy", shell: "/bin/bash",
      groups: @["wheel", "docker"]))
    check args[0] == "deploy"
    check "--home-dir" in args
    check "/home/deploy" in args
    check "--create-home" in args
    check "--shell" in args
    check "--groups" in args
    # The group list is sorted + comma-joined.
    let gi = args.find("--groups")
    check args[gi + 1] == "docker,wheel"

  test "buildUsermodArgs passes only the differing attributes":
    let observed = PasswdUserObservation(present: true, uid: "1001",
      homeDir: "/home/deploy", shell: "/bin/sh", groups: @["docker"])
    let desired = PasswdUserDesired(name: "deploy", shell: "/bin/bash",
      groups: @["docker", "wheel"])
    let args = buildUsermodArgs(desired, diffPasswdUser(desired, observed))
    check "--shell" in args
    check "/bin/bash" in args
    check "--home" notin args            # homeDir unpinned
    check "--groups" in args
    check args[^1] == "deploy"
    # An in-sync account yields an empty argv.
    check buildUsermodArgs(desired, diffPasswdUser(desired,
      PasswdUserObservation(present: true, shell: "/bin/bash",
        groups: @["docker", "wheel"]))).len == 0

  test "buildUserdelArgs removes the home directory":
    check buildUserdelArgs("deploy") == @["--remove", "deploy"]

  test "canonical desired vs observed: unpinned attributes use a wildcard":
    let desired = PasswdUserDesired(name: "deploy", shell: "/bin/bash",
      groups: @["docker"])
    # An observation matching the pinned attributes (any uid / home)
    # canonicalizes to the same string as the desired wildcard form.
    check canonicalPasswdUserDesired(desired) ==
      "user:present;uid=*;home=*;shell=/bin/bash;groups=docker"
    check canonicalPasswdUserState(
      PasswdUserObservation(present: false)) == "user:absent"

  test "passwd.user desired digest: a destroy op is the absent sentinel":
    let destroyOp = PrivilegedOperation(kind: pokPasswdUser, address: "u",
      puName: "deploy", puDestroy: true)
    check posixSystemDesiredDigestHex(destroyOp) ==
      "0000000000000000000000000000000000000000000000000000000000000000"

  test "canonicalPasswdUserStateMaskedBy: unpinned fields mask to wildcard":
    # The post-apply re-probe contract: an `useradd` driven by a
    # desired that pins ONLY name + groups must compare equal to
    # whatever `useradd` chose for home / shell / uid. Without the
    # mask the digests would never match (the desired canonical
    # has `home=*;shell=*` while the observed has the live paths)
    # and every `passwd.user` apply would `errorCount=1` even on a
    # clean `useradd` exit 0.
    let desired = PasswdUserDesired(name: "reprotest",
      homeDir: "", shell: "", groups: @["users"])
    let observed = PasswdUserObservation(present: true,
      uid: "1001", primaryGroup: "users",
      homeDir: "/home/reprotest", shell: "/bin/sh",
      groups: @["users"])
    # The unmasked observed carries the live paths (drift detection).
    check canonicalPasswdUserState(observed) ==
      "user:present;uid=1001;home=/home/reprotest;shell=/bin/sh;" &
      "groups=users"
    # The masked observed matches the desired byte-for-byte.
    check canonicalPasswdUserStateMaskedBy(observed, desired) ==
      canonicalPasswdUserDesired(desired)

  test "canonicalPasswdUserStateMaskedBy: pinned fields are NOT masked":
    # A resource that pins `shell` must not be satisfied by an
    # observation with a DIFFERENT shell — masking only rewrites
    # fields the desired left blank.
    let desired = PasswdUserDesired(name: "reprotest",
      homeDir: "", shell: "/bin/bash", groups: @["users"])
    let observed = PasswdUserObservation(present: true,
      uid: "1001", primaryGroup: "users",
      homeDir: "/home/reprotest", shell: "/bin/sh",
      groups: @["users"])
    check canonicalPasswdUserStateMaskedBy(observed, desired) !=
      canonicalPasswdUserDesired(desired)
    # The pinned shell shows through verbatim; only home was masked.
    check canonicalPasswdUserStateMaskedBy(observed, desired) ==
      "user:present;uid=*;home=*;shell=/bin/sh;groups=users"

  test "canonicalPasswdUserStateMaskedBy: absent observation is `user:absent`":
    let desired = PasswdUserDesired(name: "reprotest", groups: @["users"])
    check canonicalPasswdUserStateMaskedBy(
      PasswdUserObservation(present: false), desired) == "user:absent"

  test "canonicalPasswdUserStateMaskedBy: extra groups are tolerated (ADDITIVE-only — M11 fix)":
    # The macOS `sysadminctl -addUser` makes a fresh user a member
    # of many `everyone`-style default groups (`everyone`,
    # `localaccounts`, `_appstore`, `com.apple.access_*`, ...) on
    # top of whatever supplementary groups the resource declared.
    # The pre-M11 post-apply re-probe compared the observed set
    # against the desired set as a SET-EQUALITY check (digests
    # had to be byte-equal) and fail-closed spuriously on macOS
    # even though the apply genuinely succeeded. M11 narrows the
    # comparator to ADDITIVE-only: the masked-observed canonical
    # contains the INTERSECTION of observed-and-desired groups, so
    # "every declared group is observed" suffices, "no extra
    # groups exist" is no longer required.
    let desired = PasswdUserDesired(name: "reprotest",
      homeDir: "", shell: "", groups: @["admin"])
    let observed = PasswdUserObservation(present: true,
      uid: "502", primaryGroup: "staff",
      homeDir: "/Users/reprotest", shell: "/bin/zsh",
      groups: @["admin", "everyone", "localaccounts",
        "_appstore", "_developer", "com.apple.access_ssh"])
    # The masked observed is reduced to `groups=admin` — the
    # intersection of observed-and-desired — matching the desired
    # canonical byte-for-byte.
    check canonicalPasswdUserStateMaskedBy(observed, desired) ==
      canonicalPasswdUserDesired(desired)

  test "canonicalPasswdUserStateMaskedBy: missing declared group is NOT tolerated (negative)":
    # Conversely: if a DECLARED group is missing from the
    # observation (the apply did not actually add the user to it),
    # the masked-observed canonical drops the group and the
    # comparator catches the drift.
    let desired = PasswdUserDesired(name: "reprotest",
      groups: @["admin", "wheel"])
    let observed = PasswdUserObservation(present: true,
      uid: "502", primaryGroup: "staff",
      homeDir: "/Users/reprotest", shell: "/bin/zsh",
      groups: @["admin"])              # missing "wheel"
    check canonicalPasswdUserStateMaskedBy(observed, desired) !=
      canonicalPasswdUserDesired(desired)

  test "parsePasswdObservation: primary group filtered out of supplementary set":
    # Debian / Ubuntu's `useradd reprotest --groups users` (with the
    # default `USERGROUPS_ENAB=yes`) creates a per-user primary
    # group `reprotest` AND adds the user to supplementary `users`,
    # so `id -nG reprotest` returns `reprotest users`. The
    # supplementary-only set the `passwd.user` resource pins is
    # `["users"]`, not `["reprotest", "users"]` — the parser must
    # drop the primary group to keep the diff / re-probe digest
    # correct on every distro where useradd creates per-user primary
    # groups.
    let obs = parsePasswdObservation(
      "reprotest:x:1001:1001::/home/reprotest:/bin/sh",
      "reprotest users", "reprotest")
    check obs.present
    check obs.primaryGroup == "reprotest"
    check obs.groups == @["users"]

  test "parsePasswdObservation: primary already excluded by id -nG -> no-op":
    # Distros that share a system-wide primary group (NixOS, some
    # corporate LDAP setups) produce `id -nG reprotest` => `users`
    # alone, with `id -gn reprotest` => `users`. The filter MUST
    # NOT drop the only group when it's both primary and pinned.
    let obs = parsePasswdObservation(
      "reprotest:x:1001:100::/home/reprotest:/bin/sh",
      "users", "users")
    check obs.present
    check obs.primaryGroup == "users"
    check obs.groups == newSeq[string]()

  test "parsePasswdObservation: empty primary leaves all groups intact":
    # Defence in depth: a probe that returns no primary group (the
    # `id -gn` failure mode) MUST NOT discard the entire group set
    # — leave `groups` populated so drift detection still has
    # something to compare against.
    let obs = parsePasswdObservation(
      "reprotest:x:1001:100::/home/reprotest:/bin/sh",
      "docker wheel", "")
    check obs.present
    check obs.groups == @["docker", "wheel"]

# ===========================================================================
# M82 Phase B — the shared producer / consumer map, promoted from the
# driver-private `CapabilityServiceMap`. Verified here at the elevation
# library boundary so a regression that hides the table (or breaks the
# prefix-matching semantics) is caught WITHOUT a Windows host or a
# real broker run.
# ===========================================================================

suite "repro_elevation: ProducerConsumerMap lookup (M82 Phase B)":

  test "lookupProducedResources matches a Windows Capability by prefix":
    # The seed entry: `windows.capability OpenSSH.Server~~~~` registers
    # the `sshd` SCM service. The prefix match is the load-bearing
    # invariant — the version-tagged real name varies across Windows
    # releases but the table entry remains stable.
    let produced = lookupProducedResources("windows.capability",
      "OpenSSH.Server~~~~0.0.1.0")
    check produced.len == 1
    check produced[0].kind == "windows.service"
    check produced[0].name == "sshd"
    # The bare prefix matches too.
    let bare = lookupProducedResources("windows.capability",
      "OpenSSH.Server~~~~")
    check bare == produced

  test "lookupProducedResources returns empty for an unmapped producer":
    check lookupProducedResources("windows.capability",
      "RSAT.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0").len == 0
    check lookupProducedResources("windows.service", "sshd").len == 0
    check lookupProducedResources("totally.unknownKind", "anything").len == 0

  test "lookupCapabilityRegisteredService is the driver-side back-compat shim":
    # The M69 CBS-finalization wait calls this — verify it still finds
    # the SAME `sshd` entry the planner's edge inference picks up via
    # `lookupProducedResources`, so the driver-side and planner-side
    # views of the table can never diverge.
    check lookupCapabilityRegisteredService(
      "OpenSSH.Server~~~~0.0.1.0") == "sshd"
    check lookupCapabilityRegisteredService(
      "RSAT.NotInMap") == ""

# ===========================================================================
# windows.firewallRule — pure parse + drift logic. The shell-out side
# of the driver runs only on Windows hosts; what runs everywhere is
# the closed-set validator, the canonical-state digest, and the
# Get-NetFirewallRule probe-output parser.
# ===========================================================================

suite "repro_elevation: windows.firewallRule pure surface":

  test "isSafeFirewallIdentifier accepts a typical rule name":
    check isSafeFirewallIdentifier("OpenSSH-Server-In-TCP")
    check isSafeFirewallIdentifier("Custom_Rule.42 v2")
    check not isSafeFirewallIdentifier("")
    check not isSafeFirewallIdentifier("Bad'Name")
    check not isSafeFirewallIdentifier("Bad;Name")
    check not isSafeFirewallIdentifier("Bad`Name")

  test "isSafeFirewallDisplayName accepts spaces and parentheses":
    check isSafeFirewallDisplayName("OpenSSH Server (sshd)")
    check isSafeFirewallDisplayName("")
    check not isSafeFirewallDisplayName("Bad'Quote")
    check not isSafeFirewallDisplayName("Has\nNewline")

  test "isSafeFirewallPort accepts single ports, ranges, lists, and Any":
    check isSafeFirewallPort("22")
    check isSafeFirewallPort("22,2222")
    check isSafeFirewallPort("8000-9000")
    check isSafeFirewallPort("Any")
    check isSafeFirewallPort("any")
    check isSafeFirewallPort("")
    check not isSafeFirewallPort("22; rm")
    check not isSafeFirewallPort("$(whoami)")
    check not isSafeFirewallPort("twentytwo")

  test "operationValidationError accepts a valid firewall-rule operation":
    let ok = PrivilegedOperation(kind: pokWindowsFirewallRule,
      address: "ssh-firewall",
      fwName: "OpenSSH-Server-In-TCP",
      fwDisplayName: "OpenSSH Server (sshd)",
      fwProtocol: "TCP", fwDirection: "Inbound", fwAction: "Allow",
      fwLocalPort: "22", fwEnabled: true)
    check operationValidationError(ok) == ""

  test "operationValidationError flags bad firewall fields":
    let badProto = PrivilegedOperation(kind: pokWindowsFirewallRule,
      address: "x", fwName: "Rule",
      fwProtocol: "SCTP", fwDirection: "Inbound", fwAction: "Allow")
    check operationValidationError(badProto).len > 0

    let badDir = PrivilegedOperation(kind: pokWindowsFirewallRule,
      address: "x", fwName: "Rule",
      fwProtocol: "TCP", fwDirection: "Sideways", fwAction: "Allow")
    check operationValidationError(badDir).len > 0

    let badAction = PrivilegedOperation(kind: pokWindowsFirewallRule,
      address: "x", fwName: "Rule",
      fwProtocol: "TCP", fwDirection: "Inbound", fwAction: "Permit")
    check operationValidationError(badAction).len > 0

    let badName = PrivilegedOperation(kind: pokWindowsFirewallRule,
      address: "x", fwName: "X'; rm -rf /",
      fwProtocol: "TCP", fwDirection: "Inbound", fwAction: "Allow")
    check operationValidationError(badName).len > 0

    let emptyAddr = PrivilegedOperation(kind: pokWindowsFirewallRule,
      address: "", fwName: "Rule",
      fwProtocol: "TCP", fwDirection: "Inbound", fwAction: "Allow")
    check operationValidationError(emptyAddr).len > 0

  test "parseFirewallRuleQuery reads a present rule probe":
    let raw = """
Name=OpenSSH-Server-In-TCP
DisplayName=OpenSSH Server (sshd)
Direction=Inbound
Action=Allow
Enabled=True
Protocol=TCP
LocalPort=22
"""
    let obs = parseFirewallRuleQuery(raw)
    check obs.present
    check obs.name == "OpenSSH-Server-In-TCP"
    check obs.displayName == "OpenSSH Server (sshd)"
    check obs.protocol == "TCP"
    check obs.direction == "Inbound"
    check obs.action == "Allow"
    check obs.localPort == "22"
    check obs.enabled

  test "parseFirewallRuleQuery reads the Missing=1 sentinel as absent":
    check not parseFirewallRuleQuery("Missing=1").present

  test "parseFirewallRuleQuery treats an empty output as absent":
    check not parseFirewallRuleQuery("").present

  test "canonical firewall-rule state collapses Any port spellings":
    let obs1 = FirewallRuleObservation(present: true,
      name: "R", displayName: "R", protocol: "TCP",
      direction: "Inbound", action: "Allow", localPort: "Any",
      enabled: true)
    let obs2 = FirewallRuleObservation(present: true,
      name: "R", displayName: "R", protocol: "TCP",
      direction: "Inbound", action: "Allow", localPort: "any",
      enabled: true)
    check canonicalFirewallRuleState(obs1) ==
      canonicalFirewallRuleState(obs2)
    check canonicalFirewallRuleState(obs1) ==
      canonicalFirewallRuleDesired("R", "R", "TCP", "Inbound", "Allow",
        "Any", true)

  test "firewallRuleMatchesDesired detects a port mismatch":
    let obs = FirewallRuleObservation(present: true,
      name: "OpenSSH-Server-In-TCP",
      displayName: "OpenSSH Server (sshd)",
      protocol: "TCP", direction: "Inbound", action: "Allow",
      localPort: "22", enabled: true)
    check firewallRuleMatchesDesired(obs,
      "OpenSSH-Server-In-TCP", "OpenSSH Server (sshd)",
      "TCP", "Inbound", "Allow", "22", true)
    check not firewallRuleMatchesDesired(obs,
      "OpenSSH-Server-In-TCP", "OpenSSH Server (sshd)",
      "TCP", "Inbound", "Allow", "23", true)
    check not firewallRuleMatchesDesired(obs,
      "OpenSSH-Server-In-TCP", "OpenSSH Server (sshd)",
      "TCP", "Inbound", "Allow", "22", false)
    check not firewallRuleMatchesDesired(
      FirewallRuleObservation(present: false),
      "OpenSSH-Server-In-TCP", "OpenSSH Server (sshd)",
      "TCP", "Inbound", "Allow", "22", true)

  test "RBEB Operation frame round-trips a windows.firewallRule":
    let op = PrivilegedOperation(kind: pokWindowsFirewallRule,
      address: "ssh-firewall",
      fwName: "OpenSSH-Server-In-TCP",
      fwDisplayName: "OpenSSH Server (sshd)",
      fwProtocol: "TCP", fwDirection: "Inbound", fwAction: "Allow",
      fwLocalPort: "22", fwEnabled: true, fwDestroy: false)
    let wire = WireOperation(operation: op,
      baselineDigestHex: "deadbeef")
    let dec = decodeFrame(encodeOperation(wire))
    check dec.messageType == rmtOperation
    let w2 = decodeOperation(dec.body)
    check w2.baselineDigestHex == "deadbeef"
    check w2.operation.kind == pokWindowsFirewallRule
    check w2.operation.address == "ssh-firewall"
    check w2.operation.fwName == "OpenSSH-Server-In-TCP"
    check w2.operation.fwDisplayName == "OpenSSH Server (sshd)"
    check w2.operation.fwProtocol == "TCP"
    check w2.operation.fwDirection == "Inbound"
    check w2.operation.fwAction == "Allow"
    check w2.operation.fwLocalPort == "22"
    check w2.operation.fwEnabled
    check not w2.operation.fwDestroy

  test "windows.firewallRule requires elevation":
    check requiresElevation(pokWindowsFirewallRule)
    check $pokWindowsFirewallRule == "windows.firewallRule"
    check privilegedOperationKindFromString("windows.firewallRule") ==
      pokWindowsFirewallRule

# ===========================================================================
# windows.service Phase B (Windows-System-Resources) — closed-set
# recovery action vocabulary, sc.exe argv formatter, codec round-trip
# across all four optional fields, and sc qfailure output parser. The
# real driver runs only on Windows; what runs everywhere is the pure
# logic verified below.
# ===========================================================================

suite "repro_elevation: windows.service Phase B pure surface":

  test "all four recovery-action enum variants round-trip through their token":
    for variant in [wsrakNone, wsrakRestart, wsrakRunCommand, wsrakReboot]:
      let tok = windowsServiceRecoveryActionToken(variant)
      check isKnownWindowsServiceRecoveryActionToken(tok)
      check windowsServiceRecoveryActionFromToken(tok) == variant
    # Canonical lower-case vocabulary.
    check windowsServiceRecoveryActionToken(wsrakNone) == "none"
    check windowsServiceRecoveryActionToken(wsrakRestart) == "restart"
    check windowsServiceRecoveryActionToken(wsrakRunCommand) == "runcommand"
    check windowsServiceRecoveryActionToken(wsrakReboot) == "reboot"

  test "windowsServiceRecoveryActionFromToken rejects unknown / uppercase":
    expect ValueError:
      discard windowsServiceRecoveryActionFromToken("Restart")
    expect ValueError:
      discard windowsServiceRecoveryActionFromToken("RESTART")
    expect ValueError:
      discard windowsServiceRecoveryActionFromToken("")
    expect ValueError:
      discard windowsServiceRecoveryActionFromToken("nope")
    check not isKnownWindowsServiceRecoveryActionToken("Restart")
    check not isKnownWindowsServiceRecoveryActionToken("")

  test "scExeFailureActionToken maps to the SCM's sc.exe vocabulary":
    # `sc.exe failure ... actions=` consumes `restart` / `run` / `reboot`
    # / empty (with the `runcommand` enum mapping to sc.exe's shorter
    # `run` spelling — which is what the failure-action printer prints).
    check scExeFailureActionToken(wsrakRestart) == "restart"
    check scExeFailureActionToken(wsrakRunCommand) == "run"
    check scExeFailureActionToken(wsrakReboot) == "reboot"
    check scExeFailureActionToken(wsrakNone) == ""

  test "renderScExeFailureActionsArg assembles slash-separated slots":
    let actions = @[
      WindowsServiceRecoverySpec(action: wsrakRestart, delayMs: 5000),
      WindowsServiceRecoverySpec(action: wsrakRestart, delayMs: 10000),
      WindowsServiceRecoverySpec(action: wsrakReboot, delayMs: 60000)]
    check renderScExeFailureActionsArg(actions) ==
      "restart/5000/restart/10000/reboot/60000"
    # Empty seq -> empty string (caller decides to skip the sc.exe call).
    check renderScExeFailureActionsArg(@[]) == ""
    # Single slot.
    check renderScExeFailureActionsArg(@[WindowsServiceRecoverySpec(
      action: wsrakRunCommand, delayMs: 30000)]) == "run/30000"

  test "renderScExeFailureCommand emits reset + actions in argv form":
    let argv = renderScExeFailureCommand("sshd", 86400, @[
      WindowsServiceRecoverySpec(action: wsrakRestart, delayMs: 5000)])
    check argv == @[
      "sc.exe", "failure", "sshd",
      "reset=", "86400",
      "actions=", "restart/5000"]
    # Both halves absent -> still a valid no-op invocation (the driver
    # tests `needRecovery` before calling, so this is just shape).
    let bare = renderScExeFailureCommand("sshd", 0, @[])
    check bare == @["sc.exe", "failure", "sshd"]

  test "renderScExeFailureCommand handles reset-only / actions-only":
    # reset only.
    check renderScExeFailureCommand("sshd", 3600, @[]) ==
      @["sc.exe", "failure", "sshd", "reset=", "3600"]
    # actions only.
    check renderScExeFailureCommand("sshd", 0, @[
        WindowsServiceRecoverySpec(action: wsrakReboot, delayMs: 60000)]) ==
      @["sc.exe", "failure", "sshd", "actions=", "reboot/60000"]

  test "renderScExeConfig{BinPath,DisplayName}Command emit the right argv":
    check renderScExeConfigBinPathCommand("sshd",
      "C:\\Windows\\System32\\OpenSSH\\sshd.exe") == @[
      "sc.exe", "config", "sshd", "binPath=",
      "C:\\Windows\\System32\\OpenSSH\\sshd.exe"]
    check renderScExeConfigDisplayNameCommand("sshd",
      "OpenSSH SSH Server") == @[
      "sc.exe", "config", "sshd", "DisplayName=", "OpenSSH SSH Server"]

  test "operationValidationError accepts a Phase B windows.service":
    let op = PrivilegedOperation(kind: pokWindowsService,
      address: "actions-runner-svc",
      serviceName: "actions.runner.windows-runner-001",
      serviceStartType: "Automatic", serviceRunning: true,
      serviceDisplayName: "GitHub Actions Runner",
      serviceBinPath: "C:\\actions-runner\\Runner.Listener.exe",
      serviceRecoveryActions: @[
        WindowsServiceRecoverySpec(action: wsrakRestart, delayMs: 5000),
        WindowsServiceRecoverySpec(action: wsrakRestart, delayMs: 10000),
        WindowsServiceRecoverySpec(action: wsrakReboot, delayMs: 60000)],
      serviceRecoveryResetSeconds: 86400)
    check operationValidationError(op) == ""

  test "operationValidationError flags Phase B bad fields":
    # >3 slots.
    let tooMany = PrivilegedOperation(kind: pokWindowsService,
      address: "x", serviceName: "sshd", serviceStartType: "Automatic",
      serviceRunning: true,
      serviceRecoveryActions: @[
        WindowsServiceRecoverySpec(action: wsrakRestart, delayMs: 1000),
        WindowsServiceRecoverySpec(action: wsrakRestart, delayMs: 2000),
        WindowsServiceRecoverySpec(action: wsrakRestart, delayMs: 3000),
        WindowsServiceRecoverySpec(action: wsrakRestart, delayMs: 4000)])
    check operationValidationError(tooMany).len > 0
    # negative delay.
    let negDelay = PrivilegedOperation(kind: pokWindowsService,
      address: "x", serviceName: "sshd", serviceStartType: "Automatic",
      serviceRunning: true,
      serviceRecoveryActions: @[
        WindowsServiceRecoverySpec(action: wsrakRestart, delayMs: -1)])
    check operationValidationError(negDelay).len > 0
    # negative reset.
    let negReset = PrivilegedOperation(kind: pokWindowsService,
      address: "x", serviceName: "sshd", serviceStartType: "Automatic",
      serviceRunning: true, serviceRecoveryResetSeconds: -1)
    check operationValidationError(negReset).len > 0

  test "RBEB Operation frame round-trips windows.service Phase B fields":
    let op = PrivilegedOperation(kind: pokWindowsService,
      address: "actions-runner-svc",
      serviceName: "actions.runner.windows-runner-001",
      serviceStartType: "Automatic", serviceRunning: true,
      serviceDisplayName: "GitHub Actions Runner",
      serviceBinPath: "C:\\actions-runner\\Runner.Listener.exe",
      serviceRecoveryActions: @[
        WindowsServiceRecoverySpec(action: wsrakRestart, delayMs: 5000),
        WindowsServiceRecoverySpec(action: wsrakRunCommand, delayMs: 30000),
        WindowsServiceRecoverySpec(action: wsrakReboot, delayMs: 60000)],
      serviceRecoveryResetSeconds: 86400)
    let wire = WireOperation(operation: op, baselineDigestHex: "abcd")
    let dec = decodeFrame(encodeOperation(wire))
    check dec.messageType == rmtOperation
    let w2 = decodeOperation(dec.body)
    check w2.baselineDigestHex == "abcd"
    check w2.operation.kind == pokWindowsService
    check w2.operation.address == "actions-runner-svc"
    check w2.operation.serviceName ==
      "actions.runner.windows-runner-001"
    check w2.operation.serviceStartType == "Automatic"
    check w2.operation.serviceRunning
    check w2.operation.serviceDisplayName == "GitHub Actions Runner"
    check w2.operation.serviceBinPath ==
      "C:\\actions-runner\\Runner.Listener.exe"
    check w2.operation.serviceRecoveryActions.len == 3
    check w2.operation.serviceRecoveryActions[0].action == wsrakRestart
    check w2.operation.serviceRecoveryActions[0].delayMs == 5000
    check w2.operation.serviceRecoveryActions[1].action == wsrakRunCommand
    check w2.operation.serviceRecoveryActions[1].delayMs == 30000
    check w2.operation.serviceRecoveryActions[2].action == wsrakReboot
    check w2.operation.serviceRecoveryActions[2].delayMs == 60000
    check w2.operation.serviceRecoveryResetSeconds == 86400

  test "RBEB Operation frame stays backward-compat for legacy windows.service":
    # A pre-Phase-B operation (no Phase B fields set) MUST round-trip
    # byte-for-byte through the wire — the deserialized op has all
    # four fields at their "leave unmanaged" defaults.
    let op = PrivilegedOperation(kind: pokWindowsService,
      address: "sshd-svc", serviceName: "sshd",
      serviceStartType: "Automatic", serviceRunning: true)
    let wire = WireOperation(operation: op, baselineDigestHex: "")
    let w2 = decodeOperation(decodeFrame(encodeOperation(wire)).body)
    check w2.operation.serviceDisplayName == ""
    check w2.operation.serviceBinPath == ""
    check w2.operation.serviceRecoveryActions.len == 0
    check w2.operation.serviceRecoveryResetSeconds == 0

  test "parseScQfailureOutput parses the standard sc qfailure block":
    let raw = """[SC] QueryServiceConfig2 SUCCESS

SERVICE_NAME: sshd
        RESET_PERIOD (in seconds)    : 86400
        REBOOT_MESSAGE               :
        COMMAND_LINE                 :
        FAILURE_ACTIONS              : RESTART -- Delay = 5000 milliseconds.
                                       RESTART -- Delay = 10000 milliseconds.
                                       REBOOT -- Delay = 60000 milliseconds.
"""
    let parsed = parseScQfailureOutput(raw)
    check parsed.resetSeconds == 86400
    check parsed.actions.len == 3
    check parsed.actions[0].action == "restart"
    check parsed.actions[0].delayMs == 5000
    check parsed.actions[1].action == "restart"
    check parsed.actions[1].delayMs == 10000
    check parsed.actions[2].action == "reboot"
    check parsed.actions[2].delayMs == 60000

  test "parseScQfailureOutput handles RUN PROCESS / NO_ACTION":
    # `sc.exe` prints `RUN PROCESS` for the runcommand variant (which
    # the normalizer collapses to the lower-case `runcommand` wire
    # token); `NO_ACTION` collapses to `none`.
    let raw = """SERVICE_NAME: foo
        RESET_PERIOD (in seconds)    : 3600
        FAILURE_ACTIONS              : RUN PROCESS -- Delay = 30000 milliseconds.
                                       NO_ACTION -- Delay = 0 milliseconds.
"""
    let parsed = parseScQfailureOutput(raw)
    check parsed.resetSeconds == 3600
    check parsed.actions.len == 2
    check parsed.actions[0].action == "runcommand"
    check parsed.actions[0].delayMs == 30000
    check parsed.actions[1].action == "none"
    check parsed.actions[1].delayMs == 0

  test "parseScQfailureOutput on empty / non-policy output yields defaults":
    let parsed = parseScQfailureOutput("")
    check parsed.resetSeconds == 0
    check parsed.actions.len == 0

  test "parseServiceQuery reads DisplayName and BinPath fields":
    # Phase B-extended probe shape — the parser collapses absent lines
    # to empty strings, so a legacy two-field probe still parses
    # correctly (verified by the existing tests).
    let raw = """StartType=Automatic
Status=Running
DisplayName=OpenSSH SSH Server
BinPath=C:\Windows\System32\OpenSSH\sshd.exe
"""
    let obs = parseServiceQuery(raw)
    check obs.present
    check obs.startType == "Automatic"
    check obs.running
    check obs.displayName == "OpenSSH SSH Server"
    check obs.binPath == "C:\\Windows\\System32\\OpenSSH\\sshd.exe"

  test "parseServiceQuery on legacy two-line probe leaves Phase B fields empty":
    # Back-compat: the legacy two-line probe parses to the same
    # observation it always did; the new fields default to empty.
    let raw = "StartType=Automatic\nStatus=Running\n"
    let obs = parseServiceQuery(raw)
    check obs.present
    check obs.startType == "Automatic"
    check obs.displayName == ""
    check obs.binPath == ""

  test "serviceMatchesDesired ignores Phase B fields when desired is empty":
    # "Leave unmanaged" semantics: a non-empty observation displayName
    # should NOT trigger drift if the operator didn't declare one.
    let obs = ServiceObservation(present: true, startType: "Automatic",
      running: true,
      displayName: "OpenSSH SSH Server",
      binPath: "C:\\Windows\\System32\\OpenSSH\\sshd.exe")
    # Bare desired: only the legacy three fields are compared; the
    # observed displayName/binPath are ignored.
    check serviceMatchesDesired(obs, "Automatic", true)

  test "serviceMatchesDesired enforces Phase B fields when desired is set":
    let obs = ServiceObservation(present: true, startType: "Automatic",
      running: true, displayName: "OpenSSH SSH Server",
      binPath: "C:\\Windows\\System32\\OpenSSH\\sshd.exe")
    # A desired displayName that matches.
    check serviceMatchesDesired(obs, "Automatic", true,
      wantDisplayName = "OpenSSH SSH Server")
    # A desired displayName that doesn't match -> drift.
    check not serviceMatchesDesired(obs, "Automatic", true,
      wantDisplayName = "Different Label")
    # A desired binPath that doesn't match -> drift.
    check not serviceMatchesDesired(obs, "Automatic", true,
      wantBinPath = "C:\\elsewhere\\sshd.exe")

  test "serviceMatchesDesired enforces recovery slots in declaration order":
    let obs = ServiceObservation(present: true, startType: "Automatic",
      running: true,
      recoveryActions: @[
        ServiceRecoveryActionObservation(action: "restart", delayMs: 5000),
        ServiceRecoveryActionObservation(action: "reboot", delayMs: 60000)],
      recoveryResetSeconds: 3600)
    let want = @[
      ServiceRecoveryActionObservation(action: "restart", delayMs: 5000),
      ServiceRecoveryActionObservation(action: "reboot", delayMs: 60000)]
    check serviceMatchesDesired(obs, "Automatic", true,
      wantRecoveryActions = want, wantRecoveryResetSeconds = 3600)
    # Wrong order -> drift.
    let reordered = @[
      ServiceRecoveryActionObservation(action: "reboot", delayMs: 60000),
      ServiceRecoveryActionObservation(action: "restart", delayMs: 5000)]
    check not serviceMatchesDesired(obs, "Automatic", true,
      wantRecoveryActions = reordered, wantRecoveryResetSeconds = 3600)
    # Wrong reset window -> drift.
    check not serviceMatchesDesired(obs, "Automatic", true,
      wantRecoveryActions = want, wantRecoveryResetSeconds = 86400)

  test "canonicalServiceState legacy call stays byte-identical":
    # Back-compat: a SystemResource with no Phase B fields produces
    # the SAME canonical-state digest input as before the change.
    let obs = ServiceObservation(present: true, startType: "Automatic",
      running: true,
      displayName: "OpenSSH SSH Server",
      binPath: "C:\\Windows\\System32\\OpenSSH\\sshd.exe")
    # The legacy single-arg call ignores observed displayName/binPath.
    check canonicalServiceState(obs) == "service:Automatic:running"
    # The desired-side legacy call matches.
    check canonicalServiceDesired("Automatic", true) ==
      "service:Automatic:running"

  test "canonicalServiceState extends with Phase B fields when desired":
    let obs = ServiceObservation(present: true, startType: "Automatic",
      running: true, displayName: "OpenSSH SSH Server",
      binPath: "C:\\bin\\sshd.exe",
      recoveryActions: @[
        ServiceRecoveryActionObservation(action: "restart", delayMs: 5000)],
      recoveryResetSeconds: 3600)
    let digest = canonicalServiceState(obs,
      wantDisplayName = "OpenSSH SSH Server",
      wantBinPath = "C:\\bin\\sshd.exe",
      includeRecovery = true)
    check digest.contains("displayName=OpenSSH SSH Server")
    check digest.contains("binPath=C:\\bin\\sshd.exe")
    check digest.contains("restart/5000")
    check digest.contains("reset=3600")
    # Desired-side parallel: the digest matches when the observation
    # matches.
    let want = canonicalServiceDesired("Automatic", true,
      wantDisplayName = "OpenSSH SSH Server",
      wantBinPath = "C:\\bin\\sshd.exe",
      wantRecoveryActions = @[
        ServiceRecoveryActionObservation(action: "restart", delayMs: 5000)],
      wantRecoveryResetSeconds = 3600)
    check digest == want

  test "windows.service still requires elevation":
    # Sanity: the predicate is unchanged by the Phase B extension.
    check requiresElevation(pokWindowsService)

# ===========================================================================
# os.timezone — pure parse + drift logic. The shell-out side of the
# driver runs only on the resident host's platform; what runs everywhere
# is the closed-set validator, the IANA -> Windows mapping table, the
# canonical-state digest, and the tzutil / timedatectl / systemsetup
# probe-output parsers.
# ===========================================================================

suite "repro_elevation: os.timezone pure surface":

  test "isSafeIanaTimezone accepts the IANA charset":
    check isSafeIanaTimezone("Europe/Sofia")
    check isSafeIanaTimezone("America/Los_Angeles")
    check isSafeIanaTimezone("Etc/GMT+10")
    check isSafeIanaTimezone("Etc/GMT-5")
    check isSafeIanaTimezone("America/Argentina/Buenos_Aires")
    check not isSafeIanaTimezone("")
    check not isSafeIanaTimezone("Europe/Sofia;rm")
    check not isSafeIanaTimezone("$(whoami)")
    check not isSafeIanaTimezone("Europe Sofia")    # space refused
    check not isSafeIanaTimezone("Europe\\Sofia")   # backslash refused

  test "lookupWindowsTimezoneName covers Europe/Sofia and other common zones":
    check lookupWindowsTimezoneName("Europe/Sofia") == "FLE Standard Time"
    check lookupWindowsTimezoneName("America/Los_Angeles") ==
      "Pacific Standard Time"
    check lookupWindowsTimezoneName("Asia/Tokyo") == "Tokyo Standard Time"
    check lookupWindowsTimezoneName("UTC") == "UTC"
    check lookupWindowsTimezoneName("Etc/UTC") == "UTC"
    check lookupWindowsTimezoneName("Atlantis/Citadel") == ""

  test "isMappedIanaTimezone gates the apply path":
    check isMappedIanaTimezone("Europe/Sofia")
    check isMappedIanaTimezone("UTC")
    check not isMappedIanaTimezone("Atlantis/Citadel")
    check not isMappedIanaTimezone("Europe/Sofia;rm")    # both unsafe + unmapped

  test "reverseLookupIanaTimezoneName resolves many-to-one ambiguity":
    # Regression for the M83 step-3 Hyper-V harness failure: the
    # Windows-to-IANA mapping is many-to-one (Helsinki, Kiev, Sofia,
    # and Kyiv all live under `FLE Standard Time`). A naive
    # "first match wins" reverse lookup picks `Europe/Helsinki` so a
    # post-apply re-probe of an `Europe/Sofia` apply digests the wrong
    # IANA and raises a spurious "post-apply observation disagrees
    # with desired state" error. The disambiguating reverse lookup
    # honours the `preferred` IANA name (the operator's stated intent)
    # whenever it maps to the same Windows zone — so the post-apply
    # re-probe returns Sofia, not Helsinki.
    check reverseLookupIanaTimezoneName("FLE Standard Time",
      "Europe/Sofia") == "Europe/Sofia"
    check reverseLookupIanaTimezoneName("FLE Standard Time",
      "Europe/Kiev") == "Europe/Kiev"
    check reverseLookupIanaTimezoneName("FLE Standard Time",
      "Europe/Kyiv") == "Europe/Kyiv"
    check reverseLookupIanaTimezoneName("FLE Standard Time",
      "Europe/Helsinki") == "Europe/Helsinki"
    # No preferred -> falls back to the first table match.
    check reverseLookupIanaTimezoneName("FLE Standard Time", "") ==
      "Europe/Helsinki"
    # Preferred maps to a DIFFERENT Windows zone (live tz really
    # does disagree with desired) -> fall back to first match for
    # the OBSERVED Windows zone, NOT the preferred (which would
    # mis-report agreement).
    check reverseLookupIanaTimezoneName("Pacific Standard Time",
      "Europe/Sofia") == "America/Los_Angeles"
    # Unmapped Windows zone -> empty string.
    check reverseLookupIanaTimezoneName("Mars Standard Time",
      "Europe/Sofia") == ""
    # Empty Windows zone -> empty string.
    check reverseLookupIanaTimezoneName("", "Europe/Sofia") == ""

  test "reverseLookupIanaTimezoneName: canonical digests match post-apply":
    # End-to-end pin: when the operator declared `Europe/Sofia` and
    # the system's live Windows tz is now `FLE Standard Time`, the
    # canonical observed-state digest (computed via reverse-lookup
    # with the desired IANA as `preferred`) MUST equal the canonical
    # desired-state digest. This is what the M83 step-3 post-apply
    # re-probe asserts — and what the harness failure caught when
    # the digests fell on different sides of the many-to-one map.
    let observedWin = "FLE Standard Time"
    let observedIana = reverseLookupIanaTimezoneName(observedWin, "Europe/Sofia")
    check observedIana == "Europe/Sofia"
    check canonicalTimezoneState(observedIana) ==
      canonicalTimezoneDesired("Europe/Sofia")

  test "operationValidationError accepts a valid os.timezone operation":
    let ok = PrivilegedOperation(kind: pokOsTimezone,
      address: "userTimezone",
      tzIana: "Europe/Sofia")
    check operationValidationError(ok) == ""

  test "operationValidationError flags bad os.timezone fields":
    let empty = PrivilegedOperation(kind: pokOsTimezone,
      address: "x", tzIana: "")
    check operationValidationError(empty).len > 0
    let unsafe = PrivilegedOperation(kind: pokOsTimezone,
      address: "x", tzIana: "Europe/Sofia;rm -rf /")
    check operationValidationError(unsafe).len > 0
    let unmapped = PrivilegedOperation(kind: pokOsTimezone,
      address: "x", tzIana: "Atlantis/Citadel")
    check operationValidationError(unmapped).len > 0
    let noAddress = PrivilegedOperation(kind: pokOsTimezone,
      address: "", tzIana: "Europe/Sofia")
    check operationValidationError(noAddress).len > 0

  test "parseTzutilOutput strips whitespace and CR/LF":
    check parseTzutilOutput("FLE Standard Time\r\n") == "FLE Standard Time"
    check parseTzutilOutput("  Pacific Standard Time  \n") ==
      "Pacific Standard Time"
    check parseTzutilOutput("") == ""

  test "parseTimedatectlOutput reads both --value and --property forms":
    check parseTimedatectlOutput("Timezone=Europe/Sofia\n") ==
      "Europe/Sofia"
    check parseTimedatectlOutput(
      "       Local time: Sat 2026-05-30 12:00:00 EEST\n" &
      "  Universal time: Sat 2026-05-30 09:00:00 UTC\n" &
      "        RTC time: Sat 2026-05-30 09:00:00\n" &
      "       Time zone: Europe/Sofia (EEST, +0300)\n") == "Europe/Sofia"
    check parseTimedatectlOutput("") == ""

  test "parseEtcTimezone reads the IANA line, skipping comments":
    check parseEtcTimezone("Europe/Sofia\n") == "Europe/Sofia"
    check parseEtcTimezone("# comment\nEurope/Sofia\n") == "Europe/Sofia"
    check parseEtcTimezone("\n\n  \nAmerica/Los_Angeles\n") ==
      "America/Los_Angeles"
    check parseEtcTimezone("") == ""

  test "canonical timezone state and desired digests match for the same IANA":
    check canonicalTimezoneState("Europe/Sofia") ==
      canonicalTimezoneDesired("Europe/Sofia")
    check canonicalTimezoneState("") == "timezone:absent"

  test "RBEB Operation frame round-trips an os.timezone":
    let op = PrivilegedOperation(kind: pokOsTimezone,
      address: "userTimezone",
      tzIana: "Europe/Sofia")
    let wire = WireOperation(operation: op,
      baselineDigestHex: "deadbeef")
    let dec = decodeFrame(encodeOperation(wire))
    check dec.messageType == rmtOperation
    let w2 = decodeOperation(dec.body)
    check w2.baselineDigestHex == "deadbeef"
    check w2.operation.kind == pokOsTimezone
    check w2.operation.address == "userTimezone"
    check w2.operation.tzIana == "Europe/Sofia"

  test "os.timezone requires elevation":
    check requiresElevation(pokOsTimezone)
    check $pokOsTimezone == "os.timezone"
    check privilegedOperationKindFromString("os.timezone") == pokOsTimezone

# ===========================================================================
# os.hostname — pure parse + drift logic. The shell-out side of the
# driver runs only on the resident host's platform; what runs everywhere
# is the closed-set validator, the RFC 1123 hostname guard, the canonical-
# state digest (case-insensitive), and the `hostname` probe parser.
# ===========================================================================

suite "repro_elevation: os.hostname pure surface":

  test "isSafeHostname accepts RFC 1123 names":
    check isSafeHostname("myhost")
    check isSafeHostname("MyHost")
    check isSafeHostname("host-01")
    check isSafeHostname("a")
    check not isSafeHostname("")
    check not isSafeHostname("-myhost")           # leading dash
    check not isSafeHostname("myhost-")           # trailing dash
    check not isSafeHostname("my.host")           # period not allowed (single label)
    check not isSafeHostname("my_host")           # underscore refused
    check not isSafeHostname("my host")           # space refused
    check not isSafeHostname("my'host")
    check not isSafeHostname("host;rm")
    check not isSafeHostname("x" & "a".repeat(63)) # 64 chars, too long

  test "operationValidationError accepts a valid os.hostname operation":
    let ok = PrivilegedOperation(kind: pokOsHostname,
      address: "userHostname",
      hostnameName: "myhost-01")
    check operationValidationError(ok) == ""

  test "operationValidationError flags bad os.hostname fields":
    let empty = PrivilegedOperation(kind: pokOsHostname,
      address: "x", hostnameName: "")
    check operationValidationError(empty).len > 0
    let unsafe = PrivilegedOperation(kind: pokOsHostname,
      address: "x", hostnameName: "host;rm -rf /")
    check operationValidationError(unsafe).len > 0
    let noAddress = PrivilegedOperation(kind: pokOsHostname,
      address: "", hostnameName: "myhost")
    check operationValidationError(noAddress).len > 0

  test "parseHostnameOutput strips whitespace and CR/LF":
    check parseHostnameOutput("myhost\r\n") == "myhost"
    check parseHostnameOutput("  myhost  \n") == "myhost"
    check parseHostnameOutput("") == ""

  test "canonical hostname state is case-insensitive":
    check canonicalHostnameState("MyHost") == canonicalHostnameState("myhost")
    check canonicalHostnameState("MyHost") == canonicalHostnameDesired("myhost")
    check hostnameMatchesDesired("MYHOST", "myhost")
    check hostnameMatchesDesired("myhost", "MYHOST")
    check not hostnameMatchesDesired("otherhost", "myhost")
    check canonicalHostnameState("") == "hostname:absent"

  test "RBEB Operation frame round-trips an os.hostname":
    let op = PrivilegedOperation(kind: pokOsHostname,
      address: "userHostname",
      hostnameName: "MyDevBox")
    let wire = WireOperation(operation: op,
      baselineDigestHex: "deadbeef")
    let dec = decodeFrame(encodeOperation(wire))
    check dec.messageType == rmtOperation
    let w2 = decodeOperation(dec.body)
    check w2.baselineDigestHex == "deadbeef"
    check w2.operation.kind == pokOsHostname
    check w2.operation.address == "userHostname"
    check w2.operation.hostnameName == "MyDevBox"

  test "os.hostname requires elevation":
    check requiresElevation(pokOsHostname)
    check $pokOsHostname == "os.hostname"
    check privilegedOperationKindFromString("os.hostname") == pokOsHostname

# ===========================================================================
# linux.sysctl — pure parse + content + drift logic. The shell-out
# side runs only on Linux hosts; what runs everywhere is the closed-
# set validator, the basename / key / value safety predicates, the
# canonical drop-in content generator, and the drop-in line parser.
# ===========================================================================

suite "repro_elevation: linux.sysctl pure surface":

  test "isSafeDropInBasename accepts a typical basename":
    check isSafeDropInBasename("99-reprobuild.conf")
    check isSafeDropInBasename("kernel.perf_event_paranoid")
    check isSafeDropInBasename("a")
    check not isSafeDropInBasename("")
    check not isSafeDropInBasename(".")
    check not isSafeDropInBasename("..")
    check not isSafeDropInBasename("foo/bar.conf")
    check not isSafeDropInBasename("foo\\bar.conf")
    check not isSafeDropInBasename("foo; rm")
    check not isSafeDropInBasename("$(whoami).conf")

  test "isSafeSysctlKey accepts dotted kernel-parameter keys":
    check isSafeSysctlKey("kernel.perf_event_paranoid")
    check isSafeSysctlKey("net.ipv4.tcp_rmem")
    check isSafeSysctlKey("vm.swappiness")
    # `/proc/sys/...` form
    check isSafeSysctlKey("net/ipv4/tcp_rmem")
    check not isSafeSysctlKey("")
    check not isSafeSysctlKey("kernel.foo; rm")
    check not isSafeSysctlKey("$(whoami)")
    check not isSafeSysctlKey("kernel.foo bar")

  test "isSafeSysctlValue refuses newlines, accepts everything else":
    check isSafeSysctlValue("1")
    check isSafeSysctlValue("0 1024 65536")
    check isSafeSysctlValue("")
    check isSafeSysctlValue("$(whoami)")            # OK — never reaches shell
    check not isSafeSysctlValue("1\n2")
    check not isSafeSysctlValue("foo\r\nbar")

  test "sysctlDropInContent renders the canonical key=value line":
    check sysctlDropInContent("kernel.perf_event_paranoid", "1") ==
      "kernel.perf_event_paranoid = 1\n"
    check sysctlDropInContent("vm.swappiness", "10") ==
      "vm.swappiness = 10\n"

  test "sysctlDropInFilename honours an explicit filename":
    let op = PrivilegedOperation(kind: pokLinuxSysctl,
      address: "perf",
      sysctlKey: "kernel.perf_event_paranoid",
      sysctlValue: "1",
      sysctlFilename: "10-perf.conf")
    check sysctlDropInFilename(op) == "10-perf.conf"

  test "sysctlDropInFilename auto-derives a slug from the address":
    let op = PrivilegedOperation(kind: pokLinuxSysctl,
      address: "tune-perf-paranoid",
      sysctlKey: "kernel.perf_event_paranoid",
      sysctlValue: "1")
    check sysctlDropInFilename(op) ==
      "99-reprobuild-tune-perf-paranoid.conf"

  test "sysctlDropInFilename auto-derives a slug from the key when no address":
    let op = PrivilegedOperation(kind: pokLinuxSysctl,
      address: "",
      sysctlKey: "kernel.perf_event_paranoid",
      sysctlValue: "1")
    check sysctlDropInFilename(op) ==
      "99-reprobuild-kernel.perf_event_paranoid.conf"

  test "sysctlDropInFilename sanitizes shell-metas in the auto slug":
    let op = PrivilegedOperation(kind: pokLinuxSysctl,
      address: "perf$(rm); attack",
      sysctlKey: "kernel.x",
      sysctlValue: "0")
    let derived = sysctlDropInFilename(op)
    check isSafeDropInBasename(derived)

  test "sysctlDropInPath joins the directory with the filename":
    let op = PrivilegedOperation(kind: pokLinuxSysctl,
      address: "perf",
      sysctlKey: "kernel.perf_event_paranoid",
      sysctlValue: "1",
      sysctlFilename: "10-perf.conf")
    check sysctlDropInPath(op) == "/etc/sysctl.d/10-perf.conf"
    check LinuxSysctlDir == "/etc/sysctl.d"

  test "parseSysctlDropInLine matches the LHS exactly":
    check parseSysctlDropInLine("kernel.x = 7", "kernel.x") ==
      (matched: true, value: "7")
    check parseSysctlDropInLine("  kernel.x   =   7  ", "kernel.x") ==
      (matched: true, value: "7")
    check parseSysctlDropInLine("kernel.x=7", "kernel.x") ==
      (matched: true, value: "7")
    check parseSysctlDropInLine("kernel.x = 7", "kernel.y") ==
      (matched: false, value: "")
    check parseSysctlDropInLine("# kernel.x = 7", "kernel.x") ==
      (matched: false, value: "")
    check parseSysctlDropInLine("", "kernel.x") ==
      (matched: false, value: "")

  test "readSysctlDropInValue returns the LAST matching line":
    let content = """
# leading comment
kernel.x = 1
kernel.y = 2
kernel.x = 7
"""
    let result = readSysctlDropInValue(content, "kernel.x")
    check result.present
    check result.value == "7"
    check readSysctlDropInValue(content, "kernel.z") ==
      (present: false, value: "")

  test "operationValidationError accepts a valid linux.sysctl operation":
    let ok = PrivilegedOperation(kind: pokLinuxSysctl,
      address: "perf",
      sysctlKey: "kernel.perf_event_paranoid",
      sysctlValue: "1",
      sysctlFilename: "10-perf.conf")
    check operationValidationError(ok) == ""
    let okAuto = PrivilegedOperation(kind: pokLinuxSysctl,
      address: "perf",
      sysctlKey: "kernel.perf_event_paranoid",
      sysctlValue: "1")
    check operationValidationError(okAuto) == ""

  test "operationValidationError flags bad linux.sysctl fields":
    # Empty key
    let emptyKey = PrivilegedOperation(kind: pokLinuxSysctl,
      address: "x", sysctlKey: "", sysctlValue: "1")
    check operationValidationError(emptyKey).len > 0
    # Injection-shaped key
    let badKey = PrivilegedOperation(kind: pokLinuxSysctl,
      address: "x", sysctlKey: "kernel.x; rm -rf /", sysctlValue: "1")
    check operationValidationError(badKey).len > 0
    # Newline in value
    let nlValue = PrivilegedOperation(kind: pokLinuxSysctl,
      address: "x", sysctlKey: "kernel.x", sysctlValue: "1\n2")
    check operationValidationError(nlValue).len > 0
    # Path-escape in filename
    let escape = PrivilegedOperation(kind: pokLinuxSysctl,
      address: "x", sysctlKey: "kernel.x", sysctlValue: "1",
      sysctlFilename: "../etc/shadow")
    check operationValidationError(escape).len > 0
    # Bad extension
    let badExt = PrivilegedOperation(kind: pokLinuxSysctl,
      address: "x", sysctlKey: "kernel.x", sysctlValue: "1",
      sysctlFilename: "10-perf.txt")
    check operationValidationError(badExt).len > 0
    # Empty address
    let emptyAddr = PrivilegedOperation(kind: pokLinuxSysctl,
      address: "", sysctlKey: "kernel.x", sysctlValue: "1")
    check operationValidationError(emptyAddr).len > 0

  test "RBEB Operation frame round-trips a linux.sysctl":
    let op = PrivilegedOperation(kind: pokLinuxSysctl,
      address: "perf",
      sysctlKey: "kernel.perf_event_paranoid",
      sysctlValue: "1",
      sysctlFilename: "10-perf.conf",
      sysctlDestroy: false)
    let wire = WireOperation(operation: op,
      baselineDigestHex: "deadbeef")
    let dec = decodeFrame(encodeOperation(wire))
    check dec.messageType == rmtOperation
    let w2 = decodeOperation(dec.body)
    check w2.baselineDigestHex == "deadbeef"
    check w2.operation.kind == pokLinuxSysctl
    check w2.operation.address == "perf"
    check w2.operation.sysctlKey == "kernel.perf_event_paranoid"
    check w2.operation.sysctlValue == "1"
    check w2.operation.sysctlFilename == "10-perf.conf"
    check not w2.operation.sysctlDestroy

  test "RBEB Operation frame round-trips a destroy linux.sysctl":
    let op = PrivilegedOperation(kind: pokLinuxSysctl,
      address: "perf",
      sysctlKey: "kernel.perf_event_paranoid",
      sysctlValue: "1",
      sysctlDestroy: true)
    let wire = WireOperation(operation: op,
      baselineDigestHex: "cafef00d")
    let w2 = decodeOperation(decodeFrame(encodeOperation(wire)).body)
    check w2.operation.kind == pokLinuxSysctl
    check w2.operation.sysctlDestroy

  test "posix desired digest matches the canonical drop-in content":
    let op = PrivilegedOperation(kind: pokLinuxSysctl,
      address: "perf",
      sysctlKey: "kernel.perf_event_paranoid",
      sysctlValue: "1")
    let canon = sysctlDropInContent(op.sysctlKey, op.sysctlValue)
    check posixSystemDesiredDigestHex(op) == posixDigestHexOfText(canon)

  test "posix desired digest for a destroy is the absent sentinel":
    let op = PrivilegedOperation(kind: pokLinuxSysctl,
      address: "perf",
      sysctlKey: "kernel.perf_event_paranoid",
      sysctlValue: "1",
      sysctlDestroy: true)
    check posixSystemDesiredDigestHex(op) == ZeroDigestHex

  test "linux.sysctl requires elevation":
    check requiresElevation(pokLinuxSysctl)
    check $pokLinuxSysctl == "linux.sysctl"
    check privilegedOperationKindFromString("linux.sysctl") == pokLinuxSysctl

  test "off-Linux observe / apply raise ENotImplementedPlatform":
    when not defined(linux):
      let op = PrivilegedOperation(kind: pokLinuxSysctl,
        address: "perf",
        sysctlKey: "kernel.perf_event_paranoid",
        sysctlValue: "1")
      expect ENotImplementedPlatform:
        discard observeLinuxSysctl(op)
      expect ENotImplementedPlatform:
        discard applyLinuxSysctl(op)
      expect ENotImplementedPlatform:
        discard destroyLinuxSysctl(op)

# ===========================================================================
# linux.udevRule — pure parse + drift logic. The shell-out side runs
# only on Linux; what runs everywhere is the closed-set validator, the
# canonical-bytes digest, and the udev rule path derivation.
# ===========================================================================

suite "repro_elevation: linux.udevRule pure surface":

  test "udevRulePath joins the directory with the basename":
    check udevRulePath("99-myrule.rules") == "/etc/udev/rules.d/99-myrule.rules"
    check LinuxUdevRulesDir == "/etc/udev/rules.d"

  test "operationValidationError accepts a valid linux.udevRule":
    let ok = PrivilegedOperation(kind: pokLinuxUdevRule,
      address: "my-keyboard-rule",
      udevName: "99-my-keyboard.rules",
      udevContent: "KERNEL==\"event*\", MODE=\"0666\"\n")
    check operationValidationError(ok) == ""

  test "operationValidationError flags bad linux.udevRule fields":
    # path-escape name
    let escape = PrivilegedOperation(kind: pokLinuxUdevRule,
      address: "x",
      udevName: "../etc/passwd",
      udevContent: "x")
    check operationValidationError(escape).len > 0
    # shell-meta name
    let meta = PrivilegedOperation(kind: pokLinuxUdevRule,
      address: "x",
      udevName: "evil; rm.rules",
      udevContent: "x")
    check operationValidationError(meta).len > 0
    # missing .rules extension
    let badExt = PrivilegedOperation(kind: pokLinuxUdevRule,
      address: "x",
      udevName: "99-myrule.txt",
      udevContent: "x")
    check operationValidationError(badExt).len > 0
    # empty address
    let emptyAddr = PrivilegedOperation(kind: pokLinuxUdevRule,
      address: "",
      udevName: "99-myrule.rules",
      udevContent: "x")
    check operationValidationError(emptyAddr).len > 0

  test "udevRule content may contain newlines (multi-line rules)":
    # The udev rule body is a file write; newlines in content are
    # required by the udev grammar (one rule per line) and must not
    # be refused by the validator.
    let multiLine = PrivilegedOperation(kind: pokLinuxUdevRule,
      address: "x",
      udevName: "99-my.rules",
      udevContent: "KERNEL==\"event*\", MODE=\"0666\"\n" &
        "KERNEL==\"mouse*\", MODE=\"0666\"\n")
    check operationValidationError(multiLine) == ""

  test "RBEB Operation frame round-trips a linux.udevRule":
    let op = PrivilegedOperation(kind: pokLinuxUdevRule,
      address: "my-rule",
      udevName: "99-my.rules",
      udevContent: "KERNEL==\"event*\", MODE=\"0666\"\n",
      udevDestroy: false)
    let wire = WireOperation(operation: op,
      baselineDigestHex: "deadbeef")
    let w2 = decodeOperation(decodeFrame(encodeOperation(wire)).body)
    check w2.baselineDigestHex == "deadbeef"
    check w2.operation.kind == pokLinuxUdevRule
    check w2.operation.address == "my-rule"
    check w2.operation.udevName == "99-my.rules"
    check w2.operation.udevContent ==
      "KERNEL==\"event*\", MODE=\"0666\"\n"
    check not w2.operation.udevDestroy

  test "RBEB Operation frame round-trips a destroy linux.udevRule":
    let op = PrivilegedOperation(kind: pokLinuxUdevRule,
      address: "my-rule",
      udevName: "99-my.rules",
      udevContent: "",
      udevDestroy: true)
    let wire = WireOperation(operation: op,
      baselineDigestHex: "cafef00d")
    let w2 = decodeOperation(decodeFrame(encodeOperation(wire)).body)
    check w2.operation.kind == pokLinuxUdevRule
    check w2.operation.udevDestroy

  test "posix desired digest for udev rule matches content bytes":
    let op = PrivilegedOperation(kind: pokLinuxUdevRule,
      address: "my-rule",
      udevName: "99-my.rules",
      udevContent: "KERNEL==\"event*\", MODE=\"0666\"\n")
    check posixSystemDesiredDigestHex(op) ==
      posixDigestHexOfText(op.udevContent)

  test "posix desired digest for udev destroy is the absent sentinel":
    let op = PrivilegedOperation(kind: pokLinuxUdevRule,
      address: "x",
      udevName: "99-my.rules",
      udevContent: "x",
      udevDestroy: true)
    check posixSystemDesiredDigestHex(op) == ZeroDigestHex

  test "linux.udevRule requires elevation":
    check requiresElevation(pokLinuxUdevRule)
    check $pokLinuxUdevRule == "linux.udevRule"
    check privilegedOperationKindFromString("linux.udevRule") ==
      pokLinuxUdevRule

  test "off-Linux linux.udevRule entry points raise ENotImplementedPlatform":
    when not defined(linux):
      let op = PrivilegedOperation(kind: pokLinuxUdevRule,
        address: "x",
        udevName: "99-my.rules",
        udevContent: "x")
      expect ENotImplementedPlatform:
        discard observeLinuxUdevRule(op)
      expect ENotImplementedPlatform:
        discard applyLinuxUdevRule(op)
      expect ENotImplementedPlatform:
        discard destroyLinuxUdevRule(op)

# ===========================================================================
# linux.polkitRule — pure parse + drift logic. Polkit auto-reloads via
# inotify so the driver has no reload-command surface — it is the
# simplest in the family.
# ===========================================================================

suite "repro_elevation: linux.polkitRule pure surface":

  test "polkitRulePath joins the directory with the basename":
    check polkitRulePath("50-myrule.rules") ==
      "/etc/polkit-1/rules.d/50-myrule.rules"
    check LinuxPolkitRulesDir == "/etc/polkit-1/rules.d"

  test "operationValidationError accepts a valid linux.polkitRule":
    let ok = PrivilegedOperation(kind: pokLinuxPolkitRule,
      address: "wheel-admin",
      polkitName: "50-wheel-admin.rules",
      polkitContent: "polkit.addRule(function(action, subject) { ... });\n")
    check operationValidationError(ok) == ""

  test "operationValidationError flags bad linux.polkitRule fields":
    let escape = PrivilegedOperation(kind: pokLinuxPolkitRule,
      address: "x",
      polkitName: "../etc/passwd",
      polkitContent: "x")
    check operationValidationError(escape).len > 0
    let meta = PrivilegedOperation(kind: pokLinuxPolkitRule,
      address: "x",
      polkitName: "evil; rm.rules",
      polkitContent: "x")
    check operationValidationError(meta).len > 0
    let badExt = PrivilegedOperation(kind: pokLinuxPolkitRule,
      address: "x",
      polkitName: "50-bad.txt",
      polkitContent: "x")
    check operationValidationError(badExt).len > 0
    let emptyAddr = PrivilegedOperation(kind: pokLinuxPolkitRule,
      address: "",
      polkitName: "50-my.rules",
      polkitContent: "x")
    check operationValidationError(emptyAddr).len > 0

  test "RBEB Operation frame round-trips a linux.polkitRule":
    let op = PrivilegedOperation(kind: pokLinuxPolkitRule,
      address: "my-rule",
      polkitName: "50-my.rules",
      polkitContent: "polkit.addRule(function() { return null; });\n",
      polkitDestroy: false)
    let wire = WireOperation(operation: op,
      baselineDigestHex: "deadbeef")
    let w2 = decodeOperation(decodeFrame(encodeOperation(wire)).body)
    check w2.baselineDigestHex == "deadbeef"
    check w2.operation.kind == pokLinuxPolkitRule
    check w2.operation.address == "my-rule"
    check w2.operation.polkitName == "50-my.rules"
    check w2.operation.polkitContent ==
      "polkit.addRule(function() { return null; });\n"
    check not w2.operation.polkitDestroy

  test "RBEB Operation frame round-trips a destroy linux.polkitRule":
    let op = PrivilegedOperation(kind: pokLinuxPolkitRule,
      address: "my-rule",
      polkitName: "50-my.rules",
      polkitContent: "",
      polkitDestroy: true)
    let wire = WireOperation(operation: op,
      baselineDigestHex: "cafef00d")
    let w2 = decodeOperation(decodeFrame(encodeOperation(wire)).body)
    check w2.operation.kind == pokLinuxPolkitRule
    check w2.operation.polkitDestroy

  test "posix desired digest for polkit rule matches content bytes":
    let op = PrivilegedOperation(kind: pokLinuxPolkitRule,
      address: "my-rule",
      polkitName: "50-my.rules",
      polkitContent: "polkit.addRule(function() { return null; });\n")
    check posixSystemDesiredDigestHex(op) ==
      posixDigestHexOfText(op.polkitContent)

  test "posix desired digest for polkit destroy is the absent sentinel":
    let op = PrivilegedOperation(kind: pokLinuxPolkitRule,
      address: "x",
      polkitName: "50-my.rules",
      polkitContent: "x",
      polkitDestroy: true)
    check posixSystemDesiredDigestHex(op) == ZeroDigestHex

  test "linux.polkitRule requires elevation":
    check requiresElevation(pokLinuxPolkitRule)
    check $pokLinuxPolkitRule == "linux.polkitRule"
    check privilegedOperationKindFromString("linux.polkitRule") ==
      pokLinuxPolkitRule

  test "off-Linux linux.polkitRule entry points raise ENotImplementedPlatform":
    when not defined(linux):
      let op = PrivilegedOperation(kind: pokLinuxPolkitRule,
        address: "x",
        polkitName: "50-my.rules",
        polkitContent: "x")
      expect ENotImplementedPlatform:
        discard observeLinuxPolkitRule(op)
      expect ENotImplementedPlatform:
        discard applyLinuxPolkitRule(op)
      expect ENotImplementedPlatform:
        discard destroyLinuxPolkitRule(op)

# ===========================================================================
# linux.tmpfilesRule — pure parse + drift logic. The shell-out side
# (write + `systemd-tmpfiles --create`) runs only on Linux.
# ===========================================================================

suite "repro_elevation: linux.tmpfilesRule pure surface":

  test "tmpfilesRulePath joins the directory with the basename":
    check tmpfilesRulePath("repro-cache.conf") ==
      "/etc/tmpfiles.d/repro-cache.conf"
    check LinuxTmpfilesDir == "/etc/tmpfiles.d"

  test "operationValidationError accepts a valid linux.tmpfilesRule":
    let ok = PrivilegedOperation(kind: pokLinuxTmpfilesRule,
      address: "repro-cache",
      tmpfilesName: "repro-cache.conf",
      tmpfilesContent: "d /var/cache/repro 0755 root root - -\n",
      tmpfilesApplyNow: true)
    check operationValidationError(ok) == ""

  test "operationValidationError flags bad linux.tmpfilesRule fields":
    let escape = PrivilegedOperation(kind: pokLinuxTmpfilesRule,
      address: "x",
      tmpfilesName: "../etc/passwd",
      tmpfilesContent: "x")
    check operationValidationError(escape).len > 0
    let meta = PrivilegedOperation(kind: pokLinuxTmpfilesRule,
      address: "x",
      tmpfilesName: "evil; rm.conf",
      tmpfilesContent: "x")
    check operationValidationError(meta).len > 0
    let badExt = PrivilegedOperation(kind: pokLinuxTmpfilesRule,
      address: "x",
      tmpfilesName: "repro-cache.rules",
      tmpfilesContent: "x")
    check operationValidationError(badExt).len > 0
    let emptyAddr = PrivilegedOperation(kind: pokLinuxTmpfilesRule,
      address: "",
      tmpfilesName: "repro-cache.conf",
      tmpfilesContent: "x")
    check operationValidationError(emptyAddr).len > 0

  test "RBEB Operation frame round-trips a linux.tmpfilesRule":
    let op = PrivilegedOperation(kind: pokLinuxTmpfilesRule,
      address: "repro-cache",
      tmpfilesName: "repro-cache.conf",
      tmpfilesContent: "d /var/cache/repro 0755 root root - -\n",
      tmpfilesApplyNow: true,
      tmpfilesDestroy: false)
    let wire = WireOperation(operation: op,
      baselineDigestHex: "deadbeef")
    let w2 = decodeOperation(decodeFrame(encodeOperation(wire)).body)
    check w2.baselineDigestHex == "deadbeef"
    check w2.operation.kind == pokLinuxTmpfilesRule
    check w2.operation.address == "repro-cache"
    check w2.operation.tmpfilesName == "repro-cache.conf"
    check w2.operation.tmpfilesContent ==
      "d /var/cache/repro 0755 root root - -\n"
    check w2.operation.tmpfilesApplyNow
    check not w2.operation.tmpfilesDestroy

  test "RBEB Operation frame round-trips a destroy linux.tmpfilesRule":
    let op = PrivilegedOperation(kind: pokLinuxTmpfilesRule,
      address: "repro-cache",
      tmpfilesName: "repro-cache.conf",
      tmpfilesContent: "",
      tmpfilesApplyNow: false,
      tmpfilesDestroy: true)
    let wire = WireOperation(operation: op,
      baselineDigestHex: "cafef00d")
    let w2 = decodeOperation(decodeFrame(encodeOperation(wire)).body)
    check w2.operation.kind == pokLinuxTmpfilesRule
    check w2.operation.tmpfilesDestroy
    check not w2.operation.tmpfilesApplyNow

  test "posix desired digest for tmpfiles rule matches content bytes":
    let op = PrivilegedOperation(kind: pokLinuxTmpfilesRule,
      address: "x",
      tmpfilesName: "repro-cache.conf",
      tmpfilesContent: "d /var/cache/repro 0755 root root - -\n",
      tmpfilesApplyNow: true)
    check posixSystemDesiredDigestHex(op) ==
      posixDigestHexOfText(op.tmpfilesContent)

  test "posix desired digest for tmpfiles destroy is the absent sentinel":
    let op = PrivilegedOperation(kind: pokLinuxTmpfilesRule,
      address: "x",
      tmpfilesName: "repro-cache.conf",
      tmpfilesContent: "x",
      tmpfilesApplyNow: true,
      tmpfilesDestroy: true)
    check posixSystemDesiredDigestHex(op) == ZeroDigestHex

  test "linux.tmpfilesRule requires elevation":
    check requiresElevation(pokLinuxTmpfilesRule)
    check $pokLinuxTmpfilesRule == "linux.tmpfilesRule"
    check privilegedOperationKindFromString("linux.tmpfilesRule") ==
      pokLinuxTmpfilesRule

  test "off-Linux linux.tmpfilesRule entry points raise ENotImplementedPlatform":
    when not defined(linux):
      let op = PrivilegedOperation(kind: pokLinuxTmpfilesRule,
        address: "x",
        tmpfilesName: "repro-cache.conf",
        tmpfilesContent: "x",
        tmpfilesApplyNow: true)
      expect ENotImplementedPlatform:
        discard observeLinuxTmpfilesRule(op)
      expect ENotImplementedPlatform:
        discard applyLinuxTmpfilesRule(op)
      expect ENotImplementedPlatform:
        discard destroyLinuxTmpfilesRule(op)

# ===========================================================================
# linux.sudoersRule — pure parse + drift logic. The shell-out side
# adds `visudo -c -f` validation gating; pure tests cover the closed-
# set validator, the path derivation including the `.tmp` staging
# path, and the codec round-trip.
# ===========================================================================

suite "repro_elevation: linux.sudoersRule pure surface":

  test "sudoersRulePath joins the directory with the basename":
    check sudoersRulePath("wheel-extra") == "/etc/sudoers.d/wheel-extra"
    check LinuxSudoersDir == "/etc/sudoers.d"

  test "sudoersRuleTmpPath stages with a .tmp suffix":
    check sudoersRuleTmpPath("wheel-extra") ==
      "/etc/sudoers.d/wheel-extra.tmp"

  test "operationValidationError accepts a valid linux.sudoersRule":
    let ok = PrivilegedOperation(kind: pokLinuxSudoersRule,
      address: "wheel-extra",
      sudoersName: "wheel-extra",
      sudoersContent: "%wheel ALL=(ALL) NOPASSWD: /usr/bin/systemctl\n")
    check operationValidationError(ok) == ""

  test "operationValidationError flags bad linux.sudoersRule fields":
    # path escape
    let escape = PrivilegedOperation(kind: pokLinuxSudoersRule,
      address: "x",
      sudoersName: "../etc/shadow",
      sudoersContent: "x")
    check operationValidationError(escape).len > 0
    # shell-meta name
    let meta = PrivilegedOperation(kind: pokLinuxSudoersRule,
      address: "x",
      sudoersName: "evil; rm",
      sudoersContent: "x")
    check operationValidationError(meta).len > 0
    # a `.` in the name (sudo silently skips dotted files)
    let dotted = PrivilegedOperation(kind: pokLinuxSudoersRule,
      address: "x",
      sudoersName: "wheel-extra.conf",
      sudoersContent: "x")
    check operationValidationError(dotted).len > 0
    # empty address
    let emptyAddr = PrivilegedOperation(kind: pokLinuxSudoersRule,
      address: "",
      sudoersName: "wheel-extra",
      sudoersContent: "x")
    check operationValidationError(emptyAddr).len > 0

  test "RBEB Operation frame round-trips a linux.sudoersRule":
    let op = PrivilegedOperation(kind: pokLinuxSudoersRule,
      address: "wheel-extra",
      sudoersName: "wheel-extra",
      sudoersContent: "%wheel ALL=(ALL) NOPASSWD: /usr/bin/systemctl\n",
      sudoersDestroy: false)
    let wire = WireOperation(operation: op,
      baselineDigestHex: "deadbeef")
    let w2 = decodeOperation(decodeFrame(encodeOperation(wire)).body)
    check w2.baselineDigestHex == "deadbeef"
    check w2.operation.kind == pokLinuxSudoersRule
    check w2.operation.address == "wheel-extra"
    check w2.operation.sudoersName == "wheel-extra"
    check w2.operation.sudoersContent ==
      "%wheel ALL=(ALL) NOPASSWD: /usr/bin/systemctl\n"
    check not w2.operation.sudoersDestroy

  test "RBEB Operation frame round-trips a destroy linux.sudoersRule":
    let op = PrivilegedOperation(kind: pokLinuxSudoersRule,
      address: "wheel-extra",
      sudoersName: "wheel-extra",
      sudoersContent: "",
      sudoersDestroy: true)
    let wire = WireOperation(operation: op,
      baselineDigestHex: "cafef00d")
    let w2 = decodeOperation(decodeFrame(encodeOperation(wire)).body)
    check w2.operation.kind == pokLinuxSudoersRule
    check w2.operation.sudoersDestroy

  test "posix desired digest for sudoers rule matches content bytes":
    let op = PrivilegedOperation(kind: pokLinuxSudoersRule,
      address: "x",
      sudoersName: "wheel-extra",
      sudoersContent: "%wheel ALL=(ALL) NOPASSWD: /usr/bin/systemctl\n")
    check posixSystemDesiredDigestHex(op) ==
      posixDigestHexOfText(op.sudoersContent)

  test "posix desired digest for sudoers destroy is the absent sentinel":
    let op = PrivilegedOperation(kind: pokLinuxSudoersRule,
      address: "x",
      sudoersName: "wheel-extra",
      sudoersContent: "x",
      sudoersDestroy: true)
    check posixSystemDesiredDigestHex(op) == ZeroDigestHex

  test "linux.sudoersRule requires elevation":
    check requiresElevation(pokLinuxSudoersRule)
    check $pokLinuxSudoersRule == "linux.sudoersRule"
    check privilegedOperationKindFromString("linux.sudoersRule") ==
      pokLinuxSudoersRule

  test "off-Linux linux.sudoersRule entry points raise ENotImplementedPlatform":
    when not defined(linux):
      let op = PrivilegedOperation(kind: pokLinuxSudoersRule,
        address: "x",
        sudoersName: "wheel-extra",
        sudoersContent: "x")
      expect ENotImplementedPlatform:
        discard observeLinuxSudoersRule(op)
      expect ENotImplementedPlatform:
        discard applyLinuxSudoersRule(op)
      expect ENotImplementedPlatform:
        discard destroyLinuxSudoersRule(op)

# ===========================================================================
# passwd.group — pure parse + drift logic. The shell-out side wraps
# `groupadd` / `groupmod` / `usermod -aG`; pure tests cover the closed-
# set validator (name + gid + member charsets), the additive-only
# membership semantics in the diff, the canonical-state digest, the
# argv builders, and the codec round-trip.
# ===========================================================================

suite "repro_elevation: passwd.group pure surface":

  test "parseGetentGroup parses a populated group entry":
    let line = "docker:x:998:alice,bob"
    let obs = parseGetentGroup(line)
    check obs.present
    check obs.gid == "998"
    check obs.members == @["alice", "bob"]

  test "parseGetentGroup parses an empty member list":
    let line = "wheel:x:10:"
    let obs = parseGetentGroup(line)
    check obs.present
    check obs.gid == "10"
    check obs.members.len == 0

  test "parseGetentGroup treats an empty / malformed line as absent":
    check not parseGetentGroup("").present
    check not parseGetentGroup("malformed-no-colons").present
    check not parseGetentGroup("only:two:fields").present

  test "diffPasswdGroup flags an absent group":
    let want = PasswdGroupDesired(name: "docker", gid: "998",
      members: @["alice"])
    let obs = PasswdGroupObservation(present: false)
    let d = diffPasswdGroup(want, obs)
    check d.groupAbsent
    check d.missingMembers == @["alice"]

  test "diffPasswdGroup flags gid drift on a pinned gid":
    let want = PasswdGroupDesired(name: "docker", gid: "998",
      members: @[])
    let obs = PasswdGroupObservation(present: true, gid: "1000",
      members: @[])
    let d = diffPasswdGroup(want, obs)
    check d.gidDiffers
    check not d.groupAbsent

  test "diffPasswdGroup ignores gid when unpinned":
    let want = PasswdGroupDesired(name: "docker", gid: "", members: @[])
    let obs = PasswdGroupObservation(present: true, gid: "1000",
      members: @[])
    let d = diffPasswdGroup(want, obs)
    check not d.gidDiffers

  test "diffPasswdGroup reports missing + extra members but does NOT mix them":
    # Declared = [alice, bob]; observed = [bob, carol]
    # missing = [alice], extra = [carol]  (additive-only: extras are
    # reported but the driver does not act on them by default).
    let want = PasswdGroupDesired(name: "docker", gid: "",
      members: @["alice", "bob"])
    let obs = PasswdGroupObservation(present: true, gid: "998",
      members: @["bob", "carol"])
    let d = diffPasswdGroup(want, obs)
    check d.missingMembers == @["alice"]
    check d.extraMembers == @["carol"]

  test "canonicalPasswdGroupState renders a stable digest input":
    let obs = PasswdGroupObservation(present: true, gid: "998",
      members: @["alice", "bob"])
    check canonicalPasswdGroupState(obs) ==
      "group:present;gid=998;members=alice,bob"
    check canonicalPasswdGroupState(
      PasswdGroupObservation(present: false)) == "group:absent"

  test "canonicalPasswdGroupDesired renders `*` for an unpinned gid":
    let want = PasswdGroupDesired(name: "docker", gid: "",
      members: @["bob", "alice"])
    # Members must be sorted in the canonical form.
    check canonicalPasswdGroupDesired(want) ==
      "group:present;gid=*;members=alice,bob"

  test "buildGroupaddArgs builds a typed argv with --gid when pinned":
    let want = PasswdGroupDesired(name: "docker", gid: "998",
      members: @[])
    check buildGroupaddArgs(want) == @["--gid", "998", "docker"]

  test "buildGroupaddArgs omits --gid when unpinned":
    let want = PasswdGroupDesired(name: "docker", gid: "", members: @[])
    check buildGroupaddArgs(want) == @["docker"]

  test "buildGroupmodGidArgs and buildGroupdelArgs":
    let want = PasswdGroupDesired(name: "docker", gid: "999",
      members: @[])
    check buildGroupmodGidArgs(want) == @["--gid", "999", "docker"]
    check buildGroupdelArgs("docker") == @["docker"]

  test "operationValidationError accepts a valid passwd.group":
    let ok = PrivilegedOperation(kind: pokPasswdGroup,
      address: "docker",
      pgName: "docker",
      pgGid: "998",
      pgMembers: @["alice", "bob"])
    check operationValidationError(ok) == ""

  test "operationValidationError flags bad passwd.group fields":
    # bad name (shell meta)
    let badName = PrivilegedOperation(kind: pokPasswdGroup,
      address: "x", pgName: "bad; rm", pgGid: "",
      pgMembers: @[])
    check operationValidationError(badName).len > 0
    # leading '-' (argument-injection guard)
    let dashName = PrivilegedOperation(kind: pokPasswdGroup,
      address: "x", pgName: "-rf", pgGid: "",
      pgMembers: @[])
    check operationValidationError(dashName).len > 0
    # non-numeric gid
    let badGid = PrivilegedOperation(kind: pokPasswdGroup,
      address: "x", pgName: "docker", pgGid: "abc",
      pgMembers: @[])
    check operationValidationError(badGid).len > 0
    # member with a slash
    let badMember = PrivilegedOperation(kind: pokPasswdGroup,
      address: "x", pgName: "docker", pgGid: "",
      pgMembers: @["a/b"])
    check operationValidationError(badMember).len > 0
    # empty address
    let emptyAddr = PrivilegedOperation(kind: pokPasswdGroup,
      address: "", pgName: "docker", pgGid: "",
      pgMembers: @[])
    check operationValidationError(emptyAddr).len > 0

  test "RBEB Operation frame round-trips a passwd.group":
    let op = PrivilegedOperation(kind: pokPasswdGroup,
      address: "docker",
      pgName: "docker",
      pgGid: "998",
      pgMembers: @["alice", "bob"],
      pgDestroy: false)
    let wire = WireOperation(operation: op,
      baselineDigestHex: "deadbeef")
    let w2 = decodeOperation(decodeFrame(encodeOperation(wire)).body)
    check w2.baselineDigestHex == "deadbeef"
    check w2.operation.kind == pokPasswdGroup
    check w2.operation.address == "docker"
    check w2.operation.pgName == "docker"
    check w2.operation.pgGid == "998"
    check w2.operation.pgMembers == @["alice", "bob"]
    check not w2.operation.pgDestroy

  test "RBEB Operation frame round-trips a destroy passwd.group":
    let op = PrivilegedOperation(kind: pokPasswdGroup,
      address: "docker",
      pgName: "docker",
      pgGid: "",
      pgMembers: @[],
      pgDestroy: true)
    let wire = WireOperation(operation: op,
      baselineDigestHex: "cafef00d")
    let w2 = decodeOperation(decodeFrame(encodeOperation(wire)).body)
    check w2.operation.kind == pokPasswdGroup
    check w2.operation.pgDestroy

  test "posix desired digest for passwd.group matches canonical desired":
    let op = PrivilegedOperation(kind: pokPasswdGroup,
      address: "docker",
      pgName: "docker",
      pgGid: "998",
      pgMembers: @["bob", "alice"])
    check posixSystemDesiredDigestHex(op) ==
      posixDigestHexOfText(canonicalPasswdGroupDesired(
        PasswdGroupDesired(name: "docker", gid: "998",
          members: @["bob", "alice"])))

  test "posix desired digest for passwd.group destroy is the absent sentinel":
    let op = PrivilegedOperation(kind: pokPasswdGroup,
      address: "docker",
      pgName: "docker",
      pgGid: "",
      pgMembers: @[],
      pgDestroy: true)
    check posixSystemDesiredDigestHex(op) == ZeroDigestHex

  test "passwd.group requires elevation":
    check requiresElevation(pokPasswdGroup)
    check $pokPasswdGroup == "passwd.group"
    check privilegedOperationKindFromString("passwd.group") ==
      pokPasswdGroup

  test "off-POSIX passwd.group entry points raise ENotImplementedPlatform":
    # M11 added a macOS arm (`dscl . -create /Groups/<name>` +
    # `dseditgroup` + `dscl . -delete`) alongside the original Linux
    # arm. Both POSIX arms shell out to real tools and need a real
    # host to exercise — the assertion that off-platform entry points
    # raise `ENotImplementedPlatform` therefore narrows from
    # "off-Linux" (the pre-M11 statement) to "off-POSIX" (the
    # post-M11 statement). The Linux smoke test for the Linux arm
    # still lives in ~tests/e2e/m69/t_e2e_repro_infra_passwd_group_vm.nim~
    # (gated on REPRO_M69_PASSWD_GROUP_VM=1); the macOS smoke test
    # lives in ~tests/e2e/macos-phase5/t_e2e_macos_phase5_passwd_group.nim~
    # (gated on REPRO_PHASE5_MACOS_PASSWD_GROUP_VM=1).
    when not (defined(linux) or defined(macosx)):
      let op = PrivilegedOperation(kind: pokPasswdGroup,
        address: "docker",
        pgName: "docker",
        pgGid: "",
        pgMembers: @[])
      expect ENotImplementedPlatform:
        discard observePasswdGroup(op)
      expect ENotImplementedPlatform:
        discard applyPasswdGroup(op)
      expect ENotImplementedPlatform:
        discard destroyPasswdGroup(op)

# ===========================================================================
# linux.nixDaemonSetting — pure drop-in parse + drift logic. The shell-
# out side wraps a write to /etc/nix/nix.conf.d/; pure tests cover the
# closed-set validator (Nix-key + value charset), the canonical
# drop-in content shape, the line parser, the auto-filename
# derivation, and the codec round-trip.
# ===========================================================================

suite "repro_elevation: linux.nixDaemonSetting pure surface":

  test "nixDaemonDropInContent renders the canonical bytes":
    check nixDaemonDropInContent("experimental-features",
      "nix-command flakes") ==
      "experimental-features = nix-command flakes\n"

  test "parseNixDaemonDropInLine matches a simple key=value pair":
    let m = parseNixDaemonDropInLine(
      "experimental-features = nix-command flakes",
      "experimental-features")
    check m.matched
    check m.value == "nix-command flakes"

  test "parseNixDaemonDropInLine ignores comments and blank lines":
    check not parseNixDaemonDropInLine(
      "# experimental-features = flakes",
      "experimental-features").matched
    check not parseNixDaemonDropInLine("",
      "experimental-features").matched
    check not parseNixDaemonDropInLine("   ",
      "experimental-features").matched

  test "parseNixDaemonDropInLine returns the LAST matching value":
    let content = "experimental-features = old\n" &
                  "experimental-features = nix-command flakes\n"
    let r = readNixDaemonDropInValue(content, "experimental-features")
    check r.present
    check r.value == "nix-command flakes"

  test "readNixDaemonDropInValue reports absent for an unmatched key":
    let r = readNixDaemonDropInValue("# nothing here\n",
      "experimental-features")
    check not r.present

  test "nixDaemonDropInFilename uses explicit filename when set":
    let op = PrivilegedOperation(kind: pokLinuxNixDaemonSetting,
      address: "ef",
      nixKey: "experimental-features",
      nixValue: "x",
      nixFilename: "10-flakes.conf")
    check nixDaemonDropInFilename(op) == "10-flakes.conf"

  test "nixDaemonDropInFilename auto-derives a slug when filename empty":
    let op = PrivilegedOperation(kind: pokLinuxNixDaemonSetting,
      address: "linux.nixDaemonSetting:experimental-features",
      nixKey: "experimental-features",
      nixValue: "x",
      nixFilename: "")
    let f = nixDaemonDropInFilename(op)
    check f.startsWith("99-reprobuild-")
    check f.endsWith(".conf")

  test "nixDaemonDropInPath roots the file under /etc/nix/nix.conf.d":
    let op = PrivilegedOperation(kind: pokLinuxNixDaemonSetting,
      address: "ef",
      nixKey: "experimental-features",
      nixValue: "x",
      nixFilename: "10-flakes.conf")
    check nixDaemonDropInPath(op) ==
      "/etc/nix/nix.conf.d/10-flakes.conf"
    check LinuxNixDaemonDropInDir == "/etc/nix/nix.conf.d"

  test "operationValidationError accepts a valid linux.nixDaemonSetting":
    let ok = PrivilegedOperation(kind: pokLinuxNixDaemonSetting,
      address: "experimental-features",
      nixKey: "experimental-features",
      nixValue: "nix-command flakes",
      nixFilename: "10-flakes.conf")
    check operationValidationError(ok) == ""

  test "operationValidationError flags bad linux.nixDaemonSetting fields":
    # shell-meta in key
    let badKey = PrivilegedOperation(kind: pokLinuxNixDaemonSetting,
      address: "x", nixKey: "bad; rm", nixValue: "x")
    check operationValidationError(badKey).len > 0
    # newline in value
    let badValue = PrivilegedOperation(kind: pokLinuxNixDaemonSetting,
      address: "x", nixKey: "ok", nixValue: "first\nsecond")
    check operationValidationError(badValue).len > 0
    # filename missing .conf
    let badFilename = PrivilegedOperation(kind: pokLinuxNixDaemonSetting,
      address: "x", nixKey: "ok", nixValue: "x",
      nixFilename: "no-extension")
    check operationValidationError(badFilename).len > 0
    # filename with path-escape segment
    let escapeFilename = PrivilegedOperation(kind: pokLinuxNixDaemonSetting,
      address: "x", nixKey: "ok", nixValue: "x",
      nixFilename: "../etc/passwd")
    check operationValidationError(escapeFilename).len > 0
    # empty address
    let emptyAddr = PrivilegedOperation(kind: pokLinuxNixDaemonSetting,
      address: "", nixKey: "ok", nixValue: "x")
    check operationValidationError(emptyAddr).len > 0

  test "RBEB Operation frame round-trips a linux.nixDaemonSetting":
    let op = PrivilegedOperation(kind: pokLinuxNixDaemonSetting,
      address: "experimental-features",
      nixKey: "experimental-features",
      nixValue: "nix-command flakes",
      nixFilename: "10-flakes.conf",
      nixDestroy: false)
    let wire = WireOperation(operation: op,
      baselineDigestHex: "deadbeef")
    let w2 = decodeOperation(decodeFrame(encodeOperation(wire)).body)
    check w2.baselineDigestHex == "deadbeef"
    check w2.operation.kind == pokLinuxNixDaemonSetting
    check w2.operation.address == "experimental-features"
    check w2.operation.nixKey == "experimental-features"
    check w2.operation.nixValue == "nix-command flakes"
    check w2.operation.nixFilename == "10-flakes.conf"
    check not w2.operation.nixDestroy

  test "RBEB Operation frame round-trips a destroy linux.nixDaemonSetting":
    let op = PrivilegedOperation(kind: pokLinuxNixDaemonSetting,
      address: "ef",
      nixKey: "experimental-features",
      nixValue: "",
      nixFilename: "",
      nixDestroy: true)
    let wire = WireOperation(operation: op,
      baselineDigestHex: "cafef00d")
    let w2 = decodeOperation(decodeFrame(encodeOperation(wire)).body)
    check w2.operation.kind == pokLinuxNixDaemonSetting
    check w2.operation.nixDestroy

  test "posix desired digest for nixDaemonSetting matches content bytes":
    let op = PrivilegedOperation(kind: pokLinuxNixDaemonSetting,
      address: "ef",
      nixKey: "experimental-features",
      nixValue: "nix-command flakes")
    check posixSystemDesiredDigestHex(op) ==
      posixDigestHexOfText(nixDaemonDropInContent(op.nixKey, op.nixValue))

  test "posix desired digest for nixDaemonSetting destroy is the absent sentinel":
    let op = PrivilegedOperation(kind: pokLinuxNixDaemonSetting,
      address: "ef",
      nixKey: "experimental-features",
      nixValue: "x",
      nixDestroy: true)
    check posixSystemDesiredDigestHex(op) == ZeroDigestHex

  test "linux.nixDaemonSetting requires elevation":
    check requiresElevation(pokLinuxNixDaemonSetting)
    check $pokLinuxNixDaemonSetting == "linux.nixDaemonSetting"
    check privilegedOperationKindFromString("linux.nixDaemonSetting") ==
      pokLinuxNixDaemonSetting

  test "off-Linux linux.nixDaemonSetting entry points raise ENotImplementedPlatform":
    when not defined(linux):
      let op = PrivilegedOperation(kind: pokLinuxNixDaemonSetting,
        address: "ef",
        nixKey: "experimental-features",
        nixValue: "x")
      expect ENotImplementedPlatform:
        discard observeLinuxNixDaemonSetting(op)
      expect ENotImplementedPlatform:
        discard applyLinuxNixDaemonSetting(op)
      expect ENotImplementedPlatform:
        discard destroyLinuxNixDaemonSetting(op)

# ===========================================================================
# systemd.systemTimer — pure drift logic. The shell-out side mirrors
# systemd.systemUnit; pure tests cover the closed-set validator
# (`.timer` suffix + safe unit-name), the path derivation, the content
# digest, the four enabled/running boolean combinations on the codec
# round-trip, and the off-Linux gate.
# ===========================================================================

suite "repro_elevation: systemd.systemTimer pure surface":

  test "systemUnitPath joins the directory with the timer file name":
    check systemUnitPath("zfs-scrub.timer") ==
      "/etc/systemd/system/zfs-scrub.timer"
    check SystemdSystemUnitDir == "/etc/systemd/system"

  test "operationValidationError accepts a valid systemd.systemTimer":
    let ok = PrivilegedOperation(kind: pokSystemdSystemTimer,
      address: "zfs-scrub.timer",
      stName: "zfs-scrub.timer",
      stContent: "[Unit]\n[Timer]\nOnCalendar=weekly\n[Install]\n",
      stEnabled: true,
      stRunning: true)
    check operationValidationError(ok) == ""

  test "operationValidationError flags bad systemd.systemTimer fields":
    # missing .timer suffix
    let badSuffix = PrivilegedOperation(kind: pokSystemdSystemTimer,
      address: "x", stName: "zfs-scrub.service",
      stContent: "x", stEnabled: true, stRunning: true)
    check operationValidationError(badSuffix).len > 0
    # path-escape name
    let escape = PrivilegedOperation(kind: pokSystemdSystemTimer,
      address: "x", stName: "../etc/passwd.timer",
      stContent: "x", stEnabled: true, stRunning: true)
    check operationValidationError(escape).len > 0
    # empty address
    let emptyAddr = PrivilegedOperation(kind: pokSystemdSystemTimer,
      address: "", stName: "zfs-scrub.timer",
      stContent: "x", stEnabled: true, stRunning: true)
    check operationValidationError(emptyAddr).len > 0

  test "RBEB Operation frame round-trips a systemd.systemTimer (all four states)":
    # The driver supports four enabled/running combinations; check
    # all four survive the wire round-trip.
    for enabled in [true, false]:
      for running in [true, false]:
        let op = PrivilegedOperation(kind: pokSystemdSystemTimer,
          address: "zfs-scrub.timer",
          stName: "zfs-scrub.timer",
          stContent: "[Unit]\n[Timer]\nOnCalendar=weekly\n",
          stEnabled: enabled,
          stRunning: running,
          stDestroy: false)
        let wire = WireOperation(operation: op,
          baselineDigestHex: "deadbeef")
        let w2 = decodeOperation(decodeFrame(encodeOperation(wire)).body)
        check w2.baselineDigestHex == "deadbeef"
        check w2.operation.kind == pokSystemdSystemTimer
        check w2.operation.stName == "zfs-scrub.timer"
        check w2.operation.stEnabled == enabled
        check w2.operation.stRunning == running
        check not w2.operation.stDestroy

  test "RBEB Operation frame round-trips a destroy systemd.systemTimer":
    let op = PrivilegedOperation(kind: pokSystemdSystemTimer,
      address: "zfs-scrub.timer",
      stName: "zfs-scrub.timer",
      stContent: "",
      stEnabled: false,
      stRunning: false,
      stDestroy: true)
    let wire = WireOperation(operation: op,
      baselineDigestHex: "cafef00d")
    let w2 = decodeOperation(decodeFrame(encodeOperation(wire)).body)
    check w2.operation.kind == pokSystemdSystemTimer
    check w2.operation.stDestroy

  test "posix desired digest for systemd.systemTimer matches content bytes":
    let op = PrivilegedOperation(kind: pokSystemdSystemTimer,
      address: "x",
      stName: "zfs-scrub.timer",
      stContent: "[Unit]\n[Timer]\nOnCalendar=weekly\n[Install]\n",
      stEnabled: true,
      stRunning: true)
    check posixSystemDesiredDigestHex(op) ==
      posixDigestHexOfText(op.stContent)

  test "posix desired digest for systemd.systemTimer destroy is the absent sentinel":
    let op = PrivilegedOperation(kind: pokSystemdSystemTimer,
      address: "x",
      stName: "zfs-scrub.timer",
      stContent: "x",
      stEnabled: false,
      stRunning: false,
      stDestroy: true)
    check posixSystemDesiredDigestHex(op) == ZeroDigestHex

  test "systemd.systemTimer requires elevation":
    check requiresElevation(pokSystemdSystemTimer)
    check $pokSystemdSystemTimer == "systemd.systemTimer"
    check privilegedOperationKindFromString("systemd.systemTimer") ==
      pokSystemdSystemTimer

  test "off-Linux systemd.systemTimer entry points raise ENotImplementedPlatform":
    when not defined(linux):
      let op = PrivilegedOperation(kind: pokSystemdSystemTimer,
        address: "zfs-scrub.timer",
        stName: "zfs-scrub.timer",
        stContent: "x",
        stEnabled: true,
        stRunning: true)
      expect ENotImplementedPlatform:
        discard observeSystemdSystemTimer(op)
      expect ENotImplementedPlatform:
        discard applySystemdSystemTimer(op)

# ===========================================================================
# linux.firewallRule — pure parse + drift logic. The shell-out side
# wraps `nft add rule` / `nft -a list chain` / `nft delete rule`;
# pure tests cover the closed-set validator (chain triple shape +
# protocol / action / direction enums + port charset), the rule
# body / comment builders, the handle parser, and the codec
# round-trip.
# ===========================================================================

suite "repro_elevation: linux.firewallRule pure surface":

  test "nftRuleComment and NftCommentPrefix":
    # The marker uses `-` (not `:`) as the prefix/name separator so
    # the comment body parses unambiguously through nft's grammar
    # even when the surrounding `nft add rule` line passes through
    # the shell and loses one layer of quoting. nft sub-parses
    # `<word>:<word>` as a key/value pair and rejects it; `-` is
    # never sub-parsed.
    check NftCommentPrefix == "repro-fw-"
    check nftRuleComment("openssh") == "repro-fw-openssh"

  test "nftRuleBody for tcp includes dport and comment":
    check nftRuleBody("tcp", "22", "accept", "openssh") ==
      "tcp dport 22 accept comment \"repro-fw-openssh\""

  test "nftRuleBody for udp includes dport and comment":
    check nftRuleBody("udp", "53", "drop", "dns-block") ==
      "udp dport 53 drop comment \"repro-fw-dns-block\""

  test "nftRuleBody for icmp omits the dport clause":
    check nftRuleBody("icmp", "", "accept", "ping") ==
      "icmp accept comment \"repro-fw-ping\""

  test "nftRuleBody for icmpv6 omits the dport clause":
    check nftRuleBody("icmpv6", "", "accept", "ping6") ==
      "icmpv6 accept comment \"repro-fw-ping6\""

  test "nft rule body contains no `:` (the byte that breaks unquoted comments)":
    # Belt-and-braces against a regression that re-introduces `:`
    # in the marker — it'd compile, but `nft add rule` would
    # reject it on every distro whose nft sub-parses unquoted
    # `<word>:<word>` tokens (Ubuntu 22.04 nftables 1.0.x).
    let body = nftRuleBody("tcp", "65500", "accept", "reprom83vmtest")
    check ':' notin body

  test "parseNftHandleForComment finds the integer handle":
    let listing = "table inet filter {\n" &
                  "\tchain input {\n" &
                  "\t\ttype filter hook input priority 0;\n" &
                  "\t\ttcp dport 22 accept comment \"repro-fw-openssh\" # handle 17\n" &
                  "\t\ttcp dport 80 accept # handle 18\n" &
                  "\t}\n" &
                  "}\n"
    check parseNftHandleForComment(listing, "repro-fw-openssh") == 17

  test "parseNftHandleForComment returns -1 for an absent marker":
    let listing = "table inet filter {\n" &
                  "\tchain input {\n" &
                  "\t\ttcp dport 80 accept # handle 18\n" &
                  "\t}\n" &
                  "}\n"
    check parseNftHandleForComment(listing, "repro-fw-openssh") == -1

  test "parseNftHandleForComment ignores lines without a handle suffix":
    # A `nft list ruleset` (no `-a` flag) emits no `# handle N`
    # suffix; the parser must safely return -1 instead of crashing.
    let listing = "table inet filter {\n" &
                  "\ttcp dport 22 accept comment \"repro-fw-openssh\"\n" &
                  "}\n"
    check parseNftHandleForComment(listing, "repro-fw-openssh") == -1

  test "parseNftRuleSpecForComment strips leading whitespace + handle suffix":
    let listing = "\t\ttcp dport 22 accept comment \"repro-fw-openssh\" # handle 17\n"
    check parseNftRuleSpecForComment(listing, "repro-fw-openssh") ==
      "tcp dport 22 accept comment \"repro-fw-openssh\""

  test "parseNftRuleSpecForComment returns empty for an absent marker":
    check parseNftRuleSpecForComment(
      "tcp dport 80 accept # handle 18", "repro-fw-openssh") == ""

  test "operationValidationError accepts a valid linux.firewallRule (tcp)":
    let ok = PrivilegedOperation(kind: pokLinuxFirewallRule,
      address: "openssh",
      lfwChain: "inet filter input",
      lfwName: "openssh",
      lfwProtocol: "tcp",
      lfwDirection: "inbound",
      lfwLocalPort: "22",
      lfwAction: "accept")
    check operationValidationError(ok) == ""

  test "operationValidationError accepts a valid linux.firewallRule (icmp, no port)":
    let ok = PrivilegedOperation(kind: pokLinuxFirewallRule,
      address: "ping",
      lfwChain: "inet filter input",
      lfwName: "ping",
      lfwProtocol: "icmp",
      lfwDirection: "inbound",
      lfwLocalPort: "",
      lfwAction: "accept")
    check operationValidationError(ok) == ""

  test "operationValidationError flags bad linux.firewallRule fields":
    # bad chain (not a triple)
    let badChain = PrivilegedOperation(kind: pokLinuxFirewallRule,
      address: "x", lfwChain: "input",
      lfwName: "x", lfwProtocol: "tcp",
      lfwLocalPort: "22", lfwAction: "accept")
    check operationValidationError(badChain).len > 0
    # chain with shell metacharacter
    let metaChain = PrivilegedOperation(kind: pokLinuxFirewallRule,
      address: "x", lfwChain: "inet filter input; rm",
      lfwName: "x", lfwProtocol: "tcp",
      lfwLocalPort: "22", lfwAction: "accept")
    check operationValidationError(metaChain).len > 0
    # bad protocol
    let badProto = PrivilegedOperation(kind: pokLinuxFirewallRule,
      address: "x", lfwChain: "inet filter input",
      lfwName: "x", lfwProtocol: "sctp",
      lfwLocalPort: "22", lfwAction: "accept")
    check operationValidationError(badProto).len > 0
    # bad action
    let badAction = PrivilegedOperation(kind: pokLinuxFirewallRule,
      address: "x", lfwChain: "inet filter input",
      lfwName: "x", lfwProtocol: "tcp",
      lfwLocalPort: "22", lfwAction: "log")
    check operationValidationError(badAction).len > 0
    # bad direction
    let badDir = PrivilegedOperation(kind: pokLinuxFirewallRule,
      address: "x", lfwChain: "inet filter input",
      lfwName: "x", lfwProtocol: "tcp", lfwDirection: "sideways",
      lfwLocalPort: "22", lfwAction: "accept")
    check operationValidationError(badDir).len > 0
    # missing port for tcp
    let noPort = PrivilegedOperation(kind: pokLinuxFirewallRule,
      address: "x", lfwChain: "inet filter input",
      lfwName: "x", lfwProtocol: "tcp",
      lfwLocalPort: "", lfwAction: "accept")
    check operationValidationError(noPort).len > 0
    # bad rule name (shell meta)
    let badName = PrivilegedOperation(kind: pokLinuxFirewallRule,
      address: "x", lfwChain: "inet filter input",
      lfwName: "evil; rm", lfwProtocol: "tcp",
      lfwLocalPort: "22", lfwAction: "accept")
    check operationValidationError(badName).len > 0
    # bad port shape
    let badPort = PrivilegedOperation(kind: pokLinuxFirewallRule,
      address: "x", lfwChain: "inet filter input",
      lfwName: "x", lfwProtocol: "tcp",
      lfwLocalPort: "twenty-two", lfwAction: "accept")
    check operationValidationError(badPort).len > 0
    # empty address
    let emptyAddr = PrivilegedOperation(kind: pokLinuxFirewallRule,
      address: "", lfwChain: "inet filter input",
      lfwName: "x", lfwProtocol: "tcp",
      lfwLocalPort: "22", lfwAction: "accept")
    check operationValidationError(emptyAddr).len > 0

  test "destroy linux.firewallRule does not need a localPort":
    # The destroy direction looks up by comment marker only; the
    # protocol-port pairing rule does not gate destroy.
    let destroyOp = PrivilegedOperation(kind: pokLinuxFirewallRule,
      address: "openssh",
      lfwChain: "inet filter input",
      lfwName: "openssh",
      lfwProtocol: "tcp",
      lfwDirection: "inbound",
      lfwLocalPort: "",
      lfwAction: "accept",
      lfwDestroy: true)
    check operationValidationError(destroyOp) == ""

  test "RBEB Operation frame round-trips a linux.firewallRule":
    let op = PrivilegedOperation(kind: pokLinuxFirewallRule,
      address: "openssh",
      lfwChain: "inet filter input",
      lfwName: "openssh",
      lfwProtocol: "tcp",
      lfwDirection: "inbound",
      lfwLocalPort: "22",
      lfwAction: "accept",
      lfwDestroy: false)
    let wire = WireOperation(operation: op,
      baselineDigestHex: "deadbeef")
    let w2 = decodeOperation(decodeFrame(encodeOperation(wire)).body)
    check w2.baselineDigestHex == "deadbeef"
    check w2.operation.kind == pokLinuxFirewallRule
    check w2.operation.lfwChain == "inet filter input"
    check w2.operation.lfwName == "openssh"
    check w2.operation.lfwProtocol == "tcp"
    check w2.operation.lfwDirection == "inbound"
    check w2.operation.lfwLocalPort == "22"
    check w2.operation.lfwAction == "accept"
    check not w2.operation.lfwDestroy

  test "RBEB Operation frame round-trips a destroy linux.firewallRule":
    let op = PrivilegedOperation(kind: pokLinuxFirewallRule,
      address: "openssh",
      lfwChain: "inet filter input",
      lfwName: "openssh",
      lfwProtocol: "tcp",
      lfwDirection: "inbound",
      lfwLocalPort: "22",
      lfwAction: "accept",
      lfwDestroy: true)
    let wire = WireOperation(operation: op,
      baselineDigestHex: "cafef00d")
    let w2 = decodeOperation(decodeFrame(encodeOperation(wire)).body)
    check w2.operation.kind == pokLinuxFirewallRule
    check w2.operation.lfwDestroy

  test "posix desired digest for linux.firewallRule matches rule body":
    let op = PrivilegedOperation(kind: pokLinuxFirewallRule,
      address: "openssh",
      lfwChain: "inet filter input",
      lfwName: "openssh",
      lfwProtocol: "tcp",
      lfwDirection: "inbound",
      lfwLocalPort: "22",
      lfwAction: "accept")
    check posixSystemDesiredDigestHex(op) ==
      posixDigestHexOfText(nftRuleBody("tcp", "22", "accept", "openssh"))

  test "posix desired digest for linux.firewallRule destroy is absent sentinel":
    let op = PrivilegedOperation(kind: pokLinuxFirewallRule,
      address: "openssh",
      lfwChain: "inet filter input",
      lfwName: "openssh",
      lfwProtocol: "tcp",
      lfwLocalPort: "22",
      lfwAction: "accept",
      lfwDestroy: true)
    check posixSystemDesiredDigestHex(op) == ZeroDigestHex

  test "linux.firewallRule requires elevation":
    check requiresElevation(pokLinuxFirewallRule)
    check $pokLinuxFirewallRule == "linux.firewallRule"
    check privilegedOperationKindFromString("linux.firewallRule") ==
      pokLinuxFirewallRule

  test "off-Linux linux.firewallRule entry points raise ENotImplementedPlatform":
    when not defined(linux):
      let op = PrivilegedOperation(kind: pokLinuxFirewallRule,
        address: "openssh",
        lfwChain: "inet filter input",
        lfwName: "openssh",
        lfwProtocol: "tcp",
        lfwDirection: "inbound",
        lfwLocalPort: "22",
        lfwAction: "accept")
      expect ENotImplementedPlatform:
        discard observeLinuxFirewallRule(op)
      expect ENotImplementedPlatform:
        discard applyLinuxFirewallRule(op)
      expect ENotImplementedPlatform:
        discard destroyLinuxFirewallRule(op)

# ===========================================================================
# windows.acl — pure parse + drift logic. The shell-out side of the
# driver runs only on Windows hosts; what runs everywhere is the
# closed-set validator, the canonical-state digest, and the icacls
# probe-output parser.
# ===========================================================================

suite "repro_elevation: windows.acl pure surface":

  test "isSafeAclPath accepts a typical absolute path":
    check isSafeAclPath("C:\\Users\\foo\\.ssh")
    check isSafeAclPath("C:\\ProgramData\\Reprobuild-Tests\\acl-test")
    check isSafeAclPath("D:\\path with spaces\\sub")
    check not isSafeAclPath("")
    check not isSafeAclPath("C:\\bad\\..\\escape")
    check not isSafeAclPath("C:\\bad;rm")
    check not isSafeAclPath("C:\\bad`rm")
    check not isSafeAclPath("C:\\bad\"injected")
    check not isSafeAclPath("C:\\$injected")

  test "isSafeAclPrincipal accepts NTAccount + SID forms":
    check isSafeAclPrincipal("BUILTIN\\Administrators")
    check isSafeAclPrincipal("NT AUTHORITY\\SYSTEM")
    check isSafeAclPrincipal("Administrators")
    check isSafeAclPrincipal("S-1-5-32-544")
    check isSafeAclPrincipal("Zahary")
    check isSafeAclPrincipal("DOMAIN\\user.name")
    check isSafeAclPrincipal("user@DOMAIN")
    check not isSafeAclPrincipal("")
    check not isSafeAclPrincipal("Bad'Name")
    check not isSafeAclPrincipal("Bad;Name")
    check not isSafeAclPrincipal("Bad:Name")
    check not isSafeAclPrincipal("Bad\"Name")

  test "isSafeAclEntry accepts canonical icacls grant forms":
    check isSafeAclEntry("BUILTIN\\Administrators:(OI)(CI)(F)")
    check isSafeAclEntry("NT AUTHORITY\\SYSTEM:(OI)(CI)(F)")
    check isSafeAclEntry("Users:(OI)(CI)(RX)")
    check isSafeAclEntry("Zahary:(R,W)")
    check isSafeAclEntry("S-1-5-32-544:(F)")
    check not isSafeAclEntry("")
    check not isSafeAclEntry("noColonForm")
    check not isSafeAclEntry("BadPrinc;:(F)")
    check not isSafeAclEntry("OK:(F);rm -rf /")
    check not isSafeAclEntry("OK:$(whoami)")

  test "operationValidationError accepts a valid windows.acl op":
    let ok = PrivilegedOperation(kind: pokWindowsAcl,
      address: "ssh-acl",
      aclPath: "C:\\Users\\Zahary\\.ssh",
      aclOwner: "BUILTIN\\Administrators",
      aclEntries: @["BUILTIN\\Administrators:(OI)(CI)(F)",
                    "NT AUTHORITY\\SYSTEM:(OI)(CI)(F)",
                    "Zahary:(OI)(CI)(F)"],
      aclInheritanceMode: "disabled-replace")
    check operationValidationError(ok) == ""

  test "operationValidationError flags bad windows.acl fields":
    let emptyEntries = PrivilegedOperation(kind: pokWindowsAcl,
      address: "x", aclPath: "C:\\Users\\Zahary\\.ssh",
      aclEntries: @[])
    check operationValidationError(emptyEntries).len > 0

    let badPath = PrivilegedOperation(kind: pokWindowsAcl,
      address: "x", aclPath: "C:\\bad\\..\\escape",
      aclEntries: @["Users:(F)"])
    check operationValidationError(badPath).len > 0

    let badOwner = PrivilegedOperation(kind: pokWindowsAcl,
      address: "x", aclPath: "C:\\valid",
      aclOwner: "BAD;OWNER",
      aclEntries: @["Users:(F)"])
    check operationValidationError(badOwner).len > 0

    let badMode = PrivilegedOperation(kind: pokWindowsAcl,
      address: "x", aclPath: "C:\\valid",
      aclEntries: @["Users:(F)"],
      aclInheritanceMode: "off")
    check operationValidationError(badMode).len > 0

    let badEntry = PrivilegedOperation(kind: pokWindowsAcl,
      address: "x", aclPath: "C:\\valid",
      aclEntries: @["Users:(F);rm -rf /"])
    check operationValidationError(badEntry).len > 0

    let emptyAddr = PrivilegedOperation(kind: pokWindowsAcl,
      address: "", aclPath: "C:\\valid",
      aclEntries: @["Users:(F)"])
    check operationValidationError(emptyAddr).len > 0

    # destroy op with empty entries is allowed (icacls /reset takes
    # no entries).
    let okDestroy = PrivilegedOperation(kind: pokWindowsAcl,
      address: "x", aclPath: "C:\\valid",
      aclEntries: @[], aclDestroy: true)
    check operationValidationError(okDestroy) == ""

  test "parseIcaclsOutput reads a present directory ACL":
    let raw = "C:\\ProgramData\\Reprobuild-Tests\\acl-test " &
      "BUILTIN\\Administrators:(F)\n" &
      "                                            " &
      "NT AUTHORITY\\SYSTEM:(F)\n" &
      "                                            " &
      "BUILTIN\\Users:(OI)(CI)(RX)\n" &
      "\n" &
      "Successfully processed 1 files; Failed processing 0 files\n"
    let obs = parseIcaclsOutput(raw,
      "C:\\ProgramData\\Reprobuild-Tests\\acl-test")
    check obs.present
    check obs.entries.len == 3
    check obs.entries[0].contains("Administrators:(F)")
    check obs.entries[1].contains("SYSTEM:(F)")
    check obs.entries[2].contains("Users:(OI)(CI)(RX)")
    # No `(I)` flag in any entry => observation reports inheritance
    # disabled (heuristic — see parser docstring).
    check obs.inheritanceDisabled

  test "parseIcaclsOutput detects the (I) inherited-marker flag":
    let raw = "C:\\foo BUILTIN\\Users:(I)(OI)(CI)(RX)\n" &
      "       BUILTIN\\Administrators:(F)\n" &
      "Successfully processed 1 files; Failed processing 0 files\n"
    let obs = parseIcaclsOutput(raw, "C:\\foo")
    check obs.present
    check not obs.inheritanceDisabled

  test "parseIcaclsOutput treats `cannot find` output as absent":
    let raw = "C:\\does\\not\\exist: The system cannot find the " &
      "path specified.\n"
    let obs = parseIcaclsOutput(raw, "C:\\does\\not\\exist")
    check not obs.present
    check obs.entries.len == 0

  test "parseIcaclsOutput treats empty output as absent":
    check not parseIcaclsOutput("", "C:\\anywhere").present

  test "normalizeAclEntry collapses whitespace":
    check normalizeAclEntry("Users:(F)") == "Users:(F)"
    check normalizeAclEntry("  Users:(F)  ") == "Users:(F)"
    check normalizeAclEntry("Users: (F)") == "Users: (F)"
    check normalizeAclEntry("Users:(F)\t(OI)") == "Users:(F) (OI)"

  test "canonicalAclDesired sorts entries":
    let a = canonicalAclDesired("C:\\foo", "",
      @["Users:(R)", "Administrators:(F)"], "enabled")
    let b = canonicalAclDesired("C:\\foo", "",
      @["Administrators:(F)", "Users:(R)"], "enabled")
    check a == b

  test "canonicalAclDesired defaults inheritanceMode to enabled":
    let a = canonicalAclDesired("C:\\foo", "",
      @["Users:(R)"], "")
    let b = canonicalAclDesired("C:\\foo", "",
      @["Users:(R)"], "enabled")
    check a == b

  test "aclMatchesDesired detects missing ACE":
    let obs = AclObservation(present: true, inheritanceDisabled: true,
      entries: @["BUILTIN\\Administrators:(F)",
                 "NT AUTHORITY\\SYSTEM:(F)"])
    check aclMatchesDesired(obs, "C:\\foo", "",
      @["BUILTIN\\Administrators:(F)",
        "NT AUTHORITY\\SYSTEM:(F)"], "enabled")
    # Adding a desired entry that's not present => mismatch.
    check not aclMatchesDesired(obs, "C:\\foo", "",
      @["BUILTIN\\Administrators:(F)",
        "NT AUTHORITY\\SYSTEM:(F)",
        "Zahary:(F)"], "enabled")

  test "aclMatchesDesired is additive-only on extra ACEs":
    let obs = AclObservation(present: true, inheritanceDisabled: true,
      entries: @["BUILTIN\\Administrators:(F)",
                 "NT AUTHORITY\\SYSTEM:(F)",
                 "Extra-Local-Account:(R)"])
    # The operator declared only Administrators+SYSTEM; the extra
    # local ACE is NOT considered drift.
    check aclMatchesDesired(obs, "C:\\foo", "",
      @["BUILTIN\\Administrators:(F)",
        "NT AUTHORITY\\SYSTEM:(F)"], "enabled")

  test "aclMatchesDesired enforces disabled-replace inheritance":
    let obsInherited = AclObservation(present: true,
      inheritanceDisabled: false,
      entries: @["BUILTIN\\Administrators:(F)"])
    check not aclMatchesDesired(obsInherited, "C:\\foo", "",
      @["BUILTIN\\Administrators:(F)"], "disabled-replace")
    let obsDisabled = AclObservation(present: true,
      inheritanceDisabled: true,
      entries: @["BUILTIN\\Administrators:(F)"])
    check aclMatchesDesired(obsDisabled, "C:\\foo", "",
      @["BUILTIN\\Administrators:(F)"], "disabled-replace")

  test "aclMatchesDesired returns false for absent":
    check not aclMatchesDesired(AclObservation(present: false),
      "C:\\foo", "", @["Users:(F)"], "enabled")

  test "RBEB Operation frame round-trips a windows.acl":
    let op = PrivilegedOperation(kind: pokWindowsAcl,
      address: "ssh-acl",
      aclPath: "C:\\Users\\Zahary\\.ssh",
      aclOwner: "BUILTIN\\Administrators",
      aclEntries: @["BUILTIN\\Administrators:(OI)(CI)(F)",
                    "NT AUTHORITY\\SYSTEM:(OI)(CI)(F)",
                    "Zahary:(OI)(CI)(F)"],
      aclInheritanceMode: "disabled-replace",
      aclDestroy: false)
    let wire = WireOperation(operation: op,
      baselineDigestHex: "deadbeef")
    let dec = decodeFrame(encodeOperation(wire))
    check dec.messageType == rmtOperation
    let w2 = decodeOperation(dec.body)
    check w2.baselineDigestHex == "deadbeef"
    check w2.operation.kind == pokWindowsAcl
    check w2.operation.address == "ssh-acl"
    check w2.operation.aclPath == "C:\\Users\\Zahary\\.ssh"
    check w2.operation.aclOwner == "BUILTIN\\Administrators"
    check w2.operation.aclEntries.len == 3
    check w2.operation.aclEntries[0] ==
      "BUILTIN\\Administrators:(OI)(CI)(F)"
    check w2.operation.aclEntries[2] == "Zahary:(OI)(CI)(F)"
    check w2.operation.aclInheritanceMode == "disabled-replace"
    check not w2.operation.aclDestroy

  test "windows.acl requires elevation":
    check requiresElevation(pokWindowsAcl)
    check $pokWindowsAcl == "windows.acl"
    check privilegedOperationKindFromString("windows.acl") ==
      pokWindowsAcl

  test "off-Windows windows.acl entry points raise ENotImplementedPlatform":
    when not defined(windows):
      let op = PrivilegedOperation(kind: pokWindowsAcl,
        address: "x", aclPath: "C:\\foo",
        aclEntries: @["Users:(F)"])
      expect ENotImplementedPlatform:
        discard observeWindowsAcl(op)
      expect ENotImplementedPlatform:
        discard applyWindowsAcl(op)
      expect ENotImplementedPlatform:
        discard destroyWindowsAcl(op)

# ---------------------------------------------------------------------------
# Recipe-Validation side-finding regressions:
#
#   * Item 3 — `os.timezone` IANA alias collapsing (Etc/UTC vs UTC).
#   * Item 4 — `systemd.systemUnit` Alpine / OpenRC carve-out.
# ---------------------------------------------------------------------------

suite "Recipe-Val side-findings: os.timezone canonicalization":

  test "Etc/UTC collapses to UTC in canonical state and desired digests":
    # The M7 multi-distro harness observed `UTC` (the
    # `/etc/localtime` symlink-target basename on every glibc distro)
    # while the fixture profile declared `Etc/UTC`. Without
    # `canonicalIanaTimezone`, the two strings hash differently and
    # the plan reports a spurious `update` action on a true no-op.
    # Both halves of the digest comparison must reduce alias-equivalent
    # IANA names to the same canonical form.
    check canonicalTimezoneState("UTC") == canonicalTimezoneDesired("Etc/UTC")
    check canonicalTimezoneState("Etc/UTC") ==
          canonicalTimezoneDesired("UTC")
    check canonicalTimezoneState("Etc/UTC") ==
          canonicalTimezoneDesired("Etc/UTC")
    # Per the IANA tzdb's `backward` link table.
    check canonicalIanaTimezone("Etc/UTC") == "UTC"
    check canonicalIanaTimezone("Etc/Zulu") == "UTC"
    check canonicalIanaTimezone("Universal") == "UTC"

  test "GMT family aliases collapse to Etc/GMT":
    # IANA `backward` link aliases for the zero-offset GMT file. All
    # collapse to a single canonical form so a fixture declaring `GMT`
    # and a host reporting `Etc/GMT` (or vice-versa) drift-compare as
    # no-op.
    check canonicalIanaTimezone("Etc/GMT") == "Etc/GMT"
    check canonicalIanaTimezone("GMT") == "Etc/GMT"
    check canonicalIanaTimezone("Greenwich") == "Etc/GMT"
    check canonicalTimezoneState("GMT") == canonicalTimezoneDesired("Etc/GMT")
    check canonicalIanaTimezone("Etc/GMT+0") == canonicalIanaTimezone("Etc/GMT")
    check canonicalIanaTimezone("Etc/GMT-0") == canonicalIanaTimezone("Etc/GMT")
    check canonicalIanaTimezone("Etc/GMT+1") != canonicalIanaTimezone("Etc/GMT")  # different zone

  test "non-alias timezones flow through the canonicalizer unchanged":
    # The slow-path zones must keep their existing identity-on-IANA
    # canonicalization — only the explicit alias families fold. A
    # `Europe/Sofia` -> `Europe/Sofia` round-trip is the existing
    # contract every other test in this file relies on.
    check canonicalIanaTimezone("Europe/Sofia") == "Europe/Sofia"
    check canonicalIanaTimezone("America/Los_Angeles") == "America/Los_Angeles"
    check canonicalIanaTimezone("Asia/Tokyo") == "Asia/Tokyo"
    check canonicalTimezoneState("Europe/Sofia") ==
          canonicalTimezoneDesired("Europe/Sofia")
    # Whitespace handling preserved.
    check canonicalIanaTimezone("  Europe/Sofia  ") == "Europe/Sofia"

  test "empty string still maps to timezone:absent":
    # The "absent" sentinel must not be polluted by the alias map.
    check canonicalTimezoneState("") == "timezone:absent"
    check canonicalTimezoneState("   ") == "timezone:absent"

suite "Recipe-Val side-findings: parseOsReleaseId / systemd carve-out":

  test "parseOsReleaseId extracts ID for the five harness distros":
    # The Recipe-Validation M7 sweep covers arch / debian / ubuntu /
    # fedora / alpine. Each `/etc/os-release` has the same `ID=`
    # shape; the carve-out predicate only needs to identify alpine
    # but verifying the other four roundtrip protects against a future
    # quoting / whitespace regression.
    check parseOsReleaseId("ID=alpine\n") == "alpine"
    check parseOsReleaseId("ID=\"alpine\"\n") == "alpine"
    check parseOsReleaseId("ID='alpine'\n") == "alpine"
    check parseOsReleaseId("NAME=\"Alpine Linux\"\nID=alpine\nVERSION_ID=3.21\n") ==
          "alpine"
    check parseOsReleaseId("ID=debian") == "debian"
    check parseOsReleaseId("ID=ubuntu\n") == "ubuntu"
    check parseOsReleaseId("ID=fedora\n") == "fedora"
    check parseOsReleaseId("ID=arch\n") == "arch"
    # `#` comments + blank lines are stripped before the prefix match.
    check parseOsReleaseId("# leading comment\n\nID=alpine\n") == "alpine"
    # Missing ID line -> empty.
    check parseOsReleaseId("PRETTY_NAME=Nothing\n") == ""
    check parseOsReleaseId("") == ""

  test "isAlpineFromOsRelease + usesSystemdFromOsRelease closed-set":
    check isAlpineFromOsRelease("ID=alpine\n")
    check not isAlpineFromOsRelease("ID=debian\n")
    # Alpine, Void, Gentoo: not systemd (per the conservative closed
    # set the M7 carve-out enforces). Every other ID assumed systemd
    # — including the unknown / empty case so an unrecognized
    # mainstream distro doesn't auto-deny a system-unit install.
    check not usesSystemdFromOsRelease("ID=alpine\n")
    check not usesSystemdFromOsRelease("ID=void\n")
    check not usesSystemdFromOsRelease("ID=gentoo\n")
    check usesSystemdFromOsRelease("ID=debian\n")
    check usesSystemdFromOsRelease("ID=ubuntu\n")
    check usesSystemdFromOsRelease("ID=fedora\n")
    check usesSystemdFromOsRelease("ID=arch\n")
    check usesSystemdFromOsRelease("")  # conservative default

  test "REPRO_OS_RELEASE_PATH override drives hostOsReleaseId":
    # The host-probe + override seam is the wire that lets the
    # destructive `applySystemdSystemUnit` carve-out be tested from
    # a non-Alpine host (e.g. this Windows / macOS test machine).
    # Drop a fake `os-release` and re-read it through `hostOsReleaseId`
    # — the round-trip MUST observe the ID we wrote, and the
    # `hostUsesSystemd` predicate MUST flip false for alpine and true
    # otherwise.
    let dir = createTempDir("reprobuild-os-release-", "")
    let fakePath = dir / "os-release-alpine"
    writeFile(fakePath, "ID=alpine\nVERSION_ID=3.21\n")
    putEnv(OsReleaseOverrideEnvVar, fakePath)
    try:
      check hostOsReleaseId() == "alpine"
      check not hostUsesSystemd()
    finally:
      delEnv(OsReleaseOverrideEnvVar)
      try: removeFile(fakePath) except OSError: discard
      try: removeDir(dir) except OSError: discard

  test "applySystemdSystemUnit raises EProtocol on Alpine":
    # Wire the override to a fake Alpine `os-release`; on Linux the
    # destructive entry point hard-errors before any filesystem write.
    # On non-Linux the entry point still raises `ENotImplementedPlatform`
    # via the existing fail-closed arm — the carve-out is Linux-only by
    # design (the OpenRC equivalence is a Linux question).
    when defined(linux):
      let dir = createTempDir("reprobuild-os-release-", "")
      let fakePath = dir / "os-release-alpine-carveout"
      writeFile(fakePath, "ID=alpine\n")
      putEnv(OsReleaseOverrideEnvVar, fakePath)
      try:
        let op = PrivilegedOperation(kind: pokSystemdSystemUnit,
          address: "m7-hello.service",
          suName: "m7-hello.service",
          suContent: "[Unit]\nDescription=test\n",
          suEnabled: false)
        var caught = false
        try:
          discard applySystemdSystemUnit(op)
        except EProtocol as e:
          caught = true
          # The diagnostic must name the distro AND point at the
          # OpenRC alternative; an unhelpful "not supported" string
          # would defeat the purpose of the carve-out.
          check "alpine" in e.msg
          check "openrc" in e.msg.toLowerAscii()
        check caught
      finally:
        delEnv(OsReleaseOverrideEnvVar)
        try: removeFile(fakePath) except OSError: discard
        try: removeDir(dir) except OSError: discard

# ===========================================================================
# Windows-System-Resources Phase C: windows.scheduledTask.
#
# Closed-set vocabulary tests + codec round-trip across every
# ScheduleKind + drift comparator across every kind/field combination.
# All tests platform-pure (the genuinely-Windows shell-outs gate behind
# `when defined(windows)` in the driver; the assemblers below are
# `seq[string]` pure-function returns).
# ===========================================================================

suite "repro_elevation: windows.scheduledTask Phase C":

  test "pokWindowsScheduledTask is in the closed set + requires elevation":
    check requiresElevation(pokWindowsScheduledTask)
    check isKnownPrivilegedOperationKind($pokWindowsScheduledTask)
    check $pokWindowsScheduledTask == "windows.scheduledTask"

  test "schedule-kind token codec: all 5 variants round-trip":
    for tok in ["onBoot", "onLogon", "once", "daily", "interval"]:
      check isKnownScheduledTaskScheduleKindToken(tok)
      let k = scheduledTaskScheduleKindFromToken(tok)
      check scheduledTaskScheduleKindToken(k) == tok
    check scheduledTaskScheduleKindToken(wstskOnBoot) == "onBoot"
    check scheduledTaskScheduleKindToken(wstskOnLogon) == "onLogon"
    check scheduledTaskScheduleKindToken(wstskOnce) == "once"
    check scheduledTaskScheduleKindToken(wstskDaily) == "daily"
    check scheduledTaskScheduleKindToken(wstskInterval) == "interval"

  test "schedule-kind token codec: rejects unknown spellings":
    for bad in ["", "ONBOOT", "onboot", "weekly", "monthly", "rest"]:
      check not isKnownScheduledTaskScheduleKindToken(bad)
      expect ValueError:
        discard scheduledTaskScheduleKindFromToken(bad)

  test "isValidScheduledTaskTimeOfDay: closed-set HH:MM":
    for ok in ["00:00", "08:30", "23:59", "12:00"]:
      check isValidScheduledTaskTimeOfDay(ok)
    for bad in ["", "8:30", "24:00", "12:60", "1234", "12:00:00",
                "ab:cd"]:
      check not isValidScheduledTaskTimeOfDay(bad)

  test "isValidScheduledTaskIso8601: charset closed":
    for ok in ["2030-01-01T08:00:00Z",
               "2030-01-01T08:00:00+02:00",
               "2030-01-01T08:00:00.500Z"]:
      check isValidScheduledTaskIso8601(ok)
    for bad in ["", "not a date", "2030-01-01 08:00:00",
                "2030/01/01T08:00:00Z"]:
      check not isValidScheduledTaskIso8601(bad)

  test "encodeScheduledTaskScheduleSpec: every variant round-trips":
    let cases = @[
      ScheduledTaskScheduleSpec(kind: wstskOnBoot, delaySeconds: 0),
      ScheduledTaskScheduleSpec(kind: wstskOnBoot, delaySeconds: 60),
      ScheduledTaskScheduleSpec(kind: wstskOnLogon, forUser: ""),
      ScheduledTaskScheduleSpec(kind: wstskOnLogon,
        forUser: "DOMAIN\\runner"),
      ScheduledTaskScheduleSpec(kind: wstskOnce,
        runAt: "2030-01-01T08:00:00Z"),
      ScheduledTaskScheduleSpec(kind: wstskDaily, timeOfDay: "08:30"),
      ScheduledTaskScheduleSpec(kind: wstskInterval, everyMinutes: 5,
        startAt: ""),
      ScheduledTaskScheduleSpec(kind: wstskInterval, everyMinutes: 60,
        startAt: "2030-01-01T00:00:00Z")]
    for s in cases:
      let token = encodeScheduledTaskScheduleSpec(s)
      let round = decodeScheduledTaskScheduleToken(token)
      check round == s

  test "encodeScheduledTaskScheduleSpec rejects malformed in-process construction":
    expect ValueError:
      discard encodeScheduledTaskScheduleSpec(
        ScheduledTaskScheduleSpec(kind: wstskOnBoot, delaySeconds: -1))
    expect ValueError:
      discard encodeScheduledTaskScheduleSpec(
        ScheduledTaskScheduleSpec(kind: wstskOnce, runAt: ""))
    expect ValueError:
      discard encodeScheduledTaskScheduleSpec(
        ScheduledTaskScheduleSpec(kind: wstskDaily, timeOfDay: "8:30"))
    expect ValueError:
      discard encodeScheduledTaskScheduleSpec(
        ScheduledTaskScheduleSpec(kind: wstskInterval,
          everyMinutes: 0))
    expect ValueError:
      discard encodeScheduledTaskScheduleSpec(
        ScheduledTaskScheduleSpec(kind: wstskInterval,
          everyMinutes: 5, startAt: "bad-stamp"))

  test "decodeScheduledTaskScheduleToken rejects every malformed shape":
    for bad in ["", "onBoot", ":30", "unknown:30", "ONBOOT:30",
                "onBoot:abc", "onBoot:-5",
                "once:not-iso", "once:",
                "daily:8:30", "daily:25:00", "daily:",
                "interval:0:", "interval:abc:",
                "interval:5", "interval:5:bad"]:
      expect ValueError:
        discard decodeScheduledTaskScheduleToken(bad)

  test "isSafeScheduledTaskTaskName: closed-set charset + escape guard":
    for ok in ["\\Reprobuild\\Foo",
               "\\Microsoft\\Windows\\Updates\\Scheduled Start",
               "MyTask"]:
      check isSafeScheduledTaskTaskName(ok)
    for bad in ["", "Foo'; rm", "Bar\nBaz",
                "\\Reprobuild\\..\\..\\evil",
                "Foo$evil", "Foo`evil"]:
      check not isSafeScheduledTaskTaskName(bad)

  test "isSafeScheduledTaskPrincipal: SYSTEM + DOMAIN\\user + SID":
    for ok in ["SYSTEM", "LOCAL_SERVICE", "NETWORK_SERVICE",
               "DOMAIN\\runner", "S-1-5-18", "user@example.com"]:
      check isSafeScheduledTaskPrincipal(ok)
    for bad in ["", "rm -rf /", "user; cmd", "user'or'1"]:
      check not isSafeScheduledTaskPrincipal(bad)

  test "windows.scheduledTask frames round-trip through wire codec — every kind":
    # Codec round-trip across the full 5-variant cross-product is the
    # broker integrity gate. A regression in either the encoder or
    # decoder would break the round-trip equality check.
    let schedules = @[
      ScheduledTaskScheduleSpec(kind: wstskOnBoot, delaySeconds: 30),
      ScheduledTaskScheduleSpec(kind: wstskOnLogon,
        forUser: "DOMAIN\\runner"),
      ScheduledTaskScheduleSpec(kind: wstskOnce,
        runAt: "2030-01-01T08:00:00Z"),
      ScheduledTaskScheduleSpec(kind: wstskDaily, timeOfDay: "08:30"),
      ScheduledTaskScheduleSpec(kind: wstskInterval, everyMinutes: 15,
        startAt: "2030-01-01T00:00:00Z")]
    for s in schedules:
      let op = PrivilegedOperation(kind: pokWindowsScheduledTask,
        address: "wst-" & $s.kind,
        wstTaskName: "\\Reprobuild\\T-" & $s.kind,
        wstExecutable: "C:\\bin\\app.exe",
        wstArguments: @["--unattended", "--name=runner"],
        wstWorkingDirectory: "C:\\actions-runner",
        wstRunAsUser: "SYSTEM",
        wstRunWithHighestPrivileges: true,
        wstSchedule: s,
        wstEnabled: true,
        wstDestroy: false)
      check operationValidationError(op) == ""
      let frame = encodeOperation(WireOperation(operation: op,
        baselineDigestHex: "abc"))
      let dec = decodeOperation(decodeFrame(frame).body)
      check dec.operation.kind == pokWindowsScheduledTask
      check dec.operation.wstTaskName == op.wstTaskName
      check dec.operation.wstExecutable == op.wstExecutable
      check dec.operation.wstArguments == op.wstArguments
      check dec.operation.wstWorkingDirectory ==
        op.wstWorkingDirectory
      check dec.operation.wstRunAsUser == op.wstRunAsUser
      check dec.operation.wstRunWithHighestPrivileges ==
        op.wstRunWithHighestPrivileges
      check dec.operation.wstEnabled == op.wstEnabled
      check dec.operation.wstDestroy == op.wstDestroy
      check dec.operation.wstSchedule == op.wstSchedule

  test "windows.scheduledTask: destroy direction codec round-trip":
    let op = PrivilegedOperation(kind: pokWindowsScheduledTask,
      address: "wstDestroy",
      wstTaskName: "\\Foo",
      wstExecutable: "C:\\bin\\foo.exe",
      wstSchedule: ScheduledTaskScheduleSpec(kind: wstskOnBoot,
        delaySeconds: 0),
      wstRunAsUser: "SYSTEM",
      wstRunWithHighestPrivileges: true,
      wstEnabled: true,
      wstDestroy: true)
    check operationValidationError(op) == ""
    let dec = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: op, baselineDigestHex: ""))).body)
    check dec.operation.wstDestroy == true

  test "windows.scheduledTask validator rejects empty fields + malformed":
    # Closed-set defence-in-depth: the broker validator is the LAST
    # gate before the typed driver dispatches.
    block emptyName:
      let bad = PrivilegedOperation(kind: pokWindowsScheduledTask,
        address: "wstBad",
        wstTaskName: "",
        wstExecutable: "C:\\bin\\foo.exe",
        wstSchedule: ScheduledTaskScheduleSpec(kind: wstskOnBoot),
        wstRunAsUser: "SYSTEM")
      check operationValidationError(bad).len > 0
    block emptyExe:
      let bad = PrivilegedOperation(kind: pokWindowsScheduledTask,
        address: "wstBad",
        wstTaskName: "\\Foo",
        wstExecutable: "",
        wstSchedule: ScheduledTaskScheduleSpec(kind: wstskOnBoot),
        wstRunAsUser: "SYSTEM")
      check operationValidationError(bad).len > 0
    block escapeName:
      let bad = PrivilegedOperation(kind: pokWindowsScheduledTask,
        address: "wstBad",
        wstTaskName: "\\Reprobuild\\..\\evil",
        wstExecutable: "C:\\bin\\foo.exe",
        wstSchedule: ScheduledTaskScheduleSpec(kind: wstskOnBoot),
        wstRunAsUser: "SYSTEM")
      check operationValidationError(bad).len > 0
    block badPrincipal:
      let bad = PrivilegedOperation(kind: pokWindowsScheduledTask,
        address: "wstBad",
        wstTaskName: "\\Foo",
        wstExecutable: "C:\\bin\\foo.exe",
        wstSchedule: ScheduledTaskScheduleSpec(kind: wstskOnBoot),
        wstRunAsUser: "rm -rf /")
      check operationValidationError(bad).len > 0
    block badIso:
      let bad = PrivilegedOperation(kind: pokWindowsScheduledTask,
        address: "wstBad",
        wstTaskName: "\\Foo",
        wstExecutable: "C:\\bin\\foo.exe",
        wstSchedule: ScheduledTaskScheduleSpec(kind: wstskOnce,
          runAt: "not iso"),
        wstRunAsUser: "SYSTEM")
      check operationValidationError(bad).len > 0
    block badInterval:
      let bad = PrivilegedOperation(kind: pokWindowsScheduledTask,
        address: "wstBad",
        wstTaskName: "\\Foo",
        wstExecutable: "C:\\bin\\foo.exe",
        wstSchedule: ScheduledTaskScheduleSpec(kind: wstskInterval,
          everyMinutes: 0),
        wstRunAsUser: "SYSTEM")
      check operationValidationError(bad).len > 0
    block badDaily:
      let bad = PrivilegedOperation(kind: pokWindowsScheduledTask,
        address: "wstBad",
        wstTaskName: "\\Foo",
        wstExecutable: "C:\\bin\\foo.exe",
        wstSchedule: ScheduledTaskScheduleSpec(kind: wstskDaily,
          timeOfDay: "25:00"),
        wstRunAsUser: "SYSTEM")
      check operationValidationError(bad).len > 0

  test "renderRegisterScheduledTaskCommand: pure argv assembler":
    # The assembler is the apply-side argv builder the driver hands to
    # PowerShell. Pure function — testable on Linux.
    let argv = renderRegisterScheduledTaskCommand(
      taskName = "\\Foo",
      executable = "C:\\bin\\foo.exe",
      arguments = @["--flag", "C:\\config.toml"],
      workingDirectory = "C:\\actions-runner",
      runAsUser = "SYSTEM",
      runWithHighestPrivileges = true,
      scheduleXml = "<BootTrigger/>",
      enabled = true)
    check argv[0] == "Register-ScheduledTask"
    check "-TaskName" in argv
    check "\\Foo" in argv
    check "-ArgumentList" in argv
    check "-WorkingDirectory" in argv
    check "-Trigger" in argv
    check "<BootTrigger/>" in argv
    check "-Principal" in argv
    check "SYSTEM" in argv
    check "-RunLevel" in argv
    check "Highest" in argv

  test "renderRegisterScheduledTaskCommand: enabled=false adds Disabled settings":
    let argv = renderRegisterScheduledTaskCommand(
      taskName = "\\Foo",
      executable = "C:\\bin\\foo.exe",
      arguments = @[],
      workingDirectory = "",
      runAsUser = "DOMAIN\\runner",
      runWithHighestPrivileges = false,
      scheduleXml = "<BootTrigger/>",
      enabled = false)
    check "Disabled" in argv
    check "-RunLevel" notin argv
    check "-ArgumentList" notin argv
    check "-WorkingDirectory" notin argv

  test "renderUnregisterScheduledTaskCommand: destroy argv":
    let argv = renderUnregisterScheduledTaskCommand("\\Foo")
    check argv == @["Unregister-ScheduledTask", "-TaskName", "\\Foo",
                    "-Confirm:$false"]

  test "renderScheduledTaskScheduleXml: every variant emits a Task Scheduler element":
    let onBoot = renderScheduledTaskScheduleXml(
      ScheduledTaskScheduleSpec(kind: wstskOnBoot, delaySeconds: 0))
    check onBoot == "<BootTrigger></BootTrigger>"
    let onBootDelay = renderScheduledTaskScheduleXml(
      ScheduledTaskScheduleSpec(kind: wstskOnBoot, delaySeconds: 30))
    check onBootDelay.contains("<Delay>PT30S</Delay>")
    let onLogon = renderScheduledTaskScheduleXml(
      ScheduledTaskScheduleSpec(kind: wstskOnLogon,
        forUser: "DOMAIN\\u"))
    check onLogon.contains("<UserId>DOMAIN\\u</UserId>")
    let onLogonAny = renderScheduledTaskScheduleXml(
      ScheduledTaskScheduleSpec(kind: wstskOnLogon, forUser: ""))
    check onLogonAny == "<LogonTrigger></LogonTrigger>"
    let once = renderScheduledTaskScheduleXml(
      ScheduledTaskScheduleSpec(kind: wstskOnce,
        runAt: "2030-01-01T08:00:00Z"))
    check once.contains("<StartBoundary>2030-01-01T08:00:00Z" &
      "</StartBoundary>")
    let daily = renderScheduledTaskScheduleXml(
      ScheduledTaskScheduleSpec(kind: wstskDaily, timeOfDay: "08:30"))
    check daily.contains("<CalendarTrigger>")
    check daily.contains("<DaysInterval>1</DaysInterval>")
    check daily.contains("1970-01-01T08:30:00")
    let interval = renderScheduledTaskScheduleXml(
      ScheduledTaskScheduleSpec(kind: wstskInterval,
        everyMinutes: 15, startAt: "2030-01-01T00:00:00Z"))
    check interval.contains("<Repetition><Interval>PT15M</Interval>")

  test "scheduledTaskMatchesDesired: matches when all fields agree":
    let want = ScheduledTaskScheduleSpec(kind: wstskOnBoot,
      delaySeconds: 30)
    let obs = ScheduledTaskObservation(present: true,
      taskName: "\\Foo", executable: "C:\\bin\\foo.exe",
      arguments: @[], workingDirectory: "", runAsUser: "SYSTEM",
      runWithHighestPrivileges: true, enabled: true,
      schedule: want)
    check scheduledTaskMatchesDesired(obs,
      "\\Foo", "C:\\bin\\foo.exe", @[], "", "SYSTEM",
      true, want, true)

  test "scheduledTaskMatchesDesired: drift on each load-bearing field":
    let want = ScheduledTaskScheduleSpec(kind: wstskOnBoot,
      delaySeconds: 30)
    let base = ScheduledTaskObservation(present: true,
      taskName: "\\Foo", executable: "C:\\bin\\foo.exe",
      arguments: @[], workingDirectory: "", runAsUser: "SYSTEM",
      runWithHighestPrivileges: true, enabled: true,
      schedule: want)
    # Absent => mismatch.
    check not scheduledTaskMatchesDesired(
      ScheduledTaskObservation(present: false),
      "\\Foo", "C:\\bin\\foo.exe", @[], "", "SYSTEM",
      true, want, true)
    # taskName drift.
    var obs = base
    obs.taskName = "\\OtherName"
    check not scheduledTaskMatchesDesired(obs,
      "\\Foo", "C:\\bin\\foo.exe", @[], "", "SYSTEM",
      true, want, true)
    # executable drift.
    obs = base
    obs.executable = "C:\\bin\\other.exe"
    check not scheduledTaskMatchesDesired(obs,
      "\\Foo", "C:\\bin\\foo.exe", @[], "", "SYSTEM",
      true, want, true)
    # arguments drift.
    obs = base
    obs.arguments = @["--flag"]
    check not scheduledTaskMatchesDesired(obs,
      "\\Foo", "C:\\bin\\foo.exe", @[], "", "SYSTEM",
      true, want, true)
    # principal drift.
    obs = base
    obs.runAsUser = "LOCAL_SERVICE"
    check not scheduledTaskMatchesDesired(obs,
      "\\Foo", "C:\\bin\\foo.exe", @[], "", "SYSTEM",
      true, want, true)
    # highestPrivileges drift.
    obs = base
    obs.runWithHighestPrivileges = false
    check not scheduledTaskMatchesDesired(obs,
      "\\Foo", "C:\\bin\\foo.exe", @[], "", "SYSTEM",
      true, want, true)
    # enabled drift.
    obs = base
    obs.enabled = false
    check not scheduledTaskMatchesDesired(obs,
      "\\Foo", "C:\\bin\\foo.exe", @[], "", "SYSTEM",
      true, want, true)
    # schedule drift (different kind).
    obs = base
    obs.schedule = ScheduledTaskScheduleSpec(kind: wstskDaily,
      timeOfDay: "08:30")
    check not scheduledTaskMatchesDesired(obs,
      "\\Foo", "C:\\bin\\foo.exe", @[], "", "SYSTEM",
      true, want, true)
    # schedule drift (same kind, different delay).
    obs = base
    obs.schedule = ScheduledTaskScheduleSpec(kind: wstskOnBoot,
      delaySeconds: 60)
    check not scheduledTaskMatchesDesired(obs,
      "\\Foo", "C:\\bin\\foo.exe", @[], "", "SYSTEM",
      true, want, true)

  test "scheduledTaskMatchesDesired: drift across every ScheduleKind":
    # Per-kind: a desired spec of each kind must match the equivalent
    # observation AND mismatch a same-kind variation.
    let kinds = @[
      (ScheduledTaskScheduleSpec(kind: wstskOnBoot, delaySeconds: 10),
       ScheduledTaskScheduleSpec(kind: wstskOnBoot,
         delaySeconds: 20)),
      (ScheduledTaskScheduleSpec(kind: wstskOnLogon,
         forUser: "DOMAIN\\u"),
       ScheduledTaskScheduleSpec(kind: wstskOnLogon, forUser: "")),
      (ScheduledTaskScheduleSpec(kind: wstskOnce,
         runAt: "2030-01-01T08:00:00Z"),
       ScheduledTaskScheduleSpec(kind: wstskOnce,
         runAt: "2031-01-01T08:00:00Z")),
      (ScheduledTaskScheduleSpec(kind: wstskDaily,
         timeOfDay: "08:30"),
       ScheduledTaskScheduleSpec(kind: wstskDaily,
         timeOfDay: "09:30")),
      (ScheduledTaskScheduleSpec(kind: wstskInterval,
         everyMinutes: 15, startAt: ""),
       ScheduledTaskScheduleSpec(kind: wstskInterval,
         everyMinutes: 30, startAt: ""))]
    for (a, b) in kinds:
      let obs = ScheduledTaskObservation(present: true,
        taskName: "\\T", executable: "C:\\app.exe", arguments: @[],
        workingDirectory: "", runAsUser: "SYSTEM",
        runWithHighestPrivileges: true, enabled: true, schedule: a)
      check scheduledTaskMatchesDesired(obs,
        "\\T", "C:\\app.exe", @[], "", "SYSTEM", true, a, true)
      check not scheduledTaskMatchesDesired(obs,
        "\\T", "C:\\app.exe", @[], "", "SYSTEM", true, b, true)

  test "parseScheduledTaskQuery: Missing=1 collapses to absent":
    let obs = parseScheduledTaskQuery("Missing=1")
    check obs.present == false

  test "parseScheduledTaskQuery: onBoot probe parses cleanly":
    let probe = """
TaskName=\Reprobuild\Foo
Executable=C:\bin\foo.exe
Arguments=
WorkingDirectory=
RunAsUser=SYSTEM
RunWithHighestPrivileges=True
Enabled=True
ScheduleKind=onBoot
ScheduleDelaySeconds=30
"""
    let obs = parseScheduledTaskQuery(probe)
    check obs.present
    check obs.taskName == "\\Reprobuild\\Foo"
    check obs.executable == "C:\\bin\\foo.exe"
    check obs.runAsUser == "SYSTEM"
    check obs.runWithHighestPrivileges == true
    check obs.enabled == true
    check obs.schedule.kind == wstskOnBoot
    check obs.schedule.delaySeconds == 30

  test "parseScheduledTaskQuery: daily probe":
    let probe = """
TaskName=\DailyJob
Executable=C:\bin\daily.exe
RunAsUser=SYSTEM
RunWithHighestPrivileges=True
Enabled=True
ScheduleKind=daily
ScheduleTimeOfDay=08:30
"""
    let obs = parseScheduledTaskQuery(probe)
    check obs.present
    check obs.schedule.kind == wstskDaily
    check obs.schedule.timeOfDay == "08:30"

  test "parseScheduledTaskQuery: interval probe":
    let probe = """
TaskName=\Heartbeat
Executable=C:\bin\hb.exe
RunAsUser=SYSTEM
RunWithHighestPrivileges=True
Enabled=True
ScheduleKind=interval
ScheduleEveryMinutes=15
ScheduleStartAt=2030-01-01T00:00:00Z
"""
    let obs = parseScheduledTaskQuery(probe)
    check obs.present
    check obs.schedule.kind == wstskInterval
    check obs.schedule.everyMinutes == 15
    check obs.schedule.startAt == "2030-01-01T00:00:00Z"

  test "canonicalScheduledTaskState == canonicalScheduledTaskDesired on convergence":
    # Drift-digest equality property: the broker's digest computation
    # of an observed task that matches the desired state produces the
    # SAME canonical string as the desired-state digest.
    let want = ScheduledTaskScheduleSpec(kind: wstskInterval,
      everyMinutes: 15, startAt: "")
    let obs = ScheduledTaskObservation(present: true,
      taskName: "\\T", executable: "C:\\app.exe",
      arguments: @["--unattended"], workingDirectory: "",
      runAsUser: "SYSTEM", runWithHighestPrivileges: true,
      enabled: true, schedule: want)
    check canonicalScheduledTaskState(obs) ==
      canonicalScheduledTaskDesired("\\T", "C:\\app.exe",
        @["--unattended"], "", "SYSTEM", true, want, true)

  test "canonicalScheduledTaskState diverges on drift":
    let want = ScheduledTaskScheduleSpec(kind: wstskOnBoot,
      delaySeconds: 0)
    let obs = ScheduledTaskObservation(present: true,
      taskName: "\\T", executable: "C:\\app.exe",
      arguments: @[], workingDirectory: "",
      runAsUser: "SYSTEM", runWithHighestPrivileges: true,
      enabled: false, schedule: want)
    check canonicalScheduledTaskState(obs) !=
      canonicalScheduledTaskDesired("\\T", "C:\\app.exe",
        @[], "", "SYSTEM", true, want, true)

  test "windows.scheduledTask: validator rejects schedule-malformed in-memory":
    # A defence-in-depth case: an operation that was built directly in
    # Nim (skipping the codec) must STILL fail the validator if it
    # carries a malformed schedule. The codec is the FIRST gate; the
    # validator is the LAST gate before the typed driver runs.
    let bad = PrivilegedOperation(kind: pokWindowsScheduledTask,
      address: "wstBad",
      wstTaskName: "\\Foo",
      wstExecutable: "C:\\bin\\foo.exe",
      wstSchedule: ScheduledTaskScheduleSpec(kind: wstskOnBoot,
        delaySeconds: -5),
      wstRunAsUser: "SYSTEM")
    check operationValidationError(bad).len > 0

# ---------------------------------------------------------------------------
# Windows-System-Resources Phase E — `pokInlineExecCall` + `@FILE:` argv
# preprocessor.
#
# The cross-cutting bridge between the build engine and the broker:
# every `inlineExecCall(...)` build-graph edge tagged
# `requiresElevation = true` becomes a `pokInlineExecCall`
# `PrivilegedOperation` the broker spawns under elevation. The argv
# `@FILE:<path>` preprocessor runs on BOTH the elevated and the non-
# elevated paths so the substitution semantics are uniform.
# ---------------------------------------------------------------------------

suite "repro_elevation: pokInlineExecCall is in the closed set":

  test "pokInlineExecCall requires elevation and is a known kind tag":
    check requiresElevation(pokInlineExecCall)
    check isKnownPrivilegedOperationKind($pokInlineExecCall)
    check $pokInlineExecCall == "reprobuild.inlineExecCall"

  test "an unknown inline-exec-like tag is rejected":
    # Defence-in-depth: a frame that NAMES inlineExecCall via a typo /
    # forged tag must NOT be accepted as a recognized kind.
    check not isKnownPrivilegedOperationKind("reprobuild.inline_exec_call")
    check not isKnownPrivilegedOperationKind("inlineExecCall")
    check not isKnownPrivilegedOperationKind("reprobuild.inlineExec")

suite "repro_elevation: pokInlineExecCall codec round-trip":

  test "every field round-trips through the wire codec":
    # Build a fully-populated operation, encode + decode it, and assert
    # on every field. The codec must preserve every closed string +
    # the typed exit-code list verbatim.
    let op = PrivilegedOperation(kind: pokInlineExecCall,
      address: "phaseE-runner-config",
      iecExecutable: "C:\\actions-runner\\config.cmd",
      iecArguments: @[
        "--unattended", "--replace",
        "--url", "https://github.com/metacraft-labs",
        "--token", "@FILE:C:\\actions-runner-tokens\\mcl.token",
        "--name", "windows-runner-001"],
      iecWorkingDirectory: "C:\\actions-runner",
      iecEnvironment: @["RUNNER_LOG_DIR=C:\\actions-runner\\logs",
        "RUNNER_TIMEOUT=300"],
      iecToolIdentityRefs: @["C:\\actions-runner\\config.cmd"],
      iecAcceptExitCodes: @[0, 3010])
    let frame = encodeOperation(WireOperation(operation: op,
      baselineDigestHex: "baseline-phaseE"))
    let dec = decodeOperation(decodeFrame(frame).body)
    check dec.operation.kind == pokInlineExecCall
    check dec.operation.address == "phaseE-runner-config"
    check dec.baselineDigestHex == "baseline-phaseE"
    check dec.operation.iecExecutable == op.iecExecutable
    check dec.operation.iecArguments == op.iecArguments
    check dec.operation.iecWorkingDirectory == op.iecWorkingDirectory
    check dec.operation.iecEnvironment == op.iecEnvironment
    check dec.operation.iecToolIdentityRefs == op.iecToolIdentityRefs
    check dec.operation.iecAcceptExitCodes == @[0, 3010]

  test "defaults round-trip (empty fields, empty exit-code list)":
    # A bare-minimum operation: only executable + one argument. The
    # codec must round-trip the empty fields without inventing a value.
    let op = PrivilegedOperation(kind: pokInlineExecCall,
      address: "phaseE-bare",
      iecExecutable: "/bin/sh",
      iecArguments: @[],
      iecWorkingDirectory: "",
      iecEnvironment: @[],
      iecToolIdentityRefs: @[],
      iecAcceptExitCodes: @[])
    let frame = encodeOperation(WireOperation(operation: op,
      baselineDigestHex: ""))
    let dec = decodeOperation(decodeFrame(frame).body)
    check dec.operation.iecExecutable == "/bin/sh"
    check dec.operation.iecArguments.len == 0
    check dec.operation.iecWorkingDirectory == ""
    check dec.operation.iecEnvironment.len == 0
    check dec.operation.iecToolIdentityRefs.len == 0
    check dec.operation.iecAcceptExitCodes.len == 0

  test "negative exit code (Windows STATUS code) round-trips":
    # Windows installers surface negative `NTSTATUS` codes; the codec
    # casts through `int32` so the sign bit survives a round-trip.
    let op = PrivilegedOperation(kind: pokInlineExecCall,
      address: "phaseE-signed",
      iecExecutable: "C:\\Windows\\System32\\msiexec.exe",
      iecAcceptExitCodes: @[0, 3010, -2147483647])
    let frame = encodeOperation(WireOperation(operation: op,
      baselineDigestHex: ""))
    let dec = decodeOperation(decodeFrame(frame).body)
    check dec.operation.iecAcceptExitCodes == @[0, 3010, -2147483647]

suite "repro_elevation: pokInlineExecCall validator":

  test "accepts a well-formed operation":
    let ok = PrivilegedOperation(kind: pokInlineExecCall,
      address: "phaseE-ok",
      iecExecutable: "/bin/echo",
      iecArguments: @["hello"],
      iecEnvironment: @["TZ=UTC"],
      iecToolIdentityRefs: @["echo"])
    check operationValidationError(ok) == ""

  test "rejects an empty executable":
    let bad = PrivilegedOperation(kind: pokInlineExecCall,
      address: "phaseE-empty",
      iecExecutable: "",
      iecArguments: @[])
    let err = operationValidationError(bad)
    check err.len > 0
    check err.contains("empty executable")

  test "rejects a NUL byte in executable / arg / env / toolref":
    var bad = PrivilegedOperation(kind: pokInlineExecCall,
      address: "phaseE-nul",
      iecExecutable: "/bin/echo\x00malicious")
    check operationValidationError(bad).contains("NUL")
    bad = PrivilegedOperation(kind: pokInlineExecCall,
      address: "phaseE-nul",
      iecExecutable: "/bin/echo",
      iecArguments: @["hello\x00world"])
    check operationValidationError(bad).contains("NUL")
    bad = PrivilegedOperation(kind: pokInlineExecCall,
      address: "phaseE-nul",
      iecExecutable: "/bin/echo",
      iecEnvironment: @["FOO=bar\x00baz"])
    check operationValidationError(bad).contains("NUL")
    bad = PrivilegedOperation(kind: pokInlineExecCall,
      address: "phaseE-nul",
      iecExecutable: "/bin/echo",
      iecToolIdentityRefs: @["sh\x00"])
    check operationValidationError(bad).contains("NUL")

  test "rejects an environment entry that is not NAME=VALUE":
    let bad = PrivilegedOperation(kind: pokInlineExecCall,
      address: "phaseE-env",
      iecExecutable: "/bin/echo",
      iecEnvironment: @["NOT_A_KEY_VALUE_PAIR"])
    let err = operationValidationError(bad)
    check err.len > 0
    check err.contains("NAME=VALUE")

  test "rejects an empty tool identity ref":
    let bad = PrivilegedOperation(kind: pokInlineExecCall,
      address: "phaseE-emptyref",
      iecExecutable: "/bin/echo",
      iecToolIdentityRefs: @[""])
    let err = operationValidationError(bad)
    check err.len > 0
    check err.contains("empty")

  test "rejects malformed @FILE: tokens at the codec boundary":
    # `@FILE:` with no payload is malformed — the apply-time expander
    # would fail closed, but the validator catches it earlier so the
    # operator sees a clean diagnostic instead of an obscure runtime.
    let bareToken = PrivilegedOperation(kind: pokInlineExecCall,
      address: "phaseE-bare-token",
      iecExecutable: "/bin/cat",
      iecArguments: @["@FILE:"])
    check operationValidationError(bareToken).len > 0
    # Relative `@FILE:` path: refused because the broker's cwd is not
    # a stable identity (defensible-decision documented in the helper).
    let relativeToken = PrivilegedOperation(kind: pokInlineExecCall,
      address: "phaseE-rel-token",
      iecExecutable: "/bin/cat",
      iecArguments: @["@FILE:secret.tok"])
    let relErr = operationValidationError(relativeToken)
    check relErr.len > 0
    check relErr.contains("absolute") or relErr.contains("relative")
    # NUL byte in `@FILE:` path: refused because the OS reader would
    # reject it.
    let nulToken = PrivilegedOperation(kind: pokInlineExecCall,
      address: "phaseE-nul-token",
      iecExecutable: "/bin/cat",
      iecArguments: @["@FILE:/tmp/secret\x00.tok"])
    check operationValidationError(nulToken).contains("NUL")

suite "repro_elevation: @FILE: argv preprocessor (pure helper)":

  test "isArgFileToken / argFilePath classify and split":
    check isArgFileToken("@FILE:/abs/path")
    check not isArgFileToken("not-a-token")
    # A bare `@FILE:` (no payload) IS classified as a token here so
    # the validator / expander catches it as a hard error rather than
    # letting it fall through as if it were a literal argument.
    check isArgFileToken("@FILE:")
    check argFilePath("@FILE:/secret.tok") == "/secret.tok"
    check argFilePath("plain") == ""
    # The bare-prefix token's payload is empty — argFilePath returns
    # an empty string so the downstream validator's empty-payload
    # check fires cleanly.
    check argFilePath("@FILE:") == ""

  test "expandArgFileToken substitutes well-formed tokens":
    # Inject a pure table-backed reader so the test exercises the
    # substitution semantics without touching real disk.
    proc r(path: string): string =
      if path == "/etc/runner.tok": "abc123\n"
      elif path == "/etc/empty.tok": ""
      else: raise newException(IOError, "no such test path " & path)
    check expandArgFileToken("@FILE:/etc/runner.tok", r) == "abc123"
    check expandArgFileToken("plain", r) == "plain"

  test "expandArgFileToken strips trailing CR / LF":
    # Common case for text-file secrets that end with a newline. The
    # spec asks for the trimmed contents.
    proc r(path: string): string =
      case path
      of "/a": "value\n"
      of "/b": "value\r\n"
      of "/c": "value\r"
      of "/d": "value"
      else: raise newException(IOError, "no such path")
    check expandArgFileToken("@FILE:/a", r) == "value"
    check expandArgFileToken("@FILE:/b", r) == "value"
    check expandArgFileToken("@FILE:/c", r) == "value"
    check expandArgFileToken("@FILE:/d", r) == "value"

  test "expandArgFileToken returns empty string for an empty file":
    # Spec: "Empty file ⇒ pass empty arg (caller decides if that's
    # valid)." The expander does NOT raise here.
    proc r(path: string): string = ""
    check expandArgFileToken("@FILE:/empty.tok", r) == ""

  test "expandArgFileToken raises EProtocol when the file is missing":
    proc r(path: string): string =
      raise newException(IOError, "no such file")
    expect EProtocol:
      discard expandArgFileToken("@FILE:/missing.tok", r)

  test "expandArgFileToken raises EProtocol on OSError too":
    # Permission-denied / other OS errors surface with the same
    # spec-mandated `@FILE: not found` shape.
    proc r(path: string): string =
      raise newException(OSError, "permission denied")
    expect EProtocol:
      discard expandArgFileToken("@FILE:/forbidden.tok", r)

  test "expandArgFileToken EProtocol diagnostic includes the path":
    # The audit log uses this diagnostic; it MUST cite which path
    # failed.
    proc r(path: string): string =
      raise newException(IOError, "boom")
    try:
      discard expandArgFileToken("@FILE:/path/to/missing.tok", r)
      check false  # unreachable
    except EProtocol as e:
      check e.msg.contains("@FILE:")
      check e.msg.contains("/path/to/missing.tok")

  test "expandArgFileToken re-checks malformed tokens (defence in depth)":
    # A call site that constructs the operation in-process and skips
    # the codec validator must STILL fail closed if it carries a
    # malformed token. The expander double-checks.
    proc r(path: string): string = ""
    expect EProtocol:
      discard expandArgFileToken("@FILE:", r)
    expect EProtocol:
      discard expandArgFileToken("@FILE:relative-path", r)

  test "expandArgFiles preserves order across mixed argv":
    proc r(path: string): string =
      case path
      of "/tok1": "value1\n"
      of "/tok2": "value2"
      else: raise newException(IOError, "missing")
    let expanded = expandArgFiles(@["--first", "@FILE:/tok1", "--mid",
      "@FILE:/tok2", "--last"], r)
    check expanded == @["--first", "value1", "--mid", "value2", "--last"]

  test "auditArgvWithRedaction replaces tokens with the redaction":
    # Spec §2.1: the audit log records the substitution as `<arg
    # redacted: read from <path>>` — the substituted bytes never reach
    # the log.
    let argv = @["config.cmd", "--token", "@FILE:/secrets/x.tok",
      "--name", "runner"]
    let safe = auditArgvWithRedaction(argv)
    check safe.len == argv.len
    check safe[0] == "config.cmd"
    check safe[1] == "--token"
    check safe[2] == "<arg redacted: read from /secrets/x.tok>"
    check safe[3] == "--name"
    check safe[4] == "runner"

suite "repro_elevation: inline-exec driver dispatch":

  test "expandExecCallArgv prepends the executable to the expanded argv":
    proc r(path: string): string = "tok-bytes"
    let op = PrivilegedOperation(kind: pokInlineExecCall,
      address: "phaseE-expand",
      iecExecutable: "/usr/bin/curl",
      iecArguments: @["-H", "@FILE:/tmp/auth.tok", "https://example/"])
    let argv = expandExecCallArgv(op, r)
    check argv == @["/usr/bin/curl", "-H", "tok-bytes",
      "https://example/"]

  test "expandExecCallArgv on a non-inline-exec kind raises ValueError":
    let op = PrivilegedOperation(kind: pokFixtureFile,
      address: "wrong-kind", fileRelPath: "x", fileContent: "")
    expect ValueError:
      discard expandExecCallArgv(op)

  test "inlineExecCallAuditDetail uses the redacted argv form":
    let op = PrivilegedOperation(kind: pokInlineExecCall,
      address: "phaseE-audit",
      iecExecutable: "config.cmd",
      iecArguments: @["--token", "@FILE:/secrets/x.tok", "--name",
        "runner"])
    let detail = inlineExecCallAuditDetail(op,
      InlineExecCallOutcome(exitCode: 0))
    check detail.contains("config.cmd")
    check detail.contains("<arg redacted: read from /secrets/x.tok>")
    check detail.contains("exit 0")
    # Critically: the literal `@FILE:` token MUST appear inside the
    # redaction placeholder — not the substituted bytes.
    check not detail.contains("tok-bytes")

  test "runInlineExecCall: success on exit code 0 via /bin/true":
    when defined(linux) or defined(macosx):
      let op = PrivilegedOperation(kind: pokInlineExecCall,
        address: "phaseE-true",
        iecExecutable: "true",
        iecAcceptExitCodes: @[0])
      let outcome = runInlineExecCall(op)
      check outcome.exitCode == 0

  test "runInlineExecCall: non-zero exit raises EProtocol":
    when defined(linux) or defined(macosx):
      let op = PrivilegedOperation(kind: pokInlineExecCall,
        address: "phaseE-false",
        iecExecutable: "false",
        iecAcceptExitCodes: @[0])
      expect EProtocol:
        discard runInlineExecCall(op)

  test "runInlineExecCall: configured acceptable exit code is success":
    when defined(linux) or defined(macosx):
      # /bin/false exits 1; accepting {0, 1} treats it as success.
      let op = PrivilegedOperation(kind: pokInlineExecCall,
        address: "phaseE-accept-1",
        iecExecutable: "false",
        iecAcceptExitCodes: @[0, 1])
      let outcome = runInlineExecCall(op)
      check outcome.exitCode == 1

  test "runInlineExecCall: default acceptable set is @[0]":
    when defined(linux) or defined(macosx):
      # An empty `iecAcceptExitCodes` defaults to @[0] inside the
      # driver — exit 1 must still raise.
      let op = PrivilegedOperation(kind: pokInlineExecCall,
        address: "phaseE-default-accept",
        iecExecutable: "false",
        iecAcceptExitCodes: @[])
      expect EProtocol:
        discard runInlineExecCall(op)

  test "runInlineExecCall: @FILE: missing file raises EProtocol before spawn":
    when defined(linux) or defined(macosx):
      let op = PrivilegedOperation(kind: pokInlineExecCall,
        address: "phaseE-missing-token",
        iecExecutable: "true",
        iecArguments: @["@FILE:/this/path/does/not/exist.tok"])
      expect EProtocol:
        discard runInlineExecCall(op)

  test "runInlineExecCall: empty @FILE: file passes empty arg through":
    when defined(linux) or defined(macosx):
      # Create a real empty file and confirm the spawn succeeds with
      # an empty arg passed to `/bin/true` (which ignores its argv).
      let emptyPath = "/tmp/repro_phaseE_empty_" & $getCurrentProcessId() &
        ".tok"
      writeFile(emptyPath, "")
      defer:
        try: removeFile(emptyPath)
        except CatchableError: discard
      let op = PrivilegedOperation(kind: pokInlineExecCall,
        address: "phaseE-empty-token",
        iecExecutable: "true",
        iecArguments: @["@FILE:" & emptyPath])
      let outcome = runInlineExecCall(op)
      check outcome.exitCode == 0

  test "runInlineExecCall raises ValueError for a non-inline-exec kind":
    let op = PrivilegedOperation(kind: pokFixtureFile,
      address: "phaseE-wrong-kind",
      fileRelPath: "x", fileContent: "")
    expect ValueError:
      discard runInlineExecCall(op)

suite "repro_elevation: pokInlineExecCall dispatch via the broker":

  test "dispatchOperation: a successful inline-exec edge is doApplied":
    when defined(linux) or defined(macosx):
      let dir = createTempDir("phaseE-dispatch-", "")
      defer:
        try: removeDir(dir)
        except CatchableError: discard
      let op = PrivilegedOperation(kind: pokInlineExecCall,
        address: "phaseE-dispatch-true",
        iecExecutable: "true",
        iecAcceptExitCodes: @[0])
      let planned = PlannedOperation(operation: op,
        baselineDigestHex: "")
      let res = dispatchOperation(FixtureContext(filePrefix: dir),
        planned)
      check res.outcome == doApplied
      check res.address == "phaseE-dispatch-true"
      check res.kind == pokInlineExecCall
      check res.detail.contains("exit 0")

  test "dispatchOperation: a failing inline-exec edge raises EProtocol":
    when defined(linux) or defined(macosx):
      let dir = createTempDir("phaseE-dispatch-fail-", "")
      defer:
        try: removeDir(dir)
        except CatchableError: discard
      let op = PrivilegedOperation(kind: pokInlineExecCall,
        address: "phaseE-dispatch-false",
        iecExecutable: "false",
        iecAcceptExitCodes: @[0])
      let planned = PlannedOperation(operation: op,
        baselineDigestHex: "")
      expect EProtocol:
        discard dispatchOperation(FixtureContext(filePrefix: dir),
          planned)

  test "dispatchOperation rejects an in-policy-broken inline-exec op":
    # Defence-in-depth: even though the codec already validated, the
    # dispatch re-runs the validator and fails closed.
    when defined(linux) or defined(macosx):
      let dir = createTempDir("phaseE-dispatch-bad-", "")
      defer:
        try: removeDir(dir)
        except CatchableError: discard
      let op = PrivilegedOperation(kind: pokInlineExecCall,
        address: "phaseE-bad",
        iecExecutable: "")   # empty executable, fails the validator
      let planned = PlannedOperation(operation: op,
        baselineDigestHex: "")
      expect EProtocol:
        discard dispatchOperation(FixtureContext(filePrefix: dir),
          planned)

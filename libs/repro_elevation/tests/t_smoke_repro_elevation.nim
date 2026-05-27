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
    # M82 Phase A removes the dispatch-layer apply-time drift gate that
    # this test exercises (the `raiseBrokerDrift` on
    # observed != recorded-baseline AND observed != desired in
    # `dispatch.dispatchOperation`). The contract it documents — refuse
    # to overwrite a third-party out-of-band edit — does NOT go away;
    # it migrates to plan time per Planner-Apply-Refresh-Model.md and
    # the M82 milestone entry: `repro infra plan` / `repro home plan`
    # will compare observed state against the previously-applied
    # generation's recorded state and surface external drift with a
    # user-confirmation flow before any apply runs. The integrity
    # check at apply time is the driver's post-apply re-probe (the
    # `applyWindowsService` precedent from `f19a0ed`, extended to the
    # rest of the system-scope drivers in M82 Phase A Deliverable 1).
    # This test is preserved (not deleted) because it documents the
    # contract; it migrates to plan-time external-drift detection in
    # M82 Phase C.
    skip()
    # Phase A removes apply-time drift gate; this scenario migrates to
    # plan-time external-drift detection in M82 Phase C.
    when false:
      let prefix = createTempDir("repro-elev-unit-", "")
      defer: removeDir(prefix)
      let ctx = FixtureContext(filePrefix: prefix)
      let op = PrivilegedOperation(kind: pokFixtureFile, address: "f2",
        fileRelPath: "data.txt", fileContent: "desired content")
      # The plan's baseline says the target held "plan-time content".
      let planBaseline = desiredDigestHex(PrivilegedOperation(
        kind: pokFixtureFile, address: "f2", fileRelPath: "data.txt",
        fileContent: "plan-time content"))
      # But the real world now holds something a third party changed.
      writeFile(prefix / "data.txt", "a hostile out-of-band edit")
      expect EBrokerDrift:
        discard dispatchOperation(ctx,
          PlannedOperation(operation: op, baselineDigestHex: planBaseline))
      # The drifted file was NOT overwritten.
      check readFile(prefix / "data.txt") == "a hostile out-of-band edit"

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
              pokEnvSystemVariable, pokPasswdUser]:
      check requiresElevation(k)
      check isKnownPrivilegedOperationKind($k)
    check not isKnownPrivilegedOperationKind("posix.runArbitraryCommand")

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

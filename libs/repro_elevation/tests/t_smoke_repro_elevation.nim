## Library-local unit tests for the M81 privileged-operation broker
## library. Covers the PLATFORM-PURE surface — partition, the
## `requiresElevation` predicate, the RBEB codec round-trips, the
## closed-set validation, the sandbox-escape guard, and the
## fixture file driver's drift contract. These run everywhere
## (Windows, Linux, macOS); the Windows-only IPC / broker-launch
## path is exercised by the M81 integration gate.

import std/[os, strutils, tempfiles, unittest]

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

  test "broker fails closed on a drifted file":
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

  test "a safe update (observed == baseline) is applied":
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

import std/[envvars, options, os, strutils, unittest]
import repro_test_support/reasoned_skip
when defined(posix):
  import std/posix

import repro_hcr_agent
import repro_hcr_test

const
  SupportProfile = "macos-arm64-direct-hcr-in-codetracer-v1"
  FunctionName = "_reprobuild_hcr_patchable_value"

proc resolveTargetSymbol(ctx: pointer; symbolName: string): uint64 =
  let target = cast[ptr FakeTarget](ctx)
  if symbolName == FunctionName:
    target[].entryAddress(symbolName)
  else:
    0

proc runtimeOps(target: var FakeTarget): HcrAgentRuntimeOps =
  HcrAgentRuntimeOps(
    ctx: addr target,
    targetEnv: target.targetOps(),
    resolveTargetSymbol: resolveTargetSymbol)

proc agentHello(): HcrAgentMessage =
  HcrAgentMessage(
    schemaId: HcrAgentProtocolSchemaId,
    transportScope: HcrAgentTransportScope,
    protocolVersion: HcrAgentProtocolVersion,
    messageId: "agent-hello-1",
    kind: hmkHello,
    hello: HcrHello(
      supportProfile: SupportProfile,
      agentPid: 1234,
      capabilities: @["hcr-agent-protocol", "direct-patch-injection"]))

proc coordinatorHelloAck(): HcrAgentMessage =
  HcrAgentMessage(
    schemaId: HcrAgentProtocolSchemaId,
    transportScope: HcrAgentTransportScope,
    protocolVersion: HcrAgentProtocolVersion,
    messageId: "coordinator-hello-ack-1",
    kind: hmkHelloAck,
    hello: HcrHello(
      supportProfile: SupportProfile,
      agentPid: 0,
      capabilities: @["hcr-agent-protocol"]))

proc sourceGenerations(): seq[HcrSourceGenerationEntry] =
  @[
    HcrSourceGenerationEntry(
      sourcePath: "src/patchable.c",
      generation: 1,
      snapshotDigest: "blake3-256:source-generation-1",
      lineTableDigest: "blake3-256:line-table-1")
  ]

proc makeRequest(patchBytes: seq[byte]): HcrPatchRequest =
  directPatchRequest(
    patchId = "patch-0001",
    supportProfile = SupportProfile,
    changedFunctions = [FunctionName],
    targetSymbols = [FunctionName],
    directPatchBytes = patchBytes,
    debugObjectBytes = [byte 0x7f, 0x45, 0x4c, 0x46],
    unwindMetadataBytes = [byte 0x10, 0x00, 0x00, 0x00],
    sourceGenerationMap = sourceGenerations())

proc openSocketPair(): tuple[
    listener: HcrAgentUnixListener,
    coordinator: HcrAgentSocketConnection,
    agent: HcrAgentSocketConnection] =
  let socketPath = getTempDir() /
    ("repro-hcr-agent-ipc-" & $getCurrentProcessId() & ".sock")
  result.listener = listenHcrAgentUnixSocket(socketPath)
  result.coordinator = connectHcrAgentUnixSocket(socketPath)
  result.agent = result.listener.acceptHcrAgentConnection()

suite "HCR agent IPC":
  test "launch environment names the agent socket path":
    let entry = hcrAgentSocketEnv("/tmp/repro-hcr-agent.sock")
    check entry.name == ReproHcrAgentSocketEnv
    check entry.value == "/tmp/repro-hcr-agent.sock"

    let hadPrevious = existsEnv(ReproHcrAgentSocketEnv)
    let previous = getEnv(ReproHcrAgentSocketEnv, "")
    defer:
      if hadPrevious:
        putEnv(ReproHcrAgentSocketEnv, previous)
      else:
        delEnv(ReproHcrAgentSocketEnv)

    delEnv(ReproHcrAgentSocketEnv)
    expect ValueError:
      discard requireHcrAgentSocketPathFromEnv()

    putEnv(ReproHcrAgentSocketEnv, entry.value)
    check requireHcrAgentSocketPathFromEnv() == entry.value

  test "Unix socket transport carries framed protocol messages":
    when defined(posix):
      var sockets = openSocketPair()
      var listener = sockets.listener
      defer: listener.close()
      var coordinatorConnection = sockets.coordinator
      defer: coordinatorConnection.close()
      var agentConnection = sockets.agent
      defer: agentConnection.close()

      discard agentConnection.writeAgentMessage(agentHello())
      let hello = coordinatorConnection.readAgentMessage()
      check hello.kind == hmkHello
      check hello.hello.supportProfile == SupportProfile
      check hello.hello.capabilities == @[
        "hcr-agent-protocol", "direct-patch-injection"]

      discard coordinatorConnection.writeAgentMessage(coordinatorHelloAck())
      let ack = agentConnection.readAgentMessage()
      check ack.kind == hmkHelloAck
      check ack.hello.supportProfile == SupportProfile
    else:
      skip()

  test "agent can connect through launch environment socket path":
    when defined(posix):
      let hadPrevious = existsEnv(ReproHcrAgentSocketEnv)
      let previous = getEnv(ReproHcrAgentSocketEnv, "")
      defer:
        if hadPrevious:
          putEnv(ReproHcrAgentSocketEnv, previous)
        else:
          delEnv(ReproHcrAgentSocketEnv)

      let socketPath = getTempDir() /
        ("repro-hcr-agent-env-" & $getCurrentProcessId() & ".sock")
      var listener = listenHcrAgentUnixSocket(socketPath)
      defer: listener.close()
      putEnv(ReproHcrAgentSocketEnv, socketPath)

      var agentConnection = connectHcrAgentFromEnv()
      defer: agentConnection.close()
      var coordinatorConnection = listener.acceptHcrAgentConnection()
      defer: coordinatorConnection.close()

      discard agentConnection.writeAgentMessage(agentHello())
      let hello = coordinatorConnection.readAgentMessage()
      check hello.kind == hmkHello
      check hello.hello.supportProfile == SupportProfile
    else:
      skip()

  test "coordinator and endpoint use Unix socket IPC with session validation":
    when defined(posix):
      var target = initFakeTarget(
        FunctionName, aarch64PatchableReturnBytes(11, sledNops = 4))
      let patchBytes = aarch64ReturnImmediateBytes(77)
      let request = makeRequest(patchBytes)
      var endpoint = initHcrAgentEndpoint(
        SupportProfile, runtimeOps(target), agentPid = 1234)
      var coordinator = initHcrCoordinatorClient(SupportProfile)

      var sockets = openSocketPair()
      var listener = sockets.listener
      defer: listener.close()
      var coordinatorConnection = sockets.coordinator
      defer: coordinatorConnection.close()
      var agentConnection = sockets.agent
      defer: agentConnection.close()

      discard agentConnection.writeAgentMessage(endpoint.agentHelloMessage())
      discard coordinator.receiveAgentMessage(coordinatorConnection)
      coordinator.sendCoordinatorMessage(
        coordinatorConnection, coordinator.coordinatorHelloAckMessage())
      coordinator.sendCoordinatorMessage(
        coordinatorConnection,
        coordinator.coordinatorPatchRequestMessage(request))

      discard endpoint.handleCoordinatorMessage(
        agentConnection.readAgentMessage())
      for response in endpoint.handleCoordinatorMessage(
          agentConnection.readAgentMessage()):
        discard agentConnection.writeAgentMessage(response)

      while coordinator.session.state == hssPatchRequested:
        discard coordinator.receiveAgentMessage(coordinatorConnection)

      check coordinator.session.state == hssPatchFinished
      check coordinator.patchApplied.isSome
      check coordinator.patchApplied.get().patchId == "patch-0001"
      check target.callOriginalPointer(FunctionName) == 77
    else:
      skip()

  test "an over-long agent socket path is refused with an error naming the limit":
    # `std/net` refuses a Unix-socket path of `Sockaddr_un_path_length` bytes
    # or more (108 on Linux, 92 on macOS) with a bare `socket path too long`
    # that names neither the path nor the limit. The library refuses first,
    # on both the listening and the dialling side, and says which.
    when defined(posix):
      let limit = min(Sockaddr_un_path_length,
        sizeof(Sockaddr_un().sun_path)) - 1
      let socketPath = "/tmp/" & repeat('h', limit + 1 - "/tmp/".len)
      require socketPath.len == limit + 1
      for side in ["listen", "connect"]:
        try:
          if side == "listen":
            var listener = listenHcrAgentUnixSocket(socketPath)
            listener.close()
          else:
            var connection = connectHcrAgentUnixSocket(socketPath)
            connection.close()
          checkpoint(side & " accepted an over-long path")
          check false
        except ValueError as err:
          checkpoint(side & ": " & err.msg)
          check socketPath in err.msg
          check ($socketPath.len & " bytes") in err.msg
          check $limit in err.msg
          check "socket path too long" notin err.msg
      check not fileExists(socketPath)
    else:
      skip("Windows HCR agents use named pipes, which have no sun_path limit; the bound is POSIX-only")

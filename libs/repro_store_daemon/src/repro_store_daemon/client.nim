import std/[net, os, strutils]

import repro_local_store

import ./protocol

type
  StoreDaemonClientError* = object of CatchableError

proc scopedRootId*(holderId, rootId: string): string =
  "dev/" & $currentUid() & "/" & safePathSegment(holderId, "holder") & "/" &
    safePathSegment(rootId, "root")

proc connectDevDaemon*(endpoint = defaultDevEndpoint()): Socket =
  when defined(posix):
    result = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE)
    result.connectUnix(endpoint)
    result.writeFrame(sdkHello, helloBody("repro-store-client"))
    let ack = result.readFrame()
    if ack.kind == sdkError:
      raise newException(StoreDaemonClientError, parseErrorBody(ack.body))
    if ack.kind != sdkHelloAck:
      raise newException(StoreDaemonClientError,
        "store daemon returned unexpected hello frame: " & $ack.kind)
    let parsed = parseHelloAck(ack.body)
    if parsed.version != StoreDaemonProtocolVersion or
        parsed.profile != StoreDaemonProfileDev:
      raise newException(StoreDaemonClientError,
        "incompatible store daemon at " & endpoint)
  else:
    raise newException(StoreDaemonClientError,
      "reprostored development IPC is not implemented on this platform")

proc queryDevStatus*(endpoint = defaultDevEndpoint()): StoreDaemonStatus =
  result.endpoint = endpoint
  when defined(posix):
    var socket: Socket
    try:
      socket = connectDevDaemon(endpoint)
    except CatchableError:
      result.running = false
      return
    defer: socket.close()
    socket.writeFrame(sdkStatus)
    let frame = socket.readFrame()
    if frame.kind == sdkStatusResponse:
      result = parseStatusBody(frame.body)
      return
    if frame.kind == sdkError:
      raise newException(StoreDaemonClientError, parseErrorBody(frame.body))
    raise newException(StoreDaemonClientError,
      "unexpected status frame: " & $frame.kind)
  else:
    result.running = false

proc directSyntheticRealize*(req: SyntheticRealizeRequest):
    StoreDaemonRealizeResult =
  var store = openStore(req.storeRoot)
  defer: store.close()
  let prefixId = parsePrefixIdHex(req.realizationIdHex)
  let hint = StoreReceiptHint(
    adapter: "synthetic",
    packageName: req.packageName,
    version: req.version,
    declaredExecutablePath: "bin/tool",
    lockIdentity: "synthetic:" & req.realizationIdHex,
    materializationMechanism: "directory")
  let outcome = store.realizePrefix(prefixId, hint,
    proc (stagingDir: string; mechanism: var string) =
      createDir(stagingDir / "bin")
      writeFile(stagingDir / "bin" / "tool", req.payload)
      mechanism = "directory")
  let scoped = scopedRootId(req.holderId, req.rootId)
  store.registerRoot(scoped, rkSession, currentUid())
  store.attachPrefixToRoot(scoped, prefixId)
  StoreDaemonRealizeResult(
    status:
      if outcome.outcome == roAlreadyPresent: "already-realized"
      else: "realized",
    realizedPrefixPath: outcome.absolutePath,
    realizationHashHex: req.realizationIdHex,
    rootId: scoped,
    writerMode: "direct")

proc realizeSyntheticViaDaemon*(req: SyntheticRealizeRequest;
                                endpoint = defaultDevEndpoint()):
    StoreDaemonRealizeResult =
  var socket = connectDevDaemon(endpoint)
  defer: socket.close()
  socket.writeFrame(sdkSyntheticRealize, syntheticBody(req))
  let frame =
    try:
      socket.readFrame()
    except CatchableError as err:
      raise newException(StoreDaemonClientError,
        "lost connection to dev store daemon during realize; retry after " &
        "restarting reprostored --dev: " & err.msg)
  if frame.kind == sdkRealizeResponse:
    return parseRealizeResponseBody(frame.body)
  if frame.kind == sdkError:
    raise newException(StoreDaemonClientError, parseErrorBody(frame.body))
  raise newException(StoreDaemonClientError,
    "unexpected realize frame: " & $frame.kind)

proc realizeSyntheticWithFallback*(req: SyntheticRealizeRequest;
                                   endpoint = defaultDevEndpoint()):
    StoreDaemonRealizeResult =
  try:
    result = realizeSyntheticViaDaemon(req, endpoint)
  except CatchableError:
    result = directSyntheticRealize(req)

proc releaseDevRoot*(holderId, rootId: string;
                     endpoint = defaultDevEndpoint()) =
  var socket = connectDevDaemon(endpoint)
  defer: socket.close()
  socket.writeFrame(sdkReleaseRoot, releaseRootBody(holderId, rootId))
  let frame = socket.readFrame()
  if frame.kind == sdkReleaseRootAck:
    return
  if frame.kind == sdkError:
    raise newException(StoreDaemonClientError, parseErrorBody(frame.body))
  raise newException(StoreDaemonClientError,
    "unexpected release-root frame: " & $frame.kind)

proc requestDevShutdown*(endpoint = defaultDevEndpoint()) =
  var socket = connectDevDaemon(endpoint)
  defer: socket.close()
  socket.writeFrame(sdkShutdown)
  let frame = socket.readFrame()
  if frame.kind == sdkShutdownAck:
    return
  if frame.kind == sdkError:
    raise newException(StoreDaemonClientError, parseErrorBody(frame.body))
  raise newException(StoreDaemonClientError,
    "unexpected shutdown frame: " & $frame.kind)

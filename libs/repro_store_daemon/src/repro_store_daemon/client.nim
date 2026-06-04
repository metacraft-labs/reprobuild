import std/[os, strutils]

import repro_interface_artifacts
import repro_local_store
import repro_tool_profiles

import ./protocol

type
  StoreDaemonClientError* = object of CatchableError

proc scopedRootId*(holderId, rootId: string): string =
  "dev/" & $currentUid() & "/" & safePathSegment(holderId, "holder") & "/" &
    safePathSegment(rootId, "root")

proc connectDevDaemon*(endpoint = defaultDevEndpoint()): IpcConn =
  try:
    result = connectIpc(endpoint)
  except IpcEndpointError as exc:
    raise newException(StoreDaemonClientError, exc.msg)
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

proc queryDevStatus*(endpoint = defaultDevEndpoint()): StoreDaemonStatus =
  result.endpoint = endpoint
  var conn: IpcConn
  try:
    conn = connectDevDaemon(endpoint)
  except CatchableError:
    result.running = false
    return
  defer: conn.closeIpcConn()
  conn.writeFrame(sdkStatus)
  let frame = conn.readFrame()
  if frame.kind == sdkStatusResponse:
    result = parseStatusBody(frame.body)
    return
  if frame.kind == sdkError:
    raise newException(StoreDaemonClientError, parseErrorBody(frame.body))
  raise newException(StoreDaemonClientError,
    "unexpected status frame: " & $frame.kind)

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
    writerMode: "direct",
    installMethod: "synthetic",
    selectedStorePath: outcome.absolutePath)

proc realizeSyntheticViaDaemon*(req: SyntheticRealizeRequest;
                                endpoint = defaultDevEndpoint()):
    StoreDaemonRealizeResult =
  let socket = connectDevDaemon(endpoint)
  defer: socket.closeIpcConn()
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

proc requestFromNixUse*(useDef: InterfaceToolUse; storeRoot, holderId,
                        rootId: string): StoreDaemonExternalRealizeRequest =
  let plan = nixAcquisitionPlan(useDef)
  StoreDaemonExternalRealizeRequest(
    storeRoot: storeRoot,
    holderId: holderId,
    rootId: rootId,
    rawConstraint: useDef.rawConstraint,
    packageSelector: useDef.packageSelector,
    executableName: useDef.executableName,
    packageId: plan.packageId,
    declaredExecutablePath: plan.declaredExecutablePath,
    lockIdentity: plan.lockIdentity,
    nixSelector: plan.nixSelector,
    nixExpressionFile: plan.nixExpressionFile,
    nixpkgsRef: plan.nixpkgsRef,
    nixpkgsRev: plan.nixpkgsRev,
    nixpkgsNarHash: plan.nixpkgsNarHash)

proc requestFromTarballUse*(useDef: InterfaceToolUse; storeRoot, holderId,
                            rootId: string):
    StoreDaemonExternalRealizeRequest =
  let plan = tarballAcquisitionPlan(useDef)
  StoreDaemonExternalRealizeRequest(
    storeRoot: storeRoot,
    holderId: holderId,
    rootId: rootId,
    rawConstraint: useDef.rawConstraint,
    packageSelector: useDef.packageSelector,
    executableName: useDef.executableName,
    packageId: plan.packageId,
    declaredExecutablePath: plan.declaredExecutablePath,
    lockIdentity: plan.lockIdentity,
    tarballUrl: plan.url,
    tarballMirrors: plan.mirrors,
    tarballSha256: plan.sha256,
    archiveType: plan.archiveType,
    stripComponents: plan.stripComponents)

proc realizeExternalViaDaemon(req: StoreDaemonExternalRealizeRequest;
                              kind: StoreDaemonMessageKind;
                              endpoint: string): StoreDaemonRealizeResult =
  let socket = connectDevDaemon(endpoint)
  defer: socket.closeIpcConn()
  socket.writeFrame(kind, externalRealizeBody(req))
  let frame =
    try:
      socket.readFrame()
    except CatchableError as err:
      raise newException(StoreDaemonClientError,
        "lost connection to dev store daemon during external realize; " &
        "retry after restarting reprostored --dev: " & err.msg)
  if frame.kind == sdkRealizeResponse:
    return parseRealizeResponseBody(frame.body)
  if frame.kind == sdkError:
    raise newException(StoreDaemonClientError, parseErrorBody(frame.body))
  raise newException(StoreDaemonClientError,
    "unexpected external-realize frame: " & $frame.kind)

proc realizeNixViaDaemon*(req: StoreDaemonExternalRealizeRequest;
                          endpoint = defaultDevEndpoint()):
    StoreDaemonRealizeResult =
  realizeExternalViaDaemon(req, sdkNixRealize, endpoint)

proc realizeTarballViaDaemon*(req: StoreDaemonExternalRealizeRequest;
                              endpoint = defaultDevEndpoint()):
    StoreDaemonRealizeResult =
  realizeExternalViaDaemon(req, sdkTarballRealize, endpoint)

proc realizeSyntheticWithFallback*(req: SyntheticRealizeRequest;
                                   endpoint = defaultDevEndpoint()):
    StoreDaemonRealizeResult =
  try:
    result = realizeSyntheticViaDaemon(req, endpoint)
  except CatchableError:
    result = directSyntheticRealize(req)

proc scoopRealizationIsPerUserFallthrough*(): bool =
  ## Scoop installs into the calling user's Scoop root and keeps weak
  ## per-user execution-profile semantics. An active store daemon does
  ## not make Scoop a shared-store adapter.
  true

proc releaseDevRoot*(holderId, rootId: string;
                     endpoint = defaultDevEndpoint()) =
  let socket = connectDevDaemon(endpoint)
  defer: socket.closeIpcConn()
  socket.writeFrame(sdkReleaseRoot, releaseRootBody(holderId, rootId))
  let frame = socket.readFrame()
  if frame.kind == sdkReleaseRootAck:
    return
  if frame.kind == sdkError:
    raise newException(StoreDaemonClientError, parseErrorBody(frame.body))
  raise newException(StoreDaemonClientError,
    "unexpected release-root frame: " & $frame.kind)

proc requestDevShutdown*(endpoint = defaultDevEndpoint()) =
  let socket = connectDevDaemon(endpoint)
  defer: socket.closeIpcConn()
  socket.writeFrame(sdkShutdown)
  let frame = socket.readFrame()
  if frame.kind == sdkShutdownAck:
    return
  if frame.kind == sdkError:
    raise newException(StoreDaemonClientError, parseErrorBody(frame.body))
  raise newException(StoreDaemonClientError,
    "unexpected shutdown frame: " & $frame.kind)

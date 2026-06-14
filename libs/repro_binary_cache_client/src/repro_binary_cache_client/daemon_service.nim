## ReproOS-Generations-And-Foreign-Packages A2.5 — daemon-resident wrapper.
##
## Per the spec § Multi-user vs single-user mode:
##
##   * The daemon hosts the client library; build tools talk to the
##     daemon via the existing IPC; the daemon owns the persistent
##     HTTP/2 connection pool + the single-writer lock on the local
##     CAS.
##
## ``DaemonSubstituteService`` is the singleton + service primitive:
## one ``ClientContext`` per daemon, one ``HttpPool``, one
## ``ClientIndex``. The daemon runtime constructs it once at start
## and shares it across every ``substitute(closure)`` request.
##
## ## IPC framing
##
## The actual ``repro-daemon`` IPC protocol lives in
## ``libs/repro_daemon_core/src/repro_daemon_core/protocol.nim``;
## wiring the protocol-level ``substitute`` request type belongs to
## the daemon library, not the cache client. The service primitive
## here is wire-format-agnostic — the daemon constructs requests
## from its decoded IPC, calls ``handleRequest``, returns the
## structured outcome.
##
## ## Concurrency
##
## v1 holds a process-wide ``Lock`` around the ``substitute()`` entry
## point. The pool capacity + the BuildEngine's wait-loop already
## limit parallelism upstream of the daemon. A more aggressive
## design would dispatch one closure walk per worker thread; the
## v1 single-lock design is sufficient for the workloads A2.5
## targets (one workstation, one cache server, parallel builds).

import std/[locks, os, strutils]

import repro_daemon_core

import ./types
import ./http_pool
import ./scheduler_executor
import ./closure_walk
import ./index
import ../../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

# ---------------------------------------------------------------------------
# Hex helpers for the trusted-signer pubkey wire encoding.
#
# ``peerAuth`` exposes ``PublicKeyBytes`` (array[65, byte]) but keeps its
# hex codec internal. The IPC bridge below needs a plain hex round-trip
# for the wire format; we mirror the lower-case codec used elsewhere in
# the codebase (see ``repro_core/codec.nim``'s ``hexBytes`` and
# ``repro_peer_cache/auth.nim``'s ``toHexN``).
# ---------------------------------------------------------------------------

const PubKeyHexChars = "0123456789abcdef"

proc pubKeyToHex(buf: peerAuth.PublicKeyBytes): string =
  result = newString(buf.len * 2)
  for i, b in buf:
    result[2 * i] = PubKeyHexChars[(int(b) shr 4) and 0xf]
    result[2 * i + 1] = PubKeyHexChars[int(b) and 0xf]

proc pubKeyFromHex(hex: string): peerAuth.PublicKeyBytes =
  if hex.len != result.len * 2:
    raise newException(ValueError,
      "daemon-substitute IPC: trusted-signer pubkey hex must be " &
      $(result.len * 2) & " chars, got " & $hex.len)
  for i in 0 ..< result.len:
    try:
      result[i] = byte(parseHexInt(hex[2 * i .. 2 * i + 1]))
    except ValueError:
      raise newException(ValueError,
        "daemon-substitute IPC: trusted-signer pubkey hex has invalid " &
        "digit at position " & $(2 * i))

type
  DaemonSubstituteService* = ref object
    ctx*: ClientContext
    pool*: HttpPool
    idx*: ClientIndex
    lock: Lock
    closed: bool

  DaemonSubstituteRequest* = object
    rootEntryKeyHex*: string
    endpoint*: SubstituteEndpoint

  DaemonSubstituteResult* = object
    ok*: bool
    reason*: string
    plan*: seq[SubstitutePlan]
    outcomes*: seq[SubstituteOutcome]
    realizedCasPaths*: seq[string]
    totalBytesFetched*: int64
    totalWallclockMillis*: int64

proc newDaemonSubstituteService*(config: ClientConfig):
                                  DaemonSubstituteService =
  result = DaemonSubstituteService(
    ctx: newClientContext(config),
    pool: newHttpPool(maxConnections = config.maxConnectionsPerHost *
                                       max(1, config.endpoints.len)),
    idx: openClientIndex(config.storeRoot),
    closed: false)
  initLock(result.lock)

proc close*(svc: DaemonSubstituteService) =
  if svc.isNil or svc.closed:
    return
  svc.closed = true
  try: svc.pool.close() except CatchableError: discard
  try: svc.ctx.close() except CatchableError: discard
  try: svc.idx.flush() except CatchableError: discard
  deinitLock(svc.lock)

proc toIpcEndpoint*(endpoint: SubstituteEndpoint): DaemonSubstituteIpcEndpoint =
  ## Convert an in-process ``SubstituteEndpoint`` (binary signer pubkeys)
  ## to the wire-format ``DaemonSubstituteIpcEndpoint`` (hex-encoded
  ## signer pubkeys). The protocol module is leaf-level and does not
  ## depend on ``repro_peer_cache``; the conversion happens here.
  result.baseUrl = endpoint.baseUrl
  result.priority = endpoint.priority
  result.trustedSignerHex = newSeqOfCap[string](endpoint.trustedSigners.len)
  for signer in endpoint.trustedSigners:
    result.trustedSignerHex.add(pubKeyToHex(signer))

proc fromIpcEndpoint*(ipcEndpoint: DaemonSubstituteIpcEndpoint):
    SubstituteEndpoint =
  result.baseUrl = ipcEndpoint.baseUrl
  result.priority = ipcEndpoint.priority
  result.trustedSigners = newSeqOfCap[peerAuth.PublicKeyBytes](
    ipcEndpoint.trustedSignerHex.len)
  for hex in ipcEndpoint.trustedSignerHex:
    result.trustedSigners.add(pubKeyFromHex(hex))

proc handleRequest*(svc: DaemonSubstituteService;
                    req: DaemonSubstituteRequest): DaemonSubstituteResult =
  ## Walks the closure rooted at ``req.rootEntryKeyHex`` and
  ## materialises every member. The single-writer lock serialises
  ## concurrent ``substitute()`` calls from different daemon clients
  ## so the local CAS index stays consistent.
  withLock(svc.lock):
    var plan: seq[SubstitutePlan]
    try:
      plan = planClosure(svc.ctx, svc.pool, req.endpoint,
                         req.rootEntryKeyHex)
    except CatchableError as e:
      result.ok = false
      result.reason = "closure walk failed: " & e.msg
      return
    result.plan = plan
    var allOk = true
    for step in plan:
      let sr = SubstituteRequest(
        entryKeyHex: step.entryKeyHex, endpoint: req.endpoint)
      let outcome = executeSubstituteAction(
        svc.ctx, svc.pool, sr, svc.idx)
      result.outcomes.add(outcome)
      result.totalBytesFetched += outcome.bytesFetched
      result.totalWallclockMillis += outcome.wallclockMillis
      if outcome.ok and outcome.casPath.len > 0:
        result.realizedCasPaths.add(outcome.casPath)
      if not outcome.ok:
        allOk = false
        result.reason = "substitute failed for " & step.entryKeyHex &
          ": " & outcome.reason
        break
    result.ok = allOk
    try: svc.idx.flush() except CatchableError: discard

# ---------------------------------------------------------------------------
# A2.5 P6 — IPC bridge
# ---------------------------------------------------------------------------
#
# ``DaemonSubstituteService.handleRequest`` is the in-process primitive.
# The IPC bridge below maps the wire-format
# ``DaemonSubstituteIpcRequest`` to the in-process shape, calls
# ``handleRequest``, then maps the in-process result back to the wire-
# format ``DaemonSubstituteIpcResponse``. The daemon entrypoint binds
# the service singleton into the IPC dispatcher with
# ``installDaemonSubstituteIpcExecutor``.

proc handleIpcRequest*(svc: DaemonSubstituteService;
                       ipcReq: DaemonSubstituteIpcRequest):
                        DaemonSubstituteIpcResponse =
  if ipcReq.rootEntryKeyHex.len == 0:
    result.ok = false
    result.reason = "udkSubstituteRequest carried no rootEntryKeyHex roots"
    return
  let endpoint = fromIpcEndpoint(ipcReq.endpoint)
  var aggregateOk = true
  var aggregateReason = ""
  for rootHex in ipcReq.rootEntryKeyHex:
    let inProc = DaemonSubstituteRequest(
      rootEntryKeyHex: rootHex, endpoint: endpoint)
    let res = svc.handleRequest(inProc)
    for step in res.plan:
      result.plan.add(DaemonSubstituteIpcPlanStep(
        entryKeyHex: step.entryKeyHex,
        sourceEndpointBaseUrl: step.sourceEndpoint.baseUrl))
    for outcome in res.outcomes:
      result.outcomes.add(DaemonSubstituteIpcOutcome(
        entryKeyHex: "",
          # ``SubstituteOutcome`` does not carry the entry-key on the
          # in-process side; the daemon-side plan carries it. For the
          # wire-format outcomes we leave the field blank — the
          # zip-by-position with the response plan recovers it on the
          # client side. A future protocol bump can plumb the entry-key
          # through the in-process ``SubstituteOutcome`` shape.
        ok: outcome.ok,
        skipped: outcome.skipped,
        reason: outcome.reason,
        casPath: outcome.casPath,
        bytesFetched: outcome.bytesFetched,
        wallclockMillis: outcome.wallclockMillis))
    for path in res.realizedCasPaths:
      result.realizedCasPaths.add(path)
    result.totalBytesFetched += res.totalBytesFetched
    result.totalWallclockMillis += res.totalWallclockMillis
    if not res.ok:
      aggregateOk = false
      if aggregateReason.len == 0:
        aggregateReason = res.reason
  result.ok = aggregateOk
  result.reason = aggregateReason
  # Backfill the wire-format outcome entryKey from the plan when the
  # in-process scheduler emitted one outcome per planned step.
  if result.outcomes.len == result.plan.len:
    for i in 0 ..< result.outcomes.len:
      result.outcomes[i].entryKeyHex = result.plan[i].entryKeyHex

proc installDaemonSubstituteIpcExecutor*(svc: DaemonSubstituteService) =
  ## Wire the singleton ``DaemonSubstituteService`` into the
  ## ``repro_daemon_core`` runtime so the daemon's IPC dispatcher
  ## answers ``udkSubstituteRequest`` frames. Call this exactly once
  ## from the daemon entrypoint after the service is constructed.
  setUserDaemonSubstituteExecutor(proc(
      req: DaemonSubstituteIpcRequest): DaemonSubstituteIpcResponse =
    svc.handleIpcRequest(req))

# ---------------------------------------------------------------------------
# Client-side IPC wrapper
# ---------------------------------------------------------------------------

type
  DaemonSubstituteClientError* = object of CatchableError

proc substituteViaDaemon*(rootEntryKeyHex: string;
                          endpoint: SubstituteEndpoint;
                          daemonEndpoint = defaultUserDaemonEndpoint();
                          singleWriterMode = true):
                            DaemonSubstituteIpcResponse =
  ## Connect to the running ``repro-daemon`` at ``daemonEndpoint``, send
  ## a ``udkSubstituteRequest`` for the closure rooted at
  ## ``rootEntryKeyHex``, and return the decoded
  ## ``DaemonSubstituteIpcResponse``. This is the public entry point
  ## ``repro build`` calls in multi-user mode.
  var conn = connectUserDaemon(daemonEndpoint,
    clientName = "repro-binary-cache-client",
    commandMode = "substitute",
    requiredFeatures = ["substitute-routing"])
  defer: conn.closeIpcConn()
  let ipcReq = DaemonSubstituteIpcRequest(
    rootEntryKeyHex: @[rootEntryKeyHex],
    endpoint: toIpcEndpoint(endpoint),
    singleWriterMode: singleWriterMode)
  conn.writeFrame(udkSubstituteRequest, substituteRequestBody(ipcReq))
  let frame = conn.readFrame()
  case frame.kind
  of udkSubstituteResponse:
    return parseSubstituteResponseBody(frame.body)
  of udkError:
    raise newException(DaemonSubstituteClientError, parseErrorBody(frame.body))
  else:
    raise newException(DaemonSubstituteClientError,
      "unexpected user-daemon substitute frame: " & $frame.kind)

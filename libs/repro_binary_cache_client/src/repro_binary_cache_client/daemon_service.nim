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

import ./types
import ./http_pool
import ./scheduler_executor
import ./closure_walk
import ./index

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

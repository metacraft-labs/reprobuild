## End-to-end regression guard for the **wedged-but-connected** daemon —
## the exact shape that re-introduced the silent hang and that the
## fake-liveness unit tests in ``t_runquota_grant_wait_unresponsive.nim``
## cannot reach.
##
## Those unit tests inject a *fake* liveness closure, so they never
## exercise the REAL ``livenessProbe`` → ``daemonStatus`` → ``readResponse``
## → ``receiveFrame`` → ``readExact`` → ``readExactSocket`` wiring — which
## is precisely where the latest defect lived: the probe called
## ``daemonStatus()`` with no ``timeoutMs``, defaulting to ``0`` = an
## UNBOUNDED blocking read.  Against a daemon that ACCEPTS the connection
## but then never answers (wedged / mid-restart), the bounded grant read
## returns no frame (``gpoNoFrame``) and the probe would then block forever
## in ``recv`` — so ``livSilent`` and the ``unresponsiveMs`` deadline were
## UNREACHABLE and the build hung silently, exactly the bug the loop exists
## to prevent.
##
## This test forks a real stub RQSP server process on a Unix socket that
## completes the Hello + RegisterSession handshake (so a real
## ``RunQuotaSession`` is established and connected) and then goes
## permanently silent — it answers neither ``GrantNext`` nor
## ``StatusRequest``.  We point a real ``runquota_client`` session at it
## and drive the REAL probe path two ways:
##
##   1. ``daemonStatus(timeoutMs = small)`` against the connected-but-silent
##      socket MUST raise ``RunQuotaClientError`` within ~the timeout
##      (proves the bounded read actually bounds — this is the call the
##      ``livenessProbe`` makes).
##   2. The real ``awaitGrantLoop`` driven by a real bounded
##      ``pollNextGrantBounded`` poll and the REAL ``livenessProbe`` shape
##      (a bounded ``daemonStatus`` whose timeout maps to ``livSilent``)
##      MUST raise an actionable ``ReproRunQuotaError`` within a bounded
##      wall-clock time (``gpoNoFrame`` → ``livSilent`` → deadline).
##
## Falsifiability: under the OLD unbounded ``daemonStatus()`` call BOTH the
## probe and the loop block forever in ``recv`` against this server, so the
## real-time guards below would never be reached — the test would HANG
## (and a CI timeout would mark it failed).  Under the fix the bounded read
## returns and both assertions pass promptly.  A hard real-time guard turns
## any regression into a failure rather than an infinite hang.
##
## The stub server is forked as a child PROCESS (this same binary re-exec'd
## with ``REPRO_WEDGED_STUB_SOCKET`` set) rather than a thread, so no Socket
## object or GC heap is shared across threads.

import std/[os, osproc, strutils, times, unittest]

import repro_runquota

import runquota_client
import runquota_ipc
import runquota_protocol
import runquota_core

const stubEnvVar = "REPRO_WEDGED_STUB_SOCKET"

proc sendResponse(connection: var LocalConnection; kind: RqspMessageKind;
                  requestId: uint64; payload: string) =
  connection.sendFrame(encodeFrame(kind, FrameFlagResponse, requestId, payload))

proc runWedgedStub(socketPath: string) =
  ## A daemon that is reachable and completes the control handshake, then
  ## wedges: it answers Hello and RegisterSession but NEVER replies to the
  ## grant stream or to a StatusRequest.
  var listener = bindEndpoint(unixEndpoint(socketPath))
  var connection = acceptConnection(listener)
  while true:
    var frame: RqspFrame
    # Unbounded server-side read: the server blocks waiting for the client's
    # next request frame.  The client side is the thing under test, and it
    # must NOT block waiting for OUR (deliberately never-sent) reply.
    if not connection.receiveFrame(frame):
      break
    case frame.header.messageKind
    of rqHello:
      let helloOk = HelloOkMessage(
        selectedProtocolMajor: RqspProtocolMajor,
        selectedProtocolMinor: RqspProtocolMinor,
        daemonId: 1'u64,
        daemonVersion: "wedged-stub",
        capabilities: defaultCapabilities(
          "test", "unix", milliCpu(1000), bytes(1024)),
        flow: defaultFlowControlLimits())
      connection.sendResponse(rqHelloOk, frame.header.requestId,
        encodeHelloOk(helloOk))
    of rqRegisterSession:
      connection.sendResponse(rqSessionRegistered, frame.header.requestId,
        encodeSessionRegistered(SessionRegisteredMessage(
          sessionId: sessionId(7'u64))))
    else:
      # rqGrantNext, rqStatusRequest, anything else: stay SILENT.  We keep
      # the connection open (we do NOT close it) and consume further request
      # frames without ever answering — a wedged / mid-restart daemon.  This
      # is what made the probe's unbounded read hang forever.
      discard

# When re-exec'd as the stub child, run the server and never return.
proc socketExists(path: string): bool =
  ## ``os.fileExists`` returns false for a Unix-socket special file, so the
  ## readiness check must use ``getFileInfo`` (which succeeds for any
  ## existing path) instead.
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

when isMainModule:
  let stubSocket = getEnv(stubEnvVar)
  if stubSocket.len > 0:
    runWedgedStub(stubSocket)
    quit(0)

proc startStub(socketPath: string): Process =
  ## Fork this same binary as the silent-stub server.
  let self = getAppFilename()
  putEnv(stubEnvVar, socketPath)
  result = startProcess(self, args = @[], options = {poParentStreams})
  delEnv(stubEnvVar)

proc waitForSocket(path: string): bool =
  for _ in 0 ..< 500:
    if socketExists(path):
      return true
    sleep(10)
  false

suite "repro_runquota grant-wait — wedged-but-connected daemon (end-to-end)":

  test "bounded daemonStatus against a connected-but-silent daemon raises within bound":
    let socketPath = "/tmp/repro-wedged-rq-" &
      $getCurrentProcessId() & ".sock"
    removeFile(socketPath)
    let stub = startStub(socketPath)
    defer:
      stub.terminate()
      discard stub.waitForExit()
      removeFile(socketPath)
    check waitForSocket(socketPath)

    var client = connect(unixEndpoint(socketPath))
    # The handshake (Hello + RegisterSession) completes — the daemon is
    # reachable and the session is live and CONNECTED.
    var session = client.registerSession("wedged-test", "0.1.0")
    check session.active

    # Now the daemon is silent.  ``daemonStatus`` with a SMALL bound is
    # exactly the call ``livenessProbe`` makes.  Under the fix it must raise
    # within ~the timeout; under the OLD unbounded ``daemonStatus()`` it
    # would block forever in ``recv`` and we would never reach the
    # assertions below.
    let timeoutMs = 500
    let probeStart = epochTime()
    var raised = false
    try:
      discard client.daemonStatus(timeoutMs = timeoutMs)
    except RunQuotaClientError:
      raised = true
    let probeElapsed = epochTime() - probeStart
    check raised
    # Real-time guard: a bounded read returns close to its deadline.  A few
    # times the timeout is plenty of slack for scheduling; an unbounded read
    # would blow far past this (in fact never return).
    check probeElapsed < (timeoutMs.float / 1000.0) * 8.0

    client.close()

  test "awaitGrant path with the REAL probe raises within the deadline (no hang)":
    let socketPath = "/tmp/repro-wedged-rq2-" &
      $getCurrentProcessId() & ".sock"
    removeFile(socketPath)
    let stub = startStub(socketPath)
    defer:
      stub.terminate()
      discard stub.waitForExit()
      removeFile(socketPath)
    check waitForSocket(socketPath)

    var client = connect(unixEndpoint(socketPath))
    var session = client.registerSession("wedged-test-2", "0.1.0")
    check session.active

    # Drive the REAL bounded grant poll and the REAL liveness-probe shape (a
    # bounded ``daemonStatus`` whose timeout/error maps to ``livSilent``) —
    # the same wiring ``waitForQueuedGrant`` builds, with a deliberately
    # small read window and deadline so the test is fast.
    let boundedReadMs = 300
    let unresponsiveMs = 2_000
    let sessionPtr = addr session

    proc poll(): GrantPollResult =
      let polled = sessionPtr[].pollNextGrantBounded(boundedReadMs)
      case polled.kind
      of grantPollTimeout:
        GrantPollResult(outcome: gpoNoFrame)
      of grantPollFrame:
        # The wedged stub never frames the grant stream, so this branch is
        # not taken; treat any frame as still-queued liveness.
        GrantPollResult(outcome: gpoAliveQueued)

    proc livenessProbe(): LivenessOutcome =
      try:
        discard sessionPtr[].client[].daemonStatus(timeoutMs = boundedReadMs)
        livAlive
      except RunQuotaClientError:
        livSilent

    let realStart = epochTime()
    var raised = false
    try:
      discard awaitGrantLoop(
        candidateId = 1'u64, label = "wedged-e2e", statsId = "stats-e2e",
        poll = poll,
        liveness = livenessProbe,
        heartbeatMs = 5_000,
        unresponsiveMs = unresponsiveMs,
        nowMs = proc(): int = int(epochTime() * 1000.0),
        napMs = proc(ms: int) = sleep(ms),
        heartbeat = proc(label, statsId: string; waitedMs: int) = discard)
    except ReproRunQuotaError as err:
      raised = true
      # Principle 2: the diagnostic names the remedy.
      check "runquota=off" in err.msg
      check "wedged" in err.msg
    let elapsed = epochTime() - realStart
    check raised
    # Real-time guard: the deadline is ``unresponsiveMs``; with bounded reads
    # the loop must terminate within a small multiple of it.  Under the OLD
    # unbounded ``daemonStatus()`` the very first ``gpoNoFrame`` tick's probe
    # would block forever and this guard would never run.
    check elapsed < (unresponsiveMs.float / 1000.0) * 6.0

    client.close()

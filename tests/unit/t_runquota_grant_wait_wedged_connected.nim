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

import std/[os, osproc, strutils, tempfiles, times, unittest]

import repro_runquota

import runquota_client
import runquota_ipc
import runquota_protocol
import runquota_core

# `runquotaRendezvousDir` is the ONE place the suite decides where a locally
# spawned RunQuota endpoint may live. Narrow import: this file already has
# `connect`/`close` from `runquota_client`, and the module exports more.
from repro_test_support import runquotaRendezvousDir

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

proc privateSocketPath(): tuple[root, socket: string] =
  ## A rendezvous directory THIS process owns — because runquota refuses to
  ## bind or connect through one it does not — and short enough that the
  ## address fits a ``sockaddr_un``. Returns the scratch root as well, so
  ## the caller can remove it.
  ##
  ## These cases once named ``/tmp/repro-wedged-rq-<pid>.sock`` directly.
  ## ``/tmp`` is root-owned and ``1777`` on an ordinary host, and
  ## ``requireTrustedEndpointDir`` refuses exactly that — "a rendezvous
  ## point another user owns is a rendezvous point another user controls".
  ## So the stub child died in ``bindEndpoint`` before it ever listened and
  ## the parent then died in ``connect``: the wedged-daemon wiring under
  ## test was never reached, in either direction.
  ##
  ## They then named a ``createTempDir`` directory under ``$TMPDIR`` and
  ## ``setFilePermissions``-ed it to ``0700`` by hand. Both halves of that
  ## were wrong, and ``repro_test_support.runquotaRendezvousDir`` is the one
  ## place that gets both right:
  ##
  ## * **The mode is a function of the HOST, not a constant.** RunQuota's
  ##   ``rendezvousPolicy`` wants owner-only ``0700`` on a host with no
  ##   ``runquota`` group and group-gated ``0750`` on a host that has one, so
  ##   a hard-coded ``0700`` is refused for the OPPOSITE reason on a
  ##   provisioned host (``refusing mode 0700, required 0750``). Four copies
  ##   of this helper carried that constant and were silently correct only in
  ##   the first case. ``runquotaRendezvousDir`` routes through
  ##   ``runquota_ipc.ensureEndpointDir``, which both provisions and VERIFIES
  ##   the directory by the product's own rule, so this file keeps no second
  ##   copy of it.
  ## * **``$TMPDIR`` is not short.** ``bindUnix``/``connectUnix`` refuse a
  ##   path of ``Sockaddr_un_path_length`` bytes or more — 108 on Linux, but
  ##   only 92 on macOS, where ``std/posix`` declares an array shorter than
  ##   the kernel's 104. The suite scratch root is 73 bytes on the shared CI
  ##   runners (``/var/lib/github-runner-work/<slot>/.cache/
  ##   reprobuild-test-tmp/<n>`` — a GARM work root, far deeper than a login
  ##   home), which put this socket at 116 bytes: the stub child died in
  ##   ``bindEndpoint`` with ``socket path too long``, ``waitForSocket`` then
  ##   failed, and the parent died in ``runquota_client.connect`` with the
  ##   same message — both cases having asserted nothing about a wedged
  ##   daemon. Shortening the fixture's own name was never the fix, because
  ##   the overflow is paid out of a budget the checkout and the ``TMPDIR``
  ##   have already spent: fixture IPC paths must fit INDEPENDENTLY of the
  ##   checkout and ``TMPDIR`` length (reprobuild ``6210412a``).
  ##   ``runquotaRendezvousDir`` already applies that rule — when
  ##   ``<root>/ep`` plus a socket name would not fit it relocates the
  ##   endpoint to a short private directory under ``/tmp``, provisioned and
  ##   verified by the very same ``ensureEndpointDir`` and registered for
  ##   removal at process exit only once it has passed.
  ##
  ## ONLY THE ENDPOINT MOVES. The scratch root is still a fresh
  ## ``createTempDir`` under ``$TMPDIR``, and the per-pid socket name is kept
  ## so a crashed run leaves an obvious trail. ``rq-<pid>.sock`` is 15 bytes
  ## at a seven-digit pid, inside the 24 bytes
  ## ``RunquotaRendezvousSocketNameBudget`` promises a caller.
  result.root = createTempDir("repro-wedged-rq-", "")
  result.socket = runquotaRendezvousDir(result.root) /
    ("rq-" & $getCurrentProcessId() & ".sock")

suite "repro_runquota grant-wait — wedged-but-connected daemon (end-to-end)":

  test "bounded daemonStatus against a connected-but-silent daemon raises within bound":
    # ``scratchRoot`` is removed here; the endpoint directory is inside it
    # unless it had to be relocated, and a relocated one is removed at
    # process exit by ``runquotaRendezvousDir`` itself.
    let (scratchRoot, socketPath) = privateSocketPath()
    removeFile(socketPath)
    let stub = startStub(socketPath)
    defer:
      stub.terminate()
      discard stub.waitForExit()
      removeFile(socketPath)
      removeDir(scratchRoot)
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
    let (scratchRoot, socketPath) = privateSocketPath()
    removeFile(socketPath)
    let stub = startStub(socketPath)
    defer:
      stub.terminate()
      discard stub.waitForExit()
      removeFile(socketPath)
      removeDir(scratchRoot)
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

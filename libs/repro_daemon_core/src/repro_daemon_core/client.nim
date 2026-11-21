import std/[os, strutils, times]

import repro_core

import ./daemon_lock_probe
import ./protocol

const
  UserDaemonHandshakeTimeoutMs* = 10_000
    ## Upper bound on how long a status handshake (the ``udkHello`` ack and a
    ## ``udkStatus`` response) may take before the client gives up and treats
    ## the daemon as unavailable. A responsive daemon sends its hello-ack the
    ## moment it accepts the connection, so this only ever fires for a wedged
    ## or protocol-incompatible daemon that binds the endpoint but never
    ## returns a complete frame. Without the bound the client blocks in
    ## ``recv`` forever — the deadlock the daemon control-plane suite hit on
    ## macOS when a build connected to the fake protocol-mismatch daemon.
    ## ``startUserDaemon`` turns the resulting not-running status into its
    ## existing "did not complete a compatible status handshake" fallback.

type
  UserDaemonClientError* = object of CatchableError

  UserDaemonBuildResult* = object
    supported*: bool
    exitCode*: int
    message*: string
    events*: seq[UserDaemonBuildEvent]
    connectionUs*: float

  UserDaemonWatchResult* = object
    supported*: bool
    exitCode*: int
    message*: string
    sessionId*: string
    events*: seq[UserDaemonBuildEvent]

proc userDaemonEndpointExists*(endpoint: string): bool =
  endpointExistsLocal(endpoint)

proc userDaemonEndpointAcceptsConnections*(endpoint: string): bool =
  endpointAcceptsConnections(endpoint)

proc featureSet(flags: string): seq[string] =
  for raw in flags.split(','):
    let item = raw.strip()
    if item.len > 0:
      result.add(item)

proc missingUserDaemonFeatures*(advertisedFlags: string;
                                required: openArray[string]): seq[string] =
  ## The names in ``required`` that ``advertisedFlags`` (the hello-ack's
  ## comma-separated feature list) does not carry, in the order required and
  ## without duplicates. Names are matched whole: ``build-events`` does not
  ## satisfy ``build``.
  ##
  ## ALL of them, not the first: a client refused for one feature used to
  ## learn of the next one only after the restart that fixed the first.
  let advertised = featureSet(advertisedFlags)
  for needed in required:
    if advertised.find(needed) < 0 and result.find(needed) < 0:
      result.add(needed)

proc imagePathText(identity: BinaryIdentity): string =
  # An identity the handshake did not fill in (an older daemon, a platform
  # that could not answer ``getAppFilename``) is said to be unknown rather
  # than printed as an empty field, which reads as a blank, not a gap.
  if identity.path.len > 0: identity.path else: "<unknown>"

proc versionText(identity: BinaryIdentity): string =
  if identity.version.len > 0: identity.version else: "<unknown>"

proc unsupportedDaemonMessage*(missing: openArray[string];
                               daemon, client: BinaryIdentity): string =
  ## The unsupported-daemon error ``connectUserDaemon`` raises when the
  ## daemon does not advertise a feature the request requires
  ## (spec/Local-Daemons-And-Control-Plane.md, *Protocol Compatibility*:
  ## "report a clear unsupported-daemon error under `require`").
  ##
  ## WHY IT SAYS SO MUCH (reprobuild-pm issue 2026-10-13). The case that
  ## reaches this is almost always a daemon still running an older image
  ## than the client -- a nix-store build serving a locally built CLI, say
  ## -- and the two report the SAME version string, because that string is
  ## the package version and every build between two bumps shares it. A
  ## reader holding "does not advertise required feature: X" next to two
  ## identical versions concludes the daemon is current and looks elsewhere.
  ## So the message names every missing feature and what it is for, puts
  ## the two IMAGE PATHS side by side (the field that actually
  ## discriminates), says outright that equal versions are not evidence,
  ## and gives the one-command remedy.
  ##
  ## The first line keeps the original wording -- with one missing feature
  ## it is byte-for-byte the line this error always raised -- so anything
  ## matching on it keeps working. Pure, so it is testable without a
  ## socket.
  let noun = if missing.len == 1: "feature" else: "features"
  result = "user daemon does not advertise required " & noun & ": " &
    missing.join(", ")
  for name in missing:
    result.add("\n  - " & name & ": " & userDaemonFeatureDescription(name))
  result.add("\ndaemon image: " & imagePathText(daemon) & " (version " &
    versionText(daemon) & ")")
  result.add("\nclient image: " & imagePathText(client) & " (version " &
    versionText(client) & ")")
  result.add("\nthe same version string does not mean the same features: " &
    "two builds of one release can differ, so compare the image paths " &
    "above, not the versions.")
  result.add("\nremedy: run `repro daemon restart` with this client to " &
    "relaunch the daemon from the current image.")

proc requireDaemonFeatures*(advertisedFlags: string;
                            required: openArray[string];
                            daemon, client: BinaryIdentity) =
  ## Raise ``UserDaemonClientError`` carrying ``unsupportedDaemonMessage``
  ## when ``advertisedFlags`` lacks any of ``required``; return quietly
  ## otherwise. ``daemon`` is the identity from the hello-ack and ``client``
  ## the one this process sent in its hello.
  let missing = missingUserDaemonFeatures(advertisedFlags, required)
  if missing.len > 0:
    raise newException(UserDaemonClientError,
      unsupportedDaemonMessage(missing, daemon, client))

proc connectUserDaemon*(endpoint = defaultUserDaemonEndpoint();
                        clientName = "repro";
                        commandMode = "daemon";
                        projectRoot = "";
                        protocolMajor = UserDaemonProtocolMajor;
                        protocolMinor = UserDaemonProtocolMinor;
                        requiredFeatures: openArray[string] = []): IpcConn =
  try:
    result = connectIpc(endpoint)
  except IpcEndpointError as exc:
    raise newException(UserDaemonClientError, exc.msg)
  let client = binaryIdentity(clientName, getAppFilename(), versionString())
  # Bound the hello SEND symmetrically with the hello-ack RECV below: a daemon
  # that accepts the connection but never ``recv``s (a wedged / stale daemon)
  # would otherwise block the client in ``send`` forever once the socket
  # buffers fill — the deadlock the m2 stale-endpoint test hit on macOS, where
  # ``connectUserDaemon → writeFrame → send`` hung for 50+ minutes. On timeout
  # ``writeFrame`` raises ``IpcEndpointError``; convert it to the daemon-client
  # error type so callers fall back to direct mode instead of hanging.
  try:
    result.writeFrame(udkHello, helloBody(client, UserDaemonFeatureFlags,
      commandMode, projectRoot, protocolMajor, protocolMinor),
      timeoutMs = UserDaemonHandshakeTimeoutMs)
  except IpcEndpointError as exc:
    result.closeIpcConn()
    raise newException(UserDaemonClientError, exc.msg)
  # Bound the hello-ack: a daemon that accepts the connection but never
  # returns a frame (wedged / protocol-incompatible) must not hang the client
  # forever. On timeout ``readFrame`` raises ``IpcEndpointError``; convert it
  # to the daemon-client error type (as the connect path above does) so every
  # caller's existing ``UserDaemonClientError`` handling routes it to a
  # fallback to direct mode instead of a hang.
  var ack: tuple[kind: UserDaemonMessageKind; body: seq[byte]]
  try:
    ack = result.readFrame(UserDaemonHandshakeTimeoutMs)
  except IpcEndpointError as exc:
    result.closeIpcConn()
    raise newException(UserDaemonClientError, exc.msg)
  if ack.kind == udkError:
    raise newException(UserDaemonClientError, parseErrorBody(ack.body))
  if ack.kind != udkHelloAck:
    raise newException(UserDaemonClientError,
      "user daemon returned unexpected hello frame: " & $ack.kind)
  let parsed = parseHelloAck(ack.body)
  if parsed.major != UserDaemonProtocolMajor:
    raise newException(UserDaemonClientError,
      "user daemon protocol mismatch: client major " &
      $UserDaemonProtocolMajor & ", daemon major " & $parsed.major)
  # ``parsed.daemon`` is the daemon's own identity from the hello-ack; it is
  # what lets the refusal name the image that lacks the feature. Close the
  # connection before raising: the caller never receives it on this path,
  # so nobody else could.
  try:
    requireDaemonFeatures(parsed.featureFlags, requiredFeatures,
      parsed.daemon, client)
  except UserDaemonClientError:
    result.closeIpcConn()
    raise

proc queryUserDaemonStatus*(endpoint = defaultUserDaemonEndpoint()):
    UserDaemonStatus =
  result.endpoint = endpoint
  if not endpointExistsLocal(endpoint):
    result.running = false
    return
  var conn: IpcConn
  try:
    conn = connectUserDaemon(endpoint, commandMode = "status")
  except CatchableError:
    result.running = false
    return
  defer: conn.closeIpcConn()
  # Bound the status SEND for the same reason as the hello send above: a daemon
  # that completed the hello handshake but then wedged before reading the
  # status request must not block the client in ``send``.
  conn.writeFrame(udkStatus, timeoutMs = UserDaemonHandshakeTimeoutMs)
  # Same bound as the hello-ack: a daemon that completes the hello handshake
  # but then stalls before answering the status query must not wedge the
  # client. The caller treats the raised error as "daemon not running".
  let frame = conn.readFrame(UserDaemonHandshakeTimeoutMs)
  if frame.kind == udkStatusResponse:
    return parseStatusBody(frame.body)
  if frame.kind == udkError:
    raise newException(UserDaemonClientError, parseErrorBody(frame.body))
  raise newException(UserDaemonClientError,
    "unexpected user-daemon status frame: " & $frame.kind)

const UserDaemonShutdownWaitSeconds = 5
  ## How long ``requestUserDaemonShutdown`` waits for the endpoint to close,
  ## and then again for the lockfile to go.

type
  UserDaemonShutdownResult* = object
    ## What ``requestUserDaemonShutdown`` observed of a stop that SUCCEEDED.
    ## A stop that did not succeed raises instead.
    staleLockPath*: string
      ## Non-empty when the daemon is gone but its lockfile is still on
      ## disk. No process holds the lock, or (``staleLockDetail``) the file
      ## could not be examined and the daemon process has exited.
    staleLockDetail*: string
      ## Why the leftover lockfile could not be examined, when it could not.
    successorPid*: int64
      ## Non-zero when ANOTHER daemon had the endpoint or the state
      ## directory by the time a wait ended, which is why the endpoint or
      ## the lockfile never went away. A caller must not then clean up after
      ## "the" daemon: what is registered and recorded now is the successor's.

proc userDaemonShutdownNote*(outcome: UserDaemonShutdownResult): string =
  ## The line a command prints beside "stopped" when the stop left something
  ## worth saying; empty when it did not.
  if outcome.successorPid != 0:
    return "another daemon (pid " & $outcome.successorPid &
      ") took over while the stopped one was shutting down; it was left " &
      "running"
  if outcome.staleLockPath.len == 0:
    return ""
  if outcome.staleLockDetail.len == 0:
    return "the daemon released its lock but left its lock file " &
      outcome.staleLockPath & " behind; no process holds the lock, and the " &
      "next daemon start takes it over"
  "the daemon process is gone but its lock file " & outcome.staleLockPath &
    " is still present and could not be examined (" &
    outcome.staleLockDetail & ")"

proc requestUserDaemonShutdown*(endpoint = defaultUserDaemonEndpoint()):
    UserDaemonShutdownResult {.discardable.} =
  ## Issue the shutdown request and wait for the daemon to RELEASE
  ## its endpoint and its state-directory lock — not just to ACK. The
  ## daemon's listener loop sends ``sdkShutdownAck`` from inside
  ## ``handleClient`` before its outer ``defer`` chain runs (close listener,
  ## remove endpoint files, release lock, remove lockfile). On Windows the
  ## lockfile + status file removal lags the ACK by a few hundred
  ## microseconds; a caller that immediately tries ``removeDir(tempRoot)``
  ## then hits "The process cannot access the file because it is being used
  ## by another process."
  ##
  ## A failure says which thing was observed, because they are different
  ## faults: the endpoint still accepting connections (the daemon never left
  ## its accept loop), or the endpoint closed with the lock still HELD (a
  ## process is still alive behind it). A lockfile that is merely still on
  ## disk, held by nobody, is not a failure of the stop: the daemon has let
  ## go of the state directory. Nor is a different daemon having taken over.
  ## That is returned, not raised (reprobuild-pm issue 2026-11-16, "`repro
  ## daemon stop` reports 'did not release its endpoint within 5 s' even
  ## when the daemon exited": all three used to raise that one sentence).
  # Ask the daemon for its state-dir and pid BEFORE issuing the shutdown so
  # we can poll for its lockfile to disappear once the endpoint flips quiet —
  # querying after shutdown loses the race (the daemon might already
  # be tearing down the listener when the status request lands).
  var stateDir = ""
  var daemonPid = 0'i64
  try:
    let before = queryUserDaemonStatus(endpoint)
    stateDir = before.stateDir
    daemonPid = before.pid
  except CatchableError:
    discard
  block:
    var socket = connectUserDaemon(endpoint, commandMode = "stop")
    defer: socket.closeIpcConn()
    socket.writeFrame(udkShutdown)
    let frame = socket.readFrame()
    if frame.kind == udkError:
      raise newException(UserDaemonClientError, parseErrorBody(frame.body))
    if frame.kind != udkShutdownAck:
      raise newException(UserDaemonClientError,
        "unexpected user-daemon shutdown frame: " & $frame.kind)

  # Poll for endpoint quiescence. The daemon's listener-defer runs
  # FIRST (LIFO order) — that closes the IPC listener and flips
  # ``endpointAcceptsConnections`` to false. The lockfile release
  # runs in the SECOND defer immediately after.
  #
  # Between the two defers the daemon also writes the final
  # ``stopped`` line to its log + reads/removes the lockfile metadata,
  # so the gap to a clean ``removeDir(stateDir)`` is a few hundred
  # milliseconds on a healthy host. On a heavily-loaded Windows host
  # the daemon process's scheduling latency between the two defers
  # has been observed at >200 ms, hitting integration tests' defer
  # chain with ``ERROR_SHARING_VIOLATION`` on the lockfile. After the
  # endpoint flips quiet, poll for ``.repro-daemon.lock`` (which lives
  # next to ``status/`` under the state-dir reported by the daemon's
  # status response) to disappear — that file's removal IS the final
  # action of ``releaseUserDaemonLock`` and is the canonical signal
  # the cleanup chain has fully drained.
  let waitText = $UserDaemonShutdownWaitSeconds & " s"

  proc successorOnEndpoint(): int64 =
    ## The pid of a DIFFERENT daemon answering on the endpoint, else 0.
    if daemonPid <= 0:
      return 0
    try:
      let now = queryUserDaemonStatus(endpoint)
      if now.running and now.pid > 0 and now.pid != daemonPid:
        return now.pid
    except CatchableError:
      discard
    0

  proc successorInLockfile(lockPath: string): int64 =
    ## The pid a DIFFERENT, still-running daemon wrote into the lockfile,
    ## else 0. A daemon writes its metadata as soon as it holds the lock
    ## (``lockMetadata``). Unreadable while locked on Windows, which answers
    ## 0. A pid established to be gone is no successor: one that started and
    ## died left the file, and is reported as the leftover it is.
    if daemonPid <= 0:
      return 0
    try:
      for line in readFile(lockPath).splitLines():
        if line.startsWith("pid="):
          let pid = parseBiggestInt(line["pid=".len .. ^1].strip())
          if pid > 0 and pid != daemonPid and not userDaemonProcessGone(pid):
            return pid
    except CatchableError:
      discard
    0

  var endpointClosed = false
  let deadline = epochTime() + float(UserDaemonShutdownWaitSeconds)
  while epochTime() < deadline:
    if not endpointAcceptsConnections(endpoint):
      endpointClosed = true
      break
    sleep(10)
  if not endpointClosed:
    # Something is still listening after the ACK. If it is another daemon
    # (one bound the endpoint between two polls), the one we asked is gone.
    let successor = successorOnEndpoint()
    if successor != 0:
      return UserDaemonShutdownResult(successorPid: successor)
    # Otherwise the daemon never left its accept loop. That's a real bug —
    # surface it instead of silently returning.
    raise newException(UserDaemonClientError,
      "user-daemon at " & endpoint & " acknowledged the shutdown request " &
      "but is still accepting connections " & waitText & " later")
  if stateDir.len == 0:
    # We never got a state-dir from the pre-shutdown status
    # query. Fall back to a fixed wait long enough for the
    # daemon's lockfile defer to land on a busy Windows host.
    sleep(1500)
    return
  let lockPath = stateDir / UserDaemonLockFileName
  let lockDeadline = epochTime() + float(UserDaemonShutdownWaitSeconds)
  while epochTime() < lockDeadline:
    if not fileExists(lockPath):
      # Lockfile is gone: removing it is the daemon's last act, after it
      # closed its own handle. (On Windows a file whose delete is still
      # pending behind ANOTHER process's handle also reads as gone here.)
      return
    sleep(25)

  # The endpoint closed, yet the lockfile is still on disk. Find out which
  # of the things that can mean is the case, and say that one.
  #
  # 1. Another daemon took the state directory over in the meantime (a
  #    concurrent `repro build` auto-started one). Its lockfile is the one
  #    we are looking at, and the daemon we stopped is gone. Asked first,
  #    so the probe below never touches the lock of a daemon that is
  #    starting up; the lockfile is read as well because the successor may
  #    serve another endpoint or not have bound this one yet.
  var successor = successorOnEndpoint()
  if successor == 0:
    successor = successorInLockfile(lockPath)
  if successor != 0:
    return UserDaemonShutdownResult(successorPid: successor)
  let pidText =
    if daemonPid > 0: "pid " & $daemonPid
    else: "pid unknown"
  let probe = probeUserDaemonLock(lockPath)
  case probe.state
  of udlAbsent:
    return
  of udlFree:
    # 2. Nobody holds the lock: the daemon let go of it (or died), and only
    #    the file was left. Not removed here: a daemon starting right now
    #    may already have this very file open, and unlinking it under that
    #    daemon would let a second one lock a fresh file beside it.
    return UserDaemonShutdownResult(staleLockPath: lockPath)
  of udlHeld:
    # 3. A process is alive behind the closed endpoint. Which one is only
    #    known when the daemon's own pid is established to be gone.
    let holder =
      if userDaemonProcessGone(daemonPid):
        "the daemon process (" & pidText & ") is gone, so another " &
          "process holds the lock"
      else:
        "the daemon process (" & pidText & ") still exists"
    raise newException(UserDaemonClientError,
      "user-daemon at " & endpoint & " closed its endpoint after the " &
      "shutdown request, but its lock " & lockPath & " is still held " &
      waitText & " later: " & holder)
  of udlUnexamined:
    if userDaemonProcessGone(daemonPid):
      return UserDaemonShutdownResult(staleLockPath: lockPath,
        staleLockDetail: probe.detail)
    raise newException(UserDaemonClientError,
      "user-daemon at " & endpoint & " closed its endpoint after the " &
      "shutdown request, but its lock file " & lockPath & " is still " &
      "present " & waitText & " later and could not be examined (" &
      probe.detail & "); the daemon process (" & pidText &
      ") still exists or could not be checked")

proc requestUserDaemonSessions*(endpoint = defaultUserDaemonEndpoint()):
    seq[UserDaemonSession] =
  var socket = connectUserDaemon(endpoint, commandMode = "sessions")
  defer: socket.closeIpcConn()
  socket.writeFrame(udkSessions)
  let frame = socket.readFrame()
  if frame.kind == udkSessionsResponse:
    return parseSessionsBody(frame.body)
  if frame.kind == udkError:
    raise newException(UserDaemonClientError, parseErrorBody(frame.body))
  raise newException(UserDaemonClientError,
    "unexpected user-daemon sessions frame: " & $frame.kind)

proc requestUserDaemonLeaseRenew*(request: DaemonLeaseRenewRequest;
                                  endpoint = defaultUserDaemonEndpoint()):
    DaemonLeaseRenewResponse =
  ## Ephemeral-State-Leases L4 (§4.2): send a lease RENEW to the running
  ## daemon and return its ack. Raises ``UserDaemonClientError`` if the
  ## daemon is unreachable or answers with ``udkError`` — callers that want
  ## the best-effort, no-daemon-tolerant behaviour use
  ## ``renewLeaseBestEffort`` below.
  var socket = connectUserDaemon(endpoint, commandMode = "lease-renew",
    requiredFeatures = ["lease-registry"])
  defer: socket.closeIpcConn()
  socket.writeFrame(udkLeaseRenew, leaseRenewRequestBody(request))
  let frame = socket.readFrame()
  if frame.kind == udkLeaseRenewAck:
    return parseLeaseRenewResponseBody(frame.body)
  if frame.kind == udkError:
    raise newException(UserDaemonClientError, parseErrorBody(frame.body))
  raise newException(UserDaemonClientError,
    "unexpected user-daemon lease-renew frame: " & $frame.kind)

proc requestUserDaemonServiceConverge*(
    request: DaemonServiceConvergeRequest;
    endpoint = defaultUserDaemonEndpoint()):
    DaemonServiceConvergeResponse =
  ## Shared-Development-Services L7 (§4.5): `repro up`'s converge.
  ##
  ## THERE IS DELIBERATELY NO `...BestEffort` SIBLING, unlike
  ## `renewLeaseBestEffort` one proc up. A lease renew that cannot reach
  ## the daemon is harmless -- the reconcile's own store write is the
  ## source of truth. A CONVERGE that cannot reach the daemon is not:
  ## there is no registry to resolve against, so the only things a
  ## best-effort arm could do are start a second instance or pretend one
  ## is running. §4.5 makes the daemon the registry, so an unreachable
  ## daemon has to be an error the caller sees and reports.
  var socket = connectUserDaemon(endpoint, commandMode = "service-converge",
    requiredFeatures = ["service-instance-registry"])
  defer: socket.closeIpcConn()
  socket.writeFrame(udkServiceConverge, serviceConvergeRequestBody(request))
  let frame = socket.readFrame()
  if frame.kind == udkServiceConvergeAck:
    return parseServiceConvergeResponseBody(frame.body)
  if frame.kind == udkError:
    raise newException(UserDaemonClientError, parseErrorBody(frame.body))
  raise newException(UserDaemonClientError,
    "unexpected user-daemon service-converge frame: " & $frame.kind)

proc requestUserDaemonServiceRelease*(
    request: DaemonServiceReleaseRequest;
    endpoint = defaultUserDaemonEndpoint()):
    DaemonServiceReleaseResponse =
  ## L7 (§4.5): `repro down`'s release. No best-effort sibling, for the
  ## reason above pointing the other way: a release that silently did
  ## nothing would leave this project counted as a holder forever, so the
  ## instance would never be released by anyone.
  var socket = connectUserDaemon(endpoint, commandMode = "service-release",
    requiredFeatures = ["service-instance-registry"])
  defer: socket.closeIpcConn()
  socket.writeFrame(udkServiceRelease, serviceReleaseRequestBody(request))
  let frame = socket.readFrame()
  if frame.kind == udkServiceReleaseAck:
    return parseServiceReleaseResponseBody(frame.body)
  if frame.kind == udkError:
    raise newException(UserDaemonClientError, parseErrorBody(frame.body))
  raise newException(UserDaemonClientError,
    "unexpected user-daemon service-release frame: " & $frame.kind)

proc renewLeaseBestEffort*(request: DaemonLeaseRenewRequest;
                           endpoint = defaultUserDaemonEndpoint()):
    tuple[sent: bool; response: DaemonLeaseRenewResponse] =
  ## The seam a ``repro`` reconcile that consumes a leased state calls after
  ## its in-process L1 store write: forward the renew to the daemon-hosted
  ## registry IF one is reachable. This NEVER regresses the no-daemon path —
  ## if the daemon is absent / unreachable / does not advertise the
  ## ``lease-registry`` feature, ``sent`` is false and the reconcile's own
  ## store write (L2) remains the source of truth. It never raises.
  try:
    let response = requestUserDaemonLeaseRenew(request, endpoint)
    (sent: true, response: response)
  except CatchableError:
    (sent: false, response: DaemonLeaseRenewResponse(ok: false,
      reason: "daemon unreachable", effectiveDeadlineUnix: LeaseRenewKeepSentinel))

proc requestUserDaemonLeaseReapProviders*(
    request: DaemonLeaseReapProvidersRequest;
    endpoint = defaultUserDaemonEndpoint()):
    DaemonLeaseReapProvidersResponse =
  ## Ephemeral-State-Leases L4/L5 (§4.2 destroy transport): tell the running
  ## daemon which provider artifact serves which resource ``typeId``, so its
  ## reap tick can destroy an out-of-tree type over a launched provider session
  ## rather than falling back to in-process linking it does not have. Raises
  ## ``UserDaemonClientError`` if the daemon is unreachable or answers with
  ## ``udkError`` — callers that want the best-effort, no-daemon-tolerant
  ## behaviour use ``registerLeaseReapProvidersBestEffort`` below.
  ##
  ## Requires the ``lease-reap-providers`` feature as well as
  ## ``lease-registry``, so a NEW client against an OLD daemon is refused by
  ## the handshake rather than by that daemon's "unsupported user-daemon
  ## message" error frame. Both end as a raise here, but only the first is a
  ## truthful one: the old daemon is working exactly as built, it simply does
  ## not have this capability.
  var socket = connectUserDaemon(endpoint, commandMode = "lease-reap-providers",
    requiredFeatures = ["lease-registry", "lease-reap-providers"])
  defer: socket.closeIpcConn()
  socket.writeFrame(udkLeaseReapProviders,
    leaseReapProvidersRequestBody(request))
  let frame = socket.readFrame()
  if frame.kind == udkLeaseReapProvidersAck:
    return parseLeaseReapProvidersResponseBody(frame.body)
  if frame.kind == udkError:
    raise newException(UserDaemonClientError, parseErrorBody(frame.body))
  raise newException(UserDaemonClientError,
    "unexpected user-daemon lease-reap-providers frame: " & $frame.kind)

proc registerLeaseReapProvidersBestEffort*(
    request: DaemonLeaseReapProvidersRequest;
    endpoint = defaultUserDaemonEndpoint()):
    tuple[sent: bool; response: DaemonLeaseReapProvidersResponse] =
  ## The seam a ``repro`` reconcile that materializes an OUT-OF-TREE leased
  ## state calls once it knows the provider artifacts: forward them to the
  ## daemon-hosted reap registry IF one is reachable.
  ##
  ## BEST-EFFORT, AND IT MATTERS THAT IT IS. This registration is a freshness
  ## optimization, not the mechanism: the artifact is also persisted in each
  ## state record the reconcile writes, so a reaper with no daemon — or a
  ## daemon restarted since — still finds its route in the store (§4.3). A
  ## reconcile must therefore never fail, or even slow, because no daemon was
  ## listening. ``sent`` is false in that case and is purely observational; it
  ## never raises.
  try:
    let response = requestUserDaemonLeaseReapProviders(request, endpoint)
    (sent: true, response: response)
  except CatchableError:
    (sent: false, response: DaemonLeaseReapProvidersResponse(ok: false,
      reason: "daemon unreachable"))

proc requestUserDaemonBuild*(request: UserDaemonBuildRequest;
                             endpoint = defaultUserDaemonEndpoint();
                             onEvent: proc(event: UserDaemonBuildEvent) = nil):
    UserDaemonBuildResult =
  let connectStart = epochTime()
  var socket = connectUserDaemon(endpoint, commandMode = "build",
    projectRoot = request.projectRoot,
    requiredFeatures = ["build-routing", "build-events"])
  result.connectionUs = (epochTime() - connectStart) * 1_000_000.0
  defer: socket.closeIpcConn()
  socket.writeFrame(udkBuildRequest, buildRequestBody(request))
  while true:
    let frame = socket.readFrame()
    if frame.kind == udkBuildEvent:
      let event = parseBuildEventBody(frame.body)
      result.events.add(event)
      if onEvent != nil:
        onEvent(event)
      if event.terminal:
        result.exitCode = event.exitCode
        result.message = event.message
        result.supported = event.kind != bekUnsupported
        return
    elif frame.kind == udkError:
      raise newException(UserDaemonClientError, parseErrorBody(frame.body))
    else:
      raise newException(UserDaemonClientError,
        "unexpected user-daemon build frame: " & $frame.kind)

proc requestUserDaemonWatchStart*(request: UserDaemonWatchRequest;
                                  endpoint = defaultUserDaemonEndpoint();
                                  onEvent: proc(event: UserDaemonBuildEvent) = nil):
    UserDaemonWatchResult =
  var socket = connectUserDaemon(endpoint, commandMode = "watch",
    projectRoot = request.projectRoot,
    requiredFeatures = ["watch-routing", "watch-events", "watch-sessions"])
  defer: socket.closeIpcConn()
  socket.writeFrame(udkWatchStartRequest, watchRequestBody(request))
  while true:
    let frame = socket.readFrame()
    if frame.kind == udkWatchEvent:
      let event = parseBuildEventBody(frame.body)
      result.events.add(event)
      if result.sessionId.len == 0:
        result.sessionId = event.sessionId
      if onEvent != nil:
        onEvent(event)
      if request.detached and event.kind == bekAccepted:
        result.exitCode = 0
        result.message = event.message
        result.supported = true
        return
      if event.terminal:
        result.exitCode = event.exitCode
        result.message = event.message
        result.supported = event.kind != bekUnsupported
        return
    elif frame.kind == udkError:
      raise newException(UserDaemonClientError, parseErrorBody(frame.body))
    else:
      raise newException(UserDaemonClientError,
        "unexpected user-daemon watch frame: " & $frame.kind)

proc requestUserDaemonWatchAttach*(sessionId: string;
                                   endpoint = defaultUserDaemonEndpoint();
                                   onEvent: proc(event: UserDaemonBuildEvent) = nil):
    UserDaemonWatchResult =
  var socket = connectUserDaemon(endpoint, commandMode = "watch-attach",
    requiredFeatures = ["watch-routing", "watch-events", "watch-sessions"])
  defer: socket.closeIpcConn()
  socket.writeFrame(udkWatchAttachRequest, watchSessionRequestBody(
    UserDaemonWatchSessionRequest(sessionId: sessionId,
      cancelOnDisconnect: false)))
  while true:
    let frame = socket.readFrame()
    if frame.kind == udkWatchEvent:
      let event = parseBuildEventBody(frame.body)
      result.events.add(event)
      result.sessionId = event.sessionId
      if onEvent != nil:
        onEvent(event)
      if event.terminal:
        result.exitCode = event.exitCode
        result.message = event.message
        result.supported = event.kind != bekUnsupported
        return
    elif frame.kind == udkError:
      raise newException(UserDaemonClientError, parseErrorBody(frame.body))
    else:
      raise newException(UserDaemonClientError,
        "unexpected user-daemon watch attach frame: " & $frame.kind)

proc requestUserDaemonWatchStop*(sessionId: string;
                                 endpoint = defaultUserDaemonEndpoint()):
    UserDaemonWatchResult =
  var socket = connectUserDaemon(endpoint, commandMode = "watch-stop",
    requiredFeatures = ["watch-routing", "watch-events", "watch-sessions"])
  defer: socket.closeIpcConn()
  socket.writeFrame(udkWatchStopRequest, watchSessionRequestBody(
    UserDaemonWatchSessionRequest(sessionId: sessionId)))
  let frame = socket.readFrame()
  if frame.kind == udkWatchEvent:
    let event = parseBuildEventBody(frame.body)
    result.events.add(event)
    result.sessionId = event.sessionId
    result.exitCode = event.exitCode
    result.message = event.message
    result.supported = true
    return
  if frame.kind == udkError:
    raise newException(UserDaemonClientError, parseErrorBody(frame.body))
  raise newException(UserDaemonClientError,
    "unexpected user-daemon watch stop frame: " & $frame.kind)

proc requestUserDaemonWatchDetach*(sessionId: string;
                                   endpoint = defaultUserDaemonEndpoint()):
    UserDaemonWatchResult =
  var socket = connectUserDaemon(endpoint, commandMode = "watch-detach",
    requiredFeatures = ["watch-routing", "watch-events", "watch-sessions"])
  defer: socket.closeIpcConn()
  socket.writeFrame(udkWatchDetachRequest, watchSessionRequestBody(
    UserDaemonWatchSessionRequest(sessionId: sessionId)))
  let frame = socket.readFrame()
  if frame.kind == udkWatchEvent:
    let event = parseBuildEventBody(frame.body)
    result.events.add(event)
    result.sessionId = event.sessionId
    result.exitCode = event.exitCode
    result.message = event.message
    result.supported = true
    return
  if frame.kind == udkError:
    raise newException(UserDaemonClientError, parseErrorBody(frame.body))
  raise newException(UserDaemonClientError,
    "unexpected user-daemon watch detach frame: " & $frame.kind)

import std/[os, sets, strutils, times]

import repro_core
import blake3

import ./ipc
export ipc

when defined(posix):
  import std/posix

const
  UserDaemonProtocolMajor* = 1'u16
  UserDaemonProtocolMinor* = 2'u16
    ## 2 covers every frame added to this protocol since minor 1, which in this
    ## tree is two independent additions that landed together in a merge:
    ##
    ##   * ``udkServiceConverge``/``Ack`` and ``udkServiceRelease``/``Ack``
    ##     (the shared-service instance registry, 22-25) — added WITHOUT a
    ##     minor bump on their own branch;
    ##   * ``udkLeaseReapProviders``/``Ack`` (26-27 — how the daemon reaches an
    ##     out-of-tree provider to destroy its state, Ephemeral-State-Leases
    ##     §4.2), which is what raised the minor to 2.
    ##
    ## The number is therefore not a claim about either change by itself; it
    ## says "newer than 1". Said explicitly because the bump arrived with one of
    ## the two and a reader could otherwise take minor 2 to mean only that one.
    ##
    ## A MINOR bump, not a major one: every added frame is additive and no
    ## earlier request changed, so an old client talks to a new daemon exactly
    ## as before. The reverse direction — a new client against an old daemon —
    ## is handled by the FEATURE FLAGS below rather than by this number, which
    ## is what clients actually gate on; a version comparison cannot say which
    ## of two independent additions a given daemon has.
  UserDaemonRole* = "repro-daemon/user"
  UserDaemonFeatureFlags* =
    "lifecycle,status,logs,shutdown,sessions,build-routing,build-events," &
    "watch-routing,watch-events,watch-sessions,dev-self-restart," &
    "substitute-routing,lease-registry,service-instance-registry," &
    "lease-reap-providers"
    ## ``lease-reap-providers`` is advertised separately from
    ## ``lease-registry``, which only promises the renew half. A new CLI
    ## against an OLD daemon must fail the feature gate in
    ## ``requestUserDaemonLeaseReapProviders`` and report ``sent = false``,
    ## rather than send a frame kind that daemon's lifecycle server answers
    ## with ``unsupported user-daemon message`` — a best-effort registration
    ## has to be able to tell "no daemon wants this" from "the daemon broke".
  BuildEventSchemaId* = "reprobuild.daemon.build-event.v1"
  BuildEventSchemaVersion* = 1'u16
  FrameMagic = "RBUD"
  ReproTestRunnerOwnerTokenEnv = "REPRO_TEST_RUNNER_OWNER_TOKEN"

proc unknownUserDaemonFeatureDescription*(name: string): string =
  ## The description `userDaemonFeatureDescription` gives a name it has no
  ## entry for. Exported so the completeness test can tell "described"
  ## from "fell through" without duplicating this wording.
  ##
  ## An unknown name reaches a refusal when a client is newer than this
  ## table's copy in the image doing the describing, so the text says that
  ## rather than pretending the feature does not exist.
  "a daemon capability this build has no description for (" & name & ")"

proc userDaemonFeatureDescription*(name: string): string =
  ## The human-facing meaning of one wire feature name from
  ## `UserDaemonFeatureFlags`, for diagnostics that refuse a daemon lacking
  ## it (`unsupportedDaemonMessage` in `client.nim`).
  ##
  ## WHY THIS TABLE EXISTS. The wire names are terse protocol tokens, and
  ## a refusal that says only `lease-registry` leaves the reader to guess
  ## what they were trying to do that needed it. Two builds of one release
  ## share a version string while differing in this list (reprobuild-pm
  ## issue 2026-10-13), so the feature name is the only discriminator a
  ## refused client can point to, and it has to be readable.
  ##
  ## EVERY FLAG IN `UserDaemonFeatureFlags` MUST HAVE AN ENTRY HERE;
  ## `tests/t_daemon_missing_feature_diagnostic.nim` fails, naming the flag,
  ## when one does not. Keep each description short and say what the
  ## client asked the daemon to do, not how the daemon does it.
  case name
  of "lifecycle": "daemon lifecycle control (start, stop, restart)"
  of "status": "status queries (`repro daemon status`)"
  of "logs": "daemon log access (`repro daemon logs`)"
  of "shutdown": "shutdown requests (`repro daemon stop`)"
  of "sessions": "session listing (`repro daemon sessions`)"
  of "build-routing": "running `repro build` inside the daemon"
  of "build-events": "streaming build progress events back to the client"
  of "watch-routing": "running `repro watch` inside the daemon"
  of "watch-events": "streaming watch-session events back to the client"
  of "watch-sessions":
    "attaching to, detaching from and stopping watch sessions"
  of "dev-self-restart":
    "dev-mode self-restart onto a rebuilt daemon image (`--dev`)"
  of "substitute-routing":
    "binary-cache substitution served by the daemon (multi-user mode)"
  of "lease-registry":
    "the ephemeral-state lease registry (lease renewals)"
  of "service-instance-registry":
    "sharing development service instances between sessions " &
      "(`repro up` / `repro down` converge on and release them)"
  of "lease-reap-providers":
    "registering the provider that owns a resource type, so the daemon can " &
    "reap that type's state over a provider session"
  else: unknownUserDaemonFeatureDescription(name)

proc sanitizeUserDaemonRequestEnvironment*(
    environment: openArray[string]): seq[string] =
  ## Remove the test runner's private process-ownership marker at every daemon
  ## request boundary. The marker belongs only to OS process launch/restart
  ## ownership. It must never enter the daemon wire protocol, build/watch
  ## action environments, fingerprints, cache inputs, logs, or results.
  ##
  ## Preserve every unrelated entry byte-for-byte and in its original order.
  ## A malformed marker entry without ``=`` is filtered as well so even its
  ## private name cannot cross the wire.
  for item in environment:
    let split = item.find('=')
    let key = if split < 0: item else: item[0 ..< split]
    if key != ReproTestRunnerOwnerTokenEnv:
      result.add(item)

proc daemonCarriedEnvironment*(): seq[string] =
  ## Snapshot the user-facing CLI environment for the daemon-hosted build/watch
  ## executor. Direct builds evaluate providers and resolve action
  ## ``envPassthrough`` values against this environment; daemon builds must be
  ## byte-for-byte equivalent even when a project declares an arbitrary name
  ## that reprobuild could not know in advance.
  ##
  ## The request worker installs this snapshot only for the duration of one
  ## session and restores its prior environment afterwards. The build engine
  ## still filters each action down to its declared passthrough set. The wire
  ## sanitizer removes the test runner's private ownership marker before any
  ## request is encoded.
  ##
  ## THIS LIVES HERE, not in ``repro_cli_support``, because BOTH clients that
  ## can compose a ``UserDaemonBuildRequest`` must produce the same snapshot:
  ## the full ``repro`` image and the thin ``repro-client`` (MAC-1). The
  ## request's environment feeds action fingerprints and cache keys, so two
  ## independently-maintained snapshots would let the same command get
  ## different cache decisions depending on which client the user ran.
  var seen = initHashSet[string]()
  for key, value in envPairs():
    if key.len == 0 or seen.contains(key):
      continue
    seen.incl(key)
    result.add(key & "=" & value)
  result = sanitizeUserDaemonRequestEnvironment(result)

type
  UserDaemonMessageKind* = enum
    udkHello = 1
    udkHelloAck = 2
    udkStatus = 3
    udkStatusResponse = 4
    udkShutdown = 5
    udkShutdownAck = 6
    udkSessions = 7
    udkSessionsResponse = 8
    udkBuildRequest = 9
    udkBuildEvent = 10
    udkBuildCancel = 11
    udkWatchStartRequest = 12
    udkWatchAttachRequest = 13
    udkWatchDetachRequest = 14
    udkWatchStopRequest = 15
    udkWatchEvent = 16
    udkWatchListRequest = 17
    udkSubstituteRequest = 18
      ## ReproOS-Generations-And-Foreign-Packages A2.5 P6 — multi-user
      ## substitute request. Carries a non-empty list of root cache-entry
      ## keys (the closure to substitute) plus the upstream endpoint
      ## (baseUrl + trusted-signer pubkeys + priority + single-writer
      ## flag). The daemon answers with ``udkSubstituteResponse``.
    udkSubstituteResponse = 19
      ## Reply for ``udkSubstituteRequest``: the plan, per-step outcomes,
      ## realized CAS paths, totals, and an aggregate ok/reason field.
    udkLeaseRenew = 20
      ## Ephemeral-State-Leases L4 (§4.2 renew). A ``repro`` reconcile that
      ## CONSUMES a leased state sends this to advance the holder's lease
      ## in the daemon-hosted registry: ``{scope, address, consumerId,
      ## ttlSeconds}``. The daemon sets ``holders[consumerId] =
      ## deadlineFrom(policy, now)`` for a dated policy, or records the
      ## consumer in ``keepHolders`` for ``keep``, recomputes the
      ## reference-counted MAX ``effectiveDeadline`` (L2 semantics), and
      ## persists the record. The daemon answers with ``udkLeaseRenewAck``.
    udkLeaseRenewAck = 21
      ## Reply for ``udkLeaseRenew``: whether a record existed + was
      ## renewed, and the resulting (optional) effective deadline.
    udkServiceConverge = 22
      ## Shared-Development-Services L7 (§4.5): converge on the instance
      ## of a shared development service named by ``(identity, scope,
      ## environment)``. The daemon attaches when an instance is present
      ## and MATERIALISES one otherwise, inside this one request -- see
      ## ``instance_registry.nim`` for why the decision and the
      ## materialisation cannot be two round trips. Answered with
      ## ``udkServiceConvergeAck``.
    udkServiceConvergeAck = 23
      ## Reply for ``udkServiceConverge``.
    udkServiceRelease = 24
      ## L7 (§4.5): drop ONE holder's reference to an instance. The
      ## instance is stopped only when that was the last holder; this is
      ## ``repro down``'s request and the reason it does not stop an
      ## instance another project is using. Answered with
      ## ``udkServiceReleaseAck``.
    udkServiceReleaseAck = 25
      ## Reply for ``udkServiceRelease``.
    udkLeaseReapProviders = 26
      ## Ephemeral-State-Leases L4/L5 (§4.2 destroy transport). A ``repro``
      ## reconcile that materializes an OUT-OF-TREE leased state sends this to
      ## tell the daemon how to reach that type's provider:
      ## ``{scope, [{typeId, binaryPath, providerArtifactId, workingDir}]}``.
      ## The daemon registers each with its reap-provider registry, so its next
      ## wall-clock tick dispatches that type's destroy over a launched provider
      ## SESSION instead of falling back to in-process linking it does not have.
      ## The daemon answers with ``udkLeaseReapProvidersAck``.
      ##
      ## This is the FRESH half of the §4.2 artifact resolution; the durable
      ## half is the artifact persisted in the state record itself. The
      ## registration is in-memory and therefore lost on a daemon restart,
      ## which is exactly why it is not the only half: see
      ## ``reapTransportFactory``.
      ##
      ## NUMBERED 26, NOT 22. This pair was written as 22/23 on its own branch
      ## and renumbered when it merged: the shared-service frames above had
      ## already landed on ``agents`` at 22-25, so they are the PUBLISHED
      ## meaning of those numbers and a daemon built from that branch answers
      ## them. Two meanings for one wire number is not a conflict a reader can
      ## detect at runtime — a mismatched pair would be decoded as the other
      ## request's body — so the later addition moves. Never reuse a number an
      ## ancestor published, even if nothing has shipped yet.
    udkLeaseReapProvidersAck = 27
      ## Reply for ``udkLeaseReapProviders``: whether the registration was
      ## accepted and how many entries were registered.
    udkError = 255

  UserDaemonBuildEventKind* = enum
    bekAccepted = "accepted"
    bekDiagnostic = "diagnostic"
    bekUnsupported = "unsupported"
    bekCancelled = "cancelled"
    bekFinished = "finished"

  BinaryIdentity* = object
    name*: string
    path*: string
    version*: string
    sizeBytes*: int64
    mtimeUnix*: int64

  UserDaemonStatus* = object
    running*: bool
    role*: string
    endpoint*: string
    stateDir*: string
    logPath*: string
    pid*: int64
    uptimeSeconds*: int64
    protocolMajor*: uint16
    protocolMinor*: uint16
    binary*: BinaryIdentity
    featureFlags*: string
    generation*: string
    activeSessionCount*: int
    devMode*: bool
    sourceImagePath*: string
    runningImagePath*: string
    sourceHash*: string
    runningHash*: string
    protocolGeneration*: string
    restartRunId*: string
    stagedGenerationDir*: string
    previousStagedGenerationDir*: string
    reconnectLimitations*: string

  UserDaemonSession* = object
    sessionId*: string
    projectRoot*: string
    mode*: string
    state*: string
    startedAtUnix*: int64
    endedAtUnix*: int64
    exitCode*: int
    message*: string
    selectedRoots*: seq[string]
    debounceMs*: int
    watchedPaths*: seq[string]
    tierState*: string
    lastResult*: string
    writer*: string
      ## Writer identity (`writer_identity.encodeWriterIdentity`), so a record
      ## left non-terminal by a crashed writer can be told from a build still
      ## in flight. ON-DISK ONLY and deliberately absent from `writeSession`
      ## / `readSession`: reclamation is a daemon-local concern about its own
      ## state directory, and putting it on the wire would be a protocol
      ## change for no consumer.

  UserDaemonBuildRequest* = object
    runId*: string
    target*: string
    workingDir*: string
    projectRoot*: string
    toolProvisioning*: string
    workRoot*: string
    publicCliPath*: string
    rawArgs*: seq[string]
    environment*: seq[string]
    attached*: bool
    cancelOnDisconnect*: bool

  UserDaemonWatchRequest* = object
    runId*: string
    target*: string
    workingDir*: string
    projectRoot*: string
    toolProvisioning*: string
    workRoot*: string
    publicCliPath*: string
    rawArgs*: seq[string]
    environment*: seq[string]
    attached*: bool
    detached*: bool
    cancelOnDisconnect*: bool
    debounceMs*: int
    maxCycles*: int
    selectedRoots*: seq[string]

  UserDaemonWatchSessionRequest* = object
    sessionId*: string
    cancelOnDisconnect*: bool

  UserDaemonBuildEvent* = object
    schemaId*: string
    schemaVersion*: uint16
    eventId*: uint64
    occurredAtUnixMs*: int64
    runId*: string
    sessionId*: string
    projectRoot*: string
    command*: string
    kind*: UserDaemonBuildEventKind
    severity*: string
    message*: string
    terminal*: bool
    exitCode*: int
    payloadJson*: string

proc bytesOf(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc textOf(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc writeBool(buf: var seq[byte]; value: bool) =
  buf.add(if value: 1'u8 else: 0'u8)

proc readBool(buf: openArray[byte]; pos: var int): bool =
  if pos >= buf.len:
    raise newException(ValueError, "truncated boolean")
  result = buf[pos] != 0
  inc pos

proc writeI64(buf: var seq[byte]; value: int64) =
  buf.writeU64Le(uint64(value))

proc readI64(buf: openArray[byte]; pos: var int): int64 =
  let raw = buf.readU64Le(pos)
  if raw <= uint64(int64.high):
    int64(raw)
  elif raw == 0x8000000000000000'u64:
    int64.low
  else:
    -int64((not raw) + 1'u64)

proc safePathSegment(value, fallback: string): string =
  for ch in value:
    if ch in {'a' .. 'z'} or ch in {'A' .. 'Z'} or ch in {'0' .. '9'} or
        ch in {'-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = fallback

proc currentUid*(): int64 =
  when defined(posix):
    int64(getuid())
  else:
    0'i64

when defined(macosx):
  # macOS exposes a stable per-user temp directory through
  # confstr(_CS_DARWIN_USER_TEMP_DIR). This is the same directory that
  # launchd-spawned services see and is anchored to the user's confined
  # area (e.g. /var/folders/<hash>/T/), regardless of any $TMPDIR override
  # in the calling environment.
  #
  # We deliberately bypass nim's getTempDir() (which honours $TMPDIR) here
  # because nix-shell rewrites $TMPDIR to a session-scoped path such as
  # /tmp/nix-shell.<rand>/. That makes the per-user repro-daemon socket
  # path change on every nix-shell entry, which prevents `repro build`
  # from rediscovering an already-running daemon and causes daemon auto-
  # spawn to time out waiting on a socket the previous daemon (still
  # holding the shared user-daemon lock under
  # ~/Library/Application Support/repro/daemon) does not bind to. See
  # repro-daemon discovery in runtime.nim and M11 (Default Daemon Mode
  # Rollout And Recovery) in
  # reprobuild-specs/Local-Daemons-And-Control-Plane.milestones.org.
  # Values from <unistd.h>:
  #   #define _CS_DARWIN_USER_TEMP_DIR 65537
  #   #define _CS_DARWIN_USER_CACHE_DIR 65538
  # We intentionally use the TEMP_DIR variant (the per-user T directory)
  # rather than CACHE_DIR (C) because the daemon endpoint is ephemeral and
  # matches launchd's view of the user temp confinement.
  const CsDarwinUserTempDir = 65537.cint
  proc confstr(name: cint; buf: cstring; len: csize_t): csize_t {.
    importc, header: "<unistd.h>".}

  proc darwinUserTempDir(): string =
    # confstr returns required buffer size (including NUL) when buf is nil
    # or len is 0. A return of 0 means the value is unavailable.
    let needed = confstr(CsDarwinUserTempDir, nil, csize_t(0))
    if needed <= 0:
      return ""
    var buf = newString(int(needed))
    let written = confstr(CsDarwinUserTempDir, cstring(buf), needed)
    if written <= 0:
      return ""
    # confstr writes a trailing NUL inside the buffer. Strip it.
    buf.setLen(int(written) - 1)
    if buf.len > 0 and buf[buf.high] == '/':
      buf.setLen(buf.high)
    buf

proc userDaemonEndpointLeaf(): string =
  ## The default endpoint's file name inside ``userDaemonRuntimeDir``.
  "repro-daemon-" & $currentUid() & ".sock"

proc boundedTempRuntimeDir(tempRoot: string): string =
  ## ``<tempRoot>/repro-<uid>``, unless the default endpoint inside it could
  ## not be published there -- then ``/tmp/repro-<uid>``.
  ##
  ## ``tempRoot`` is ``getTempDir()``, i.e. ``$TMPDIR``, and nothing bounds
  ## its length: the suite's ``~/.cache/reprobuild-test-tmp/<slot>``, a
  ## ``nix-shell`` session directory or a deep CI workspace can leave an
  ## endpoint ``std/net`` refuses to bind (107 bytes on Linux, 91 on macOS;
  ## ``repro_core/paths.unixSocketPathMaxLen``), or one with no room beside it
  ## for ``bindIpcListener``'s staging name. ``ipcEndpointFits`` checks both.
  ## The fallback is the shape this default already has whenever
  ## ``TMPDIR=/tmp``, so it introduces no new location -- and it is the rule
  ## ``repro_core/paths.runquotaEndpointPath`` applies to its own sockets.
  ## Every process of this user under the same ``TMPDIR`` takes the same
  ## branch, so client and daemon still agree on the endpoint.
  result = tempRoot / ("repro-" & $currentUid())
  when defined(posix):
    if not ipcEndpointFits(result / userDaemonEndpointLeaf()):
      result = "/tmp" / ("repro-" & $currentUid())

proc userDaemonRuntimeDir*(): string =
  ## Where the user daemon's default endpoint lives. ``REPRO_DAEMON_RUNTIME_DIR``
  ## is taken verbatim, as is ``XDG_RUNTIME_DIR``'s ``repro`` subdirectory
  ## (the session manager's short ``/run/user/<uid>``); only the
  ## ``getTempDir()`` fallbacks are bounded (``boundedTempRuntimeDir``). An
  ## over-long explicit choice is reported by ``bindIpcListener``, naming the
  ## limit, rather than silently moved.
  let explicit = getEnv("REPRO_DAEMON_RUNTIME_DIR")
  if explicit.len > 0:
    return explicit
  when defined(windows):
    let local = getEnv("LOCALAPPDATA")
    if local.len > 0: local / "repro" / "daemon" / "runtime"
    else: getEnv("USERPROFILE") / "AppData" / "Local" / "repro" /
      "daemon" / "runtime"
  elif defined(macosx):
    # Prefer the per-user darwin temp dir so the endpoint is stable
    # across nix-shell sessions and matches the path launchd-spawned
    # repro-daemon instances bind to. Fall back to getTempDir() only
    # if confstr is unavailable on this host.
    let darwinTmp = darwinUserTempDir()
    if darwinTmp.len > 0: darwinTmp / ("repro-" & $currentUid())
    else: boundedTempRuntimeDir(getTempDir())
  else:
    let xdg = getEnv("XDG_RUNTIME_DIR")
    if xdg.len > 0: xdg / "repro"
    else: boundedTempRuntimeDir(getTempDir())

proc userDaemonStateDir*(): string =
  let explicit = getEnv("REPRO_DAEMON_STATE_DIR")
  if explicit.len > 0:
    return explicit
  when defined(windows):
    let local = getEnv("LOCALAPPDATA")
    if local.len > 0: local / "repro" / "daemon"
    else: getEnv("USERPROFILE") / "AppData" / "Local" / "repro" / "daemon"
  elif defined(macosx):
    getEnv("HOME") / "Library" / "Application Support" / "repro" / "daemon"
  else:
    let xdg = getEnv("XDG_STATE_HOME")
    let base = if xdg.len > 0: xdg else: getEnv("HOME") / ".local" / "state"
    base / "repro" / "daemon"

proc defaultUserDaemonEndpoint*(): string =
  let explicit = getEnv("REPRO_DAEMON_ENDPOINT")
  if explicit.len > 0:
    return explicit
  when defined(windows):
    "\\\\.\\pipe\\repro-daemon-current-user"
  else:
    userDaemonRuntimeDir() / userDaemonEndpointLeaf()

proc defaultUserDaemonLogPath*(): string =
  userDaemonStateDir() / "logs" / "repro-daemon.log"

proc endpointDigest*(endpoint: string): string =
  ## The part of a per-daemon name that identifies the WHOLE endpoint: 16 hex
  ## characters (64 bits) of blake3 over the endpoint string VERBATIM. The
  ## one digest behind every such name -- the status record
  ## (``endpointInstanceKey``), the systemd unit and the launchd label
  ## (``systemdUnitName``, ``launchdLabel``) -- so they cannot drift apart.
  ## ``systemdUnitName``'s docstring carries the reasoning for the width and
  ## for hashing verbatim.
  blake3.digest(endpoint).toHex()[0 ..< 16]

proc endpointInstanceKey*(endpoint, fallback: string): string =
  ## ``<readable basename>-<endpointDigest>``: the name of per-daemon objects
  ## that live in a namespace shared by several daemons
  ## (``systemdUnitName``, ``statusFileForEndpoint``).
  ##
  ## KEYED ON THE WHOLE ENDPOINT. Endpoints sit in per-run scratch
  ## directories precisely because the basename is not unique, so a name
  ## built from ``extractFilename`` alone is shared by every ``d.sock``. The
  ## basename is kept in front for the human reader. See ``systemdUnitName``
  ## for the measured failure.
  safePathSegment(endpoint.extractFilename, fallback) & "-" &
    endpointDigest(endpoint)

proc statusFileForEndpoint*(stateDir, endpoint: string): string =
  ## The daemon status record for ``endpoint`` under ``stateDir``. The ONE
  ## derivation: the daemon writes, removes and stale-cleans its record
  ## through it. It takes the state directory rather than defaulting to
  ## ``userDaemonStateDir()``, because that default is how a reader once
  ## disagreed with a daemon started with ``--state-dir``.
  stateDir / "status" / (endpointInstanceKey(endpoint, "repro-daemon") &
    ".status")

proc binaryIdentity*(name, path, version: string): BinaryIdentity =
  result = BinaryIdentity(name: name, path: path, version: version)
  if path.len > 0 and fileExists(path):
    try:
      let info = getFileInfo(path)
      result.sizeBytes = int64(info.size)
      result.mtimeUnix = info.lastWriteTime.toUnix
    except CatchableError:
      discard

proc writeBinaryIdentity(buf: var seq[byte]; identity: BinaryIdentity) =
  buf.writeString(identity.name)
  buf.writeString(identity.path)
  buf.writeString(identity.version)
  buf.writeI64(identity.sizeBytes)
  buf.writeI64(identity.mtimeUnix)

proc readBinaryIdentity(buf: openArray[byte]; pos: var int): BinaryIdentity =
  result.name = buf.readString(pos)
  result.path = buf.readString(pos)
  result.version = buf.readString(pos)
  result.sizeBytes = buf.readI64(pos)
  result.mtimeUnix = buf.readI64(pos)

proc writeStringSeq(buf: var seq[byte]; values: openArray[string]) =
  buf.writeU32Le(uint32(values.len))
  for value in values:
    buf.writeString(value)

proc readStringSeq(buf: openArray[byte]; pos: var int): seq[string] =
  let count = buf.readElementCount(pos, 4)
  result = newSeq[string](count)
  for i in 0 ..< count:
    result[i] = buf.readString(pos)

proc writeSession(buf: var seq[byte]; session: UserDaemonSession) =
  buf.writeString(session.sessionId)
  buf.writeString(session.projectRoot)
  buf.writeString(session.mode)
  buf.writeString(session.state)
  buf.writeI64(session.startedAtUnix)
  buf.writeI64(session.endedAtUnix)
  buf.writeI64(int64(session.exitCode))
  buf.writeString(session.message)
  buf.writeStringSeq(session.selectedRoots)
  buf.writeI64(int64(session.debounceMs))
  buf.writeStringSeq(session.watchedPaths)
  buf.writeString(session.tierState)
  buf.writeString(session.lastResult)

proc readSession(buf: openArray[byte]; pos: var int): UserDaemonSession =
  result.sessionId = buf.readString(pos)
  result.projectRoot = buf.readString(pos)
  result.mode = buf.readString(pos)
  result.state = buf.readString(pos)
  result.startedAtUnix = buf.readI64(pos)
  result.endedAtUnix = buf.readI64(pos)
  result.exitCode = int(buf.readI64(pos))
  result.message = buf.readString(pos)
  if pos < buf.len:
    result.selectedRoots = buf.readStringSeq(pos)
    result.debounceMs = int(buf.readI64(pos))
    result.watchedPaths = buf.readStringSeq(pos)
    result.tierState = buf.readString(pos)
    result.lastResult = buf.readString(pos)

proc writeFrame*(conn: IpcConn; kind: UserDaemonMessageKind;
                 body: openArray[byte] = []; timeoutMs = 0) =
  ## ``timeoutMs > 0`` bounds the underlying send (see ``sendByteString``); it
  ## is used for the daemon status handshake so a wedged daemon that accepts the
  ## connection but never reads cannot block the client's send forever. The
  ## default (0) preserves the original unbounded blocking write used by the
  ## long-lived build/watch command streams.
  var frame: seq[byte] = @[]
  for ch in FrameMagic:
    frame.add(byte(ord(ch)))
  frame.writeU16Le(uint16(ord(kind)))
  frame.writeU32Le(uint32(body.len))
  frame.add(body)
  conn.sendByteString(frame.textOf(), timeoutMs)

proc readFrame*(conn: IpcConn; timeoutMs = 0): tuple[kind: UserDaemonMessageKind;
                                      body: seq[byte]] =
  ## ``timeoutMs > 0`` bounds BOTH the header and body reads (see
  ## ``recvBytesExact``); it is used for the daemon status handshake so an
  ## unresponsive daemon triggers fallback instead of an indefinite hang.
  ## The default (0) preserves the original unbounded blocking read used by
  ## the long-lived build/watch command streams.
  let header = conn.recvBytesExact(10, timeoutMs)
  for i in 0 ..< 4:
    if header[i] != byte(ord(FrameMagic[i])):
      raise newException(ValueError, "bad user-daemon frame magic")
  var pos = 4
  let kindRaw = int(header.readU16Le(pos))
  let bodyLen = int(header.readU32Le(pos))
  result.kind = UserDaemonMessageKind(kindRaw)
  result.body = conn.recvBytesExact(bodyLen, timeoutMs)

proc helloBody*(client: BinaryIdentity; featureFlags, commandMode,
                projectRoot: string; protocolMajor = UserDaemonProtocolMajor;
                protocolMinor = UserDaemonProtocolMinor): seq[byte] =
  result.writeU16Le(protocolMajor)
  result.writeU16Le(protocolMinor)
  result.writeBinaryIdentity(client)
  result.writeString(featureFlags)
  result.writeString(commandMode)
  result.writeString(projectRoot)
  result.writeI64(int64(getCurrentProcessId()))

proc parseHello*(body: openArray[byte]): tuple[major: uint16; minor: uint16;
    client: BinaryIdentity; featureFlags: string; commandMode: string;
    projectRoot: string; pid: int64] =
  var pos = 0
  result.major = body.readU16Le(pos)
  result.minor = body.readU16Le(pos)
  result.client = body.readBinaryIdentity(pos)
  result.featureFlags = body.readString(pos)
  result.commandMode = body.readString(pos)
  result.projectRoot = body.readString(pos)
  result.pid = body.readI64(pos)

proc helloAckBody*(daemon: BinaryIdentity; featureFlags, generation: string):
    seq[byte] =
  result.writeU16Le(UserDaemonProtocolMajor)
  result.writeU16Le(UserDaemonProtocolMinor)
  result.writeBinaryIdentity(daemon)
  result.writeString(featureFlags)
  result.writeString(generation)

proc parseHelloAck*(body: openArray[byte]): tuple[major: uint16;
    minor: uint16; daemon: BinaryIdentity; featureFlags: string;
    generation: string] =
  var pos = 0
  result.major = body.readU16Le(pos)
  result.minor = body.readU16Le(pos)
  result.daemon = body.readBinaryIdentity(pos)
  result.featureFlags = body.readString(pos)
  result.generation = body.readString(pos)

proc statusBody*(status: UserDaemonStatus): seq[byte] =
  result.writeBool(status.running)
  result.writeString(status.role)
  result.writeString(status.endpoint)
  result.writeString(status.stateDir)
  result.writeString(status.logPath)
  result.writeI64(status.pid)
  result.writeI64(status.uptimeSeconds)
  result.writeU16Le(status.protocolMajor)
  result.writeU16Le(status.protocolMinor)
  result.writeBinaryIdentity(status.binary)
  result.writeString(status.featureFlags)
  result.writeString(status.generation)
  result.writeU32Le(uint32(status.activeSessionCount))
  result.writeBool(status.devMode)
  result.writeString(status.sourceImagePath)
  result.writeString(status.runningImagePath)
  result.writeString(status.sourceHash)
  result.writeString(status.runningHash)
  result.writeString(status.protocolGeneration)
  result.writeString(status.restartRunId)
  result.writeString(status.stagedGenerationDir)
  result.writeString(status.previousStagedGenerationDir)
  result.writeString(status.reconnectLimitations)

proc parseStatusBody*(body: openArray[byte]): UserDaemonStatus =
  var pos = 0
  result.running = body.readBool(pos)
  result.role = body.readString(pos)
  result.endpoint = body.readString(pos)
  result.stateDir = body.readString(pos)
  result.logPath = body.readString(pos)
  result.pid = body.readI64(pos)
  result.uptimeSeconds = body.readI64(pos)
  result.protocolMajor = body.readU16Le(pos)
  result.protocolMinor = body.readU16Le(pos)
  result.binary = body.readBinaryIdentity(pos)
  result.featureFlags = body.readString(pos)
  result.generation = body.readString(pos)
  result.activeSessionCount = int(body.readU32Le(pos))
  result.devMode = body.readBool(pos)
  if pos < body.len:
    result.sourceImagePath = body.readString(pos)
    result.runningImagePath = body.readString(pos)
    result.sourceHash = body.readString(pos)
    result.runningHash = body.readString(pos)
    result.protocolGeneration = body.readString(pos)
    result.restartRunId = body.readString(pos)
    result.stagedGenerationDir = body.readString(pos)
    result.previousStagedGenerationDir = body.readString(pos)
    result.reconnectLimitations = body.readString(pos)

proc sessionsBody*(sessions: openArray[UserDaemonSession]): seq[byte] =
  result.writeU32Le(uint32(sessions.len))
  for session in sessions:
    result.writeSession(session)

proc parseSessionsBody*(body: openArray[byte]): seq[UserDaemonSession] =
  var pos = 0
  let count = body.readElementCount(pos, 4)
  result = newSeq[UserDaemonSession](count)
  for i in 0 ..< count:
    result[i] = body.readSession(pos)

proc buildRequestBody*(request: UserDaemonBuildRequest): seq[byte] =
  result.writeString(request.runId)
  result.writeString(request.target)
  result.writeString(request.workingDir)
  result.writeString(request.projectRoot)
  result.writeString(request.toolProvisioning)
  result.writeString(request.workRoot)
  result.writeString(request.publicCliPath)
  result.writeStringSeq(request.rawArgs)
  result.writeStringSeq(
    sanitizeUserDaemonRequestEnvironment(request.environment))
  result.writeBool(request.attached)
  result.writeBool(request.cancelOnDisconnect)

proc parseBuildRequestBody*(body: openArray[byte]): UserDaemonBuildRequest =
  var pos = 0
  result.runId = body.readString(pos)
  result.target = body.readString(pos)
  result.workingDir = body.readString(pos)
  result.projectRoot = body.readString(pos)
  result.toolProvisioning = body.readString(pos)
  result.workRoot = body.readString(pos)
  result.publicCliPath = body.readString(pos)
  result.rawArgs = body.readStringSeq(pos)
  result.environment =
    sanitizeUserDaemonRequestEnvironment(body.readStringSeq(pos))
  result.attached = body.readBool(pos)
  result.cancelOnDisconnect = body.readBool(pos)

proc watchRequestBody*(request: UserDaemonWatchRequest): seq[byte] =
  result.writeString(request.runId)
  result.writeString(request.target)
  result.writeString(request.workingDir)
  result.writeString(request.projectRoot)
  result.writeString(request.toolProvisioning)
  result.writeString(request.workRoot)
  result.writeString(request.publicCliPath)
  result.writeStringSeq(request.rawArgs)
  result.writeStringSeq(
    sanitizeUserDaemonRequestEnvironment(request.environment))
  result.writeBool(request.attached)
  result.writeBool(request.detached)
  result.writeBool(request.cancelOnDisconnect)
  result.writeI64(int64(request.debounceMs))
  result.writeI64(int64(request.maxCycles))
  result.writeStringSeq(request.selectedRoots)

proc parseWatchRequestBody*(body: openArray[byte]): UserDaemonWatchRequest =
  var pos = 0
  result.runId = body.readString(pos)
  result.target = body.readString(pos)
  result.workingDir = body.readString(pos)
  result.projectRoot = body.readString(pos)
  result.toolProvisioning = body.readString(pos)
  result.workRoot = body.readString(pos)
  result.publicCliPath = body.readString(pos)
  result.rawArgs = body.readStringSeq(pos)
  result.environment =
    sanitizeUserDaemonRequestEnvironment(body.readStringSeq(pos))
  result.attached = body.readBool(pos)
  result.detached = body.readBool(pos)
  result.cancelOnDisconnect = body.readBool(pos)
  result.debounceMs = int(body.readI64(pos))
  result.maxCycles = int(body.readI64(pos))
  result.selectedRoots = body.readStringSeq(pos)

proc watchSessionRequestBody*(request: UserDaemonWatchSessionRequest): seq[byte] =
  result.writeString(request.sessionId)
  result.writeBool(request.cancelOnDisconnect)

proc parseWatchSessionRequestBody*(body: openArray[byte]):
    UserDaemonWatchSessionRequest =
  var pos = 0
  result.sessionId = body.readString(pos)
  result.cancelOnDisconnect = body.readBool(pos)

proc parseBuildEventKind(value: string): UserDaemonBuildEventKind =
  case value
  of "accepted":
    bekAccepted
  of "diagnostic":
    bekDiagnostic
  of "unsupported":
    bekUnsupported
  of "cancelled":
    bekCancelled
  of "finished":
    bekFinished
  else:
    raise newException(ValueError,
      "unknown user-daemon build event kind: " & value)

proc buildEventBody*(event: UserDaemonBuildEvent): seq[byte] =
  result.writeString(event.schemaId)
  result.writeU16Le(event.schemaVersion)
  result.writeU64Le(event.eventId)
  result.writeI64(event.occurredAtUnixMs)
  result.writeString(event.runId)
  result.writeString(event.sessionId)
  result.writeString(event.projectRoot)
  result.writeString(event.command)
  result.writeString($event.kind)
  result.writeString(event.severity)
  result.writeString(event.message)
  result.writeBool(event.terminal)
  result.writeI64(int64(event.exitCode))
  result.writeString(event.payloadJson)

proc parseBuildEventBody*(body: openArray[byte]): UserDaemonBuildEvent =
  var pos = 0
  result.schemaId = body.readString(pos)
  result.schemaVersion = body.readU16Le(pos)
  result.eventId = body.readU64Le(pos)
  result.occurredAtUnixMs = body.readI64(pos)
  result.runId = body.readString(pos)
  result.sessionId = body.readString(pos)
  result.projectRoot = body.readString(pos)
  result.command = body.readString(pos)
  result.kind = parseBuildEventKind(body.readString(pos))
  result.severity = body.readString(pos)
  result.message = body.readString(pos)
  result.terminal = body.readBool(pos)
  result.exitCode = int(body.readI64(pos))
  result.payloadJson = body.readString(pos)

proc errorBody*(message: string): seq[byte] =
  result.writeString(message)

proc parseErrorBody*(body: openArray[byte]): string =
  var pos = 0
  body.readString(pos)

# ---------------------------------------------------------------------------
# ReproOS-Generations-And-Foreign-Packages A2.5 P6 — substitute messages
# ---------------------------------------------------------------------------
#
# Wire format choice: hand-rolled little-endian binary using the existing
# ``writeString``/``readString``/``writeU32Le``/``writeBool``/``writeI64``
# helpers, matching every other repro-daemon IPC message in this module
# (helloBody, statusBody, buildRequestBody, watchRequestBody, etc.). All
# upstream identity fields the cache client carries (``baseUrl``, hex-
# encoded trusted signer pubkeys) are plain strings on the wire — that
# keeps ``repro_daemon_core`` free of a ``repro_peer_cache`` dependency
# and lets the cache-client wrapper hex-encode 65-byte P-256 pubkeys at
# the serialization boundary.
#
# Backwards-compatibility: the new ``udkSubstituteRequest`` /
# ``udkSubstituteResponse`` enum values are appended at 18/19. Existing
# kinds (1-17 and 255 for ``udkError``) keep their numeric ids, so the
# 2026-05-21 A2 daemon binary and a 2026-06-12 substitute-capable client
# remain framewise compatible: the older daemon would respond with
# ``udkError`` on the unknown kind, exactly the path
# ``handleClient`` takes for unsupported messages today.

type
  DaemonSubstituteIpcEndpoint* = object
    ## Wire shape of a single configured upstream cache endpoint. Mirrors
    ## ``SubstituteEndpoint`` in ``repro_binary_cache_client/types.nim``
    ## but uses ``string`` for the trusted-signer pubkeys (hex-encoded)
    ## so the protocol module stays leaf-level.
    baseUrl*: string
    trustedSignerHex*: seq[string]
      ## Each entry is the hex encoding of the 65-byte P-256 public key
      ## (see ``repro_peer_cache/auth.nim``).
    priority*: int32

  DaemonSubstituteIpcRequest* = object
    rootEntryKeyHex*: seq[string]
      ## Non-empty list of cache-entry-key hex roots. For the v1 single-
      ## root call the client populates this with a one-element seq;
      ## the field is a seq rather than a single string so a future
      ## multi-root closure request fits the same wire shape without a
      ## protocol bump.
    endpoint*: DaemonSubstituteIpcEndpoint
    singleWriterMode*: bool
      ## Forward-compat option. v1 servers always serialise concurrent
      ## substitute calls behind the ``DaemonSubstituteService``'s
      ## process-wide ``Lock``; the flag exists for the future case
      ## where the daemon can dispatch parallel walks against
      ## disjoint roots and the caller wants to opt back into the
      ## serialised mode.

  DaemonSubstituteIpcPlanStep* = object
    entryKeyHex*: string
    sourceEndpointBaseUrl*: string

  DaemonSubstituteIpcOutcome* = object
    entryKeyHex*: string
    ok*: bool
    skipped*: bool
    reason*: string
    casPath*: string
    bytesFetched*: int64
    wallclockMillis*: int64

  DaemonSubstituteIpcResponse* = object
    ok*: bool
    reason*: string
    plan*: seq[DaemonSubstituteIpcPlanStep]
    outcomes*: seq[DaemonSubstituteIpcOutcome]
    realizedCasPaths*: seq[string]
    totalBytesFetched*: int64
    totalWallclockMillis*: int64

proc substituteRequestBody*(request: DaemonSubstituteIpcRequest): seq[byte] =
  result.writeStringSeq(request.rootEntryKeyHex)
  result.writeString(request.endpoint.baseUrl)
  result.writeStringSeq(request.endpoint.trustedSignerHex)
  result.writeI64(int64(request.endpoint.priority))
  result.writeBool(request.singleWriterMode)

proc parseSubstituteRequestBody*(body: openArray[byte]):
    DaemonSubstituteIpcRequest =
  var pos = 0
  result.rootEntryKeyHex = body.readStringSeq(pos)
  result.endpoint.baseUrl = body.readString(pos)
  result.endpoint.trustedSignerHex = body.readStringSeq(pos)
  result.endpoint.priority = int32(body.readI64(pos))
  result.singleWriterMode = body.readBool(pos)

proc writeSubstituteStep(buf: var seq[byte];
                         step: DaemonSubstituteIpcPlanStep) =
  buf.writeString(step.entryKeyHex)
  buf.writeString(step.sourceEndpointBaseUrl)

proc readSubstituteStep(body: openArray[byte]; pos: var int):
    DaemonSubstituteIpcPlanStep =
  result.entryKeyHex = body.readString(pos)
  result.sourceEndpointBaseUrl = body.readString(pos)

proc writeSubstituteOutcome(buf: var seq[byte];
                            outcome: DaemonSubstituteIpcOutcome) =
  buf.writeString(outcome.entryKeyHex)
  buf.writeBool(outcome.ok)
  buf.writeBool(outcome.skipped)
  buf.writeString(outcome.reason)
  buf.writeString(outcome.casPath)
  buf.writeI64(outcome.bytesFetched)
  buf.writeI64(outcome.wallclockMillis)

proc readSubstituteOutcome(body: openArray[byte]; pos: var int):
    DaemonSubstituteIpcOutcome =
  result.entryKeyHex = body.readString(pos)
  result.ok = body.readBool(pos)
  result.skipped = body.readBool(pos)
  result.reason = body.readString(pos)
  result.casPath = body.readString(pos)
  result.bytesFetched = body.readI64(pos)
  result.wallclockMillis = body.readI64(pos)

proc substituteResponseBody*(response: DaemonSubstituteIpcResponse): seq[byte] =
  result.writeBool(response.ok)
  result.writeString(response.reason)
  result.writeU32Le(uint32(response.plan.len))
  for step in response.plan:
    result.writeSubstituteStep(step)
  result.writeU32Le(uint32(response.outcomes.len))
  for outcome in response.outcomes:
    result.writeSubstituteOutcome(outcome)
  result.writeStringSeq(response.realizedCasPaths)
  result.writeI64(response.totalBytesFetched)
  result.writeI64(response.totalWallclockMillis)

proc parseSubstituteResponseBody*(body: openArray[byte]):
    DaemonSubstituteIpcResponse =
  var pos = 0
  result.ok = body.readBool(pos)
  result.reason = body.readString(pos)
  let planCount = body.readElementCount(pos, 4)
  result.plan = newSeqOfCap[DaemonSubstituteIpcPlanStep](planCount)
  for _ in 0 ..< planCount:
    result.plan.add(body.readSubstituteStep(pos))
  let outcomeCount = body.readElementCount(pos, 4)
  result.outcomes = newSeqOfCap[DaemonSubstituteIpcOutcome](outcomeCount)
  for _ in 0 ..< outcomeCount:
    result.outcomes.add(body.readSubstituteOutcome(pos))
  result.realizedCasPaths = body.readStringSeq(pos)
  result.totalBytesFetched = body.readI64(pos)
  result.totalWallclockMillis = body.readI64(pos)

# ---------------------------------------------------------------------------
# Ephemeral-State-Leases L4 (§4.2) — lease renew messages
# ---------------------------------------------------------------------------
#
# Wire format choice: the same hand-rolled little-endian binary the rest of
# this module uses (``writeString`` / ``writeI64`` / ``writeBool``), so the
# protocol module stays a leaf that depends only on ``repro_core`` — it does
# NOT link ``repro_resources``. The daemon-side handler
# (``lease_registry.nim``) translates the wire policy encoded in
# ``ttlSeconds`` into a ``repro_resources`` ``LeasePolicy`` and drives the
# L1/L2 store; the CLI-side client (``repro_resources`` or the reconcile
# seam) encodes its ``LeasePolicy`` back into ``ttlSeconds`` at this boundary.
#
# ``ttlSeconds`` policy encoding (a single int64 keeps the frame tiny and
# forward-compatible; a ``keep`` holder pins the state with no expiry):
#   * ``LeaseRenewKeepSentinel`` (< 0) -> ``keep``       (never reap)
#   * ``0``                             -> ``immediate``  (now-deadline)
#   * ``> 0``                           -> ``delayed(ttl = ttlSeconds)``

const
  LeaseRenewKeepSentinel* = -1'i64
    ## ``ttlSeconds`` value meaning ``keep`` (never auto-reap): the holder
    ## pins the state with no deadline. Any negative value is treated as
    ## ``keep`` on decode so a future renegotiation cannot mis-reap.
  MaxLeaseReapProviders* = 4096
    ## Upper bound on the entries one ``udkLeaseReapProviders`` frame may
    ## carry. The count is read off the wire BEFORE any entry is decoded, so
    ## without a bound a frame claiming four billion providers would have the
    ## daemon allocate from a number a client chose. One entry per resource
    ## TYPE, and a recipe composes tens, so 4096 is far above any real producer
    ## and still refuses a hostile or corrupt frame outright.

type
  DaemonLeaseScope* = enum
    ## Which daemon / state-store root owns this lease (§4.1). ``dlsUser``
    ## routes to the per-user daemon + ``$HOME/.cache/repro/state``;
    ## ``dlsSystem`` routes to the system-scoped state dir served by the
    ## system reaper unit.
    dlsUser = 0
    dlsSystem = 1

  DaemonLeaseRenewRequest* = object
    scope*: DaemonLeaseScope
    address*: string
      ## The leased state's resource address (the store record key).
    consumerId*: string
      ## This consumer's stable holder id (the ``holders`` map key for a
      ## dated policy, the ``keepHolders`` entry for ``keep``).
    ttlSeconds*: int64
      ## The policy, encoded per the scheme above.

  DaemonLeaseRenewResponse* = object
    ok*: bool
      ## True if the renew was applied (a matching record existed and was
      ## updated). False (with ``reason``) if no record was found — a
      ## best-effort renew against a store the daemon does not (yet) hold a
      ## record for; the client must not treat this as fatal.
    reason*: string
    hadRecord*: bool
    effectiveDeadlineUnix*: int64
      ## The resulting effective deadline, or ``LeaseRenewKeepSentinel``
      ## when the folded deadline is ``none`` (never reap).

  DaemonServiceConvergeRequest* = object
    ## Shared-Development-Services L7 (§4.5) `repro up`'s converge
    ## request.
    ##
    ## `keyJson` and `snapshotJson` are OPAQUE STRINGS here on purpose.
    ## This module is a leaf — "``protocol.nim`` stays a leaf (only
    ## ``repro_core``)", as `lease_registry.nim`'s header puts it — and
    ## the instance key and the interface snapshot are `repro_resources`
    ## / `repro_project_dsl` types. Carrying them as the strings
    ## `encodeServiceInstanceKey` / `encodeServiceInterfaceSnapshot`
    ## produce keeps the frame codec independent of the resource lane,
    ## exactly as the `ttlSeconds` encoding does for a lease policy.
    scope*: DaemonLeaseScope
    keyJson*: string
    snapshotJson*: string
    holderId*: string
      ## §4.5's "one holder per consuming project":
      ## `serviceLeaseHolderId(<consuming project root>)`.
    ttlSeconds*: int64
      ## The holder's lease policy, in the SAME encoding
      ## `DaemonLeaseRenewRequest.ttlSeconds` uses (negative = keep,
      ## 0 = immediate, positive = delayed). One encoding for one
      ## concept; a second one would be a second answer to "what does
      ## -1 mean".
    command*: seq[string]
      ## The argv to materialise the instance with, when none is
      ## running. Carried on the converge request rather than fetched
      ## later because the decision and the materialisation happen in
      ## one request.
    workingDir*: string
    replace*: bool
      ## `repro up --replace` (§4.3's explicit takeover).
    force*: bool
      ## `--force`, which has meaning ONLY together with `replace` and
      ## whose §4.5-rule-2 diagnostic differs depending on whether the
      ## holder set was recoverable.
    generationJson*: string
      ## Shared-Development-Services §4.3's SAME-GENERATION PRECONDITION:
      ## the requesting client's established answer to "does the owner's
      ## lifted artifact correspond to the owner's current definition",
      ## as `encodeServiceArtifactGenerationCheck` produces it.
      ##
      ## OPAQUE HERE for the reason `keyJson` and `snapshotJson` are:
      ## this module stays a leaf on `repro_core`.
      ##
      ## IT IS THE CLIENT THAT ESTABLISHES IT, AND THAT IS NOT AN
      ## ACCIDENT OF LAYERING. The question is about the OWNER's recipe
      ## sources and the OWNER's artifact on disk; the daemon has never
      ## seen either -- it holds the RUNNING instance's persisted
      ## snapshot, which is the other side of §4.3's comparison. Asking
      ## the daemon would reduce the check to "the running snapshot
      ## equals the artifact's snapshot", which is exactly the vacuous
      ## comparison §4.3's second half forbids.
      ##
      ## AN EMPTY STRING MEANS UNESTABLISHED, NOT FRESH. That is what a
      ## body written before this field decodes to, and
      ## `decodeServiceArtifactGenerationCheck` turns it into
      ## `sagUnknownProvenance` with a `detail` saying so. The opposite
      ## default would make the precondition vanish on a client/daemon
      ## revision skew.

  DaemonServiceConvergeResponse* = object
    ok*: bool
      ## False when the daemon could not carry the decision out — a
      ## materialisation that failed, a takeover whose stop failed. It is
      ## NOT false for a refusal: a refusal is a decision the daemon made
      ## correctly, and `outcome` says which.
    outcome*: string
      ## `outcomeWord(ServiceConvergeOutcome)`. A word rather than an
      ## ordinal so a client built against a different revision reports
      ## an unknown NAME instead of silently reading some other outcome.
    diagnostic*: string
    address*: string
    pid*: int32
      ## The instance's process, after the decision. 0 when nothing is
      ## running (a refusal).
    hadInstance*: bool
    holderSetRecoverable*: bool
      ## False when §4.5's lossy rebuild applies: the holder set may be
      ## incomplete. Sent as its own field rather than inferred from
      ## `holders.len`, because "no holders" and "no holders I can name"
      ## are the two states §4.5 insists must not be conflated.
    holders*: seq[string]
    contributionPoints*: seq[string]
      ## Shared-Development-Services D-SS11 (§4.6): the CONTRIBUTION
      ## POINTS the instance this decision resolved to DECLARES, bare
      ## names, declaration order.
      ##
      ## §4.6 requires a contribution to a point "the running instance
      ## does not declare" to be refused, "including across a version
      ## skew, where the running instance was built from an older
      ## definition that lacks the point". That is a fact about the
      ## RUNNING instance, and on an attach it comes from the registry
      ## entry's own persisted snapshot -- not from the snapshot the
      ## requesting consumer sent, which is by definition the newer
      ## definition when there is skew.
      ##
      ## SENT ON THE RESPONSE RATHER THAN READ FROM THE STORE BY THE
      ## CLIENT, and the reason is measured rather than stylistic: the
      ## daemon's instance records live under its own `--state-root`,
      ## while a client's `serviceInstanceStoreRoot(dlsUser)` with no
      ## override is `$HOME/.cache/repro/state`. A client that read the
      ## record itself would find nothing whenever the daemon was
      ## started with an explicit root, and would then refuse every
      ## contribution for a reason that has nothing to do with the
      ## contribution.
      ##
      ## An EMPTY list is "this instance converges no points", which is
      ## what every pre-D-SS11 instance really did and what a client
      ## built against an older protocol decodes to. It is not "unknown":
      ## a contribution against it is refused by name, which is the
      ## correct answer for an instance that declares none.

  DaemonServiceReleaseRequest* = object
    ## L7 (§4.5) `repro down`'s release request.
    scope*: DaemonLeaseScope
    keyJson*: string
    holderId*: string

  DaemonServiceReleaseResponse* = object
    ok*: bool
    outcome*: string
      ## `outcomeWord(ServiceReleaseOutcome)`.
    diagnostic*: string
    address*: string
    holderSetRecoverable*: bool
    remainingHolders*: seq[string]
    stoppedPid*: int32
      ## The pid that was stopped, when this release was the last
      ## holder's. 0 otherwise.
    stopDetail*: string

proc scopeFromWire(v: uint32): DaemonLeaseScope =
  if v == uint32(ord(dlsSystem)): dlsSystem else: dlsUser

proc leaseRenewRequestBody*(request: DaemonLeaseRenewRequest): seq[byte] =
  result.writeU32Le(uint32(ord(request.scope)))
  result.writeString(request.address)
  result.writeString(request.consumerId)
  result.writeI64(request.ttlSeconds)

proc parseLeaseRenewRequestBody*(body: openArray[byte]):
    DaemonLeaseRenewRequest =
  var pos = 0
  result.scope = scopeFromWire(body.readU32Le(pos))
  result.address = body.readString(pos)
  result.consumerId = body.readString(pos)
  result.ttlSeconds = body.readI64(pos)

proc leaseRenewResponseBody*(response: DaemonLeaseRenewResponse): seq[byte] =
  result.writeBool(response.ok)
  result.writeString(response.reason)
  result.writeBool(response.hadRecord)
  result.writeI64(response.effectiveDeadlineUnix)

proc parseLeaseRenewResponseBody*(body: openArray[byte]):
    DaemonLeaseRenewResponse =
  var pos = 0
  result.ok = body.readBool(pos)
  result.reason = body.readString(pos)
  result.hadRecord = body.readBool(pos)
  result.effectiveDeadlineUnix = body.readI64(pos)

proc serviceConvergeRequestBody*(request: DaemonServiceConvergeRequest):
    seq[byte] =
  result.writeU32Le(uint32(ord(request.scope)))
  result.writeString(request.keyJson)
  result.writeString(request.snapshotJson)
  result.writeString(request.holderId)
  result.writeI64(request.ttlSeconds)
  result.writeStringSeq(request.command)
  result.writeString(request.workingDir)
  result.writeBool(request.replace)
  result.writeBool(request.force)
  # §4.3's precondition: appended at the END, so every field above keeps
  # its offset.
  result.writeString(request.generationJson)

proc parseServiceConvergeRequestBody*(body: openArray[byte]):
    DaemonServiceConvergeRequest =
  var pos = 0
  result.scope = scopeFromWire(body.readU32Le(pos))
  result.keyJson = body.readString(pos)
  result.snapshotJson = body.readString(pos)
  result.holderId = body.readString(pos)
  result.ttlSeconds = body.readI64(pos)
  result.command = body.readStringSeq(pos)
  result.workingDir = body.readString(pos)
  result.replace = body.readBool(pos)
  result.force = body.readBool(pos)
  if pos < body.len:
    result.generationJson = body.readString(pos)
  # A body written before §4.3's precondition ends here, and
  # `generationJson` stays "". It is read as UNESTABLISHED, which
  # refuses -- never as fresh. See the field's own comment, and
  # `decodeServiceArtifactGenerationCheck`, which is where the "" is
  # turned into a refusal with a sentence naming why.

proc serviceConvergeResponseBody*(response: DaemonServiceConvergeResponse):
    seq[byte] =
  result.writeBool(response.ok)
  result.writeString(response.outcome)
  result.writeString(response.diagnostic)
  result.writeString(response.address)
  result.writeI64(int64(response.pid))
  result.writeBool(response.hadInstance)
  result.writeBool(response.holderSetRecoverable)
  result.writeStringSeq(response.holders)
  # D-SS11: appended at the END, so every field above keeps its offset.
  result.writeStringSeq(response.contributionPoints)

proc parseServiceConvergeResponseBody*(body: openArray[byte]):
    DaemonServiceConvergeResponse =
  var pos = 0
  result.ok = body.readBool(pos)
  result.outcome = body.readString(pos)
  result.diagnostic = body.readString(pos)
  result.address = body.readString(pos)
  result.pid = int32(body.readI64(pos))
  result.hadInstance = body.readBool(pos)
  result.holderSetRecoverable = body.readBool(pos)
  result.holders = body.readStringSeq(pos)
  if pos < body.len:
    # A body written before D-SS11 ends here. Read as an EMPTY point
    # list rather than refused, for the reason the field's own comment
    # gives: an instance that converges no points is a real state, and
    # refusing the whole response over a trailing field would make a
    # newer client unable to talk to an older daemon at all.
    result.contributionPoints = body.readStringSeq(pos)

proc serviceReleaseRequestBody*(request: DaemonServiceReleaseRequest):
    seq[byte] =
  result.writeU32Le(uint32(ord(request.scope)))
  result.writeString(request.keyJson)
  result.writeString(request.holderId)

proc parseServiceReleaseRequestBody*(body: openArray[byte]):
    DaemonServiceReleaseRequest =
  var pos = 0
  result.scope = scopeFromWire(body.readU32Le(pos))
  result.keyJson = body.readString(pos)
  result.holderId = body.readString(pos)

proc serviceReleaseResponseBody*(response: DaemonServiceReleaseResponse):
    seq[byte] =
  result.writeBool(response.ok)
  result.writeString(response.outcome)
  result.writeString(response.diagnostic)
  result.writeString(response.address)
  result.writeBool(response.holderSetRecoverable)
  result.writeStringSeq(response.remainingHolders)
  result.writeI64(int64(response.stoppedPid))
  result.writeString(response.stopDetail)

proc parseServiceReleaseResponseBody*(body: openArray[byte]):
    DaemonServiceReleaseResponse =
  var pos = 0
  result.ok = body.readBool(pos)
  result.outcome = body.readString(pos)
  result.diagnostic = body.readString(pos)
  result.address = body.readString(pos)
  result.holderSetRecoverable = body.readBool(pos)
  result.remainingHolders = body.readStringSeq(pos)
  result.stoppedPid = int32(body.readI64(pos))
  result.stopDetail = body.readString(pos)

# ---------------------------------------------------------------------------
# §4.2 destroy transport: the reap-provider registration frame.
#
# Same hand-rolled LE vocabulary as the renew frame above, for the same reason:
# this module stays a leaf over ``repro_core`` and never links the resource
# lane. The daemon-side handler translates these four strings into the
# ``LeaseReapProviderArtifact`` its registry holds; the CLI side fills them from
# the provider-artifact refs the resource-graph metadata already carries.
# ---------------------------------------------------------------------------

type
  DaemonLeaseReapProvider* = object
    ## How to launch the provider that owns one resource ``typeId`` — the three
    ## fields a session launch needs, plus the type they serve.
    typeId*: string
    binaryPath*: string
    providerArtifactId*: string
    workingDir*: string

  DaemonLeaseReapProvidersRequest* = object
    scope*: DaemonLeaseScope
      ## Which registry the client means (§4.1). Carried for symmetry with the
      ## renew frame and for the daemon's log line: a daemon serves exactly one
      ## scope, chosen by how it was started, so it registers into its own
      ## registry regardless — the client routes by ENDPOINT, as it does for a
      ## renew.
    providers*: seq[DaemonLeaseReapProvider]

  DaemonLeaseReapProvidersResponse* = object
    ok*: bool
      ## False (with ``reason``) if the daemon refused the registration —
      ## today, an entry with no ``typeId`` or no ``binaryPath``, which could
      ## not name or launch anything.
    reason*: string
    registered*: int
      ## How many entries were registered. A client logs or asserts on it; it
      ## is also what distinguishes an accepted empty frame from a real
      ## registration.

proc leaseReapProvidersRequestBody*(
    request: DaemonLeaseReapProvidersRequest): seq[byte] =
  result.writeU32Le(uint32(ord(request.scope)))
  result.writeU32Le(uint32(request.providers.len))
  for p in request.providers:
    result.writeString(p.typeId)
    result.writeString(p.binaryPath)
    result.writeString(p.providerArtifactId)
    result.writeString(p.workingDir)

proc parseLeaseReapProvidersRequestBody*(body: openArray[byte]):
    DaemonLeaseReapProvidersRequest =
  var pos = 0
  result.scope = scopeFromWire(body.readU32Le(pos))
  let count = int(body.readU32Le(pos))
  # Refuse on the COUNT, before allocating anything from it. `readString`
  # would fail on a truncated body anyway, but only after the seq had been
  # grown to whatever the frame claimed. (No `count < 0` arm: a `uint32`
  # widened into a 64-bit `int` cannot be negative, and a guard that cannot
  # fire reads as though it could.)
  if count > MaxLeaseReapProviders:
    raise newException(ValueError,
      "lease-reap-provider frame claims " & $count & " entries (max " &
      $MaxLeaseReapProviders & ")")
  result.providers = newSeqOfCap[DaemonLeaseReapProvider](count)
  for _ in 0 ..< count:
    var p: DaemonLeaseReapProvider
    p.typeId = body.readString(pos)
    p.binaryPath = body.readString(pos)
    p.providerArtifactId = body.readString(pos)
    p.workingDir = body.readString(pos)
    result.providers.add(p)

proc leaseReapProvidersResponseBody*(
    response: DaemonLeaseReapProvidersResponse): seq[byte] =
  result.writeBool(response.ok)
  result.writeString(response.reason)
  result.writeU32Le(uint32(response.registered))

proc parseLeaseReapProvidersResponseBody*(body: openArray[byte]):
    DaemonLeaseReapProvidersResponse =
  var pos = 0
  result.ok = body.readBool(pos)
  result.reason = body.readString(pos)
  result.registered = int(body.readU32Le(pos))

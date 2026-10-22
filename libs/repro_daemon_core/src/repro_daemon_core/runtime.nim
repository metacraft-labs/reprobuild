import std/[algorithm, net, options, os, osproc, sets, strtabs, strutils,
  tables, times]

import repro_core
from repro_core/source_root import declareRunningImageSource
import blake3

import ./client
import ./daemon_log
import ./writer_identity
import ./protocol
import ./stats_store
import ./lease_registry
import ./instance_registry
when defined(windows):
  import ./windows_detached_spawn

const ReproTestRunnerOwnerTokenEnv =
  "REPRO_TEST_RUNNER_OWNER_TOKEN"
  ## Private process-ownership marker installed by ``repro_test_runner``.
  ## It is carried only across daemon process launch/restart boundaries.

const
  ServerRequestReadTimeoutMs* = UserDaemonHandshakeTimeoutMs
    ## Upper bound on how long the ACCEPT LOOP will wait for a freshly
    ## accepted client to deliver its ``udkHello`` and then its first command
    ## frame. The loop is single-threaded — it accepts one connection, serves
    ## it, and only then returns to ``accept`` — so an unbounded read here
    ## lets ONE client starve every other. Measured: a client that connects
    ## and then simply stays silent (never sends, never closes) makes every
    ## concurrent ``repro daemon status`` report ``not-running`` for as long
    ## as it holds the socket, because each of those clients burns its own
    ## 10 s handshake budget waiting for a hello-ack the loop is not there to
    ## send.
    ##
    ## The bound is deliberately the SAME constant the client uses for its
    ## side of the handshake (``UserDaemonHandshakeTimeoutMs``): a client that
    ## has not managed to put its hello on the wire within that window has
    ## already given up waiting for our ack, so nothing is lost by dropping
    ## it, and no healthy client can be affected — every caller in
    ## ``client.nim`` writes its command frame immediately after
    ## ``connectUserDaemon`` returns, with no user interaction in between.
    ## It applies ONLY to the two request-side reads below; the long-lived
    ## build/watch event streams keep their unbounded reads.

  ServerErrorWriteTimeoutMs* = 5_000
    ## Upper bound on the accept loop's best-effort "here is why your request
    ## failed" write. The peer of that write is by definition in an unhappy
    ## state — frequently it has already gone away (a readiness probe that
    ## connects and closes) — and the loop must return to ``accept``
    ## regardless. A dead peer now raises immediately from ``sendByteString``;
    ## this bound covers the remaining case of a peer that is alive but not
    ## reading. 5 s is an order of magnitude more than any observed local
    ## socket write and still far below the 60 s readiness budget the
    ## integration suites allow for a daemon to come up.

when defined(posix):
  import std/posix except Time

  const
    LockExclusive = 2.cint
    LockNonBlocking = 4.cint

  proc cFlock(fd: cint; operation: cint): cint
    {.importc: "flock", header: "<sys/file.h>".}

when defined(windows):
  import std/winlean

  const
    LOCKFILE_EXCLUSIVE_LOCK = 0x00000002'i32
    LOCKFILE_FAIL_IMMEDIATELY = 0x00000001'i32
    ERROR_LOCK_VIOLATION = 33'i32

  proc lockFileExRaw(hFile: Handle; dwFlags: DWORD; dwReserved: DWORD;
                     nNumberOfBytesToLockLow, nNumberOfBytesToLockHigh: DWORD;
                     lpOverlapped: ptr OVERLAPPED): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "LockFileEx", sideEffect.}
  proc unlockFileExRaw(hFile: Handle; dwReserved: DWORD;
                       nNumberOfBytesToUnlockLow,
                       nNumberOfBytesToUnlockHigh: DWORD;
                       lpOverlapped: ptr OVERLAPPED): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "UnlockFileEx", sideEffect.}

type
  UserDaemonRuntimeError* = object of CatchableError

  UserDaemonConfig* = object
    endpoint*: string
    stateDir*: string
    logPath*: string
    foreground*: bool
    devMode*: bool
    daemonExe*: string
    sourceExe*: string
    stagedGenerationDir*: string
    previousStagedGenerationDir*: string
    restartRunId*: string
    systemScope*: bool
      ## Ephemeral-State-Leases L4 (§4.1): when true the daemon serves the
      ## SYSTEM lease scope — its lease reaper tick sweeps the system state
      ## store (``/var/lib/repro/state``) instead of the per-user one. Set by
      ## ``repro daemon serve --system`` (the system reaper unit).
    leaseStoreRoot*: string
      ## Explicit lease state-store root override (``--state-root``). Empty
      ## => derived from ``systemScope`` via ``leaseStoreRootForScope``. A
      ## hermetic test points this at a throwaway dir under ``$HOME``.
    trustProfile*: string
      ## Distributed-Execution M7: ``--trust-profile=trusted|hardened`` —
      ## the peer-cache node's and worker role's trust profile. Empty =
      ## whatever the spec says (``profile=``), and ``trusted`` when it says
      ## nothing. Validated where the spec is parsed.
    peerCacheSpec*: string
      ## Distributed-Execution M0: ``--peer-cache=<spec>`` — when non-empty
      ## the daemon hosts the long-lived LAN peer-cache service (server,
      ## client and membership loop) through the registered
      ## ``UserDaemonBackgroundService``, so artifacts a build published stay
      ## servable to peers after the CLI that ran the build exits. The spec
      ## is opaque here; the service that consumes it lives in
      ## ``repro_cli_support``.
    processOwnerToken: string
      ## Internal launch-only copy of ``ReproTestRunnerOwnerTokenEnv``. Never
      ## serialize or log this field, or include it in action environments.

  UserDaemonBuildEmit* = proc(kind: UserDaemonBuildEventKind;
                              message: string;
                              terminal: bool;
                              exitCode: int;
                              severity: string;
                              payloadJson: string)
  UserDaemonBuildCancelCheck* = proc(): bool
  UserDaemonBuildExecutor* = proc(request: UserDaemonBuildRequest;
                                  emit: UserDaemonBuildEmit;
                                  cancelCheck: UserDaemonBuildCancelCheck):
                                  int
  UserDaemonProjectRootResolver* = proc(request: UserDaemonBuildRequest):
      string
    ## The project a build request is FOR, when the request does not say.
    ##
    ## The engine's own client fills ``projectRoot`` from the target it parsed.
    ## The thin client (``apps/repro-client``) cannot — it forwards the raw
    ## argument vector and links none of the target-resolution code — so its
    ## requests arrive with ``projectRoot`` empty, and the session record used
    ## to fall back to the client's working directory. ``repro build
    ## <project>`` run from anywhere else then listed the wrong project in
    ## ``repro daemon sessions``. The resolver derives it from the request
    ## alone (``rawArgs`` resolved against ``workingDir``); an empty answer
    ## keeps the working-directory fallback.
  UserDaemonParentPrewarmer* = proc(request: UserDaemonBuildRequest): string
    ## Dependency-Attribution MAC-2 — warm the DAEMON PARENT's in-memory build
    ## caches for an incoming request, so the worker about to be forked
    ## inherits them copy-on-write.
    ##
    ## THE CONTRACT, which is narrower than the hook it replaces and is the
    ## whole reason the hook is callable again:
    ##
    ##   1. READ-ONLY. It may decode files a previous build wrote. It may NOT
    ##      run the build engine, compile or invoke a provider, spawn a
    ##      process, or open the content store or the action cache. Those hold
    ##      descriptors and advisory locks, which do not survive a fork
    ##      safely: an inherited descriptor shares its file offset with every
    ##      sibling, and an inherited lock can be released by any child.
    ##   2. NO PROCESS-GLOBAL MUTATION. No `setCurrentDir`, no `putEnv`. The
    ##      parent is shared; the disabled predecessor's restore-after
    ##      cwd/environment mutation was safe only because it was supposed to
    ##      run in a forked worker.
    ##   3. DECISION-NEUTRAL. Anything it warms must be re-validated by its
    ##      consumer before use, so a prewarmed daemon and a cold one reach
    ##      the same cache decisions with the same reasons.
    ##   4. BOUNDED AND NON-RAISING. It runs on the dispatch path; it returns
    ##      a log line (or "") and must not throw.
  UserDaemonWatchEmit* = proc(kind: UserDaemonBuildEventKind;
                              message: string;
                              terminal: bool;
                              exitCode: int;
                              severity: string;
                              payloadJson: string;
                              watchedPaths: seq[string];
                              lastResult: string)
  UserDaemonWatchCancelCheck* = proc(): bool
  UserDaemonWatchExecutor* = proc(request: UserDaemonWatchRequest;
                                  emit: UserDaemonWatchEmit;
                                  cancelCheck: UserDaemonWatchCancelCheck):
                                  int

  UserDaemonSubstituteExecutor* = proc(request: DaemonSubstituteIpcRequest):
                                        DaemonSubstituteIpcResponse
    ## ReproOS-Generations-And-Foreign-Packages A2.5 P6 — substitute
    ## handler. The daemon entrypoint registers a closure that owns a
    ## long-lived ``DaemonSubstituteService`` and dispatches the IPC
    ## request through it. The runtime stays cache-client-agnostic.

  UserDaemonLock = object
    held: bool
    lockPath: string
    token: string
    when defined(posix):
      fd: cint
    when defined(windows):
      handle: Handle

  DevRestartState* = object
    ## Exported, with `deferralLogDue`, for
    ## `t_daemon_deferral_log_is_bounded.nim`: the invariant under test is
    ## about how the window state evolves across polls, and the clock is a
    ## parameter so the test needs no daemon and no filesystem.
    enabled: bool
    sourceImagePath: string
    runningImagePath: string
    sourceHash: string
    runningHash: string
    protocolGeneration: string
    restartRunId: string
    stagedGenerationDir: string
    previousStagedGenerationDir: string
    candidateHash: string
    candidateSinceMs: int64
    lastCheckMs: int64
    restartPending: bool
    # Stat identity (device, inode, size, mtime-with-nanoseconds) of
    # ``sourceImagePath`` as of the last time its digest was computed. The
    # dev-restart poll re-checks the source image several times a second
    # forever; digesting a ~28 MB image on every one of those passes burned
    # a third of a core and ~74 MB/s of page-cache reads on a daemon with
    # NO work to do. The content of a file cannot change without its stat
    # identity changing, so this is the cheap gate in front of the digest.
    sourceStamp: string
    # Backoff for the OTHER per-pass disk scan in ``restartCandidateReady``:
    # the active-session census that decides whether a ready restart may
    # proceed. Re-asked on the stability cadence rather than the poll
    # cadence, and its LOGGING is bounded by a time window rather than by
    # "did the answer change" -- see `deferralLogDue`.
    deferredUntilMs: int64
    deferredLogAtMs*: int64
      ## When the last deferral line was emitted. Zero means "not currently
      ## deferring", which is what makes entry into deferral loggable.
    deferralPollsSuppressed*: int

type
  UserDaemonBackgroundService* = object
    ## Distributed-Execution M0: a long-lived service hosted by the daemon's
    ## event loop — today the LAN peer cache. The daemon core knows nothing
    ## about what the service does; it only gives it CPU between IPC accepts:
    ##
    ##   * ``start`` runs once after the daemon has bound its endpoint and
    ##     returns a line for the daemon log ("" when the service decided not
    ##     to run, e.g. no spec configured);
    ##   * ``tick`` runs every loop iteration and may block for at most
    ##     ``maxWaitMs`` servicing its own sockets and timers;
    ##   * ``stop`` runs once on shutdown (and before a dev self-restart, so a
    ##     fixed listen port is free for the successor).
    ##
    ## While the service is active the IPC accept wait is capped at
    ## ``pollIntervalMs`` so neither side starves the other. On POSIX a
    ## build request is executed in a forked worker, so a long build never
    ## blocks the service; the worker must not touch the service's sockets
    ## (the service's own fork-safety is its business).
    start*: proc(config: UserDaemonConfig): string {.closure.}
    tick*: proc(maxWaitMs: int) {.closure.}
    stop*: proc() {.closure.}
    active*: proc(): bool {.closure.}
    pollIntervalMs*: int

const UserDaemonLockFileName = ".repro-daemon.lock"

var userDaemonBackgroundService: UserDaemonBackgroundService

proc setUserDaemonBackgroundService*(service: UserDaemonBackgroundService) =
  ## Registers the daemon-hosted background service (see the type).
  userDaemonBackgroundService = service

proc backgroundServiceActive(): bool =
  userDaemonBackgroundService.active != nil and
    userDaemonBackgroundService.active()

var userDaemonBuildExecutor: UserDaemonBuildExecutor
var userDaemonParentPrewarmer: UserDaemonParentPrewarmer
var userDaemonProjectRootResolver: UserDaemonProjectRootResolver
var userDaemonWatchExecutor: UserDaemonWatchExecutor
var userDaemonSubstituteExecutor: UserDaemonSubstituteExecutor

proc setUserDaemonBuildExecutor*(executor: UserDaemonBuildExecutor) =
  userDaemonBuildExecutor = executor

proc setUserDaemonParentPrewarmer*(prewarmer: UserDaemonParentPrewarmer) =
  userDaemonParentPrewarmer = prewarmer

proc setUserDaemonProjectRootResolver*(
    resolver: UserDaemonProjectRootResolver) =
  userDaemonProjectRootResolver = resolver

type
  BuildRequestProjectRootSource* = enum
    ## Where a build session's recorded project root came from. Logged with
    ## every accepted build request, so it is visible which client composed
    ## the request: the full image fills ``projectRoot`` from its own parse
    ## (``request``); the thin client leaves it empty and the daemon derives it
    ## from the raw arguments (``derived``); ``workingDir`` is the last resort.
    prsRequest = "request"
    prsDerived = "derived"
    prsWorkingDir = "workingDir"

proc resolveBuildRequestProjectRoot*(request: UserDaemonBuildRequest):
    tuple[root: string; source: BuildRequestProjectRootSource] =
  ## The project root a build session is recorded under: the request's own
  ## ``projectRoot`` when it carries one, else what the registered resolver
  ## derives from its arguments, else the client's working directory. A
  ## resolver that raises is treated as having no answer — this names a
  ## session, it must never refuse a build.
  if request.projectRoot.len > 0:
    return (request.projectRoot, prsRequest)
  if userDaemonProjectRootResolver != nil:
    var derived = ""
    try:
      derived = userDaemonProjectRootResolver(request)
    except CatchableError:
      derived = ""
    if derived.len > 0:
      return (derived, prsDerived)
  (request.workingDir, prsWorkingDir)

proc buildRequestProjectRoot*(request: UserDaemonBuildRequest): string =
  resolveBuildRequestProjectRoot(request).root

var userDaemonWorkerNote: string

proc setUserDaemonWorkerNote*(note: string) =
  ## A line the build executor wants written to the DAEMON LOG once its
  ## request finishes.
  ##
  ## This exists for one reason: MAC-2 needs a witness that a worker consumed
  ## state it INHERITED from the parent, and that witness must not reach any
  ## output stream. Byte-identical stdout is the correctness contract between a
  ## prewarmed daemon and a cold one, so a marker printed there would be a
  ## marker that breaks the thing it is meant to confirm. The daemon log is
  ## outside that contract.
  userDaemonWorkerNote = note

proc takeUserDaemonWorkerNote*(): string =
  result = userDaemonWorkerNote
  userDaemonWorkerNote = ""

proc runUserDaemonParentPrewarm*(request: UserDaemonBuildRequest): string =
  ## Invoke the registered parent prewarmer, swallowing anything it raises.
  ##
  ## The swallow is the point, not laziness: this runs on the dispatch path of
  ## a real build, and a prewarm is an optimisation. The failure mode of "warm
  ## nothing" is exactly the behaviour of a daemon with no prewarmer at all,
  ## which is what shipped before this milestone.
  if userDaemonParentPrewarmer == nil:
    return ""
  try:
    userDaemonParentPrewarmer(request)
  except CatchableError:
    ""

proc setUserDaemonWatchExecutor*(executor: UserDaemonWatchExecutor) =
  userDaemonWatchExecutor = executor

proc setUserDaemonSubstituteExecutor*(executor: UserDaemonSubstituteExecutor) =
  ## Wire the A2.5 P6 ``DaemonSubstituteService`` into the daemon's IPC
  ## dispatch. The daemon entrypoint calls this once at startup with a
  ## closure that captures the long-lived service singleton.
  userDaemonSubstituteExecutor = executor

proc dispatchRegisteredSubstitute*(request: DaemonSubstituteIpcRequest):
                                    DaemonSubstituteIpcResponse {.gcsafe.} =
  ## Invoke the currently-registered substitute executor and return its
  ## ``DaemonSubstituteIpcResponse``. Public so embedded-daemon test
  ## shells can drive the dispatch path WITHOUT reaching past
  ## ``setUserDaemonSubstituteExecutor`` — keeping the GC-safety story
  ## identical to production, where the daemon thread invokes the
  ## closure registered by the entrypoint.
  ##
  ## ``{.gcsafe.}``: the read of ``userDaemonSubstituteExecutor`` races
  ## with at most one ``setUserDaemonSubstituteExecutor`` call. Production
  ## (and the embedded-daemon test shell) register the executor BEFORE
  ## the listener thread accepts a client, so the read is observation-
  ## only. The closure body itself owns whatever heap state it captures.
  {.cast(gcsafe).}:
    if userDaemonSubstituteExecutor == nil:
      raise newException(UserDaemonRuntimeError,
        "no substitute executor registered; call " &
        "setUserDaemonSubstituteExecutor first")
    userDaemonSubstituteExecutor(request)

proc safePathSegment(value, fallback: string): string =
  for ch in value:
    if ch in {'a' .. 'z'} or ch in {'A' .. 'Z'} or ch in {'0' .. '9'} or
        ch in {'-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = fallback

proc xmlEscape(value: string): string =
  for ch in value:
    case ch
    of '&':
      result.add("&amp;")
    of '<':
      result.add("&lt;")
    of '>':
      result.add("&gt;")
    of '"':
      result.add("&quot;")
    of '\'':
      result.add("&apos;")
    else:
      result.add(ch)

proc fileDigestHex(path: string): string =
  if path.len == 0 or not fileExists(path):
    return ""
  let hasher = initHasher()
  defer: hasher.close()
  var file = open(path, fmRead)
  defer: file.close()
  var buffer = newString(64 * 1024)
  while true:
    let readCount = file.readBuffer(addr buffer[0], buffer.len)
    if readCount <= 0:
      break
    hasher.update(buffer[0].addr, readCount)
  "blake3-256:" & hasher.finalize().toHex()

proc fileIdentityStamp(path: string): string =
  ## Cheap "could this file's content have changed?" probe: one ``stat``.
  ##
  ## Returns "" when the identity cannot be established (missing file, stat
  ## error); callers MUST treat "" as "unknown, assume changed" so a probe
  ## failure can never suppress a real dev-restart. A non-empty stamp is
  ## stable exactly as long as the bytes are: it folds in the device and
  ## inode (so an atomic rename-over is a new identity even at the same
  ## size and timestamp), the size, and the modification time at the full
  ## nanosecond resolution ``stat`` reports on this platform.
  if path.len == 0:
    return ""
  try:
    let info = getFileInfo(path, followSymlink = true)
    let written = info.lastWriteTime
    result = $info.id.device & ":" & $info.id.file & ":" & $info.size & ":" &
      $written.toUnix & "." & $written.nanosecond
  except OSError, IOError:
    result = ""

proc nowUnixMs(): int64 =
  let current = getTime()
  current.toUnix * 1000 + int64(current.nanosecond div 1_000_000)

proc newRestartRunId(prefix = "dev-restart"): string =
  let current = getTime()
  prefix & "-" & $getCurrentProcessId() & "-" & $current.toUnix & "-" &
    $current.nanosecond

proc defaultUserDaemonConfig*(daemonExe = ""; foreground = false;
                              devMode = false): UserDaemonConfig =
  UserDaemonConfig(endpoint: defaultUserDaemonEndpoint(),
    stateDir: userDaemonStateDir(),
    logPath: defaultUserDaemonLogPath(),
    foreground: foreground,
    devMode: devMode,
    daemonExe: daemonExe)

proc absoluteNormalized(path: string): string =
  if path.len == 0:
    return ""
  if path.isAbsolute:
    os.normalizedPath(path)
  else:
    os.normalizedPath(getCurrentDir() / path)

proc anchoredToCurrentDir(path: string): string =
  ## ``path`` made absolute against THIS process's working directory. An
  ## absolute path, and "", are returned byte-for-byte: the endpoint string is
  ## also an identity (the systemd unit name and launchd label are derived
  ## from it), so only a path that would otherwise change meaning is touched.
  if path.len == 0 or path.isAbsolute: path
  else: os.normalizedPath(getCurrentDir() / path)

proc withAnchoredDaemonPaths(config: UserDaemonConfig): UserDaemonConfig =
  ## ``config`` with every path the daemon process will read made absolute
  ## here, against the caller's working directory.
  ##
  ## Required because the daemon does NOT start in the caller's working
  ## directory (``daemonWorkingDirectory``): a relative ``--state-dir`` or
  ## ``--log`` handed to it would be resolved against its state directory
  ## instead, and a relative staged image path would not even execute. Also
  ## applied by the daemon to its own flags, so that a daemon started by hand
  ## with relative flags passes absolute ones to its dev self-restart.
  result = config
  if endpointKindOf(config.endpoint) == ekUnixSocket:
    result.endpoint = anchoredToCurrentDir(config.endpoint)
  result.stateDir = anchoredToCurrentDir(config.stateDir)
  result.logPath = anchoredToCurrentDir(config.logPath)
  result.daemonExe = anchoredToCurrentDir(config.daemonExe)
  result.sourceExe = anchoredToCurrentDir(config.sourceExe)
  result.stagedGenerationDir = anchoredToCurrentDir(config.stagedGenerationDir)
  result.previousStagedGenerationDir =
    anchoredToCurrentDir(config.previousStagedGenerationDir)
  result.leaseStoreRoot = anchoredToCurrentDir(config.leaseStoreRoot)

proc daemonWorkingDirectory(config: UserDaemonConfig): string =
  ## The directory a daemon that ``repro`` starts on a caller's behalf runs
  ## in: its STATE DIRECTORY, never the caller's working directory.
  ##
  ## WHY NOT THE CALLER'S. The daemon outlives the ``repro`` that started it,
  ## so it must keep nothing of that invocation. On Windows a process's
  ## current directory cannot be deleted while the process lives, so a daemon
  ## auto-started by a CMake ``try_compile`` made that ``TryCompile-<id>``
  ## scratch directory undeletable until it exited (reprobuild-specs issue
  ## 2026-10-14). On POSIX the deletion succeeds, but the daemon keeps the
  ## file system busy (no unmount) and serves from a deleted directory.
  ##
  ## WHY THE STATE DIRECTORY, rather than ``/`` or the home directory. It is
  ## the one directory the daemon owns: every launch site creates it before
  ## the daemon starts, it is private to the daemon instance (a test's private
  ## daemon gets a private one), and the daemon already depends on it for its
  ## whole life -- its lock file, session records and dev-mode staged image
  ## live there -- so nobody can remove it under a running daemon without
  ## breaking that daemon anyway. Pinning it as the current directory takes
  ## nothing away from anyone else.
  ##
  ## Nothing in the daemon resolves a path against its own working directory
  ## on the request path: build and watch requests carry ``workingDir`` and
  ## the executors enter it for the request's duration (and come back here
  ## afterwards), and every path in ``daemonProcessArgs`` is absolute
  ## (``withAnchoredDaemonPaths``).
  ##
  ## Used by the two launches that inherit the starter's directory: Windows'
  ## ``spawnWithOwnStdio`` and POSIX's ``launchWithFork``. The systemd and
  ## launchd launches never did; their manager starts the unit in its own
  ## default directory.
  config.stateDir

proc companionFullCliPath(imagePath: string): string =
  ## After the single-`repro` consolidation there is no separate `repro-full`
  ## companion image — `repro` IS the full CLI. Return "" so the image digest
  ## and daemon-staleness checks track only the one binary (`imagePath`), and so
  ## a stale `repro-full` lingering on PATH is never adopted as a companion.
  discard imagePath
  ""

proc imageDigestHex*(imagePath: string): string =
  ## Digest a daemon image. Exported so identity regressions can be tested
  ## without spawning a platform service manager.
  let primary = fileDigestHex(imagePath)
  if primary.len == 0:
    return ""
  let companion = companionFullCliPath(imagePath)
  if companion.len == 0:
    return primary
  let companionDigest = fileDigestHex(companion)
  if companionDigest.len == 0:
    return primary
  let hasher = initHasher()
  defer: hasher.close()
  hasher.update("repro-dev-image-v1\n")
  hasher.update("primary=" & primary & "\n")
  hasher.update("companion=" & companionDigest & "\n")
  "blake3-256:" & hasher.finalize().toHex()

proc stageFullCliCompanion(sourceExe, generationDir: string) =
  ## No-op after the single-`repro` consolidation: there is no `repro-full`
  ## companion image to stage alongside the primary daemon image.
  discard sourceExe
  discard generationDir

proc reconnectLimitationsText(): string =
  "watch sessions can be reattached by run id/session id; completed build " &
    "session diagnostics and stats persist; attached build event streams are " &
    "not replayed after a dev self-restart"

proc daemonLaunchPath*(): string =
  ## ``argv[0]``, when it is an absolute path.
  ##
  ## THIS IS THE CANDIDATE THAT ANSWERS INSIDE AN APPIMAGE, and it is
  ## there because of what N27 turned out to be. See ``daemonImagePath``.
  ## Relative and bare-name ``argv[0]``s are dropped rather than resolved:
  ## resolving one means guessing a working directory or a ``PATH``, and a
  ## guess is what this whole chain exists to stop reporting.
  result =
    try:
      let launched = paramStr(0)
      if launched.len > 0 and isAbsolute(launched): launched else: ""
    except CatchableError, Defect:
      ""

proc daemonImagePath*(appFilename, sourceExe, runningImage: string;
                      launchPath = ""): string =
  ## The path the daemon reports as its OWN image, VERIFIED TO EXIST.
  ##
  ## Distribution-And-Packaging M1's N21: inside an AppImage, ``repro
  ## daemon status`` answered ``binary-path: /usr/bin/repro.real`` -- a
  ## file that does not exist on that host -- while
  ## ``source-image-path:`` and ``running-image-path:`` on the SAME
  ## report carried the true ``/tmp/.mount_<random>/usr/bin/repro.real``.
  ##
  ## WHY ``getAppFilename()`` ANSWERED THAT -- M1's N27, and it is no
  ## longer open. Nim reads ``/proc/self/exe`` on Linux, and for a process
  ## whose image lives on the AppImage's squashfuse mount the kernel
  ## answers the path WITH THE MOUNT POINT STRIPPED: measured at this tip
  ## in ``debian:trixie-slim`` + ``fuse3`` (``--device /dev/fuse
  ## --cap-add SYS_ADMIN``), ``readlink /proc/<daemon-pid>/exe`` is
  ## ``/usr/bin/repro.real`` while that same process's ``argv[0]`` is
  ## ``/tmp/.mount_reprobNdBCIC/usr/bin/repro.real`` and
  ## ``/usr/bin/repro.real`` does not exist on the host at all. So the
  ## AppDir's own layout is what comes back, and ``argv[0]`` -- which
  ## ``AppRun`` execs with the real mount path -- is the candidate that
  ## can answer. Hence ``launchPath``.
  ##
  ## The order is "what the OS says I am, then what I was LAUNCHED as,
  ## then what I was configured as, then what I am running" -- each used
  ## only if it is on disk.
  ##
  ## AND IF NONE OF THEM IS ON DISK, the SAME order runs again without
  ## the disk check, which is M1's N30 and is the branch an AppImage
  ## takes: the mount is gone by the time a live status query reaches the
  ## daemon, so every candidate fails ``fileExists`` and the fallback is
  ## the only thing that runs. It never blanks the field -- a status line
  ## that says nothing when the daemon does have an image would be worse
  ## than one that names a path that has since been unmounted -- but it
  ## no longer prefers the OS's answer, because the OS's answer is the
  ## one candidate known to be able to name a location that never
  ## existed. See the comment on the fallback itself.
  if appFilename.len > 0 and fileExists(appFilename):
    return appFilename
  if launchPath.len > 0 and fileExists(launchPath):
    return absoluteNormalized(launchPath)
  if sourceExe.len > 0 and fileExists(sourceExe):
    return absoluteNormalized(sourceExe)
  if runningImage.len > 0 and fileExists(runningImage):
    return runningImage
  # NOTHING IS ON DISK -- AND THAT IS THE BRANCH AN APPIMAGE ACTUALLY
  # TAKES. M1's N30, measured rather than reasoned about. A live
  # `repro daemon status` is answered by the DAEMON, and by the time it
  # is asked the AppImage run that launched the daemon has exited and
  # its squashfuse mount is GONE: `ls /tmp/.mount_*` answers "No such
  # file or directory", `/proc/<daemon-pid>/mountinfo` has zero entries
  # mentioning it, and EVERY candidate above fails `fileExists` --
  # `/usr/bin/repro.real` (the mount-stripped `/proc/self/exe`), the
  # launch path, the configured source and the running image alike.
  # Returning `appFilename` here is what printed `binary-path:
  # /usr/bin/repro.real` beside a `source-image-path:` that named the
  # true mount. So when nothing can be verified, prefer the path the
  # process was LAUNCHED as: it is a path this image really did occupy,
  # whereas a mount-stripped `/proc/self/exe` names a location that
  # never existed anywhere.
  #
  # ONLY the launch path is promoted, deliberately. `sourceExe` and
  # `runningImage` are configuration and daemon state; when neither is on
  # disk there is no reason to believe either over what the OS says, and
  # on a host whose binary was simply DELETED `appFilename` is the honest
  # answer and stays the answer. `argv[0]` is different in kind: it is
  # what this process was actually invoked as.
  if launchPath.len > 0:
    return absoluteNormalized(launchPath)
  appFilename

proc daemonSelfImagePath*(sourceExe = ""; runningImage = ""): string =
  ## ``daemonImagePath`` fed from THIS process.
  ##
  ## Every place the daemon names its own image goes through here, so
  ## that a raw ``getAppFilename()`` cannot be reintroduced one field at
  ## a time -- which is how M1's N21/N27/N30 kept coming back: N21
  ## guarded ``statusFor``, N27 found ``handleHello``, and the review
  ## after it found three more (``statusFor``'s ``runningImagePath``
  ## fallback, ``runningDevImagePath``'s final fallback and
  ## ``initDevRestartState``'s ``sourceImagePath`` fallback) all feeding
  ## the same report.
  daemonImagePath(getAppFilename(), sourceExe, runningImage,
                  launchPath = daemonLaunchPath())

proc runningDevImagePath(config: UserDaemonConfig): string =
  if config.stagedGenerationDir.len > 0:
    let staged = config.stagedGenerationDir / addFileExt("repro-daemon", ExeExt)
    if fileExists(staged):
      return absoluteNormalized(staged)
  if config.devMode and config.sourceExe.len > 0:
    let source = absoluteNormalized(config.sourceExe)
    if fileExists(source):
      return source
  # N30's sweep: not a raw ``getAppFilename()``. See ``daemonSelfImagePath``.
  absoluteNormalized(daemonSelfImagePath())

proc initDevRestartState(config: UserDaemonConfig): DevRestartState =
  result.enabled = config.devMode
  result.sourceImagePath =
    if config.sourceExe.len > 0: absoluteNormalized(config.sourceExe)
    # N30's sweep. See ``daemonSelfImagePath``.
    else: absoluteNormalized(daemonSelfImagePath())
  result.runningImagePath = runningDevImagePath(config)
  result.sourceHash = imageDigestHex(result.sourceImagePath)
  result.runningHash = imageDigestHex(result.runningImagePath)
  result.protocolGeneration = $UserDaemonProtocolMajor & "." &
    $UserDaemonProtocolMinor
  result.restartRunId =
    if config.restartRunId.len > 0: config.restartRunId
    else: newRestartRunId("dev-start")
  result.stagedGenerationDir = config.stagedGenerationDir
  result.previousStagedGenerationDir = config.previousStagedGenerationDir

proc devBinRoot(config: UserDaemonConfig): string =
  config.stateDir / "dev-bin"

proc stageDevDaemonBinary*(sourceExe: string; config: UserDaemonConfig;
                           restartRunId = ""):
    tuple[imagePath: string; generationDir: string; runId: string;
          sourceHash: string] =
  result.sourceHash = imageDigestHex(sourceExe)
  if result.sourceHash.len == 0:
    raise newException(UserDaemonRuntimeError,
      "cannot stage missing repro-daemon source executable: " & sourceExe)
  result.runId =
    if restartRunId.len > 0: restartRunId else: newRestartRunId()
  let hashSegment = safePathSegment(result.sourceHash.replace(":", "-"),
    "unknown")
  result.generationDir = devBinRoot(config) /
    safePathSegment(result.runId & "-" & hashSegment[0 .. min(23,
      hashSegment.high)], "generation")
  createDir(result.generationDir)
  result.imagePath = result.generationDir / addFileExt("repro-daemon", ExeExt)
  copyFile(sourceExe, result.imagePath)
  stageFullCliCompanion(sourceExe, result.generationDir)
  try:
    setFilePermissions(result.imagePath, {fpUserRead, fpUserWrite,
      fpUserExec, fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  except CatchableError:
    discard

proc logLine(path, message: string)

type
  DevStagedGenerationSweep* = object
    ## What one ``sweepStaleDevStagedGenerations`` pass did. ``removed`` and
    ## ``failed`` are absolute paths of generation directories under
    ## ``<state>/dev-bin``; ``kept`` is this daemon's own generation, or ""
    ## when it runs from its source image and owns none.
    removed*: seq[string]
    failed*: seq[string]
    kept*: string

proc sweepStaleDevStagedGenerations(config: UserDaemonConfig):
    DevStagedGenerationSweep =
  ## Remove every staged image generation under ``<state>/dev-bin`` except
  ## the one THIS daemon is running from. Called only by a daemon that HOLDS
  ## the state directory's lock (``acquireUserDaemonLock``), after it has
  ## established that no other daemon answers on its endpoint.
  ##
  ## WHY A SWEEP AND NOT A HAND-OFF. Every dev-mode start stages a copy of
  ## its image (``stageDevDaemonBinary``) and nothing removed it except a dev
  ## SELF-restart, whose child was told its predecessor's directory
  ## (``previousStagedGenerationDir``). A daemon REPLACED by a client --
  ## ``startUserDaemon``'s staleness restart, ``daemon stop`` followed by a
  ## start, a crash -- hands nothing to its successor, so its copy stayed for
  ## good: reprobuild-pm issue 2026-09-30 found 260 of them, the oldest four
  ## months old, at one engine image (tens of MB) each. The spec allows
  ## exactly this pass (Local-Daemons-And-Control-Plane.md, "Windows
  ## Executable Staging", last paragraph): a development daemon startup "may
  ## scan the staged-generation directory and delete generations that are
  ## not referenced by any live daemon status record or running process".
  ##
  ## WHY THE LOCK MAKES THIS SAFE. ``dev-bin`` is per state directory, and so
  ## is the lock, so the lock holder is the only daemon that can be serving
  ## from any generation here. What else can still be RUNNING from one:
  ##
  ##   * a predecessor that is exiting -- it released the lock (a dev
  ##     self-restart releases it before launching its child) but has not
  ##     yet exited. POSIX unlinks a running image without complaint; Windows
  ##     refuses, which lands in ``failed`` and is retried by the next start.
  ##   * a launch still in flight from a client that staged its generation
  ##     and lost the race to this daemon. Removing its image makes its exec
  ##     (or its lock acquisition, if it got that far) fail, and that client
  ##     then finds THIS daemon on the endpoint it is polling -- the outcome
  ##     it would have had anyway, since only one daemon can hold the lock.
  ##
  ## It subsumes the self-restart hand-off: the predecessor's directory is
  ## under ``dev-bin`` and is not ours, so it is removed with the rest.
  ##
  ## WHAT IS NEVER TOUCHED. Only DIRECTORIES that are DIRECT children of
  ## ``dev-bin`` are removed: a symlink there is not something
  ## ``stageDevDaemonBinary`` creates and would point outside, and a path
  ## that does not normalize to a child of ``dev-bin`` is refused before any
  ## removal. ``removeDir`` unlinks a symlink inside a generation rather than
  ## following it. A non-dev daemon stages nothing and sweeps nothing.
  if not config.devMode:
    return
  # No state directory, no `dev-bin` to sweep. Without this guard an empty one
  # would make `devBinRoot` the RELATIVE "dev-bin", anchored to whatever the
  # working directory happens to be -- a directory this daemon does not own.
  if config.stateDir.len == 0:
    return
  let root = absoluteNormalized(devBinRoot(config))
  if root.len == 0 or not dirExists(root):
    return
  result.kept = absoluteNormalized(config.stagedGenerationDir)
  for kind, entry in walkDir(root):
    if kind != pcDir:
      continue
    let candidate = absoluteNormalized(entry)
    if candidate == result.kept:
      continue
    # Our own generation spelled differently (the state directory reached
    # through a symlink by whoever staged it) is still our own: compared by
    # file identity too, because removing it would delete the image this
    # daemon reports as running.
    if result.kept.len > 0:
      try:
        if sameFile(candidate, result.kept):
          continue
      except OSError:
        discard
    # Containment, checked on the normalized spelling: strictly inside
    # `dev-bin`, one level down. `walkDir` yields exactly that, so this can
    # only fire if it ever stops doing so -- which is when it matters.
    if candidate == root or parentDir(candidate) != root or
        not candidate.startsWith(root & DirSep):
      continue
    try:
      removeDir(candidate)
      result.removed.add(candidate)
    except CatchableError as err:
      result.failed.add(candidate)
      logLine(config.logPath, "dev staged generation cleanup failed=" &
        candidate & " error=" & err.msg)
  if result.removed.len > 0 or result.failed.len > 0:
    logLine(config.logPath, "swept stale dev staged generations removed=" &
      $result.removed.len & " failed=" & $result.failed.len & " kept=" &
      (if result.kept.len > 0: result.kept else: "<none>"))

proc sweepStaleDevStagedGenerationsForTest*(config: UserDaemonConfig):
    DevStagedGenerationSweep =
  ## Exported for `t_daemon_dev_bin_retention.nim`, which asserts what the
  ## sweep keeps and that it never reaches outside `dev-bin`.
  sweepStaleDevStagedGenerations(config)

proc logLine(path, message: string) =
  ## Every daemon-side diagnostic goes through here. Size-bounded and
  ## never raising: see `appendUserDaemonLogLine` (`daemon_log.nim`).
  appendUserDaemonLogLine(path, message)

proc lockMetadata(config: UserDaemonConfig; token: string): string =
  "role=" & UserDaemonRole & "\n" &
    "endpoint=" & config.endpoint & "\n" &
    "stateDir=" & config.stateDir & "\n" &
    "logPath=" & config.logPath & "\n" &
    "pid=" & $getCurrentProcessId() & "\n" &
    "token=" & token & "\n" &
    "protocol=" & $UserDaemonProtocolMajor & "." &
      $UserDaemonProtocolMinor & "\n"

when defined(posix):
  var heldDaemonLockFd: cint = -1
    ## The descriptor this process holds the user-daemon lock through, or -1.
    ## Recorded so a forked build worker can close its inherited copy: the
    ## worker is not the daemon and must not keep the daemon's lock alive
    ## after the daemon is gone.

proc acquireUserDaemonLock(config: UserDaemonConfig): UserDaemonLock =
  when defined(posix):
    createDir(config.stateDir)
    let lockPath = config.stateDir / UserDaemonLockFileName
    # CLOSE-ON-EXEC. An flock is held by the open file description, so
    # every process that inherits this descriptor holds the daemon lock
    # until IT exits -- not until the daemon does. Without the flag every
    # program the daemon or a build worker execs (the auto-started
    # runquotad, a compiler, a service an action leaves running) carried
    # it. When the daemon was killed under such a survivor, the orphan kept
    # the lock, every later `repro build` was refused a replacement daemon
    # ("user daemon lock is held by a live repro-daemon") and fell back to
    # direct mode for as long as the orphan lived. A forked build worker
    # still inherits it (fork does not honour the flag); the worker closes
    # its copy instead, see `spawnDetachedDaemonWorker`.
    let fd = posix.open(lockPath.cstring, O_RDWR or O_CREAT or posix.O_CLOEXEC,
      Mode(0o600))
    if fd < 0:
      raise newException(UserDaemonRuntimeError,
        "failed to open user-daemon lockfile " & lockPath & ", errno=" &
        $errno)
    let rc = cFlock(fd, LockExclusive or LockNonBlocking)
    if rc != 0:
      let lockErr = errno
      discard posix.close(fd)
      if lockErr == EWOULDBLOCK or lockErr == EAGAIN:
        var detail = ""
        try:
          detail = readFile(lockPath).strip()
        except CatchableError:
          discard
        var msg = "user daemon lock is held by a live repro-daemon"
        if detail.len > 0:
          msg.add("; " & detail.replace("\n", ", "))
        raise newException(UserDaemonRuntimeError, msg)
      raise newException(UserDaemonRuntimeError,
        "failed to acquire user-daemon lockfile " & lockPath & ", errno=" &
        $lockErr)
    let nowTime = getTime()
    let token = $getCurrentProcessId() & "-" & $nowTime.toUnix & "-" &
      $nowTime.nanosecond
    writeFile(lockPath, lockMetadata(config, token))
    heldDaemonLockFd = fd
    UserDaemonLock(held: true, lockPath: lockPath, token: token, fd: fd)
  elif defined(windows):
    # LockFileEx on a 1-byte range serves the same role as POSIX flock:
    # the lock is automatically released when the handle closes (e.g.
    # the daemon crashes), so a dead daemon never poisons the lockfile.
    # We open the file read+write+share-read so a sibling can observe
    # the metadata while we hold the exclusive lock.
    createDir(config.stateDir)
    let lockPath = config.stateDir / UserDaemonLockFileName
    let wpath = newWideCString(lockPath)
    # SHARE_READ | SHARE_WRITE so the matching `writeFile(lockPath, ...)`
    # below — and any concurrent contender's CreateFileW — succeeds and
    # the mutual-exclusion check is delegated to ``LockFileEx``. The
    # lock itself enforces single-writer semantics: a second daemon
    # opens the same file but fails the LOCKFILE_FAIL_IMMEDIATELY lock
    # with ERROR_LOCK_VIOLATION (the case below).
    let h = createFileW(wpath,
      (GENERIC_READ or GENERIC_WRITE).DWORD,
      (FILE_SHARE_READ or FILE_SHARE_WRITE).DWORD, nil,
      OPEN_ALWAYS.DWORD, 0.DWORD, 0)
    if h == INVALID_HANDLE_VALUE:
      raise newException(UserDaemonRuntimeError,
        "failed to open user-daemon lockfile " & lockPath & ", Windows " &
        "error=" & $osLastError())
    var overlapped: OVERLAPPED
    let ok = lockFileExRaw(h,
      (LOCKFILE_EXCLUSIVE_LOCK or LOCKFILE_FAIL_IMMEDIATELY).DWORD,
      0.DWORD, 1.DWORD, 0.DWORD, addr overlapped)
    if ok == 0:
      let lockErr = int32(osLastError())
      discard closeHandle(h)
      if lockErr == ERROR_LOCK_VIOLATION:
        var detail = ""
        try:
          detail = readFile(lockPath).strip()
        except CatchableError:
          discard
        var msg = "user daemon lock is held by a live repro-daemon"
        if detail.len > 0:
          msg.add("; " & detail.replace("\n", ", "))
        raise newException(UserDaemonRuntimeError, msg)
      raise newException(UserDaemonRuntimeError,
        "failed to acquire user-daemon lockfile " & lockPath &
        ", Windows error=" & $lockErr)
    let nowTime = getTime()
    let token = $getCurrentProcessId() & "-" & $nowTime.toUnix & "-" &
      $nowTime.nanosecond
    writeFile(lockPath, lockMetadata(config, token))
    UserDaemonLock(held: true, lockPath: lockPath, token: token, handle: h)
  else:
    UserDaemonLock(held: false)

proc releaseUserDaemonLock(lock: var UserDaemonLock) =
  if not lock.held:
    return
  when defined(posix):
    try:
      if fileExists(lock.lockPath) and
          readFile(lock.lockPath).contains("token=" & lock.token & "\n"):
        removeFile(lock.lockPath)
    except CatchableError:
      discard
    if lock.fd >= 0:
      if heldDaemonLockFd == lock.fd:
        heldDaemonLockFd = -1
      discard posix.close(lock.fd)
      lock.fd = -1
  elif defined(windows):
    if lock.handle != 0 and lock.handle != INVALID_HANDLE_VALUE:
      var overlapped: OVERLAPPED
      discard unlockFileExRaw(lock.handle, 0.DWORD, 1.DWORD, 0.DWORD,
        addr overlapped)
      discard closeHandle(lock.handle)
      lock.handle = 0
    try:
      if fileExists(lock.lockPath) and
          readFile(lock.lockPath).contains("token=" & lock.token & "\n"):
        removeFile(lock.lockPath)
    except CatchableError:
      discard
  lock.held = false

proc statusPath(config: UserDaemonConfig): string =
  statusFileForEndpoint(config.stateDir, config.endpoint)

proc sessionRecordsDir(config: UserDaemonConfig): string =
  config.stateDir / "sessions"

var sessionRecordsDirWalks = 0
  ## How many times this process has walked `sessions/`. Incremented by
  ## `sessionRecordFiles`, the only place the directory is enumerated.

proc sessionRecordsDirWalkCount*(): int =
  ## Exported for `t_daemon_active_session_tally.nim`, which asserts that
  ## priming the active-session tally walks `sessions/` a bounded number of
  ## times however many records it reclaims. The walk is the cost that
  ## matters -- it is proportional to every record ever written -- and a
  ## wall-clock assertion cannot see it on a test-sized fixture, so the test
  ## counts walks instead.
  sessionRecordsDirWalks

iterator sessionRecordFiles(config: UserDaemonConfig): string =
  ## Every `.session` file under `sessions/`, in one walk of the directory.
  ##
  ## ONE ENUMERATION SITE, so that `sessionRecordsDirWalkCount` counts every
  ## walk: a second `walkDir` of this directory would be a cost the test that
  ## bounds it cannot see.
  if dirExists(sessionRecordsDir(config)):
    inc sessionRecordsDirWalks
    for kind, path in walkDir(sessionRecordsDir(config)):
      if kind == pcFile and path.endsWith(".session"):
        yield path

proc sessionRecordPath(config: UserDaemonConfig; sessionId: string): string =
  sessionRecordsDir(config) / (safePathSegment(sessionId, "session") & ".session")

proc sessionEventLogPath(config: UserDaemonConfig; sessionId: string): string =
  sessionRecordsDir(config) /
    (safePathSegment(sessionId, "session") & ".events")

proc sessionStopRequestPath(config: UserDaemonConfig; sessionId: string): string =
  sessionRecordsDir(config) /
    (safePathSegment(sessionId, "session") & ".stop")

proc flattenRecordValue(value: string): string =
  value.replace("\n", "\\n").replace("\r", "\\r")

proc expandRecordValue(value: string): string =
  value.replace("\\n", "\n").replace("\\r", "\r")

proc flattenRecordSeq(values: openArray[string]): string =
  var escaped: seq[string] = @[]
  for value in values:
    escaped.add(flattenRecordValue(value).replace("\t", "\\t"))
  escaped.join("\t")

proc expandRecordSeq(value: string): seq[string] =
  if value.len == 0:
    return
  for item in value.split('\t'):
    result.add(expandRecordValue(item.replace("\\t", "\t")))

proc atomicWriteTextFile(path, content: string) =
  let tmpPath = path & ".tmp." & $getCurrentProcessId()
  writeFile(tmpPath, content)
  try:
    moveFile(tmpPath, path)
  except CatchableError:
    try: removeFile(tmpPath) except OSError: discard
    raise

const AbandonedSessionState* = "abandoned"
  ## A session whose writer is gone, or whose legacy record expired.
  ##
  ## Distinct from `cancelled` on purpose: a user cancelling a build and a
  ## build process vanishing are different events, and a reader looking at
  ## why a build stopped needs to tell them apart. Distinct from `failed`
  ## too -- a failed build ran and lost; an abandoned one never reported.
  ##
  ## Making it REPRESENTABLE is the point. Before this state existed the
  ## outcome had to be inferred later from a dead pid, by every reader
  ## separately, and none of them did.

type
  SessionLifecycle = enum
    ## The session-state vocabulary, as an enum, so classifying it is
    ## exhaustive. The records themselves still store strings -- there are
    ## dozens of string literals across the codebase and converting them all
    ## is a separate change -- but every CLASSIFICATION goes through the
    ## `case` statements below, so a new member cannot be added without the
    ## compiler demanding it be classified as active or terminal.
    slAccepted, slRunning, slCancelling, slWatching, slIdle
    slSucceeded, slFailed, slCancelled, slUnsupported, slCompleted
    slAbandoned

proc lifecycleToken(lifecycle: SessionLifecycle): string =
  case lifecycle
  of slAccepted: "accepted"
  of slRunning: "running"
  of slCancelling: "cancelling"
  of slWatching: "watching"
  of slIdle: "idle"
  of slSucceeded: "succeeded"
  of slFailed: "failed"
  of slCancelled: "cancelled"
  of slUnsupported: "unsupported"
  of slCompleted: "completed"
  of slAbandoned: AbandonedSessionState

proc lifecycleIsActive(lifecycle: SessionLifecycle): bool =
  case lifecycle
  of slAccepted, slRunning, slCancelling, slWatching, slIdle: true
  of slSucceeded, slFailed, slCancelled, slUnsupported, slCompleted,
     slAbandoned: false

proc parseLifecycle(state: string): Option[SessionLifecycle] =
  for lifecycle in SessionLifecycle:
    if lifecycleToken(lifecycle) == state:
      return some(lifecycle)
  none(SessionLifecycle)

proc sessionStateIsActive(state: string): bool =
  ## An UNRECOGNISED state is not active, which preserves the behaviour of
  ## the string list this replaced. It is the direction that matters less
  ## than it looks: an unknown state cannot arise from this binary, and the
  ## reclamation below is gated on writer liveness rather than on the state
  ## being understood.
  let parsed = parseLifecycle(state)
  parsed.isSome and lifecycleIsActive(parsed.get())

proc noteSessionRecordWritten(config: UserDaemonConfig;
                              session: UserDaemonSession)
  ## Forward-declared: the tally is defined below, after
  ## `loadSessionRecords` which primes it, but the single write funnel that
  ## folds into it is above.

proc imageDigestCachePath(config: UserDaemonConfig; imagePath: string): string =
  config.stateDir / "image-digests" /
    (safePathSegment(imagePath, "image") & ".digest")

const imageDigestRacyWindowNs = 2_000_000_000'i64
  ## How long an image must have been untouched, before its hash began, for a
  ## memoized digest of it to be trusted. Two seconds covers the coarsest
  ## mtime granularity in common use (FAT's 2 s) with the Linux coarse clock's
  ## few-millisecond lag far inside it. See ``cachedImageDigestHex``.

proc nowUnixNs(): int64 =
  let current = getTime()
  current.toUnix * 1_000_000_000'i64 + int64(current.nanosecond)

proc fileMtimeUnixNs(path: string): int64 =
  ## 0 when unknown; callers treat 0 as "not quiescent".
  try:
    let written = getFileInfo(path, followSymlink = true).lastWriteTime
    written.toUnix * 1_000_000_000'i64 + int64(written.nanosecond)
  except OSError, IOError:
    0

proc cachedImageDigestHex(config: UserDaemonConfig; imagePath: string): string =
  ## `imageDigestHex` memoized on `fileIdentityStamp`.
  ##
  ## The digest is hashed over the whole `repro` image -- 15.66 MiB on this
  ## host -- and the ONLY consumer is the daemon-staleness comparison in
  ## `startUserDaemon`, which every `repro build` performs. Measured in situ
  ## it cost 16.5 ms of a 74.7 ms warm no-op: the second-largest term in the
  ## invocation's fixed cost, and pure re-derivation of an answer that does
  ## not change between builds.
  ##
  ## WHY A STAT STAMP IS ENOUGH HERE, checked rather than assumed. The worry
  ## is an image whose bytes change without the key moving.
  ##
  ## * `fileIdentityStamp` folds DEVICE, INODE, SIZE and mtime at full
  ##   nanosecond resolution, so a rename-over is a new identity even at an
  ##   identical size and timestamp -- its own docstring makes that the
  ##   point, and the daemon's dev-restart poll already trusts it for this
  ##   exact question (see `restartCandidateReady`).
  ## * The one in-place-rewrite mechanism in this codebase,
  ##   `writeExecutableIfChanged`, does NOT truncate in place: it stages
  ##   beside the target and replaces it with one rename, precisely so an
  ##   active reader keeps a whole inode. Truncating in place was the bug it
  ##   was changed away from. It also writes only VCS hook dispatchers, never
  ##   this image.
  ## * An unreadable or unstattable image yields an empty stamp, and an empty
  ##   stamp NEVER consults the cache. A probe failure must not be able to
  ##   make a stale daemon look current, which is the one direction that
  ##   matters: the comparison exists to catch a daemon running old code.
  ## * A stamp CANNOT separate two writes that land in one timestamp tick.
  ##   The kernel stamps mtime from a coarse clock (a jiffy on Linux, so
  ##   several milliseconds), so "nanosecond resolution" is the field's width,
  ##   not its precision. An in-place rewrite of the same size within that
  ##   tick keeps device, inode, size AND mtime, and the memo answered the
  ##   old digest: ``t_daemon_image_digest_cache``'s same-size case failed
  ##   about 1 run in 8, alone and in the suite. So an entry also records when
  ##   its hash STARTED, and is trusted only for an image that was already
  ##   quiescent then -- its mtime older than that instant by
  ##   ``imageDigestRacyWindowNs``. That is git's "racily clean" rule: a
  ##   write after the hash began carries an mtime no earlier than the
  ##   hash's start minus the clock's lag, so it can never be mistaken for
  ##   the stamp of a file that had already been still for longer than the
  ##   window. The cost is one extra hash of a freshly rebuilt image, until
  ##   it has sat for the window.
  ##
  ## WHY NOT ASK THE DAEMON FOR ITS OWN HASH, which looks cheaper still: the
  ## daemon's `runningHash` covers a DIFFERENT FILE. It digests the STAGED
  ## image it is executing; this digests the SOURCE image on disk now. The
  ## comparison is between those two, so the daemon already supplies one side
  ## for free and cannot supply the other. A daemon asked for the source
  ## digest would answer from its own init-time reading, which agrees with
  ## its own running hash by construction -- self-confirming, and a daemon
  ## that could never look stale is the failure this check exists to prevent.
  let hashStartedNs = nowUnixNs()
  let stamp = fileIdentityStamp(imagePath)
  if stamp.len == 0:
    return imageDigestHex(imagePath)
  let mtimeNs = fileMtimeUnixNs(imagePath)
  let cachePath = imageDigestCachePath(config, imagePath)
  try:
    let cached = readFile(cachePath).splitLines()
    if cached.len >= 3 and cached[0] == stamp and cached[1].len > 0:
      let entryHashStartedNs = parseBiggestInt(cached[2])
      if mtimeNs > 0 and
          mtimeNs < entryHashStartedNs - imageDigestRacyWindowNs:
        return cached[1]
  except CatchableError:
    discard
  result = imageDigestHex(imagePath)
  if result.len > 0:
    try:
      createDir(parentDir(cachePath))
      atomicWriteTextFile(cachePath,
        stamp & "\n" & result & "\n" & $hashStartedNs & "\n")
    except CatchableError:
      # A cache that cannot be written must not fail the build; the next
      # invocation simply re-derives. Deliberately silent for that reason.
      discard

proc expectedDaemonRunningDigestHex(config: UserDaemonConfig;
                                    sourceExe: string;
                                    devMode: bool): string

proc expectedDaemonRunningDigestHexForTest*(config: UserDaemonConfig;
                                           sourceExe: string): string =
  ## Exported for `t_daemon_image_digest_cache.nim`, which grades the memoized
  ## digest against the uncached `imageDigestHex` across mutations chosen to
  ## attack the cache key. Dev mode, because that is the arm the cache is on.
  expectedDaemonRunningDigestHex(config, sourceExe, devMode = true)

proc expectedDaemonRunningDigestHex(config: UserDaemonConfig;
                                    sourceExe: string;
                                    devMode: bool): string =
  if sourceExe.len == 0 or not isAbsolute(sourceExe) or
      not fileExists(sourceExe):
    return ""
  if devMode:
    return cachedImageDigestHex(config, sourceExe)
  let companion = companionFullCliPath(sourceExe)
  if companion.len > 0:
    let companionDigest = fileDigestHex(companion)
    if companionDigest.len > 0:
      return companionDigest
  fileDigestHex(sourceExe)

type ForeignEngineVerdict* = object
  ## What `foreignEngineVerdict` found. `decline` is true only when a
  ## mismatch is PROVEN; the two digests are carried for the decline's
  ## payload and the daemon log.
  decline*: bool
  requestImageHash*: string
  daemonImageHash*: string

proc foreignEngineVerdict*(config: UserDaemonConfig;
                           requestPublicCliPath, daemonRunningHash: string):
    ForeignEngineVerdict =
  ## Whether a build or watch request was sent for an engine OTHER than the
  ## one this daemon is running, and must therefore be declined.
  ##
  ## WHY THE CLIENT'S OWN CHECK IS NOT ENOUGH. `startUserDaemon` compares the
  ## daemon's running-image digest with the client's engine and restarts a
  ## daemon that differs. But every checkout on a host shares ONE per-user
  ## endpoint, and that check runs before the request is sent. A second
  ## workspace whose reprobuild is a different build runs the same check
  ## against the same endpoint, finds the daemon "outdated" from its side, and
  ## restarts it onto its own engine. A request sent in between is served by
  ## that other engine, which then reads THIS checkout's build state -- and an
  ## interface artifact written in a newer envelope version than it knows
  ## fails the build with `unsupported interface envelope version`
  ## (reprobuild-pm issue 2026-10-16, shared-daemon dry-run). No client-side
  ## check can close the window, because the daemon can always be swapped
  ## after it. The request, however, names the engine it was sent for
  ## (`publicCliPath`), so the daemon can close it at the only point that
  ## is not racy: when it holds the request.
  ##
  ## THE SAME COMPARISON AS `startUserDaemon`, on purpose: the request's image
  ## through the memoized `cachedImageDigestHex` (which the client has
  ## normally just warmed for exactly this path, so this is a stat and a
  ## small read rather than a hash of the whole image), against the
  ## daemon's `runningHash`. A request that passed the client's check against
  ## an un-swapped daemon therefore always passes this one.
  ##
  ## THIS SIDE SERVES WHAT IT CANNOT DISPROVE: an empty, relative or missing
  ## path (an older client, or an engine deleted since) or an unavailable
  ## digest proves nothing, and the request is served as before. That is
  ## the opposite of `startUserDaemon`, which refuses to route to a daemon
  ## whose identity it cannot establish (reprobuild-pm issue 2026-09-30).
  ## The client's check is the one that must establish identity; this one
  ## only closes the race after it, so declining on an unknown here would
  ## turn every request from a client too old to name its engine into a
  ## direct build without making any of them more correct.
  result.daemonImageHash = daemonRunningHash
  if requestPublicCliPath.len == 0 or not isAbsolute(requestPublicCliPath) or
      not fileExists(requestPublicCliPath) or daemonRunningHash.len == 0:
    return
  result.requestImageHash = cachedImageDigestHex(config, requestPublicCliPath)
  result.decline = result.requestImageHash.len > 0 and
    result.requestImageHash != daemonRunningHash

proc foreignEngineDeclineEvent(command, runId, projectRoot,
                               requestPublicCliPath, daemonImagePath: string;
                               verdict: ForeignEngineVerdict):
    UserDaemonBuildEvent =
  ## The single terminal event that declines a foreign engine's request:
  ## unsupported, fallback allowed. Both clients already treat that as "run
  ## it yourself": the full CLI's `runDaemonBuild` / watch path fall back to
  ## a direct run, and the thin client hands over to its engine, whose own
  ## `startUserDaemon` then restarts the daemon onto the matching image. So
  ## the decline costs the race's loser one direct build; serving it cost a
  ## wrong answer.
  UserDaemonBuildEvent(
    schemaId: BuildEventSchemaId,
    schemaVersion: BuildEventSchemaVersion,
    eventId: 1'u64,
    occurredAtUnixMs: nowUnixMs(),
    runId: runId,
    projectRoot: projectRoot,
    command: command,
    kind: bekUnsupported,
    severity: "warning",
    message: "daemon-hosted " & command & " declined: the request was sent " &
      "for engine " & requestPublicCliPath & " (" & verdict.requestImageHash &
      ") but this repro-daemon runs " & daemonImagePath & " (" &
      verdict.daemonImageHash & "); another reprobuild build sharing this " &
      "endpoint restarted it",
    terminal: true,
    exitCode: 64,
    payloadJson: "{\"fallbackAllowed\":true,\"reason\":\"engine-mismatch\"," &
      "\"requestImageHash\":\"" & verdict.requestImageHash & "\"," &
      "\"daemonImageHash\":\"" & verdict.daemonImageHash & "\"}")

proc writeSessionRecord*(config: UserDaemonConfig; session: UserDaemonSession) =
  ## Exported for `t_daemon_active_session_tally.nim`. It is the daemon's
  ## SINGLE write funnel for session records -- creation and every state
  ## transition go through it -- which is why the active-session tally is
  ## maintained here and why a test that drives it exercises every mutation
  ## path the daemon has.
  createDir(sessionRecordsDir(config))
  atomicWriteTextFile(sessionRecordPath(config, session.sessionId),
    "sessionId=" & flattenRecordValue(session.sessionId) & "\n" &
    "projectRoot=" & flattenRecordValue(session.projectRoot) & "\n" &
    "mode=" & flattenRecordValue(session.mode) & "\n" &
    "state=" & flattenRecordValue(session.state) & "\n" &
    "startedAtUnix=" & $session.startedAtUnix & "\n" &
    "endedAtUnix=" & $session.endedAtUnix & "\n" &
    "exitCode=" & $session.exitCode & "\n" &
    "message=" & flattenRecordValue(session.message) & "\n" &
    "selectedRoots=" & flattenRecordSeq(session.selectedRoots) & "\n" &
    "debounceMs=" & $session.debounceMs & "\n" &
    "watchedPaths=" & flattenRecordSeq(session.watchedPaths) & "\n" &
    "tierState=" & flattenRecordValue(session.tierState) & "\n" &
    "lastResult=" & flattenRecordValue(session.lastResult) & "\n" &
    "writer=" & flattenRecordValue(session.writer) & "\n")
  noteSessionRecordWritten(config, session)

proc readSessionRecord(path: string): UserDaemonSession =
  for line in readFile(path).splitLines:
    let split = line.find('=')
    if split < 0:
      continue
    let key = line[0 ..< split]
    let value = expandRecordValue(line[split + 1 .. ^1])
    case key
    of "sessionId":
      result.sessionId = value
    of "projectRoot":
      result.projectRoot = value
    of "mode":
      result.mode = value
    of "state":
      result.state = value
    of "startedAtUnix":
      try: result.startedAtUnix = parseBiggestInt(value)
      except ValueError: discard
    of "endedAtUnix":
      try: result.endedAtUnix = parseBiggestInt(value)
      except ValueError: discard
    of "exitCode":
      try: result.exitCode = int(parseBiggestInt(value))
      except ValueError: discard
    of "message":
      result.message = value
    of "selectedRoots":
      result.selectedRoots = expandRecordSeq(value)
    of "debounceMs":
      try: result.debounceMs = int(parseBiggestInt(value))
      except ValueError: discard
    of "watchedPaths":
      result.watchedPaths = expandRecordSeq(value)
    of "tierState":
      result.tierState = value
    of "lastResult":
      result.lastResult = value
    of "writer":
      result.writer = value
    else:
      discard

proc loadSessionRecords(config: UserDaemonConfig): seq[UserDaemonSession] =
  for path in sessionRecordFiles(config):
    try:
      let session = readSessionRecord(path)
      if session.sessionId.len > 0:
        result.add(session)
    except CatchableError:
      discard

proc countActiveSessionRecordsFromDisk*(config: UserDaemonConfig): int =
  ## The DEFINITION of the active-session count, by reading every record.
  ##
  ## No longer on the hot path -- `activeSessionTallyFor` answers `status`
  ## requests -- but kept as the reference the incremental tally is graded
  ## against, and used to prime it. Exported for that test.
  for session in loadSessionRecords(config):
    if sessionStateIsActive(session.state):
      inc result

# ACTIVE-SESSION COUNT, MAINTAINED RATHER THAN RECOUNTED.
#
# `statusFor` needs one integer: how many sessions are active. It used to get
# it from a from-disk count, which walks `sessions/` and parses
# every record ever written. Records are never pruned, so that walk grows
# without bound with use: measured on a developer machine with 2,108 records
# (9.2 MB, oldest seven weeks old) it cost 37.6 ms of a 76 ms `repro build`
# no-op -- about half the invocation's fixed cost, and the largest single term
# in it. A `status` request is issued on EVERY build (the daemon-staleness
# check in `startUserDaemon`), so every build paid it.
#
# The count is therefore primed ONCE from disk and maintained from then on.
# Priming from disk rather than starting at zero is the load-bearing half: a
# daemon that counted only the sessions its own process had seen would report
# LOW after a dev self-restart, and a status consumer that believes there are
# no active sessions where there are is worse than a slow one. `writeSession`
# is the single funnel for both creation and every state transition, so
# maintaining it there covers every mutation without a second bookkeeping
# site.
#
# Keyed on the records directory, so a differently-configured `stateDir`
# re-primes instead of inheriting another daemon's tally.
#
# A PRIME IS ONE RECLAIM WALK AND ONE COUNT WALK, AND A WRITE NEVER STARTS
# ONE. Priming reclaims first, and every record it reclaims is rewritten
# through `writeSessionRecord`, which reports the write to
# `noteSessionRecordWritten`. The cache key is not published until the prime
# ends, and that proc used to answer a write into an unprimed directory by
# priming -- so each reclaimed record started a nested prime, each walking
# `sessions/` twice. The answer was still right (the outermost frame recounts
# last), but n reclaimed records cost 2n + 2 walks of a directory that holds
# every record ever written, at a recursion depth nothing bounded. The
# daemon's startup reclaim took the same path on its first write, and the
# prime that set off reclaimed the rest behind its back, so the startup log
# said `count=1` however many records were reclaimed.
#
# Priming only where the tally is READ (`activeSessionTallyFor`) makes the
# re-entry impossible rather than unlikely. A write into an unprimed directory
# is already on disk, so the prime that eventually runs counts it; priming or
# folding at write time adds nothing but the walk. A writer added inside a
# prime later -- reclamation or anything else -- cannot re-enter it either.
var activeSessionCacheDir = ""
var activeSessionStateById = initTable[string, bool]()
var activeSessionTally = 0

const LegacySessionInactivitySeconds = 7'i64 * 24 * 60 * 60

type SessionReclamation = enum
  srNone, srDeadWriter, srLegacyInactive

proc sessionReclamation(session: UserDaemonSession; path: string;
                        nowUnix: int64): SessionReclamation =
  # Unknown nonempty identities are never aged out. Only the pre-identity
  # population needs a bounded inactivity policy; an identified writer's
  # ownership must instead be settled by the actual liveness probe.
  if session.writer.len > 0:
    if writerLiveness(session.writer) == wlDead:
      return srDeadWriter
    return srNone
  if session.startedAtUnix <= 0 or nowUnix < LegacySessionInactivitySeconds:
    return srNone
  let modified =
    try: getLastModificationTime(path).toUnix
    except CatchableError: return srNone
  # The later timestamp protects a recently updated old session and a
  # recently started backdated file. Comparing with a cutoff also avoids
  # overflowing on corrupt/future start times. Exactly seven days qualifies.
  if modified <= 0:
    return srNone
  if max(session.startedAtUnix, modified) <=
      nowUnix - LegacySessionInactivitySeconds:
    return srLegacyInactive
  srNone

proc abandonedRecord(session: UserDaemonSession;
                     reason: SessionReclamation): UserDaemonSession =
  ## The shared terminal rewrite for startup and query reconciliation.
  ## Keep history and an existing message; supply the reason only when empty.
  result = session
  result.state = AbandonedSessionState
  result.endedAtUnix = getTime().toUnix
  if result.message.len == 0:
    result.message =
      if reason == srLegacyInactive:
        "no writer identity or activity for seven days"
      else:
        "writer process no longer exists"

proc reclaimAbandonedSessions*(config: UserDaemonConfig): int =
  ## Rewrite active records with provably dead writers, and legacy records
  ## with no writer identity and at least seven days of inactivity.
  ## Returns how many records were successfully reclaimed.
  ##
  ## Killed workers never write a terminal state, so records can otherwise
  ## defer development self-restart forever. Writer liveness alone does not
  ## settle pre-field records: the historical 16,788-deferral flood included
  ## records without writer identities. The legacy inactivity rule covers
  ## that population while preserving recent records and unknown nonempty
  ## identities. File mtime and start time must both meet the age bound.
  ##
  ## This full directory sweep runs at startup/prime only. Status queries
  ## reconcile only believed-active records, avoiding a walk of every record
  ## ever written on every build.
  let nowUnix = getTime().toUnix
  for path in sessionRecordFiles(config):
    let session =
      try: readSessionRecord(path)
      except CatchableError: continue
    if session.sessionId.len == 0 or not sessionStateIsActive(session.state):
      continue
    let reason = sessionReclamation(session, path, nowUnix)
    if reason == srNone:
      continue
    try:
      writeSessionRecord(config, abandonedRecord(session, reason))
      inc result
    except CatchableError:
      # Preserve the record on write failure; startup is never fatal.
      discard

proc primeActiveSessionTally(config: UserDaemonConfig) =
  ## Count the active sessions in `sessions/` from disk, after reclaiming the
  ## abandoned ones. At most two walks of the directory, whatever it holds:
  ## see the note above `activeSessionCacheDir` for why nothing re-enters it.
  # Reclaim BEFORE counting, so the tally this produces already excludes
  # dead writers and expired legacy records. Counting first and reclaiming later would
  # leave the first status answer of every daemon reporting phantom work.
  discard reclaimAbandonedSessions(config)
  activeSessionStateById = initTable[string, bool]()
  activeSessionTally = 0
  for session in loadSessionRecords(config):
    let active = sessionStateIsActive(session.state)
    activeSessionStateById[session.sessionId] = active
    if active:
      inc activeSessionTally
  activeSessionCacheDir = sessionRecordsDir(config)

proc noteSessionRecordWritten(config: UserDaemonConfig;
                              session: UserDaemonSession) =
  if activeSessionCacheDir != sessionRecordsDir(config):
    # Not primed for this directory -- or being primed right now, since the
    # key is published last. The record is already on disk, so whichever
    # prime counts this directory counts it. Neither fold it in nor prime
    # here: see the note above `activeSessionCacheDir`.
    return
  let active = sessionStateIsActive(session.state)
  if not activeSessionStateById.hasKey(session.sessionId):
    if active:
      inc activeSessionTally
  elif activeSessionStateById[session.sessionId] != active:
    if active: inc activeSessionTally else: dec activeSessionTally
  activeSessionStateById[session.sessionId] = active

proc refreshBelievedActiveSessions(config: UserDaemonConfig) =
  ## Re-read the records THIS process believes are active, and fold any that
  ## have left an active state.
  ##
  ## `writeSessionRecord` is a single write funnel only WITHIN one process.
  ## A build or watch session is accepted by the daemon parent (which counts
  ## it) and then run by a double-forked worker (`spawnDetachedDaemonWorker`),
  ## and every later transition — `running`, then `succeeded`/`failed` — is
  ## written by that worker, into the WORKER's copy of the tally. The parent
  ## never saw a session end, so after one build it reported
  ## `active-sessions: 1` forever and deferred every dev self-restart
  ## (t_local_daemons_control_plane_m10
  ## `integration_daemon_dev_restart_does_not_corrupt_state`).
  ##
  ## Only the believed-active records are read, so the cost is the number of
  ## sessions in flight — not the unbounded walk of every record ever written
  ## that the maintained tally replaced. A record that has vanished counts as
  ## ended; one that cannot be READ keeps its last known state, because
  ## under-reporting live work is the failure `restartCandidateReady` cannot
  ## afford (see the note above `activeSessionCacheDir`).
  ##
  ## A RECORD LEFT NON-TERMINAL BY A WRITER THAT DIED COUNTS AS ENDED TOO,
  ## AND IS RECLAIMED HERE. The re-read above answers "did someone write a
  ## terminal state?", and that is only half of how a session stops being
  ## live work: the other half is a worker that is SIGKILLed, OOM-killed or
  ## dies with its terminal machine, which writes nothing at all. Such a
  ## record stays `running` on disk forever, so the re-read keeps agreeing
  ## that it is active and the tally keeps blocking the dev self-restart --
  ## for the whole life of the daemon process, because
  ## `reclaimAbandonedSessions` runs only at prime/startup. Measured on this
  ## workstation: a daemon deferring its restart 16,788 consecutive times.
  ## Dead-writer probing alone did not cover that flood's pre-field records;
  ## those require the narrowly scoped legacy inactivity rule below.
  ##
  ## So the reconciliation happens WHERE THE ANSWER WOULD BLOCK AN ACTION
  ## rather than only at startup. It costs nothing extra: the record has just
  ## been read, and `writerLiveness` is one `/proc` (or `sysctl`) probe per
  ## session in flight -- never the unbounded directory walk. The rewrite is
  ## what makes the finding durable and shared: this process stops counting
  ## the record, and every other process that reads `sessions/` now sees
  ## `abandoned` instead of a lie.
  ##
  ## Nonempty unknown identities remain live. Records without any identity
  ## instead expire after seven days without activity, using the same
  ## timestamp checks as startup. A failed legacy rewrite keeps the tally
  ## active for retry, because age is policy rather than proof of death.
  var ended: seq[string] = @[]
  var abandoned: seq[tuple[record: UserDaemonSession,
                           reason: SessionReclamation]] = @[]
  let nowUnix = getTime().toUnix
  for sessionId, active in activeSessionStateById.pairs:
    if not active:
      continue
    let path = sessionRecordPath(config, sessionId)
    if not fileExists(path):
      ended.add(sessionId)
      continue
    var record: UserDaemonSession
    try:
      record = readSessionRecord(path)
    except CatchableError:
      # Keeps its last known state: see the docstring on why this direction.
      continue
    if not sessionStateIsActive(record.state):
      ended.add(sessionId)
    else:
      let reason = sessionReclamation(record, path, nowUnix)
      if reason != srNone:
        abandoned.add((record, reason))
  for sessionId in ended:
    activeSessionStateById[sessionId] = false
    dec activeSessionTally
  # After the loop, never inside it: `writeSessionRecord` folds the record
  # into `activeSessionStateById` through `noteSessionRecordWritten`, and a
  # table must not be mutated while it is being iterated.
  for (record, reason) in abandoned:
    try:
      writeSessionRecord(config, abandonedRecord(record, reason))
    except CatchableError:
      # A proved-dead writer is no longer work even if persistence fails.
      # For legacy expiry ownership is unknown, so keep the belief active
      # until the terminal rewrite succeeds and is shared with other readers.
      if reason == srLegacyInactive:
        continue
    if activeSessionStateById.getOrDefault(record.sessionId, false):
      activeSessionStateById[record.sessionId] = false
      dec activeSessionTally

proc activeSessionTallyFor*(config: UserDaemonConfig): int =
  ## The number `statusFor` reports; refresh cost is believed-active records.
  ##
  ## Exported for `t_daemon_active_session_tally.nim`, which asserts the
  ## invariant this exists to preserve: it equals a fresh from-disk
  ## `countActiveSessionRecordsFromDisk` after any sequence of opens and
  ## terminations.
  if activeSessionCacheDir != sessionRecordsDir(config):
    primeActiveSessionTally(config)
  else:
    refreshBelievedActiveSessions(config)
  activeSessionTally


proc removeStatusFile(config: UserDaemonConfig) =
  try:
    removeFile(statusPath(config))
  except OSError:
    discard

proc removeEndpointFiles(config: UserDaemonConfig) =
  try: removeFile(config.endpoint) except OSError: discard
  removeStatusFile(config)

proc removeLegacyStatusFile(config: UserDaemonConfig): bool =
  ## Remove the record an older-generation daemon for ``config.endpoint``
  ## left behind when it died uncleanly. That generation keyed the record on
  ## the endpoint BASENAME, so the file at the legacy name may belong to any
  ## same-basename endpoint, possibly a live one; it is removed only when its
  ## ``endpoint=`` line names this endpoint exactly, and only from the posix
  ## stale gate below (the endpoint refuses connections). The normal exit
  ## path never touches it.
  let legacy = config.stateDir / "status" /
    (safePathSegment(config.endpoint.extractFilename, "repro-daemon") &
      ".status")
  try:
    if fileExists(legacy) and
        ("endpoint=" & config.endpoint) in readFile(legacy).splitLines():
      removeFile(legacy)
      result = true
  except CatchableError:
    discard

proc cleanupStaleUserDaemonDiscovery*(requested: UserDaemonConfig): bool =
  ## Remove stale discovery files only when the endpoint does not accept a raw
  ## connection. A protocol-incompatible but live daemon must keep its state.
  ##
  ## The paths are anchored first, as ``cleanupPlatformBackgroundRegistration``
  ## anchors them: the daemon keyed its record on the ABSOLUTE endpoint and
  ## state directory, and `repro daemon status|stop` pass the flags as typed.
  let config = withAnchoredDaemonPaths(requested)
  when defined(posix):
    let endpointPresent = userDaemonEndpointExists(config.endpoint)
    let accepts = userDaemonEndpointAcceptsConnections(config.endpoint)
    if endpointPresent and not accepts:
      try:
        removeFile(config.endpoint)
        result = true
      except OSError:
        discard
    if not accepts:
      if fileExists(statusPath(config)):
        removeStatusFile(config)
        result = true
      if removeLegacyStatusFile(config):
        result = true
  else:
    if fileExists(statusPath(config)):
      removeStatusFile(config)
      result = true

proc generationFor(startedAt: Time): string =
  $getCurrentProcessId() & "-" & $startedAt.toUnix & "-" & $startedAt.nanosecond


proc statusFor(config: UserDaemonConfig; startedAt: Time;
               generation: string; activeSessionCount = 0;
               devRestart: DevRestartState = DevRestartState()):
    UserDaemonStatus =
  UserDaemonStatus(
    running: true,
    role: UserDaemonRole,
    endpoint: config.endpoint,
    stateDir: config.stateDir,
    logPath: config.logPath,
    pid: int64(getCurrentProcessId()),
    uptimeSeconds: getTime().toUnix - startedAt.toUnix,
    protocolMajor: UserDaemonProtocolMajor,
    protocolMinor: UserDaemonProtocolMinor,
    binary: binaryIdentity("repro-daemon",
      daemonSelfImagePath(config.sourceExe, devRestart.runningImagePath),
      versionString()),
    featureFlags: UserDaemonFeatureFlags,
    generation: generation,
    activeSessionCount: activeSessionCount,
    devMode: config.devMode,
    sourceImagePath: devRestart.sourceImagePath,
    runningImagePath:
      if devRestart.runningImagePath.len > 0:
        devRestart.runningImagePath
      else:
        # N30's sweep. See ``daemonSelfImagePath``.
        daemonSelfImagePath(),
    sourceHash: devRestart.sourceHash,
    runningHash: devRestart.runningHash,
    protocolGeneration:
      if devRestart.protocolGeneration.len > 0:
        devRestart.protocolGeneration
      else:
        $UserDaemonProtocolMajor & "." & $UserDaemonProtocolMinor,
    restartRunId: devRestart.restartRunId,
    stagedGenerationDir: devRestart.stagedGenerationDir,
    previousStagedGenerationDir: devRestart.previousStagedGenerationDir,
    reconnectLimitations:
      if config.devMode: reconnectLimitationsText() else: "")

proc writeStatusFile(config: UserDaemonConfig; status: UserDaemonStatus) =
  let path = statusPath(config)
  createDir(parentDir(path))
  writeFile(path,
    "role=" & status.role & "\n" &
    "endpoint=" & status.endpoint & "\n" &
    "stateDir=" & status.stateDir & "\n" &
    "logPath=" & status.logPath & "\n" &
    "pid=" & $status.pid & "\n" &
    "protocol=" & $status.protocolMajor & "." & $status.protocolMinor &
      "\n" &
    "binary=" & status.binary.path & "\n" &
    "generation=" & status.generation & "\n" &
    "sourceImagePath=" & status.sourceImagePath & "\n" &
    "runningImagePath=" & status.runningImagePath & "\n" &
    "sourceHash=" & status.sourceHash & "\n" &
    "runningHash=" & status.runningHash & "\n" &
    "protocolGeneration=" & status.protocolGeneration & "\n" &
    "restartRunId=" & status.restartRunId & "\n" &
    "stagedGenerationDir=" & status.stagedGenerationDir & "\n" &
    "previousStagedGenerationDir=" &
      status.previousStagedGenerationDir & "\n" &
    "featureFlags=" & status.featureFlags & "\n")

proc daemonLeaseScope(config: UserDaemonConfig): DaemonLeaseScope =
  ## L4 (§4.1): a ``--system`` daemon serves the system lease scope; every
  ## other daemon serves the per-user scope.
  if config.systemScope: dlsSystem else: dlsUser

proc daemonLeaseStoreRoot(config: UserDaemonConfig): string =
  ## The state-store root this daemon's lease registry + reaper tick operate
  ## on: an explicit ``--state-root`` wins, otherwise it is derived from the
  ## daemon's scope (§4.1 routing).
  leaseStoreRootForScope(daemonLeaseScope(config), config.leaseStoreRoot)

proc handleLeaseRenew(socket: IpcConn; config: UserDaemonConfig;
                      request: DaemonLeaseRenewRequest) =
  ## L4 (§4.2) renew handler: advance the holder's lease in the scoped
  ## store. The request's own ``scope`` selects the store root (a mismatched
  ## scope is honoured verbatim so a client can address either registry);
  ## the daemon's ``--state-root`` override still wins for a hermetic test.
  let response =
    try:
      applyLeaseRenew(request, overrideRoot = config.leaseStoreRoot)
    except CatchableError as err:
      DaemonLeaseRenewResponse(ok: false,
        reason: "lease renew raised: " & err.msg,
        effectiveDeadlineUnix: LeaseRenewKeepSentinel)
  socket.writeFrame(udkLeaseRenewAck, leaseRenewResponseBody(response))
  logLine(config.logPath, "lease renew address=" & request.address &
    " consumer=" & request.consumerId & " ttlSeconds=" &
    $request.ttlSeconds & " ok=" & $response.ok & " hadRecord=" &
    $response.hadRecord)

proc handleServiceConverge(socket: IpcConn; config: UserDaemonConfig;
                           instances: var ServiceInstanceRegistry;
                           request: DaemonServiceConvergeRequest) =
  ## Shared-Development-Services L7 (§4.5) converge handler: resolve
  ## `(identity, scope, environment)` against the instance registry,
  ## attach when an instance is present and materialise one otherwise.
  ##
  ## THE REGISTRY IS THE DAEMON'S, NOT THIS REQUEST'S. It is rebuilt once
  ## at daemon start and mutated in place by each handler, which is what
  ## §4.5 means by "in-memory, and authoritative only while the daemon is
  ## running" -- and it is what makes the gate's daemon-restart clause
  ## non-vacuous: a registry re-read from disk on every request would
  ## satisfy that clause without ever exercising a rebuild.
  ##
  ## The accept loop is single-threaded and sequential (one
  ## `handleClient` at a time), so a `var` registry needs no lock; the
  ## comment is here because adding a worker thread to that loop would
  ## break this assumption silently.
  let response =
    try:
      applyServiceConverge(instances, request)
    except CatchableError as err:
      DaemonServiceConvergeResponse(ok: false,
        outcome: outcomeWord(scoRefuseUnknownHolders),
        diagnostic: "service converge raised: " & err.msg)
  socket.writeFrame(udkServiceConvergeAck,
    serviceConvergeResponseBody(response))
  logLine(config.logPath, "service converge holder=" & request.holderId &
    " address=" & response.address & " outcome=" & response.outcome &
    " ok=" & $response.ok & " hadInstance=" & $response.hadInstance &
    " holderSetRecoverable=" & $response.holderSetRecoverable &
    " holders=" & $response.holders.len & " pid=" & $response.pid)

proc handleServiceRelease(socket: IpcConn; config: UserDaemonConfig;
                          instances: var ServiceInstanceRegistry;
                          request: DaemonServiceReleaseRequest) =
  ## L7 (§4.5) release handler: drop ONE holder, and stop the instance
  ## only when that holder was the last.
  let response =
    try:
      applyServiceRelease(instances, request)
    except CatchableError as err:
      DaemonServiceReleaseResponse(ok: false,
        outcome: outcomeWord(srlRefuseUnknownHolders),
        diagnostic: "service release raised: " & err.msg)
  socket.writeFrame(udkServiceReleaseAck,
    serviceReleaseResponseBody(response))
  logLine(config.logPath, "service release holder=" & request.holderId &
    " address=" & response.address & " outcome=" & response.outcome &
    " ok=" & $response.ok & " remaining=" &
    $response.remainingHolders.len & " stoppedPid=" &
    $response.stoppedPid)

proc handleLeaseReapProviders(socket: IpcConn; config: UserDaemonConfig;
                              request: DaemonLeaseReapProvidersRequest) =
  ## L4/L5 (§4.2 destroy transport) handler: record how to reach the provider
  ## that owns each named resource ``typeId``, so the next reap tick destroys
  ## that type over a launched provider SESSION instead of falling back to
  ## in-process linking this daemon does not have.
  ##
  ## This is the feeder whose absence made the whole ``rtSession`` arm
  ## unreachable from the product
  ## (reprobuild-pm/issues/2026-10-14-no-production-path-enables-the-daemons-session-reap-transport.md):
  ## ``registerLeaseReapProvider`` had no caller in the shipped tree.
  ##
  ## THE REGISTRY IS A MODULE GLOBAL AND IS NOT LOCKED, which is sound here and
  ## only here: this handler runs on the event-loop thread, between accepts, and
  ## so does the reap tick (``runScopedLeaseReapTick``) — the writer and the
  ## reader are the same thread. Build and watch work runs in detached
  ## PROCESSES, which share no globals with the loop.
  ##
  ## VALIDATION IS A REFUSAL, NOT A FILTER, and it is exactly the test the
  ## TRANSPORT will later apply (``leaseReapProviderRefusal`` ->
  ## ``isLaunchableArtifact``): no typeId names no type, and a path that is
  ## empty OR NOT ABSOLUTE cannot be launched, so the tick would drop it and
  ## reap in-process. Accepting such an entry would answer ``ok: true,
  ## registered: 1``, log a successful registration and make
  ## ``hasLeaseReapProviders()`` true while changing nothing about any sweep —
  ## reporting success and doing nothing, which is the exact shape this whole
  ## area has been fixing. The frame is rejected whole, and nothing is
  ## registered from it.
  var response = DaemonLeaseReapProvidersResponse(ok: true)
  for p in request.providers:
    # The validator is handed THE ARTIFACT THAT WOULD BE REGISTERED, and it
    # delegates to the same `isLaunchableArtifact` the transport applies — so
    # the handler cannot accept a ref the tick will throw away. See
    # `leaseReapProviderRefusal`.
    let refusal = leaseReapProviderRefusal(p.typeId,
      LeaseReapProviderArtifact(
        binaryPath: p.binaryPath,
        providerArtifactId: p.providerArtifactId,
        workingDir: p.workingDir))
    if refusal.len > 0:
      response = DaemonLeaseReapProvidersResponse(ok: false, reason: refusal)
      break
  if response.ok:
    for p in request.providers:
      registerLeaseReapProvider(p.typeId, LeaseReapProviderArtifact(
        binaryPath: p.binaryPath,
        providerArtifactId: p.providerArtifactId,
        workingDir: p.workingDir))
    response.registered = request.providers.len
  socket.writeFrame(udkLeaseReapProvidersAck,
    leaseReapProvidersResponseBody(response))
  logLine(config.logPath, "lease reap providers registered=" &
    $response.registered & " requested=" & $request.providers.len &
    " ok=" & $response.ok &
    (if response.reason.len > 0: " reason=" & response.reason else: "") &
    " scope=" & (if request.scope == dlsSystem: "system" else: "user"))

proc handleHello(socket: IpcConn; config: UserDaemonConfig; generation: string;
                 frameBody: openArray[byte];
                 devRestart = DevRestartState()): bool =
  let hello = parseHello(frameBody)
  if hello.major != UserDaemonProtocolMajor:
    socket.writeFrame(udkError, errorBody(
      "user daemon protocol mismatch: client major " & $hello.major &
      ", daemon major " & $UserDaemonProtocolMajor))
    return false
  # THROUGH `daemonSelfImagePath`, WHICH IS WHERE N21 STOPPED SHORT. N21
  # guarded the field in `statusFor` and left this handshake building the
  # daemon's identity from a raw `getAppFilename()`.
  #
  # WHAT THIS IS NOT, corrected after the seventh-pass review measured the
  # claim that used to stand here: `repro daemon status` does NOT print
  # the HelloAck's identity. `queryUserDaemonStatus` returns
  # `parseStatusBody` of the `udkStatusResponse` frame -- `statusFor`, the
  # same producer the STATUS FILE is written from -- and the only fields
  # `connectUserDaemon` reads out of `parseHelloAck` are `major` and
  # `featureFlags`. `parsed.daemon` is parsed and never read by any
  # caller, so the file-versus-live disagreement N27 credited to this site
  # cannot arise on this path. This guard is still correct: the identity
  # IS on the wire, a future client may read it, and one guarded producer
  # beside one unguarded producer is the shape the whole N21/N27/N30
  # sequence kept reappearing in. It is hardening, not the fix for a
  # measured disagreement, and it is labelled as such.
  let daemon = binaryIdentity("repro-daemon",
    daemonSelfImagePath(config.sourceExe, devRestart.runningImagePath),
    versionString())
  socket.writeFrame(udkHelloAck, helloAckBody(daemon, UserDaemonFeatureFlags,
    generation))
  logLine(config.logPath, "handshake client=" & hello.client.name &
    " mode=" & hello.commandMode & " client-protocol=" & $hello.major &
    "." & $hello.minor)
  true

proc nextBuildEvent(runId, sessionId, projectRoot: string;
                    eventId: uint64;
                    kind: UserDaemonBuildEventKind;
                    message: string;
                    terminal = false;
                    exitCode = 0;
                    severity = "info";
                    payloadJson = ""): UserDaemonBuildEvent =
  UserDaemonBuildEvent(
    schemaId: BuildEventSchemaId,
    schemaVersion: BuildEventSchemaVersion,
    eventId: eventId,
    occurredAtUnixMs: nowUnixMs(),
    runId: runId,
    sessionId: sessionId,
    projectRoot: projectRoot,
    command: "build",
    kind: kind,
    severity: severity,
    message: message,
    terminal: terminal,
    exitCode: exitCode,
    payloadJson: payloadJson)

proc bytesToString(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc stringToBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc appendWatchEventRecord(config: UserDaemonConfig; sessionId: string;
                            event: UserDaemonBuildEvent) =
  createDir(sessionRecordsDir(config))
  let body = buildEventBody(event)
  var record: seq[byte] = @[]
  record.writeU32Le(uint32(body.len))
  record.add(body)
  var file = open(sessionEventLogPath(config, sessionId), fmAppend)
  defer: file.close()
  file.write(record.bytesToString())

proc readU32LeFromString(raw: string; pos: var int): uint32 =
  if pos + 4 > raw.len:
    raise newException(ValueError, "truncated watch event length")
  result =
    uint32(ord(raw[pos])) or
    (uint32(ord(raw[pos + 1])) shl 8) or
    (uint32(ord(raw[pos + 2])) shl 16) or
    (uint32(ord(raw[pos + 3])) shl 24)
  pos += 4

proc readWatchEventsFrom(config: UserDaemonConfig; sessionId: string;
                         offset: var int64): seq[UserDaemonBuildEvent] =
  let path = sessionEventLogPath(config, sessionId)
  if not fileExists(path):
    return
  let raw = readFile(path)
  var pos = int(offset)
  while pos + 4 <= raw.len:
    let start = pos
    let length = int(readU32LeFromString(raw, pos))
    if length < 0 or pos + length > raw.len:
      pos = start
      break
    let body = raw[pos ..< pos + length].stringToBytes()
    result.add(parseBuildEventBody(body))
    pos += length
  offset = int64(pos)

proc latestSessionRecord(config: UserDaemonConfig;
                         sessionId: string): UserDaemonSession =
  let path = sessionRecordPath(config, sessionId)
  if fileExists(path):
    return readSessionRecord(path)
  UserDaemonSession(sessionId: sessionId, state: "missing", exitCode: 1,
    message: "watch session not found")

proc removeSession(sessions: var seq[UserDaemonSession]; sessionId: string) =
  var kept: seq[UserDaemonSession] = @[]
  for session in sessions:
    if session.sessionId != sessionId:
      kept.add(session)
  sessions = kept

proc sessionStateAccepted(sessionId, projectRoot: string; started: Time):
    UserDaemonSession =
  UserDaemonSession(sessionId: sessionId,
    projectRoot: projectRoot, mode: "build", state: "accepted",
    writer: encodeWriterIdentity(currentWriterIdentity()),
    startedAtUnix: started.toUnix,
    exitCode: -1,
    message: "build request accepted by repro-daemon")

proc watchSessionStateAccepted(sessionId, projectRoot: string; started: Time;
                               request: UserDaemonWatchRequest):
    UserDaemonSession =
  UserDaemonSession(sessionId: sessionId,
    projectRoot: projectRoot, mode: "watch", state: "accepted",
    writer: encodeWriterIdentity(currentWriterIdentity()),
    startedAtUnix: started.toUnix,
    exitCode: -1,
    message: "watch request accepted by repro-daemon",
    selectedRoots: request.selectedRoots,
    debounceMs: request.debounceMs,
    tierState: "single-tier",
    lastResult: "pending")

proc updateSessionState(config: UserDaemonConfig; session: var UserDaemonSession;
                        state: string; exitCode = -1; message = "") =
  session.state = state
  session.exitCode = exitCode
  if message.len > 0:
    session.message = message
  if state notin ["accepted", "running", "cancelling", "watching", "idle"]:
    session.endedAtUnix = getTime().toUnix
  writeSessionRecord(config, session)

proc setSessionState(session: var UserDaemonSession; state: string;
                     exitCode = -1; message = "") =
  session.state = state
  session.exitCode = exitCode
  if message.len > 0:
    session.message = message
  if state notin ["accepted", "running", "cancelling", "watching", "idle"]:
    session.endedAtUnix = getTime().toUnix

proc buildResponseDelayMs(): int =
  let raw = getEnv("REPRO_DAEMON_M3_BUILD_RESPONSE_DELAY_MS", "")
  if raw.len == 0:
    return 0
  try:
    max(0, parseInt(raw))
  except ValueError:
    0

proc waitForBuildUnsupportedOrDisconnect(socket: IpcConn; delayMs: int): bool =
  ## Returns true when the attached client disconnected before the placeholder
  ## M3 unsupported response was sent.
  let deadline = epochTime() + float(delayMs) / 1000.0
  while epochTime() < deadline:
    if socket.clientDisconnected():
      return true
    sleep(25)
  socket.clientDisconnected()

proc flushStatsAfterTerminal(config: UserDaemonConfig; sessionId: string) =
  let flush = flushStatsObservations()
  if flush.flushed > 0:
    logLine(config.logPath, "stats flushed session=" & sessionId &
      " observations=" & $flush.flushed & " store=" & flush.storePath)
  elif flush.discarded > 0:
    # M18: THE DISCARD IS LOGGED, NOT SWALLOWED. The derived store's
    # backend is not linked, so rollup inputs have nowhere to go -- and an
    # operator looking at an empty derived store must be able to tell
    # "nothing was captured" from "what was captured had nowhere to go".
    # The in-process counter cannot answer that from another process; this
    # line can.
    logLine(config.logPath, "stats discarded session=" & sessionId &
      " observations=" & $flush.discarded & " store=" & flush.storePath &
      " reason=derived-backend-not-linked")
  elif flush.lastError.len > 0:
    logLine(config.logPath, "stats flush failed session=" & sessionId &
      " error=" & flush.lastError)

when defined(posix):
  template spawnDetachedDaemonWorker(config: UserDaemonConfig;
                                     label, sessionId: string;
                                     sock: IpcConn; body: untyped) =
    ## Run a detached daemon worker via a double-fork so the worker is
    ## reparented to the init/subreaper and auto-reaped on exit — the
    ## daemon is long-lived, and a single fork left every finished worker
    ## as a zombie (the parent never waited on it). A global
    ## SIGCHLD/``waitpid(-1)`` reaper is not an option here because the
    ## daemon parent also drives ``osproc`` children (binary staging,
    ## launchctl/systemctl); reaping with ``-1`` would steal their exit
    ## statuses. Double-forking sidesteps that: the parent only waits on
    ## the short-lived intermediate (a known pid, never an osproc child),
    ## and the grandchild worker is auto-reaped after re-parenting. The
    ## body runs in the grandchild; ``sock`` is closed there afterwards,
    ## matching the previous single-fork path.
    let firstPid = fork()
    if firstPid < 0:
      raise newException(UserDaemonRuntimeError, "failed to fork " & label)
    if firstPid == 0:
      let secondPid = fork()
      if secondPid == 0:
        signal(SIGCHLD, SIG_DFL)
        # The worker is not the daemon: drop its inherited copy of the daemon
        # lock so a worker that outlives a killed daemon cannot keep a
        # replacement from starting (see `acquireUserDaemonLock`). The
        # daemon's own descriptor still holds the lock.
        if heldDaemonLockFd >= 0:
          discard posix.close(heldDaemonLockFd)
          heldDaemonLockFd = -1
        logLine(config.logPath,
          label & " started session=" & sessionId & " pid=" &
            $getCurrentProcessId())
        try:
          body
        except CatchableError as err:
          logLine(config.logPath,
            label & " fatal session=" & sessionId & " error=" & err.msg)
        try: sock.closeIpcConn() except CatchableError: discard
        quit(0)
      quit(0)
    var workerStatus: cint
    while waitpid(firstPid, workerStatus, 0) < 0 and errno == EINTR:
      discard

proc runBuildRequestWorker(socket: IpcConn; config: UserDaemonConfig;
                           request: UserDaemonBuildRequest;
                           session: var UserDaemonSession) =
  var eventId = 1'u64
  var terminalSent = false
  let sessionId = session.sessionId
  let projectRoot = session.projectRoot
  proc emit(kind: UserDaemonBuildEventKind; message: string; terminal: bool;
            exitCode: int; severity: string; payloadJson: string) =
    inc eventId
    socket.writeFrame(udkBuildEvent, buildEventBody(nextBuildEvent(
      request.runId, sessionId, projectRoot, eventId, kind,
      message, terminal = terminal, exitCode = exitCode,
      severity = severity, payloadJson = payloadJson)))
    terminalSent = terminalSent or terminal

  proc cancelCheck(): bool =
    request.attached and request.cancelOnDisconnect and socket.clientDisconnected()

  # Do not prewarm here. MAC-2's prewarm runs in the PARENT, before the fork
  # that produced this worker (see `handleBuildRequest`), which is the only
  # placement where warmed state reaches more than one build. Running it here
  # would warm a process that is about to exit — and it would do so while an
  # attached client waits for a terminal event, which is one of the three
  # reasons the original prewarmer was disabled.

  try:
    # THE WORKER STAMPS ITSELF, IN THE SAME WRITE THAT LEAVES `accepted`.
    #
    # `writer` must always name the process whose death orphans this record,
    # and for a session that is `running` that process is THIS grandchild --
    # not the daemon that accepted the request. `spawnDetachedDaemonWorker`
    # double-forks and reparents, so the worker outlives the daemon
    # routinely (a dev self-restart alone does it).
    #
    # Stamping the daemon's identity and leaving it was a real defect, caught
    # before merge: daemon accepts (writer = daemon), forks, daemon dies, a
    # new daemon sees an active record whose writer is gone and marks it
    # `abandoned` -- while this worker is still building. A tally that drops
    # while work continues can then let a dev self-restart proceed under a
    # live build, which is worse than the lingering record it was fixing.
    #
    # WHICH IDENTITY GOVERNS IS ENCODED IN THE STATE, so there is no window
    # rather than a short one:
    #   * `accepted` -- the DAEMON's identity governs. The worker has not
    #     stamped yet, and no work can have begun, so a dead daemon plus
    #     `accepted` is safely reclaimable.
    #   * `running` and beyond -- the WORKER's identity governs, because this
    #     assignment and the transition out of `accepted` are ONE
    #     `writeSessionRecord`. The record never exists in `running` carrying
    #     the daemon's identity, so the guarantee is structural and not a
    #     matter of how fast the stamp lands after the fork.
    session.writer = encodeWriterIdentity(currentWriterIdentity())
    updateSessionState(config, session, "running",
      message = "daemon-hosted build running")
    if userDaemonBuildExecutor == nil:
      let message =
        "daemon-hosted build executor is not registered in repro-daemon"
      updateSessionState(config, session, "unsupported", 64, message)
      emit(bekUnsupported, message, true, 64, "warning",
        "{\"fallbackAllowed\":true,\"deferredMilestone\":\"M4\"}")
      return
    let exitCode = userDaemonBuildExecutor(request, emit, cancelCheck)
    let workerNote = takeUserDaemonWorkerNote()
    if workerNote.len > 0:
      logLine(config.logPath, "build worker " & workerNote & " session=" &
        session.sessionId)
    let message =
      if exitCode == 0: "daemon-hosted build succeeded"
      else: "daemon-hosted build failed"
    updateSessionState(config, session,
      if exitCode == 0: "succeeded" else: "failed", exitCode, message)
    if not terminalSent:
      # The executor may have already emitted its own terminal event
      # carrying a domain-specific message (e.g. the Named-Targets M2
      # ``unknown_target`` / ``target_ambiguous`` translation in
      # ``installUserDaemonBuildExecutor``). When it has, we MUST NOT
      # tail the diagnostic with the generic "daemon-hosted build
      # failed" status line — the client-side stderr router would
      # surface that as a second, contradicting error line. Honour
      # ``terminalSent`` and skip the generic emit in that case;
      # the session state update above still records the outcome.
      emit(bekFinished, message, true, exitCode,
        if exitCode == 0: "info" else: "error",
        "{\"executor\":\"direct-build-entrypoint\"}")
    try: socket.closeIpcConn() except CatchableError: discard
    flushStatsAfterTerminal(config, session.sessionId)
    logLine(config.logPath, "build request finished session=" &
      session.sessionId & " exitCode=" & $exitCode)
  except CatchableError as err:
    let cancelled = cancelCheck()
    let kind = if cancelled: bekCancelled else: bekFinished
    let state = if cancelled: "cancelled" else: "failed"
    let code = if cancelled: 130 else: 1
    let message =
      if cancelled: "daemon-hosted build cancelled after client disconnect"
      else: "daemon-hosted build failed: " & err.msg
    updateSessionState(config, session, state, code, message)
    if not terminalSent:
      try:
        emit(kind, message, true, code,
          if cancelled: "warning" else: "error",
          "{\"executor\":\"direct-build-entrypoint\"}")
      except CatchableError:
        discard
    logLine(config.logPath, "build request " & state & " session=" &
      session.sessionId & " message=" & message)

proc handleBuildRequest(socket: IpcConn; config: UserDaemonConfig;
                        request: UserDaemonBuildRequest;
                        sessions: var seq[UserDaemonSession]) =
  var workerRequest = request
  # Sanitize immediately before the detached worker fork as defense in depth
  # for direct runtime callers that bypass the wire codec.
  workerRequest.environment =
    sanitizeUserDaemonRequestEnvironment(request.environment)
  let started = getTime()
  let sessionId =
    if request.runId.len > 0:
      request.runId
    else:
      $getCurrentProcessId() & "-" & $started.toUnix & "-" &
        $started.nanosecond
  let (projectRoot, projectRootSource) =
    resolveBuildRequestProjectRoot(request)
  var session = sessionStateAccepted(sessionId, projectRoot, started)
  sessions.add(session)
  writeSessionRecord(config, session)
  logLine(config.logPath, "build request accepted session=" & sessionId &
    " projectRoot=" & projectRoot &
    " projectRootSource=" & $projectRootSource &
    " attached=" & $request.attached &
    " cancelOnDisconnect=" & $request.cancelOnDisconnect)
  try:
    socket.writeFrame(udkBuildEvent, buildEventBody(nextBuildEvent(
      request.runId, sessionId, projectRoot, 1'u64, bekAccepted,
      "build request accepted by repro-daemon")))
    let delayMs = buildResponseDelayMs()
    if delayMs > 0 and request.attached and request.cancelOnDisconnect:
      if waitForBuildUnsupportedOrDisconnect(socket, delayMs):
        logLine(config.logPath, "build request cancelled session=" &
          sessionId & " reason=client-disconnect")
        updateSessionState(config, session, "cancelled", 130,
          "daemon-hosted build cancelled before scheduling")
        return
    # Dependency-Attribution MAC-2 — WARM THE PARENT, THEN FORK.
    #
    # This is deliberately on this side of the fork. The three in-memory build
    # caches the warm pass fills (lowered graph, provider-graph snapshot, tool
    # identity) are plain heap data, so the worker inherits them copy-on-write
    # at zero copy cost; filled after the fork they would be private to a
    # worker that is about to exit, and every later worker would start cold —
    # which is precisely today's behaviour and the ~5 ms this milestone is
    # about.
    #
    # WHY THIS IS NOT THE PREWARM THAT WAS DISABLED HERE. The earlier one ran
    # the whole speculative graph/provider-compile path, and the reasons it was
    # removed are addressed rather than sidestepped:
    #
    #   * DUPLICATION — the old pass re-ran provider inspection that the
    #     executor then ran authoritatively. This pass has no compute path: it
    #     decodes files that already exist and computes nothing the executor
    #     will compute. Where it succeeds, the executor's read is REPLACED by a
    #     memory hit, not repeated.
    #   * BEFORE ANY TERMINAL EVENT — the old pass could sit in heavyweight
    #     project inspection while an attached client waited. This one costs
    #     what the forked worker would otherwise have spent on the same reads,
    #     and in the steady state (the same project built again) it is a
    #     handful of `stat` calls: `prewarmDaemonParentCaches` returns `reused`
    #     without re-decoding when every warmed file is still stat-identical.
    #     `bekAccepted` has already been written above either way.
    #   * OUTLIVING A DISCONNECT — the old pass ran inside a DETACHED worker
    #     that kept going after its client was gone, which on CMake-generated
    #     projects meant multi-GB RSS with nobody listening. This runs in the
    #     daemon parent, which is long-lived by design and holds ONE project's
    #     warm set; there is no detached process to outlive anything, and the
    #     inherited copy is shared with every worker instead of duplicated per
    #     worker.
    #
    # Non-posix has no fork: `runBuildRequestWorker` runs in this process, so
    # the caches warm naturally across requests and a prewarm would be pure
    # cost.
    when defined(posix):
      let prewarmLine = runUserDaemonParentPrewarm(workerRequest)
      if prewarmLine.len > 0:
        logLine(config.logPath, prewarmLine & " session=" & sessionId)
      spawnDetachedDaemonWorker(config, "build worker", sessionId, socket):
        runBuildRequestWorker(socket, config, workerRequest, session)
    else:
      runBuildRequestWorker(socket, config, workerRequest, session)
  finally:
    sessions.removeSession(sessionId)

proc watchStopRequested(config: UserDaemonConfig; sessionId: string): bool =
  fileExists(sessionStopRequestPath(config, sessionId))

proc writeWatchStopRequest(config: UserDaemonConfig; sessionId, reason: string) =
  createDir(sessionRecordsDir(config))
  writeFile(sessionStopRequestPath(config, sessionId), reason & "\n")

proc nextWatchEvent(runId, sessionId, projectRoot: string;
                    eventId: uint64;
                    kind: UserDaemonBuildEventKind;
                    message: string;
                    terminal = false;
                    exitCode = 0;
                    severity = "info";
                    payloadJson = ""): UserDaemonBuildEvent =
  result = nextBuildEvent(runId, sessionId, projectRoot, eventId, kind,
    message, terminal = terminal, exitCode = exitCode, severity = severity,
    payloadJson = payloadJson)
  result.command = "watch"

proc runWatchRequestWorker(socket: IpcConn; config: UserDaemonConfig;
                           request: UserDaemonWatchRequest;
                           session: var UserDaemonSession;
                           streamToSocket: bool) =
  var eventId = 1'u64
  var terminalSent = false
  let sessionId = session.sessionId
  let projectRoot = session.projectRoot
  let sessionRef = new(UserDaemonSession)
  sessionRef[] = session
  proc emitEvent(kind: UserDaemonBuildEventKind; message: string;
                 terminal: bool; exitCode: int; severity: string;
                 payloadJson: string; watchedPaths: seq[string];
                 lastResult: string) =
    inc eventId
    if watchedPaths.len > 0:
      sessionRef[].watchedPaths = watchedPaths
    if lastResult.len > 0:
      sessionRef[].lastResult = lastResult
    if terminal:
      terminalSent = true
    elif sessionRef[].state == "running":
      sessionRef[].state = "watching"
    if message.len > 0:
      sessionRef[].message = message
    let event = nextWatchEvent(request.runId, sessionId, projectRoot, eventId,
      kind, message, terminal = terminal, exitCode = exitCode,
      severity = severity, payloadJson = payloadJson)
    if terminal:
      # Attach streams must observe the terminal event before the session
      # record moves to a terminal state, otherwise they can close early.
      appendWatchEventRecord(config, sessionId, event)
      writeSessionRecord(config, sessionRef[])
    else:
      writeSessionRecord(config, sessionRef[])
      appendWatchEventRecord(config, sessionId, event)
    if streamToSocket:
      socket.writeFrame(udkWatchEvent, buildEventBody(event))

  proc cancelCheck(): bool =
    if watchStopRequested(config, sessionId):
      return true
    streamToSocket and request.cancelOnDisconnect and
      socket.clientDisconnected()

  try:
    # Same rule as the build worker: the worker owns `running`, and the stamp
    # rides the same write that leaves `accepted`. See that comment.
    sessionRef[].writer = encodeWriterIdentity(currentWriterIdentity())
    updateSessionState(config, sessionRef[], "running",
      message = "daemon-hosted watch running")
    if userDaemonWatchExecutor == nil:
      let message =
        "daemon-hosted watch executor is not registered in repro-daemon"
      updateSessionState(config, sessionRef[], "unsupported", 64, message)
      emitEvent(bekUnsupported, message, true, 64, "warning",
        "{\"fallbackAllowed\":true,\"deferredMilestone\":\"M5\"}", @[],
        "unsupported")
      return
    let exitCode = userDaemonWatchExecutor(request, emitEvent, cancelCheck)
    let stopped = watchStopRequested(config, sessionId) or
      (streamToSocket and request.cancelOnDisconnect and socket.clientDisconnected())
    let state =
      if stopped: "stopped"
      elif exitCode == 0: "succeeded"
      else: "failed"
    let message =
      if stopped: "daemon-hosted watch stopped"
      elif exitCode == 0: "daemon-hosted watch finished"
      else: "daemon-hosted watch failed"
    if not terminalSent:
      setSessionState(sessionRef[], state, exitCode, message)
      # Mirror the Named-Targets M2 ``runBuildRequestWorker`` guard: the
      # executor may have already emitted its own terminal event (e.g.
      # the M3 ``unknown_target`` / ``target_ambiguous`` translation in
      # ``installUserDaemonWatchExecutor``). When it has, tailing a
      # generic "daemon-hosted watch failed" line would surface as a
      # second, contradicting error on the client. The session state
      # update above still records the outcome.
      emitEvent(if stopped: bekCancelled else: bekFinished, message, true,
        exitCode, if exitCode == 0: "info" else: "error",
        "{\"executor\":\"direct-watch-entrypoint\"}",
        sessionRef[].watchedPaths,
        "exitCode=" & $exitCode)
    else:
      updateSessionState(config, sessionRef[], state, exitCode, message)
    try: socket.closeIpcConn() except CatchableError: discard
    flushStatsAfterTerminal(config, sessionRef[].sessionId)
    logLine(config.logPath, "watch request finished session=" &
      sessionRef[].sessionId & " exitCode=" & $exitCode)
  except CatchableError as err:
    let cancelled = cancelCheck()
    let kind = if cancelled: bekCancelled else: bekFinished
    let state = if cancelled: "stopped" else: "failed"
    let code = if cancelled: 130 else: 1
    let message =
      if cancelled: "daemon-hosted watch stopped"
      else: "daemon-hosted watch failed: " & err.msg
    if not terminalSent:
      setSessionState(sessionRef[], state, code, message)
      try:
        emitEvent(kind, message, true, code,
          if cancelled: "warning" else: "error",
          "{\"executor\":\"direct-watch-entrypoint\"}",
          sessionRef[].watchedPaths,
          "exitCode=" & $code)
      except CatchableError:
        writeSessionRecord(config, sessionRef[])
        discard
    else:
      updateSessionState(config, sessionRef[], state, code, message)
    logLine(config.logPath, "watch request " & state & " session=" &
      sessionRef[].sessionId & " message=" & message)

proc streamWatchSession(socket: IpcConn; config: UserDaemonConfig;
                        sessionId: string; stopOnDisconnect: bool) =
  var offset = 0'i64
  var sawAny = false
  while true:
    for event in readWatchEventsFrom(config, sessionId, offset):
      sawAny = true
      socket.writeFrame(udkWatchEvent, buildEventBody(event))
      if event.terminal:
        return
    let session = latestSessionRecord(config, sessionId)
    if session.sessionId.len == 0 or session.state == "missing":
      socket.writeFrame(udkError, errorBody("watch session not found: " &
        sessionId))
      return
    if session.state notin ["accepted", "running", "watching", "idle",
        "cancelling"] and sawAny:
      return
    if stopOnDisconnect and socket.clientDisconnected():
      writeWatchStopRequest(config, sessionId, "attached client disconnected")
      return
    sleep(50)

proc handleWatchStart(socket: IpcConn; config: UserDaemonConfig;
                      request: UserDaemonWatchRequest;
                      sessions: var seq[UserDaemonSession]) =
  var workerRequest = request
  # Keep the build/watch spawn boundaries identical. Detached watch workers
  # must not receive a private launch marker through an in-process request.
  workerRequest.environment =
    sanitizeUserDaemonRequestEnvironment(request.environment)
  let started = getTime()
  let sessionId =
    if request.runId.len > 0:
      request.runId
    else:
      "watch-" & $getCurrentProcessId() & "-" & $started.toUnix & "-" &
        $started.nanosecond
  let projectRoot =
    if request.projectRoot.len > 0:
      request.projectRoot
    else:
      request.workingDir
  var session = watchSessionStateAccepted(sessionId, projectRoot, started,
    request)
  sessions.add(session)
  writeSessionRecord(config, session)
  try: removeFile(sessionStopRequestPath(config, sessionId)) except OSError: discard
  logLine(config.logPath, "watch request accepted session=" & sessionId &
    " projectRoot=" & projectRoot & " attached=" & $request.attached &
    " detached=" & $request.detached)
  let accepted = nextWatchEvent(request.runId, sessionId, projectRoot, 1'u64,
    bekAccepted, "watch request accepted by repro-daemon",
    payloadJson = "{\"detached\":" & $request.detached & "}")
  appendWatchEventRecord(config, sessionId, accepted)
  socket.writeFrame(udkWatchEvent, buildEventBody(accepted))
  when defined(posix):
    spawnDetachedDaemonWorker(config, "watch worker", sessionId, socket):
      runWatchRequestWorker(socket, config, workerRequest, session,
        streamToSocket = request.attached and not request.detached)
  else:
    runWatchRequestWorker(socket, config, workerRequest, session,
      streamToSocket = request.attached and not request.detached)
  sessions.removeSession(sessionId)

proc handleWatchAttach(socket: IpcConn; config: UserDaemonConfig;
                       request: UserDaemonWatchSessionRequest) =
  ## ATTACH DELIBERATELY DOES NOT STAMP ITSELF AS THE WRITER, and this is the
  ## one place the `accepted`/`running` rule does not apply -- attach joins a
  ## session someone else created, so it has no `accepted` of its own.
  ##
  ## The rule the field encodes is "name the process whose death orphans the
  ## record", and an attacher is a READER: it streams events a worker
  ## produces and its departure ends nothing. `streamWatchSession` never
  ## writes the session record at all, so the identity stays the worker's by
  ## construction rather than by intent.
  ##
  ## Both alternatives are worse, in opposite directions. If attach stamped
  ## itself, the original worker's death would stop being noticed -- a live
  ## attacher would keep an orphaned session looking healthy forever, which
  ## is the bug this whole change exists to remove. And an attacher that
  ## died while the worker ran would make a LIVE session reclaimable, which
  ## is the direction that corrupts builds.
  ##
  ## The residual oddity is accepted knowingly: if a worker dies while an
  ## attacher is streaming, the record is reclaimed `abandoned` under the
  ## attacher. That is honest -- the work really has stopped -- and it costs
  ## a confusing stream rather than a wrong build.
  if request.sessionId.len == 0:
    socket.writeFrame(udkError, errorBody("watch attach requires a session id"))
    return
  when defined(posix):
    spawnDetachedDaemonWorker(config, "watch attach", request.sessionId, socket):
      streamWatchSession(socket, config, request.sessionId,
        request.cancelOnDisconnect)
  else:
    streamWatchSession(socket, config, request.sessionId,
      request.cancelOnDisconnect)

proc handleWatchStop(socket: IpcConn; config: UserDaemonConfig;
                     request: UserDaemonWatchSessionRequest) =
  if request.sessionId.len == 0:
    socket.writeFrame(udkError, errorBody("watch stop requires a session id"))
    return
  let session = latestSessionRecord(config, request.sessionId)
  if session.sessionId.len == 0 or session.state == "missing":
    socket.writeFrame(udkError, errorBody("watch session not found: " &
      request.sessionId))
    return
  writeWatchStopRequest(config, request.sessionId, "stop requested")
  let event = nextWatchEvent(request.sessionId, request.sessionId,
    session.projectRoot, 1'u64, bekCancelled,
    "watch stop requested", terminal = false,
    payloadJson = "{\"stopRequested\":true}")
  appendWatchEventRecord(config, request.sessionId, event)
  socket.writeFrame(udkWatchEvent, buildEventBody(event))

proc handleWatchDetach(socket: IpcConn; config: UserDaemonConfig;
                       request: UserDaemonWatchSessionRequest) =
  if request.sessionId.len == 0:
    socket.writeFrame(udkError, errorBody("watch detach requires a session id"))
    return
  let session = latestSessionRecord(config, request.sessionId)
  if session.sessionId.len == 0 or session.state == "missing":
    socket.writeFrame(udkError, errorBody("watch session not found: " &
      request.sessionId))
    return
  let event = nextWatchEvent(request.sessionId, request.sessionId,
    session.projectRoot, 1'u64, bekDiagnostic,
    "watch client detached; session remains running", terminal = false,
    payloadJson = "{\"detached\":true}")
  appendWatchEventRecord(config, request.sessionId, event)
  socket.writeFrame(udkWatchEvent, buildEventBody(event))

proc handleClient(socket: IpcConn; config: UserDaemonConfig; startedAt: Time;
                  generation: string; shuttingDown: var bool;
                  sessions: var seq[UserDaemonSession];
                  instances: var ServiceInstanceRegistry;
                  devRestart: DevRestartState) =
  # Both request-side reads are bounded: the accept loop is single-threaded,
  # so a client that connects and then goes quiet must not be able to starve
  # every other client. See ``ServerRequestReadTimeoutMs``.
  let helloFrame = socket.readFrame(ServerRequestReadTimeoutMs)
  if helloFrame.kind != udkHello:
    socket.writeFrame(udkError, errorBody(
      "first user-daemon message must be hello, got " & $helloFrame.kind))
    return
  if not handleHello(socket, config, generation, helloFrame.body, devRestart):
    return

  let frame = socket.readFrame(ServerRequestReadTimeoutMs)
  case frame.kind
  of udkStatus:
    socket.writeFrame(udkStatusResponse,
      statusBody(statusFor(config, startedAt, generation,
        activeSessionTallyFor(config), devRestart)))
  of udkShutdown:
    for session in loadSessionRecords(config):
      if session.mode == "watch" and session.state in ["accepted", "running",
          "watching", "idle", "cancelling"]:
        writeWatchStopRequest(config, session.sessionId,
          "daemon shutdown requested")
    shuttingDown = true
    socket.writeFrame(udkShutdownAck)
    logLine(config.logPath, "shutdown requested")
  of udkSessions:
    socket.writeFrame(udkSessionsResponse,
      sessionsBody(loadSessionRecords(config)))
  of udkWatchListRequest:
    var watchSessions: seq[UserDaemonSession] = @[]
    for session in loadSessionRecords(config):
      if session.mode == "watch":
        watchSessions.add(session)
    socket.writeFrame(udkSessionsResponse, sessionsBody(watchSessions))
  of udkBuildRequest:
    if devRestart.restartPending:
      socket.writeFrame(udkError, errorBody(
        "repro-daemon development restart is in progress; retry by run id " &
        "after reconnect where supported"))
      return
    let request = parseBuildRequestBody(frame.body)
    # Before the request is accepted, and before anything (the parent
    # prewarm included) reads its project: a request sent for another
    # engine is declined here, with no session record, because no session
    # ever ran. See `foreignEngineVerdict` for why only the daemon can do it.
    let verdict = foreignEngineVerdict(config, request.publicCliPath,
      devRestart.runningHash)
    if verdict.decline:
      logLine(config.logPath, "build request declined reason=engine-mismatch" &
        " request-image=" & request.publicCliPath & " request-hash=" &
        verdict.requestImageHash & " running-hash=" & verdict.daemonImageHash)
      socket.writeFrame(udkBuildEvent, buildEventBody(
        foreignEngineDeclineEvent("build", request.runId, request.projectRoot,
          request.publicCliPath, devRestart.runningImagePath, verdict)))
      return
    handleBuildRequest(socket, config, request, sessions)
  of udkWatchStartRequest:
    if devRestart.restartPending:
      socket.writeFrame(udkError, errorBody(
        "repro-daemon development restart is in progress; retry by run id " &
        "after reconnect where supported"))
      return
    let request = parseWatchRequestBody(frame.body)
    # Same decline as a build request, for the same reason: every watch
    # cycle is a build run by this daemon's engine.
    let verdict = foreignEngineVerdict(config, request.publicCliPath,
      devRestart.runningHash)
    if verdict.decline:
      logLine(config.logPath, "watch request declined reason=engine-mismatch" &
        " request-image=" & request.publicCliPath & " request-hash=" &
        verdict.requestImageHash & " running-hash=" & verdict.daemonImageHash)
      socket.writeFrame(udkWatchEvent, buildEventBody(
        foreignEngineDeclineEvent("watch", request.runId, request.projectRoot,
          request.publicCliPath, devRestart.runningImagePath, verdict)))
      return
    handleWatchStart(socket, config, request, sessions)
  of udkWatchAttachRequest:
    handleWatchAttach(socket, config, parseWatchSessionRequestBody(frame.body))
  of udkWatchStopRequest:
    handleWatchStop(socket, config, parseWatchSessionRequestBody(frame.body))
  of udkWatchDetachRequest:
    handleWatchDetach(socket, config, parseWatchSessionRequestBody(frame.body))
  of udkSubstituteRequest:
    if userDaemonSubstituteExecutor == nil:
      socket.writeFrame(udkError, errorBody(
        "daemon-hosted substitute executor is not registered in " &
        "repro-daemon (A2.5 P6 wiring missing)"))
      return
    let request =
      try:
        parseSubstituteRequestBody(frame.body)
      except CatchableError as err:
        socket.writeFrame(udkError, errorBody(
          "malformed udkSubstituteRequest body: " & err.msg))
        return
    let response =
      try:
        userDaemonSubstituteExecutor(request)
      except CatchableError as err:
        socket.writeFrame(udkError, errorBody(
          "substitute executor raised: " & err.msg))
        return
    socket.writeFrame(udkSubstituteResponse, substituteResponseBody(response))
    logLine(config.logPath, "substitute request handled roots=" &
      $request.rootEntryKeyHex.len & " endpoint=" & request.endpoint.baseUrl &
      " ok=" & $response.ok & " plan=" & $response.plan.len &
      " realized=" & $response.realizedCasPaths.len &
      " bytes=" & $response.totalBytesFetched)
  of udkLeaseRenew:
    let request =
      try:
        parseLeaseRenewRequestBody(frame.body)
      except CatchableError as err:
        socket.writeFrame(udkError, errorBody(
          "malformed udkLeaseRenew body: " & err.msg))
        return
    handleLeaseRenew(socket, config, request)
  of udkServiceConverge:
    let request =
      try:
        parseServiceConvergeRequestBody(frame.body)
      except CatchableError as err:
        socket.writeFrame(udkError, errorBody(
          "malformed udkServiceConverge body: " & err.msg))
        return
    handleServiceConverge(socket, config, instances, request)
  of udkServiceRelease:
    let request =
      try:
        parseServiceReleaseRequestBody(frame.body)
      except CatchableError as err:
        socket.writeFrame(udkError, errorBody(
          "malformed udkServiceRelease body: " & err.msg))
        return
    handleServiceRelease(socket, config, instances, request)
  of udkLeaseReapProviders:
    let request =
      try:
        parseLeaseReapProvidersRequestBody(frame.body)
      except CatchableError as err:
        socket.writeFrame(udkError, errorBody(
          "malformed udkLeaseReapProviders body: " & err.msg))
        return
    handleLeaseReapProviders(socket, config, request)
  else:
    socket.writeFrame(udkError, errorBody(
      "unsupported user-daemon message in lifecycle server: " &
      $frame.kind))

proc devRestartPollIntervalMs(): int64 =
  try:
    max(50, parseInt(getEnv("REPRO_DAEMON_DEV_RESTART_POLL_MS", "250")))
  except ValueError:
    250

proc devRestartStableMs(): int64 =
  try:
    max(50, parseInt(getEnv("REPRO_DAEMON_DEV_RESTART_STABLE_MS", "750")))
  except ValueError:
    750

proc devRestartDeferralLogWindowMs*(): int64 =
  ## How often a CONTINUING deferral may restate itself.
  ##
  ## 60 s, against a 250 ms poll, so a permanently deferred restart costs
  ## about 60 lines an hour instead of 14,400.
  try:
    max(1_000, parseInt(getEnv("REPRO_DAEMON_DEFERRAL_LOG_MS", "60000")))
  except ValueError:
    60_000

proc deferralLogDue*(state: var DevRestartState; nowMs: int64;
                     windowMs: int64): bool =
  ## Should this deferral poll emit a line? Maintains the window state.
  ##
  ## WHAT THIS REPLACED, AND AN UNEXPLAINED FLOOD IT DOES NOT EXPLAIN. The
  ## previous guard logged only when the active count CHANGED. It is present
  ## in the history, correct in isolation, and a developer machine still
  ## accumulated 949,394 `dev restart deferred` lines -- 93% of an 82 MB
  ## daemon log.
  ##
  ## Do not repeat either of the two stories that were offered for that and
  ## withdrawn; both were checked and are false.
  ##
  ## * NOT oscillation. Collapsing consecutive runs gives ONE run of 948,900
  ##   identical consecutive `active-sessions=4` lines. A change-detector
  ##   would have suppressed 948,899 of them.
  ## * NOT competing daemon generations. The flood is confined to
  ##   2026-09-05..08 at ~280,000 lines a day, and the log records ZERO
  ##   daemon starts on the 5th, 6th and 7th. It was one long-lived process.
  ##
  ## What the evidence does say, and where it stops: ~3.2 lines a second is
  ## the 250 ms poll cadence, and it EXCEEDS what `deferredUntilMs` alone
  ## should allow (one pass per 750 ms), so during that window neither the
  ## change guard nor the stability throttle was taking effect -- consistent
  ## with `DevRestartState` mutations not persisting across polls in that
  ## process. No commit touched this library in that window, so it was not a
  ## code change, and the mechanism is NOT identified. Before and after,
  ## including now, the rate is 8-518 lines a day.
  ##
  ## SO BE HONEST ABOUT WHAT THIS WINDOW BUYS. It is a strictly tighter bound
  ## than change-detection: it holds under oscillation, and it holds when
  ## several writers share a log, neither of which a per-generation memory
  ## survives. It does NOT help if the real cause is state that fails to
  ## persist, because it keeps its own state the same way. That possibility
  ## is open and is the more useful finding if it is ever confirmed.
  ##
  ## Entry into deferral always logs -- that transition is the event worth
  ## seeing -- and a continuing deferral restates itself once per window
  ## carrying the number of polls it stayed quiet for, so the suppression is
  ## visible in the log rather than inferred from its absence.
  ##
  ## NOT ROTATION. Rotation would have bounded the file and hidden the cause:
  ## the 82 MB was the symptom that made 19 session records stuck in
  ## `state=running` findable at all. (The log is now also bounded by
  ## rotation, `appendUserDaemonLogLine`; that bounds the file, and a flood
  ## would still evict everything else from it, so it does not replace this.)
  if state.deferredLogAtMs == 0 or nowMs - state.deferredLogAtMs >= windowMs:
    state.deferredLogAtMs = nowMs
    return true
  false

proc restartCandidateReady(config: UserDaemonConfig;
                           state: var DevRestartState): bool =
  if not state.enabled or state.sourceImagePath.len == 0 or
      not fileExists(state.sourceImagePath):
    return false
  let nowMs = nowUnixMs()
  if nowMs - state.lastCheckMs < devRestartPollIntervalMs():
    return false
  state.lastCheckMs = nowMs
  # The digest is the decision, but a ``stat`` is the gate in front of it.
  # An unchanged (device, inode, size, mtime-ns) identity means the bytes we
  # already digested are still the bytes on disk, so re-reading ~28 MB to
  # learn that again is pure waste — and at the 250 ms poll cadence it is
  # waste paid ~3x a second for the entire lifetime of an IDLE daemon.
  # An empty stamp means "unknown"; that falls through and digests, so a
  # stat failure degrades to the old always-digest behaviour rather than
  # silently disabling dev restart.
  let stamp = fileIdentityStamp(state.sourceImagePath)
  if stamp.len == 0 or stamp != state.sourceStamp:
    state.sourceStamp = stamp
    let currentHash = imageDigestHex(state.sourceImagePath)
    if currentHash.len == 0 or currentHash == state.runningHash:
      state.candidateHash = ""
      state.candidateSinceMs = 0
      return false
    if currentHash != state.candidateHash:
      state.candidateHash = currentHash
      state.candidateSinceMs = nowMs
      logLine(config.logPath, "dev restart candidate source=" &
        state.sourceImagePath & " hash=" & currentHash)
      return false
  elif state.candidateHash.len == 0:
    # Identity unchanged and no restart pending: the steady state. This is
    # the branch an idle dev daemon takes forever, and it costs one stat.
    return false
  # Either the digest just confirmed the pending candidate, or the source
  # has stopped moving while a candidate waits out the stability window.
  # Both cases fall through to the same settle-then-restart gate as before.
  if nowMs - state.candidateSinceMs < devRestartStableMs():
    return false
  if nowMs < state.deferredUntilMs:
    return false
  let active = activeSessionTallyFor(config)
  if active > 0:
    # Reconciliation reads only believed-active records, rather than every
    # historical session. Dead writers and inactive legacy records can now
    # clear a deferral; live sessions may remain active for a long time.
    # Re-ask on the stability cadence, and bound repeated diagnostics so a
    # persistent deferral stays visible without flooding the log.
    state.deferredUntilMs = nowMs + devRestartStableMs()
    if state.deferralLogDue(nowMs, devRestartDeferralLogWindowMs()):
      let suppressed = state.deferralPollsSuppressed
      state.deferralPollsSuppressed = 0
      if suppressed == 0:
        logLine(config.logPath,
          "dev restart deferred active-sessions=" & $active)
      else:
        logLine(config.logPath,
          "dev restart still deferred active-sessions=" & $active &
            " (" & $suppressed & " polls suppressed)")
    else:
      inc state.deferralPollsSuppressed
    return false
  if state.deferredLogAtMs != 0:
    # Log the RESOLUTION as well. Without it a bounded log shows a deferral
    # starting and never ending, which reads worse than the flood did: the
    # reader cannot tell an ongoing deferral from one that cleared.
    logLine(config.logPath, "dev restart no longer deferred" &
      (if state.deferralPollsSuppressed > 0:
         " (" & $state.deferralPollsSuppressed & " polls suppressed)"
       else: ""))
  state.deferredLogAtMs = 0
  state.deferralPollsSuppressed = 0
  true

proc daemonProcessArgs(config: UserDaemonConfig): seq[string]
proc launchWithFork(exe: string; config: UserDaemonConfig)

proc performDevSelfRestart(config: UserDaemonConfig;
                           listener: var IpcListener;
                           daemonLock: var UserDaemonLock;
                           state: var DevRestartState): bool =
  state.restartPending = true
  discard flushStatsObservations()
  let runId = newRestartRunId()
  let staged = stageDevDaemonBinary(state.sourceImagePath, config, runId)
  var nextConfig = config
  nextConfig.daemonExe = staged.imagePath
  nextConfig.sourceExe = state.sourceImagePath
  nextConfig.stagedGenerationDir = staged.generationDir
  nextConfig.previousStagedGenerationDir = state.stagedGenerationDir
  nextConfig.restartRunId = runId
  logLine(config.logPath, "dev restart launching source=" &
    state.sourceImagePath & " running=" & staged.imagePath & " runId=" &
    runId)
  closeIpcListener(listener)
  removeEndpointFiles(config)
  releaseUserDaemonLock(daemonLock)
  # Use the same launchWithFork the initial launch uses (fork + setsid +
  # dup2 stdio onto /dev/null and the log file + close inherited fds +
  # execv). osproc.startProcess with poDaemon on POSIX leaves the child
  # with stdio pipes that the parent immediately closes via
  # process.close(); the new daemon then dies of SIGPIPE on the first
  # write to stderr — the listener never binds, the test polls
  # 'daemon status' for 20 s, and the restart appears to time out.
  # On Windows the same guarantee comes from ``spawnWithOwnStdio``: the new
  # daemon inherits only NUL and its log, never a handle of this process.
  # Both start it in ``daemonWorkingDirectory``, as the first launch did.
  when defined(posix):
    launchWithFork(staged.imagePath, nextConfig)
  else:
    let pid = spawnWithOwnStdio(staged.imagePath,
      daemonProcessArgs(nextConfig), [], inheritEnvironment = true,
      logPath = "",
      workingDir = daemonWorkingDirectory(nextConfig))
    logLine(config.logPath, "dev restart launched backend=windows-handle-list " &
      "pid=" & $pid)
  logLine(config.logPath, "dev restart old process exiting runId=" & runId)
  true

type
  LeaseReapTickState = object
    ## Per-daemon-instance reap-tick bookkeeping, and specifically the
    ## DE-DUPLICATION of what the tick reports.
    ##
    ## The tick runs every 30 s for the daemon's whole life. A condition it
    ## cannot fix by retrying — a record whose attrs marshaller this process
    ## does not link, a provider it cannot reach — is therefore reported on
    ## every single tick unless something stops it, and a condition that
    ## persists is exactly the kind that does not get fixed quickly. The live
    ## daemon on this workstation logged the SAME sentence 141,895 times over
    ## 60 days (62 MB of a 385 MB unrotated log). A message repeated that many
    ## times is not a louder message, it is a quieter one: it buries every
    ## other line in the log and trains its readers to skip it.
    ##
    ## So each distinct finding is logged ONCE per daemon run. A restart
    ## re-reports (the state is per-instance, deliberately: a fresh daemon's
    ## log should stand on its own), and a NEW finding is always reported.
    ##
    ## What counts as "distinct" is ``leaseReapFindings``' signature, NOT the
    ## sentence logged: see its docstring for why keying on the sentence would
    ## bring the flood back, and grow this set for the daemon's whole life, for
    ## any failure whose message is a provider's rather than ours.
    reported: HashSet[string]

proc initLeaseReapTickState(): LeaseReapTickState =
  LeaseReapTickState(reported: initHashSet[string]())

proc reportOnce(state: var LeaseReapTickState; config: UserDaemonConfig;
                signature, message: string) =
  if state.reported.containsOrIncl(signature):
    return
  logLine(config.logPath, message)

proc runScopedLeaseReapTick(config: UserDaemonConfig;
                            state: var LeaseReapTickState;
                            instances: ptr ServiceInstanceRegistry) =
  ## Ephemeral-State-Leases L4 (§4.2): run ONE wall-clock reap sweep against
  ## this daemon's scoped lease store. Best-effort — a reap must never wedge
  ## the event loop or crash the daemon, so all errors are logged + swallowed.
  ## The store is on disk, so this is correct on the FIRST tick after a
  ## restart (an expired record left by a prior instance is reaped here).
  ##
  ## A record the sweep could not reap comes back as a FINDING rather than as
  ## a raise — see ``reapOnce``'s "one unhandleable record must not abort the
  ## sweep". So does a record the sweep could not even DECODE: the listing
  ## (``scanStateRecords``) reports a newer repro's record as foreign and
  ## quarantines a corrupt one instead of raising, and those come back through
  ## ``leaseReapFindings`` too — reported even on a tick that reaped nothing,
  ## since the findings loop below does not depend on ``reapedCount``.
  ## ``outcome.raised`` is therefore set only by a WHOLE-SWEEP failure (an
  ## unreadable store root), which is equally unfixable-by-retrying and so is
  ## deduplicated on the same terms.
  ##
  ## Shared-Development-Services L7 (§4.5): "an instance is reaped when its
  ## last lease lapses". A shared service INSTANCE record lives in THIS store
  ## — one root, deliberately, see ``serviceInstanceStoreRoot`` — so this
  ## tick is where that clause is honoured. The real instance-reap handler is
  ## installed for the duration of the sweep and the DECLINING one
  ## (``repro_resources/service_registry``'s) restored afterwards, so nothing
  ## outside this tick can remove an instance record while its process is
  ## still running. The handler is scoped to the sweep rather than installed
  ## once at startup because it has to reach THIS daemon's registry object:
  ## stopping the process without dropping the in-memory entry would leave
  ## the next ``repro up`` attaching a consumer to a process this tick had
  ## just killed.
  ##
  ## THE VERDICT IS RECORDED BY THE SWEEP, NOT BY THIS LOGGING.
  ## ``runAndRecordLeaseReapTick`` runs the sweep and persists its verdict in
  ## one step and returns only what to log, which is what makes a reaper that
  ## is not working visible to ``repro health``. The de-duplication above is
  ## precisely why that record is not optional: after the first report a
  ## permanently stuck reaper says NOTHING at all, so the log stops being
  ## evidence of its own state.
  ##
  ## Everything in the inner ``try`` is therefore best-effort reporting around
  ## an outcome already decided and already on disk. Each logging call is
  ## individually guarded, including the ``reportOnce`` calls — ``reportOnce``
  ## writes to the log too, so the arm that reports a failure can fail the
  ## same way, and this proc is called from the startup sweep and from the
  ## event loop, neither of which wraps it. An escape there would stop the
  ## daemon over a log write.
  ##
  ## THE OUTER ``try`` CARRIES ONLY A ``finally``, which is the whole reason
  ## the sweep can sit inside it: it uninstalls the instance handler whatever
  ## happens, and it catches NOTHING, so a whole-sweep raise propagates
  ## exactly as it does without the handler scoping. The sweep is not made
  ## best-effort by being lexically inside a ``try``.
  installServiceInstanceReapHandler(instances)
  try:
    let outcome = runAndRecordLeaseReapTick(daemonLeaseScope(config),
      overrideRoot = config.leaseStoreRoot)
    try:
      if outcome.raised:
        reportOnce(state, config, "sweep\x00" & outcome.failure,
          "lease reap tick error (reported once per daemon run): " &
            outcome.failure)
      else:
        if outcome.reapedCount > 0:
          logLine(config.logPath, "lease reap tick reaped=" &
            $outcome.reapedCount & " kept=" & $outcome.keptCount &
            " unreapable=" & $outcome.failedCount & " scope=" &
            (if config.systemScope: "system" else: "user"))
        for finding in outcome.findings:
          reportOnce(state, config, finding.signature,
            "lease reap tick (reported once per daemon run) " & finding.line)
      if outcome.healthWriteError.len > 0:
        reportOnce(state, config, "health-write\x00" & outcome.healthWriteError,
          "lease reap tick health not recorded (reported once per daemon run): " &
            outcome.healthWriteError)
    except CatchableError:
      # Nowhere left to report a reporting failure, and nothing depends on it:
      # the tick's verdict is already written, and it is the thing
      # ``repro health`` actually reads.
      discard
  finally:
    uninstallServiceInstanceReapHandler()

proc runUserDaemonForeground*(initialConfig: UserDaemonConfig): int =
  # A daemon started by hand may have been given relative flags; its dev
  # self-restart starts the successor in the state directory, where they
  # would mean something else.
  var config = withAnchoredDaemonPaths(initialConfig)
  config.processOwnerToken = getEnv(ReproTestRunnerOwnerTokenEnv)
  # The OS keeps the exec-time environment used by the test runner to identify
  # this process. Remove the live entry before handling requests so daemon
  # actions cannot inherit a runner-private implementation detail. Dev
  # self-restarts use only the private config copy above.
  if existsEnv(ReproTestRunnerOwnerTokenEnv):
    delEnv(ReproTestRunnerOwnerTokenEnv)
  # A dev-mode daemon runs a staged COPY of its source image
  # (`stageDevDaemonBinary`). Reprobuild's sources are found relative to the
  # image -- the checkout it runs from, or `<prefix>/share/repro/source`
  # beside an installed one -- so resolve them from the source image, not
  # from the copy under `<state>/dev-bin`. Before any request is served.
  if config.devMode and config.sourceExe.len > 0:
    declareRunningImageSource(absoluteNormalized(config.sourceExe))

  # Named-pipe endpoints live under the kernel ``\\.\pipe\`` namespace
  # which is NOT a filesystem directory; ``createDir`` on its
  # parent would raise. Filesystem endpoints (AF_UNIX socket paths)
  # still need their parent directory provisioned.
  if endpointKindOf(config.endpoint) == ekUnixSocket:
    createDir(parentDir(config.endpoint))
  createDir(config.stateDir)
  createDir(parentDir(config.logPath))
  var daemonLock = acquireUserDaemonLock(config)
  defer:
    releaseUserDaemonLock(daemonLock)
  # L4/L5 (§4.2): close the reap transport's pooled provider sessions on the
  # way out, and forget the registered artifacts. The pool holds a live
  # provider CHILD per artifact the tick reaped over, so a daemon that exited
  # without this would orphan every one of them — and the registration is
  # in-memory anyway, so a successor re-learns it from the records it sweeps
  # or from the next consuming `repro run`.
  defer:
    try: clearLeaseReapProviders() except CatchableError: discard

  let restartChild =
    config.devMode and config.previousStagedGenerationDir.len > 0
  if not restartChild:
    try:
      let existing = queryUserDaemonStatus(config.endpoint)
      if existing.running:
        stderr.writeLine("repro-daemon: already running at " &
          config.endpoint)
        return 0
    except CatchableError:
      discard

  if not restartChild:
    discard cleanupStaleUserDaemonDiscovery(config)
  removeEndpointFiles(config)
  var listener = bindIpcListener(config.endpoint)
  var selfRestarting = false
  defer:
    # The listener-defer runs BEFORE the daemonLock-defer (LIFO).
    # Closing the listener flips ``endpointAcceptsConnections`` to
    # false — the visible signal ``requestUserDaemonShutdown``
    # polls on. The daemonLock-defer then releases the lockfile
    # handle and unlinks ``.repro-daemon.lock``.
    closeIpcListener(listener)
    if not selfRestarting:
      removeEndpointFiles(config)
      logLine(config.logPath, "stopped")

  let startedAt = getTime()
  let generation = generationFor(startedAt)
  var devRestart = initDevRestartState(config)
  # Daemon startup: reclaim records whose writers died while no daemon was
  # running to notice. `primeActiveSessionTally` also reclaims, but only when
  # something first asks for the tally; doing it here means a daemon that is
  # never asked still clears them, and means the startup log below reports a
  # true active count.
  let reclaimed = reclaimAbandonedSessions(config)
  if reclaimed > 0:
    logLine(config.logPath,
      "reclaimed abandoned sessions count=" & $reclaimed)
  # Retention of dev staged image copies. Here, not earlier: the lock is held
  # and no other daemon answered on this endpoint, so no generation under
  # `dev-bin` but our own can be serving. See `sweepStaleDevStagedGenerations`.
  discard sweepStaleDevStagedGenerations(config)
  var sessions: seq[UserDaemonSession] = @[]
  # Shared-Development-Services L7 (§4.5): "A daemon that restarts
  # rebuilds it from the lease records". This IS that rebuild, and it runs
  # at startup rather than lazily for the same reason
  # `reclaimAbandonedSessions` above does: a daemon nobody asks still has
  # to drop the records of instances whose processes are gone, or the
  # next `repro up` attaches to one that is not there.
  let instancesOpen = openDaemonServiceInstanceRegistry(
    daemonLeaseScope(config), config.leaseStoreRoot)
  var instances = instancesOpen.registry
  logLine(config.logPath, describeRebuild(instancesOpen.report))
  for event in instancesOpen.report.events:
    logLine(config.logPath, "service instance " & $event.kind &
      " address=" & event.address & " liveness=" & $event.liveness &
      " holderRecovery=" & $event.holderRecovery &
      " detail=" & event.detail)
  writeStatusFile(config, statusFor(config, startedAt, generation,
    sessions.len, devRestart))
  logLine(config.logPath, "started role=" & UserDaemonRole &
    " endpoint=" & config.endpoint & " generation=" & generation &
    " devMode=" & $config.devMode & " source=" &
    devRestart.sourceImagePath & " running=" & devRestart.runningImagePath &
    " restartRunId=" & devRestart.restartRunId)

  # L4 (§4.2): the wall-clock reaper tick. The event loop is otherwise
  # event-driven (it only wakes on a client or the dev-restart poll); the
  # tick is the one new capability. We cap the poll timeout at the reap
  # cadence so a lapsed lease is swept promptly even with NO client traffic,
  # and run the sweep BETWEEN accepts so socket handling is never stalled by
  # a reap (a reap is a bounded store scan; it runs on the loop thread only
  # when no client is waiting, so it cannot wedge an in-flight client).
  let leaseReapMs = leaseReapIntervalMs()
  var lastLeaseReapMs = nowUnixMs()
  var leaseReapState = initLeaseReapTickState()
  # Run an initial sweep at startup so a restart resumes reaping immediately
  # (an expired record left by a crashed/stopped prior instance is reaped on
  # the first pass rather than after a full interval).
  if leaseReapMs > 0:
    runScopedLeaseReapTick(config, leaseReapState, addr instances)

  # Distributed-Execution M0: the hosted background service (peer cache).
  # Started after the endpoint is bound, so a client that sees the daemon
  # running can rely on the service having been attempted; a service that
  # fails to start logs and leaves the daemon serving builds as before.
  var serviceStopped = true
  if userDaemonBackgroundService.start != nil:
    try:
      let line = userDaemonBackgroundService.start(config)
      serviceStopped = false
      if line.len > 0:
        logLine(config.logPath, line)
    except CatchableError as err:
      logLine(config.logPath, "background service failed to start: " &
        err.msg)
  proc stopBackgroundService() =
    if serviceStopped:
      return
    serviceStopped = true
    if userDaemonBackgroundService.stop != nil:
      try:
        userDaemonBackgroundService.stop()
      except CatchableError as err:
        logLine(config.logPath, "background service stop failed: " & err.msg)
  defer:
    stopBackgroundService()
  proc tickBackgroundService(maxWaitMs: int) =
    if serviceStopped or not backgroundServiceActive():
      return
    try:
      userDaemonBackgroundService.tick(maxWaitMs)
    except CatchableError as err:
      logLine(config.logPath, "background service tick failed: " & err.msg)

  var shuttingDown = false
  while not shuttingDown:
    if restartCandidateReady(config, devRestart):
      writeStatusFile(config, statusFor(config, startedAt, generation,
        activeSessionTallyFor(config), devRestart))
      # The successor binds the service's listen port; free it first.
      stopBackgroundService()
      if performDevSelfRestart(config, listener, daemonLock, devRestart):
        selfRestarting = true
        return 0
    if leaseReapMs > 0 and nowUnixMs() - lastLeaseReapMs >= leaseReapMs:
      runScopedLeaseReapTick(config, leaseReapState, addr instances)
      lastLeaseReapMs = nowUnixMs()
    var pollMs = int(devRestartPollIntervalMs())
    if leaseReapMs > 0 and leaseReapMs < pollMs:
      pollMs = leaseReapMs           # wake in time for the next reap tick
    let serviceRunning = not serviceStopped and backgroundServiceActive()
    if serviceRunning:
      let servicePoll = max(1, userDaemonBackgroundService.pollIntervalMs)
      if servicePoll < pollMs:
        pollMs = servicePoll
    let clientWaiting = listener.waitForClient(pollMs)
    if serviceRunning:
      # Service its sockets whether or not an IPC client arrived, bounded so
      # a waiting client is accepted promptly.
      tickBackgroundService(if clientWaiting: 0 else: pollMs)
    if not clientWaiting:
      continue
    var client = listener.acceptIpc()
    try:
      handleClient(client, config, startedAt, generation, shuttingDown,
        sessions, instances, devRestart)
    except CatchableError as err:
      logLine(config.logPath, "client error: " & err.msg)
      try:
        # Bounded: this courtesy reply must never cost the accept loop more
        # than ``ServerErrorWriteTimeoutMs``. The common trigger for landing
        # here is a readiness probe that connected and closed without sending
        # a frame, i.e. the peer is ALREADY gone and the write fails at once.
        client.writeFrame(udkError, errorBody(err.msg),
          timeoutMs = ServerErrorWriteTimeoutMs)
      except CatchableError:
        discard
    client.closeIpcConn()
  0

proc siblingUserDaemonPath*(publicCliPath: string): string =
  ## Locate the ``repro-daemon`` companion binary for the given ``repro``
  ## executable. Prefers a sibling next to ``publicCliPath`` (the layout used
  ## by installed and ``just build`` outputs), then falls back to ``findExe``
  ## so a daemon staged into ``PATH`` (for example, in a dev shell with
  ## ``build/bin`` on ``PATH``) still wins. Returns the bare unqualified
  ## binary name when neither lookup succeeds; callers must treat that as
  ## "daemon binary not found" and fail fast rather than handing the bare
  ## name to ``launchctl`` / ``execv``.
  let candidate = parentDir(publicCliPath) /
    addFileExt("repro-daemon", ExeExt)
  if fileExists(candidate):
    return os.normalizedPath(candidate)
  let viaPath = findExe("repro-daemon")
  if viaPath.len > 0:
    return os.normalizedPath(absolutePath(viaPath))
  addFileExt("repro-daemon", ExeExt)

proc daemonProcessArgs(config: UserDaemonConfig): seq[string] =
  # Executable-Consolidation M2: the daemon process is `repro daemon serve …`
  # (the self-spawned `repro` image), so every launch site (`launchWithFork`,
  # `launchWithLaunchd`, `launchWithSystemdUser`, and the dev self-restart
  # re-exec) prepends the `daemon serve` subcommand selector ahead of the
  # daemon flags. `runThinApp` consumes `daemon serve` and hands the remaining
  # flags to `runUserDaemonCommand` → `parseUserDaemonArgs`.
  result = @["daemon", "serve", "--foreground", "--endpoint", config.endpoint,
    "--state-dir", config.stateDir, "--log", config.logPath]
  if config.devMode:
    result.add("--dev")
  if config.sourceExe.len > 0:
    result.add("--source-exe")
    result.add(config.sourceExe)
  if config.stagedGenerationDir.len > 0:
    result.add("--staged-generation")
    result.add(config.stagedGenerationDir)
  if config.previousStagedGenerationDir.len > 0:
    result.add("--previous-staged-generation")
    result.add(config.previousStagedGenerationDir)
  if config.restartRunId.len > 0:
    result.add("--restart-run-id")
    result.add(config.restartRunId)
  if config.systemScope:
    result.add("--system")
  if config.leaseStoreRoot.len > 0:
    result.add("--state-root")
    result.add(config.leaseStoreRoot)
  if config.peerCacheSpec.len > 0:
    result.add("--peer-cache")
    result.add(config.peerCacheSpec)
  if config.trustProfile.len > 0:
    result.add("--trust-profile")
    result.add(config.trustProfile)

proc legacyLaunchdLabel(config: UserDaemonConfig): string =
  ## The label binaries before the endpoint-keyed naming registered: the
  ## endpoint's basename alone. Kept only so the launcher and the cleanup can
  ## find a job such a binary left behind -- see ``bootoutLegacyLaunchdJob``.
  "org.reprobuild.repro-daemon." &
    safePathSegment(config.endpoint.extractFilename, "user")

proc launchdLabel*(config: UserDaemonConfig): string =
  ## The launchd label the daemon for ``config.endpoint`` is registered under.
  ##
  ## KEYED ON THE WHOLE ENDPOINT PATH, NOT ON ITS LAST COMPONENT, for the
  ## reason ``systemdUnitName`` gives: a label is a per-user GLOBAL namespace
  ## while endpoints are not unique by basename (every one of them is some
  ## directory's ``d.sock``). The basename stays in front of the digest
  ## because the label is also what ``launchctl list`` shows.
  ##
  ## On launchd a shared label cost more than the fallback it cost on
  ## systemd. Measured on macOS 2026-10-14: a second ``launchctl bootstrap``
  ## of a loaded label fails with ``Bootstrap failed: 5: Input/output
  ## error``, but ``launchWithLaunchd`` boots out any prior job under its
  ## label first, and ``bootout`` SIGTERMs a running job -- so launching the
  ## second daemon KILLED the first, and
  ## ``cleanupPlatformBackgroundRegistration`` for one endpoint stopped
  ## whichever daemon held the label.
  ##
  ## The result is bounded and legal: an AF_UNIX endpoint is at most 104
  ## bytes on macOS (``sun_path``), and ``safePathSegment`` produces only
  ## ``[A-Za-z0-9._-]`` (characters a label and a file name both accept), so
  ## ``<label>.plist`` stays well under the 255-byte file-name limit.
  ##
  ## Exported so a second derivation -- a test teardown -- asks for the name
  ## instead of restating it.
  legacyLaunchdLabel(config) & "-" & endpointDigest(config.endpoint)

proc launchdPlistPath*(config: UserDaemonConfig): string =
  ## Where the launcher writes the plist for ``launchdLabel(config)``; it
  ## moves with the label.
  config.stateDir / "launchd" / (launchdLabel(config) & ".plist")

proc processOwnerTokenForLaunch(config: UserDaemonConfig): string =
  if config.processOwnerToken.len > 0:
    config.processOwnerToken
  else:
    getEnv(ReproTestRunnerOwnerTokenEnv)

proc isReprobuildRuntimeEnvKey(key: string): bool =
  ## Is ``key`` part of reprobuild's OWN runtime configuration, and therefore
  ## required by a daemon image that launchd starts?
  ##
  ## ``launchWithFork`` hands the daemon a copy of the parent environment, but a
  ## launchd user agent instead starts from launchd's default environment —
  ## ``PATH=/usr/bin:/bin:/usr/sbin:/sbin`` and nothing else. An installed
  ## ``repro`` is a makeWrapper script that injects its runtime configuration
  ## (``REPROBUILD_SOURCE_ROOT``, ``CLINGO_PREFIX``, the ``*_SRC`` source roots,
  ## …) as ``--set-default`` variables, and the daemon image it spawns is the
  ## inner *unwrapped* binary, so without propagation the daemon loses all of
  ## it. Concretely: ``reprobuild-nix-daemon`` ships only under
  ## ``$REPROBUILD_SOURCE_ROOT/tools`` (the package installs just ``bin/`` and
  ## ``lib/``), so a launchd-started daemon could never locate it and every
  ## ``tool-provisioning=nix`` build died with
  ## "Failed to connect or spawn reprobuild-nix-daemon".
  ##
  ## Propagation is CURATED rather than the wholesale copy ``launchWithFork``
  ## performs, because the plist is serialised to disk for ``launchctl`` to
  ## read: copying the caller's entire environment would persist unrelated user
  ## secrets (credentials, API tokens) into a file. Restricting it to
  ## reprobuild's own namespace plus ``PATH`` keeps the daemon correct without
  ## widening that exposure.
  key == "PATH" or key.startsWith("REPRO") or key.endsWith("_SRC") or
    key.endsWith("_PREFIX")

proc renderLaunchdUserAgentPlist*(exe: string; config: UserDaemonConfig):
    string =
  var args = @[exe] & daemonProcessArgs(config)
  result = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" &
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" " &
    "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" &
    "<plist version=\"1.0\">\n<dict>\n" &
    "  <key>Label</key>\n  <string>" & xmlEscape(launchdLabel(config)) &
      "</string>\n" &
    "  <key>ProgramArguments</key>\n  <array>\n"
  for arg in args:
    result.add("    <string>" & xmlEscape(arg) & "</string>\n")
  result.add("  </array>\n")
  # Reprobuild's own runtime configuration must survive the launchd launch —
  # see isReprobuildRuntimeEnvKey. Sorted so the rendered plist is byte-stable
  # for a given environment (envPairs' iteration order is unspecified).
  var envEntries: seq[(string, string)] = @[]
  for key, value in envPairs():
    if key != ReproTestRunnerOwnerTokenEnv and isReprobuildRuntimeEnvKey(key):
      envEntries.add((key, value))
  envEntries.sort()
  # The ownership marker is launch-time state rather than inherited
  # environment, so it is appended from the config, never copied from the
  # parent (protocol.sanitizeUserDaemonRequestEnvironment strips it elsewhere).
  let processOwnerToken = processOwnerTokenForLaunch(config)
  if processOwnerToken.len > 0:
    envEntries.add((ReproTestRunnerOwnerTokenEnv, processOwnerToken))
  if envEntries.len > 0:
    result.add("  <key>EnvironmentVariables</key>\n  <dict>\n")
    for (key, value) in envEntries:
      result.add("    <key>" & xmlEscape(key) & "</key>\n" &
        "    <string>" & xmlEscape(value) & "</string>\n")
    result.add("  </dict>\n")
  result.add(
    "  <key>RunAtLoad</key>\n  <true/>\n" &
    "  <key>KeepAlive</key>\n  <false/>\n" &
    "  <key>StandardOutPath</key>\n  <string>" &
      xmlEscape("/dev/null") & "</string>\n" &
    "  <key>StandardErrorPath</key>\n  <string>" &
      xmlEscape("/dev/null") & "</string>\n" &
    "</dict>\n</plist>\n")

proc quoteCommand(args: openArray[string]): string =
  var parts: seq[string] = @[]
  for arg in args:
    parts.add(quoteShell(arg))
  parts.join(" ")

proc launchdJobServesEndpoint(serviceTarget, endpoint: string): bool =
  ## Does the launchd job ``serviceTarget`` (``gui/<uid>/<label>``) run with
  ## ``--endpoint <endpoint>`` among its program arguments?
  ##
  ## Read from ``launchctl print``, which lists them one per line between
  ## ``arguments = {`` and ``}``. There is no structured form of that output;
  ## it is the same tool the launcher and the cleanup already drive. A job
  ## that is not loaded, or whose output does not parse, answers false: the
  ## caller only acts on a positive match.
  when defined(macosx):
    let res = execCmdEx(quoteCommand(["launchctl", "print", serviceTarget]))
    if res.exitCode != 0:
      return false
    var inArguments = false
    var arguments: seq[string] = @[]
    for line in res.output.splitLines():
      let stripped = line.strip()
      if not inArguments:
        if stripped == "arguments = {":
          inArguments = true
      elif stripped == "}":
        break
      else:
        arguments.add(stripped)
    for i in 0 ..< arguments.len - 1:
      if arguments[i] == "--endpoint" and arguments[i + 1] == endpoint:
        return true
    false
  else:
    false

proc bootoutLegacyLaunchdJob(config: UserDaemonConfig) =
  ## Boot out a job a binary from before ``launchdLabel`` was keyed on the
  ## whole endpoint registered for ``config.endpoint`` under the basename-only
  ## ``legacyLaunchdLabel``. Nothing else will ever boot that label out, and a
  ## finished ``KeepAlive=false`` job stays loaded under it until logout.
  ##
  ## The legacy label is shared by every endpoint with this basename, so the
  ## job is booted out only when launchd confirms it serves THIS endpoint --
  ## otherwise this would stop another endpoint's daemon, the very collision
  ## the new label removes.
  when defined(macosx):
    let legacyTarget = "gui/" & $currentUid() & "/" &
      legacyLaunchdLabel(config)
    if launchdJobServesEndpoint(legacyTarget, config.endpoint):
      discard execCmdEx(quoteCommand(["launchctl", "bootout", legacyTarget]))
      let legacyPlist = config.stateDir / "launchd" /
        (legacyLaunchdLabel(config) & ".plist")
      if fileExists(legacyPlist):
        try:
          removeFile(legacyPlist)
        except OSError:
          discard
  else:
    discard

proc launchWithLaunchd(exe: string; config: UserDaemonConfig): bool =
  when defined(macosx):
    try:
      createDir(parentDir(launchdPlistPath(config)))
      let plistPath = launchdPlistPath(config)
      writeFile(plistPath, renderLaunchdUserAgentPlist(exe, config))
      setFilePermissions(plistPath, {fpUserRead, fpUserWrite})
      # launchd snapshots the job definition during bootstrap. Remove the
      # token-bearing source plist on every return path; the registered job
      # remains available for status/bootout through its label.
      defer:
        try:
          removeFile(plistPath)
        except OSError:
          discard
      let serviceTarget = "gui/" & $currentUid()
      # Boot out any prior registration of this label BEFORE bootstrapping the
      # fresh plist. A ``RunAtLoad=true`` / ``KeepAlive=false`` agent runs once
      # and exits, but launchd keeps the (now-dead, status ``-9``) job loaded
      # under its label. A subsequent ``bootstrap`` of the same label then fails
      # ("service already bootstrapped"), so the code below fell through to
      # ``kickstart -k`` — which on a dead job whose ProgramArguments still point
      # at an OLD staged binary either relaunches the stale image or never
      # produces a ready endpoint, forcing the 30 s ``waitForUserDaemonStatus``
      # timeout and a posix-fork fallback on EVERY daemon spawn after the first.
      # (Observed as accumulating ``launchctl list`` entries across the daemon
      # control-plane + watch suites and the resulting "watch did not become
      # ready" timeouts.) Removing the stale job first lets ``bootstrap`` of the
      # freshly-written plist succeed cleanly. Errors are ignored: a missing
      # job simply means there was nothing to remove.
      discard execCmdEx(quoteCommand(["launchctl", "bootout",
        serviceTarget & "/" & launchdLabel(config)]))
      # The same for a job an older binary left for this endpoint under the
      # basename-only label: the bootout above no longer reaches it.
      bootoutLegacyLaunchdJob(config)
      let bootstrap = execCmdEx(quoteCommand(["launchctl", "bootstrap",
        serviceTarget, plistPath]))
      if bootstrap.exitCode == 0:
        logLine(config.logPath, "launch requested backend=launchd label=" &
          launchdLabel(config))
        return true
      let kickstart = execCmdEx(quoteCommand(["launchctl", "kickstart", "-k",
        serviceTarget & "/" & launchdLabel(config)]))
      if kickstart.exitCode == 0:
        logLine(config.logPath, "launch requested backend=launchd-kickstart label=" &
          launchdLabel(config))
        return true
      logLine(config.logPath, "launchd unavailable, falling back: " &
        bootstrap.output.strip() & " " & kickstart.output.strip())
    except CatchableError as err:
      logLine(config.logPath, "launchd launch failed, falling back: " &
        err.msg)
    false
  else:
    false

proc systemdUnitName*(config: UserDaemonConfig): string =
  ## The transient user unit the daemon for ``config.endpoint`` runs under.
  ##
  ## KEYED ON THE WHOLE ENDPOINT PATH, NOT ON ITS LAST COMPONENT. Transient
  ## unit names are a per-user GLOBAL namespace, while endpoints are placed in
  ## per-run scratch directories precisely BECAUSE the basename is not unique:
  ## every one of them is some directory's ``d.sock``. Keying the unit on
  ## ``extractFilename`` therefore discarded exactly the distinguishing part,
  ## and ``systemd-run`` refuses a name that is already loaded -- measured:
  ## ``Failed to start transient service unit: Unit
  ## repro-daemon-d.sock.service was already loaded``, exit 1. Six concurrent
  ## daemons wanted that one name; one held it and the other five took the
  ## ``launchWithFork`` fallback, which is not a supervised unit at all: they
  ## reparented to init and survived 11.8 days until they were reaped by hand.
  ##
  ## The basename is KEPT in front of the hash, because the name is also a
  ## human interface -- it is what ``systemctl --user list-units`` shows and
  ## what someone types to stop a daemon -- and a name that is only a hash
  ## tells that reader nothing.
  ##
  ## The endpoint string is hashed VERBATIM rather than normalised. The name
  ## has to be the same at launch and at
  ## ``cleanupPlatformBackgroundRegistration``, and the only thing guaranteed
  ## to be the same across those two calls is the config field itself; a
  ## normalisation against the process's cwd is not (the launching CLI and a
  ## later cleanup need not share one). Endpoints are absolute in every
  ## producer (``defaultUserDaemonEndpoint``, the ``--endpoint`` flag,
  ## per-run scratch dirs), so verbatim is also already canonical in practice.
  ##
  ## 16 hex characters is 64 bits of the digest: for a namespace whose
  ## population is the handful of daemons one user runs at once, a collision
  ## is not a risk worth a longer name. The result is bounded well under
  ## systemd's 255-byte limit, because an AF_UNIX path is itself bounded by
  ## ``sun_path`` (108 bytes).
  ##
  ## The key is ``endpointInstanceKey``, which the status record shares.
  "repro-daemon-" & endpointInstanceKey(config.endpoint, "user") & ".service"

proc systemdUserRunArgs*(exe: string; config: UserDaemonConfig):
    seq[string] =
  ## The ``systemd-run --user`` command line that starts the daemon.
  ##
  ## THE SAME CURATED ENVIRONMENT THE LAUNCHD PLIST CARRIES. A transient
  ## user unit starts from the user MANAGER's environment, not from the
  ## caller's — on NixOS that is ``PATH=<systemd>/bin`` and little else —
  ## exactly as a launchd agent starts from launchd's. The plist has carried
  ## reprobuild's own runtime configuration across that boundary
  ## (``isReprobuildRuntimeEnvKey``) since the reprobuild-nix-daemon defect;
  ## this launcher carried none of it. Everything the daemon PARENT reads from
  ## its own environment was therefore silently the manager's default on
  ## Linux: ``REPROBUILD_DAEMON_PARENT_PREWARM=0`` never turned the prewarm
  ## off (t_daemon_parent_prewarm_e2e's cold arm logged a prewarm), and
  ## ``PATH`` / ``RUNQUOTAD_BIN`` / the ``*_SRC`` roots were the manager's.
  ## Sorted so the argv is stable for a given environment.
  result = @["systemd-run", "--user", "--unit=" & systemdUnitName(config),
    "--collect", "--quiet", "-p", "ExitType=cgroup"]
  var envEntries: seq[(string, string)] = @[]
  for key, value in envPairs():
    if key != ReproTestRunnerOwnerTokenEnv and isReprobuildRuntimeEnvKey(key):
      envEntries.add((key, value))
  envEntries.sort()
  for (key, value) in envEntries:
    result.add("--setenv=" & key & "=" & value)
  let processOwnerToken = processOwnerTokenForLaunch(config)
  if processOwnerToken.len > 0:
    result.add("--setenv=" & ReproTestRunnerOwnerTokenEnv & "=" &
      processOwnerToken)
  result.add(exe)
  result.add(daemonProcessArgs(config))

proc launchWithSystemdUser(exe: string; config: UserDaemonConfig): bool =
  when defined(linux):
    try:
      # ExitType=cgroup is what lets the dev self-restart survive on
      # Linux: the old daemon performs the fork+exec of the staged
      # binary and then exits 0. With the default ExitType=main,
      # systemd treats the unit as inactive the moment that main
      # process exits, --collect removes it, and KillMode=control-group
      # SIGKILLs every other PID in the cgroup — including the
      # freshly-forked replacement. ExitType=cgroup keeps the unit
      # active as long as any process in the cgroup is alive, so the
      # replacement keeps running and can bind the endpoint.
      let args = systemdUserRunArgs(exe, config)
      let res = execCmdEx(quoteCommand(args))
      if res.exitCode == 0:
        logLine(config.logPath, "launch requested backend=systemd-user unit=" &
          systemdUnitName(config))
        return true
      logLine(config.logPath, "systemd --user unavailable, falling back: " &
        res.output.strip())
    except CatchableError as err:
      logLine(config.logPath, "systemd --user launch failed, falling back: " &
        err.msg)
    false
  else:
    false

proc noteSupervisionDowngrade(config: UserDaemonConfig; reason: string) =
  ## Say, in the daemon's own log, that what is about to start is NOT a
  ## supervised process.
  ##
  ## WHY THIS IS NOT JUST ANOTHER "falling back" LINE. The two launchers above
  ## already log why the platform manager declined, and that reads as a
  ## routine retry. It is not: the fallback changes WHO IS RESPONSIBLE FOR THE
  ## PROCESS'S DEATH. A transient unit is stopped when the unit is stopped,
  ## collected when it exits, and listed by ``systemctl --user``; a
  ## ``fork()`` + ``setsid()`` child is owned by nobody, reparents to init,
  ## and appears in no inventory. That difference is what turned an ordinary
  ## test-fixture leak into five daemons that ran for 11.8 days. Nobody chose
  ## the quieter supervision model, so the log has to name it.
  ##
  ## ``ppid=1`` is named because it is the discriminator that actually works
  ## for finding these afterwards. Age does not: of the leaked cohort, one
  ## daemon 369 s old with a live parent was healthy, while two aged 1.1 h and
  ## 1.6 h with ``ppid=1`` were already orphaned.
  logLine(config.logPath,
    "supervision downgraded: " & reason & "; starting a detached setsid " &
    "child instead. Nothing supervises it -- it reparents to init (ppid=1) " &
    "and is in no manager's inventory. endpoint=" & config.endpoint)

proc launchWithFork(exe: string; config: UserDaemonConfig) =
  when defined(posix):
    let argv = @[exe] & daemonProcessArgs(config)
    let cargv = allocCStringArray(argv)
    var environment: seq[string] = @[]
    for key, value in envPairs():
      if key != ReproTestRunnerOwnerTokenEnv:
        environment.add(key & "=" & value)
    let processOwnerToken = processOwnerTokenForLaunch(config)
    if processOwnerToken.len > 0:
      environment.add(ReproTestRunnerOwnerTokenEnv & "=" & processOwnerToken)
    let cenv = allocCStringArray(environment)
    let exeCString = cstring(exe)
    # Prepared before the fork: the child may only make async-signal-safe
    # calls, and ``chdir`` is one, allocating a C string is not.
    let workingDir = daemonWorkingDirectory(config)
    let workingDirCString = cstring(workingDir)
    let pid = fork()
    if pid < 0:
      raise newException(UserDaemonRuntimeError,
        "failed to fork repro-daemon")
    if pid == 0:
      discard setsid()
      # Not the caller's working directory: the daemon outlives the caller,
      # and would keep that directory's file system busy and serve from it
      # after it was deleted (``daemonWorkingDirectory``). ``/`` is the
      # conventional fallback when the state directory cannot be entered.
      if posix.chdir(workingDirCString) != 0:
        discard posix.chdir(cstring("/"))
      # Raw output must not bypass the structured log writer's size bound.
      let devNull = posix.open(cstring("/dev/null"), O_RDWR)
      if devNull < 0:
        exitnow(127)
      for fd in 0.cint .. 2.cint:
        if dup2(devNull, fd) < 0:
          exitnow(127)
      for fd in 3.cint .. 255.cint:
        discard posix.close(fd)
      discard execve(exeCString, cargv, cenv)
      quit(127)
    logLine(config.logPath, "launch requested backend=posix-fork pid=" &
      $pid)

proc cleanupPlatformBackgroundRegistration*(requested: UserDaemonConfig) =
  ## Deregister the daemon for ``requested.endpoint`` from the platform
  ## service manager (launchd job / systemd transient unit).
  ##
  ## The paths are anchored first, exactly as ``startUserDaemon`` anchors them
  ## before it launches: the name the manager knows the daemon by is derived
  ## from the endpoint string, and the launcher registered it under the
  ## ABSOLUTE one. A caller passing ``--endpoint`` relative to its working
  ## directory would otherwise ask for a name nothing was registered under.
  let config = withAnchoredDaemonPaths(requested)
  when defined(macosx):
    discard execCmdEx(quoteCommand(["launchctl", "bootout",
      "gui/" & $currentUid() & "/" & launchdLabel(config)]))
    if fileExists(launchdPlistPath(config)):
      try:
        removeFile(launchdPlistPath(config))
      except OSError:
        discard
    bootoutLegacyLaunchdJob(config)
  elif defined(linux):
    discard execCmdEx(quoteCommand(["systemctl", "--user", "stop",
      systemdUnitName(config)]))

proc waitForUserDaemonStatus*(endpoint: string; timeoutMs = 60000):
    UserDaemonStatus =
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  while epochTime() < deadline:
    let status = queryUserDaemonStatus(endpoint)
    if status.running:
      return status
    sleep(25)
  raise newException(UserDaemonRuntimeError,
    "timed out waiting for repro-daemon at " & endpoint)

proc raiseDaemonBinaryNotFound(publicCliPath: string) {.noreturn.} =
  ## The one wording of "there is no daemon image to start", shared by the
  ## launch guard and by the identity check that cannot digest the image it
  ## would compare. Callers catch it and fall back to direct mode.
  raise newException(UserDaemonRuntimeError,
    "repro-daemon binary not found (looked for sibling next to " &
      publicCliPath & " and on PATH as 'repro-daemon'); set " &
      "REPRO_DAEMON=off or install/build repro-daemon next to repro")

proc startUserDaemon*(publicCliPath: string;
                      requestedConfig: UserDaemonConfig): UserDaemonStatus =
  # Absolute before anything is derived from it: the daemon starts in its
  # state directory, not ours (``daemonWorkingDirectory``).
  let config = withAnchoredDaemonPaths(requestedConfig)
  let sourceExe =
    # Executable-Consolidation M2: the user daemon IS the `repro` image, run as
    # `repro daemon serve …` (see `daemonProcessArgs`). Self-spawn the current
    # `repro` rather than locating a separate `repro-daemon` binary, so the
    # image-hash compared below is `repro`'s own image on both sides. (An older
    # daemon still running the standalone `repro-daemon` binary therefore
    # reports a different `runningHash` and is auto-restarted onto the new
    # `repro daemon serve` image.)
    if config.daemonExe.len > 0: config.daemonExe
    else: publicCliPath
  let existing = queryUserDaemonStatus(config.endpoint)
  if existing.running:
    # A user daemon is persistent and can outlive the `repro` that started it.
    # If the running daemon's binary differs from the one this `repro` would
    # spawn — i.e. reprobuild was rebuilt to a newer version — continuing to
    # use it means talking to a stale build engine: an older build-target
    # payload decoder (`unsupported build target payload version`), a progress
    # encoding the new client renders as raw `progress:` lines, and so on.
    # Detect that by comparing the daemon-reported running-image hash to the
    # on-disk image that daemon startup will actually execute. `repro` is a
    # single full-CLI image (no thin wrapper / `repro-full` companion), so the
    # digest tracks that one binary.
    #
    # THIS FAILS CLOSED. The running daemon is reused only when BOTH digests
    # are known and EQUAL. It used to fail open -- "if either hash is
    # unavailable we cannot prove staleness, so leave the daemon running" --
    # and that is how a thin client handed a RELATIVE engine path (for which
    # `expectedDaemonRunningDigestHex` answers "") routed every build to
    # whatever older engine was resident, silently (reprobuild-pm issue
    # 2026-09-30). The contract is that a routed invocation runs the engine a
    # fallback would have run; an identity nobody can establish does not meet
    # it. So:
    #
    #   * equal digests -> reuse;
    #   * different digests -> restart onto the current image;
    #   * the DAEMON's digest unknown (an image deleted or unreadable under
    #     it) -> restart as well: it is unproven, and replacing it costs one
    #     daemon start;
    #   * OUR digest unknown -> refuse, without touching the daemon. We cannot
    #     name the image we would run, so we can neither vouch for the
    #     resident daemon nor start a replacement; the error makes every
    #     caller fall back to the engine in-process (direct mode), which is
    #     exactly the image it named.
    let expectedHash = expectedDaemonRunningDigestHex(config, sourceExe,
      config.devMode)
    if expectedHash.len == 0:
      if not isAbsolute(sourceExe) or not fileExists(sourceExe):
        raiseDaemonBinaryNotFound(publicCliPath)
      raise newException(UserDaemonRuntimeError,
        "cannot digest the repro-daemon image " & sourceExe & " to verify " &
          "the daemon running at " & config.endpoint & "; refusing to route " &
          "to a daemon of unverified identity (set REPRO_DAEMON=off for " &
          "direct mode)")
    if existing.runningHash == expectedHash:
      return existing
    if existing.runningHash.len == 0:
      logLine(config.logPath, "restarting daemon of unknown identity: " &
        "running-hash unavailable expected-hash=" & expectedHash &
        " (cannot prove it runs the current reprobuild image)")
    else:
      logLine(config.logPath, "restarting outdated daemon: running-hash=" &
        existing.runningHash & " expected-hash=" & expectedHash &
        " (reprobuild image changed)")
    try:
      requestUserDaemonShutdown(config.endpoint)
    except CatchableError as err:
      logLine(config.logPath, "outdated-daemon shutdown failed: " & err.msg)
  when defined(posix):
    if userDaemonEndpointExists(config.endpoint) and
        userDaemonEndpointAcceptsConnections(config.endpoint):
      raise newException(UserDaemonRuntimeError,
        "repro-daemon endpoint accepts connections but did not complete a " &
          "compatible status handshake at " & config.endpoint &
          "; stop the incompatible daemon or set REPRO_DAEMON=off for direct mode")
  discard cleanupStaleUserDaemonDiscovery(config)
  # Fail fast when the daemon binary cannot be located. Without this guard the
  # bare unqualified name returned by ``siblingUserDaemonPath`` propagates into
  # ``launchctl bootstrap`` (which silently registers a non-executable plist
  # entry and forces a 30 s status-wait timeout) and then into ``execv`` in the
  # posix-fork fallback (another 60 s wait). Both paths eventually surface as a
  # generic timeout that hides the real cause from CLI fallbacks. Raising here
  # lets ``runBuildCommand`` / ``runWatchCommand`` switch to direct mode in
  # milliseconds with a clear diagnostic naming the path we tried.
  if not isAbsolute(sourceExe) or not fileExists(sourceExe):
    raiseDaemonBinaryNotFound(publicCliPath)
  var launchConfig = config
  launchConfig.processOwnerToken = getEnv(ReproTestRunnerOwnerTokenEnv)
  var exe = sourceExe
  if config.devMode:
    let staged = stageDevDaemonBinary(sourceExe, config,
      if config.restartRunId.len > 0: config.restartRunId else: newRestartRunId(
        "dev-start"))
    exe = staged.imagePath
    launchConfig.sourceExe = absoluteNormalized(sourceExe)
    launchConfig.stagedGenerationDir = staged.generationDir
    launchConfig.restartRunId = staged.runId
    logLine(config.logPath, "dev start staged source=" & sourceExe &
      " running=" & exe & " runId=" & staged.runId)
  when defined(posix):
    createDir(parentDir(launchConfig.endpoint))
    createDir(launchConfig.stateDir)
    createDir(parentDir(launchConfig.logPath))
    var launchedWithPlatformManager = false
    when defined(macosx):
      launchedWithPlatformManager = launchWithLaunchd(exe, launchConfig)
      if not launchedWithPlatformManager:
        noteSupervisionDowngrade(launchConfig,
          "launchd did not take the daemon")
        launchWithFork(exe, launchConfig)
    elif defined(linux):
      launchedWithPlatformManager = launchWithSystemdUser(exe, launchConfig)
      if not launchedWithPlatformManager:
        noteSupervisionDowngrade(launchConfig,
          "systemd --user did not take the daemon")
        launchWithFork(exe, launchConfig)
    else:
      noteSupervisionDowngrade(launchConfig,
        "this platform has no background manager")
      launchWithFork(exe, launchConfig)
    if launchedWithPlatformManager:
      try:
        return waitForUserDaemonStatus(launchConfig.endpoint, 30000)
      except UserDaemonRuntimeError as err:
        logLine(launchConfig.logPath,
          "platform launcher did not produce a ready repro-daemon: " &
            err.msg & "; falling back to posix-fork")
        cleanupPlatformBackgroundRegistration(launchConfig)
        discard cleanupStaleUserDaemonDiscovery(launchConfig)
        noteSupervisionDowngrade(launchConfig,
          "the platform manager started a daemon that never became ready")
        launchWithFork(exe, launchConfig)
  else:
    # NOT ``osproc.startProcess``: on Windows it creates the child with
    # ``bInheritHandles = TRUE`` and no handle list, so the daemon -- which
    # outlives this process -- received every inheritable handle we held,
    # including the write end of whatever pipe our caller reads our output
    # from. A caller reading to EOF (CMake's try_compile, a test runner) then
    # waited for as long as the daemon lived. ``spawnWithOwnStdio`` passes
    # exactly NUL and the log, which is ``launchWithFork``'s guarantee. It
    # also starts the daemon in its state directory, not in ours, which
    # Windows would otherwise refuse to delete while the daemon lives.
    createDir(launchConfig.stateDir)
    var env = newStringTable(modeCaseInsensitive)
    for key, value in envPairs():
      if cmpIgnoreCase(key, ReproTestRunnerOwnerTokenEnv) != 0:
        env[key] = value
    if launchConfig.processOwnerToken.len > 0:
      env[ReproTestRunnerOwnerTokenEnv] = launchConfig.processOwnerToken
    env["REPRO_DAEMON_ENDPOINT"] = launchConfig.endpoint
    env["REPRO_DAEMON_STATE_DIR"] = launchConfig.stateDir
    var envPairsForChild: seq[(string, string)] = @[]
    for key, value in env:
      envPairsForChild.add((key, value))
    let pid = spawnWithOwnStdio(exe, daemonProcessArgs(launchConfig),
      envPairsForChild, inheritEnvironment = false,
      logPath = "",
      workingDir = daemonWorkingDirectory(launchConfig))
    logLine(launchConfig.logPath,
      "launch requested backend=windows-handle-list pid=" & $pid)
  waitForUserDaemonStatus(launchConfig.endpoint)

proc stopUserDaemon*(endpoint = defaultUserDaemonEndpoint()) =
  requestUserDaemonShutdown(endpoint)

const UserDaemonBinaryVersionNote* =
  "the version string does not identify the build; two builds with " &
  "different features can share it. Compare binary-identity and features."
  ## Printed as `binary-version-note:` directly under `binary-version:` in
  ## `repro daemon status`. One line, so `field: value` readers of the
  ## report are unaffected. See `userDaemonBinaryIdentity` for why.

proc userDaemonBinaryIdentity*(status: UserDaemonStatus): string =
  ## The value `repro daemon status` prints as `binary-identity:` -- the
  ## field that actually tells two daemon builds apart.
  ##
  ## WHY NOT `binary-version` (reprobuild-pm issue 2026-10-13). The version
  ## is the package version, shared by every build between two bumps. A
  ## nix-store daemon and a locally built one both reported `0.2.5` while
  ## advertising different feature sets, and a reader who compared the CLI's
  ## version with the daemon's concluded the daemon was current. The spec
  ## (Local-Daemons-And-Control-Plane.md, *Protocol Compatibility*) asks for
  ## binary IDENTITY as a field distinct from the feature flags.
  ##
  ## The preference order is by strength of evidence:
  ##
  ## 1. `runningHash`, verbatim -- the content digest of the running image
  ##    as `imageDigestHex` produced it, algorithm prefix included
  ##    (`blake3-256:<hex>`), the same value `running-hash:` prints.
  ## 2. `path:<image>` when no digest could be taken (the image was deleted
  ##    or replaced under a running daemon): weaker, and labelled so a
  ##    reader does not compare it with a digest as if they were alike.
  ##    The running image wins over the source image, which may have been
  ##    rebuilt since the daemon staged its copy.
  ## 3. `unknown` -- never empty, because two empty identities compared by
  ##    eye read as "the same build".
  if status.runningHash.len > 0:
    status.runningHash
  elif status.runningImagePath.len > 0:
    "path:" & status.runningImagePath
  elif status.sourceImagePath.len > 0:
    "path:" & status.sourceImagePath
  else:
    "unknown"

proc renderUserDaemonStatus*(status: UserDaemonStatus): string =
  if not status.running:
    return "repro daemon: not-running\nendpoint: " & status.endpoint
  "repro daemon: running\n" &
    "role: " & status.role & "\n" &
    "endpoint: " & status.endpoint & "\n" &
    "state-dir: " & status.stateDir & "\n" &
    "log: " & status.logPath & "\n" &
    "protocol: " & $status.protocolMajor & "." & $status.protocolMinor & "\n" &
    "binary-name: " & status.binary.name & "\n" &
    "binary-path: " & status.binary.path & "\n" &
    "binary-version: " & status.binary.version & "\n" &
    # Kept verbatim (tools parse it); the two lines after it say why it
    # must not be read as the build identity.
    "binary-identity: " & userDaemonBinaryIdentity(status) & "\n" &
    "binary-version-note: " & UserDaemonBinaryVersionNote & "\n" &
    "features: " & status.featureFlags & "\n" &
    "generation: " & status.generation & "\n" &
    "pid: " & $status.pid & "\n" &
    "uptime-seconds: " & $status.uptimeSeconds & "\n" &
    "active-sessions: " & $status.activeSessionCount & "\n" &
    "dev-mode: " & $status.devMode & "\n" &
    "source-image-path: " & status.sourceImagePath & "\n" &
    "running-image-path: " & status.runningImagePath & "\n" &
    "source-hash: " & status.sourceHash & "\n" &
    "running-hash: " & status.runningHash & "\n" &
    "protocol-generation: " & status.protocolGeneration & "\n" &
    "restart-run-id: " & status.restartRunId & "\n" &
    "staged-generation-dir: " & status.stagedGenerationDir & "\n" &
    "previous-staged-generation-dir: " &
      status.previousStagedGenerationDir & "\n" &
    "reconnect-limitations: " & status.reconnectLimitations

proc renderUserDaemonLogs*(config: UserDaemonConfig): string =
  ## What `repro daemon logs` prints: the previous generation (`<log>.1`)
  ## followed by the current file, oldest line first. Printing `.1` is what
  ## keeps a rotation from hiding the previous retained generation. The
  ## byte amount depends on line lengths and rotation boundaries.
  let previous = userDaemonLogPreviousGeneration(config.logPath)
  let hasPrevious = fileExists(previous)
  let hasCurrent = fileExists(config.logPath)
  if not hasPrevious and not hasCurrent:
    return "repro daemon logs: no log file at " & config.logPath
  # Each read is guarded on its own: a writer can rotate between the
  # `fileExists` above and the read, and whatever is still there is worth
  # printing.
  if hasPrevious:
    try:
      result.add(readFile(previous))
    except IOError:
      discard
  if hasCurrent:
    try:
      result.add(readFile(config.logPath))
    except IOError:
      discard

proc renderUserDaemonSessions*(sessions: openArray[UserDaemonSession]):
    string =
  if sessions.len == 0:
    return "repro daemon sessions: none"
  result = "repro daemon sessions: " & $sessions.len
  for session in sessions:
    result.add("\n" & session.sessionId & "\t" & session.mode & "\t" &
      session.state & "\t" & $session.exitCode & "\t" &
      session.projectRoot)
    if session.mode == "watch":
      result.add("\tselectedRoots=" & session.selectedRoots.join(",") &
        "\tdebounceMs=" & $session.debounceMs &
        "\t watchedPaths=" & $session.watchedPaths.len &
        "\ttierState=" & session.tierState &
        "\tlastResult=" & session.lastResult)
    if session.message.len > 0:
      result.add("\t" & session.message)

proc parseUserDaemonConfigFlags*(args: seq[string];
                                 base = defaultUserDaemonConfig()):
    tuple[config: UserDaemonConfig; rest: seq[string]] =
  result.config = base
  var explicitLog = false
  var i = 0
  while i < args.len:
    let raw = args[i]
    proc valueFor(flag: string): string =
      let prefix = flag & "="
      if raw.startsWith(prefix):
        return raw[prefix.len .. ^1]
      if raw == flag:
        if i + 1 >= args.len:
          raise newException(ValueError, flag & " requires a value")
        inc i
        return args[i]
      raise newException(ValueError, "internal user-daemon flag parse error")

    if raw == "--foreground":
      result.config.foreground = true
    elif raw == "--dev":
      result.config.devMode = true
    elif raw == "--daemon-exe" or raw.startsWith("--daemon-exe="):
      result.config.daemonExe = valueFor("--daemon-exe")
    elif raw == "--source-exe" or raw.startsWith("--source-exe="):
      result.config.sourceExe = valueFor("--source-exe")
    elif raw == "--staged-generation" or
        raw.startsWith("--staged-generation="):
      result.config.stagedGenerationDir = valueFor("--staged-generation")
    elif raw == "--previous-staged-generation" or
        raw.startsWith("--previous-staged-generation="):
      result.config.previousStagedGenerationDir =
        valueFor("--previous-staged-generation")
    elif raw == "--restart-run-id" or raw.startsWith("--restart-run-id="):
      result.config.restartRunId = valueFor("--restart-run-id")
    elif raw == "--endpoint" or raw.startsWith("--endpoint="):
      result.config.endpoint = valueFor("--endpoint")
    elif raw == "--state-dir" or raw.startsWith("--state-dir="):
      result.config.stateDir = valueFor("--state-dir")
    elif raw == "--log" or raw.startsWith("--log="):
      result.config.logPath = valueFor("--log")
      explicitLog = true
    elif raw == "--system":
      result.config.systemScope = true
    elif raw == "--state-root" or raw.startsWith("--state-root="):
      result.config.leaseStoreRoot = valueFor("--state-root")
    elif raw == "--peer-cache" or raw.startsWith("--peer-cache="):
      result.config.peerCacheSpec = valueFor("--peer-cache")
    elif raw == "--trust-profile" or raw.startsWith("--trust-profile="):
      result.config.trustProfile = valueFor("--trust-profile")
    else:
      result.rest.add(raw)
    inc i
  if not explicitLog:
    result.config.logPath = result.config.stateDir / "logs" /
      "repro-daemon.log"

proc userDaemonUsage*(): string =
  "usage: repro-daemon [--foreground] [--dev] [--system] [--endpoint PATH] " &
    "[--state-dir PATH] [--log PATH] [--state-root PATH] " &
    "[--peer-cache SPEC] [--trust-profile trusted|hardened]"

proc runUserDaemonCommand*(args: seq[string]): int =
  if args.len == 1 and args[0] in ["--help", "-h"]:
    echo userDaemonUsage()
    return 0
  try:
    let parsed = parseUserDaemonConfigFlags(args)
    if parsed.rest.len > 0:
      stderr.writeLine("repro-daemon: unexpected argument: " &
        parsed.rest[0])
      return 2
    return runUserDaemonForeground(parsed.config)
  except CatchableError as err:
    stderr.writeLine("repro-daemon: error: " & err.msg)
    return 1

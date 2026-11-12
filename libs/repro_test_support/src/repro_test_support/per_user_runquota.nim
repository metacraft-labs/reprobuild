## Fixtures for the SHARED PER-USER ``runquotad`` a POSIX ``repro`` adopts or
## starts (reprobuild-pm ``spec/RunQuota-Host-Configuration.md``, "The shared
## per-user daemon (POSIX)").
##
## WHY A TEST NEVER USES THE REAL PER-USER ENDPOINT. The daemon ``repro``
## starts there OUTLIVES the invocation and is shared by every process of the
## user -- on a shared CI host that includes other agents and other test runs
## under the same uid. A test that adopted it would grade somebody else's
## daemon; a test that stopped it would cut somebody else's builds off. So
## every test that reaches ``startAutoRunQuotaIfNeeded`` names a scratch
## endpoint directory through ``RUNQUOTA_USER_ENDPOINT_DIR`` -- the isolation
## knob the specification provides for exactly this -- and stops, in a
## ``defer``, the daemon it caused to be started there.
##
## WHAT IS READ, AND FROM WHERE. Which daemon is alive at an endpoint is the
## holder of its LIFETIME LOCK (``<socket>.lock``), not the socket file: a
## daemon killed with ``SIGKILL`` leaves its socket behind. On Linux the
## holder's pid is read from ``/proc/locks``, a pure read that disturbs
## nothing (a client connection would reset the daemon's idle timer, which
## is what some of these tests measure). Elsewhere the pid is not available
## and ``lifetimeLockHolderPid`` answers 0; ``lifetimeLockHeld`` (RunQuota's
## own probe) answers whether anyone holds it on every POSIX host.
##
## NO MOCKS: the real lock files, the real ``/proc/locks``, the real client
## library's ``RetireDaemon``.

when defined(posix):
  import std/[os, posix, strutils]
  import runquota_ipc
  import runquota_client
  import repro_test_support/process_fixtures
  export lifetimeLockHeld

  proc scratchUserEndpointDir*(): string =
    ## ``/tmp/<12 hex>/u``: a per-user endpoint directory nobody else uses,
    ## short enough that ``runquotad.sock.start`` fits ``sun_path`` on every
    ## host. The PARENT is created owner-only and removed at process exit;
    ## ``u`` itself is left for the launcher to create, because creating it
    ## (``mkdir`` ``0700``, last component only) is part of what is tested.
    shortSocketDirAtProcessExit("rqu") / "u"

  proc userSocketIn*(directory: string): string =
    ## The socket ``runquota_ipc.userEndpoint`` names for ``directory``.
    directory / endpointSocketName

  proc linuxDevNumbers(dev: uint64): tuple[major, minor: uint64] =
    ## glibc's ``gnu_dev_major`` / ``gnu_dev_minor``, which ``/proc/locks``
    ## prints in hex as ``MAJOR:MINOR``.
    (major: ((dev shr 8) and 0xfff'u64) or ((dev shr 32) and not 0xfff'u64),
     minor: (dev and 0xff'u64) or ((dev shr 12) and not 0xff'u64))

  proc lifetimeLockHolderPid*(socket: string): int =
    ## The pid holding ``socket``'s lifetime lock exclusively, or 0 when
    ## nobody does (or, off Linux, when it cannot be read).
    when defined(linux):
      var info: Stat
      if stat(cstring(lifetimeLockPath(socket)), info) != 0:
        return 0
      let dev = linuxDevNumbers(uint64(info.st_dev))
      for line in lines("/proc/locks"):
        # `1: FLOCK  ADVISORY  WRITE 12345 00:1b:4987 0 EOF`; a waiter is
        # printed as `1: -> FLOCK ...` and is not a holder.
        let fields = line.splitWhitespace()
        if fields.len < 6 or fields[1] == "->":
          continue
        if fields[1] == "FLOCK" and fields[3] == "WRITE":
          # The device is MAJOR:MINOR in hex, the inode in decimal.
          let parts = fields[5].split(':')
          if parts.len == 3:
            try:
              let same = parseHexInt(parts[0]) == int(dev.major) and
                parseHexInt(parts[1]) == int(dev.minor) and
                parts[2] == $uint64(info.st_ino)
              if same:
                return parseInt(fields[4])
            except ValueError:
              discard
      0
    else:
      discard socket
      0

  proc waitLifetimeLockFree*(socket: string; timeoutMs: int): bool =
    ## Whether the lifetime lock of ``socket`` became free within
    ## ``timeoutMs``.
    var waited = 0
    while waited <= timeoutMs:
      if not lifetimeLockHeld(socket):
        return true
      sleep(50)
      waited += 50
    not lifetimeLockHeld(socket)

  proc socketPresent*(path: string): bool =
    ## Whether anything is at ``path`` (``fileExists`` is ``S_ISREG`` and
    ## answers false for every socket there is).
    var info: Stat
    lstat(path.cstring, info) == 0

  proc pidAlive*(pid: int): bool =
    pid > 0 and (posix.kill(Pid(pid), 0) == 0 or errno == EPERM)

  proc stopUserDaemon*(socket: string; startedPid = 0) =
    ## Stop the daemon THIS TEST caused to be started at ``socket``, the way
    ## an operator would (``runquota daemon stop --wait``): an unconditional
    ## ``RetireDaemon`` through the real client, then a wait for the lifetime
    ## lock to be released. Only when it is still held after 30 s is the
    ## holder sent ``SIGTERM`` -- and only when it is ``startedPid``, the pid
    ## the caller recorded for the daemon it started, so a process this test
    ## did not start is never signalled.
    if not lifetimeLockHeld(socket):
      return
    let savedSocket = getEnv("RUNQUOTA_SOCKET")
    let hadSocket = existsEnv("RUNQUOTA_SOCKET")
    let savedScope = getEnv("RUNQUOTA_ENDPOINT_SCOPE")
    let hadScope = existsEnv("RUNQUOTA_ENDPOINT_SCOPE")
    putEnv("RUNQUOTA_SOCKET", socket)
    putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
    try:
      var client = connect(unixEndpoint(socket))
      try:
        discard client.retireDaemon(reason = "test teardown")
      finally:
        client.close()
    except CatchableError:
      discard
    finally:
      if hadSocket: putEnv("RUNQUOTA_SOCKET", savedSocket)
      else: delEnv("RUNQUOTA_SOCKET")
      if hadScope: putEnv("RUNQUOTA_ENDPOINT_SCOPE", savedScope)
      else: delEnv("RUNQUOTA_ENDPOINT_SCOPE")
    if waitLifetimeLockFree(socket, 30_000):
      return
    let holder = lifetimeLockHolderPid(socket)
    if startedPid > 0 and holder == startedPid:
      discard posix.kill(Pid(holder), SIGTERM)
      discard waitLifetimeLockFree(socket, 10_000)

  type IsolatedUserRunQuota* = object
    ## An in-process test's private per-user endpoint, and the RunQuota
    ## environment it replaced.
    dir*: string
    socket*: string
    saved: seq[tuple[key: string; present: bool; value: string]]

  proc isolateUserRunQuota*(): IsolatedUserRunQuota =
    ## Point ``RUNQUOTA_USER_ENDPOINT_DIR`` at a scratch directory for a test
    ## that calls ``startAutoRunQuotaIfNeeded`` in its own process, and save
    ## the variables that call publishes (``RUNQUOTA_SOCKET``,
    ## ``RUNQUOTA_ENDPOINT_SCOPE``) so ``release`` can put them back: the
    ## publication outlives the call by design, and must not outlive the
    ## case into the next one.
    for key in ["RUNQUOTA_USER_ENDPOINT_DIR", "RUNQUOTA_SOCKET",
        "RUNQUOTA_ENDPOINT_SCOPE"]:
      result.saved.add((key, existsEnv(key), getEnv(key)))
    result.dir = scratchUserEndpointDir()
    result.socket = userSocketIn(result.dir)
    putEnv("RUNQUOTA_USER_ENDPOINT_DIR", result.dir)

  proc release*(isolated: IsolatedUserRunQuota; startedPid = 0) =
    ## Stop the daemon the case started there and restore the environment.
    stopUserDaemon(isolated.socket, startedPid)
    for entry in isolated.saved:
      if entry.present: putEnv(entry.key, entry.value)
      else: delEnv(entry.key)

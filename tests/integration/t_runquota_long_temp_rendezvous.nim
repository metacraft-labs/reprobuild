import std/[monotimes, os, osproc, streams, strutils, tempfiles, times, unittest]
import repro_core/paths
import repro_test_support

when defined(posix):
  import runquota_client
  import runquota_ipc

  template withLongTemp(body: untyped) =
    let scratch = createTempDir("runquota-endpoint-", "")
    let wasSet = existsEnv("TMPDIR")
    let previous = getEnv("TMPDIR")
    let longRoot = scratch / repeat('x', 160)
    createDir(longRoot)
    # Each daemon's persistent state lives under the case's own scratch
    # directory; see `startDaemon`.
    let daemonState {.inject.} = scratch / "daemon-state"
    createDir(daemonState)
    putEnv("TMPDIR", longRoot)
    try:
      body
    finally:
      if wasSet: putEnv("TMPDIR", previous)
      else: delEnv("TMPDIR")
      removeDir(scratch)

  proc startDaemon(path, stateRoot: string): owned(Process) =
    ## Starts a real daemon on `path`. These cases are about the endpoint
    ## (its directory, its socket, the client's trust check), so the daemon
    ## runs with its observation store OFF (`--no-write-stats`) and with
    ## host identity and estimates private to it, under `stateRoot`.
    ##
    ## Left to its defaults, a test daemon opens the HOST's observation
    ## store (`/var/lib/runquota/observations.sqlite3` — ~300 MB on a
    ## working machine, shared with the user's real daemon) before it binds
    ## its socket, and writes test traffic into it. Measured on a loaded
    ## host: 9.6-24 s to bind with the host store, 0.75-3 s with a private
    ## one (≈11 `sqlite3` invocations before `bind`), 0.06-0.23 s with
    ## `--no-write-stats` — against `awaitDaemon`'s 5 s deadline.
    let daemon = requireRunQuotaDaemonBin(getCurrentDir())
    let state = stateRoot / path.parentDir.lastPathPart
    createDir(state)
    startProcess(daemon, args = ["--socket", path, "--cpu-milli", "1000",
      "--memory-bytes", "1073741824", "--no-write-stats",
      "--host-identity-file", state / "host-id",
      "--observation-db", state / "observations.sqlite3",
      "--estimate-db", state / "estimates.sqlite3"],
      options = {poUsePath, poStdErrToStdOut})

  proc stopDaemon(process: var owned(Process)) =
    if process != nil:
      if process.running:
        process.terminate()
        if process.waitForExit(5_000) == -1:
          process.kill()
          discard process.waitForExit()
      process.close()
      process = nil

  proc awaitDaemon(process: Process; path: string) =
    let wasSet = existsEnv("RUNQUOTA_HANDSHAKE_TIMEOUT_MS")
    let previous = getEnv("RUNQUOTA_HANDSHAKE_TIMEOUT_MS")
    putEnv("RUNQUOTA_HANDSHAKE_TIMEOUT_MS", "1000")
    defer:
      if wasSet: putEnv("RUNQUOTA_HANDSHAKE_TIMEOUT_MS", previous)
      else: delEnv("RUNQUOTA_HANDSHAKE_TIMEOUT_MS")
    let deadline = getMonoTime() + initDuration(seconds = 5)
    var diagnostic = ""
    while getMonoTime() < deadline:
      if not process.running:
        raise newException(OSError, process.outputStream.readAll())
      try:
        # A bound socket inode can exist before the daemon starts listening.
        var client = connect(unixEndpoint(path), "readiness-probe")
        client.close()
        return
      except OSError, EndpointTrustError, RunQuotaClientError:
        diagnostic = getCurrentExceptionMsg()
        sleep(25)
    raise newException(OSError, "RunQuota handshake did not complete: " &
      path & ": " & diagnostic)

suite "RunQuota long temp rendezvous":
  test "two callers connect to independent real daemons under a long TMPDIR":
    when defined(posix):
      withLongTemp:
        let first = runquotaEndpointPath("first-" & $getCurrentProcessId())
        let second = runquotaEndpointPath("second-" & $getCurrentProcessId())
        require first.parentDir != second.parentDir
        require not dirExists(first.parentDir)
        require not dirExists(second.parentDir)
        var a = startDaemon(first, daemonState)
        var b: owned(Process)
        defer:
          stopDaemon(b)
          stopDaemon(a)
          if dirExists(first.parentDir): removeDir(first.parentDir)
          if dirExists(second.parentDir): removeDir(second.parentDir)
        b = startDaemon(second, daemonState)
        awaitDaemon(a, first)
        awaitDaemon(b, second)
        for path in [first, second]:
          check fpGroupWrite notin getFilePermissions(path.parentDir)
          check fpOthersWrite notin getFilePermissions(path.parentDir)
          check endpointDirectoryRefusal(unixEndpoint(path)).len == 0
        var clientA = connect(unixEndpoint(first), "long-temp-first")
        defer: clientA.close()
        var clientB = connect(unixEndpoint(second), "long-temp-second")
        defer: clientB.close()
        check clientA.daemonStatus(timeoutMs = 5_000).activeLeases == 0
        stopDaemon(a)
        check b.running
        check clientB.daemonStatus(timeoutMs = 5_000).activeLeases == 0
    else:
      skip()

  test "the daemon still refuses a preexisting world-writable parent":
    when defined(posix):
      withLongTemp:
        let path = runquotaEndpointPath("unsafe-" & $getCurrentProcessId())
        require not dirExists(path.parentDir)
        createDir(path.parentDir)
        setFilePermissions(path.parentDir, {fpUserRead, fpUserWrite, fpUserExec,
          fpGroupRead, fpGroupWrite, fpGroupExec,
          fpOthersRead, fpOthersWrite, fpOthersExec})
        defer: removeDir(path.parentDir)
        var daemon = startDaemon(path, daemonState)
        defer: stopDaemon(daemon)
        let code = daemon.waitForExit(5_000)
        require code != -1
        check code != 0
        let output = daemon.outputStream.readAll()
        checkpoint(output)
        check "refusing" in output
        check "endpoint directory" in output
    else:
      skip()

  test "the client still refuses a live endpoint after its parent becomes writable":
    when defined(posix):
      withLongTemp:
        let path = runquotaEndpointPath("changed-" & $getCurrentProcessId())
        require not dirExists(path.parentDir)
        var daemon = startDaemon(path, daemonState)
        defer:
          stopDaemon(daemon)
          if dirExists(path.parentDir): removeDir(path.parentDir)
        awaitDaemon(daemon, path)
        let priorMode = getFilePermissions(path.parentDir)
        setFilePermissions(path.parentDir, priorMode + {fpOthersWrite})
        defer: setFilePermissions(path.parentDir, priorMode)
        expect EndpointTrustError:
          var client = connect(unixEndpoint(path), "unsafe-client")
          client.close()
    else:
      skip()

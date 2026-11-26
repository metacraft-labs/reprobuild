## The engine's RunQuota bypass fallback says why it was taken when the
## endpoint EXISTS and refused this process, and `RUNQUOTA_STRICT` refuses
## the build instead of running actions unleased.
##
## THE DEFECT. A process started before its user joined the rendezvous group
## does not carry that group, so the host socket's mode refuses its
## `connect(2)` with `EACCES`. On a build mode that may fall back
## (`fallbackToRunQuotaBypass`), the engine then ran every action with no
## lease, and the only trace was the generic "bypassed" build header: not
## which endpoint, not why, not what to do.
##
## WHAT IS ASSERTED, through the real `runBuild` with the inline RunQuota
## path and the bypass fallback on:
##
## * refused (`EACCES`), not strict: the action runs (its marker file
##   appears) and standard error carries EXACTLY ONE warning line naming the
##   socket, `EACCES (Permission denied)` and the remedy -- one, although the
##   engine retries the session for every launch;
## * refused, strict: the build is refused with a message naming the socket
##   and `RUNQUOTA_STRICT`, and the marker does NOT exist: nothing ran;
## * a reachable `runquotad` (strict on): no warning, the action ran, and it
##   ran under a lease (the result carries a lease id).
##
## THE REFUSING SOCKET IS REAL, AND REFUSES WITH A REAL `EACCES`. The test
## binds and listens on a Unix socket itself and `chmod 0`s the socket file;
## `connect(2)` needs write permission on it, so a non-root caller gets
## `EACCES` while the listener is alive (measured on Linux 2026-11-24 before
## writing this file). The host endpoint policy is used, with the documented
## `RUNQUOTA_ENDPOINT_OWNER_UID` / `RUNQUOTA_ENDPOINT_GROUP` naming this
## test's uid and gid so the 0750 scratch directory passes the directory
## check and `connect(2)` is what refuses: under the private policy the
## client would refuse the 0000 socket in its own mode check first, a
## different failure. The reachable case is a test-owned daemon under the
## private policy, as every fixture here starts one.
##
## STANDARD ERROR IS CAPTURED BY REDIRECTING DESCRIPTOR 2 to a file for the
## duration of one `runBuild`, because the warning is written by the engine
## in this process. Nothing else is replaced.
##
## NO MOCKS: the real engine, real sockets, a real `runquotad`, real child
## processes and the filesystem as the oracle.
##
## FALSIFYING MUTATIONS, each applied once, recompiled, run and reverted,
## measured on Linux 2026-11-24 against origin/agents `e62e214bd` plus this
## change (3/3 pass unmutated):
##
## * `runQuotaUnleasedFallback` returns an empty message outside strict mode
##   (the warning dropped): the refused, non-strict case fails; 2/3 pass.
## * `runQuotaUnleasedFallback` ignores `strict`: the strict case fails (the
##   build runs the action); 2/3 pass.

when defined(linux) or defined(macosx):
  import std/[os, osproc, posix, strutils, tempfiles, unittest]

  import repro_build_engine
  import repro_core
  from repro_core/process_streams import drainStream
  import repro_runquota
  import repro_test_support

  const WarningNeedle = "repro: warning: cannot use the RunQuota daemon at "

  let repoRoot = getCurrentDir()
  let scratchParent = repoRoot / "build" / "test-tmp"
  createDir(scratchParent)
  let tempRoot = createTempDir("rqref-", "", scratchParent)

  proc markerAction(id, marker: string): BuildAction =
    action(id, ["/bin/sh", "-c", "touch " & quoteShell(marker)],
      cacheable = false,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())

  proc fallbackConfig(cacheRoot: string): BuildEngineConfig =
    ## A build mode that may fall back to the bypass, on the inline path
    ## (the engine's own session; no helper binary involved).
    result = defaultBuildEngineConfig(cacheRoot)
    result.bypassRunQuota = false
    result.fallbackToRunQuotaBypass = true
    result.inlineRunQuota = true
    result.maxParallelism = 1'u32

  type Captured = object
    run: BuildRunResult
    raised: string
    stderr: string

  proc runCapturingStderr(g: BuildGraph; config: BuildEngineConfig;
                          capturePath: string): Captured =
    stderr.flushFile()
    let saved = dup(2)
    doAssert saved >= 0
    let fd = posix.open(capturePath.cstring, O_WRONLY or O_CREAT or O_TRUNC,
      Mode(0o600))
    doAssert fd >= 0
    doAssert dup2(fd, 2) >= 0
    discard posix.close(fd)
    try:
      result.run = runBuild(g, config)
    except CatchableError as error:
      result.raised = error.msg
    finally:
      stderr.flushFile()
      doAssert dup2(saved, 2) >= 0
      discard posix.close(saved)
    result.stderr = readFile(capturePath)

  proc warningCount(text: string): int =
    for line in text.splitLines():
      if WarningNeedle in line: inc result

  proc ranLeased(run: BuildRunResult): bool =
    for item in run.results:
      if item.leaseId != 0'u64: return true

  # The refusing endpoint: a 0750 directory of this uid and gid, and a
  # listening socket in it at mode 0000.
  let refusedDir = tempRoot / "host"
  createDir(refusedDir)
  doAssert chown(refusedDir.cstring, Uid(high(uint32)), getegid()) == 0
  doAssert chmod(refusedDir.cstring, Mode(0o750)) == 0
  let refusedSocket = refusedDir / "d.sock"
  let listener = posix.socket(AF_UNIX, SOCK_STREAM, 0)
  doAssert cint(listener) >= 0
  var address: Sockaddr_un
  address.sun_family = TSa_Family(AF_UNIX)
  doAssert refusedSocket.len < address.sun_path.len,
    "scratch socket path too long: " & refusedSocket
  copyMem(addr address.sun_path[0], refusedSocket.cstring, refusedSocket.len)
  doAssert bindSocket(listener, cast[ptr SockAddr](addr address),
    SockLen(sizeof(address))) == 0
  doAssert listen(listener, 16) == 0
  doAssert chmod(refusedSocket.cstring, Mode(0)) == 0

  proc selectRefusedEndpoint() =
    delEnv("RUNQUOTA_ENDPOINT_SCOPE")
    putEnv("RUNQUOTA_SOCKET", refusedSocket)
    putEnv("RUNQUOTA_ENDPOINT_OWNER_UID", $geteuid())
    putEnv("RUNQUOTA_ENDPOINT_GROUP", $getegid())

  for key in ["RUNQUOTA_STRICT", "REPROBUILD_NO_RUNQUOTA"]:
    delEnv(key)

  suite "a refused RunQuota endpoint is warned about; strict refuses":
    test "refused (EACCES), not strict: the action runs, one warning":
      doAssert geteuid() != 0, "root bypasses the socket's mode"
      selectRefusedEndpoint()
      delEnv("RUNQUOTA_STRICT")
      let caseDir = createTempDir("lenient-", "", tempRoot)
      let marker = caseDir / "ran"
      let second = caseDir / "ran-too"
      let captured = runCapturingStderr(
        graph([markerAction("rq-lenient", marker),
               markerAction("rq-lenient-2", second)]),
        fallbackConfig(caseDir / "cache"), caseDir / "stderr.txt")
      checkpoint captured.stderr
      check captured.raised.len == 0
      check fileExists(marker)
      check fileExists(second)
      check warningCount(captured.stderr) == 1
      check refusedSocket in captured.stderr
      check "EACCES (Permission denied)" in captured.stderr
      check "start a new login session" in captured.stderr
      check captured.run.runQuotaBypassed

    test "refused (EACCES), strict: the build is refused, nothing runs":
      doAssert geteuid() != 0, "root bypasses the socket's mode"
      selectRefusedEndpoint()
      putEnv("RUNQUOTA_STRICT", "1")
      defer: delEnv("RUNQUOTA_STRICT")
      let caseDir = createTempDir("strict-", "", tempRoot)
      let marker = caseDir / "ran"
      let captured = runCapturingStderr(
        graph([markerAction("rq-strict", marker)]),
        fallbackConfig(caseDir / "cache"), caseDir / "stderr.txt")
      let said = captured.raised & "\n" & captured.stderr
      checkpoint said
      check not fileExists(marker)
      check captured.raised.len > 0
      check refusedSocket in said
      check "RUNQUOTA_STRICT is set" in said
      check "EACCES" in said
      check warningCount(captured.stderr) == 0

    test "a reachable runquotad, strict: no warning, the action is leased":
      for key in ["RUNQUOTA_ENDPOINT_OWNER_UID", "RUNQUOTA_ENDPOINT_GROUP",
                  "RUNQUOTA_SOCKET"]:
        delEnv(key)
      delEnv("RUNQUOTA_ENDPOINT_SCOPE")
      putEnv("RUNQUOTA_STRICT", "1")
      defer: delEnv("RUNQUOTA_STRICT")
      let caseDir = createTempDir("leased-", "", tempRoot)
      # The test's own daemon, on a private rendezvous (which also selects
      # the private scope for this process).
      let socketPath = runquotaRendezvousDir(caseDir) / "d.sock"
      var daemon = startProcess(requireRunQuotaDaemonBin(repoRoot), args = [
        "--socket", socketPath, "--cpu-milli", "4000",
        "--memory-bytes", "4294967296"], options = {poStdErrToStdOut})
      defer:
        if daemon.running:
          daemon.terminate()
          discard daemon.waitForExit(10_000)
        if daemon.running:
          daemon.kill()
          discard daemon.waitForExit(10_000)
        daemon.close()
      # A stat, not `fileExists`: a Unix socket is not a regular file.
      proc bound(path: string): bool =
        var info: Stat
        lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode)
      var waited = 0
      while not bound(socketPath) and daemon.running and waited < 30_000:
        sleep(25)
        waited += 25
      if not bound(socketPath):
        let said =
          if daemon.running: "(still running)"
          else: drainStream(daemon.outputStream)
        doAssert false, "runquotad did not bind " & socketPath & ": " & said
      putEnv("RUNQUOTA_SOCKET", socketPath)
      defer: delEnv("RUNQUOTA_SOCKET")
      let marker = caseDir / "ran"
      let captured = runCapturingStderr(
        graph([markerAction("rq-leased", marker)]),
        fallbackConfig(caseDir / "cache"), caseDir / "stderr.txt")
      checkpoint captured.stderr & "\n" & captured.raised
      check captured.raised.len == 0
      check fileExists(marker)
      check warningCount(captured.stderr) == 0
      check "RUNQUOTA_STRICT" notin captured.stderr
      check not captured.run.runQuotaBypassed
      check ranLeased(captured.run)

  discard posix.close(listener)
  removeDir(tempRoot)
else:
  echo "t_refused_runquota_endpoint_warns_or_refuses: POSIX only"

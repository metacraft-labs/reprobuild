## Production auto-start selects the owner-only PRIVATE policy for the
## daemon, the parent and the managed actions, on the shared per-user
## endpoint, independently of installed service accounts (reprobuild-pm
## `spec/RunQuota-Host-Configuration.md`, "Explicit private endpoint policy
## (POSIX)" and "The shared per-user daemon (POSIX)").
##
## Until 2026-11-11 the endpoint was a fresh directory per invocation and the
## daemon ended with the invocation; the cases that graded that lifetime now
## grade its replacement, driving `startAutoRunQuotaIfNeeded` in process:
## the endpoint is the per-user one, the publication of `RUNQUOTA_SOCKET` /
## `RUNQUOTA_ENDPOINT_SCOPE` survives the release, a stale socket nobody
## holds the lifetime lock of is replaced, a second invocation ADOPTS the
## daemon, a failed start says why with the daemon's log, and an invalid
## idle period is refused before anything starts. The CLI-level coverage of
## the same rule is `t_auto_runquota_shared_per_user_daemon`.
##
## Every case names a scratch endpoint directory through
## `RUNQUOTA_USER_ENDPOINT_DIR` and stops the daemon it started, so the real
## per-user daemon of this uid is never touched.
##
## No success mocks: real runquotad, sockets, parent/client connections and
## leased child. Explicit foreign host selectors reproduce the account shape
## without NSS changes. Two shell fixtures stand in for a daemon where a real
## one cannot produce the outcome: a refusing script grades only startup
## output transport (a real daemon cannot deterministically produce large
## independent stdout/stderr refusals), and a `RUNQUOTAD_BIN` that records
## that it ran and exits proves a refusal happened BEFORE anything started.
## The first case starts the real daemon through a wrapper that adds this
## test's own host file, identity and store; it starts once and adopts
## nothing, so the wrapper's image digest is never compared with the
## daemon's.
import std/[json, os, osproc, strutils, tempfiles, unittest]
import repro_cli_support
import repro_runquota
import repro_test_support
import repro_test_support/process_fixtures
import runquota_client
import runquota_protocol

when defined(posix):
  import std/posix
  from std/net import nil
  from std/nativesockets import Domain, SockType, Protocol
  from runquota_ipc import hostWideEndpointDir
  import repro_test_support/per_user_runquota

  proc checkRefusesWithoutSpawn(root, endpoint, scope: string) =
    let marker = root / "unexpected-start"
    let wrapper = root / "must-not-start"
    writeFile(wrapper, "#!/bin/sh\nprintf executed > " & quoteShell(marker) &
      "\nexit 23\n")
    setFilePermissions(wrapper, {fpUserRead, fpUserWrite, fpUserExec})
    putEnv("RUNQUOTAD_BIN", wrapper)
    putEnv("RUNQUOTA_SOCKET", endpoint)
    if scope.len > 0: putEnv("RUNQUOTA_ENDPOINT_SCOPE", scope)
    else: delEnv("RUNQUOTA_ENDPOINT_SCOPE")
    var message = ""
    try:
      var daemon = startAutoRunQuotaIfNeeded(false)
      releaseAutoRunQuotaProcess(daemon)
    except CatchableError as error:
      message = error.msg
    check message.len > 0
    check not fileExists(marker)
    check getEnv("RUNQUOTA_SOCKET") == endpoint
    check getEnv("RUNQUOTA_ENDPOINT_SCOPE") == scope

  proc writeRealDaemonWrapper(root, daemonBin: string): string =
    ## A `RUNQUOTAD_BIN` that execs the real daemon with this test's own
    ## host file, identity and store, so nothing touches the host's.
    result = root / "runquotad"
    let hostFile = root / "host.toml"
    writeFile(hostFile, "schema = \"runquota.host-config.v1\"\n")
    writeFile(result, "#!/bin/sh\nexec " & quoteShell(daemonBin) &
      " --host-config " & quoteShell(hostFile) &
      " --host-identity-file " & quoteShell(root / "host-id") &
      " --observation-db " & quoteShell(root / "observations.sqlite") &
      " --ambient-sample-interval-millis 0 \"$@\"\n")
    setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

  proc isSocketInode(path: string): bool =
    var info: Stat
    lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode)

  proc plantStaleSocket(directory: string): string =
    ## What a daemon killed with SIGKILL leaves behind: an owner-only
    ## endpoint directory holding a socket inode nothing listens on any
    ## more, and a lifetime lock nobody holds. Closing a bound socket does
    ## not unlink its path.
    if posix.mkdir(directory.cstring, Mode(0o700)) != 0:
      raiseOSError(osLastError(), "mkdir " & directory)
    result = userSocketIn(directory)
    var listener = net.newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM,
      Protocol.IPPROTO_IP) # protocol 0, the only one AF_UNIX has
    net.bindUnix(listener, result)
    net.close(listener)
    doAssert isSocketInode(result)

  proc inodeOf(path: string): uint64 =
    var info: Stat
    doAssert lstat(path.cstring, info) == 0
    uint64(info.st_ino)

  if paramCount() == 1 and paramStr(1) == "--private-action-client":
    doAssert getEnv("RUNQUOTA_ENDPOINT_SCOPE") == "private"
    var client = runquota_client.connectDefault()
    client.close()
    stdout.write("private-action-connected\n")
    quit(0)

  suite "auto-started RunQuota uses the private policy on the per-user endpoint":
    setup:
      let root = createTempDir("repro-private-policy-", "")
      releaseDirAtProcessExit(root)
      var saved: seq[tuple[key: string, present: bool, value: string]]
      for key in ["RUNQUOTA_SOCKET", "RUNQUOTA_ENDPOINT_SCOPE",
          "RUNQUOTA_ENDPOINT_OWNER_UID", "RUNQUOTA_ENDPOINT_GROUP",
          "RUNQUOTAD_BIN", "REPROBUILD_AUTO_RUNQUOTA", "REPRO_DAEMONS_CONFIG",
          "RUNQUOTA_USER_ENDPOINT_DIR",
          "REPROBUILD_RUNQUOTA_IDLE_EXIT_SECONDS"]:
        saved.add((key, existsEnv(key), getEnv(key)))
      let daemonBin = requireRunQuotaDaemonBin(getCurrentDir())
      let userDir = scratchUserEndpointDir()
      let userSocket = userSocketIn(userDir)
      putEnv("RUNQUOTA_USER_ENDPOINT_DIR", userDir)
      delEnv("REPROBUILD_RUNQUOTA_IDLE_EXIT_SECONDS")
      putEnv("REPROBUILD_AUTO_RUNQUOTA", "1")
      putEnv("RUNQUOTA_SOCKET", root / "absent.sock")
      delEnv("RUNQUOTA_ENDPOINT_SCOPE")
      putEnv("RUNQUOTA_ENDPOINT_OWNER_UID", if geteuid() == 0: "1" else: "0")
      putEnv("RUNQUOTA_ENDPOINT_GROUP", "0")
      writeFile(root / "daemons.conf", "")
      putEnv("REPRO_DAEMONS_CONFIG", root / "daemons.conf")
      putEnv("RUNQUOTAD_BIN", daemonBin)
      forgetMachineDeclaredDaemonTrust()
      var startedPid = 0
    teardown:
      releaseAdoptedDaemonHold()
      stopUserDaemon(userSocket, startedPid)
      for entry in saved:
        if entry.present: putEnv(entry.key, entry.value)
        else: delEnv(entry.key)
      removeDir(root)
      forgetMachineDeclaredDaemonTrust()

    test "daemon parent and leased action use the per-user private endpoint":
      putEnv("RUNQUOTAD_BIN", writeRealDaemonWrapper(root, daemonBin))
      var daemon = startAutoRunQuotaIfNeeded(false)
      defer: releaseAutoRunQuotaProcess(daemon)
      require daemon != nil
      startedPid = processID(daemon)
      let socket = getEnv("RUNQUOTA_SOCKET")
      # The inherited socket named nothing, so the invocation recovered to
      # the per-user endpoint rather than a directory of its own.
      check socket == userSocket
      check getEnv("RUNQUOTA_ENDPOINT_SCOPE") == "private"
      check getFilePermissions(socket.parentDir) == {fpUserRead, fpUserWrite, fpUserExec}
      check getFilePermissions(socket) == {fpUserRead, fpUserWrite}
      var client = runquota_client.connectDefault()
      defer: client.close()
      var captureReady = false
      for _ in 0 ..< 400:
        let observations = parseJson(client.inspectionJson("observations"))["observations"]
        if observations["capture_enabled"].getBool():
          check not observations["write_stats_disabled"].getBool()
          check observations["store_path"].getStr() == root / "observations.sqlite"
          captureReady = true
          break
        sleep(25)
      require captureReady
      let execution = runWithRunQuota(
        ReproResourceRequest(label: "private-policy-action", cpuMilli: 1,
          memoryBytes: 1024 * 1024, commandStatsId: "repro-private-policy"),
        ReproCommandSpec(argv: @[getAppFilename(), "--private-action-client"],
          stdoutLimit: 4096, stderrLimit: 4096))
      check execution.exitCode == 0
      check execution.stdout == "private-action-connected\n"
      check execution.stderr == ""
      check execution.leaseFinishedSent
      check execution.leaseReleased
      let exported = client.queryStats(statsSubjectExport, "repro-private-policy")
      check exported.captureEnabled
      require exported.extensionRows.len == 1
      require exported.extensionRows[0].values.len == 1
      let row = parseJson(exported.extensionRows[0].values[0])
      check row["command_stats_id"].getStr() == "repro-private-policy"
      check row["exit_status"].getInt() == 0
      client.close()
      releaseAutoRunQuotaProcess(daemon)
      # PUBLISHED, NOT RESTORED: the endpoint names a daemon that outlives
      # the invocation, and every later command must find it.
      check getEnv("RUNQUOTA_SOCKET") == userSocket
      check getEnv("RUNQUOTA_ENDPOINT_SCOPE") == "private"
      # And the daemon is still there: releasing it does not stop it.
      check lifetimeLockHeld(userSocket)
      check dirExists(userDir)

    test "a stale per-user socket nobody holds the lock of is replaced":
      let stale = plantStaleSocket(userDir)
      let staleInode = inodeOf(stale)
      check not lifetimeLockHeld(stale)
      var daemon = startAutoRunQuotaIfNeeded(false)
      defer: releaseAutoRunQuotaProcess(daemon)
      require daemon != nil
      startedPid = processID(daemon)
      check getEnv("RUNQUOTA_SOCKET") == stale
      check isSocketInode(stale)
      check inodeOf(stale) != staleInode
      check lifetimeLockHeld(stale)
      var client = runquota_client.connectDefault()
      client.close()

    test "a second invocation in one process adopts the first one's daemon":
      var first = startAutoRunQuotaIfNeeded(false)
      defer: releaseAutoRunQuotaProcess(first)
      require first != nil
      startedPid = processID(first)
      check getEnv("RUNQUOTA_SOCKET") == userSocket
      releaseAutoRunQuotaProcess(first)
      check not holdsAdoptedDaemon()
      # The inherited socket is now the per-user one: adopt-or-start, which
      # finds the daemon alive and adopts it.
      var second = startAutoRunQuotaIfNeeded(false)
      defer: releaseAutoRunQuotaProcess(second)
      check second == nil
      # Adopted AND HELD, so it cannot idle out or retire under this
      # invocation before its first session.
      check holdsAdoptedDaemon()
      check getEnv("RUNQUOTA_SOCKET") == userSocket
      when defined(linux):
        check lifetimeLockHolderPid(userSocket) == startedPid
      releaseAutoRunQuotaProcess(second)
      check not holdsAdoptedDaemon()
      check lifetimeLockHeld(userSocket)

    test "startup error retains both streams through the daemon's log":
      let wrapper = root / "refusing-runquotad"
      writeFile(wrapper, "#!/bin/sh\n" &
        "printf '%s\\n' \"$@\" > " & quoteShell(root / "daemon-args") & "\n" &
        "i=0; while [ $i -lt 4096 ]; do printf 'stdout-padding-0123456789\\n'; " &
        "printf 'stderr-padding-0123456789\\n' >&2; i=$((i+1)); done\n" &
        "printf 'specific startup stdout reason\\n'\n" &
        "printf 'specific startup stderr refusal\\n' >&2\nexit 23\n")
      setFilePermissions(wrapper, {fpUserRead, fpUserWrite, fpUserExec})
      putEnv("RUNQUOTAD_BIN", wrapper)
      var message = ""
      try:
        var daemon = startAutoRunQuotaIfNeeded(false)
        releaseAutoRunQuotaProcess(daemon)
      except OSError as error:
        message = error.msg
      checkpoint(message)
      check "did not become reachable" in message
      check "runquotad.log" in message
      check "specific startup stdout reason" in message
      check "specific startup stderr refusal" in message
      check "truncated" in message
      # Nothing was started, so nothing was published.
      check getEnv("RUNQUOTA_SOCKET") == root / "absent.sock"
      check not existsEnv("RUNQUOTA_ENDPOINT_SCOPE")
      # The daemon was handed the per-user socket and the idle period, and
      # no budget flag.
      let args = readFile(root / "daemon-args").splitLines()
      check args[0 .. 3] == @["--socket", userSocket, "--idle-exit-after", "600"]

    test "an invalid idle period is an error before anything starts":
      for value in ["0", "-5", "abc", "1.5", " 7"]:
        putEnv("REPROBUILD_RUNQUOTA_IDLE_EXIT_SECONDS", value)
        let marker = root / "unexpected-start"
        let wrapper = root / "must-not-start"
        writeFile(wrapper, "#!/bin/sh\nprintf executed > " &
          quoteShell(marker) & "\nexit 23\n")
        setFilePermissions(wrapper, {fpUserRead, fpUserWrite, fpUserExec})
        putEnv("RUNQUOTAD_BIN", wrapper)
        var message = ""
        try:
          var daemon = startAutoRunQuotaIfNeeded(false)
          releaseAutoRunQuotaProcess(daemon)
        except CatchableError as error:
          message = error.msg
        checkpoint(value & ": " & message)
        check "REPROBUILD_RUNQUOTA_IDLE_EXIT_SECONDS" in message
        check not fileExists(marker)
        check not dirExists(userDir)
      delEnv("REPROBUILD_RUNQUOTA_IDLE_EXIT_SECONDS")

    test "existing untrusted endpoint retains refusal and starts no daemon":
      let endpoint = root / "unsafe.sock"
      writeFile(endpoint, "a file cannot impersonate a daemon")
      checkRefusesWithoutSpawn(root, endpoint, "")
      check readFile(endpoint) == "a file cannot impersonate a daemon"

    test "dangling endpoint symlink is not an absent invocation socket":
      let endpoint = root / "dangling.sock"
      createSymlink(root / "absent-target", endpoint)
      checkRefusesWithoutSpawn(root, endpoint, "")
      check symlinkExists(endpoint)

    test "malformed scope and private paths are not replaced":
      checkRefusesWithoutSpawn(root, root / "absent.sock", "unknown")
      checkRefusesWithoutSpawn(root, "relative.sock", "private")
      checkRefusesWithoutSpawn(root, "", "private")
      # POSIX environment values cannot carry NUL: setenv truncates before
      # getenv can deliver the string. RunQuota's direct-path API grades NUL.
      let wrongParent = root / "ordinary-file"
      writeFile(wrongParent, "not a directory")
      checkRefusesWithoutSpawn(root, wrongParent / "socket", "")
      check not fileExists(root / "unexpected-start")

    test "inaccessible parent is not an absent invocation socket":
      # The production test is run as a regular developer, as in the issue.
      # Root bypasses directory DAC; do not pretend to grade that boundary.
      require geteuid() != 0
      let denied = root / "denied"
      createDir(denied)
      setFilePermissions(denied, {})
      defer: setFilePermissions(denied, {fpUserRead, fpUserWrite, fpUserExec})
      checkRefusesWithoutSpawn(root, denied / "socket", "")
      check not fileExists(root / "unexpected-start")

    test "missing explicitly selected host endpoint does not spawn privately":
      checkRefusesWithoutSpawn(root, hostWideEndpointDir /
        ("repro-absent-" & $getCurrentProcessId() & ".sock"), "")
      check not fileExists(root / "unexpected-start")

    test "alias parent traversal to a missing host endpoint retains refusal":
      let hostParent = parentDir(hostWideEndpointDir)
      let alias = root / "host-parent"
      createSymlink(hostParent, alias)
      let endpoint = alias & "/../" & lastPathPart(hostParent) & "/" &
        lastPathPart(hostWideEndpointDir) & "/repro-absent-" &
        $getCurrentProcessId() & ".sock"
      checkRefusesWithoutSpawn(root, endpoint, "")
      check not fileExists(root / "unexpected-start")

    test "missing selected machine-declared endpoint does not spawn privately":
      let endpoint = root / "declared.sock"
      writeFile(root / "daemons.conf", "[runquotad]\nsocket = " & endpoint &
        "\nuid = " & $geteuid() & "\n")
      checkRefusesWithoutSpawn(root, endpoint, "")
      check not fileExists(root / "unexpected-start")

    test "alias of missing selected machine-declared endpoint retains refusal":
      let directory = root / "declared"
      createDir(directory)
      let alias = root / "alias"
      createSymlink(directory, alias)
      writeFile(root / "daemons.conf", "[runquotad]\nsocket = " &
        directory / "absent.sock" & "\nuid = " & $geteuid() & "\n")
      checkRefusesWithoutSpawn(root, alias / "absent.sock", "")
      createDir(directory / "child")
      let childAlias = root / "child-alias"
      createSymlink(directory / "child", childAlias)
      checkRefusesWithoutSpawn(root, childAlias & "/../absent.sock", "")
      check not fileExists(root / "unexpected-start")

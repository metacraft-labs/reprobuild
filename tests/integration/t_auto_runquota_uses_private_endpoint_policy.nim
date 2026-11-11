## Production auto-start selects owner-only policy for daemon, parent and
## managed actions, independently of installed service accounts. No success
## mocks: real runquotad, sockets, parent/client connections and leased child.
## Explicit foreign host selectors reproduce the account shape without NSS
## changes. A shell fixture grades only startup output transport: a real daemon
## cannot deterministically produce large independent stdout/stderr refusals.
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
  from repro_core/paths import runquotaEndpointPath
  from runquota_ipc import hostWideEndpointDir

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
    ## What a killed daemon leaves behind: an owner-only rendezvous directory
    ## holding a socket inode nothing listens on any more. Closing a bound
    ## socket does not unlink its path.
    if posix.mkdir(directory.cstring, Mode(0o700)) != 0:
      raiseOSError(osLastError(), "mkdir " & directory)
    result = directory / "runquota.sock"
    var listener = net.newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM,
      Protocol.IPPROTO_IP) # protocol 0, the only one AF_UNIX has
    net.bindUnix(listener, result)
    net.close(listener)
    doAssert isSocketInode(result)

  if paramCount() == 1 and paramStr(1) == "--private-action-client":
    doAssert getEnv("RUNQUOTA_ENDPOINT_SCOPE") == "private"
    var client = runquota_client.connectDefault()
    client.close()
    stdout.write("private-action-connected\n")
    quit(0)

  suite "auto-started RunQuota owns a private endpoint":
    setup:
      let root = createTempDir("repro-private-policy-", "")
      releaseDirAtProcessExit(root)
      releaseDirAtProcessExit(parentDir(runquotaEndpointPath(
        "reprobuild-runquota-" & $getCurrentProcessId())))
      var saved: seq[tuple[key: string, present: bool, value: string]]
      for key in ["RUNQUOTA_SOCKET", "RUNQUOTA_ENDPOINT_SCOPE",
          "RUNQUOTA_ENDPOINT_OWNER_UID", "RUNQUOTA_ENDPOINT_GROUP",
          "RUNQUOTAD_BIN", "REPROBUILD_AUTO_RUNQUOTA", "REPRO_DAEMONS_CONFIG"]:
        saved.add((key, existsEnv(key), getEnv(key)))
      let daemonBin = requireRunQuotaDaemonBin(getCurrentDir())
      putEnv("REPROBUILD_AUTO_RUNQUOTA", "1")
      putEnv("RUNQUOTA_SOCKET", root / "absent.sock")
      delEnv("RUNQUOTA_ENDPOINT_SCOPE")
      putEnv("RUNQUOTA_ENDPOINT_OWNER_UID", if geteuid() == 0: "1" else: "0")
      putEnv("RUNQUOTA_ENDPOINT_GROUP", "0")
      writeFile(root / "daemons.conf", "")
      putEnv("REPRO_DAEMONS_CONFIG", root / "daemons.conf")
      forgetMachineDeclaredDaemonTrust()
    teardown:
      for entry in saved:
        if entry.present: putEnv(entry.key, entry.value)
        else: delEnv(entry.key)
      removeDir(root)
      forgetMachineDeclaredDaemonTrust()

    test "daemon parent and leased action use invocation ownership":
      putEnv("RUNQUOTAD_BIN", writeRealDaemonWrapper(root, daemonBin))
      var daemon = startAutoRunQuotaIfNeeded(false)
      defer: releaseAutoRunQuotaProcess(daemon)
      require daemon != nil
      let socket = getEnv("RUNQUOTA_SOCKET")
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
      check getEnv("RUNQUOTA_SOCKET") == root / "absent.sock"
      check not existsEnv("RUNQUOTA_ENDPOINT_SCOPE")
      # The invocation created the rendezvous directory, so it removes it.
      check not dirExists(socket.parentDir)

    test "a stale endpoint left at an earlier process's pid does not block start":
      # The kernel reuses pids. A daemon killed before its orderly shutdown
      # leaves `reprobuild-runquota-<pid>/runquota.sock` behind, and a later
      # invocation holding the same pid must neither be refused by it nor
      # delete it: a private bind refuses an existing endpoint, so the
      # invocation's endpoint must not be derivable from its pid.
      let staleDir = parentDir(runquotaEndpointPath(
        "reprobuild-runquota-" & $getCurrentProcessId()))
      removeDir(staleDir)
      let stale = plantStaleSocket(staleDir)
      putEnv("RUNQUOTAD_BIN", writeRealDaemonWrapper(root, daemonBin))
      var daemon = startAutoRunQuotaIfNeeded(false)
      defer: releaseAutoRunQuotaProcess(daemon)
      require daemon != nil
      let socket = getEnv("RUNQUOTA_SOCKET")
      check socket != stale
      check socket.parentDir != staleDir
      check getFilePermissions(socket.parentDir) ==
        {fpUserRead, fpUserWrite, fpUserExec}
      var client = runquota_client.connectDefault()
      client.close()
      releaseAutoRunQuotaProcess(daemon)
      check not dirExists(socket.parentDir)
      # Not ours, so not touched.
      check isSocketInode(stale)
      removeDir(staleDir)

    test "two invocations in one process never share a rendezvous directory":
      putEnv("RUNQUOTAD_BIN", writeRealDaemonWrapper(root, daemonBin))
      var first = startAutoRunQuotaIfNeeded(false)
      defer: releaseAutoRunQuotaProcess(first)
      require first != nil
      let firstSocket = getEnv("RUNQUOTA_SOCKET")
      releaseAutoRunQuotaProcess(first)
      check not dirExists(firstSocket.parentDir)
      var second = startAutoRunQuotaIfNeeded(false)
      defer: releaseAutoRunQuotaProcess(second)
      require second != nil
      let secondSocket = getEnv("RUNQUOTA_SOCKET")
      check secondSocket.parentDir != firstSocket.parentDir
      releaseAutoRunQuotaProcess(second)
      check not dirExists(secondSocket.parentDir)

    test "startup error retains both streams without filling a pipe":
      let wrapper = root / "refusing-runquotad"
      writeFile(wrapper, "#!/bin/sh\n" &
        "printf '%s' \"$2\" > " & quoteShell(root / "socket-arg") & "\n" &
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
      check "did not become reachable" in message
      # The error says how the wait ended: the daemon exited by itself, and
      # with which status -- not merely that it was not reachable.
      check "it exited before it listened" in message
      check "with exit code 23" in message
      check "still running" notin message
      check "specific startup stdout reason" in message
      check "specific startup stderr refusal" in message
      check "truncated" in message
      check getEnv("RUNQUOTA_SOCKET") == root / "absent.sock"
      check not existsEnv("RUNQUOTA_ENDPOINT_SCOPE")
      # The refused daemon was handed `--socket <path>` first; the directory
      # the invocation created for it must not outlive the failed start.
      let attempted = readFile(root / "socket-arg")
      check attempted.endsWith("/runquota.sock")
      check not dirExists(attempted.parentDir)

    test "a daemon killed by a signal before it listens is reported as such":
      # A signal is a different fate from an exit code, and the error must
      # not fold one into the other: `exit 137` and SIGKILL are not the same
      # report to whoever reads it.
      let wrapper = root / "signalled-runquotad"
      writeFile(wrapper, "#!/bin/sh\n" &
        "printf 'killing myself before I listen\\n' >&2\nkill -9 $$\n")
      setFilePermissions(wrapper, {fpUserRead, fpUserWrite, fpUserExec})
      putEnv("RUNQUOTAD_BIN", wrapper)
      var message = ""
      try:
        var daemon = startAutoRunQuotaIfNeeded(false)
        releaseAutoRunQuotaProcess(daemon)
      except OSError as error:
        message = error.msg
      checkpoint message
      check "did not become reachable" in message
      check "it exited before it listened" in message
      check "with signal 9" in message
      check "exit code" notin message
      check "killing myself before I listen" in message

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

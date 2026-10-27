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
      let wrapper = root / "runquotad"
      let hostFile = root / "host.toml"
      writeFile(hostFile, "schema = \"runquota.host-config.v1\"\n")
      writeFile(wrapper, "#!/bin/sh\nexec " & quoteShell(daemonBin) &
        " --host-config " & quoteShell(hostFile) &
        " --host-identity-file " & quoteShell(root / "host-id") &
        " --observation-db " & quoteShell(root / "observations.sqlite") &
        " --ambient-sample-interval-millis 0 \"$@\"\n")
      setFilePermissions(wrapper, {fpUserRead, fpUserWrite, fpUserExec})
      putEnv("RUNQUOTAD_BIN", wrapper)
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
      removeDir(socket.parentDir)

    test "startup error retains both streams without filling a pipe":
      let wrapper = root / "refusing-runquotad"
      writeFile(wrapper, "#!/bin/sh\n" &
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
      check "specific startup stdout reason" in message
      check "specific startup stderr refusal" in message
      check "truncated" in message
      check getEnv("RUNQUOTA_SOCKET") == root / "absent.sock"
      check not existsEnv("RUNQUOTA_ENDPOINT_SCOPE")

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

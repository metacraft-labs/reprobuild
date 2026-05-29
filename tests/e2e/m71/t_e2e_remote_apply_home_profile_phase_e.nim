## M71 Phase E gate: public home-profile remote apply.
##
## This drives `repro home enable <activity> --host <target> --now`
## over a real user-owned loopback sshd. It covers the public wiring,
## source-side target preflight, and the failure semantics that preserve
## the local intent edit after build/transfer/activation failures.

import std/[net, os, osproc, sequtils, streams, strtabs, strutils, tempfiles,
    unittest]

import repro_home_generations
import repro_home_intent
import repro_local_store

const ProjectRoot = currentSourcePath().parentDir().parentDir()
  .parentDir().parentDir()

const
  ActivityName = "remote_activity"
  PackageName = "m71-phase-e-fixture"
  SourceHostName = "m71-phase-e-source"
  TargetHostName = "localhost"

type
  CmdResult = tuple[exitCode: int; output: string]

  SshHarness = object
    ssh*: string
    sshd*: string
    sshKeygen*: string
    port*: int
    clientKey*: string
    knownHosts*: string
    process*: Process

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  let candidate = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(candidate),
    "repro binary not found at " & candidate &
    "; build with `just build` first"
  candidate

proc findRequiredExe(name: string; extra: openArray[string] = []): string =
  result = findExe(name)
  if result.len > 0:
    return
  for candidate in extra:
    if fileExists(candidate):
      return candidate
  doAssert false, "M71 Phase E blocker: required executable not found: " & name

proc runProgram(program: string; args: openArray[string];
                envOverrides: openArray[tuple[k, v: string]] = []): CmdResult =
  var processEnv = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    processEnv[k] = v
  for kv in envOverrides:
    processEnv[kv.k] = kv.v
  let p = startProcess(program, args = @args, env = processEnv,
    options = {poUsePath, poStdErrToStdOut})
  let output = p.outputStream().readAll()
  let code = p.waitForExit()
  p.close()
  (exitCode: code, output: output)

proc runRepro(envOverrides: openArray[tuple[k, v: string]];
              args: openArray[string]): CmdResult =
  runProgram(reproBinary(), args, envOverrides)

proc fieldValue(output, name: string): string =
  let prefix = name & ": "
  for line in output.splitLines():
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()
  doAssert false, "missing field " & name & " in output:\n" & output

proc chooseLoopbackPort(): int =
  var s = newSocket()
  s.bindAddr(Port(0), "127.0.0.1")
  let local = s.getLocalAddr()
  s.close()
  int(local[1])

proc writeFixtureExe(path: string): string =
  when defined(windows):
    result =
      "@echo off\r\n" &
      "echo m71-fixture phase-e\r\n"
    writeFile(path, result)
  else:
    result =
      "#!/bin/sh\n" &
      "set -eu\n" &
      "echo m71-fixture phase-e\n"
    writeFile(path, result)
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc sshArgs(h: SshHarness): seq[string] =
  @[
    "-F", "/dev/null",
    "-o", "UserKnownHostsFile=" & h.knownHosts,
    "-o", "GlobalKnownHostsFile=/dev/null",
    "-o", "StrictHostKeyChecking=no",
    "-o", "IdentitiesOnly=yes",
    "-o", "PasswordAuthentication=no",
    "-o", "KbdInteractiveAuthentication=no",
    "-i", h.clientKey,
    "-p", $h.port]

proc startLoopbackSshd(tempRoot: string): SshHarness =
  result.ssh = findRequiredExe("ssh", ["/usr/bin/ssh"])
  result.sshKeygen = findRequiredExe("ssh-keygen", ["/usr/bin/ssh-keygen"])
  result.sshd = findRequiredExe("sshd", ["/usr/sbin/sshd", "/usr/bin/sshd"])
  result.port = chooseLoopbackPort()
  let sshDir = tempRoot / "sshd"
  createDir(sshDir)
  let hostKey = sshDir / "host_ed25519"
  result.clientKey = sshDir / "client_ed25519"
  result.knownHosts = sshDir / "known_hosts"
  let authorizedKeys = sshDir / "authorized_keys"
  let pidFile = sshDir / "sshd.pid"
  let config = sshDir / "sshd_config"

  let hostKeygen = runProgram(result.sshKeygen,
    ["-q", "-t", "ed25519", "-N", "", "-f", hostKey])
  doAssert hostKeygen.exitCode == 0,
    "M71 Phase E blocker: ssh-keygen failed for host key:\n" &
    hostKeygen.output
  let clientKeygen = runProgram(result.sshKeygen,
    ["-q", "-t", "ed25519", "-N", "", "-f", result.clientKey])
  doAssert clientKeygen.exitCode == 0,
    "M71 Phase E blocker: ssh-keygen failed for client key:\n" &
    clientKeygen.output
  writeFile(authorizedKeys, readFile(result.clientKey & ".pub"))
  writeFile(result.knownHosts, "")

  writeFile(config,
    "Port " & $result.port & "\n" &
    "ListenAddress 127.0.0.1\n" &
    "HostKey " & hostKey & "\n" &
    "PidFile " & pidFile & "\n" &
    "AuthorizedKeysFile " & authorizedKeys & "\n" &
    "StrictModes no\n" &
    "PubkeyAuthentication yes\n" &
    "PasswordAuthentication no\n" &
    "KbdInteractiveAuthentication no\n" &
    "ChallengeResponseAuthentication no\n" &
    "UsePAM no\n" &
    "PermitRootLogin no\n" &
    "LogLevel ERROR\n")

  result.process = startProcess(result.sshd,
    args = ["-D", "-e", "-f", config],
    options = {poStdErrToStdOut})

  var last = ""
  for _ in 0 ..< 60:
    sleep(100)
    let probe = runProgram(result.ssh,
      sshArgs(result) & @["localhost", "true"])
    if probe.exitCode == 0:
      return
    last = probe.output
    if not result.process.running():
      let daemonOutput = result.process.outputStream().readAll()
      doAssert false,
        "M71 Phase E blocker: loopback sshd exited before accepting " &
        "connections.\nsshd output:\n" & daemonOutput &
        "\nlast ssh probe:\n" & last

  doAssert false,
    "M71 Phase E blocker: loopback sshd did not accept connections on " &
    "127.0.0.1:" & $result.port & "\nlast ssh probe:\n" & last

proc stopLoopbackSshd(h: var SshHarness) =
  if h.process != nil:
    try:
      if h.process.running():
        h.process.terminate()
        discard h.process.waitForExit()
    except CatchableError:
      discard
    try: h.process.close() except CatchableError: discard

proc writeProfile(profileDir: string) =
  createDir(profileDir)
  writeFile(profileDir / "home.nim",
    "import repro/profile\n\n" &
    "profile \"m71-phase-e\":\n" &
    "  activity " & ActivityName & ":\n" &
    "    " & PackageName & "\n")

proc commonEnv(profileDir, sourceStateDir, sourceStoreRoot, sourceHomeDir,
               exePath, generatedRel, generatedContent: string):
    seq[tuple[k, v: string]] =
  @[
    (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
    (k: "REPRO_HOME_STATE_DIR", v: sourceStateDir),
    (k: "REPRO_STORE_ROOT", v: sourceStoreRoot),
    (k: "HOME", v: sourceHomeDir),
    (k: "USERPROFILE", v: sourceHomeDir),
    (k: "REPRO_HOST", v: SourceHostName),
    (k: "REPRO_HOME_PACKAGE_CATALOG", v: PackageName),
    (k: "REPRO_TEST_PACKAGE_SOURCE", v: PackageName & "=" & exePath),
    (k: "REPRO_TEST_PACKAGE_GENERATES",
      v: PackageName & "=" & generatedRel & ":" & generatedContent)]

proc remoteActivityArgs(command: string; h: SshHarness; targetStoreRoot,
                        targetStateDir, targetHomeDir: string): seq[string] =
  result = @[
    "home", command, ActivityName,
    "--host", TargetHostName,
    "--now",
    "--remote-repro", reproBinary(),
    "--target-store-root", targetStoreRoot,
    "--target-state-dir", targetStateDir,
    "--target-home-dir", targetHomeDir,
    "--ssh", h.ssh,
    "--port", $h.port]
  for opt in [
      "-F", "/dev/null",
      "-o", "UserKnownHostsFile=" & h.knownHosts,
      "-o", "GlobalKnownHostsFile=/dev/null",
      "-o", "StrictHostKeyChecking=no",
      "-o", "IdentitiesOnly=yes",
      "-o", "PasswordAuthentication=no",
      "-o", "KbdInteractiveAuthentication=no",
      "-i", h.clientKey]:
    result.add("--ssh-option")
    result.add(opt)

proc remoteDevStoreActivityArgs(command: string; h: SshHarness;
                                targetStoreRoot, targetStoreEndpoint,
                                targetStateDir, targetHomeDir: string):
    seq[string] =
  result = remoteActivityArgs(command, h, targetStoreRoot, targetStateDir,
    targetHomeDir)
  result.add("--target-store-daemon")
  result.add("dev")
  result.add("--target-store-endpoint")
  result.add(targetStoreEndpoint)

proc remoteEnableArgs(h: SshHarness; targetStoreRoot, targetStateDir,
                      targetHomeDir: string): seq[string] =
  remoteActivityArgs("enable", h, targetStoreRoot, targetStateDir,
    targetHomeDir)

proc remoteDisableArgs(h: SshHarness; targetStoreRoot, targetStateDir,
                       targetHomeDir: string): seq[string] =
  remoteActivityArgs("disable", h, targetStoreRoot, targetStateDir,
    targetHomeDir)

proc q(value: string): string = quoteShell(value)

proc remoteStoreDaemonCommand(action, targetStoreRoot,
                              targetStoreEndpoint: string): string =
  [reproBinary(), "store", "daemon", action, "--dev",
    "--store-root", targetStoreRoot,
    "--endpoint", targetStoreEndpoint].mapIt(q(it)).join(" ")

proc runSsh(h: SshHarness; remoteCommand: string): CmdResult =
  runProgram(h.ssh, sshArgs(h) & @["localhost", remoteCommand])

proc otherPlatform(): string =
  let source = currentHostContext().platform
  if source == "linux": "macos" else: "linux"

suite "M71 Phase E: public remote home-profile apply":
  test "enable --host --now builds, transfers, activates, and is idempotent":
    when defined(windows):
      doAssert false,
        "M71 Phase E gate must not be skipped; Windows needs a " &
        "target-side launcher implementation or an explicit fail-closed " &
        "fixture with no launchers"
    else:
      let tempRoot = createTempDir("repro-m71-public-remote-apply-", "")
      var sshd: SshHarness
      defer:
        stopLoopbackSshd(sshd)
        try: removeDir(tempRoot) except OSError: discard

      let sourceStateDir = tempRoot / "source-state"
      let targetStateDir = tempRoot / "target-state"
      let sourceStoreRoot = tempRoot / "source-store"
      let targetStoreRoot = tempRoot / "target-store"
      let profileDir = tempRoot / "profile"
      let sourceHomeDir = tempRoot / "source-home"
      let targetHomeDir = tempRoot / "target-home"
      let fixtureDir = tempRoot / "fixture"
      createDir(sourceStateDir)
      createDir(targetStateDir)
      createDir(sourceStoreRoot)
      createDir(targetStoreRoot)
      createDir(sourceHomeDir)
      createDir(targetHomeDir)
      createDir(fixtureDir)
      writeProfile(profileDir)

      let exePath = fixtureDir / PackageName
      discard writeFixtureExe(exePath)
      let generatedRel = ".m71-phase-e-generated"
      let generatedPath = targetHomeDir / generatedRel
      let generatedContent = "phase-e generated content"
      let env = commonEnv(profileDir, sourceStateDir, sourceStoreRoot,
        sourceHomeDir, exePath, generatedRel, generatedContent)

      sshd = startLoopbackSshd(tempRoot)
      let first = runRepro(env, remoteEnableArgs(sshd, targetStoreRoot,
        targetStateDir, targetHomeDir))
      check first.exitCode == 0
      check fieldValue(first.output, "remoteApplyStatus") == "activated"
      check fieldValue(first.output, "targetHost") == TargetHostName
      check fieldValue(first.output, "transferStatus") == "sent"
      let generationId = fieldValue(first.output, "remoteGenerationId")
      let bundleDigest = fieldValue(first.output, "bundleDigest")
      check fieldValue(first.output, "localGenerationId") == generationId
      check fieldValue(first.output, "targetCurrent") == generationId

      let profileText = readFile(profileDir / "home.nim")
      check profileText.contains("\"" & TargetHostName & "\": [" &
        ActivityName & "]")
      check readCurrentGenerationId(targetStateDir) == generationId
      check fileExists(pointerPath(targetStateDir, generationId))
      check fileExists(generatedPath)
      check readFile(generatedPath) == generatedContent
      check not fileExists(sourceHomeDir / generatedRel)

      var targetStore = openStore(targetStoreRoot)
      let targetBundle = targetStore.readCasBlob(parsePrefixIdHex(bundleDigest))
      check targetBundle.len > 0
      let targetRows = targetStore.listPrefixes()
      let targetRoots = targetStore.listRoots()
      check targetRows.len == 1
      check targetRoots.len == 1
      check targetRoots[0].rootId == generationId
      check targetRoots[0].kind == "profile"
      let targetPrefix = targetStore.absolutePrefixPath(
        targetRows[0].realizedPath)
      check targetPrefix.startsWith(targetStoreRoot)
      check dirExists(targetPrefix)
      let launcherPath = generationDir(targetStateDir, generationId) /
        "bin" / PackageName
      check fileExists(launcherPath)
      let launcherBody = readFile(launcherPath)
      check launcherBody.contains(targetStoreRoot)
      check launcherBody.contains(targetPrefix)
      check not launcherBody.contains(sourceStoreRoot)
      check fileExists(currentPath(targetStateDir) / "bin" / PackageName)
      let prefixCount = targetRows.len
      let rootCount = targetRoots.len
      targetStore.close()

      let second = runRepro(env, remoteEnableArgs(sshd, targetStoreRoot,
        targetStateDir, targetHomeDir))
      check second.exitCode == 0
      check fieldValue(second.output, "remoteApplyStatus") == "activated"
      check fieldValue(second.output, "remoteGenerationId") == generationId
      check fieldValue(second.output, "bundleDigest") == bundleDigest
      check fieldValue(second.output, "transferStatus") == "already-present"

      var targetStoreAgain = openStore(targetStoreRoot)
      check targetStoreAgain.listPrefixes().len == prefixCount
      check targetStoreAgain.listRoots().len == rootCount
      check readCurrentGenerationId(targetStateDir) == generationId
      check readFile(generatedPath) == generatedContent
      targetStoreAgain.close()

      let disabled = runRepro(env, remoteDisableArgs(sshd, targetStoreRoot,
        targetStateDir, targetHomeDir))
      check disabled.exitCode == 0
      check fieldValue(disabled.output, "remoteApplyStatus") == "activated"
      let disabledGenerationId = fieldValue(disabled.output,
        "remoteGenerationId")
      check disabledGenerationId != generationId
      check readCurrentGenerationId(targetStateDir) == disabledGenerationId
      check not fileExists(generatedPath)
      check not fileExists(currentPath(targetStateDir) / "bin" / PackageName)
      let disabledProfile = readFile(profileDir / "home.nim")
      check disabledProfile.contains("\"" & TargetHostName & "\": []")

  test "daemon-backed dev-store mode starts reprostored and remote applies":
    when defined(windows):
      doAssert false,
        "M71 daemon-backed dev-store gate is POSIX-only in this slice"
    else:
      let tempRoot = createTempDir("repro-m71-public-remote-devdaemon-", "")
      let targetStoreEndpoint =
        "/tmp/repro-m71-" & $getCurrentProcessId() & "-dev-store.sock"
      var sshd: SshHarness
      defer:
        if sshd.process != nil:
          discard runSsh(sshd, remoteStoreDaemonCommand("stop",
            tempRoot / "target-store", targetStoreEndpoint))
        try: removeFile(targetStoreEndpoint) except OSError: discard
        try: removeFile(targetStoreEndpoint & ".status") except OSError: discard
        stopLoopbackSshd(sshd)
        try: removeDir(tempRoot) except OSError: discard

      let sourceStateDir = tempRoot / "source-state"
      let targetStateDir = tempRoot / "target-state"
      let sourceStoreRoot = tempRoot / "source-store"
      let targetStoreRoot = tempRoot / "target-store"
      let profileDir = tempRoot / "profile"
      let sourceHomeDir = tempRoot / "source-home"
      let targetHomeDir = tempRoot / "target-home"
      let fixtureDir = tempRoot / "fixture"
      createDir(sourceStateDir)
      createDir(targetStateDir)
      createDir(sourceStoreRoot)
      createDir(targetStoreRoot)
      createDir(sourceHomeDir)
      createDir(targetHomeDir)
      createDir(fixtureDir)
      writeProfile(profileDir)

      let exePath = fixtureDir / PackageName
      discard writeFixtureExe(exePath)
      let generatedRel = ".m71-phase-e-devdaemon-generated"
      let generatedPath = targetHomeDir / generatedRel
      let generatedContent = "phase-e dev daemon generated content"
      let env = commonEnv(profileDir, sourceStateDir, sourceStoreRoot,
        sourceHomeDir, exePath, generatedRel, generatedContent)

      sshd = startLoopbackSshd(tempRoot)
      let applied = runRepro(env, remoteDevStoreActivityArgs("enable", sshd,
        targetStoreRoot, targetStoreEndpoint, targetStateDir, targetHomeDir))
      check applied.exitCode == 0
      check fieldValue(applied.output, "remoteApplyStatus") == "activated"
      check fieldValue(applied.output, "targetStoreDaemon") ==
        "development-store"
      check fieldValue(applied.output, "targetStoreEndpoint") ==
        targetStoreEndpoint
      check applied.output.contains("targetStoreDaemonPid: ")
      check not applied.output.contains("repro daemon")
      check not applied.output.contains("repro-daemon")
      check not applied.output.contains("watch daemon")

      let generationId = fieldValue(applied.output, "remoteGenerationId")
      check readCurrentGenerationId(targetStateDir) == generationId
      check fileExists(generatedPath)
      check readFile(generatedPath) == generatedContent

      let status = runSsh(sshd, remoteStoreDaemonCommand("status",
        targetStoreRoot, targetStoreEndpoint))
      check status.exitCode == 0
      check status.output.contains("repro store daemon: running")
      check fieldValue(status.output, "profile") == "development-store"
      check fieldValue(status.output, "endpoint") == targetStoreEndpoint
      check fieldValue(status.output, "store-root") == targetStoreRoot
      check not status.output.contains("repro daemon")
      check not status.output.contains("watch daemon")

      let watchDaemon = runSsh(sshd, [reproBinary(), "daemon"].mapIt(q(it)).
        join(" "))
      check watchDaemon.exitCode != 0
      check not watchDaemon.output.contains("development-store")
      check not watchDaemon.output.contains("repro store daemon: running")

      var targetStore = openStore(targetStoreRoot)
      check targetStore.listPrefixes().len == 1
      check targetStore.listRoots().len == 1
      targetStore.close()

      let reused = runRepro(env, remoteDevStoreActivityArgs("enable", sshd,
        targetStoreRoot, targetStoreEndpoint, targetStateDir, targetHomeDir))
      check reused.exitCode == 0
      check fieldValue(reused.output, "remoteApplyStatus") == "activated"
      check fieldValue(reused.output, "targetStoreEndpoint") ==
        targetStoreEndpoint
      check fieldValue(reused.output, "targetStoreDaemonPid") ==
        fieldValue(applied.output, "targetStoreDaemonPid")
      check fieldValue(reused.output, "transferStatus") == "already-present"
      var targetStoreAfterReuse = openStore(targetStoreRoot)
      defer: targetStoreAfterReuse.close()
      check targetStoreAfterReuse.listPrefixes().len == 1
      check targetStoreAfterReuse.listRoots().len == 1

  test "--host without --now is a pure intent edit and does not contact SSH":
    let tempRoot = createTempDir("repro-m71-public-remote-intent-", "")
    defer:
      try: removeDir(tempRoot) except OSError: discard

    let sourceStateDir = tempRoot / "source-state"
    let sourceStoreRoot = tempRoot / "source-store"
    let targetStateDir = tempRoot / "target-state"
    let targetStoreRoot = tempRoot / "target-store"
    let profileDir = tempRoot / "profile"
    let sourceHomeDir = tempRoot / "source-home"
    let targetHomeDir = tempRoot / "target-home"
    let fixtureDir = tempRoot / "fixture"
    createDir(sourceHomeDir)
    createDir(targetHomeDir)
    createDir(fixtureDir)
    writeProfile(profileDir)

    let exePath = fixtureDir / PackageName
    discard writeFixtureExe(exePath)
    let env = commonEnv(profileDir, sourceStateDir, sourceStoreRoot,
      sourceHomeDir, exePath, ".m71-phase-e-no-now", "no-now")
    let missingSsh = tempRoot / "missing-ssh"

    let edited = runRepro(env, [
      "home", "enable", ActivityName,
      "--host", TargetHostName,
      "--ssh", missingSsh,
      "--target-store-root", targetStoreRoot,
      "--target-state-dir", targetStateDir,
      "--target-home-dir", targetHomeDir])
    check edited.exitCode == 0
    check readFile(profileDir / "home.nim").contains(
      "\"" & TargetHostName & "\": [" & ActivityName & "]")
    check readCurrentGenerationId(sourceStateDir) == ""
    check readCurrentGenerationId(targetStateDir) == ""
    check not dirExists(sourceStoreRoot)
    check not dirExists(targetStoreRoot)

  test "cross-platform refusal preserves the local intent edit before SSH":
    let tempRoot = createTempDir("repro-m71-public-remote-cross-", "")
    defer:
      try: removeDir(tempRoot) except OSError: discard

    let sourceStateDir = tempRoot / "source-state"
    let sourceStoreRoot = tempRoot / "source-store"
    let targetStateDir = tempRoot / "target-state"
    let targetStoreRoot = tempRoot / "target-store"
    let profileDir = tempRoot / "profile"
    let sourceHomeDir = tempRoot / "source-home"
    let targetHomeDir = tempRoot / "target-home"
    let fixtureDir = tempRoot / "fixture"
    createDir(sourceHomeDir)
    createDir(targetHomeDir)
    createDir(fixtureDir)
    writeProfile(profileDir)

    let exePath = fixtureDir / PackageName
    discard writeFixtureExe(exePath)
    let env = commonEnv(profileDir, sourceStateDir, sourceStoreRoot,
      sourceHomeDir, exePath, ".m71-phase-e-cross", "cross")
    let targetPlatform = otherPlatform()
    let refused = runRepro(env, [
      "home", "enable", ActivityName,
      "--host", TargetHostName,
      "--now",
      "--ssh", tempRoot / "missing-ssh",
      "--target-store-root", targetStoreRoot,
      "--target-state-dir", targetStateDir,
      "--target-home-dir", targetHomeDir,
      "--target-platform", targetPlatform])

    check refused.exitCode != 0
    check refused.output.contains("remoteApplyPhase: preflight")
    check refused.output.contains("sourcePlatform: " &
      currentHostContext().platform)
    check refused.output.contains("targetPlatform: " & targetPlatform)
    check refused.output.contains("missingCapability: cross-builder")
    check refused.output.contains("cross-builder capability")
    check readFile(profileDir / "home.nim").contains(
      "\"" & TargetHostName & "\": [" & ActivityName & "]")
    check readCurrentGenerationId(sourceStateDir) == ""
    check readCurrentGenerationId(targetStateDir) == ""
    check not dirExists(sourceStoreRoot)
    check not dirExists(targetStoreRoot)

  test "transfer failure preserves intent and does not activate target":
    let tempRoot = createTempDir("repro-m71-public-remote-transfer-fail-", "")
    defer:
      try: removeDir(tempRoot) except OSError: discard

    let sourceStateDir = tempRoot / "source-state"
    let sourceStoreRoot = tempRoot / "source-store"
    let targetStateDir = tempRoot / "target-state"
    let targetStoreRoot = tempRoot / "target-store"
    let profileDir = tempRoot / "profile"
    let sourceHomeDir = tempRoot / "source-home"
    let targetHomeDir = tempRoot / "target-home"
    let fixtureDir = tempRoot / "fixture"
    createDir(sourceHomeDir)
    createDir(targetHomeDir)
    createDir(fixtureDir)
    writeProfile(profileDir)

    let exePath = fixtureDir / PackageName
    discard writeFixtureExe(exePath)
    let generatedRel = ".m71-phase-e-transfer-fail"
    let env = commonEnv(profileDir, sourceStateDir, sourceStoreRoot,
      sourceHomeDir, exePath, generatedRel, "transfer-fail")

    let failed = runRepro(env, [
      "home", "enable", ActivityName,
      "--host", TargetHostName,
      "--now",
      "--ssh", tempRoot / "missing-ssh",
      "--target-store-root", targetStoreRoot,
      "--target-state-dir", targetStateDir,
      "--target-home-dir", targetHomeDir])

    check failed.exitCode != 0
    check failed.output.contains("remoteApplyPhase: transfer")
    check failed.output.contains("localIntentStatus: preserved")
    check not failed.output.contains("remoteApplyPhase: activate")
    check readFile(profileDir / "home.nim").contains(
      "\"" & TargetHostName & "\": [" & ActivityName & "]")
    check readCurrentGenerationId(targetStateDir) == ""
    check not dirExists(targetStoreRoot)
    check not fileExists(sourceHomeDir / generatedRel)
    check not fileExists(targetHomeDir / generatedRel)

  test "activation failure after transfer preserves intent and leaves bundle CAS":
    when defined(windows):
      doAssert false,
        "M71 Phase E gate must not be skipped; Windows needs a " &
        "target-side launcher implementation or an explicit fail-closed " &
        "fixture with no launchers"
    else:
      let tempRoot = createTempDir("repro-m71-public-remote-fail-", "")
      var sshd: SshHarness
      defer:
        stopLoopbackSshd(sshd)
        try: removeDir(tempRoot) except OSError: discard

      let sourceStateDir = tempRoot / "source-state"
      let targetStateDir = tempRoot / "target-state"
      let sourceStoreRoot = tempRoot / "source-store"
      let targetStoreRoot = tempRoot / "target-store"
      let profileDir = tempRoot / "profile"
      let sourceHomeDir = tempRoot / "source-home"
      let targetHomeDir = tempRoot / "target-home"
      let fixtureDir = tempRoot / "fixture"
      createDir(sourceStateDir)
      createDir(targetStateDir)
      createDir(sourceStoreRoot)
      createDir(targetStoreRoot)
      createDir(sourceHomeDir)
      createDir(targetHomeDir)
      createDir(fixtureDir)
      writeProfile(profileDir)

      let exePath = fixtureDir / PackageName
      discard writeFixtureExe(exePath)
      let generatedRel = ".m71-phase-e-conflict"
      let generatedPath = targetHomeDir / generatedRel
      writeFile(generatedPath, "conflicting target bytes")
      let env = commonEnv(profileDir, sourceStateDir, sourceStoreRoot,
        sourceHomeDir, exePath, generatedRel, "desired remote bytes")

      sshd = startLoopbackSshd(tempRoot)
      let failed = runRepro(env, remoteEnableArgs(sshd, targetStoreRoot,
        targetStateDir, targetHomeDir))
      check failed.exitCode != 0
      check failed.output.contains("remoteApplyPhase: activate")
      check failed.output.contains("localIntentStatus: preserved")
      check failed.output.contains("generated file target already exists")
      let bundleDigest = fieldValue(failed.output, "bundleDigest")
      let targetBundlePath = fieldValue(failed.output, "targetBundlePath")
      check targetBundlePath.startsWith(targetStoreRoot)

      check readFile(profileDir / "home.nim").contains(
        "\"" & TargetHostName & "\": [" & ActivityName & "]")
      check readCurrentGenerationId(targetStateDir) == ""
      check readFile(generatedPath) == "conflicting target bytes"
      check not fileExists(sourceHomeDir / generatedRel)

      var targetStore = openStore(targetStoreRoot)
      defer: targetStore.close()
      check targetStore.readCasBlob(parsePrefixIdHex(bundleDigest)).len > 0

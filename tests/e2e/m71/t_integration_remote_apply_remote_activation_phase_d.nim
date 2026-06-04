## M71 Phase D gate: target-side remote activation runtime.
##
## This extends the Phase C loopback-SSH transfer harness by running
## the target activation command as the SSH user. It still does not
## claim public `repro home enable --host --now` wiring or Phase E
## failure/cross-platform semantics.

import std/[net, os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_home_generations
import repro_local_store

import repro_test_support

const ProjectRoot = currentSourcePath().parentDir().parentDir()
  .parentDir().parentDir()

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
  doAssert false, "M71 Phase D blocker: required executable not found: " & name

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
      "echo m71-fixture phase-d\r\n"
    writeFile(path, result)
  else:
    result =
      "#!/bin/sh\n" &
      "set -eu\n" &
      "echo m71-fixture phase-d\n"
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
    "M71 Phase D blocker: ssh-keygen failed for host key:\n" &
    hostKeygen.output
  let clientKeygen = runProgram(result.sshKeygen,
    ["-q", "-t", "ed25519", "-N", "", "-f", result.clientKey])
  doAssert clientKeygen.exitCode == 0,
    "M71 Phase D blocker: ssh-keygen failed for client key:\n" &
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
        "M71 Phase D blocker: loopback sshd exited before accepting " &
        "connections.\nsshd output:\n" & daemonOutput &
        "\nlast ssh probe:\n" & last

  doAssert false,
    "M71 Phase D blocker: loopback sshd did not accept connections on " &
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

proc remoteCommand(parts: openArray[string]): string =
  for idx, part in parts:
    if idx > 0:
      result.add(" ")
    result.add(quoteShell(part))

proc runSsh(h: SshHarness; command: string): CmdResult =
  runProgram(h.ssh, sshArgs(h) & @["localhost", command])

proc keyFromDigest(digest: Digest256): PrefixIdBytes =
  for i in 0 ..< 32:
    result[i] = digest[i]

suite "M71 Phase D: remote activation over loopback SSH":
  when isNixSupported:
    test "target activation commits generation, roots, current, launchers, and owned files idempotently":
      when defined(windows):
        doAssert false,
          "M71 Phase D gate must not be skipped; Windows needs a " &
          "target-side launcher implementation or an explicit fail-closed " &
          "fixture with no launchers"
      else:
        let tempRoot = createTempDir("repro-m71-remote-activate-", "")
        var sshd: SshHarness
        defer:
          stopLoopbackSshd(sshd)
          try: removeDir(tempRoot) except OSError: discard

        let sourceStateDir = tempRoot / "source-state"
        let targetStateDir = tempRoot / "target-state"
        let sourceStoreRoot = tempRoot / "source-store"
        let targetStoreRoot = tempRoot / "target-store"
        let profileDir = tempRoot / "profile"
        let targetHomeDir = tempRoot / "target-home"
        let fixtureDir = tempRoot / "fixture"
        createDir(sourceStateDir)
        createDir(targetStateDir)
        createDir(sourceStoreRoot)
        createDir(targetStoreRoot)
        createDir(profileDir)
        createDir(targetHomeDir)
        createDir(fixtureDir)

        writeFile(profileDir / "home.nim",
          "import repro_profile\n\n" &
          "profile \"m71-phase-d\":\n" &
          "  activity default:\n" &
          "    `m71-fixture`\n")

        let exeName = "m71-fixture"
        let exePath = fixtureDir / exeName
        discard writeFixtureExe(exePath)
        let generatedRel = ".m71-phase-d-generated"
        let generatedPath = targetHomeDir / generatedRel
        let generatedContent = "phase-d generated content"

        let env = @[
          (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
          (k: "REPRO_HOME_STATE_DIR", v: sourceStateDir),
          (k: "REPRO_STORE_ROOT", v: sourceStoreRoot),
          (k: "HOME", v: targetHomeDir),
          (k: "USERPROFILE", v: targetHomeDir),
          (k: "REPRO_HOST", v: "m71-target-host"),
          (k: "REPRO_HOME_PACKAGE_CATALOG", v: "m71-fixture"),
          (k: "REPRO_TEST_PACKAGE_SOURCE", v: "m71-fixture=" & exePath),
          (k: "REPRO_TEST_PACKAGE_GENERATES",
            v: "m71-fixture=" & generatedRel & ":" & generatedContent)]

        let apply = runRepro(env, ["home", "apply"])
        check apply.exitCode == 0
        check apply.output.contains("applied generation ")
        check fileExists(generatedPath)

        let built = runRepro(env, ["home", "__build-bundle"])
        check built.exitCode == 0
        let bundleDigestHex = fieldValue(built.output, "bundleDigest")
        var sourceStore = openStore(sourceStoreRoot)
        let bundleDigest = parsePrefixIdHex(bundleDigestHex)
        let sourceBundle = decodeActivationBundleBytes(
          sourceStore.readCasBlob(bundleDigest), fieldValue(built.output,
            "bundlePath"))
        check sourceBundle.casBlobs.len >= 2
        sourceStore.close()

        removeFile(generatedPath)
        check not fileExists(generatedPath)

        sshd = startLoopbackSshd(tempRoot)
        var transferArgs = @[
          "home", "__transfer-bundle",
          "--bundle-digest", bundleDigestHex,
          "--store-root", sourceStoreRoot,
          "--target", "localhost",
          "--remote-repro", reproBinary(),
          "--target-store-root", targetStoreRoot,
          "--ssh", sshd.ssh,
          "--port", $sshd.port]
        for opt in [
            "-F", "/dev/null",
            "-o", "UserKnownHostsFile=" & sshd.knownHosts,
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "StrictHostKeyChecking=no",
            "-o", "IdentitiesOnly=yes",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-i", sshd.clientKey]:
          transferArgs.add("--ssh-option")
          transferArgs.add(opt)

        let transferred = runRepro([], transferArgs)
        check transferred.exitCode == 0
        check fieldValue(transferred.output, "transferStatus") == "sent"
        check fieldValue(transferred.output, "bundleDigest") ==
          bundleDigestHex.toLowerAscii()

        let activate = runSsh(sshd, remoteCommand([
          reproBinary(), "home", "__remote-activate",
          "--store-root", targetStoreRoot,
          "--state-dir", targetStateDir,
          "--bundle-digest", bundleDigestHex]))
        check activate.exitCode == 0
        check fieldValue(activate.output, "activationStatus") == "activated"
        let generationId = fieldValue(activate.output, "generationId")
        check fieldValue(activate.output, "current") == generationId
        check parseInt(fieldValue(activate.output, "launchersMaterialized")) == 1
        check parseInt(fieldValue(activate.output,
          "generatedFilesMaterialized")) == 1

        check readCurrentGenerationId(targetStateDir) == generationId
        check fileExists(pointerPath(targetStateDir, generationId))
        let targetPointer = readPointerFile(pointerPath(targetStateDir,
          generationId))
        check generationIdHex(targetPointer.generationId) == generationId

        var targetStore = openStore(targetStoreRoot)
        let targetBundleBytes = targetStore.readCasBlob(bundleDigest)
        check targetBundleBytes.len > 0
        let targetRows = targetStore.listPrefixes()
        check targetRows.len == 1
        let targetRoots = targetStore.listRoots()
        check targetRoots.len == 1
        check targetRoots[0].rootId == generationId
        check targetRoots[0].kind == "profile"
        check targetStore.deadSet().len == 0

        let manifest = decodeManifestBytes(targetStore.readCasBlob(
          keyFromDigest(targetPointer.activationManifestDigest)))
        check manifest.exportedCommands.len == 1
        check manifest.generatedFiles.len == 1
        check manifest.generatedFiles[0].absoluteOutputPath == generatedPath

        let targetPrefix = targetStore.absolutePrefixPath(
          targetRows[0].realizedPath)
        check targetPrefix.startsWith(targetStoreRoot)
        check dirExists(targetPrefix)
        check fileExists(targetPrefix / ReceiptFileName)
        let launcherPath = generationDir(targetStateDir, generationId) /
          "bin" / exeName
        check fileExists(launcherPath)
        let launcherBody = readFile(launcherPath)
        check launcherBody.contains(targetStoreRoot)
        check launcherBody.contains(targetPrefix)
        check not launcherBody.contains(sourceStoreRoot)
        check fileExists(currentPath(targetStateDir) / "bin" / exeName)

        check fileExists(generatedPath)
        check readFile(generatedPath) == generatedContent
        let prefixCountAfterFirst = targetRows.len
        let rootCountAfterFirst = targetRoots.len
        targetStore.close()

        let activateAgain = runSsh(sshd, remoteCommand([
          reproBinary(), "__remote-activate",
          "--store-root", targetStoreRoot,
          "--state-dir", targetStateDir,
          "--bundle-digest", bundleDigestHex]))
        check activateAgain.exitCode == 0
        check fieldValue(activateAgain.output, "activationStatus") == "activated"
        check fieldValue(activateAgain.output, "generationId") == generationId
        check parseInt(fieldValue(activateAgain.output,
          "prefixesImported")) == 0
        check parseInt(fieldValue(activateAgain.output,
          "prefixesAlreadyPresent")) == 1

        var targetStore2 = openStore(targetStoreRoot)
        defer: targetStore2.close()
        check targetStore2.listPrefixes().len == prefixCountAfterFirst
        check targetStore2.listRoots().len == rootCountAfterFirst
        check targetStore2.deadSet().len == 0
        check readCurrentGenerationId(targetStateDir) == generationId
        check readFile(generatedPath) == generatedContent

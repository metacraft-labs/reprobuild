## M71 Phase C gate: SSH transfer/import of an activation bundle.
##
## This uses a real user-owned loopback sshd on a high port. It stops
## at target store import: no remote activation runtime, no target
## generation pointer rotation, and no public `enable --host --now`.

import std/[net, os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_home_generations
import repro_local_store

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
  doAssert false, "M71 Phase C blocker: required executable not found: " & name

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
      "echo m71-fixture phase-c\r\n"
    writeFile(path, result)
  else:
    result =
      "#!/bin/sh\n" &
      "set -eu\n" &
      "echo m71-fixture phase-c\n"
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
    "M71 Phase C blocker: ssh-keygen failed for host key:\n" &
    hostKeygen.output
  let clientKeygen = runProgram(result.sshKeygen,
    ["-q", "-t", "ed25519", "-N", "", "-f", result.clientKey])
  doAssert clientKeygen.exitCode == 0,
    "M71 Phase C blocker: ssh-keygen failed for client key:\n" &
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
        "M71 Phase C blocker: loopback sshd exited before accepting " &
        "connections.\nsshd output:\n" & daemonOutput &
        "\nlast ssh probe:\n" & last

  doAssert false,
    "M71 Phase C blocker: loopback sshd did not accept connections on " &
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

proc parsePrefixId(hex: string): PrefixIdBytes =
  parsePrefixIdHex(hex)

proc bundleFileEntry(bundle: ActivationBundle; rel: string):
    tuple[found: bool; entry: ActivationBundleFileEntry] =
  for closure in bundle.prefixes:
    for entry in closure.files:
      if entry.relativePath == rel:
        return (true, entry)
  (false, ActivationBundleFileEntry())

proc bytesAsString(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

suite "M71 Phase C: SSH activation-bundle transfer/import":
  test "bundle streams over real SSH once, then exact target CAS hit skips streaming":
    when defined(windows):
      doAssert false,
        "M71 Phase C gate must not be skipped; provide a user-owned " &
        "loopback sshd harness for Windows before running this gate there"
    else:
      let tempRoot = createTempDir("repro-m71-ssh-transfer-", "")
      var sshd: SshHarness
      defer:
        stopLoopbackSshd(sshd)
        try: removeDir(tempRoot) except OSError: discard

      let stateDir = tempRoot / "source-state"
      let sourceStoreRoot = tempRoot / "source-store"
      let targetStoreRoot = tempRoot / "target-store"
      let profileDir = tempRoot / "profile"
      let homeDir = tempRoot / "home"
      let fixtureDir = tempRoot / "fixture"
      createDir(stateDir)
      createDir(sourceStoreRoot)
      createDir(targetStoreRoot)
      createDir(profileDir)
      createDir(homeDir)
      createDir(fixtureDir)

      writeFile(profileDir / "home.nim",
        "import repro/profile\n\n" &
        "profile \"m71-phase-c\":\n" &
        "  activity default:\n" &
        "    m71-fixture\n")

      let exeName = "m71-fixture"
      let exePath = fixtureDir / exeName
      let exeContent = writeFixtureExe(exePath)

      let env = @[
        (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
        (k: "REPRO_HOME_STATE_DIR", v: stateDir),
        (k: "REPRO_STORE_ROOT", v: sourceStoreRoot),
        (k: "HOME", v: homeDir),
        (k: "USERPROFILE", v: homeDir),
        (k: "REPRO_HOST", v: "m71-source-host"),
        (k: "REPRO_HOME_PACKAGE_CATALOG", v: "m71-fixture"),
        (k: "REPRO_TEST_PACKAGE_SOURCE", v: "m71-fixture=" & exePath)]

      let apply = runRepro(env, ["home", "apply"])
      check apply.exitCode == 0
      check apply.output.contains("applied generation ")

      let built = runRepro(env, ["home", "__build-bundle"])
      check built.exitCode == 0
      let bundleDigestHex = fieldValue(built.output, "bundleDigest")

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

      let first = runRepro([], transferArgs)
      check first.exitCode == 0
      check fieldValue(first.output, "transferStatus") == "sent"
      check fieldValue(first.output, "bundleDigest") ==
        bundleDigestHex.toLowerAscii()
      check parseInt(fieldValue(first.output, "prefixesImported")) == 1
      check parseInt(fieldValue(first.output, "prefixesAlreadyPresent")) == 0
      check parseInt(fieldValue(first.output, "bytesReceived")) > 0

      var targetStore = openStore(targetStoreRoot)
      let bundleDigest = parsePrefixId(bundleDigestHex)
      let targetBundleBytes = readCasBlob(targetStore, bundleDigest)
      let targetBundle = decodeActivationBundleBytes(targetBundleBytes,
        fieldValue(first.output, "targetBundlePath"))
      check targetBundle.prefixes.len == 1
      let rowsAfterFirst = targetStore.listPrefixes()
      check rowsAfterFirst.len == 1
      check targetStore.listRoots().len == 0
      let row = rowsAfterFirst[0]
      let targetPrefix = targetStore.absolutePrefixPath(row.realizedPath)
      check dirExists(targetPrefix)
      check fileExists(targetPrefix / ReceiptFileName)
      let exeEntry = bundleFileEntry(targetBundle, exeName)
      check exeEntry.found
      check bytesAsString(exeEntry.entry.contentBytes) == exeContent
      check readFile(targetPrefix / exeName) == exeContent
      targetStore.close()

      let second = runRepro([], transferArgs)
      check second.exitCode == 0
      check fieldValue(second.output, "transferStatus") == "already-present"
      check parseInt(fieldValue(second.output, "prefixesImported")) == 0
      check parseInt(fieldValue(second.output, "prefixesAlreadyPresent")) == 1
      check fieldValue(second.output, "bytesReceived") == "0"

      var targetStore2 = openStore(targetStoreRoot)
      defer: targetStore2.close()
      check targetStore2.listPrefixes().len == rowsAfterFirst.len
      check targetStore2.listRoots().len == 0
      check not fileExists(targetStoreRoot / "current")
      check not dirExists(targetStoreRoot / "generations")

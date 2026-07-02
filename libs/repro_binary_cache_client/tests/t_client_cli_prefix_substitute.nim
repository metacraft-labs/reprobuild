## Windows-Runner-Binary-Cache-Deploy M3a — hermetic prefix-substitute gate.
##
## The Windows runner deploy path substitutes a pre-built ``bin/``-shaped
## deployment prefix out of the reprobuild binary cache instead of building
## it from source. This gate is the OS-agnostic primitive behind that path:
## it drives the SHIPPED client CLI (``repro_binary_cache_client_cli``) end
## to end over two real processes on a real TCP socket, and asserts the
## materialised tree is byte-identical to the source AND that the rbcarc-v1
## ``fileModeOctal`` exec-bit normalisation round-trips correctly.
##
## Concretely it:
##
##   1. Builds a ``bin/``-shaped prefix containing
##        * an ``.exe``-like file with the executable bit SET, and
##        * a ``.dll``-like file (regular, NON-executable, NUL-laced bytes),
##      plus a nested ``lib/`` payload, so the walk/pack path covers
##      subdirectories.
##   2. ``publish``es the prefix to a ``repro_binary_cache`` server subprocess
##      bound on 127.0.0.1:<port> (real socket, distinct process).
##   3. ``substitute``s the entry into a FRESH, EMPTY store + out dir.
##   4. Asserts, for every file: it exists at the same relative path and its
##      bytes are IDENTICAL to the source (binary read, NUL-safe compare).
##   5. Asserts exec-bit normalisation: on POSIX the ``.exe``-like file comes
##      back EXECUTABLE (mode 0o755 in the archive → exec bits restored) and
##      the ``.dll``-like file comes back NON-executable (mode 0o644). On
##      Windows there is no exec bit, so the assertion is that both files
##      materialise byte-identical (the mode field is normalised away).
##
## This is a real two-process, real-socket, byte-identity gate — not a stub,
## not exit-code-only. It shares the A3 P2 CLI test's process plumbing but is
## a distinct binary so the runner can target it by name
## (``t_client_cli_prefix_substitute``).

import std/[os, osproc, net, random, streams, strtabs, strutils, unittest]

import ../src/repro_binary_cache_client
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

const
  ServerBinary = "build/test-bin" / addFileExt("repro_binary_cache", ExeExt)
  CliBinary = "build/test-bin" / addFileExt("repro_binary_cache_client_cli", ExeExt)

proc pickPort(): int =
  randomize(); 24_000 + rand(6_999)

proc waitForListener(port: int; tries = 100; sleepMs = 50): bool =
  for _ in 0 ..< tries:
    try:
      let sock = newSocket()
      sock.connect("127.0.0.1", Port(port))
      sock.close()
      return true
    except CatchableError:
      sleep(sleepMs)
  return false

proc startServer(serverRoot: string; port: int): Process =
  startProcess(absolutePath(ServerBinary),
               args = @["--root=" & serverRoot,
                        "--listen=127.0.0.1:" & $port],
               options = {poStdErrToStdOut, poParentStreams})

proc runCli(args: openArray[string]; env: openArray[(string, string)] = @[]):
            tuple[code: int; outp: string] =
  var combinedEnv = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    combinedEnv[k] = v
  for (k, v) in env:
    combinedEnv[k] = v
  let p = startProcess(absolutePath(CliBinary),
                       args = @args,
                       env = combinedEnv,
                       options = {poStdErrToStdOut, poUsePath})
  var outp = ""
  let stream = p.outputStream
  while true:
    let line =
      try: stream.readLine()
      except IOError: break
    if line.len == 0 and stream.atEnd:
      break
    outp.add(line)
    outp.add("\n")
  let code = p.waitForExit()
  p.close()
  return (code, outp)

proc isExecutable(path: string): bool =
  ## POSIX: any of the exec permission bits set. (Windows callers guard
  ## against calling this — there is no exec bit there.)
  let perms = getFilePermissions(path)
  (perms * {fpUserExec, fpGroupExec, fpOthersExec}).len > 0

suite "M3a — client CLI prefix substitute (byte-identity + exec-bit)":

  test "t_client_cli_prefix_substitute":
    check fileExists(ServerBinary)
    check fileExists(CliBinary)

    let port = pickPort()
    let tag = $rand(999_999)
    let serverRoot = getTempDir() / ("m3a_srv_" & tag)
    let clientStore = getTempDir() / ("m3a_store_" & tag)
    let prefixDir = getTempDir() / ("m3a_prefix_" & tag)
    let outDir = getTempDir() / ("m3a_out_" & tag)
    let keyDir = getTempDir() / ("m3a_keys_" & tag)
    for d in [serverRoot, clientStore, prefixDir, outDir, keyDir]:
      removeDir(d)
    createDir(serverRoot); createDir(clientStore)
    createDir(prefixDir); createDir(keyDir)
    defer:
      for d in [serverRoot, clientStore, prefixDir, outDir, keyDir]:
        try: removeDir(d) except CatchableError: discard

    # ---- Build a bin/-shaped prefix: an exe-like (executable) + a dll-like
    # (regular) + a nested lib payload with NUL-laced binary bytes. ----
    createDir(prefixDir / "bin")
    createDir(prefixDir / "lib")

    let exeRel = "bin/deploy-agent.exe"
    let dllRel = "bin/libdeploy.dll"
    let libRel = "lib/data.bin"

    # exe-like: NUL-laced bytes so a "treat-as-text" bug would corrupt it.
    var exeBytes = newString(2048)
    for i in 0 ..< exeBytes.len:
      exeBytes[i] = char((i * 7 + 3) mod 256)
    writeFile(prefixDir / exeRel, exeBytes)

    var dllBytes = newString(1536)
    for i in 0 ..< dllBytes.len:
      dllBytes[i] = char((i * 13 + 1) mod 256)
    writeFile(prefixDir / dllRel, dllBytes)

    var libBytes = newString(4096)
    for i in 0 ..< libBytes.len:
      libBytes[i] = char(i mod 256)
    writeFile(prefixDir / libRel, libBytes)

    # Set the exec bit on the .exe-like file ONLY (POSIX). On Windows the
    # exec bit is meaningless; rbcarc-v1 fileModeOctal keys off the .exe
    # extension there, so the archive still records 0o755 for it.
    when not defined(windows):
      var exePerms = getFilePermissions(prefixDir / exeRel)
      exePerms.incl(fpUserExec); exePerms.incl(fpGroupExec)
      exePerms.incl(fpOthersExec)
      setFilePermissions(prefixDir / exeRel, exePerms)
      # Ensure the dll-like + lib payloads are NON-executable so the
      # normalisation-away assertion is meaningful.
      for r in [dllRel, libRel]:
        var p = getFilePermissions(prefixDir / r)
        p.excl(fpUserExec); p.excl(fpGroupExec); p.excl(fpOthersExec)
        setFilePermissions(prefixDir / r, p)

    # ---- Producer keypair on disk (ecdsa-p256 private + uncompressed pub). ----
    let kp = peerAuth.generateKeypair()
    let keyPath = keyDir / "producer.key"
    let certPath = keyDir / "producer.cert"
    const HexChars = "0123456789abcdef"
    var privHex = newStringOfCap(64)
    for b in kp.privateKey:
      privHex.add(HexChars[(int(b) shr 4) and 0xf])
      privHex.add(HexChars[int(b) and 0xf])
    var pubHex = newStringOfCap(130)
    for b in kp.publicKey:
      pubHex.add(HexChars[(int(b) shr 4) and 0xf])
      pubHex.add(HexChars[int(b) and 0xf])
    writeFile(keyPath, "ecdsa-p256:" & privHex & "\n")
    writeFile(certPath, pubHex & "\n")

    # ---- Boot the cache server subprocess. ----
    let srvProc = startServer(serverRoot, port)
    defer:
      try: srvProc.terminate() except CatchableError: discard
      try: srvProc.close() except CatchableError: discard
    if not waitForListener(port):
      fail()
    let url = "http://127.0.0.1:" & $port

    # ---- Derive identity (local platform so the substitute compat-check
    # passes) and publish. ----
    let local = detectLocalPlatform(clientStore)
    let platform = PlatformTriple(cpu: local.cpu, os: local.os,
                                  abi: local.abi, libcVariant: "")
    var idy = newCacheEntryIdentity(
      packageName = "deploy-prefix", packageVersion = "1.0.0",
      platform = platform,
      toolchain = ToolchainIdentity(name: "stub", version: "1",
                                    hostLdSoAbi: "",
                                    extraFingerprint: ""),
      providerRevision = "m3a-prefix-rev-001")
    let entryHex = deriveCacheEntryKeyHex(idy)

    let publishArgs = @[
      "publish", entryHex, prefixDir,
      "--package-name=deploy-prefix", "--package-version=1.0.0",
      "--platform-cpu=" & local.cpu, "--platform-os=" & local.os,
      "--platform-abi=" & local.abi, "--platform-libc=",
      "--toolchain-name=stub", "--toolchain-version=1",
      "--toolchain-host-ldso=", "--toolchain-extra=",
      "--provider-revision=m3a-prefix-rev-001"]
    let (pubCode, pubOut) = runCli(publishArgs, env = @[
      ("REPRO_BINARY_CACHE_URL", url),
      ("REPRO_BINARY_CACHE_KEY_PATH", keyPath),
      ("REPRO_BINARY_CACHE_CERT_PATH", certPath)])
    if pubCode != 0:
      echo "publish failed (code=", pubCode, "): ", pubOut
    check pubCode == 0
    check pubOut.contains(entryHex)

    # ---- Substitute into a FRESH, EMPTY out dir over the real socket. ----
    check not dirExists(outDir)
    let (subCode, subOut) = runCli(
      ["substitute", entryHex, outDir],
      env = @[("REPRO_BINARY_CACHE_URL", url),
              ("REPRO_LOCAL_STORE", clientStore)])
    if subCode != 0:
      echo "substitute failed (code=", subCode, "): ", subOut
    check subCode == 0

    # ---- Byte-identity for every file. ----
    for (rel, want) in [(exeRel, exeBytes), (dllRel, dllBytes),
                        (libRel, libBytes)]:
      check fileExists(outDir / rel)
      check readFile(outDir / rel) == want

    # ---- Exec-bit normalisation (the rbcarc-v1 fileModeOctal path). ----
    when defined(windows):
      # No exec bit on Windows; the guarantee is byte-identity (asserted
      # above). Nothing further to check.
      discard
    else:
      # The .exe-like file was published executable → archive mode 0o755 →
      # extract restores the exec bits.
      check isExecutable(outDir / exeRel)
      # The .dll-like + lib payloads were non-executable → archive mode
      # 0o644 → extract must NOT set exec bits.
      check not isExecutable(outDir / dllRel)
      check not isExecutable(outDir / libRel)

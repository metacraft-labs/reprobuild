## ReproOS-Generations-And-Foreign-Packages A3 P2 — CLI gate.
##
## Spins up an A2 server, builds the A3 P2 CLI binary, and exercises
## ``lookup`` → ``publish`` → ``lookup`` (hit) → ``substitute`` against
## a synthetic 1-member entry. The test asserts:
##
##   1. The CLI binary is present at ``build/test-bin/``.
##   2. ``lookup <random-key>`` reports miss (exit 1).
##   3. ``publish <key> <prefix-dir>`` succeeds against the running
##      server (exit 0, the body echoes the entry-key hex).
##   4. ``lookup <key>`` after publish reports hit (exit 0).
##   5. ``substitute <key> <out-dir>`` materialises the original prefix
##      bytes into ``<out-dir>`` so the build-script consumer can use
##      them.
##
## Single-user mode end-to-end; no daemon involvement.

import std/[algorithm, os, osproc, net, random, streams, strtabs, strutils,
            tables, times, unittest]

import ../src/repro_binary_cache_client
import ../../repro_binary_cache_server/src/repro_binary_cache_server
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
  ## Spawns the CLI binary and captures stdout. Errors flow to the
  ## parent's stderr for easy diagnosis.
  var combinedEnv = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    combinedEnv[k] = v
  for (k, v) in env:
    combinedEnv[k] = v
  let p = startProcess(absolutePath(CliBinary),
                       args = @args,
                       env = combinedEnv,
                       options = {poStdErrToStdOut, poUsePath})
  # Drain the combined stdout/stderr fully BEFORE the wait — Nim's
  # asynchttpserver child can leave bytes buffered if we wait first.
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

proc randomHex64(): string =
  result = newString(64)
  for i in 0 ..< 64:
    result[i] = "0123456789abcdef"[rand(15)]

suite "A3 P2 — CLI substitute / publish / lookup":

  test "CLI binary exists and accepts --help":
    check fileExists(CliBinary)
    let (code, outp) = runCli(["--help"])
    check code == 0
    check outp.contains("repro-binary-cache-client")

  test "publish + lookup + substitute round-trip":
    let port = pickPort()
    let serverRoot = getTempDir() / ("a3_p2_srv_" & $rand(999_999))
    let clientStore = getTempDir() / ("a3_p2_cli_store_" & $rand(999_999))
    let prefixDir = getTempDir() / ("a3_p2_prefix_" & $rand(999_999))
    let outDir = getTempDir() / ("a3_p2_out_" & $rand(999_999))
    let keyDir = getTempDir() / ("a3_p2_keys_" & $rand(999_999))
    removeDir(serverRoot); removeDir(clientStore)
    removeDir(prefixDir); removeDir(outDir); removeDir(keyDir)
    createDir(serverRoot); createDir(clientStore)
    createDir(prefixDir); createDir(keyDir)
    defer:
      try: removeDir(serverRoot) except CatchableError: discard
      try: removeDir(clientStore) except CatchableError: discard
      try: removeDir(prefixDir) except CatchableError: discard
      try: removeDir(outDir) except CatchableError: discard
      try: removeDir(keyDir) except CatchableError: discard

    # Populate the prefix with two test files.
    createDir(prefixDir / "bin")
    createDir(prefixDir / "share")
    writeFile(prefixDir / "bin" / "hex0", "fake-hex0-binary")
    writeFile(prefixDir / "share" / "readme.txt", "hello reprobuild")

    # Materialise the producer keypair on disk so the CLI can load it.
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

    # Boot the A2 server.
    let srvProc = startServer(serverRoot, port)
    defer:
      try: srvProc.terminate() except CatchableError: discard
      try: srvProc.close() except CatchableError: discard
    if not waitForListener(port):
      fail()

    let url = "http://127.0.0.1:" & $port

    # 1. lookup random-key → miss (exit 1)
    let missHex = randomHex64()
    let (missCode, missOut) = runCli(["lookup", missHex],
                                     env = @[("REPRO_BINARY_CACHE_URL", url)])
    check missCode == 1
    check missOut.contains("miss")

    # 2. derive the identity → publish. Use the LOCAL platform so the
    # compat-check on substitute lets the manifest through (this gate
    # exercises the publish + substitute pipeline; the dedicated
    # compat-isolation gate lives in P7).
    let local = detectLocalPlatform(clientStore)
    let platform = PlatformTriple(cpu: local.cpu, os: local.os,
                                  abi: local.abi, libcVariant: "")
    var idy = newCacheEntryIdentity(
      packageName = "hex0", packageVersion = "0.1.0",
      platform = platform,
      toolchain = ToolchainIdentity(name: "gcc", version: "11.4.0",
                                    hostLdSoAbi: "",
                                    extraFingerprint: "binutils-2.40"),
      providerRevision = "fake-recipe-sha-001")
    idy.addOption("optflag", "-O2")
    let entryHex = deriveCacheEntryKeyHex(idy)

    let publishArgs = @[
      "publish", entryHex, prefixDir,
      "--package-name=hex0", "--package-version=0.1.0",
      "--platform-cpu=" & local.cpu, "--platform-os=" & local.os,
      "--platform-abi=" & local.abi, "--platform-libc=",
      "--toolchain-name=gcc", "--toolchain-version=11.4.0",
      "--toolchain-host-ldso=",
      "--toolchain-extra=binutils-2.40",
      "--provider-revision=fake-recipe-sha-001",
      "--option=optflag=-O2"]
    let (pubCode, pubOut) = runCli(publishArgs, env = @[
      ("REPRO_BINARY_CACHE_URL", url),
      ("REPRO_BINARY_CACHE_KEY_PATH", keyPath),
      ("REPRO_BINARY_CACHE_CERT_PATH", certPath)])
    if pubCode != 0:
      echo "publish failed (code=", pubCode, "): ----"
      echo pubOut
      echo "---- end publish output"
    check pubCode == 0
    check pubOut.contains(entryHex)

    # 3. lookup → hit
    let (hitCode, hitOut) = runCli(["lookup", entryHex],
                                   env = @[("REPRO_BINARY_CACHE_URL", url)])
    if hitCode != 0:
      echo "lookup-hit unexpected exit: ", hitOut
    check hitCode == 0
    check hitOut.contains("hit")

    # 4. substitute into outDir
    let (subCode, subOut) = runCli(
      ["substitute", entryHex, outDir],
      env = @[("REPRO_BINARY_CACHE_URL", url),
              ("REPRO_LOCAL_STORE", clientStore)])
    if subCode != 0:
      echo "substitute unexpected exit: ", subOut
    check subCode == 0
    check fileExists(outDir / "bin" / "hex0")
    check fileExists(outDir / "share" / "readme.txt")
    check readFile(outDir / "bin" / "hex0") == "fake-hex0-binary"
    check readFile(outDir / "share" / "readme.txt") == "hello reprobuild"

  test "multi-file directory roundtrip — 3 files across 3 subdirs":
    ## Explicit gate against the realizedPrefixDigest / payload-digest
    ## class of bug surfaced in the A3 review. Publishes a directory
    ## with three files across three subdirectories (mixing a text
    ## file, a multi-line text file, and a binary blob with NULs),
    ## then substitutes into a fresh tree and asserts every file
    ## exists with byte-identical contents at its original path. If
    ## the realized-tree digest semantics ever drift away from the
    ## payload-archive digest semantics, this gate catches it
    ## independent of the single-file fast-path.
    let port = pickPort()
    let serverRoot = getTempDir() / ("a3_p2_mf_srv_" & $rand(999_999))
    let clientStore = getTempDir() / ("a3_p2_mf_cli_store_" & $rand(999_999))
    let prefixDir = getTempDir() / ("a3_p2_mf_prefix_" & $rand(999_999))
    let outDir = getTempDir() / ("a3_p2_mf_out_" & $rand(999_999))
    let keyDir = getTempDir() / ("a3_p2_mf_keys_" & $rand(999_999))
    removeDir(serverRoot); removeDir(clientStore)
    removeDir(prefixDir); removeDir(outDir); removeDir(keyDir)
    createDir(serverRoot); createDir(clientStore)
    createDir(prefixDir); createDir(keyDir)
    defer:
      try: removeDir(serverRoot) except CatchableError: discard
      try: removeDir(clientStore) except CatchableError: discard
      try: removeDir(prefixDir) except CatchableError: discard
      try: removeDir(outDir) except CatchableError: discard
      try: removeDir(keyDir) except CatchableError: discard

    # Populate prefix with three files in three subdirs. The binary
    # blob mixes NULs + non-ASCII bytes so any "treat-as-string"
    # accidental conversion in the publish/substitute pipe gets
    # caught here.
    createDir(prefixDir / "bin")
    createDir(prefixDir / "share")
    createDir(prefixDir / "lib")
    writeFile(prefixDir / "bin" / "exec", "fake-exec-binary")
    writeFile(prefixDir / "share" / "readme.txt",
              "hello reprobuild\nline two\nline three\n")
    var blob = newString(4096)
    for i in 0 ..< blob.len:
      blob[i] = char(i mod 256)
    writeFile(prefixDir / "lib" / "data.bin", blob)

    # Materialise producer keypair.
    let kp = peerAuth.generateKeypair()
    let keyPath = keyDir / "producer.key"
    let certPath = keyDir / "producer.cert"
    const HexChars2 = "0123456789abcdef"
    var privHex = newStringOfCap(64)
    for b in kp.privateKey:
      privHex.add(HexChars2[(int(b) shr 4) and 0xf])
      privHex.add(HexChars2[int(b) and 0xf])
    var pubHex = newStringOfCap(130)
    for b in kp.publicKey:
      pubHex.add(HexChars2[(int(b) shr 4) and 0xf])
      pubHex.add(HexChars2[int(b) and 0xf])
    writeFile(keyPath, "ecdsa-p256:" & privHex & "\n")
    writeFile(certPath, pubHex & "\n")

    # Boot server.
    let srvProc = startServer(serverRoot, port)
    defer:
      try: srvProc.terminate() except CatchableError: discard
      try: srvProc.close() except CatchableError: discard
    if not waitForListener(port):
      fail()
    let url = "http://127.0.0.1:" & $port

    # Derive identity matching the local platform.
    let local = detectLocalPlatform(clientStore)
    let platform = PlatformTriple(cpu: local.cpu, os: local.os,
                                  abi: local.abi, libcVariant: "")
    var idy = newCacheEntryIdentity(
      packageName = "multi-file-test", packageVersion = "1.0.0",
      platform = platform,
      toolchain = ToolchainIdentity(name: "stub", version: "1",
                                    hostLdSoAbi: "",
                                    extraFingerprint: ""),
      providerRevision = "multi-file-rev-001")
    let entryHex = deriveCacheEntryKeyHex(idy)

    let publishArgs = @[
      "publish", entryHex, prefixDir,
      "--package-name=multi-file-test", "--package-version=1.0.0",
      "--platform-cpu=" & local.cpu, "--platform-os=" & local.os,
      "--platform-abi=" & local.abi, "--platform-libc=",
      "--toolchain-name=stub", "--toolchain-version=1",
      "--toolchain-host-ldso=",
      "--toolchain-extra=",
      "--provider-revision=multi-file-rev-001"]
    let (pubCode, pubOut) = runCli(publishArgs, env = @[
      ("REPRO_BINARY_CACHE_URL", url),
      ("REPRO_BINARY_CACHE_KEY_PATH", keyPath),
      ("REPRO_BINARY_CACHE_CERT_PATH", certPath)])
    if pubCode != 0:
      echo "multi-file publish failed (code=", pubCode, "): ", pubOut
    check pubCode == 0
    check pubOut.contains(entryHex)

    # Substitute into a fresh dir, then assert every file is present
    # with byte-identical contents at the same relative path.
    let (subCode, subOut) = runCli(
      ["substitute", entryHex, outDir],
      env = @[("REPRO_BINARY_CACHE_URL", url),
              ("REPRO_LOCAL_STORE", clientStore)])
    if subCode != 0:
      echo "multi-file substitute failed (code=", subCode, "): ", subOut
    check subCode == 0

    check fileExists(outDir / "bin" / "exec")
    check fileExists(outDir / "share" / "readme.txt")
    check fileExists(outDir / "lib" / "data.bin")
    check readFile(outDir / "bin" / "exec") == "fake-exec-binary"
    check readFile(outDir / "share" / "readme.txt") ==
      "hello reprobuild\nline two\nline three\n"
    check readFile(outDir / "lib" / "data.bin") == blob

    # Realised-tree structure must match: the three subdirs and only
    # those three subdirs exist below outDir.
    var seenSubdirs: seq[string] = @[]
    for kind, path in walkDir(outDir):
      if kind == pcDir:
        seenSubdirs.add(extractFilename(path))
    seenSubdirs.sort(cmp)
    check seenSubdirs == @["bin", "lib", "share"]

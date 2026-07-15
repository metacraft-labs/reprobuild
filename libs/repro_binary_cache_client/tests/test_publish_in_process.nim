## M9.L.4-refactor Step A — publishInProcess library API gate.
##
## Exercises the new ``publishInProcess`` library API (lifted from the
## ``repro cache publish`` handler in
## ``libs/repro_binary_cache_client/src/repro_binary_cache_client/cli_dispatch.nim``
## §cmdPublish) directly, without going through the CLI binary, so
## the engine's new ``binaryCachePublisher`` closure can adopt it
## without forking.
##
## Coverage:
##   * Drift-guard fires when the supplied entry-key hex does not
##     match the identity-derived hex (HARD-FAIL before any byte
##     hits the network).
##   * Missing prefix path produces a structured error result.
##   * Multi-file directory round-trip publishes against the real
##     A2 server subprocess; the manifest's signature verifies.
##   * Single-file prefix round-trip exercises the
##     ``packSingleFilePrefix`` fallback.
##   * Result.bytesUploaded is populated on success.
##
## Server subprocess is shared with the existing A2/A3 gates.

import std/[net, os, osproc, random, streams, strutils, times, unittest]

import ../src/repro_binary_cache_client
import ../../repro_binary_cache_server/src/repro_binary_cache_server/types
import ../../repro_binary_cache_server/src/repro_binary_cache_server/manifest_codec as serverCodec
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

const
  ServerBinary = "build/test-bin" / addFileExt("repro_binary_cache", ExeExt)

proc pickPort(): int =
  var sock = newSocket()
  sock.bindAddr(Port(0), "127.0.0.1")
  let local = sock.getLocalAddr()
  sock.close()
  int(local[1])

proc waitForListener(srvProc: Process; port: int; tries = 2400;
                     sleepMs = 50): bool =
  for _ in 0 ..< tries:
    if not srvProc.running():
      checkpoint("server exited before opening listener; exit=" &
        $srvProc.peekExitCode())
      return false
    var sock: Socket
    try:
      sock = newSocket()
      sock.connect("127.0.0.1", Port(port))
      return true
    except CatchableError:
      sleep(sleepMs)
    finally:
      if not sock.isNil:
        try: sock.close() except CatchableError: discard
  return false

proc startServer(serverRoot: string; port: int): Process =
  startProcess(absolutePath(ServerBinary),
               args = @["--root=" & serverRoot,
                        "--listen=127.0.0.1:" & $port,
                        "--print-pubkey"],
               options = {poStdErrToStdOut})

proc waitForExitWithin(p: Process; millis: int): bool =
  let deadline = epochTime() + (millis.float / 1000.0)
  while epochTime() < deadline:
    if p.peekExitCode() != -1:
      return true
    sleep(20)
  p.peekExitCode() != -1

proc drainServerOutput(p: Process): string =
  try:
    let stream = p.outputStream
    if stream.isNil:
      return ""
    result = stream.readAll()
  except CatchableError as e:
    result = "failed to read server output: " & e.msg & "\n"

proc stopServer(p: Process): string =
  try:
    if p.peekExitCode() == -1:
      try: p.terminate() except CatchableError: discard
      if not waitForExitWithin(p, 5000):
        try: p.kill() except CatchableError: discard
        discard waitForExitWithin(p, 30_000)
    if p.peekExitCode() != -1:
      discard p.waitForExit()
      result = drainServerOutput(p)
    else:
      result = "server process did not exit after terminate/kill\n"
  finally:
    try: p.close() except CatchableError: discard

proc checkpointServerOutput(prefix: string; output: string) =
  if output.len > 0:
    checkpoint(prefix & " server output:\n" & output)
  else:
    checkpoint(prefix & " server produced no output")

proc localPlatform(): PlatformTriple =
  when defined(amd64) or defined(x86_64):
    const cpu = "x86_64"
  elif defined(arm64) or defined(aarch64):
    const cpu = "aarch64"
  else:
    const cpu = "unknown"
  when defined(linux):
    const osName = "linux"; const abi = "gnu"
  elif defined(windows):
    const osName = "windows"; const abi = "msvc"
  else:
    const osName = "darwin"; const abi = ""
  PlatformTriple(cpu: cpu, os: osName, abi: abi, libcVariant: "")

proc stubIdentity(name = "publish-in-process-test";
                  ver = "1.0.0";
                  rev = "rev-001"): CacheEntryIdentity =
  result = newCacheEntryIdentity(
    packageName = name,
    packageVersion = ver,
    platform = localPlatform(),
    toolchain = ToolchainIdentity(name: "stub", version: "1",
                                  hostLdSoAbi: "", extraFingerprint: ""),
    providerRevision = rev)

suite "M9.L.4-refactor Step A — publishInProcess library API":

  test "drift-guard fires when supplied hex disagrees with identity-derived hex":
    let identity = stubIdentity()
    # 64-char all-zero hex is not the identity's derived key.
    let req = PublishInProcessRequest(
      entryKeyHex: "0000000000000000000000000000000000000000000000000000000000000000",
      prefixDir: getTempDir(),
      identity: identity,
      endpoint: "http://127.0.0.1:1",  # bogus port; we MUST short-circuit
      keypair: peerAuth.generateKeypair())
    let res = publishInProcess(req)
    check (not res.ok)
    check res.statusCode == 0  # no HTTP issued
    check res.error.contains("identity-derived key does not match")
    check res.bytesUploaded == 0

  test "missing prefix path produces a structured error":
    let identity = stubIdentity(rev = "missing-prefix")
    let derivedHex = deriveCacheEntryKeyHex(identity)
    let req = PublishInProcessRequest(
      entryKeyHex: derivedHex,
      prefixDir: getTempDir() / "this-path-does-not-exist-" & $rand(999_999),
      identity: identity,
      endpoint: "http://127.0.0.1:1",
      keypair: peerAuth.generateKeypair())
    let res = publishInProcess(req)
    check (not res.ok)
    check res.error.contains("prefix path does not exist")

  test "multi-file directory round-trip + signature verifies":
    let port = pickPort()
    let serverRoot = getTempDir() / ("pub_in_proc_srv_" & $rand(999_999))
    let prefixDir = getTempDir() / ("pub_in_proc_prefix_" & $rand(999_999))
    removeDir(serverRoot); removeDir(prefixDir)
    createDir(serverRoot); createDir(prefixDir)
    defer:
      try: removeDir(serverRoot) except CatchableError: discard
      try: removeDir(prefixDir) except CatchableError: discard

    # 3-file prefix.
    createDir(prefixDir / "bin")
    createDir(prefixDir / "share")
    writeFile(prefixDir / "bin" / "exec", "executable-payload")
    writeFile(prefixDir / "share" / "data.txt", "text payload\nline two\n")
    var blob = newString(2048)
    for i in 0 ..< blob.len:
      blob[i] = char(i mod 256)
    writeFile(prefixDir / "blob.bin", blob)

    let srvProc = startServer(serverRoot, port)
    var serverStopped = false
    var serverOutput = ""
    proc stopServerOnce() =
      if not serverStopped:
        serverOutput = stopServer(srvProc)
        serverStopped = true
    defer:
      stopServerOnce()
      if serverOutput.contains("Traceback") or
          serverOutput.contains("Error:") or
          serverOutput.contains("Exception"):
        checkpointServerOutput("multi-file", serverOutput)
    if not waitForListener(srvProc, port):
      checkpoint("server did not listen on port " & $port)
      stopServerOnce()
      checkpointServerOutput("multi-file", serverOutput)
      check false
    else:
      let baseUrl = "http://127.0.0.1:" & $port

      let kp = peerAuth.generateKeypair()
      let identity = stubIdentity(rev = "multi-file-rev")
      let derivedHex = deriveCacheEntryKeyHex(identity)
      let req = PublishInProcessRequest(
        entryKeyHex: derivedHex,
        prefixDir: prefixDir,
        identity: identity,
        endpoint: baseUrl,
        keypair: kp)
      let res = publishInProcess(req)
      if not res.ok:
        echo "publish failed: status=", res.statusCode, " err=", res.error
      check res.ok
      check res.statusCode in 200 .. 299
      check res.bytesUploaded > 0
      check res.responseBody.contains(derivedHex)

      # The server now holds a manifest under derivedHex; fetch it
      # back via the lookup HTTP route to confirm the signature shape
      # is what the codec produced.
      let pool = newHttpPool()
      defer: pool.close()
      let cfg = defaultConfig(
        getTempDir() / ("pub_in_proc_cli_" & $rand(999_999)), @[
          SubstituteEndpoint(
            baseUrl: baseUrl,
            trustedSigners: @[kp.publicKey],
            priority: 30)])
      let ctx = newClientContext(cfg)
      defer: ctx.close()
      let endpoint = cfg.endpoints[0]
      let fetched = fetchAndVerifyManifest(ctx, pool, endpoint, derivedHex)
      check serverCodec.verifyManifest(fetched)
      check fetched.entryKey.packageName == "publish-in-process-test"
      check fetched.payloads.len == 1
      check fetched.producerPubKey == kp.publicKey

  test "single-file prefix round-trip exercises packSingleFilePrefix":
    let port = pickPort()
    let serverRoot = getTempDir() / ("pub_in_proc_srv_sf_" & $rand(999_999))
    let prefixFile = getTempDir() / ("pub_in_proc_file_" & $rand(999_999))
    removeDir(serverRoot)
    if fileExists(prefixFile): removeFile(prefixFile)
    createDir(serverRoot)
    defer:
      try: removeDir(serverRoot) except CatchableError: discard
      try: removeFile(prefixFile) except CatchableError: discard

    writeFile(prefixFile, "single-file payload contents")

    let srvProc = startServer(serverRoot, port)
    var serverStopped = false
    var serverOutput = ""
    proc stopServerOnce() =
      if not serverStopped:
        serverOutput = stopServer(srvProc)
        serverStopped = true
    defer:
      stopServerOnce()
      if serverOutput.contains("Traceback") or
          serverOutput.contains("Error:") or
          serverOutput.contains("Exception"):
        checkpointServerOutput("single-file", serverOutput)
    if not waitForListener(srvProc, port):
      checkpoint("server did not listen on port " & $port)
      stopServerOnce()
      checkpointServerOutput("single-file", serverOutput)
      check false
    else:
      let baseUrl = "http://127.0.0.1:" & $port

      let kp = peerAuth.generateKeypair()
      let identity = stubIdentity(rev = "single-file-rev")
      let derivedHex = deriveCacheEntryKeyHex(identity)
      let req = PublishInProcessRequest(
        entryKeyHex: derivedHex,
        prefixDir: prefixFile,
        identity: identity,
        endpoint: baseUrl,
        keypair: kp)
      let res = publishInProcess(req)
      if not res.ok:
        echo "single-file publish failed: status=", res.statusCode,
             " err=", res.error
      check res.ok
      check res.bytesUploaded > 0

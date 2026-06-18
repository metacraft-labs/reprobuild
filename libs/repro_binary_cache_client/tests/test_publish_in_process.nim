## M9.L.4-refactor Step A — publishInProcess library API gate.
##
## Exercises the new ``publishInProcess`` library API (lifted from
## ``apps/repro-binary-cache-client/repro_binary_cache_client_cli.nim``
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

import std/[net, os, osproc, random, strutils, unittest]

import ../src/repro_binary_cache_client
import ../../repro_binary_cache_server/src/repro_binary_cache_server/types
import ../../repro_binary_cache_server/src/repro_binary_cache_server/manifest_codec as serverCodec
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

const
  ServerBinary = "build/test-bin" / addFileExt("repro_binary_cache", ExeExt)

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
    defer:
      try: srvProc.terminate() except CatchableError: discard
      try: srvProc.close() except CatchableError: discard
    check waitForListener(port)
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
    let cfg = defaultConfig(getTempDir() / ("pub_in_proc_cli_" & $rand(999_999)), @[
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
    defer:
      try: srvProc.terminate() except CatchableError: discard
      try: srvProc.close() except CatchableError: discard
    check waitForListener(port)
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

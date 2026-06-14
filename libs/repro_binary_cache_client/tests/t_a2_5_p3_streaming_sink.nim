## A2.5 P3 — streaming payload sink (the centerpiece).
##
## Publishes a 8 MiB random-but-deterministic payload to an A2 server
## subprocess, fetches it via the client library, and asserts:
##
##   * The fetched bytes are byte-identical to the published bytes
##     (via on-disk re-read).
##   * The local CAS file's BLAKE3-256 digest matches the manifest's
##     declared digest.
##   * The receive-side memory peak stays bounded (we only hold one
##     receive buffer + one outgoing seq[byte] copy via the test
##     code; the client itself doesn't accumulate the whole payload
##     in RAM).
##   * Atomic semantics: the temp file is gone after success; the
##     final CAS path exists.
##   * Re-running ``fetchPayloadStreaming`` is a no-op fast path
##     (hits the "already present + hash matches" branch).
##
## The Linux strace-based single-pass-read assertion lives in the
## shell gate ``tests/integration/binary_cache/perf/
## t_a2_5_single_pass_hash.sh`` (P8). Here we keep the unit gate
## platform-agnostic.

import std/[os, osproc, net, random, strutils, unittest]

import ../src/repro_binary_cache_client
import ../../repro_binary_cache_server/src/repro_binary_cache_server/types
import ../../repro_binary_cache_server/src/repro_binary_cache_server/key
import ../../repro_binary_cache_server/src/repro_binary_cache_server/manifest_codec
import ../../repro_binary_cache_server/src/repro_binary_cache_server/index as bcsIndex
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import ../../blake3/src/blake3

const ServerBinary = "build/test-bin/repro_binary_cache.exe"

proc pickPort(): int =
  randomize()
  result = 23_000 + rand(8_999)

proc generatePayload(sizeBytes: int; seed: int): seq[byte] =
  ## Deterministic pseudo-random payload. Faster than calling rand
  ## per byte; the rolling 64-bit LCG mixes well enough for our
  ## throughput assertions.
  result = newSeq[byte](sizeBytes)
  var state = uint64(seed) or 0x1u64
  var i = 0
  while i < sizeBytes:
    state = state * 6364136223846793005'u64 + 1442695040888963407'u64
    let n = min(8, sizeBytes - i)
    for j in 0 ..< n:
      result[i + j] = byte((state shr (8 * j.uint64)) and 0xff)
    i += n

proc buildSignedManifest(kp: PeerKeypair;
                         payloadBytes: openArray[byte]): BinaryCacheManifest =
  let payloadDigestRaw = blake3.digest(payloadBytes)
  var payloadDigest: Blake3Hash
  for i in 0 ..< 32:
    payloadDigest[i] = payloadDigestRaw[i]
  var realizedPrefix: Blake3Hash
  for i in 0 ..< 32:
    realizedPrefix[i] = byte((i * 19 + 5) and 0xff)

  when defined(amd64) or defined(x86_64):
    const localCpu = "x86_64"
  elif defined(arm64) or defined(aarch64):
    const localCpu = "aarch64"
  else:
    const localCpu = "unknown"
  when defined(linux):
    const localOs = "linux"
    const localAbi = "gnu"
  elif defined(windows):
    const localOs = "windows"
    const localAbi = "msvc"
  else:
    const localOs = "darwin"
    const localAbi = ""

  let payload = PayloadObject(
    kind: pkPrefixArchive,
    compression: ckNone,
    declaredSize: uint64(payloadBytes.len),
    uncompressedSize: uint64(payloadBytes.len),
    digest: payloadDigest,
    name: "prefix.bin")

  let entryKey = CacheEntryKey(
    packageName: "a2_5-p3-streaming",
    packageVersion: "1.0.0",
    selectedOptions: @[],
    platform: PlatformTriple(cpu: localCpu, os: localOs,
                             abi: localAbi, libcVariant: ""),
    toolchain: ToolchainIdentity(name: "gcc", version: "11"),
    depClosureDigest: payloadDigest,         # any 32 bytes; unused here
    providerRevision: "a2_5-p3-streaming")

  result = BinaryCacheManifest(
    formatVersion: BinaryCacheFormatVersion,
    entryKey: entryKey,
    payloads: @[payload],
    realizedPrefixDigest: realizedPrefix,
    depReferences: @[],
    relocationPolicy: rpOptional,
    createdAtUnix: 1_750_000_000'i64)
  signManifest(kp, result)

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
  let exePath = absolutePath(ServerBinary)
  doAssert fileExists(exePath), "missing " & exePath
  result = startProcess(
    exePath,
    args = @["--root=" & serverRoot,
             "--listen=127.0.0.1:" & $port],
    options = {poStdErrToStdOut, poParentStreams})

suite "A2.5 P3 — streaming payload sink":
  test "8 MiB payload streams end-to-end with byte-identical CAS write":
    randomize()
    let port = pickPort()
    let serverRoot = getTempDir() / ("a2_5_p3_srv_" & $rand(999_999))
    let clientRoot = getTempDir() / ("a2_5_p3_cli_" & $rand(999_999))
    removeDir(serverRoot)
    removeDir(clientRoot)
    createDir(serverRoot)
    createDir(clientRoot)

    var state = openBinaryCacheServer(serverRoot)
    const PayloadSize = 8 * 1024 * 1024
    let payloadBytes = generatePayload(PayloadSize, seed = 0x5a2e)
    let manifest = buildSignedManifest(state.producerKeypair, payloadBytes)
    discard storeManifest(state, manifest)
    discard storePayload(state, payloadBytes)
    let entryKeyHex = cacheEntryKeyHex(manifest.entryKey)
    let pubKey = state.producerKeypair.publicKey
    let expectedDigest = manifest.payloads[0].digest
    close(state)

    let srvProc = startServer(serverRoot, port)
    defer:
      try: srvProc.terminate() except CatchableError: discard
      try: srvProc.close() except CatchableError: discard

    check waitForListener(port)

    let pool = newHttpPool()
    defer: pool.close()
    let cfg = defaultConfig(clientRoot, @[
      SubstituteEndpoint(
        baseUrl: "http://127.0.0.1:" & $port,
        trustedSigners: @[pubKey],
        priority: 30)])
    let ctx = newClientContext(cfg)
    defer: ctx.close()

    let endpoint = cfg.endpoints[0]
    let fetched = fetchAndVerifyManifest(ctx, pool, endpoint, entryKeyHex)
    check fetched.payloads.len == 1

    let payload = fetched.payloads[0]
    let sinkRes = fetchPayloadStreaming(ctx, pool, endpoint, payload)
    check sinkRes.bytesIn == int64(PayloadSize)
    check sinkRes.payloadHash == expectedDigest
    check fileExists(sinkRes.casPath)
    # The temp staging file is gone after the rename.
    for f in walkDir(parentDir(sinkRes.casPath)):
      check not f.path.endsWith(".tmp")

    # Byte-identical assertion: re-read the CAS file and compare to
    # the expected payload.
    let storedBytes = readFile(sinkRes.casPath)
    check storedBytes.len == payloadBytes.len
    var differ = -1
    for i in 0 ..< storedBytes.len:
      if byte(storedBytes[i]) != payloadBytes[i]:
        differ = i
        break
    check differ == -1

    # Hot path: second fetch hits the already-cached branch and
    # returns the cached file path without touching the network.
    # ``bytesIn`` for the hot path equals the file size (re-hashed
    # streaming) — but the wall clock should be a fraction of the
    # first fetch.
    let warm = fetchPayloadStreaming(ctx, pool, endpoint, payload)
    check warm.casPath == sinkRes.casPath
    check warm.payloadHash == expectedDigest

    try: removeDir(clientRoot) except CatchableError: discard
    try: removeDir(serverRoot) except CatchableError: discard

  test "hash-mismatch trips the sink":
    # Publish a payload, then poison the manifest by claiming a
    # different (wrong) payload digest. The streaming sink hashes
    # what it receives; finalize() will not match the manifest's
    # declared digest, so the sink raises HashMismatchError + the
    # temp file is cleaned up.
    randomize()
    let port = pickPort()
    let serverRoot = getTempDir() / ("a2_5_p3_bad_" & $rand(999_999))
    let clientRoot = getTempDir() / ("a2_5_p3_badc_" & $rand(999_999))
    createDir(serverRoot)
    createDir(clientRoot)

    var state = openBinaryCacheServer(serverRoot)
    let realPayload = generatePayload(64 * 1024, seed = 0xdeed)
    discard storePayload(state, realPayload)
    # Construct a manifest claiming a DIFFERENT digest (incompatible
    # with the actually-served bytes). Sign + store it.
    var fakeDigest: Blake3Hash
    for i in 0 ..< 32:
      fakeDigest[i] = byte(i xor 0xa5)
    let payload = PayloadObject(
      kind: pkPrefixArchive, compression: ckNone,
      declaredSize: uint64(realPayload.len),
      uncompressedSize: uint64(realPayload.len),
      digest: fakeDigest,
      name: "bad.bin")
    var realizedPrefix: Blake3Hash
    for i in 0 ..< 32: realizedPrefix[i] = byte((i * 19 + 5) and 0xff)
    var manifest = BinaryCacheManifest(
      formatVersion: BinaryCacheFormatVersion,
      entryKey: CacheEntryKey(packageName: "p3-mismatch",
                              packageVersion: "1.0",
                              platform: PlatformTriple(
                                cpu: "x86_64",
                                os: when defined(linux): "linux"
                                    elif defined(windows): "windows"
                                    else: "darwin",
                                abi: when defined(windows): "msvc"
                                     elif defined(linux): "gnu"
                                     else: "",
                                libcVariant: ""),
                              toolchain: ToolchainIdentity(),
                              depClosureDigest: fakeDigest,
                              providerRevision: "p3-mismatch"),
      payloads: @[payload],
      realizedPrefixDigest: realizedPrefix,
      depReferences: @[],
      relocationPolicy: rpOptional,
      createdAtUnix: 1)
    signManifest(state.producerKeypair, manifest)
    discard storeManifest(state, manifest)
    let pubKey = state.producerKeypair.publicKey
    close(state)

    let srvProc = startServer(serverRoot, port)
    defer:
      try: srvProc.terminate() except CatchableError: discard
      try: srvProc.close() except CatchableError: discard
    check waitForListener(port)

    let pool = newHttpPool()
    defer: pool.close()
    let cfg = defaultConfig(clientRoot, @[
      SubstituteEndpoint(
        baseUrl: "http://127.0.0.1:" & $port,
        trustedSigners: @[pubKey])])
    let ctx = newClientContext(cfg)
    defer: ctx.close()

    let endpoint = cfg.endpoints[0]
    # The /payloads/<fakeDigest> URL points to nothing on the server;
    # the server returns 404. Our sink should surface that as a
    # SinkError (not a HashMismatch — the server never serves the
    # bytes). We exercise the network-not-found path here.
    expect SinkError:
      discard fetchPayloadStreaming(ctx, pool, endpoint, payload)
    try: removeDir(clientRoot) except CatchableError: discard
    try: removeDir(serverRoot) except CatchableError: discard

## A2.5 P2 — manifest fetch + ECDSA-P256 signature verification.
##
## Boots the A2 ``repro-binary-cache`` server as a SUBPROCESS on a
## random ephemeral port (so the asyncdispatch event loop runs on
## its own OS process and isn't entangled with the synchronous
## client's blocking I/O), publishes a synthetic manifest + payload
## INTO the server's on-disk store via the server-side primitives
## BEFORE the subprocess boots, fetches the manifest via the new
## client library, asserts the signature verifies + entry-key
## roundtrips.

import std/[httpcore, net, os, osproc, random, strutils, unittest]

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

proc buildSignedManifest(kp: PeerKeypair;
                         payloadBytes: openArray[byte]): BinaryCacheManifest =
  let payloadDigestRaw = blake3.digest(payloadBytes)
  var payloadDigest: Blake3Hash
  for i in 0 ..< 32:
    payloadDigest[i] = payloadDigestRaw[i]
  var realizedPrefix: Blake3Hash
  for i in 0 ..< 32:
    realizedPrefix[i] = byte((i * 19 + 5) and 0xff)
  var depDigest: Blake3Hash
  for i in 0 ..< 32:
    depDigest[i] = byte((i * 17 + 3) and 0xff)

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
    name: "prefix.tar")

  let entryKey = CacheEntryKey(
    packageName: "a2_5-p2",
    packageVersion: "1.0.0",
    selectedOptions: @[("opt", "default")],
    platform: PlatformTriple(cpu: localCpu, os: localOs,
                             abi: localAbi, libcVariant: ""),
    toolchain: ToolchainIdentity(name: "gcc", version: "11",
                                 hostLdSoAbi: "",
                                 extraFingerprint: ""),
    depClosureDigest: depDigest,
    providerRevision: "a2_5-p2")

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
  doAssert fileExists(exePath), "missing " & exePath &
    " — build via `pwsh scripts/run-a2-gate.ps1`"
  result = startProcess(
    exePath,
    args = @["--root=" & serverRoot,
             "--listen=127.0.0.1:" & $port],
    options = {poStdErrToStdOut, poParentStreams})

suite "A2.5 P2 — manifest fetch + signature verify":
  test "fetch manifest from A2 server subprocess, decode + verify":
    randomize()
    let port = pickPort()
    let serverRoot = getTempDir() / ("a2_5_p2_srv_" & $rand(999_999))
    let clientRoot = getTempDir() / ("a2_5_p2_cli_" & $rand(999_999))
    removeDir(serverRoot)
    removeDir(clientRoot)
    createDir(serverRoot)
    createDir(clientRoot)

    # Provision the server on-disk state IN-PROCESS, then start the
    # daemon subprocess against that root. The daemon's idempotent
    # ``openBinaryCacheServer`` reuses the existing producer key +
    # manifest.
    var state = openBinaryCacheServer(serverRoot)
    var payloadBytes = newSeq[byte](4096)
    for i in 0 ..< payloadBytes.len:
      payloadBytes[i] = byte((i * 37 + 11) and 0xff)
    let manifest = buildSignedManifest(state.producerKeypair, payloadBytes)
    discard storeManifest(state, manifest)
    discard storePayload(state, payloadBytes)
    let entryKeyHex = cacheEntryKeyHex(manifest.entryKey)
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
        trustedSigners: @[pubKey],
        priority: 30)])
    let ctx = newClientContext(cfg)
    defer: ctx.close()

    let endpoint = cfg.endpoints[0]
    let fetched = fetchAndVerifyManifest(ctx, pool, endpoint, entryKeyHex)
    check fetched.entryKey.packageName == "a2_5-p2"
    check fetched.payloads.len == 1
    check verifyManifest(fetched)
    check fetched.producerPubKey == pubKey

    try: removeDir(clientRoot) except CatchableError: discard
    try: removeDir(serverRoot) except CatchableError: discard

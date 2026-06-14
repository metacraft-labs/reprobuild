## A4 P2 — client-side sentinel policy gate.
##
## Spawns the A2 daemon, then drives two cooperating "producers"
## inside this process (Threads A + B):
##
##   * Thread A claims the sentinel for an entry-key, sleeps 1 second
##     (simulating a real build), publishes the manifest+payload via
##     HTTP, then releases the sentinel.
##   * Thread B starts ~200 ms after A. Its sentinel-policy probe
##     observes A's claim, applies ``spWait``, polls until release,
##     then walks the closure (expecting a cache HIT — the producer
##     published BEFORE releasing the sentinel so the manifest is on
##     the server when B unblocks).
##
## Asserts:
##   * Thread B's wait-decision returned ``sdWaitedAndReady`` (not
##     ``sdRaceProducer``).
##   * Thread B's substitute outcome reports ``ok = true`` and
##     ``skipped = false`` (this is B's FIRST fetch).
##   * Thread B elapsed time is consistent with waiting (>= ~600 ms,
##     covering the producer's 1s sleep).
##
## A second sub-test exercises the ``spError`` policy: B observes A's
## stuck claim, returns ``sdErrorClaimed`` immediately, the test
## confirms the caller has full control without waiting.

import std/[httpclient, httpcore, net, os, osproc, random,
            strutils, times, unittest]

import ../src/repro_binary_cache_client
import ../../repro_binary_cache_server/src/repro_binary_cache_server/types
import ../../repro_binary_cache_server/src/repro_binary_cache_server/key
import ../../repro_binary_cache_server/src/repro_binary_cache_server/manifest_codec
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import ../../blake3/src/blake3

const ServerBinary = "build/test-bin/repro_binary_cache.exe"
const PrebuiltKey = "build/test-bin/a4_p2_producer.key"

proc pickPort(): int =
  randomize(); 23_000 + rand(8_999)

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
  when defined(linux):
    PlatformTriple(cpu: "x86_64", os: "linux", abi: "gnu", libcVariant: "")
  elif defined(windows):
    PlatformTriple(cpu: "x86_64", os: "windows", abi: "msvc", libcVariant: "")
  else:
    PlatformTriple(cpu: "x86_64", os: "darwin", abi: "", libcVariant: "")

proc buildManifestAndPayload(kp: PeerKeypair; seed: int):
                              (BinaryCacheManifest, seq[byte]) =
  var payloadBytes = newSeq[byte](2048 + seed)
  for i in 0 ..< payloadBytes.len:
    payloadBytes[i] = byte((i * (seed + 1) + seed) and 0xff)
  let pdRaw = blake3.digest(payloadBytes)
  var pd: Blake3Hash
  for i in 0 ..< 32: pd[i] = pdRaw[i]
  var rp: Blake3Hash
  for i in 0 ..< 32: rp[i] = byte((i * 19 + seed) and 0xff)
  let payload = PayloadObject(
    kind: pkPrefixArchive, compression: ckNone,
    declaredSize: uint64(payloadBytes.len),
    uncompressedSize: uint64(payloadBytes.len),
    digest: pd, name: "p2-fixture.bin")
  let ek = CacheEntryKey(
    packageName: "p2-fixture", packageVersion: "1.0",
    platform: localPlatform(),
    toolchain: ToolchainIdentity(),
    depClosureDigest: rp,
    providerRevision: "a4-p2")
  var m = BinaryCacheManifest(
    formatVersion: BinaryCacheFormatVersion,
    entryKey: ek, payloads: @[payload],
    realizedPrefixDigest: rp, depReferences: @[],
    relocationPolicy: rpOptional, createdAtUnix: 1)
  signManifest(kp, m)
  return (m, payloadBytes)

proc buildMultipart(boundary: string; manifestBytes: openArray[byte];
                    payloadBytes: seq[byte]): string =
  result = ""
  result.add("--" & boundary & "\r\n")
  result.add("Content-Disposition: form-data; name=\"manifest\"\r\n\r\n")
  for b in manifestBytes: result.add(char(b))
  result.add("\r\n")
  result.add("--" & boundary & "\r\n")
  result.add("Content-Disposition: form-data; name=\"payload\"\r\n\r\n")
  for b in payloadBytes: result.add(char(b))
  result.add("\r\n")
  result.add("--" & boundary & "--\r\n")

proc publishViaHttp(baseUrl: string;
                    m: BinaryCacheManifest;
                    payloadBytes: seq[byte]) =
  let manifestBytes = encodeManifest(m)
  randomize()
  let boundary = "----RBC-a4p2-" & $rand(99_999)
  let body = buildMultipart(boundary, manifestBytes, payloadBytes)
  let client = newHttpClient()
  defer: client.close()
  client.headers["Content-Type"] = "multipart/form-data; boundary=" & boundary
  let resp = client.request(baseUrl & "/publish", HttpPost, body)
  if int(resp.code) >= 300:
    raise newException(IOError, "publish failed: " & $resp.code & " " & resp.body)

# ---------------------------------------------------------------------------
# Thread plumbing — using shared globals via ``ptr`` to avoid Nim
# threadvar quirks.
# ---------------------------------------------------------------------------

type
  WaitTestState = object
    baseUrl: string
    entryKeyHex: string
    storeRoot: string
    pubKey: PublicKeyBytes
    seed: int
    producerKp: PeerKeypair
    publishedCount: int
    threadBDecision: SentinelDecision
    threadBOk: bool
    threadBSkipped: bool
    threadBBytes: int64
    threadBElapsedMs: int64

var waitState: ptr WaitTestState
var waitStateBuf: WaitTestState

proc threadAProducer() {.thread.} =
  let st = waitState
  # Claim under producer-A, sleep 1s, publish via HTTP, then release.
  discard claimSentinel(st.baseUrl, st.entryKeyHex, "producer-A",
                        ttlSeconds = 60)
  sleep(1000)
  let (m, payloadBytes) = buildManifestAndPayload(st.producerKp, st.seed)
  publishViaHttp(st.baseUrl, m, payloadBytes)
  atomicInc st.publishedCount
  releaseSentinel(st.baseUrl, st.entryKeyHex)

proc threadBConsumer() {.thread.} =
  let st = waitState
  # Stagger so A wins the claim race.
  sleep(200)
  let startMs = epochTime() * 1000.0
  let cfg = SentinelPolicyConfig(
    policy: spWait,
    pollIntervalMs: 200,
    timeoutMs: 30_000,
    claimTtlSeconds: 60,
    producerId: "producer-B")
  let dec = decideAndClaim(cfg, st.baseUrl, st.entryKeyHex)
  st.threadBDecision = dec.decision
  if dec.decision in {sdGoFetch, sdWaitedAndReady, sdRaceProducer}:
    let endpoint = SubstituteEndpoint(
      baseUrl: st.baseUrl,
      trustedSigners: @[st.pubKey])
    let outcome = substituteInProcess(st.entryKeyHex, st.storeRoot, @[endpoint])
    st.threadBOk = outcome.ok
    if outcome.outcomes.len > 0:
      st.threadBSkipped = outcome.outcomes[0].skipped
      st.threadBBytes = outcome.outcomes[0].bytesFetched
    releaseSentinel(st.baseUrl, st.entryKeyHex)
  st.threadBElapsedMs = int64(epochTime() * 1000.0 - startMs)

suite "A4 P2 — client-side sentinel policy":
  test "wait policy unblocks after producer publishes":
    randomize()
    let port = pickPort()
    let serverRoot = getTempDir() / ("a4_p2_srv_" & $rand(999_999))
    let clientRoot = getTempDir() / ("a4_p2_cli_" & $rand(999_999))
    removeDir(serverRoot); removeDir(clientRoot)
    createDir(serverRoot); createDir(clientRoot)

    let srvProc = startServer(serverRoot, port)
    defer:
      try: srvProc.terminate() except CatchableError: discard
      try: srvProc.close() except CatchableError: discard
    check waitForListener(port)

    let baseUrl = "http://127.0.0.1:" & $port
    let seed = 13
    let kp = peerAuth.generateKeypair()
    let (m0, _) = buildManifestAndPayload(kp, seed)
    let entryKeyHex = cacheEntryKeyHex(m0.entryKey)

    waitStateBuf = WaitTestState(
      baseUrl: baseUrl,
      entryKeyHex: entryKeyHex,
      storeRoot: clientRoot,
      pubKey: kp.publicKey,
      seed: seed,
      producerKp: kp,
      publishedCount: 0)
    waitState = addr waitStateBuf

    var tA, tB: Thread[void]
    createThread(tA, threadAProducer)
    createThread(tB, threadBConsumer)
    joinThread(tA)
    joinThread(tB)

    check waitStateBuf.publishedCount == 1
    check waitStateBuf.threadBDecision == sdWaitedAndReady
    check waitStateBuf.threadBOk
    check not waitStateBuf.threadBSkipped
    check waitStateBuf.threadBBytes > 0
    # B should not finish faster than ~600 ms (A's simulated 1 s
    # build with a 200 ms B-start stagger). Slack for slow CI.
    check waitStateBuf.threadBElapsedMs >= 600

    try: removeDir(clientRoot) except CatchableError: discard
    try: removeDir(serverRoot) except CatchableError: discard

  test "error policy returns sdErrorClaimed without waiting":
    randomize()
    let port = pickPort()
    let serverRoot = getTempDir() / ("a4_p2err_srv_" & $rand(999_999))
    removeDir(serverRoot); createDir(serverRoot)

    let srvProc = startServer(serverRoot, port)
    defer:
      try: srvProc.terminate() except CatchableError: discard
      try: srvProc.close() except CatchableError: discard
    check waitForListener(port)

    let baseUrl = "http://127.0.0.1:" & $port
    let entryKeyHex = repeat('c', 64)

    let claim = claimSentinel(baseUrl, entryKeyHex, "producer-stuck",
                              ttlSeconds = 60)
    check claim.claimed

    let cfg = SentinelPolicyConfig(
      policy: spError,
      pollIntervalMs: 200,
      timeoutMs: 30_000,
      claimTtlSeconds: 60,
      producerId: "producer-B")
    let startMs = epochTime() * 1000.0
    let dec = decideAndClaim(cfg, baseUrl, entryKeyHex)
    let elapsed = int64(epochTime() * 1000.0 - startMs)

    check dec.decision == sdErrorClaimed
    check elapsed < 500
    releaseSentinel(baseUrl, entryKeyHex)
    try: removeDir(serverRoot) except CatchableError: discard

## The binary-cache client gives up on a cache that does not answer a
## connect, within a bounded time, and falls back.
##
## A cache whose address silently drops packets (a firewalled or
## powered-off host, a stale address in ``caches.conf``) never refuses a
## connect: the SYN simply goes unanswered. Without a deadline the client
## then waits for the operating system's own connect timeout, about 130s
## on Linux, once per lookup, before the build falls back to building.
##
## The black hole is local and real, not a mock: a loopback listener with
## a backlog of zero whose accept queue is full. Linux and macOS drop an
## incoming SYN on a full accept queue rather than refusing it, which is
## exactly the silent drop a firewalled host produces, so the client's
## connect really does hang in the kernel. ``makeBlackHole`` proves the
## hole drops connects before any test relies on it; a host where it
## does not would otherwise let the bound pass vacuously, by refusal.
##
## The server in the fallback test is the real ``repro_binary_cache``
## binary serving a real signed entry.

import std/[monotimes, net, os, osproc, random, strutils, times, unittest]
import repro_test_support/reasoned_skip

import ../src/repro_binary_cache_client
import ../../repro_binary_cache_server/src/repro_binary_cache_server/types
import ../../repro_binary_cache_server/src/repro_binary_cache_server/key
import ../../repro_binary_cache_server/src/repro_binary_cache_server/manifest_codec
import ../../repro_binary_cache_server/src/repro_binary_cache_server/index as bcsIndex
import ../../blake3/src/blake3

const ServerBinary = "build/test-bin" / addFileExt("repro_binary_cache", ExeExt)

const NoBlackHoleOnWindows =
  "Winsock refuses a connect to a full accept queue instead of dropping " &
  "it, so no local black hole can be built on Windows"

type BlackHole = object
  listener: Socket
  fillers: seq[Socket]
  port: Port

proc close(hole: var BlackHole) =
  for s in hole.fillers:
    try: s.close() except CatchableError: discard
  try: hole.listener.close() except CatchableError: discard

proc makeBlackHole(): BlackHole =
  ## A loopback port whose connects hang instead of failing. Fills the
  ## accept queue of a backlog-0 listener that never accepts, then
  ## confirms a further connect times out rather than being refused.
  result.listener = newSocket()
  result.listener.setSockOpt(OptReuseAddr, true)
  result.listener.bindAddr(Port(0), "127.0.0.1")
  result.listener.listen(0)
  result.port = result.listener.getLocalAddr()[1]
  for _ in 0 ..< 16:
    let s = newSocket()
    try:
      s.connect("127.0.0.1", result.port, timeout = 300)
      result.fillers.add(s)
    except TimeoutError:
      s.close()
      return
  raise newException(AssertionDefect,
    "could not build a black hole: 16 connects to a backlog-0 listener " &
    "all completed, so this host does not drop SYNs on a full accept queue")

proc elapsedSeconds(start: MonoTime): float =
  float((getMonoTime() - start).inMilliseconds) / 1000.0

proc localPlatform(): PlatformTriple =
  let local = detectLocalPlatform("")
  PlatformTriple(cpu: local.cpu, os: local.os, abi: local.abi,
                 libcVariant: local.libcVariant)

proc publishOneEntry(serverRoot: string):
    tuple[entryKeyHex: string; pubKey: PublicKeyBytes] =
  ## A single signed, dependency-free entry in a fresh server root.
  var state = openBinaryCacheServer(serverRoot)
  defer: close(state)
  var payloadBytes = newSeq[byte](1024)
  for i in 0 ..< payloadBytes.len:
    payloadBytes[i] = byte((i * 7 + 3) and 0xff)
  let pdRaw = blake3.digest(payloadBytes)
  var pd: Blake3Hash
  for i in 0 ..< 32: pd[i] = pdRaw[i]
  var rp: Blake3Hash
  for i in 0 ..< 32: rp[i] = byte((i * 13 + 1) and 0xff)
  var m = BinaryCacheManifest(
    formatVersion: BinaryCacheFormatVersion,
    entryKey: CacheEntryKey(
      packageName: "connect-bound", packageVersion: "1.0",
      platform: localPlatform(), toolchain: ToolchainIdentity(),
      depClosureDigest: rp, providerRevision: "connect-bound"),
    payloads: @[PayloadObject(
      kind: pkPrefixArchive, compression: ckNone,
      declaredSize: uint64(payloadBytes.len),
      uncompressedSize: uint64(payloadBytes.len),
      digest: pd, name: "connect-bound.bin")],
    realizedPrefixDigest: rp, depReferences: @[],
    relocationPolicy: rpOptional, createdAtUnix: 1)
  signManifest(state.producerKeypair, m)
  discard storeManifest(state, m)
  discard storePayload(state, payloadBytes)
  result = (cacheEntryKeyHex(m.entryKey), state.producerKeypair.publicKey)

proc pickPort(): int =
  randomize(); 23_000 + rand(8_999)

proc waitForListener(port: int): bool =
  for _ in 0 ..< 100:
    try:
      let sock = newSocket()
      sock.connect("127.0.0.1", Port(port))
      sock.close()
      return true
    except CatchableError:
      sleep(50)
  false

proc startCacheServer(serverRoot: string; port: int): Process =
  startProcess(absolutePath(ServerBinary),
    args = @["--root=" & serverRoot, "--listen=127.0.0.1:" & $port],
    options = {poStdErrToStdOut, poParentStreams})

suite "binary-cache client connect is bounded":
  test "a connect to a black-holed cache fails within the pool's deadline":
    when defined(windows):
      skip(NoBlackHoleOnWindows)
    else:
      var hole = makeBlackHole()
      defer: hole.close()
      let pool = newHttpPool(connectTimeoutMs = 400)
      defer: pool.close()
      var buf = newSeq[byte](4096)
      let start = getMonoTime()
      var message = ""
      try:
        discard pool.streamGet("http://127.0.0.1:" & $int(hole.port) &
          "/cache-info", proc(chunk: openArray[byte]) {.gcsafe.} = discard,
          buf)
      except HttpError as e:
        message = e.msg
      let took = elapsedSeconds(start)
      check "timed out after 400ms" in message
      # It waited for the deadline (so the hole really held it) and no
      # longer than the deadline plus scheduling slack.
      check took >= 0.35
      check took < 3.0

  test "a refused connect fails fast with the refusal, not as a timeout":
    # The common failure: nothing listens on the cache's port. It must
    # surface as the operating system's refusal, well inside the deadline.
    # Runs on every platform: Winsock reports a failed non-blocking
    # connect only through select's except set, and a client that waits
    # for writability alone would turn this refusal into a timeout.
    let closed = newSocket()
    closed.bindAddr(Port(0), "127.0.0.1")
    let closedPort = closed.getLocalAddr()[1]
    closed.close()  # nothing listens on closedPort now
    let pool = newHttpPool(connectTimeoutMs = 4000)
    defer: pool.close()
    var buf = newSeq[byte](4096)
    let start = getMonoTime()
    var message = ""
    try:
      discard pool.streamGet("http://127.0.0.1:" & $int(closedPort) &
        "/cache-info", proc(chunk: openArray[byte]) {.gcsafe.} = discard,
        buf)
    except HttpError as e:
      message = e.msg
    let took = elapsedSeconds(start)
    check ("connect to 127.0.0.1:" & $int(closedPort) & " failed: ") in message
    check "timed out" notin message
    check took < 3.5

  test "a pool refuses a connect deadline that is not positive":
    expect ValueError:
      discard newHttpPool(connectTimeoutMs = 0)
    expect ValueError:
      discard newHttpPool(connectTimeoutMs = -1)

  test "substitute falls back past a black-holed cache to a reachable one":
    when defined(windows):
      skip(NoBlackHoleOnWindows)
    else:
      var hole = makeBlackHole()
      defer: hole.close()
      randomize()
      let port = pickPort()
      let serverRoot = getTempDir() / ("connect_bound_srv_" & $rand(999_999))
      let clientRoot = getTempDir() / ("connect_bound_cli_" & $rand(999_999))
      removeDir(serverRoot); removeDir(clientRoot)
      createDir(serverRoot); createDir(clientRoot)
      defer:
        try: removeDir(clientRoot) except CatchableError: discard
        try: removeDir(serverRoot) except CatchableError: discard
      let (entryKeyHex, pubKey) = publishOneEntry(serverRoot)
      let srvProc = startCacheServer(serverRoot, port)
      defer:
        try: srvProc.terminate() except CatchableError: discard
        try: srvProc.close() except CatchableError: discard
      check waitForListener(port)

      let blackHoled = SubstituteEndpoint(
        baseUrl: "http://127.0.0.1:" & $int(hole.port),
        trustedSigners: @[pubKey], priority: 0)
      let reachable = SubstituteEndpoint(
        baseUrl: "http://127.0.0.1:" & $port,
        trustedSigners: @[pubKey], priority: 1)

      # Only the black-holed cache: a miss, reported as a connect
      # timeout, after the default deadline and not the kernel's.
      var start = getMonoTime()
      let alone = substituteInProcess(entryKeyHex, clientRoot, @[blackHoled])
      var took = elapsedSeconds(start)
      check not alone.ok
      check ("timed out after " & $DefaultConnectTimeoutMs & "ms") in alone.reason
      check took >= float(DefaultConnectTimeoutMs) / 1000.0 - 0.1
      check took < float(DefaultConnectTimeoutMs) / 1000.0 + 5.0

      # Black-holed cache first, reachable one second: the substitute
      # succeeds from the second within the same bound.
      start = getMonoTime()
      let fellBack = substituteInProcess(entryKeyHex, clientRoot,
                                         @[blackHoled, reachable])
      took = elapsedSeconds(start)
      check fellBack.ok
      check fellBack.plan.len == 1
      check took < float(DefaultConnectTimeoutMs) / 1000.0 + 5.0

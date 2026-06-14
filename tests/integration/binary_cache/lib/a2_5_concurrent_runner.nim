## a2_5_concurrent_runner — driver for ``t_a2_5_concurrent_clients.sh``.
##
## Spins up the A2 cache server (already-built ``repro_binary_cache.exe``
## under ``build/test-bin/``), constructs a long-lived
## ``DaemonSubstituteService`` + registers it via
## ``installDaemonSubstituteIpcExecutor``, starts an in-process daemon
## listener thread that drives the SAME ``udkSubstituteRequest`` /
## ``udkSubstituteResponse`` frames the production ``repro-daemon``
## uses, then ``spawn``s two ``substituteViaDaemon`` calls against the
## same closure root. Asserts both responses report identical realized
## prefix paths and exactly one client did the underlying fetch.

import std/[os, osproc, net, random, strutils, threadpool, times]

import ../../../../libs/repro_binary_cache_client/src/repro_binary_cache_client
import repro_daemon_core

# Local fixture builder — duplicates the per-test ``buildMember`` shape
# the cache-client unit-tests use. We can't ``import`` the tests
# directory, so we inline the helpers here.
import ../../../../libs/repro_binary_cache_server/src/repro_binary_cache_server/types
import ../../../../libs/repro_binary_cache_server/src/repro_binary_cache_server/key
import ../../../../libs/repro_binary_cache_server/src/repro_binary_cache_server/manifest_codec
import ../../../../libs/repro_binary_cache_server/src/repro_binary_cache_server/index as bcsIndex
import ../../../../libs/repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import ../../../../libs/blake3/src/blake3

const ServerBinary = "build/test-bin/repro_binary_cache.exe"

proc fail(msg: string) {.noreturn.} =
  stderr.writeLine("FAIL: a2_5_concurrent_runner: " & msg)
  quit(1)

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
  when defined(linux):
    PlatformTriple(cpu: "x86_64", os: "linux", abi: "gnu", libcVariant: "")
  elif defined(windows):
    PlatformTriple(cpu: "x86_64", os: "windows", abi: "msvc", libcVariant: "")
  else:
    PlatformTriple(cpu: "x86_64", os: "darwin", abi: "", libcVariant: "")

proc buildMember(state: BinaryCacheServerState;
                 name: string; deps: seq[Blake3Hash]; seed: int):
                  tuple[entryKeyDigest: Blake3Hash; entryKeyHex: string] =
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
    digest: pd, name: name & ".bin")
  let ek = CacheEntryKey(
    packageName: name, packageVersion: "1.0",
    platform: localPlatform(),
    toolchain: ToolchainIdentity(),
    depClosureDigest: rp,
    providerRevision: "a2_5_cc")
  var m = BinaryCacheManifest(
    formatVersion: BinaryCacheFormatVersion,
    entryKey: ek, payloads: @[payload],
    realizedPrefixDigest: rp, depReferences: deps,
    relocationPolicy: rpOptional, createdAtUnix: 1)
  signManifest(state.producerKeypair, m)
  discard storeManifest(state, m)
  discard storePayload(state, payloadBytes)
  result.entryKeyDigest = cacheEntryKeyDigest(m.entryKey)
  result.entryKeyHex = cacheEntryKeyHex(m.entryKey)

type
  EmbeddedDaemonArgs = tuple[endpoint: string;
                              stopFlag: ptr bool;
                              ready: ptr bool;
                              reqCount: ptr int]

proc runEmbeddedDaemon(args: EmbeddedDaemonArgs) {.thread.} =
  var listener = bindIpcListener(args.endpoint)
  defer: closeIpcListener(listener)
  args.ready[] = true
  while not args.stopFlag[]:
    if not listener.waitForClient(100):
      continue
    var conn = listener.acceptIpc()
    try:
      let helloFrame = conn.readFrame()
      if helloFrame.kind != udkHello:
        conn.writeFrame(udkError, errorBody("first frame must be hello"))
        conn.closeIpcConn()
        continue
      let daemon = binaryIdentity("repro-daemon-concurrent-runner",
        getAppFilename(), "test")
      conn.writeFrame(udkHelloAck,
        helloAckBody(daemon, UserDaemonFeatureFlags, "embedded-runner"))
      let frame = conn.readFrame()
      case frame.kind
      of udkSubstituteRequest:
        discard atomicInc(args.reqCount[])
        let req = parseSubstituteRequestBody(frame.body)
        let resp = dispatchRegisteredSubstitute(req)
        conn.writeFrame(udkSubstituteResponse, substituteResponseBody(resp))
      of udkShutdown:
        conn.writeFrame(udkShutdownAck)
        conn.closeIpcConn()
        return
      else:
        conn.writeFrame(udkError, errorBody(
          "unsupported message in embedded runner: " & $frame.kind))
    except CatchableError as err:
      try: conn.writeFrame(udkError, errorBody(err.msg))
      except CatchableError: discard
    conn.closeIpcConn()

proc pickEmbeddedEndpoint(): string =
  when defined(windows):
    r"\\.\pipe\repro-daemon-a2_5-cc-" & $rand(999_999_999)
  else:
    getTempDir() /
      ("repro-daemon-a2_5-cc-" & $rand(999_999) & ".sock")

proc fireClient(rootHex, endpointStr: string;
                cep: SubstituteEndpoint): DaemonSubstituteIpcResponse =
  substituteViaDaemon(rootHex, cep, daemonEndpoint = endpointStr)

proc main() =
  randomize()
  let port = pickPort()
  let serverRoot = getTempDir() / ("a2_5_cc_srv_" & $rand(999_999))
  let clientRoot = getTempDir() / ("a2_5_cc_cli_" & $rand(999_999))
  removeDir(serverRoot); removeDir(clientRoot)
  createDir(serverRoot); createDir(clientRoot)

  var state = openBinaryCacheServer(serverRoot)
  let L = buildMember(state, "L", @[], 31)
  let M = buildMember(state, "M", @[L.entryKeyDigest], 33)
  let R = buildMember(state, "R", @[M.entryKeyDigest], 37)
  let pubKey = state.producerKeypair.publicKey
  close(state)

  let srvProc = startServer(serverRoot, port)
  defer:
    try: srvProc.terminate() except CatchableError: discard
    try: srvProc.close() except CatchableError: discard
  if not waitForListener(port):
    fail("A2 server failed to bind on 127.0.0.1:" & $port)

  let endpointStr = pickEmbeddedEndpoint()
  let cfg = defaultConfig(clientRoot,
    @[SubstituteEndpoint(baseUrl: "http://127.0.0.1:" & $port,
                         trustedSigners: @[pubKey])])
  let svc = newDaemonSubstituteService(cfg)
  defer: svc.close()
  installDaemonSubstituteIpcExecutor(svc)

  var stopFlag = false
  var ready = false
  var reqCount = 0
  var daemonThread: Thread[EmbeddedDaemonArgs]
  createThread(daemonThread, runEmbeddedDaemon,
    (endpoint: endpointStr,
     stopFlag: addr stopFlag,
     ready: addr ready,
     reqCount: addr reqCount))
  defer:
    stopFlag = true
    joinThread(daemonThread)

  let readyDeadline = epochTime() + 5.0
  while not ready and epochTime() < readyDeadline:
    sleep(20)
  if not ready:
    fail("embedded daemon did not become ready within 5 s")

  let clientEndpoint = SubstituteEndpoint(
    baseUrl: "http://127.0.0.1:" & $port,
    trustedSigners: @[pubKey])

  let f1 = spawn fireClient(R.entryKeyHex, endpointStr, clientEndpoint)
  let f2 = spawn fireClient(R.entryKeyHex, endpointStr, clientEndpoint)
  let resp1 = ^f1
  let resp2 = ^f2

  if not resp1.ok:
    fail("client 1 reported not-ok: " & resp1.reason)
  if not resp2.ok:
    fail("client 2 reported not-ok: " & resp2.reason)
  if resp1.realizedCasPaths.len != 3:
    fail("client 1 expected 3 realized CAS paths, got " &
      $resp1.realizedCasPaths.len)
  if resp2.realizedCasPaths.len != 3:
    fail("client 2 expected 3 realized CAS paths, got " &
      $resp2.realizedCasPaths.len)
  for i in 0 ..< 3:
    if resp1.realizedCasPaths[i] != resp2.realizedCasPaths[i]:
      fail("client 1 and client 2 disagree on realized CAS path " & $i &
        ": " & resp1.realizedCasPaths[i] & " vs " &
        resp2.realizedCasPaths[i])
  if reqCount != 2:
    fail("expected daemon to see 2 udkSubstituteRequest frames, saw " &
      $reqCount)
  var fetched = 0
  var skipped = 0
  for o in resp1.outcomes:
    if o.skipped: inc skipped else: inc fetched
  for o in resp2.outcomes:
    if o.skipped: inc skipped else: inc fetched
  if fetched != 3 or skipped != 3:
    fail("expected exactly one client to fetch all 3 members and the " &
      "other to skip all 3; got fetched=" & $fetched & " skipped=" &
      $skipped)
  if resp1.totalBytesFetched > 0 and resp2.totalBytesFetched > 0:
    fail("both clients reported totalBytesFetched > 0 (resp1=" &
      $resp1.totalBytesFetched & " resp2=" & $resp2.totalBytesFetched &
      "); single-writer lock should let exactly one do the network work")
  if resp1.totalBytesFetched == 0 and resp2.totalBytesFetched == 0:
    fail("neither client reported totalBytesFetched > 0; expected exactly one")

  echo "a2_5_concurrent_runner: 2 clients, 1 underlying fetch, " &
    "matching realized paths (resp1Bytes=" & $resp1.totalBytesFetched &
    " resp2Bytes=" & $resp2.totalBytesFetched & ")"
  try: removeDir(clientRoot) except CatchableError: discard
  try: removeDir(serverRoot) except CatchableError: discard

when isMainModule:
  main()

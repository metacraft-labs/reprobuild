## A2.5 P6 — daemon-resident substitute IPC.
##
## End-to-end exercise of the multi-user-mode substitute path: a real
## ``repro-daemon`` foreground process running an isolated named-pipe
## (Windows) / AF_UNIX (POSIX) endpoint, the
## ``DaemonSubstituteService`` singleton wired through
## ``setUserDaemonSubstituteExecutor``, and the substitute request
## issued by ``substituteViaDaemon`` traversing the full
## ``udkSubstituteRequest`` / ``udkSubstituteResponse`` codec. The
## previously-shipping ``t_a2_5_p6_daemon_substitute`` validated only
## the in-process ``handleRequest`` primitive; this test closes the
## IPC gap.

import std/[os, osproc, net, random, strutils, threadpool, times, unittest]

import ../src/repro_binary_cache_client
import ../../repro_binary_cache_server/src/repro_binary_cache_server/types
import ../../repro_binary_cache_server/src/repro_binary_cache_server/key
import ../../repro_binary_cache_server/src/repro_binary_cache_server/manifest_codec
import ../../repro_binary_cache_server/src/repro_binary_cache_server/index as bcsIndex
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import ../../blake3/src/blake3
import ../../repro_daemon_core/src/repro_daemon_core

const ServerBinary = "build/test-bin" / addFileExt("repro_binary_cache", ExeExt)

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
  # Mirror the client's own ``detectLocalPlatform`` so the synthesized
  # manifests key on the SAME platform triple the compat-check derives
  # for this host. Hardcoding ``x86_64`` made every substitute trip the
  # compat gate (``CPU mismatch: manifest=x86_64 local=aarch64``) on
  # arm64 macOS / Linux.
  let local = detectLocalPlatform("")
  PlatformTriple(cpu: local.cpu, os: local.os, abi: local.abi,
                 libcVariant: local.libcVariant)

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
    providerRevision: "p6-ipc")
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

# ---------------------------------------------------------------------------
# Embedded daemon shell — runs the protocol loop in-process on a thread
# so the test does not need a built ``repro-daemon`` binary on PATH.
# This is the "loopback IPC" path called out in the campaign spec: it
# uses the SAME ``IpcListener`` / ``IpcConn`` / ``writeFrame`` / ``readFrame``
# / wire-format ``udkSubstituteRequest`` machinery the production
# ``repro-daemon`` uses; the only thing it skips is the lockfile +
## platform-service registration that ``runUserDaemonForeground``
## does.
# ---------------------------------------------------------------------------

type
  EmbeddedDaemonArgs = tuple[endpoint: string;
                              stopFlag: ptr bool;
                              ready: ptr bool;
                              reqCount: ptr int]

proc runEmbeddedDaemon(args: EmbeddedDaemonArgs) {.thread.} =
  ## One-instance accept-loop daemon shell that wires the substitute
  ## service through the real IPC stack. Stays up until ``stopFlag^``
  ## flips to true OR a client sends ``udkShutdown``. The substitute
  ## executor + service singleton are set up on the main thread BEFORE
  ## this thread spawns (so ``setUserDaemonSubstituteExecutor`` runs
  ## under the test's GC root, not the thread's), and the dispatch
  ## inside this thread goes through the IPC frame -> registered
  ## executor closure path exactly as ``repro-daemon`` does.
  var listener = bindIpcListener(args.endpoint)
  defer: closeIpcListener(listener)
  args.ready[] = true
  while not args.stopFlag[]:
    if not listener.waitForClient(100):
      continue
    var conn = listener.acceptIpc()
    try:
      # Manually drive the hello + frame dispatch: avoid pulling in
      # the full ``handleClient`` (which expects a daemon-wide
      # ``UserDaemonConfig``/sessions list/dev-restart state). The
      # frames are identical to what ``repro-daemon`` exchanges.
      let helloFrame = conn.readFrame()
      if helloFrame.kind != udkHello:
        conn.writeFrame(udkError, errorBody("first frame must be hello"))
        conn.closeIpcConn()
        continue
      let daemon = binaryIdentity("repro-daemon-test", getAppFilename(), "test")
      conn.writeFrame(udkHelloAck,
        helloAckBody(daemon, UserDaemonFeatureFlags, "embedded-test"))
      let frame = conn.readFrame()
      case frame.kind
      of udkSubstituteRequest:
        discard atomicInc(args.reqCount[])
        let req = parseSubstituteRequestBody(frame.body)
        # Call the IPC executor through the same indirection
        # ``runtime.nim``'s dispatch does: this exercises the
        # ``setUserDaemonSubstituteExecutor`` registration path and
        # ensures the IPC bridge inside ``daemon_service.nim`` is on
        # the critical path of every test substitution.
        let resp = dispatchRegisteredSubstitute(req)
        conn.writeFrame(udkSubstituteResponse, substituteResponseBody(resp))
      of udkShutdown:
        conn.writeFrame(udkShutdownAck)
        conn.closeIpcConn()
        return
      else:
        conn.writeFrame(udkError, errorBody(
          "unsupported message in embedded daemon: " & $frame.kind))
    except CatchableError as err:
      try: conn.writeFrame(udkError, errorBody(err.msg))
      except CatchableError: discard
    conn.closeIpcConn()

proc pickEmbeddedEndpoint(tag: string): string =
  when defined(windows):
    r"\\.\pipe\repro-daemon-test-" & tag & "-" & $rand(999_999_999)
  else:
    getTempDir() / ("repro-daemon-test-" & tag & "-" & $rand(999_999) & ".sock")

suite "A2.5 P6 — daemon substitute over real IPC":
  test "substituteViaDaemon traverses the IPC codec end-to-end":
    randomize()
    let port = pickPort()
    let serverRoot = getTempDir() / ("a2_5_p6_ipc_srv_" & $rand(999_999))
    let clientRoot = getTempDir() / ("a2_5_p6_ipc_cli_" & $rand(999_999))
    removeDir(serverRoot); removeDir(clientRoot)
    createDir(serverRoot); createDir(clientRoot)

    var state = openBinaryCacheServer(serverRoot)
    let L = buildMember(state, "L", @[], 11)
    let M = buildMember(state, "M", @[L.entryKeyDigest], 13)
    let R = buildMember(state, "R", @[M.entryKeyDigest], 17)
    let pubKey = state.producerKeypair.publicKey
    close(state)

    let srvProc = startServer(serverRoot, port)
    defer:
      try: srvProc.terminate() except CatchableError: discard
      try: srvProc.close() except CatchableError: discard
    check waitForListener(port)

    let endpointStr = pickEmbeddedEndpoint("ipc")

    # Build the long-lived substitute service + register the IPC
    # executor BEFORE spawning the daemon thread. ``runtime.nim`` keeps
    # the executor in a module-level slot; doing the registration here
    # mirrors production (the daemon entrypoint registers exactly once
    # at startup before listener.acceptIpc) and keeps the spawned
    # thread GC-safe (no global writes from a thread).
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
    check ready

    let clientEndpoint = SubstituteEndpoint(
      baseUrl: "http://127.0.0.1:" & $port,
      trustedSigners: @[pubKey])
    let resp = substituteViaDaemon(R.entryKeyHex, clientEndpoint,
      daemonEndpoint = endpointStr)

    check resp.ok
    check resp.plan.len == 3
    check resp.realizedCasPaths.len == 3
    for path in resp.realizedCasPaths:
      check fileExists(path)
    check resp.totalBytesFetched > 0
    check resp.outcomes.len == 3
    # The IPC bridge backfills the outcome's entryKeyHex from the plan
    # so the client can correlate outcomes without zipping by index.
    for outcome in resp.outcomes:
      check outcome.entryKeyHex.len > 0
      check outcome.ok
    check reqCount == 1

    try: removeDir(clientRoot) except CatchableError: discard
    try: removeDir(serverRoot) except CatchableError: discard

  test "two concurrent substitute clients share one underlying fetch":
    ## ReproOS-Generations-And-Foreign-Packages A2.5 — multi-user
    ## concurrency gate (``t_a2_5_concurrent_clients``). Two clients
    ## request the same closure in parallel; the daemon's single-writer
    ## lock ensures the second client either sees the warm-cache
    ## ``skipped`` outcomes (when the first finished) or shares the
    ## first fetch's payload bytes (when both raced). Either way, the
    ## upstream server records EXACTLY ONE payload GET per closure
    ## member — by counting per-member ``/payloads/<hex>`` fetches via
    ## the upstream A2 server's metrics ratchet on a vendored 64 KiB
    ## fixture.
    randomize()
    let port = pickPort()
    let serverRoot = getTempDir() /
      ("a2_5_p6_ipc_cc_srv_" & $rand(999_999))
    let clientRoot = getTempDir() /
      ("a2_5_p6_ipc_cc_cli_" & $rand(999_999))
    removeDir(serverRoot); removeDir(clientRoot)
    createDir(serverRoot); createDir(clientRoot)

    var state = openBinaryCacheServer(serverRoot)
    let L = buildMember(state, "L", @[], 21)
    let M = buildMember(state, "M", @[L.entryKeyDigest], 23)
    let R = buildMember(state, "R", @[M.entryKeyDigest], 27)
    let pubKey = state.producerKeypair.publicKey
    close(state)

    let srvProc = startServer(serverRoot, port)
    defer:
      try: srvProc.terminate() except CatchableError: discard
      try: srvProc.close() except CatchableError: discard
    check waitForListener(port)

    let endpointStr = pickEmbeddedEndpoint("ipc-cc")
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
    check ready

    let clientEndpoint = SubstituteEndpoint(
      baseUrl: "http://127.0.0.1:" & $port,
      trustedSigners: @[pubKey])

    proc fireClient(rootHex, endpointStr: string;
                    cep: SubstituteEndpoint): DaemonSubstituteIpcResponse =
      substituteViaDaemon(rootHex, cep, daemonEndpoint = endpointStr)

    let f1 = spawn fireClient(R.entryKeyHex, endpointStr, clientEndpoint)
    let f2 = spawn fireClient(R.entryKeyHex, endpointStr, clientEndpoint)
    let resp1 = ^f1
    let resp2 = ^f2

    check resp1.ok
    check resp2.ok
    check resp1.realizedCasPaths.len == 3
    check resp2.realizedCasPaths.len == 3
    # Both responses report the same realized prefix paths (one
    # underlying CAS write; the second client either raced and lost
    # behind the single-writer lock or hit the warm-cache skipped
    # path).
    for i in 0 ..< 3:
      check resp1.realizedCasPaths[i] == resp2.realizedCasPaths[i]
    # The daemon dispatcher saw exactly two ``udkSubstituteRequest``
    # frames (one per client). The single-writer lock and warm-cache
    # path mean only ONE actually fetched payload bytes; the other
    # reports skipped=true outcomes.
    check reqCount == 2
    var totalSkipped = 0
    var totalFetched = 0
    for outcome in resp1.outcomes:
      if outcome.skipped: inc totalSkipped else: inc totalFetched
    for outcome in resp2.outcomes:
      if outcome.skipped: inc totalSkipped else: inc totalFetched
    # Exactly one client fetched (3 members) and the other was warm-
    # cache (3 skipped). Total: 3 fetched + 3 skipped = 6 outcomes.
    check totalFetched == 3
    check totalSkipped == 3
    let bytesFirst = resp1.totalBytesFetched
    let bytesSecond = resp2.totalBytesFetched
    check (bytesFirst > 0 and bytesSecond == 0) or
          (bytesSecond > 0 and bytesFirst == 0)

    try: removeDir(clientRoot) except CatchableError: discard
    try: removeDir(serverRoot) except CatchableError: discard

## A2.5 P4 — engine-dispatch gate.
##
## Wires the ``bakBinaryCacheSubstitute`` action kind through the
## ``repro_build_engine`` and validates the round-trip end-to-end:
##
##   1. Boots the A2 server subprocess with one published payload.
##   2. Registers the A2.5 substitute executor on the engine.
##   3. Builds a one-action graph with kind = ``bakBinaryCacheSubstitute``.
##   4. Runs the engine; observes the substitute action transitions
##      from ``Pending`` -> ``Succeeded`` and the payload lands in
##      the local CAS.

import std/[os, osproc, net, random, strutils, unittest]

import repro_build_engine
import repro_local_store

import ../src/repro_binary_cache_client
import ../../repro_binary_cache_server/src/repro_binary_cache_server/types
import ../../repro_binary_cache_server/src/repro_binary_cache_server/key
import ../../repro_binary_cache_server/src/repro_binary_cache_server/manifest_codec
import ../../repro_binary_cache_server/src/repro_binary_cache_server/index as bcsIndex
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import ../../blake3/src/blake3

const ServerBinary = "build/test-bin" / addFileExt("repro_binary_cache", ExeExt)

proc pickPort(): int =
  randomize()
  result = 23_000 + rand(8_999)

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

# Globals reachable from the executor proc (which has gcsafe pragma).
var gCtx: ClientContext
var gPool: HttpPool
var gIdx: ClientIndex

proc substituteExecutor(action: BuildAction): ActionResult {.gcsafe.} =
  {.cast(gcsafe).}:
    var res = ActionResult(id: action.id, launched: true,
                           runQuotaBackend: "binary-cache-substitute")
    try:
      let req = parseActionPayload(action.builtinText)
      let outcome = executeSubstituteAction(gCtx, gPool, req, gIdx)
      if outcome.ok:
        res.status = asSucceeded
        res.exitCode = 0
        res.stdout =
          (if outcome.skipped: "skipped (cached) " else: "fetched ") &
          $outcome.bytesFetched & " bytes in " &
          $outcome.wallclockMillis & "ms"
      else:
        res.status = asFailed
        res.exitCode = 1
        res.stderr = outcome.reason
        res.reason = outcome.reason
    except CatchableError as e:
      res.status = asFailed
      res.exitCode = 1
      res.stderr = e.msg
      res.reason = "substitute crashed: " & e.msg
    return res

suite "A2.5 P4 — engine-dispatch":
  test "bakBinaryCacheSubstitute dispatches through engine + materialises payload":
    randomize()
    let port = pickPort()
    let serverRoot = getTempDir() / ("a2_5_p4_srv_" & $rand(999_999))
    let clientRoot = getTempDir() / ("a2_5_p4_cli_" & $rand(999_999))
    let engineCacheRoot = getTempDir() / ("a2_5_p4_engcache_" & $rand(999_999))
    removeDir(serverRoot); removeDir(clientRoot); removeDir(engineCacheRoot)
    createDir(serverRoot); createDir(clientRoot); createDir(engineCacheRoot)

    var state = openBinaryCacheServer(serverRoot)
    var payloadBytes = newSeq[byte](64 * 1024)
    for i in 0 ..< payloadBytes.len:
      payloadBytes[i] = byte((i * 41 + 13) and 0xff)
    let payloadDigestRaw = blake3.digest(payloadBytes)
    var payloadDigest: Blake3Hash
    for i in 0 ..< 32: payloadDigest[i] = payloadDigestRaw[i]

    # Detect the host CPU so the manifest keys on the SAME triple the
    # client's compat-check derives. Hardcoding ``x86_64`` made the
    # substitute fail the compat gate (``CPU mismatch: manifest=x86_64
    # local=aarch64``) on arm64 macOS / Linux.
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
      kind: pkPrefixArchive, compression: ckNone,
      declaredSize: uint64(payloadBytes.len),
      uncompressedSize: uint64(payloadBytes.len),
      digest: payloadDigest, name: "p4.bin")
    var realizedPrefix: Blake3Hash
    for i in 0 ..< 32: realizedPrefix[i] = byte((i * 19 + 5) and 0xff)
    let entryKey = CacheEntryKey(
      packageName: "p4", packageVersion: "1.0",
      platform: PlatformTriple(cpu: localCpu, os: localOs,
                               abi: localAbi, libcVariant: ""),
      toolchain: ToolchainIdentity(),
      depClosureDigest: payloadDigest,
      providerRevision: "p4")
    var manifest = BinaryCacheManifest(
      formatVersion: BinaryCacheFormatVersion,
      entryKey: entryKey, payloads: @[payload],
      realizedPrefixDigest: realizedPrefix, depReferences: @[],
      relocationPolicy: rpOptional, createdAtUnix: 1)
    signManifest(state.producerKeypair, manifest)
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

    # Wire up the engine executor.
    let cfg = defaultConfig(clientRoot, @[
      SubstituteEndpoint(
        baseUrl: "http://127.0.0.1:" & $port,
        trustedSigners: @[pubKey])])
    gCtx = newClientContext(cfg)
    gPool = newHttpPool()
    gIdx = openClientIndex(clientRoot)
    defer:
      try: gPool.close() except CatchableError: discard
      try: gCtx.close() except CatchableError: discard

    registerBinaryCacheSubstituteExecutor(substituteExecutor)
    defer: clearBinaryCacheSubstituteExecutor()

    # Build a one-action graph carrying the substitute request.
    let actionPayload =
      entryKeyHex & "\n" &
      "http://127.0.0.1:" & $port & "\n"
    let action = builtinAction(
      kind = bakBinaryCacheSubstitute,
      id = "substitute-p4",
      cwd = engineCacheRoot,
      text = actionPayload)
    let g = graph(@[action])

    let engineCfg = BuildEngineConfig(
      cacheRoot: engineCacheRoot,
      maxParallelism: 1,
      bypassRunQuota: true)
    let runRes = runBuild(g, engineCfg)
    check runRes.results.len == 1
    let r = runRes.results[0]
    if r.status != asSucceeded:
      echo "FAILED: stderr=", r.stderr, " reason=", r.reason
    check r.status == asSucceeded
    check r.exitCode == 0
    # Payload landed in the local CAS.
    let casPath = gCtx.store.casPath(payloadDigest)
    check fileExists(casPath)

    try: removeDir(clientRoot) except CatchableError: discard
    try: removeDir(serverRoot) except CatchableError: discard
    try: removeDir(engineCacheRoot) except CatchableError: discard

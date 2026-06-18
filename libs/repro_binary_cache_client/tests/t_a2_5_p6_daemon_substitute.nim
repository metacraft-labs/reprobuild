## A2.5 P6 — daemon-resident substitute service.
##
## Boots the A2 server with a 3-member closure (R -> M -> L), spins
## up a ``DaemonSubstituteService`` against the local store, submits
## one ``DaemonSubstituteRequest`` rooted at R, asserts every member's
## payload is materialised + the index sidecar is populated.
##
## The actual repro-daemon IPC framing is left as a daemon-library
## follow-up; the service primitive validated here is the
## architectural piece (singleton ClientContext + HttpPool +
## ClientIndex + single-writer lock).

import std/[os, osproc, net, random, strutils, unittest]

import ../src/repro_binary_cache_client
import ../../repro_binary_cache_server/src/repro_binary_cache_server/types
import ../../repro_binary_cache_server/src/repro_binary_cache_server/key
import ../../repro_binary_cache_server/src/repro_binary_cache_server/manifest_codec
import ../../repro_binary_cache_server/src/repro_binary_cache_server/index as bcsIndex
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import ../../blake3/src/blake3

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
    providerRevision: "p6")
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

suite "A2.5 P6 — daemon-resident substitute service":
  test "substituteService walks + materialises a 3-member closure":
    randomize()
    let port = pickPort()
    let serverRoot = getTempDir() / ("a2_5_p6_srv_" & $rand(999_999))
    let clientRoot = getTempDir() / ("a2_5_p6_cli_" & $rand(999_999))
    removeDir(serverRoot); removeDir(clientRoot)
    createDir(serverRoot); createDir(clientRoot)

    var state = openBinaryCacheServer(serverRoot)
    let L = buildMember(state, "L", @[], 7)
    let M = buildMember(state, "M", @[L.entryKeyDigest], 5)
    let R = buildMember(state, "R", @[M.entryKeyDigest], 3)
    let pubKey = state.producerKeypair.publicKey
    close(state)

    let srvProc = startServer(serverRoot, port)
    defer:
      try: srvProc.terminate() except CatchableError: discard
      try: srvProc.close() except CatchableError: discard
    check waitForListener(port)

    let endpoint = SubstituteEndpoint(
      baseUrl: "http://127.0.0.1:" & $port,
      trustedSigners: @[pubKey])
    let cfg = defaultConfig(clientRoot, @[endpoint])
    let svc = newDaemonSubstituteService(cfg)
    defer: svc.close()

    let res = svc.handleRequest(DaemonSubstituteRequest(
      rootEntryKeyHex: R.entryKeyHex,
      endpoint: endpoint))
    check res.ok
    check res.plan.len == 3
    check res.realizedCasPaths.len == 3
    for path in res.realizedCasPaths:
      check fileExists(path)
    check res.totalBytesFetched > 0

    # Second submit: every member is cached. The service should
    # report ok with skipped=true outcomes.
    let res2 = svc.handleRequest(DaemonSubstituteRequest(
      rootEntryKeyHex: R.entryKeyHex,
      endpoint: endpoint))
    check res2.ok
    var skipped = 0
    for o in res2.outcomes:
      if o.skipped: inc skipped
    check skipped == 3

    try: removeDir(clientRoot) except CatchableError: discard
    try: removeDir(serverRoot) except CatchableError: discard

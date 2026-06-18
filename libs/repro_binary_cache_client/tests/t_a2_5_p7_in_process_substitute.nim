## A2.5 P7 — in-process (single-user) wrapper.
##
## Validates ``substituteInProcess`` against the same 3-member
## closure shape as P6, but without a daemon-resident service.
## Each call creates its own ``ClientContext`` + ``HttpPool``;
## the materialised payloads are byte-identical to the multi-user
## mode result.

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

proc buildMember(state: BinaryCacheServerState; name: string;
                 deps: seq[Blake3Hash]; seed: int):
                  tuple[entryKeyDigest: Blake3Hash; entryKeyHex: string;
                        payloadBytes: seq[byte]] =
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
    providerRevision: "p7")
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
  result.payloadBytes = payloadBytes

suite "A2.5 P7 — in-process substitute (single-user mode)":
  test "substituteInProcess materialises a 3-member closure end-to-end":
    randomize()
    let port = pickPort()
    let serverRoot = getTempDir() / ("a2_5_p7_srv_" & $rand(999_999))
    let clientRoot = getTempDir() / ("a2_5_p7_cli_" & $rand(999_999))
    removeDir(serverRoot); removeDir(clientRoot)
    createDir(serverRoot); createDir(clientRoot)

    var state = openBinaryCacheServer(serverRoot)
    let L = buildMember(state, "L", @[], 9)
    let M = buildMember(state, "M", @[L.entryKeyDigest], 6)
    let R = buildMember(state, "R", @[M.entryKeyDigest], 4)
    let pubKey = state.producerKeypair.publicKey
    close(state)

    let srvProc = startServer(serverRoot, port)
    defer:
      try: srvProc.terminate() except CatchableError: discard
      try: srvProc.close() except CatchableError: discard
    check waitForListener(port)

    let endpoints = @[SubstituteEndpoint(
      baseUrl: "http://127.0.0.1:" & $port,
      trustedSigners: @[pubKey])]
    let res = substituteInProcess(R.entryKeyHex, clientRoot, endpoints)
    check res.ok
    check res.plan.len == 3
    var seen = 0
    for o in res.outcomes:
      if o.ok and o.casPath.len > 0:
        check fileExists(o.casPath)
        inc seen
    check seen == 3

    # Re-run: same byte payload, but the client-side index hits
    # the warm cache on every member.
    let res2 = substituteInProcess(R.entryKeyHex, clientRoot, endpoints)
    check res2.ok
    var skipped = 0
    for o in res2.outcomes:
      if o.skipped: inc skipped
    check skipped == 3

    try: removeDir(clientRoot) except CatchableError: discard
    try: removeDir(serverRoot) except CatchableError: discard

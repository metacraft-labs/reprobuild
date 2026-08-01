## Reprobuild-Binary-Cache-Fleet R1 — client-side trust + config gate.
##
## Proves the default-untrusted substitution model end-to-end against a
## REAL ``repro_binary_cache`` server (the same one A2.5 P7 boots):
##
##   1. UNTRUSTED-KEY REJECT — a manifest that is validly SIGNED but by
##      a producer key NOT in the cache's ``trusted-public-keys`` is
##      rejected: ``substituteInProcess`` returns ``ok == false`` and
##      NOTHING is materialised. (Load-bearing gate.)
##   2. TRUSTED-KEY ACCEPT — the SAME manifest, with the signing key
##      added to the config, substitutes + materialises.
##   3. NO-TRUST-ENTRY MISS — a cache whose config lists NO trusted key
##      (``enforceTrust`` on, empty list) yields a miss even though the
##      server serves a valid, signed manifest.
##   4. MULTI-CACHE PRIORITY + FALLBACK — two caches; the higher-
##      priority one rejects on trust (untrusted key) and the walk
##      falls through to the lower-priority TRUSTED cache; the first
##      TRUSTED hit wins.
##
## Non-vacuity: test 1 (and the fallback leg of test 4) FAIL if the
## trust check is removed — without it the validly-signed-but-untrusted
## manifest would materialise. The pre-R1 code (empty ``trustedSigners``
## == trust-anything) fails test 1 and test 3.
##
## The config parser is exercised separately in
## ``t_r1_caches_config.nim`` (pure, no server).

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
  let local = detectLocalPlatform("")
  PlatformTriple(cpu: local.cpu, os: local.os, abi: local.abi,
                 libcVariant: local.libcVariant)

proc publishMember(state: BinaryCacheServerState;
                   kp: peerAuth.PeerKeypair;
                   name: string; seed: int):
                    tuple[entryKeyHex: string; payloadBytes: seq[byte]] =
  ## Builds + SIGNS a single-payload manifest with the supplied keypair
  ## and stores it (manifest + payload) into the server. ``storeManifest``
  ## does NOT re-verify, so we can plant a manifest signed by ANY key —
  ## exactly what a compromised / untrusted cache would serve.
  var payloadBytes = newSeq[byte](1024 + seed)
  for i in 0 ..< payloadBytes.len:
    payloadBytes[i] = byte((i * (seed + 3) + seed) and 0xff)
  let pdRaw = blake3.digest(payloadBytes)
  var pd: Blake3Hash
  for i in 0 ..< 32: pd[i] = pdRaw[i]
  var rp: Blake3Hash
  for i in 0 ..< 32: rp[i] = byte((i * 23 + seed) and 0xff)
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
    providerRevision: "r1")
  var m = BinaryCacheManifest(
    formatVersion: BinaryCacheFormatVersion,
    entryKey: ek, payloads: @[payload],
    realizedPrefixDigest: rp, depReferences: @[],
    relocationPolicy: rpOptional, createdAtUnix: 1)
  signManifest(kp, m)
  discard storeManifest(state, m)
  discard storePayload(state, payloadBytes)
  result.entryKeyHex = cacheEntryKeyHex(m.entryKey)
  result.payloadBytes = payloadBytes

proc anyMaterialised(res: InProcessOutcome): bool =
  for o in res.outcomes:
    if o.ok and o.casPath.len > 0 and fileExists(o.casPath):
      return true
  return false

suite "R1 — client trust + default-untrusted substitution":

  test "untrusted signing key is REJECTED; trusted key is ACCEPTED":
    randomize()
    let port = pickPort()
    let serverRoot = getTempDir() / ("r1_srv_" & $rand(999_999))
    let clientRoot = getTempDir() / ("r1_cli_" & $rand(999_999))
    removeDir(serverRoot); removeDir(clientRoot)
    createDir(serverRoot); createDir(clientRoot)

    var state = openBinaryCacheServer(serverRoot)
    # A SECOND, independent keypair — the "attacker" / untrusted signer.
    let attacker = peerAuth.generateKeypair()
    let entry = publishMember(state, attacker, "pkg", 5)
    let attackerPub = attacker.publicKey
    close(state)

    let srvProc = startServer(serverRoot, port)
    defer:
      try: srvProc.terminate() except CatchableError: discard
      try: srvProc.close() except CatchableError: discard
    check waitForListener(port)
    let url = "http://127.0.0.1:" & $port

    # --- Leg A: cache trusts a DIFFERENT key => the attacker-signed
    # manifest is rejected; nothing materialises.
    let otherKey = peerAuth.generateKeypair().publicKey
    let rejectEndpoints = @[SubstituteEndpoint(
      baseUrl: url, trustedSigners: @[otherKey],
      priority: 10, enforceTrust: true)]
    let rejectRes = substituteInProcess(entry.entryKeyHex, clientRoot,
                                        rejectEndpoints)
    check (not rejectRes.ok)
    check (not anyMaterialised(rejectRes))

    # --- Leg B: same server, now the cache trusts the SIGNING key.
    let acceptEndpoints = @[SubstituteEndpoint(
      baseUrl: url, trustedSigners: @[attackerPub],
      priority: 10, enforceTrust: true)]
    let acceptRes = substituteInProcess(entry.entryKeyHex, clientRoot,
                                        acceptEndpoints)
    check acceptRes.ok
    check anyMaterialised(acceptRes)

    try: removeDir(clientRoot) except CatchableError: discard
    try: removeDir(serverRoot) except CatchableError: discard

  test "cache with NO trusted-public-keys yields a MISS (default-untrusted)":
    randomize()
    let port = pickPort()
    let serverRoot = getTempDir() / ("r1_srv2_" & $rand(999_999))
    let clientRoot = getTempDir() / ("r1_cli2_" & $rand(999_999))
    removeDir(serverRoot); removeDir(clientRoot)
    createDir(serverRoot); createDir(clientRoot)

    var state = openBinaryCacheServer(serverRoot)
    # Sign with the SERVER's own (valid) producer key — a wholly
    # legitimate, signature-verifying manifest.
    let entry = publishMember(state, state.producerKeypair, "pkg", 7)
    close(state)

    let srvProc = startServer(serverRoot, port)
    defer:
      try: srvProc.terminate() except CatchableError: discard
      try: srvProc.close() except CatchableError: discard
    check waitForListener(port)
    let url = "http://127.0.0.1:" & $port

    # No trusted keys, enforceTrust on => never substituted from even
    # though the manifest is valid + signature-verifies.
    let endpoints = @[SubstituteEndpoint(
      baseUrl: url, trustedSigners: @[],
      priority: 10, enforceTrust: true)]
    let res = substituteInProcess(entry.entryKeyHex, clientRoot, endpoints)
    check (not res.ok)
    check (not anyMaterialised(res))

    try: removeDir(clientRoot) except CatchableError: discard
    try: removeDir(serverRoot) except CatchableError: discard

  test "multi-cache: untrusted high-priority falls through to trusted lower-priority":
    randomize()
    let portA = pickPort()
    var portB = pickPort()
    while portB == portA: portB = pickPort()
    let srvRootA = getTempDir() / ("r1_srvA_" & $rand(999_999))
    let srvRootB = getTempDir() / ("r1_srvB_" & $rand(999_999))
    let clientRoot = getTempDir() / ("r1_cliM_" & $rand(999_999))
    for d in [srvRootA, srvRootB, clientRoot]:
      removeDir(d); createDir(d)

    # Both servers serve a manifest for the SAME entry key (same
    # identity => same hex) but signed by different keys. Cache A
    # (higher priority = lower number) is signed by an UNTRUSTED key;
    # cache B (lower priority) is signed by a key we DO trust.
    let attacker = peerAuth.generateKeypair()
    let good = peerAuth.generateKeypair()

    var stateA = openBinaryCacheServer(srvRootA)
    let entryA = publishMember(stateA, attacker, "pkg", 11)
    close(stateA)
    var stateB = openBinaryCacheServer(srvRootB)
    let entryB = publishMember(stateB, good, "pkg", 11)
    close(stateB)
    check entryA.entryKeyHex == entryB.entryKeyHex  # identity => same key

    let goodPub = good.publicKey

    let procA = startServer(srvRootA, portA)
    let procB = startServer(srvRootB, portB)
    defer:
      for p in [procA, procB]:
        try: p.terminate() except CatchableError: discard
        try: p.close() except CatchableError: discard
    check waitForListener(portA)
    check waitForListener(portB)

    # Priority: A=10 (tried first) trusts only ``good`` but SERVES an
    # attacker-signed manifest => trust reject => fall through to
    # B=20 which serves a good-signed manifest and trusts ``good``.
    let endpoints = @[
      SubstituteEndpoint(baseUrl: "http://127.0.0.1:" & $portA,
                         trustedSigners: @[goodPub],
                         priority: 10, enforceTrust: true),
      SubstituteEndpoint(baseUrl: "http://127.0.0.1:" & $portB,
                         trustedSigners: @[goodPub],
                         priority: 20, enforceTrust: true)]
    let res = substituteInProcess(entryA.entryKeyHex, clientRoot, endpoints)
    check res.ok
    check anyMaterialised(res)

    for d in [srvRootA, srvRootB, clientRoot]:
      try: removeDir(d) except CatchableError: discard

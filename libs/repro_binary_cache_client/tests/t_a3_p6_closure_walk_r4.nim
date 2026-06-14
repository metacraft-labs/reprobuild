## ReproOS-Generations-And-Foreign-Packages A3 P6 — closure-aware substitute gate.
##
## Builds a 5-member R4-shaped closure (hex0 → stage0-posix → mescc-tools
## → mes → tcc) via direct ``CacheEntryIdentity`` + manifest publish.
## Verifies that ``substituteInProcess`` walks the closure correctly:
##
##   * Plan length == 5.
##   * Plan visits in topological order: hex0 first, tcc last.
##   * Every outcome.ok == true.
##   * Every realised CAS path exists on disk.
##
## This complements the bash integration tests (``t_a3_substitute_hit_r4_chain.sh``)
## which exercise the same shape via the CLI.

import std/[os, osproc, net, random, strutils, tables, times, unittest]

import ../src/repro_binary_cache_client
import ../../repro_binary_cache_server/src/repro_binary_cache_server
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import ../../blake3/src/blake3

const ServerBinary = "build/test-bin/repro_binary_cache.exe"

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
  let local = detectLocalPlatform("")
  PlatformTriple(cpu: local.cpu, os: local.os, abi: local.abi,
                 libcVariant: "")

proc publishMember(state: BinaryCacheServerState;
                   packageName, packageVersion: string;
                   deps: seq[Blake3Hash]; seed: int):
    tuple[digest: Blake3Hash; hex: string] =
  ## Constructs + signs + persists a single-payload manifest. Returns
  ## the entry-key digest + hex so the next member can carry it as a
  ## dep reference.
  let plat = localPlatform()
  var idy = newCacheEntryIdentity(
    packageName = packageName, packageVersion = packageVersion,
    platform = plat,
    toolchain = ToolchainIdentity(name: "stub", version: "1",
                                  hostLdSoAbi: "", extraFingerprint: ""),
    providerRevision = "a3-p6-rev-" & packageName)
  idy.addOption("seed", $seed)
  let entryKey = deriveCacheEntryKey(idy)
  # Build a deterministic payload.
  var payloadBytes = newSeq[byte](256 + seed * 7)
  for i in 0 ..< payloadBytes.len:
    payloadBytes[i] = byte((i * (seed + 1) + seed) and 0xff)
  let rawDigest = blake3.digest(payloadBytes)
  var payloadDigest: Blake3Hash
  for i in 0 ..< 32: payloadDigest[i] = rawDigest[i]
  let payloadObj = PayloadObject(
    kind: pkPrefixArchive, compression: ckNone,
    declaredSize: uint64(payloadBytes.len),
    uncompressedSize: uint64(payloadBytes.len),
    digest: payloadDigest, name: packageName & ".bin")
  var manifest = BinaryCacheManifest(
    formatVersion: BinaryCacheFormatVersion,
    entryKey: entryKey,
    payloads: @[payloadObj],
    realizedPrefixDigest: payloadDigest,
    depReferences: deps,
    relocationPolicy: rpOptional,
    createdAtUnix: 1_750_000_000'i64 + seed)
  signManifest(state.producerKeypair, manifest)
  discard storeManifest(state, manifest)
  discard storePayload(state, payloadBytes)
  result.digest = cacheEntryKeyDigest(entryKey)
  result.hex = cacheEntryKeyHex(entryKey)

suite "A3 P6 — closure-aware substitute walks the R4 chain":

  test "publish 5-member closure, substitute walks topologically":
    randomize()
    let port = pickPort()
    let serverRoot = getTempDir() / ("a3_p6_srv_" & $rand(999_999))
    let clientRoot = getTempDir() / ("a3_p6_cli_" & $rand(999_999))
    removeDir(serverRoot); removeDir(clientRoot)
    createDir(serverRoot); createDir(clientRoot)
    defer:
      try: removeDir(serverRoot) except CatchableError: discard
      try: removeDir(clientRoot) except CatchableError: discard

    var state = openBinaryCacheServer(serverRoot)
    let hex0 = publishMember(state, "hex0", "stage0-posix-r1.9", @[], 1)
    let stage0 = publishMember(state, "stage0-posix", "r1.9",
                               @[hex0.digest], 3)
    let mescc = publishMember(state, "mescc-tools", "r1.9",
                              @[stage0.digest], 5)
    let mes = publishMember(state, "mes", "0.27.1", @[mescc.digest], 7)
    let tcc = publishMember(state, "tinycc-bootstrappable", "ea3900f6",
                            @[mes.digest, mescc.digest], 11)
    let pubKey = state.producerKeypair.publicKey
    close(state)

    let srvProc = startServer(serverRoot, port)
    defer:
      try: srvProc.terminate() except CatchableError: discard
      try: srvProc.close() except CatchableError: discard
    if not waitForListener(port):
      fail()

    let endpoints = @[SubstituteEndpoint(
      baseUrl: "http://127.0.0.1:" & $port,
      trustedSigners: @[pubKey],
      priority: 0)]
    let res = substituteInProcess(tcc.hex, clientRoot, endpoints)
    if not res.ok:
      echo "substitute failed: ", res.reason
    check res.ok
    check res.plan.len == 5

    # Confirm topological order: hex0 first, tcc last; intermediates in
    # dep order (each plan entry's manifest only references entries
    # already emitted).
    var emitted: seq[string] = @[]
    for step in res.plan:
      let manifest = step.manifest
      for dep in manifest.depReferences:
        let depHex = digestToHex(dep)
        check depHex in emitted
      emitted.add(step.entryKeyHex)

    check emitted[0] == hex0.hex
    check emitted[^1] == tcc.hex

    # Every outcome materialised a CAS blob on disk.
    var realised = 0
    for outcome in res.outcomes:
      check outcome.ok
      if outcome.casPath.len > 0 and fileExists(outcome.casPath):
        inc realised
    check realised == 5

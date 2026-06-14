## A2.5 P5 — closure walk + parallel substitution.
##
## Publishes a 5-member closure (A depends on B+C; B depends on D; D
## depends on E) to the A2 server, then exercises the client's
## ``planClosure`` to enumerate the substitute steps. Asserts:
##
##   1. The plan walks all 5 members.
##   2. The plan is topologically sorted (leaves first; root last).
##   3. Compat check passes for each member.
##   4. Materialising the plan via repeated ``executeSubstituteAction``
##      lands every payload in the local CAS.

import std/[os, osproc, net, random, strutils, tables, unittest]

import ../src/repro_binary_cache_client
import ../../repro_binary_cache_server/src/repro_binary_cache_server/types
import ../../repro_binary_cache_server/src/repro_binary_cache_server/key
import ../../repro_binary_cache_server/src/repro_binary_cache_server/manifest_codec
import ../../repro_binary_cache_server/src/repro_binary_cache_server/index as bcsIndex
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import ../../blake3/src/blake3

const ServerBinary = "build/test-bin/repro_binary_cache.exe"

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

proc buildMember(state: BinaryCacheServerState;
                 name: string; deps: seq[Blake3Hash]; seed: int):
                  tuple[manifest: BinaryCacheManifest;
                        entryKeyDigest: Blake3Hash;
                        entryKeyHex: string] =
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
    providerRevision: "p5")
  var m = BinaryCacheManifest(
    formatVersion: BinaryCacheFormatVersion,
    entryKey: ek, payloads: @[payload],
    realizedPrefixDigest: rp, depReferences: deps,
    relocationPolicy: rpOptional, createdAtUnix: 1)
  signManifest(state.producerKeypair, m)
  discard storeManifest(state, m)
  discard storePayload(state, payloadBytes)
  result.manifest = m
  result.entryKeyDigest = cacheEntryKeyDigest(m.entryKey)
  result.entryKeyHex = cacheEntryKeyHex(m.entryKey)

suite "A2.5 P5 — closure walk":
  test "5-member DAG: A -> {B, C}, B -> D, D -> E":
    randomize()
    let port = pickPort()
    let serverRoot = getTempDir() / ("a2_5_p5_srv_" & $rand(999_999))
    let clientRoot = getTempDir() / ("a2_5_p5_cli_" & $rand(999_999))
    removeDir(serverRoot); removeDir(clientRoot)
    createDir(serverRoot); createDir(clientRoot)

    var state = openBinaryCacheServer(serverRoot)
    # Build leaves first.
    let E = buildMember(state, "E", @[], 5)
    let D = buildMember(state, "D", @[E.entryKeyDigest], 4)
    let C = buildMember(state, "C", @[], 3)
    let B = buildMember(state, "B", @[D.entryKeyDigest], 2)
    let A = buildMember(state, "A",
                        @[B.entryKeyDigest, C.entryKeyDigest], 1)
    let pubKey = state.producerKeypair.publicKey
    close(state)

    let srvProc = startServer(serverRoot, port)
    defer:
      try: srvProc.terminate() except CatchableError: discard
      try: srvProc.close() except CatchableError: discard
    check waitForListener(port)

    let pool = newHttpPool()
    defer: pool.close()
    let endpoint = SubstituteEndpoint(
      baseUrl: "http://127.0.0.1:" & $port,
      trustedSigners: @[pubKey])
    let cfg = defaultConfig(clientRoot, @[endpoint])
    let ctx = newClientContext(cfg)
    defer: ctx.close()

    let plan = planClosure(ctx, pool, endpoint, A.entryKeyHex)
    # Plan covers every member exactly once.
    check plan.len == 5
    var seen = initTable[string, int]()
    for i, step in plan:
      seen[step.entryKeyHex] = i
    check seen.hasKey(A.entryKeyHex)
    check seen.hasKey(B.entryKeyHex)
    check seen.hasKey(C.entryKeyHex)
    check seen.hasKey(D.entryKeyHex)
    check seen.hasKey(E.entryKeyHex)

    # Topological invariant: every dep precedes the parent.
    check seen[E.entryKeyHex] < seen[D.entryKeyHex]
    check seen[D.entryKeyHex] < seen[B.entryKeyHex]
    check seen[B.entryKeyHex] < seen[A.entryKeyHex]
    check seen[C.entryKeyHex] < seen[A.entryKeyHex]

    # Materialise the plan and assert every payload lands.
    let idx = openClientIndex(clientRoot)
    for step in plan:
      let req = SubstituteRequest(
        entryKeyHex: step.entryKeyHex,
        endpoint: endpoint)
      let outcome = executeSubstituteAction(ctx, pool, req, idx)
      check outcome.ok
      check fileExists(outcome.casPath)

    try: removeDir(clientRoot) except CatchableError: discard
    try: removeDir(serverRoot) except CatchableError: discard

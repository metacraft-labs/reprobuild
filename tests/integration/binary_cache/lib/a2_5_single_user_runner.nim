## a2_5_single_user_runner — driver for ``t_a2_5_single_user_mode.sh``.
##
## Spins up the A2 cache server, then ``substituteInProcess``-es the
## same synthetic 3-member closure the concurrent-clients gate uses,
## and reports wall-clock + total bytes. The bash wrapper just needs a
## clean exit code.

import std/[os, osproc, net, random, strutils, times]

import ../../../../libs/repro_binary_cache_client/src/repro_binary_cache_client

import ../../../../libs/repro_binary_cache_server/src/repro_binary_cache_server/types
import ../../../../libs/repro_binary_cache_server/src/repro_binary_cache_server/key
import ../../../../libs/repro_binary_cache_server/src/repro_binary_cache_server/manifest_codec
import ../../../../libs/repro_binary_cache_server/src/repro_binary_cache_server/index as bcsIndex
import ../../../../libs/repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import ../../../../libs/blake3/src/blake3

const ServerBinary = "build/test-bin/repro_binary_cache.exe"

proc fail(msg: string) {.noreturn.} =
  stderr.writeLine("FAIL: a2_5_single_user_runner: " & msg)
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
    providerRevision: "a2_5_su")
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

proc main() =
  randomize()
  let port = pickPort()
  let serverRoot = getTempDir() / ("a2_5_su_srv_" & $rand(999_999))
  let clientRoot = getTempDir() / ("a2_5_su_cli_" & $rand(999_999))
  removeDir(serverRoot); removeDir(clientRoot)
  createDir(serverRoot); createDir(clientRoot)

  var state = openBinaryCacheServer(serverRoot)
  let L = buildMember(state, "L", @[], 41)
  let M = buildMember(state, "M", @[L.entryKeyDigest], 43)
  let R = buildMember(state, "R", @[M.entryKeyDigest], 47)
  let pubKey = state.producerKeypair.publicKey
  close(state)

  let srvProc = startServer(serverRoot, port)
  defer:
    try: srvProc.terminate() except CatchableError: discard
    try: srvProc.close() except CatchableError: discard
  if not waitForListener(port):
    fail("A2 server failed to bind on 127.0.0.1:" & $port)

  let endpoints = @[SubstituteEndpoint(
    baseUrl: "http://127.0.0.1:" & $port,
    trustedSigners: @[pubKey])]
  let startMs = epochTime() * 1000.0
  let res = substituteInProcess(R.entryKeyHex, clientRoot, endpoints)
  let endMs = epochTime() * 1000.0

  if not res.ok:
    fail("substituteInProcess reported not-ok: " & res.reason)
  if res.plan.len != 3:
    fail("expected plan of 3 members, got " & $res.plan.len)
  var totalBytes = 0'i64
  var realized = 0
  for o in res.outcomes:
    if o.ok and o.casPath.len > 0:
      if not fileExists(o.casPath):
        fail("realized CAS path missing on disk: " & o.casPath)
      inc realized
      totalBytes += o.bytesFetched
  if realized != 3:
    fail("expected 3 realized members, got " & $realized)

  echo "a2_5_single_user_runner: 3 members realized in ",
    (endMs - startMs).int, " ms, total bytes fetched=", totalBytes

  try: removeDir(clientRoot) except CatchableError: discard
  try: removeDir(serverRoot) except CatchableError: discard

when isMainModule:
  main()

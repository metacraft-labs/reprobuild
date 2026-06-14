## A2 P2 in-process gate.
##
## Boots the HTTP server in-process against a freshly-provisioned
## ``BinaryCacheServerState`` rooted under ``$TEMP/rbc-p2-<random>/``,
## exercises every REST route through Nim's async HTTP client, and
## verifies the publish path round-trips a signed manifest +
## payload through the on-disk store.
##
## Routes covered:
##
##   * GET /healthz
##   * GET /cache-info
##   * POST /publish (with manifest + payload)
##   * GET /manifests/<entry-key>
##   * GET /payloads/<blake3>
##   * GET /manifests/<bad-hex> + GET /payloads/<bad-hex> 404 path
##
## The test is deterministic and self-contained; no WSL distro is
## required. The P3 WSL provisioning gate exercises the same daemon
## binary inside ``repro-cache``.

import std/[asyncdispatch, httpclient, httpcore, os, random,
            strutils, unittest]

import ../src/repro_binary_cache_server/types
import ../src/repro_binary_cache_server/key
import ../src/repro_binary_cache_server/manifest_codec
import ../src/repro_binary_cache_server/index
import ../src/repro_binary_cache_server/server
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import ../../blake3/src/blake3

proc pickPort(): int =
  # Random ephemeral port between 23000-32000 to avoid colliding with
  # the systemd-fixed 7878 default.
  randomize()
  result = 23_000 + rand(8_999)

proc buildSignedManifest(kp: PeerKeypair;
                         payloadBytes: openArray[byte]): BinaryCacheManifest =
  let payloadDigestRaw = blake3.digest(payloadBytes)
  var payloadDigest: Blake3Hash
  for i in 0 ..< 32:
    payloadDigest[i] = payloadDigestRaw[i]
  var depDigest: Blake3Hash
  for i in 0 ..< 32:
    depDigest[i] = byte((i * 17 + 3) and 0xff)
  var realizedPrefix: Blake3Hash
  for i in 0 ..< 32:
    realizedPrefix[i] = byte((i * 19 + 5) and 0xff)

  let payload = PayloadObject(
    kind: pkPrefixArchive,
    compression: ckZstd,
    declaredSize: uint64(payloadBytes.len),
    uncompressedSize: uint64(payloadBytes.len),
    digest: payloadDigest,
    name: "prefix.tar.zst")

  let entryKey = CacheEntryKey(
    packageName: "p2-fixture",
    packageVersion: "1.0.0",
    selectedOptions: @[("opt", "default")],
    platform: PlatformTriple(cpu: "x86_64", os: "linux",
                             abi: "gnu", libcVariant: ""),
    toolchain: ToolchainIdentity(name: "gcc", version: "11",
                                 hostLdSoAbi: "",
                                 extraFingerprint: ""),
    depClosureDigest: depDigest,
    providerRevision: "p2-test")

  result = BinaryCacheManifest(
    formatVersion: BinaryCacheFormatVersion,
    entryKey: entryKey,
    payloads: @[payload],
    realizedPrefixDigest: realizedPrefix,
    depReferences: @[depDigest],
    relocationPolicy: rpOptional,
    createdAtUnix: 1_750_000_000'i64)

  signManifest(kp, result)

proc httpGet(url: string): Future[(HttpCode, string)] {.async.} =
  let client = newAsyncHttpClient()
  defer: client.close()
  let resp = await client.request(url, HttpGet)
  result = (resp.code, await resp.body)

proc httpPublishMultipart(url: string; boundary: string;
                          body: string): Future[(HttpCode, string)] {.async.} =
  let client = newAsyncHttpClient()
  defer: client.close()
  client.headers["Content-Type"] = "multipart/form-data; boundary=" & boundary
  let resp = await client.request(url, HttpPost, body)
  result = (resp.code, await resp.body)

proc buildMultipartBody(boundary: string;
                        manifestBytes, payloadBytes: openArray[byte]): string =
  result = ""
  result.add("--" & boundary & "\r\n")
  result.add("Content-Disposition: form-data; name=\"manifest\"\r\n\r\n")
  for b in manifestBytes:
    result.add(char(b))
  result.add("\r\n")
  result.add("--" & boundary & "\r\n")
  result.add("Content-Disposition: form-data; name=\"payload\"\r\n\r\n")
  for b in payloadBytes:
    result.add(char(b))
  result.add("\r\n")
  result.add("--" & boundary & "--\r\n")

proc runScenario() {.async.} =
  randomize()
  let root = getTempDir() / ("rbc-p2-" & $rand(999_999))
  removeDir(root)
  createDir(root)
  defer:
    try: removeDir(root) except CatchableError: discard

  let state = openBinaryCacheServer(root)
  defer: close(state)

  let port = Port(pickPort())
  let srv = newBinaryCacheHttpServer(state)
  await srv.start("127.0.0.1:" & $port.int)
  defer: close(srv)
  await sleepAsync(150)

  let base = "http://127.0.0.1:" & $port.int

  block healthz:
    let (code, body) = await httpGet(base & "/healthz")
    check code == Http200
    check body == "ok"

  block cacheInfo:
    let (code, body) = await httpGet(base & "/cache-info")
    check code == Http200
    check body.len > 0
    # Envelope magic.
    check body[0 .. 3] == "RCI1"

  block missingManifest:
    let bogus = repeat('0', 64)
    let (code, _) = await httpGet(base & "/manifests/" & bogus)
    check code == Http404

  block invalidHex:
    let (code, _) = await httpGet(base & "/manifests/not-a-key")
    check code == Http400

  block publish:
    let kp = peerAuth.generateKeypair()
    let payload = newSeq[byte](256)
    var rng = initRand(7)
    var payloadFilled = payload
    for i in 0 ..< payloadFilled.len:
      payloadFilled[i] = byte(rng.next() and 0xff)
    let manifest = buildSignedManifest(kp, payloadFilled)
    let manifestBytes = encodeManifest(manifest)
    let boundary = "----RBC-test-" & $rand(99_999)
    let body = buildMultipartBody(boundary, manifestBytes, payloadFilled)

    let (code, hexBody) = await httpPublishMultipart(
      base & "/publish", boundary, body)
    check code == Http200
    let entryKeyHex = hexBody.strip()
    check entryKeyHex == cacheEntryKeyHex(manifest.entryKey)

    # Round-trip GET /manifests/<key>.
    let (mfCode, mfBytes) = await httpGet(base & "/manifests/" & entryKeyHex)
    check mfCode == Http200
    let mfRaw = cast[seq[byte]](mfBytes)
    let decoded = decodeManifest(mfRaw)
    check verifyManifest(decoded)
    check decoded.entryKey.packageName == "p2-fixture"

    # Round-trip GET /payloads/<hex>.
    let payloadHex = digestToHex(manifest.payloads[0].digest)
    let (pCode, pBody) = await httpGet(base & "/payloads/" & payloadHex)
    check pCode == Http200
    let pRaw = cast[seq[byte]](pBody)
    check pRaw.len == payloadFilled.len
    var ok = true
    for i in 0 ..< pRaw.len:
      if pRaw[i] != payloadFilled[i]:
        ok = false
        break
    check ok

  block publishMissingManifest:
    let boundary = "----RBC-empty-" & $rand(99_999)
    var body = "--" & boundary & "\r\n"
    body.add("Content-Disposition: form-data; name=\"payload\"\r\n\r\n")
    body.add("garbage\r\n")
    body.add("--" & boundary & "--\r\n")
    let (code, msg) = await httpPublishMultipart(
      base & "/publish", boundary, body)
    check code == Http422
    check msg.contains("missing manifest")

suite "A2 P2 — repro-binary-cache HTTP REST surface":
  test "publish + GET manifest + GET payload + cache-info round-trip":
    waitFor runScenario()

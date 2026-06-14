## A2 integration-test publish helper.
##
## Bash can build multipart bodies easily, but signing the manifest
## with the ephemeral test ECDSA-P256 key is painful in bash. This
## helper does it once per publish:
##
##   * Generates (or reuses, if --key-file points at one) an
##     ECDSA-P256 keypair via repro_peer_cache/auth.nim.
##   * Builds a single-payload BinaryCacheManifest with the supplied
##     identity tuple + optional dep reference.
##   * Signs it via manifest_codec.signManifest.
##   * POSTs a multipart/form-data body to the supplied --url, with
##     parts ``manifest`` + ``payload``.
##
## The helper echoes the cache-entry-key hex on stdout on success.
## Used by the bash integration scripts under tests/integration/binary_cache/.

import std/[httpclient, httpcore, os, parseopt, random, strutils]

import repro_binary_cache_server
import repro_peer_cache/auth as peerAuth
import blake3

type
  HelperOpts = object
    url: string
    package: string
    version: string
    payload: string
    depHex: string
    keyFile: string
    tamperManifest: bool
    producer: string
      ## Optional ``X-Repro-Producer`` header value. Used by the A4
      ## publish-auto-release leg; absent for A2 / A2.5 tests so the
      ## server's peer-addr fallback applies.
    expectStatus: int
      ## Phase A debt-closure hard-cap test: when non-zero, the helper
      ## treats this as the EXPECTED HTTP status from the server. A
      ## matching status exits 0 (instead of 3) and prints the
      ## response body on stdout; a mismatch exits 4 with a diag on
      ## stderr. Lets the bash integration tests probe negative
      ## paths (507, 422, etc.) without parsing curl's exit codes.

proc parseCli(): HelperOpts =
  result.url = ""
  result.payload = ""
  var p = initOptParser(commandLineParams())
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "url": result.url = p.val
      of "package": result.package = p.val
      of "version": result.version = p.val
      of "payload": result.payload = p.val
      of "dep": result.depHex = p.val
      of "key-file": result.keyFile = p.val
      of "tamper-manifest": result.tamperManifest = true
      of "producer": result.producer = p.val
      of "expect-status":
        try: result.expectStatus = parseInt(p.val)
        except ValueError: discard
      else: discard
    of cmdArgument: discard

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, ch in s:
    result[i] = byte(ch)

proc buildMultipart(boundary: string;
                    manifestBytes: openArray[byte];
                    payload: string): string =
  result = ""
  result.add("--" & boundary & "\r\n")
  result.add("Content-Disposition: form-data; name=\"manifest\"\r\n\r\n")
  for b in manifestBytes:
    result.add(char(b))
  result.add("\r\n")
  result.add("--" & boundary & "\r\n")
  result.add("Content-Disposition: form-data; name=\"payload\"\r\n\r\n")
  result.add(payload)
  result.add("\r\n")
  result.add("--" & boundary & "--\r\n")

proc main() =
  let opts = parseCli()
  if opts.url.len == 0 or opts.payload.len == 0:
    stderr.writeLine("a2_publish_helper: --url + --payload required")
    quit(2)

  let kp = peerAuth.generateKeypair()

  let payloadBytes = bytesOf(opts.payload)
  let rawDigest = blake3.digest(payloadBytes)
  var payloadDigest: Blake3Hash
  for i in 0 ..< 32:
    payloadDigest[i] = rawDigest[i]

  var depDigest: Blake3Hash
  if opts.depHex.len == 64:
    depDigest = hexToDigest(opts.depHex)
  else:
    for i in 0 ..< 32:
      depDigest[i] = 0'u8

  var realizedPrefix: Blake3Hash
  for i in 0 ..< 32:
    realizedPrefix[i] = byte((i * 23 + 11) and 0xff)

  let payload = PayloadObject(
    kind: pkPrefixArchive,
    compression: ckZstd,
    declaredSize: uint64(payloadBytes.len),
    uncompressedSize: uint64(payloadBytes.len),
    digest: payloadDigest,
    name: "prefix.tar.zst")

  var entryKey = CacheEntryKey(
    packageName: opts.package,
    packageVersion: opts.version,
    selectedOptions: @[],
    platform: PlatformTriple(cpu: "x86_64", os: "linux",
                             abi: "gnu", libcVariant: ""),
    toolchain: ToolchainIdentity(name: "gcc", version: "",
                                 hostLdSoAbi: "",
                                 extraFingerprint: ""),
    depClosureDigest: depDigest,
    providerRevision: "a2-itest")

  var depRefs: seq[Blake3Hash] = @[]
  if opts.depHex.len == 64:
    depRefs.add(depDigest)

  var manifest = BinaryCacheManifest(
    formatVersion: BinaryCacheFormatVersion,
    entryKey: entryKey,
    payloads: @[payload],
    realizedPrefixDigest: realizedPrefix,
    depReferences: depRefs,
    relocationPolicy: rpOptional,
    createdAtUnix: 1_750_000_000'i64)
  signManifest(kp, manifest)

  var manifestBytes = encodeManifest(manifest)
  if opts.tamperManifest:
    # Flip a single byte inside the realizedPrefixDigest region so
    # the signature stops verifying without touching the entry-key
    # sentinel (which would trip earlier at decode).
    # We pick the LAST byte of the realizedPrefix digest — it sits
    # comfortably between the payload list and the depReferences
    # list in the envelope.
    let prefixIdx = manifestBytes.len - peerAuth.P256PubLen -
                    peerAuth.P256SigLen - 8 - 1 - 4 - 32 +
                    32 - 1
    # The above arithmetic is brittle; use the simpler "find the
    # digest in the bytes" trick:
    var hit = -1
    for i in 0 .. (manifestBytes.len - 32):
      var match = true
      for j in 0 ..< 32:
        if manifestBytes[i + j] != realizedPrefix[j]:
          match = false
          break
      if match:
        hit = i
        break
    if hit >= 0:
      manifestBytes[hit] = manifestBytes[hit] xor 0xff'u8

  randomize()
  let boundary = "----RBC-itest-" & $rand(99_999)
  let body = buildMultipart(boundary, manifestBytes, opts.payload)
  let client = newHttpClient()
  defer: client.close()
  client.headers["Content-Type"] = "multipart/form-data; boundary=" & boundary
  if opts.producer.len > 0:
    client.headers["X-Repro-Producer"] = opts.producer
  let resp = client.request(opts.url & "/publish", HttpPost, body)
  let actual = int(resp.code)
  if opts.expectStatus != 0:
    if actual == opts.expectStatus:
      stdout.writeLine(resp.body.strip())
      quit(0)
    stderr.writeLine("publish status mismatch: expected " & $opts.expectStatus &
                     " got " & $actual & " body=" & resp.body)
    quit(4)
  if actual >= 300:
    stderr.writeLine("publish failed: " & $resp.code & " " & resp.body)
    quit(3)
  stdout.writeLine(resp.body.strip())

when isMainModule:
  main()

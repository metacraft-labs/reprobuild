## Windows-Runner-Binary-Cache-Deploy M6 gate —
## ``t_repro_binary_cache_https_publish_authz``.
##
## Stands up the REAL ``repro-binary-cache`` daemon as a SUBPROCESS over
## **HTTPS** (self-signed TLS cert generated with ``openssl``) with a
## ``publicSigners`` publish-authorization allowlist file configured
## (``--allowed-signers``), and asserts the M6 deliverables end-to-end
## over real TLS from a pure client:
##
##   1. An AUTHORIZED publisher (signer in the allowlist) can PUBLISH over
##      HTTPS; the payload is stored and SUBSTITUTABLE BACK (byte-identical)
##      over HTTPS.
##   2. An UNAUTHORIZED publisher (cryptographically-VALID signature by a
##      key that is NOT in the allowlist) is REJECTED (HTTP 403) and
##      NOTHING is written to the store (GET /manifests/<key> → 404,
##      GET /payloads/<hex> → 404).
##   3. The TLS is REAL — the client speaks TLS through the product's own
##      HTTPS code paths (``newHttpClient`` + SSL context for publish;
##      ``http_pool.getEntireBody`` over https for GET/substitute), AND a
##      plaintext probe against the HTTPS port does NOT get a valid HTTP
##      response, proving the port genuinely negotiates TLS.
##   4. NO REGRESSION — a SECOND daemon bound WITHOUT TLS still serves
##      plain HTTP (GET /healthz → 200 "ok"), the M1/M2 path.
##
## Runs the daemon as a REAL subprocess (like the M4/M5 gates) — the
## server's async accept loop and the synchronous TLS client thus live in
## separate processes, so there is no single-event-loop deadlock. The
## daemon binary path is taken from ``REPRO_BINARY_CACHE_SERVER`` (set by
## the harness to the ``-d:ssl`` build); it falls back to
## ``build/test-bin/repro_binary_cache_m6`` for a manual run.
##
## Compiled with ``-d:ssl``. Requires ``openssl`` on PATH (present in the
## reprobuild dev shell) to mint the self-signed cert.

import std/[httpclient, net, os, osproc, random, strutils, unittest]

import ../src/repro_binary_cache_server/types
import ../src/repro_binary_cache_server/key
import ../src/repro_binary_cache_server/manifest_codec
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import ../../blake3/src/blake3
import ../../repro_binary_cache_client/src/repro_binary_cache_client/http_pool

proc serverBin(): string =
  let env = getEnv("REPRO_BINARY_CACHE_SERVER", "")
  if env.len > 0: return env
  result = getCurrentDir() / "build" / "test-bin" / "repro_binary_cache_m6"

proc pickPort(): int =
  randomize()
  result = 24_000 + rand(7_999)

proc hex65(pub: PublicKeyBytes): string =
  const HexChars = "0123456789abcdef"
  result = newStringOfCap(130)
  for b in pub:
    result.add(HexChars[int(b shr 4) and 0x0f])
    result.add(HexChars[int(b) and 0x0f])

proc genSelfSignedCert(dir: string): tuple[cert, key: string] =
  let cert = dir / "tls-cert.pem"
  let key = dir / "tls-key.pem"
  let cmd = "openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 " &
    "-nodes -keyout " & quoteShell(key) & " -out " & quoteShell(cert) &
    " -days 1 -subj /CN=127.0.0.1 -addext subjectAltName=IP:127.0.0.1"
  let (outp, rc) = execCmdEx(cmd)
  if rc != 0:
    raise newException(IOError, "openssl cert gen failed: " & outp)
  (cert, key)

proc buildSignedManifest(kp: PeerKeypair; pkgName: string;
                         payloadBytes: openArray[byte]): BinaryCacheManifest =
  let payloadDigestRaw = blake3.digest(payloadBytes)
  var payloadDigest: Blake3Hash
  for i in 0 ..< 32: payloadDigest[i] = payloadDigestRaw[i]
  var depDigest: Blake3Hash
  for i in 0 ..< 32: depDigest[i] = byte((i * 13 + 7) and 0xff)
  var realizedPrefix: Blake3Hash
  for i in 0 ..< 32: realizedPrefix[i] = byte((i * 23 + 1) and 0xff)
  let payload = PayloadObject(
    kind: pkPrefixArchive, compression: ckNone,
    declaredSize: uint64(payloadBytes.len),
    uncompressedSize: uint64(payloadBytes.len),
    digest: payloadDigest, name: "prefix.rbcarc")
  let entryKey = CacheEntryKey(
    packageName: pkgName, packageVersion: "1.0.0",
    selectedOptions: @[("opt", "default")],
    platform: PlatformTriple(cpu: "x86_64", os: "windows", abi: "msvc",
                             libcVariant: ""),
    toolchain: ToolchainIdentity(name: "nim", version: "2.2.8",
                                 hostLdSoAbi: "", extraFingerprint: ""),
    depClosureDigest: depDigest, providerRevision: "m6-test")
  result = BinaryCacheManifest(
    formatVersion: BinaryCacheFormatVersion, entryKey: entryKey,
    payloads: @[payload], realizedPrefixDigest: realizedPrefix,
    depReferences: @[depDigest], relocationPolicy: rpOptional,
    createdAtUnix: 1_760_000_000'i64)
  signManifest(kp, result)

proc buildMultipartBody(boundary: string;
                        manifestBytes, payloadBytes: openArray[byte]): string =
  result = ""
  result.add("--" & boundary & "\r\n")
  result.add("Content-Disposition: form-data; name=\"manifest\"\r\n\r\n")
  for b in manifestBytes: result.add(char(b))
  result.add("\r\n--" & boundary & "\r\n")
  result.add("Content-Disposition: form-data; name=\"payload\"\r\n\r\n")
  for b in payloadBytes: result.add(char(b))
  result.add("\r\n--" & boundary & "--\r\n")

proc httpsPublish(baseUrl, boundary, body: string): (int, string) =
  ## HTTPS publish via the SAME newHttpClient+SSL path the product's
  ## in_process publisher uses. CVerifyNone accepts the self-signed cert.
  let ctx = newContext(verifyMode = CVerifyNone)
  let client = newHttpClient(timeout = 30_000, sslContext = ctx)
  defer: client.close()
  client.headers["Content-Type"] = "multipart/form-data; boundary=" & boundary
  let resp = client.request(baseUrl & "/publish", HttpPost, body)
  (int(resp.code), resp.body)

proc httpsGet(pool: HttpPool; url: string): (int, seq[byte]) =
  ## GET over HTTPS via the product's own streaming http_pool client — the
  ## exact TLS code path a substitute uses.
  let r = pool.getEntireBody(url)
  (r.statusCode, r.body)

proc plaintextProbeGetsHttp(host: string; port: int): bool =
  ## Plain (non-TLS) socket to the HTTPS port + a plaintext GET. Returns
  ## true iff a well-formed ``HTTP/…`` status line comes back — which on a
  ## real TLS port must be FALSE.
  var s: Socket
  try:
    s = newSocket()
    s.connect(host, Port(port))
    s.send("GET /healthz HTTP/1.1\r\nHost: " & host & "\r\n\r\n")
    var line = ""
    try:
      s.readLine(line, timeout = 2000)
    except CatchableError:
      return false
    return line.startsWith("HTTP/")
  except CatchableError:
    return false
  finally:
    try: s.close() except CatchableError: discard

proc waitHealthy(pool: HttpPool; url: string; tries = 60): bool =
  for _ in 0 ..< tries:
    try:
      let (code, body) = httpsGet(pool, url)
      if code == 200 and cast[string](body) == "ok":
        return true
    except CatchableError:
      discard
    sleep(200)
  return false

proc runScenario() =
  randomize()
  let root = getTempDir() / ("rbc-m6-" & $rand(9_999_999))
  removeDir(root)
  createDir(root)
  defer:
    try: removeDir(root) except CatchableError: discard

  let bin = serverBin()
  doAssert fileExists(bin), "server binary not found: " & bin

  # --- TLS material ---
  let certDir = root / "tls"
  createDir(certDir)
  let (certFile, keyFile) = genSelfSignedCert(certDir)
  # Point the http_pool GET client at the self-signed cert as its CA so it
  # performs REAL peer verification (not CVerifyNone) — a stronger TLS
  # assertion. Must be set before the first http_pool GET (the context is
  # cached on first use).
  putEnv("REPRO_BINARY_CACHE_CA_FILE", certFile)

  # --- Signers: one AUTHORIZED (in allowlist), one UNAUTHORIZED ---
  let authorizedKp = peerAuth.generateKeypair()
  let unauthorizedKp = peerAuth.generateKeypair()

  # Allowlist file: ONLY the authorized producer key (one 130-char hex line).
  let allowFile = root / "allowed-signers.txt"
  writeFile(allowFile, hex65(authorizedKp.publicKey) & "\n")

  # --- Launch the REAL daemon over HTTPS with the allowlist enforced ---
  let tlsPort = pickPort()
  let srvRoot = root / "srv"
  let proc0 = startProcess(bin, args = [
    "--root=" & srvRoot,
    "--listen=127.0.0.1:" & $tlsPort,
    "--tls-cert=" & certFile,
    "--tls-key=" & keyFile,
    "--allowed-signers=" & allowFile],
    options = {poStdErrToStdOut})
  defer:
    try: proc0.terminate() except CatchableError: discard
    try: discard proc0.waitForExit() except CatchableError: discard
    try: proc0.close() except CatchableError: discard

  let base = "https://127.0.0.1:" & $tlsPort
  let pool = newHttpPool()
  defer: pool.close()

  # --- (3) TLS is REAL: healthz over https works (also waits for boot) ---
  check waitHealthy(pool, base & "/healthz")

  # --- ...and a PLAINTEXT probe against the HTTPS port does NOT speak HTTP ---
  block plaintextRejected:
    check (not plaintextProbeGetsHttp("127.0.0.1", tlsPort))

  # --- (1) AUTHORIZED publish over HTTPS succeeds + substitutes back ---
  var authPayload = newSeq[byte](512)
  var rng = initRand(4242)
  for i in 0 ..< authPayload.len:
    authPayload[i] = byte(rng.next() and 0xff)
  authPayload[10] = 0; authPayload[11] = 0; authPayload[300] = 0
  let authManifest = buildSignedManifest(authorizedKp, "m6-authorized", authPayload)
  let authKeyHex = cacheEntryKeyHex(authManifest.entryKey)
  let authPayloadHex = digestToHex(authManifest.payloads[0].digest)

  block authorizedPublish:
    let manifestBytes = encodeManifest(authManifest)
    let boundary = "----RBC-m6-auth-" & $rand(99_999)
    let body = buildMultipartBody(boundary, manifestBytes, authPayload)
    let (code, respBody) = httpsPublish(base, boundary, body)
    check code == 200
    check respBody.strip() == authKeyHex

  block authorizedSubstitutable:
    let (mCode, mBytes) = httpsGet(pool, base & "/manifests/" & authKeyHex)
    check mCode == 200
    let decoded = decodeManifest(mBytes)
    check verifyManifest(decoded)
    check decoded.entryKey.packageName == "m6-authorized"
    let (pCode, pBytes) = httpsGet(pool, base & "/payloads/" & authPayloadHex)
    check pCode == 200
    check pBytes.len == authPayload.len
    var identical = true
    for i in 0 ..< pBytes.len:
      if pBytes[i] != authPayload[i]:
        identical = false
        break
    check identical

  # --- (2) UNAUTHORIZED publish over HTTPS is REJECTED (403) + NOT stored ---
  var badPayload = newSeq[byte](256)
  for i in 0 ..< badPayload.len:
    badPayload[i] = byte((i * 3 + 1) and 0xff)
  let badManifest = buildSignedManifest(unauthorizedKp, "m6-unauthorized", badPayload)
  let badKeyHex = cacheEntryKeyHex(badManifest.entryKey)
  let badPayloadHex = digestToHex(badManifest.payloads[0].digest)

  block unauthorizedRejected:
    # The signature is CRYPTOGRAPHICALLY VALID (so the gate is the ALLOWLIST
    # check, not a broken signature) but the signer is NOT allowlisted.
    check verifyManifest(badManifest)
    let manifestBytes = encodeManifest(badManifest)
    let boundary = "----RBC-m6-bad-" & $rand(99_999)
    let body = buildMultipartBody(boundary, manifestBytes, badPayload)
    let (code, _) = httpsPublish(base, boundary, body)
    check code == 403

  block unauthorizedNotStored:
    let (mCode, _) = httpsGet(pool, base & "/manifests/" & badKeyHex)
    check mCode == 404
    let (pCode, _) = httpsGet(pool, base & "/payloads/" & badPayloadHex)
    check pCode == 404
    # Belt-and-suspenders: no manifest file for the rejected key on disk.
    let manifestDir = srvRoot / "manifests" / badKeyHex[0 .. 1]
    check (not fileExists(manifestDir / (badKeyHex & ".manifest")))

  # --- (4) NO REGRESSION: a plain-HTTP daemon (no TLS) still serves ---
  block plainHttpStillWorks:
    let plainPort = pickPort() + 1
    let plainProc = startProcess(bin, args = [
      "--root=" & (root / "srv-plain"),
      "--listen=127.0.0.1:" & $plainPort],
      options = {poStdErrToStdOut})
    defer:
      try: plainProc.terminate() except CatchableError: discard
      try: discard plainProc.waitForExit() except CatchableError: discard
      try: plainProc.close() except CatchableError: discard
    var ok = false
    let client = newHttpClient(timeout = 5_000)
    defer: client.close()
    for _ in 0 ..< 60:
      try:
        let resp = client.get("http://127.0.0.1:" & $plainPort & "/healthz")
        if int(resp.code) == 200 and resp.body == "ok":
          ok = true
          break
      except CatchableError:
        discard
      sleep(200)
    check ok

suite "M6 — repro-binary-cache HTTPS + publish authorization":
  test "authorized-publish over HTTPS succeeds + substitutes byte-identical; unauthorized rejected 403 + not stored; TLS real; plain HTTP regression":
    runScenario()

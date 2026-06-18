## ReproOS-Generations-And-Foreign-Packages A2 — HTTP server.
##
## REST surface per ``Binary-Caches.md`` + the A2 milestone spec:
##
##   * ``GET /cache-info``       — SSZ-encoded ``CacheInfoRecord``.
##   * ``GET /manifests/<hex>``  — raw manifest envelope.
##   * ``GET /payloads/<hex>``   — raw CAS payload bytes.
##   * ``POST /publish``         — signed multipart: manifest +
##                                 zero or more payload object bytes.
##                                 Server verifies the manifest's
##                                 ECDSA-P256 signature, content-hashes
##                                 every attached payload against the
##                                 declared digest, and rejects on
##                                 mismatch.
##   * ``GET /healthz``          — always 200 "ok" so systemd /
##                                 integration tests can probe liveness.
##
## v1 ships as HTTP (the "promote to HTTPS" item is documented in the
## operator handbook as a follow-up; the threat model is single-tenant
## workstation localhost + WSL/loopback). The HTTP layer is layered on
## top of Nim std/asynchttpserver — the same primitive
## ``libs/repro_peer_cache/src/repro_peer_cache/metrics.nim`` already
## uses for its scrape endpoint.
##
## ## Multipart parsing
##
## ``POST /publish`` uses a minimal multipart parser purpose-built for
## the two-or-three-part shape the v1 publish path needs. The boundary
## is taken from the ``Content-Type`` header; each part starts with a
## ``Content-Disposition: form-data; name="<key>"`` line. Recognised
## keys:
##
##   * ``manifest`` — exactly one; the SSZ envelope bytes.
##   * ``payload`` — zero or more; one per ``PayloadObject`` declared
##                   by the manifest. Order does not matter; the server
##                   re-hashes each part and matches it against the
##                   manifest's declared digests.
##
## Header parsing is RFC 7578-strict on the boundary delimiter only;
## arbitrary header attributes inside the parts are tolerated.

import std/[asyncdispatch, asynchttpserver, asyncnet, httpcore, net, options,
            os, strutils, tables, uri]

import repro_local_store

import ./types
import ./key
import ./manifest_codec
import ./index
import ./sentinel

const
  ManifestContentType* = "application/octet-stream"
  PayloadContentType* = "application/octet-stream"
  CacheInfoContentType* = "application/octet-stream"
  MultipartBoundaryPrefix = "----RBC-"

type
  PublishRequest* = object
    manifestBytes*: seq[byte]
    payloadBlocks*: seq[seq[byte]]

  PublishError* = object of CatchableError
    ## Raised on malformed multipart, missing manifest, or rejected
    ## signature. The HTTP layer maps each to ``Http400`` /
    ## ``Http403`` / ``Http422``.

  PublishCapacityError* = object of CatchableError
    ## Raised by ``handlePublish`` when ingesting the request's
    ## payloads would push the on-disk footprint past the hard cap
    ## (A4 P4 / Debt 2). The HTTP layer maps this to ``Http507``
    ## (Insufficient Storage). NO bytes are written to the CAS
    ## before this raises — the projection runs against the
    ## sum of ``payloadBlocks.len`` BEFORE any ``storeCasBlob``
    ## call.

  BinaryCacheHttpServer* = ref object
    state*: BinaryCacheServerState
    server*: AsyncHttpServer
    listenHost*: string
    listenPort*: Port
    running*: bool
    serveFut*: Future[void]
      ## The in-flight ``AsyncHttpServer.serve`` accept loop. Held so
      ## ``close`` can install a completion handler that swallows the
      ## ``Bad file descriptor`` (``OSError``) that the pending accept
      ## raises once the listening socket is torn down. Without this,
      ## ``asyncCheck`` would reraise that expected shutdown error into
      ## the next ``poll`` and crash an in-process caller that boots and
      ## closes the server inside a single event loop.

# ---------------------------------------------------------------------------
# Multipart parser — tight enough to debug, lax enough to accept
# whitespace variations between RFC 7578 lines.
# ---------------------------------------------------------------------------

proc indexOfBytes(buf: openArray[byte]; needle: openArray[byte];
                  startAt: int): int =
  ## Naive substring search — payloads are bounded by the publish-size
  ## limit (default 1 GiB per the operator handbook) so KMP overkill.
  if needle.len == 0 or buf.len - startAt < needle.len:
    return -1
  var i = startAt
  while i <= buf.len - needle.len:
    var j = 0
    while j < needle.len and buf[i + j] == needle[j]:
      inc j
    if j == needle.len:
      return i
    inc i
  return -1

proc indexOfCharsRange(buf: openArray[byte]; needle: string;
                       startAt: int): int =
  var nb = newSeq[byte](needle.len)
  for i, ch in needle:
    nb[i] = byte(ch)
  indexOfBytes(buf, nb, startAt)

proc parseBoundary*(contentType: string): string =
  ## Extracts ``boundary=...`` from a ``Content-Type: multipart/form-data;
  ## boundary=...`` header value. Strips quotes if present.
  let parts = contentType.split(';')
  for raw in parts:
    let p = raw.strip()
    if p.startsWith("boundary="):
      var b = p[9 .. ^1]
      if b.len >= 2 and b[0] == '"' and b[^1] == '"':
        b = b[1 ..< b.len - 1]
      return b
  raise newException(PublishError,
    "missing boundary= in Content-Type: " & contentType)

proc extractPartName(headers: string): string =
  ## Reads ``name="..."`` from the part's ``Content-Disposition`` line.
  let lower = headers.toLowerAscii()
  let idx = lower.find("content-disposition")
  if idx < 0:
    raise newException(PublishError, "multipart part missing Content-Disposition")
  let lineEnd = lower.find("\r\n", idx)
  let endPos = if lineEnd < 0: lower.len else: lineEnd
  let line = headers[idx ..< endPos]
  let nameIdx = line.toLowerAscii().find("name=")
  if nameIdx < 0:
    raise newException(PublishError, "multipart part missing name= attribute")
  var start = nameIdx + 5
  if start < line.len and line[start] == '"':
    inc start
    let endQ = line.find('"', start)
    if endQ < 0:
      raise newException(PublishError, "unterminated name=\" attribute")
    return line[start ..< endQ]
  else:
    var p = start
    while p < line.len and line[p] notin {';', ' ', '\t', '\r', '\n'}:
      inc p
    return line[start ..< p]

proc parseMultipart*(body: openArray[byte];
                     boundary: string): PublishRequest =
  ## Walks the body splitting on ``--<boundary>``. Tolerant of CRLF /
  ## LF terminators (the integration scripts use curl which always
  ## emits CRLF, but bash test fixtures sometimes use LF). The body
  ## form per RFC 7578:
  ##
  ##   --boundary\r\n
  ##   Content-Disposition: form-data; name="..."\r\n
  ##   \r\n
  ##   <part bytes>\r\n
  ##   --boundary\r\n
  ##   ...
  ##   --boundary--\r\n
  ##
  ## Parts are returned in body order.
  let openMarker = "--" & boundary
  let closeMarker = "--" & boundary & "--"
  var cursor = 0
  let firstBoundary = indexOfCharsRange(body, openMarker, 0)
  if firstBoundary < 0:
    raise newException(PublishError,
      "no boundary marker found in multipart body")
  cursor = firstBoundary + openMarker.len

  while cursor < body.len:
    # Skip CRLF / LF after the boundary marker.
    if cursor < body.len and body[cursor] == byte('\r'):
      inc cursor
    if cursor < body.len and body[cursor] == byte('\n'):
      inc cursor
    # Find the end-of-headers marker (\r\n\r\n) or (\n\n).
    let crlfBlank = indexOfCharsRange(body, "\r\n\r\n", cursor)
    let lfBlank = indexOfCharsRange(body, "\n\n", cursor)
    let blank = (
      if crlfBlank >= 0 and (lfBlank < 0 or crlfBlank <= lfBlank): crlfBlank
      else: lfBlank)
    let blankLen = if blank == crlfBlank: 4 else: 2
    if blank < 0:
      break
    var headers = newString(blank - cursor)
    for i in 0 ..< headers.len:
      headers[i] = char(body[cursor + i])
    let partName = extractPartName(headers)
    let dataStart = blank + blankLen
    # Find next boundary marker.
    let nextBoundary = indexOfCharsRange(body, openMarker, dataStart)
    if nextBoundary < 0:
      raise newException(PublishError,
        "multipart body terminated without final boundary marker")
    # Trim trailing CRLF/LF before the next boundary.
    var dataEnd = nextBoundary
    if dataEnd > dataStart and body[dataEnd - 1] == byte('\n'):
      dec dataEnd
    if dataEnd > dataStart and body[dataEnd - 1] == byte('\r'):
      dec dataEnd
    var partBytes = newSeq[byte](dataEnd - dataStart)
    for i in 0 ..< partBytes.len:
      partBytes[i] = body[dataStart + i]
    case partName
    of "manifest":
      result.manifestBytes = partBytes
    of "payload":
      result.payloadBlocks.add(partBytes)
    else:
      raise newException(PublishError,
        "unknown multipart part name: " & partName)
    # Advance cursor past the next boundary marker for the next pass.
    cursor = nextBoundary + openMarker.len
    # The closing marker is ``--boundary--``; if the next two bytes
    # after the marker are ``--``, we're done.
    if cursor + 1 < body.len and
       body[cursor] == byte('-') and body[cursor + 1] == byte('-'):
      break

# ---------------------------------------------------------------------------
# Publish handler.
# ---------------------------------------------------------------------------

proc handlePublish*(s: BinaryCacheServerState;
                    req: PublishRequest): BinaryCacheManifest =
  ## Validates + ingests a publish request. Returns the decoded
  ## manifest so the HTTP layer can echo the entry-key hex back to
  ## the client.
  ##
  ## Debt 2 / A4 P4 — hard-cap rejection: BEFORE any payload bytes
  ## are written to the CAS the handler projects the post-publish
  ## footprint = ``currentFootprintBytes`` + sum(``payloadBlocks``).
  ## If the projection exceeds ``evictionPolicy.hardCapBytes`` the
  ## publish is rejected with a ``PublishCapacityError`` which the
  ## HTTP layer maps to ``Http507``. The projection is conservative:
  ## it double-counts a payload that is already in the CAS under
  ## the same digest. This is intentional — the publisher MUST
  ## still see the over-cap signal even if a deduplicated blob
  ## happens to leave the actual footprint unchanged; otherwise an
  ## attacker could trickle-publish duplicates to keep the daemon
  ## arbitrarily close to its hard cap without triggering the cap
  ## response. We document the conservativeness in
  ## ``EVICTION-POLICY.md`` and leave the dedup-aware variant for
  ## a future milestone.
  if req.manifestBytes.len == 0:
    raise newException(PublishError, "publish missing manifest part")
  let manifest = decodeManifest(req.manifestBytes)
  # Signature check on the embedded producer pubkey. The trust-anchor
  # allowlist enforcement is logged-only in v1 (single-tenant); a
  # federated deployment would gate here on
  # ``s.info.publicSigners.contains(manifest.producerPubKey)``.
  if not verifyManifest(manifest):
    raise newException(PublishError,
      "manifest signature failed verification against embedded pubkey")
  # Hard-cap projection — runs BEFORE any storeCasBlob call so a
  # rejection leaves the on-disk footprint unchanged.
  if s.evictionPolicy.hardCapBytes > 0:
    var incoming: int64 = 0
    for blob in req.payloadBlocks:
      incoming += int64(blob.len)
    let current = currentFootprintBytes(s.store)
    # Refresh pins from disk if a pin-list path is configured so
    # the operator can adjust pin coverage without bouncing the
    # daemon. The pin set isn't used in the projection itself but
    # we keep it fresh for the soft-cap sweep that may run
    # immediately after a successful publish.
    if s.pinListPath.len > 0:
      try:
        s.evictionPolicy.pins = loadPinList(s.pinListPath)
      except CatchableError: discard
    if willExceedHardCap(s.evictionPolicy, current, incoming):
      raise newException(PublishCapacityError,
        "publish rejected: hard-cap=" & $s.evictionPolicy.hardCapBytes &
        " current=" & $current & " incoming=" & $incoming &
        " (would exceed by " &
        $((current + incoming) - s.evictionPolicy.hardCapBytes) & " bytes)")
  # Verify every declared payload object has a matching attached blob.
  var attachedByDigest = initTable[Blake3Hash, seq[byte]]()
  for blob in req.payloadBlocks:
    let prefixDigest = storeCasBlob(s.store, blob)
    var hash: Blake3Hash
    for i in 0 ..< 32:
      hash[i] = prefixDigest[i]
    attachedByDigest[hash] = blob
  for payload in manifest.payloads:
    if payload.digest notin attachedByDigest:
      raise newException(PublishError,
        "publish missing payload for declared digest " &
        payloadDigestHex(payload))
    let attached = attachedByDigest[payload.digest]
    if uint64(attached.len) != payload.declaredSize:
      raise newException(PublishError,
        "publish payload byte length mismatch for " &
        payloadDigestHex(payload) & ": declared " &
        $payload.declaredSize & ", got " & $attached.len)
  # All checks pass. Persist the manifest under
  # ``manifests/<ab>/<key>.manifest``.
  discard storeManifest(s, manifest)
  return manifest

# ---------------------------------------------------------------------------
# HTTP routing.
# ---------------------------------------------------------------------------

const
  RoutePrefixManifests = "/manifests/"
  RoutePrefixPayloads = "/payloads/"
  RoutePrefixSentinel = "/sentinel/"
  SentinelProducerHeader = "x-repro-producer"
  SentinelTtlHeader = "x-repro-sentinel-ttl"

proc readWholeBody(req: Request): Future[string] {.async.} =
  ## Nim's ``asynchttpserver.Request.body`` already holds the full
  ## body for ``POST`` requests with a ``Content-Length`` header that
  ## the framework read up-front. The wrapper exists so any future
  ## chunked-transfer support has one place to extend.
  result = req.body

proc handleCacheInfo(s: BinaryCacheServerState;
                     req: Request): Future[void] {.async.} =
  let bytes = encodeCacheInfo(s.info)
  var headers = newHttpHeaders()
  headers["Content-Type"] = CacheInfoContentType
  await req.respond(Http200, cast[string](bytes), headers)

proc handleGetManifest(s: BinaryCacheServerState;
                       hex: string;
                       req: Request): Future[void] {.async.} =
  if hex.len != 64:
    await req.respond(Http400, "binary-cache entry-key hex must be 64 chars")
    return
  if not manifestExists(s, hex):
    await req.respond(Http404, "manifest not found")
    return
  let bytes = manifestRawBytes(s, hex)
  var headers = newHttpHeaders()
  headers["Content-Type"] = ManifestContentType
  await req.respond(Http200, cast[string](bytes), headers)

proc handleGetPayload(s: BinaryCacheServerState;
                      hex: string;
                      req: Request): Future[void] {.async.} =
  ## Streams the CAS blob's bytes directly from disk into the client
  ## socket, avoiding the A2 baseline's whole-payload RAM buffer (the
  ## gap A2.5 closes for the throughput gate). Per the A2.5 design,
  ## payloads that can reach ~85 MiB (R5 gcc-15.2.0) must NEVER ride
  ## a ``seq[byte]`` of the same size — the substituter pipeline's
  ## headline win lives on the server keeping memory flat too.
  ##
  ## The byte format matches what ``readPayload`` would have returned;
  ## a peer that buffered against this stream sees identical bytes.
  ## Transport framing: HTTP/1.1 ``Content-Length`` (known up front
  ## from ``getFileSize``), no chunked encoding required — the file
  ## size is determined at handler entry, so we can advertise it
  ## verbatim and stream the bytes through ``client.send`` in 256 KiB
  ## frames.
  if hex.len != 64:
    await req.respond(Http400, "binary-cache payload hex must be 64 chars")
    return
  let prefixId =
    try:
      payloadDigestFromHex(hex)
    except ValueError as e:
      await req.respond(Http400, "malformed payload hex: " & e.msg)
      return
  if not payloadExists(s, prefixId):
    await req.respond(Http404, "payload not found")
    return
  let casPath = s.store.casPath(prefixId)
  let totalBytes = getFileSize(casPath)
  # Build the response prefix: status line + headers + blank.
  var prefix = "HTTP/1.1 200 OK\c\L"
  prefix.add("Content-Type: " & PayloadContentType & "\c\L")
  prefix.add("Content-Length: ")
  prefix.add($totalBytes)
  prefix.add("\c\L\c\L")
  await req.client.send(prefix)
  # Stream the body in 256 KiB frames straight from disk. Per the
  # A2.5 spec § Architecture, we want the receive-side pipeline to
  # observe bytes as they cross the wire, not as one big buffer.
  const FrameBytes = 262144
  var f = open(casPath, fmRead)
  defer: f.close()
  var buf = newString(FrameBytes)
  var remaining = totalBytes
  while remaining > 0:
    let want = int(min(int64(FrameBytes), remaining))
    let n = f.readBuffer(addr buf[0], want)
    if n <= 0:
      # File truncated under us. The client will see Content-Length
      # mismatch on its end. Abort the body here; there's no clean
      # way to retract the headers.
      break
    await req.client.send(buf[0 ..< n])
    remaining -= int64(n)

proc producerIdFor(req: Request; fallback: string): string

proc handlePublishHttp(s: BinaryCacheServerState;
                       req: Request): Future[void] {.async.} =
  let ct =
    if req.headers.hasKey("content-type"): $req.headers["content-type"]
    else: ""
  if not ct.toLowerAscii().contains("multipart/form-data"):
    await req.respond(Http400,
      "POST /publish requires multipart/form-data, got " & ct)
    return
  let boundary =
    try:
      parseBoundary(ct)
    except PublishError as e:
      await req.respond(Http400, e.msg)
      return
  let body = await readWholeBody(req)
  let bytes = cast[seq[byte]](body)
  var parsed =
    try:
      parseMultipart(bytes, boundary)
    except PublishError as e:
      await req.respond(Http400, e.msg)
      return
  try:
    let manifest = handlePublish(s, parsed)
    let hex = cacheEntryKeyHex(manifest.entryKey)
    # Auto-release any sentinel the publishing producer was holding
    # for this entry. The producer self-identifies via the same
    # ``X-Repro-Producer`` header the sentinel POST used. Absent
    # header is tolerated — the sentinel will be reaped by the
    # sweeper on TTL expiry.
    let peer =
      try: $getPeerAddr(req.client)[0]
      except CatchableError: "anonymous"
    let producer = producerIdFor(req, peer)
    if producer.len > 0:
      discard releaseSentinelIfHeldBy(s, hex, producer)
    var headers = newHttpHeaders()
    headers["Content-Type"] = "text/plain; charset=utf-8"
    await req.respond(Http200, hex & "\n", headers)
  except PublishCapacityError as e:
    # Map the hard-cap rejection to 507 Insufficient Storage. The
    # producer's retry logic sees a structured signal it can act on
    # (e.g. trim its publishing batch or escalate to the operator).
    var headers = newHttpHeaders()
    headers["Content-Type"] = "text/plain; charset=utf-8"
    await req.respond(Http507, e.msg & "\n", headers)
  except PublishError as e:
    await req.respond(Http422, e.msg)
  except BinaryCacheCodecError as e:
    await req.respond(Http400, "manifest codec error: " & e.msg)
  except BinaryCacheSignatureError as e:
    await req.respond(Http403, e.msg)

# ---------------------------------------------------------------------------
# In-flight sentinel handlers (A4 P1).
# ---------------------------------------------------------------------------

proc parseSentinelKey(path: string): string =
  ## Strips the ``/sentinel/`` prefix + any trailing slash and returns
  ## the entry-key hex. Returns the empty string on a missing key.
  if not path.startsWith(RoutePrefixSentinel):
    return ""
  var k = path[RoutePrefixSentinel.len .. ^1]
  while k.len > 0 and k[^1] == '/':
    k.setLen(k.len - 1)
  return k

proc producerIdFor(req: Request; fallback: string): string =
  ## The A4 sentinel protocol identifies producers via an opaque header
  ## (``X-Repro-Producer``). When absent we fall back to the client's
  ## peer-addr so a misbehaving producer can't squat on an entry by
  ## omitting the header — the next claim from a different peer takes
  ## over once the original's TTL expires.
  if req.headers.hasKey(SentinelProducerHeader):
    return ($req.headers[SentinelProducerHeader]).strip()
  return fallback

proc parseTtlFromHeader(req: Request): uint32 =
  ## Reads the ``X-Repro-Sentinel-TTL`` header. Falls back to the
  ## ``DefaultSentinelTtlSeconds`` when absent / malformed. Caps the
  ## TTL at 86400 (24h) so a misbehaving producer can't pin an entry
  ## indefinitely.
  if req.headers.hasKey(SentinelTtlHeader):
    let raw = ($req.headers[SentinelTtlHeader]).strip()
    if raw.len > 0:
      try:
        let v = parseInt(raw)
        if v <= 0:
          return DefaultSentinelTtlSeconds
        if v > 86400:
          return 86400'u32
        return uint32(v)
      except ValueError:
        discard
  return DefaultSentinelTtlSeconds

proc handleSentinelGet(s: BinaryCacheServerState;
                       hex: string;
                       req: Request): Future[void] {.async.} =
  if hex.len != 64:
    await req.respond(Http400, "sentinel entry-key hex must be 64 chars")
    return
  let now = nowUnix()
  let prior = loadSentinelIfExists(s, hex)
  if not prior.ok:
    await req.respond(Http404, "no sentinel for entry-key")
    return
  if isExpired(prior.rec, now):
    # Lazy sweep: an expired record is observably "absent" — drop it
    # so the next POST starts clean.
    removeSentinel(s, hex)
    await req.respond(Http404, "sentinel expired")
    return
  let remaining = remainingSeconds(prior.rec, now)
  var headers = newHttpHeaders()
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["X-Repro-Sentinel-Producer"] = prior.rec.producer
  headers["X-Repro-Sentinel-Ttl-Remaining"] = $remaining
  await req.respond(Http200, $remaining & "\n", headers)

proc handleSentinelPost(s: BinaryCacheServerState;
                        hex: string;
                        req: Request): Future[void] {.async.} =
  if hex.len != 64:
    await req.respond(Http400, "sentinel entry-key hex must be 64 chars")
    return
  let peer =
    try: $getPeerAddr(req.client)[0]
    except CatchableError: "anonymous"
  let producer = producerIdFor(req, peer)
  if producer.len == 0:
    await req.respond(Http400, "sentinel claim missing producer id")
    return
  let ttl = parseTtlFromHeader(req)
  let outcome = claimSentinel(s, hex, producer, ttl)
  case outcome
  of scClaimed:
    var headers = newHttpHeaders()
    headers["Content-Type"] = "text/plain; charset=utf-8"
    await req.respond(Http201, "claimed\n", headers)
  of scRefreshed:
    var headers = newHttpHeaders()
    headers["Content-Type"] = "text/plain; charset=utf-8"
    await req.respond(Http200, "refreshed\n", headers)
  of scAlreadyClaimed:
    await req.respond(Http409, "sentinel already claimed by another producer")

proc handleSentinelDelete(s: BinaryCacheServerState;
                          hex: string;
                          req: Request): Future[void] {.async.} =
  if hex.len != 64:
    await req.respond(Http400, "sentinel entry-key hex must be 64 chars")
    return
  releaseSentinel(s, hex)
  await req.respond(Http200, "released\n")

proc handleRequest*(srv: BinaryCacheHttpServer;
                    req: Request): Future[void] {.async.} =
  if not srv.running:
    return
  let path = req.url.path
  case req.reqMethod
  of HttpGet:
    case path
    of "/cache-info":
      await handleCacheInfo(srv.state, req)
    of "/healthz":
      await req.respond(Http200, "ok")
    else:
      if path.startsWith(RoutePrefixManifests):
        let hex = path[RoutePrefixManifests.len .. ^1]
        await handleGetManifest(srv.state, hex, req)
      elif path.startsWith(RoutePrefixPayloads):
        let hex = path[RoutePrefixPayloads.len .. ^1]
        await handleGetPayload(srv.state, hex, req)
      elif path.startsWith(RoutePrefixSentinel):
        let hex = parseSentinelKey(path)
        await handleSentinelGet(srv.state, hex, req)
      else:
        await req.respond(Http404, "no such route")
  of HttpPost:
    case path
    of "/publish":
      await handlePublishHttp(srv.state, req)
    else:
      if path.startsWith(RoutePrefixSentinel):
        let hex = parseSentinelKey(path)
        await handleSentinelPost(srv.state, hex, req)
      else:
        await req.respond(Http404, "no such route")
  of HttpDelete:
    if path.startsWith(RoutePrefixSentinel):
      let hex = parseSentinelKey(path)
      await handleSentinelDelete(srv.state, hex, req)
    else:
      await req.respond(Http404, "no such route")
  else:
    await req.respond(Http405, "method not allowed")

# ---------------------------------------------------------------------------
# Lifecycle.
# ---------------------------------------------------------------------------

proc newBinaryCacheHttpServer*(state: BinaryCacheServerState): BinaryCacheHttpServer =
  BinaryCacheHttpServer(
    state: state,
    server: newAsyncHttpServer(),
    running: false)

proc parseListenAddr*(addrSpec: string): (string, Port) =
  ## Parses ``host:port`` strings — the same convention metrics.nim
  ## uses. Defaults to 0.0.0.0 if host is empty.
  let idx = addrSpec.rfind(':')
  if idx < 0:
    raise newException(ValueError,
      "binary-cache listen addr must be host:port, got " & addrSpec)
  let host = if idx == 0: "0.0.0.0" else: addrSpec[0 ..< idx]
  let port = Port(parseInt(addrSpec[idx + 1 .. ^1]))
  (host, port)

proc sweeperLoop(srv: BinaryCacheHttpServer) {.async.} =
  ## Background sentinel-eviction tick. Wakes every
  ## ``SweepIntervalMs`` and drops every on-disk sentinel whose TTL
  ## has elapsed. The lazy ``GET /sentinel/<key>`` path also evicts on
  ## demand; this loop is the durable safety net for the case where a
  ## producer crashes between claim + publish and no client polls in
  ## the meantime.
  while srv.running:
    await sleepAsync(SweepIntervalMs)
    if not srv.running:
      break
    {.cast(gcsafe).}:
      try:
        discard sweepExpiredSentinels(srv.state)
      except CatchableError as e:
        stderr.writeLine("sentinel sweep failed: " & e.msg)

proc start*(srv: BinaryCacheHttpServer; listenAddr: string) {.async.} =
  let (host, port) = parseListenAddr(listenAddr)
  srv.listenHost = host
  srv.listenPort = port
  srv.running = true
  # One-shot startup sweep so a stale sentinel from a crashed
  # pre-restart producer doesn't survive across reboots.
  {.cast(gcsafe).}:
    try:
      discard sweepExpiredSentinels(srv.state)
    except CatchableError: discard
  proc cb(req: Request) {.async, gcsafe.} =
    {.cast(gcsafe).}:
      await handleRequest(srv, req)
  # Hold the serve future instead of ``asyncCheck``-ing it: ``close``
  # tears down the listening socket while this accept loop is still
  # pending, which surfaces as a ``Bad file descriptor`` ``OSError``.
  # That failure is expected during shutdown, so ``close`` installs a
  # handler that consumes it; ``asyncCheck`` would instead reraise it
  # into the next ``poll`` and crash an in-process caller.
  srv.serveFut = srv.server.serve(port, cb, host)
  asyncCheck sweeperLoop(srv)

proc close*(srv: BinaryCacheHttpServer) =
  if srv.isNil or not srv.running:
    return
  srv.running = false
  # Drain the pending accept loop's expected post-close failure before
  # tearing down the socket, so the event loop never reraises it.
  if not srv.serveFut.isNil and not srv.serveFut.finished:
    # Installing a no-op completion callback marks the future's
    # eventual failure as consumed, so ``asyncCheck``'s default reraise
    # path never runs for the shutdown-induced ``OSError``.
    srv.serveFut.callback = proc () = discard
  try: srv.server.close() except CatchableError: discard

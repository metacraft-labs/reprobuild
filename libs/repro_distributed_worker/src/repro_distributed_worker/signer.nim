## The certificate signer — Distributed-Execution M7 (deployment-security-
## architecture.md EDGE-5, CRED-1, CRED-3, CRED-4; threat model deviation D5).
##
## WHY IT IS NOT ON THE WORKER. EDGE-5 prohibits signing credentials on an
## Edge host, and a worker is untrusted-by-construction. Before this module
## each worker kept a long-lived per-host signing CA on its own disk and
## minted one-hour signing keys from it on demand: whoever compromised the
## worker could mint certificates for as long as the CA was trusted, and the
## "<= 1 h" bound of the keys bounded nothing.
##
## THE SHAPE NOW. The signer is its own service, on its own host, holding
## one signing CA PER WORKER (`repro-worker-<host>` key ids, so revocation
## still names exactly one worker). A worker that has run a test node and
## re-verified its tree asks the signer for ONE certificate; the signer
##
##   * authenticates the worker by its short-lived host-CA leaf (judged at
##     the signer's clock, on every request — a connection never outlives
##     the leaf that opened it);
##   * checks the worker is AUTHORIZED right now (`authorizedPath`, re-read
##     on every request) and not revoked (`revokedPath`): a de-authorized
##     worker gets nothing, even over a connection opened before;
##   * stamps the issuance time from ITS clock (a trusted time — never one
##     the worker wrote; threat model G15);
##   * certifies a fresh one-issuance key for a window of minutes around
##     that time, signs the record, deletes the key, and records the
##     issuance in its own register (`issuedLogPath`) — the list M8
##     enumerates when a worker's certificates must be revoked.
##
## So the worker holds nothing that signs: compromising one yields
## certificates only for as long as the signer still authorizes it, each
## attributed to it, and nothing at all once it is de-authorized.
##
## The wire vocabulary is one request verb. The signing operation itself
## (building and signing a `test-certificate.v1` with `ssh-keygen`) is
## injected (`SignOperation`): it lives with the certificate code in
## `repro_cli_support`, which this library must not depend on.

import std/[asyncdispatch, asyncnet, nativesockets, net, options, os, sets,
            strutils, tables, times]

from repro_core/codec import elementCountFits
import repro_peer_cache/[identity, pki, tls, types]

import ./receiver

const
  SignerMaxFrameBytes* = 256 * 1024
  SignerRatePerSecond = 2.0
  SignerBurst = 10.0
  vProof = 0'u8
  vSign = 1'u8
  vSigned = 2'u8
  vRefused = 3'u8

type
  SignOperation* = proc(workerHost: PeerId; req: CertificateRequest;
                        issuedAt: Time): tuple[ok: bool;
      certificate, serial, reason: string] {.gcsafe, closure.}
    ## Builds and signs one certificate for `workerHost`'s key id, dated
    ## `issuedAt` (the signer's clock), and returns it with the serial of
    ## the one-issuance key's SSH certificate.

  CertSignerServer* = ref object
    identity*: HostIdentity
    leaf*: LeafCredential
    anchorsDir*: string
      ## The workers' host CAs; re-read for every connection.
    authorizedPath*: string
      ## `<64-hex host id>` per line: the workers allowed to obtain
      ## certificates. Re-read on every request; absent = nobody.
    revokedPath*: string
    issuedLogPath*: string
    signOp*: SignOperation
    listenAddr*: string
    listenPort*: Port
    listener: AsyncSocket
    running*: bool
    buckets: Table[PeerId, tuple[tokens: float; lastMs: int64]]
    issuedCount*: int
    refusedCount*: int
    clock*: proc(): int64 {.gcsafe, closure.}
      ## Unix milliseconds; nil = the system clock (a test seam).

  SignerError* = object of CatchableError

proc nowMs(s: CertSignerServer): int64 =
  if s.clock.isNil: int64(epochTime() * 1000.0) else: s.clock()

# ---------------------------------------------------------------------------
# Framing.
# ---------------------------------------------------------------------------

proc putU32(d: var seq[byte]; v: uint32) =
  for s in countup(0, 24, 8): d.add(byte((v shr uint32(s)) and 0xff))

proc putStr(d: var seq[byte]; s: string) =
  d.putU32(uint32(s.len))
  for ch in s: d.add(byte(ord(ch)))

proc getU32(d: openArray[byte]; pos: var int): uint32 =
  if pos + 4 > d.len: raise newException(SignerError, "truncated frame")
  for i in 0 ..< 4: result = result or (uint32(d[pos + i]) shl uint32(8 * i))
  pos += 4

proc getStr(d: openArray[byte]; pos: var int; maxLen: int): string =
  let n = int(getU32(d, pos))
  if n > maxLen or pos + n > d.len:
    raise newException(SignerError, "string too long or truncated")
  result = newString(n)
  for i in 0 ..< n: result[i] = char(d[pos + i])
  pos += n

proc getCount(d: openArray[byte]; pos: var int; minimumBytes: int): int =
  ## An element count, bounded BEFORE anything is sized or looped over by
  ## it: each element takes at least `minimumBytes` (repro_core/codec).
  let raw = getU32(d, pos)
  if not elementCountFits(raw, d.len - pos, minimumBytes):
    raise newException(SignerError, "sign request element count exceeds remaining bytes")
  int(raw)

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, ch in s: result[i] = byte(ord(ch))

proc toStr(b: openArray[byte]): string =
  result = newString(b.len)
  for i, x in b: result[i] = char(x)

proc encodeSignRequest*(req: CertificateRequest): seq[byte] =
  result.putStr(req.content)
  result.putStr(req.project)
  result.putStr(req.platform)
  result.putStr(req.target)
  result.putStr(req.baseCommit)
  result.putStr(req.callerHost)
  result.putU32(uint32(req.commands.len))
  for argv in req.commands:
    result.putU32(uint32(argv.len))
    for a in argv: result.putStr(a)

proc decodeSignRequest*(d: openArray[byte]): CertificateRequest =
  var pos = 0
  result.content = getStr(d, pos, 128)
  result.project = getStr(d, pos, 512)
  result.platform = getStr(d, pos, 128)
  result.target = getStr(d, pos, 512)
  result.baseCommit = getStr(d, pos, 64)
  result.callerHost = getStr(d, pos, 256)
  let n = getCount(d, pos, 4)
  if n > 64: raise newException(SignerError, "too many commands")
  for _ in 0 ..< n:
    let m = getCount(d, pos, 4)
    if m > 1024: raise newException(SignerError, "argv too long")
    var argv: seq[string] = @[]
    for _ in 0 ..< m: argv.add(getStr(d, pos, 8192))
    result.commands.add(argv)
  if pos != d.len: raise newException(SignerError, "trailing bytes")
  if not result.content.startsWith("git-tree-sha1:"):
    raise newException(SignerError, "content is not a git-tree-sha1 id")

proc sendFrame(conn: TlsConn; verb: uint8; body: seq[byte]) {.async.} =
  var frame: seq[byte] = @[]
  frame.putU32(uint32(body.len + 1))
  frame.add(verb)
  frame.add(body)
  await tls.send(conn, frame)

proc recvExact(conn: TlsConn; n: int): Future[seq[byte]] {.async.} =
  var got = ""
  while got.len < n:
    let chunk = await tls.recv(conn, n - got.len)
    if chunk.len == 0:
      return @[]
    got.add(chunk)
  result = toBytes(got)

proc readFrame(conn: TlsConn): Future[tuple[ok: bool; verb: uint8;
                                            body: seq[byte]]] {.async.} =
  let header = await recvExact(conn, 4)
  if header.len != 4:
    return (false, 0'u8, @[])
  var p = 0
  let n = int(getU32(header, p))
  if n < 1 or n > SignerMaxFrameBytes:
    return (false, 0'u8, @[])
  let rest = await recvExact(conn, n)
  if rest.len != n:
    return (false, 0'u8, @[])
  return (true, rest[0], rest[1 .. ^1])

# ---------------------------------------------------------------------------
# Server.
# ---------------------------------------------------------------------------

proc newCertSignerServer*(identity: HostIdentity; anchorsDir: string;
                          authorizedPath, revokedPath, issuedLogPath: string;
                          signOp: SignOperation; listenAddr: string;
                          listenPort = Port(0)): CertSignerServer =
  CertSignerServer(identity: identity, leaf: mintLeaf(identity, lrDaemon),
    anchorsDir: anchorsDir, authorizedPath: authorizedPath,
    revokedPath: revokedPath, issuedLogPath: issuedLogPath, signOp: signOp,
    listenAddr: listenAddr, listenPort: listenPort,
    buckets: initTable[PeerId, tuple[tokens: float; lastMs: int64]]())

proc hostListed(path: string; host: PeerId; failClosed: bool): bool =
  ## Whether `host` is listed in `path`. An unreadable file answers
  ## `failClosed` (authorized: no; revoked: yes).
  if path.len == 0 or not fileExists(path):
    return false
  var text = ""
  try:
    text = readFile(path)
  except CatchableError:
    return failClosed
  for raw in text.splitLines:
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    if line.splitWhitespace()[0] == $host:
      return true
  false

proc takeToken(s: CertSignerServer; host: PeerId): bool =
  let now = s.nowMs()
  var b = s.buckets.getOrDefault(host, (SignerBurst, now))
  b.tokens = min(SignerBurst,
    b.tokens + float(max(0'i64, now - b.lastMs)) / 1000.0 * SignerRatePerSecond)
  b.lastMs = now
  result = b.tokens >= 1.0
  if result: b.tokens -= 1.0
  s.buckets[host] = b

proc register(s: CertSignerServer; line: string) =
  ## The issuance register: one line per decision, appended (O_APPEND).
  if s.issuedLogPath.len == 0:
    return
  try:
    let f = open(s.issuedLogPath, fmAppend)
    defer: f.close()
    f.writeLine(line)
  except CatchableError:
    discard

proc handleConnection(s: CertSignerServer; sock: AsyncSocket) {.async.} =
  if s.leaf.needsRenewal:
    s.leaf = mintLeaf(s.identity, lrDaemon)
  var anchors: TrustAnchorSet
  try:
    anchors = loadTrustAnchorDir(s.anchorsDir)
  except CatchableError:
    try: sock.close() except CatchableError: discard
    return
  let connOpt = await wrapServerSocket(sock, s.leaf.cert.certDer, s.leaf.key,
    anchors)
  if connOpt.isNone:
    try: sock.close() except CatchableError: discard
    return
  let conn = connOpt.get()
  try:
    await sendFrame(conn, vProof, s.leaf.cert.certDer)
    let proof = await readFrame(conn)
    if not proof.ok or proof.verb != vProof:
      return
    let who = verifyLeaf(proof.body, anchors, s.nowMs() div 1000,
      expectedPublicKey = remotePublicKey(conn))
    if not who.ok or who.role != lrDaemon:
      inc s.refusedCount
      return
    while s.running:
      let frame = await readFrame(conn)
      if not frame.ok:
        break
      let nowSec = s.nowMs() div 1000
      proc refuse(reason: string) {.async.} =
        inc s.refusedCount
        s.register($nowSec & " refused " & $who.hostId & " " &
          reason.replace("\n", " "))
        await sendFrame(conn, vRefused, toBytes(reason))
      if nowSec - LeafClockSkewSeconds >= who.notAfter:
        await refuse("the worker's leaf expired; reconnect with a current one")
        break
      if frame.verb != vSign:
        await refuse("not in the signer's vocabulary")
        break
      if hostListed(s.revokedPath, who.hostId, failClosed = true):
        await refuse("worker " & $who.hostId & " is revoked")
        continue
      if not hostListed(s.authorizedPath, who.hostId, failClosed = false):
        await refuse("worker " & $who.hostId &
          " is not authorized to obtain certificates")
        continue
      if not s.takeToken(who.hostId):
        await refuse("rate limit")
        continue
      var req: CertificateRequest
      try:
        req = decodeSignRequest(frame.body)
      except CatchableError as err:
        await refuse("malformed request: " & err.msg)
        break
      let issuedAt = fromUnix(nowSec)
      let signed =
        try: s.signOp(who.hostId, req, issuedAt)
        except CatchableError as err: (false, "", "", err.msg)
      if not signed.ok:
        await refuse("signing failed: " & signed.reason)
        continue
      inc s.issuedCount
      s.register($nowSec & " issued " & $who.hostId & " serial=" &
        signed.serial & " content=" & req.content & " target=" & req.target)
      await sendFrame(conn, vSigned, toBytes(signed.certificate))
  except CatchableError:
    discard
  finally:
    try: await tls.close(conn) except CatchableError: discard

proc acceptLoop(s: CertSignerServer) {.async.} =
  while s.running:
    var client: AsyncSocket
    try:
      client = await s.listener.accept()
    except CatchableError:
      break
    asyncCheck handleConnection(s, client)

proc start*(s: CertSignerServer) =
  s.listener = newAsyncSocket()
  s.listener.setSockOpt(OptReuseAddr, true)
  s.listener.bindAddr(s.listenPort, s.listenAddr)
  s.listenPort = getLocalAddr(s.listener.getFd(), Domain.AF_INET)[1]
  s.listener.listen()
  s.running = true
  asyncCheck acceptLoop(s)

proc stop*(s: CertSignerServer) =
  if not s.running:
    return
  s.running = false
  try: s.listener.close() except CatchableError: discard

# ---------------------------------------------------------------------------
# Client (the worker side).
# ---------------------------------------------------------------------------

proc requestCertificate*(endpoint: Endpoint; leafProvider: LeafProvider;
                         signerAnchors: TrustAnchorSet; expectedSigner: PeerId;
                         req: CertificateRequest;
                         timeoutMs = 60_000): Future[tuple[ok: bool;
    certificate, reason: string]] {.async.} =
  ## Asks the signer at `endpoint` — which must prove the pinned host
  ## `expectedSigner`, under `signerAnchors` (its CA alone) — for one
  ## certificate.
  let sock = newAsyncSocket()
  try:
    await sock.connect(endpoint.host, endpoint.port)
  except CatchableError as err:
    try: sock.close() except CatchableError: discard
    return (false, "", "the certificate signer is unreachable: " & err.msg)
  let leaf = leafProvider()
  if leaf.key.isNil or not leaf.key.available:
    try: sock.close() except CatchableError: discard
    return (false, "", "this worker holds no usable leaf")
  let connOpt = await wrapClientSocket(sock, endpoint.host, leaf.cert.certDer,
    leaf.key, signerAnchors)
  if connOpt.isNone:
    try: sock.close() except CatchableError: discard
    return (false, "", "TLS handshake with the certificate signer failed")
  let conn = connOpt.get()
  try:
    let proof = await readFrame(conn)
    if not proof.ok or proof.verb != vProof:
      return (false, "", "the signer sent no identity proof")
    let signer = verifyLeaf(proof.body, signerAnchors, getTime().toUnix,
      expectedPublicKey = remotePublicKey(conn))
    if not signer.ok or signer.hostId != expectedSigner:
      return (false, "", "the certificate signer is not the pinned host: " &
        signer.reason)
    await sendFrame(conn, vProof, leaf.cert.certDer)
    await sendFrame(conn, vSign, encodeSignRequest(req))
    let replyFut = readFrame(conn)
    if not await withTimeout(replyFut, timeoutMs):
      return (false, "", "the certificate signer did not answer")
    let reply = replyFut.read()
    if not reply.ok:
      return (false, "", "the certificate signer closed the connection")
    case reply.verb
    of vSigned: return (true, toStr(reply.body), "")
    of vRefused: return (false, "", "the signer refused: " & toStr(reply.body))
    else: return (false, "", "unexpected answer from the certificate signer")
  except CatchableError as err:
    return (false, "", "certificate signer exchange failed: " & err.msg)
  finally:
    try: await tls.close(conn) except CatchableError: discard

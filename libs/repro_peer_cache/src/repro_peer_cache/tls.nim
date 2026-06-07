## Peer-Cache-BearSSL M3 — BearSSL TLS 1.2 mutual-auth wrap.
##
## Wraps an `asyncnet.AsyncSocket` with a BearSSL TLS context (one of
## `SslServerContext` / `SslClientContext`). Both sides validate the
## remote leaf against the trust-anchor directory loaded by
## `pki.loadTrustAnchorDir`. Once the handshake completes the M0
## peer-cache framing (`mkHello` / `mkHelloOk` / `mkAdvertiseV2` /
## fetch) runs verbatim inside the tunnel.
##
## See `reprobuild-specs/Peer-Cache-BearSSL.md` §"TLS layer" and
## §"Implementation notes", and the M3 block in
## `reprobuild-specs/Peer-Cache-BearSSL.milestones.org`.
##
## ## API shape
##
## Public surface mirrors `AsyncSocket` so the existing send/recv sites
## in `server.nim` / `client.nim` can swap one for the other behind a
## thin adapter:
##
##   * `wrapServerSocket(sock, ourCert, anchors)` and
##     `wrapClientSocket(sock, host, ourCert, anchors)` drive the
##     handshake to completion (or return `none(TlsConn)` on any
##     failure path: peer cert not in anchors, expired / malformed,
##     timeout, I/O).
##   * `recv(conn, n)` / `send(conn, s)` / `close(conn)` operate on the
##     wrapped tunnel.
##   * `peerCertificateDigest(conn)` returns the SHA-256 of the peer's
##     leaf cert for logging / metrics.
##   * `remotePeerId(conn)` derives the peer-id from the validated
##     pubkey (`BLAKE3-256(pubkey)`, matching the M2 derivation).
##
## ## Buffer lifetime
##
## BearSSL's `SslEngineContext` keeps `ptr byte` references into a
## caller-owned IO buffer + the cert chain + the EC private key for
## the whole life of the TLS session. We allocate everything inside a
## single heap-allocated `TlsConn` ref object so the buffers outlive
## each individual handshake step.
##
## The EC private key bytes (`ourPrivateKeyBuf`) live on the heap-
## allocated `TlsConn` and never move; the BearSSL `EcPrivateKey`
## stored in `ecKey` points at `ourPrivateKeyBuf[0]` for the duration
## of the session. Same pattern for `ourCertDer` (the DER-encoded
## leaf cert) which `X509Certificate.data` points into.
##
## ## Async handshake driver
##
## BearSSL exposes a blocking 5-bit state register
## (`sslEngineCurrentState`) we poll:
##   * `SSL_SENDREC` — bytes to write out to the peer socket
##   * `SSL_RECVREC` — bytes to read in from the peer socket
##   * `SSL_SENDAPP` / `SSL_RECVAPP` — handshake done, app phase live
##   * `SSL_CLOSED` — terminal
##
## `pumpHandshake` chases the engine until SENDAPP or RECVAPP is set or
## a per-step deadline expires. Steady-state `recv` / `send` share the
## same loop; the difference is just which "want app data" bit we're
## chasing.
##
## ## Upstream wrappers checked
##
## `status-im/nim-bearssl` ships `bearssl/{ssl,x509,ec,...}` but no
## `asyncnet` / `chronos` adapter (verified by greping for `asyncnet`
## and `AsyncSocket` over the bindings tree). Hand-rolled wrapper per
## the BearSSL state-machine pattern.

import std/[asyncdispatch, asyncnet, monotimes, options, strutils, tables, times]

import bearssl/[ec, hash as bsslHash]
import bearssl/abi/bearssl_ec as bsslEcAbi
import bearssl/abi/bearssl_hash as bsslHashAbi
import bearssl/abi/bearssl_ssl as bsslSslAbi
import bearssl/abi/bearssl_x509 as bsslX509Abi
import ./auth
import ./pki
import ./types

var tlsDebug* = false
  ## Optional debug toggle — when true the server/client handshakes
  ## emit a one-line trace on every state transition (stderr). Off by
  ## default so the verification tests stay quiet.

const
  TlsHandshakeTimeoutMs* = 2_000
    ## Peer-Cache-BearSSL M3: wall-clock budget for completing the TLS
    ## handshake (mirrors the M3 `AuthHandshakeTimeoutMs` so mixed-mode
    ## peers fail predictably). The handshake loop in `pumpHandshake`
    ## tracks elapsed time and aborts once this is exceeded.

type
  TlsRole* = enum
    trServer, trClient

  TlsHandshakeError* = object of CatchableError

  TlsConn* = ref object
    ## Heap-allocated container that owns every buffer the BearSSL
    ## context references for the lifetime of the TLS session.
    ## See the `Buffer lifetime` doc-section at the top of this file.
    socket*: AsyncSocket
    role*: TlsRole
    closed*: bool

    # BearSSL state-machine contexts. Exactly one of `clientCtx` /
    # `serverCtx` is non-nil according to `role`. `xc` carries the
    # X509Minimal verifier the engine uses to validate the peer's
    # cert chain.
    clientCtx: ref SslClientContext
    serverCtx: ref SslServerContext
    xc: ref X509MinimalContext

    # IO buffer the BearSSL engine uses for both record-layer encode
    # and decode (bidi). Stays alive for the connection lifetime.
    ioBuf: ref array[SSL_BUFSIZE_BIDI, byte]

    # Per-connection trust-anchor staging. BearSSL wants a contiguous
    # `ptr X509TrustAnchor` array whose DN bytes + pubkey bytes stay
    # live for the whole session — we copy from the `TrustAnchorSet`
    # into our own storage so a caller mutating the original set
    # mid-session doesn't pull the rug out.
    anchorList: seq[X509TrustAnchor]
    anchorDns: seq[seq[byte]]        ## Owns the DN bytes referenced by `anchorList[i].dn.data`.
    anchorPubkeys: seq[seq[byte]]    ## Owns the pubkey bytes for `anchorList[i].pkey.key.ec.q`.

    # Our own cert + private key in their BearSSL-ABI-stable owned
    # storage. Both are referenced by the engine across the session.
    ourCertDer: seq[byte]
    ourCertChain: seq[X509Certificate]
    ourPrivateKeyBuf: array[P256PrivLen, byte]
    ecKey: EcPrivateKey

    # Peer identity captured from the validated cert chain.
    peerLeafDer: seq[byte]
    peerPublicKey: PublicKeyBytes
    peerPublicKeyKnown: bool

    # Per-call IO scratch.
    handshakeStarted: bool

# ---------------------------------------------------------------------------
# Small helpers.
# ---------------------------------------------------------------------------

var tlsEpoch = getMonoTime()

proc nowMs(): int64 =
  ## Monotonic milliseconds since module init. Only differences matter
  ## — we use this for deadlines.
  int64((getMonoTime() - tlsEpoch).inMilliseconds)

proc sha256Bytes(buf: openArray[byte]): array[32, byte] =
  var ctx: bsslHashAbi.Sha256Context
  bsslHashAbi.sha256Init(ctx)
  if buf.len > 0:
    bsslHashAbi.sha256Update(ctx, unsafeAddr buf[0], csize_t(buf.len))
  bsslHashAbi.sha256Out(ctx, addr result[0])

# ---------------------------------------------------------------------------
# Trust-anchor staging.
# ---------------------------------------------------------------------------

proc buildAnchorList(conn: TlsConn; anchors: TrustAnchorSet) =
  ## Copies each `TrustAnchorEntry` from the set into per-`TlsConn`-owned
  ## buffers, then builds the parallel `seq[X509TrustAnchor]` whose
  ## `dn.data` + `pkey.key.ec.q` pointers reference those owned buffers.
  conn.anchorDns = @[]
  conn.anchorPubkeys = @[]
  conn.anchorList = @[]
  for _, entry in anchors.byPeerId.pairs:
    if entry.subjectDn.len == 0 or entry.publicKey.len != P256PubLen:
      # Anchor cert without a DN we can match against — useless for
      # chain validation. Skip rather than fail; the caller's missing-
      # anchor path covers the no-peer-validates case.
      continue
    conn.anchorDns.add(entry.subjectDn)
    var pubCopy = newSeq[byte](P256PubLen)
    for i in 0 ..< P256PubLen:
      pubCopy[i] = entry.publicKey[i]
    conn.anchorPubkeys.add(pubCopy)
    conn.anchorList.add(X509TrustAnchor())
  # Track each anchor's CA status alongside its dn/pubkey index so the
  # flag-pass below can discriminate per anchor.
  var isCaFlags = newSeq[bool](conn.anchorList.len)
  var idx = 0
  for _, entry in anchors.byPeerId.pairs:
    if entry.subjectDn.len == 0 or entry.publicKey.len != P256PubLen:
      continue
    isCaFlags[idx] = entry.isCa
    inc idx
  # Wire up the pointers in a second pass — the per-conn-owned buffers
  # have stable addresses now (no further `add` reallocations).
  for i in 0 ..< conn.anchorList.len:
    conn.anchorList[i].dn.data = addr conn.anchorDns[i][0]
    conn.anchorList[i].dn.len = uint(conn.anchorDns[i].len)
    # Peer-Cache-BearSSL M4: per-anchor CA flag discrimination.
    #
    # Direct-trust mode (M3 default): each peer's leaf cert IS its own
    # anchor; `flags = 0` puts it in the leaf-cert direct-trust path.
    #
    # CA-trust mode (M4 mini-CA flow): the mini-CA cert is the anchor;
    # peer leaf certs are NOT in the anchor set; `flags = X509_TA_CA`
    # puts the anchor in the intermediate-issuer lookup path so the
    # BearSSL X509Minimal verifier validates peer leaf certs against
    # it.
    conn.anchorList[i].flags =
      if isCaFlags[i]: cuint(bsslX509Abi.X509_TA_CA) else: 0'u32
    conn.anchorList[i].pkey.keyType = byte(bsslX509Abi.KEYTYPE_EC)
    conn.anchorList[i].pkey.key.ec.curve = cint(bsslEcAbi.EC_secp256r1)
    conn.anchorList[i].pkey.key.ec.q = addr conn.anchorPubkeys[i][0]
    conn.anchorList[i].pkey.key.ec.qlen = uint(conn.anchorPubkeys[i].len)

# ---------------------------------------------------------------------------
# Engine initialisation.
# ---------------------------------------------------------------------------

proc setupOurCertAndKey(conn: TlsConn; ourCert: CertAndKey) =
  ## Copies the leaf cert + private scalar into TlsConn-owned storage and
  ## wires up the BearSSL ABI types that the engine will hold pointers to.
  conn.ourCertDer = ourCert.certDer
  conn.ourCertChain = @[X509Certificate()]
  conn.ourCertChain[0].data = addr conn.ourCertDer[0]
  conn.ourCertChain[0].dataLen = uint(conn.ourCertDer.len)
  for i in 0 ..< P256PrivLen:
    conn.ourPrivateKeyBuf[i] = ourCert.keypair.privateKey[i]
  conn.ecKey.curve = cint(bsslEcAbi.EC_secp256r1)
  conn.ecKey.x = addr conn.ourPrivateKeyBuf[0]
  conn.ecKey.xlen = uint(P256PrivLen)

proc newTlsConn(sock: AsyncSocket; role: TlsRole): TlsConn =
  result = TlsConn(
    socket: sock,
    role: role,
    closed: false,
    handshakeStarted: false,
    peerPublicKeyKnown: false)
  result.clientCtx = nil
  result.serverCtx = nil
  result.xc = new X509MinimalContext
  result.ioBuf = new array[SSL_BUFSIZE_BIDI, byte]

proc initClientEngine(conn: TlsConn; targetHost: string) =
  conn.clientCtx = new SslClientContext
  let anchorsPtr =
    if conn.anchorList.len == 0: nil
    else: addr conn.anchorList[0]
  sslClientInitFull(conn.clientCtx[],
                    cast[ptr X509MinimalContext](addr conn.xc[]),
                    anchorsPtr, uint(conn.anchorList.len))
  # Pin TLS 1.2: TLS 1.0/1.1 doesn't send signature algorithms in
  # CertificateRequest, which breaks BearSSL's `cc_choose` (it cannot
  # find a shared hash and sends an empty Certificate). We need the
  # sig-alg list for mutual auth to work.
  sslEngineSetVersions(conn.clientCtx[].eng, uint16(TLS12), uint16(TLS12))
  # Set the engine buffer BEFORE reset (matches the M0 smoke pattern).
  # `sslClientReset` internally clears the buffer pointer, but we set
  # it back after reset too — see below.
  sslEngineSetBuffer(conn.clientCtx[].eng,
                     addr conn.ioBuf[][0],
                     csize_t(SSL_BUFSIZE_BIDI),
                     1.cint)
  # Provide the client cert + key for the server's CertificateRequest.
  sslClientSetSingleEc(
    conn.clientCtx[],
    addr conn.ourCertChain[0],
    conn.ourCertChain.len,
    addr conn.ecKey,
    cuint(KEYTYPE_SIGN),
    cuint(KEYTYPE_EC),
    ecGetDefault(),
    ecdsaSignAsn1GetDefault())
  # Pass NULL as the server name: peer-cache certs bind the peer-id
  # (BLAKE3-256 of the public key) into the SubjectAltName, not the
  # network hostname. The TLS server-name match would always fail
  # because callers dial by IP, so we let `tlsTrustAnchorsPath` be the
  # sole identity gate.
  discard targetHost
  let resetOk = sslClientReset(conn.clientCtx[], nil.cstring, 0.cint)
  if resetOk != 1:
    raise newException(TlsHandshakeError,
      "BearSSL sslClientReset failed (err=" &
      $sslEngineLastError(conn.clientCtx[].eng) & ")")

proc initServerEngine(conn: TlsConn) =
  conn.serverCtx = new SslServerContext
  sslServerInitFullEc(conn.serverCtx[],
                      addr conn.ourCertChain[0],
                      csize_t(conn.ourCertChain.len),
                      cuint(KEYTYPE_EC),
                      addr conn.ecKey)
  # `sslServerInitFullEc` does NOT wire an ECDSA verifier on the
  # engine — only the EC primitives. Without `iecdsa`, the BearSSL
  # T0 server flow reports `supports-ecdsa? = false`, so its
  # CertificateRequest omits ECDSA from the supported sig-types
  # list. The client's `cc_choose` then can't find a matching hash
  # for our ECDSA cert and ships an empty Certificate, which the
  # server rejects with `BR_ERR_NO_CLIENT_AUTH`. Wire the default
  # ECDSA verifier explicitly so the negotiation works for mutual
  # auth.
  sslEngineSetDefaultEcdsa(conn.serverCtx[].eng)
  # Pin TLS 1.2 — see `initClientEngine` for the rationale.
  sslEngineSetVersions(conn.serverCtx[].eng, uint16(TLS12), uint16(TLS12))
  # Set the engine buffer BEFORE reset so the reset can validate it.
  sslEngineSetBuffer(conn.serverCtx[].eng,
                     addr conn.ioBuf[][0],
                     csize_t(SSL_BUFSIZE_BIDI),
                     1.cint)
  # Wire client-cert validation against the same trust-anchor list.
  # We need an X509MinimalContext for the server side and we ask
  # BearSSL to require a client cert by pointing the server at our
  # anchor DN list.
  if conn.anchorList.len > 0:
    x509MinimalInitFull(conn.xc[],
                       addr conn.anchorList[0],
                       uint(conn.anchorList.len))
    conn.serverCtx[].eng.x509ctx =
      cast[X509ClassPointerConst](addr conn.xc[].vtable)
    # Tell the server to send a CertificateRequest carrying the
    # anchor DNs — this triggers the client's certificate flow.
    sslServerSetTrustAnchorNamesAlt(conn.serverCtx[],
                                    addr conn.anchorList[0],
                                    uint(conn.anchorList.len))
  # Debug toggle: temporarily allow no-client-auth flow so we can
  # distinguish between "client didn't send cert" and "client's cert
  # didn't validate". Off by default.
  when defined(peerCacheTlsTolerateClientAuth):
    sslEngineAddFlags(conn.serverCtx[].eng,
                      uint32(OPT_TOLERATE_NO_CLIENT_AUTH))
  let resetOk = sslServerReset(conn.serverCtx[])
  if resetOk != 1:
    raise newException(TlsHandshakeError,
      "BearSSL sslServerReset failed")

# ---------------------------------------------------------------------------
# Engine accessor (role-aware).
# ---------------------------------------------------------------------------

proc engineRef(conn: TlsConn): ptr SslEngineContext =
  case conn.role
  of trServer: addr conn.serverCtx[].eng
  of trClient: addr conn.clientCtx[].eng

# ---------------------------------------------------------------------------
# Raw socket IO (string <-> byte buffers).
# ---------------------------------------------------------------------------

proc rawSocketSend(sock: AsyncSocket; src: ptr byte; len: int):
    Future[void] {.async.} =
  if len <= 0:
    return
  var s = newString(len)
  for i in 0 ..< len:
    s[i] = char(cast[ptr UncheckedArray[byte]](src)[i])
  await sock.send(s)

proc rawSocketRecvInto(sock: AsyncSocket; dst: ptr byte; cap: int):
    Future[int] {.async.} =
  if cap <= 0:
    return 0
  let chunk = await sock.recv(cap)
  if chunk.len == 0:
    return 0
  let n = min(chunk.len, cap)
  for i in 0 ..< n:
    cast[ptr UncheckedArray[byte]](dst)[i] = byte(ord(chunk[i]))
  return n

# ---------------------------------------------------------------------------
# Handshake / record-layer pump.
# ---------------------------------------------------------------------------

proc pumpUntilState(conn: TlsConn; wanted: cuint; deadlineMs: int64):
    Future[bool] {.async.} =
  ## Drives the BearSSL state machine until one of the bits in `wanted`
  ## is set (or `SSL_CLOSED` flips on, in which case we bail). Returns
  ## true on success, false on close / deadline / IO error.
  let eng = conn.engineRef()
  while true:
    let state = sslEngineCurrentState(eng[])
    if (state and SSL_CLOSED) != 0'u:
      return false
    if (state and wanted) != 0'u:
      return true
    if (state and SSL_SENDREC) != 0'u:
      var sendLen: uint = 0
      let sendBuf = sslEngineSendrecBuf(eng[], sendLen)
      if sendLen == 0'u or sendBuf.isNil:
        # State bit set but no buffer — wait for the engine to advance.
        await sleepAsync(0)
        continue
      try:
        await rawSocketSend(conn.socket, sendBuf, int(sendLen))
      except CatchableError:
        return false
      sslEngineSendrecAck(eng[], csize_t(sendLen))
      continue
    if (state and SSL_RECVREC) != 0'u:
      var recvLen: uint = 0
      let recvBuf = sslEngineRecvrecBuf(eng[], recvLen)
      if recvLen == 0'u or recvBuf.isNil:
        await sleepAsync(0)
        continue
      let recvFut = rawSocketRecvInto(conn.socket, recvBuf, int(recvLen))
      let waitMs = max(0, int(deadlineMs - nowMs()))
      let ok =
        if waitMs <= 0: false
        else: await withTimeout(recvFut, waitMs)
      if not ok:
        return false
      let got =
        try: recvFut.read()
        except CatchableError: 0
      if got <= 0:
        return false
      sslEngineRecvrecAck(eng[], csize_t(got))
      continue
    # No I/O state bit set — yield to dispatcher and re-check.
    await sleepAsync(0)
    if nowMs() > deadlineMs:
      return false

# ---------------------------------------------------------------------------
# Peer identity capture (post-handshake).
# ---------------------------------------------------------------------------

proc capturePeerIdentity(conn: TlsConn) =
  ## Pulls the peer's leaf cert pubkey out of the X509Minimal context.
  let pkPtr = conn.xc[].pkey
  if pkPtr.keyType == byte(KEYTYPE_EC) and pkPtr.key.ec.qlen == uint(P256PubLen):
    let qBuf = cast[ptr UncheckedArray[byte]](pkPtr.key.ec.q)
    var pub: PublicKeyBytes
    for i in 0 ..< P256PubLen:
      pub[i] = qBuf[i]
    conn.peerPublicKey = pub
    conn.peerPublicKeyKnown = true
  # The leaf DER bytes aren't kept by the X509Minimal verifier itself
  # (it streams them through). For metrics we hash the SPKI surrogate
  # — peerCertificateDigest documents this trade-off.

# ---------------------------------------------------------------------------
# Public API: wrapServerSocket / wrapClientSocket.
# ---------------------------------------------------------------------------

proc dumpEngine(conn: TlsConn; tag: string) =
  if not tlsDebug:
    return
  let eng = conn.engineRef()
  let st = sslEngineCurrentState(eng[])
  let err = sslEngineLastError(eng[])
  let xcErr = conn.xc[].err
  let xcNumCerts = conn.xc[].numCerts
  let ver = sslEngineGetVersion(eng[])
  var extra = ""
  if conn.role == trClient and not conn.clientCtx.isNil:
    let authType = conn.clientCtx[].authType
    let hashId = conn.clientCtx[].hashId
    let hashes = conn.clientCtx[].hashes
    let serverCurve = conn.clientCtx[].serverCurve
    let chainLen = eng.chainLen
    extra = " authType=" & $authType.int & " hashId=" & $hashId.int &
            " hashes=" & toHex(int(hashes)) &
            " serverCurve=" & $serverCurve.int &
            " chainLen=" & $chainLen
  stderr.writeLine("tls:" & tag & " role=" & $conn.role &
                   " state=" & toHex(int(st)) & " err=" & $err &
                   " xcErr=" & $xcErr & " xcNumCerts=" & $xcNumCerts &
                   " ver=" & toHex(int(ver)) & extra)

proc wrapServerSocket*(sock: AsyncSocket;
                      ourCert: CertAndKey;
                      anchors: TrustAnchorSet;
                      timeoutMs: int = TlsHandshakeTimeoutMs):
                      Future[Option[TlsConn]] {.async.} =
  ## Wraps an accepted TCP socket with a BearSSL TLS 1.2 mutual-auth
  ## server context. Returns `none` on any handshake failure.
  var conn: TlsConn
  try:
    conn = newTlsConn(sock, trServer)
    setupOurCertAndKey(conn, ourCert)
    buildAnchorList(conn, anchors)
    initServerEngine(conn)
  except CatchableError as err:
    if tlsDebug:
      stderr.writeLine("tls:server init failed: " & err.msg)
    return none(TlsConn)
  dumpEngine(conn, "server-after-init")
  let deadline = nowMs() + int64(timeoutMs)
  let ok = await pumpUntilState(conn,
                                cuint(SSL_SENDAPP) or cuint(SSL_RECVAPP),
                                deadline)
  dumpEngine(conn, "server-after-pump")
  if not ok:
    return none(TlsConn)
  capturePeerIdentity(conn)
  return some(conn)

proc wrapClientSocket*(sock: AsyncSocket;
                      targetHost: string;
                      ourCert: CertAndKey;
                      anchors: TrustAnchorSet;
                      timeoutMs: int = TlsHandshakeTimeoutMs):
                      Future[Option[TlsConn]] {.async.} =
  ## Mirror for the dial side. `targetHost` becomes the TLS SNI; an
  ## empty string falls back to the placeholder `peer.local`.
  var conn: TlsConn
  try:
    conn = newTlsConn(sock, trClient)
    setupOurCertAndKey(conn, ourCert)
    buildAnchorList(conn, anchors)
    initClientEngine(conn, targetHost)
  except CatchableError as err:
    if tlsDebug:
      stderr.writeLine("tls:client init failed: " & err.msg)
    return none(TlsConn)
  dumpEngine(conn, "client-after-init")
  let deadline = nowMs() + int64(timeoutMs)
  let ok = await pumpUntilState(conn,
                                cuint(SSL_SENDAPP) or cuint(SSL_RECVAPP),
                                deadline)
  dumpEngine(conn, "client-after-pump")
  if not ok:
    return none(TlsConn)
  capturePeerIdentity(conn)
  return some(conn)

# ---------------------------------------------------------------------------
# Steady-state IO.
# ---------------------------------------------------------------------------

proc flushSendrec(conn: TlsConn; deadlineMs: int64): Future[bool] {.async.} =
  ## Drains any pending SEND records the engine has queued. Called after
  ## a write so the bytes actually hit the wire.
  let eng = conn.engineRef()
  sslEngineFlush(eng[], 0.cint)
  while true:
    let state = sslEngineCurrentState(eng[])
    if (state and SSL_CLOSED) != 0'u:
      return false
    if (state and SSL_SENDREC) == 0'u:
      return true
    var sendLen: uint = 0
    let sendBuf = sslEngineSendrecBuf(eng[], sendLen)
    if sendLen == 0'u or sendBuf.isNil:
      await sleepAsync(0)
      continue
    try:
      await rawSocketSend(conn.socket, sendBuf, int(sendLen))
    except CatchableError:
      return false
    sslEngineSendrecAck(eng[], csize_t(sendLen))
    if nowMs() > deadlineMs:
      return false

proc sendBytes*(conn: TlsConn; data: seq[byte]) {.async.} =
  ## Pushes `data.len` bytes through the tunnel. Yields between chunks
  ## if BearSSL's send-app buffer fills up.
  if conn.closed:
    raise newException(TlsHandshakeError, "send on closed TlsConn")
  let eng = conn.engineRef()
  var offset = 0
  let deadline = nowMs() + int64(60_000)
  while offset < data.len:
    # Make sure the engine is in a send-app or send-rec state.
    let ok = await pumpUntilState(conn,
                                  cuint(SSL_SENDAPP) or cuint(SSL_SENDREC),
                                  deadline)
    if not ok:
      raise newException(TlsHandshakeError, "send pump failed")
    let state = sslEngineCurrentState(eng[])
    if (state and SSL_SENDAPP) != 0'u:
      var roomLen: uint = 0
      let appBuf = sslEngineSendappBuf(eng[], roomLen)
      if roomLen == 0'u or appBuf.isNil:
        await sleepAsync(0)
        continue
      let chunk = min(int(roomLen), data.len - offset)
      let dst = cast[ptr UncheckedArray[byte]](appBuf)
      for i in 0 ..< chunk:
        dst[i] = data[offset + i]
      sslEngineSendappAck(eng[], csize_t(chunk))
      offset += chunk
    elif (state and SSL_SENDREC) != 0'u:
      # Flush pending records before adding more app data.
      let flushOk = await flushSendrec(conn, deadline)
      if not flushOk:
        raise newException(TlsHandshakeError, "send flush failed")
    else:
      raise newException(TlsHandshakeError,
        "send: engine in unexpected state " & $state)
  let finalFlush = await flushSendrec(conn, deadline)
  if not finalFlush:
    raise newException(TlsHandshakeError, "send final flush failed")

proc send*(conn: TlsConn; data: string) {.async.} =
  var asBytes = newSeq[byte](data.len)
  for i in 0 ..< data.len:
    asBytes[i] = byte(ord(data[i]))
  await sendBytes(conn, asBytes)

proc send*(conn: TlsConn; data: seq[byte]) {.async.} =
  await sendBytes(conn, data)

proc recv*(conn: TlsConn; size: int): Future[string] {.async.} =
  ## Reads up to `size` bytes from the tunnel. Returns the empty string
  ## when the tunnel is closed by the peer.
  if size <= 0:
    return ""
  if conn.closed:
    return ""
  result = newStringOfCap(size)
  let eng = conn.engineRef()
  let deadline = nowMs() + int64(60_000)
  while result.len < size:
    let ok = await pumpUntilState(conn,
                                  cuint(SSL_RECVAPP) or cuint(SSL_CLOSED),
                                  deadline)
    if not ok:
      # Treat handshake-pump exit as remote-close for the recv contract.
      break
    let state = sslEngineCurrentState(eng[])
    if (state and SSL_CLOSED) != 0'u:
      break
    if (state and SSL_RECVAPP) == 0'u:
      await sleepAsync(0)
      continue
    var availLen: uint = 0
    let appBuf = sslEngineRecvappBuf(eng[], availLen)
    if availLen == 0'u or appBuf.isNil:
      await sleepAsync(0)
      continue
    let want = min(int(availLen), size - result.len)
    let src = cast[ptr UncheckedArray[byte]](appBuf)
    for i in 0 ..< want:
      result.add(char(src[i]))
    sslEngineRecvappAck(eng[], csize_t(want))
    # If we got something, return as soon as we've satisfied the
    # caller's contract (best-effort: matches `AsyncSocket.recv`
    # semantics where partial reads are legal).
    if result.len >= size:
      break

proc close*(conn: TlsConn) {.async.} =
  if conn.closed:
    return
  conn.closed = true
  try: conn.socket.close() except CatchableError: discard

# ---------------------------------------------------------------------------
# Metadata accessors.
# ---------------------------------------------------------------------------

proc peerCertificateDigest*(conn: TlsConn): Option[seq[byte]] =
  ## Returns SHA-256 of the peer's validated public-key bytes — a
  ## stable per-peer fingerprint for logging. (BearSSL's minimal
  ## verifier streams cert bytes through the engine without preserving
  ## the full DER; we use the SPKI as a fingerprint surrogate.)
  if not conn.peerPublicKeyKnown:
    return none(seq[byte])
  let digest = sha256Bytes(conn.peerPublicKey)
  var out0: seq[byte] = newSeq[byte](digest.len)
  for i in 0 ..< digest.len:
    out0[i] = digest[i]
  some(out0)

proc remotePeerId*(conn: TlsConn): Option[PeerId] =
  if not conn.peerPublicKeyKnown:
    return none(PeerId)
  some(derivePeerIdFromPublicKey(conn.peerPublicKey))

proc remotePublicKey*(conn: TlsConn): Option[PublicKeyBytes] =
  if not conn.peerPublicKeyKnown:
    return none(PublicKeyBytes)
  some(conn.peerPublicKey)

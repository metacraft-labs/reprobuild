## ReproOS-Generations-And-Foreign-Packages A2.5 — HTTP connection pool.
##
## **Why hand-rolled?** ``std/httpclient`` buffers the entire response
## body in a string before handing it to the caller; that defeats the
## A2.5 streaming-sink design (we must pipe socket bytes straight into
## BLAKE3 + the temp file in one pass). We write a minimal HTTP/1.1
## client on top of ``std/net.Socket`` that exposes a chunk-callback
## interface — the receive callback fires for every TCP read, so the
## payload bytes never coalesce into one big buffer.
##
## **HTTP/2 / libcurl path.** Nix uses libcurl's multi handle for
## per-connection HTTP/2 stream multiplexing; the cumulative win against
## a busy mirror is real. The hand-rolled HTTP/1.1 client here matches
## what A2 currently advertises (``std/asynchttpserver`` is HTTP/1.1
## only) — when we promote the server to HTTP/2 (follow-up), this pool
## grows a libcurl backend behind the same ``streamGet`` shape. The
## interface is libcurl-shaped on purpose.
##
## ## Threading model
##
## A pool holds a ring of cached connections per host. ``streamGet``
## leases one (or opens a fresh socket), drives the request/response
## exchange, fires the chunk-callback for every read, and returns the
## connection to the pool. The pool is mutex-free because A2.5's
## scheduler-executor entry points are called from the build-engine's
## main thread (one ``executeBuildAction`` at a time); per-thread
## fanout for parallel substitutes opens its own pool lease through
## the BuildPool ``capacity`` knob — the engine guarantees one
## ``ClientContext`` accessor per worker thread.

import std/[monotimes, nativesockets, net, os, parseutils, strutils, times, uri]

when defined(windows):
  import std/winlean
else:
  import std/posix

when defined(ssl):
  import wrappers/openssl

# Windows-Runner-Binary-Cache-Deploy M6 — HTTPS support. TLS is compiled
# in only under ``-d:ssl`` (OpenSSL); without it, an https:// URL raises a
# clear error at ``parseTarget`` and plain HTTP is unaffected. The CA /
# verification mode is resolved from the environment so a self-signed
# server cert (the M6 gate + behind-NetBird deployment) is usable:
#
#   * ``REPRO_BINARY_CACHE_CA_FILE``  — PEM CA/cert to trust (verify peer).
#   * ``REPRO_BINARY_CACHE_TLS_INSECURE=1`` — skip cert verification
#     (self-signed, no CA on hand). The manifest ECDSA-P256 signature is
#     the end-to-end trust boundary, so this only relaxes transport auth.
when defined(ssl):
  var gTlsCtx: SslContext = nil
  var gOpenSslInitialized = false

  proc ensureOpenSslInitialized() =
    if not gOpenSslInitialized:
      discard SSL_library_init()
      gOpenSslInitialized = true

  proc tlsContext(): SslContext =
    if gTlsCtx != nil:
      return gTlsCtx
    ensureOpenSslInitialized()
    let caFile = getEnv("REPRO_BINARY_CACHE_CA_FILE", "")
    let insecure = getEnv("REPRO_BINARY_CACHE_TLS_INSECURE", "") in ["1", "true", "yes"]
    if insecure:
      gTlsCtx = newContext(verifyMode = CVerifyNone)
    elif caFile.len > 0:
      gTlsCtx = newContext(verifyMode = CVerifyPeer, caFile = caFile)
    else:
      gTlsCtx = newContext(verifyMode = CVerifyPeer)
    return gTlsCtx

type
  HostKey = tuple[host: string; port: Port; secure: bool]

  PooledConnection* = ref object
    sock*: Socket
    host*: string
    port*: Port
    secure*: bool
      ## When true the socket has been TLS-wrapped. Reserved for the
      ## HTTPS follow-up; A2.5 ships HTTP-only (the cryptographic
      ## boundary is the ECDSA-P256 signature on each manifest).
    inUse*: bool

  HttpPool* = ref object
    connections*: seq[PooledConnection]
    maxConnections*: int
      ## libcurl ``CURLMOPT_MAX_TOTAL_CONNECTIONS`` analogue. When the
      ## pool is full, ``streamGet`` opens a transient (non-pooled)
      ## connection instead of blocking.
    receiveTimeoutMs*: int
      ## Deadline for the peer to answer once connected; surfaced as
      ## ``HttpError`` if it stalls. The TLS handshake must complete
      ## within it, the request must be sent within it, the status line
      ## and headers together must arrive within it, as must each
      ## chunk-size line, and each body read returns within it. Over TLS
      ## these hold against a peer that sends a TLS record a byte at a
      ## time, not only against a silent one. 30s default — large
      ## payloads on slow links still fit, because the body as a whole
      ## has no deadline.
    connectTimeoutMs: int
      ## Deadline for opening a TCP connection, covering every address
      ## the host name resolves to. It applies to every user of the pool,
      ## not only binary-cache lookups. A cache whose address silently drops
      ## packets (a firewalled or powered-off host, a stale address in
      ## ``caches.conf``) would otherwise hold the caller for the
      ## operating system's own connect timeout — about 130s on Linux —
      ## when the caller's next step is to fall back to building. 5s
      ## default: a reachable cache, even over a VPN, connects well
      ## inside it, and it still leaves room for two lost SYNs.

  HttpError* = object of CatchableError

  StreamChunkCallback* = proc(chunk: openArray[byte]) {.gcsafe.}
    ## Fires for every TCP read after headers are drained. The callback
    ## sees a slice into a buffer the pool owns; it must consume the
    ## bytes before returning.

  StreamResponse* = object
    statusCode*: int
    contentLength*: int64
      ## ``-1`` when the server sent ``Transfer-Encoding: chunked`` —
      ## the body length is then determined by the chunked-framing.
    bytesReceived*: int64
    chunked*: bool
    location*: string
      ## The ``Location`` header of a 3xx response, verbatim; ``""``
      ## otherwise. ``streamGet`` does not follow redirects itself (a
      ## redirect target is the caller's policy), so a caller that wants
      ## them loops on this.

const
  DefaultMaxConnections = 16
  DefaultReceiveTimeoutMs = 30_000
  DefaultConnectTimeoutMs* = 5_000

proc newHttpPool*(maxConnections = DefaultMaxConnections;
                  receiveTimeoutMs = DefaultReceiveTimeoutMs;
                  connectTimeoutMs = DefaultConnectTimeoutMs): HttpPool =
  ## ``connectTimeoutMs`` and ``receiveTimeoutMs`` must be positive:
  ## there is deliberately no "wait as long as the operating system does"
  ## setting, because that is the unbounded stall the deadlines exist to
  ## prevent.
  if connectTimeoutMs <= 0:
    raise newException(ValueError,
      "connectTimeoutMs must be positive, got " & $connectTimeoutMs)
  if receiveTimeoutMs <= 0:
    raise newException(ValueError,
      "receiveTimeoutMs must be positive, got " & $receiveTimeoutMs)
  HttpPool(
    connections: @[],
    maxConnections: maxConnections,
    receiveTimeoutMs: receiveTimeoutMs,
    connectTimeoutMs: connectTimeoutMs)

proc connectTimeoutMs*(pool: HttpPool): int =
  ## The pool's connect deadline. Read-only: it is set, and checked to be
  ## positive, only by ``newHttpPool``.
  pool.connectTimeoutMs

proc close*(pool: HttpPool) =
  if pool.isNil:
    return
  for c in pool.connections:
    try: c.sock.close() except CatchableError: discard
  pool.connections.setLen(0)

# ---------------------------------------------------------------------------
# URL parsing
# ---------------------------------------------------------------------------

type
  ParsedUrl* = object
    host*: string
    port*: Port
    path*: string
    secure*: bool

proc parseTarget*(url: string): ParsedUrl =
  ## Splits the URL into host / port / path. HTTPS is supported when the
  ## binary is compiled with ``-d:ssl`` (Windows-Runner-Binary-Cache-Deploy
  ## M6); otherwise an https:// URL raises so plain-HTTP builds fail loud
  ## rather than silently talking plaintext to a TLS port.
  let u = parseUri(url)
  if u.scheme.toLowerAscii() notin ["http", "https"]:
    raise newException(HttpError, "unsupported scheme: " & u.scheme)
  result.secure = u.scheme.toLowerAscii() == "https"
  if result.secure and not defined(ssl):
    raise newException(HttpError,
      "https:// requires a build with -d:ssl; this binary is HTTP-only")
  result.host = u.hostname
  let defaultPort = if result.secure: 443 else: 80
  result.port = Port(if u.port.len > 0: parseInt(u.port) else: defaultPort)
  result.path = if u.path.len == 0: "/" else: u.path
  if u.query.len > 0:
    result.path.add("?")
    result.path.add(u.query)

# ---------------------------------------------------------------------------
# Connection lease
# ---------------------------------------------------------------------------

type ConnectWait = enum
  cwFinished     ## the connect completed, successfully or not: read SO_ERROR
  cwTimedOut     ## the deadline passed first
  cwInterrupted  ## a signal interrupted the wait; wait again

proc awaitConnect(fd: SocketHandle; remainingMs: int64): ConnectWait =
  ## Waits for a pending non-blocking connect on ``fd`` to finish, for at
  ## most ``remainingMs``. Raises ``OSError`` for a failure of the wait
  ## itself other than an interruption by a signal.
  let waitMs = cint(min(remainingMs, int64(high(cint))))
  when defined(windows):
    # Winsock reports a finished connect in the WRITE set when it
    # succeeded and only in the EXCEPT set when it failed, so both sets
    # are watched. A write-set-only wait never wakes for a refused
    # connect and would report it as a timeout. Behaviour documented at
    # https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-select
    # (WSAPoll is not used: older Windows builds do not report a failed
    # connect through it.)
    var wr, ex: TFdSet
    FD_ZERO(wr); FD_ZERO(ex)
    FD_SET(fd, wr); FD_SET(fd, ex)
    var tv = Timeval(tv_sec: int32(waitMs div 1000),
                     tv_usec: int32((waitMs mod 1000) * 1000))
    let rc = winlean.select(0, nil, addr wr, addr ex, addr tv)
    if rc > 0: return cwFinished
    if rc == 0: return cwTimedOut
    raiseOSError(osLastError())
  else:
    # POSIX reports both outcomes as writability (a failure also raises
    # POLLERR, which poll(2) reports whatever ``events`` asked for).
    var pfd = TPollfd(fd: fd.cint, events: POLLOUT, revents: 0)
    let rc = poll(addr pfd, 1, waitMs)
    if rc > 0: return cwFinished
    if rc == 0: return cwTimedOut
    let err = osLastError()
    if err.cint == EINTR: return cwInterrupted
    raiseOSError(err)

proc connectWithDeadline(sock: Socket; domain: Domain; host: string;
                         port: Port; timeoutMs: int) =
  ## Connects ``sock`` (created for address family ``domain``; ``net``
  ## does not expose a socket's family) to ``host:port``, giving up once
  ## ``timeoutMs`` has passed. The deadline is shared by every address
  ## ``host`` resolves to, tried in resolver order as the blocking
  ## ``net.connect`` does. Raises ``TimeoutError`` when the deadline passes
  ## and ``OSError`` for any other failure (name resolution, refusal,
  ## unreachable network), carrying the operating system's own message.
  ##
  ## Name resolution itself (``getaddrinfo``) is not bounded here; a
  ## cache is normally named by an address or a host-local name.
  ##
  ## Not the standard library's timed ``connect`` (``net.connect`` with
  ## ``timeout``), for three reasons. It stops at the first address whose
  ## connect is pending, so a refusal that arrives later through
  ## ``SO_ERROR`` is raised instead of falling through to the host's next
  ## address the way the blocking connect did. On POSIX it reports a wait
  ## interrupted by a signal (``EINTR``) as a timeout. And on Windows it
  ## waits only for writability, which Winsock never signals for a failed
  ## connect (see ``awaitConnect``), so a refused port would take the whole
  ## deadline and be reported as a timeout.
  ## Non-blocking connect protocol:
  ## https://pubs.opengroup.org/onlinepubs/9799919799/functions/connect.html
  ## The deadline is on the monotonic clock, so a wall-clock step neither
  ## cuts the wait short nor extends it.
  let fd = sock.getFd()
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  let aiList = getAddrInfo(host, port, domain)
  defer: freeAddrInfo(aiList)
  fd.setBlocking(false)
  var lastError = OSErrorCode(0)
  var ai = aiList
  while ai != nil:
    let started =
      when defined(windows): winlean.connect(fd, ai.ai_addr, ai.ai_addrlen.SockLen)
      else: posix.connect(fd, ai.ai_addr, ai.ai_addrlen.SockLen)
    if started == 0:
      fd.setBlocking(true)
      return
    let err = osLastError()
    let pending =
      when defined(windows): err.int32 == WSAEWOULDBLOCK
      else: err.cint == EINPROGRESS
    if not pending:
      lastError = err
      ai = ai.ai_next
      continue
    while true:
      let remainingMs = (deadline - getMonoTime()).inMilliseconds
      if remainingMs <= 0:
        raise newException(TimeoutError, "connect timed out")
      case awaitConnect(fd, remainingMs)
      of cwFinished: break
      of cwTimedOut: raise newException(TimeoutError, "connect timed out")
      of cwInterrupted: continue
    # The connect finished. ``SO_ERROR`` says how.
    let soError = getSockOptInt(fd, SOL_SOCKET, SO_ERROR)
    if soError == 0:
      fd.setBlocking(true)
      return
    lastError = OSErrorCode(soError)
    ai = ai.ai_next
  if lastError.int == 0:
    raise newException(OSError, "no address found for " & host)
  raiseOSError(lastError)

proc awaitIo(fd: SocketHandle; forWrite: bool; deadline: MonoTime): bool =
  ## Waits until ``fd`` is readable (or, with ``forWrite``, writable), or
  ## has an error or hang-up to report, for at most the time left before
  ## ``deadline`` on the monotonic clock. Returns false when the deadline
  ## passes first. A wait interrupted by a signal is resumed. Raises
  ## ``OSError`` for a failure of the wait itself.
  while true:
    let remainingMs = (deadline - getMonoTime()).inMilliseconds
    if remainingMs <= 0:
      return false
    let waitMs = cint(min(remainingMs, int64(high(cint))))
    when defined(windows):
      # A closed or reset connection is reported in the read set, and a
      # failed one in the except set.
      # https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-select
      var rw, ex: TFdSet
      FD_ZERO(rw); FD_ZERO(ex)
      FD_SET(fd, rw); FD_SET(fd, ex)
      var tv = Timeval(tv_sec: int32(waitMs div 1000),
                       tv_usec: int32((waitMs mod 1000) * 1000))
      let rc =
        if forWrite: winlean.select(0, nil, addr rw, addr ex, addr tv)
        else: winlean.select(0, addr rw, nil, addr ex, addr tv)
      if rc > 0: return true
      if rc < 0: raiseOSError(osLastError())
    else:
      # POLLERR and POLLHUP are reported whatever ``events`` asked for; the
      # read or write that follows then reports what happened.
      # https://pubs.opengroup.org/onlinepubs/9799919799/functions/poll.html
      var pfd = TPollfd(fd: fd.cint,
                        events: (if forWrite: POLLOUT else: POLLIN),
                        revents: 0)
      let rc = poll(addr pfd, 1, waitMs)
      if rc > 0: return true
      if rc < 0:
        let err = osLastError()
        if err.cint != EINTR:
          raiseOSError(err)

proc wouldBlock(err: OSErrorCode): bool =
  ## Whether a failed non-blocking ``send`` or ``recv`` only means "not
  ## now" (no buffer space, or no data yet, or a signal arrived).
  when defined(windows):
    err.int32 == WSAEWOULDBLOCK or err.int32 == WSAEINTR
  else:
    err.cint == EAGAIN or err.cint == EWOULDBLOCK or err.cint == EINTR

when defined(ssl):
  type TlsStep = enum
    tsRetry   ## OpenSSL can make progress now: call it again
    tsClosed  ## the peer closed the connection

  proc openSslErrorText(): string =
    ## The oldest queued OpenSSL error, as OpenSSL words it, and clears
    ## the queue.
    let code = ERR_get_error()
    ErrClearError()
    if code == 0: "an unspecified TLS error"
    else: $ERR_error_string(code, nil)

  proc awaitTls(sock: Socket; ret: cint; deadline: MonoTime): TlsStep =
    ## Handles a non-positive result ``ret`` of ``SSL_connect``,
    ## ``SSL_read`` or ``SSL_write`` on the non-blocking ``sock``: waits,
    ## until ``deadline``, for the socket condition OpenSSL asked for, and
    ## then says to retry. Raises ``TimeoutError`` once the deadline
    ## passes and ``OSError`` for a TLS or socket failure. Driving OpenSSL
    ## this way is what makes the deadline total: a blocking ``SSL_read``
    ## keeps reading until it has a whole TLS record, so a peer sending a
    ## byte at a time would hold it however each wait was bounded.
    ## https://docs.openssl.org/3.0/man3/SSL_get_error/
    let err = SSL_get_error(sock.sslHandle, ret)
    case err
    of SSL_ERROR_WANT_READ, SSL_ERROR_WANT_WRITE:
      if not awaitIo(sock.getFd(), err == SSL_ERROR_WANT_WRITE, deadline):
        raise newException(TimeoutError, "TLS wait timed out")
      return tsRetry
    of SSL_ERROR_ZERO_RETURN:
      return tsClosed
    of SSL_ERROR_SYSCALL:
      let osErr = osLastError()
      if ERR_peek_last_error() != 0:
        raise newException(OSError, openSslErrorText())
      if ret == 0 or osErr.int == 0:
        # End of file without a close_notify (OpenSSL 1.1 reports it
        # this way; 3.x reports it as SSL_ERROR_SSL).
        return tsClosed
      if wouldBlock(osErr):
        return tsRetry
      raiseOSError(osErr)
    of SSL_ERROR_SSL:
      raise newException(OSError, openSslErrorText())
    else:
      raise newException(OSError, "unexpected SSL_get_error result " & $err)

  proc tlsHandshakeBefore(sock: Socket; host: string; deadline: MonoTime) =
    ## Performs the client TLS handshake on the connected, non-blocking
    ## ``sock``, completing it before ``deadline``. Raises ``TimeoutError``
    ## when the deadline passes and ``OSError`` or ``SslError`` when the
    ## handshake fails.
    ##
    ## Does what ``net.wrapConnectedSocket`` does for ``handshakeAsClient``
    ## (SNI for a host name, then the same host-name check, under the same
    ## conditions), except that the handshake is driven by ``awaitTls``
    ## rather than one blocking ``SSL_connect``.
    tlsContext().wrapSocket(sock)
    if host.len > 0 and not isIpAddress(host):
      discard SSL_set_tlsext_host_name(sock.sslHandle, host)
    while true:
      ErrClearError()
      let ret = SSL_connect(sock.sslHandle)
      if ret == 1:
        break
      if awaitTls(sock, ret, deadline) == tsClosed:
        raise newException(OSError,
          "the peer closed the connection during the handshake")
    when not defined(nimDisableCertificateValidation) and not defined(windows):
      # ``net.checkCertName`` is private; this is its body.
      # https://docs.openssl.org/3.0/man3/X509_check_host/
      if host.len > 0 and not isIpAddress(host):
        let certificate = SSL_get_peer_certificate(sock.sslHandle)
        if certificate.isNil:
          raiseSSLError("No SSL certificate found.")
        const X509_CHECK_FLAG_ALWAYS_CHECK_SUBJECT = 0x1.cuint
        let match = certificate.X509_check_host(host.cstring, host.len.cint,
          X509_CHECK_FLAG_ALWAYS_CHECK_SUBJECT, nil)
        X509_free(certificate)
        if match != 1:
          raiseSSLError("SSL Certificate check failed.")

proc sendBefore(sock: Socket; data: string; deadline: MonoTime) =
  ## Sends all of ``data`` on the non-blocking ``sock`` before
  ## ``deadline``. Raises ``TimeoutError`` when the deadline passes (a
  ## peer that has stopped reading) and ``OSError`` for any other failure.
  ## Not ``net.send``: that retries a send that would block up to 100
  ## times, so its bound is a multiple of any per-call timeout.
  var written = 0
  while written < data.len:
    when defined(ssl):
      if sock.isSsl:
        ErrClearError()
        let ret = SSL_write(sock.sslHandle,
                            cast[cstring](unsafeAddr data[written]),
                            data.len - written)
        if ret > 0:
          written += ret
        elif awaitTls(sock, ret, deadline) == tsClosed:
          raise newException(OSError, "the peer closed the connection")
        continue
    let fd = sock.getFd()
    let sent =
      when defined(windows):
        int(winlean.send(fd, unsafeAddr data[written],
                         cint(data.len - written), 0))
      elif defined(macosx):
        # No MSG_NOSIGNAL on macOS; ``net`` sets SO_NOSIGPIPE instead.
        int(posix.send(fd, unsafeAddr data[written], data.len - written, 0))
      else:
        int(posix.send(fd, unsafeAddr data[written], data.len - written,
                       MSG_NOSIGNAL))
    if sent >= 0:
      written += sent
      continue
    let err = osLastError()
    if not wouldBlock(err):
      raiseOSError(err)
    if not awaitIo(fd, forWrite = true, deadline):
      raise newException(TimeoutError, "send timed out")

proc recvBefore(sock: Socket; data: pointer; size: int;
                deadline: MonoTime): int =
  ## Reads from the non-blocking ``sock`` into ``data``, returning before
  ## ``deadline``. Returns the number of bytes read, 0 when the peer has
  ## closed the connection, or (plain HTTP only) a negative value for a
  ## failed read. Raises ``TimeoutError`` when the deadline passes and
  ## ``OSError`` for a TLS failure.
  ##
  ## Over TLS it returns as soon as some bytes are available. Plain HTTP
  ## goes through ``net``'s timed ``recv``, which waits for data before
  ## each read and so never blocks, and fills ``size`` bytes unless the
  ## peer closes first.
  when defined(ssl):
    if sock.isSsl:
      while true:
        ErrClearError()
        let ret = SSL_read(sock.sslHandle, data, size)
        if ret > 0:
          return int(ret)
        if awaitTls(sock, ret, deadline) == tsClosed:
          return 0
  let remainingMs = (deadline - getMonoTime()).inMilliseconds
  if remainingMs <= 0:
    raise newException(TimeoutError, "recv timed out")
  sock.recv(data, size, timeout = int(remainingMs))

proc millisFromNow(ms: int): MonoTime =
  getMonoTime() + initDuration(milliseconds = ms)

proc leaseConnection(pool: HttpPool; host: string; port: Port;
                     secure: bool): PooledConnection =
  ## Returns a cached connection for the (host, port) tuple if one is
  ## idle, otherwise opens a fresh socket. The transient case (pool
  ## full) skips the cache and is closed by the caller after the
  ## request finishes — never added back to ``pool.connections``.
  for c in pool.connections:
    if not c.inUse and c.host == host and c.port == port and c.secure == secure:
      c.inUse = true
      return c
  let sock = newSocket(AF_INET)
  try:
    connectWithDeadline(sock, AF_INET, host, port, pool.connectTimeoutMs)
    # Every socket the pool uses is non-blocking from here on: each read
    # and write waits in ``awaitIo`` for at most the time its deadline
    # leaves, and nothing else can block.
    sock.getFd().setBlocking(false)
  except TimeoutError:
    try: sock.close() except CatchableError: discard
    raise newException(HttpError,
      "connect to " & host & ":" & $int(port) & " timed out after " &
      $pool.connectTimeoutMs & "ms")
  except OSError as e:
    try: sock.close() except CatchableError: discard
    raise newException(HttpError,
      "connect to " & host & ":" & $int(port) & " failed: " & e.msg)
  if secure:
    when defined(ssl):
      try:
        tlsHandshakeBefore(sock, host, millisFromNow(pool.receiveTimeoutMs))
      except TimeoutError:
        try: sock.close() except CatchableError: discard
        raise newException(HttpError,
          "TLS handshake to " & host & ":" & $int(port) &
          " timed out after " & $pool.receiveTimeoutMs & "ms")
      except CatchableError as e:
        try: sock.close() except CatchableError: discard
        raise newException(HttpError,
          "TLS handshake to " & host & ":" & $int(port) & " failed: " & e.msg)
    else:
      try: sock.close() except CatchableError: discard
      raise newException(HttpError,
        "https:// requires a build with -d:ssl; this binary is HTTP-only")
  result = PooledConnection(sock: sock, host: host, port: port,
                            secure: secure, inUse: true)
  if pool.connections.len < pool.maxConnections:
    pool.connections.add(result)
  # else: transient, not pooled.

proc releaseConnection(pool: HttpPool; conn: PooledConnection;
                       reusable: bool) =
  ## Marks the connection idle for reuse, or closes it (and drops it
  ## from the pool) if the response left the stream in a non-reusable
  ## state (e.g. ``Connection: close``, error).
  if conn.isNil:
    return
  if not reusable:
    try: conn.sock.close() except CatchableError: discard
    var keep: seq[PooledConnection] = @[]
    for c in pool.connections:
      if c != conn:
        keep.add(c)
    pool.connections = keep
    return
  conn.inUse = false

# ---------------------------------------------------------------------------
# Line-oriented header read (small buffer; not on the payload hot path)
# ---------------------------------------------------------------------------

proc readLineBefore(sock: Socket; deadline: MonoTime; timeoutMs: int;
                    what: string): string =
  ## Reads a ``\r\n``-terminated line, raising ``HttpError`` once
  ## ``deadline`` (on the monotonic clock) has passed; ``timeoutMs`` and
  ## ``what`` only word that error. We hand-roll the byte-at-a-time loop
  ## instead of using ``net.readLine`` because the std implementation
  ## peeks via ``peekChar`` after each ``\r`` which has surprised us with
  ## phantom EOF events on Windows winsock under back-to-back keep-alive
  ## responses. Our loop reads one byte at a time and tolerates
  ## ``\n``-only line terminators (some HTTP/1.0 servers emit them after
  ## a ``Connection: close``).
  ##
  ## Each byte is read with ``recvBefore``, which returns before
  ## ``deadline`` however the peer spaces out its bytes, over TLS as well.
  result = ""
  var c: char
  while true:
    let remainingMs = (deadline - getMonoTime()).inMilliseconds
    if remainingMs <= 0:
      raise newException(HttpError, what & " timed out after " &
        $timeoutMs & "ms")
    var n = 0
    try:
      n = recvBefore(sock, addr c, 1, deadline)
    except TimeoutError:
      raise newException(HttpError, what & " timed out after " &
        $timeoutMs & "ms")
    except OSError as e:
      raise newException(HttpError, what & " failed: " & e.msg)
    if n == 0:
      # Peer closed; return whatever we have. Header parsing decides
      # whether it's a fatal premature EOF.
      return result
    if n < 0:
      raise newException(HttpError, what & " failed: recv returned " & $n)
    if c == '\n':
      # Strip trailing \r if any.
      if result.len > 0 and result[^1] == '\r':
        result.setLen(result.len - 1)
      return result
    result.add(c)
    if result.len > 65536:
      raise newException(HttpError, "header line exceeds 64 KiB")

proc readLineWithTimeout(sock: Socket; timeoutMs: int): string =
  ## A line of chunked framing (a chunk-size line, a trailer, the CRLF
  ## after a chunk), which must arrive within ``timeoutMs``.
  readLineBefore(sock, millisFromNow(timeoutMs), timeoutMs,
                 "chunk framing read")

proc readHeaders(sock: Socket; timeoutMs: int):
    tuple[statusCode: int; headers: seq[(string, string)]] =
  ## Reads the status line and headers, which must all arrive within
  ## ``timeoutMs``: one deadline for the block, so a peer that sends a
  ## header line now and then cannot hold the caller longer than a peer
  ## that sends nothing.
  let deadline = millisFromNow(timeoutMs)
  let statusLine = readLineBefore(sock, deadline, timeoutMs, "header read")
  if not statusLine.startsWith("HTTP/"):
    raise newException(HttpError,
      "malformed status line: " & statusLine.escape())
  let firstSpace = statusLine.find(' ')
  if firstSpace < 0:
    raise newException(HttpError, "no status code in: " & statusLine)
  var code = 0
  discard parseInt(statusLine, code, firstSpace + 1)
  result.statusCode = code
  result.headers = @[]
  while true:
    let line = readLineBefore(sock, deadline, timeoutMs, "header read")
    if line.len == 0:
      break
    let colon = line.find(':')
    if colon < 0:
      continue
    let name = line[0 ..< colon].strip().toLowerAscii()
    let value = line[colon + 1 .. ^1].strip()
    result.headers.add((name, value))

proc headerValue(headers: seq[(string, string)]; name: string): string =
  let lname = name.toLowerAscii()
  for (k, v) in headers:
    if k == lname:
      return v
  return ""

# ---------------------------------------------------------------------------
# Streaming body drain
# ---------------------------------------------------------------------------

proc drainContentLength(sock: Socket; total: int64;
                        buf: var seq[byte];
                        callback: StreamChunkCallback;
                        timeoutMs: int): int64 =
  ## Reads exactly ``total`` bytes from the socket, firing ``callback``
  ## for each TCP read. Returns the total bytes received (which equals
  ## ``total`` on success).
  result = 0
  if total == 0:
    return 0
  let chunkSize = if buf.len > 0: buf.len else: 65536
  if buf.len == 0:
    buf.setLen(65536)
  while result < total:
    let want = int(min(int64(chunkSize), total - result))
    var bytesRead = 0
    try:
      bytesRead = recvBefore(sock, buf[0].addr, want, millisFromNow(timeoutMs))
    except TimeoutError:
      raise newException(HttpError, "body read timed out")
    except OSError as e:
      raise newException(HttpError, "body read failed: " & e.msg)
    if bytesRead <= 0:
      raise newException(HttpError,
        "upstream closed connection early at " & $result & " / " &
        $total & " bytes")
    callback(buf.toOpenArray(0, bytesRead - 1))
    result += int64(bytesRead)

proc drainChunked(sock: Socket;
                  buf: var seq[byte];
                  callback: StreamChunkCallback;
                  timeoutMs: int): int64 =
  ## Decodes ``Transfer-Encoding: chunked``. Each chunk has a hex-
  ## sized length line + ``\r\n`` + payload + ``\r\n``. Empty length
  ## line marks EOF (after which we tolerate but discard any trailers).
  result = 0
  if buf.len == 0:
    buf.setLen(65536)
  while true:
    let sizeLine = readLineWithTimeout(sock, timeoutMs)
    let semi = sizeLine.find(';')
    let sizeHex = if semi >= 0: sizeLine[0 ..< semi].strip() else: sizeLine.strip()
    if sizeHex.len == 0:
      raise newException(HttpError, "empty chunk-size line")
    var chunkSize = 0
    discard parseHex(sizeHex, chunkSize)
    if chunkSize == 0:
      # Drain trailer headers (just consume up to blank line).
      while true:
        let trailer = readLineWithTimeout(sock, timeoutMs)
        if trailer.len == 0:
          break
      return result
    var remaining = chunkSize
    while remaining > 0:
      let want = min(buf.len, remaining)
      var bytesRead = 0
      try:
        bytesRead = recvBefore(sock, buf[0].addr, want, millisFromNow(timeoutMs))
      except TimeoutError:
        raise newException(HttpError, "chunk body read timed out")
      except OSError as e:
        raise newException(HttpError, "chunk body read failed: " & e.msg)
      if bytesRead <= 0:
        raise newException(HttpError,
          "upstream closed mid-chunk at " & $(chunkSize - remaining) &
          " / " & $chunkSize)
      callback(buf.toOpenArray(0, bytesRead - 1))
      result += int64(bytesRead)
      remaining -= bytesRead
    # Trailing CRLF after each chunk.
    let trailing = readLineWithTimeout(sock, timeoutMs)
    if trailing.len != 0:
      raise newException(HttpError,
        "expected blank CRLF after chunk, got " & trailing.escape())

proc drainUntilClose(sock: Socket;
                     buf: var seq[byte];
                     callback: StreamChunkCallback;
                     timeoutMs: int): int64 =
  ## Fallback for HTTP/1.0-style responses without ``Content-Length``
  ## and without chunking. Reads until the peer closes the socket. Not
  ## reusable afterwards (returns ``reusable=false``).
  result = 0
  if buf.len == 0:
    buf.setLen(65536)
  while true:
    var bytesRead = 0
    try:
      bytesRead = recvBefore(sock, buf[0].addr, buf.len, millisFromNow(timeoutMs))
    except TimeoutError:
      raise newException(HttpError, "body read timed out")
    except OSError:
      break
    if bytesRead <= 0:
      break
    callback(buf.toOpenArray(0, bytesRead - 1))
    result += int64(bytesRead)

# ---------------------------------------------------------------------------
# Public GET — the streaming entry point
# ---------------------------------------------------------------------------

proc sendRequest(sock: Socket; req: string; timeoutMs: int) =
  ## Sends a request, which must be on its way within ``timeoutMs``.
  try:
    sendBefore(sock, req, millisFromNow(timeoutMs))
  except TimeoutError:
    raise newException(HttpError,
      "send request timed out after " & $timeoutMs & "ms")
  except OSError as e:
    raise newException(HttpError, "send request failed: " & e.msg)

proc requestStatusOnly*(pool: HttpPool; meth, url: string;
                        extraHeaders: seq[(string, string)] = @[]):
    tuple[statusCode: int; location: string] =
  ## Issue ``meth url`` (``HEAD``, or a ``GET`` with a ``Range``) and read
  ## the status line and headers only: the body is never read, and the
  ## connection is dropped, not reused, so a server that ignores ``Range``
  ## and sends a whole file costs nothing. For a probe of whether a URL is
  ## served.
  let parsed = parseTarget(url)
  let conn = pool.leaseConnection(parsed.host, parsed.port, parsed.secure)
  try:
    var req = meth & " " & parsed.path & " HTTP/1.1\r\n" &
              "Host: " & parsed.host
    if int(parsed.port) != (if parsed.secure: 443 else: 80):
      req.add(":" & $int(parsed.port))
    req.add("\r\nUser-Agent: repro-binary-cache-client/0.1\r\n" &
            "Accept: */*\r\nConnection: close\r\n")
    for (name, value) in extraHeaders:
      req.add(name & ": " & value & "\r\n")
    req.add("\r\n")
    conn.sock.sendRequest(req, pool.receiveTimeoutMs)
    let (statusCode, headers) = readHeaders(conn.sock, pool.receiveTimeoutMs)
    result = (statusCode, headerValue(headers, "location"))
  finally:
    pool.releaseConnection(conn, reusable = false)

proc streamGet*(pool: HttpPool; url: string;
                callback: StreamChunkCallback;
                reuseBuffer: var seq[byte];
                extraHeaders: seq[(string, string)] = @[];
                maxBodyBytes = -1'i64):
                  StreamResponse =
  ## Issues ``GET url`` and pipes the response body through ``callback``
  ## as bytes arrive. ``reuseBuffer`` is the receive ring buffer — the
  ## caller supplies a pre-allocated ``seq[byte]`` (typically 256 KiB)
  ## so we don't allocate per substitute. Returns the response
  ## descriptor; ``bytesReceived`` lets the caller assert the wire-size
  ## against the manifest's declared payload size.
  ##
  ## ``maxBodyBytes`` (when non-negative) bounds a 2xx body: a
  ## ``Content-Length`` above it is refused before a byte of the body is
  ## read, and a chunked or unterminated body is refused at the first byte
  ## past it. Either refusal is an ``HttpError`` raised from inside the
  ## drain, so the connection is dropped, not reused. The callback never
  ## sees a byte beyond the cap.
  let parsed = parseTarget(url)
  let conn = pool.leaseConnection(parsed.host, parsed.port, parsed.secure)
  var reusable = false
  var resp = StreamResponse(statusCode: 0, contentLength: -1,
                            bytesReceived: 0, chunked: false)
  try:
    # ---- Request ----
    var req = "GET " & parsed.path & " HTTP/1.1\r\n" &
              "Host: " & parsed.host
    if int(parsed.port) != (if parsed.secure: 443 else: 80):
      req.add(":" & $int(parsed.port))
    req.add("\r\nUser-Agent: repro-binary-cache-client/0.1\r\n" &
            "Accept: */*\r\n" &
            "Connection: keep-alive\r\n")
    for (name, value) in extraHeaders:
      req.add(name & ": " & value & "\r\n")
    req.add("\r\n")
    conn.sock.sendRequest(req, pool.receiveTimeoutMs)

    # ---- Response headers ----
    let (statusCode, headers) =
      readHeaders(conn.sock, pool.receiveTimeoutMs)
    resp.statusCode = statusCode
    resp.location = headerValue(headers, "location")

    let teRaw = headerValue(headers, "transfer-encoding").toLowerAscii()
    let connHdr = headerValue(headers, "connection").toLowerAscii()
    resp.chunked = teRaw.contains("chunked")
    let clenRaw = headerValue(headers, "content-length")
    if clenRaw.len > 0 and not resp.chunked:
      var clen = 0'i64
      try: clen = parseBiggestInt(clenRaw).int64 except CatchableError: clen = -1
      resp.contentLength = clen
    # Non-2xx responses still drain their body so the connection is
    # reusable. We surface the status code to the caller; the caller
    # decides whether to act on the bytes.
    if resp.statusCode >= 200 and resp.statusCode < 300:
      if maxBodyBytes >= 0 and resp.contentLength > maxBodyBytes:
        raise newException(HttpError, "response body of " &
          $resp.contentLength & " bytes exceeds the " & $maxBodyBytes &
          "-byte cap for " & url)
      var received = 0'i64
      let cappedCallback: StreamChunkCallback =
        if maxBodyBytes < 0: callback
        else: (proc(chunk: openArray[byte]) {.gcsafe.} =
          received += int64(chunk.len)
          if received > maxBodyBytes:
            raise newException(HttpError, "response body exceeds the " &
              $maxBodyBytes & "-byte cap for " & url)
          callback(chunk))
      if resp.chunked:
        resp.bytesReceived = drainChunked(
          conn.sock, reuseBuffer, cappedCallback, pool.receiveTimeoutMs)
        reusable = not connHdr.contains("close")
      elif resp.contentLength >= 0:
        resp.bytesReceived = drainContentLength(
          conn.sock, resp.contentLength, reuseBuffer, cappedCallback,
          pool.receiveTimeoutMs)
        reusable = not connHdr.contains("close")
      else:
        # No content-length, no chunked => drain until close. Not
        # reusable.
        resp.bytesReceived = drainUntilClose(
          conn.sock, reuseBuffer, cappedCallback, pool.receiveTimeoutMs)
        reusable = false
    else:
      # Drain error body into a throwaway buffer so the connection stays
      # in a known state. The buffer keeps at most 64 KiB, and the read
      # itself stops at 64 KiB too: a server that answers an error with an
      # endless body would otherwise keep this call busy until the socket
      # timed out, so past the cap the drain raises and the connection is
      # dropped rather than reused.
      const ErrorBodyCap = 65536
      var sink = newSeq[byte](0)
      var drained = 0
      let drainCb: StreamChunkCallback = proc(chunk: openArray[byte]) =
        drained += chunk.len
        if drained > ErrorBodyCap:
          raise newException(HttpError, "error response body exceeds " &
            $ErrorBodyCap & " bytes for " & url & " (HTTP " &
            $resp.statusCode & ")")
        if sink.len < ErrorBodyCap:
          let want = min(chunk.len, ErrorBodyCap - sink.len)
          for i in 0 ..< want:
            sink.add(chunk[i])
      if resp.chunked:
        discard drainChunked(conn.sock, reuseBuffer, drainCb,
                             pool.receiveTimeoutMs)
        reusable = not connHdr.contains("close")
      elif resp.contentLength >= 0:
        if resp.contentLength > ErrorBodyCap:
          raise newException(HttpError, "error response body of " &
            $resp.contentLength & " bytes exceeds " & $ErrorBodyCap &
            " for " & url & " (HTTP " & $resp.statusCode & ")")
        discard drainContentLength(
          conn.sock, resp.contentLength, reuseBuffer, drainCb,
          pool.receiveTimeoutMs)
        reusable = not connHdr.contains("close")
      else:
        discard drainUntilClose(
          conn.sock, reuseBuffer, drainCb, pool.receiveTimeoutMs)
        reusable = false
  except CatchableError as e:
    pool.releaseConnection(conn, reusable = false)
    raise e
  pool.releaseConnection(conn, reusable = reusable)
  return resp

proc getEntireBody*(pool: HttpPool; url: string;
                    extraHeaders: seq[(string, string)] = @[]):
                      tuple[statusCode: int; body: seq[byte]] =
  ## Convenience for callers that DO need the whole body in RAM —
  ## manifests, ``/cache-info``. NOT used on the payload hot path.
  var sink: seq[byte] = @[]
  var buf = newSeq[byte](32768)
  let cb: StreamChunkCallback = proc(chunk: openArray[byte]) =
    let startLen = sink.len
    sink.setLen(startLen + chunk.len)
    if chunk.len > 0:
      copyMem(addr sink[startLen], unsafeAddr chunk[0], chunk.len)
  let resp = streamGet(pool, url, cb, buf, extraHeaders)
  result.statusCode = resp.statusCode
  result.body = sink

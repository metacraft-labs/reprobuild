## The binary-cache client gives up on a cache that accepts a connection
## and then does not answer, within the pool's receive deadline.
##
## A wedged cache process, or a proxy or load balancer that accepts and
## then waits on a dead upstream, completes the TCP connect and then sends
## nothing. The connect deadline does not help there: the connect
## succeeded. What has to be bounded is everything after it — the TLS
## handshake, the status line and headers, and the chunked framing.
##
## The silent peers are real loopback sockets, not mocks. A listener that
## never calls ``accept`` still completes the connect in the kernel (the
## connection waits in the accept queue), so the client's reads really do
## block in ``recv`` with nothing to read. The trickling and stalling
## peers are a thread that accepts and writes a scripted response.
##
## Built with ``-d:ssl`` so the TLS handshake against a silent peer is
## exercised the way the shipped ``repro`` binary performs it.
##
## Over TLS, a deadline has to hold against a peer that sends a TLS record
## a byte at a time, each byte well inside the deadline: OpenSSL keeps
## reading until it has a whole record, so a bound on each wait for data
## does not bound the read. The TLS peer here is a real OpenSSL server
## (a self-signed certificate minted with the ``openssl`` CLI, present in
## the reprobuild dev shell), driven through memory BIOs so the test
## controls when each encrypted byte reaches the socket. Nothing in the
## client is replaced.

import std/[monotimes, nativesockets, net, os, osproc, strutils, times,
            unittest]
import wrappers/openssl

when defined(windows):
  import std/winlean
else:
  import std/posix

import ../src/repro_binary_cache_client

type
  ScriptStep = tuple[delayMs: int; bytes: string]
  ScriptedPeer = object
    ## Accepts one connection on ``listenFd`` and writes each step's
    ## bytes after its delay, then holds the connection open for
    ## ``holdMs`` without writing.
    listenFd: int
    steps: seq[ScriptStep]
    holdMs: int

proc sendAll(conn: SocketHandle; bytes: string): bool =
  var sent = 0
  while sent < bytes.len:
    let n =
      when defined(windows):
        int(winlean.send(conn, unsafeAddr bytes[sent], cint(bytes.len - sent), 0))
      else:
        posix.send(conn, unsafeAddr bytes[sent], bytes.len - sent, 0'i32)
    if n <= 0:
      return false
    sent += n
  true

proc runScriptedPeer(peer: ScriptedPeer) {.thread.} =
  let (conn, _) = accept(SocketHandle(peer.listenFd))
  if conn == osInvalidSocket:
    return
  for step in peer.steps:
    sleep(step.delayMs)
    if not conn.sendAll(step.bytes):
      break
  sleep(peer.holdMs)
  conn.close()

# Memory-BIO server calls the standard library's OpenSSL wrapper does not
# declare. https://docs.openssl.org/3.0/man3/SSL_set_bio/ and
# https://docs.openssl.org/3.0/man3/SSL_do_handshake/
proc SSL_set_bio(ssl: SslPtr; rbio, wbio: BIO) {.cdecl, dynlib: DLLSSLName,
    importc.}
proc SSL_set_accept_state(ssl: SslPtr) {.cdecl, dynlib: DLLSSLName, importc.}
proc SSL_do_handshake(ssl: SslPtr): cint {.cdecl, dynlib: DLLSSLName, importc.}

type
  TlsPeer = object
    ## Accepts one connection on ``listenFd``, completes a TLS handshake
    ## as the server, then encrypts ``response`` and writes the encrypted
    ## bytes one at a time, ``byteDelayMs`` apart (all at once when 0),
    ## then holds the connection open for ``holdMs``.
    listenFd: int
    certFile, keyFile: string
    response: string
    byteDelayMs: int
    holdMs: int

proc flushBio(wbio: BIO; conn: SocketHandle; byteDelayMs = 0): bool =
  ## Sends everything OpenSSL has written into ``wbio``.
  var buf = newString(16384)
  while true:
    let n = BIO_read(wbio, cstring(buf), cint(buf.len))
    if n <= 0:
      return true
    if byteDelayMs == 0:
      if not conn.sendAll(buf[0 ..< n]):
        return false
    else:
      for i in 0 ..< n:
        sleep(byteDelayMs)
        if not conn.sendAll(buf[i .. i]):
          return false

proc runTlsPeer(peer: TlsPeer) {.thread.} =
  let (conn, _) = accept(SocketHandle(peer.listenFd))
  if conn == osInvalidSocket:
    return
  defer: conn.close()
  let ctx = newContext(verifyMode = CVerifyNone, certFile = peer.certFile,
                       keyFile = peer.keyFile)
  let ssl = SSL_new(ctx.context)
  let rbio = bioNew(bioSMem())
  let wbio = bioNew(bioSMem())
  SSL_set_bio(ssl, rbio, wbio)
  SSL_set_accept_state(ssl)
  var buf = newString(16384)
  while true:
    let rc = SSL_do_handshake(ssl)
    if not wbio.flushBio(conn):
      return
    if rc == 1:
      break
    if SSL_get_error(ssl, rc) != SSL_ERROR_WANT_READ:
      return
    let n =
      when defined(windows):
        int(winlean.recv(conn, addr buf[0], cint(buf.len), 0))
      else:
        posix.recv(conn, addr buf[0], buf.len, 0'i32)
    if n <= 0:
      return
    discard BIO_write(rbio, cstring(buf), cint(n))
  if SSL_write(ssl, cstring(peer.response), cint(peer.response.len)) <= 0:
    return
  discard wbio.flushBio(conn, peer.byteDelayMs)
  sleep(peer.holdMs)
  SSL_free(ssl)

proc selfSignedCert(dnsName = ""): tuple[cert, key: string] =
  ## A throwaway certificate and key in a fresh temporary directory, which
  ## the caller removes. With ``dnsName`` the certificate names that host,
  ## so the client's host-name check has something to compare.
  let dir = getTempDir() / ("t_cache_reads_are_bounded_" &
                            $getCurrentProcessId() & "_" & dnsName)
  createDir(dir)
  result = (dir / "cert.pem", dir / "key.pem")
  let subject =
    if dnsName.len == 0: "-subj /CN=127.0.0.1"
    else: "-subj /CN=" & dnsName & " -addext subjectAltName=DNS:" & dnsName
  let (output, code) = execCmdEx(
    "openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 " &
    "-nodes -keyout " & quoteShell(result.key) & " -out " &
    quoteShell(result.cert) & " -days 1 " & subject)
  doAssert code == 0, "openssl could not mint a test certificate: " & output

proc listenLoopback(): tuple[sock: Socket; port: Port] =
  ## A loopback listener whose connects complete in the kernel whether or
  ## not anything ever accepts them.
  result.sock = newSocket()
  result.sock.setSockOpt(OptReuseAddr, true)
  result.sock.bindAddr(Port(0), "127.0.0.1")
  result.sock.listen()
  result.port = result.sock.getLocalAddr()[1]

proc elapsedSeconds(start: MonoTime): float =
  float((getMonoTime() - start).inMilliseconds) / 1000.0

proc discardChunk(chunk: openArray[byte]) {.gcsafe.} = discard

proc streamGetError(pool: HttpPool; url: string): string =
  ## Runs ``streamGet`` and returns the ``HttpError`` message it raised,
  ## or ``""`` if it returned.
  var buf = newSeq[byte](4096)
  try:
    discard pool.streamGet(url, discardChunk, buf)
  except HttpError as e:
    return e.msg
  ""

suite "binary-cache client reads after the connect are bounded":
  test "a cache that accepts and never answers fails the header read in time":
    let (listener, port) = listenLoopback()
    defer: listener.close()
    let url = "http://127.0.0.1:" & $int(port) & "/cache-info"
    let pool = newHttpPool(receiveTimeoutMs = 400)
    defer: pool.close()

    var start = getMonoTime()
    let message = pool.streamGetError(url)
    var took = elapsedSeconds(start)
    check "header read timed out after 400ms" in message
    # It waited for the deadline (so the silence really held it) and no
    # longer than the deadline plus scheduling slack.
    check took >= 0.35
    check took < 3.0

    # The status-only probe reads the same headers the same way.
    start = getMonoTime()
    var probeMessage = ""
    try:
      discard pool.requestStatusOnly("HEAD", url)
    except HttpError as e:
      probeMessage = e.msg
    took = elapsedSeconds(start)
    check "header read timed out after 400ms" in probeMessage
    check took >= 0.35
    check took < 3.0

  test "headers sent a line at a time cannot outlast the header deadline":
    # Every line arrives well inside the deadline, but the block never
    # ends: one deadline for the whole block, not one per line, is what
    # bounds this.
    let (listener, port) = listenLoopback()
    defer: listener.close()
    var steps: seq[ScriptStep] = @[(0, "HTTP/1.1 200 OK\r\n")]
    for i in 0 ..< 40:
      steps.add((150, "X-Filler-" & $i & ": 1\r\n"))
    var peer: Thread[ScriptedPeer]
    createThread(peer, runScriptedPeer, ScriptedPeer(
      listenFd: int(listener.getFd()), steps: steps, holdMs: 0))
    let pool = newHttpPool(receiveTimeoutMs = 600)
    let start = getMonoTime()
    let message = pool.streamGetError("http://127.0.0.1:" & $int(port) & "/")
    let took = elapsedSeconds(start)
    pool.close()
    joinThread(peer)
    check "header read timed out after 600ms" in message
    check took >= 0.55
    check took < 3.0

  test "a chunked body whose framing stalls fails within the deadline":
    let (listener, port) = listenLoopback()
    defer: listener.close()
    var peer: Thread[ScriptedPeer]
    createThread(peer, runScriptedPeer, ScriptedPeer(
      listenFd: int(listener.getFd()),
      steps: @[(0, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")],
      holdMs: 4000))
    let pool = newHttpPool(receiveTimeoutMs = 400)
    let start = getMonoTime()
    let message = pool.streamGetError("http://127.0.0.1:" & $int(port) & "/")
    let took = elapsedSeconds(start)
    pool.close()
    joinThread(peer)
    check "chunk framing read timed out after 400ms" in message
    check took >= 0.35
    check took < 3.0

  test "a TLS handshake with a cache that never answers fails in time":
    # The handshake never gets far enough for a certificate to matter;
    # trusting any certificate keeps the test independent of the host's
    # CA bundle.
    putEnv("REPRO_BINARY_CACHE_TLS_INSECURE", "1")
    let (listener, port) = listenLoopback()
    defer: listener.close()
    let pool = newHttpPool(receiveTimeoutMs = 400)
    defer: pool.close()
    let start = getMonoTime()
    let message = pool.streamGetError("https://127.0.0.1:" & $int(port) & "/")
    let took = elapsedSeconds(start)
    check ("TLS handshake to 127.0.0.1:" & $int(port) &
           " timed out after 400ms") in message
    check took >= 0.35
    check took < 3.0

  test "a TLS handshake sent a byte at a time cannot outlast the deadline":
    # A TLS record header announcing a 16 KiB handshake record, then its
    # body a byte every 100ms: every wait for data ends well inside the
    # deadline, and OpenSSL keeps reading until the record is whole.
    putEnv("REPRO_BINARY_CACHE_TLS_INSECURE", "1")
    let (listener, port) = listenLoopback()
    defer: listener.close()
    var steps: seq[ScriptStep] = @[(0, "\x16\x03\x03\x40\x00")]
    for i in 0 ..< 80:
      steps.add((100, "\x00"))
    var peer: Thread[ScriptedPeer]
    createThread(peer, runScriptedPeer, ScriptedPeer(
      listenFd: int(listener.getFd()), steps: steps, holdMs: 0))
    let pool = newHttpPool(receiveTimeoutMs = 500)
    let start = getMonoTime()
    let message = pool.streamGetError("https://127.0.0.1:" & $int(port) & "/")
    let took = elapsedSeconds(start)
    pool.close()
    joinThread(peer)
    check ("TLS handshake to 127.0.0.1:" & $int(port) &
           " timed out after 500ms") in message
    check took >= 0.45
    check took < 3.0

  test "a TLS handshake the peer refuses at once is not called a timeout":
    putEnv("REPRO_BINARY_CACHE_TLS_INSECURE", "1")
    let (listener, port) = listenLoopback()
    defer: listener.close()
    var peer: Thread[ScriptedPeer]
    createThread(peer, runScriptedPeer, ScriptedPeer(
      listenFd: int(listener.getFd()),
      steps: @[(0, "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")],
      holdMs: 0))
    let pool = newHttpPool(receiveTimeoutMs = 2000)
    let start = getMonoTime()
    let message = pool.streamGetError("https://127.0.0.1:" & $int(port) & "/")
    let took = elapsedSeconds(start)
    pool.close()
    joinThread(peer)
    check ("TLS handshake to 127.0.0.1:" & $int(port) & " failed: ") in message
    check "timed out" notin message
    check took < 1.5

  test "headers sent a byte at a time inside a TLS record cannot outlast the header deadline":
    # The handshake completes promptly; then the status line and headers,
    # one TLS record, reach the socket a byte every 100ms. The record is
    # well over 60 bytes, so a read bounded only per wait would take more
    # than 6s.
    putEnv("REPRO_BINARY_CACHE_TLS_INSECURE", "1")
    let (cert, key) = selfSignedCert()
    defer: removeDir(cert.parentDir)
    let (listener, port) = listenLoopback()
    defer: listener.close()
    var peer: Thread[TlsPeer]
    createThread(peer, runTlsPeer, TlsPeer(
      listenFd: int(listener.getFd()), certFile: cert, keyFile: key,
      response: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n" &
                "X-Filler: " & repeat('a', 40) & "\r\n\r\n",
      byteDelayMs: 100, holdMs: 0))
    let pool = newHttpPool(receiveTimeoutMs = 800)
    let start = getMonoTime()
    let message = pool.streamGetError("https://127.0.0.1:" & $int(port) & "/")
    let took = elapsedSeconds(start)
    pool.close()
    joinThread(peer)
    check "header read timed out after 800ms" in message
    check took >= 0.75
    check took < 3.0

  test "a TLS cache that answers promptly is still read in full":
    putEnv("REPRO_BINARY_CACHE_TLS_INSECURE", "1")
    let (cert, key) = selfSignedCert()
    defer: removeDir(cert.parentDir)
    let (listener, port) = listenLoopback()
    defer: listener.close()
    var peer: Thread[TlsPeer]
    createThread(peer, runTlsPeer, TlsPeer(
      listenFd: int(listener.getFd()), certFile: cert, keyFile: key,
      response: "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n" &
                "Connection: close\r\n\r\n5\r\nhello\r\n" &
                "6\r\n world\r\n0\r\n\r\n",
      byteDelayMs: 0, holdMs: 200))
    let pool = newHttpPool(receiveTimeoutMs = 2000)
    let (status, body) = pool.getEntireBody("https://127.0.0.1:" & $int(port) & "/")
    pool.close()
    joinThread(peer)
    check status == 200
    check cast[string](body) == "hello world"

  test "the TLS handshake still checks the certificate names the host":
    # The handshake is driven by the pool rather than by
    # ``net.wrapConnectedSocket``, so the pool carries its own copy of the
    # host-name check. A certificate for the host is accepted and one for
    # another name is refused, even with chain verification off (as
    # ``wrapConnectedSocket`` does).
    putEnv("REPRO_BINARY_CACHE_TLS_INSECURE", "1")
    for (certName, accepted) in [("localhost", true),
                                 ("other.invalid", false)]:
      let (cert, key) = selfSignedCert(certName)
      defer: removeDir(cert.parentDir)
      let (listener, port) = listenLoopback()
      defer: listener.close()
      var peer: Thread[TlsPeer]
      createThread(peer, runTlsPeer, TlsPeer(
        listenFd: int(listener.getFd()), certFile: cert, keyFile: key,
        response: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n" &
                  "Connection: close\r\n\r\nok",
        byteDelayMs: 0, holdMs: 200))
      let pool = newHttpPool(receiveTimeoutMs = 2000)
      let message = pool.streamGetError("https://localhost:" & $int(port) & "/")
      pool.close()
      joinThread(peer)
      if accepted or defined(windows):
        # ``std/net`` skips the host-name check on Windows, and the copy
        # keeps that condition.
        check message == ""
      else:
        check ("TLS handshake to localhost:" & $int(port) &
               " failed: SSL Certificate check failed.") in message

  test "a request the cache never reads fails the send in time":
    # A listener that never accepts never reads either, so once the
    # socket buffers on both ends are full the request cannot be sent.
    # 32 MiB of header is far more than loopback buffers hold.
    let (listener, port) = listenLoopback()
    defer: listener.close()
    let pool = newHttpPool(receiveTimeoutMs = 400)
    defer: pool.close()
    var buf = newSeq[byte](4096)
    let start = getMonoTime()
    var message = ""
    try:
      discard pool.streamGet("http://127.0.0.1:" & $int(port) & "/",
                             discardChunk, buf,
                             extraHeaders = @[("X-Filler", repeat('a', 32 shl 20))])
    except HttpError as e:
      message = e.msg
    let took = elapsedSeconds(start)
    check "send request timed out after 400ms" in message
    check took >= 0.35
    check took < 3.0

  test "a receive deadline that is not positive is refused":
    # Without one nothing after the connect would be bounded.
    expect ValueError:
      discard newHttpPool(receiveTimeoutMs = 0)
    expect ValueError:
      discard newHttpPool(receiveTimeoutMs = -1)

  test "a cache that answers promptly is still read in full":
    let (listener, port) = listenLoopback()
    defer: listener.close()
    var peer: Thread[ScriptedPeer]
    createThread(peer, runScriptedPeer, ScriptedPeer(
      listenFd: int(listener.getFd()),
      steps: @[(0, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n" &
                   "Connection: close\r\n\r\n5\r\nhello\r\n0\r\n\r\n")],
      holdMs: 0))
    let pool = newHttpPool(receiveTimeoutMs = 2000)
    let (status, body) = pool.getEntireBody("http://127.0.0.1:" & $int(port) & "/")
    pool.close()
    joinThread(peer)
    check status == 200
    check cast[string](body) == "hello"

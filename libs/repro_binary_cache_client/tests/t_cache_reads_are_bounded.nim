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

import std/[monotimes, nativesockets, net, os, strutils, times, unittest]

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

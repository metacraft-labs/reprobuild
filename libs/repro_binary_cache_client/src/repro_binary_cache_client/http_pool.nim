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

import std/[net, os, parseutils, strutils, times, uri]

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
      ## Per-read deadline; surfaced as ``HttpError`` if the upstream
      ## stalls. 30s default — large payloads on slow links still fit.

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

const
  DefaultMaxConnections = 16
  DefaultReceiveTimeoutMs = 30_000

proc newHttpPool*(maxConnections = DefaultMaxConnections;
                  receiveTimeoutMs = DefaultReceiveTimeoutMs): HttpPool =
  HttpPool(
    connections: @[],
    maxConnections: maxConnections,
    receiveTimeoutMs: receiveTimeoutMs)

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
  ## Splits the URL into host / port / path. We only support HTTP in
  ## A2.5; HTTPS slot is reserved for the follow-up.
  let u = parseUri(url)
  if u.scheme.toLowerAscii() notin ["http", "https"]:
    raise newException(HttpError, "unsupported scheme: " & u.scheme)
  result.secure = u.scheme.toLowerAscii() == "https"
  if result.secure:
    raise newException(HttpError,
      "A2.5 ships HTTP only; HTTPS is reserved for a follow-up")
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
  let sock = newSocket()
  try:
    sock.connect(host, port)
  except OSError as e:
    raise newException(HttpError,
      "connect to " & host & ":" & $int(port) & " failed: " & e.msg)
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

proc readLineWithTimeout(sock: Socket; timeoutMs: int): string =
  ## Reads ``\r\n``-terminated header line. We hand-roll the byte-at-
  ## a-time loop instead of using ``net.readLine`` because the std
  ## implementation peeks via ``peekChar`` after each ``\r`` which has
  ## surprised us with phantom EOF events on Windows winsock under
  ## back-to-back keep-alive responses. Our loop reads one byte at a
  ## time and tolerates ``\n``-only line terminators (some HTTP/1.0
  ## servers emit them after a ``Connection: close``).
  result = ""
  var c: char
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  while epochTime() < deadline:
    var n = 0
    try:
      n = sock.recv(addr c, 1)
    except OSError as e:
      raise newException(HttpError, "header read failed: " & e.msg)
    if n == 0:
      # Peer closed; return whatever we have. Header parsing decides
      # whether it's a fatal premature EOF.
      return result
    if n < 0:
      raise newException(HttpError, "recv returned " & $n)
    if c == '\n':
      # Strip trailing \r if any.
      if result.len > 0 and result[^1] == '\r':
        result.setLen(result.len - 1)
      return result
    result.add(c)
    if result.len > 65536:
      raise newException(HttpError, "header line exceeds 64 KiB")
  raise newException(HttpError, "header read timed out after " &
    $timeoutMs & "ms")

proc readHeaders(sock: Socket; timeoutMs: int):
    tuple[statusCode: int; headers: seq[(string, string)]] =
  let statusLine = readLineWithTimeout(sock, timeoutMs)
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
    let line = readLineWithTimeout(sock, timeoutMs)
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
      bytesRead = sock.recv(buf[0].addr, want, timeout = timeoutMs)
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
        bytesRead = sock.recv(buf[0].addr, want, timeout = timeoutMs)
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
      bytesRead = sock.recv(buf[0].addr, buf.len, timeout = timeoutMs)
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

proc streamGet*(pool: HttpPool; url: string;
                callback: StreamChunkCallback;
                reuseBuffer: var seq[byte];
                extraHeaders: seq[(string, string)] = @[]):
                  StreamResponse =
  ## Issues ``GET url`` and pipes the response body through ``callback``
  ## as bytes arrive. ``reuseBuffer`` is the receive ring buffer — the
  ## caller supplies a pre-allocated ``seq[byte]`` (typically 256 KiB)
  ## so we don't allocate per substitute. Returns the response
  ## descriptor; ``bytesReceived`` lets the caller assert the wire-size
  ## against the manifest's declared payload size.
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
    try:
      conn.sock.send(req)
    except OSError as e:
      raise newException(HttpError, "send request failed: " & e.msg)

    # ---- Response headers ----
    let (statusCode, headers) =
      readHeaders(conn.sock, pool.receiveTimeoutMs)
    resp.statusCode = statusCode

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
      if resp.chunked:
        resp.bytesReceived = drainChunked(
          conn.sock, reuseBuffer, callback, pool.receiveTimeoutMs)
        reusable = not connHdr.contains("close")
      elif resp.contentLength >= 0:
        resp.bytesReceived = drainContentLength(
          conn.sock, resp.contentLength, reuseBuffer, callback,
          pool.receiveTimeoutMs)
        reusable = not connHdr.contains("close")
      else:
        # No content-length, no chunked => drain until close. Not
        # reusable.
        resp.bytesReceived = drainUntilClose(
          conn.sock, reuseBuffer, callback, pool.receiveTimeoutMs)
        reusable = false
    else:
      # Drain error body into a throwaway buffer so the connection stays
      # in a known state. Cap at 64 KiB so a misbehaving server can't
      # blow our memory.
      var sink = newSeq[byte](0)
      let drainCb: StreamChunkCallback = proc(chunk: openArray[byte]) =
        if sink.len < 65536:
          let want = min(chunk.len, 65536 - sink.len)
          for i in 0 ..< want:
            sink.add(chunk[i])
      if resp.chunked:
        discard drainChunked(conn.sock, reuseBuffer, drainCb,
                             pool.receiveTimeoutMs)
        reusable = not connHdr.contains("close")
      elif resp.contentLength >= 0:
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

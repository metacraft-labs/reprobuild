## A small, bounded HTTP/1.1 server for one pre-authentication surface.
##
## ## Why this is not ``std/asynchttpserver``
##
## Three reasons, in order of weight.
##
## **The closure.** This daemon sits inside every attested TCB. Its
## dependencies are part of what the image measures, so every module it
## pulls in is a module a verifier's trust extends over. This file needs
## ``std/net`` and nothing else; the async stack brings a dispatcher, a
## selector backend and the platform machinery underneath them.
##
## **The bounds are the feature.** The limits in ``limits`` have to be
## applied *before* the thing they bound is read — a body limit enforced
## after the body has arrived has already lost. That means deciding from
## the ``Content-Length`` header whether to read at all, capping the
## request line and the headers as they are consumed, and charging the
## rate limiter before either. Those are decisions inside the read loop,
## which is exactly the part a framework owns.
##
## **A quote is not a web page.** The whole workload is a handful of
## requests per boot, each answered by a blocking transaction with a
## device. There is no concurrency to exploit, and a design that
## pretended there was would add a scheduler to serialise on a single
## piece of hardware anyway.
##
## ## The shape, and its consequences
##
## One connection, one request, no keep-alive; every response says
## ``Connection: close`` and the socket is closed after it. This is
## deliberate rather than a simplification. A pre-authentication caller
## that could hold a connection open holds the *server*, since the accept
## loop is single-threaded — so a connection lives for one request and no
## longer, and the connection deadline is therefore a per-request
## deadline. ``Transfer-Encoding`` is refused for the same reason: a
## chunked body is a body whose size is not known until it has arrived.
##
## Two clocks bound a connection. ``readTimeoutMs`` bounds one read, so a
## caller that connects and says nothing costs a bounded wait.
## ``connectionDeadlineMs`` bounds the whole connection and does *not*
## reset, so a caller dribbling one byte per read window — which would
## refresh the read timeout forever — is cut off. One of those alone is
## not enough, which is why there are two.
##
## ## Mocking
##
## None. The listener is a real socket on a real port; the tests drive it
## with a real client.

import std/[nativesockets, net, oserrors, strutils, times]

when defined(posix) and not defined(lwip):
  import std/posix

import ./limits

type
  HttpRequest* = object
    ## A parsed request, with every field already inside its bound.
    verb*: string
    target*: string
      ## The raw request target, path and query together.
    path*: string
    query*: string
    body*: string
    peer*: string
      ## The connecting address, and the rate limiter's key. Never
      ## trusted for anything else: it is not an identity.

  HttpResponse* = object
    status*: int
    contentType*: string
    body*: string

  RequestCost* = proc (verb, path: string): int {.gcsafe, raises: [].}
    ## What a route costs the rate limiter, decided from the request line
    ## alone. It has to be answerable before the body is read, because
    ## the charge happens before the body is read.

  RequestHandler* = proc (req: HttpRequest): HttpResponse {.gcsafe.}

  HttpServer* = ref object
    listener: Socket
    limits: AgentLimits
    limiter: RateLimiter
    handler: RequestHandler
    cost: RequestCost
    stopRequested: bool
    listenPort: Port
    served: int
    refusedByLimit: int

const
  ReadChunk = 4_096

proc statusText*(code: int): string =
  case code
  of 200: "OK"
  of 400: "Bad Request"
  of 404: "Not Found"
  of 405: "Method Not Allowed"
  of 409: "Conflict"
  of 411: "Length Required"
  of 413: "Content Too Large"
  of 414: "URI Too Long"
  of 429: "Too Many Requests"
  of 431: "Request Header Fields Too Large"
  of 500: "Internal Server Error"
  of 501: "Not Implemented"
  of 503: "Service Unavailable"
  else: "Status " & $code

proc renderResponse*(r: HttpResponse): string =
  ## The bytes on the wire. Written by hand, with a fixed header order
  ## and no header value taken from the request, so nothing a caller
  ## sends can appear in a response header.
  result = "HTTP/1.1 " & $r.status & " " & statusText(r.status) & "\r\n"
  result.add "Content-Type: " & r.contentType & "\r\n"
  result.add "Content-Length: " & $r.body.len & "\r\n"
  result.add "Connection: close\r\n"
  result.add "Cache-Control: no-store\r\n"
  result.add "\r\n"
  result.add r.body

# ---------------------------------------------------------------------
# Bounded reading
# ---------------------------------------------------------------------

type
  Reader = object
    sock: Socket
    buf: string
    pos: int
    timeoutMs: int
    deadline: float

  LineOutcome = enum
    ## ``readLine`` has three answers and they need different handling, so
    ## it does not signal any of them with an empty string: a blank line
    ## is what ends a header block, and conflating it with a closed
    ## connection is how a truncated request gets served.
    loLine
    loOverrun
    loClosed

proc nowSeconds(): float = epochTime()

proc remainingMs(r: Reader): int =
  let left = int((r.deadline - nowSeconds()) * 1000.0)
  if left < 0: 0 else: left

proc waitReadable(sock: Socket; timeoutMs: int): bool =
  ## Block until the socket has *something* to read, or the budget runs
  ## out.
  ##
  ## The readiness wait is separate from the read on purpose, and it is
  ## not the obvious spelling. ``std/net``'s ``recv`` overloads that take
  ## a timeout do not return early: they loop until the requested size
  ## has arrived, so asking for a buffer's worth of a request that is a
  ## hundred bytes long waits for the timeout every time. Waiting for
  ## readability and then issuing one unbuffered ``recv`` — which returns
  ## whatever the kernel has — is what makes a short request cost one
  ## round trip instead of one timeout.
  ##
  ## ``poll`` on POSIX rather than ``select``: ``select`` cannot see a
  ## descriptor at or above ``FD_SETSIZE``, and a daemon is exactly the
  ## kind of process that eventually has one.
  when defined(posix) and not defined(lwip):
    var pfd = TPollfd(fd: cint(sock.getFd()),
                      events: cshort(POLLIN or POLLPRI), revents: 0)
    posix.poll(addr pfd, Tnfds(1), cint(timeoutMs)) > 0
  else:
    var fds = @[sock.getFd()]
    selectRead(fds, timeoutMs) > 0

proc waitWritable(sock: Socket; timeoutMs: int): bool =
  when defined(posix) and not defined(lwip):
    var pfd = TPollfd(fd: cint(sock.getFd()),
                      events: cshort(POLLOUT), revents: 0)
    posix.poll(addr pfd, Tnfds(1), cint(timeoutMs)) > 0
  else:
    var fds = @[sock.getFd()]
    selectWrite(fds, timeoutMs) > 0

proc sendFully*(sock: Socket; data: string; deadline: float): bool =
  ## Write every byte, or give up. Returns whether all of it went.
  ##
  ## ``std/net``'s string ``send`` cannot be used for this, and the reason
  ## is worth writing down because the failure is a hang rather than an
  ## error. That overload loops until every byte has been written, and it
  ## reports a failed write through ``socketError`` with ``SafeDisconn``
  ## in its flags — which *swallows* precisely the disconnection errors
  ## that mean no byte will ever be written. Nothing is raised, nothing
  ## is written, and the loop condition never changes. A peer that closes
  ## before reading its response therefore turns one write into an
  ## unbounded spin at 100% of a core, and on a single-threaded accept
  ## loop that is not a slow request: it is the end of the daemon, from a
  ## client that did nothing but hang up early.
  ##
  ## So the write is done here, over the low-level send, with the errno
  ## cases separated: an interrupted write is retried, a full send buffer
  ## is waited on, and a broken pipe is what it is. Every path is bounded
  ## by the connection's deadline.
  if data.len == 0: return true
  var written = 0
  while written < data.len:
    if nowSeconds() >= deadline: return false
    var sent = 0
    try:
      sent = sock.send(unsafeAddr data[written], data.len - written)
    except OSError:
      return false
    if sent > 0:
      written = written + sent
      continue
    when defined(posix) and not defined(lwip):
      let err = osLastError().int32
      if err == EINTR: continue
      if err == EAGAIN or err == EWOULDBLOCK:
        let leftMs = int((deadline - nowSeconds()) * 1000.0)
        if leftMs <= 0: return false
        if not waitWritable(sock, min(leftMs, 100)): continue
        continue
    # Anything else — a broken pipe, a reset, a peer that hung up — is
    # final. There is no version of retrying that ends differently.
    return false
  true

proc fill(r: var Reader): bool =
  ## One read, bounded by whichever of the two clocks expires first.
  ## Returns false when the peer closed or a clock ran out.
  let budget = min(r.timeoutMs, r.remainingMs)
  if budget <= 0: return false
  if not waitReadable(r.sock, budget): return false
  var chunk = newString(ReadChunk)
  var got = 0
  try:
    got = r.sock.recv(addr chunk[0], ReadChunk)
  except OSError:
    return false
  if got <= 0: return false
  # Compact what has already been consumed so the buffer tracks the
  # unread remainder rather than the whole conversation.
  if r.pos > 0:
    r.buf = r.buf[r.pos .. ^1]
    r.pos = 0
  r.buf.add chunk[0 ..< got]
  true

proc readLine(r: var Reader; maxBytes: int; line: var string): LineOutcome =
  ## Up to the next CRLF, exclusive. The caller decides what an overrun
  ## means, because a long request line and a long header field are
  ## different refusals.
  ##
  ## The bound is checked on the LINE, not only on how much has
  ## accumulated without one. Checking only the latter is a bound that
  ## cannot fire whenever the whole request fits in one read — which is
  ## every request that matters, since a caller sending an over-long
  ## request line sends it in one go — so the terminator is found, the
  ## line is returned, and the limit never runs.
  line = ""
  while true:
    var i = r.pos
    while i + 1 < r.buf.len:
      if r.buf[i] == '\r' and r.buf[i + 1] == '\n':
        if i - r.pos > maxBytes:
          return loOverrun
        line = r.buf[r.pos ..< i]
        r.pos = i + 2
        return loLine
      inc i
    if r.buf.len - r.pos > maxBytes:
      return loOverrun
    if not r.fill():
      return loClosed

proc lingeringDrain(r: var Reader; budgetMs: int) =
  ## Discard whatever the peer is still sending, briefly, and then let
  ## the caller close.
  ##
  ## This exists because of how TCP ends a connection. Closing a socket
  ## whose receive queue still holds unread bytes sends the peer a reset,
  ## and a reset discards whatever the peer had not yet read — including
  ## the refusal that was just written to it. A caller who sent a body
  ## over the limit would then see a connection error instead of the 413
  ## explaining what it did wrong, which is the least useful answer
  ## available.
  ##
  ## The bound is TIME, not bytes, and that is the right resource to
  ## bound: the bytes are discarded as they arrive and cost no memory,
  ## while the thing an attacker is trying to take is the single-threaded
  ## loop. A byte budget would also be self-defeating here — the body
  ## being drained is by definition larger than any byte budget derived
  ## from the limit it just exceeded.
  ##
  ## The first readiness check has a zero timeout, so a caller that
  ## declared a large body and sent none of it costs nothing at all: the
  ## refusal is written and the connection closes immediately. Only a
  ## peer with bytes actually in flight is waited on.
  if not waitReadable(r.sock, 0): return
  let until = nowSeconds() + float(budgetMs) / 1000.0
  while true:
    let leftMs = int((until - nowSeconds()) * 1000.0)
    if leftMs <= 0: break
    if not waitReadable(r.sock, min(leftMs, 50)): break
    var chunk = newString(ReadChunk)
    var got = 0
    try:
      got = r.sock.recv(addr chunk[0], ReadChunk)
    except OSError:
      break
    if got <= 0: break

proc readBody(r: var Reader; length: int; body: var string): bool =
  ## Exactly ``length`` bytes. False when they do not all arrive inside
  ## the connection's remaining budget. The caller has already checked
  ## ``length`` against the bound.
  while r.buf.len - r.pos < length:
    if not r.fill(): return false
  body = r.buf[r.pos ..< r.pos + length]
  r.pos = r.pos + length
  true

# ---------------------------------------------------------------------
# Request parsing
# ---------------------------------------------------------------------

type
  ParseOutcome = object
    ## What reading the head of a request produced.
    refusalStatus: int
      ## 0 when the request head was read; 0 with ``peerLeft`` when the
      ## peer went away; otherwise the status to answer with.
    refusalMessage: string
    peerLeft: bool
    declaredLength: int
      ## The ``Content-Length`` the request declared, or -1 for none. The
      ## body is deliberately NOT read here: it must not be read until
      ## the rate limiter has admitted the request.

proc splitTarget(target: string): (string, string) =
  let q = target.find('?')
  if q < 0: (target, "")
  else: (target[0 ..< q], target[q + 1 .. ^1])

proc refusedWith(status: int; message: string): ParseOutcome =
  ParseOutcome(refusalStatus: status, refusalMessage: message,
               peerLeft: false, declaredLength: -1)

proc parseRequestHead(r: var Reader; l: AgentLimits;
                      req: var HttpRequest): ParseOutcome =
  var line = ""
  case r.readLine(l.maxRequestLineBytes, line)
  of loOverrun:
    return refusedWith(414,
      "the request line exceeds " & $l.maxRequestLineBytes & " bytes")
  of loClosed:
    return ParseOutcome(refusalStatus: 0, peerLeft: true, declaredLength: -1)
  of loLine: discard

  let parts = line.split(' ')
  if parts.len != 3:
    return refusedWith(400,
      "the request line is not \"<method> <target> <version>\"")
  req.verb = parts[0]
  req.target = parts[1]
  (req.path, req.query) = splitTarget(parts[1])

  var headerBytes = 0
  var headerCount = 0
  var contentLength = -1
  var chunked = false
  while true:
    var h = ""
    case r.readLine(l.maxHeaderBytes, h)
    of loOverrun:
      return refusedWith(431,
        "a header line exceeds " & $l.maxHeaderBytes & " bytes")
    of loClosed:
      return ParseOutcome(refusalStatus: 0, peerLeft: true, declaredLength: -1)
    of loLine: discard
    if h.len == 0: break

    inc headerCount
    headerBytes = headerBytes + h.len + 2
    if headerCount > l.maxHeaderCount:
      return refusedWith(431,
        "more than " & $l.maxHeaderCount & " header fields")
    if headerBytes > l.maxHeaderBytes:
      return refusedWith(431,
        "the header block exceeds " & $l.maxHeaderBytes & " bytes")

    let colon = h.find(':')
    if colon <= 0:
      return refusedWith(400, "a header line has no field name")
    let name = toLowerAscii(h[0 ..< colon])
    let value = strip(h[colon + 1 .. ^1])
    if name == "content-length":
      try:
        contentLength = parseInt(value)
      except ValueError:
        return refusedWith(400, "Content-Length is not a number")
      if contentLength < 0:
        return refusedWith(400, "Content-Length is negative")
    elif name == "transfer-encoding":
      chunked = true

  if chunked:
    # A chunked body is a body whose length is not known until it has
    # been read, which is the one thing a bounded surface cannot allow.
    return refusedWith(411,
      "a chunked body has no length to check before reading it; send " &
      "Content-Length")

  ParseOutcome(refusalStatus: 0, peerLeft: false, declaredLength: contentLength)

# ---------------------------------------------------------------------
# The connection
# ---------------------------------------------------------------------

proc lingerBudgetMs(l: AgentLimits): int =
  ## How long a refusal will wait for an in-flight body to finish
  ## arriving. Derived from the read timeout so that a deployment which
  ## tightens its clocks tightens this too, and capped so that tightening
  ## is the only direction it moves.
  min(l.readTimeoutMs, 1_000)

proc respond(r: var Reader; resp: HttpResponse) =
  ## Best effort, always bounded. A response nobody is listening for is
  ## not an error worth acting on — but it must not be a wait, either.
  discard sendFully(r.sock, renderResponse(resp), r.deadline)

proc refuse(r: var Reader; status: int; message: string; lingerMs: int) =
  ## Answer, then let what the peer is still sending drain away, so that
  ## closing does not reset the connection out from under the answer.
  respond(r, HttpResponse(status: status, contentType: "text/plain",
    body: statusText(status) & ": " & message & "\n"))
  lingeringDrain(r, lingerMs)

proc serveConnection(s: HttpServer; client: Socket; peer: string) =
  var r = Reader(sock: client, buf: "", pos: 0,
                 timeoutMs: s.limits.readTimeoutMs,
                 deadline: nowSeconds() +
                   float(s.limits.connectionDeadlineMs) / 1000.0)
  var req = HttpRequest(peer: peer)
  let head = parseRequestHead(r, s.limits, req)
  if head.peerLeft: return
  if head.refusalStatus != 0:
    inc s.refusedByLimit
    refuse(r, head.refusalStatus, head.refusalMessage, lingerBudgetMs(s.limits))
    return

  # Charged before the body is read: reading a quarter of a mebibyte for
  # a caller who is about to be told 429 is work an unadmitted caller got
  # for free, and doing it once per connection is the whole attack.
  let nowMs = int64(nowSeconds() * 1000.0)
  let decision = s.limiter.charge(peer, s.cost(req.verb, req.path), nowMs)
  if decision != rdAdmitted:
    inc s.refusedByLimit
    refuse(r, 429,
      (if decision == rdRefusedGlobal:
         "this agent is answering as fast as it will; retry shortly"
       else:
         "this client is asking faster than it will be answered"),
      lingerBudgetMs(s.limits))
    return

  if head.declaredLength > s.limits.maxBodyBytes:
    inc s.refusedByLimit
    refuse(r, 413,
      "the declared body is " & $head.declaredLength & " bytes; at most " &
      $s.limits.maxBodyBytes & " are read", lingerBudgetMs(s.limits))
    return
  if head.declaredLength > 0:
    if not readBody(r, head.declaredLength, req.body):
      # The body never arrived inside the connection's budget.
      return

  var response =
    try:
      s.handler(req)
    except CatchableError as err:
      HttpResponse(status: 500, contentType: "text/plain",
        body: "Internal Server Error: " & err.msg & "\n")
  inc s.served
  respond(r, response)

# ---------------------------------------------------------------------
# The server
# ---------------------------------------------------------------------

proc newHttpServer*(host: string; port: Port; l: AgentLimits;
                    handler: RequestHandler; cost: RequestCost): HttpServer =
  ## Binds immediately, so a port that cannot be taken is an error at
  ## start-up rather than a daemon that is running and unreachable.
  validateAgentLimits(l)
  let sock = newSocket(buffered = false)
  sock.setSockOpt(OptReuseAddr, true)
  sock.bindAddr(port, host)
  sock.listen()
  result = HttpServer(listener: sock, limits: l,
    limiter: newRateLimiter(l, int64(nowSeconds() * 1000.0)),
    handler: handler, cost: cost, stopRequested: false,
    listenPort: getLocalAddr(sock)[1])

proc boundPort*(s: HttpServer): Port =
  ## The port actually bound, which is what a caller that asked for port
  ## 0 needs to know.
  s.listenPort

proc servedRequests*(s: HttpServer): int = s.served
proc refusedRequests*(s: HttpServer): int = s.refusedByLimit

proc requestStop*(s: HttpServer) =
  ## Ask the accept loop to finish.
  ##
  ## The loop is blocked in ``accept`` and there is nothing to interrupt
  ## it with, so a caller sets this and then opens one connection to the
  ## listening port. That connection is accepted, the flag is seen, and
  ## the loop returns. It is a deliberate choice over a polling accept:
  ## polling costs a wake-up per interval for the entire life of a daemon
  ## that is almost always idle, to save one socket at shutdown.
  s.stopRequested = true

proc close*(s: HttpServer) =
  try: s.listener.close()
  except OSError: discard

proc serve*(s: HttpServer) =
  ## The accept loop. Returns after ``requestStop`` has been called and
  ## one further connection has arrived.
  while true:
    var client: Socket = nil
    var peer = ""
    try:
      s.listener.acceptAddr(client, peer)
    except OSError:
      if s.stopRequested: break
      continue
    if s.stopRequested:
      try: client.close()
      except OSError: discard
      break
    try:
      serveConnection(s, client, peer)
    except CatchableError:
      # A connection is never allowed to end the daemon. This is the
      # clause the abuse gate is about: surviving by dying is not
      # surviving.
      discard
    try: client.close()
    except OSError: discard

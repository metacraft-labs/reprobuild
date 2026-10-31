## The host's two Unix domain sockets (spec §"Encoding and transport").
##
## `provider.sock` and `consent.sock` live in a `0700` directory. Every
## accepted connection's peer must have the host's uid; on `consent.sock`
## an optional `consentPeer` predicate must also accept the peer's pid
## (ReproOS passes one that compares `/proc/<pid>/exe` with the consent
## surface binary of the active generation). The predicate is a policy
## hook, not a default: when one is configured and the pid cannot be
## obtained on this platform, the connection is refused.
##
## Each connection reads length-prefixed CBOR frames and answers each with
## one frame. The host is single-threaded. A request runs to completion
## before the next request of its connection starts, and responses keep
## request order, with one exception: `plan.cancel` is answered as soon as
## it is read, ahead of anything queued, so a cancellation never waits for
## the execution it cancels (`requestId` tells the answers apart). A
## backend call waits through `Host.pump`, which runs the dispatcher, so
## other connections are served, and cancellations read, meanwhile.
##
## Peer credentials: Linux `SO_PEERCRED` (socket(7),
## https://man7.org/linux/man-pages/man7/unix.7.html); macOS and the BSDs
## `getpeereid(3)`.

import std/[asyncdispatch, asyncnet, deques, nativesockets, os, posix]

import ./[types, host, wire]

type
  PeerCred* = object
    uid*: int
    pid*: int ## -1 when the platform does not report it

  ConsentPeerCheck* = proc (pid: int): bool {.gcsafe.}
    ## Called for every consent-socket peer, with -1 when the platform
    ## does not report the peer's pid (macOS `getpeereid`).

  HostServer* = ref object
    host*: Host
    dir*: string
    provider, consent: AsyncSocket
    consentPeer*: ConsentPeerCheck
    closed: bool

when defined(linux):
  type Ucred {.importc: "struct ucred", header: "<sys/socket.h>".} = object
    pid: Pid
    uid: Uid
    gid: Gid
  var SO_PEERCRED {.importc, header: "<sys/socket.h>".}: cint

  proc peerCred*(fd: SocketHandle): PeerCred =
    var c: Ucred
    var len = SockLen(sizeof(c))
    if getsockopt(fd, SOL_SOCKET, SO_PEERCRED, addr c, addr len) != 0:
      raiseOSError(osLastError(), "SO_PEERCRED")
    PeerCred(uid: int(c.uid), pid: int(c.pid))
else:
  proc getpeereid(s: SocketHandle; uid: var Uid; gid: var Gid): cint {.
    importc, header: "<unistd.h>".}

  proc peerCred*(fd: SocketHandle): PeerCred =
    var uid: Uid
    var gid: Gid
    if getpeereid(fd, uid, gid) != 0:
      raiseOSError(osLastError(), "getpeereid")
    PeerCred(uid: int(uid), pid: -1)

proc providerSocketPath*(dir: string): string = dir / "provider.sock"
proc consentSocketPath*(dir: string): string = dir / "consent.sock"

proc readFrame(sock: AsyncSocket): Future[seq[byte]] {.async.} =
  ## One frame, or an empty seq when the peer closed. A frame header that
  ## announces more than the bound closes the connection.
  let head = await sock.recv(4)
  if head.len < 4:
    return @[]
  let n = (int(ord(head[0])) shl 24) or (int(ord(head[1])) shl 16) or
          (int(ord(head[2])) shl 8) or int(ord(head[3]))
  if n > MaxFrameBytes:
    return @[]
  var body = ""
  while body.len < n:
    let part = await sock.recv(n - body.len)
    if part.len == 0:
      return @[]
    body.add part
  result = newSeq[byte](n)
  for i in 0 ..< n:
    result[i] = byte(ord(body[i]))

type ConnState = ref object
  server: HostServer
  sock: AsyncSocket
  conn: Connection
  queue: Deque[seq[byte]]
  busy: bool   ## a request of this connection is being handled
  closed: bool
  sending: Future[void] ## the last queued send; sends are chained in order

proc sendAfter(st: ConnState; prev: Future[void]; data: string) {.async.} =
  if not prev.isNil:
    await prev
  if st.closed:
    return
  try:
    await st.sock.send(data)
  except CatchableError:
    st.closed = true

proc send(st: ConnState; payload: seq[byte]) =
  if st.closed:
    return
  let f = frame(payload)
  var str = newString(f.len)
  for i, b in f:
    str[i] = char(b)
  st.sending = st.sendAfter(st.sending, str)

proc answer(st: ConnState; req: seq[byte]) =
  try:
    st.send(st.server.host.handleMessage(st.conn, req))
  except CatchableError:
    st.closed = true # a response larger than a frame: drop the peer

proc drain(st: ConnState) =
  ## Handle the queued requests in order. Runs from the dispatcher (never
  ## inside `serve`'s own frame), so `serve` keeps reading while a request
  ## executes.
  if st.busy:
    return
  st.busy = true
  try:
    while st.queue.len > 0 and not st.closed:
      st.answer(st.queue.popFirst())
  finally:
    st.busy = false

proc serve(s: HostServer; sock: AsyncSocket; channel: AgentChannel) {.async.} =
  let st = ConnState(server: s, sock: sock, conn: newConnection(channel),
                     queue: initDeque[seq[byte]]())
  try:
    while not s.closed and not st.closed:
      let req = await readFrame(sock)
      if req.len == 0:
        break
      if requestKind(req) == "plan.cancel":
        st.answer(req)
      else:
        st.queue.addLast req
        if not st.busy:
          callSoon(proc () {.gcsafe.} =
            {.cast(gcsafe).}: st.drain())
  except CatchableError:
    discard # a broken connection ends the session's attachment below
  finally:
    st.closed = true
    s.host.disconnect(st.conn)
    sock.close()

proc admit(s: HostServer; client: AsyncSocket; channel: AgentChannel): bool =
  ## The peer-credential checks. A refused peer is closed without a
  ## response: it is not a protocol participant.
  let cred =
    try: peerCred(client.getFd)
    except OSError: return false
  if cred.uid != int(getuid()):
    return false
  if channel == chConsent and not s.consentPeer.isNil:
    # The policy always sees the attempt (it may audit it), with -1 when
    # the platform does not report the peer's pid; an unknown pid is
    # refused whatever the policy says.
    let accepted = s.consentPeer(cred.pid)
    if cred.pid < 0 or not accepted:
      return false
  true

proc acceptLoop(s: HostServer; listener: AsyncSocket;
                channel: AgentChannel) {.async.} =
  while not s.closed:
    let client =
      try: await listener.accept()
      except CatchableError:
        if s.closed: return
        continue
    if s.admit(client, channel):
      asyncCheck s.serve(client, channel)
    else:
      client.close()

proc listenUnix(path: string): AsyncSocket =
  if fileExists(path) or symlinkExists(path):
    removeFile(path)
  result = newAsyncSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
  result.bindUnix(path)
  result.listen()

proc startServer*(h: Host; dir: string;
                  consentPeer: ConsentPeerCheck = nil): HostServer =
  ## Create `dir` with mode 0700 and listen on both sockets. The caller
  ## drives the dispatcher (`runForever`, `poll`, or `waitFor`).
  createDir(dir)
  setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
  result = HostServer(host: h, dir: dir, consentPeer: consentPeer)
  h.pump = proc (waitMs: int) {.gcsafe.} =
    {.cast(gcsafe).}:
      try: poll(waitMs)
      except ValueError: sleep(waitMs) # nothing registered
  result.provider = listenUnix(providerSocketPath(dir))
  result.consent = listenUnix(consentSocketPath(dir))
  asyncCheck result.acceptLoop(result.provider, chProvider)
  asyncCheck result.acceptLoop(result.consent, chConsent)

proc stop*(s: HostServer) =
  s.closed = true
  s.host.pump = nil
  s.provider.close()
  s.consent.close()
  removeFile(providerSocketPath(s.dir))
  removeFile(consentSocketPath(s.dir))

# ---------------------------------------------------------------------
# A minimal client, for the consent surface, tests and Nim providers.

type HostClient* = ref object
  sock: AsyncSocket

proc connectHost*(path: string): Future[HostClient] {.async.} =
  let sock = newAsyncSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
  await sock.connectUnix(path)
  return HostClient(sock: sock)

proc send*(c: HostClient; payload: seq[byte]) {.async.} =
  ## Send one request frame without waiting for its response.
  let f = frame(payload)
  var str = newString(f.len)
  for i, b in f:
    str[i] = char(b)
  await c.sock.send(str)

proc receive*(c: HostClient): Future[seq[byte]] =
  ## The next response frame; empty when the host closed the connection.
  readFrame(c.sock)

proc request*(c: HostClient; payload: seq[byte]): Future[seq[byte]] {.async.} =
  ## Send one request frame and wait for its response frame; empty when
  ## the host closed the connection.
  await c.send(payload)
  return await c.receive()

proc close*(c: HostClient) = c.sock.close()

## The host's two channels (spec §"Encoding and transport", and on
## Windows §"The Windows transport").
##
## POSIX: `provider.sock` and `consent.sock`, two Unix domain sockets in a
## `0700` directory. Every accepted connection's peer must have the host's
## uid, checked at accept from the kernel's peer credentials: Linux
## `SO_PEERCRED` (socket(7),
## https://man7.org/linux/man-pages/man7/unix.7.html); macOS and the BSDs
## `getpeereid(3)`.
##
## Windows: two named pipes, `\\.\pipe\reproos-agent-<SID>-<nonce>-provider`
## and `…-consent`, created owner-only, local-only and first-instance
## (`named_pipe`). A named-pipe server can identify its client only after
## reading from it, so the host reads the first frame's 4-byte header, takes
## the user SID of the client's impersonation token, and admits the peer
## only when it equals the host's own; nothing is answered before that,
## on either platform.
##
## On `consent` an optional `consentPeer` predicate must also accept the
## peer's pid (ReproOS passes one that compares `/proc/<pid>/exe` with the
## consent surface binary of the active generation). The predicate is a
## policy hook, not a default: when one is configured and the pid cannot be
## obtained on this platform, the connection is refused. On Windows that
## pid is advisory (a client can spoof it); the identity check above is the
## one that holds.
##
## Each connection reads length-prefixed CBOR frames and answers each with
## one frame. The host is single-threaded. A request runs to completion
## before the next request of its connection starts, and responses keep
## request order, with one exception: `plan.cancel` is answered as soon as
## it is read, ahead of anything queued, so a cancellation never waits for
## the execution it cancels (`requestId` tells the answers apart). A
## backend call waits through `Host.pump`, which runs the dispatcher, so
## other connections are served, and cancellations read, meanwhile.

import std/[asyncdispatch, deques, os]

when defined(windows):
  import ./named_pipe
  export named_pipe.ClientImpersonation, named_pipe.PipeStream
else:
  import std/[asyncnet, nativesockets, posix]

import ./[types, host, wire]

type
  PeerCred* = object
    uid*: int ## POSIX only; -1 on Windows
    pid*: int ## -1 when the platform does not report it
    sid*: string ## Windows only: the user SID of the client's token

  ConsentPeerCheck* = proc (pid: int): bool {.gcsafe.}
    ## Called for every consent-channel peer, with -1 when the platform
    ## does not report the peer's pid (macOS `getpeereid`).

when defined(windows):
  type
    Stream = PipeStream
    Listener = PipeListener
else:
  type
    Stream = AsyncSocket
    Listener = AsyncSocket

type
  HostServer* = ref object
    host*: Host
    dir*: string
    providerPath*: string ## what a provider connects to (`REPROOS_AGENT_SOCKET`)
    consentPath*: string  ## what the consent surface connects to
    provider, consent: Listener
    consentPeer*: ConsentPeerCheck
    ownSid: string ## Windows: the host's user SID
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
elif defined(posix):
  proc getpeereid(s: SocketHandle; uid: var Uid; gid: var Gid): cint {.
    importc, header: "<unistd.h>".}

  proc peerCred*(fd: SocketHandle): PeerCred =
    var uid: Uid
    var gid: Gid
    if getpeereid(fd, uid, gid) != 0:
      raiseOSError(osLastError(), "getpeereid")
    PeerCred(uid: int(uid), pid: -1)
else:
  proc peerCred*(s: PipeStream): PeerCred =
    ## The client's identity, from its impersonation token (raises
    ## `PipeSecurityError` when it cannot be identified), and its advisory
    ## pid. Data must have been read from the pipe first.
    PeerCred(uid: -1, pid: s.clientPid, sid: s.clientSid)

proc providerSocketPath*(dir: string): string = dir / "provider.sock"
  ## POSIX: the provider socket of a server started on `dir`. Use
  ## `HostServer.providerPath`, which is right on every platform.
proc consentSocketPath*(dir: string): string = dir / "consent.sock"
  ## POSIX: see `providerSocketPath`.

const
  ProviderSuffix = "-provider"
  ConsentSuffix = "-consent"

proc consentPathBeside*(providerPath: string): string =
  ## The consent channel of the host whose provider channel is
  ## `providerPath`. A provider can always compute this; the channel is
  ## protected by the peer checks, never by its name being unknown.
  when defined(windows):
    if providerPath.len > ProviderSuffix.len and
        providerPath[^ProviderSuffix.len .. ^1] == ProviderSuffix:
      providerPath[0 ..< providerPath.len - ProviderSuffix.len] & ConsentSuffix
    else:
      providerPath & ConsentSuffix
  else:
    providerPath.parentDir / "consent.sock"

# ---------------------------------------------------------------------
# Byte streams

proc recvBytes(s: Stream; n: int): Future[string] =
  s.recv(n)

proc sendBytes(s: Stream; data: string): Future[void] =
  s.send(data)

proc closeStream(s: Stream) = s.close()

proc frameLength(head: string): int =
  (int(ord(head[0])) shl 24) or (int(ord(head[1])) shl 16) or
    (int(ord(head[2])) shl 8) or int(ord(head[3]))

proc readHeader(s: Stream): Future[int] {.async.} =
  ## The announced length of the next frame, or -1 when the peer closed or
  ## announced more than the bound.
  var head = ""
  while head.len < 4:
    let part = await s.recvBytes(4 - head.len)
    if part.len == 0:
      return -1
    head.add part
  let n = frameLength(head)
  if n > MaxFrameBytes: -1 else: n

proc readBody(s: Stream; n: int): Future[seq[byte]] {.async.} =
  ## The `n`-byte body of a frame; empty when the peer closed first.
  var body = ""
  while body.len < n:
    let part = await s.recvBytes(n - body.len)
    if part.len == 0:
      return @[]
    body.add part
  result = newSeq[byte](n)
  for i in 0 ..< n:
    result[i] = byte(ord(body[i]))

proc readFrame(s: Stream): Future[seq[byte]] {.async.} =
  ## One frame, or an empty seq when the peer closed. A frame header that
  ## announces more than the bound closes the connection.
  let n = await readHeader(s)
  if n < 0:
    return @[]
  return await readBody(s, n)

proc toWire(payload: seq[byte]): string =
  let f = frame(payload)
  result = newString(f.len)
  for i, b in f:
    result[i] = char(b)

type ConnState = ref object
  server: HostServer
  sock: Stream
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
    await st.sock.sendBytes(data)
  except CatchableError:
    st.closed = true

proc send(st: ConnState; payload: seq[byte]) =
  if st.closed:
    return
  st.sending = st.sendAfter(st.sending, toWire(payload))

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

proc enqueue(st: ConnState; req: seq[byte]) =
  if requestKind(req) == "plan.cancel":
    st.answer(req)
  else:
    st.queue.addLast req
    if not st.busy:
      callSoon(proc () {.gcsafe.} =
        {.cast(gcsafe).}: st.drain())

proc serve(s: HostServer; sock: Stream; channel: AgentChannel;
           first: seq[byte]) {.async.} =
  ## Serve an admitted peer. `first`, when not empty, is a request already
  ## read (on Windows, the frame whose header was read to identify it).
  let st = ConnState(server: s, sock: sock, conn: newConnection(channel),
                     queue: initDeque[seq[byte]]())
  try:
    if first.len > 0:
      st.enqueue(first)
    while not s.closed and not st.closed:
      let req = await readFrame(sock)
      if req.len == 0:
        break
      st.enqueue(req)
  except CatchableError:
    discard # a broken connection ends the session's attachment below
  finally:
    st.closed = true
    s.host.disconnect(st.conn)
    sock.closeStream()

proc admitConsentPid(s: HostServer; channel: AgentChannel; pid: int): bool =
  if channel == chConsent and not s.consentPeer.isNil:
    # The policy always sees the attempt (it may audit it), with -1 when
    # the platform does not report the peer's pid; an unknown pid is
    # refused whatever the policy says.
    let accepted = s.consentPeer(pid)
    if pid < 0 or not accepted:
      return false
  true

when defined(windows):
  proc admitAndServe(s: HostServer; pipe: PipeStream;
                     channel: AgentChannel) {.async.} =
    ## Identify the client after reading its first frame header, then
    ## serve it. A refused or unidentifiable peer is closed without a
    ## response: it is not a protocol participant.
    var admitted = false
    var first: seq[byte]
    try:
      let n = await readHeader(pipe)
      if n >= 0:
        let cred =
          try: peerCred(pipe)
          except OSError: PeerCred(uid: -1, pid: -1, sid: "")
        if cred.sid.len > 0 and cred.sid == s.ownSid and
            s.admitConsentPid(channel, cred.pid):
          first = await readBody(pipe, n)
          # An empty frame ends the connection here as it does on POSIX
          # (`readFrame` cannot tell it from a close).
          admitted = first.len > 0
    except CatchableError:
      admitted = false
    if not admitted:
      pipe.close()
      return
    await s.serve(pipe, channel, first)
else:
  proc admit(s: HostServer; client: AsyncSocket; channel: AgentChannel): bool =
    ## The peer-credential checks. A refused peer is closed without a
    ## response: it is not a protocol participant.
    let cred =
      try: peerCred(client.getFd)
      except OSError: return false
    if cred.uid != int(getuid()):
      return false
    s.admitConsentPid(channel, cred.pid)

proc acceptLoop(s: HostServer; listener: Listener;
                channel: AgentChannel) {.async.} =
  while not s.closed:
    let client =
      try: await listener.accept()
      except CatchableError:
        if s.closed: return
        continue
    if s.closed:
      client.closeStream()
      return
    when defined(windows):
      asyncCheck s.admitAndServe(client, channel)
    else:
      if s.admit(client, channel):
        asyncCheck s.serve(client, channel, @[])
      else:
        client.close()

when not defined(windows):
  proc listenUnix(path: string): AsyncSocket =
    if fileExists(path) or symlinkExists(path):
      removeFile(path)
    result = newAsyncSocket(Domain.AF_UNIX, SockType.SOCK_STREAM,
                            Protocol.IPPROTO_IP)
    result.bindUnix(path)
    result.listen()

proc startServer*(h: Host; dir: string;
                  consentPeer: ConsentPeerCheck = nil;
                  pipeNonce = ""; pipeSecurity = ""): HostServer =
  ## Listen on both channels. The caller drives the dispatcher
  ## (`runForever`, `poll`, or `waitFor`).
  ##
  ## POSIX: the sockets go in `dir`, created with mode 0700.
  ##
  ## Windows: `dir` is created (the conformance harness keeps its files
  ## there) but the channels are named pipes: `providerPath` and
  ## `consentPath` name them. `pipeNonce` fixes the per-start part of the
  ## names (default: 128 random bits); `pipeSecurity` replaces the
  ## owner-only DACL with another SDDL string, which exists for tests that
  ## show the identity check holds without the DACL's help. Raises OSError
  ## when either name already exists. Both parameters are ignored on POSIX.
  createDir(dir)
  result = HostServer(host: h, dir: dir, consentPeer: consentPeer)
  h.pump = proc (waitMs: int) {.gcsafe.} =
    {.cast(gcsafe).}:
      try: poll(waitMs)
      except ValueError: sleep(waitMs) # nothing registered
  when defined(windows):
    result.ownSid = currentUserSid()
    let nonce = if pipeNonce.len > 0: pipeNonce else: randomNonce()
    let base = "\\\\.\\pipe\\reproos-agent-" & result.ownSid & "-" & nonce
    let sddl =
      if pipeSecurity.len > 0: pipeSecurity else: ownerOnlySddl(result.ownSid)
    result.providerPath = base & ProviderSuffix
    result.consentPath = base & ConsentSuffix
    result.provider = listenPipe(result.providerPath, sddl)
    try:
      result.consent = listenPipe(result.consentPath, sddl)
    except OSError:
      result.provider.close()
      raise
  else:
    discard pipeNonce
    discard pipeSecurity
    setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
    result.providerPath = providerSocketPath(dir)
    result.consentPath = consentSocketPath(dir)
    result.provider = listenUnix(result.providerPath)
    result.consent = listenUnix(result.consentPath)
  asyncCheck result.acceptLoop(result.provider, chProvider)
  asyncCheck result.acceptLoop(result.consent, chConsent)

proc stop*(s: HostServer) =
  s.closed = true
  s.host.pump = nil
  s.provider.close()
  s.consent.close()
  when not defined(windows):
    removeFile(s.providerPath)
    removeFile(s.consentPath)

# ---------------------------------------------------------------------
# A minimal client, for the consent surface, tests and Nim providers.

type HostClient* = ref object
  sock: Stream

when defined(windows):
  proc connectHost*(path: string;
                    level = ciIdentification): Future[HostClient] {.async.} =
    ## Connect to a host channel. `level` is the impersonation level the
    ## client grants; the protocol's is `ciIdentification`, and a host
    ## refuses a client it cannot identify.
    return HostClient(sock: await openPipe(path, level))

  proc newHostClient*(pipe: PipeStream): HostClient =
    ## A client over a pipe the caller opened itself (`openPipeNow`), for
    ## a caller that must open it under another token.
    HostClient(sock: pipe)
else:
  proc connectHost*(path: string): Future[HostClient] {.async.} =
    let sock = newAsyncSocket(Domain.AF_UNIX, SockType.SOCK_STREAM,
                              Protocol.IPPROTO_IP)
    await sock.connectUnix(path)
    return HostClient(sock: sock)

proc send*(c: HostClient; payload: seq[byte]) {.async.} =
  ## Send one request frame without waiting for its response.
  await c.sock.sendBytes(toWire(payload))

proc receive*(c: HostClient): Future[seq[byte]] =
  ## The next response frame; empty when the host closed the connection.
  readFrame(c.sock)

proc request*(c: HostClient; payload: seq[byte]): Future[seq[byte]] {.async.} =
  ## Send one request frame and wait for its response frame; empty when
  ## the host closed the connection.
  await c.send(payload)
  return await c.receive()

proc close*(c: HostClient) = c.sock.closeStream()

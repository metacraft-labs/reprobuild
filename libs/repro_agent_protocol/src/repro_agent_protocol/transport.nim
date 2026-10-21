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
## one frame. The host is single-threaded; the async dispatcher interleaves
## connections between requests, never within one.
##
## Peer credentials: Linux `SO_PEERCRED` (socket(7),
## https://man7.org/linux/man-pages/man7/unix.7.html); macOS and the BSDs
## `getpeereid(3)`.

import std/[asyncdispatch, asyncnet, nativesockets, os, posix]

import ./[types, host, wire]

type
  PeerCred* = object
    uid*: int
    pid*: int ## -1 when the platform does not report it

  ConsentPeerCheck* = proc (pid: int): bool {.gcsafe.}

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

proc serve(s: HostServer; sock: AsyncSocket; channel: AgentChannel) {.async.} =
  let conn = newConnection(channel)
  try:
    while not s.closed:
      let req = await readFrame(sock)
      if req.len == 0:
        break
      let resp = frame(s.host.handleMessage(conn, req))
      var str = newString(resp.len)
      for i, b in resp:
        str[i] = char(b)
      await sock.send(str)
  except CatchableError:
    discard # a broken connection ends the session's attachment below
  finally:
    s.host.disconnect(conn)
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
    if cred.pid < 0 or not s.consentPeer(cred.pid):
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
  result.provider = listenUnix(providerSocketPath(dir))
  result.consent = listenUnix(consentSocketPath(dir))
  asyncCheck result.acceptLoop(result.provider, chProvider)
  asyncCheck result.acceptLoop(result.consent, chConsent)

proc stop*(s: HostServer) =
  s.closed = true
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

proc request*(c: HostClient; payload: seq[byte]): Future[seq[byte]] {.async.} =
  ## Send one request frame and wait for its response frame; empty when
  ## the host closed the connection.
  let f = frame(payload)
  var str = newString(f.len)
  for i, b in f:
    str[i] = char(b)
  await c.sock.send(str)
  return await readFrame(c.sock)

proc close*(c: HostClient) = c.sock.close()

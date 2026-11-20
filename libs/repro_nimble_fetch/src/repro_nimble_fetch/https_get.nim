## One bounded HTTPS request, made to an address chosen before connecting.
##
## The Nimble source fetch reads two kinds of location over HTTPS, and both go
## through `httpsRequest`:
##
## * a **mirror** the client's configuration names (organization-local, or a
##   catalog's): its host is resolved through the policy's resolver and
##   connected to, without the origin address rules, because an
##   organization's mirror is often on an internal address. A mirror that
##   answers with a redirect is a failed read: the configuration names where
##   the bytes are, and nothing a mirror answers moves that.
## * an **origin's forge archive** (`fetchOriginArchive`): the URL is named by
##   the registry or a lock row, so it passes the origin egress policy of the
##   catalog generator (`repro_nimble_generator/egress`) at every hop: `https`
##   only, no credentials, every resolved address public, and each redirect's
##   target vetted the same way before it is followed (at most
##   `maxRedirects`).
##
## In both cases the TLS session is to the vetted (dialed) address with the
## URL's host as the server name and certificate identity, so a second DNS
## answer cannot redirect the connection. A response is bounded in bytes
## (`maxBytes`, refused as `erSize` while it arrives), in time without
## progress (`erStall`) and in time overall (`wallSeconds`, `erTimeout`), so
## a peer that trickles one byte at a time cannot hold a fetch open.
##
## `httpsRequestWith` takes only plain data (the trust-anchor path, the
## limits, the URL and the address), never the policy's resolver or dialer
## closures, so a worker thread can run it (`parallel_get`).

import std/[net, strutils, times]

import repro_nimble_generator/egress

type
  HttpsAnswer* = object
    status*: int
    location*: string
    body*: string
    contentLength*: int64 ## -1 when the answer had none

  RequestStep* = object
    ## One request of a redirect chain, for diagnostics and tests.
    url*: string
    status*: int

proc closeQuietly(s: Socket) =
  try: s.close() except CatchableError: discard

when defined(ssl):
  proc checkDeadline(u: OriginUrl; deadline: float; wallSeconds: int) =
    if deadline > 0 and epochTime() > deadline:
      refuse(erTimeout, u.url, "the answer took longer than " &
        $wallSeconds & " s")

  proc readBody(sock: Socket; u: OriginUrl; contentLength: int64;
                chunked: bool; maxBytes: int64; stallMs: int;
                deadline: float; wallSeconds: int): string =
    ## The body, bounded: by its length, by its chunks, or to the close; and
    ## in all by the wall-time ``deadline``.
    proc grow(acc: var string; data: string) =
      if int64(acc.len + data.len) > maxBytes:
        refuse(erSize, u.url, "the answer passed " & $maxBytes & " bytes")
      checkDeadline(u, deadline, wallSeconds)
      acc.add data
    if chunked:
      while true:
        let sizeLine = sock.recvLine(timeout = stallMs).strip()
        if sizeLine.len == 0:
          raise newException(IOError, "truncated chunked body from " & u.url)
        var n: int
        try:
          n = parseHexInt(sizeLine.split(';')[0])
        except ValueError:
          raise newException(IOError, "bad chunk size from " & u.url)
        if n == 0:
          discard sock.recvLine(timeout = stallMs)
          break
        if int64(result.len + n) > maxBytes:
          refuse(erSize, u.url, "the answer passed " & $maxBytes & " bytes")
        var got = 0
        while got < n:
          let part = sock.recv(min(65536, n - got), timeout = stallMs)
          if part.len == 0:
            raise newException(IOError, "truncated chunk from " & u.url)
          result.grow(part)
          got += part.len
        discard sock.recv(2, timeout = stallMs)
    elif contentLength >= 0:
      if contentLength > maxBytes:
        refuse(erSize, u.url, "the answer declares " & $contentLength &
          " bytes, more than " & $maxBytes)
      while int64(result.len) < contentLength:
        let part = sock.recv(int(min(65536'i64, contentLength - result.len)),
          timeout = stallMs)
        if part.len == 0:
          raise newException(IOError, "truncated body from " & u.url & ": " &
            $result.len & " of " & $contentLength & " bytes")
        result.grow(part)
    else:
      while true:
        let part = sock.recv(65536, timeout = stallMs)
        if part.len == 0: break
        result.grow(part)

proc httpsRequestWith*(caFile: string; limits: EgressLimits; meth: string;
                       u: OriginUrl; connectTo: IpAddress;
                       maxBytes: int64): HttpsAnswer {.gcsafe.} =
  ## One request (``meth`` is `GET` or `HEAD`) over TLS to ``connectTo``,
  ## with ``u.host`` as the server name, without following a redirect,
  ## trusting the anchors in ``caFile`` ("" for the host's default).
  ## Raises `EgressError` for a limit (`erSize`, `erStall`, `erTimeout`),
  ## `IOError` for a connection, TLS or protocol failure.
  when not defined(ssl):
    raise newException(IOError, "this build has no TLS (compile with -d:ssl)")
  else:
    let ctx = newContext(verifyMode = CVerifyPeer, caFile = caFile)
    defer: ctx.destroyContext()
    let domain = if connectTo.family == IpAddressFamily.IPv6: AF_INET6
                 else: AF_INET
    let sock = newSocket(domain, SOCK_STREAM, IPPROTO_TCP)
    defer: sock.closeQuietly()
    let stallMs = limits.stallSeconds * 1000
    let deadline =
      if limits.wallSeconds > 0: epochTime() + float(limits.wallSeconds)
      else: 0.0
    try:
      sock.connect($connectTo, Port(u.port), limits.connectTimeoutMs)
      ctx.wrapConnectedSocket(sock, handshakeAsClient, u.host)
      let hostHeader = (if ':' in u.host: "[" & u.host & "]" else: u.host) &
        (if u.explicitPort: ":" & $u.port else: "")
      sock.send(meth & " " & u.path & " HTTP/1.1\r\nHost: " & hostHeader &
        "\r\nUser-Agent: reprobuild-nimble-fetch/1\r\nAccept: */*\r\n" &
        "Accept-Encoding: identity\r\nConnection: close\r\n\r\n")
      let statusLine = sock.recvLine(timeout = stallMs)
      let parts = statusLine.split(' ')
      if parts.len < 2 or not parts[0].startsWith("HTTP/"):
        raise newException(IOError, "not an HTTP answer from " & u.url)
      try:
        result.status = parseInt(parts[1])
      except ValueError:
        raise newException(IOError, "bad HTTP status from " & u.url)
      result.contentLength = -1
      var chunked = false
      var n = 0
      while true:
        inc n
        if n > 200:
          raise newException(IOError, "too many header lines from " & u.url)
        let line = sock.recvLine(timeout = stallMs)
        checkDeadline(u, deadline, limits.wallSeconds)
        if line.len == 0 or line == "\r\n":
          break
        let c = line.find(':')
        if c <= 0: continue
        let name = line[0 ..< c].strip().toLowerAscii()
        let value = line[c + 1 .. ^1].strip()
        case name
        of "location": result.location = value
        of "content-length":
          try: result.contentLength = parseBiggestInt(value)
          except ValueError:
            raise newException(IOError, "bad Content-Length from " & u.url)
        of "transfer-encoding":
          chunked = "chunked" in value.toLowerAscii()
        else: discard
      if meth != "HEAD" and result.status == 200:
        result.body = readBody(sock, u, result.contentLength, chunked,
          maxBytes, stallMs, deadline, limits.wallSeconds)
    except TimeoutError as e:
      refuse(erStall, u.url, "no progress for " & $limits.stallSeconds &
        " s: " & e.msg)
    except EgressError:
      raise
    except IOError:
      raise
    except CatchableError as e:
      raise newException(IOError, u.url & ": " & e.msg)

proc httpsRequest*(policy: EgressPolicy; meth: string; u: OriginUrl;
                   connectTo: IpAddress; maxBytes: int64): HttpsAnswer =
  ## `httpsRequestWith` under ``policy``'s trust anchors and limits.
  httpsRequestWith(policy.caFile, policy.limits, meth, u, connectTo, maxBytes)

proc mirrorRequest*(policy: EgressPolicy; meth, url: string;
                    maxBytes: int64): HttpsAnswer =
  ## A request to a configured mirror: resolved without the origin address
  ## rules (see the module docstring), never redirected.
  let u = parseOriginUrl(url)
  let addrs = resolveHost(policy, u)
  httpsRequest(policy, meth, u, dialed(policy, addrs[0]), maxBytes)

proc resolveRedirect(base: OriginUrl; location: string): string =
  if location.contains("://"):
    return location
  if location.startsWith("//"):
    return "https:" & location
  let h = if ':' in base.host: "[" & base.host & "]" else: base.host
  let authority = "https://" & h &
    (if base.explicitPort: ":" & $base.port else: "")
  if location.startsWith("/"):
    return authority & location
  var dir = base.path
  let q = dir.find('?')
  if q >= 0: dir = dir[0 ..< q]
  let s = dir.rfind('/')
  dir = if s >= 0: dir[0 .. s] else: "/"
  authority & dir & location

proc fetchOriginArchive*(policy: EgressPolicy; url: string; maxBytes: int64;
                         steps: var seq[RequestStep]): string =
  ## GET an origin's archive under the origin egress policy, re-vetting every
  ## redirect target before it is contacted. Returns the body of the final
  ## `200`; raises `EgressError` for a refusal and `IOError` for any other
  ## answer.
  var current = parseOriginUrl(url)
  var hops = 0
  let start = epochTime()
  while true:
    let addrs = vetHost(policy, current)
    let answer = httpsRequest(policy, "GET", current,
      dialed(policy, addrs[0]), maxBytes)
    steps.add RequestStep(url: current.url, status: answer.status)
    if answer.status in [301, 302, 303, 307, 308]:
      inc hops
      if hops > policy.limits.maxRedirects:
        refuse(erRedirect, current.url, "more than " &
          $policy.limits.maxRedirects & " redirects")
      if answer.location.len == 0:
        raise newException(IOError, current.url & " redirects nowhere")
      current = parseOriginUrl(resolveRedirect(current, answer.location))
      if epochTime() - start > float(policy.limits.wallSeconds):
        refuse(erTimeout, current.url, "the archive took longer than " &
          $policy.limits.wallSeconds & " s")
      continue
    if answer.status != 200:
      raise newException(IOError, current.url & " answered " &
        $answer.status)
    return answer.body

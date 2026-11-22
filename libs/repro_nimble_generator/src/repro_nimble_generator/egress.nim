## The origin egress policy of the Nimble catalog generator.
##
## Every origin a generator edge contacts is named by someone the catalog
## does not control: a registry entry, an `[[extra]]`, a `.gitmodules` of a
## package, a redirect an origin answers with. Before anything is fetched
## the URL passes this policy, and the connection is then made only to the
## addresses the policy vetted:
##
## 1. **Scheme.** `https://host[:port]/path` only. `file`, `ssh`, `git`,
##    `http`, `ext::`, scp-like `user@host:path` and every other spelling are
##    refused, and so is a URL that carries credentials (`user@host`).
## 2. **Addresses.** The host is resolved, and EVERY address it resolves to
##    must be a public unicast address: loopback, private (RFC 1918, unique
##    local), shared (100.64/10), link-local, cloud metadata, unspecified,
##    multicast, broadcast and reserved addresses are refused, including in
##    their IPv4-mapped, IPv4-compatible, NAT64 and 6to4 IPv6 spellings
##    (everything outside 2000::/3, the local-use NAT64 prefix included, is
##    reserved).
## 3. **Redirects.** The generator asks the origin for its smart-HTTP
##    discovery document itself, without following redirects, and applies
##    rules 1 and 2 to each `Location` before following it (at most
##    `maxRedirects`). Git is then run against the final URL with redirects
##    off, so git never follows one the policy did not check.
## 4. **Pinning.** Git's HTTP client is told the vetted addresses
##    (`http.curloptResolve`), so a second, different DNS answer at
##    connection time (rebinding) cannot reach an address that was not
##    checked.
## 5. **Limits.** A fetch is bounded in bytes, in time without progress
##    (stall) and in wall time; exceeding one is a refusal (`origin_git`).
##
## The policy is the first layer; the git invocation adds a second
## (`protocol.allow=never` with only `https` allowed, no configuration from
## the host), so a transport the first layer missed is still refused.
##
## The resolver and the dialer are fields of the policy so a test can run
## the real checks against a local HTTPS server: its resolver answers a
## public address for the test's host name, and its dialer connects that
## address to the local server. The address the policy checks is the one
## the resolver answered; production uses the system resolver and dials the
## vetted address itself.

import std/[nativesockets, net, os, strutils]

type
  EgressRefusalKind* = enum
    erScheme = "scheme"
      ## not `https://`
    erCredentials = "credentials"
      ## the URL carries a user or password
    erMalformed = "malformed"
      ## no host, a host that is not a DNS name or an address literal
    erResolve = "resolve"
      ## the host does not resolve
    erAddress = "address"
      ## the host resolves to an address outside the public unicast space
    erRedirect = "redirect"
      ## too many redirects, or one the policy cannot follow
    erSize = "size"
      ## the transfer exceeded the byte limit
    erStall = "stall"
      ## the transfer made no progress for the stall limit
    erTimeout = "timeout"
      ## the transfer exceeded the wall-time limit

  AddressClass* = enum
    acPublic = "public"
    acLoopback = "loopback"
    acPrivate = "private"
    acShared = "shared"           ## 100.64.0.0/10 (carrier-grade NAT)
    acLinkLocal = "link-local"
    acMetadata = "metadata"       ## cloud instance metadata endpoints
    acUnspecified = "unspecified"
    acMulticast = "multicast"
    acBroadcast = "broadcast"
    acReserved = "reserved"

  EgressRefusal* = object
    kind*: EgressRefusalKind
    url*: string      ## the URL that was refused (the redirect target, for a redirect)
    detail*: string
    address*: string  ## the refused address, for `erAddress`
    addressClass*: AddressClass

  EgressError* = object of CatchableError
    refusal*: EgressRefusal

  OriginUrl* = object
    url*: string  ## as given
    host*: string ## lower case, without brackets
    port*: int    ## 443 unless given
    path*: string ## from the first `/` after the authority, `/` at least
    explicitPort*: bool

  Resolver* = proc(host: string): seq[IpAddress] {.gcsafe.}
  Dialer* = proc(address: IpAddress): IpAddress {.gcsafe.}

  EgressLimits* = object
    maxBytes*: int64      ## bytes one fetch may transfer and store
    stallSeconds*: int    ## seconds without progress before a fetch is cut
    wallSeconds*: int     ## seconds a fetch may take in all
    maxRedirects*: int
    connectTimeoutMs*: int

  EgressPolicy* = object
    limits*: EgressLimits
    resolver*: Resolver   ## nil: the system resolver
    dialer*: Dialer       ## nil: connect to the vetted address itself
    caFile*: string
      ## the trust anchors for origin TLS; empty: the host's default bundle
      ## (`defaultCaFile`)

  VettedOrigin* = object
    ## An origin that passed the policy: the URL git is to be run against
    ## (after any redirects) and the address its host is pinned to.
    requested*: string
    final*: OriginUrl
    addresses*: seq[IpAddress]   ## the vetted addresses of ``final.host``
    connectTo*: seq[IpAddress]   ## what the dialer maps them to
    redirects*: seq[string]

const
  DefaultLimits* = EgressLimits(maxBytes: 512'i64 * 1024 * 1024,
    stallSeconds: 60, wallSeconds: 900, maxRedirects: 5,
    connectTimeoutMs: 15_000)
  UploadPackDiscovery* = "/info/refs?service=git-upload-pack"

proc refuse*(kind: EgressRefusalKind; url, detail: string;
             address = ""; cls = acPublic) {.noreturn.} =
  var e = newException(EgressError, "origin refused (" & $kind & "): " &
    url & ": " & detail)
  e.refusal = EgressRefusal(kind: kind, url: url, detail: detail,
    address: address, addressClass: cls)
  raise e

# ---------------------------------------------------------------------------
# URL
# ---------------------------------------------------------------------------

proc parseOriginUrl*(url: string): OriginUrl =
  ## Rule 1: an `https://` URL without credentials, with a DNS-name or
  ## address-literal host. Raises `EgressError` (`erScheme`,
  ## `erCredentials`, `erMalformed`).
  result.url = url
  if url.startsWith("ext::") or "::" in url.split("/")[0]:
    refuse(erScheme, url, "a git remote helper (`<transport>::`) is not an " &
      "origin; only https is fetched")
  let sep = url.find("://")
  if sep < 0:
    refuse(erScheme, url, "has no scheme (an scp-like `host:path` is ssh); " &
      "only https is fetched")
  let scheme = url[0 ..< sep].toLowerAscii()
  if scheme != "https":
    refuse(erScheme, url, "scheme " & scheme.escape() & " is not fetched; " &
      "only https is")
  for ch in url:
    if ord(ch) <= 0x20 or ord(ch) >= 0x7f or ch in {'\\', '#'}:
      refuse(erMalformed, url, "contains whitespace, a control or non-ASCII " &
        "character, a backslash or a fragment")
  var rest = url[sep + 3 .. ^1]
  let slash = rest.find('/')
  var authority = if slash < 0: rest else: rest[0 ..< slash]
  result.path = if slash < 0: "/" else: rest[slash .. ^1]
  let q = result.path.find('?')
  if q >= 0:
    result.path = result.path[0 ..< q]
  if '@' in authority:
    refuse(erCredentials, url, "carries credentials; an origin is fetched " &
      "without any")
  if authority.len == 0:
    refuse(erMalformed, url, "has no host")
  var host = authority
  var portText = ""
  if host.startsWith("["):
    let close = host.find(']')
    if close < 0:
      refuse(erMalformed, url, "an IPv6 literal is not closed")
    if close + 1 < host.len:
      if host[close + 1] != ':':
        refuse(erMalformed, url, "unexpected text after the IPv6 literal")
      portText = host[close + 2 .. ^1]
    host = host[1 ..< close]
    if not isIpAddress(host):
      refuse(erMalformed, url, "the bracketed host is not an IPv6 address")
  else:
    let colon = host.rfind(':')
    if colon >= 0:
      portText = host[colon + 1 .. ^1]
      host = host[0 ..< colon]
    if host.endsWith("."):
      host.setLen(host.len - 1)
    if host.len == 0 or host.len > 253:
      refuse(erMalformed, url, "has no host or an overlong one")
    for label in host.split('.'):
      if label.len == 0 or label.len > 63 or label[0] == '-' or
          label[^1] == '-':
        refuse(erMalformed, url, "host " & host.escape() & " is not a DNS " &
          "name or an IPv4 address")
      for c in label:
        if c notin {'a'..'z', 'A'..'Z', '0'..'9', '-'}:
          refuse(erMalformed, url, "host " & host.escape() & " is not a " &
            "DNS name or an IPv4 address")
  result.host = host.toLowerAscii()
  result.port = 443
  if portText.len > 0:
    if not portText.allCharsInSet({'0'..'9'}) or portText.len > 5:
      refuse(erMalformed, url, "port " & portText.escape() & " is not a number")
    result.port = parseInt(portText)
    result.explicitPort = true
    if result.port < 1 or result.port > 65535:
      refuse(erMalformed, url, "port " & portText & " is out of range")

proc baseUrl*(u: OriginUrl): string =
  ## ``u`` as a URL again, without a query.
  let h = if ':' in u.host: "[" & u.host & "]" else: u.host
  "https://" & h & (if u.explicitPort: ":" & $u.port else: "") & u.path

# ---------------------------------------------------------------------------
# Addresses
# ---------------------------------------------------------------------------

proc classifyV4(b: array[4, uint8]): AddressClass =
  let (a, b1, c, d) = (b[0], b[1], b[2], b[3])
  if a == 169 and b1 == 254 and c == 169 and d == 254: return acMetadata
  if a == 100 and b1 == 100 and c == 100 and d == 200: return acMetadata
  if a == 0: return acUnspecified
  if a == 127: return acLoopback
  if a == 10: return acPrivate
  if a == 172 and (b1 and 0xf0) == 16: return acPrivate
  if a == 192 and b1 == 168: return acPrivate
  if a == 100 and (b1 and 0xc0) == 64: return acShared
  if a == 169 and b1 == 254: return acLinkLocal
  if a == 192 and b1 == 0 and c == 0: return acReserved  # IETF protocol assignments
  if a == 198 and (b1 and 0xfe) == 18: return acReserved # benchmarking
  if a == 255 and b1 == 255 and c == 255 and d == 255: return acBroadcast
  if a >= 224 and a <= 239: return acMulticast
  if a >= 240: return acReserved
  acPublic

proc classifyAddress*(ip: IpAddress): AddressClass =
  ## Rule 2. Only `acPublic` may be contacted.
  case ip.family
  of IpAddressFamily.IPv4:
    classifyV4(ip.address_v4)
  of IpAddressFamily.IPv6:
    let b = ip.address_v6
    var allZero = true
    for i in 0 ..< 16:
      if b[i] != 0: allZero = false
    if allZero: return acUnspecified
    var loop = true
    for i in 0 ..< 15:
      if b[i] != 0: loop = false
    if loop and b[15] == 1: return acLoopback
    # IPv4-mapped ::ffff:a.b.c.d and IPv4-compatible ::a.b.c.d
    var prefixZero = true
    for i in 0 ..< 10:
      if b[i] != 0: prefixZero = false
    if prefixZero and ((b[10] == 0xff and b[11] == 0xff) or
        (b[10] == 0 and b[11] == 0)):
      return classifyV4([b[12], b[13], b[14], b[15]])
    # NAT64 64:ff9b::/96
    if b[0] == 0 and b[1] == 0x64 and b[2] == 0xff and b[3] == 0x9b:
      var mid = true
      for i in 4 ..< 12:
        if b[i] != 0: mid = false
      if mid:
        return classifyV4([b[12], b[13], b[14], b[15]])
    # AWS metadata fd00:ec2::254
    if b[0] == 0xfd and b[1] == 0 and b[2] == 0x0e and b[3] == 0xc2:
      var rest = true
      for i in 4 ..< 14:
        if b[i] != 0: rest = false
      if rest and b[14] == 0x02 and b[15] == 0x54: return acMetadata
    if (b[0] and 0xfe) == 0xfc: return acPrivate     # fc00::/7
    if b[0] == 0xfe and (b[1] and 0xc0) == 0x80: return acLinkLocal # fe80::/10
    if b[0] == 0xfe and (b[1] and 0xc0) == 0xc0: return acPrivate   # fec0::/10
    if b[0] == 0xff: return acMulticast
    if b[0] == 0x20 and b[1] == 0x02:                 # 6to4 2002::/16
      return classifyV4([b[2], b[3], b[4], b[5]])
    if (b[0] and 0xe0) != 0x20: return acReserved     # outside 2000::/3
    acPublic

proc systemResolve(host: string): seq[IpAddress] =
  var info: ptr AddrInfo
  try:
    info = getAddrInfo(host, Port(443), AF_UNSPEC, SOCK_STREAM, IPPROTO_TCP)
  except OSError:
    return @[]
  var it = info
  while it != nil:
    if it.ai_addr != nil:
      var ip: IpAddress
      var port: Port
      try:
        fromSockAddr(cast[ptr Sockaddr_storage](it.ai_addr)[],
          SockLen(it.ai_addrlen), ip, port)
        if ip notin result: result.add ip
      except CatchableError:
        discard
    it = it.ai_next
  freeAddrInfo(info)

proc resolveHost*(policy: EgressPolicy; u: OriginUrl): seq[IpAddress] =
  ## The addresses ``u.host`` resolves to (an address literal is itself),
  ## through the policy's resolver, WITHOUT classifying them. Rule 2 for an
  ## origin is `vetHost`; this alone is for a location the operator
  ## configured (a mirror), which may be organization-internal. Raises
  ## `EgressError` (`erResolve`) when nothing answers.
  if isIpAddress(u.host):
    result = @[parseIpAddress(u.host)]
  elif policy.resolver != nil:
    result = policy.resolver(u.host)
  else:
    result = systemResolve(u.host)
  if result.len == 0:
    refuse(erResolve, u.url, "host " & u.host.escape() & " does not resolve")

proc vetHost*(policy: EgressPolicy; u: OriginUrl): seq[IpAddress] =
  ## Rule 2 for one host: every address it resolves to, each public.
  result = resolveHost(policy, u)
  for ip in result:
    let cls = classifyAddress(ip)
    if cls != acPublic:
      refuse(erAddress, u.url, "host " & u.host.escape() & " resolves to " &
        $ip & ", a " & $cls & " address", $ip, cls)

proc dialed*(policy: EgressPolicy; ip: IpAddress): IpAddress =
  if policy.dialer == nil: ip else: policy.dialer(ip)

proc defaultCaFile*(): string =
  ## The host's trust anchors for origin TLS, named explicitly because git
  ## runs with an environment built from nothing.
  for v in ["SSL_CERT_FILE", "NIX_SSL_CERT_FILE"]:
    let f = getEnv(v)
    if f.len > 0 and fileExists(f): return f
  for f in ["/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt",
            "/etc/ssl/cert.pem"]:
    if fileExists(f): return f
  ""

proc defaultPolicy*(): EgressPolicy =
  EgressPolicy(limits: DefaultLimits, caFile: defaultCaFile())

# ---------------------------------------------------------------------------
# Rule 3: discovery without following redirects
# ---------------------------------------------------------------------------

proc resolveLocation(base: OriginUrl; location: string): string =
  if location.startsWith("https://") or location.contains("://"):
    return location
  if location.startsWith("//"):
    return "https:" & location
  let h = if ':' in base.host: "[" & base.host & "]" else: base.host
  let authority = "https://" & h & (if base.explicitPort: ":" & $base.port else: "")
  if location.startsWith("/"):
    return authority & location
  var dir = base.path
  let s = dir.rfind('/')
  dir = if s >= 0: dir[0 .. s] else: "/"
  authority & dir & location

when defined(ssl):
  proc discoveryStatus(policy: EgressPolicy; u: OriginUrl;
                       connectTo: IpAddress): tuple[status: int;
                         location: string] =
    ## One discovery request over TLS to ``connectTo`` with ``u.host`` as the
    ## TLS name, without following redirects: the status and `Location`.
    let ctx = newContext(verifyMode = CVerifyPeer, caFile = policy.caFile)
    defer: ctx.destroyContext()
    let domain = if connectTo.family == IpAddressFamily.IPv6: AF_INET6
                 else: AF_INET
    let sock = newSocket(domain, SOCK_STREAM, IPPROTO_TCP)
    defer: sock.close()
    try:
      sock.connect($connectTo, Port(u.port), policy.limits.connectTimeoutMs)
      ctx.wrapConnectedSocket(sock, handshakeAsClient, u.host)
      let path = u.path.strip(leading = false, chars = {'/'}) &
        UploadPackDiscovery
      let hostHeader = (if ':' in u.host: "[" & u.host & "]" else: u.host) &
        (if u.explicitPort: ":" & $u.port else: "")
      sock.send("GET " & path & " HTTP/1.1\r\nHost: " & hostHeader &
        "\r\nUser-Agent: git/2 (reprobuild nimble generator)\r\n" &
        "Accept: */*\r\nConnection: close\r\n\r\n")
      let deadline = policy.limits.stallSeconds * 1000
      let statusLine = sock.recvLine(timeout = deadline)
      let parts = statusLine.split(' ')
      if parts.len < 2 or not parts[0].startsWith("HTTP/"):
        return (0, "")
      result.status = parseInt(parts[1])
      var n = 0
      while n < 100:
        inc n
        let line = sock.recvLine(timeout = deadline)
        if line.len == 0 or line == "\r\n":
          break
        let c = line.find(':')
        if c > 0 and line[0 ..< c].toLowerAscii() == "location":
          result.location = line[c + 1 .. ^1].strip()
    except TimeoutError as e:
      refuse(erStall, u.url, "the origin did not answer discovery within " &
        $policy.limits.stallSeconds & " s: " & e.msg)
    except CatchableError as e:
      return (-1, e.msg)

type
  VetProgress* = object
    ## How far ``vetOriginFrom`` got: the URL it is vetting and the
    ## redirects it followed to reach it. Vetting resumes from it, so a
    ## caller that had to stop (a host only another thread's resolver can
    ## answer) continues without repeating a discovery request.
    current*: string
    hops*: int
    redirects*: seq[string]

proc vetOriginFrom*(policy: EgressPolicy; requested: string;
                    progress: var VetProgress): VettedOrigin =
  ## ``vetOrigin`` from ``progress`` on, keeping ``progress`` up to date as
  ## it goes: when it raises, ``progress`` names the URL whose host was
  ## being vetted.
  result.requested = requested
  var current = parseOriginUrl(progress.current)
  var hops = progress.hops
  result.redirects = progress.redirects
  while true:
    progress = VetProgress(current: current.url, hops: hops,
      redirects: result.redirects)
    let addrs = vetHost(policy, current)
    result.final = current
    result.addresses = addrs
    result.connectTo = @[]
    for a in addrs: result.connectTo.add dialed(policy, a)
    when defined(ssl):
      let (status, location) = discoveryStatus(policy, current,
        result.connectTo[0])
      if status in [301, 302, 303, 307, 308]:
        inc hops
        if hops > policy.limits.maxRedirects:
          refuse(erRedirect, current.url, "more than " &
            $policy.limits.maxRedirects & " redirects")
        let target = resolveLocation(current, location)
        if not target.endsWith(UploadPackDiscovery):
          refuse(erRedirect, target, "a redirect that does not keep the " &
            "discovery path cannot be followed as a repository")
        result.redirects.add target
        let next = target[0 ..< target.len - UploadPackDiscovery.len]
        current = parseOriginUrl(next)
        continue
    # Without -d:ssl there is no discovery request, so no redirect is
    # followed at all: git runs with redirects off and fails on one.
    return

proc vetOrigin*(policy: EgressPolicy; url: string): VettedOrigin =
  ## Rules 1-3: the URL, its addresses, and every redirect its discovery
  ## answers with. Raises `EgressError` for a refusal. A discovery that
  ## fails otherwise (connection refused, 404, TLS) is not a refusal: the
  ## final URL is returned and git's own run reports the failure.
  var progress = VetProgress(current: url)
  vetOriginFrom(policy, url, progress)

proc curloptResolve*(v: VettedOrigin): string =
  ## Rule 4: git's `http.curloptResolve` value pinning the final host to the
  ## vetted (dialed) addresses.
  var addrs: seq[string]
  for a in v.connectTo:
    addrs.add(if a.family == IpAddressFamily.IPv6: "[" & $a & "]" else: $a)
  v.final.host & ":" & $v.final.port & ":" & addrs.join(",")

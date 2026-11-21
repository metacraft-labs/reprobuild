## Declared-interface resolution for listeners — Distributed-Execution M7
## (deployment-security-architecture.md FLOW-6: "the listener binds the
## narrowest interface that works").
##
## A peer-cache or worker listener never binds a wildcard address. The
## peer-cache policy DECLARES what it binds — an interface name (`en0`,
## `wt0`, `utun4`, `lo0`) or an address assigned to one — and this module
## turns that declaration into the one IPv4 address to bind, refusing
## anything that would widen it:
##
## * `0.0.0.0`, `::`, `*`, `any` and the empty-string-as-wildcard are
##   refused outright, with the reason;
## * an address must be assigned to a local interface (binding a foreign
##   address would fail anyway, but the check names the problem);
## * an interface must exist and carry exactly the IPv4 address used; when
##   it carries several, the first is used and the others are reported so
##   the declaration can be made exact by naming the address instead.
##
## No declaration means loopback: a node that was told nothing serves only
## its own host, which is the narrowest interface that works for the
## single-host cases (`repro test`'s local peer cache, tests).

import std/[net, strutils]

when defined(posix):
  import std/posix

const
  WildcardSpellings* = ["0.0.0.0", "::", "[::]", "*", "any", "0"]

type
  BindResolution* = object
    ok*: bool
    address*: string
      ## The IPv4 address to bind.
    interfaceName*: string
      ## The interface that carries it ("" when unknown).
    isLoopback*: bool
    reason*: string
      ## Why resolution failed, or a note (several addresses) on success.

  LocalAddress* = object
    interfaceName*: string
    address*: string
    isLoopback*: bool

when defined(posix):
  type
    Ifaddrs {.importc: "struct ifaddrs", header: "<ifaddrs.h>",
              incompleteStruct.} = object
      ifa_next: ptr Ifaddrs
      ifa_name: cstring
      ifa_flags: cuint
      ifa_addr: ptr SockAddr

  proc c_getifaddrs(ifap: ptr ptr Ifaddrs): cint {.importc: "getifaddrs",
    header: "<ifaddrs.h>".}
  proc c_freeifaddrs(ifa: ptr Ifaddrs) {.importc: "freeifaddrs",
    header: "<ifaddrs.h>".}

proc localIpv4Addresses*(): seq[LocalAddress] =
  ## Every IPv4 address assigned to a local interface. Empty when the
  ## platform offers no enumeration (the caller then accepts only loopback
  ## and explicit literals).
  when defined(posix):
    var head: ptr Ifaddrs = nil
    if c_getifaddrs(addr head) != 0:
      return @[]
    defer: c_freeifaddrs(head)
    var cur = head
    while cur != nil:
      if cur.ifa_addr != nil and cint(cur.ifa_addr.sa_family) == AF_INET:
        let sin = cast[ptr Sockaddr_in](cur.ifa_addr)
        let raw = cast[array[4, uint8]](sin.sin_addr.s_addr)
        let text = $raw[0] & "." & $raw[1] & "." & $raw[2] & "." & $raw[3]
        result.add(LocalAddress(interfaceName: $cur.ifa_name,
          address: text, isLoopback: raw[0] == 127'u8))
      cur = cur.ifa_next
  else:
    result = @[LocalAddress(interfaceName: "loopback", address: "127.0.0.1",
      isLoopback: true)]

proc isWildcard*(spec: string): bool =
  spec.strip().toLowerAscii in WildcardSpellings

proc isIpv4Literal(spec: string): bool =
  try:
    let ip = parseIpAddress(spec)
    ip.family == IpAddressFamily.IPv4
  except ValueError:
    false

proc resolveBindSpec*(spec: string): BindResolution =
  ## See the module doc. `spec` is the declared interface or address.
  let s = spec.strip()
  if s.len == 0:
    return BindResolution(ok: true, address: "127.0.0.1",
      interfaceName: "loopback", isLoopback: true,
      reason: "no interface declared: bound to loopback only")
  if isWildcard(s):
    return BindResolution(ok: false, reason: "'" & s & "' is a wildcard " &
      "address; a listener binds the named LAN or overlay interface the " &
      "peer-cache policy declares (FLOW-6), e.g. bind=wt0 or bind=<address>")
  let locals = localIpv4Addresses()
  if isIpv4Literal(s):
    if s.startsWith("127."):
      return BindResolution(ok: true, address: s, interfaceName: "loopback",
        isLoopback: true)
    for la in locals:
      if la.address == s:
        return BindResolution(ok: true, address: s,
          interfaceName: la.interfaceName, isLoopback: la.isLoopback)
    return BindResolution(ok: false, reason: "address " & s &
      " is not assigned to any local interface")
  var matches: seq[LocalAddress] = @[]
  for la in locals:
    if la.interfaceName == s:
      matches.add(la)
  if matches.len == 0:
    return BindResolution(ok: false, reason: "interface '" & s &
      "' does not exist or carries no IPv4 address")
  result = BindResolution(ok: true, address: matches[0].address,
    interfaceName: s, isLoopback: matches[0].isLoopback)
  if matches.len > 1:
    var others: seq[string] = @[]
    for m in matches[1 .. ^1]: others.add(m.address)
    result.reason = "interface '" & s & "' carries several IPv4 addresses; " &
      "bound " & matches[0].address & " (also: " & others.join(", ") &
      "); name the address to choose another"

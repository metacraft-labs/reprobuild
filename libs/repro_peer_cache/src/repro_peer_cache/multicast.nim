## Peer-cache UDP multicast helpers — Peer-Cache M2.
##
## Nim's `std/asyncnet` doesn't expose multicast socket options. We
## therefore bind a `std/nativesockets` UDP socket (raw `SocketHandle`),
## set the `IP_ADD_MEMBERSHIP` / `SO_REUSEADDR` / `IP_MULTICAST_LOOP`
## options through the POSIX `setsockopt` import, and wrap the resulting
## FD via `asyncnet.newAsyncSocket(fd)` for the async recv loop.
##
## The constants `IP_ADD_MEMBERSHIP`, `IP_MULTICAST_LOOP`,
## `IP_MULTICAST_TTL`, and the `ip_mreq` struct are pulled in from
## `<netinet/in.h>` via `importc`. The exact integer value differs
## across kernels (Linux uses 35 for `IP_ADD_MEMBERSHIP`, BSD uses 12),
## so we let the C compiler resolve the symbol rather than hard-coding.
##
## On loopback testing: `IP_MULTICAST_LOOP` is enabled by default on
## Linux, so a peer's own multicast announcement reaches its own
## receiver. The M2 verification test handles self-reception by
## dropping packets whose `Hello.peerId` equals the receiver's
## `selfPeerId`.
##
## Windows support: the Windows branch implements the same shape via
## `std/winlean` (ws2_32). A module-init `wsaInit` runs `WSAStartup`
## exactly once before the first socket is created; the socket and
## setsockopt calls use the winlean primitives with `<ws2tcpip.h>`'s
## `ip_mreq` struct + the four `IP_*` constants (`IP_ADD_MEMBERSHIP`,
## `IP_MULTICAST_IF`, `IP_MULTICAST_LOOP`, `IP_MULTICAST_TTL`)
## imported via `header: "<ws2tcpip.h>"`. The async wrap is the
## cross-platform `createAsyncNativeSocket` + `newAsyncSocket(fd)`
## idiom — `asyncdispatch`'s Windows backend registers the handle
## with the IOCP. Pure-data procs (`ipAddressToString`,
## `encodeHelloPacket`, `decodeHelloPacket`) remain cross-platform.

import std/[asyncnet, net]

import ./codec
import ./types

# ---------------------------------------------------------------------------
# Address helpers (cross-platform).
# ---------------------------------------------------------------------------

proc ipAddressToString*(ip: IpAddress): string =
  ## Stringifies an `IpAddress` (IPv4 form `A.B.C.D`). IPv6 is
  ## supported but the M2 multicast path is IPv4-only.
  $ip

# ---------------------------------------------------------------------------
# Socket creation + group join.
# ---------------------------------------------------------------------------

type
  MulticastSocketError* = object of CatchableError

when defined(posix):
  import std/[asyncdispatch, nativesockets, posix]

  const
    netinetIn = "<netinet/in.h>"
    arpaInet = "<arpa/inet.h>"

  type
    IpMreq* {.importc: "struct ip_mreq", header: netinetIn,
              bycopy.} = object
      imr_multiaddr* {.importc.}: InAddr
      imr_interface* {.importc.}: InAddr

  let
    IP_ADD_MEMBERSHIP* {.importc, header: netinetIn.}: cint
    IP_DROP_MEMBERSHIP* {.importc, header: netinetIn.}: cint
    IP_MULTICAST_LOOP* {.importc, header: netinetIn.}: cint
    IP_MULTICAST_TTL* {.importc, header: netinetIn.}: cint
    IP_MULTICAST_IF* {.importc, header: netinetIn.}: cint

  proc inet_addr(s: cstring): InAddrScalar
    {.importc, header: arpaInet.}

  proc ipAddressToInAddr(ip: IpAddress): InAddr =
    ## Converts an `IpAddress` (assumed IPv4) to the POSIX `InAddr`
    ## wire form expected by `setsockopt(IP_ADD_MEMBERSHIP, ...)`.
    doAssert ip.family == IpAddressFamily.IPv4,
      "peer-cache multicast is IPv4-only (got " & $ip.family & ")"
    let s = $ip
    result.s_addr = inet_addr(s.cstring)

  proc newMulticastReceiverSocket*(group: MulticastGroup): AsyncSocket =
    ## Creates a UDP socket, sets `SO_REUSEADDR`, binds it to the
    ## multicast group's port on `INADDR_ANY` (so any local interface
    ## that receives the multicast traffic delivers it), and joins the
    ## multicast group via `IP_ADD_MEMBERSHIP` with the configured
    ## `interfaceIp`.
    ##
    ## The returned socket is an `AsyncSocket` ready for `recvFrom`.
    ## Uses `createAsyncNativeSocket` so the FD is auto-registered with
    ## the current dispatcher's epoll/kqueue.
    let fd = createAsyncNativeSocket(
      Domain.AF_INET, SockType.SOCK_DGRAM, Protocol.IPPROTO_UDP)
    if fd.SocketHandle == osInvalidSocket:
      raise newException(MulticastSocketError,
        "multicast receiver: createAsyncNativeSocket failed")
    let nativeFd = fd.SocketHandle
    # Allow multiple sockets to bind the same multicast port on the
    # same host. This is required for the M2 loopback test where three
    # peers each open their own receiver on the same group + port.
    var reuse: cint = 1
    if setsockopt(nativeFd, posix.SOL_SOCKET, posix.SO_REUSEADDR,
                  addr reuse, SockLen(sizeof(reuse))) < 0:
      nativeFd.close()
      raise newException(MulticastSocketError,
        "multicast receiver: setsockopt SO_REUSEADDR failed")
    when declared(posix.SO_REUSEPORT):
      # Linux and macOS expose SO_REUSEPORT; required on macOS so two
      # receivers in the same process can bind the same group port. On
      # Linux it's redundant with SO_REUSEADDR for multicast but
      # harmless. Guarded by `when declared` so the call compiles out
      # on kernels that don't expose the constant.
      discard setsockopt(nativeFd, posix.SOL_SOCKET, posix.SO_REUSEPORT,
                         addr reuse, SockLen(sizeof(reuse)))
    # Bind to the multicast port on INADDR_ANY. We bind to ANY rather
    # than to the multicast address itself because some kernels reject
    # the latter; the IP_ADD_MEMBERSHIP join below restricts the
    # delivery scope to the configured group + interface.
    var bindAddr: Sockaddr_in
    bindAddr.sin_family = TSa_Family(posix.AF_INET)
    bindAddr.sin_port = nativesockets.htons(uint16(group.port))
    bindAddr.sin_addr.s_addr = InAddrScalar(0)  # INADDR_ANY
    if bindSocket(nativeFd, cast[ptr SockAddr](addr bindAddr),
                  SockLen(sizeof(bindAddr))) < 0:
      nativeFd.close()
      raise newException(MulticastSocketError,
        "multicast receiver: bind to port " & $group.port.int &
        " failed (errno " & $errno & ")")
    # Join the multicast group on the configured interface. Per POSIX
    # `ip_mreq`, `imr_multiaddr` is the group address, `imr_interface`
    # is the local interface IP (or INADDR_ANY).
    var mreq: IpMreq
    mreq.imr_multiaddr = ipAddressToInAddr(group.address)
    mreq.imr_interface = ipAddressToInAddr(group.interfaceIp)
    if setsockopt(nativeFd, posix.IPPROTO_IP, IP_ADD_MEMBERSHIP,
                  addr mreq, SockLen(sizeof(mreq))) < 0:
      nativeFd.close()
      raise newException(MulticastSocketError,
        "multicast receiver: IP_ADD_MEMBERSHIP failed on group " &
        $group.address & " interface " & $group.interfaceIp &
        " (errno " & $errno & ")")
    result = newAsyncSocket(fd, Domain.AF_INET,
                            SockType.SOCK_DGRAM, Protocol.IPPROTO_UDP,
                            buffered = false)

  proc newMulticastSenderSocket*(group: MulticastGroup): AsyncSocket =
    ## Creates a UDP socket configured for sending to a multicast group:
    ## `IP_MULTICAST_IF` is set to `group.interfaceIp` so the kernel
    ## routes the packet through the chosen local interface, and
    ## `IP_MULTICAST_LOOP` is left enabled so loopback testing receives
    ## the sender's own announcements (the receiver filters out
    ## self-announcements by peer ID).
    let fd = createAsyncNativeSocket(
      Domain.AF_INET, SockType.SOCK_DGRAM, Protocol.IPPROTO_UDP)
    if fd.SocketHandle == osInvalidSocket:
      raise newException(MulticastSocketError,
        "multicast sender: createAsyncNativeSocket failed")
    let nativeFd = fd.SocketHandle
    var ifaceAddr = ipAddressToInAddr(group.interfaceIp)
    if setsockopt(nativeFd, posix.IPPROTO_IP, IP_MULTICAST_IF,
                  addr ifaceAddr, SockLen(sizeof(ifaceAddr))) < 0:
      nativeFd.close()
      raise newException(MulticastSocketError,
        "multicast sender: IP_MULTICAST_IF failed on interface " &
        $group.interfaceIp & " (errno " & $errno & ")")
    var loopOn: uint8 = uint8(1)
    discard setsockopt(nativeFd, posix.IPPROTO_IP, IP_MULTICAST_LOOP,
                       addr loopOn, SockLen(sizeof(loopOn)))
    var ttl: uint8 = uint8(1)
    discard setsockopt(nativeFd, posix.IPPROTO_IP, IP_MULTICAST_TTL,
                       addr ttl, SockLen(sizeof(ttl)))
    result = newAsyncSocket(fd, Domain.AF_INET,
                            SockType.SOCK_DGRAM, Protocol.IPPROTO_UDP,
                            buffered = false)

  proc sendMulticastPacket*(sock: AsyncSocket; group: MulticastGroup;
                            data: string) =
    ## Posts a UDP packet to the multicast group via raw `posix.sendto`,
    ## bypassing `asyncnet.sendTo` (which routes through
    ## `getaddrinfo("239.x.y.z")` and surfaces EAI_NONAME on some
    ## Linux glibc versions for multicast literals).
    ##
    ## Since UDP `sendto` is non-blocking on the underlying FD (the
    ## async socket is set non-blocking by `newAsyncSocket`) and the
    ## kernel never blocks on a transient outbound multicast packet,
    ## this is intentionally synchronous: returning a `Future[void]`
    ## would just complete immediately on the dispatcher's next tick.
    ## The caller's enclosing async proc is unaffected.
    var destAddr: Sockaddr_in
    destAddr.sin_family = TSa_Family(posix.AF_INET)
    destAddr.sin_port = nativesockets.htons(uint16(group.port))
    destAddr.sin_addr = ipAddressToInAddr(group.address)
    let nativeFd = sock.getFd()
    discard posix.sendto(nativeFd, cstring(data), data.len,
                         0.cint,
                         cast[ptr SockAddr](addr destAddr),
                         SockLen(sizeof(destAddr)))

else:
  # Windows multicast layer (Dotfiles-Migration-Completion N7).
  # winlean exports the bare ws2_32 procs (`socket`, `bindSocket`,
  # `setsockopt`, `sendto`, `wsaStartup`, `closesocket`) and the
  # generic Winsock types (`Sockaddr_in`, `InAddr`, `SockLen`,
  # `SocketHandle`). The four `IP_*` multicast option constants and
  # the `ip_mreq` struct live in `<ws2tcpip.h>` and are pulled in
  # via `importc, header: "<ws2tcpip.h>"`.
  import std/[asyncdispatch, nativesockets, winlean]

  const
    ws2tcpip = "<ws2tcpip.h>"
    # IPPROTO_IP is `0` on every Winsock-compatible header; winlean
    # doesn't export it as an importc so we use the well-known
    # literal. (See `nativesockets.toInt(IPPROTO_IP)` which also
    # returns `0.cint` on the Windows branch.)
    IPPROTO_IP_WIN: cint = 0

  let
    IP_ADD_MEMBERSHIP_WIN* {.importc: "IP_ADD_MEMBERSHIP",
                              header: ws2tcpip.}: cint
    IP_MULTICAST_IF_WIN*   {.importc: "IP_MULTICAST_IF",
                              header: ws2tcpip.}: cint
    IP_MULTICAST_LOOP_WIN* {.importc: "IP_MULTICAST_LOOP",
                              header: ws2tcpip.}: cint
    IP_MULTICAST_TTL_WIN*  {.importc: "IP_MULTICAST_TTL",
                              header: ws2tcpip.}: cint

  type
    IpMreqWin* {.importc: "struct ip_mreq", header: ws2tcpip,
                 bycopy.} = object
      imr_multiaddr* {.importc.}: InAddr
      imr_interface* {.importc.}: InAddr

  # WSAStartup is idempotent within a process when the matching
  # WSACleanup count is observed; we never WSACleanup here because the
  # lifetime is the whole process. A single global flag avoids the
  # per-call WSAStartup overhead (which would still return 0 on a
  # warm winsock, but the syscall is non-zero cost).
  var wsaStarted {.global.}: bool

  proc wsaInit() =
    if wsaStarted:
      return
    var wsaData: WSAData
    let rc = wsaStartup(0x0202'i16, addr wsaData)
    if rc != 0:
      raise newException(MulticastSocketError,
        "multicast: WSAStartup(2.2) failed with rc=" & $rc)
    wsaStarted = true

  proc ipAddressToInAddrWin(ip: IpAddress): InAddr =
    ## Converts an `IpAddress` (assumed IPv4) to the Winsock `InAddr`
    ## wire form expected by `setsockopt(IP_ADD_MEMBERSHIP, ...)`.
    doAssert ip.family == IpAddressFamily.IPv4,
      "peer-cache multicast is IPv4-only (got " & $ip.family & ")"
    let s = $ip
    # winlean exports `inet_addr(cstring): uint32`; on Windows the
    # `InAddr.s_addr` field is `uint32`, so a direct assignment works
    # without the POSIX `InAddrScalar` wrapper.
    result.s_addr = winlean.inet_addr(s.cstring)

  proc newMulticastReceiverSocket*(group: MulticastGroup): AsyncSocket =
    ## Creates a UDP socket, sets `SO_REUSEADDR` (Windows: allows
    ## binding a port already bound by another socket — what we want
    ## for multicast on loopback where each peer needs its own
    ## receiver on the same port), binds to `INADDR_ANY:port`, and
    ## joins the multicast group via `IP_ADD_MEMBERSHIP`.
    ##
    ## The returned socket is wrapped with `newAsyncSocket(fd, ...)`
    ## after `createAsyncNativeSocket` registered the handle with the
    ## dispatcher's IOCP.
    wsaInit()
    let fd = createAsyncNativeSocket(
      Domain.AF_INET, SockType.SOCK_DGRAM, Protocol.IPPROTO_UDP)
    if fd.SocketHandle == osInvalidSocket:
      raise newException(MulticastSocketError,
        "multicast receiver: createAsyncNativeSocket failed")
    let nativeFd = fd.SocketHandle
    var reuse: cint = 1
    if winlean.setsockopt(nativeFd, winlean.SOL_SOCKET,
                          winlean.SO_REUSEADDR,
                          cast[pointer](addr reuse),
                          SockLen(sizeof(reuse))) < 0:
      discard winlean.closesocket(nativeFd)
      raise newException(MulticastSocketError,
        "multicast receiver: setsockopt SO_REUSEADDR failed " &
        "(WSAGetLastError=" & $wsaGetLastError() & ")")
    var bindAddr: Sockaddr_in
    bindAddr.sin_family = uint16(winlean.AF_INET)
    bindAddr.sin_port = nativesockets.htons(uint16(group.port))
    bindAddr.sin_addr.s_addr = 0'u32  # INADDR_ANY
    if winlean.bindSocket(nativeFd, cast[ptr SockAddr](addr bindAddr),
                          SockLen(sizeof(bindAddr))) < 0:
      discard winlean.closesocket(nativeFd)
      raise newException(MulticastSocketError,
        "multicast receiver: bind to port " & $group.port.int &
        " failed (WSAGetLastError=" & $wsaGetLastError() & ")")
    var mreq: IpMreqWin
    mreq.imr_multiaddr = ipAddressToInAddrWin(group.address)
    mreq.imr_interface = ipAddressToInAddrWin(group.interfaceIp)
    if winlean.setsockopt(nativeFd, IPPROTO_IP_WIN,
                          IP_ADD_MEMBERSHIP_WIN,
                          cast[pointer](addr mreq),
                          SockLen(sizeof(mreq))) < 0:
      discard winlean.closesocket(nativeFd)
      raise newException(MulticastSocketError,
        "multicast receiver: IP_ADD_MEMBERSHIP failed on group " &
        $group.address & " interface " & $group.interfaceIp &
        " (WSAGetLastError=" & $wsaGetLastError() & ")")
    result = newAsyncSocket(fd, Domain.AF_INET,
                            SockType.SOCK_DGRAM, Protocol.IPPROTO_UDP,
                            buffered = false)

  proc newMulticastSenderSocket*(group: MulticastGroup): AsyncSocket =
    ## Creates a UDP socket configured for sending to a multicast
    ## group: `IP_MULTICAST_IF` selects the outbound interface,
    ## `IP_MULTICAST_LOOP` is explicitly enabled (Windows default is
    ## already on; explicit for symmetry with the POSIX branch +
    ## documentation), and `IP_MULTICAST_TTL` is 1 for link-local
    ## scope (the loopback test path never crosses a router but the
    ## TTL is still load-bearing for the LAN-scope path).
    wsaInit()
    let fd = createAsyncNativeSocket(
      Domain.AF_INET, SockType.SOCK_DGRAM, Protocol.IPPROTO_UDP)
    if fd.SocketHandle == osInvalidSocket:
      raise newException(MulticastSocketError,
        "multicast sender: createAsyncNativeSocket failed")
    let nativeFd = fd.SocketHandle
    var ifaceAddr = ipAddressToInAddrWin(group.interfaceIp)
    if winlean.setsockopt(nativeFd, IPPROTO_IP_WIN,
                          IP_MULTICAST_IF_WIN,
                          cast[pointer](addr ifaceAddr),
                          SockLen(sizeof(ifaceAddr))) < 0:
      discard winlean.closesocket(nativeFd)
      raise newException(MulticastSocketError,
        "multicast sender: IP_MULTICAST_IF failed on interface " &
        $group.interfaceIp &
        " (WSAGetLastError=" & $wsaGetLastError() & ")")
    # IP_MULTICAST_LOOP on Windows takes a DWORD (cuint). Many
    # examples pass a single byte and it works thanks to a kernel
    # compatibility shim, but the documented type is DWORD; we use
    # cuint to match. Same for IP_MULTICAST_TTL.
    var loopOn: cuint = 1
    discard winlean.setsockopt(nativeFd, IPPROTO_IP_WIN,
                               IP_MULTICAST_LOOP_WIN,
                               cast[pointer](addr loopOn),
                               SockLen(sizeof(loopOn)))
    var ttl: cuint = 1
    discard winlean.setsockopt(nativeFd, IPPROTO_IP_WIN,
                               IP_MULTICAST_TTL_WIN,
                               cast[pointer](addr ttl),
                               SockLen(sizeof(ttl)))
    result = newAsyncSocket(fd, Domain.AF_INET,
                            SockType.SOCK_DGRAM, Protocol.IPPROTO_UDP,
                            buffered = false)

  proc sendMulticastPacket*(sock: AsyncSocket; group: MulticastGroup;
                            data: string) =
    ## Posts a UDP packet to the multicast group via raw
    ## `winlean.sendto`, bypassing `asyncnet.sendTo` (which routes
    ## through `getaddrinfo` and surfaces hostname resolution errors
    ## on multicast literals). UDP `sendto` on a non-blocking socket
    ## (which `newAsyncSocket` sets) is intentionally synchronous
    ## here: the kernel never blocks on a transient outbound
    ## multicast packet so a `Future[void]` would just complete on
    ## the dispatcher's next tick.
    var destAddr: Sockaddr_in
    destAddr.sin_family = uint16(winlean.AF_INET)
    destAddr.sin_port = nativesockets.htons(uint16(group.port))
    destAddr.sin_addr = ipAddressToInAddrWin(group.address)
    let nativeFd = sock.getFd()
    discard winlean.sendto(nativeFd,
                           cast[pointer](data.cstring),
                           cint(data.len),
                           0.cint,
                           cast[ptr SockAddr](addr destAddr),
                           SockLen(sizeof(destAddr)))

# ---------------------------------------------------------------------------
# Mkhello-as-multicast-packet helpers (cross-platform).
# ---------------------------------------------------------------------------

proc encodeHelloPacket*(hello: Hello): string =
  ## Encodes a `mkHello` frame for transmission as the multicast
  ## payload. Returns the wire bytes as a `string` so the caller can
  ## pass it directly to `asyncSocket.sendTo`.
  let frameBytes = encodeFrame(mkHello, encodeHello(hello))
  result = newString(frameBytes.len)
  for i, b in frameBytes:
    result[i] = char(b)

proc decodeHelloPacket*(data: string): Hello =
  ## Decodes a multicast `mkHello` packet. Raises
  ## `PeerCacheCodecError` (from `codec`) on malformed bytes.
  var raw = newSeq[byte](data.len)
  for i in 0 ..< data.len:
    raw[i] = byte(ord(data[i]))
  let frame = decodeFrame(raw)
  if frame.messageKind != mkHello:
    raise newException(PeerCacheCodecError,
      "multicast packet is not mkHello: got " & $frame.messageKind)
  decodeHello(frame.payload)

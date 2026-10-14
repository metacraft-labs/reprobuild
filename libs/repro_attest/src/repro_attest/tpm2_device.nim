## Talking to a TPM: the command transactions the quote seam needs, and
## the two ways of reaching a device.
##
## ## What this is for
##
## `tpm2_backend` assembles evidence and checks it; `tpm2` reads and
## writes the structures a TPM signs. Neither of them ever asked a TPM
## for anything, so the backend's source seam had exactly one
## implementation — a reader of artifacts somebody else had already
## captured — and no shipped program could produce evidence from a
## machine's own root of trust. This module is the missing half: it
## issues `TPM2_*` commands and returns what came back.
##
## It is deliberately a *command* layer and not a policy layer. It
## marshals a command, performs one transaction, refuses a response that
## is not well formed or that carries a non-zero response code, and
## hands the parameter bytes back. It decides nothing about which
## registers are worth quoting, what an acceptable measurement is, or
## whether a signature is genuine — all three live elsewhere, and two of
## them deliberately live on a verifier rather than on the machine being
## verified.
##
## ## The transaction, stated once
##
## Every TPM command is one request and one response over a byte stream,
## and both are big-endian with no alignment and no padding::
##
##   request:  tag:U16  commandSize:U32  commandCode:U32
##             handles…  [authorizationSize:U32  authArea]  parameters
##   response: tag:U16  responseSize:U32  responseCode:U32
##             handles…  [parameterSize:U32]  parameters  [authArea]
##
## Three details in there are the ones that bite:
##
##   * `commandSize` counts the ten header bytes as well as the body, so
##     it cannot be written until the body exists. It is composed here
##     rather than patched in place, because a size field written twice
##     is a size field that can disagree with itself.
##   * **Response handles come before `parameterSize`, not after.** A
##     reader that took the parameter size first would read a handle as
##     a length and then read a few billion bytes of nothing.
##   * The `parameterSize` field exists only when the tag says
##     sessions. A command sent without an auth area gets a response
##     with no parameter size, and assuming one either way mis-reads
##     every byte after it.
##
## A non-zero `responseCode` is a refusal and never a value: the
## parameter area of an error response is empty, so a caller that
## ignored the code would parse zero bytes as a structure. The code
## travels on the exception, because one caller — start-up — genuinely
## needs to tell "the TPM was already initialised" from every other way
## a command can fail.
##
## ## Authorization
##
## Only the password session is implemented, with an empty password:
## the `TPM_RS_PW` handle, no nonce, no attributes, no HMAC. That is
## what a hierarchy with no owner authorization set and an object with
## `userWithAuth` accept, which is the state a measured-boot machine's
## attestation key is normally created in. An HMAC or policy session is
## a different shape and is not guessed at here — a build that needs one
## adds it, rather than having this one pretend.
##
## ## The two transports
##
##   * **A character device** — `/dev/tpmrm0` (the kernel's resource
##     manager, which virtualises handle slots between callers) or
##     `/dev/tpm0` (the raw device, one caller at a time). One `write`
##     carries the command, one `read` returns the whole response.
##   * **A stream socket** — TCP or a Unix socket carrying the same raw
##     commands. This is what a software TPM's data channel speaks, and
##     it is what makes the quote path testable on a host with no TPM in
##     it.
##
## They differ in how a response is read and in nothing else, which is
## why the difference is a subclass of two methods rather than a flag
## threaded through the command layer.
##
## **The character device is not exercised by any test.** The gate below
## this module drives the socket transport, because a development host
## has no TPM in it and a software TPM offers a socket and not a device
## node. So `Tpm2CharDeviceTransport` is read, reviewed and compiled,
## and has never performed a transaction — while every command above it
## has, over the socket. Read that as the real division: the framing and
## the commands are exercised, the twenty lines that do `write` and
## `read` on a device node are not, and the first machine with a TPM to
## run this is the one that finds out. A host with `/dev/tpmrm0` can
## check it in one step, which is why it is worth saying where the line
## falls rather than leaving a reader to assume it is all the same.
##
## ## Mocking
##
## None. Every byte this module returns came out of a TPM; it
## synthesizes nothing and has no "pretend" mode. A build with no TPM
## reachable gets a refusal naming the endpoint, which is the honest
## answer and the one an operator can act on.

import std/[nativesockets, net, strutils]

when defined(posix):
  import std/posix

import ./tpm2

const
  Tpm2HeaderBytes* = 10
    ## tag, size, code — the fixed prologue of a command and of a
    ## response.

  MaxPcrReadRounds* = 8
    ## How many times `tpmPcrRead` asks again for registers an answer
    ## did not carry. Every answer either returns at least one register
    ## or is refused, so this bounds a conversation that is making no
    ## progress; it is not a statement about how many registers a
    ## platform has.

  MaxTpm2MessageBytes* = 8192
    ## The largest request or response this module will build or accept.
    ## A TPM's own buffer is typically 2–4 KiB; this is above that and
    ## far below anything that could be mistaken for a payload, so a
    ## device answering with a wild length field is refused by a
    ## comparison rather than by a memory allocation.

  TpmStNoSessions* = 0x8001'u16
  TpmStSessions* = 0x8002'u16

  TpmRhOwner* = 0x40000001'u32
    ## The storage hierarchy. A primary key created under it is
    ## regenerated from the hierarchy's own seed, so it survives a
    ## reboot without anything being stored outside the TPM.
  TpmRsPassword* = 0x40000009'u32
    ## `TPM_RS_PW`: the password "session" that is not a session.

  TpmRcSuccess* = 0x00000000'u32
  TpmRcInitialize* = 0x00000100'u32
    ## What `TPM2_Startup` answers when the TPM has already been started.
    ## The one response code this module treats as anything other than a
    ## refusal, and only in `tpmStartupClear`.

  TpmSuClear* = 0x0000'u16

  # --- command codes, TPM 2.0 Part 2 -------------------------------
  CcStartup* = 0x00000144'u32
  CcCreatePrimary* = 0x00000131'u32
  CcFlushContext* = 0x00000165'u32
  CcReadPublic* = 0x00000173'u32
  CcPcrRead* = 0x0000017E'u32
  CcPcrExtend* = 0x00000182'u32
  CcQuote* = 0x00000158'u32

  # --- the pieces of the attestation key's template ----------------
  TpmAlgEcc* = TpmAlgId(0x0023'u16)
  TpmEccNistP256* = 0x0003'u16

  AttestationKeyFixedBytes* = 20
    ## How much of the key template the TPM must store verbatim: the
    ## type, the name algorithm, the object attributes, the (empty)
    ## authorization policy and the ECC parameters — everything up to
    ## `unique`.
    ##
    ## `unique` is where the TPM puts the public point it derived, so it
    ## is *expected* to differ from the zero-length placeholder a
    ## template carries. Comparing the whole structure would therefore
    ## fail on every TPM; comparing nothing would let a device quietly
    ## create an unrestricted key. The boundary is where the comparison
    ## goes.

  AttestationKeyAttributes* = 0x00050472'u32
    ## `fixedTPM | fixedParent | sensitiveDataOrigin | userWithAuth |
    ## noDA | restricted | sign`.
    ##
    ## `restricted` is the load-bearing one and it is what makes the key
    ## an *attestation* key rather than a general signing key: a
    ## restricted signing key refuses to sign any digest that begins
    ## with `TPM_GENERATED_VALUE`, which is exactly the prefix every
    ## structure the TPM itself produced begins with. So a caller cannot
    ## hand this key a hand-written `TPMS_ATTEST` and get it signed —
    ## which is the whole reason a verifier is entitled to conclude
    ## anything from a signature over one.

type
  Tpm2TransportError* = object of CatchableError
    ## A transport or framing failure: no device, a short write, a
    ## response that is not a response. The message names the endpoint,
    ## because whoever reads it is looking at a machine whose TPM did
    ## not answer.

  Tpm2CommandError* = object of Tpm2TransportError
    ## A command the TPM understood and refused. `responseCode` is the
    ## TPM's own, carried so a caller can distinguish one refusal from
    ## another without parsing the message text.
    responseCode*: uint32

  Tpm2Transport* = ref object of RootObj
    ## One open conversation with a TPM.
    ##
    ## A transport is stateful — handles created through it live until
    ## they are flushed or it is closed — so it is a long-lived object
    ## rather than a function that opens and closes a device per
    ## command. Opening a device per command would also lose every
    ## transient handle between them, which is to say it would make
    ## `TPM2_Quote` unreachable.
    endpointName: string

  Tpm2Reply* = object
    ## What one transaction returned.
    handles*: seq[uint32]
    parameters*: string

  Tpm2SigningKey* = object
    ## A loaded signing key, as the TPM describes it.
    handle*: uint32
      ## The transient handle. Valid until it is flushed or the
      ## transport closes.
    publicArea*: string
      ## The `TPMT_PUBLIC` bytes, without the `TPM2B` size prefix. The
      ## key's Name is a digest of exactly these bytes, which is what
      ## makes the Name checkable by whoever holds them.
    name*: string
      ## `TPM2B_NAME` contents: the name algorithm followed by the
      ## digest of `publicArea`.
    qualifiedName*: string
      ## The Name hashed together with the parent's qualified name, so
      ## it says *where in the hierarchy* the key sits and not merely
      ## what it is. A quote's `qualifiedSigner` is this value, which is
      ## what lets a holder of the key's public half decide whether a
      ## quote came from it.

proc initTpm2Transport*(t: Tpm2Transport; endpoint: string) =
  if endpoint.len == 0:
    raise newException(Tpm2TransportError,
      "a TPM transport must name its endpoint; the endpoint is what an " &
      "operator reads when a machine will not attest")
  t.endpointName = endpoint

proc endpoint*(t: Tpm2Transport): string = t.endpointName

method transportTransact*(t: Tpm2Transport; command: string): string
    {.base.} =
  ## Send one command, return one whole response, including its ten
  ## header bytes.
  raise newException(Tpm2TransportError,
    "TPM transport " & t.endpoint &
    " does not implement transportTransact")

method transportClose*(t: Tpm2Transport) {.base.} = discard

# ---------------------------------------------------------------------
# A transport over a stream socket
# ---------------------------------------------------------------------

type
  Tpm2SocketTransport* = ref object of Tpm2Transport
    ## The raw command stream a software TPM's data channel carries.
    ##
    ## A stream gives no message boundaries, so the response is read in
    ## two steps: the ten-byte header, then exactly `responseSize - 10`
    ## further bytes. Reading "whatever has arrived" would work on a
    ## loopback socket most of the time, which is the worst available
    ## outcome.
    socket: Socket
    open: bool
    readTimeoutMs: int

const
  DefaultTpmReadTimeoutMs* = 60_000
    ## How long a transaction waits for the TPM's answer before
    ## refusing.
    ##
    ## A bound and not a hang, and the difference matters more than the
    ## number. A TPM socket can be *connected* while nothing is
    ## servicing it — a software TPM's data channel serves one client at
    ## a time, so a second connection is accepted by the listener and
    ## then never read — and a read with no bound turns that into a
    ## process that waits forever. An agent that hangs is worse than one
    ## that refuses: a refusal names the endpoint and a hang looks like
    ## a machine that is thinking about it.
    ##
    ## A minute is far above any command here (an ECC primary key is
    ## milliseconds) and far below any human's patience, so it can only
    ## ever fire on a conversation that is not going to finish.

proc sendAll(t: Tpm2SocketTransport; data: string) =
  try:
    t.socket.send(data)
  except CatchableError as e:
    raise newException(Tpm2TransportError,
      "TPM transport " & t.endpoint & ": sending a " & $data.len &
      "-byte command failed: " & e.msg)

proc readExactly(t: Tpm2SocketTransport; n: int; what: string): string =
  result = newString(n)
  var got = 0
  while got < n:
    # `hasDataBuffered` FIRST, and the socket is unbuffered as well.
    #
    # The trap this pair exists for was measured, not imagined. A
    # buffered `Socket` pulls a whole response out of the kernel while
    # satisfying a ten-byte read, and the descriptor is then NOT readable
    # although nine bytes of the answer are sitting in user space — so a
    # readiness check on the descriptor times out on a conversation that
    # already finished. The first `TPM2_PCR_Extend` of a run reported
    # "0 of 9 bytes arrived" after a minute, against a software TPM that
    # had already sent all nineteen.
    #
    # Either half alone closes it, and that was measured too: with the
    # sockets unbuffered this check never fires, and with the check in
    # place the sockets can be buffered again. So this is belt and
    # braces rather than two necessary conditions, and it is kept that
    # way on purpose — the unbuffered constructors make the descriptor
    # the single truth about what has arrived, and the check keeps the
    # loop correct if a buffered socket is ever handed to a transport
    # that did not build it.
    var waiting = @[t.socket.getFd()]
    if not t.socket.hasDataBuffered and selectRead(waiting,
                                                   t.readTimeoutMs) <= 0:
      raise newException(Tpm2TransportError,
        "TPM transport " & t.endpoint & ": no answer within " &
        $t.readTimeoutMs & "ms while reading " & what & " (" & $got &
        " of " & $n & " bytes arrived). The endpoint is connected and " &
        "nothing is servicing it: a software TPM's data channel admits " &
        "one client at a time, so a second conversation with the same " &
        "socket waits behind the first.")
    let chunk = try:
        t.socket.recv(addr result[got], n - got)
      except CatchableError as e:
        raise newException(Tpm2TransportError,
          "TPM transport " & t.endpoint & ": reading " & what &
          " failed after " & $got & " of " & $n & " bytes: " & e.msg)
    if chunk <= 0:
      raise newException(Tpm2TransportError,
        "TPM transport " & t.endpoint & ": the connection closed after " &
        $got & " of " & $n & " bytes of " & what &
        "; a half-read response is not a response")
    got += chunk

method transportTransact*(t: Tpm2SocketTransport; command: string): string =
  if not t.open:
    raise newException(Tpm2TransportError,
      "TPM transport " & t.endpoint & " is closed")
  t.sendAll(command)
  let header = t.readExactly(Tpm2HeaderBytes, "the response header")
  var r = initTpm2Reader(header, "TPM response header")
  discard r.readU16("tag")
  let size = int(r.readU32("responseSize"))
  if size < Tpm2HeaderBytes or size > MaxTpm2MessageBytes:
    raise newException(Tpm2TransportError,
      "TPM transport " & t.endpoint & ": the response declares " & $size &
      " bytes, which is outside " & $Tpm2HeaderBytes & ".." &
      $MaxTpm2MessageBytes &
      "; the stream is not carrying TPM responses")
  result = header
  if size > Tpm2HeaderBytes:
    result.add t.readExactly(size - Tpm2HeaderBytes, "the response body")

method transportClose*(t: Tpm2SocketTransport) =
  if t.open:
    t.open = false
    try: t.socket.close()
    except CatchableError: discard

proc newTpm2TcpTransport*(host: string; port: int): Tpm2SocketTransport =
  ## Connect to a TPM reachable over TCP — a software TPM's `--server
  ## type=tcp` channel.
  if port <= 0 or port > 65535:
    raise newException(Tpm2TransportError,
      "a TPM TCP endpoint's port is " & $port & ", outside 1..65535")
  result = Tpm2SocketTransport()
  initTpm2Transport(result, "tcp:" & host & ":" & $port)
  try:
    # Unbuffered: see the note in `readExactly`.
    result.socket = newSocket(buffered = false)
    result.socket.connect(host, Port(port))
    result.open = true
    result.readTimeoutMs = DefaultTpmReadTimeoutMs
  except CatchableError as e:
    raise newException(Tpm2TransportError,
      "no TPM answered at " & result.endpoint & ": " & e.msg)

proc newTpm2UnixTransport*(path: string): Tpm2SocketTransport =
  ## Connect to a TPM reachable over a Unix stream socket — a software
  ## TPM's `--server type=unixio` channel.
  when defined(posix):
    if path.len == 0:
      raise newException(Tpm2TransportError,
        "a TPM Unix endpoint needs a socket path")
    result = Tpm2SocketTransport()
    initTpm2Transport(result, "unix:" & path)
    try:
      # Qualified: `std/posix` carries `AF_UNIX` and friends as plain
      # `cint`s, so the unqualified names make the constructor
      # ambiguous rather than wrong — and the `cint` overload would
      # compile and connect to the wrong address family.
      result.socket = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM,
                                Protocol.IPPROTO_IP, buffered = false)
      result.socket.connectUnix(path)
      result.open = true
      result.readTimeoutMs = DefaultTpmReadTimeoutMs
    except CatchableError as e:
      raise newException(Tpm2TransportError,
        "no TPM answered at " & result.endpoint & ": " & e.msg)
  else:
    raise newException(Tpm2TransportError,
      "a Unix socket is not an endpoint this platform has; " & path &
      " cannot be reached")

# ---------------------------------------------------------------------
# A transport over a character device
# ---------------------------------------------------------------------

when defined(posix):
  type
    Tpm2CharDeviceTransport* = ref object of Tpm2Transport
      ## `/dev/tpmrm0` or `/dev/tpm0`.
      ##
      ## The kernel's TPM character device is message-oriented: one
      ## `write` is one command and the following `read` returns the
      ## whole response or fails. So there is no header-then-body dance
      ## here, and attempting one would block forever on the second
      ## read.
      fd: cint

  proc newTpm2CharDeviceTransport*(path: string): Tpm2CharDeviceTransport =
    ## Open a TPM character device. Prefer `/dev/tpmrm0`: the raw
    ## `/dev/tpm0` admits one caller at a time, so a daemon holding it
    ## open locks every other user of the machine's TPM out.
    if path.len == 0:
      raise newException(Tpm2TransportError,
        "a TPM device transport needs a device path")
    result = Tpm2CharDeviceTransport()
    initTpm2Transport(result, "device:" & path)
    let fd = posix.open(path.cstring, O_RDWR)
    if fd < 0:
      raise newException(Tpm2TransportError,
        "cannot open " & path & " (" & $strerror(errno) &
        "); this machine has no TPM device to attest with, or this " &
        "process is not permitted to use it")
    result.fd = fd

  method transportTransact*(t: Tpm2CharDeviceTransport;
                            command: string): string =
    if t.fd < 0:
      raise newException(Tpm2TransportError,
        "TPM transport " & t.endpoint & " is closed")
    let written = posix.write(t.fd, command.cstring, command.len)
    if written < 0:
      raise newException(Tpm2TransportError,
        "TPM transport " & t.endpoint & ": writing a " & $command.len &
        "-byte command failed: " & $strerror(errno))
    if written != command.len:
      # A short write to a TPM device is not a partial command to be
      # continued; the driver takes a command per write, so the device
      # has already been handed a truncated one.
      raise newException(Tpm2TransportError,
        "TPM transport " & t.endpoint & ": wrote " & $written & " of " &
        $command.len & " command bytes; the device takes one whole " &
        "command per write, so this command was truncated")
    var buf = newString(MaxTpm2MessageBytes)
    let got = posix.read(t.fd, addr buf[0], buf.len)
    if got < 0:
      raise newException(Tpm2TransportError,
        "TPM transport " & t.endpoint & ": reading the response failed: " &
        $strerror(errno))
    if got < Tpm2HeaderBytes:
      raise newException(Tpm2TransportError,
        "TPM transport " & t.endpoint & ": the device returned " & $got &
        " bytes, which is shorter than a response header")
    result = buf[0 ..< got]

  method transportClose*(t: Tpm2CharDeviceTransport) =
    if t.fd >= 0:
      discard posix.close(t.fd)
      t.fd = -1

# ---------------------------------------------------------------------
# Naming an endpoint in one string
# ---------------------------------------------------------------------

proc newTpm2Transport*(spec: string): Tpm2Transport =
  ## One spelling for the three endpoints, so a configuration file or a
  ## command line carries one field rather than a family of mutually
  ## exclusive ones:
  ##
  ##   * ``tcp:HOST:PORT`` — a TPM reachable over TCP;
  ##   * ``unix:PATH`` — a TPM reachable over a Unix stream socket;
  ##   * anything else — a character device path.
  ##
  ## The default is the device and not the socket, deliberately. A
  ## mistyped prefix then opens nothing and says which path it could not
  ## open, rather than connecting to whatever is listening on a port.
  if spec.len == 0:
    raise newException(Tpm2TransportError,
      "a TPM endpoint must be named; this build does not search for one")
  if spec.startsWith("unix:"):
    return newTpm2UnixTransport(spec["unix:".len .. ^1])
  if spec.startsWith("tcp:"):
    let rest = spec["tcp:".len .. ^1]
    let colon = rest.rfind(':')
    if colon <= 0:
      raise newException(Tpm2TransportError,
        "a TPM TCP endpoint is tcp:HOST:PORT, and " & spec.escape() &
        " names no port")
    let port = try:
        parseInt(rest[colon + 1 .. ^1])
      except ValueError:
        raise newException(Tpm2TransportError,
          "a TPM TCP endpoint's port is not a number in " & spec.escape())
    return newTpm2TcpTransport(rest[0 ..< colon], port)
  when defined(posix):
    newTpm2CharDeviceTransport(spec)
  else:
    raise newException(Tpm2TransportError,
      "a TPM character device is a Unix interface; name a tcp: or unix: " &
      "endpoint instead of " & spec.escape())

# ---------------------------------------------------------------------
# The command layer
# ---------------------------------------------------------------------

proc responseCodeName*(rc: uint32): string =
  ## A few codes by name, every other one in hex. Named rather than
  ## numbered where it helps: the four below are what a misconfigured
  ## machine actually produces, and "0x1d5" sends a reader to a spec
  ## they do not have open.
  ##
  ## Only format-0 codes are named, and that is the boundary rather than
  ## a short list. A format-0 code is a constant: `TPM_RC_LOCKOUT` is
  ## `0x921` whatever command produced it, so an exact match is right. A
  ## format-1 code — the `TPM_RC_FMT1` class, bit 7 set — carries the
  ## number of the handle, parameter or session at fault in its upper
  ## bits, so `TPM_RC_AUTH_FAIL` is `0x08E` for no particular argument,
  ## `0x98E` for the first session and `0x18E` for the first handle. An
  ## exact case for one of those would name the code correctly in one of
  ## sixteen arrivals and fall through to hex in the rest, which reads as
  ## two different failures. They fall through deliberately.
  case rc
  of TpmRcSuccess: "success"
  of TpmRcInitialize: "TPM_RC_INITIALIZE (the TPM has not been started, " &
                      "or has already been)"
  of 0x0000012F'u32: "TPM_RC_AUTH_UNAVAILABLE (this authorization is not " &
                     "one the object's attributes admit)"
  of 0x00000910'u32: "TPM_RC_REFERENCE_H0 (the handle names nothing loaded)"
  of 0x00000921'u32: "TPM_RC_LOCKOUT (the TPM is in dictionary-attack " &
                     "lockout and will not authorize)"
  else: "0x" & toHex(rc, 8).toLowerAscii

proc passwordAuthArea*(): string =
  ## One password session with an empty password. See the module header
  ## for why this is the only authorization shape here.
  var w = initTpm2Writer("TPMS_AUTH_COMMAND")
  w.writeU32(TpmRsPassword)
  w.writeU16(0'u16)   # nonce: empty
  w.writeU8(0'u8)     # sessionAttributes: none
  w.writeU16(0'u16)   # hmac: empty
  w.bytes

proc tpmTransact*(t: Tpm2Transport; code: uint32; what: string;
                  handles: openArray[uint32] = [];
                  authArea = ""; params = "";
                  responseHandles = 0): Tpm2Reply =
  ## One command, one response, both checked.
  ##
  ## The tag follows from whether there is an auth area, rather than
  ## being a parameter: a command sent with an auth area and tagged
  ## without sessions describes a body the TPM cannot walk, and the two
  ## could only ever disagree by mistake.
  let sessions = authArea.len > 0
  var body = initTpm2Writer(what)
  for h in handles: body.writeU32(h)
  if sessions:
    body.writeU32(uint32(authArea.len))
    body.writeBytes(authArea)
  body.writeBytes(params)

  let total = Tpm2HeaderBytes + body.bytes.len
  if total > MaxTpm2MessageBytes:
    raise newException(Tpm2TransportError,
      what & ": the command would be " & $total & " bytes, above the " &
      $MaxTpm2MessageBytes & " this module sends")
  var cmd = initTpm2Writer(what)
  cmd.writeU16(if sessions: TpmStSessions else: TpmStNoSessions)
  cmd.writeU32(uint32(total))
  cmd.writeU32(code)
  cmd.writeBytes(body.bytes)

  let raw = t.transportTransact(cmd.bytes)
  try:
    var r = initTpm2Reader(raw, what & " response")
    let tag = r.readU16("tag")
    let size = int(r.readU32("responseSize"))
    let rc = r.readU32("responseCode")
    if size != raw.len:
      raise newException(Tpm2TransportError,
        what & ": the response declares " & $size & " bytes and " &
        $raw.len & " arrived; a response whose length field disagrees " &
        "with itself is not one this module will parse")
    if rc != TpmRcSuccess:
      var e = newException(Tpm2CommandError,
        what & " was refused by the TPM at " & t.endpoint & ": " &
        responseCodeName(rc))
      e.responseCode = rc
      raise e
    result.handles = @[]
    for _ in 0 ..< responseHandles:
      result.handles.add r.readU32("handle")
    if tag == TpmStSessions:
      let psize = int(r.readU32("parameterSize"))
      result.parameters = r.readBytes("parameters", psize)
    else:
      result.parameters = r.readBytes("parameters", r.remaining)
  except Tpm2CodecError as e:
    # Translated so a caller needs one `try`. A truncated response is a
    # transport failure wearing a codec's exception type.
    raise newException(Tpm2TransportError, what & ": " & e.msg)

proc tpmStartupClear*(t: Tpm2Transport) =
  ## `TPM2_Startup(TPM_SU_CLEAR)`, tolerating a TPM that has already
  ## been started.
  ##
  ## A real machine's TPM is started by its firmware long before
  ## anything in user space runs, so this is a no-op there and the
  ## already-started code must not be an error. A software TPM launched
  ## without a start-up flag has to be told, and a caller should not
  ## have to know which of the two it is talking to.
  var p = initTpm2Writer("TPM2_Startup")
  p.writeU16(TpmSuClear)
  try:
    discard tpmTransact(t, CcStartup, "TPM2_Startup", params = p.bytes)
  except Tpm2CommandError as e:
    if e.responseCode != TpmRcInitialize: raise

proc tpmPcrExtend*(t: Tpm2Transport; index: int; alg: TpmAlgId;
                   digest: string) =
  ## Extend one register in one bank.
  ##
  ## Present because the registers a quote covers have to have been
  ## written by *something* before the quote says anything, and on a
  ## machine whose firmware did not do it there is no other way to put
  ## a known value in one. It is not part of producing evidence and the
  ## quote source never calls it.
  let size = digestSize(alg)
  if size == 0:
    raise newException(Tpm2TransportError,
      "TPM2_PCR_Extend: " & $alg & " is not a bank this codec knows the " &
      "digest length of")
  if digest.len != size:
    raise newException(Tpm2TransportError,
      "TPM2_PCR_Extend: a " & $alg & " digest is " & $size &
      " bytes and this one is " & $digest.len)
  var p = initTpm2Writer("TPML_DIGEST_VALUES")
  p.writeU32(1'u32)
  p.writeAlg(alg)
  p.writeBytes(digest)
  discard tpmTransact(t, CcPcrExtend, "TPM2_PCR_Extend",
                      handles = [uint32(index)],
                      authArea = passwordAuthArea(),
                      params = p.bytes)

proc readPcrSelectionFrom(r: var Tpm2Reader): seq[tuple[bank: TpmAlgId,
                                                        index: int]] =
  ## The registers a `TPML_PCR_SELECTION` in a response names, in wire
  ## order. Hand-walked because the selection in `TPM2_PCR_Read`'s
  ## answer is a field to be *skipped past* as much as read — but
  ## skipping it by length is not possible, since its length depends on
  ## its contents.
  result = @[]
  let count = int(r.readU32("pcrSelectionOut.count"))
  if count > MaxPcrBanks:
    raise newException(Tpm2TransportError,
      "TPM2_PCR_Read: the answer names " & $count &
      " banks and a TPM carries at most " & $MaxPcrBanks)
  for i in 0 ..< count:
    let alg = r.readAlg("pcrSelectionOut[" & $i & "].hashAlg")
    let sizeofSelect = int(r.readU8("pcrSelectionOut[" & $i &
                                    "].sizeofSelect"))
    if sizeofSelect < PcrSelectMin or sizeofSelect > PcrSelectMax:
      raise newException(Tpm2TransportError,
        "TPM2_PCR_Read: the answer's bitmap is " & $sizeofSelect &
        " bytes, outside " & $PcrSelectMin & ".." & $PcrSelectMax)
    let bitmap = r.readBytes("pcrSelectionOut[" & $i & "].pcrSelect",
                             sizeofSelect)
    for byteIndex in 0 ..< sizeofSelect:
      for bit in 0 ..< 8:
        if (uint8(bitmap[byteIndex]) and uint8(1 shl bit)) != 0:
          result.add (bank: alg, index: byteIndex * 8 + bit)

proc tpmPcrRead*(t: Tpm2Transport; alg: TpmAlgId;
                 indices: openArray[int]): seq[SelectedPcr] =
  ## Read registers out of one bank.
  ##
  ## A TPM answers with as many as fit its buffer and says in
  ## `pcrSelectionOut` which ones those were, so a request for eight
  ## registers can legitimately come back with fewer. The loop asks
  ## again for what is still missing rather than assuming it got
  ## everything, which is the bug this shape exists to make
  ## unspellable: pairing the request's index list with the answer's
  ## value list positionally gives wrong values under exactly the
  ## conditions that are hardest to reproduce.
  var wanted: seq[int] = @[]
  for i in indices:
    if i notin wanted: wanted.add i
  if wanted.len == 0:
    raise newException(Tpm2TransportError,
      "TPM2_PCR_Read: a request for no register would return nothing and " &
      "report success")
  result = @[]
  var rounds = 0
  while wanted.len > 0:
    inc rounds
    if rounds > MaxPcrReadRounds:
      raise newException(Tpm2TransportError,
        "TPM2_PCR_Read: the TPM at " & t.endpoint & " still has not " &
        "returned " & $wanted.len & " register(s) after " & $rounds &
        " rounds")
    let reply = tpmTransact(t, CcPcrRead, "TPM2_PCR_Read",
      params = serializePcrSelection(pcrSelection(alg, wanted)))
    var got: seq[tuple[bank: TpmAlgId, index: int]]
    var values: seq[string] = @[]
    try:
      var r = initTpm2Reader(reply.parameters, "TPM2_PCR_Read parameters")
      discard r.readU32("pcrUpdateCounter")
      got = readPcrSelectionFrom(r)
      let valueCount = int(r.readU32("pcrValues.count"))
      if valueCount != got.len:
        raise newException(Tpm2TransportError,
          "TPM2_PCR_Read: the answer selects " & $got.len &
          " register(s) and carries " & $valueCount &
          " value(s); pairing them would report one register's value " &
          "under another's number")
      for i in 0 ..< valueCount:
        values.add r.readTpm2b("pcrValues[" & $i & "]", MaxDigestBytes)
      r.finish()
    except Tpm2CodecError as e:
      raise newException(Tpm2TransportError, "TPM2_PCR_Read: " & e.msg)
    if got.len == 0:
      raise newException(Tpm2TransportError,
        "TPM2_PCR_Read: the TPM at " & t.endpoint & " selected no " &
        "register, so this request made no progress")
    for i in 0 ..< got.len:
      result.add selectedPcr(got[i].bank, got[i].index, values[i])
      let at = wanted.find(got[i].index)
      if at >= 0: wanted.delete(at)

proc attestationKeyTemplate*(): string =
  ## The `TPMT_PUBLIC` of a restricted ECDSA/SHA-256 signing key over
  ## NIST P-256, with no `unique` material: the TPM derives that from
  ## the hierarchy seed, which is what makes the key the same one after
  ## a reboot without anything having been stored.
  var w = initTpm2Writer("TPMT_PUBLIC")
  w.writeAlg(TpmAlgEcc)                 # type
  w.writeAlg(TpmAlgSha256)              # nameAlg
  w.writeU32(AttestationKeyAttributes)
  w.writeU16(0'u16)                     # authPolicy: empty
  w.writeAlg(TpmAlgNull)                # symmetric: none, this signs
  w.writeAlg(TpmAlgEcdsa)               # scheme
  w.writeAlg(TpmAlgSha256)              # scheme.details.hashAlg
  w.writeU16(TpmEccNistP256)            # curveID
  w.writeAlg(TpmAlgNull)                # kdf: none
  w.writeU16(0'u16)                     # unique.x: empty
  w.writeU16(0'u16)                     # unique.y: empty
  result = w.bytes
  # The split the comparison in `tpmCreateAttestationKey` relies on: the
  # bytes before `unique` are what the TPM must store verbatim, and the
  # two empty `TPM2B_ECC_PARAMETER`s after it are the four bytes it
  # replaces with the point it derived. A template that grew a field
  # without the boundary moving would make that comparison check the
  # wrong prefix, silently, so it does not compile instead.
  doAssert result.len == AttestationKeyFixedBytes + 4,
    "the attestation key template is " & $result.len &
    " bytes and the fixed prefix is declared to be " &
    $AttestationKeyFixedBytes

proc tpmReadPublic*(t: Tpm2Transport; handle: uint32): Tpm2SigningKey =
  ## What the TPM says about a loaded object: its public area, its Name
  ## and its qualified Name.
  ##
  ## The qualified Name is the field a quote's `qualifiedSigner` has to
  ## equal, and asking the TPM for it is better than computing it: the
  ## computation needs the parent chain's rule, and a holder of the
  ## public half can check this answer against the key it holds.
  let reply = tpmTransact(t, CcReadPublic, "TPM2_ReadPublic",
                          handles = [handle])
  try:
    var r = initTpm2Reader(reply.parameters, "TPM2_ReadPublic parameters")
    result.handle = handle
    result.publicArea = r.readBytes("outPublic",
      int(r.readU16("outPublic.size")))
    result.name = r.readTpm2b("name", MaxNameBytes)
    result.qualifiedName = r.readTpm2b("qualifiedName", MaxNameBytes)
    r.finish()
  except Tpm2CodecError as e:
    raise newException(Tpm2TransportError, "TPM2_ReadPublic: " & e.msg)

proc tpmCreateAttestationKey*(t: Tpm2Transport): Tpm2SigningKey =
  ## `TPM2_CreatePrimary` under the storage hierarchy, then
  ## `TPM2_ReadPublic` on the handle it returned.
  ##
  ## Two commands and not one: `TPM2_CreatePrimary` answers with the
  ## public area and the Name but *not* the qualified Name, and the
  ## qualified Name is the field that ties a quote to this key. Deriving
  ## it here instead would be this code's opinion about the hierarchy's
  ## rule; reading it is the TPM's statement.
  var params = initTpm2Writer("TPM2_CreatePrimary")
  params.writeU16(4'u16)                # inSensitive, a TPM2B
  params.writeU16(0'u16)                #   userAuth: empty
  params.writeU16(0'u16)                #   data: empty
  let pub = attestationKeyTemplate()
  params.writeU16(uint16(pub.len))      # inPublic, a TPM2B
  params.writeBytes(pub)
  params.writeU16(0'u16)                # outsideInfo: empty
  params.writeU32(0'u32)                # creationPCR: no selection

  let reply = tpmTransact(t, CcCreatePrimary, "TPM2_CreatePrimary",
                          handles = [TpmRhOwner],
                          authArea = passwordAuthArea(),
                          params = params.bytes,
                          responseHandles = 1)
  if reply.handles.len != 1:
    raise newException(Tpm2TransportError,
      "TPM2_CreatePrimary: the TPM at " & t.endpoint &
      " returned no object handle")
  result = tpmReadPublic(t, reply.handles[0])
  # The template is what makes the key RESTRICTED, and an unrestricted
  # signing key will sign a hand-written attestation structure — which
  # would make every conclusion a verifier draws from a signature
  # unfounded. So the attributes the TPM stored are read back and
  # compared rather than assumed, and a device that stored something
  # else is refused rather than used to attest.
  if result.publicArea.len < AttestationKeyFixedBytes or
     result.publicArea[0 ..< AttestationKeyFixedBytes] !=
       pub[0 ..< AttestationKeyFixedBytes]:
    raise newException(Tpm2TransportError,
      "TPM2_CreatePrimary: the TPM at " & t.endpoint & " created a key " &
      "whose attributes are not the ones it was given, so the key's " &
      "restrictions are not the ones this build asked for")

proc tpmFlushContext*(t: Tpm2Transport; handle: uint32) =
  ## Release a transient handle. The handle travels in the parameter
  ## area rather than the handle area for this one command, which is a
  ## genuine irregularity in the command set and not a mistake here.
  var p = initTpm2Writer("TPM2_FlushContext")
  p.writeU32(handle)
  discard tpmTransact(t, CcFlushContext, "TPM2_FlushContext",
                      params = p.bytes)

proc tpmQuote*(t: Tpm2Transport; keyHandle: uint32; qualifyingData: string;
               selection: TpmlPcrSelection): tuple[attest, signature: string] =
  ## `TPM2_Quote`: the registers the selection names, digested and
  ## signed, with `qualifyingData` carried through into the signed
  ## structure's `extraData`.
  ##
  ## The scheme is sent as null so the key's own scheme is used. A
  ## caller-chosen scheme would be a caller-chosen hash over the
  ## composite, and the key was created with the one this build means.
  if qualifyingData.len == 0:
    raise newException(Tpm2TransportError,
      "TPM2_Quote: a quote over no qualifying data answers no question")
  if qualifyingData.len > MaxDataBytes:
    raise newException(Tpm2TransportError,
      "TPM2_Quote: " & $qualifyingData.len &
      " bytes of qualifying data, above the " & $MaxDataBytes &
      " a TPM2B_DATA carries")
  if selectedPcrs(selection).len == 0:
    raise newException(Tpm2TransportError,
      "TPM2_Quote: a selection naming no register would sign the digest " &
      "of the empty string, which is the same on every machine")
  var params = initTpm2Writer("TPM2_Quote")
  params.writeU16(uint16(qualifyingData.len))
  params.writeBytes(qualifyingData)
  params.writeAlg(TpmAlgNull)           # inScheme: the key's own
  params.writeBytes(serializePcrSelection(selection))

  let reply = tpmTransact(t, CcQuote, "TPM2_Quote",
                          handles = [keyHandle],
                          authArea = passwordAuthArea(),
                          params = params.bytes)
  try:
    var r = initTpm2Reader(reply.parameters, "TPM2_Quote parameters")
    result.attest = r.readBytes("quoted", int(r.readU16("quoted.size")))
    result.signature = r.readBytes("signature", r.remaining)
  except Tpm2CodecError as e:
    raise newException(Tpm2TransportError, "TPM2_Quote: " & e.msg)
  if result.attest.len == 0 or result.signature.len == 0:
    raise newException(Tpm2TransportError,
      "TPM2_Quote: the TPM at " & t.endpoint & " returned " &
      $result.attest.len & " attest bytes and " & $result.signature.len &
      " signature bytes; a quote is both or neither")

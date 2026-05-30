## The framed, typed `RBEB` ("Reprobuild Elevation Broker") wire
## protocol (M81 deliverable 4).
##
## Modelled on the existing M62 binary envelopes (`RBPT` / `RBAM` /
## `RBSN` in `repro_home_generations`): a 4-byte ASCII magic, a u16
## LE schema version, a u32 LE body length, the body, and a trailing
## 32-byte BLAKE3-256 checksum over magic+version+type+bodyLen+body.
## RBEB adds a u16 LE message-type discriminator after the version,
## because — unlike the single-purpose RBPT/RBAM/RBSN envelopes — one
## RBEB channel carries a STREAM of differently-typed frames.
##
## Frame on-disk shape (little-endian throughout):
##
##   offset 0   :  magic            4 bytes ASCII "RBEB"
##   offset 4   :  schemaVersion    u16 LE
##   offset 6   :  messageType      u16 LE   (RbebMessageType)
##   offset 8   :  bodyLength       u32 LE
##   offset 12  :  body             bodyLength bytes
##   trailing   :  checksum         32 bytes BLAKE3-256
##
## Message stream over one channel:
##
##   parent -> broker : Hello   (nonce + protocol version)
##   broker -> parent : HelloAck
##   parent -> broker : Operation       \  repeated, one per
##   broker -> parent : OperationResult  \ privileged operation;
##   broker -> parent : ApplyLogRecord  /  the ApplyLogRecord is
##                                      /  emitted before the result
##   parent -> broker : Done
##
## This module is platform-pure and unit-testable everywhere — it
## owns ONLY the byte encoding; `ipc.nim` owns the transport.

import blake3
import repro_core

import ./errors
import ./operations
import ./system_value

const
  RbebMagic* = "RBEB"
  RbebSchemaVersion*: uint16 = 1
  RbebHeaderSize = 4 + 2 + 2 + 4
  RbebTrailerSize = 32
  RbebMaxFrameBody* = 8 * 1024 * 1024
    ## Hard cap on a single frame body. A frame claiming a larger
    ## body is rejected before any allocation — a malformed /
    ## hostile length field cannot drive an unbounded allocation.

type
  RbebMessageType* = enum
    ## The closed set of RBEB frame types. The on-disk value is the
    ## ordinal; an unknown discriminator is rejected by the decoder.
    rmtHello = 1
    rmtHelloAck = 2
    rmtOperation = 3
    rmtOperationResult = 4
    rmtApplyLogRecord = 5
    rmtDone = 6

  HelloFrame* = object
    ## First frame, parent -> broker. The broker checks `nonce`
    ## against the `--token` it was launched with; a mismatch is
    ## `EChannelAuth`.
    protocolVersion*: uint16
    nonce*: string

  HelloAckFrame* = object
    ## broker -> parent. `accepted == false` means the broker
    ## rejected the handshake (nonce mismatch); `reason` says why.
    accepted*: bool
    protocolVersion*: uint16
    reason*: string

  ApplyLogRecord* = object
    ## A structured apply-log record streamed back so the parent
    ## writes the unified apply log (deliverable 7). One is emitted
    ## per privileged operation, before its `OperationResult`.
    ## `restartNeeded` is set by the M69 `windows.optionalFeature` /
    ## `windows.capability` drivers when DISM signals a pending
    ## reboot — Reprobuild surfaces it, never auto-reboots.
    operationAddress*: string
    operationKind*: string
    outcome*: string                   ## "applied" | "no-op" | "drift" | "error"
    detail*: string
    preWriteDigestHex*: string
    postWriteDigestHex*: string
    restartNeeded*: bool

  OperationResultFrame* = object
    ## broker -> parent, one per `Operation`. `ok == false` carries
    ## a structured diagnostic; `driftDetected` distinguishes a
    ## fail-closed drift from a generic driver failure.
    operationAddress*: string
    ok*: bool
    driftDetected*: bool
    diagnostic*: string

# ---------------------------------------------------------------------------
# Frame envelope encode / decode.
# ---------------------------------------------------------------------------

proc encodeFrame*(messageType: RbebMessageType;
                  body: openArray[byte]): seq[byte] =
  ## Wrap a body in the RBEB envelope. Deterministic: identical
  ## (type, body) always produce identical bytes.
  if body.len > RbebMaxFrameBody:
    raiseProtocol("frame body " & $body.len & " bytes exceeds the " &
      $RbebMaxFrameBody & "-byte cap")
  result = newSeqOfCap[byte](RbebHeaderSize + body.len + RbebTrailerSize)
  for ch in RbebMagic:
    result.add(byte(ord(ch)))
  result.writeU16Le(RbebSchemaVersion)
  result.writeU16Le(uint16(ord(messageType)))
  result.writeU32Le(uint32(body.len))
  for b in body:
    result.add(b)
  let checksum = blake3.digest(result)
  for b in checksum:
    result.add(b)

type
  DecodedFrame* = object
    messageType*: RbebMessageType
    body*: seq[byte]

proc messageTypeFromOrd(v: uint16): RbebMessageType =
  case v
  of 1: rmtHello
  of 2: rmtHelloAck
  of 3: rmtOperation
  of 4: rmtOperationResult
  of 5: rmtApplyLogRecord
  of 6: rmtDone
  else:
    raiseProtocol("unknown RBEB message-type discriminator " & $v)

proc parseFrameHeader*(header: openArray[byte]): tuple[
    messageType: RbebMessageType; bodyLength: int] =
  ## Validate just the fixed-size `RbebHeaderSize` header — magic,
  ## schema version, message type, body length. The transport reads
  ## the header first so it knows how many body bytes to read next.
  if header.len < RbebHeaderSize:
    raiseProtocol("RBEB header is shorter than " & $RbebHeaderSize &
      " bytes")
  for i in 0 ..< 4:
    if header[i] != byte(ord(RbebMagic[i])):
      raiseProtocol("bad RBEB magic (expected '" & RbebMagic & "')")
  var pos = 4
  let version = readU16Le(header, pos)
  if version != RbebSchemaVersion:
    raiseProtocol("unsupported RBEB schema version " & $version &
      " (this build speaks " & $RbebSchemaVersion & ")")
  let mt = messageTypeFromOrd(readU16Le(header, pos))
  let bodyLen = int(readU32Le(header, pos))
  if bodyLen > RbebMaxFrameBody:
    raiseProtocol("RBEB frame claims a " & $bodyLen &
      "-byte body, over the " & $RbebMaxFrameBody & "-byte cap")
  result = (messageType: mt, bodyLength: bodyLen)

proc decodeFrame*(frame: openArray[byte]): DecodedFrame =
  ## Decode a complete frame (header + body + trailing checksum).
  ## Validates magic, version, type, length bounds and the trailing
  ## BLAKE3-256 checksum. Raises `EProtocol` on any inconsistency.
  if frame.len < RbebHeaderSize + RbebTrailerSize:
    raiseProtocol("RBEB frame is too short to be valid")
  let hdr = parseFrameHeader(frame)
  let bodyEnd = RbebHeaderSize + hdr.bodyLength
  if bodyEnd + RbebTrailerSize != frame.len:
    raiseProtocol("RBEB declared body length disagrees with frame size")
  var prefix = newSeqOfCap[byte](bodyEnd)
  for i in 0 ..< bodyEnd:
    prefix.add(frame[i])
  let expected = blake3.digest(prefix)
  for i in 0 ..< 32:
    if frame[bodyEnd + i] != expected[i]:
      raiseProtocol("RBEB trailing BLAKE3-256 checksum mismatch")
  result.messageType = hdr.messageType
  result.body = newSeq[byte](hdr.bodyLength)
  for i in 0 ..< hdr.bodyLength:
    result.body[i] = frame[RbebHeaderSize + i]

# ---------------------------------------------------------------------------
# Per-message body codecs. Strings are length-prefixed via the shared
# `repro_core/codec` helpers; bools are a single byte.
# ---------------------------------------------------------------------------

proc writeBool(outp: var seq[byte]; v: bool) =
  outp.add(if v: 1'u8 else: 0'u8)

proc readBool(bytes: openArray[byte]; pos: var int; field: string): bool =
  if pos >= bytes.len:
    raiseProtocol("truncated bool field '" & field & "'")
  let b = bytes[pos]; inc pos
  if b != 0 and b != 1:
    raiseProtocol("field '" & field & "' is not a valid bool byte")
  b == 1

# ---- Hello -----------------------------------------------------------------

proc encodeHello*(h: HelloFrame): seq[byte] =
  var body: seq[byte]
  body.writeU16Le(h.protocolVersion)
  body.writeString(h.nonce)
  encodeFrame(rmtHello, body)

proc decodeHello*(body: openArray[byte]): HelloFrame =
  var pos = 0
  result.protocolVersion = readU16Le(body, pos)
  result.nonce = readString(body, pos)

# ---- HelloAck --------------------------------------------------------------

proc encodeHelloAck*(h: HelloAckFrame): seq[byte] =
  var body: seq[byte]
  body.writeBool(h.accepted)
  body.writeU16Le(h.protocolVersion)
  body.writeString(h.reason)
  encodeFrame(rmtHelloAck, body)

proc decodeHelloAck*(body: openArray[byte]): HelloAckFrame =
  var pos = 0
  result.accepted = readBool(body, pos, "accepted")
  result.protocolVersion = readU16Le(body, pos)
  result.reason = readString(body, pos)

# ---- Operation -------------------------------------------------------------

type
  WireOperation* = object
    ## The on-wire form of a privileged operation: the typed
    ## operation PLUS the digest the non-elevated plan observed for
    ## the target (the "expected baseline"). The broker needs the
    ## baseline so it can distinguish a safe update (observed ==
    ## baseline) from a genuine mid-flight drift (observed is neither
    ## the desired value nor the baseline) — exactly the M68
    ## plan-apply-record drift contract.
    operation*: PrivilegedOperation
    baselineDigestHex*: string

proc encodeOperation*(wire: WireOperation): seq[byte] =
  ## The privileged-operation request frame. The kind tag is
  ## serialized as its string form so the decoder can reject an
  ## unknown tag before constructing the variant.
  let op = wire.operation
  var body: seq[byte]
  body.writeString($op.kind)
  body.writeString(op.address)
  body.writeString(wire.baselineDigestHex)
  case op.kind
  of pokFixtureFile:
    body.writeString(op.fileRelPath)
    body.writeString(op.fileContent)
  of pokFixtureRegistry:
    body.writeString(op.regSubPath)
    body.writeString(op.regValueName)
    body.writeString(op.regValueData)
  of pokWindowsRegistryValue:
    body.writeString(op.hklmSubkey)
    body.writeString(op.hklmValueName)
    body.writeString($op.hklmValueKind)
    body.writeString(op.hklmValueLiteral)
    body.writeBool(op.hklmDestroy)
  of pokWindowsOptionalFeature:
    body.writeString(op.featureName)
    body.writeBool(op.featureEnable)
  of pokWindowsCapability:
    body.writeString(op.capabilityName)
    body.writeBool(op.capabilityInstall)
  of pokWindowsService:
    body.writeString(op.serviceName)
    body.writeString(op.serviceStartType)
    body.writeBool(op.serviceRunning)
  of pokWindowsVsInstaller:
    body.writeString(op.vsEdition)
    body.writeString(op.vsChannel)
    body.writeString(op.vsInstallPath)
    body.writeU32Le(uint32(op.vsWorkloads.len))
    for w in op.vsWorkloads:
      body.writeString(w)
    body.writeU32Le(uint32(op.vsComponents.len))
    for c in op.vsComponents:
      body.writeString(c)
    body.writeBool(op.vsStrict)
    body.writeBool(op.vsDestroy)
  of pokWindowsFirewallRule:
    body.writeString(op.fwName)
    body.writeString(op.fwDisplayName)
    body.writeString(op.fwProtocol)
    body.writeString(op.fwDirection)
    body.writeString(op.fwAction)
    body.writeString(op.fwLocalPort)
    body.writeBool(op.fwEnabled)
    body.writeBool(op.fwDestroy)
  of pokMacosSystemDefault:
    body.writeString(op.sdDomain)
    body.writeString(op.sdKey)
    body.writeString(op.sdValueType)
    body.writeString(op.sdValueLiteral)
    body.writeString(op.sdRestartTarget)
    body.writeBool(op.sdDestroy)
  of pokSystemdSystemUnit:
    body.writeString(op.suName)
    body.writeString(op.suContent)
    body.writeBool(op.suEnabled)
    body.writeBool(op.suDestroy)
  of pokLaunchdSystemDaemon:
    body.writeString(op.sdaLabel)
    body.writeU32Le(uint32(op.sdaProgramArgs.len))
    for a in op.sdaProgramArgs:
      body.writeString(a)
    body.writeBool(op.sdaRunAtLoad)
    body.writeBool(op.sdaDestroy)
  of pokFsSystemFile:
    body.writeString(op.sfPath)
    body.writeString(op.sfContent)
    body.writeBool(op.sfDestroy)
  of pokEnvSystemVariable:
    body.writeString(op.evName)
    body.writeU32Le(uint32(op.evContribution.len))
    for c in op.evContribution:
      body.writeString(c)
    body.writeBool(op.evIsPathList)
    body.writeBool(op.evDestroy)
  of pokPasswdUser:
    body.writeString(op.puName)
    body.writeString(op.puHome)
    body.writeString(op.puShell)
    body.writeU32Le(uint32(op.puGroups.len))
    for g in op.puGroups:
      body.writeString(g)
    body.writeBool(op.puDestroy)
  of pokOsTimezone:
    body.writeString(op.tzIana)
  of pokOsHostname:
    body.writeString(op.hostnameName)
  of pokLinuxSysctl:
    body.writeString(op.sysctlKey)
    body.writeString(op.sysctlValue)
    body.writeString(op.sysctlFilename)
    body.writeBool(op.sysctlDestroy)
  of pokLinuxUdevRule:
    body.writeString(op.udevName)
    body.writeString(op.udevContent)
    body.writeBool(op.udevDestroy)
  of pokLinuxPolkitRule:
    body.writeString(op.polkitName)
    body.writeString(op.polkitContent)
    body.writeBool(op.polkitDestroy)
  of pokLinuxTmpfilesRule:
    body.writeString(op.tmpfilesName)
    body.writeString(op.tmpfilesContent)
    body.writeBool(op.tmpfilesApplyNow)
    body.writeBool(op.tmpfilesDestroy)
  of pokLinuxSudoersRule:
    body.writeString(op.sudoersName)
    body.writeString(op.sudoersContent)
    body.writeBool(op.sudoersDestroy)
  of pokPasswdGroup:
    body.writeString(op.pgName)
    body.writeString(op.pgGid)
    body.writeU32Le(uint32(op.pgMembers.len))
    for m in op.pgMembers:
      body.writeString(m)
    body.writeBool(op.pgDestroy)
  of pokLinuxNixDaemonSetting:
    body.writeString(op.nixKey)
    body.writeString(op.nixValue)
    body.writeString(op.nixFilename)
    body.writeBool(op.nixDestroy)
  of pokSystemdSystemTimer:
    body.writeString(op.stName)
    body.writeString(op.stContent)
    body.writeBool(op.stEnabled)
    body.writeBool(op.stRunning)
    body.writeBool(op.stDestroy)
  encodeFrame(rmtOperation, body)

proc decodeOperation*(body: openArray[byte]): WireOperation =
  ## Decode an `Operation` body. An unrecognized kind tag raises
  ## `EProtocol` — this is the broker's primary closed-set guard:
  ## a frame that is not a recognized typed `PrivilegedOperation` is
  ## never constructed, let alone dispatched.
  var pos = 0
  let kindTag = readString(body, pos)
  if not isKnownPrivilegedOperationKind(kindTag):
    raiseProtocol("frame names an unrecognized privileged-operation " &
      "kind '" & kindTag & "'; the broker executes only the closed " &
      "typed operation set")
  let kind = privilegedOperationKindFromString(kindTag)
  let address = readString(body, pos)
  result.baselineDigestHex = readString(body, pos)
  case kind
  of pokFixtureFile:
    result.operation = PrivilegedOperation(kind: pokFixtureFile,
      address: address)
    result.operation.fileRelPath = readString(body, pos)
    result.operation.fileContent = readString(body, pos)
  of pokFixtureRegistry:
    result.operation = PrivilegedOperation(kind: pokFixtureRegistry,
      address: address)
    result.operation.regSubPath = readString(body, pos)
    result.operation.regValueName = readString(body, pos)
    result.operation.regValueData = readString(body, pos)
  of pokWindowsRegistryValue:
    result.operation = PrivilegedOperation(kind: pokWindowsRegistryValue,
      address: address)
    result.operation.hklmSubkey = readString(body, pos)
    result.operation.hklmValueName = readString(body, pos)
    let valueKindTag = readString(body, pos)
    if not isKnownSystemRegistryValueKind(valueKindTag):
      raiseProtocol("windows.registryValue frame names an unrecognized " &
        "value kind '" & valueKindTag & "'")
    result.operation.hklmValueKind =
      systemRegistryValueKindFromString(valueKindTag)
    result.operation.hklmValueLiteral = readString(body, pos)
    result.operation.hklmDestroy = readBool(body, pos, "hklmDestroy")
  of pokWindowsOptionalFeature:
    result.operation = PrivilegedOperation(kind: pokWindowsOptionalFeature,
      address: address)
    result.operation.featureName = readString(body, pos)
    result.operation.featureEnable = readBool(body, pos, "featureEnable")
  of pokWindowsCapability:
    result.operation = PrivilegedOperation(kind: pokWindowsCapability,
      address: address)
    result.operation.capabilityName = readString(body, pos)
    result.operation.capabilityInstall =
      readBool(body, pos, "capabilityInstall")
  of pokWindowsService:
    result.operation = PrivilegedOperation(kind: pokWindowsService,
      address: address)
    result.operation.serviceName = readString(body, pos)
    result.operation.serviceStartType = readString(body, pos)
    result.operation.serviceRunning = readBool(body, pos, "serviceRunning")
  of pokWindowsVsInstaller:
    result.operation = PrivilegedOperation(kind: pokWindowsVsInstaller,
      address: address)
    result.operation.vsEdition = readString(body, pos)
    result.operation.vsChannel = readString(body, pos)
    result.operation.vsInstallPath = readString(body, pos)
    let wCount = int(readU32Le(body, pos))
    if wCount < 0 or pos + wCount > body.len:
      raiseProtocol("windows.vsInstaller frame: implausible workload count")
    for _ in 0 ..< wCount:
      result.operation.vsWorkloads.add(readString(body, pos))
    let cCount = int(readU32Le(body, pos))
    if cCount < 0 or pos + cCount > body.len:
      raiseProtocol("windows.vsInstaller frame: implausible component count")
    for _ in 0 ..< cCount:
      result.operation.vsComponents.add(readString(body, pos))
    result.operation.vsStrict = readBool(body, pos, "vsStrict")
    result.operation.vsDestroy = readBool(body, pos, "vsDestroy")
  of pokWindowsFirewallRule:
    result.operation = PrivilegedOperation(kind: pokWindowsFirewallRule,
      address: address)
    result.operation.fwName = readString(body, pos)
    result.operation.fwDisplayName = readString(body, pos)
    result.operation.fwProtocol = readString(body, pos)
    result.operation.fwDirection = readString(body, pos)
    result.operation.fwAction = readString(body, pos)
    result.operation.fwLocalPort = readString(body, pos)
    result.operation.fwEnabled = readBool(body, pos, "fwEnabled")
    result.operation.fwDestroy = readBool(body, pos, "fwDestroy")
  of pokMacosSystemDefault:
    result.operation = PrivilegedOperation(kind: pokMacosSystemDefault,
      address: address)
    result.operation.sdDomain = readString(body, pos)
    result.operation.sdKey = readString(body, pos)
    result.operation.sdValueType = readString(body, pos)
    result.operation.sdValueLiteral = readString(body, pos)
    result.operation.sdRestartTarget = readString(body, pos)
    result.operation.sdDestroy = readBool(body, pos, "sdDestroy")
  of pokSystemdSystemUnit:
    result.operation = PrivilegedOperation(kind: pokSystemdSystemUnit,
      address: address)
    result.operation.suName = readString(body, pos)
    result.operation.suContent = readString(body, pos)
    result.operation.suEnabled = readBool(body, pos, "suEnabled")
    result.operation.suDestroy = readBool(body, pos, "suDestroy")
  of pokLaunchdSystemDaemon:
    result.operation = PrivilegedOperation(kind: pokLaunchdSystemDaemon,
      address: address)
    result.operation.sdaLabel = readString(body, pos)
    let aCount = int(readU32Le(body, pos))
    if aCount < 0 or pos + aCount > body.len:
      raiseProtocol("launchd.systemDaemon frame: implausible argv count")
    for _ in 0 ..< aCount:
      result.operation.sdaProgramArgs.add(readString(body, pos))
    result.operation.sdaRunAtLoad = readBool(body, pos, "sdaRunAtLoad")
    result.operation.sdaDestroy = readBool(body, pos, "sdaDestroy")
  of pokFsSystemFile:
    result.operation = PrivilegedOperation(kind: pokFsSystemFile,
      address: address)
    result.operation.sfPath = readString(body, pos)
    result.operation.sfContent = readString(body, pos)
    result.operation.sfDestroy = readBool(body, pos, "sfDestroy")
  of pokEnvSystemVariable:
    result.operation = PrivilegedOperation(kind: pokEnvSystemVariable,
      address: address)
    result.operation.evName = readString(body, pos)
    let cCount = int(readU32Le(body, pos))
    if cCount < 0 or pos + cCount > body.len:
      raiseProtocol("env.systemVariable frame: implausible contribution count")
    for _ in 0 ..< cCount:
      result.operation.evContribution.add(readString(body, pos))
    result.operation.evIsPathList = readBool(body, pos, "evIsPathList")
    result.operation.evDestroy = readBool(body, pos, "evDestroy")
  of pokPasswdUser:
    result.operation = PrivilegedOperation(kind: pokPasswdUser,
      address: address)
    result.operation.puName = readString(body, pos)
    result.operation.puHome = readString(body, pos)
    result.operation.puShell = readString(body, pos)
    let gCount = int(readU32Le(body, pos))
    if gCount < 0 or pos + gCount > body.len:
      raiseProtocol("passwd.user frame: implausible group count")
    for _ in 0 ..< gCount:
      result.operation.puGroups.add(readString(body, pos))
    result.operation.puDestroy = readBool(body, pos, "puDestroy")
  of pokOsTimezone:
    result.operation = PrivilegedOperation(kind: pokOsTimezone,
      address: address)
    result.operation.tzIana = readString(body, pos)
  of pokOsHostname:
    result.operation = PrivilegedOperation(kind: pokOsHostname,
      address: address)
    result.operation.hostnameName = readString(body, pos)
  of pokLinuxSysctl:
    result.operation = PrivilegedOperation(kind: pokLinuxSysctl,
      address: address)
    result.operation.sysctlKey = readString(body, pos)
    result.operation.sysctlValue = readString(body, pos)
    result.operation.sysctlFilename = readString(body, pos)
    result.operation.sysctlDestroy = readBool(body, pos, "sysctlDestroy")
  of pokLinuxUdevRule:
    result.operation = PrivilegedOperation(kind: pokLinuxUdevRule,
      address: address)
    result.operation.udevName = readString(body, pos)
    result.operation.udevContent = readString(body, pos)
    result.operation.udevDestroy = readBool(body, pos, "udevDestroy")
  of pokLinuxPolkitRule:
    result.operation = PrivilegedOperation(kind: pokLinuxPolkitRule,
      address: address)
    result.operation.polkitName = readString(body, pos)
    result.operation.polkitContent = readString(body, pos)
    result.operation.polkitDestroy = readBool(body, pos, "polkitDestroy")
  of pokLinuxTmpfilesRule:
    result.operation = PrivilegedOperation(kind: pokLinuxTmpfilesRule,
      address: address)
    result.operation.tmpfilesName = readString(body, pos)
    result.operation.tmpfilesContent = readString(body, pos)
    result.operation.tmpfilesApplyNow = readBool(body, pos, "tmpfilesApplyNow")
    result.operation.tmpfilesDestroy = readBool(body, pos, "tmpfilesDestroy")
  of pokLinuxSudoersRule:
    result.operation = PrivilegedOperation(kind: pokLinuxSudoersRule,
      address: address)
    result.operation.sudoersName = readString(body, pos)
    result.operation.sudoersContent = readString(body, pos)
    result.operation.sudoersDestroy = readBool(body, pos, "sudoersDestroy")
  of pokPasswdGroup:
    result.operation = PrivilegedOperation(kind: pokPasswdGroup,
      address: address)
    result.operation.pgName = readString(body, pos)
    result.operation.pgGid = readString(body, pos)
    let mCount = int(readU32Le(body, pos))
    if mCount < 0 or pos + mCount > body.len:
      raiseProtocol("passwd.group frame: implausible member count")
    for _ in 0 ..< mCount:
      result.operation.pgMembers.add(readString(body, pos))
    result.operation.pgDestroy = readBool(body, pos, "pgDestroy")
  of pokLinuxNixDaemonSetting:
    result.operation = PrivilegedOperation(kind: pokLinuxNixDaemonSetting,
      address: address)
    result.operation.nixKey = readString(body, pos)
    result.operation.nixValue = readString(body, pos)
    result.operation.nixFilename = readString(body, pos)
    result.operation.nixDestroy = readBool(body, pos, "nixDestroy")
  of pokSystemdSystemTimer:
    result.operation = PrivilegedOperation(kind: pokSystemdSystemTimer,
      address: address)
    result.operation.stName = readString(body, pos)
    result.operation.stContent = readString(body, pos)
    result.operation.stEnabled = readBool(body, pos, "stEnabled")
    result.operation.stRunning = readBool(body, pos, "stRunning")
    result.operation.stDestroy = readBool(body, pos, "stDestroy")

# ---- OperationResult -------------------------------------------------------

proc encodeOperationResult*(r: OperationResultFrame): seq[byte] =
  var body: seq[byte]
  body.writeString(r.operationAddress)
  body.writeBool(r.ok)
  body.writeBool(r.driftDetected)
  body.writeString(r.diagnostic)
  encodeFrame(rmtOperationResult, body)

proc decodeOperationResult*(body: openArray[byte]): OperationResultFrame =
  var pos = 0
  result.operationAddress = readString(body, pos)
  result.ok = readBool(body, pos, "ok")
  result.driftDetected = readBool(body, pos, "driftDetected")
  result.diagnostic = readString(body, pos)

# ---- ApplyLogRecord --------------------------------------------------------

proc encodeApplyLogRecord*(r: ApplyLogRecord): seq[byte] =
  var body: seq[byte]
  body.writeString(r.operationAddress)
  body.writeString(r.operationKind)
  body.writeString(r.outcome)
  body.writeString(r.detail)
  body.writeString(r.preWriteDigestHex)
  body.writeString(r.postWriteDigestHex)
  body.writeBool(r.restartNeeded)
  encodeFrame(rmtApplyLogRecord, body)

proc decodeApplyLogRecord*(body: openArray[byte]): ApplyLogRecord =
  var pos = 0
  result.operationAddress = readString(body, pos)
  result.operationKind = readString(body, pos)
  result.outcome = readString(body, pos)
  result.detail = readString(body, pos)
  result.preWriteDigestHex = readString(body, pos)
  result.postWriteDigestHex = readString(body, pos)
  result.restartNeeded = readBool(body, pos, "restartNeeded")

# ---- Done ------------------------------------------------------------------

proc encodeDone*(): seq[byte] =
  ## `Done` carries no body — the parent sends it to tell the broker
  ## to exit cleanly.
  encodeFrame(rmtDone, @[])

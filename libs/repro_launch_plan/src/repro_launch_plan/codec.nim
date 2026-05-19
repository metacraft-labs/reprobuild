## Binary RBLP envelope for `LaunchPlan` plus binary RBLS envelope for
## the Windows launcher sidecar. The two envelope shapes intentionally
## mirror the M56 `RPRC` receipt envelope: 4-byte ASCII magic, u16 LE
## version, u32 LE body length, body bytes, then a trailing BLAKE3-256
## checksum computed over `header || body`.
##
## A `LaunchPlan.launchPlanId` is the BLAKE3-256 of the complete RBLP
## envelope bytes — that is the key the M56 CAS uses.

import std/[strutils]

import blake3
import repro_core

import ./types

type
  LaunchPlanCodecError* = object of CatchableError

const
  EnvelopeOverhead = 4 + 2 + 4 + 32     ## magic + version + bodyLen + checksum

proc writeBool(outp: var seq[byte]; value: bool) =
  outp.add(if value: 1'u8 else: 0'u8)

proc readBool(buf: openArray[byte]; pos: var int): bool =
  if pos >= buf.len:
    raise newException(LaunchPlanCodecError, "truncated bool")
  let raw = buf[pos]
  inc pos
  case raw
  of 0: false
  of 1: true
  else: raise newException(LaunchPlanCodecError, "invalid bool value " & $raw)

proc writeStr(outp: var seq[byte]; value: string) =
  outp.writeString(value)

proc readStr(buf: openArray[byte]; pos: var int): string =
  try:
    readString(buf, pos)
  except EnvelopeError as err:
    raise newException(LaunchPlanCodecError, err.msg)

proc writeStrSeq(outp: var seq[byte]; values: openArray[string]) =
  outp.writeU32Le(uint32(values.len))
  for v in values:
    outp.writeStr(v)

proc readStrSeq(buf: openArray[byte]; pos: var int): seq[string] =
  let count = int(readU32Le(buf, pos))
  result = newSeq[string](count)
  for i in 0 ..< count:
    result[i] = readStr(buf, pos)

proc writeEnvBinding(outp: var seq[byte]; eb: EnvBinding) =
  outp.writeStr(eb.name)
  outp.add(byte(ord(eb.kind)))
  outp.writeStr(eb.value)

proc readEnvBinding(buf: openArray[byte]; pos: var int): EnvBinding =
  result.name = readStr(buf, pos)
  if pos >= buf.len:
    raise newException(LaunchPlanCodecError, "truncated env binding kind")
  let raw = buf[pos]
  inc pos
  if raw > byte(ord(ebkUnset)):
    raise newException(LaunchPlanCodecError,
      "invalid env binding kind " & $raw)
  result.kind = EnvBindingKind(raw)
  result.value = readStr(buf, pos)

proc writeExecBinding(outp: var seq[byte]; eb: ExecutableBinding) =
  outp.writeStr(eb.logicalName)
  outp.writeStr(eb.executablePath)

proc readExecBinding(buf: openArray[byte]; pos: var int): ExecutableBinding =
  result.logicalName = readStr(buf, pos)
  result.executablePath = readStr(buf, pos)

proc writeSupportProfile(outp: var seq[byte]; sp: SupportProfile) =
  outp.writeStr(sp.platform)
  outp.writeStr(sp.arch)
  outp.writeStr(sp.abi)
  outp.writeStr(sp.osMinVersion)

proc readSupportProfile(buf: openArray[byte]; pos: var int): SupportProfile =
  result.platform = readStr(buf, pos)
  result.arch = readStr(buf, pos)
  result.abi = readStr(buf, pos)
  result.osMinVersion = readStr(buf, pos)

proc writeExecProfile(outp: var seq[byte]; ep: ExecutionProfileChecksum) =
  outp.writeBool(ep.present)
  outp.writeBool(ep.requires)
  outp.writeStr(ep.checksumHex)

proc readExecProfile(buf: openArray[byte]; pos: var int): ExecutionProfileChecksum =
  result.present = readBool(buf, pos)
  result.requires = readBool(buf, pos)
  result.checksumHex = readStr(buf, pos)

proc writeProvenance(outp: var seq[byte]; pr: LaunchPlanProvenance) =
  outp.writeStr(pr.adapter)
  outp.writeStr(pr.packageId)
  outp.writeStr(pr.realizationHashHex)

proc readProvenance(buf: openArray[byte]; pos: var int): LaunchPlanProvenance =
  result.adapter = readStr(buf, pos)
  result.packageId = readStr(buf, pos)
  result.realizationHashHex = readStr(buf, pos)

proc writeProjection(outp: var seq[byte]; pj: ProjectedRuntimeImage) =
  outp.writeBool(pj.present)
  outp.writeStr(pj.imageId)
  outp.writeStr(pj.relativePath)

proc readProjection(buf: openArray[byte]; pos: var int): ProjectedRuntimeImage =
  result.present = readBool(buf, pos)
  result.imageId = readStr(buf, pos)
  result.relativePath = readStr(buf, pos)

proc encodeBody(plan: LaunchPlan): seq[byte] =
  result.writeU16Le(plan.schemaVersion)
  result.writeStr(plan.realizedPrefix)
  result.writeStr(plan.exportedCommand)
  result.writeStr(plan.executablePath)
  result.writeStrSeq(plan.arguments)
  result.writeBool(plan.hasWorkingDirectory)
  result.writeStr(plan.workingDirectory)
  result.writeU32Le(uint32(plan.environmentBindings.len))
  for e in plan.environmentBindings: result.writeEnvBinding(e)
  result.writeU32Le(uint32(plan.executableBindings.len))
  for e in plan.executableBindings: result.writeExecBinding(e)
  result.writeStrSeq(plan.runtimeLibraryDirs)
  result.writeProjection(plan.projectedRuntimeImage)
  result.writeExecProfile(plan.executionProfile)
  result.writeSupportProfile(plan.supportProfile)
  result.writeProvenance(plan.provenance)
  result.add(byte(ord(plan.binding)))

proc decodeBody(buf: openArray[byte]): LaunchPlan =
  var pos = 0
  result.schemaVersion = readU16Le(buf, pos)
  if result.schemaVersion != LaunchPlanCurrentSchemaVersion:
    raise newException(LaunchPlanCodecError,
      "unsupported LaunchPlan schema version " & $result.schemaVersion)
  result.realizedPrefix = readStr(buf, pos)
  result.exportedCommand = readStr(buf, pos)
  result.executablePath = readStr(buf, pos)
  result.arguments = readStrSeq(buf, pos)
  result.hasWorkingDirectory = readBool(buf, pos)
  result.workingDirectory = readStr(buf, pos)
  let envCount = int(readU32Le(buf, pos))
  result.environmentBindings = newSeq[EnvBinding](envCount)
  for i in 0 ..< envCount:
    result.environmentBindings[i] = readEnvBinding(buf, pos)
  let execCount = int(readU32Le(buf, pos))
  result.executableBindings = newSeq[ExecutableBinding](execCount)
  for i in 0 ..< execCount:
    result.executableBindings[i] = readExecBinding(buf, pos)
  result.runtimeLibraryDirs = readStrSeq(buf, pos)
  result.projectedRuntimeImage = readProjection(buf, pos)
  result.executionProfile = readExecProfile(buf, pos)
  result.supportProfile = readSupportProfile(buf, pos)
  result.provenance = readProvenance(buf, pos)
  if pos >= buf.len:
    raise newException(LaunchPlanCodecError, "truncated binding kind")
  let bindingByte = buf[pos]
  inc pos
  if bindingByte > byte(ord(lbkWindowsProjection)):
    raise newException(LaunchPlanCodecError,
      "invalid LaunchPlan binding kind " & $bindingByte)
  result.binding = LaunchPlanBindingKind(bindingByte)
  if pos != buf.len:
    raise newException(LaunchPlanCodecError,
      "trailing bytes after LaunchPlan body")

proc encodeLaunchPlan*(plan: LaunchPlan): seq[byte] =
  ## Encode the LaunchPlan as an RBLP binary envelope:
  ##
  ##   4-byte magic ("RBLP") | u16 LE version | u32 LE body length |
  ##   body bytes            | BLAKE3-256 checksum over magic+ver+len+body
  ##
  ## The trailing checksum lets a reader detect corruption before parsing.
  let body = encodeBody(plan)
  result = newSeqOfCap[byte](EnvelopeOverhead + body.len)
  for ch in LaunchPlanEnvelopeMagic:
    result.add(byte(ord(ch)))
  result.writeU16Le(LaunchPlanCurrentSchemaVersion)
  result.writeU32Le(uint32(body.len))
  result.add(body)
  let checksum = blake3.digest(result)
  for b in checksum: result.add(b)

proc decodeLaunchPlan*(buf: openArray[byte]): LaunchPlan =
  ## Inverse of `encodeLaunchPlan`. Verifies the trailing checksum
  ## before deserializing.
  if buf.len < EnvelopeOverhead:
    raise newException(LaunchPlanCodecError, "RBLP envelope too short")
  for i in 0 ..< 4:
    if buf[i] != byte(ord(LaunchPlanEnvelopeMagic[i])):
      raise newException(LaunchPlanCodecError, "unknown RBLP magic")
  var pos = 4
  let version = readU16Le(buf, pos)
  if version != LaunchPlanCurrentSchemaVersion:
    raise newException(LaunchPlanCodecError,
      "unsupported RBLP version " & $version)
  let bodyLen = int(readU32Le(buf, pos))
  if pos + bodyLen + 32 != buf.len:
    raise newException(LaunchPlanCodecError,
      "RBLP envelope length mismatch (declared body " & $bodyLen & " bytes)")
  let bodyStart = pos
  let bodyEnd = bodyStart + bodyLen
  var prefix: seq[byte] = newSeqOfCap[byte](bodyEnd)
  for i in 0 ..< bodyEnd: prefix.add(buf[i])
  let expected = blake3.digest(prefix)
  for i in 0 ..< 32:
    if buf[bodyEnd + i] != expected[i]:
      raise newException(LaunchPlanCodecError,
        "RBLP checksum mismatch (corrupted envelope)")
  result = decodeBody(buf.toOpenArray(bodyStart, bodyEnd - 1))

proc launchPlanIdBytes*(plan: LaunchPlan): array[32, byte] =
  ## BLAKE3-256 of the canonical RBLP envelope bytes. This is the value
  ## used as the M56 CAS key for storing/retrieving the plan.
  blake3.digest(encodeLaunchPlan(plan))

proc launchPlanIdHex*(plan: LaunchPlan): string =
  let id = launchPlanIdBytes(plan)
  result = newStringOfCap(64)
  for b in id:
    result.add(toHex(int(b), 2).toLowerAscii())

# ---------------------------------------------------------------------------
# Sidecar (RBLS) envelope used by the Windows launcher binary
# ---------------------------------------------------------------------------

type
  LaunchSidecar* = object
    ## On-disk record placed next to a copy of the Reprobuild Windows
    ## launcher binary at activation time. The launcher reads this file
    ## via argv[0] resolution and uses it to locate the LaunchPlan in
    ## the M56 CAS without rewriting the launcher binary itself.
    schemaVersion*: uint16
    launchPlanIdHex*: string         ## 64-char lowercase hex (BLAKE3-256)
    storeRoot*: string               ## absolute path to <store-root>
    realizedPrefix*: string          ## resolved at activation time
    exportedCommand*: string         ## the user-visible command name
    requiresExecutionProfile*: bool
    executionProfileHex*: string     ## empty when not requested

const LaunchSidecarCurrentVersion* = 1'u16

proc encodeSidecarBody(s: LaunchSidecar): seq[byte] =
  result.writeU16Le(s.schemaVersion)
  result.writeStr(s.launchPlanIdHex)
  result.writeStr(s.storeRoot)
  result.writeStr(s.realizedPrefix)
  result.writeStr(s.exportedCommand)
  result.writeBool(s.requiresExecutionProfile)
  result.writeStr(s.executionProfileHex)

proc decodeSidecarBody(buf: openArray[byte]): LaunchSidecar =
  var pos = 0
  result.schemaVersion = readU16Le(buf, pos)
  if result.schemaVersion != LaunchSidecarCurrentVersion:
    raise newException(LaunchPlanCodecError,
      "unsupported sidecar schema version " & $result.schemaVersion)
  result.launchPlanIdHex = readStr(buf, pos)
  result.storeRoot = readStr(buf, pos)
  result.realizedPrefix = readStr(buf, pos)
  result.exportedCommand = readStr(buf, pos)
  result.requiresExecutionProfile = readBool(buf, pos)
  result.executionProfileHex = readStr(buf, pos)
  if pos != buf.len:
    raise newException(LaunchPlanCodecError, "trailing bytes after sidecar")

proc encodeLaunchSidecar*(s: LaunchSidecar): seq[byte] =
  ## RBLS envelope with the same shape as RBLP (magic, version, body
  ## length, body, BLAKE3 trailing checksum).
  let body = encodeSidecarBody(s)
  result = newSeqOfCap[byte](EnvelopeOverhead + body.len)
  for ch in LaunchSidecarEnvelopeMagic:
    result.add(byte(ord(ch)))
  result.writeU16Le(LaunchSidecarCurrentVersion)
  result.writeU32Le(uint32(body.len))
  result.add(body)
  let checksum = blake3.digest(result)
  for b in checksum: result.add(b)

proc decodeLaunchSidecar*(buf: openArray[byte]): LaunchSidecar =
  if buf.len < EnvelopeOverhead:
    raise newException(LaunchPlanCodecError, "RBLS envelope too short")
  for i in 0 ..< 4:
    if buf[i] != byte(ord(LaunchSidecarEnvelopeMagic[i])):
      raise newException(LaunchPlanCodecError, "unknown RBLS magic")
  var pos = 4
  let version = readU16Le(buf, pos)
  if version != LaunchSidecarCurrentVersion:
    raise newException(LaunchPlanCodecError,
      "unsupported RBLS version " & $version)
  let bodyLen = int(readU32Le(buf, pos))
  if pos + bodyLen + 32 != buf.len:
    raise newException(LaunchPlanCodecError,
      "RBLS envelope length mismatch")
  let bodyEnd = pos + bodyLen
  var prefix: seq[byte] = newSeqOfCap[byte](bodyEnd)
  for i in 0 ..< bodyEnd: prefix.add(buf[i])
  let expected = blake3.digest(prefix)
  for i in 0 ..< 32:
    if buf[bodyEnd + i] != expected[i]:
      raise newException(LaunchPlanCodecError,
        "RBLS checksum mismatch (corrupted sidecar)")
  result = decodeSidecarBody(buf.toOpenArray(pos, bodyEnd - 1))

proc writeSidecarFile*(path: string; sidecar: LaunchSidecar) =
  let bytes = encodeLaunchSidecar(sidecar)
  var text = newString(bytes.len)
  for i, b in bytes:
    text[i] = char(b)
  writeFile(path, text)

proc readSidecarFile*(path: string): LaunchSidecar =
  let raw = readFile(path)
  var buf = newSeq[byte](raw.len)
  for i, ch in raw:
    buf[i] = byte(ord(ch))
  decodeLaunchSidecar(buf)

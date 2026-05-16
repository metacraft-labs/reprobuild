import std/[json, os, osproc, sequtils, strutils]

import cbor
import repro_core
import repro_core/paths as corepaths
import repro_domain_types
import repro_hash
import repro_interface_artifacts

type
  ToolProvisioningMode* = enum
    tpmUnspecified
    tpmPathOnly

  AdapterStrength* = enum
    asWeak
    asStrong

  CachePortability* = enum
    cpLocalOnly
    cpPortable

  ToolProbeKind* = enum
    tpkVersion
    tpkChecksum
    tpkCapability

  ToolProbeSpec* = object
    kind*: ToolProbeKind
    name*: string
    args*: seq[string]

  ToolProbeResult* = object
    spec*: ToolProbeSpec
    exitCode*: int
    output*: string

  PathOnlyToolProfile* = object
    installMethod*: string
    packageSelector*: string
    executableName*: string
    pathSearchList*: seq[string]
    resolvedExecutablePath*: string
    probes*: seq[ToolProbeResult]
    adapterStrength*: AdapterStrength
    cachePortability*: CachePortability
    profileFingerprint*: ContentDigest

  ToolActionIdentity* = object
    providerEntrypointId*: string
    packageSelector*: string
    executableName*: string
    subcommand*: string
    pathSearchList*: seq[string]
    resolvedExecutablePath*: string
    probes*: seq[ToolProbeResult]
    actionFingerprint*: ContentDigest
    cachePortability*: CachePortability

  PathOnlyBuildIdentity* = object
    projectName*: string
    interfaceFingerprint*: ContentDigest
    profiles*: seq[PathOnlyToolProfile]
    actionIdentities*: seq[ToolActionIdentity]

const
  ArtifactMagic = [byte(ord('R')), byte(ord('B')), byte(ord('T')), byte(ord('P'))]
  ArtifactVersion = 1'u16

proc writeByte(outp: var seq[byte]; value: byte) =
  outp.add(value)

proc readByte(bytes: openArray[byte]; pos: var int): byte =
  if pos >= bytes.len:
    raiseEnvelopeError(eeMalformed, "truncated byte")
  result = bytes[pos]
  inc pos

proc writeStringSeq(outp: var seq[byte]; values: openArray[string]) =
  outp.writeU32Le(uint32(values.len))
  for value in values:
    outp.writeString(value)

proc readStringSeq(bytes: openArray[byte]; pos: var int): seq[string] =
  let count = int(readU32Le(bytes, pos))
  result = newSeq[string](count)
  for i in 0 ..< count:
    result[i] = readString(bytes, pos)

proc writeDigest(outp: var seq[byte]; digest: ContentDigest) =
  outp.writeByte(byte(ord(digest.algorithm)))
  outp.writeByte(byte(ord(digest.domain)))
  outp.add(digest.bytes)

proc readDigest(bytes: openArray[byte]; pos: var int): ContentDigest =
  let algorithm = readByte(bytes, pos)
  let domain = readByte(bytes, pos)
  if algorithm > byte(ord(haXxh3_64)):
    raiseEnvelopeError(eeMalformed, "invalid hash algorithm")
  if domain > byte(ord(hdMetadataEnvelope)):
    raiseEnvelopeError(eeMalformed, "invalid hash domain")
  if pos + 32 > bytes.len:
    raiseEnvelopeError(eeMalformed, "truncated content digest")
  result.algorithm = HashAlgorithm(algorithm)
  result.domain = HashDomain(domain)
  for i in 0 ..< 32:
    result.bytes[i] = bytes[pos + i]
  pos += 32

proc toByteString(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc fromByteString(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc digestHex(digest: ContentDigest): string =
  toHex(digest.bytes)

proc splitPathList(pathValue: string): seq[string] =
  if pathValue.len == 0:
    return @[]
  result = pathValue.split(PathSep)

proc configuredProbes*(packageSelector, executableName: string): seq[
    ToolProbeSpec] =
  discard packageSelector
  discard executableName
  @[ToolProbeSpec(kind: tpkVersion, name: "version", args: @["--version"])]

proc runProbe(executablePath: string; spec: ToolProbeSpec): ToolProbeResult =
  let command = @[executablePath] & spec.args
  let res = execCmdEx(command.mapIt("'" & it.replace("'", "'\\''") & "'").join(" "))
  ToolProbeResult(spec: spec, exitCode: res.exitCode, output: res.output)

proc profileFingerprintFor(profile: PathOnlyToolProfile): ContentDigest =
  var payload: seq[byte] = @[]
  payload.writeString("reprobuild.pathOnlyToolProfile.v1")
  payload.writeString(profile.installMethod)
  payload.writeString(profile.packageSelector)
  payload.writeString(profile.executableName)
  payload.writeStringSeq(profile.pathSearchList)
  payload.writeString(profile.resolvedExecutablePath)
  for probe in profile.probes:
    payload.writeByte(byte(ord(probe.spec.kind)))
    payload.writeString(probe.spec.name)
    payload.writeStringSeq(probe.spec.args)
    payload.writeU32Le(uint32(max(probe.exitCode, 0)))
    payload.writeString(probe.output)
  payload.writeByte(byte(ord(profile.adapterStrength)))
  payload.writeByte(byte(ord(profile.cachePortability)))
  blake3DomainDigest(payload, hdActionFingerprint)

proc actionFingerprintFor(identity: ToolActionIdentity): ContentDigest =
  var payload: seq[byte] = @[]
  payload.writeString("reprobuild.pathOnlyToolAction.v1")
  payload.writeString(identity.providerEntrypointId)
  payload.writeString(identity.packageSelector)
  payload.writeString(identity.executableName)
  payload.writeString(identity.subcommand)
  payload.writeStringSeq(identity.pathSearchList)
  payload.writeString(identity.resolvedExecutablePath)
  for probe in identity.probes:
    payload.writeByte(byte(ord(probe.spec.kind)))
    payload.writeString(probe.spec.name)
    payload.writeStringSeq(probe.spec.args)
    payload.writeU32Le(uint32(max(probe.exitCode, 0)))
    payload.writeString(probe.output)
  payload.writeByte(byte(ord(identity.cachePortability)))
  blake3DomainDigest(payload, hdActionFingerprint)

proc findExecutableOnPath(executableName: string;
                          pathSearchList: openArray[string]): string =
  if executableName.len == 0:
    return ""
  for dir in pathSearchList:
    if dir.len == 0:
      continue
    let candidate = dir / executableName
    if fileExists(candidate) and {fpUserExec, fpGroupExec, fpOthersExec}.anyIt(
          it in getFilePermissions(candidate)):
      return absolutePath(candidate)
  ""

proc resolvePathOnlyTool*(useDef: InterfaceToolUse;
                          pathValue = getEnv("PATH")): PathOnlyToolProfile =
  let searchList = splitPathList(pathValue)
  let resolved = findExecutableOnPath(useDef.executableName, searchList)
  if resolved.len == 0:
    raise newException(OSError,
      "tool-resolution failed: " & useDef.executableName &
      " requested by uses \"" & useDef.rawConstraint &
      "\" was not found in PATH while --tool-provisioning=path is active")

  result = PathOnlyToolProfile(
    installMethod: "path",
    packageSelector: useDef.packageSelector,
    executableName: useDef.executableName,
    pathSearchList: searchList,
    resolvedExecutablePath: resolved,
    adapterStrength: asWeak,
    cachePortability: cpLocalOnly)

  for probe in configuredProbes(useDef.packageSelector, useDef.executableName):
    let probeResult = runProbe(resolved, probe)
    if probeResult.exitCode != 0:
      raise newException(OSError,
        "tool-resolution failed: probe " & probe.name & " for " &
        useDef.executableName & " exited " & $probeResult.exitCode)
    result.probes.add(probeResult)

  result.profileFingerprint = profileFingerprintFor(result)

proc metadataFor(identity: ToolActionIdentity): DynamicValue =
  var pathValues: seq[DynamicValue] = @[]
  for path in identity.pathSearchList:
    pathValues.add(cborText(path))
  var probeValues: seq[DynamicValue] = @[]
  for probe in identity.probes:
    probeValues.add(cborMap([
      entry("kind", cborText($probe.spec.kind)),
      entry("name", cborText(probe.spec.name)),
      entry("exitCode", cborUInt(uint64(max(probe.exitCode, 0)))),
      entry("output", cborText(probe.output))
    ]))
  cborMap([
    entry("kind", cborText("pathOnlyToolAction")),
    entry("schema", cborUInt(1)),
    entry("installMethod", cborText("path")),
    entry("packageSelector", cborText(identity.packageSelector)),
    entry("executableName", cborText(identity.executableName)),
    entry("pathSearchList", cborArray(pathValues)),
    entry("resolvedExecutablePath", cborText(identity.resolvedExecutablePath)),
    entry("probes", cborArray(probeValues)),
    entry("adapterStrength", cborText("weak")),
    entry("cachePortability", cborText("local-only")),
    entry("actionFingerprint", cborText(digestHex(identity.actionFingerprint)))
  ])

proc stableIdFromDigest(digest: ContentDigest): StableId =
  var raw: array[16, byte]
  for i in 0 ..< raw.len:
    raw[i] = digest.bytes[i]
  stableId(raw)

proc actionSpecFor*(identity: ToolActionIdentity): ActionSpec =
  var args: seq[string] = @[]
  ActionSpec(
    actionId: stableIdFromDigest(identity.actionFingerprint),
    process: directProcess(corepaths.normalizedPath(
        identity.resolvedExecutablePath),
      args, corepaths.normalizedPath(getCurrentDir())),
    dependencyPolicy: declaredOnlyPolicy(),
    metadata: metadataFor(identity))

proc pathOnlyBuildIdentity*(artifact: ProjectInterfaceArtifact;
                            pathValue = getEnv("PATH")):
    PathOnlyBuildIdentity =
  result.projectName = artifact.projectInterface.projectName
  result.interfaceFingerprint = artifact.interfaceFingerprint
  for useDef in artifact.projectInterface.toolUses:
    let profile = resolvePathOnlyTool(useDef, pathValue)
    result.profiles.add(profile)
    result.actionIdentities.add(ToolActionIdentity(
      providerEntrypointId: useDef.packageSelector & "." &
        useDef.executableName & ".path",
      packageSelector: useDef.packageSelector,
      executableName: useDef.executableName,
      subcommand: "path",
      pathSearchList: profile.pathSearchList,
      resolvedExecutablePath: profile.resolvedExecutablePath,
      probes: profile.probes,
      actionFingerprint: actionFingerprintFor(ToolActionIdentity(
        providerEntrypointId: useDef.packageSelector & "." &
          useDef.executableName & ".path",
        packageSelector: useDef.packageSelector,
        executableName: useDef.executableName,
        subcommand: "path",
        pathSearchList: profile.pathSearchList,
        resolvedExecutablePath: profile.resolvedExecutablePath,
        probes: profile.probes,
        cachePortability: cpLocalOnly)),
      cachePortability: cpLocalOnly))

proc writeProbeSpec(outp: var seq[byte]; spec: ToolProbeSpec) =
  outp.writeByte(byte(ord(spec.kind)))
  outp.writeString(spec.name)
  outp.writeStringSeq(spec.args)

proc readProbeSpec(bytes: openArray[byte]; pos: var int): ToolProbeSpec =
  let kind = readByte(bytes, pos)
  if kind > byte(ord(tpkCapability)):
    raiseEnvelopeError(eeMalformed, "invalid tool probe kind")
  result.kind = ToolProbeKind(kind)
  result.name = readString(bytes, pos)
  result.args = readStringSeq(bytes, pos)

proc writeProbeResult(outp: var seq[byte]; probe: ToolProbeResult) =
  outp.writeProbeSpec(probe.spec)
  outp.writeU32Le(uint32(max(probe.exitCode, 0)))
  outp.writeString(probe.output)

proc readProbeResult(bytes: openArray[byte]; pos: var int): ToolProbeResult =
  result.spec = readProbeSpec(bytes, pos)
  result.exitCode = int(readU32Le(bytes, pos))
  result.output = readString(bytes, pos)

proc writeProbeResults(outp: var seq[byte]; probes: openArray[
    ToolProbeResult]) =
  outp.writeU32Le(uint32(probes.len))
  for probe in probes:
    outp.writeProbeResult(probe)

proc readProbeResults(bytes: openArray[byte]; pos: var int): seq[
    ToolProbeResult] =
  let count = int(readU32Le(bytes, pos))
  result = newSeq[ToolProbeResult](count)
  for i in 0 ..< count:
    result[i] = readProbeResult(bytes, pos)

proc writeProfile(outp: var seq[byte]; profile: PathOnlyToolProfile) =
  outp.writeString(profile.installMethod)
  outp.writeString(profile.packageSelector)
  outp.writeString(profile.executableName)
  outp.writeStringSeq(profile.pathSearchList)
  outp.writeString(profile.resolvedExecutablePath)
  outp.writeProbeResults(profile.probes)
  outp.writeByte(byte(ord(profile.adapterStrength)))
  outp.writeByte(byte(ord(profile.cachePortability)))
  outp.writeDigest(profile.profileFingerprint)

proc readProfile(bytes: openArray[byte]; pos: var int): PathOnlyToolProfile =
  result.installMethod = readString(bytes, pos)
  result.packageSelector = readString(bytes, pos)
  result.executableName = readString(bytes, pos)
  result.pathSearchList = readStringSeq(bytes, pos)
  result.resolvedExecutablePath = readString(bytes, pos)
  result.probes = readProbeResults(bytes, pos)
  let strength = readByte(bytes, pos)
  if strength > byte(ord(asStrong)):
    raiseEnvelopeError(eeMalformed, "invalid adapter strength")
  result.adapterStrength = AdapterStrength(strength)
  let portability = readByte(bytes, pos)
  if portability > byte(ord(cpPortable)):
    raiseEnvelopeError(eeMalformed, "invalid cache portability")
  result.cachePortability = CachePortability(portability)
  result.profileFingerprint = readDigest(bytes, pos)

proc writeActionIdentity(outp: var seq[byte]; identity: ToolActionIdentity) =
  outp.writeString(identity.providerEntrypointId)
  outp.writeString(identity.packageSelector)
  outp.writeString(identity.executableName)
  outp.writeString(identity.subcommand)
  outp.writeStringSeq(identity.pathSearchList)
  outp.writeString(identity.resolvedExecutablePath)
  outp.writeProbeResults(identity.probes)
  outp.writeDigest(identity.actionFingerprint)
  outp.writeByte(byte(ord(identity.cachePortability)))

proc readActionIdentity(bytes: openArray[byte];
    pos: var int): ToolActionIdentity =
  result.providerEntrypointId = readString(bytes, pos)
  result.packageSelector = readString(bytes, pos)
  result.executableName = readString(bytes, pos)
  result.subcommand = readString(bytes, pos)
  result.pathSearchList = readStringSeq(bytes, pos)
  result.resolvedExecutablePath = readString(bytes, pos)
  result.probes = readProbeResults(bytes, pos)
  result.actionFingerprint = readDigest(bytes, pos)
  let portability = readByte(bytes, pos)
  if portability > byte(ord(cpPortable)):
    raiseEnvelopeError(eeMalformed, "invalid cache portability")
  result.cachePortability = CachePortability(portability)

proc encodePathOnlyBuildIdentity*(identity: PathOnlyBuildIdentity): seq[byte] =
  var payload: seq[byte] = @[]
  payload.writeString(identity.projectName)
  payload.writeDigest(identity.interfaceFingerprint)
  payload.writeU32Le(uint32(identity.profiles.len))
  for profile in identity.profiles:
    payload.writeProfile(profile)
  payload.writeU32Le(uint32(identity.actionIdentities.len))
  for actionIdentity in identity.actionIdentities:
    payload.writeActionIdentity(actionIdentity)
  result.add(ArtifactMagic)
  result.writeU16Le(ArtifactVersion)
  result.writeU32Le(uint32(payload.len))
  result.add(payload)

proc decodePathOnlyBuildIdentity*(bytes: openArray[
    byte]): PathOnlyBuildIdentity =
  if bytes.len < 10:
    raiseEnvelopeError(eeMalformed, "truncated path-only tool artifact")
  for i in 0 ..< ArtifactMagic.len:
    if bytes[i] != ArtifactMagic[i]:
      raiseEnvelopeError(eeUnknownMagic, "unknown path-only tool artifact magic")
  var pos = 4
  let version = readU16Le(bytes, pos)
  if version != ArtifactVersion:
    raiseEnvelopeError(eeUnsupportedVersion,
      "unsupported path-only tool artifact version")
  let payloadLength = int(readU32Le(bytes, pos))
  if pos + payloadLength != bytes.len:
    raiseEnvelopeError(eeMalformed, "path-only tool payload length mismatch")
  result.projectName = readString(bytes, pos)
  result.interfaceFingerprint = readDigest(bytes, pos)
  let profileCount = int(readU32Le(bytes, pos))
  result.profiles = newSeq[PathOnlyToolProfile](profileCount)
  for i in 0 ..< profileCount:
    result.profiles[i] = readProfile(bytes, pos)
  let actionCount = int(readU32Le(bytes, pos))
  result.actionIdentities = newSeq[ToolActionIdentity](actionCount)
  for i in 0 ..< actionCount:
    result.actionIdentities[i] = readActionIdentity(bytes, pos)
  if pos != bytes.len:
    raiseEnvelopeError(eeMalformed, "trailing path-only tool payload bytes")

proc writePathOnlyBuildIdentity*(path: string;
    identity: PathOnlyBuildIdentity) =
  createDir(parentDir(path))
  writeFile(path, toByteString(encodePathOnlyBuildIdentity(identity)))

proc readPathOnlyBuildIdentity*(path: string): PathOnlyBuildIdentity =
  decodePathOnlyBuildIdentity(fromByteString(readFile(path)))

proc jsonProbe(probe: ToolProbeResult): JsonNode =
  %*{
    "kind": $probe.spec.kind,
    "name": probe.spec.name,
    "args": probe.spec.args,
    "exitCode": probe.exitCode,
    "output": probe.output
  }

proc jsonProfile(profile: PathOnlyToolProfile): JsonNode =
  var probes = newJArray()
  for probe in profile.probes:
    probes.add(jsonProbe(probe))
  %*{
    "installMethod": profile.installMethod,
    "packageSelector": profile.packageSelector,
    "executableName": profile.executableName,
    "pathSearchList": profile.pathSearchList,
    "resolvedExecutablePath": profile.resolvedExecutablePath,
    "probes": probes,
    "adapterStrength": "weak",
    "cachePortability": "local-only",
    "profileFingerprint": digestHex(profile.profileFingerprint)
  }

proc jsonAction(identity: ToolActionIdentity): JsonNode =
  var probes = newJArray()
  for probe in identity.probes:
    probes.add(jsonProbe(probe))
  %*{
    "providerEntrypointId": identity.providerEntrypointId,
    "packageSelector": identity.packageSelector,
    "executableName": identity.executableName,
    "subcommand": identity.subcommand,
    "pathSearchList": identity.pathSearchList,
    "resolvedExecutablePath": identity.resolvedExecutablePath,
    "probes": probes,
    "cachePortability": "local-only",
    "actionFingerprint": digestHex(identity.actionFingerprint)
  }

proc inspectionJson*(identity: PathOnlyBuildIdentity): string =
  var profiles = newJArray()
  for profile in identity.profiles:
    profiles.add(jsonProfile(profile))
  var actions = newJArray()
  for actionIdentity in identity.actionIdentities:
    actions.add(jsonAction(actionIdentity))
  let root = %*{
    "projectName": identity.projectName,
    "interfaceFingerprint": digestHex(identity.interfaceFingerprint),
    "profiles": profiles,
    "actionIdentities": actions
  }
  root.pretty()

proc writeInspectionJson*(path: string; identity: PathOnlyBuildIdentity) =
  createDir(parentDir(path))
  writeFile(path, inspectionJson(identity))

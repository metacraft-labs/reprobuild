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
    tpmNix

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
    packageId*: string
    nixSelector*: string
    realizedStorePaths*: seq[string]
    selectedStorePath*: string
    lockIdentity*: string
    realizationBoundary*: string
    executableName*: string
    pathSearchList*: seq[string]
    resolvedExecutablePath*: string
    probes*: seq[ToolProbeResult]
    adapterStrength*: AdapterStrength
    cachePortability*: CachePortability
    profileFingerprint*: ContentDigest

  ToolActionIdentity* = object
    providerEntrypointId*: string
    installMethod*: string
    packageSelector*: string
    packageId*: string
    nixSelector*: string
    realizedStorePaths*: seq[string]
    selectedStorePath*: string
    lockIdentity*: string
    realizationBoundary*: string
    executableName*: string
    subcommand*: string
    pathSearchList*: seq[string]
    resolvedExecutablePath*: string
    probes*: seq[ToolProbeResult]
    actionFingerprint*: ContentDigest
    adapterStrength*: AdapterStrength
    cachePortability*: CachePortability

  PathOnlyBuildIdentity* = object
    projectName*: string
    interfaceFingerprint*: ContentDigest
    profiles*: seq[PathOnlyToolProfile]
    actionIdentities*: seq[ToolActionIdentity]

const
  ArtifactMagic = [byte(ord('R')), byte(ord('B')), byte(ord('T')), byte(ord('P'))]
  ArtifactVersion = 2'u16

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

proc strengthName(strength: AdapterStrength): string =
  case strength
  of asWeak: "weak"
  of asStrong: "strong"

proc portabilityName(portability: CachePortability): string =
  case portability
  of cpLocalOnly: "local-only"
  of cpPortable: "portable"

proc splitPathList(pathValue: string): seq[string] =
  if pathValue.len == 0:
    return @[]
  result = pathValue.split(PathSep)

proc configuredProbes*(packageSelector, executableName: string): seq[
    ToolProbeSpec] =
  discard packageSelector
  discard executableName
  @[ToolProbeSpec(kind: tpkVersion, name: "version", args: @["--version"])]

proc shellCommand(args: openArray[string]): string =
  args.mapIt(quoteShell(it)).join(" ")

proc runProbe(executablePath: string; spec: ToolProbeSpec): ToolProbeResult =
  let command = @[executablePath] & spec.args
  let res = execCmdEx(shellCommand(command))
  ToolProbeResult(spec: spec, exitCode: res.exitCode, output: res.output)

proc profileFingerprintFor(profile: PathOnlyToolProfile): ContentDigest =
  var payload: seq[byte] = @[]
  payload.writeString("reprobuild.toolProfile.v2")
  payload.writeString(profile.installMethod)
  payload.writeString(profile.packageSelector)
  payload.writeString(profile.packageId)
  payload.writeString(profile.nixSelector)
  payload.writeStringSeq(profile.realizedStorePaths)
  payload.writeString(profile.selectedStorePath)
  payload.writeString(profile.lockIdentity)
  payload.writeString(profile.realizationBoundary)
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
  payload.writeString("reprobuild.toolAction.v2")
  payload.writeString(identity.providerEntrypointId)
  payload.writeString(identity.installMethod)
  payload.writeString(identity.packageSelector)
  payload.writeString(identity.packageId)
  payload.writeString(identity.nixSelector)
  payload.writeStringSeq(identity.realizedStorePaths)
  payload.writeString(identity.selectedStorePath)
  payload.writeString(identity.lockIdentity)
  payload.writeString(identity.realizationBoundary)
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
  payload.writeByte(byte(ord(identity.adapterStrength)))
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
    packageId: useDef.packageSelector,
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

proc nixSelectorFor(useDef: InterfaceToolUse): string =
  case useDef.packageSelector
  of "nim":
    "nixpkgs#nim"
  of "node":
    "nixpkgs#nodejs"
  of "gcc":
    "nixpkgs#gcc"
  of "sh":
    "nixpkgs#bash"
  else:
    if useDef.packageSelector.contains("#"):
      useDef.packageSelector
    else:
      "nixpkgs#" & useDef.packageSelector

proc executableInStorePath(storePath, executableName: string): string =
  let candidate = storePath / "bin" / executableName
  if fileExists(candidate) and {fpUserExec, fpGroupExec, fpOthersExec}.anyIt(
      it in getFilePermissions(candidate)):
    absolutePath(candidate)
  else:
    ""

proc resolveNixTool*(useDef: InterfaceToolUse): PathOnlyToolProfile =
  let selector = nixSelectorFor(useDef)
  let res = execCmdEx(shellCommand(@["nix", "build", "--no-link",
    "--print-out-paths", selector]))
  if res.exitCode != 0:
    raise newException(OSError,
      "tool-resolution failed: nix build for " & selector & " exited " &
      $res.exitCode & "\n" & res.output)

  var realized: seq[string] = @[]
  for line in res.output.splitLines:
    let stripped = line.strip()
    if stripped.startsWith("/nix/store/"):
      realized.add(stripped)
  if realized.len == 0:
    raise newException(OSError,
      "tool-resolution failed: nix build for " & selector &
      " did not print any /nix/store outputs")

  var selectedStorePath = ""
  var resolved = ""
  for storePath in realized:
    let candidate = executableInStorePath(storePath, useDef.executableName)
    if candidate.len > 0:
      selectedStorePath = storePath
      resolved = candidate
      break
  if resolved.len == 0:
    raise newException(OSError,
      "tool-resolution failed: nix build for " & selector &
      " realized outputs without bin/" & useDef.executableName)

  result = PathOnlyToolProfile(
    installMethod: "nix",
    packageSelector: useDef.packageSelector,
    packageId: selector,
    nixSelector: selector,
    realizedStorePaths: realized,
    selectedStorePath: selectedStorePath,
    lockIdentity: selector,
    realizationBoundary: selectedStorePath,
    executableName: useDef.executableName,
    pathSearchList: @[selectedStorePath / "bin"],
    resolvedExecutablePath: resolved,
    adapterStrength: asStrong,
    cachePortability: cpPortable)

  for probe in configuredProbes(useDef.packageSelector, useDef.executableName):
    let probeResult = runProbe(resolved, probe)
    if probeResult.exitCode != 0:
      raise newException(OSError,
        "tool-resolution failed: probe " & probe.name & " for " &
        useDef.executableName & " from " & selector & " exited " &
        $probeResult.exitCode)
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
    entry("installMethod", cborText(identity.installMethod)),
    entry("packageSelector", cborText(identity.packageSelector)),
    entry("packageId", cborText(identity.packageId)),
    entry("nixSelector", cborText(identity.nixSelector)),
    entry("selectedStorePath", cborText(identity.selectedStorePath)),
    entry("lockIdentity", cborText(identity.lockIdentity)),
    entry("realizationBoundary", cborText(identity.realizationBoundary)),
    entry("executableName", cborText(identity.executableName)),
    entry("pathSearchList", cborArray(pathValues)),
    entry("resolvedExecutablePath", cborText(identity.resolvedExecutablePath)),
    entry("probes", cborArray(probeValues)),
    entry("adapterStrength", cborText(strengthName(identity.adapterStrength))),
    entry("cachePortability", cborText(portabilityName(identity.cachePortability))),
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

proc toolProfileFor(useDef: InterfaceToolUse; mode: ToolProvisioningMode;
                    pathValue: string): PathOnlyToolProfile =
  case mode
  of tpmPathOnly:
    resolvePathOnlyTool(useDef, pathValue)
  of tpmNix:
    resolveNixTool(useDef)
  else:
    raise newException(ValueError, "tool provisioning mode is not resolved")

proc actionIdentityFor(useDef: InterfaceToolUse;
                       profile: PathOnlyToolProfile): ToolActionIdentity =
  result = ToolActionIdentity(
    providerEntrypointId: useDef.packageSelector & "." &
      useDef.executableName & "." & profile.installMethod,
    installMethod: profile.installMethod,
    packageSelector: useDef.packageSelector,
    packageId: profile.packageId,
    nixSelector: profile.nixSelector,
    realizedStorePaths: profile.realizedStorePaths,
    selectedStorePath: profile.selectedStorePath,
    lockIdentity: profile.lockIdentity,
    realizationBoundary: profile.realizationBoundary,
    executableName: useDef.executableName,
    subcommand: profile.installMethod,
    pathSearchList: profile.pathSearchList,
    resolvedExecutablePath: profile.resolvedExecutablePath,
    probes: profile.probes,
    adapterStrength: profile.adapterStrength,
    cachePortability: profile.cachePortability)
  result.actionFingerprint = actionFingerprintFor(result)

proc toolBuildIdentity*(artifact: ProjectInterfaceArtifact;
                        mode: ToolProvisioningMode;
                        pathValue = getEnv("PATH")):
    PathOnlyBuildIdentity =
  result.projectName = artifact.projectInterface.projectName
  result.interfaceFingerprint = artifact.interfaceFingerprint
  for useDef in artifact.projectInterface.toolUses:
    let profile = toolProfileFor(useDef, mode, pathValue)
    result.profiles.add(profile)
    result.actionIdentities.add(actionIdentityFor(useDef, profile))

proc pathOnlyBuildIdentity*(artifact: ProjectInterfaceArtifact;
                            pathValue = getEnv("PATH")):
    PathOnlyBuildIdentity =
  toolBuildIdentity(artifact, tpmPathOnly, pathValue)

proc nixBuildIdentity*(artifact: ProjectInterfaceArtifact): PathOnlyBuildIdentity =
  toolBuildIdentity(artifact, tpmNix)

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
  outp.writeString(profile.packageId)
  outp.writeString(profile.nixSelector)
  outp.writeStringSeq(profile.realizedStorePaths)
  outp.writeString(profile.selectedStorePath)
  outp.writeString(profile.lockIdentity)
  outp.writeString(profile.realizationBoundary)
  outp.writeString(profile.executableName)
  outp.writeStringSeq(profile.pathSearchList)
  outp.writeString(profile.resolvedExecutablePath)
  outp.writeProbeResults(profile.probes)
  outp.writeByte(byte(ord(profile.adapterStrength)))
  outp.writeByte(byte(ord(profile.cachePortability)))
  outp.writeDigest(profile.profileFingerprint)

proc readProfile(bytes: openArray[byte]; pos: var int;
                 version: uint16): PathOnlyToolProfile =
  result.installMethod = readString(bytes, pos)
  result.packageSelector = readString(bytes, pos)
  if version >= 2'u16:
    result.packageId = readString(bytes, pos)
    result.nixSelector = readString(bytes, pos)
    result.realizedStorePaths = readStringSeq(bytes, pos)
    result.selectedStorePath = readString(bytes, pos)
    result.lockIdentity = readString(bytes, pos)
    result.realizationBoundary = readString(bytes, pos)
  else:
    result.packageId = result.packageSelector
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
  outp.writeString(identity.installMethod)
  outp.writeString(identity.packageSelector)
  outp.writeString(identity.packageId)
  outp.writeString(identity.nixSelector)
  outp.writeStringSeq(identity.realizedStorePaths)
  outp.writeString(identity.selectedStorePath)
  outp.writeString(identity.lockIdentity)
  outp.writeString(identity.realizationBoundary)
  outp.writeString(identity.executableName)
  outp.writeString(identity.subcommand)
  outp.writeStringSeq(identity.pathSearchList)
  outp.writeString(identity.resolvedExecutablePath)
  outp.writeProbeResults(identity.probes)
  outp.writeDigest(identity.actionFingerprint)
  outp.writeByte(byte(ord(identity.adapterStrength)))
  outp.writeByte(byte(ord(identity.cachePortability)))

proc readActionIdentity(bytes: openArray[byte];
    pos: var int; version: uint16): ToolActionIdentity =
  result.providerEntrypointId = readString(bytes, pos)
  if version >= 2'u16:
    result.installMethod = readString(bytes, pos)
  else:
    result.installMethod = "path"
  result.packageSelector = readString(bytes, pos)
  if version >= 2'u16:
    result.packageId = readString(bytes, pos)
    result.nixSelector = readString(bytes, pos)
    result.realizedStorePaths = readStringSeq(bytes, pos)
    result.selectedStorePath = readString(bytes, pos)
    result.lockIdentity = readString(bytes, pos)
    result.realizationBoundary = readString(bytes, pos)
  else:
    result.packageId = result.packageSelector
  result.executableName = readString(bytes, pos)
  result.subcommand = readString(bytes, pos)
  result.pathSearchList = readStringSeq(bytes, pos)
  result.resolvedExecutablePath = readString(bytes, pos)
  result.probes = readProbeResults(bytes, pos)
  result.actionFingerprint = readDigest(bytes, pos)
  if version >= 2'u16:
    let strength = readByte(bytes, pos)
    if strength > byte(ord(asStrong)):
      raiseEnvelopeError(eeMalformed, "invalid adapter strength")
    result.adapterStrength = AdapterStrength(strength)
  else:
    result.adapterStrength = asWeak
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
  if version < 1'u16 or version > ArtifactVersion:
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
    result.profiles[i] = readProfile(bytes, pos, version)
  let actionCount = int(readU32Le(bytes, pos))
  result.actionIdentities = newSeq[ToolActionIdentity](actionCount)
  for i in 0 ..< actionCount:
    result.actionIdentities[i] = readActionIdentity(bytes, pos, version)
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
    "packageId": profile.packageId,
    "nixSelector": profile.nixSelector,
    "realizedStorePaths": profile.realizedStorePaths,
    "selectedStorePath": profile.selectedStorePath,
    "lockIdentity": profile.lockIdentity,
    "realizationBoundary": profile.realizationBoundary,
    "executableName": profile.executableName,
    "pathSearchList": profile.pathSearchList,
    "resolvedExecutablePath": profile.resolvedExecutablePath,
    "probes": probes,
    "adapterStrength": strengthName(profile.adapterStrength),
    "cachePortability": portabilityName(profile.cachePortability),
    "profileFingerprint": digestHex(profile.profileFingerprint)
  }

proc jsonAction(identity: ToolActionIdentity): JsonNode =
  var probes = newJArray()
  for probe in identity.probes:
    probes.add(jsonProbe(probe))
  %*{
    "providerEntrypointId": identity.providerEntrypointId,
    "installMethod": identity.installMethod,
    "packageSelector": identity.packageSelector,
    "packageId": identity.packageId,
    "nixSelector": identity.nixSelector,
    "realizedStorePaths": identity.realizedStorePaths,
    "selectedStorePath": identity.selectedStorePath,
    "lockIdentity": identity.lockIdentity,
    "realizationBoundary": identity.realizationBoundary,
    "executableName": identity.executableName,
    "subcommand": identity.subcommand,
    "pathSearchList": identity.pathSearchList,
    "resolvedExecutablePath": identity.resolvedExecutablePath,
    "probes": probes,
    "adapterStrength": strengthName(identity.adapterStrength),
    "cachePortability": portabilityName(identity.cachePortability),
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

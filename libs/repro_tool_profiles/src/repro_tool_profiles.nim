import std/[httpclient, json, os, osproc, sequtils, strutils, tables, times]

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
    tpmTarball

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
    tarballUrl*: string
    tarballMirrors*: seq[string]
    tarballSelectedUrl*: string
    tarballSha256*: string
    archiveType*: string
    stripComponents*: int
    declaredExecutablePath*: string
    nixExpressionFile*: string
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
    tarballUrl*: string
    tarballMirrors*: seq[string]
    tarballSelectedUrl*: string
    tarballSha256*: string
    archiveType*: string
    stripComponents*: int
    declaredExecutablePath*: string
    nixExpressionFile*: string
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

  NixAcquisitionPlan* = object
    packageSelector*: string
    packageId*: string
    nixSelector*: string
    declaredExecutablePath*: string
    nixExpressionFile*: string
    lockIdentity*: string

  TarballAcquisitionPlan* = object
    packageSelector*: string
    packageId*: string
    url*: string
    mirrors*: seq[string]
    sha256*: string
    archiveType*: string
    declaredExecutablePath*: string
    stripComponents*: int
    lockIdentity*: string

const
  ArtifactMagic = [byte(ord('R')), byte(ord('B')), byte(ord('T')), byte(ord('P'))]
  ArtifactVersion = 5'u16

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
  payload.writeString("reprobuild.toolProfile.v4")
  payload.writeString(profile.installMethod)
  payload.writeString(profile.packageSelector)
  payload.writeString(profile.packageId)
  payload.writeString(profile.nixSelector)
  payload.writeString(profile.tarballUrl)
  payload.writeStringSeq(profile.tarballMirrors)
  payload.writeString(profile.tarballSelectedUrl)
  payload.writeString(profile.tarballSha256)
  payload.writeString(profile.archiveType)
  payload.writeU32Le(uint32(max(profile.stripComponents, 0)))
  payload.writeString(profile.declaredExecutablePath)
  payload.writeString(profile.nixExpressionFile)
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
  payload.writeString("reprobuild.toolAction.v4")
  payload.writeString(identity.providerEntrypointId)
  payload.writeString(identity.installMethod)
  payload.writeString(identity.packageSelector)
  payload.writeString(identity.packageId)
  payload.writeString(identity.nixSelector)
  payload.writeString(identity.tarballUrl)
  payload.writeStringSeq(identity.tarballMirrors)
  payload.writeString(identity.tarballSelectedUrl)
  payload.writeString(identity.tarballSha256)
  payload.writeString(identity.archiveType)
  payload.writeU32Le(uint32(max(identity.stripComponents, 0)))
  payload.writeString(identity.declaredExecutablePath)
  payload.writeString(identity.nixExpressionFile)
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
  when defined(windows):
    # Windows: executables have extensions (.exe, .cmd, .bat, .com) and
    # there is no POSIX execute-permission bit. Probe each PATH entry for the
    # standard executable suffixes from PATHEXT, falling back to common defaults
    # when PATHEXT is unset. Try extensioned candidates first so we never
    # accidentally pick up a POSIX shell-script shim with no extension (those
    # cannot be CreateProcess'd as Win32 apps). Only fall back to the bare name
    # if the caller already supplied an extension in the name itself.
    var suffixes: seq[string] = @[]
    let pathExt = getEnv("PATHEXT")
    if pathExt.len > 0:
      for ext in pathExt.split(';'):
        let lowered = ext.strip().toLowerAscii()
        if lowered.len > 0:
          suffixes.add(lowered)
    else:
      suffixes.add(".exe")
      suffixes.add(".cmd")
      suffixes.add(".bat")
      suffixes.add(".com")
    let nameHasExt = executableName.splitFile.ext.len > 0
    if nameHasExt:
      suffixes.insert("", 0)
    for dir in pathSearchList:
      if dir.len == 0:
        continue
      for suffix in suffixes:
        let candidate = dir / (executableName & suffix)
        if fileExists(candidate):
          return absolutePath(candidate)
    return ""
  else:
    for dir in pathSearchList:
      if dir.len == 0:
        continue
      let candidate = dir / executableName
      if fileExists(candidate) and {fpUserExec, fpGroupExec, fpOthersExec}.anyIt(
            it in getFilePermissions(candidate)):
        return absolutePath(candidate)
    ""

proc sidecarToolProfile(path: string): Table[string, string] =
  let sidecar = path & ".repro-tool-profile"
  if not fileExists(sidecar):
    return
  for line in readFile(sidecar).splitLines:
    let stripped = line.strip()
    if stripped.len == 0 or stripped.startsWith("#") or
        stripped == "reprobuild-tool-profile-v1":
      continue
    let marker = stripped.find('=')
    if marker <= 0:
      continue
    result[stripped[0 ..< marker]] = stripped[marker + 1 .. ^1]

proc applySidecarProfile(profile: var PathOnlyToolProfile;
                         sidecar: Table[string, string]) =
  if sidecar.len == 0:
    return
  if sidecar.hasKey("installMethod"):
    profile.installMethod = sidecar["installMethod"]
  if sidecar.hasKey("packageId"):
    profile.packageId = sidecar["packageId"]
  if sidecar.hasKey("nixSelector"):
    profile.nixSelector = sidecar["nixSelector"]
  if sidecar.hasKey("declaredExecutablePath"):
    profile.declaredExecutablePath = sidecar["declaredExecutablePath"]
  if sidecar.hasKey("selectedStorePath"):
    profile.selectedStorePath = sidecar["selectedStorePath"]
  if sidecar.hasKey("lockIdentity"):
    profile.lockIdentity = sidecar["lockIdentity"]
  if sidecar.hasKey("realizationBoundary"):
    profile.realizationBoundary = sidecar["realizationBoundary"]
  if sidecar.hasKey("pathSearchList"):
    profile.pathSearchList = splitPathList(sidecar["pathSearchList"])
  if sidecar.hasKey("resolvedExecutablePath"):
    profile.resolvedExecutablePath = sidecar["resolvedExecutablePath"]
  if sidecar.hasKey("adapterStrength"):
    case sidecar["adapterStrength"]
    of "strong":
      profile.adapterStrength = asStrong
    of "weak":
      profile.adapterStrength = asWeak
    else:
      discard
  if sidecar.hasKey("cachePortability"):
    case sidecar["cachePortability"]
    of "portable":
      profile.cachePortability = cpPortable
    of "local-only":
      profile.cachePortability = cpLocalOnly
    else:
      discard

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
    declaredExecutablePath: useDef.executableName,
    executableName: useDef.executableName,
    pathSearchList: searchList,
    resolvedExecutablePath: resolved,
    adapterStrength: asWeak,
    cachePortability: cpLocalOnly)
  result.applySidecarProfile(sidecarToolProfile(resolved))

  for probe in configuredProbes(useDef.packageSelector, useDef.executableName):
    let probeResult = runProbe(resolved, probe)
    if probeResult.exitCode != 0:
      raise newException(OSError,
        "tool-resolution failed: probe " & probe.name & " for " &
        useDef.executableName & " exited " & $probeResult.exitCode)
    result.probes.add(probeResult)

  result.profileFingerprint = profileFingerprintFor(result)

proc nixAcquisitionPlan*(useDef: InterfaceToolUse): NixAcquisitionPlan =
  if useDef.nixProvisioning.len == 0:
    raise newException(ValueError,
      "tool-resolution failed: package \"" & useDef.packageSelector &
      "\" requested by uses \"" & useDef.rawConstraint &
      "\" does not declare provisioning: nixPackage metadata")
  let selected = useDef.nixProvisioning[0]
  if selected.selector.len == 0 or selected.executablePath.len == 0:
    raise newException(ValueError,
      "tool-resolution failed: incomplete nixPackage metadata for package \"" &
      useDef.packageSelector & "\"")
  let packageId =
    if selected.packageId.len > 0:
      selected.packageId
    else:
      selected.selector
  let lockIdentity =
    if selected.lockIdentity.len > 0:
      selected.lockIdentity
    else:
      selected.selector
  NixAcquisitionPlan(
    packageSelector: useDef.packageSelector,
    packageId: packageId,
    nixSelector: selected.selector,
    declaredExecutablePath: selected.executablePath,
    nixExpressionFile: selected.expressionFile,
    lockIdentity: lockIdentity)

proc unsafeRelativePath(value: string): bool =
  let normalized = value.replace('\\', '/')
  if normalized.len == 0 or normalized.startsWith("/"):
    return true
  for part in normalized.split('/'):
    if part == "..":
      return true

proc pathContainsSymlink(root, relativePath: string): bool =
  var current = root
  for part in relativePath.replace('\\', '/').split('/'):
    if part.len == 0 or part == ".":
      continue
    current = current / part
    try:
      if getFileInfo(current, followSymlink = false).kind in
          {pcLinkToFile, pcLinkToDir}:
        return true
    except OSError:
      discard

proc executableInStorePath(storePath, declaredExecutablePath: string;
                           rejectSymlinks = false): string =
  if declaredExecutablePath.unsafeRelativePath:
    return ""
  if rejectSymlinks and pathContainsSymlink(storePath, declaredExecutablePath):
    return ""
  let candidate = storePath / declaredExecutablePath
  if fileExists(candidate) and {fpUserExec, fpGroupExec, fpOthersExec}.anyIt(
      it in getFilePermissions(candidate)):
    absolutePath(candidate)
  else:
    ""

proc resolveNixTool*(useDef: InterfaceToolUse): PathOnlyToolProfile =
  let plan = nixAcquisitionPlan(useDef)
  let selector = plan.nixSelector
  var nixArgs = @["nix", "build", "--no-link", "--print-out-paths"]
  if plan.nixExpressionFile.len > 0:
    nixArgs.add("--file")
    nixArgs.add(plan.nixExpressionFile)
  else:
    nixArgs.add(selector)
  let res = execCmdEx(shellCommand(nixArgs))
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
    let candidate = executableInStorePath(storePath,
      plan.declaredExecutablePath)
    if candidate.len > 0:
      selectedStorePath = storePath
      resolved = candidate
      break
  if resolved.len == 0:
    raise newException(OSError,
      "tool-resolution failed: nix build for " & selector &
      " realized outputs without " & plan.declaredExecutablePath)

  result = PathOnlyToolProfile(
    installMethod: "nix",
    packageSelector: useDef.packageSelector,
    packageId: plan.packageId,
    nixSelector: selector,
    declaredExecutablePath: plan.declaredExecutablePath,
    nixExpressionFile: plan.nixExpressionFile,
    realizedStorePaths: realized,
    selectedStorePath: selectedStorePath,
    lockIdentity: plan.lockIdentity,
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

proc normalizedSha256(value: string): string =
  result = value.strip().toLowerAscii()
  if result.startsWith("sha256:"):
    result = result["sha256:".len .. ^1]
  if result.len != 64 or result.anyIt(not (it in {'0' .. '9', 'a' .. 'f'})):
    raise newException(ValueError, "invalid sha256 digest: " & value)

proc fileSha256Hex(path: string): string =
  let sha256sum = findExe("sha256sum")
  let shasum = findExe("shasum")
  let openssl = findExe("openssl")
  let command =
    if sha256sum.len > 0:
      shellCommand(["sha256sum", path])
    elif shasum.len > 0:
      shellCommand(["shasum", "-a", "256", path])
    elif openssl.len > 0:
      shellCommand(["openssl", "dgst", "-sha256", "-r", path])
    else:
      raise newException(OSError,
        "tool-resolution failed: no sha256 verifier found (tried sha256sum, shasum, openssl)")
  let res = execCmdEx(command)
  if res.exitCode != 0:
    raise newException(OSError,
      "tool-resolution failed: sha256 verifier exited " & $res.exitCode &
      "\n" & res.output)
  let parts = res.output.strip().splitWhitespace()
  if parts.len == 0:
    raise newException(OSError, "tool-resolution failed: sha256 verifier produced no digest")
  normalizedSha256(parts[0])

proc safeStoreSegment(value, fallback: string): string =
  for ch in value:
    if ch in {'a' .. 'z'} or ch in {'A' .. 'Z'} or ch in {'0' .. '9'} or
        ch in {'-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = fallback

proc tarballAcquisitionPlan*(useDef: InterfaceToolUse): TarballAcquisitionPlan =
  if useDef.tarballProvisioning.len == 0:
    raise newException(ValueError,
      "tool-resolution failed: package \"" & useDef.packageSelector &
      "\" requested by uses \"" & useDef.rawConstraint &
      "\" does not declare provisioning: tarball metadata")
  let selected = useDef.tarballProvisioning[0]
  let sha256 = normalizedSha256(selected.sha256)
  if selected.url.len == 0 or selected.executablePath.len == 0:
    raise newException(ValueError,
      "tool-resolution failed: incomplete tarball metadata for package \"" &
      useDef.packageSelector & "\"")
  if selected.executablePath.unsafeRelativePath:
    raise newException(ValueError,
      "tool-resolution failed: unsafe tarball executablePath for package \"" &
      useDef.packageSelector & "\": " & selected.executablePath)
  TarballAcquisitionPlan(
    packageSelector: useDef.packageSelector,
    packageId: if selected.packageId.len >
    0: selected.packageId else: selected.url,
    url: selected.url,
    mirrors: selected.mirrors,
    sha256: sha256,
    archiveType: if selected.archiveType.len >
    0: selected.archiveType else: "tar.gz",
    declaredExecutablePath: selected.executablePath,
    stripComponents: selected.stripComponents,
    lockIdentity: if selected.lockIdentity.len > 0:
        selected.lockIdentity
      else:
        "sha256:" & sha256)

proc downloadUrlToFile(url, destination: string) =
  createDir(parentDir(destination))
  if url.startsWith("file://"):
    let source = url["file://".len .. ^1]
    if not fileExists(source):
      raise newException(IOError, "file URL does not exist: " & url)
    copyFile(source, destination)
  elif url.startsWith("http://") or url.startsWith("https://"):
    var client = newHttpClient()
    try:
      client.downloadFile(url, destination)
    finally:
      client.close()
  else:
    if not fileExists(url):
      raise newException(IOError, "unsupported archive URL or missing file: " & url)
    copyFile(url, destination)

proc verifiedDownload(plan: TarballAcquisitionPlan; storeRoot: string):
    tuple[path: string; selectedUrl: string] =
  let downloads = storeRoot / "downloads"
  let tmpRoot = storeRoot / "tmp"
  createDir(downloads)
  createDir(tmpRoot)
  let finalPath = downloads / (plan.sha256 & ".archive")
  if fileExists(finalPath):
    let actual = fileSha256Hex(finalPath)
    if actual == plan.sha256:
      return (path: finalPath, selectedUrl: "cache")
    removeFile(finalPath)

  var diagnostics: seq[string] = @[]
  for url in @[plan.url] & plan.mirrors:
    let tmpPath = tmpRoot / ("download." & $getCurrentProcessId() & "." &
      $getTime().toUnix & "." & $diagnostics.len)
    try:
      downloadUrlToFile(url, tmpPath)
      let actual = fileSha256Hex(tmpPath)
      if actual != plan.sha256:
        diagnostics.add(url & ": sha256 mismatch expected " & plan.sha256 &
          " got " & actual)
        removeFile(tmpPath)
        continue
      try:
        moveFile(tmpPath, finalPath)
      except OSError:
        if fileExists(finalPath) and fileSha256Hex(finalPath) == plan.sha256:
          if fileExists(tmpPath):
            removeFile(tmpPath)
        else:
          raise
      return (path: finalPath, selectedUrl: url)
    except CatchableError as e:
      diagnostics.add(url & ": " & e.msg)
      if fileExists(tmpPath):
        removeFile(tmpPath)
  raise newException(OSError,
    "tool-resolution failed: all tarball archive URLs failed for " &
    plan.packageSelector & "\n" & diagnostics.join("\n"))

proc validateTarEntries(archivePath, archiveType: string) =
  let lowerType = archiveType.toLowerAscii()
  let args =
    case lowerType
    of "tar.gz", "tgz":
      @["tar", "-tzf", archivePath]
    of "tar":
      @["tar", "-tf", archivePath]
    else:
      raise newException(ValueError,
        "tool-resolution failed: unsupported tarball archiveType " & archiveType)
  let res = execCmdEx(shellCommand(args))
  if res.exitCode != 0:
    raise newException(OSError,
      "tool-resolution failed: tar listing failed for " & archivePath &
      "\n" & res.output)
  for entry in res.output.splitLines:
    let normalized = entry.replace('\\', '/')
    if normalized.len == 0:
      continue
    if normalized.startsWith("/") or normalized == ".." or
        normalized.startsWith("../") or normalized.contains("/../") or
        normalized.endsWith("/.."):
      raise newException(OSError,
        "tool-resolution failed: unsafe archive entry: " & entry)

proc extractTarballArchive(archivePath, destination, archiveType: string;
                           stripComponents: int) =
  validateTarEntries(archivePath, archiveType)
  createDir(destination)
  let lowerType = archiveType.toLowerAscii()
  var args =
    case lowerType
    of "tar.gz", "tgz":
      @["tar", "-xzf", archivePath, "-C", destination]
    of "tar":
      @["tar", "-xf", archivePath, "-C", destination]
    else:
      raise newException(ValueError,
        "tool-resolution failed: unsupported tarball archiveType " & archiveType)
  if stripComponents > 0:
    args.add("--strip-components=" & $stripComponents)
  let res = execCmdEx(shellCommand(args))
  if res.exitCode != 0:
    raise newException(OSError,
      "tool-resolution failed: tar extraction failed for " & archivePath &
      "\n" & res.output)

proc tarballReceiptPath(prefix: string): string =
  prefix / ".reprobuild-tarball-receipt.json"

proc writeTarballReceipt(prefix: string; plan: TarballAcquisitionPlan;
                         selectedUrl: string) =
  let receipt = %*{
    "installMethod": "tarball",
    "packageSelector": plan.packageSelector,
    "packageId": plan.packageId,
    "url": plan.url,
    "mirrors": plan.mirrors,
    "selectedUrl": selectedUrl,
    "sha256": plan.sha256,
    "archiveType": plan.archiveType,
    "stripComponents": plan.stripComponents,
    "declaredExecutablePath": plan.declaredExecutablePath,
    "lockIdentity": plan.lockIdentity,
    "realizationBoundary": prefix
  }
  writeFile(tarballReceiptPath(prefix), receipt.pretty())

proc selectedUrlFromReceipt(prefix: string): string =
  let path = tarballReceiptPath(prefix)
  if not fileExists(path):
    return "existing"
  try:
    result = parseFile(path){"selectedUrl"}.getStr("existing")
  except CatchableError:
    result = "existing"

proc materializeTarballPrefix(plan: TarballAcquisitionPlan; storeRoot: string):
    tuple[prefix: string; archivePath: string; selectedUrl: string] =
  let realizations = storeRoot / "realizations"
  let tmpRoot = storeRoot / "tmp"
  createDir(realizations)
  createDir(tmpRoot)
  let prefix = realizations / (safeStoreSegment(plan.packageSelector,
    "package") & "-" & plan.sha256[0 .. 15])
  if dirExists(prefix):
    if executableInStorePath(prefix, plan.declaredExecutablePath,
        rejectSymlinks = true).len == 0:
      raise newException(OSError,
        "tool-resolution failed: existing tarball realization lacks " &
        plan.declaredExecutablePath & ": " & prefix)
    return (prefix: prefix, archivePath: "",
        selectedUrl: selectedUrlFromReceipt(prefix))

  let downloaded = verifiedDownload(plan, storeRoot)
  let tempPrefix = tmpRoot / ("extract." & $getCurrentProcessId() & "." &
    $getTime().toUnix & "." & plan.sha256[0 .. 15])
  if dirExists(tempPrefix):
    removeDir(tempPrefix)
  try:
    extractTarballArchive(downloaded.path, tempPrefix, plan.archiveType,
      plan.stripComponents)
    if executableInStorePath(tempPrefix, plan.declaredExecutablePath,
        rejectSymlinks = true).len == 0:
      raise newException(OSError,
        "tool-resolution failed: extracted tarball lacks executable " &
        plan.declaredExecutablePath)
    writeTarballReceipt(tempPrefix, plan, downloaded.selectedUrl)
    try:
      moveDir(tempPrefix, prefix)
    except OSError:
      if dirExists(prefix):
        removeDir(tempPrefix)
      else:
        raise
    if executableInStorePath(prefix, plan.declaredExecutablePath,
        rejectSymlinks = true).len == 0:
      raise newException(OSError,
        "tool-resolution failed: materialized tarball lacks executable " &
        plan.declaredExecutablePath)
    (prefix: prefix, archivePath: downloaded.path,
      selectedUrl: downloaded.selectedUrl)
  except CatchableError:
    if dirExists(tempPrefix):
      removeDir(tempPrefix)
    raise

proc resolveTarballTool*(useDef: InterfaceToolUse; storeRoot: string):
    PathOnlyToolProfile =
  let plan = tarballAcquisitionPlan(useDef)
  let root =
    if storeRoot.len > 0:
      storeRoot
    else:
      getCurrentDir() / ".repro" / "tool-store"
  let materialized = materializeTarballPrefix(plan, root)
  let resolved = executableInStorePath(materialized.prefix,
    plan.declaredExecutablePath, rejectSymlinks = true)
  if resolved.len == 0:
    raise newException(OSError,
      "tool-resolution failed: tarball realization lacks " &
      plan.declaredExecutablePath)

  result = PathOnlyToolProfile(
    installMethod: "tarball",
    packageSelector: useDef.packageSelector,
    packageId: plan.packageId,
    tarballUrl: plan.url,
    tarballMirrors: plan.mirrors,
    tarballSelectedUrl: materialized.selectedUrl,
    tarballSha256: plan.sha256,
    archiveType: plan.archiveType,
    stripComponents: plan.stripComponents,
    declaredExecutablePath: plan.declaredExecutablePath,
    realizedStorePaths: @[materialized.prefix],
    selectedStorePath: materialized.prefix,
    lockIdentity: plan.lockIdentity,
    realizationBoundary: materialized.prefix,
    executableName: useDef.executableName,
    pathSearchList: @[parentDir(resolved)],
    resolvedExecutablePath: resolved,
    adapterStrength: asStrong,
    cachePortability: cpPortable)

  for probe in configuredProbes(useDef.packageSelector, useDef.executableName):
    let probeResult = runProbe(resolved, probe)
    if probeResult.exitCode != 0:
      raise newException(OSError,
        "tool-resolution failed: probe " & probe.name & " for " &
        useDef.executableName & " from tarball " & plan.url & " exited " &
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
    entry("tarballUrl", cborText(identity.tarballUrl)),
    entry("tarballSelectedUrl", cborText(identity.tarballSelectedUrl)),
    entry("tarballSha256", cborText(identity.tarballSha256)),
    entry("archiveType", cborText(identity.archiveType)),
    entry("stripComponents", cborUInt(uint64(max(identity.stripComponents, 0)))),
    entry("declaredExecutablePath", cborText(identity.declaredExecutablePath)),
    entry("nixExpressionFile", cborText(identity.nixExpressionFile)),
    entry("selectedStorePath", cborText(identity.selectedStorePath)),
    entry("lockIdentity", cborText(identity.lockIdentity)),
    entry("realizationBoundary", cborText(identity.realizationBoundary)),
    entry("executableName", cborText(identity.executableName)),
    entry("pathSearchList", cborArray(pathValues)),
    entry("resolvedExecutablePath", cborText(identity.resolvedExecutablePath)),
    entry("probes", cborArray(probeValues)),
    entry("adapterStrength", cborText(strengthName(identity.adapterStrength))),
    entry("cachePortability", cborText(portabilityName(
        identity.cachePortability))),
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
                    pathValue, storeRoot: string): PathOnlyToolProfile =
  case mode
  of tpmPathOnly:
    resolvePathOnlyTool(useDef, pathValue)
  of tpmNix:
    resolveNixTool(useDef)
  of tpmTarball:
    resolveTarballTool(useDef, storeRoot)
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
    tarballUrl: profile.tarballUrl,
    tarballMirrors: profile.tarballMirrors,
    tarballSelectedUrl: profile.tarballSelectedUrl,
    tarballSha256: profile.tarballSha256,
    archiveType: profile.archiveType,
    stripComponents: profile.stripComponents,
    declaredExecutablePath: profile.declaredExecutablePath,
    nixExpressionFile: profile.nixExpressionFile,
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
                        pathValue = getEnv("PATH");
                        storeRoot = ""):
    PathOnlyBuildIdentity =
  result.projectName = artifact.projectInterface.projectName
  result.interfaceFingerprint = artifact.interfaceFingerprint
  for useDef in artifact.projectInterface.toolUses:
    let profile = toolProfileFor(useDef, mode, pathValue, storeRoot)
    result.profiles.add(profile)
    result.actionIdentities.add(actionIdentityFor(useDef, profile))

proc pathOnlyBuildIdentity*(artifact: ProjectInterfaceArtifact;
                            pathValue = getEnv("PATH")):
    PathOnlyBuildIdentity =
  toolBuildIdentity(artifact, tpmPathOnly, pathValue)

proc nixBuildIdentity*(artifact: ProjectInterfaceArtifact): PathOnlyBuildIdentity =
  toolBuildIdentity(artifact, tpmNix)

proc tarballBuildIdentity*(artifact: ProjectInterfaceArtifact; storeRoot = ""):
    PathOnlyBuildIdentity =
  toolBuildIdentity(artifact, tpmTarball, storeRoot = storeRoot)

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
  outp.writeString(profile.tarballUrl)
  outp.writeStringSeq(profile.tarballMirrors)
  outp.writeString(profile.tarballSelectedUrl)
  outp.writeString(profile.tarballSha256)
  outp.writeString(profile.archiveType)
  outp.writeU32Le(uint32(max(profile.stripComponents, 0)))
  outp.writeString(profile.declaredExecutablePath)
  outp.writeString(profile.nixExpressionFile)
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
    if version >= 5'u16:
      result.tarballUrl = readString(bytes, pos)
      result.tarballMirrors = readStringSeq(bytes, pos)
      result.tarballSelectedUrl = readString(bytes, pos)
      result.tarballSha256 = readString(bytes, pos)
      result.archiveType = readString(bytes, pos)
      result.stripComponents = int(readU32Le(bytes, pos))
    if version >= 3'u16:
      result.declaredExecutablePath = readString(bytes, pos)
    if version >= 4'u16:
      result.nixExpressionFile = readString(bytes, pos)
    result.realizedStorePaths = readStringSeq(bytes, pos)
    result.selectedStorePath = readString(bytes, pos)
    result.lockIdentity = readString(bytes, pos)
    result.realizationBoundary = readString(bytes, pos)
  else:
    result.packageId = result.packageSelector
  result.executableName = readString(bytes, pos)
  if result.declaredExecutablePath.len == 0:
    result.declaredExecutablePath = "bin/" & result.executableName
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
  outp.writeString(identity.tarballUrl)
  outp.writeStringSeq(identity.tarballMirrors)
  outp.writeString(identity.tarballSelectedUrl)
  outp.writeString(identity.tarballSha256)
  outp.writeString(identity.archiveType)
  outp.writeU32Le(uint32(max(identity.stripComponents, 0)))
  outp.writeString(identity.declaredExecutablePath)
  outp.writeString(identity.nixExpressionFile)
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
    if version >= 5'u16:
      result.tarballUrl = readString(bytes, pos)
      result.tarballMirrors = readStringSeq(bytes, pos)
      result.tarballSelectedUrl = readString(bytes, pos)
      result.tarballSha256 = readString(bytes, pos)
      result.archiveType = readString(bytes, pos)
      result.stripComponents = int(readU32Le(bytes, pos))
    if version >= 3'u16:
      result.declaredExecutablePath = readString(bytes, pos)
    if version >= 4'u16:
      result.nixExpressionFile = readString(bytes, pos)
    result.realizedStorePaths = readStringSeq(bytes, pos)
    result.selectedStorePath = readString(bytes, pos)
    result.lockIdentity = readString(bytes, pos)
    result.realizationBoundary = readString(bytes, pos)
  else:
    result.packageId = result.packageSelector
  result.executableName = readString(bytes, pos)
  if result.declaredExecutablePath.len == 0:
    result.declaredExecutablePath = "bin/" & result.executableName
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
    "tarballUrl": profile.tarballUrl,
    "tarballMirrors": profile.tarballMirrors,
    "tarballSelectedUrl": profile.tarballSelectedUrl,
    "tarballSha256": profile.tarballSha256,
    "archiveType": profile.archiveType,
    "stripComponents": profile.stripComponents,
    "declaredExecutablePath": profile.declaredExecutablePath,
    "nixExpressionFile": profile.nixExpressionFile,
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
    "tarballUrl": identity.tarballUrl,
    "tarballMirrors": identity.tarballMirrors,
    "tarballSelectedUrl": identity.tarballSelectedUrl,
    "tarballSha256": identity.tarballSha256,
    "archiveType": identity.archiveType,
    "stripComponents": identity.stripComponents,
    "declaredExecutablePath": identity.declaredExecutablePath,
    "nixExpressionFile": identity.nixExpressionFile,
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

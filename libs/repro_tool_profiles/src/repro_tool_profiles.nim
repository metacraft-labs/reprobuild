import std/[algorithm, json, os, osproc, sequtils, strutils, tables, times]

import blake3
import cbor
import repro_core
import repro_core/paths as corepaths
import repro_domain_types
import repro_hash
import repro_interface_artifacts
import repro_local_store
# repro_local_store provides the M56 unified store. Every adapter
# (Nix / tarball / Scoop) calls `registerInUnifiedStore` after laying
# out its realized prefix on disk so the same SQLite-backed
# `index.db` records every prefix the system has materialized
# regardless of which adapter produced it.

type
  ToolProvisioningMode* = enum
    tpmUnspecified
    tpmPathOnly
    tpmNix
    tpmTarball
    tpmScoop

  AdapterStrength* = enum
    asWeak
    asStrong

  CachePortability* = enum
    cpLocalOnly
    cpPortable

  PracticalHardening* = enum
    phNone                       # adapter not applicable (path/nix/tarball)
    phPinned                     # exact version, no execution profile
    phPinnedAndProfileVerified   # exact version + manifest + exec profile
    phRanged                     # range pin, no execution profile
    phRangedAndProfileVerified   # range pin + manifest + exec profile

  EScoopMissing* = object of CatchableError
  EScoopBucketMissing* = object of CatchableError
  EScoopVersionMismatch* = object of CatchableError
  EScoopVersionDrift* = object of CatchableError
  EScoopManifestUnreadable* = object of CatchableError
  EScoopManifestChecksumMismatch* = object of CatchableError
  EScoopInstallFailed* = object of CatchableError
  EScoopProfileChecksumMismatch* = object of CatchableError
  EScoopJunctionFailed* = object of CatchableError

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
    timedOut*: bool
      ## M75: true when the probe was killed by the wall-clock timeout
      ## (`probeTimeoutSeconds`) rather than exiting on its own. A
      ## timed-out probe is a STRUCTURED outcome — never an infinite
      ## block — and carries the sentinel `exitCode`
      ## `probeTimeoutExitCode`.

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
    practicalHardening*: PracticalHardening
    scoopBucket*: string
    scoopApp*: string
    scoopPinnedVersion*: string
    scoopPreferredVersion*: string
    scoopResolvedVersion*: string
    scoopManifestChecksum*: string
    scoopDeclaredManifestChecksum*: string
    scoopExecutionProfileChecksum*: string
    scoopRequiresExecutionProfile*: bool
    scoopRoot*: string
    scoopJunctionTarget*: string
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
    practicalHardening*: PracticalHardening
    scoopBucket*: string
    scoopApp*: string
    scoopPinnedVersion*: string
    scoopPreferredVersion*: string
    scoopResolvedVersion*: string
    scoopManifestChecksum*: string
    scoopExecutionProfileChecksum*: string
    scoopRoot*: string
    scoopJunctionTarget*: string

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
    nixpkgsRef*: string
    nixpkgsRev*: string
    nixpkgsNarHash*: string
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

  ScoopAcquisitionPlan* = object
    packageSelector*: string
    packageId*: string
    bucket*: string
    app*: string
    version*: string
    preferredVersion*: string
    manifestChecksum*: string
    manifestUrl*: string
    declaredExecutablePath*: string
    requiresExecutionProfileChecksum*: bool
    lockIdentity*: string

const
  ArtifactMagic = [byte(ord('R')), byte(ord('B')), byte(ord('T')), byte(ord('P'))]
  ArtifactVersion = 6'u16
  NixMaterializationMagic = [byte(ord('R')), byte(ord('B')), byte(ord('N')), byte(ord('M'))]
  NixMaterializationVersion = 1'u16

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

proc practicalHardeningName*(value: PracticalHardening): string =
  case value
  of phNone: "none"
  of phPinned: "pinned"
  of phPinnedAndProfileVerified: "pinned-and-profile-verified"
  of phRanged: "ranged"
  of phRangedAndProfileVerified: "ranged-and-profile-verified"

proc splitPathList(pathValue: string): seq[string] =
  if pathValue.len == 0:
    return @[]
  result = pathValue.split(PathSep)

proc configuredProbes*(packageSelector, executableName: string): seq[
    ToolProbeSpec] =
  discard packageSelector
  if executableName == "tmux":
    return @[ToolProbeSpec(kind: tpkVersion, name: "version", args: @["-V"])]
  if executableName == "xvfb-run":
    return @[ToolProbeSpec(kind: tpkVersion, name: "help", args: @["--help"])]
  @[ToolProbeSpec(kind: tpkVersion, name: "version", args: @["--version"])]

proc shellCommand(args: openArray[string]): string =
  args.mapIt(quoteShell(it)).join(" ")

# ---------------------------------------------------------------------------
# M75: probe timeout + process-tree kill.
#
# Any executable probe that IS run (an `--version`-style invocation) is
# bounded by a hard wall-clock timeout. A misbehaving probe — a GUI
# binary that launches the full application and never exits, or a
# console tool stuck in an infinite loop — can therefore NEVER hang
# `repro home apply`. On timeout the probe process AND its entire child
# process tree are killed (a GUI app spawns helper children — Chrome's
# GPU / renderer processes — that outlive a bare parent-kill), and the
# probe result is recorded as a structured `timedOut` outcome.
const
  probeTimeoutSeconds* = 10
    ## Hard wall-clock bound on every executable probe. 10s is generous
    ## for an `--version` print by a legitimate console tool yet short
    ## enough that a hung probe surfaces quickly.
  probeTimeoutExitCode* = 124
    ## Sentinel exit code recorded for a probe killed by the timeout —
    ## the conventional `timeout(1)` exit status. Distinguishes a
    ## timed-out probe from a probe that genuinely exited 0 or non-zero.

proc killProcessTree(pid: int) =
  ## Kill the process `pid` AND its entire descendant process tree. A
  ## bare parent-kill is not enough: a GUI application spawns helper
  ## children that keep running (and keep the apply effectively
  ## blocked / leave orphans) after the parent dies.
  when defined(windows):
    # `taskkill /T` walks the child process tree; `/F` forces
    # termination. This reaps the whole tree, not just the root.
    discard execCmdEx("taskkill /T /F /PID " & $pid)
  else:
    # POSIX: signal the process group. The child is started in its own
    # session/group below, so a negative-pid kill hits the whole tree.
    discard execCmdEx("kill -KILL -" & $pid & " 2>/dev/null")
    discard execCmdEx("kill -KILL " & $pid & " 2>/dev/null")

proc runProbe(executablePath: string; spec: ToolProbeSpec): ToolProbeResult =
  ## Run an executable probe under a hard wall-clock timeout.
  ##
  ## The probe is launched with `startProcess` (NOT a blocking
  ## `execCmdEx`/`execProcess`) so the wait is bounded: the parent polls
  ## `peekExitCode` against a deadline `probeTimeoutSeconds` in the
  ## future, and on expiry kills the probe's whole process tree. The
  ## probe's stdout+stderr are redirected to a temp file rather than an
  ## OS pipe — a process that fills a pipe buffer while the parent is
  ## blocked in a wait would deadlock; a file sink cannot back-pressure.
  result.spec = spec
  let tmpDir = getTempDir()
  let outPath = tmpDir / ("repro-probe-" & $getCurrentProcessId() & "-" &
    spec.name & "-" & $epochTime().int & ".log")
  # The probe command line: the executable plus the probe args, each
  # `quoteShell`-quoted, with stdout+stderr redirected to a temp FILE.
  # A file sink (not an OS pipe) is deliberate — a chatty probe that
  # fills a pipe buffer while the parent is in a bounded wait could
  # DEADLOCK; a file cannot back-pressure.
  #
  # The shell is invoked via the explicit `args` form
  # (`startProcess(shell, args = @["/c"|"-c", cmdLine])`), NOT
  # `poEvalCommand`: `poEvalCommand` mangles a `>` redirection operator
  # embedded in the command (it is passed to the probe as a literal
  # argument instead of being interpreted by the shell), whereas the
  # `args` form hands `cmd`/`sh` one quoted blob it parses itself —
  # redirection and all.
  let inner = (@[executablePath] & spec.args).mapIt(quoteShell(it)).join(" ")
  var process: Process
  try:
    when defined(windows):
      let cmdLine = inner & " > " & quoteShell(outPath) & " 2>&1"
      process = startProcess("cmd.exe", args = @["/c", cmdLine],
        options = {})
    else:
      # `poDaemon` asks Nim's POSIX process launcher to put the child in
      # its own process group. That gives `killProcessTree` a portable
      # negative-pid target without depending on a `setsid(1)` binary
      # being present (macOS does not ship one by default).
      let cmdLine = inner & " > " & quoteShell(outPath) & " 2>&1"
      process = startProcess("/bin/sh", args = @["-c", cmdLine],
        options = {poDaemon})
  except OSError as err:
    result.exitCode = -1
    result.output = "probe failed to start: " & err.msg
    return

  let deadline = epochTime() + probeTimeoutSeconds.float
  var exitCode = -1
  var timedOut = false
  try:
    while true:
      let code = process.peekExitCode()
      if code != -1:
        exitCode = code
        break
      if epochTime() >= deadline:
        timedOut = true
        # Kill the WHOLE tree — the launched `cmd.exe`/`sh` plus the
        # probe binary plus any GUI helper children it spawned.
        killProcessTree(process.processID)
        # Reap the now-killed parent so no zombie/handle leaks.
        discard process.waitForExit()
        break
      sleep(50)
  finally:
    process.close()

  var captured = ""
  if fileExists(extendedPath(outPath)):
    try: captured = readFile(extendedPath(outPath))
    except CatchableError: discard
    try: removeFile(extendedPath(outPath))
    except CatchableError: discard

  if timedOut:
    result.timedOut = true
    result.exitCode = probeTimeoutExitCode
    result.output =
      "probe '" & spec.name & "' timed out after " &
      $probeTimeoutSeconds & "s and was killed (process tree reaped)\n" &
      captured
  else:
    result.exitCode = exitCode
    result.output = captured

proc collectConfiguredProbes(executablePath, packageSelector,
                             executableName: string): seq[ToolProbeResult] =
  for probe in configuredProbes(packageSelector, executableName):
    result.add(runProbe(executablePath, probe))

proc profileFingerprintFor(profile: PathOnlyToolProfile): ContentDigest =
  var payload: seq[byte] = @[]
  payload.writeString("reprobuild.toolProfile.v5")
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
  payload.writeByte(byte(ord(profile.practicalHardening)))
  payload.writeString(profile.scoopBucket)
  payload.writeString(profile.scoopApp)
  payload.writeString(profile.scoopPinnedVersion)
  payload.writeString(profile.scoopPreferredVersion)
  payload.writeString(profile.scoopResolvedVersion)
  payload.writeString(profile.scoopManifestChecksum)
  payload.writeString(profile.scoopDeclaredManifestChecksum)
  payload.writeString(profile.scoopExecutionProfileChecksum)
  payload.writeByte(byte(ord(profile.scoopRequiresExecutionProfile)))
  payload.writeString(profile.scoopRoot)
  payload.writeString(profile.scoopJunctionTarget)
  blake3DomainDigest(payload, hdActionFingerprint)

proc actionFingerprintFor(identity: ToolActionIdentity): ContentDigest =
  var payload: seq[byte] = @[]
  payload.writeString("reprobuild.toolAction.v5")
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
  payload.writeByte(byte(ord(identity.practicalHardening)))
  payload.writeString(identity.scoopBucket)
  payload.writeString(identity.scoopApp)
  payload.writeString(identity.scoopPinnedVersion)
  payload.writeString(identity.scoopPreferredVersion)
  payload.writeString(identity.scoopResolvedVersion)
  payload.writeString(identity.scoopManifestChecksum)
  payload.writeString(identity.scoopExecutionProfileChecksum)
  payload.writeString(identity.scoopRoot)
  payload.writeString(identity.scoopJunctionTarget)
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
        if fileExists(extendedPath(candidate)):
          return absolutePath(candidate)
    return ""
  else:
    for dir in pathSearchList:
      if dir.len == 0:
        continue
      let candidate = dir / executableName
      if fileExists(extendedPath(candidate)) and {fpUserExec, fpGroupExec, fpOthersExec}.anyIt(
            it in getFilePermissions(extendedPath(candidate))):
        return absolutePath(candidate)
    ""

proc readSidecarToolProfile(sidecarPath: string): Table[string, string] =
  if not fileExists(extendedPath(sidecarPath)):
    return
  for line in readFile(extendedPath(sidecarPath)).splitLines:
    let stripped = line.strip()
    if stripped.len == 0 or stripped.startsWith("#") or
        stripped == "reprobuild-tool-profile-v1":
      continue
    let marker = stripped.find('=')
    if marker <= 0:
      continue
    result[stripped[0 ..< marker]] = stripped[marker + 1 .. ^1]

proc sidecarToolProfile(path: string): Table[string, string] =
  readSidecarToolProfile(path & ".repro-tool-profile")

proc findToolProfileSidecarOnPath(executableName: string;
                                  pathSearchList: openArray[string]): string =
  ## Look for a freestanding ``<dir>/<executableName>.repro-tool-profile``
  ## on PATH. Generators that already know the tool's absolute location
  ## (e.g. the CMake Reprobuild generator, which gets the compiler path
  ## from CMAKE_<LANG>_COMPILER) write just the profile sidecar into a
  ## bin/ marker dir and rely on this lookup so the resolver does not
  ## also require a wrapper executable to be present on PATH. The sidecar
  ## carries the real ``resolvedExecutablePath``; nothing in the engine's
  ## launch path consults the bin/ marker dir at run time.
  if executableName.len == 0:
    return ""
  for dir in pathSearchList:
    if dir.len == 0:
      continue
    let candidate = dir / (executableName & ".repro-tool-profile")
    if fileExists(extendedPath(candidate)):
      return absolutePath(candidate)
  ""

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

  # Sidecar-first lookup: when a generator already knows the tool's
  # absolute path and drops a `<name>.repro-tool-profile` on PATH, honour
  # that profile directly. The sidecar's `resolvedExecutablePath` IS the
  # tool; no wrapper executable file needs to exist next to it.
  let sidecarPath =
    findToolProfileSidecarOnPath(useDef.executableName, searchList)
  if sidecarPath.len > 0:
    let sidecar = readSidecarToolProfile(sidecarPath)
    let resolvedFromSidecar = sidecar.getOrDefault("resolvedExecutablePath")
    if resolvedFromSidecar.len > 0 and
        fileExists(extendedPath(resolvedFromSidecar)):
      result = PathOnlyToolProfile(
        installMethod: "path",
        packageSelector: useDef.packageSelector,
        packageId: useDef.packageSelector,
        declaredExecutablePath: useDef.executableName,
        executableName: useDef.executableName,
        pathSearchList: searchList,
        resolvedExecutablePath: resolvedFromSidecar,
        adapterStrength: asWeak,
        cachePortability: cpLocalOnly)
      result.applySidecarProfile(sidecar)
      result.probes = collectConfiguredProbes(result.resolvedExecutablePath,
        useDef.packageSelector, useDef.executableName)
      result.profileFingerprint = profileFingerprintFor(result)
      return

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

  result.probes = collectConfiguredProbes(resolved,
    useDef.packageSelector, useDef.executableName)

  result.profileFingerprint = profileFingerprintFor(result)

proc lockedNixpkgsRef(baseRef, narHash: string): string =
  result = baseRef
  if narHash.len > 0 and not result.contains("narHash="):
    if result.contains("?"):
      result.add("&narHash=")
    else:
      result.add("?narHash=")
    result.add(narHash)

proc effectiveNixSelector(selected: InterfaceNixProvisioning): string =
  if selected.nixpkgsRef.len > 0 and selected.selector.startsWith("nixpkgs#"):
    return lockedNixpkgsRef(selected.nixpkgsRef,
      selected.nixpkgsNarHash) & "#" & selected.selector["nixpkgs#".len .. ^1]
  selected.selector

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
  let resolvedSelector = effectiveNixSelector(selected)
  let lockIdentity =
    if selected.lockIdentity.len > 0:
      selected.lockIdentity
    elif selected.nixpkgsRef.len > 0:
      resolvedSelector
    else:
      selected.selector
  NixAcquisitionPlan(
    packageSelector: useDef.packageSelector,
    packageId: packageId,
    nixSelector: resolvedSelector,
    declaredExecutablePath: selected.executablePath,
    nixExpressionFile: selected.expressionFile,
    nixpkgsRef: selected.nixpkgsRef,
    nixpkgsRev: selected.nixpkgsRev,
    nixpkgsNarHash: selected.nixpkgsNarHash,
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
      if getFileInfo(extendedPath(current), followSymlink = false).kind in
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
  if fileExists(extendedPath(candidate)) and {fpUserExec, fpGroupExec, fpOthersExec}.anyIt(
      it in getFilePermissions(extendedPath(candidate))):
    absolutePath(candidate)
  else:
    ""

proc safeStoreSegment(value, fallback: string): string =
  for ch in value:
    if ch in {'a' .. 'z'} or ch in {'A' .. 'Z'} or ch in {'0' .. '9'} or
        ch in {'-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = fallback

proc versionFromPackageSelector(packageSelector: string): string =
  ## Best-effort extraction of a version component out of a package
  ## selector like `foo@1.0.0` or `foo-1.0.0`. The tarball metadata
  ## does not always carry a separate version field, so the realized
  ## prefix's `<version>` segment falls back to a synthesized name.
  for sep in ['@', '#']:
    let idx = packageSelector.rfind(sep)
    if idx > 0 and idx + 1 < packageSelector.len:
      return packageSelector[idx + 1 .. ^1]
  ""

# ---------------------------------------------------------------------------
# M56 — Unified store registration.
#
# Every adapter (Nix / tarball / Scoop) calls `registerInUnifiedStore` after
# it has materialized its realized prefix at the canonical
# `<store-root>/prefixes/<package>/<version>-<hash>/` location. The helper
# opens the M56 SQLite-backed store index, computes the realization hash
# the store records, seals a typed `.repro-receipt` binary envelope at the
# prefix root, and inserts the row idempotently.
#
# The function deliberately accepts the on-disk prefix path the adapter
# has already prepared (it does NOT move bytes around). Adapters are
# expected to choose the prefix path with `unifiedPrefixPath` so a
# subsequent `repro store gc` finds the directory through the standard
# layout.
# ---------------------------------------------------------------------------

proc unifiedStoreRoot*(explicit: string): string =
  ## Resolves the unified store root. Empty `explicit` falls through
  ## to the M56 `defaultUserStoreRoot()` (per-user OS XDG path).
  if explicit.len > 0: explicit
  else: defaultUserStoreRoot()

proc unifiedPrefixPath*(storeRoot, packageName, version, adapter,
                       lockIdentity, declaredExecutablePath: string;
                       provenanceUrl = ""; provenanceChecksum = "";
                       extra: openArray[string] = []):
    tuple[absolutePath: string; relativePath: string;
          prefixId: PrefixIdBytes] =
  ## Returns the canonical M56 prefix path the adapter must materialize
  ## into. The path is `<store-root>/prefixes/<safe-package>/<version>-
  ## <realization-hash-prefix>/`. `relativePath` is store-rooted with
  ## forward slashes — the same form persisted in the `prefixes`
  ## index column.
  let prefixId = computeRealizationHash(packageName, version, adapter,
    lockIdentity, declaredExecutablePath, provenanceUrl,
    provenanceChecksum, extra)
  let rel = prefixRelativePath(packageName, version, prefixId)
  (absolutePath: storeRoot / rel.replace('/', DirSep),
   relativePath: rel,
   prefixId: prefixId)

proc registerInUnifiedStore*(storeRoot, packageName, version, adapter,
                            lockIdentity, declaredExecutablePath,
                            provenanceUrl, provenanceChecksum,
                            materializationMechanism: string;
                            extra: openArray[string];
                            absoluteRealizedPath: string;
                            exportedExecutables: openArray[string] = []):
    tuple[prefixId: PrefixIdBytes; inserted: bool] =
  ## Records the materialized prefix in the unified store and seals the
  ## binary `.repro-receipt` envelope at its root.
  let prefixId = computeRealizationHash(packageName, version, adapter,
    lockIdentity, declaredExecutablePath, provenanceUrl,
    provenanceChecksum, extra)
  let rel = prefixRelativePath(packageName, version, prefixId)
  let receipt = RealizationReceipt(
    schemaVersion: 1'u16,
    adapter: adapter,
    packageName: packageName,
    version: version,
    realizationHash: prefixId,
    realizedPath: rel,
    declaredExecutablePath: declaredExecutablePath,
    exportedExecutables: @exportedExecutables,
    lockIdentity: lockIdentity,
    provenanceUrl: provenanceUrl,
    provenanceChecksum: provenanceChecksum,
    materializationMechanism: materializationMechanism,
    createdAtUnix: getTime().toUnix,
    writerProcessId: int64(getCurrentProcessId()),
    writerMode: "direct")
  let receiptBytes = encodeReceipt(receipt)
  var receiptText = newString(receiptBytes.len)
  for i, b in receiptBytes:
    receiptText[i] = char(b)
  createDir(extendedPath(absoluteRealizedPath))
  writeFile(extendedPath(absoluteRealizedPath / ".repro-receipt"), receiptText)

  let row = PrefixRow(
    prefixId: prefixId,
    packageName: packageName,
    version: version,
    realizedPath: rel,
    adapter: adapter,
    receiptDigest: receiptDigest(receipt),
    createdAtUnix: receipt.createdAtUnix)
  var store = openStore(storeRoot)
  defer: store.close()
  let inserted = store.insertPrefixOrIgnore(row)
  (prefixId: prefixId, inserted: inserted)

proc writeProfile(outp: var seq[byte]; profile: PathOnlyToolProfile)
proc readProfile(bytes: openArray[byte]; pos: var int;
                 version: uint16): PathOnlyToolProfile

proc materializationKeyFileComponent(value: string): string =
  safeStoreSegment(value[0 .. min(value.high, 31)], "nix-materialization") &
    "-" & value

proc nixMaterializationExpressionDigest(path: string): string =
  if path.len == 0:
    return ""
  if not fileExists(extendedPath(path)):
    return "missing"
  blake3.toHex(blake3.digest(readFile(extendedPath(path))))

proc nixMaterializationCacheKey(useDef: InterfaceToolUse;
                                plan: NixAcquisitionPlan): string =
  var payload: seq[byte] = @[]
  payload.writeString("reprobuild.nix.materialization.v1")
  payload.writeString(hostOS)
  payload.writeString(hostCPU)
  payload.writeString(useDef.packageSelector)
  payload.writeString(useDef.executableName)
  payload.writeString(plan.packageSelector)
  payload.writeString(plan.packageId)
  payload.writeString(plan.nixSelector)
  payload.writeString(plan.declaredExecutablePath)
  payload.writeString(plan.nixExpressionFile)
  payload.writeString(nixMaterializationExpressionDigest(plan.nixExpressionFile))
  payload.writeString(plan.nixpkgsRef)
  payload.writeString(plan.nixpkgsRev)
  payload.writeString(plan.nixpkgsNarHash)
  payload.writeString(plan.lockIdentity)
  let probes = configuredProbes(useDef.packageSelector, useDef.executableName)
  payload.writeU32Le(uint32(probes.len))
  for probe in probes:
    payload.writeByte(byte(ord(probe.kind)))
    payload.writeString(probe.name)
    payload.writeStringSeq(probe.args)
  blake3.toHex(blake3.digest(toByteString(payload)))

proc nixMaterializationCachePath(storeRoot, key: string): string =
  storeRoot / "nix-materialization-cache" /
    (materializationKeyFileComponent(key) & ".rbnm")

proc executableFileUsable(path: string): bool =
  if not fileExists(extendedPath(path)):
    return false
  let permissions = getFilePermissions(extendedPath(path))
  {fpUserExec, fpGroupExec, fpOthersExec}.anyIt(it in permissions)

proc nixMaterializationProfileMatches(profile: PathOnlyToolProfile;
                                      useDef: InterfaceToolUse;
                                      plan: NixAcquisitionPlan): bool =
  if profile.installMethod != "nix":
    return false
  if profile.packageSelector != useDef.packageSelector:
    return false
  if profile.packageId != plan.packageId:
    return false
  if profile.nixSelector != plan.nixSelector:
    return false
  if profile.declaredExecutablePath != plan.declaredExecutablePath:
    return false
  if profile.nixExpressionFile != plan.nixExpressionFile:
    return false
  if profile.lockIdentity != plan.lockIdentity:
    return false
  if profile.executableName != useDef.executableName:
    return false
  if profile.selectedStorePath.len == 0 or
      not dirExists(extendedPath(profile.selectedStorePath)):
    return false
  if profile.realizationBoundary.len == 0 or
      not dirExists(extendedPath(profile.realizationBoundary)):
    return false
  if profile.resolvedExecutablePath.len == 0 or
      not executableFileUsable(profile.resolvedExecutablePath):
    return false
  if profile.realizedStorePaths.len == 0:
    return false
  for storePath in profile.realizedStorePaths:
    if storePath.len == 0 or not dirExists(extendedPath(storePath)):
      return false
  for searchPath in profile.pathSearchList:
    if searchPath.len == 0 or not dirExists(extendedPath(searchPath)):
      return false
  if profile.profileFingerprint != profileFingerprintFor(profile):
    return false
  true

proc encodeNixMaterializationProfile(profile: PathOnlyToolProfile): seq[byte] =
  var payload: seq[byte] = @[]
  payload.writeProfile(profile)
  result.add(NixMaterializationMagic)
  result.writeU16Le(NixMaterializationVersion)
  result.writeU16Le(ArtifactVersion)
  result.writeU32Le(uint32(payload.len))
  result.add(payload)

proc decodeNixMaterializationProfile(bytes: openArray[byte]):
    PathOnlyToolProfile =
  if bytes.len < 12:
    raiseEnvelopeError(eeMalformed, "truncated nix materialization receipt")
  for i in 0 ..< NixMaterializationMagic.len:
    if bytes[i] != NixMaterializationMagic[i]:
      raiseEnvelopeError(eeUnknownMagic,
        "unknown nix materialization receipt magic")
  var pos = 4
  let receiptVersion = readU16Le(bytes, pos)
  if receiptVersion != NixMaterializationVersion:
    raiseEnvelopeError(eeUnsupportedVersion,
      "unsupported nix materialization receipt version")
  let profileVersion = readU16Le(bytes, pos)
  if profileVersion < 1'u16 or profileVersion > ArtifactVersion:
    raiseEnvelopeError(eeUnsupportedVersion,
      "unsupported nix materialization profile version")
  let payloadLength = int(readU32Le(bytes, pos))
  if pos + payloadLength != bytes.len:
    raiseEnvelopeError(eeMalformed,
      "nix materialization receipt payload length mismatch")
  result = readProfile(bytes, pos, profileVersion)
  if pos != bytes.len:
    raiseEnvelopeError(eeMalformed,
      "trailing nix materialization receipt bytes")

proc readCachedNixMaterialization(storeRoot: string; useDef: InterfaceToolUse;
                                  plan: NixAcquisitionPlan):
    tuple[hit: bool; profile: PathOnlyToolProfile] =
  if storeRoot.len == 0:
    return
  let key = nixMaterializationCacheKey(useDef, plan)
  let path = nixMaterializationCachePath(storeRoot, key)
  if not fileExists(extendedPath(path)):
    return
  try:
    let profile = decodeNixMaterializationProfile(
      fromByteString(readFile(extendedPath(path))))
    if not profile.nixMaterializationProfileMatches(useDef, plan):
      return
    return (hit: true, profile: profile)
  except CatchableError:
    return

proc writeCachedNixMaterialization(storeRoot: string; useDef: InterfaceToolUse;
                                   plan: NixAcquisitionPlan;
                                   profile: PathOnlyToolProfile) =
  if storeRoot.len == 0:
    return
  let key = nixMaterializationCacheKey(useDef, plan)
  let path = nixMaterializationCachePath(storeRoot, key)
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path),
    toByteString(encodeNixMaterializationProfile(profile)))

proc resolveNixTool*(useDef: InterfaceToolUse;
                     storeRoot = ""): PathOnlyToolProfile =
  let plan = nixAcquisitionPlan(useDef)
  let selector = plan.nixSelector
  let cached = readCachedNixMaterialization(storeRoot, useDef, plan)
  if cached.hit:
    return cached.profile

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

  result.probes = collectConfiguredProbes(resolved,
    useDef.packageSelector, useDef.executableName)

  if storeRoot.len > 0:
    # M56 — record the Nix realization in the unified index. The Nix
    # store keeps the actual files at `/nix/store/...`; the unified
    # prefix is a small marker directory whose receipt records the
    # /nix/store path as adapter-specific provenance so a subsequent
    # `repro store gc` knows which Nix outputs the user holds live.
    let nixPackageName = safeStoreSegment("nix." & plan.packageId,
      "nix-package")
    let nixVersion =
      if versionFromPackageSelector(plan.packageSelector).len > 0:
        versionFromPackageSelector(plan.packageSelector)
      else:
        # Use the last path segment of the /nix/store derivation as
        # version; it usually carries the upstream version string.
        let segment = selectedStorePath.extractFilename
        let dash = segment.find('-')
        if dash >= 0 and dash + 1 < segment.len:
          segment[dash + 1 .. ^1]
        else:
          segment
    let unified = unifiedPrefixPath(storeRoot, nixPackageName,
      nixVersion, "nix", plan.lockIdentity,
      plan.declaredExecutablePath, "nix://" & plan.nixSelector,
      selectedStorePath, realized)
    createDir(extendedPath(unified.absolutePath))
    writeFile(extendedPath(unified.absolutePath / "nix-store-path.txt"),
      selectedStorePath & "\n")
    discard registerInUnifiedStore(storeRoot, nixPackageName,
      nixVersion, "nix", plan.lockIdentity,
      plan.declaredExecutablePath, "nix://" & plan.nixSelector,
      selectedStorePath, "nix-store-pointer", realized,
      unified.absolutePath, [plan.declaredExecutablePath])
    # Update the path-only profile to advertise the unified store
    # path alongside the /nix/store realization so callers can record
    # both for downstream tooling.
    result.realizedStorePaths.add(unified.absolutePath)

  result.profileFingerprint = profileFingerprintFor(result)
  writeCachedNixMaterialization(storeRoot, useDef, plan, result)

proc normalizedSha256(value: string): string =
  result = value.strip().toLowerAscii()
  if result.startsWith("sha256:"):
    result = result["sha256:".len .. ^1]
  if result.len != 64 or result.anyIt(not (it in {'0' .. '9', 'a' .. 'f'})):
    raise newException(ValueError, "invalid sha256 digest: " & value)

proc parseHexLine(output: string): string =
  ## Scans `output` line by line for the first 64-hex-digit token. Used
  ## to robustly parse the SHA-256 verifier's output regardless of
  ## whether it was sha256sum/shasum/openssl/certutil's idiosyncratic
  ## prefixing.  Also handles sha256sum's `\<digest> *<path>` form
  ## (the leading literal backslash signals a path that itself
  ## contains backslashes, common on Windows paths).
  proc clean(s: string): string =
    result = s
    if result.startsWith("\\"):
      result = result[1 .. ^1]
    if result.startsWith("*"):
      result = result[1 .. ^1]
    result = result.replace(" ", "").toLowerAscii()
  for line in output.splitLines:
    let stripped = line.strip()
    if stripped.len == 0:
      continue
    for token in stripped.splitWhitespace():
      let candidate = clean(token)
      if candidate.len == 64 and candidate.allCharsInSet(HexDigits):
        return candidate
    let collapsed = clean(stripped)
    if collapsed.len == 64 and collapsed.allCharsInSet(HexDigits):
      return collapsed
  ""

proc fileSha256Hex*(path: string): string =
  ## Compute the SHA-256 hex digest of `path` using whichever tool the
  ## host provides. Windows ships `certutil -hashfile <path> SHA256` as
  ## a built-in; macOS and Linux ship one of sha256sum / shasum /
  ## openssl. We prefer in this order:
  ##   sha256sum → shasum → certutil (Windows) → openssl.
  let sha256sum = findExe("sha256sum")
  let shasum = findExe("shasum")
  let openssl = findExe("openssl")
  when defined(windows):
    let certutil = findExe("certutil")
  else:
    let certutil = ""
  let command =
    if sha256sum.len > 0:
      shellCommand(["sha256sum", path])
    elif shasum.len > 0:
      shellCommand(["shasum", "-a", "256", path])
    elif certutil.len > 0:
      shellCommand(["certutil", "-hashfile", path, "SHA256"])
    elif openssl.len > 0:
      shellCommand(["openssl", "dgst", "-sha256", "-r", path])
    else:
      raise newException(OSError,
        "tool-resolution failed: no sha256 verifier found (tried " &
        "sha256sum, shasum, certutil, openssl)")
  let res = execCmdEx(command)
  if res.exitCode != 0:
    raise newException(OSError,
      "tool-resolution failed: sha256 verifier exited " & $res.exitCode &
      "\n" & res.output)
  let parsed = parseHexLine(res.output)
  if parsed.len == 0:
    raise newException(OSError, "tool-resolution failed: sha256 verifier " &
      "produced no recognizable digest in:\n" & res.output)
  normalizedSha256(parsed)

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
  createDir(extendedPath(parentDir(destination)))
  if url.startsWith("file://"):
    let source = url["file://".len .. ^1]
    if not fileExists(extendedPath(source)):
      raise newException(IOError, "file URL does not exist: " & url)
    copyFile(extendedPath(source), extendedPath(destination))
  elif url.startsWith("http://") or url.startsWith("https://"):
    let curl = findExe("curl")
    if curl.len == 0:
      raise newException(IOError,
        "curl is required to download archive URL: " & url)
    let process = startProcess(curl,
      args = ["-L", "--fail", "--silent", "--show-error", "-o",
        destination, url],
      options = {poUsePath, poParentStreams})
    let exitCode = waitForExit(process)
    close(process)
    if exitCode != 0:
      raise newException(IOError,
        "curl failed while downloading archive URL: " & url)
  else:
    if not fileExists(extendedPath(url)):
      raise newException(IOError, "unsupported archive URL or missing file: " & url)
    copyFile(extendedPath(url), extendedPath(destination))

proc verifiedDownload(plan: TarballAcquisitionPlan; storeRoot: string):
    tuple[path: string; selectedUrl: string] =
  let downloads = storeRoot / "downloads"
  let tmpRoot = storeRoot / "tmp"
  createDir(extendedPath(downloads))
  createDir(extendedPath(tmpRoot))
  let finalPath = downloads / (plan.sha256 & ".archive")
  if fileExists(extendedPath(finalPath)):
    let actual = fileSha256Hex(finalPath)
    if actual == plan.sha256:
      return (path: finalPath, selectedUrl: "cache")
    removeFile(extendedPath(finalPath))

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
        removeFile(extendedPath(tmpPath))
        continue
      try:
        moveFile(extendedPath(tmpPath), extendedPath(finalPath))
      except OSError:
        if fileExists(extendedPath(finalPath)) and fileSha256Hex(finalPath) == plan.sha256:
          if fileExists(extendedPath(tmpPath)):
            removeFile(extendedPath(tmpPath))
        else:
          raise
      return (path: finalPath, selectedUrl: url)
    except CatchableError as e:
      diagnostics.add(url & ": " & e.msg)
      if fileExists(extendedPath(tmpPath)):
        removeFile(extendedPath(tmpPath))
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
  createDir(extendedPath(destination))
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
  writeFile(extendedPath(tarballReceiptPath(prefix)), receipt.pretty())

proc selectedUrlFromReceipt(prefix: string): string =
  let path = tarballReceiptPath(prefix)
  if not fileExists(extendedPath(path)):
    return "existing"
  try:
    result = parseFile(path){"selectedUrl"}.getStr("existing")
  except CatchableError:
    result = "existing"

proc materializeTarballPrefix(plan: TarballAcquisitionPlan; storeRoot: string):
    tuple[prefix: string; archivePath: string; selectedUrl: string] =
  ## Materializes a tarball realization into the unified M56 layout
  ## (`<store-root>/prefixes/<package>/<version>-<hash>/`).
  let tmpRoot = storeRoot / "tmp"
  createDir(extendedPath(tmpRoot))
  let packageName = safeStoreSegment(plan.packageSelector, "package")
  let resolvedVersion =
    if versionFromPackageSelector(plan.packageSelector).len > 0:
      versionFromPackageSelector(plan.packageSelector)
    else:
      plan.sha256[0 .. 15]
  let unified = unifiedPrefixPath(storeRoot, packageName, resolvedVersion,
    "tarball", plan.lockIdentity, plan.declaredExecutablePath,
    plan.url, plan.sha256, [plan.archiveType, $plan.stripComponents])
  let prefix = unified.absolutePath
  if dirExists(extendedPath(prefix)):
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
  if dirExists(extendedPath(tempPrefix)):
    removeDir(extendedPath(tempPrefix))
  try:
    extractTarballArchive(downloaded.path, tempPrefix, plan.archiveType,
      plan.stripComponents)
    if executableInStorePath(tempPrefix, plan.declaredExecutablePath,
        rejectSymlinks = true).len == 0:
      raise newException(OSError,
        "tool-resolution failed: extracted tarball lacks executable " &
        plan.declaredExecutablePath)
    writeTarballReceipt(tempPrefix, plan, downloaded.selectedUrl)
    createDir(extendedPath(prefix.parentDir))
    try:
      moveDir(extendedPath(tempPrefix), extendedPath(prefix))
    except OSError:
      if dirExists(extendedPath(prefix)):
        removeDir(extendedPath(tempPrefix))
      else:
        raise
    if executableInStorePath(prefix, plan.declaredExecutablePath,
        rejectSymlinks = true).len == 0:
      raise newException(OSError,
        "tool-resolution failed: materialized tarball lacks executable " &
        plan.declaredExecutablePath)
    # Register in the unified M56 index and seal the typed binary
    # `.repro-receipt` envelope (the JSON receipt already written by
    # writeTarballReceipt is adapter-specific provenance and stays
    # alongside the binary receipt).
    discard registerInUnifiedStore(storeRoot, packageName,
      resolvedVersion, "tarball", plan.lockIdentity,
      plan.declaredExecutablePath, plan.url, plan.sha256, "directory",
      [plan.archiveType, $plan.stripComponents], prefix,
      [plan.declaredExecutablePath])
    (prefix: prefix, archivePath: downloaded.path,
      selectedUrl: downloaded.selectedUrl)
  except CatchableError:
    if dirExists(extendedPath(tempPrefix)):
      removeDir(extendedPath(tempPrefix))
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

  result.probes = collectConfiguredProbes(resolved,
    useDef.packageSelector, useDef.executableName)

  result.profileFingerprint = profileFingerprintFor(result)

proc blake3HexBytes*(bytes: openArray[byte]): string =
  blake3.toHex(blake3.digest(bytes))

proc blake3HexText*(value: string): string =
  blake3.toHex(blake3.digest(value))

proc blake3HexFile*(path: string): string =
  blake3.toHex(blake3.digest(readFile(extendedPath(path))))

proc normalizeScoopVersionTag(value: string): string =
  result = value.strip()
  if result.startsWith("v") and result.len > 1 and result[1].isDigit():
    result = result[1 .. ^1]

proc parsePreferredVersionConstraint(spec: string):
    tuple[minInclusive, minExclusive, maxInclusive, maxExclusive, equality:
      string] =
  for raw in spec.split(','):
    var token = raw.strip()
    if token.len == 0:
      continue
    if token.startsWith(">="):
      result.minInclusive = token[2 .. ^1].strip()
    elif token.startsWith(">"):
      result.minExclusive = token[1 .. ^1].strip()
    elif token.startsWith("<="):
      result.maxInclusive = token[2 .. ^1].strip()
    elif token.startsWith("<"):
      result.maxExclusive = token[1 .. ^1].strip()
    elif token.startsWith("=="):
      result.equality = token[2 .. ^1].strip()
    elif token.startsWith("="):
      result.equality = token[1 .. ^1].strip()
    else:
      result.equality = token

proc parseVersionTokens(value: string): seq[int] =
  for chunk in value.split({'.', '-', '+'}):
    if chunk.len == 0:
      continue
    var n = 0
    var ok = true
    for ch in chunk:
      if not ch.isDigit():
        ok = false
        break
      n = n * 10 + (ord(ch) - ord('0'))
    if ok:
      result.add(n)

proc compareVersions(a, b: string): int =
  let ta = parseVersionTokens(a)
  let tb = parseVersionTokens(b)
  let n = max(ta.len, tb.len)
  for i in 0 ..< n:
    let va = if i < ta.len: ta[i] else: 0
    let vb = if i < tb.len: tb[i] else: 0
    if va < vb: return -1
    if va > vb: return 1
  cmp(a, b)

proc versionSatisfiesRange(version, constraint: string): bool =
  if constraint.len == 0:
    return true
  let parts = parsePreferredVersionConstraint(constraint)
  if parts.equality.len > 0:
    return compareVersions(version, parts.equality) == 0
  if parts.minInclusive.len > 0 and compareVersions(version,
      parts.minInclusive) < 0:
    return false
  if parts.minExclusive.len > 0 and compareVersions(version,
      parts.minExclusive) <= 0:
    return false
  if parts.maxInclusive.len > 0 and compareVersions(version,
      parts.maxInclusive) > 0:
    return false
  if parts.maxExclusive.len > 0 and compareVersions(version,
      parts.maxExclusive) >= 0:
    return false
  true

proc installedVersionSatisfies*(installedVersions: openArray[string];
                                pinnedVersion, preferredVersion: string):
    tuple[satisfied: bool; version: string] =
  ## M80 shared predicate: given the set of Scoop versions already
  ## installed on disk for an app (the exact-version directory leaves
  ## under `apps/<app>/`, `current` excluded), decide whether an
  ## already-installed version satisfies the package's version
  ## reference — independent of the current bucket head.
  ##
  ## This is the SINGLE decision both the apply-time adapter
  ## (`resolveScoopTool`, M77) and the plan-time package classifier
  ## (`repro_home_apply/package_catalog.resolvePackage`, M80) consult,
  ## so the dry-run plan and the real apply can never disagree on
  ## whether an installed package is a cache-hit.
  ##
  ## Semantics — mirrors M77's `resolveScoopTool`:
  ##   * pinned (`pinnedVersion` non-empty): satisfied iff that exact
  ##     version is installed. `resolveScoopTool` treats the pinned
  ##     version's on-disk install tree as a cache-hit and performs no
  ##     install, so the bucket head is irrelevant.
  ##   * ranged (`preferredVersion` non-empty): satisfied iff some
  ##     installed version satisfies the range; the highest such
  ##     version is returned (matching `resolveScoopTool`'s
  ##     `installedSatisfying` pick).
  ##   * bare reference (both empty — the shape a `home.nim` package
  ##     reference always has): satisfied by ANY installed version.
  ##
  ## A NOT-installed reference is never satisfied here — the caller
  ## then classifies it as a genuine install/`realize`.
  let pinned = normalizeScoopVersionTag(pinnedVersion)
  if pinned.len > 0:
    for installed in installedVersions:
      if normalizeScoopVersionTag(installed) == pinned:
        return (true, installed)
    return (false, "")
  var best = ""
  for installed in installedVersions:
    let norm = normalizeScoopVersionTag(installed)
    if preferredVersion.len == 0 or versionSatisfiesRange(norm,
        preferredVersion):
      if best.len == 0 or compareVersions(norm,
          normalizeScoopVersionTag(best)) > 0:
        best = installed
  (best.len > 0, best)

proc scoopExecutableName(): string =
  when defined(windows):
    "scoop.cmd"
  else:
    "scoop"

proc resolveScoopExecutable(scoopOverride: string): string =
  if scoopOverride.len > 0 and fileExists(extendedPath(scoopOverride)):
    return scoopOverride
  let envOverride = getEnv("REPROBUILD_SCOOP_BINARY")
  if envOverride.len > 0 and fileExists(extendedPath(envOverride)):
    return envOverride
  # scoop.exe is just a CLI launcher around the PowerShell entry point,
  # but on Windows hosts the typical install ships scoop.cmd / scoop.ps1
  # under <scoopRoot>/shims. Walk PATH explicitly to surface
  # EScoopMissing when the user removed it.
  for candidate in @["scoop.cmd", "scoop.exe", "scoop.ps1", "scoop"]:
    let resolved = findExe(candidate)
    if resolved.len > 0:
      return resolved
  ""

proc scoopAcquisitionPlan*(useDef: InterfaceToolUse): ScoopAcquisitionPlan =
  if useDef.scoopProvisioning.len == 0:
    raise newException(ValueError,
      "tool-resolution failed: package \"" & useDef.packageSelector &
      "\" requested by uses \"" & useDef.rawConstraint &
      "\" does not declare provisioning: scoopApp metadata")
  let selected = useDef.scoopProvisioning[0]
  if selected.bucket.len == 0 or selected.app.len == 0 or
      selected.executablePath.len == 0:
    raise newException(ValueError,
      "tool-resolution failed: incomplete scoopApp metadata for package \"" &
      useDef.packageSelector & "\"")
  if selected.version.len == 0 and selected.preferredVersion.len == 0:
    raise newException(ValueError,
      "tool-resolution failed: scoopApp for \"" & useDef.packageSelector &
      "\" must declare version or preferredVersion")
  let packageId =
    if selected.packageId.len > 0:
      selected.packageId
    else:
      selected.bucket & "/" & selected.app
  let lockIdentity =
    if selected.lockIdentity.len > 0:
      selected.lockIdentity
    else:
      "scoop:" & selected.bucket & "/" & selected.app
  ScoopAcquisitionPlan(
    packageSelector: useDef.packageSelector,
    packageId: packageId,
    bucket: selected.bucket,
    app: selected.app,
    version: selected.version,
    preferredVersion: selected.preferredVersion,
    manifestChecksum: selected.manifestChecksum,
    manifestUrl: selected.manifestUrl,
    declaredExecutablePath: selected.executablePath,
    requiresExecutionProfileChecksum:
      selected.requiresExecutionProfileChecksum,
    lockIdentity: lockIdentity)

proc resolveScoopRoot(scoopOverride: string): string =
  let explicit = getEnv("SCOOP")
  if explicit.len > 0:
    return explicit
  if scoopOverride.len > 0:
    let parent = scoopOverride.parentDir.parentDir
    if dirExists(extendedPath(parent / "apps")):
      return parent
  let home = getEnv("USERPROFILE", getEnv("HOME"))
  if home.len > 0:
    return home / "scoop"
  ""

proc readScoopManifest(scoopRoot, bucket, app: string): tuple[
    raw: string; version: string; checksum: string; path: string] =
  let manifestPath = scoopRoot / "buckets" / bucket / "bucket" / (app & ".json")
  if not fileExists(extendedPath(manifestPath)):
    raise newException(EScoopBucketMissing,
      "EScoopBucketMissing: bucket manifest not present at " & manifestPath)
  var raw: string
  try:
    raw = readFile(extendedPath(manifestPath))
  except CatchableError as err:
    raise newException(EScoopManifestUnreadable,
      "EScoopManifestUnreadable: " & manifestPath & ": " & err.msg)
  var parsed: JsonNode
  try:
    parsed = parseJson(raw)
  except CatchableError as err:
    raise newException(EScoopManifestUnreadable,
      "EScoopManifestUnreadable: " & manifestPath & ": " & err.msg)
  if parsed.kind != JObject:
    raise newException(EScoopManifestUnreadable,
      "EScoopManifestUnreadable: " & manifestPath & ": top-level JSON is not an object")
  if not parsed.hasKey("version"):
    raise newException(EScoopManifestUnreadable,
      "EScoopManifestUnreadable: " & manifestPath & ": missing version field")
  let version = parsed["version"].getStr()
  if version.len == 0:
    raise newException(EScoopManifestUnreadable,
      "EScoopManifestUnreadable: " & manifestPath & ": empty version field")
  result = (raw: raw, version: version, checksum: blake3HexText(raw),
    path: manifestPath)

# ---------------------------------------------------------------------------
# M74: Scoop manifest `bin`-field parser.
#
# A Scoop app's manifest declares which executables it exposes via the
# `bin` field. The authoritative on-disk executable layout VARIES per
# app — `gh` keeps its executable at `<versionDir>/bin/gh.exe`, others
# place it at the version root — so the adapter MUST resolve executable
# paths from the manifest rather than assume a fixed `bin/` layout.
#
# `bin` takes these forms (all handled here):
#   * a single string:   "bin": "gh.exe"  /  "bin": "bin\\gh.exe"
#   * an array of strings: "bin": ["a.exe", "sub\\b.exe"]
#   * an array whose entries may themselves be [path, alias, args]
#     arrays: "bin": [["bin\\app.exe", "app", "--flag"]] — the FIRST
#     element is the executable path (the 2nd/3rd are shim alias/args).
#   * mixed arrays (some entries strings, some arrays) are allowed.
# Every path is relative to the app's version directory and may use
# `\` or `/`; both are normalized to the host `DirSep`.
#
# A manifest with NO `bin` field is valid — some apps are libraries or
# `env_add_path`-only. The parser returns an empty seq in that case;
# the realize step treats that as "no executable, no launcher" and
# does NOT raise.
proc normalizeScoopBinPath(raw: string): string =
  ## Normalize a manifest `bin` path: trim, collapse separators to the
  ## host `DirSep`. The path stays relative to the version directory.
  raw.strip().replace('/', DirSep).replace('\\', DirSep)

proc parseScoopManifestBin*(manifestNode: JsonNode; manifestPath: string):
    seq[string] =
  ## Parse the `bin` field of an already-parsed Scoop manifest JSON node
  ## into a list of executable paths relative to the version directory.
  ## Handles the string / array-of-strings / array-of-`[path,alias,args]`
  ## forms (and mixtures). Returns an empty seq when there is no `bin`
  ## field. Raises `EScoopManifestUnreadable` for a structurally invalid
  ## `bin` field (e.g. a number, or an array entry that is neither a
  ## string nor a non-empty array whose first element is a string).
  if manifestNode.isNil or manifestNode.kind != JObject:
    return @[]
  let binNode = manifestNode{"bin"}
  if binNode.isNil:
    return @[]
  case binNode.kind
  of JString:
    let p = normalizeScoopBinPath(binNode.getStr(""))
    if p.len > 0:
      result.add(p)
  of JArray:
    for entry in binNode:
      case entry.kind
      of JString:
        let p = normalizeScoopBinPath(entry.getStr(""))
        if p.len > 0:
          result.add(p)
      of JArray:
        # `[path, alias, args]` — only the first element is the path.
        if entry.len == 0 or entry[0].kind != JString:
          raise newException(EScoopManifestUnreadable,
            "EScoopManifestUnreadable: " & manifestPath &
            ": bin array entry is not a [path, ...] array with a " &
            "string first element")
        let p = normalizeScoopBinPath(entry[0].getStr(""))
        if p.len > 0:
          result.add(p)
      else:
        raise newException(EScoopManifestUnreadable,
          "EScoopManifestUnreadable: " & manifestPath &
          ": bin array entry is neither a string nor a [path, ...] array")
  else:
    raise newException(EScoopManifestUnreadable,
      "EScoopManifestUnreadable: " & manifestPath &
      ": bin field is neither a string nor an array")

proc manifestDeclaresShortcuts*(manifestNode: JsonNode): bool =
  ## M75: a Scoop manifest's `shortcuts` field is the reliable signal
  ## that the app is a GUI application with a Start Menu entry. Its mere
  ## PRESENCE (as a non-empty JSON array) is what matters — Reprobuild
  ## never creates the shortcut, it only reads the field to decide that
  ## the app must NOT be exec-probed (a GUI app launched with
  ## `--version` opens the full application and never exits).
  if manifestNode.isNil or manifestNode.kind != JObject:
    return false
  let node = manifestNode{"shortcuts"}
  if node.isNil:
    return false
  # Scoop's `shortcuts` is an array of `[target, name, ...]` entries.
  result = node.kind == JArray and node.len > 0

proc readInstalledManifestBin*(versionDir: string):
    tuple[binPaths: seq[string]; manifestPath: string; present: bool;
          hasShortcuts: bool] =
  ## Read the installed app's `manifest.json` (Scoop copies the bucket
  ## manifest into `<versionDir>/manifest.json` on install) and parse
  ## its `bin` field. `present` is false when no `manifest.json` exists
  ## in the version directory — the caller decides whether that is an
  ## error (it is not for M74: the realize step then has no manifest
  ## `bin` to honor and falls back to the package-declared path).
  ## M75: `hasShortcuts` reports whether the manifest declares a
  ## `shortcuts` field — the GUI-app signal that suppresses exec-probing.
  let manifestPath = versionDir / "manifest.json"
  result.manifestPath = manifestPath
  if not fileExists(extendedPath(manifestPath)):
    result.present = false
    return
  result.present = true
  var parsed: JsonNode
  try:
    parsed = parseJson(readFile(extendedPath(manifestPath)))
  except CatchableError as err:
    raise newException(EScoopManifestUnreadable,
      "EScoopManifestUnreadable: " & manifestPath & ": " & err.msg)
  if parsed.kind != JObject:
    raise newException(EScoopManifestUnreadable,
      "EScoopManifestUnreadable: " & manifestPath &
      ": installed manifest top-level JSON is not an object")
  result.binPaths = parseScoopManifestBin(parsed, manifestPath)
  result.hasShortcuts = manifestDeclaresShortcuts(parsed)

proc selectPrimaryScoopExecutable*(binPaths: seq[string];
                                   preferredLeaf, appName: string): string =
  ## Pick the primary executable from the manifest-declared `bin` paths.
  ## The home-apply launcher model exports ONE command per package, so
  ## the adapter records one primary executable. Selection order:
  ##   1. the `bin` entry whose leaf name matches `preferredLeaf` (the
  ##      package-declared executable path's leaf — e.g. `gh.exe`);
  ##   2. the `bin` entry whose leaf matches `<appName>.exe` / `appName`;
  ##   3. the first declared `bin` entry.
  ## Returns "" when `binPaths` is empty (a manifest with no `bin`).
  if binPaths.len == 0:
    return ""
  let wantLeaf = extractFilename(preferredLeaf).toLowerAscii()
  if wantLeaf.len > 0:
    for p in binPaths:
      if extractFilename(p).toLowerAscii() == wantLeaf:
        return p
  let appLeafExe = (appName & ".exe").toLowerAscii()
  let appLeaf = appName.toLowerAscii()
  for p in binPaths:
    let leaf = extractFilename(p).toLowerAscii()
    if leaf == appLeafExe or leaf == appLeaf:
      return p
  binPaths[0]

# ---------------------------------------------------------------------------
# M75: GUI-application detection — PE subsystem inspection.
#
# The second GUI signal (after the manifest `shortcuts` field) is the
# primary executable's PE subsystem. A Windows PE Optional header
# carries a `Subsystem` field:
#   * IMAGE_SUBSYSTEM_WINDOWS_GUI (2) — a windowed GUI application; an
#     `--version` exec-probe launches the full app, which never exits.
#   * IMAGE_SUBSYSTEM_WINDOWS_CUI (3) — a console application; an
#     `--version` probe prints and exits — safe (and useful) to probe.
#
# PE layout walked here (all offsets bounds-checked):
#   offset 0x00  : DOS header — must start with the `MZ` magic.
#   offset 0x3C  : `e_lfanew`, a uint32 LE pointing at the PE header.
#   <pe>+0x00    : the 4-byte PE signature `PE\0\0`.
#   <pe>+0x04    : the 20-byte COFF file header.
#   <pe>+0x18    : the Optional header begins (PE-sig 4 + COFF 20).
#   <opt>+0x44   : the `Subsystem` field, a uint16 LE — i.e. at
#                  `<pe> + 4 + 20 + 0x44` = `<pe> + 0x5C` from the PE
#                  signature start.
# A file too small, not a PE, or otherwise malformed yields the
# `unknown` result and the caller falls back to the `shortcuts` signal.
type
  PeSubsystem* = enum
    pssUnknown   ## not a PE / too small / malformed — undetermined
    pssConsole   ## IMAGE_SUBSYSTEM_WINDOWS_CUI (3)
    pssGui       ## IMAGE_SUBSYSTEM_WINDOWS_GUI (2)

const
  imageSubsystemWindowsGui = 2'u16
  imageSubsystemWindowsCui = 3'u16

proc readU16LeAt(data: openArray[byte]; offset: int): tuple[ok: bool;
    value: uint16] =
  ## Bounds-checked little-endian uint16 read.
  if offset < 0 or offset + 1 >= data.len:
    return (ok: false, value: 0'u16)
  (ok: true, value: uint16(data[offset]) or
    (uint16(data[offset + 1]) shl 8))

proc readU32LeAt(data: openArray[byte]; offset: int): tuple[ok: bool;
    value: uint32] =
  ## Bounds-checked little-endian uint32 read.
  if offset < 0 or offset + 3 >= data.len:
    return (ok: false, value: 0'u32)
  (ok: true, value: uint32(data[offset]) or
    (uint32(data[offset + 1]) shl 8) or
    (uint32(data[offset + 2]) shl 16) or
    (uint32(data[offset + 3]) shl 24))

proc peExecutableSubsystem*(path: string): PeSubsystem =
  ## Inspect the PE Optional header `Subsystem` field of the executable
  ## at `path`. Returns `pssUnknown` for anything that is not a
  ## well-formed PE — including a `.cmd`/`.bat`/`.ps1` script, which is
  ## a console script and is handled by the caller as console.
  ##
  ## Every offset is bounds-checked; a truncated or malformed file
  ## degrades gracefully to `pssUnknown` rather than reading OOB.
  let ext = path.splitFile.ext.toLowerAscii()
  if ext in [".cmd", ".bat", ".ps1"]:
    # A script "executable" — not a PE; the caller treats it as console.
    return pssUnknown
  if not fileExists(extendedPath(path)):
    return pssUnknown
  var data: string
  try:
    data = readFile(extendedPath(path))
  except CatchableError:
    return pssUnknown
  let bytes = cast[seq[byte]](data)
  # DOS header: `MZ` magic at offset 0.
  if bytes.len < 0x40 or bytes[0] != byte('M') or bytes[1] != byte('Z'):
    return pssUnknown
  # `e_lfanew` (uint32 LE) at offset 0x3C points at the PE header.
  let lfanew = readU32LeAt(bytes, 0x3C)
  if not lfanew.ok:
    return pssUnknown
  let peOffset = int(lfanew.value)
  # PE signature `PE\0\0` (4 bytes) at peOffset.
  if peOffset < 0 or peOffset + 4 > bytes.len:
    return pssUnknown
  if bytes[peOffset] != byte('P') or bytes[peOffset + 1] != byte('E') or
     bytes[peOffset + 2] != 0'u8 or bytes[peOffset + 3] != 0'u8:
    return pssUnknown
  # Optional header `Subsystem` (uint16 LE) at PE-sig(4) + COFF(20) +
  # 0x44 = peOffset + 0x5C.
  let subsystem = readU16LeAt(bytes, peOffset + 0x5C)
  if not subsystem.ok:
    return pssUnknown
  case subsystem.value
  of imageSubsystemWindowsGui: pssGui
  of imageSubsystemWindowsCui: pssConsole
  else: pssUnknown

proc scoopAppIsGuiApplication*(manifestHasShortcuts: bool;
                               primaryExecutablePath: string): bool =
  ## M75 GUI-application decision. A realized Scoop app is treated as a
  ## GUI / non-exec-probeable app when EITHER:
  ##   * its installed manifest declares a `shortcuts` field (the
  ##     reliable Scoop GUI signal), OR
  ##   * its primary executable's PE subsystem is the GUI subsystem.
  ## A `.cmd`/`.bat`/`.ps1` script, or any non-PE / undetermined file,
  ## is NOT GUI on the PE signal — it falls through to the `shortcuts`
  ## result. For a GUI app the post-realize verification is
  ## presence-on-disk only and the binary is never executed.
  if manifestHasShortcuts:
    return true
  if primaryExecutablePath.len > 0:
    return peExecutableSubsystem(primaryExecutablePath) == pssGui
  false

proc deleteJunctionDir(target: string) =
  if not dirExists(extendedPath(target)):
    return
  when defined(windows):
    # Use cmd's rmdir which removes the junction reparse point without
    # following into the target directory.
    let res = execCmdEx("cmd /c rmdir " & quoteShell(target))
    if res.exitCode != 0 and dirExists(extendedPath(target)):
      removeDir(extendedPath(target))
  else:
    removeDir(extendedPath(target))

proc createScoopJunction(target, source: string) =
  ## Creates an NTFS junction (or symlink on POSIX) from `target` to `source`.
  if not dirExists(extendedPath(source)):
    raise newException(EScoopJunctionFailed,
      "EScoopJunctionFailed: junction source missing: " & source)
  createDir(extendedPath(target.parentDir))
  deleteJunctionDir(target)
  when defined(windows):
    let res = execCmdEx("cmd /c mklink /J " & quoteShell(target) & " " &
      quoteShell(source))
    if res.exitCode != 0 or not dirExists(extendedPath(target)):
      raise newException(EScoopJunctionFailed,
        "EScoopJunctionFailed: mklink /J " & target & " -> " & source &
        " exited " & $res.exitCode & "\n" & res.output)
  else:
    try:
      createSymlink(extendedPath(source), extendedPath(target))
    except OSError as err:
      raise newException(EScoopJunctionFailed,
        "EScoopJunctionFailed: createSymlink " & target & " -> " &
        source & ": " & err.msg)

proc readJunctionTarget*(junctionPath: string): string =
  ## Returns the resolved target of a junction/symlink, or "" if not found.
  when defined(windows):
    let res = execCmdEx("cmd /c dir /AL " &
      quoteShell(junctionPath.parentDir))
    if res.exitCode != 0:
      return ""
    let leaf = junctionPath.extractFilename
    for line in res.output.splitLines:
      if line.contains("<JUNCTION>") and line.contains(leaf):
        let openBracket = line.find('[')
        let closeBracket = line.rfind(']')
        if openBracket > 0 and closeBracket > openBracket:
          return line[openBracket + 1 ..< closeBracket].strip()
    ""
  else:
    try:
      expandSymlink(extendedPath(junctionPath))
    except OSError:
      ""

proc fileTreeListing(root: string): seq[string] =
  if not dirExists(extendedPath(root)):
    return
  # TODO(win-longpath): walk results escape; needs review
  for path in walkDirRec(root, yieldFilter = {pcFile, pcLinkToFile},
      relative = true):
    result.add(path.replace('\\', '/'))
  result.sort()

proc executionProfilePayload*(prefix: string;
                              relativeExecutablePath: string): string =
  ## Deterministic serialization of the post-install file tree at `prefix`,
  ## anchored on the declared executable. The serialization is:
  ##   reprobuild.scoop.executionProfile.v1\n
  ##   exe:<relative-path>\n
  ##   blake3:<hex of declared executable bytes>\n
  ##   files:<count>\n
  ##   <relative-path>\t<size>\t<blake3>\n  (sorted by path)
  ## A user-installed antivirus or a `scoop update` that rewrites any byte
  ## in the install tree will change this serialization, and therefore the
  ## stored execution-profile checksum.
  let normalizedExe = relativeExecutablePath.replace('\\', '/')
  result.add("reprobuild.scoop.executionProfile.v1\n")
  result.add("exe:" & normalizedExe & "\n")
  let executable = prefix / relativeExecutablePath
  if fileExists(extendedPath(executable)):
    result.add("blake3:" & blake3HexFile(executable) & "\n")
  else:
    result.add("blake3:missing\n")
  let entries = fileTreeListing(prefix)
  result.add("files:" & $entries.len & "\n")
  for entry in entries:
    let absolute = prefix / entry
    if fileExists(extendedPath(absolute)):
      let size = getFileSize(extendedPath(absolute))
      let digest = blake3HexFile(absolute)
      result.add(entry & "\t" & $size & "\t" & digest & "\n")
    else:
      result.add(entry & "\t0\tmissing\n")

proc executionProfileChecksum*(prefix: string;
                               relativeExecutablePath: string): string =
  ## Stable BLAKE3-256 over the deterministic execution-profile serialization
  ## from `executionProfilePayload`.
  blake3HexText(executionProfilePayload(prefix, relativeExecutablePath))

proc scoopReceiptPath(prefix: string): string =
  prefix / ".repro-receipt.json"

proc writeScoopReceipt(prefix: string; plan: ScoopAcquisitionPlan;
                       resolvedVersion, manifestChecksum,
                       executionProfileChecksum, scoopRoot, junctionTarget,
                       resolvedExecutablePath: string;
                       practicalHardening: PracticalHardening;
                       relativeExecutablePath: string;
                       manifestBinPaths: seq[string]) =
  ## M74: `relativeExecutablePath` is the manifest-resolved primary
  ## executable path relative to the version dir (the junction target);
  ## it is written as `declaredExecutablePath` so the launch-time
  ## `verifyScoopExecutionProfile` recomputes the execution profile
  ## against the SAME path the realize step used. `manifestBinPaths`
  ## records every manifest-declared `bin` entry for provenance.
  let binPathsJson = newJArray()
  for p in manifestBinPaths:
    binPathsJson.add(newJString(p))
  let receipt = %*{
    "adapter": "scoop",
    "adapterStrength": "weak",
    "practicalHardening": practicalHardeningName(practicalHardening),
    "packageSelector": plan.packageSelector,
    "packageId": plan.packageId,
    "bucket": plan.bucket,
    "app": plan.app,
    "pinnedVersion": plan.version,
    "preferredVersion": plan.preferredVersion,
    "resolvedVersion": resolvedVersion,
    "manifestChecksum": manifestChecksum,
    "declaredManifestChecksum": plan.manifestChecksum,
    "executionProfileChecksum": executionProfileChecksum,
    "requiresExecutionProfileChecksum":
      plan.requiresExecutionProfileChecksum,
    "scoopRoot": scoopRoot,
    "junctionTarget": junctionTarget,
    "declaredExecutablePath":
      (if relativeExecutablePath.len > 0: relativeExecutablePath
       else: plan.declaredExecutablePath),
    "packageDeclaredExecutablePath": plan.declaredExecutablePath,
    "manifestBin": binPathsJson,
    "resolvedExecutablePath": resolvedExecutablePath,
    "lockIdentity": plan.lockIdentity,
    "realizationBoundary": prefix
  }
  createDir(extendedPath(prefix))
  writeFile(extendedPath(scoopReceiptPath(prefix)), receipt.pretty())

proc safeScoopSegment(value, fallback: string): string =
  for ch in value:
    if ch in {'a' .. 'z'} or ch in {'A' .. 'Z'} or ch in {'0' .. '9'} or
        ch in {'-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = fallback

proc scoopAppsDir(scoopRoot, app: string): string =
  scoopRoot / "apps" / app

proc runScoopInstall(scoopExecutable, scoopRoot, bucket, app: string;
                     version: string) =
  var args: seq[string] = @[]
  let isPowerShell = scoopExecutable.endsWith(".ps1")
  let appRef = bucket & "/" & app &
    (if version.len > 0: "@" & version else: "")
  # `--no-update-scoop` skips Scoop's "is_scoop_outdated → scoop-update"
  # branch. We don't want unrelated upstream bucket updates running as
  # a side effect of acquisition; the package author already pinned
  # what we resolve against (the bucket head + manifestChecksum).
  let invocation: seq[string] =
    if isPowerShell:
      @["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
        scoopExecutable, "install", "--no-update-scoop", appRef]
    else:
      @[scoopExecutable, "install", "--no-update-scoop", appRef]
  let command = invocation.mapIt(quoteShell(it)).join(" ")
  putEnv("SCOOP", scoopRoot)
  let res = execCmdEx(command)
  if res.exitCode != 0:
    raise newException(EScoopInstallFailed,
      "EScoopInstallFailed: scoop install " & appRef &
      " (root=" & scoopRoot & ") exited " & $res.exitCode & "\n" & res.output)

proc determinePracticalHardening(plan: ScoopAcquisitionPlan;
                                 executionProfileCaptured: bool):
    PracticalHardening =
  let pinned = plan.version.len > 0
  if pinned:
    if executionProfileCaptured: phPinnedAndProfileVerified else: phPinned
  else:
    if executionProfileCaptured: phRangedAndProfileVerified else: phRanged

proc resolveScoopTool*(useDef: InterfaceToolUse; storeRoot: string;
                       scoopOverride = ""): PathOnlyToolProfile =
  let plan = scoopAcquisitionPlan(useDef)
  let scoopExe = resolveScoopExecutable(scoopOverride)
  if scoopExe.len == 0:
    raise newException(EScoopMissing,
      "EScoopMissing: scoop is not installed or not on PATH. " &
      "Install Scoop from https://scoop.sh/ before running --tool-provisioning=scoop.")

  let scoopRoot = resolveScoopRoot(scoopExe)
  if scoopRoot.len == 0:
    raise newException(EScoopMissing,
      "EScoopMissing: could not determine Scoop root (SCOOP env var unset and " &
      "no USERPROFILE/HOME available)")

  if not dirExists(extendedPath(scoopRoot / "buckets" / plan.bucket)):
    raise newException(EScoopBucketMissing,
      "EScoopBucketMissing: bucket directory not present at " &
      (scoopRoot / "buckets" / plan.bucket) &
      ". The test fixture or operator must run `scoop bucket add " &
      plan.bucket & " <url>` before --tool-provisioning=scoop.")

  let manifest = readScoopManifest(scoopRoot, plan.bucket, plan.app)
  let manifestVersion = normalizeScoopVersionTag(manifest.version)
  let manifestChecksum = manifest.checksum
  if plan.manifestChecksum.len > 0 and
      manifestChecksum != plan.manifestChecksum:
    raise newException(EScoopManifestChecksumMismatch,
      "EScoopManifestChecksumMismatch: bucket manifest " & manifest.path &
      " has blake3 " & manifestChecksum & " but the package declared " &
      plan.manifestChecksum)

  let appsDir = scoopAppsDir(scoopRoot, plan.app)

  # M77: the bucket-head equality check (pinned path) and the
  # `preferredVersion` range check (unpinned path) only matter when an
  # install FROM THE BUCKET is actually required. When the wanted
  # version is already installed under `appsDir`, `resolveScoopTool`
  # uses the on-disk version directory as a cache-hit and performs no
  # `scoop install`, so the current bucket head is irrelevant — a
  # `scoop update` that moved the bucket head past the installed
  # version must not fail a non-destructive home realization. The
  # checks are kept verbatim for the genuine install-required case (the
  # bucket cannot supply a version it does not currently publish).
  proc installedScoopVersions(): seq[string] =
    ## The exact-version directories present under `appsDir` (Scoop's
    ## per-app install tree). `current` is a junction, not a version.
    if not dirExists(extendedPath(appsDir)):
      return @[]
    # TODO(win-longpath): walk results escape; needs review
    for kind, path in walkDir(appsDir, relative = true):
      if kind in {pcDir, pcLinkToDir}:
        let leaf = path.extractFilename
        if leaf.len > 0 and leaf != "current":
          result.add(leaf)

  # M80: the installed-version cache-hit decision is the shared
  # `installedVersionSatisfies` predicate — the SAME predicate the
  # plan-time package classifier (`repro_home_apply/package_catalog.
  # resolvePackage`) consults, so a `repro home apply --plan` dry run
  # and the real `repro home apply` can never disagree on whether an
  # installed-but-bucket-drifted package is a cache-hit.
  let installedHit = installedVersionSatisfies(installedScoopVersions(),
    plan.version, plan.preferredVersion)
  let resolvedVersion =
    if plan.version.len > 0:
      let pinned = normalizeScoopVersionTag(plan.version)
      # Cache-hit: the pinned version's install tree is already on disk.
      # No install is performed, so the bucket head does not matter.
      if installedHit.satisfied:
        normalizeScoopVersionTag(installedHit.version)
      elif manifestVersion != pinned:
        # An install is required and the bucket cannot supply `pinned`.
        raise newException(EScoopVersionMismatch,
          "EScoopVersionMismatch: package pinned " & pinned &
          " but bucket head is " & manifestVersion &
          " (manifest=" & manifest.path & ")")
      else:
        pinned
    else:
      # Unpinned: when the bucket head satisfies the range, resolve to
      # it exactly as before (the M55 contract — a ranged plan follows
      # the bucket head, and if that version is already installed it is
      # reused below, otherwise it is installed). M77 relaxes ONLY the
      # failure case: when the bucket head does NOT satisfy the range,
      # an already-installed version that DOES satisfy it is resolved as
      # a cache-hit instead of raising — because no install from the
      # bucket is performed and the bucket head is then irrelevant.
      if versionSatisfiesRange(manifestVersion, plan.preferredVersion):
        manifestVersion
      elif installedHit.satisfied:
        installedHit.version
      else:
        # Nothing satisfying is installed and the bucket head cannot
        # supply the range — an install is required and unsatisfiable.
        raise newException(EScoopVersionMismatch,
          "EScoopVersionMismatch: bucket head " & manifestVersion &
          " does not satisfy preferredVersion " & plan.preferredVersion &
          " (manifest=" & manifest.path & ")")

  let versionDir = appsDir / resolvedVersion
  if not dirExists(extendedPath(versionDir)):
    runScoopInstall(scoopExe, scoopRoot, plan.bucket, plan.app,
      resolvedVersion)
    if not dirExists(extendedPath(versionDir)):
      raise newException(EScoopInstallFailed,
        "EScoopInstallFailed: post-install directory missing: " & versionDir)

  # Compute the canonical M56 prefix path. The realization hash is
  # derived from (bucket, app, resolvedVersion, manifestChecksum) so
  # the first 16 hex chars match the legacy `realizationKey[0 .. 15]`
  # value in spirit while now living in the standard
  # `prefixes/<package>/<version>-<hash>/` shape.
  let scoopPackageName = safeStoreSegment("scoop." & plan.bucket & "." &
    plan.app, "scoop-app")
  let unified = unifiedPrefixPath(storeRoot, scoopPackageName,
    resolvedVersion, "scoop", plan.lockIdentity,
    plan.declaredExecutablePath, "scoop://" & plan.bucket & "/" &
    plan.app & "@" & resolvedVersion, manifestChecksum,
    [plan.bucket, plan.app])
  let prefix = unified.absolutePath
  # The store prefix junctions the WHOLE Scoop app version directory at
  # `<prefix>/bin` (the junction target is the version ROOT, not an
  # assumed `bin/` subdir). The manifest-declared `bin` paths are then
  # resolved RELATIVE to this junction, so `<prefix>/bin/<bin-path>`
  # reaches the real executable wherever the app actually places it.
  let junctionTarget = prefix / "bin"

  if dirExists(extendedPath(prefix)):
    deleteJunctionDir(junctionTarget)
  else:
    createDir(extendedPath(prefix))
  createScoopJunction(junctionTarget, versionDir)

  # M74: resolve the executable(s) from the installed app's Scoop
  # manifest `bin` field rather than assuming a fixed on-disk layout.
  # Scoop copies the bucket manifest into `<versionDir>/manifest.json`
  # on install; we read that version-dir copy.
  let installedManifest = readInstalledManifestBin(versionDir)
  let manifestBinPaths = installedManifest.binPaths
  # `manifestHasBin` means the installed manifest authoritatively
  # declares one or more executables via its `bin` field. When true,
  # the manifest `bin` paths are the authoritative executable layout.
  let manifestHasBin = manifestBinPaths.len > 0
  # The package itself also declares an executable path — the
  # `executables:` `exportedExecutable(path = ...)` value carried in
  # `plan.declaredExecutablePath` (and, for a `home apply`, the
  # `#<exe>` of a Scoop binding). The normalized form:
  let packageDeclaredPath = normalizeScoopBinPath(plan.declaredExecutablePath)

  # Resolution policy:
  #   * manifest `bin` present  -> AUTHORITATIVE; pick the primary
  #     entry and presence-check EVERY declared entry strictly.
  #   * manifest `bin` absent   -> fall back to the package-declared
  #     path IF it resolves to a real file on disk under the junction
  #     (a library/`env_add_path` app such as `gnupg` ships its
  #     executables but declares no manifest `bin`; the package author
  #     still names the exported executable). If the package-declared
  #     path also does not resolve to a real file, the app genuinely
  #     exposes no executable — no executable, no launcher, NOT an
  #     error (M74 deliverable point 5).
  let relativeExecutablePath =
    if manifestHasBin:
      selectPrimaryScoopExecutable(manifestBinPaths,
        plan.declaredExecutablePath, plan.app)
    elif packageDeclaredPath.len > 0 and
        fileExists(extendedPath(junctionTarget / packageDeclaredPath)):
      packageDeclaredPath
    else:
      ""

  # M74: the post-install executable-presence check stays STRICT — it
  # is just now correct. When the manifest is authoritative, check
  # EVERY manifest-declared `bin` path at its real resolved location
  # under the junction. A genuinely absent declared executable still
  # raises the structured EScoopInstallFailed naming the expected path.
  if manifestHasBin:
    for binPath in manifestBinPaths:
      let resolved = junctionTarget / binPath
      if not fileExists(extendedPath(resolved)):
        raise newException(EScoopInstallFailed,
          "EScoopInstallFailed: executable not present after install: " &
          resolved & " (declared by " & installedManifest.manifestPath &
          " bin field)")
  # else: the manifest declares no `bin`. `relativeExecutablePath` was
  # only set above when the package-declared path already resolves to
  # a real file, so there is nothing further to presence-check; an
  # unresolvable package-declared path is a no-executable library, not
  # an error.

  let resolvedExecutable =
    if relativeExecutablePath.len > 0:
      junctionTarget / relativeExecutablePath
    else:
      ""

  var executionProfile = ""
  if plan.requiresExecutionProfileChecksum and relativeExecutablePath.len > 0:
    executionProfile = executionProfileChecksum(versionDir,
      relativeExecutablePath)

  let practicalHardening = determinePracticalHardening(plan,
    plan.requiresExecutionProfileChecksum)

  writeScoopReceipt(prefix, plan, resolvedVersion, manifestChecksum,
    executionProfile, scoopRoot, versionDir, resolvedExecutable,
    practicalHardening, relativeExecutablePath, manifestBinPaths)
  # Seal the unified M56 typed binary receipt and insert the SQLite
  # index row. The adapter-specific JSON receipt above remains for
  # tools that inspect Scoop provenance directly. M74: the exported
  # executable paths recorded in the index are the manifest-declared
  # `bin` paths (every declared executable) when the manifest is
  # authoritative; otherwise the package-declared path.
  let indexDeclaredExe =
    if relativeExecutablePath.len > 0: relativeExecutablePath
    else: plan.declaredExecutablePath
  let indexExportedExes =
    if manifestBinPaths.len > 0: manifestBinPaths
    elif relativeExecutablePath.len > 0: @[relativeExecutablePath]
    else: @[]
  discard registerInUnifiedStore(storeRoot, scoopPackageName,
    resolvedVersion, "scoop", plan.lockIdentity,
    indexDeclaredExe, "scoop://" & plan.bucket & "/" &
    plan.app & "@" & resolvedVersion, manifestChecksum, "junction",
    [plan.bucket, plan.app], prefix, indexExportedExes)

  let portability =
    if practicalHardening == phPinnedAndProfileVerified:
      cpPortable
    else:
      cpLocalOnly

  result = PathOnlyToolProfile(
    installMethod: "scoop",
    packageSelector: useDef.packageSelector,
    packageId: plan.packageId,
    # M74: the declared executable path is the manifest-resolved primary
    # `bin` path (relative to the version dir) when the installed
    # manifest is authoritative; the package-declared path otherwise;
    # "" for a manifest with no `bin` field.
    declaredExecutablePath:
      (if relativeExecutablePath.len > 0: relativeExecutablePath
       else: ""),
    realizedStorePaths: @[prefix],
    selectedStorePath: prefix,
    lockIdentity: plan.lockIdentity,
    realizationBoundary: prefix,
    executableName: useDef.executableName,
    pathSearchList: @[junctionTarget.parentDir / "bin"],
    resolvedExecutablePath: resolvedExecutable,
    adapterStrength: asWeak,
    cachePortability: portability,
    practicalHardening: practicalHardening,
    scoopBucket: plan.bucket,
    scoopApp: plan.app,
    scoopPinnedVersion: plan.version,
    scoopPreferredVersion: plan.preferredVersion,
    scoopResolvedVersion: resolvedVersion,
    scoopManifestChecksum: manifestChecksum,
    scoopDeclaredManifestChecksum: plan.manifestChecksum,
    scoopExecutionProfileChecksum: executionProfile,
    scoopRequiresExecutionProfile: plan.requiresExecutionProfileChecksum,
    scoopRoot: scoopRoot,
    scoopJunctionTarget: versionDir)
  result.pathSearchList = @[junctionTarget]

  # M75: GUI-application probe suppression.
  #
  # A realized Scoop app is treated as a GUI / non-exec-probeable app
  # when EITHER its installed manifest declares a `shortcuts` field OR
  # its primary executable's PE subsystem is the GUI subsystem. For such
  # an app the post-realize verification checks executable PRESENCE ON
  # DISK only and does NOT execute the binary — exec-probing a GUI app
  # (`chrome.exe --version`, etc.) launches the full application, which
  # never exits and hangs `repro home apply` indefinitely.
  let isGuiApp =
    scoopAppIsGuiApplication(installedManifest.hasShortcuts,
                             resolvedExecutable)
  # M74: a manifest with no `bin` field exposes no executable, so there
  # is nothing to probe — `configuredProbes` is consulted only when an
  # executable was resolved.
  if resolvedExecutable.len > 0:
    if isGuiApp:
      # GUI app: presence-on-disk verification ONLY — never execute the
      # binary. The strict presence walk above already failed closed on
      # a genuinely absent manifest-declared executable; for a no-`bin`
      # app whose package-declared path was used, re-confirm presence
      # here so a GUI app still receives a real presence check.
      if not fileExists(extendedPath(resolvedExecutable)):
        raise newException(EScoopInstallFailed,
          "EScoopInstallFailed: GUI app executable not present after " &
          "install: " & resolvedExecutable & " (scoop " & plan.bucket &
          "/" & plan.app & ")")
    else:
      # Console app: keep exec-probing — but every probe is now bounded
      # by the M75 wall-clock timeout + process-tree kill, so even a
      # misclassified or misbehaving console binary cannot hang the
      # apply.
      for probe in configuredProbes(useDef.packageSelector,
          useDef.executableName):
        let probeResult = runProbe(resolvedExecutable, probe)
        if probeResult.timedOut:
          # A console tool that timed out is a STRUCTURED diagnostic —
          # the apply did not hang. The adapter's verification contract
          # still treats a non-passing probe as an install failure, but
          # via a clean error rather than an infinite block.
          raise newException(EScoopInstallFailed,
            "EScoopInstallFailed: probe " & probe.name & " for " &
            useDef.executableName & " (scoop " & plan.bucket & "/" &
            plan.app & ") timed out after " & $probeTimeoutSeconds &
            "s and its process tree was killed\n" & probeResult.output)
        if probeResult.exitCode != 0:
          raise newException(EScoopInstallFailed,
            "EScoopInstallFailed: probe " & probe.name & " for " &
            useDef.executableName & " (scoop " & plan.bucket & "/" &
            plan.app & ") exited " & $probeResult.exitCode & "\n" &
            probeResult.output)
        result.probes.add(probeResult)

  result.profileFingerprint = profileFingerprintFor(result)

proc verifyScoopExecutionProfile*(prefix: string) =
  ## Reads the receipt at `prefix` and recomputes the execution profile
  ## checksum against the live junction target. Raises
  ## `EScoopProfileChecksumMismatch` if the recorded checksum differs.
  let receiptPath = scoopReceiptPath(prefix)
  if not fileExists(extendedPath(receiptPath)):
    raise newException(EScoopProfileChecksumMismatch,
      "EScoopProfileChecksumMismatch: receipt not present at " & receiptPath)
  let receipt = parseFile(receiptPath)
  let requires = receipt{"requiresExecutionProfileChecksum"}.getBool(false)
  if not requires:
    return
  let recorded = receipt{"executionProfileChecksum"}.getStr("")
  let junctionTarget = receipt{"junctionTarget"}.getStr("")
  let declared = receipt{"declaredExecutablePath"}.getStr("")
  if declared.len == 0:
    # M74: a manifest with no `bin` field — a library / env_add_path-only
    # app. There is no executable to profile-verify, and no launcher
    # exists for it, so this is not an error.
    return
  if recorded.len == 0:
    raise newException(EScoopProfileChecksumMismatch,
      "EScoopProfileChecksumMismatch: receipt at " & receiptPath &
      " lacks executionProfileChecksum")
  let live = executionProfileChecksum(junctionTarget, declared)
  if live != recorded:
    raise newException(EScoopProfileChecksumMismatch,
      "EScoopProfileChecksumMismatch: prefix " & prefix &
      " recorded " & recorded & " but live profile is " & live)

proc launchScoopExecutable*(prefix: string; args: openArray[string]):
    tuple[exitCode: int; output: string] =
  ## Verifies the execution-profile checksum recorded in the prefix's
  ## receipt, then runs the resolved executable with the supplied args.
  verifyScoopExecutionProfile(prefix)
  let receipt = parseFile(scoopReceiptPath(prefix))
  let resolved = receipt{"resolvedExecutablePath"}.getStr("")
  if resolved.len == 0 or not fileExists(extendedPath(resolved)):
    raise newException(EScoopInstallFailed,
      "EScoopInstallFailed: resolved executable missing for " & prefix)
  let cmd = (@[resolved] & @args).mapIt(quoteShell(it)).join(" ")
  let res = execCmdEx(cmd)
  (exitCode: res.exitCode, output: res.output)

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
      entry("output", cborText(probe.output)),
      entry("timedOut", cborBool(probe.timedOut))
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
    entry("practicalHardening", cborText(practicalHardeningName(
        identity.practicalHardening))),
    entry("scoopBucket", cborText(identity.scoopBucket)),
    entry("scoopApp", cborText(identity.scoopApp)),
    entry("scoopPinnedVersion", cborText(identity.scoopPinnedVersion)),
    entry("scoopPreferredVersion", cborText(identity.scoopPreferredVersion)),
    entry("scoopResolvedVersion", cborText(identity.scoopResolvedVersion)),
    entry("scoopManifestChecksum", cborText(identity.scoopManifestChecksum)),
    entry("scoopExecutionProfileChecksum",
      cborText(identity.scoopExecutionProfileChecksum)),
    entry("scoopRoot", cborText(identity.scoopRoot)),
    entry("scoopJunctionTarget", cborText(identity.scoopJunctionTarget)),
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
    resolveNixTool(useDef, storeRoot)
  of tpmTarball:
    resolveTarballTool(useDef, storeRoot)
  of tpmScoop:
    resolveScoopTool(useDef, storeRoot)
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
    cachePortability: profile.cachePortability,
    practicalHardening: profile.practicalHardening,
    scoopBucket: profile.scoopBucket,
    scoopApp: profile.scoopApp,
    scoopPinnedVersion: profile.scoopPinnedVersion,
    scoopPreferredVersion: profile.scoopPreferredVersion,
    scoopResolvedVersion: profile.scoopResolvedVersion,
    scoopManifestChecksum: profile.scoopManifestChecksum,
    scoopExecutionProfileChecksum: profile.scoopExecutionProfileChecksum,
    scoopRoot: profile.scoopRoot,
    scoopJunctionTarget: profile.scoopJunctionTarget)
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

proc nixBuildIdentity*(artifact: ProjectInterfaceArtifact;
                       storeRoot = ""): PathOnlyBuildIdentity =
  toolBuildIdentity(artifact, tpmNix, storeRoot = storeRoot)

proc tarballBuildIdentity*(artifact: ProjectInterfaceArtifact; storeRoot = ""):
    PathOnlyBuildIdentity =
  toolBuildIdentity(artifact, tpmTarball, storeRoot = storeRoot)

proc scoopBuildIdentity*(artifact: ProjectInterfaceArtifact; storeRoot = ""):
    PathOnlyBuildIdentity =
  toolBuildIdentity(artifact, tpmScoop, storeRoot = storeRoot)

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
  # M75: a timed-out probe carries the negative-clamped sentinel
  # `probeTimeoutExitCode`; serialize the raw int so it round-trips.
  outp.writeU32Le(uint32(max(probe.exitCode, 0)))
  outp.writeString(probe.output)
  outp.writeByte(if probe.timedOut: 1'u8 else: 0'u8)

proc readProbeResult(bytes: openArray[byte]; pos: var int): ToolProbeResult =
  result.spec = readProbeSpec(bytes, pos)
  result.exitCode = int(readU32Le(bytes, pos))
  result.output = readString(bytes, pos)
  result.timedOut = readByte(bytes, pos) != 0'u8

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
  outp.writeByte(byte(ord(profile.practicalHardening)))
  outp.writeString(profile.scoopBucket)
  outp.writeString(profile.scoopApp)
  outp.writeString(profile.scoopPinnedVersion)
  outp.writeString(profile.scoopPreferredVersion)
  outp.writeString(profile.scoopResolvedVersion)
  outp.writeString(profile.scoopManifestChecksum)
  outp.writeString(profile.scoopDeclaredManifestChecksum)
  outp.writeString(profile.scoopExecutionProfileChecksum)
  outp.writeByte(byte(ord(profile.scoopRequiresExecutionProfile)))
  outp.writeString(profile.scoopRoot)
  outp.writeString(profile.scoopJunctionTarget)
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
  if version >= 6'u16:
    let hardening = readByte(bytes, pos)
    if hardening > byte(ord(phRangedAndProfileVerified)):
      raiseEnvelopeError(eeMalformed, "invalid practical hardening tier")
    result.practicalHardening = PracticalHardening(hardening)
    result.scoopBucket = readString(bytes, pos)
    result.scoopApp = readString(bytes, pos)
    result.scoopPinnedVersion = readString(bytes, pos)
    result.scoopPreferredVersion = readString(bytes, pos)
    result.scoopResolvedVersion = readString(bytes, pos)
    result.scoopManifestChecksum = readString(bytes, pos)
    result.scoopDeclaredManifestChecksum = readString(bytes, pos)
    result.scoopExecutionProfileChecksum = readString(bytes, pos)
    result.scoopRequiresExecutionProfile = readByte(bytes, pos) != 0
    result.scoopRoot = readString(bytes, pos)
    result.scoopJunctionTarget = readString(bytes, pos)
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
  outp.writeByte(byte(ord(identity.practicalHardening)))
  outp.writeString(identity.scoopBucket)
  outp.writeString(identity.scoopApp)
  outp.writeString(identity.scoopPinnedVersion)
  outp.writeString(identity.scoopPreferredVersion)
  outp.writeString(identity.scoopResolvedVersion)
  outp.writeString(identity.scoopManifestChecksum)
  outp.writeString(identity.scoopExecutionProfileChecksum)
  outp.writeString(identity.scoopRoot)
  outp.writeString(identity.scoopJunctionTarget)

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
  if version >= 6'u16:
    let hardening = readByte(bytes, pos)
    if hardening > byte(ord(phRangedAndProfileVerified)):
      raiseEnvelopeError(eeMalformed, "invalid practical hardening tier")
    result.practicalHardening = PracticalHardening(hardening)
    result.scoopBucket = readString(bytes, pos)
    result.scoopApp = readString(bytes, pos)
    result.scoopPinnedVersion = readString(bytes, pos)
    result.scoopPreferredVersion = readString(bytes, pos)
    result.scoopResolvedVersion = readString(bytes, pos)
    result.scoopManifestChecksum = readString(bytes, pos)
    result.scoopExecutionProfileChecksum = readString(bytes, pos)
    result.scoopRoot = readString(bytes, pos)
    result.scoopJunctionTarget = readString(bytes, pos)

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
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), toByteString(encodePathOnlyBuildIdentity(identity)))

proc readPathOnlyBuildIdentity*(path: string): PathOnlyBuildIdentity =
  decodePathOnlyBuildIdentity(fromByteString(readFile(extendedPath(path))))

proc jsonProbe(probe: ToolProbeResult): JsonNode =
  %*{
    "kind": $probe.spec.kind,
    "name": probe.spec.name,
    "args": probe.spec.args,
    "exitCode": probe.exitCode,
    "output": probe.output,
    "timedOut": probe.timedOut
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
    "practicalHardening": practicalHardeningName(profile.practicalHardening),
    "scoopBucket": profile.scoopBucket,
    "scoopApp": profile.scoopApp,
    "scoopPinnedVersion": profile.scoopPinnedVersion,
    "scoopPreferredVersion": profile.scoopPreferredVersion,
    "scoopResolvedVersion": profile.scoopResolvedVersion,
    "scoopManifestChecksum": profile.scoopManifestChecksum,
    "scoopDeclaredManifestChecksum": profile.scoopDeclaredManifestChecksum,
    "scoopExecutionProfileChecksum": profile.scoopExecutionProfileChecksum,
    "scoopRequiresExecutionProfile": profile.scoopRequiresExecutionProfile,
    "scoopRoot": profile.scoopRoot,
    "scoopJunctionTarget": profile.scoopJunctionTarget,
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
    "practicalHardening": practicalHardeningName(identity.practicalHardening),
    "scoopBucket": identity.scoopBucket,
    "scoopApp": identity.scoopApp,
    "scoopPinnedVersion": identity.scoopPinnedVersion,
    "scoopPreferredVersion": identity.scoopPreferredVersion,
    "scoopResolvedVersion": identity.scoopResolvedVersion,
    "scoopManifestChecksum": identity.scoopManifestChecksum,
    "scoopExecutionProfileChecksum": identity.scoopExecutionProfileChecksum,
    "scoopRoot": identity.scoopRoot,
    "scoopJunctionTarget": identity.scoopJunctionTarget,
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
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), inspectionJson(identity))

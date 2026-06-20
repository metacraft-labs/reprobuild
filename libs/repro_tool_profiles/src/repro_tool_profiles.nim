import std/[algorithm, json, os, osproc, sequtils, sets, strutils, tables, times]

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
    tpmFromSource
      ## M9.Q: from-source provisioning. The resolver looks for a sibling
      ## recipe at ``recipes/packages/source/<name>/repro.nim``, then
      ## checks whether its build artifact at
      ## ``recipes/packages/source/<name>/.repro/output/<name>/<name>``
      ## (or ``<name>.exe`` on Windows) exists and is executable. If so,
      ## the tool's bin dir threads into ``pathSearchList``. If the
      ## recipe is missing or unbuilt, the resolver fails closed with a
      ## structured diagnostic naming the recipe path and the build
      ## command an operator would invoke. v1 does NOT auto-recurse;
      ## auto-build is M9.Q.1 follow-up. The principle of from-source
      ## provisioning as a real mode is what matters in v1.

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
    # M9.R.14e.1 — additional search-path channels populated by the
    # from-source resolver when the sibling recipe's install tree carries
    # the relevant artefacts. The engine threads each list onto a
    # dedicated env var at action fork time:
    #
    #   * ``pkgConfigSearchList``  → ``PKG_CONFIG_PATH``
    #     points at ``lib/pkgconfig`` + ``share/pkgconfig`` dirs in the
    #     staged install tree, so a recipe depending on ``wayland`` finds
    #     ``wayland-client.pc`` without having to set the env var by hand.
    #   * ``cmakePrefixList``      → ``CMAKE_PREFIX_PATH``
    #     points at the install-prefix root (e.g. ``build/out/usr``) so
    #     cmake-based recipes use ``find_package`` against from-source
    #     siblings.
    #   * ``cpathList``            → ``CPATH``
    #     points at ``include/`` dirs so the compiler picks up headers
    #     a recipe staged from source.
    #   * ``libraryPathList``      → ``LIBRARY_PATH`` and
    #                                ``LD_LIBRARY_PATH``
    #     points at ``lib/`` dirs so the linker resolves ``-lwayland-client``
    #     at link time AND the test executor at run time.
    #
    # Each list is empty for non-from-source profiles (path/nix/tarball/
    # scoop) — those adapters already deliver a single store path whose
    # standard FHS layout works through their existing PATH plumbing.
    # The from-source profile populates them per-recipe so a Wayland
    # consumer (libxkbcommon, wlroots, sway, ...) finds the right
    # ``wayland-client.pc`` without any per-recipe scripting.
    pkgConfigSearchList*: seq[string]
    cmakePrefixList*: seq[string]
    cpathList*: seq[string]
    libraryPathList*: seq[string]
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
    # M9.R.14e.1 — mirror of ``PathOnlyToolProfile``'s extra search-path
    # channels. The provider-compile pass copies these fields out of the
    # resolved profile and into the per-action identity so the CLI's
    # ``mkToolIdentityResolver`` projection can hand them to the engine
    # at action-launch time.
    pkgConfigSearchList*: seq[string]
    cmakePrefixList*: seq[string]
    cpathList*: seq[string]
    libraryPathList*: seq[string]
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
  # v7 — M9.R.14e.1 added the from-source search-path channels
  # (``pkgConfigSearchList`` / ``cmakePrefixList`` / ``cpathList`` /
  # ``libraryPathList``) to ``PathOnlyToolProfile`` + ``ToolActionIdentity``
  # so the engine can thread them onto per-action env vars at fork time.
  ArtifactVersion = 7'u16
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
  # v6 — M9.R.14e.1 folded the four extra search-path channels into the
  # profile fingerprint so two from-source recipes that stage different
  # ``pkgconfig`` / ``include`` / ``lib`` dirs hash to distinct cache
  # keys. The old domain tag was ``v5``; bumping mechanically invalidates
  # already-cached profiles from before the search-path extension so the
  # engine refuses to re-use a profile that lacks the new channels.
  payload.writeString("reprobuild.toolProfile.v6")
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
  payload.writeStringSeq(profile.pkgConfigSearchList)
  payload.writeStringSeq(profile.cmakePrefixList)
  payload.writeStringSeq(profile.cpathList)
  payload.writeStringSeq(profile.libraryPathList)
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
  # See ``profileFingerprintFor`` — v5 → v6 bump for the M9.R.14e.1
  # search-path channels. Two from-source siblings with different staged
  # install trees produce two distinct action fingerprints so the
  # engine never reuses a stale identity across staged-tree variations.
  payload.writeString("reprobuild.toolAction.v6")
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
  payload.writeStringSeq(identity.pkgConfigSearchList)
  payload.writeStringSeq(identity.cmakePrefixList)
  payload.writeStringSeq(identity.cpathList)
  payload.writeStringSeq(identity.libraryPathList)
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
  if not fileExists(extendedPath(candidate)):
    return ""
  # M9.R.14d.8b — data-file declarations (e.g. wayland-protocols's
  # ``share/pkgconfig/wayland-protocols.pc``) point at non-executable
  # files that exist only to verify the realization completed. Detect
  # these by extension and accept them without the +x permission
  # requirement; the consumer threads the parent prefix into
  # PKG_CONFIG_PATH at build time rather than spawning the file
  # directly.
  let dataExts = [".pc", ".so", ".a", ".h", ".hpp", ".cmake", ".json",
    ".xml", ".txt"]
  let lower = declaredExecutablePath.toLowerAscii
  var isDataDecl = false
  for ext in dataExts:
    if lower.endsWith(ext) or lower.contains(ext & "."):
      isDataDecl = true
      break
  if isDataDecl:
    return absolutePath(candidate)
  if {fpUserExec, fpGroupExec, fpOthersExec}.anyIt(
      it in getFilePermissions(extendedPath(candidate))):
    return absolutePath(candidate)
  return ""

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
                            exportedExecutables: openArray[string] = [];
                            writerMode = "direct"):
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
    writerMode: writerMode)
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

proc addUniquePath*(dst: var seq[string]; value: string)
  ## Forward declaration — defined alongside the from-source populator
  ## further down. Resolved here so ``resolveNixTool`` can reuse the
  ## same dedup/exists-probe helper for nix-store aux-path population.

proc resolveNixTool*(useDef: InterfaceToolUse;
                     storeRoot = "";
                     writerMode = "direct"): PathOnlyToolProfile =
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

  # M9.R.14e.7 + M9.R.14f.10 — populate the same four auxiliary
  # search-path channels the from-source resolver populates, but
  # anchored at the nix store output. Many nix packages (e.g.
  # wayland-protocols, libxml2-dev) ship ``.pc`` files at
  # ``<store>/share/pkgconfig/`` and headers at ``<store>/include/``;
  # the engine threads these onto ``PKG_CONFIG_PATH`` /
  # ``CMAKE_PREFIX_PATH`` / ``CPATH`` / ``LIBRARY_PATH`` at fork time
  # so a meson/cmake recipe consuming the dep finds its pc files /
  # headers without having to declare a special-case ``env:`` block.
  #
  # M9.R.14f.10: multi-output nix packages ship the .pc / headers /
  # libraries in DIFFERENT outputs. systemd's libudev.pc lives in the
  # ``dev`` output, not ``out``. Walk every realized store path so
  # consumers find them.
  for storePath in realized:
    addUniquePath(result.cmakePrefixList, storePath)
    addUniquePath(result.pkgConfigSearchList,
      storePath / "lib" / "pkgconfig")
    addUniquePath(result.pkgConfigSearchList,
      storePath / "lib64" / "pkgconfig")
    addUniquePath(result.pkgConfigSearchList,
      storePath / "share" / "pkgconfig")
    addUniquePath(result.cpathList, storePath / "include")
    addUniquePath(result.libraryPathList, storePath / "lib")
    addUniquePath(result.libraryPathList, storePath / "lib64")

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
      unified.absolutePath, [plan.declaredExecutablePath],
      writerMode = writerMode)
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

proc hostCpuToken(): string =
  ## Host CPU as the lowercase string DSL ``tarball cpu = "..."``
  ## entries match against. Mirrors the M63 ``PlatformCpu`` taxonomy
  ## (``x86_64`` and ``aarch64``) — anything else falls back to the
  ## raw `hostCPU` name.
  case hostCPU
  of "amd64", "x86_64": "x86_64"
  of "arm64", "aarch64": "aarch64"
  else: hostCPU

proc hostOsToken(): string =
  ## Host OS as the lowercase string DSL ``tarball os = "..."`` entries
  ## match against. Mirrors the M63 ``PlatformOs`` taxonomy
  ## (``windows`` / ``linux`` / ``macos``). The DSL accepts both
  ## ``macos`` and ``darwin`` for the Apple OS; we report ``macos``.
  when defined(windows): "windows"
  elif defined(macosx): "macos"
  elif defined(linux): "linux"
  else: hostOS.toLowerAscii()

proc matchesHostPlatform(provisioning: InterfaceTarballProvisioning): bool =
  ## Empty cpu / os fields mean "any host", matching everything. A
  ## non-empty value must match the host. ``darwin`` and ``macos`` are
  ## aliases (the DSL parser accepts both spellings).
  let cpuOk = provisioning.cpu.len == 0 or
    provisioning.cpu.toLowerAscii() == "any" or
    provisioning.cpu.toLowerAscii() == hostCpuToken()
  let osNorm = provisioning.os.toLowerAscii()
  let hostOsNorm = hostOsToken()
  let osOk = osNorm.len == 0 or osNorm == "any" or
    osNorm == hostOsNorm or
    (hostOsNorm == "macos" and osNorm == "darwin") or
    (hostOsNorm == "darwin" and osNorm == "macos")
  cpuOk and osOk

proc hasHostTarballProvisioning(useDef: InterfaceToolUse): bool =
  for provisioning in useDef.tarballProvisioning:
    if matchesHostPlatform(provisioning):
      return true
  false

proc selectTarballProvisioning(useDef: InterfaceToolUse):
    InterfaceTarballProvisioning =
  ## Pick the first ``tarballProvisioning`` entry that matches the host
  ## platform. ``cpu = ""`` / ``os = ""`` entries match every host and
  ## act as a catch-all when no per-platform slice is supplied. Entries
  ## are walked in declaration order so author intent is preserved
  ## (early entries beat later catch-alls).
  for provisioning in useDef.tarballProvisioning:
    if matchesHostPlatform(provisioning):
      return provisioning
  raise newException(ValueError,
    "tool-resolution failed: no tarball provisioning entry for package \"" &
    useDef.packageSelector & "\" matches host cpu=" & hostCpuToken() &
    " os=" & hostOsToken() & " (" & $useDef.tarballProvisioning.len &
    " entries; see the package's `provisioning:` block)")

proc tarballAcquisitionPlan*(useDef: InterfaceToolUse): TarballAcquisitionPlan =
  if useDef.tarballProvisioning.len == 0:
    raise newException(ValueError,
      "tool-resolution failed: package \"" & useDef.packageSelector &
      "\" requested by uses \"" & useDef.rawConstraint &
      "\" does not declare provisioning: tarball metadata")
  let selected = selectTarballProvisioning(useDef)
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
  ## Sanity-check that the archive's entry names do not escape the
  ## extraction directory via absolute paths or `..` traversal. Only
  ## tar-family archives carry a cheap-to-list table; for zip / 7z /
  ## raw payloads the extraction tools themselves refuse unsafe
  ## entries (Expand-Archive, 7z, unzip all reject parent-relative
  ## paths in their default modes), so we skip the pre-listing pass.
  let lowerType = archiveType.toLowerAscii()
  let args =
    case lowerType
    of "tar.gz", "tgz":
      @["tar", "-tzf", archivePath]
    of "tar.xz", "txz":
      @["tar", "-tJf", archivePath]
    of "tar.bz2", "tbz", "tbz2":
      @["tar", "-tjf", archivePath]
    of "tar":
      @["tar", "-tf", archivePath]
    of "zip", "7z", "7z.exe", "raw":
      return
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

proc resolveZipExtractor(): tuple[exe: string; kind: string] =
  ## Choose a zip extractor. PowerShell's `Expand-Archive` is the
  ## native Windows path and round-trips both `\\`- and `/`-separated
  ## archives. `unzip` is the POSIX baseline. Returns a (path, kind)
  ## pair; `kind` discriminates the command line shape because they
  ## are NOT interchangeable.
  when defined(windows):
    let ps = findExe("powershell")
    if ps.len > 0:
      return (exe: ps, kind: "powershell")
  let unzipExe = findExe("unzip")
  if unzipExe.len > 0:
    return (exe: unzipExe, kind: "unzip")
  when not defined(windows):
    let ps = findExe("powershell")
    if ps.len > 0:
      return (exe: ps, kind: "powershell")
  raise newException(OSError,
    "tool-resolution failed: no zip extractor available (looked for " &
    (when defined(windows): "powershell + unzip" else: "unzip + powershell") &
    ")")

proc resolveSevenZipExe(): string =
  ## Look up a `7z` / `7z.exe` on PATH. Used for `.7z` archives and
  ## `.7z.exe` (SFX) payloads. Both Scoop's `main/7zip` and the
  ## system 7-Zip install satisfy this; on POSIX, `p7zip`'s `7z`
  ## binary speaks the same CLI.
  for name in @["7z", "7z.exe", "7zz"]:
    let exe = findExe(name)
    if exe.len > 0:
      return exe
  raise newException(OSError,
    "tool-resolution failed: no 7z extractor available (looked for 7z, 7z.exe, 7zz on PATH)")

proc removeSingleTopLevelDir(destination: string) =
  ## When a zip / 7z archive ships its payload under a single top-
  ## level directory (the convention for nuwen.net's mingw, nim-
  ## lang.org's nim-X.Y.Z_x64.zip, capnproto's tools zip, etc.),
  ## flatten one level so the prefix root matches the layout the
  ## DSL's `executablePath` references. The `stripComponents = 1`
  ## tarball idiom maps onto this for non-tar archives.
  var children: seq[string] = @[]
  for kind, entry in walkDir(extendedPath(destination)):
    children.add(entry)
    if children.len > 1:
      break
  if children.len != 1:
    return
  let solo = children[0]
  if not dirExists(extendedPath(solo)):
    return
  for kind, entry in walkDir(extendedPath(solo)):
    let leaf = lastPathPart(entry)
    let target = destination / leaf
    moveFile(extendedPath(entry), extendedPath(target))
  removeDir(extendedPath(solo))

proc flattenStripComponents(destination: string; stripComponents: int) =
  ## Approximates tar's ``--strip-components=N`` for archive formats
  ## (zip, 7z) that have no native flag. v1 implements N=1, which
  ## covers every Windows tool archive in the M68 catalog (each ships
  ## its payload under a single top-level directory). N >= 2 raises
  ## so a caller's misuse is caught at realize time rather than
  ## silently producing the wrong prefix.
  if stripComponents <= 0:
    return
  if stripComponents == 1:
    removeSingleTopLevelDir(destination)
    return
  raise newException(ValueError,
    "tool-resolution failed: stripComponents=" & $stripComponents &
    " is not supported for non-tar archives; use stripComponents=1 or " &
    "rely on a tarball archiveType")

proc removeEmptyDirTree(dir: string) =
  ## Bottom-up: recurse into every child dir first, then if THIS dir
  ## has no remaining entries, remove it. Used by the rust-installer
  ## merge to clean up component dirs after their files have been
  ## moved to the merged prefix root. Tolerates stray files the
  ## upstream manifest didn't enumerate (the official installer logs
  ## but tolerates the same — see ``rust-installer/install.sh``).
  if not dirExists(extendedPath(dir)):
    return
  var childDirs: seq[string] = @[]
  for kind, entry in walkDir(extendedPath(dir)):
    if dirExists(extendedPath(entry)):
      childDirs.add(entry)
  for child in childDirs:
    removeEmptyDirTree(child)
  var hasEntries = false
  for kind, entry in walkDir(extendedPath(dir)):
    hasEntries = true
    break
  if not hasEntries:
    try:
      removeDir(extendedPath(dir))
    except OSError:
      discard

proc mergeRustInstallerComponents(destination: string) =
  ## Replays the upstream Rust standalone-distribution ``install.sh``
  ## merge step.
  ##
  ## The ``rust-<ver>-<triple>.tar.xz`` archive (and its sibling
  ## per-component archives) ships its payload as several sibling
  ## component directories under one root: ``cargo/``, ``rustc/``,
  ## ``rust-std-<triple>/``, ``clippy-preview/``,
  ## ``rustfmt-preview/``, ``rust-docs/``, ... Each component has its
  ## own ``bin/`` / ``lib/`` / ``share/`` subtree and a ``manifest.in``
  ## listing the files it owns. The official ``install.sh`` (a.k.a.
  ## ``rust-installer``) MERGES these components into a single flat
  ## prefix at install time so that ``<prefix>/bin/rustc.exe`` finds
  ## libstd at ``<prefix>/lib/rustlib/<triple>/lib/`` — exactly where
  ## rustc looks via ``<exe>/../lib/rustlib/...``. Without the merge
  ## ``cargo test --no-run`` fails with ``error[E0463]: can't find
  ## crate for `std`'' because the unmerged ``rustc/lib/rustlib/`` tree
  ## is empty (libstd lives under the sibling ``rust-std-<triple>/``).
  ##
  ## Detection is layout-driven (no schema flag needed): the merge
  ## runs IFF the extracted root carries the canonical
  ## ``rust-installer-version`` sentinel AND a ``components`` file
  ## (the manifest of component dirs upstream's installer reads). For
  ## any other archive shape the proc is a silent no-op.
  ##
  ## The merge itself walks each component's ``manifest.in``: ``dir:``
  ## entries create the destination dir, ``file:`` entries move the
  ## file from ``<root>/<component>/<rel>`` to ``<root>/<rel>``. Empty
  ## component dirs are removed afterwards. The component-internal
  ## ``manifest.in`` files are deleted as part of the merge (they
  ## belong to the component, not the merged prefix).
  let versionMarker = destination / "rust-installer-version"
  let componentsFile = destination / "components"
  if not fileExists(extendedPath(versionMarker)):
    return
  if not fileExists(extendedPath(componentsFile)):
    return

  let componentsRaw = readFile(extendedPath(componentsFile))
  for componentRaw in componentsRaw.splitLines:
    let component = componentRaw.strip()
    if component.len == 0:
      continue
    # Defence-in-depth: refuse path-traversal in the components file.
    let normalizedComponent = component.replace('\\', '/')
    if normalizedComponent.contains("/") or normalizedComponent == ".." or
        normalizedComponent == ".":
      raise newException(OSError,
        "tool-resolution failed: rust-installer components file lists " &
        "invalid component name: " & component)
    let componentDir = destination / component
    if not dirExists(extendedPath(componentDir)):
      continue
    let manifestPath = componentDir / "manifest.in"
    if not fileExists(extendedPath(manifestPath)):
      continue
    let manifestRaw = readFile(extendedPath(manifestPath))
    for entryRaw in manifestRaw.splitLines:
      let entry = entryRaw.strip()
      if entry.len == 0:
        continue
      var kind, relRaw: string
      let colonIdx = entry.find(':')
      if colonIdx <= 0:
        continue
      kind = entry[0 ..< colonIdx]
      relRaw = entry[colonIdx + 1 .. ^1]
      let rel = relRaw.replace('\\', '/').strip()
      if rel.len == 0:
        continue
      # Reject path-traversal: same rules as validateTarEntries.
      if rel.startsWith("/") or rel == ".." or rel.startsWith("../") or
          rel.contains("/../") or rel.endsWith("/.."):
        raise newException(OSError,
          "tool-resolution failed: rust-installer manifest entry " &
          "escapes the prefix: " & entry & " (component " & component & ")")
      case kind
      of "dir":
        createDir(extendedPath(destination / rel))
      of "file":
        let source = componentDir / rel
        let target = destination / rel
        if not fileExists(extendedPath(source)):
          # Source missing — either already merged by an earlier
          # invocation, or the manifest disagrees with the archive
          # contents. Skip silently; the post-extract executable-
          # presence check downstream catches the catastrophic case
          # (the declared executablePath not landing in the prefix).
          continue
        if fileExists(extendedPath(target)):
          # Earlier component already produced this file. Rust's
          # components do not overlap on real entries — the only
          # collisions are top-level metadata files (LICENSE-*,
          # README.md, version, ...) which the installer dedupes by
          # keeping the first writer. Skip the duplicate to match
          # that behaviour.
          removeFile(extendedPath(source))
          continue
        createDir(extendedPath(parentDir(target)))
        moveFile(extendedPath(source), extendedPath(target))
      else:
        # ``link:`` / unknown kinds: Rust's installer treats these as
        # post-install hooks the extracted prefix doesn't need (the
        # rust-installer source's only other kind is ``dir`` and
        # ``file`` on the platforms we ship). Ignore.
        discard
    # Delete the component's own manifest + any now-empty subtree.
    try:
      removeFile(extendedPath(manifestPath))
    except OSError:
      discard
    # Remove empty leftover directories under the component dir.
    # walkDir + bottom-up rmdir keeps this resilient to stray files
    # the manifest didn't enumerate (rare; the upstream installer
    # logs but tolerates the same).
    removeEmptyDirTree(componentDir)

  # The merged prefix no longer needs the installer metadata files.
  # Keep them (they document provenance) but strip the now-redundant
  # ``install.sh`` to discourage operators from invoking a second
  # merge inside our already-merged layout.
  let installSh = destination / "install.sh"
  if fileExists(extendedPath(installSh)):
    try: removeFile(extendedPath(installSh))
    except OSError: discard

proc extractTarballArchive(archivePath, destination, archiveType: string;
                           stripComponents: int;
                           declaredExecutablePath = "") =
  validateTarEntries(archivePath, archiveType)
  createDir(extendedPath(destination))
  let lowerType = archiveType.toLowerAscii()
  case lowerType
  of "tar.gz", "tgz", "tar.xz", "txz", "tar.bz2", "tbz", "tbz2", "tar":
    var args =
      case lowerType
      of "tar.gz", "tgz":
        @["tar", "-xzf", archivePath, "-C", destination]
      of "tar.xz", "txz":
        @["tar", "-xJf", archivePath, "-C", destination]
      of "tar.bz2", "tbz", "tbz2":
        @["tar", "-xjf", archivePath, "-C", destination]
      else: # "tar"
        @["tar", "-xf", archivePath, "-C", destination]
    if stripComponents > 0:
      args.add("--strip-components=" & $stripComponents)
    let res = execCmdEx(shellCommand(args))
    if res.exitCode != 0:
      raise newException(OSError,
        "tool-resolution failed: tar extraction failed for " & archivePath &
        "\n" & res.output)
    mergeRustInstallerComponents(destination)
  of "zip":
    let extractor = resolveZipExtractor()
    let command =
      case extractor.kind
      of "powershell":
        # `Expand-Archive` over PowerShell handles both `\\` and `/`
        # separator archives correctly. We pipe via -Command + -File
        # would require an on-disk script; -Command + a one-line
        # expression keeps the call self-contained.
        quoteShell(extractor.exe) &
          " -NoProfile -ExecutionPolicy Bypass -Command " &
          quoteShell("Expand-Archive -Path " & quoteShell(archivePath) &
            " -DestinationPath " & quoteShell(destination) & " -Force")
      of "unzip":
        quoteShell(extractor.exe) & " -q -o " & quoteShell(archivePath) &
          " -d " & quoteShell(destination)
      else:
        raise newException(ValueError, "unreachable")
    let res = execCmdEx(command)
    if res.exitCode != 0:
      raise newException(OSError,
        "tool-resolution failed: zip extraction failed for " & archivePath &
        "\n" & res.output)
    flattenStripComponents(destination, stripComponents)
  of "7z", "7z.exe":
    let sevenZipExe = resolveSevenZipExe()
    # `x` = extract with full paths preserved.
    # `-o<dir>` = output directory (NO space between -o and the path).
    # `-y` = assume yes for all prompts (overwrites).
    # `-bsp0` = no progress output on stdout.
    # `-bso0` = no standard output (only errors go to stderr).
    # 7z transparently recognises `.7z.exe` SFX envelopes; same call.
    let command = quoteShell(sevenZipExe) & " x " &
      quoteShell("-o" & destination) & " " & quoteShell(archivePath) &
      " -y -bsp0 -bso0"
    let res = execCmdEx(command)
    if res.exitCode != 0:
      raise newException(OSError,
        "tool-resolution failed: 7z extraction failed for " & archivePath &
        "\n" & res.output)
    flattenStripComponents(destination, stripComponents)
  of "raw":
    # `raw` payloads are the executable themselves (e.g. iden3/circom's
    # `circom-windows-amd64.exe` or argotorg/solidity's `solc-windows.exe`).
    # The `executablePath` declared by the package definition is the
    # relative path inside the prefix; copy the downloaded archive into
    # place under that name. `stripComponents` is meaningless here.
    if declaredExecutablePath.len == 0:
      raise newException(ValueError,
        "tool-resolution failed: archiveType=raw extraction requires the " &
        "caller to supply executablePath as the destination filename")
    let normalized = declaredExecutablePath.replace('\\', '/')
    if normalized.startsWith("/") or normalized == ".." or
        normalized.startsWith("../") or normalized.contains("/../") or
        normalized.endsWith("/.."):
      raise newException(ValueError,
        "tool-resolution failed: unsafe raw executablePath: " &
        declaredExecutablePath)
    let target = destination / declaredExecutablePath
    createDir(extendedPath(parentDir(target)))
    copyFile(extendedPath(archivePath), extendedPath(target))
    when not defined(windows):
      # Linux / macOS direct-download solc/circom binaries are shipped
      # without an executable bit on the GitHub release asset; restore
      # 0o755 so they can be exec'd from the prefix.
      setFilePermissions(extendedPath(target),
        {fpUserExec, fpUserRead, fpUserWrite,
         fpGroupExec, fpGroupRead,
         fpOthersExec, fpOthersRead})
  else:
    raise newException(ValueError,
      "tool-resolution failed: unsupported tarball archiveType " & archiveType)

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

proc materializeTarballPrefix(plan: TarballAcquisitionPlan; storeRoot: string;
                              writerMode = "direct"):
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
      plan.stripComponents, plan.declaredExecutablePath)
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
      [plan.declaredExecutablePath], writerMode = writerMode)
    (prefix: prefix, archivePath: downloaded.path,
      selectedUrl: downloaded.selectedUrl)
  except CatchableError:
    if dirExists(extendedPath(tempPrefix)):
      removeDir(extendedPath(tempPrefix))
    raise

proc resolveTarballTool*(useDef: InterfaceToolUse; storeRoot: string;
                         writerMode = "direct"):
    PathOnlyToolProfile =
  let plan = tarballAcquisitionPlan(useDef)
  let root =
    if storeRoot.len > 0:
      storeRoot
    else:
      getCurrentDir() / ".repro" / "tool-store"
  let materialized = materializeTarballPrefix(plan, root, writerMode)
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

  # M9.R.14e.7 — auxiliary search-path channels for the tarball-resolved
  # prefix. Mirrors the nix-resolved population so tarball-shipped libs
  # contribute to the consumer recipe's PKG_CONFIG_PATH /
  # CMAKE_PREFIX_PATH / CPATH / LIBRARY_PATH at action fork time.
  addUniquePath(result.cmakePrefixList, materialized.prefix)
  addUniquePath(result.pkgConfigSearchList,
    materialized.prefix / "lib" / "pkgconfig")
  addUniquePath(result.pkgConfigSearchList,
    materialized.prefix / "lib64" / "pkgconfig")
  addUniquePath(result.pkgConfigSearchList,
    materialized.prefix / "share" / "pkgconfig")
  addUniquePath(result.cpathList, materialized.prefix / "include")
  addUniquePath(result.libraryPathList, materialized.prefix / "lib")
  addUniquePath(result.libraryPathList, materialized.prefix / "lib64")

  result.probes = collectConfiguredProbes(resolved,
    useDef.packageSelector, useDef.executableName)

  result.profileFingerprint = profileFingerprintFor(result)

# ---------------------------------------------------------------------------
# MR5 -- Bootstrap toolchain resolution for the interface-extract step.
#
# The engine's `repro-interface-extract` step compiles the project's
# `repro.nim` recipe into a provider binary using `nim c` -> gcc. That
# step runs BEFORE the project's `uses:` declarations are visible (the
# manifest of "what tools the project uses" is INSIDE the recipe that
# we are trying to compile), so the engine cannot read the project's
# toolUses to learn which nim/gcc to use. It instead falls back to
# `hostCCompilerPath()` (the C compiler discovered by `staticExec` at
# the time repro.exe itself was built) and to the first `nim.exe` on
# `$PATH`. In a clean shell with neither of those pointing at a usable
# 64-bit gcc (e.g. when `gcc.exe` on PATH is FPC's 1999-era i386 gcc),
# the compile fails with `nimbase.h: Invalid argument`.
#
# To stay self-contained without baking a dev-shell path into the
# binary, we synthesize a hardcoded `InterfaceToolUse` record for nim
# and one for gcc on Windows, drive them through the same
# `resolveTarballTool` resolver that recipe-declared tools use, and
# expose the resolved exe paths via `$REPRO_NIM_COMPILER` and `$CC` —
# the two env vars `extractInterfaceFromModule` already honours. The
# tarball metadata (URL, sha256, executablePath) MUST stay in sync
# with the entries in `repro_dsl_stdlib/packages/{nim,gcc}.nim`.
# A future change can deduplicate by harvesting at compile time, but
# the hardcoded copy here keeps the engine's bootstrap free of any
# dependency on the project's recipe.
# ---------------------------------------------------------------------------

const
  BootstrapNimTarballUrl =
    "https://nim-lang.org/download/nim-2.2.10_x64.zip"
  BootstrapNimTarballSha256 =
    "fe0686a9b298e5b13d0a983df37e002a8c6320f8b16cc45a51d15cf4046a109f"
  BootstrapNimTarballLinuxUrl =
    "https://nim-lang.org/download/nim-2.2.10-linux_x64.tar.xz"
  BootstrapNimTarballLinuxSha256 =
    "0a3a38752e97e9d44aa479b3a7b37336dfe0176daf22ee5b5218ad0991ecd211"
  BootstrapGccWindowsTarballUrl =
    "https://github.com/brechtsanders/winlibs_mingw/releases/download/16.1.0posix-14.0.0-ucrt-r2/winlibs-x86_64-posix-seh-gcc-16.1.0-mingw-w64ucrt-14.0.0-r2.7z"
  BootstrapGccWindowsTarballSha256 =
    "62fb8588d2deee7d662dbcbd386702adbf19643764c971c38aa4839472eee232"

proc bootstrapNimToolUse(): InterfaceToolUse =
  result = InterfaceToolUse(
    rawConstraint: "nim >=2.2 <3.0",
    packageSelector: "nim@2.2.10",
    executableName: "nim")
  when defined(windows):
    result.tarballProvisioning = @[
      InterfaceTarballProvisioning(
        packageName: "nim",
        url: BootstrapNimTarballUrl,
        sha256: BootstrapNimTarballSha256,
        archiveType: "zip",
        executablePath: "bin/nim.exe",
        stripComponents: 1,
        packageId: "nim@2.2.10",
        lockIdentity: "tarball:nim@2.2.10:sha256:" & BootstrapNimTarballSha256,
        cpu: "x86_64",
        os: "windows")]
  else:
    result.tarballProvisioning = @[
      InterfaceTarballProvisioning(
        packageName: "nim",
        url: BootstrapNimTarballLinuxUrl,
        sha256: BootstrapNimTarballLinuxSha256,
        archiveType: "tar.xz",
        executablePath: "bin/nim",
        stripComponents: 1,
        packageId: "nim@2.2.10",
        lockIdentity: "tarball:nim@2.2.10:linux:sha256:" &
          BootstrapNimTarballLinuxSha256,
        cpu: "x86_64",
        os: "linux")]

proc bootstrapGccToolUse(): InterfaceToolUse =
  result = InterfaceToolUse(
    rawConstraint: "gcc",
    packageSelector: "gcc-winlibs@16.1.0",
    executableName: "gcc")
  when defined(windows):
    result.tarballProvisioning = @[
      InterfaceTarballProvisioning(
        packageName: "gcc",
        url: BootstrapGccWindowsTarballUrl,
        sha256: BootstrapGccWindowsTarballSha256,
        archiveType: "7z",
        executablePath: "bin/gcc.exe",
        stripComponents: 1,
        packageId: "gcc-winlibs@16.1.0",
        lockIdentity: "tarball:gcc-winlibs@16.1.0:sha256:" &
          BootstrapGccWindowsTarballSha256,
        cpu: "x86_64",
        os: "windows")]

proc findEditBin(): string =
  ## Locate `editbin.exe`, the MSVC PE-header editor. The build-shell
  ## adds the MSVC toolchain bin to PATH so it normally resolves there;
  ## fall back to `$VCToolsInstallDir/bin/Hostx64/x64/editbin.exe` when
  ## not on PATH (e.g. CI hosts that source the toolchain via
  ## `vcvarsall.bat` without prepending the bin dir).
  when defined(windows):
    let direct = findExe("editbin")
    if direct.len > 0:
      return direct
    let vcTools = getEnv("VCToolsInstallDir")
    if vcTools.len > 0:
      let candidate = vcTools / "bin" / "Hostx64" / "x64" / "editbin.exe"
      if fileExists(extendedPath(candidate)):
        return candidate
  return ""

proc bumpWindowsNimStack(nimExePath: string) =
  ## MR5 — Windows-only post-extract hook for the bootstrap-provisioned
  ## `nim.exe`. The upstream Nim Windows distribution ships nim.exe
  ## with the linker's default 2 MB stack reserve. The reprobuild
  ## ``package`` macro is deeply recursive when expanded against the
  ## full ``repro_dsl_stdlib`` umbrella that recorder ``repro.nim``
  ## recipes import; on Windows the compiler crashes with
  ## STATUS_STACK_OVERFLOW (-1073741571 / 0xC00000FD) during interface
  ## extraction. `editbin /STACK:33554432` rewrites the PE header in
  ## place to a 32 MB stack reserve, matching what
  ## ``repo-workspaces/windows/ensure-nim.ps1`` does at env.ps1
  ## install time. Idempotent (running it twice produces the same
  ## bytes) and silent on failure: if editbin isn't available the
  ## extract step still attempts the compile with the smaller stack
  ## and surfaces the original error to the user.
  when defined(windows):
    if nimExePath.len == 0 or not fileExists(extendedPath(nimExePath)):
      return
    # Cheap version check: skip if the file already has a >= 16 MB stack
    # reserve. `dumpbin /headers` would let us read it cleanly but is
    # a heavier optional tool; we instead rely on idempotency of
    # `editbin /STACK:` and the marker file written next to the binary.
    let marker = nimExePath & ".reprobuild-stack-bump.marker"
    if fileExists(extendedPath(marker)):
      return
    let editbin = findEditBin()
    if editbin.len == 0:
      return
    try:
      let res = execCmdEx(quoteShell(editbin) &
        " /STACK:33554432 " & quoteShell(nimExePath))
      if res.exitCode == 0:
        try:
          writeFile(extendedPath(marker), "ok\n")
        except CatchableError:
          discard
    except CatchableError, OSError:
      discard

proc ensureBootstrapToolchainEnv*(mode: ToolProvisioningMode;
                                  storeRoot: string) =
  ## MR5 — before the engine's interface-extract step shells out to
  ## `nim c`, ensure `$REPRO_NIM_COMPILER` and `$CC` point at a
  ## reprobuild-provisioned toolchain so the step does not pick up
  ## whatever incidental `nim.exe` / `gcc.exe` happen to be on `$PATH`
  ## (which on Windows often is FPC's 1999-era 32-bit gcc, breaking
  ## the compile with `nimbase.h: Invalid argument`).
  ##
  ## Only fires for tool-provisioning modes where the project's
  ## toolUses are resolved via the engine's tool-store (`tarball`
  ## today; `nix`/`scoop` resolve their toolchain through other
  ## adapters and the host PATH posture is already correct).
  ##
  ## MR9 — `$CC` honors pre-set values for backward compat with callers
  ## that pre-pin the compiler (CI, integration tests). But the
  ## interface-extract step ALSO publishes a dedicated, always-overridden
  ## `$REPRO_BOOTSTRAP_CC` pointing at the bootstrap-resolved gcc's
  ## absolute path on Windows. `hostCCompilerPath()` in
  ## `repro_interface_artifacts` consults that var FIRST so the nim
  ## invocation gets `--gcc.exe:<bootstrap>` regardless of whether a
  ## (possibly bare / PATH-relative) `$CC` was inherited from env.ps1
  ## or a parent shell. Without this, env.ps1's `$env:CC = "gcc"`
  ## (bare basename, not absolute) defeats the `hostCCompilerPath`
  ## `isAbsolute(ccEnv)` check, no `--gcc.exe` flag is emitted, and
  ## nim falls back to the PATH lookup that picks up FPC's 1999-era
  ## i386-target gcc 2.95 — failing the C compile of e.g. `blake3/capi.c`
  ## with `stddef.h: Invalid argument`.
  if mode != tpmTarball:
    return
  let effectiveStoreRoot =
    if storeRoot.len > 0: storeRoot
    else: getCurrentDir() / ".repro" / "tool-store"
  if getEnv("REPRO_NIM_COMPILER").len == 0:
    try:
      let useDef = bootstrapNimToolUse()
      if useDef.tarballProvisioning.len > 0:
        let profile = resolveTarballTool(useDef, effectiveStoreRoot)
        if profile.resolvedExecutablePath.len > 0:
          bumpWindowsNimStack(profile.resolvedExecutablePath)
          putEnv("REPRO_NIM_COMPILER", profile.resolvedExecutablePath)
    except CatchableError:
      # Silent: if bootstrap resolution fails (offline, no curl, etc.)
      # the existing PATH-based fallback in `nimCompilerPath()` still
      # runs and may succeed when the host has a usable nim/gcc.
      discard
  when defined(windows):
    # Always (re-)resolve the bootstrap gcc on Windows in tarball mode.
    # Publish via `$REPRO_BOOTSTRAP_CC` so the interface-extract flag
    # builder can pin `--gcc.exe:<absolute>` regardless of the inherited
    # `$CC` shape (see proc docstring). Resolution is cheap once the
    # tarball is materialized — `resolveTarballTool` short-circuits to
    # the existing prefix when the receipt is present.
    var bootstrapGcc = ""
    try:
      let useDef = bootstrapGccToolUse()
      if useDef.tarballProvisioning.len > 0:
        let profile = resolveTarballTool(useDef, effectiveStoreRoot)
        if profile.resolvedExecutablePath.len > 0:
          bootstrapGcc = profile.resolvedExecutablePath
    except CatchableError:
      discard
    if bootstrapGcc.len > 0:
      putEnv("REPRO_BOOTSTRAP_CC", bootstrapGcc)
      if getEnv("CC").len == 0:
        putEnv("CC", bootstrapGcc)

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
    pathSearchList:
      # The junction is named ``bin`` and maps to the whole scoop
      # app version dir. Some apps place their primary executable
      # at the junction root (e.g. rg.exe directly under bin/),
      # while others use a nested layout (e.g. rustup-msvc keeps
      # cargo.exe at ``.cargo/bin/cargo.exe`` via a persist
      # junction). Surface both: the junction root AND, when the
      # resolved executable lives in a deeper subdir, that subdir
      # too — so sibling binaries (cargo→rustc lookup, npm→node
      # lookup) can resolve via PATH at build time.
      block:
        var dirs = @[junctionTarget.parentDir / "bin"]
        if resolvedExecutable.len > 0:
          let exeDir = resolvedExecutable.parentDir
          if exeDir.len > 0 and exeDir notin dirs:
            dirs.add(exeDir)
        dirs,
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
    dependencyPolicy: automaticMonitorGatheringPolicy(),
    metadata: metadataFor(identity))

# ---------------------------------------------------------------------------
# M9.Q — From-source provisioning.
#
# ``tpmFromSource`` maps a ``uses: "<name>"`` recipe declaration to a
# sibling from-source recipe at ``recipes/packages/source/<name>/``.
# That recipe's ``executable <name>:`` block (claimed by the
# ``from-source-custom`` / ``from-source-meson`` / ... conventions)
# materialises a binary at
# ``recipes/packages/source/<name>/.repro/output/<name>/<name>``
# (or ``<name>.exe`` on Windows) per ``from_source_custom.nim``'s
# stage-copy contract. The resolver consults that path; if the binary
# exists and is executable, the bin dir threads into ``pathSearchList``
# and the tool is "from-source provisioned".
#
# **v1 scope.** No auto-recurse. When the sibling recipe is missing OR
# the artefact is not present, the resolver raises ``OSError`` with a
# structured diagnostic naming the recipe path and the exact build
# command the operator would invoke. The M9.Q.1 follow-up adds the
# recursive sub-build (subprocess-invoking ``repro build
# recipes/packages/source/<name> --tool-provisioning=tarball
# --no-runquota`` for each missing tool); the v1 hard-fail keeps the
# principled mode while leaving the recursion design decoupled.
#
# **Workspace anchor.** ``REPRO_FROM_SOURCE_ROOT`` (env var) overrides
# the default ``getCurrentDir() / "recipes" / "packages" / "source"``
# anchor — used by the unit test to point at a synthetic recipe tree
# without touching the production checkout.
# ---------------------------------------------------------------------------

const FromSourceRootEnvVar* = "REPRO_FROM_SOURCE_ROOT"

var fromSourceCycleBrokenTools*: HashSet[string] = initHashSet[string]()
  ## DSL-port M9.R.10a — per-process set of tool ``executableName``s
  ## flagged by the auto-recurse dispatcher as part of a closing edge of
  ## a from-source build cycle. When ``toolProfileFor(tpmFromSource, ...)``
  ## resolves a tool whose name is in this set, the sibling-recipe probe
  ## is bypassed entirely and the resolver falls through directly to
  ## ``tryResolveStdlibProvisioning`` — same logic as the
  ## ``rrSiblingMissing`` branch. This breaks the cycle without disabling
  ## from-source semantics for the rest of the build graph: the *one*
  ## tool whose recursive build would close the cycle (e.g. ``gcc`` when
  ## the chain is ``expat → autoconf → make → gcc → binutils → gcc``)
  ## comes from stdlib provisioning (nix on Linux/macOS, scoop on
  ## Windows, tarball anywhere); the rest of the chain still builds from
  ## source. Exported for test introspection.

const BootstrapCycleBreakTools* = @[
  ## M9.R.14c.2 / .8 — pre-seeded cycle-break taxonomy for the
  ## bootstrap tool chain. The dispatcher's reactive cycle break
  ## (M9.R.10a) only fires on the closing edge of a recursion cycle,
  ## so the ``gcc → binutils → gcc`` cycle adds ``gcc`` to the set but
  ## leaves ``binutils`` (and its sub-binaries) untouched. That left
  ## the binutils-from-source compile in the autotools smoke loop —
  ## ~15 minutes per iteration even when binutils is just an
  ## implementation detail of the bootstrap layer.
  ##
  ## The proactive seed treats the GNU bootstrap layer as a stdlib-
  ## provisioned floor: ``gcc``, ``make``, ``binutils`` (plus its 11
  ## sub-binaries), AND the autotools regen layer
  ## (``autoconf`` + ``automake`` + ``libtool`` + ``m4`` + ``perl``)
  ## come from nix on Linux/macOS, scoop on Windows, tarball anywhere.
  ## Application recipes (expat / libffi / wayland / glib2 / etc.)
  ## still build from source.
  ##
  ## Why the autotools regen layer is part of the floor (M9.R.14c.8):
  ## autoconf / automake / libtool are perl scripts whose execution
  ## requires sibling ``share/<tool>/`` and ``lib/<tool>/`` trees with
  ## perl modules. The autotools_package stage-copy convention
  ## (M9.R.14c.5) stages only the executable binary, dropping the
  ## sibling tree context, so a from-source-built autoconf can't find
  ## ``Autom4te/ChannelDefs.pm``. The stdlib nix provisioning ships
  ## the full install tree intact. The from-source build of these
  ## tools is correctly producing artifacts; the issue is the staging
  ## contract. M9.L's per-artifact install-glue will unblock genuine
  ## from-source autotools eventually.
  ##
  ## Binutils sub-binaries enumerated to match
  ## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/binutils.nim``
  ## (the stdlib package layout shipping 8 separate package blocks per
  ## the macro layer's "one executable per package" restriction). The
  ## remaining 3 binaries (``readelf`` / ``size`` / ``strings``) are
  ## listed here so the recipe corpus can cycle-break them when
  ## consumed even though the stdlib doesn't ship typed wrappers yet.
  "gcc", "g++", "cc", "c++",
  "make", "gmake",
  "binutils",
  "ld", "ar", "ranlib", "strip", "nm", "objdump", "objcopy", "as",
  "readelf", "size", "strings",
  # M9.R.14c.8 — autotools regen layer.
  "autoconf", "autoheader", "autom4te", "autoreconf", "autoscan",
  "autoupdate", "ifnames",
  "automake", "aclocal",
  "libtool", "libtoolize",
  "m4",
  "perl",
  # M9.R.14d.5 — meson/ninja/python3/pkg-config bootstrap floor.
  # These are build-system drivers, not C/C++ code that needs to be
  # compiled from source. Their from-source recipes either need
  # cross-language toolchains (meson is python, python3 is itself an
  # entire bootstrap problem) or don't produce a standard executable
  # artifact under the from-source-custom convention (meson lands
  # under .repro/build/from-source-custom/<pkg>/, not under
  # .repro/output/<artifactName>/). Routing them through the stdlib
  # provisioning skips the unproductive recursion.
  "meson", "ninja", "python3", "python", "pkg-config", "pkgconf",
  # M9.R.14g.5 — cmake bootstrap floor. cmake's from-source recipe
  # transitively pulls gcc and (per M9.R.10a) trips the gcc cycle break
  # too late — by then the sub-build worker has already failed because
  # the gcc tool use has no stdlib provisioning channel declared on the
  # CMake source recipe's lifted nativeBuildDeps. Routing cmake itself
  # through stdlib (nix on Linux/macOS, tarball on Windows) terminates
  # the recursion at the first edge. Same shape as meson/ninja above:
  # cmake is a build-system driver, not a leaf C/C++ artifact a recipe
  # needs to ship.
  "cmake",
]
  ## Exported so tests + the dispatcher init code can audit + seed the
  ## list without re-declaring it.

proc seedBootstrapCycleBreakTools*() =
  ## M9.R.14c.2 — populate ``fromSourceCycleBrokenTools`` with the
  ## bootstrap tool chain. Idempotent: re-running is a no-op. The CLI
  ## calls this once during ``--tool-provisioning=from-source`` setup
  ## so the resolver short-circuits binutils + gcc + make to stdlib
  ## provisioning from the first probe pass on, instead of waiting for
  ## the dispatcher to discover the cycle reactively.
  for tool in BootstrapCycleBreakTools:
    fromSourceCycleBrokenTools.incl(tool)

proc fromSourceRecipeRoot*(): string =
  ## Resolve the from-source recipe anchor. Honours
  ## ``REPRO_FROM_SOURCE_ROOT`` first; falls back to
  ## ``getCurrentDir() / "recipes" / "packages" / "source"`` so an
  ## operator invoking ``repro build`` from a reprobuild checkout finds
  ## the recipes that ship in-tree.
  let override = getEnv(FromSourceRootEnvVar)
  if override.len > 0:
    return override
  getCurrentDir() / "recipes" / "packages" / "source"

proc fromSourceArtifactCandidate*(recipeRoot, packageName,
                                  executableName: string): string =
  ## Construct the on-disk path the ``from-source-custom`` convention's
  ## stage-copy action lands the artefact at:
  ## ``<recipeRoot>/<packageName>/.repro/output/<executableName>/<executableName>``
  ## (with ``.exe`` suffix appended on Windows when the file exists at
  ## the suffixed path). Callers test ``fileExists`` themselves.
  result = recipeRoot / packageName / ".repro" / "output" /
    executableName / executableName

# ---------------------------------------------------------------------------
# M9.R.14d.1 — library vs executable artefact discovery for from-source deps
# ---------------------------------------------------------------------------

proc m9r14dCanonicalizeName*(name: string): string =
  ## Canonical form used to match a `nativeBuildDeps`/`buildDeps`
  ## selector against the sibling recipe's artifact name. Lowercase the
  ## name and drop a leading ``lib`` prefix so ``libZ`` collapses onto
  ## ``z`` and ``zlib`` collapses onto ``zlib``. Callers compare BOTH the
  ## raw lower-cased name AND the stripped form to catch the common
  ## "package zlib provides library libz" inversion: the dep selector is
  ## ``zlib`` (lower=``zlib``, stripped=``zlib``) but the artifact name
  ## is ``libZ`` (lower=``libz``, stripped=``z``) — a match requires
  ## either pair to coincide.
  result = name.toLowerAscii
  if result.startsWith("lib"):
    result = result[3 .. ^1]

proc m9r14dDepMatchesArtifact*(depName, artifactName: string): bool =
  ## Match-rule M9.R.14d.1: a dep selector matches an artifact name when
  ## any of three relations hold (most-specific first):
  ##   1. Case-insensitive exact match (``zlib`` vs ``zlib``).
  ##   2. Lowercase match (``Make`` vs ``make``).
  ##   3. Canonicalized match: lowercase-and-strip-lib equivalence on
  ##      either side. Because the package-vs-soname inversion can go
  ##      either way (recipe declares ``libZ`` for package ``zlib``;
  ##      recipe declares ``zlib`` for package ``libz``), we check both
  ##      stripping directions and allow a match when either pair of
  ##      canonical forms coincide.
  if depName.cmpIgnoreCase(artifactName) == 0: return true
  let depLower = depName.toLowerAscii
  let artLower = artifactName.toLowerAscii
  if depLower == artLower: return true
  let depCanon = m9r14dCanonicalizeName(depName)
  let artCanon = m9r14dCanonicalizeName(artifactName)
  if depCanon == artCanon: return true
  # Asymmetric forms: dep "zlib" vs artifact "libZ" ⇒ depCanon=zlib,
  # artCanon=z; depLower=zlib, artLower=libz. Compare each raw lower
  # form against the OTHER side's canonical form.
  if depLower == artCanon: return true
  if artLower == depCanon: return true
  false

proc m9r14dPlatformLibrarySuffixes(): seq[string] =
  ## Probe-order list of shared-library file extensions on the current
  ## platform. The bare-name form (`""`) is included LAST so the
  ## stage-copy's pre-M9.R.14d layout (`.repro/output/<name>/<name>`
  ## with no extension) keeps working until every recipe re-stages.
  when defined(windows):
    result = @[".dll", ""]
  elif defined(macosx):
    result = @[".dylib", ".so", ""]
  else:
    result = @[".so", ""]

type
  M9R14dArtifactKind* = enum
    makUnknown
    makExecutable
    makLibrary
    makFiles

  M9R14dArtifactCandidate* = object
    ## DSL-port M9.R.14d.1 — one candidate the resolver considers when
    ## probing a sibling recipe for a tool dep. The resolver enumerates
    ## the recipe's `.repro/output/<artifactName>/` directories AND the
    ## recipe's project-interface.rbsz (when available) to populate the
    ## seq, then picks the best match per `m9r14dDepMatchesArtifact`.
    artifactName*: string
    kind*: M9R14dArtifactKind
    resolvedPath*: string
      ## Absolute path to the on-disk artefact file (empty when nothing
      ## has been staged yet — the dispatcher then triggers a sub-build).

proc m9r14dLoadInterfaceKinds*(recipeDir: string):
    Table[string, M9R14dArtifactKind] =
  ## Read the sibling recipe's project-interface.rbsz, when it exists,
  ## and return a table mapping artifact name to ``M9R14dArtifactKind``.
  ## Returns an empty table when the recipe has not been built yet or
  ## the artefact is unreadable for any reason — the caller then falls
  ## back to filesystem-only inference (``makUnknown`` per artefact).
  let interfacePath = recipeDir / ".repro" / "build" / "repro" /
    "project-interface.rbsz"
  if not fileExists(extendedPath(interfacePath)):
    return
  try:
    let artifact = readInterfaceArtifact(interfacePath)
    for exe in artifact.projectInterface.publicExecutables:
      let name = if exe.binaryName.len > 0: exe.binaryName else: exe.exportName
      if name.len > 0:
        result[name] = makExecutable
    for lib in artifact.projectInterface.publicLibraries:
      if lib.name.len > 0:
        result[lib.name] = makLibrary
  except CatchableError:
    discard

proc m9r14dProbeArtifactFile*(outputDir, artifactName: string;
                              kind: M9R14dArtifactKind): string =
  ## Probe the on-disk layout the from-source stage-copy emits for a
  ## single artifact. Returns the absolute path when one of the
  ## platform-shaped candidates exists, "" otherwise.
  ##
  ## Probe order:
  ##   * dakLibrary:    <artifactName>.so, <artifactName>.dll,
  ##                    <artifactName>.dylib, then bare <artifactName>
  ##                    (the pre-M9.R.14d stage-copy layout).
  ##   * dakExecutable: bare <artifactName>, then <artifactName>.exe
  ##                    (Windows or cross-compiled).
  ##   * dakFiles:      <outputDir> itself when the directory exists.
  ##   * makUnknown:    union of library and executable shapes — used
  ##                    when the interface artefact isn't available yet.
  let bareCandidate = outputDir / artifactName
  case kind
  of makLibrary:
    for suffix in m9r14dPlatformLibrarySuffixes():
      let candidate = bareCandidate & suffix
      if fileExists(extendedPath(candidate)):
        return absolutePath(candidate)
  of makExecutable:
    if fileExists(extendedPath(bareCandidate)):
      when not defined(windows):
        if {fpUserExec, fpGroupExec, fpOthersExec}.anyIt(
            it in getFilePermissions(extendedPath(bareCandidate))):
          return absolutePath(bareCandidate)
      else:
        return absolutePath(bareCandidate)
    let exeCandidate = bareCandidate & ".exe"
    if fileExists(extendedPath(exeCandidate)):
      return absolutePath(exeCandidate)
  of makFiles:
    if dirExists(extendedPath(outputDir)):
      return absolutePath(outputDir)
  of makUnknown:
    # Try library-shape first (the M9.R.14d motivating case), then
    # executable-shape. The bare-name probe collapsed into the library
    # suffix list so we don't double-check it for executables.
    for suffix in m9r14dPlatformLibrarySuffixes():
      let candidate = bareCandidate & suffix
      if fileExists(extendedPath(candidate)):
        when not defined(windows):
          if suffix.len > 0:
            return absolutePath(candidate)
          if {fpUserExec, fpGroupExec, fpOthersExec}.anyIt(
              it in getFilePermissions(extendedPath(candidate))):
            return absolutePath(candidate)
        else:
          return absolutePath(candidate)
    let exeCandidate = bareCandidate & ".exe"
    if fileExists(extendedPath(exeCandidate)):
      return absolutePath(exeCandidate)
  return ""

proc m9r14dEnumerateArtifacts*(recipeDir: string):
    seq[M9R14dArtifactCandidate] =
  ## Enumerate the artifacts a sibling recipe has produced. Walks the
  ## recipe's ``.repro/output/`` directory (each subdir name is an
  ## artifact name) and pairs it with the project-interface.rbsz kind
  ## when available. Returns the empty seq when nothing has been staged.
  let outputRoot = recipeDir / ".repro" / "output"
  if not dirExists(extendedPath(outputRoot)):
    return
  let kinds = m9r14dLoadInterfaceKinds(recipeDir)
  for kindPc, name in walkDir(extendedPath(outputRoot)):
    if kindPc != pcDir and kindPc != pcLinkToDir:
      continue
    let artifactName = lastPathPart(name)
    if artifactName.len == 0: continue
    let outDir = outputRoot / artifactName
    let artKind = kinds.getOrDefault(artifactName, makUnknown)
    let resolved = m9r14dProbeArtifactFile(outDir, artifactName, artKind)
    result.add(M9R14dArtifactCandidate(
      artifactName: artifactName,
      kind: artKind,
      resolvedPath: resolved))

proc m9r14dPickBestMatch*(candidates: seq[M9R14dArtifactCandidate];
                          depName: string): int =
  ## Pick the candidate index that best matches ``depName`` per the
  ## ``m9r14dDepMatchesArtifact`` rule. Returns -1 when nothing matches.
  ##
  ## Match priority (most-specific first):
  ##   1. Exact case-insensitive match on artifact name.
  ##   2. Lowercased match.
  ##   3. Canonicalized lib-stripped match (either direction).
  ##   4. Canonical-prefix fallback: artifact's canonical form starts
  ##      with the dep's canonical form (covers the wayland case where
  ##      dep "wayland" finds artifact "libwaylandClient" — canonical
  ##      forms `wayland` vs `waylandclient`).
  ##   5. Sole-artifact fallback: if exactly ONE candidate has a
  ##      resolved on-disk file, return it (the dep selector already
  ##      identified the recipe).
  ##
  ## Within each tier, prefer the candidate whose ``resolvedPath`` is
  ## non-empty — an artifact named in the interface but not yet staged
  ## still matches by name, but a staged sibling under a less-specific
  ## tier wins because the resolver needs an on-disk file.
  result = -1
  var bestTier = high(int)
  let depCanon = m9r14dCanonicalizeName(depName)
  for i, cand in candidates:
    var tier = high(int)
    if depName.cmpIgnoreCase(cand.artifactName) == 0:
      tier = 0
    elif depName.toLowerAscii == cand.artifactName.toLowerAscii:
      tier = 1
    elif m9r14dDepMatchesArtifact(depName, cand.artifactName):
      tier = 2
    else:
      let artCanon = m9r14dCanonicalizeName(cand.artifactName)
      if depCanon.len > 0 and artCanon.len > 0 and
          (artCanon.startsWith(depCanon) or depCanon.startsWith(artCanon)):
        tier = 3
    if tier < bestTier:
      bestTier = tier
      result = i
    elif tier == bestTier and result >= 0 and
        candidates[result].resolvedPath.len == 0 and
        cand.resolvedPath.len > 0:
      result = i
  if result < 0:
    var resolvedIdx = -1
    var resolvedCount = 0
    for i, cand in candidates:
      if cand.resolvedPath.len > 0:
        resolvedIdx = i
        inc resolvedCount
    if resolvedCount == 1:
      result = resolvedIdx

proc m9r14hProbeInstallMirrorLibrary*(recipeDir, depName: string): string =
  ## DSL-port M9.R.14h.1 — install-mirror fast-path probe.
  ##
  ## When a sibling recipe has successfully completed an install-mirror
  ## pass (M9.R.14e.2) it owns
  ## ``<recipeDir>/.repro/output/install/usr/lib*/lib<X>.so*`` files
  ## with the upstream SONAME chain preserved.  The per-artifact stage
  ## tree (``.repro/output/<artifactName>/`` walked by
  ## ``m9r14dEnumerateArtifacts``) is the FIRST fast-path; the
  ## install-mirror is a SECOND fast-path covering recipes whose
  ## ``library: cli:`` block did not declare a name that survives the
  ## stage-copy probe (e.g. SONAME-versioned ``libcairo.so.2.11800.0``
  ## with no plain ``libcairo.so`` symlink in the per-artifact tree).
  ##
  ## Returns the absolute path of the first matching library file or
  ## ``""`` when nothing matches.  Mirrors the ``m9r14dProbeArtifactFile``
  ## return-shape so callers can ``len > 0``-gate the result.
  ##
  ## Idempotency guarantee (Gap 1 fix): callers can probe this BEFORE
  ## scheduling a sub-build so a sibling whose install-mirror is on disk
  ## is NEVER re-built within the same dispatcher invocation, even when
  ## the per-process ``fromSourceResolvedRecipes`` cache was cleared
  ## (e.g. by a fresh ``executeBuildTarget`` call from a sub-recurse).
  let mirrorRoot = recipeDir / ".repro" / "output" / "install" / "usr"
  if not dirExists(extendedPath(mirrorRoot)):
    return ""
  let canon = m9r14dCanonicalizeName(depName)
  if canon.len == 0:
    return ""
  # Candidate base names to probe.  We use the canonical lib-stripped
  # form so a dep selector ``zlib`` matches ``libz.so`` AND ``libzlib.so``.
  var bases: seq[string] = @[]
  bases.add("lib" & canon)
  if depName.toLowerAscii != canon:
    # Also probe the un-canonicalized lowercase form so ``zlib`` →
    # ``libzlib.so`` resolves when the recipe baked in the redundant
    # prefix.
    bases.add("lib" & depName.toLowerAscii)
  # Suffix candidates per platform.  Match either the plain ``.so`` /
  # ``.dylib`` / ``.dll`` shape OR a SONAME-versioned shape like
  # ``.so.2`` / ``.so.0.25.0`` so recipes that don't ship the plain
  # symlink (or that ship only the upstream-versioned chain) still
  # register as "already built".
  let suffixes = m9r14dPlatformLibrarySuffixes()
  for libDir in ["lib", "lib64"]:
    let dir = mirrorRoot / libDir
    if not dirExists(extendedPath(dir)):
      continue
    for base in bases:
      for suffix in suffixes:
        let exact = dir / (base & suffix)
        if fileExists(extendedPath(exact)):
          return absolutePath(exact)
      # SONAME-versioned probe: walk the dir for any file starting with
      # ``<base>.so`` (Linux) / ``<base>.dylib`` (Darwin) / ``<base>.dll``
      # (Windows) and accept the first one.  Order is non-deterministic
      # from ``walkDir`` but every match is a legitimate library file so
      # the fast-path stays correct.  We walk with ``extendedPath(dir)``
      # for long-path safety, then strip the ``\\?\`` prefix the walker
      # may have prepended so the return value is the plain canonical
      # form callers compare against.
      for kindPc, walked in walkDir(extendedPath(dir)):
        if kindPc != pcFile and kindPc != pcLinkToFile:
          continue
        var path = walked
        when defined(windows):
          if path.startsWith("\\\\?\\"):
            path = path[4 .. ^1]
        let leaf = lastPathPart(path)
        for suffix in suffixes:
          let prefix = base & suffix
          if leaf.startsWith(prefix):
            return absolutePath(path)
  return ""

type
  FromSourceResolveKind* = enum
    ## DSL-port M9.R.9 — discriminated outcome for from-source
    ## resolution. ``rrResolved`` carries a finished profile;
    ## ``rrNeedsBuild`` flags a present sibling recipe with a missing
    ## artefact (the caller schedules a recursive sub-build);
    ## ``rrSiblingMissing`` flags the absence of any sibling recipe
    ## (the caller falls through to stdlib provisioning channels).
    rrResolved
    rrNeedsBuild
    rrSiblingMissing

  FromSourceResolveResult* = object
    case kind*: FromSourceResolveKind
    of rrResolved:
      profile*: PathOnlyToolProfile
    of rrNeedsBuild:
      recipeDir*: string
      expectedArtifact*: string
      toolName*: string
    of rrSiblingMissing:
      attemptedRecipeManifest*: string
      missingToolName*: string

# ---------------------------------------------------------------------------
# M9.R.14e.1 — from-source install-tree search-path discovery
# ---------------------------------------------------------------------------

const FromSourceInstallTreeRoots* = @[
  # M9.R.14e.1 — installation tree probe roots for a from-source
  # recipe's sibling install tree. Ordered most-specific first so the
  # populator emits the M9.R.14e.2 staged-tree first when both layouts
  # are present.
  ".repro/output/install/usr",
  ".repro/output/install",
  "build/out/usr",
]

proc addUniquePath*(dst: var seq[string]; value: string) =
  ## Append ``value`` to ``dst`` when it isn't already present AND when
  ## the directory exists on disk. Centralised so the populator below
  ## stays free of fileExists / dedup boilerplate.
  if value.len == 0: return
  if not dirExists(extendedPath(value)): return
  let abs = absolutePath(value)
  for entry in dst:
    if entry == abs:
      return
  dst.add(abs)

proc populateFromSourceSearchPathsLocal(profile: var PathOnlyToolProfile;
                                        recipeDir: string) =
  ## Internal: populate ONLY this recipe's install-tree search paths
  ## (no transitive walk). Extracted from ``populateFromSourceSearchPaths``
  ## so the M9.R.14f.1 transitive walk can call it per-node without
  ## re-entering the dep-discovery loop.
  for root in FromSourceInstallTreeRoots:
    let prefixRoot = recipeDir / root
    if not dirExists(extendedPath(prefixRoot)):
      continue
    # CMAKE_PREFIX_PATH — points at the install-prefix root.
    addUniquePath(profile.cmakePrefixList, prefixRoot)
    # PKG_CONFIG_PATH — lib/pkgconfig + share/pkgconfig.
    addUniquePath(profile.pkgConfigSearchList, prefixRoot / "lib" / "pkgconfig")
    addUniquePath(profile.pkgConfigSearchList, prefixRoot / "lib64" / "pkgconfig")
    addUniquePath(profile.pkgConfigSearchList, prefixRoot / "share" / "pkgconfig")
    # CPATH — include/ dir.
    addUniquePath(profile.cpathList, prefixRoot / "include")
    # LIBRARY_PATH / LD_LIBRARY_PATH — lib/ dir (+ lib64 on multilib
    # distros).
    addUniquePath(profile.libraryPathList, prefixRoot / "lib")
    addUniquePath(profile.libraryPathList, prefixRoot / "lib64")
    # M9.R.14f.2 — also expose the ``bin/`` dir so tools the dep
    # ships (e.g. ``wayland-scanner``) are visible to consumers via
    # ``pathSearchList``.
    let binRoot = prefixRoot / "bin"
    if dirExists(extendedPath(binRoot)):
      let abs = absolutePath(binRoot)
      var present = false
      for p in profile.pathSearchList:
        if p == abs:
          present = true
          break
      if not present:
        profile.pathSearchList.add(abs)

const M9R14fMaxTransitiveDepth* = 16
  ## DSL-port M9.R.14f.1 — sanity bound on the transitive dep walk. The
  ## graph SHOULD already be acyclic (the M9.R.10a cycle-break handles
  ## genuine cycles), so this exists purely to make accidental cycles
  ## terminate fast with a clear diagnostic in tests rather than to
  ## hang the resolver.

proc m9r14fStripConstraint(value: string): string =
  ## DSL-port M9.R.14f.1 — strip a version-constraint suffix off a raw
  ## constraint string so ``"wayland >=1.22"`` → ``"wayland"``. Mirrors
  ## the same trimming the meson_package constructor does for tool refs.
  for i, ch in value:
    if ch == ' ' or ch == '>' or ch == '<' or ch == '=' or
        ch == '~' or ch == '^':
      return value[0 ..< i]
  return value

proc m9r14fDepRecipeName(useDef: InterfaceToolUse): string =
  ## Derive the sibling recipe dir name for a dep. Prefers
  ## ``executableName`` (the canonical from-source resolver key), falls
  ## back to the constraint-stripped ``packageSelector``, and finally to
  ## the trimmed ``rawConstraint``. Empty result = the dep can't be
  ## mapped onto a sibling recipe and the walk skips it.
  if useDef.executableName.len > 0:
    return useDef.executableName
  if useDef.packageSelector.len > 0:
    return m9r14fStripConstraint(useDef.packageSelector)
  if useDef.rawConstraint.len > 0:
    return m9r14fStripConstraint(useDef.rawConstraint)
  ""

proc m9r14fLoadInterfaceToolUses*(recipeDir: string): seq[InterfaceToolUse] =
  ## DSL-port M9.R.14f.1 — read the sibling recipe's
  ## ``project-interface.rbsz`` and return its ``toolUses`` (which carry
  ## both ``nativeBuildDeps`` and ``buildDeps``). Returns the empty seq
  ## when the recipe has not been built yet OR the artifact is
  ## unreadable — the caller treats that as "no transitive walk available
  ## for this dep" and moves on. Auto-recurse (M9.R.9) ensures the
  ## interface exists by the time a consumer reaches this code path.
  let interfacePath = recipeDir / ".repro" / "build" / "repro" /
    "project-interface.rbsz"
  if not fileExists(extendedPath(interfacePath)):
    return
  try:
    let artifact = readInterfaceArtifact(interfacePath)
    result = artifact.projectInterface.toolUses
  except CatchableError:
    discard

proc populateFromSourceSearchPathsImpl(profile: var PathOnlyToolProfile;
                                       recipeDir: string;
                                       recipeRoot: string;
                                       visited: var HashSet[string];
                                       depth: int) =
  ## DSL-port M9.R.14f.1 — recursive worker. Visits THIS node, then walks
  ## every dep declared in the node's ``project-interface.rbsz`` and
  ## recurses for each dep that has a sibling from-source recipe.
  if depth > M9R14fMaxTransitiveDepth:
    return
  let key = absolutePath(recipeDir)
  if key in visited:
    return
  visited.incl(key)
  populateFromSourceSearchPathsLocal(profile, recipeDir)
  # Walk the recipe's declared deps and recurse for each from-source
  # sibling. Tools without a sibling recipe (gcc / meson / ninja / ...)
  # are silently skipped — they don't contribute install-tree search
  # paths anyway.
  for useDef in m9r14fLoadInterfaceToolUses(recipeDir):
    let depName = m9r14fDepRecipeName(useDef)
    if depName.len == 0: continue
    if depName in fromSourceCycleBrokenTools: continue
    let depDir = recipeRoot / depName
    if not fileExists(extendedPath(depDir / "repro.nim")):
      continue
    populateFromSourceSearchPathsImpl(profile, depDir, recipeRoot,
      visited, depth + 1)

proc populateFromSourceSearchPaths*(profile: var PathOnlyToolProfile;
                                    recipeDir: string;
                                    recipeRoot = "") =
  ## DSL-port M9.R.14e.1 + M9.R.14f.1 — fill the four extra search-path
  ## channels on ``profile`` by probing the sibling recipe's install
  ## tree(s) AND, recursively, every from-source sibling recipe the
  ## sibling itself depends on.
  ##
  ## The probe walks ``FromSourceInstallTreeRoots`` for each known FHS
  ## subdir (``lib``, ``lib/pkgconfig``, ``include``, ``share/pkgconfig``)
  ## and adds the dirs that exist on disk to the corresponding list.
  ##
  ## M9.R.14f.1 layered the transitive walk on top: the resolver reads
  ## ``<recipeDir>/.repro/build/repro/project-interface.rbsz`` to
  ## discover the dep's own deps and recurses into each from-source
  ## sibling. The visited-set prevents infinite recursion on accidental
  ## cycles; depth is capped at ``M9R14fMaxTransitiveDepth`` as a
  ## sanity bound. Tools in ``fromSourceCycleBrokenTools`` (gcc, meson,
  ## ninja, ...) are skipped — they're stdlib-provisioned and don't
  ## contribute install-tree search paths.
  ##
  ## The autotools_package / meson_package constructors stage the
  ## upstream's ``make install DESTDIR=<recipe>/build/out`` (or
  ## ``meson install --destdir=...``) tree under ``build/out/usr/`` so
  ## the resolver finds the upstream's full install layout there
  ## directly — no extra stage-copy needed.
  ##
  ## Idempotent + deterministic: same inputs (recipe tree on disk) →
  ## same lists. Order is depth-first preorder from ``recipeDir`` so a
  ## graph ``consumer → A → B → C`` populates in order ``A, B, C``.
  let effectiveRoot =
    if recipeRoot.len > 0: recipeRoot
    else: parentDir(absolutePath(recipeDir))
  var visited: HashSet[string] = initHashSet[string]()
  populateFromSourceSearchPathsImpl(profile, recipeDir, effectiveRoot,
    visited, 0)

proc tryResolveFromSourceTool*(useDef: InterfaceToolUse;
                               recipeRoot = ""): FromSourceResolveResult =
  ## DSL-port M9.R.9 — non-raising variant of ``resolveFromSourceTool``.
  ## Returns a discriminated outcome the caller pattern-matches on:
  ##
  ##   * ``rrResolved``       — the sibling recipe exists AND its
  ##                            artefact is on disk; ``profile`` carries
  ##                            the resolved ``PathOnlyToolProfile``.
  ##   * ``rrNeedsBuild``     — the sibling recipe exists but its
  ##                            artefact is missing. ``recipeDir`` +
  ##                            ``expectedArtifact`` give the dispatcher
  ##                            the data it needs to schedule a recursive
  ##                            sub-build.
  ##   * ``rrSiblingMissing`` — no ``repro.nim`` at the conventional
  ##                            location; the caller MAY fall through to
  ##                            stdlib provisioning channels declared on
  ##                            the ``useDef`` itself.
  ##
  ## An empty ``executableName`` is still a hard error (the resolver has
  ## no way to derive a recipe dir without it) — that path raises just
  ## like the legacy entry point.
  let root =
    if recipeRoot.len > 0: recipeRoot
    else: fromSourceRecipeRoot()
  let name = useDef.executableName
  if name.len == 0:
    raise newException(OSError,
      "tool-resolution failed: from-source mode requires a non-empty " &
      "executableName on the tool use (package \"" &
      useDef.packageSelector & "\")")
  let recipeDir = root / name
  let recipeManifest = recipeDir / "repro.nim"
  if not fileExists(extendedPath(recipeManifest)):
    return FromSourceResolveResult(kind: rrSiblingMissing,
      attemptedRecipeManifest: recipeManifest,
      missingToolName: name)

  # M9.R.14d.1 — enumerate every artifact the sibling recipe has
  # staged AND every artifact it declared in its interface. Match the
  # dep's `executableName` (which is just the package selector for
  # ``nativeBuildDeps: "zlib"``-style deps) against the artifact names
  # with library-vs-executable + canonicalization awareness.
  #
  # Falls back to the pre-M9.R.14d "name-as-artifact" probe when no
  # candidates can be enumerated (the recipe's `.repro/output/` tree
  # is empty / missing) so existing tests + the executable-style probe
  # for tools like ``meson`` keep working unchanged.
  let baseCandidate = fromSourceArtifactCandidate(root, name, name)
  var candidates = m9r14dEnumerateArtifacts(recipeDir)
  var resolved = ""
  if candidates.len > 0:
    let pickIdx = m9r14dPickBestMatch(candidates, name)
    if pickIdx >= 0 and candidates[pickIdx].resolvedPath.len > 0:
      resolved = candidates[pickIdx].resolvedPath
  if resolved.len == 0:
    # Pre-M9.R.14d fallback: name-as-artifact probe. Covers the case
    # where the recipe stages under the dep's exact name (e.g. meson
    # → `.repro/output/meson/meson`) and never declared a library
    # block.
    var legacyCandidates: seq[string] = @[baseCandidate]
    when defined(windows):
      legacyCandidates.add(baseCandidate & ".exe")
    else:
      legacyCandidates.add(baseCandidate & ".exe")
    for candidate in legacyCandidates:
      if fileExists(extendedPath(candidate)):
        when defined(windows):
          resolved = candidate
          break
        else:
          if {fpUserExec, fpGroupExec, fpOthersExec}.anyIt(
              it in getFilePermissions(extendedPath(candidate))):
            resolved = candidate
            break
  if resolved.len == 0:
    # DSL-port M9.R.14h.1 — install-mirror fast-path.  If the per-
    # artifact tree didn't probe a library AND the legacy bare-name
    # probe missed (the typical case for a recipe that ONLY stages via
    # ``emitInstallTreeMirror``), check the install-mirror at
    # ``<recipeDir>/.repro/output/install/usr/lib*/lib<name>*.so*``.
    # Treat presence as a strong "already built" signal so the
    # dispatcher's auto-recurse path skips the sub-build — preventing
    # the determinism break where a sibling that successfully published
    # in an earlier sub-recurse gets its install mirror clobbered by a
    # fresh ``rm -rf install/usr`` from ``emitInstallTreeMirror``.
    let mirrorHit = m9r14hProbeInstallMirrorLibrary(recipeDir, name)
    if mirrorHit.len > 0:
      resolved = mirrorHit
  if resolved.len == 0:
    return FromSourceResolveResult(kind: rrNeedsBuild,
      recipeDir: recipeDir,
      expectedArtifact: baseCandidate,
      toolName: name)

  let absolute = absolutePath(resolved)
  var profile = PathOnlyToolProfile(
    installMethod: "from-source",
    packageSelector: useDef.packageSelector,
    packageId:
      if useDef.packageSelector.len > 0: useDef.packageSelector
      else: name & "@from-source",
    declaredExecutablePath: name,
    executableName: name,
    pathSearchList: @[parentDir(absolute)],
    resolvedExecutablePath: absolute,
    realizedStorePaths: @[recipeDir],
    selectedStorePath: recipeDir,
    realizationBoundary: recipeDir,
    lockIdentity: "from-source:" & name & ":recipe:" & recipeDir,
    adapterStrength: asStrong,
    cachePortability: cpLocalOnly,
    practicalHardening: phNone)

  # M9.R.14e.1 — populate the four extra search-path channels by
  # probing the sibling recipe's install tree. We support TWO layouts:
  #
  #   1. ``<recipeDir>/build/out/usr/`` — the autotools_package /
  #      meson_package staging tree (DESTDIR for ``make install``,
  #      ``--destdir`` for ``meson install``). Already populated by
  #      every recipe that uses the new constructors.
  #   2. ``<recipeDir>/.repro/output/install/usr/`` — the M9.R.14e.2
  #      full-tree stage-copy layout. Reserved for the next milestone
  #      step; the resolver probes it now so the data structure works
  #      end-to-end once stage-copy starts populating it.
  #
  # Each list is deduplicated and only populated with directories that
  # actually exist on disk so the engine doesn't add bogus entries to
  # the action's env vars.
  # M9.R.14f.1 — pass ``root`` so the transitive walk knows where to
  # look up sibling recipes. Without an explicit root the walk uses
  # ``parentDir(absolutePath(recipeDir))``, which is correct in
  # production (where ``recipeDir = <root>/<name>``) but the tests'
  # ``REPRO_FROM_SOURCE_ROOT`` override pattern wants the explicit form.
  populateFromSourceSearchPaths(profile, recipeDir, root)

  profile.probes = collectConfiguredProbes(absolute,
    useDef.packageSelector, useDef.executableName)
  profile.profileFingerprint = profileFingerprintFor(profile)
  FromSourceResolveResult(kind: rrResolved, profile: profile)

proc resolveFromSourceTool*(useDef: InterfaceToolUse;
                            recipeRoot = ""): PathOnlyToolProfile =
  ## M9.Q resolver entry point. ``useDef.executableName`` drives the
  ## sibling recipe lookup: the convention is that a tool ``foo`` is
  ## built from ``recipes/packages/source/foo/`` and the resulting
  ## binary is at ``.repro/output/foo/foo``.
  ##
  ## The recipe package is conventionally named ``<name>Source`` (e.g.
  ## ``mesonSource``), but the from-source-custom convention's
  ## stage-copy step is keyed off the ``executable <name>:`` member,
  ## NOT the package name — so the resolver uses ``executableName``
  ## (e.g. ``meson``) for the directory layout too.
  ##
  ## DSL-port M9.R.9 — this entry point now delegates to
  ## ``tryResolveFromSourceTool`` and raises ``OSError`` for the
  ## ``rrNeedsBuild`` / ``rrSiblingMissing`` outcomes so existing
  ## call-sites (and the M9.Q acceptance test) keep their raise
  ## contract. New dispatchers that want auto-recurse + stdlib
  ## fall-through should call ``tryResolveFromSourceTool`` directly.
  let outcome = tryResolveFromSourceTool(useDef, recipeRoot)
  case outcome.kind
  of rrResolved:
    result = outcome.profile
  of rrSiblingMissing:
    raise newException(OSError,
      "tool-resolution failed: --tool-provisioning=from-source requested " &
      "for \"" & outcome.missingToolName & "\" (package \"" &
      useDef.packageSelector & "\") but no sibling recipe at " &
      outcome.attemptedRecipeManifest &
      ". Provide a from-source recipe or pick a different " &
      "--tool-provisioning mode (path|nix|tarball|scoop).")
  of rrNeedsBuild:
    raise newException(OSError,
      "tool-resolution failed: --tool-provisioning=from-source requested " &
      "for \"" & outcome.toolName & "\" but its sibling recipe at " &
      outcome.recipeDir &
      " has not produced an artefact at " & outcome.expectedArtifact &
      " (or .exe). Build the recipe first: `repro build " &
      outcome.recipeDir & " --no-runquota` (M9.Q.1 follow-up will auto-recurse).")

proc tryResolveStdlibProvisioning*(useDef: InterfaceToolUse;
                                  storeRoot: string;
                                  profile: var PathOnlyToolProfile): bool =
  ## DSL-port M9.R.10a — shared stdlib fall-through helper. Walks the
  ## host-preference order (nix on Nix-capable hosts → scoop on Windows →
  ## tarball anywhere) against whatever provisioning channels the
  ## ``useDef`` carries from the stdlib ``package <name>:`` block.
  ##
  ## Returns ``true`` and fills ``profile`` when one of the channels
  ## resolves; ``false`` when no channel is declared on the use. The
  ## individual channel resolvers may themselves raise ``OSError`` —
  ## those propagate to the caller because they indicate a declared
  ## channel that failed to resolve at run time (not a missing channel).
  ##
  ## Used by:
  ##   * ``toolProfileFor(tpmFromSource, ...)`` for the ``rrSiblingMissing``
  ##     outcome (M9.R.9 fall-through).
  ##   * The dispatcher-side cycle break in ``executeBuildTarget``
  ##     (M9.R.10a) — when an auto-recurse cycle is detected we route
  ##     the closing-edge tool through stdlib provisioning instead of
  ##     raising, breaking the cycle without sacrificing from-source
  ##     semantics for the rest of the graph.
  const isNixHost = defined(linux) or defined(macosx)
  if isNixHost and useDef.nixProvisioning.len > 0:
    profile = resolveNixTool(useDef, storeRoot)
    return true
  if defined(windows) and useDef.scoopProvisioning.len > 0:
    profile = resolveScoopTool(useDef, storeRoot)
    return true
  if useDef.tarballProvisioning.len > 0:
    profile = resolveTarballTool(useDef, storeRoot)
    return true
  false

proc toolProfileFor(useDef: InterfaceToolUse; mode: ToolProvisioningMode;
                    pathValue, storeRoot: string): PathOnlyToolProfile =
  case mode
  of tpmPathOnly:
    # M7 (Windows reprobuild migration): when path-mode resolution
    # fails AND the use declares tarball provisioning metadata, fall
    # through to the tarball realizer. This keeps the project-wide
    # ``defaultToolProvisioning "path"`` posture for tools the host
    # already supplies (cargo / nim / git / ...) while letting
    # individual tools (e.g. ``python-dev``, ``uv``) opt into
    # engine-managed tarball materialisation simply by declaring a
    # ``tarball`` block in their stdlib package definition. The
    # fallback is silent when no tarball metadata exists — the path
    # resolver's original "not found in PATH" diagnostic propagates
    # unchanged.
    try:
      result = resolvePathOnlyTool(useDef, pathValue)
    except OSError:
      if hasHostTarballProvisioning(useDef):
        result = resolveTarballTool(useDef, storeRoot)
      elif (defined(linux) or defined(macosx)) and
          useDef.nixProvisioning.len > 0:
        # Some upstreams, such as Cap'n Proto, do not publish direct
        # Linux/macOS binary tarballs. In path mode, let Nix-capable
        # hosts use the package's pinned Nix channel instead of failing
        # on a tarball entry that only targets another OS.
        result = resolveNixTool(useDef, storeRoot)
      elif useDef.tarballProvisioning.len > 0:
        result = resolveTarballTool(useDef, storeRoot)
      else:
        raise
  of tpmNix:
    result = resolveNixTool(useDef, storeRoot)
  of tpmTarball:
    result = resolveTarballTool(useDef, storeRoot)
  of tpmScoop:
    result = resolveScoopTool(useDef, storeRoot)
  of tpmFromSource:
    # M9.Q: principled from-source provisioning. The resolver maps the
    # tool's ``executableName`` to a sibling recipe at
    # ``recipes/packages/source/<name>/`` and threads the artefact dir
    # into ``pathSearchList``.
    #
    # DSL-port M9.R.9 Part 2 — stdlib fall-through. When no sibling
    # source recipe exists, fall back to whatever provisioning channels
    # the ``useDef`` carries from the stdlib ``package <name>:`` block.
    # Order on each host: nix on Nix-capable hosts (Linux / macOS); then
    # scoop on Windows; then tarball anywhere. This makes
    # ``tpmFromSource`` pragmatic — "from-source for things we have
    # source recipes for; fall back to whatever the stdlib package
    # declares for things we don't" — so recipes that depend on tools
    # like python3 (no source recipe yet) still build under
    # ``--tool-provisioning=from-source``. The dispatcher upstream
    # handles the ``rrNeedsBuild`` outcome via recursive sub-build
    # before reaching this entry point, so we never observe it here
    # in the normal path (and surface a clean OSError if we do, with
    # the M9.Q operator hint preserved).
    #
    # DSL-port M9.R.10a — cycle-break override. The auto-recurse
    # dispatcher (``executeBuildTarget``) marks the closing-edge tool of
    # a recursion cycle in ``fromSourceCycleBrokenTools`` and falls
    # through to the stdlib provisioning channels HERE instead of
    # raising a cycle diagnostic. Bootstrap tools (gcc, binutils, make,
    # autoconf, automake, libtool, pkg-config) thereby come from stdlib
    # provisioning at cycle-break time; everything else still builds
    # from source. When the stdlib has NO provisioning the cycle is
    # genuinely unrecoverable and we surface the original diagnostic.
    if useDef.executableName.len > 0 and
        useDef.executableName in fromSourceCycleBrokenTools:
      var fallProfile: PathOnlyToolProfile
      if tryResolveStdlibProvisioning(useDef, storeRoot, fallProfile):
        result = fallProfile
        return
      raise newException(OSError,
        "tool-resolution failed: --tool-provisioning=from-source " &
        "auto-recurse detected a cycle for \"" & useDef.executableName &
        "\" (package \"" & useDef.packageSelector & "\") and attempted " &
        "the stdlib fall-through, but no provisioning channel " &
        "(nix / scoop / tarball) is declared on the tool use. Declare a " &
        "provisioning block in the stdlib package definition for \"" &
        useDef.executableName & "\" OR break the cycle by editing one " &
        "of the recipes' nativeBuildDeps lists.")
    let outcome = tryResolveFromSourceTool(useDef)
    case outcome.kind
    of rrResolved:
      result = outcome.profile
    of rrNeedsBuild:
      raise newException(OSError,
        "tool-resolution failed: --tool-provisioning=from-source requested " &
        "for \"" & outcome.toolName & "\" but its sibling recipe at " &
        outcome.recipeDir &
        " has not produced an artefact at " & outcome.expectedArtifact &
        " (or .exe). Build the recipe first: `repro build " &
        outcome.recipeDir & " --no-runquota` (M9.R.9 auto-recurse " &
        "did not pre-build it — recursion may be guarded against a cycle).")
    of rrSiblingMissing:
      var fallProfile: PathOnlyToolProfile
      if tryResolveStdlibProvisioning(useDef, storeRoot, fallProfile):
        result = fallProfile
      else:
        raise newException(OSError,
          "tool-resolution failed: --tool-provisioning=from-source requested " &
          "for \"" & outcome.missingToolName & "\" (package \"" &
          useDef.packageSelector & "\") but no sibling recipe at " &
          outcome.attemptedRecipeManifest &
          " and no stdlib provisioning channel (nix / scoop / tarball) " &
          "declared on the tool use. Either add a recipe at " &
          "recipes/packages/source/" & outcome.missingToolName &
          "/ or declare a provisioning block in the stdlib package " &
          "definition.")
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
    scoopJunctionTarget: profile.scoopJunctionTarget,
    # M9.R.14e.1 — carry the from-source resolver's search-path channels
    # through to the per-action identity so the CLI's tool-identity
    # resolver projection can hand them to the engine at action-launch
    # time. Inert for non-from-source profiles (they leave the seqs
    # empty).
    pkgConfigSearchList: profile.pkgConfigSearchList,
    cmakePrefixList: profile.cmakePrefixList,
    cpathList: profile.cpathList,
    libraryPathList: profile.libraryPathList)
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
  # M9.R.14e.1 — search-path channels (v7+). Emitted AFTER the v6
  # scoop block so older readers (which stop at the scoop tail) still
  # parse the artifact's prefix unchanged.
  outp.writeStringSeq(profile.pkgConfigSearchList)
  outp.writeStringSeq(profile.cmakePrefixList)
  outp.writeStringSeq(profile.cpathList)
  outp.writeStringSeq(profile.libraryPathList)
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
  if version >= 7'u16:
    # M9.R.14e.1 — search-path channels. Older artifacts (v < 7) leave
    # the four seqs empty, which is the correct "no contribution" signal
    # for the engine's env-thread pass downstream.
    result.pkgConfigSearchList = readStringSeq(bytes, pos)
    result.cmakePrefixList = readStringSeq(bytes, pos)
    result.cpathList = readStringSeq(bytes, pos)
    result.libraryPathList = readStringSeq(bytes, pos)
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
  # M9.R.14e.1 — search-path channels (v7+). Same trailing-extension
  # discipline as ``writeProfile`` — older readers stop at the v6
  # scoop tail and miss the new seqs, but their parse of the prefix is
  # unaffected.
  outp.writeStringSeq(identity.pkgConfigSearchList)
  outp.writeStringSeq(identity.cmakePrefixList)
  outp.writeStringSeq(identity.cpathList)
  outp.writeStringSeq(identity.libraryPathList)

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
  if version >= 7'u16:
    # M9.R.14e.1 — search-path channels. Older artifacts (v < 7) leave
    # the four seqs empty.
    result.pkgConfigSearchList = readStringSeq(bytes, pos)
    result.cmakePrefixList = readStringSeq(bytes, pos)
    result.cpathList = readStringSeq(bytes, pos)
    result.libraryPathList = readStringSeq(bytes, pos)

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
    "pkgConfigSearchList": profile.pkgConfigSearchList,
    "cmakePrefixList": profile.cmakePrefixList,
    "cpathList": profile.cpathList,
    "libraryPathList": profile.libraryPathList,
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
    "pkgConfigSearchList": identity.pkgConfigSearchList,
    "cmakePrefixList": identity.cmakePrefixList,
    "cpathList": identity.cpathList,
    "libraryPathList": identity.libraryPathList,
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

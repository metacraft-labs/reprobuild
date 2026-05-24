import std/[algorithm, json, options, os, osproc, sequtils, sets, streams,
    strutils, tables, terminal, times]
import repro_core
import repro_build_engine
import repro_dev_env_activation
import repro_depfile
import repro_dev_env_artifacts
import repro_dev_env_engine
import repro_interface_artifacts
import repro_monitor_depfile/fs_snoop
import repro_provider_runtime
import repro_project_dsl
import repro_runquota
import repro_hash
import repro_tool_profiles
import repro_local_store
import repro_launch_plan
import repro_hcr_agent
import repro_hcr_linkgraph
import repro_elevation
import repro_cli_support/watch
import repro_cli_support/dev_session
import repro_cli_support/home
import repro_cli_support/infra
import repro_home_resources/drivers/managed_block

export home.runHomeCommand, home.setPackageCatalogLookup,
       home.PackageCatalogLookup, home.CatalogEnvVar,
       home.ConfigurableSchemaEnvVar
export infra.runInfraCommand, infra.runSystemCommand

proc wantsVersion*(args: openArray[string]): bool =
  args.len == 1 and args[0] in ["--version", "-V"]

proc renderVersion*(programName: string): string =
  programName & " " & versionString()

proc renderUsage*(programName: string): string =
  if programName == "repro":
    programName & " " & versionString() & "\nusage: " & programName &
      " --version\n       " & programName &
      " capabilities [--format=json|text]\n       " & programName &
      " build [target[#name]] --tool-provisioning=path|nix|tarball|scoop [--work-root=PATH] [--progress=auto|plain|none] [--stats[=text|none]] [--report=full|none] [--log=actions|summary|quiet] [--prepare-only] [--no-runquota]\n       " &
          programName &
      " exec [selector] [--activity=name] [--dev-env-stats=PATH] -- <command> [args...]\n       " &
          programName &
      " shell [selector] [--activity=name] [--print-env=posix|fish|powershell|json] [--dev-env-stats=PATH]\n       " &
          programName &
      " up [selector] [--activity=name] [--foreground] [--http=HOST:PORT]\n       " &
          programName &
      " down [selector] [--activity=name] [--force]\n       " &
          programName &
      " dev [selector] [--activity=name] [--foreground] [--http=HOST:PORT] [--debounce-ms=N]\n       " &
          programName &
      " hooks ensure|reinstall|uninstall [--vcs] [--shell-direnv] [--shell bash|zsh|fish|powershell] [path]\n       " &
          programName &
      " watch [target[#name]] --tool-provisioning=path|nix|tarball|scoop [--work-root=PATH] [--max-cycles=N] [--debounce-ms=N] [--hcr-agent-socket=PATH --hcr-artifacts=PATH [--hcr-metadata=PATH]]\n       " &
          programName &
      " hcr coordinate --project PATH --target NAME --socket PATH --source-edit-driver PATH --artifacts PATH\n       " &
          programName &
      " hcr prepare-object --input PATH --output PATH (--function NAME|--all-code) [--segment NAME]\n       " &
          programName &
      " develop --list\n       " &
          programName &
      " develop <dependency> --into=PATH\n       " &
          programName &
      " develop <target[#name]> --tool-provisioning=path|nix|tarball|scoop [--work-root=PATH] -- <command> [args...]\n       " &
          programName &
      " develop --cmake <source-dir> --tool-provisioning=path|nix [--cmake-binary=PATH] [--work-root=PATH] -- <command> [args...]\n       " &
          programName &
      " debug fs-snoop [inspect <depfile> | [options] -- <command> [args...]]"
  elif programName == "repro-fs-snoop":
    programName & " " & versionString() & "\nusage: " & programName &
      " [options] -- <command> [args...]\n       " & programName &
      " inspect <depfile> --format text|json"
  else:
    programName & " " & versionString() & "\nusage: " & programName & " --version"

proc parseToolProvisioning(value: string): ToolProvisioningMode =
  case value
  of "path":
    tpmPathOnly
  of "nix":
    tpmNix
  of "tarball":
    tpmTarball
  of "scoop":
    tpmScoop
  else:
    raise newException(ValueError, "unsupported --tool-provisioning=" & value)

proc bytesOf(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc digestHex(digest: ContentDigest): string =
  toHex(digest.bytes)

proc safePathSegment(value, fallback: string): string =
  for ch in value:
    if ch in {'a' .. 'z'} or ch in {'A' .. 'Z'} or ch in {'0' .. '9'} or
        ch in {'-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = fallback

proc configuredWorkRoot(explicitRoot: string): string =
  if explicitRoot.len > 0:
    return explicitRoot
  getEnv("REPROBUILD_WORK_ROOT")

proc splitTarget(target: string): tuple[base: string; fragment: string] =
  let marker = target.find('#')
  if marker < 0:
    (base: target, fragment: "")
  else:
    (base: target[0 ..< marker], fragment: target[marker + 1 .. ^1])

type
  TargetFragmentKind = enum
    tfkNone
    tfkModule
    tfkActionSelection

  ParsedBuildTarget = object
    modulePath: string
    outputName: string
    selectedActionId: string
    fragmentKind: TargetFragmentKind

proc parseBuildTarget(target: string): ParsedBuildTarget =
  let parts = splitTarget(target)
  if parts.fragment.len > 0:
    if dirExists(extendedPath(parts.base)):
      let fragmentModule = parts.base / (parts.fragment & ".nim")
      if fileExists(extendedPath(fragmentModule)):
        return ParsedBuildTarget(
          modulePath: fragmentModule,
          outputName: parts.fragment,
          fragmentKind: tfkModule)
      let rootModule = parts.base / "reprobuild.nim"
      if fileExists(extendedPath(rootModule)):
        return ParsedBuildTarget(
          modulePath: rootModule,
          outputName: splitFile(rootModule).name,
          selectedActionId: parts.fragment,
          fragmentKind: tfkActionSelection)
      return ParsedBuildTarget(
        modulePath: fragmentModule,
        outputName: parts.fragment,
        fragmentKind: tfkModule)
    return ParsedBuildTarget(
      modulePath: parts.base,
      outputName: parts.fragment,
      fragmentKind: tfkModule)

  let modulePath =
    if dirExists(extendedPath(parts.base)):
      parts.base / "reprobuild.nim"
    else:
      parts.base
  ParsedBuildTarget(
    modulePath: modulePath,
    outputName: splitFile(modulePath).name,
    fragmentKind: tfkNone)

proc moduleForTarget(target: string): string =
  parseBuildTarget(target).modulePath

proc scopedWorktreeRoot(modulePath, explicitWorkRoot: string): string =
  let workRoot = configuredWorkRoot(explicitWorkRoot)
  if workRoot.len == 0:
    return ""
  let base =
    if workRoot.isAbsolute:
      os.normalizedPath(workRoot)
    else:
      os.normalizedPath(absolutePath(workRoot))
  let projectRoot = os.normalizedPath(parentDir(absolutePath(modulePath)))
  let (_, tail) = splitPath(projectRoot)
  let hash = digestHex(blake3DomainDigest(projectRoot.bytesOf(),
    hdMetadataEnvelope))
  # The worktree dir name combines the project tail (for debuggability)
  # and a 16-char content-hash (for identity). When the resulting full
  # path approaches Windows' MAX_PATH (260 chars) the host's underlying
  # tools — notably nim's own stdlib used by the provider compile —
  # fail with ERROR_FILENAME_EXCED_RANGE since they don't transparently
  # prefix `\\?\` for every OS call. Detect that and fall back to the
  # bare hash; we lose a small amount of debuggability but the build
  # stays correct. The threshold leaves room for the tail of the path
  # the engine adds inside the worktree
  # (`/build/<outputName>/provider/project-provider.exe` ≈ 60 chars).
  const reservedTailChars = 80
  let tailSegment = safePathSegment(tail, "worktree")
  let combined = tailSegment & "-" & hash[0 .. 15]
  let baseLen = base.len + "/worktrees/".len
  let segment =
    if baseLen + combined.len + reservedTailChars > 260:
      hash[0 .. 15]
    else:
      combined
  base / "worktrees" / segment

proc outputDirForTarget(target: ParsedBuildTarget;
    explicitWorkRoot = ""): string =
  let scopedRoot = scopedWorktreeRoot(target.modulePath, explicitWorkRoot)
  if scopedRoot.len > 0:
    return scopedRoot / "build" / target.outputName
  parentDir(target.modulePath) / ".repro" / "build" / target.outputName

const DefaultBuildActionMetadataName = "reprobuild.default-build-action.v1"

proc q(value: string): string =
  quoteShell(value)

proc shellCommand(args: openArray[string]): string =
  args.mapIt(q(it)).join(" ")

proc projectRootForModule(modulePath: string): string =
  parentDir(modulePath)

type
  CmakeRegenerationMetadata = object
    enabled: bool
    suppressed: bool
    metadataFile: string
    sourceDir: string
    binaryDir: string
    providerRoot: string
    cmakeCommand: string
    checkFile: string
    globVerifyScript: string
    providerFile: string
    providerStateFile: string
    values: Table[string, string]

proc readKeyValueMetadata(path: string): Table[string, string] =
  if path.len == 0 or not fileExists(extendedPath(path)):
    return
  for rawLine in readFile(extendedPath(path)).splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    let eq = line.find('=')
    if eq <= 0:
      continue
    result[line[0 ..< eq]] = line[eq + 1 .. ^1]

proc metadataValue(values: Table[string, string]; key: string;
                   fallback = ""): string =
  values.getOrDefault(key, fallback)

proc metadataFlag(values: Table[string, string]; key: string): bool =
  case values.getOrDefault(key, "").toLowerAscii()
  of "1", "on", "true", "yes", "enabled":
    true
  else:
    false

proc materializeCmakePath(meta: CmakeRegenerationMetadata;
                          path: string): string =
  if path.len == 0:
    return ""
  if path.isAbsolute:
    os.normalizedPath(path)
  else:
    os.normalizedPath(meta.binaryDir / path)

proc parseCmakeQuotedList(text, setName: string): seq[string] =
  var parsed: seq[string] = @[]
  var inSet = false
  var token = ""
  var inQuote = false
  var escaping = false

  proc finishToken() =
    if token.len > 0:
      parsed.add(token)
      token.setLen(0)

  for rawLine in text.splitLines():
    var line = rawLine.strip()
    if not inSet:
      if line == "set(" & setName:
        inSet = true
        continue
      if line.startsWith("set(" & setName & " "):
        inSet = true
        line = line.substr(("set(" & setName).len).strip()
      else:
        continue

    var i = 0
    while i < line.len:
      let ch = line[i]
      if inQuote:
        if escaping:
          token.add(ch)
          escaping = false
        elif ch == '\\':
          escaping = true
        elif ch == '"':
          inQuote = false
          finishToken()
        else:
          token.add(ch)
      else:
        case ch
        of '"':
          inQuote = true
        of ')':
          finishToken()
          return parsed
        of ' ', '\t':
          finishToken()
        else:
          token.add(ch)
      inc i
    if not inQuote:
      finishToken()
  parsed

proc parseCmakeListFromFile(path, setName: string): seq[string] =
  if path.len == 0 or not fileExists(extendedPath(path)):
    return
  parseCmakeQuotedList(readFile(extendedPath(path)), setName)

proc addUniquePath(paths: var seq[string]; path: string) =
  if path.len == 0:
    return
  let normalized = os.normalizedPath(path)
  if paths.find(normalized) < 0:
    paths.add(normalized)

proc cmakeRegenerationMetadataForModule(modulePath: string):
    CmakeRegenerationMetadata =
  let binaryDir = parentDir(modulePath)
  let metadataFile = binaryDir / "CMakeFiles" / "reprobuild" / "provider.meta"
  let values = readKeyValueMetadata(metadataFile)
  if values.len == 0 or values.metadataValue("generator") != "Reprobuild":
    return
  let sourceDir = values.metadataValue("source_dir")
  if sourceDir.len == 0:
    return
  result.values = values
  result.metadataFile = metadataFile
  result.sourceDir = os.normalizedPath(sourceDir)
  result.binaryDir = os.normalizedPath(values.metadataValue("binary_dir",
    binaryDir))
  result.providerRoot = os.normalizedPath(values.metadataValue("provider_root",
    result.binaryDir / "CMakeFiles" / "reprobuild"))
  result.cmakeCommand = values.metadataValue("cmake_command", "cmake")
  result.checkFile = values.metadataValue("cmake_regeneration_check_file",
    "CMakeFiles/Makefile.cmake")
  result.globVerifyScript = values.metadataValue(
    "cmake_regeneration_glob_verify",
    result.binaryDir / "CMakeFiles" / "VerifyGlobs.cmake")
  result.providerFile = values.metadataValue("cmake_regeneration_provider_file",
    result.binaryDir / "reprobuild.nim")
  result.providerStateFile = values.metadataValue(
    "cmake_regeneration_provider_state",
    result.providerRoot / "provider.last")
  result.suppressed = values.metadataFlag("cmake_regeneration_suppressed")
  result.enabled =
    not result.suppressed and
    values.metadataValue("cmake_regeneration", "enabled") != "disabled"

proc cmakeRegenerationInputs(meta: CmakeRegenerationMetadata;
                             publicCliPath: string): seq[string] =
  result.addUniquePath(meta.metadataFile)
  if publicCliPath.len > 0 and fileExists(extendedPath(publicCliPath)):
    result.addUniquePath(publicCliPath)
  if meta.cmakeCommand.isAbsolute and fileExists(extendedPath(meta.cmakeCommand)):
    result.addUniquePath(meta.cmakeCommand)
  let checkPath = meta.materializeCmakePath(meta.checkFile)
  result.addUniquePath(checkPath)
  result.addUniquePath(meta.binaryDir / "CMakeCache.txt")
  result.addUniquePath(meta.binaryDir / "CMakeFiles" / "cmake.check_cache")
  if meta.globVerifyScript.len > 0 and fileExists(extendedPath(meta.globVerifyScript)):
    result.addUniquePath(meta.globVerifyScript)
  for input in parseCmakeListFromFile(checkPath, "CMAKE_MAKEFILE_DEPENDS"):
    result.addUniquePath(meta.materializeCmakePath(input))

proc cmakeRegenerationHasGlobVerification(meta: CmakeRegenerationMetadata): bool =
  meta.globVerifyScript.len > 0 and fileExists(extendedPath(meta.globVerifyScript))

proc cmakeRegenerationOutputs(meta: CmakeRegenerationMetadata): seq[string] =
  result.addUniquePath(meta.providerFile)
  result.addUniquePath(meta.providerStateFile)
  if meta.cmakeRegenerationHasGlobVerification():
    # CMake's VerifyGlobs.cmake detects directory membership changes by
    # touching an empty marker. The action cache is content-based, so glob
    # projects must execute this edge until glob membership evidence is modeled.
    result.addUniquePath(meta.providerRoot /
      "cmake-regeneration-glob-always-run.sentinel")
  for key, value in meta.values:
    if key == "clean_manifest" or key.startsWith("clean_manifest_") or
        key == "hcr_metadata":
      result.addUniquePath(value)

proc addCmakeFingerprintField(payload: var string; value: string) =
  payload.add($value.len)
  payload.add(":")
  payload.add(value)
  payload.add("\n")

proc cmakeRegenerationFingerprint(meta: CmakeRegenerationMetadata;
                                  publicCliPath: string):
    ContentDigest =
  var payload = ""
  payload.addCmakeFingerprintField("reprobuild.cmake.regeneration.v1")
  payload.addCmakeFingerprintField(publicCliPath)
  payload.addCmakeFingerprintField(meta.cmakeCommand)
  payload.addCmakeFingerprintField(meta.sourceDir)
  payload.addCmakeFingerprintField(meta.binaryDir)
  payload.addCmakeFingerprintField(meta.checkFile)
  payload.addCmakeFingerprintField(meta.globVerifyScript)
  payload.addCmakeFingerprintField(meta.providerFile)
  payload.addCmakeFingerprintField(meta.providerStateFile)
  weakFingerprintFromText(payload)

proc cmakeRegenerationBuildAction(meta: CmakeRegenerationMetadata;
                                  publicCliPath: string): BuildAction =
  var env: seq[string] = @[]
  if meta.providerRoot.len > 0:
    let wrapperPath = meta.values.metadataValue("wrapper_path",
      meta.providerRoot / "bin")
    if wrapperPath.len > 0:
      env.add("PATH=" & wrapperPath & $PathSep & getEnv("PATH"))
  let sourceRoot = getEnv("REPROBUILD_SOURCE_ROOT")
  if sourceRoot.len > 0:
    env.add("REPROBUILD_SOURCE_ROOT=" & sourceRoot)
  let hasGlobVerification = meta.cmakeRegenerationHasGlobVerification()
  action("__repro_cmake_regenerate", @[
    publicCliPath,
    "__repro-cmake-regenerate",
    "--metadata", meta.metadataFile
  ],
    cwd = meta.binaryDir,
    inputs = cmakeRegenerationInputs(meta, publicCliPath),
    outputs = cmakeRegenerationOutputs(meta),
    commandStatsId = "repro cmake regeneration edge",
    cacheable = not hasGlobVerification,
    weakFingerprint = cmakeRegenerationFingerprint(meta, publicCliPath),
    dependencyPolicy = declaredOnlyPolicy(),
    env = env)

proc prependProcessPath(path: string) =
  if path.len == 0:
    return
  let normalized = os.normalizedPath(path)
  let current = getEnv("PATH")
  for item in current.split(PathSep):
    if item.len > 0 and os.normalizedPath(item) == normalized:
      return
  if current.len > 0:
    putEnv("PATH", normalized & $PathSep & current)
  else:
    putEnv("PATH", normalized)

proc applyCmakeProviderEnvironment(meta: CmakeRegenerationMetadata) =
  if meta.values.len == 0:
    return
  prependProcessPath(meta.values.metadataValue("wrapper_path",
    meta.providerRoot / "bin"))

proc reprobuildLibraryWorkDir(): string =
  proc hasReprobuildLibs(root: string): bool =
    dirExists(extendedPath(root / "libs" / "repro_project_dsl" / "src"))

  let envRoot = getEnv("REPROBUILD_SOURCE_ROOT")
  if envRoot.len > 0 and hasReprobuildLibs(envRoot):
    return envRoot
  let cwd = getCurrentDir()
  if hasReprobuildLibs(cwd):
    return cwd
  var sourceRoot = parentDir(currentSourcePath())
  for _ in 0 ..< 3:
    sourceRoot = parentDir(sourceRoot)
  if hasReprobuildLibs(sourceRoot):
    return sourceRoot
  cwd

proc moduleHasBuildBlock(modulePath: string): bool =
  for line in readFile(extendedPath(modulePath)).splitLines:
    if line.strip() == "build:":
      return true

proc materialProjectPath(projectRoot, path: string): string =
  if path.len == 0 or path.isAbsolute:
    path
  else:
    projectRoot / path

proc jsonStringSeq(values: openArray[string]): JsonNode =
  result = newJArray()
  for value in values:
    result.add(%value)

proc capabilitiesJson*(): JsonNode =
  var query = newJObject()
  query["command"] = %"repro capabilities"
  query["defaultFormat"] = %"json"
  query["formats"] = jsonStringSeq(["json", "text"])
  query["schemaId"] = %"reprobuild.capabilities.v1"

  var provider = newJObject()
  provider["metadataVersion"] = %3
  provider["generatedProviderKind"] = %"nim-source"
  provider["features"] = jsonStringSeq([
    "public-target-aliases",
    "default-target-metadata",
    "build-pool-metadata",
    "compile-commands",
    "declared-inputs-and-outputs",
    "depfile-dependency-evidence",
    "dyndep-fragment-conversion",
    "runquota-execution",
    "cmake-regeneration-edge",
    "provider-cache-priming",
    "build-report-json-inspection"])

  var hcrProfile = newJObject()
  hcrProfile["id"] = %"clang-gcc-debug-patchable-no-lto-v1"
  hcrProfile["status"] = %"prototype"
  hcrProfile["languages"] = jsonStringSeq(["C", "CXX"])
  hcrProfile["requires"] = jsonStringSeq([
    "debug-info",
    "patchable-function-entry",
    "relocatable-object-inputs",
    "source-object-link-relations",
    "linkgraph-evidence"])
  hcrProfile["rejects"] = jsonStringSeq([
    "lto",
    "interprocedural-optimization",
    "unsupported-asm-sources",
    "missing-debug-info"])
  var hcrProfiles = newJArray()
  hcrProfiles.add(hcrProfile)
  var codetracerProfile = newJObject()
  codetracerProfile["id"] = %"macos-arm64-direct-hcr-in-codetracer-v1"
  codetracerProfile["status"] = %"prototype"
  codetracerProfile["languages"] = jsonStringSeq(["C", "CXX"])
  codetracerProfile["requires"] = jsonStringSeq([
    "hcr-agent-protocol",
    "coordinator-agent-negotiation",
    "direct-patch-injection",
    "debug-object-payloads",
    "unwind-metadata-payloads",
    "source-generation-metadata",
    "codetracer-owned-launch",
    "mcr-recorded-agent-ipc"])
  codetracerProfile["features"] = jsonStringSeq([
    "hcr-agent-content-length-framing",
    "coordinator-agent-session-validation",
    "coordinator-direct-patch-request-packaging",
    "unix-domain-agent-ipc",
    "agent-socket-env-contract",
    "coordinator-report-json",
    "target-linked-c-agent-startup",
    "repro-hcr-coordinate-command",
    "codetracer-mcr-launch-bridge"])
  codetracerProfile["missingComponents"] = jsonStringSeq([])
  codetracerProfile["rejects"] = jsonStringSeq([
    "post-launch-attach",
    "same-process-direct-transaction-shortcut",
    "stdin-pipe-patch-substitute",
    "shared-library-positive-path",
    "coordinator-resend-during-replay",
    "disassembly-only-debugging"])
  hcrProfiles.add(codetracerProfile)

  var hcr = newJObject()
  hcr["decisionAuthority"] = %"reprobuild"
  hcr["buildSystemRole"] = %(
    "annotate candidate targets and static source/object/link relations")
  hcr["runtimeDecisions"] = jsonStringSeq([
    "rebuilt-actions",
    "changed-outputs",
    "affected-link-targets",
    "patchability",
    "reload-vs-restart"])
  hcr["candidateAnnotations"] = jsonStringSeq([
    "target-identity",
    "source-to-object-action",
    "object-to-link-action",
    "link-output",
    "linkgraph-action",
    "support-profile"])
  hcr["profiles"] = hcrProfiles

  var execution = newJObject()
  execution["scheduler"] = %"local"
  execution["runQuota"] = %"supported"
  execution["reports"] = jsonStringSeq(["build-report.json"])

  var interfaces = newJObject()
  interfaces["capabilityQuery"] = query
  interfaces["provider"] = provider
  interfaces["execution"] = execution
  interfaces["hcr"] = hcr

  result = newJObject()
  result["schemaId"] = %"reprobuild.capabilities.v1"
  result["reprobuildVersion"] = %versionString()
  result["host"] = %*{
    "os": hostOS,
    "cpu": hostCPU
  }
  result["interfaces"] = interfaces

proc renderCapabilitiesJson*(): string =
  capabilitiesJson().pretty()

proc renderCapabilitiesText*(): string =
  let caps = capabilitiesJson()
  "schemaId: " & caps["schemaId"].getStr() & "\n" &
    "reprobuildVersion: " & caps["reprobuildVersion"].getStr() & "\n" &
    "capabilityQuery: " &
      caps["interfaces"]["capabilityQuery"]["command"].getStr() & "\n" &
    "providerMetadataVersion: " &
      $caps["interfaces"]["provider"]["metadataVersion"].getInt() & "\n" &
    "hcrDecisionAuthority: " &
      caps["interfaces"]["hcr"]["decisionAuthority"].getStr()

proc runCapabilitiesCommand(args: openArray[string]): int =
  var format = "json"
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--help" or arg == "-h":
      echo "usage: repro capabilities [--format=json|text]"
      return 0
    elif arg == "--format":
      if i + 1 >= args.len:
        raise newException(ValueError, "--format requires json or text")
      format = args[i + 1]
      inc i
    elif arg.startsWith("--format="):
      format = arg["--format=".len .. ^1]
    else:
      raise newException(ValueError, "unsupported capabilities argument: " & arg)
    inc i

  case format
  of "json":
    echo renderCapabilitiesJson()
  of "text":
    echo renderCapabilitiesText()
  else:
    raise newException(ValueError, "unsupported --format=" & format)
  0

proc profileIndex(identity: PathOnlyBuildIdentity):
    Table[string, PathOnlyToolProfile] =
  for profile in identity.profiles:
    result[profile.packageSelector & "|" & profile.executableName] = profile
    if not result.hasKey(profile.executableName):
      result[profile.executableName] = profile

proc argvForCall(call: PublicCliCall; profile: PathOnlyToolProfile): seq[string] =
  result = @[profile.resolvedExecutablePath]

  proc encodedValues(arg: PublicCliArg): seq[string] =
    if arg.nimType.normalize == "seq[string]":
      if arg.encodedValue.len > 0:
        for item in arg.encodedValue.split("\x1f"):
          result.add(item)
    else:
      result.add(arg.encodedValue)

  proc addFormattedValue(outp: var seq[string]; flagName, value: string;
                         format: CliArgFormat) =
    case format
    of cafSeparate:
      outp.add(flagName)
      outp.add(value)
    of cafConcat:
      outp.add(flagName & value)
    of cafEquals:
      outp.add(flagName & "=" & value)

  proc addFlagArg(outp: var seq[string]; arg: PublicCliArg) =
    let flagName =
      if arg.alias.len > 0:
        arg.alias
      else:
        "--" & arg.name
    if arg.nimType.normalize == "bool":
      if arg.encodedValue.normalize == "true":
        outp.add(flagName)
      return
    let values = encodedValues(arg)
    if values.len == 0:
      return
    if arg.format == cafSeparate and not arg.repeated:
      outp.add(flagName)
      for value in values:
        outp.add(value)
    else:
      for value in values:
        outp.addFormattedValue(flagName, value, arg.format)

  proc addPositionalArg(outp: var seq[string]; arg: PublicCliArg) =
    for value in encodedValues(arg):
      outp.add(value)

  var beforeSubcommand: seq[PublicCliArg] = @[]
  var afterSubcommand: seq[PublicCliArg] = @[]
  var positional: seq[PublicCliArg] = @[]
  for arg in call.arguments:
    if arg.kind == cpkPositional:
      positional.add(arg)
      continue
    if arg.placement == capBeforeSubcommand:
      beforeSubcommand.add(arg)
    else:
      afterSubcommand.add(arg)

  for arg in beforeSubcommand:
    result.addFlagArg(arg)
  if call.subcommand.len > 0:
    result.add(call.subcommand)
  for arg in afterSubcommand:
    result.addFlagArg(arg)

  positional.sort do (a, b: PublicCliArg) -> int:
    cmp(a.position, b.position)
  for arg in positional:
    result.addPositionalArg(arg)

proc depfilePolicy(depfile: string): DependencyGatheringPolicy =
  if depfile.len == 0:
    return repro_core.declaredOnlyPolicy()
  DependencyGatheringPolicy(
    kind: dgRecognizedFormat,
    completeness: decComplete,
    recognizedReports: @[
      RecognizedDependencyReportSpec(
        formatName: DependencyFormatName(MakeDepfileFormatName),
        outputs: @[ExpectedDependencyFile(
          logicalName: "deps",
          path: depfile,
          required: true)],
        completeness: decComplete)
    ])

proc lowerDependencyPolicy(actionId, depfile: string;
                           policy: BuildActionDependencyPolicy):
    DependencyGatheringPolicy =
  case policy.kind
  of bdpDefault:
    depfilePolicy(depfile)
  of bdpDeclaredOnly:
    repro_core.declaredOnlyPolicy()
  of bdpAutomaticMonitor:
    if depfile.len > 0:
      raise newException(ValueError,
        "action " & actionId & " supplies legacy depfile and " &
          "automatic monitor dependencyPolicy; remove depfile or use " &
          "makeDepfilePolicy")
    DependencyGatheringPolicy(kind: dgAutomaticMonitor,
        completeness: decComplete)
  of bdpMakeDepfile:
    let selectedDepfile =
      if policy.depfile.len > 0:
        policy.depfile
      else:
        depfile
    if selectedDepfile.len == 0:
      raise newException(ValueError,
        "action " & actionId & " uses makeDepfilePolicy without a depfile path")
    if depfile.len > 0 and policy.depfile.len > 0 and depfile != policy.depfile:
      raise newException(ValueError,
        "action " & actionId & " supplies conflicting depfile paths: " &
          depfile & " and " & policy.depfile)
    depfilePolicy(selectedDepfile)

proc lowerGraphAction(node: GraphNode; profiles: Table[string, PathOnlyToolProfile];
                      projectRoot: string): BuildAction =
  let payload = decodeBuildActionPayload(toBytes(node.payload))
  let actionCachePolicy =
    case payload.actionCachePolicy
    of acfpTimestamp:
      ffpTimestamp
    of acfpChecksum:
      ffpChecksum
    of acfpHybrid:
      ffpHybrid
  proc argValue(name: string): string =
    for arg in payload.call.arguments:
      if arg.name == name:
        return arg.encodedValue
    ""

  proc argSeqValue(name: string): seq[string] =
    let encoded = argValue(name)
    if encoded.len == 0:
      return @[]
    encoded.split("\x1f")

  if payload.call.packageName == "reprobuild.builtin" and
      payload.call.executableName == "exec":
    # Inline-exec builtin: the call carries a literal argv (and optional cwd)
    # and the action is launched directly via the engine's process action
    # without any package-profile lookup. The wrapper layer is bypassed
    # entirely; the binary graph cache holds the resolved argv.
    let argv = argSeqValue("argv")
    if argv.len == 0:
      raise newException(ValueError,
        "reprobuild.builtin.exec action " & payload.id &
          " has empty argv")
    let cwdValue = argValue("cwd")
    let commandStatsId =
      if payload.commandStatsId.len > 0:
        payload.commandStatsId
      else:
        payload.id
    let fingerprintText = [
      "reprobuild.localInlineExecAction.v1",
      payload.id,
      node.payload
    ].join("\n")
    return repro_build_engine.action(
      payload.id,
      argv,
      cwd =
        if cwdValue.len > 0: cwdValue
        else: projectRoot,
      deps = payload.deps,
      inputs = payload.inputs.mapIt(materialProjectPath(projectRoot, it)),
      outputs = payload.outputs,
      pool = payload.pool,
      poolUnits = payload.poolUnits,
      depfile = payload.depfile,
      dynamicDepsFile = payload.dynamicDepsFile,
      cacheable = payload.cacheable,
      weakFingerprint = weakFingerprintFromText(fingerprintText),
      actionCachePolicy = actionCachePolicy,
      dependencyPolicy = lowerDependencyPolicy(payload.id, payload.depfile,
        payload.dependencyPolicy),
      commandStatsId = commandStatsId)

  if payload.call.packageName == "reprobuild.builtin" and
      payload.call.executableName == "fs":
    let commandStatsId =
      if payload.commandStatsId.len > 0:
        payload.commandStatsId
      else:
        payload.id
    let fingerprintText = [
      "reprobuild.localBuiltinAction.v1",
      payload.id,
      payload.call.subcommand,
      node.payload
    ].join("\n")
    let kind =
      case payload.call.subcommand
      of "copyFile": bakCopyFile
      of "ensureDir": bakEnsureDir
      of "writeText": bakWriteText
      of "stamp": bakStamp
      of "preserveTree": bakPreserveTree
      else:
        raise newException(ValueError,
          "unknown built-in fs operation: " & payload.call.subcommand)
    return repro_build_engine.builtinAction(
      kind,
      payload.id,
      cwd = projectRoot,
      deps = payload.deps,
      inputs = payload.inputs.mapIt(materialProjectPath(projectRoot, it)),
      outputs = payload.outputs,
      commandStatsId = commandStatsId,
      cacheable = payload.cacheable,
      weakFingerprint = weakFingerprintFromText(fingerprintText),
      actionCachePolicy = actionCachePolicy,
      text = if payload.call.subcommand == "preserveTree":
          argValue("sourceRoot") & "\n" & argValue("outputRoot")
        else:
          argValue("text") & argValue("title"),
      entries = argSeqValue("entries"))

  if payload.call.packageName == "reprobuild.builtin" and
      payload.call.executableName == "hcr":
    if payload.call.subcommand != "prepareObject":
      raise newException(ValueError,
        "unknown built-in HCR operation: " & payload.call.subcommand)
    let commandStatsId =
      if payload.commandStatsId.len > 0:
        payload.commandStatsId
      else:
        payload.id
    let fingerprintText = [
      "reprobuild.localBuiltinHcrAction.v1",
      payload.id,
      payload.call.subcommand,
      node.payload
    ].join("\n")
    var argv = @[
      getAppFilename(), "hcr", "prepare-object",
      "--input", argValue("input"),
      "--output", argValue("output"),
      "--segment", argValue("segment")
    ]
    let functionName = argValue("function")
    if functionName.len > 0:
      argv.add "--function"
      argv.add functionName
    else:
      argv.add "--all-code"
    var inputs: seq[string] = @[]
    for input in payload.inputs:
      inputs.add(materialProjectPath(projectRoot, input))
    return repro_build_engine.action(
      payload.id,
      argv,
      cwd = projectRoot,
      deps = payload.deps,
      inputs = inputs,
      outputs = payload.outputs,
      pool = payload.pool,
      poolUnits = payload.poolUnits,
      depfile = payload.depfile,
      dynamicDepsFile = payload.dynamicDepsFile,
      cacheable = payload.cacheable,
      weakFingerprint = weakFingerprintFromText(fingerprintText),
      actionCachePolicy = actionCachePolicy,
      dependencyPolicy = lowerDependencyPolicy(payload.id, payload.depfile,
        payload.dependencyPolicy),
      commandStatsId = commandStatsId)

  let executableName = payload.call.executableName
  let packageName = payload.call.packageName
  let exactKey = packageName & "|" & executableName
  let profile =
    if profiles.hasKey(exactKey):
      profiles[exactKey]
    elif profiles.hasKey(executableName):
      profiles[executableName]
    else:
      raise newException(ValueError,
        "tool-resolution failed: action " & payload.id &
          " references executable " & executableName &
          " but no tool profile was resolved for it")
  var inputs: seq[string] = @[]
  for input in payload.inputs:
    inputs.add(materialProjectPath(projectRoot, input))
  let outputs = payload.outputs
  let depfile = payload.depfile
  let commandStatsId =
    if payload.commandStatsId.len > 0:
      payload.commandStatsId
    else:
      payload.id
  let fingerprintText = [
    "reprobuild.localProjectAction.v1",
    payload.id,
    payload.call.packageName,
    executableName,
    payload.call.subcommand,
    node.payload,
    digestHex(profile.profileFingerprint)
  ].join("\n")
  repro_build_engine.action(
    payload.id,
    argvForCall(payload.call, profile),
    cwd = projectRoot,
    deps = payload.deps,
    inputs = inputs,
    outputs = outputs,
    pool = payload.pool,
    poolUnits = payload.poolUnits,
    depfile = depfile,
    dynamicDepsFile = payload.dynamicDepsFile,
    cacheable = payload.cacheable,
    weakFingerprint = weakFingerprintFromText(fingerprintText),
    actionCachePolicy = actionCachePolicy,
    dependencyPolicy = lowerDependencyPolicy(payload.id, depfile,
      payload.dependencyPolicy),
    commandStatsId = commandStatsId)

proc lowerProviderSnapshot(snapshot: ProviderGraphSnapshot;
                           identity: PathOnlyBuildIdentity;
                           projectRoot: string;
                           selectedActionId = ""):
    tuple[actions: seq[BuildAction]; pools: seq[BuildPool]] =
  let profiles = profileIndex(identity)
  var actionNodes: seq[tuple[node: GraphNode; payload: BuildActionDef]] = @[]
  var targets = initTable[string, BuildTargetDef]()
  var pools = initTable[string, BuildPoolDef]()
  for fragment in snapshot.fragments:
    for node in fragment.nodes:
      if node.kind == gnkAction:
        actionNodes.add((
          node: node,
          payload: decodeBuildActionPayload(toBytes(node.payload))))
      elif node.kind == gnkMetadata and
          node.stableName == "reprobuild.build-target.v1":
        let target = decodeBuildTargetPayload(toBytes(node.payload))
        if targets.hasKey(target.name):
          raise newException(ValueError,
            "duplicate build target metadata: " & target.name)
        targets[target.name] = target
      elif node.kind == gnkMetadata and
          node.stableName == "reprobuild.build-pool.v1":
        let pool = decodeBuildPoolPayload(toBytes(node.payload))
        if pools.hasKey(pool.name):
          raise newException(ValueError,
            "duplicate build pool metadata: " & pool.name)
        pools[pool.name] = pool
  for pool in pools.values:
    result.pools.add(repro_build_engine.pool(pool.name, pool.capacity))
  let inferredActions = inferDeclaredActionDeps(
    actionNodes.mapIt(it.payload), projectRoot)
  for i in 0 ..< actionNodes.len:
    actionNodes[i].payload = inferredActions[i]
  var aliasForAction = initTable[string, string]()
  for target in targets.values:
    if target.actions.len == 1 and target.targets.len == 0:
      let actionId = target.actions[0]
      if aliasForAction.hasKey(actionId) and aliasForAction[actionId] !=
          target.name:
        raise newException(ValueError,
          "action " & actionId & " has multiple direct target aliases: " &
            aliasForAction[actionId] & " and " & target.name)
      aliasForAction[actionId] = target.name

  proc publicPayload(action: BuildActionDef): BuildActionDef =
    result = action
    if aliasForAction.hasKey(action.id):
      result.id = aliasForAction[action.id]
    for i in 0 ..< result.deps.len:
      if aliasForAction.hasKey(result.deps[i]):
        result.deps[i] = aliasForAction[result.deps[i]]

  proc lowerItem(item: tuple[node: GraphNode; payload: BuildActionDef]):
      BuildAction =
    var node = item.node
    node.payload = actionPayload(publicPayload(item.payload))
    lowerGraphAction(node, profiles, projectRoot)

  if selectedActionId.len == 0:
    for item in actionNodes:
      result.actions.add(lowerItem(item))
    return

  var byId = initTable[string, BuildActionDef]()
  for item in actionNodes:
    byId[item.payload.id] = item.payload
  if not byId.hasKey(selectedActionId) and
      not targets.hasKey(selectedActionId):
    var available: seq[string] = @[]
    for item in actionNodes:
      available.add(item.payload.id)
    for target in targets.values:
      available.add(target.name)
    available.sort()
    raise newException(ValueError,
      "unknown build target/action id: " & selectedActionId &
        (if available.len > 0:
          " (available: " & available.join(", ") & ")"
        else: " (project defines no build actions or targets)"))

  var selected = initHashSet[string]()
  var visitingTargets = initHashSet[string]()
  var expandedTargets = initHashSet[string]()
  proc includeClosure(actionId: string) =
    if selected.contains(actionId):
      return
    if not byId.hasKey(actionId):
      raise newException(ValueError,
        "unknown dependency " & actionId & " while selecting build target " &
          selectedActionId)
    selected.incl(actionId)
    for dep in byId[actionId].deps:
      includeClosure(dep)

  proc includeTarget(targetName: string) =
    if expandedTargets.contains(targetName):
      return
    if visitingTargets.contains(targetName):
      raise newException(ValueError,
        "cyclic build target dependency involving " & targetName)
    if not targets.hasKey(targetName):
      raise newException(ValueError,
        "unknown build target " & targetName & " while selecting " &
          selectedActionId)
    visitingTargets.incl(targetName)
    let target = targets[targetName]
    for depTarget in target.targets:
      includeTarget(depTarget)
    for actionId in target.actions:
      includeClosure(actionId)
    visitingTargets.excl(targetName)
    expandedTargets.incl(targetName)

  if targets.hasKey(selectedActionId):
    includeTarget(selectedActionId)
  else:
    includeClosure(selectedActionId)
  for item in actionNodes:
    if selected.contains(item.payload.id):
      result.actions.add(lowerItem(item))

proc defaultBuildActionId(snapshot: ProviderGraphSnapshot): string =
  for fragment in snapshot.fragments:
    for node in fragment.nodes:
      if node.kind == gnkMetadata and
          node.stableName == DefaultBuildActionMetadataName:
        if result.len > 0 and result != node.payload:
          raise newException(ValueError,
            "conflicting default build action metadata: " & result &
              " and " & node.payload)
        result = node.payload

const
  LoweredGraphCacheMagic = "RBLG"
  LoweredGraphCacheVersion = 1'u16

type
  LoweredGraphCacheRecord = object
    modulePath: string
    projectRoot: string
    selectedActionId: string
    pathEnv: string
    actions: seq[BuildAction]
    pools: seq[BuildPool]

proc readByteValue(bytes: openArray[byte]; pos: var int): byte =
  if pos >= bytes.len:
    raiseEnvelopeError(eeMalformed, "truncated byte")
  result = bytes[pos]
  inc pos

proc writeDigestPayload(outp: var seq[byte]; digest: ContentDigest) =
  outp.add(byte(ord(digest.algorithm)))
  outp.add(byte(ord(digest.domain)))
  outp.add(digest.bytes)

proc readDigestPayload(bytes: openArray[byte]; pos: var int): ContentDigest =
  let algorithm = readByteValue(bytes, pos)
  let domain = readByteValue(bytes, pos)
  if algorithm > byte(ord(haXxh3_64)):
    raiseEnvelopeError(eeMalformed, "invalid digest algorithm")
  if domain > byte(ord(hdMetadataEnvelope)):
    raiseEnvelopeError(eeMalformed, "invalid digest domain")
  if pos + 32 > bytes.len:
    raiseEnvelopeError(eeMalformed, "truncated digest bytes")
  result.algorithm = HashAlgorithm(algorithm)
  result.domain = HashDomain(domain)
  for i in 0 ..< 32:
    result.bytes[i] = bytes[pos + i]
  pos += 32

proc writeStringSeq(outp: var seq[byte]; values: openArray[string]) =
  outp.writeU32Le(uint32(values.len))
  for value in values:
    outp.writeString(value)

proc readStringSeq(bytes: openArray[byte]; pos: var int): seq[string] =
  let count = int(readU32Le(bytes, pos))
  result = newSeq[string](count)
  for i in 0 ..< count:
    result[i] = readString(bytes, pos)

proc writeExpectedDependencyFile(outp: var seq[byte];
                                 value: ExpectedDependencyFile) =
  outp.writeString(value.logicalName)
  outp.writeString(value.path)
  outp.add(if value.required: 1'u8 else: 0'u8)

proc readExpectedDependencyFile(bytes: openArray[byte]; pos: var int):
    ExpectedDependencyFile =
  result.logicalName = readString(bytes, pos)
  result.path = readString(bytes, pos)
  result.required = readByteValue(bytes, pos) != 0

proc writeProcessSpec(outp: var seq[byte]; process: ProcessSpec) =
  outp.add(byte(ord(process.kind)))
  outp.writeString(process.executable.value)
  outp.writeStringSeq(process.args)
  outp.writeU32Le(uint32(process.env.len))
  for item in process.env:
    outp.writeString(item.name)
    outp.writeString(item.value)
  outp.writeString(process.cwd.value)
  outp.add(byte(ord(process.stdinPolicy)))
  outp.add(byte(ord(process.stdoutPolicy)))
  outp.add(byte(ord(process.stderrPolicy)))

proc readProcessSpec(bytes: openArray[byte]; pos: var int): ProcessSpec =
  let kind = readByteValue(bytes, pos)
  if kind > byte(ord(ckShell)):
    raiseEnvelopeError(eeMalformed, "invalid process kind")
  result.kind = CommandKind(kind)
  result.executable = NormalizedPath(kind: npRelative, value: readString(bytes, pos))
  result.args = readStringSeq(bytes, pos)
  let envCount = int(readU32Le(bytes, pos))
  result.env = newSeq[EnvVar](envCount)
  for i in 0 ..< envCount:
    result.env[i].name = readString(bytes, pos)
    result.env[i].value = readString(bytes, pos)
  result.cwd = NormalizedPath(kind: npRelative, value: readString(bytes, pos))
  let stdinPolicy = readByteValue(bytes, pos)
  let stdoutPolicy = readByteValue(bytes, pos)
  let stderrPolicy = readByteValue(bytes, pos)
  if stdinPolicy > byte(ord(spCapture)) or stdoutPolicy > byte(ord(spCapture)) or
      stderrPolicy > byte(ord(spCapture)):
    raiseEnvelopeError(eeMalformed, "invalid stdio policy")
  result.stdinPolicy = StdioPolicy(stdinPolicy)
  result.stdoutPolicy = StdioPolicy(stdoutPolicy)
  result.stderrPolicy = StdioPolicy(stderrPolicy)

proc writeDependencyPolicy(outp: var seq[byte];
                           policy: DependencyGatheringPolicy) =
  outp.add(byte(ord(policy.kind)))
  outp.add(byte(ord(policy.completeness)))
  outp.writeU32Le(uint32(policy.recognizedReports.len))
  for report in policy.recognizedReports:
    outp.writeString($report.formatName)
    outp.writeU32Le(uint32(report.outputs.len))
    for output in report.outputs:
      outp.writeExpectedDependencyFile(output)
    outp.add(byte(ord(report.completeness)))
  outp.writeU32Le(uint32(policy.postBuildConverters.len))
  for converterSpec in policy.postBuildConverters:
    outp.writeProcessSpec(converterSpec.converterProcess)
    outp.writeU32Le(uint32(converterSpec.inputs.len))
    for input in converterSpec.inputs:
      outp.writeExpectedDependencyFile(input)
    outp.writeU32Le(uint32(converterSpec.outputs.len))
    for output in converterSpec.outputs:
      outp.writeExpectedDependencyFile(output)
    outp.add(byte(ord(converterSpec.outputKind)))
    outp.writeString($converterSpec.outputFormatName)
    outp.add(byte(ord(converterSpec.completeness)))

proc readCompleteness(bytes: openArray[byte]; pos: var int):
    DependencyEvidenceCompleteness =
  let value = readByteValue(bytes, pos)
  if value > byte(ord(decDiagnosticOnly)):
    raiseEnvelopeError(eeMalformed, "invalid dependency completeness")
  DependencyEvidenceCompleteness(value)

proc readDependencyPolicy(bytes: openArray[byte]; pos: var int):
    DependencyGatheringPolicy =
  let kind = readByteValue(bytes, pos)
  if kind > byte(ord(dgNoRuntimeDependencies)):
    raiseEnvelopeError(eeMalformed, "invalid dependency gathering kind")
  result.kind = DependencyGatheringKind(kind)
  result.completeness = readCompleteness(bytes, pos)
  let reportCount = int(readU32Le(bytes, pos))
  result.recognizedReports = newSeq[RecognizedDependencyReportSpec](reportCount)
  for i in 0 ..< reportCount:
    result.recognizedReports[i].formatName =
      DependencyFormatName(readString(bytes, pos))
    let outputCount = int(readU32Le(bytes, pos))
    result.recognizedReports[i].outputs = newSeq[ExpectedDependencyFile](outputCount)
    for j in 0 ..< outputCount:
      result.recognizedReports[i].outputs[j] =
        readExpectedDependencyFile(bytes, pos)
    result.recognizedReports[i].completeness = readCompleteness(bytes, pos)
  let converterCount = int(readU32Le(bytes, pos))
  result.postBuildConverters =
    newSeq[PostBuildDependencyConverterSpec](converterCount)
  for i in 0 ..< converterCount:
    result.postBuildConverters[i].converterProcess = readProcessSpec(bytes, pos)
    let inputCount = int(readU32Le(bytes, pos))
    result.postBuildConverters[i].inputs =
      newSeq[ExpectedDependencyFile](inputCount)
    for j in 0 ..< inputCount:
      result.postBuildConverters[i].inputs[j] =
        readExpectedDependencyFile(bytes, pos)
    let outputCount = int(readU32Le(bytes, pos))
    result.postBuildConverters[i].outputs =
      newSeq[ExpectedDependencyFile](outputCount)
    for j in 0 ..< outputCount:
      result.postBuildConverters[i].outputs[j] =
        readExpectedDependencyFile(bytes, pos)
    let outputKind = readByteValue(bytes, pos)
    if outputKind > byte(ord(dcoRecognizedFormat)):
      raiseEnvelopeError(eeMalformed, "invalid converter output kind")
    result.postBuildConverters[i].outputKind =
      DependencyConverterOutputKind(outputKind)
    result.postBuildConverters[i].outputFormatName =
      DependencyFormatName(readString(bytes, pos))
    result.postBuildConverters[i].completeness = readCompleteness(bytes, pos)

proc writeBuildAction(outp: var seq[byte]; action: BuildAction) =
  outp.add(byte(ord(action.kind)))
  outp.writeString(action.id)
  outp.writeStringSeq(action.deps)
  outp.writeStringSeq(action.inputs)
  outp.writeStringSeq(action.outputs)
  outp.writeStringSeq(action.argv)
  outp.writeString(action.cwd)
  outp.writeStringSeq(action.env)
  outp.writeString(action.pool)
  outp.writeU32Le(action.poolUnits)
  outp.writeU32Le(action.cpuMilli)
  outp.writeU64Le(action.memoryBytes)
  outp.writeString(action.commandStatsId)
  outp.add(if action.cacheable: 1'u8 else: 0'u8)
  outp.writeDigestPayload(action.weakFingerprint)
  outp.add(byte(ord(action.actionCachePolicy)))
  outp.writeString(action.depfile)
  outp.writeString(action.dynamicDepsFile)
  outp.writeString(action.monitorDepfile)
  outp.writeDependencyPolicy(action.dependencyPolicy)
  outp.writeString(action.builtinText)
  outp.writeStringSeq(action.builtinEntries)

proc readBuildAction(bytes: openArray[byte]; pos: var int): BuildAction =
  let kind = readByteValue(bytes, pos)
  if kind > byte(ord(bakPreserveTree)):
    raiseEnvelopeError(eeMalformed, "invalid build action kind")
  result.kind = BuildActionKind(kind)
  result.id = readString(bytes, pos)
  result.deps = readStringSeq(bytes, pos)
  result.inputs = readStringSeq(bytes, pos)
  result.outputs = readStringSeq(bytes, pos)
  result.argv = readStringSeq(bytes, pos)
  result.cwd = readString(bytes, pos)
  result.env = readStringSeq(bytes, pos)
  result.pool = readString(bytes, pos)
  result.poolUnits = readU32Le(bytes, pos)
  result.cpuMilli = readU32Le(bytes, pos)
  result.memoryBytes = readU64Le(bytes, pos)
  result.commandStatsId = readString(bytes, pos)
  result.cacheable = readByteValue(bytes, pos) != 0
  result.weakFingerprint = readDigestPayload(bytes, pos)
  let policy = readByteValue(bytes, pos)
  if policy > byte(ord(ffpHybrid)):
    raiseEnvelopeError(eeMalformed, "invalid action cache policy")
  result.actionCachePolicy = FileFingerprintPolicy(policy)
  result.depfile = readString(bytes, pos)
  result.dynamicDepsFile = readString(bytes, pos)
  result.monitorDepfile = readString(bytes, pos)
  result.dependencyPolicy = readDependencyPolicy(bytes, pos)
  result.builtinText = readString(bytes, pos)
  result.builtinEntries = readStringSeq(bytes, pos)

proc encodeLoweredGraphCache(record: LoweredGraphCacheRecord): seq[byte] =
  result.writeString(LoweredGraphCacheMagic)
  result.writeU16Le(LoweredGraphCacheVersion)
  result.writeString(record.modulePath)
  result.writeString(record.projectRoot)
  result.writeString(record.selectedActionId)
  result.writeString(record.pathEnv)
  result.writeU32Le(uint32(record.pools.len))
  for pool in record.pools:
    result.writeString(pool.name)
    result.writeU32Le(pool.capacity)
  result.writeU32Le(uint32(record.actions.len))
  for action in record.actions:
    result.writeBuildAction(action)

proc decodeLoweredGraphCache(bytes: openArray[byte]): LoweredGraphCacheRecord =
  var pos = 0
  if readString(bytes, pos) != LoweredGraphCacheMagic:
    raiseEnvelopeError(eeUnknownMagic, "unknown lowered graph cache magic")
  let version = readU16Le(bytes, pos)
  if version != LoweredGraphCacheVersion:
    raiseEnvelopeError(eeUnsupportedVersion,
      "unsupported lowered graph cache version")
  result.modulePath = readString(bytes, pos)
  result.projectRoot = readString(bytes, pos)
  result.selectedActionId = readString(bytes, pos)
  result.pathEnv = readString(bytes, pos)
  let poolCount = int(readU32Le(bytes, pos))
  result.pools = newSeq[BuildPool](poolCount)
  for i in 0 ..< poolCount:
    result.pools[i].name = readString(bytes, pos)
    result.pools[i].capacity = readU32Le(bytes, pos)
  let actionCount = int(readU32Le(bytes, pos))
  result.actions = newSeq[BuildAction](actionCount)
  for i in 0 ..< actionCount:
    result.actions[i] = readBuildAction(bytes, pos)
  if pos != bytes.len:
    raiseEnvelopeError(eeMalformed, "trailing lowered graph cache bytes")

proc loweredGraphCachePath(outDir, selectedActionId: string): string =
  let label =
    if selectedActionId.len > 0:
      selectedActionId
    else:
      "__omitted_default__"
  outDir / "lowered-graph-cache" /
    (safePathSegment(label, "default") & "-" &
      toHex(weakFingerprintFromText(label).bytes)[0 .. 15] & ".rbbg")

proc readFreshLoweredGraphCache(path, modulePath, projectRoot, selectedActionId,
                                pathEnv: string):
    Option[tuple[actions: seq[BuildAction]; pools: seq[BuildPool]]] =
  if not fileExists(extendedPath(path)):
    return none(tuple[actions: seq[BuildAction]; pools: seq[BuildPool]])
  try:
    let record = decodeLoweredGraphCache(toBytes(readFile(extendedPath(path))))
    if record.modulePath != modulePath or record.projectRoot != projectRoot or
        record.selectedActionId != selectedActionId or record.pathEnv != pathEnv:
      return none(tuple[actions: seq[BuildAction]; pools: seq[BuildPool]])
    return some((actions: record.actions, pools: record.pools))
  except CatchableError:
    return none(tuple[actions: seq[BuildAction]; pools: seq[BuildPool]])

proc writeLoweredGraphCache(path, modulePath, projectRoot, selectedActionId,
                            pathEnv: string;
                            lowered: tuple[actions: seq[BuildAction];
                                           pools: seq[BuildPool]]) =
  createDir(extendedPath(parentDir(path)))
  let record = LoweredGraphCacheRecord(
    modulePath: modulePath,
    projectRoot: projectRoot,
    selectedActionId: selectedActionId,
    pathEnv: pathEnv,
    actions: lowered.actions,
    pools: lowered.pools)
  writeFile(extendedPath(path), fromBytes(encodeLoweredGraphCache(record)))

proc evidenceJson(evidence: PathSetEvidence): JsonNode =
  %*{
    "declaredInputs": jsonStringSeq(evidence.declaredInputs),
    "declaredOutputs": jsonStringSeq(evidence.declaredOutputs),
    "depfileInputs": jsonStringSeq(evidence.depfileInputs),
    "monitorReads": jsonStringSeq(evidence.monitorReads),
    "monitorWrites": jsonStringSeq(evidence.monitorWrites),
    "monitorProbes": jsonStringSeq(evidence.monitorProbes),
    "diagnostics": jsonStringSeq(evidence.diagnostics)
  }

proc statsJson(stats: BuildStats): JsonNode =
  var metrics = newJArray()
  for metric in stats.metrics:
    let avgUs =
      if metric.count > 0:
        metric.totalUs / float(metric.count)
      else:
        0.0
    metrics.add(%*{
      "name": metric.name,
      "count": metric.count,
      "avgUs": avgUs,
      "totalMs": metric.totalUs / 1000.0
    })
  %*{"metrics": metrics}

proc metricCount(stats: BuildStats; name: string): int =
  for metric in stats.metrics:
    if metric.name == name:
      return metric.count

proc metricTotalUs(stats: BuildStats; name: string): float =
  for metric in stats.metrics:
    if metric.name == name:
      return metric.totalUs

proc fileSizeOrZero(path: string): BiggestInt =
  if path.len == 0 or not fileExists(extendedPath(path)):
    return 0
  getFileSize(extendedPath(path))

proc evidenceInputCount(evidence: PathSetEvidence): int =
  var seen: seq[string] = @[]
  for group in [evidence.declaredInputs, evidence.depfileInputs,
      evidence.monitorReads, evidence.monitorProbes]:
    for path in group:
      if path.len > 0 and seen.find(path) < 0:
        seen.add(path)
  seen.len

proc actionPresent(action: ActionResult): bool =
  action.id.len > 0 and action.status != asPending

proc actionResultJson(item: ActionResult): JsonNode =
  # Windows: include exitCode/stdout/stderr in the build report so failed
  # actions can be diagnosed without re-running them. Without this, the JSON
  # report only carries status/cacheDecision/etc. and failures look opaque.
  %*{
    "id": item.id,
    "status": $item.status,
    "exitCode": item.exitCode,
    "launched": item.launched,
    "cacheDecision": $item.cacheDecision,
    "dependencyPolicyKind": $item.dependencyPolicyKind,
    "runQuotaBackend": item.runQuotaBackend,
    "runQuotaSocket": item.runQuotaSocket,
    "leaseId": item.leaseId,
    "stdout": item.stdout,
    "stderr": item.stderr,
    "evidence": evidenceJson(item.evidence)
  }

proc writeBuildReport(path: string; provider: ProviderCompileArtifact;
                      refresh: ProviderRefreshReport;
                      cmakeRegenerationResult,
                      providerCompileResult,
                      buildResult: BuildRunResult) =
  var cmakeRegenerationActions = newJArray()
  for item in cmakeRegenerationResult.results:
    cmakeRegenerationActions.add(actionResultJson(item))
  var providerCompileActions = newJArray()
  for item in providerCompileResult.results:
    providerCompileActions.add(actionResultJson(item))
  var actions = newJArray()
  for item in buildResult.results:
    actions.add(actionResultJson(item))
  var trace = newJArray()
  for event in buildResult.trace:
    trace.add(%*{
      "seq": event.seq,
      "actionId": event.actionId,
      "event": event.event,
      "detail": event.detail
    })
  let root = %*{
    "providerBinary": provider.outputBinaryPath,
    "providerFingerprint": digestHex(provider.providerFingerprint),
    "providerCompileOutput": provider.executionResult.output,
    "cmakeRegenerationActions": cmakeRegenerationActions,
    "providerCompileActions": providerCompileActions,
    "providerSnapshot": refresh.persistedSnapshotPath,
    "providerInvocations": refresh.invoked.len,
    "actions": actions,
    "trace": trace,
    "stats": statsJson(buildResult.stats)
  }
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), $root)

proc hasFailedActions(buildResult: BuildRunResult): bool =
  for item in buildResult.results:
    if item.status in {asFailed, asBlocked}:
      return true

proc providerCompileBuildAction(plan: ProviderCompilePlan;
                                modulePath, interfacePath, artifactPath,
                                publicCliPath, workDir: string;
                                scratchDir = ""): BuildAction =
  var inputs = plan.inputSources
  if not inputs.contains(interfacePath):
    inputs.add(interfacePath)
  var command = @[
    publicCliPath,
    "__repro-compile-provider",
    "--module", modulePath,
    "--out", plan.outputBinaryPath,
    "--artifact", artifactPath,
    "--interface", interfacePath,
    "--work-dir", workDir
  ]
  if scratchDir.len > 0:
    command.add("--scratch-dir")
    command.add(scratchDir)
  action("__repro_provider_compile", command,
    cwd = workDir,
    inputs = inputs,
    outputs = @[plan.outputBinaryPath, artifactPath],
    commandStatsId = "repro provider compile edge",
    cacheable = true,
    weakFingerprint = plan.compileEdge.actionFingerprint,
    dependencyPolicy = declaredOnlyPolicy())

proc invalidateStaleProviderCompileArtifact(plan: ProviderCompilePlan;
                                            artifactPath: string) =
  if artifactPath.len == 0 or not fileExists(extendedPath(artifactPath)):
    return
  if providerCompileArtifactFresh(artifactPath, plan.outputBinaryPath,
      plan.interfaceFingerprint, plan.providerFingerprint):
    return
  removeFile(extendedPath(artifactPath))

proc providerCompileFailure(buildResult: BuildRunResult): string =
  for item in buildResult.results:
    if item.status in {asFailed, asBlocked}:
      var parts = @[item.id & " " & $item.status]
      if item.stderr.len > 0:
        parts.add(item.stderr)
      if item.stdout.len > 0:
        parts.add(item.stdout)
      return parts.join("\n")
  "provider compile failed"

proc readTextIfExists(path: string): string =
  if path.len == 0 or not fileExists(extendedPath(path)):
    return ""
  readFile(extendedPath(path))

proc runLoggedCommand(argv: openArray[string]; cwd: string): int =
  let command = shellCommand(argv)
  let res = execCmdEx(command, workingDir = cwd)
  if res.output.len > 0:
    stdout.write(res.output)
    stdout.flushFile()
  res.exitCode

proc removeManifestEntries(path: string) =
  if path.len == 0 or not fileExists(extendedPath(path)):
    return
  for rawLine in readFile(extendedPath(path)).splitLines():
    let filePath = rawLine.strip()
    if filePath.len > 0 and fileExists(extendedPath(filePath)):
      removeFile(extendedPath(filePath))

proc invalidateCmakeProviderDerivedState(meta: CmakeRegenerationMetadata) =
  if meta.providerRoot.len > 0:
    let pattern = meta.providerRoot / "worktrees" / "*" / "build" /
      "reprobuild" / "provider-graph" / "provider-fragments.rbsz"
    for fragment in walkFiles(extendedPath(pattern)):
      removeFile(extendedPath(fragment))
  for key, value in meta.values:
    if key == "clean_manifest" or key.startsWith("clean_manifest_"):
      removeManifestEntries(value)

proc runCmakeRegenerationHelper*(args: openArray[string]): int =
  var metadataFile = ""
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--metadata":
      if i + 1 >= args.len:
        raise newException(ValueError, "--metadata requires a value")
      metadataFile = args[i + 1]
      inc i, 2
    elif arg.startsWith("--metadata="):
      metadataFile = arg.split("=", maxsplit = 1)[1]
      inc i
    else:
      raise newException(ValueError,
        "unsupported __repro-cmake-regenerate argument: " & arg)
  if metadataFile.len == 0:
    raise newException(ValueError, "--metadata is required")

  let values = readKeyValueMetadata(metadataFile)
  if values.len == 0:
    raise newException(IOError,
      "CMake regeneration metadata is missing: " & metadataFile)
  let sourceDir = values.metadataValue("source_dir")
  let binaryDir = values.metadataValue("binary_dir", parentDir(parentDir(
    parentDir(metadataFile))))
  if sourceDir.len == 0 or binaryDir.len == 0:
    raise newException(ValueError,
      "CMake regeneration metadata requires source_dir and binary_dir")
  var meta = CmakeRegenerationMetadata(
    enabled: true,
    suppressed: values.metadataFlag("cmake_regeneration_suppressed"),
    metadataFile: metadataFile,
    sourceDir: os.normalizedPath(sourceDir),
    binaryDir: os.normalizedPath(binaryDir),
    providerRoot: os.normalizedPath(values.metadataValue("provider_root",
      binaryDir / "CMakeFiles" / "reprobuild")),
    cmakeCommand: values.metadataValue("cmake_command", "cmake"),
    checkFile: values.metadataValue("cmake_regeneration_check_file",
      "CMakeFiles/Makefile.cmake"),
    globVerifyScript: values.metadataValue("cmake_regeneration_glob_verify",
      binaryDir / "CMakeFiles" / "VerifyGlobs.cmake"),
    providerFile: values.metadataValue("cmake_regeneration_provider_file",
      binaryDir / "reprobuild.nim"),
    providerStateFile: values.metadataValue(
      "cmake_regeneration_provider_state",
      values.metadataValue("provider_root", binaryDir / "CMakeFiles" /
        "reprobuild") / "provider.last"),
    values: values)

  if meta.suppressed:
    echo "cmakeRegeneration: suppressed"
    return 0

  let providerBefore = readTextIfExists(meta.providerStateFile)
  if meta.globVerifyScript.len > 0 and fileExists(extendedPath(meta.globVerifyScript)):
    let verifyRet = runLoggedCommand(@[
      meta.cmakeCommand, "-P", meta.globVerifyScript
    ], meta.binaryDir)
    if verifyRet != 0:
      return verifyRet

  let regenRet = runLoggedCommand(@[
    meta.cmakeCommand,
    "-S", meta.sourceDir,
    "-B", meta.binaryDir,
    "--check-build-system", meta.checkFile,
    "0"
  ], meta.binaryDir)
  if regenRet != 0:
    return regenRet

  let providerAfter = readTextIfExists(meta.providerFile)
  if providerAfter.len == 0:
    raise newException(IOError,
      "CMake regeneration did not produce provider file: " &
        meta.providerFile)
  if providerBefore.len > 0 and providerBefore != providerAfter:
    invalidateCmakeProviderDerivedState(meta)
  createDir(extendedPath(parentDir(meta.providerStateFile)))
  writeFile(extendedPath(meta.providerStateFile), providerAfter)
  echo "cmakeRegeneration: complete providerChanged=" &
    $(providerBefore.len > 0 and providerBefore != providerAfter)
  0

proc identityPaths(outDir: string; mode: ToolProvisioningMode):
    tuple[identityPath: string; inspectionPath: string] =
  case mode
  of tpmNix:
    (identityPath: outDir / "nix-tool-identities.rbtp",
      inspectionPath: outDir / "nix-tool-identities.inspect.json")
  of tpmTarball:
    (identityPath: outDir / "tarball-tool-identities.rbtp",
      inspectionPath: outDir / "tarball-tool-identities.inspect.json")
  of tpmScoop:
    (identityPath: outDir / "scoop-tool-identities.rbtp",
      inspectionPath: outDir / "scoop-tool-identities.inspect.json")
  else:
    (identityPath: outDir / "path-only-tool-identities.rbtp",
      inspectionPath: outDir / "path-only-tool-identities.inspect.json")

proc modeName(mode: ToolProvisioningMode): string =
  case mode
  of tpmPathOnly: "path"
  of tpmNix: "nix"
  of tpmTarball: "tarball"
  of tpmScoop: "scoop"
  else: "unspecified"

proc addCacheField(payload: var string; value: string) =
  payload.add($value.len)
  payload.add(":")
  payload.add(value)
  payload.add("\n")

proc toolIdentityCacheKey(artifact: ProjectInterfaceArtifact;
                          mode: ToolProvisioningMode): string =
  var payload = ""
  payload.addCacheField("reprobuild.toolIdentityCache.v1")
  payload.addCacheField(mode.modeName)
  payload.addCacheField(artifact.projectInterface.projectName)
  payload.addCacheField(artifact.projectInterface.packageName)
  payload.addCacheField(digestHex(artifact.interfaceFingerprint))
  if mode == tpmPathOnly:
    payload.addCacheField(getEnv("PATH"))
  for useDef in artifact.projectInterface.toolUses:
    payload.addCacheField(useDef.rawConstraint)
    payload.addCacheField(useDef.packageSelector)
    payload.addCacheField(useDef.executableName)
    payload.addCacheField(useDef.policyPath.join("/"))
    for nix in useDef.nixProvisioning:
      payload.addCacheField(nix.selector)
      payload.addCacheField(nix.executablePath)
      payload.addCacheField(nix.expressionFile)
      payload.addCacheField(nix.packageId)
      payload.addCacheField(nix.lockIdentity)
    for tarball in useDef.tarballProvisioning:
      payload.addCacheField(tarball.url)
      payload.addCacheField(tarball.mirrors.join("\n"))
      payload.addCacheField(tarball.sha256)
      payload.addCacheField(tarball.archiveType)
      payload.addCacheField($tarball.stripComponents)
      payload.addCacheField(tarball.executablePath)
      payload.addCacheField(tarball.packageId)
      payload.addCacheField(tarball.lockIdentity)
    for scoop in useDef.scoopProvisioning:
      payload.addCacheField(scoop.bucket)
      payload.addCacheField(scoop.app)
      payload.addCacheField(scoop.version)
      payload.addCacheField(scoop.preferredVersion)
      payload.addCacheField(scoop.manifestChecksum)
      payload.addCacheField(scoop.manifestUrl)
      payload.addCacheField(scoop.executablePath)
      payload.addCacheField($scoop.requiresExecutionProfileChecksum)
      payload.addCacheField(scoop.packageId)
      payload.addCacheField(scoop.lockIdentity)
  digestHex(blake3DomainDigest(payload.bytesOf(), hdMetadataEnvelope))

proc cachedToolIdentity(outDir: string; mode: ToolProvisioningMode;
                        artifact: ProjectInterfaceArtifact;
                        stableIdentityPath,
                        stableInspectionPath: string):
    tuple[hit: bool; identity: PathOnlyBuildIdentity] =
  let key = toolIdentityCacheKey(artifact, mode)
  let cacheDir = outDir / "tool-identity-cache"
  let cacheIdentityPath = cacheDir / (key & ".rbtp")
  let cacheInspectionPath = cacheDir / (key & ".inspect.json")
  let stableKeyPath = cacheDir / (mode.modeName & ".current-key")
  if fileExists(extendedPath(stableIdentityPath)) and fileExists(extendedPath(stableKeyPath)) and
      readFile(extendedPath(stableKeyPath)).strip() == key:
    try:
      let identity = readPathOnlyBuildIdentity(stableIdentityPath)
      if identity.interfaceFingerprint != artifact.interfaceFingerprint:
        return
      if not fileExists(extendedPath(stableInspectionPath)):
        if fileExists(extendedPath(cacheInspectionPath)):
          createDir(extendedPath(parentDir(stableInspectionPath)))
          copyFile(extendedPath(cacheInspectionPath), extendedPath(stableInspectionPath))
        else:
          writeInspectionJson(stableInspectionPath, identity)
      return (hit: true, identity: identity)
    except CatchableError:
      discard
  if not fileExists(extendedPath(cacheIdentityPath)):
    return
  try:
    let identity = readPathOnlyBuildIdentity(cacheIdentityPath)
    if identity.interfaceFingerprint != artifact.interfaceFingerprint:
      return
    writePathOnlyBuildIdentity(stableIdentityPath, identity)
    if fileExists(extendedPath(cacheInspectionPath)):
      createDir(extendedPath(parentDir(stableInspectionPath)))
      copyFile(extendedPath(cacheInspectionPath), extendedPath(stableInspectionPath))
    else:
      writeInspectionJson(stableInspectionPath, identity)
    createDir(extendedPath(cacheDir))
    writeFile(extendedPath(stableKeyPath), key & "\n")
    return (hit: true, identity: identity)
  except CatchableError:
    return (hit: false, identity: PathOnlyBuildIdentity())

proc writeToolIdentityCache(outDir: string; mode: ToolProvisioningMode;
                            artifact: ProjectInterfaceArtifact;
                            identity: PathOnlyBuildIdentity) =
  let key = toolIdentityCacheKey(artifact, mode)
  let cacheDir = outDir / "tool-identity-cache"
  writePathOnlyBuildIdentity(cacheDir / (key & ".rbtp"), identity)
  writeInspectionJson(cacheDir / (key & ".inspect.json"), identity)

proc resolveAndWriteIdentity(artifact: ProjectInterfaceArtifact;
                             outDir: string;
                             mode: ToolProvisioningMode):
    tuple[identity: PathOnlyBuildIdentity; identityPath: string;
      inspectionPath: string] =
  let paths = identityPaths(outDir, mode)
  let cached = cachedToolIdentity(outDir, mode, artifact,
    paths.identityPath, paths.inspectionPath)
  if cached.hit:
    return (identity: cached.identity, identityPath: paths.identityPath,
      inspectionPath: paths.inspectionPath)
  let identity = toolBuildIdentity(artifact, mode,
    storeRoot = outDir / "tool-store")
  writePathOnlyBuildIdentity(paths.identityPath, identity)
  writeInspectionJson(paths.inspectionPath, identity)
  writeToolIdentityCache(outDir, mode, artifact, identity)
  createDir(extendedPath(outDir / "tool-identity-cache"))
  writeFile(extendedPath(outDir / "tool-identity-cache" / (mode.modeName & ".current-key")),
    toolIdentityCacheKey(artifact, mode) & "\n")
  (identity: identity, identityPath: paths.identityPath,
    inspectionPath: paths.inspectionPath)

proc runQuotaSocketDiagnostic(): string =
  let socket = getEnv("RUNQUOTA_SOCKET", "")
  if socket.len > 0:
    socket
  else:
    "default"

proc buildMaxParallelism(): uint32 =
  let configured = getEnv("REPROBUILD_MAX_PARALLELISM", "")
  if configured.len == 0:
    return 8'u32
  try:
    let parsed = parseInt(configured)
    if parsed < 1:
      return 1'u32
    uint32(parsed)
  except ValueError:
    raise newException(ValueError,
      "REPROBUILD_MAX_PARALLELISM must be a positive integer")

proc stablePublicCliPath(): string =
  let app = getAppFilename()
  if app.isAbsolute:
    return os.normalizedPath(app)
  if app.contains(DirSep) or app.contains(AltSep):
    return os.normalizedPath(getCurrentDir() / app)
  let resolved = findExe(app)
  if resolved.len > 0:
    if resolved.isAbsolute:
      return os.normalizedPath(resolved)
    return os.normalizedPath(getCurrentDir() / resolved)
  os.normalizedPath(getCurrentDir() / app)

proc siblingFsSnoopPath(publicCliPath: string): string =
  let candidate = parentDir(publicCliPath) /
    addFileExt("repro-fs-snoop", ExeExt)
  if fileExists(extendedPath(candidate)):
    os.normalizedPath(candidate)
  else:
    ""

type
  BuildProgressMode = enum
    bpmAuto
    bpmPlain
    bpmNone

  BuildStatsMode = enum
    bsmNone
    bsmText

  BuildReportMode = enum
    brmFull
    brmNone

  BuildLogMode = enum
    blmActions
    blmSummary
    blmQuiet

  BuildProgressRenderer = object
    enabled: bool
    lastLen: int

  BuildCommandOutcome = object
    exitCode: int
    modulePath: string
    projectRoot: string
    outDir: string
    buildReportPath: string

proc parseBuildProgressMode(value: string): BuildProgressMode =
  case value.toLowerAscii()
  of "auto":
    bpmAuto
  of "plain", "line":
    bpmPlain
  of "none", "off":
    bpmNone
  else:
    raise newException(ValueError,
      "unsupported --progress=" & value & " (expected auto, plain, or none)")

proc configuredBuildProgressMode(): BuildProgressMode =
  let configured = getEnv("REPROBUILD_PROGRESS", "")
  if configured.len == 0:
    return bpmAuto
  parseBuildProgressMode(configured)

proc parseBuildStatsMode(value: string): BuildStatsMode =
  case value.toLowerAscii()
  of "1", "true", "yes", "on", "text", "stats":
    bsmText
  of "0", "false", "no", "off", "none":
    bsmNone
  else:
    raise newException(ValueError,
      "unsupported --stats=" & value & " (expected text or none)")

proc configuredBuildStatsMode(): BuildStatsMode =
  let configured = getEnv("REPROBUILD_STATS", "")
  if configured.len == 0:
    return bsmNone
  parseBuildStatsMode(configured)

proc parseBuildReportMode(value: string): BuildReportMode =
  case value.toLowerAscii()
  of "1", "true", "yes", "on", "full":
    brmFull
  of "0", "false", "no", "off", "none":
    brmNone
  else:
    raise newException(ValueError,
      "unsupported --report=" & value & " (expected full or none)")

proc configuredBuildReportMode(): BuildReportMode =
  let configured = getEnv("REPROBUILD_REPORT", "")
  if configured.len == 0:
    return brmFull
  parseBuildReportMode(configured)

proc parseBuildLogMode(value: string): BuildLogMode =
  case value.toLowerAscii()
  of "actions", "verbose":
    blmActions
  of "summary", "normal":
    blmSummary
  of "quiet", "none", "off":
    blmQuiet
  else:
    raise newException(ValueError,
      "unsupported --log=" & value & " (expected actions, summary, or quiet)")

proc configuredBuildLogMode(): BuildLogMode =
  let configured = getEnv("REPROBUILD_LOG", "")
  if configured.len == 0:
    return blmActions
  parseBuildLogMode(configured)

proc newBuildProgressRenderer(mode: BuildProgressMode): BuildProgressRenderer =
  BuildProgressRenderer(
    enabled:
      case mode
      of bpmAuto:
        isatty(stderr)
      of bpmPlain:
        true
      of bpmNone:
        false,
    lastLen: 0)

proc progressBar(completed, total, width: int): string =
  let safeWidth = max(width, 1)
  let clampedCompleted =
    if total <= 0:
      0
    else:
      min(max(completed, 0), total)
  let filled =
    if total <= 0:
      0
    else:
      min(safeWidth, (clampedCompleted * safeWidth) div total)
  result = "["
  for i in 0 ..< safeWidth:
    result.add(if i < filled: '#' else: '.')
  result.add("]")

proc fitProgressLine(line: string; width: int): string =
  if width <= 0 or line.len <= width:
    return line
  if width <= 3:
    return line[0 ..< width]
  line[0 ..< width - 3] & "..."

proc statusLabel(event: BuildProgressEvent): string =
  case event.kind
  of bpkActionStarted:
    "started"
  of bpkActionCompleted:
    case event.status
    of asSucceeded:
      "done"
    of asCacheHit:
      "cache"
    of asUpToDate:
      "up-to-date"
    of asFailed:
      "failed"
    of asBlocked:
      "blocked"
    else:
      $event.status

proc formatBuildProgressLine*(event: BuildProgressEvent; width = 80): string =
  let percent =
    if event.total <= 0:
      100
    else:
      min(100, (max(event.completed, 0) * 100) div event.total)
  let prefix = "repro " & progressBar(event.completed, event.total, 20) & " " &
    $event.completed & "/" & $event.total & " " & $percent & "%"
  let counters = " running=" & $event.running & " ready=" & $event.ready
  let tail = " " & statusLabel(event) & " " & event.actionId
  fitProgressLine(prefix & counters & tail, max(width, 20))

proc renderProgress(renderer: var BuildProgressRenderer; event: BuildProgressEvent) =
  if not renderer.enabled:
    return
  let width = min(max(terminalWidth(), 40), 120)
  var line = formatBuildProgressLine(event, width)
  let visibleLen = line.len
  if visibleLen < renderer.lastLen:
    line.add(repeat(' ', renderer.lastLen - visibleLen))
  stderr.write("\r" & line)
  stderr.flushFile()
  renderer.lastLen = visibleLen

proc finishProgress(renderer: var BuildProgressRenderer) =
  if renderer.enabled and renderer.lastLen > 0:
    stderr.write("\n")
    stderr.flushFile()
    renderer.lastLen = 0

proc statStart(enabled: bool): float =
  if enabled:
    epochTime()
  else:
    0.0

proc finishStat(stats: var BuildStats; enabled: bool; name: string;
                started: float) =
  if enabled:
    stats.addMetric(name, (epochTime() - started) * 1_000_000.0)

proc renderBuildStats*(stats: BuildStats): string =
  let nameWidth = 36
  result = "metric" & repeat(' ', nameWidth - "metric".len) &
    " count   avg (us)        total (ms)\n"
  for metric in stats.metrics:
    let avgUs =
      if metric.count > 0:
        metric.totalUs / float(metric.count)
      else:
        0.0
    let totalMs = metric.totalUs / 1000.0
    let paddedName =
      if metric.name.len < nameWidth:
        metric.name & repeat(' ', nameWidth - metric.name.len)
      else:
        metric.name & " "
    result.add(paddedName & " " &
      align($metric.count, 5) & "   " &
      align(formatFloat(avgUs, ffDecimal, 1), 8) & "        " &
      formatFloat(totalMs, ffDecimal, 1) & "\n")

proc cliPathExists(path: string): bool =
  fileExists(extendedPath(path)) or dirExists(extendedPath(path))

proc actionOutputsPresent(action: BuildAction): bool =
  if action.outputs.len == 0:
    return false
  for output in action.outputs:
    let path =
      if output.isAbsolute or action.cwd.len == 0:
        output
      else:
        action.cwd / output
    if not path.cliPathExists():
      return false
  true

proc cmakeGeneratedStateFresh(meta: CmakeRegenerationMetadata;
                              publicCliPath: string): bool =
  if meta.providerFile.len == 0 or meta.providerStateFile.len == 0:
    return false
  if not fileExists(extendedPath(meta.providerFile)) or not fileExists(extendedPath(meta.providerStateFile)):
    return false
  if readFile(extendedPath(meta.providerFile)) != readFile(extendedPath(meta.providerStateFile)):
    return false
  let stamp = getLastModificationTime(extendedPath(meta.providerStateFile))
  for input in cmakeRegenerationInputs(meta, publicCliPath):
    if (fileExists(extendedPath(input)) or dirExists(extendedPath(input))) and
        getLastModificationTime(extendedPath(input)) > stamp:
      return false
  true

proc seedCmakeRegenerationCache(meta: CmakeRegenerationMetadata;
                                publicCliPath, outDir: string): bool =
  let regenerationAction = cmakeRegenerationBuildAction(meta, publicCliPath)
  if not regenerationAction.cacheable:
    return false
  if not regenerationAction.actionOutputsPresent():
    return false
  let cmakeCacheRoot = outDir / "cmake-regeneration-cache"
  let cas = openLocalCas(cmakeCacheRoot / "cas")
  var cache = openActionCache(cmakeCacheRoot / "action-cache")
  defer:
    cache.flushHotIndex()
  let record = cache.recordActionResult(cas, regenerationAction.weakFingerprint,
    regenerationAction.actionCachePolicy, regenerationAction.inputs,
    regenerationAction.outputs, regenerationAction.cwd,
    storeOutputBlobs = false)
  writeActionResultRecordFile(
    dependencyEvidencePath(cmakeCacheRoot, regenerationAction.id), record)
  true

proc executeBuildTarget(target: string; mode: ToolProvisioningMode;
                        publicCliPath: string;
                        selectDefaultAction = false;
                        workRoot = "";
                        progressMode = bpmAuto;
                        statsMode = bsmNone;
                        reportMode = brmFull;
                        logMode = blmActions;
                        prepareOnly = false;
                        skipCmakeRegeneration = false;
                        bypassRunQuotaExplicit = false):
    BuildCommandOutcome =
  let statsEnabled = statsMode == bsmText
  var buildStats: BuildStats
  let buildTotalStart = statStart(statsEnabled)
  var parsedTarget = parseBuildTarget(target)
  parsedTarget.modulePath = absolutePath(parsedTarget.modulePath)
  let modulePath = parsedTarget.modulePath
  if not fileExists(extendedPath(modulePath)):
    raise newException(IOError, "build target module not found: " & modulePath)

  let outDir = outputDirForTarget(parsedTarget, workRoot)
  result.modulePath = modulePath
  result.projectRoot = projectRootForModule(modulePath)
  result.outDir = outDir
  # When --no-runquota was passed (or the env knob is set), skip the daemon
  # entirely: every action goes through the bypass-spawn path with no lease
  # round-trip. Default is "use runquota when reachable, fall back if not".
  let bypassRunQuota = bypassRunQuotaExplicit
  let fallbackToRunQuotaBypass = mode in {tpmPathOnly, tpmScoop}
  var warnedRunQuotaBypass = false

  template logSummary(line: string) =
    if logMode != blmQuiet:
      echo line

  template logAction(line: string) =
    if logMode == blmActions:
      echo line

  proc usesRunQuotaBypass(runResult: BuildRunResult): bool =
    for item in runResult.results:
      if item.launched and item.runQuotaBackend == "runquota-bypass":
        return true

  proc warnRunQuotaBypassIfUsed(runResult: BuildRunResult) =
    if warnedRunQuotaBypass or not fallbackToRunQuotaBypass:
      return
    if not usesRunQuotaBypass(runResult):
      return
    warnedRunQuotaBypass = true
    logSummary("repro build: WARNING runquotad is not reachable; using " &
      "RunQuota bypass for tool-provisioning=" & mode.modeName &
      " (no quotas/leases enforced). Start `runquotad` and rerun to " &
      "use the real lease coordinator.")

  proc runLoweredGraphBuild(lowered: tuple[actions: seq[BuildAction];
                                          pools: seq[BuildPool]];
                            selectedActionId: string): int =
    if parsedTarget.fragmentKind == tfkActionSelection:
      logSummary("selectedTarget: " & parsedTarget.selectedActionId)
    elif selectDefaultAction and selectedActionId.len > 0:
      logSummary("selectedTarget: " & selectedActionId)
    logSummary("scheduler: actions=" & $lowered.actions.len)
    if lowered.actions.len == 0:
      return 0
    var progressRenderer = newBuildProgressRenderer(progressMode)
    var engineConfig = BuildEngineConfig(
      cacheRoot: outDir / "build-engine-cache",
      runQuotaCliPath: publicCliPath,
      maxParallelism: buildMaxParallelism(),
      stdoutLimit: 1024 * 1024,
      stderrLimit: 1024 * 1024,
      rebuildMissingOutputsOnCacheHit: true,
      deferLocalOutputBlobs: true,
      bypassRunQuota: bypassRunQuota,
      fallbackToRunQuotaBypass: fallbackToRunQuotaBypass,
      inlineRunQuota: true,
      suppressTrace: reportMode == brmNone,
      skipCacheHitEvidence: reportMode == brmNone and logMode == blmQuiet)
    engineConfig.statsEnabled = statsEnabled
    if progressRenderer.enabled:
      engineConfig.progressCallback = proc(event: BuildProgressEvent) =
        progressRenderer.renderProgress(event)
    var buildResult: BuildRunResult
    let engineStart = statStart(statsEnabled)
    try:
      buildResult = runBuild(graph(lowered.actions, lowered.pools), engineConfig)
    finally:
      progressRenderer.finishProgress()
    finishStat(buildStats, statsEnabled, "repro engine runBuild", engineStart)
    buildStats.mergeStats(buildResult.stats)
    warnRunQuotaBypassIfUsed(buildResult)
    finishStat(buildStats, statsEnabled, "repro build total", buildTotalStart)
    buildResult.stats = buildStats
    let actionLogStart = statStart(statsEnabled)
    for item in buildResult.results:
      logAction("action: " & item.id & " status=" & $item.status &
        " launched=" & $item.launched & " cache=" & $item.cacheDecision &
        " runquota=" & item.runQuotaBackend &
        " socket=" & (if item.runQuotaSocket.len >
            0: item.runQuotaSocket else: "default") &
        " lease=" & $item.leaseId &
        " evidence=depfile:" & $item.evidence.depfileInputs.len)
    finishStat(buildStats, statsEnabled, "repro action log render",
      actionLogStart)
    buildResult.stats = buildStats
    if statsEnabled:
      let statsRenderStart = statStart(statsEnabled)
      stderr.write(renderBuildStats(buildResult.stats))
      stderr.flushFile()
      finishStat(buildStats, statsEnabled, "repro stats render",
        statsRenderStart)
    if buildResult.hasFailedActions():
      1
    else:
      0

  var cmakeRegenerationResult: BuildRunResult
  let cmakeMeta = cmakeRegenerationMetadataForModule(modulePath)
  cmakeMeta.applyCmakeProviderEnvironment()
  var cmakeRegenerated = false
  if cmakeMeta.enabled and not skipCmakeRegeneration:
    logSummary("cmakeRegeneration: started")
    let cmakeRegenerationStart = statStart(statsEnabled)
    let cmakeRegenerationAction =
      cmakeRegenerationBuildAction(cmakeMeta, publicCliPath)
    let cmakeCacheRoot = outDir / "cmake-regeneration-cache"
    var cmakeFastHit = false
    if reportMode == brmNone and logMode == blmQuiet:
      var cmakeCache = openActionCache(cmakeCacheRoot / "action-cache")
      defer:
        cmakeCache.flushHotIndex()
      let outputStatStart = statStart(statsEnabled)
      let outputsPresent = cmakeRegenerationAction.actionOutputsPresent()
      finishStat(buildStats, statsEnabled, "repro output stat", outputStatStart)
      if outputsPresent:
        let lookupStart = statStart(statsEnabled)
        let hot = cmakeCache.lookupHotMetadataRecord(
          cmakeRegenerationAction.weakFingerprint,
          cmakeRegenerationAction.actionCachePolicy)
        if hot.isSome and cmakeCache.hotMetadataInputsUnchanged():
          cmakeFastHit = true
          cmakeRegenerationResult.results.add(ActionResult(
            id: cmakeRegenerationAction.id,
            status: asCacheHit,
            launched: false,
            cacheDecision: cdHit,
            dependencyPolicyKind: cmakeRegenerationAction.dependencyPolicy.kind))
        finishStat(buildStats, statsEnabled, "repro cache lookup", lookupStart)
    if not cmakeFastHit:
      let stateStart = statStart(statsEnabled)
      let stateFresh = cmakeGeneratedStateFresh(cmakeMeta, publicCliPath)
      finishStat(buildStats, statsEnabled, "repro cmake state check",
        stateStart)
      if stateFresh:
        discard seedCmakeRegenerationCache(cmakeMeta, publicCliPath, outDir)
        cmakeFastHit = true
        cmakeRegenerationResult.results.add(ActionResult(
          id: cmakeRegenerationAction.id,
          status: asCacheHit,
          launched: false,
          cacheDecision: cdHit,
          dependencyPolicyKind: cmakeRegenerationAction.dependencyPolicy.kind))
    if not cmakeFastHit:
      var cmakeRegenerationConfig = BuildEngineConfig(
        cacheRoot: cmakeCacheRoot,
        runQuotaCliPath: publicCliPath,
        monitorCliPath: siblingFsSnoopPath(publicCliPath),
        maxParallelism: 1'u32,
        stdoutLimit: 1024 * 1024,
        stderrLimit: 1024 * 1024,
        rebuildMissingOutputsOnCacheHit: true,
        deferLocalOutputBlobs: true,
        bypassRunQuota: bypassRunQuota,
        fallbackToRunQuotaBypass: fallbackToRunQuotaBypass,
        inlineRunQuota: true,
        suppressTrace: reportMode == brmNone,
        skipCacheHitEvidence: reportMode == brmNone and logMode == blmQuiet)
      cmakeRegenerationConfig.statsEnabled = statsEnabled
      cmakeRegenerationResult = runBuild(graph([cmakeRegenerationAction]),
        cmakeRegenerationConfig)
      buildStats.mergeStats(cmakeRegenerationResult.stats)
    finishStat(buildStats, statsEnabled, "repro cmake regeneration",
      cmakeRegenerationStart)
    warnRunQuotaBypassIfUsed(cmakeRegenerationResult)
    for item in cmakeRegenerationResult.results:
      logAction("cmakeRegenerationAction: " & item.id & " status=" &
        $item.status & " launched=" & $item.launched & " cache=" &
        $item.cacheDecision)
      if logMode != blmQuiet and item.stdout.len > 0:
        stdout.write(item.stdout)
        stdout.flushFile()
      if logMode != blmQuiet and item.stderr.len > 0:
        stderr.write(item.stderr)
        stderr.flushFile()
    if cmakeRegenerationResult.hasFailedActions():
      raise newException(OSError,
        "CMake regeneration edge failed: " &
          providerCompileFailure(cmakeRegenerationResult))
    for item in cmakeRegenerationResult.results:
      if item.launched and item.status == asSucceeded:
        cmakeRegenerated = true

  let pathEnv = getEnv("PATH")
  let cacheSelectedActionId =
    if parsedTarget.selectedActionId.len > 0:
      parsedTarget.selectedActionId
    elif selectDefaultAction and logMode == blmQuiet:
      ""
    else:
      "\0"
  if cmakeMeta.enabled and not cmakeRegenerated and not prepareOnly and
      mode == tpmPathOnly and reportMode == brmNone and
      cacheSelectedActionId != "\0":
    let loweredCacheStart = statStart(statsEnabled)
    let loweredCache = readFreshLoweredGraphCache(
      loweredGraphCachePath(outDir, cacheSelectedActionId), modulePath,
      result.projectRoot, cacheSelectedActionId, pathEnv)
    finishStat(buildStats, statsEnabled, "repro lowered graph cache read",
      loweredCacheStart)
    if loweredCache.isSome:
      logSummary("loweredGraphCache: hit")
      result.exitCode = runLoweredGraphBuild(loweredCache.get(),
        cacheSelectedActionId)
      return

  let interfacePath = outDir / "project-interface.rbsz"
  let stubPath = outDir / "project-interface.nim"
  let compileWorkDir = reprobuildLibraryWorkDir()
  let compileScratchDir = outDir / "provider-work"
  let interfaceStart = statStart(statsEnabled)
  let artifact = extractInterfaceFromModule(modulePath, interfacePath, stubPath,
    compileWorkDir, compileScratchDir)
  finishStat(buildStats, statsEnabled, "repro interface extract",
    interfaceStart)

  if artifact.projectInterface.toolUses.len > 0 and mode == tpmUnspecified:
    raise newException(ValueError,
      "typed tool provisioning is required for uses declarations; refusing " &
        "implicit PATH fallback. Pass --tool-provisioning=path to use the " &
        "explicit weak local profile.")

  if mode in {tpmPathOnly, tpmNix, tpmTarball, tpmScoop}:
    let identityStart = statStart(statsEnabled)
    let resolved = resolveAndWriteIdentity(artifact, outDir, mode)
    finishStat(buildStats, statsEnabled, "repro tool identity resolve",
      identityStart)
    let identity = resolved.identity
    logSummary("repro build: tool provisioning active (tool-provisioning=" &
      mode.modeName & ")")
    if mode == tpmPathOnly:
      logSummary("repro build: provisioning-disabled mode active (tool-provisioning=path)")
    logSummary("project: " & artifact.projectInterface.projectName)
    logSummary("interface: " & interfacePath)
    logSummary("toolIdentity: " & resolved.identityPath)
    logSummary("inspection: " & resolved.inspectionPath)
    let portability =
      if mode == tpmNix:
        "portable"
      elif mode == tpmTarball:
        "portable"
      elif mode == tpmScoop:
        # Scoop receipts may be cache-portable or cache-local depending on
        # the practical hardening tier. Read the resolved identity to find
        # out, defaulting to local-only when no profiles are present.
        var anyLocal = false
        var anyPortable = false
        for profile in identity.profiles:
          if profile.cachePortability == cpPortable:
            anyPortable = true
          else:
            anyLocal = true
        if anyPortable and not anyLocal:
          "portable"
        elif anyPortable and anyLocal:
          "mixed"
        else:
          "local-only"
      else:
        "local-only"
    logSummary("cachePortability: " & portability)
    logSummary("runQuotaSocket: " & runQuotaSocketDiagnostic())
    if not moduleHasBuildBlock(modulePath):
      result.exitCode = 0
      return
    let providerBinaryPath = outDir / "provider" / "project-provider"
    let providerArtifactPath = outDir / "provider-compile.rbsz"
    logSummary("providerCompile: started")
    let providerCompileStart = statStart(statsEnabled)
    var providerCompileResult: BuildRunResult
    var provider: ProviderCompileArtifact
    let cachedProvider = readFreshProviderCompileArtifact(providerArtifactPath,
      modulePath, providerBinaryPath, artifact.interfaceFingerprint)
    if cachedProvider.isSome:
      provider = cachedProvider.get()
    else:
      let providerPlan = providerCompilePlan(modulePath, providerBinaryPath,
        artifact.interfaceFingerprint, compileWorkDir, compileScratchDir)
      invalidateStaleProviderCompileArtifact(providerPlan, providerArtifactPath)
      let providerCompileAction = providerCompileBuildAction(providerPlan,
        modulePath, interfacePath, providerArtifactPath, publicCliPath,
        compileWorkDir, compileScratchDir)
      var providerCompileConfig = BuildEngineConfig(
        cacheRoot: outDir / "build-engine-cache",
        runQuotaCliPath: publicCliPath,
        maxParallelism: 1'u32,
        stdoutLimit: 1024 * 1024,
        stderrLimit: 1024 * 1024,
        rebuildMissingOutputsOnCacheHit: true,
        deferLocalOutputBlobs: true,
        bypassRunQuota: bypassRunQuota,
        fallbackToRunQuotaBypass: fallbackToRunQuotaBypass,
        inlineRunQuota: true,
        suppressTrace: reportMode == brmNone,
        skipCacheHitEvidence: reportMode == brmNone and logMode == blmQuiet)
      providerCompileConfig.statsEnabled = statsEnabled
      providerCompileResult = runBuild(graph([providerCompileAction]),
        providerCompileConfig)
      buildStats.mergeStats(providerCompileResult.stats)
      warnRunQuotaBypassIfUsed(providerCompileResult)
      for item in providerCompileResult.results:
        logAction("providerCompileAction: " & item.id & " status=" &
          $item.status & " launched=" & $item.launched & " cache=" &
          $item.cacheDecision)
      if providerCompileResult.hasFailedActions():
        raise newException(OSError, providerCompileFailure(providerCompileResult))
      if not fileExists(extendedPath(providerArtifactPath)):
        raise newException(IOError,
          "provider compile edge did not write artifact: " & providerArtifactPath)
      provider = readProviderCompileArtifact(providerArtifactPath)
      if not providerCompileArtifactFresh(providerArtifactPath,
          providerPlan.outputBinaryPath, providerPlan.interfaceFingerprint,
          providerPlan.providerFingerprint):
        raise newException(IOError,
          "provider compile artifact is stale after edge execution: " &
            providerArtifactPath)
    finishStat(buildStats, statsEnabled, "repro provider compile",
      providerCompileStart)
    let providerArtifactId = digestHex(provider.providerFingerprint)
    logSummary("providerBinary: " & provider.outputBinaryPath)
    logSummary("providerCompileArtifact: " & providerArtifactPath)
    logSummary("providerArtifact: " & providerArtifactId)

    let projectRoot = result.projectRoot
    let providerGraphStart = statStart(statsEnabled)
    let refresh = refreshProviderGraph(RefreshConfig(
      storeRoot: outDir / "provider-graph",
      providerBinaryPath: provider.outputBinaryPath,
      providerArtifactId: providerArtifactId,
      rootEntryPointId: artifact.projectInterface.packageName & ".root",
      rootArguments: projectRoot,
      namespace: "project",
      lockSliceId: digestHex(artifact.interfaceFingerprint),
      activity: "build",
      providerWorkingDir: projectRoot))
    finishStat(buildStats, statsEnabled, "repro provider graph refresh",
      providerGraphStart)
    logSummary("providerGraphSnapshot: " & refresh.persistedSnapshotPath)
    logSummary("providerInvocations: " & $refresh.invoked.len)

    var selectedActionId = parsedTarget.selectedActionId
    if selectDefaultAction and selectedActionId.len == 0:
      selectedActionId = defaultBuildActionId(refresh.snapshot)
      if selectedActionId.len > 0:
        logSummary("defaultTarget: " & selectedActionId)

    let graphLowerStart = statStart(statsEnabled)
    let lowered = lowerProviderSnapshot(refresh.snapshot, identity, projectRoot,
      selectedActionId)
    finishStat(buildStats, statsEnabled, "repro graph lower", graphLowerStart)
    if cmakeMeta.enabled and mode == tpmPathOnly and selectedActionId.len > 0:
      let cacheWriteStart = statStart(statsEnabled)
      writeLoweredGraphCache(loweredGraphCachePath(outDir, selectedActionId),
        modulePath, projectRoot, selectedActionId, pathEnv, lowered)
      if selectDefaultAction and parsedTarget.selectedActionId.len == 0:
        writeLoweredGraphCache(loweredGraphCachePath(outDir, ""), modulePath,
          projectRoot, "", pathEnv, lowered)
      finishStat(buildStats, statsEnabled, "repro lowered graph cache write",
        cacheWriteStart)
    if prepareOnly:
      if cmakeMeta.enabled:
        createDir(extendedPath(parentDir(cmakeMeta.providerStateFile)))
        writeFile(extendedPath(cmakeMeta.providerStateFile), readFile(extendedPath(modulePath)))
        let seedStart = statStart(statsEnabled)
        discard seedCmakeRegenerationCache(cmakeMeta, publicCliPath, outDir)
        finishStat(buildStats, statsEnabled,
          "repro cmake regeneration cache seed", seedStart)
      finishStat(buildStats, statsEnabled, "repro build total",
        buildTotalStart)
      if statsEnabled:
        let statsRenderStart = statStart(statsEnabled)
        stderr.write(renderBuildStats(buildStats))
        stderr.flushFile()
        finishStat(buildStats, statsEnabled, "repro stats render",
          statsRenderStart)
      result.exitCode = 0
      return
    if parsedTarget.fragmentKind == tfkActionSelection:
      logSummary("selectedTarget: " & parsedTarget.selectedActionId)
    elif selectDefaultAction and selectedActionId.len > 0:
      logSummary("selectedTarget: " & selectedActionId)
    logSummary("scheduler: actions=" & $lowered.actions.len)
    if lowered.actions.len == 0:
      result.exitCode = 0
      return
    var progressRenderer = newBuildProgressRenderer(progressMode)
    var engineConfig = BuildEngineConfig(
      cacheRoot: outDir / "build-engine-cache",
      runQuotaCliPath: publicCliPath,
      maxParallelism: buildMaxParallelism(),
      stdoutLimit: 1024 * 1024,
      stderrLimit: 1024 * 1024,
      rebuildMissingOutputsOnCacheHit: true,
      deferLocalOutputBlobs: true,
      bypassRunQuota: bypassRunQuota,
      fallbackToRunQuotaBypass: fallbackToRunQuotaBypass,
      inlineRunQuota: true,
      suppressTrace: reportMode == brmNone,
      skipCacheHitEvidence: reportMode == brmNone and logMode == blmQuiet)
    engineConfig.statsEnabled = statsEnabled
    if progressRenderer.enabled:
      engineConfig.progressCallback = proc(event: BuildProgressEvent) =
        progressRenderer.renderProgress(event)
    var buildResult: BuildRunResult
    let engineStart = statStart(statsEnabled)
    try:
      buildResult = runBuild(graph(lowered.actions, lowered.pools), engineConfig)
    finally:
      progressRenderer.finishProgress()
    finishStat(buildStats, statsEnabled, "repro engine runBuild", engineStart)
    buildStats.mergeStats(buildResult.stats)
    warnRunQuotaBypassIfUsed(buildResult)
    finishStat(buildStats, statsEnabled, "repro build total", buildTotalStart)
    buildResult.stats = buildStats
    let reportPath = outDir / "build-report.json"
    if reportMode == brmFull:
      let reportStart = statStart(statsEnabled)
      writeBuildReport(reportPath, provider, refresh, cmakeRegenerationResult,
        providerCompileResult, buildResult)
      finishStat(buildStats, statsEnabled, "repro report write", reportStart)
      buildResult.stats = buildStats
      result.buildReportPath = reportPath
    let actionLogStart = statStart(statsEnabled)
    for item in buildResult.results:
      logAction("action: " & item.id & " status=" & $item.status &
        " launched=" & $item.launched & " cache=" & $item.cacheDecision &
        " runquota=" & item.runQuotaBackend &
        " socket=" & (if item.runQuotaSocket.len >
            0: item.runQuotaSocket else: "default") &
        " lease=" & $item.leaseId &
        " evidence=depfile:" & $item.evidence.depfileInputs.len)
    if reportMode == brmFull:
      logSummary("buildReport: " & reportPath)
    finishStat(buildStats, statsEnabled, "repro action log render",
      actionLogStart)
    buildResult.stats = buildStats
    if statsEnabled:
      let statsRenderStart = statStart(statsEnabled)
      stderr.write(renderBuildStats(buildResult.stats))
      stderr.flushFile()
      finishStat(buildStats, statsEnabled, "repro stats render",
        statsRenderStart)
    result.exitCode =
      if buildResult.hasFailedActions():
        1
      else:
        0
    return

  echo "repro build: no external tools requested"
  echo "interface: " & interfacePath
  result.exitCode = 0

proc isUnderReproDir(path: string): bool =
  for part in path.split({'/', '\\'}):
    if part == ".repro":
      return true

proc addWatchCandidate(paths: var HashSet[string]; projectRoot, path: string) =
  if path.len == 0:
    return
  var candidate =
    if path.isAbsolute:
      path
    else:
      projectRoot / path
  candidate = os.normalizedPath(candidate)
  if candidate.isUnderReproDir():
    return
  paths.incl(candidate)
  let parent = parentDir(candidate)
  if parent.len > 0 and not parent.isUnderReproDir():
    paths.incl(parent)

proc watchPathsFromReport(outcome: BuildCommandOutcome): seq[string] =
  var paths = initHashSet[string]()
  addWatchCandidate(paths, outcome.projectRoot, outcome.modulePath)
  if outcome.buildReportPath.len > 0 and fileExists(extendedPath(outcome.buildReportPath)):
    let report = parseFile(outcome.buildReportPath)
    for action in report{"actions"}:
      let evidence = action{"evidence"}
      for key in ["declaredInputs", "depfileInputs", "monitorReads",
          "monitorProbes"]:
        for item in evidence{key}:
          addWatchCandidate(paths, outcome.projectRoot, item.getStr())
  result = toSeq(paths)
  result.sort()

proc flushStdout() =
  stdout.flushFile()

proc binDirsForDevelop(identity: PathOnlyBuildIdentity): seq[string] =
  for profile in identity.profiles:
    if profile.installMethod == "nix":
      for storePath in profile.realizedStorePaths:
        let binDir = storePath / "bin"
        if dirExists(extendedPath(binDir)) and not result.contains(binDir):
          result.add(binDir)
    else:
      for binDir in profile.pathSearchList:
        if binDir.len > 0 and dirExists(extendedPath(binDir)) and not result.contains(binDir):
          result.add(binDir)

proc runInDevelopEnvironment(command: openArray[string]; projectRoot: string;
                             identity: PathOnlyBuildIdentity;
                             identityPath, inspectionPath,
                             interfacePath: string): int =
  if command.len == 0:
    raise newException(ValueError, "develop command is empty")
  let profileBinDirs = binDirsForDevelop(identity)
  let pathValue =
    if profileBinDirs.len > 0:
      profileBinDirs.join($PathSep) & $PathSep & getEnv("PATH")
    else:
      getEnv("PATH")
  let artifact = DevEnvArtifact(
    projectRoot: projectRoot,
    selectedActivities: @["develop"],
    shellOps: @[
      DevEnvShellOp(kind: deskSetEnv, name: "PATH", value: pathValue),
      DevEnvShellOp(kind: deskSetEnv, name: "REPRO_TOOL_PROFILE_ARTIFACT",
        value: identityPath),
      DevEnvShellOp(kind: deskSetEnv, name: "REPRO_TOOL_PROFILE_INSPECTION",
        value: inspectionPath),
      DevEnvShellOp(kind: deskSetEnv, name: "REPRO_PROJECT_INTERFACE",
        value: interfacePath),
      DevEnvShellOp(kind: deskSetEnv, name: "REPRO_PROJECT_ROOT",
        value: projectRoot)
    ])
  runActivatedCommand(artifact, "", command, projectRoot)

proc valueAfterFlag(args: openArray[string]; flag: string): string =
  var i = 0
  while i < args.len:
    if args[i] == flag and i + 1 < args.len:
      return args[i + 1]
    inc i
  ""

proc navigatorStatsJson(stats: DevEnvNavigatorStats): JsonNode =
  %*{
    "envelopeBytesChecked": stats.envelopeBytesChecked,
    "payloadBytesHashed": stats.payloadBytesHashed,
    "payloadHeaderBytesRead": stats.payloadHeaderBytesRead,
    "shellOpRecordsDecoded": stats.shellOpRecordsDecoded,
    "taskRecordsDecoded": stats.taskRecordsDecoded,
    "serviceRecordsDecoded": stats.serviceRecordsDecoded,
    "maxDecodedPayloadOffset": stats.maxDecodedPayloadOffset,
    "shellOpsSectionStart": stats.shellOpsSectionStart,
    "shellOpsSectionEnd": stats.shellOpsSectionEnd,
    "tasksSectionStart": stats.tasksSectionStart,
    "servicesSectionStart": stats.servicesSectionStart
  }

proc runProviderCompileHelper(args: openArray[string]): int =
  let modulePath = valueAfterFlag(args, "--module")
  let outputPath = valueAfterFlag(args, "--out")
  let artifactPath = valueAfterFlag(args, "--artifact")
  let interfacePath = valueAfterFlag(args, "--interface")
  let workDir = valueAfterFlag(args, "--work-dir")
  let scratchDir = valueAfterFlag(args, "--scratch-dir")
  for (name, value) in [
    ("--module", modulePath),
    ("--out", outputPath),
    ("--artifact", artifactPath),
    ("--interface", interfacePath),
    ("--work-dir", workDir)
  ]:
    if value.len == 0:
      stderr.writeLine("repro provider compile: missing " & name)
      return 2
  try:
    let interfaceArtifact = readInterfaceArtifact(interfacePath)
    discard compileProviderBinary(modulePath, outputPath,
      interfaceArtifact.interfaceFingerprint, artifactPath, workDir, scratchDir)
    return 0
  except CatchableError as err:
    stderr.writeLine("repro provider compile: error: " & err.msg)
    return 1

proc splitDevEnvActivities(value: string): seq[string] =
  let source = if value.len > 0: value else: "default"
  for raw in source.split(','):
    let item = raw.strip()
    if item.len > 0:
      result.add(item)
  if result.len == 0:
    result.add("default")

proc descriptorById(manifest: ProviderManifest; id: string):
    Option[GraphEntryPointDescriptor] =
  for descriptor in manifest.entryPoints:
    if descriptor.id == id:
      return some(descriptor)
  none(GraphEntryPointDescriptor)

proc validateDevEnvManifest(manifest: ProviderManifest;
                            providerArtifactId: string) =
  if manifest.protocolVersion != ProviderProtocolVersion:
    raise newException(ValueError, "unsupported provider protocol version " &
      $manifest.protocolVersion)
  if providerArtifactId.len > 0 and
      manifest.providerArtifactId != providerArtifactId:
    raise newException(ValueError,
      "provider manifest artifact mismatch: expected " &
        providerArtifactId & ", got " & manifest.providerArtifactId)

proc runStableProviderProtocol(binaryPath, protocolRoot, stem, cwd: string;
                               request: ProviderGraphRequest):
                               ProviderGraphResponse =
  createDir(extendedPath(protocolRoot))
  let requestPath = protocolRoot / (stem & ".request.rbpg")
  let responsePath = protocolRoot / (stem & ".response.rbpg")
  writeProviderRequestFile(requestPath, request)
  if fileExists(extendedPath(responsePath)):
    removeFile(extendedPath(responsePath))
  let process = startProcess(binaryPath,
    args = @[
      "--repro-provider-request", requestPath,
      "--repro-provider-response", responsePath
    ],
    workingDir = cwd,
    options = {poUsePath, poStdErrToStdOut})
  let output =
    if process.outputStream != nil: process.outputStream.readAll()
    else: ""
  let exitCode = process.waitForExit()
  process.close()
  if exitCode != 0:
    raise newException(OSError,
      "provider exited with code " & $exitCode & ": " & output)
  if not fileExists(extendedPath(responsePath)):
    raise newException(IOError, "provider did not write response: " &
      responsePath)
  readProviderResponseFile(responsePath)

proc runDevEnvIntrospectionHelper(args: openArray[string]): int =
  let providerBinary = valueAfterFlag(args, "--provider-binary")
  let providerArtifactId = valueAfterFlag(args, "--provider-artifact-id")
  let projectRoot = valueAfterFlag(args, "--project-root")
  let artifactPath = valueAfterFlag(args, "--out")
  let protocolRoot = valueAfterFlag(args, "--protocol-root")
  let entryPointId = valueAfterFlag(args, "--entry-point")
  let activity = valueAfterFlag(args, "--activity")
  let lockSliceId = valueAfterFlag(args, "--lock-slice")
  let developOverridesPath = valueAfterFlag(args, "--develop-overrides")
  for (name, value) in [
    ("--provider-binary", providerBinary),
    ("--provider-artifact-id", providerArtifactId),
    ("--project-root", projectRoot),
    ("--out", artifactPath),
    ("--protocol-root", protocolRoot)
  ]:
    if value.len == 0:
      stderr.writeLine("repro dev-env introspection: missing " & name)
      return 2
  try:
    if developOverridesPath.len > 0:
      putEnv("REPRO_DEVELOP_OVERRIDES_FILE", developOverridesPath)
    let cwd = if projectRoot.len > 0: projectRoot else: getCurrentDir()
    let manifestResponse = runStableProviderProtocol(providerBinary,
      protocolRoot, "manifest", cwd, ProviderGraphRequest(
        kind: prkManifest,
        providerArtifactId: providerArtifactId,
        reason: girExplicitUserRequest))
    if manifestResponse.kind != pskManifest:
      raise newException(ValueError,
        "provider manifest request returned non-manifest response")
    validateDevEnvManifest(manifestResponse.manifest, providerArtifactId)

    var selectedEntryPoint = entryPointId
    if selectedEntryPoint.len == 0:
      for descriptor in manifestResponse.manifest.entryPoints:
        if descriptor.kind == gpkDevEnvIntrospection:
          selectedEntryPoint = descriptor.id
          break
    if selectedEntryPoint.len == 0:
      raise newException(ValueError,
        "provider manifest does not expose dev-env introspection")
    let descriptorOpt = manifestResponse.manifest.descriptorById(
      selectedEntryPoint)
    if descriptorOpt.isNone:
      raise newException(ValueError,
        "dev-env entry point is missing from provider manifest")
    let descriptor = descriptorOpt.get()
    if descriptor.kind != gpkDevEnvIntrospection:
      raise newException(ValueError,
        "entry point is not dev-env introspection: " & selectedEntryPoint)

    let selectedActivity = if activity.len > 0: activity else: "default"
    let request = ProviderGraphRequest(
      kind: prkDevEnvIntrospection,
      providerArtifactId: providerArtifactId,
      entryPointId: selectedEntryPoint,
      entryPointBodyHash: descriptor.bodyHash,
      reason: girExplicitUserRequest,
      arguments: projectRoot,
      lockSliceId: lockSliceId,
      activity: selectedActivity)
    let response = runStableProviderProtocol(providerBinary, protocolRoot,
      "dev-env", cwd, request)
    if response.kind != pskDevEnvResult:
      raise newException(ValueError,
        "provider dev-env request did not return a dev-env result")
    validateDevEnvManifest(response.manifest, providerArtifactId)
    if response.devEnv.providerArtifactId != providerArtifactId:
      raise newException(ValueError, "provider artifact mismatch in dev-env result")
    if response.devEnv.providerEntryPointId != selectedEntryPoint:
      raise newException(ValueError, "provider entry point mismatch in dev-env result")
    if response.devEnv.providerEntryPointBodyHash != descriptor.bodyHash:
      raise newException(ValueError, "provider body hash mismatch in dev-env result")
    if response.devEnv.projectRoot != projectRoot:
      raise newException(ValueError, "project root mismatch in dev-env result")
    if response.devEnv.lockSliceId != lockSliceId:
      raise newException(ValueError, "lock slice mismatch in dev-env result")
    if response.devEnv.selectedActivities !=
        splitDevEnvActivities(selectedActivity):
      raise newException(ValueError, "activity selection mismatch in dev-env result")

    writeDevEnvArtifact(artifactPath, artifactFromDevEnvResult(response.devEnv))
    return 0
  except CatchableError as err:
    stderr.writeLine("repro dev-env introspection: error: " & err.msg)
    return 1

proc runDevEnvShellRenderHelper(args: openArray[string]): int =
  let artifactPath = valueAfterFlag(args, "--artifact")
  let outputPath = valueAfterFlag(args, "--out")
  let navigatorStatsPath = valueAfterFlag(args, "--navigator-stats")
  for (name, value) in [
    ("--artifact", artifactPath),
    ("--out", outputPath)
  ]:
    if value.len == 0:
      stderr.writeLine("repro dev-env shell render: missing " & name)
      return 2
  try:
    var navigatorStats: DevEnvNavigatorStats
    let ops = shellOpsFromNavigatorFile(artifactPath, navigatorStats)
    createDir(extendedPath(parentDir(outputPath)))
    writeFile(extendedPath(outputPath), renderDevEnvShellOps(ops, depPosix))
    if navigatorStatsPath.len > 0:
      createDir(extendedPath(parentDir(navigatorStatsPath)))
      writeFile(extendedPath(navigatorStatsPath),
        pretty(navigatorStatsJson(navigatorStats)) & "\n")
    return 0
  except CatchableError as err:
    stderr.writeLine("repro dev-env shell render: error: " & err.msg)
    return 1

type
  DevelopOverrideEntry = object
    node: string
    path: string

  DevEnvCliSelection = object
    selector: string
    modulePath: string
    projectRoot: string
    outDir: string
    workRoot: string
    activity: string
    lockSliceId: string
    developOverridesPath: string
    statsPath: string

  ParsedDevEnvExec = object
    selection: DevEnvCliSelection
    command: seq[string]

  ParsedDevEnvShell = object
    selection: DevEnvCliSelection
    printEnv: bool
    printFormat: DevEnvPrintFormat
    shellPath: string

proc valueFromFlag(args: openArray[string]; i: var int; flag: string): string =
  let arg = args[i]
  if arg.startsWith(flag & "="):
    return arg.split("=", maxsplit = 1)[1]
  if arg == flag:
    if i + 1 >= args.len:
      raise newException(ValueError, flag & " requires a value")
    inc i
    return args[i]
  ""

proc appendActivitySelection(current: var string; value: string) =
  for raw in value.split(','):
    let item = raw.strip()
    if item.len == 0:
      continue
    if current.len == 0:
      current = item
    elif current.split(',').find(item) < 0:
      current.add("," & item)

proc gitDirForProjectRoot(projectRoot: string): string =
  let dotGit = projectRoot / ".git"
  if dirExists(extendedPath(dotGit)):
    return dotGit
  if fileExists(extendedPath(dotGit)):
    let content = readFile(extendedPath(dotGit)).strip()
    const prefix = "gitdir:"
    if content.normalize().startsWith(prefix):
      let raw = content[prefix.len .. ^1].strip()
      if raw.isAbsolute:
        return os.normalizedPath(raw)
      return os.normalizedPath(projectRoot / raw)
  ""

proc developOverridesMetadataPath(projectRoot: string): string =
  let gitDir = gitDirForProjectRoot(projectRoot)
  if gitDir.len > 0:
    return gitDir / "reprobuild" / "develop-overrides.json"
  projectRoot / ".repro" / "local" / "develop-overrides.json"

proc readDevelopOverrides(path: string): seq[DevelopOverrideEntry] =
  if path.len == 0 or not fileExists(extendedPath(path)):
    return @[]
  let root = parseFile(extendedPath(path))
  if root.kind != JObject or not root.hasKey("overrides"):
    return @[]
  for item in root["overrides"]:
    if item.kind != JObject:
      continue
    let node = item{"node"}.getStr()
    let localPath = item{"path"}.getStr()
    if node.len > 0 and localPath.len > 0:
      result.add(DevelopOverrideEntry(node: node, path: localPath))

proc writeDevelopOverrides(path, projectRoot: string;
                           entries: openArray[DevelopOverrideEntry]) =
  var sorted = @entries
  sorted.sort(proc (a, b: DevelopOverrideEntry): int = cmp(a.node, b.node))
  var overrides = newJArray()
  for entry in sorted:
    overrides.add(%*{
      "node": entry.node,
      "path": entry.path
    })
  let payload = %*{
    "schemaId": "reprobuild.develop-overrides.v1",
    "projectRoot": projectRoot,
    "overrides": overrides
  }
  createDir(extendedPath(parentDir(path)))
  let tmp = path & ".tmp"
  writeFile(extendedPath(tmp), pretty(payload) & "\n")
  if fileExists(extendedPath(path)):
    removeFile(extendedPath(path))
  moveFile(extendedPath(tmp), extendedPath(path))

proc findDevEnvProjectRoot(startPath: string): string

proc activeProjectRootFromCwd(): string =
  result = findDevEnvProjectRoot(getCurrentDir())
  if result.len == 0:
    raise newException(ValueError,
      "repro develop requires a current project containing reprobuild.nim")

proc resolveDevelopOverrideCheckout(dependency, intoPath: string): string =
  if intoPath.len == 0:
    raise newException(ValueError,
      "repro develop <dependency> requires --into=PATH for local overrides")
  let intoAbs = os.normalizedPath(absolutePath(intoPath))
  var candidates = @[intoAbs]
  let (_, tail) = splitPath(intoAbs)
  if tail != dependency:
    candidates.add(intoAbs / safePathSegment(dependency, "dependency"))
  for candidate in candidates:
    if fileExists(extendedPath(candidate / "reprobuild.nim")):
      return os.normalizedPath(candidate)
  raise newException(IOError,
    "develop override checkout for " & dependency &
      " must already exist and contain reprobuild.nim under " &
      candidates.join(" or "))

proc upsertDevelopOverride(projectRoot, dependency, localPath: string): string =
  result = developOverridesMetadataPath(projectRoot)
  var entries = readDevelopOverrides(result)
  var replaced = false
  for entry in entries.mitems:
    if entry.node == dependency:
      entry.path = localPath
      replaced = true
  if not replaced:
    entries.add(DevelopOverrideEntry(node: dependency, path: localPath))
  writeDevelopOverrides(result, projectRoot, entries)

proc devEnvActivitySegment(activity: string): string =
  safePathSegment(if activity.len > 0: activity else: "default", "default")

proc defaultDevEnvOutDir(modulePath, workRoot, activity: string): string =
  let scopedRoot = scopedWorktreeRoot(modulePath, workRoot)
  if scopedRoot.len > 0:
    return scopedRoot / "dev-env" / devEnvActivitySegment(activity)
  parentDir(modulePath) / ".repro" / "dev-env" /
    devEnvActivitySegment(activity)

proc resolveDevEnvSelection(selection: var DevEnvCliSelection) =
  if selection.selector.len == 0:
    selection.selector = "."
  if selection.activity.len == 0:
    selection.activity = "default"
  selection.modulePath = absolutePath(moduleForTarget(selection.selector))
  if not fileExists(extendedPath(selection.modulePath)):
    raise newException(IOError,
      "dev-env target module not found: " & selection.modulePath)
  selection.projectRoot = projectRootForModule(selection.modulePath)
  selection.developOverridesPath =
    developOverridesMetadataPath(selection.projectRoot)
  selection.outDir = defaultDevEnvOutDir(selection.modulePath,
    selection.workRoot, selection.activity)

proc parseDevEnvExecArgs(args: openArray[string]): ParsedDevEnvExec =
  var selection = DevEnvCliSelection()
  var afterSeparator = false
  var i = 0
  while i < args.len:
    let arg = args[i]
    if afterSeparator:
      result.command.add(arg)
    elif arg == "--":
      afterSeparator = true
    elif arg == "--activity" or arg.startsWith("--activity="):
      selection.activity.appendActivitySelection(valueFromFlag(args, i,
        "--activity"))
    elif arg == "--work-root" or arg.startsWith("--work-root="):
      selection.workRoot = valueFromFlag(args, i, "--work-root")
    elif arg == "--lock-slice" or arg.startsWith("--lock-slice="):
      selection.lockSliceId = valueFromFlag(args, i, "--lock-slice")
    elif arg == "--dev-env-stats" or arg.startsWith("--dev-env-stats="):
      selection.statsPath = valueFromFlag(args, i, "--dev-env-stats")
    elif arg.startsWith("-"):
      raise newException(ValueError, "unsupported exec flag: " & arg)
    elif selection.selector.len == 0:
      selection.selector = arg
    else:
      raise newException(ValueError,
        "unexpected exec argument before --: " & arg)
    inc i
  if result.command.len == 0:
    raise newException(ValueError,
      "repro exec requires -- <command> [args...]")
  selection.resolveDevEnvSelection()
  result.selection = selection

proc parseDevEnvShellArgs(args: openArray[string]): ParsedDevEnvShell =
  var selection = DevEnvCliSelection()
  result.printFormat = depPosix
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--activity" or arg.startsWith("--activity="):
      selection.activity.appendActivitySelection(valueFromFlag(args, i,
        "--activity"))
    elif arg == "--work-root" or arg.startsWith("--work-root="):
      selection.workRoot = valueFromFlag(args, i, "--work-root")
    elif arg == "--lock-slice" or arg.startsWith("--lock-slice="):
      selection.lockSliceId = valueFromFlag(args, i, "--lock-slice")
    elif arg == "--dev-env-stats" or arg.startsWith("--dev-env-stats="):
      selection.statsPath = valueFromFlag(args, i, "--dev-env-stats")
    elif arg == "--shell" or arg.startsWith("--shell="):
      result.shellPath = valueFromFlag(args, i, "--shell")
    elif arg == "--print-env" or arg.startsWith("--print-env="):
      result.printEnv = true
      result.printFormat = parseDevEnvPrintFormat(valueFromFlag(args, i,
        "--print-env"))
    elif arg.startsWith("-"):
      raise newException(ValueError, "unsupported shell flag: " & arg)
    elif selection.selector.len == 0:
      selection.selector = arg
    else:
      raise newException(ValueError,
        "unexpected shell argument: " & arg)
    inc i
  selection.resolveDevEnvSelection()
  result.selection = selection

proc publicDevEnvFsSnoop(publicCliPath: string): string =
  result = siblingFsSnoopPath(publicCliPath)
  if result.len > 0:
    return
  result = getEnv("REPRO_FS_SNOOP")
  if result.len > 0:
    return
  let candidate = reprobuildLibraryWorkDir() / "build" / "bin" /
    addFileExt("repro-fs-snoop", ExeExt)
  if fileExists(extendedPath(candidate)):
    result = os.normalizedPath(candidate)

proc computePublicDevEnv(selection: DevEnvCliSelection;
                         publicCliPath: string;
                         renderShell = false): DevEnvEdgeResult =
  computeDevEnvEdge(DevEnvEdgeConfig(
    modulePath: selection.modulePath,
    projectRoot: selection.projectRoot,
    outDir: selection.outDir,
    workDir: reprobuildLibraryWorkDir(),
    publicCliPath: publicCliPath,
    monitorCliPath: publicDevEnvFsSnoop(publicCliPath),
    monitorShimLibPath: getEnv("REPRO_MONITOR_SHIM_LIB"),
    activity: selection.activity,
    lockSliceId: selection.lockSliceId,
    developOverridesPath: selection.developOverridesPath,
    renderShell: renderShell,
    statsEnabled: selection.statsPath.len > 0))

proc devEnvPerformanceEvidenceJson(edge: DevEnvEdgeResult): JsonNode =
  let devStats = edge.devEnvResult.stats
  let compileStats = edge.providerCompileResult.stats
  let introspectionInputs = edge.introspectionAction.evidence.evidenceInputCount()
  let shellInputs = edge.shellRenderAction.evidence.evidenceInputCount()
  let shellRenderPresent = edge.shellRenderAction.actionPresent()
  %*{
    "schemaId": "reprobuild.dev-env.performance-evidence.v1",
    "providerBuild": {
      "checks": 1,
      "launched": edge.stats.providerBuildLaunched,
      "skippedFresh": edge.stats.providerBuildSkippedFresh,
      "cacheHit": edge.stats.providerBuildCacheHit,
      "actionPresent": edge.providerCompileAction.actionPresent(),
      "actionStatus": $edge.providerCompileAction.status,
      "cacheLookupCount": compileStats.metricCount("repro cache lookup"),
      "cacheLookupTotalUs": compileStats.metricTotalUs("repro cache lookup"),
      "hotInputScanCount": compileStats.metricCount("repro hot input scan"),
      "outputStatCount": compileStats.metricCount("repro output stat"),
      "runBuildTotalUs": compileStats.metricTotalUs("repro scheduler total")
    },
    "providerIntrospection": {
      "actions": 1,
      "launched": edge.stats.providerIntrospectionLaunched,
      "cacheHit": edge.stats.providerIntrospectionCacheHit,
      "actionStatus": $edge.introspectionAction.status,
      "cacheDecision": $edge.introspectionAction.cacheDecision,
      "evidenceInputPathCount": introspectionInputs,
      "declaredInputCount": edge.introspectionAction.evidence.declaredInputs.len,
      "monitorReadCount": edge.introspectionAction.evidence.monitorReads.len,
      "monitorProbeCount": edge.introspectionAction.evidence.monitorProbes.len
    },
    "artifactLookup": {
      "artifactPath": edge.artifactPath,
      "artifactBytes": edge.artifactPath.fileSizeOrZero(),
      "artifactWriteLaunched": edge.stats.artifactWriteLaunched,
      "artifactWriteSkipped": edge.stats.artifactWriteSkipped,
      "introspectionCacheHit": edge.stats.providerIntrospectionCacheHit
    },
    "invalidation": {
      "cacheLookupCount": devStats.metricCount("repro cache lookup"),
      "cacheLookupTotalUs": devStats.metricTotalUs("repro cache lookup"),
      "hotRecordLookupCount": devStats.metricCount("repro hot record lookup"),
      "hotRecordLookupTotalUs": devStats.metricTotalUs("repro hot record lookup"),
      "hotInputScanCount": devStats.metricCount("repro hot input scan"),
      "hotInputScanTotalUs": devStats.metricTotalUs("repro hot input scan"),
      "fastNoopScanCount": devStats.metricCount("repro fast noop scan"),
      "fastNoopScanTotalUs": devStats.metricTotalUs("repro fast noop scan"),
      "outputStatCount": devStats.metricCount("repro output stat"),
      "checkedInputPathCount": introspectionInputs + shellInputs,
      "cacheHitResultMaterializeCount":
        devStats.metricCount("repro cache hit result materialize")
    },
    "shellRender": {
      "actions": if shellRenderPresent: 1 else: 0,
      "launched": edge.stats.shellRenderingLaunched,
      "cacheHit": edge.stats.shellRenderingCacheHit,
      "skipped": edge.stats.shellRenderingSkipped,
      "actionStatus": $edge.shellRenderAction.status,
      "cacheDecision": $edge.shellRenderAction.cacheDecision,
      "evidenceInputPathCount": shellInputs,
      "shellFragmentPath": edge.shellFragmentPath,
      "shellFragmentBytes": edge.shellFragmentPath.fileSizeOrZero(),
      "navigatorStatsPath": edge.shellNavigatorStatsPath,
      "navigatorStatsBytes": edge.shellNavigatorStatsPath.fileSizeOrZero()
    }
  }

proc devEnvStatsJson(edge: DevEnvEdgeResult; commandName: string): JsonNode =
  let navigatorStats =
    if edge.shellNavigatorStatsPath.len > 0 and fileExists(
        extendedPath(edge.shellNavigatorStatsPath)):
      parseFile(extendedPath(edge.shellNavigatorStatsPath))
    else:
      newJNull()
  %*{
    "schemaId": "reprobuild.dev-env.cli-stats.v1",
    "command": commandName,
    "artifactPath": edge.artifactPath,
    "shellFragmentPath": edge.shellFragmentPath,
    "shellNavigatorStatsPath": edge.shellNavigatorStatsPath,
    "shellNavigatorStats": navigatorStats,
    "providerArtifactPath": edge.providerArtifactPath,
    "providerBinaryPath": edge.providerBinaryPath,
    "providerArtifactId": edge.providerArtifactId,
    "stats": {
      "providerBuildLaunched": edge.stats.providerBuildLaunched,
      "providerBuildSkippedFresh": edge.stats.providerBuildSkippedFresh,
      "providerBuildCacheHit": edge.stats.providerBuildCacheHit,
      "providerIntrospectionLaunched": edge.stats.providerIntrospectionLaunched,
      "providerIntrospectionCacheHit": edge.stats.providerIntrospectionCacheHit,
      "artifactWriteLaunched": edge.stats.artifactWriteLaunched,
      "artifactWriteSkipped": edge.stats.artifactWriteSkipped,
      "shellRenderingLaunched": edge.stats.shellRenderingLaunched,
      "shellRenderingCacheHit": edge.stats.shellRenderingCacheHit,
      "shellRenderingSkipped": edge.stats.shellRenderingSkipped
    },
    "providerCompileAction": actionResultJson(edge.providerCompileAction),
    "introspectionAction": actionResultJson(edge.introspectionAction),
    "shellRenderAction": actionResultJson(edge.shellRenderAction),
    "providerCompileRunStats": statsJson(edge.providerCompileResult.stats),
    "devEnvRunStats": statsJson(edge.devEnvResult.stats),
    "performance": devEnvPerformanceEvidenceJson(edge)
  }

proc writeDevEnvStats(path: string; edge: DevEnvEdgeResult;
                      commandName: string) =
  if path.len == 0:
    return
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), $devEnvStatsJson(edge, commandName) & "\n")

proc emitDevEnvDiagnostics(artifact: DevEnvArtifact): bool =
  ## Returns true when an error diagnostic was emitted.
  for diagnostic in artifact.diagnostics:
    if diagnostic.severity == dedsInfo:
      continue
    let prefix =
      case diagnostic.severity
      of dedsInfo: "info"
      of dedsWarning: "warning"
      of dedsError: "error"
    stderr.writeLine("repro dev-env: " & prefix & ": " &
      diagnostic.message)
    if diagnostic.severity == dedsError:
      result = true

proc runReproExecCommand(args: openArray[string];
                         publicCliPath: string): int =
  let parsed = parseDevEnvExecArgs(args)
  let edge = computePublicDevEnv(parsed.selection, publicCliPath)
  writeDevEnvStats(parsed.selection.statsPath, edge, "exec")
  let artifact = readDevEnvArtifact(edge.artifactPath)
  if emitDevEnvDiagnostics(artifact):
    return 1
  runActivatedCommand(artifact, edge.artifactPath, parsed.command,
    parsed.selection.projectRoot)

proc defaultInteractiveShell(): string =
  when defined(windows):
    let comspec = getEnv("COMSPEC")
    if comspec.len > 0:
      return comspec
    let pwsh = findExe("pwsh")
    if pwsh.len > 0:
      return pwsh
    "powershell"
  else:
    getEnv("SHELL", "/bin/sh")

proc runReproShellCommand(args: openArray[string];
                          publicCliPath: string): int =
  let parsed = parseDevEnvShellArgs(args)
  let edge = computePublicDevEnv(parsed.selection, publicCliPath)
  writeDevEnvStats(parsed.selection.statsPath, edge, "shell")
  let artifact = readDevEnvArtifact(edge.artifactPath)
  if emitDevEnvDiagnostics(artifact):
    return 1
  if parsed.printEnv:
    stdout.write(renderDevEnvArtifact(artifact, edge.artifactPath,
      parsed.printFormat))
    return 0
  let shellPath =
    if parsed.shellPath.len > 0:
      parsed.shellPath
    else:
      defaultInteractiveShell()
  spawnActivatedShell(artifact, edge.artifactPath, shellPath,
    parsed.selection.projectRoot)

type
  ParsedDevSessionCommand = object
    selection: DevEnvCliSelection
    foreground: bool
    httpBind: string
    debounceMs: int
    force: bool

proc parseDevSessionArgs(args: openArray[string]; commandName: string):
    ParsedDevSessionCommand =
  var selection = DevEnvCliSelection()
  result.httpBind = "127.0.0.1:0"
  result.debounceMs = 250
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--activity" or arg.startsWith("--activity="):
      selection.activity.appendActivitySelection(valueFromFlag(args, i,
        "--activity"))
    elif arg == "--work-root" or arg.startsWith("--work-root="):
      selection.workRoot = valueFromFlag(args, i, "--work-root")
    elif arg == "--lock-slice" or arg.startsWith("--lock-slice="):
      selection.lockSliceId = valueFromFlag(args, i, "--lock-slice")
    elif arg == "--foreground":
      result.foreground = true
    elif arg == "--force":
      result.force = true
    elif arg == "--http" or arg.startsWith("--http="):
      result.httpBind = valueFromFlag(args, i, "--http")
    elif arg == "--debounce-ms" or arg.startsWith("--debounce-ms="):
      result.debounceMs = parseInt(valueFromFlag(args, i, "--debounce-ms"))
      if result.debounceMs < 0:
        raise newException(ValueError, "--debounce-ms must be non-negative")
    elif arg.startsWith("-"):
      raise newException(ValueError,
        "unsupported " & commandName & " flag: " & arg)
    elif selection.selector.len == 0:
      selection.selector = arg
    else:
      raise newException(ValueError,
        "unexpected " & commandName & " argument: " & arg)
    inc i
  selection.resolveDevEnvSelection()
  result.selection = selection

proc supervisorConfig(parsed: ParsedDevSessionCommand;
                      edge: DevEnvEdgeResult;
                      publicCliPath: string;
                      mode: DevSessionMode): DevSessionSupervisorConfig =
  DevSessionSupervisorConfig(
    mode: mode,
    foreground: parsed.foreground,
    projectRoot: parsed.selection.projectRoot,
    modulePath: parsed.selection.modulePath,
    outDir: parsed.selection.outDir,
    workDir: reprobuildLibraryWorkDir(),
    publicCliPath: publicCliPath,
    monitorCliPath: publicDevEnvFsSnoop(publicCliPath),
    monitorShimLibPath: getEnv("REPRO_MONITOR_SHIM_LIB"),
    artifactPath: edge.artifactPath,
    activity: parsed.selection.activity,
    lockSliceId: parsed.selection.lockSliceId,
    developOverridesPath: parsed.selection.developOverridesPath,
    httpBind: parsed.httpBind,
    debounceMs: parsed.debounceMs)

proc supervisorCliArgs(config: DevSessionSupervisorConfig): seq[string] =
  result = @[
    "__repro-dev-session-supervisor",
    "--mode", config.mode.modeName,
    "--project-root", config.projectRoot,
    "--module", config.modulePath,
    "--out-dir", config.outDir,
    "--work-dir", config.workDir,
    "--artifact", config.artifactPath,
    "--activity", config.activity,
    "--lock-slice", config.lockSliceId,
    "--develop-overrides", config.developOverridesPath,
    "--monitor-cli", config.monitorCliPath,
    "--monitor-shim", config.monitorShimLibPath,
    "--http", config.httpBind,
    "--debounce-ms", $config.debounceMs
  ]
  if config.foreground:
    result.add("--foreground")

proc startBackgroundSupervisor(config: DevSessionSupervisorConfig) =
  createDir(extendedPath(config.outDir.sessionDir))
  let logPath = config.outDir.sessionDir / "supervisor.log"
  when defined(windows):
    discard startProcess(config.publicCliPath,
      args = config.supervisorCliArgs(),
      workingDir = config.projectRoot,
      options = {poUsePath, poDaemon, poParentStreams})
  else:
    var fdsToClose: seq[string] = @[]
    for fd in 3 .. 64:
      fdsToClose.add($fd)
    let closeInheritedFds = "for fd in " & fdsToClose.join(" ") &
      "; do eval \"exec $fd>&-\"; done; "
    let command = "(cd " & q(config.projectRoot) & " && " &
      closeInheritedFds &
      "exec " &
      shellCommand(@[config.publicCliPath] & config.supervisorCliArgs()) &
      ") </dev/null >> " & q(logPath) & " 2>&1 &"
    let exitCode = execShellCmd(command)
    if exitCode != 0:
      raise newException(OSError,
        "failed to launch dev session supervisor: " & command)

proc runUpOrDevCommand(args: openArray[string]; publicCliPath: string;
                       mode: DevSessionMode): int =
  let commandName = if mode == dsmDev: "dev" else: "up"
  var parsed = parseDevSessionArgs(args, commandName)
  let edge = computePublicDevEnv(parsed.selection, publicCliPath)
  let config = supervisorConfig(parsed, edge, publicCliPath, mode)
  if parsed.foreground:
    return runDevSessionSupervisor(config)
  config.startBackgroundSupervisor()
  let status = waitForDevSessionReady(config)
  echo "repro " & commandName & ": session " &
    status["sessionId"].getStr() & " " & status["status"].getStr() &
    " " & status["httpBind"].getStr()
  0

proc runDownCommand(args: openArray[string]): int =
  let parsed = parseDevSessionArgs(args, "down")
  let metadataPath = parsed.selection.outDir.sessionMetadataPath()
  if not fileExists(extendedPath(metadataPath)):
    raise newException(IOError,
      "no authoritative Reprobuild dev session metadata at " & metadataPath)
  let metadata = parseFile(extendedPath(metadataPath))
  let httpBindValue = metadata{"httpBind"}.getStr()
  if httpBindValue.len == 0:
    raise newException(ValueError,
      "dev session metadata is missing httpBind: " & metadataPath)
  try:
    let response = httpRequest(httpBindValue, "/session/stop",
      httpMethod = "POST")
    if response.status < 200 or response.status >= 300:
      raise newException(IOError,
        "session stop request failed with HTTP " & $response.status &
          ": " & response.body)
  except CatchableError as err:
    if not parsed.force:
      raise
    writeFile(extendedPath(parsed.selection.outDir.sessionDir /
      StopRequestFile), "{\"source\":\"force-file\"}\n")
    stderr.writeLine("repro down: HTTP stop failed; wrote stop request file: " &
      err.msg)
  var waited = 0
  while waited <= 10000:
    if fileExists(extendedPath(metadataPath)):
      let current = parseFile(extendedPath(metadataPath))
      if current{"status"}.getStr() == "down":
        echo "repro down: session " & current{"sessionId"}.getStr() &
          " down"
        return 0
    sleep(100)
    waited.inc(100)
  raise newException(IOError,
    "timed out waiting for dev session to stop: " & metadataPath)

proc runDevSessionSupervisorHelper(args: openArray[string];
                                   publicCliPath: string): int =
  let modeText = valueAfterFlag(args, "--mode")
  let mode =
    case modeText
    of "dev": dsmDev
    of "up", "": dsmUp
    else:
      raise newException(ValueError, "unsupported dev session mode: " & modeText)
  let debounceText = valueAfterFlag(args, "--debounce-ms")
  let config = DevSessionSupervisorConfig(
    mode: mode,
    foreground: args.find("--foreground") >= 0,
    projectRoot: valueAfterFlag(args, "--project-root"),
    modulePath: valueAfterFlag(args, "--module"),
    outDir: valueAfterFlag(args, "--out-dir"),
    workDir: valueAfterFlag(args, "--work-dir"),
    publicCliPath: publicCliPath,
    monitorCliPath: valueAfterFlag(args, "--monitor-cli"),
    monitorShimLibPath: valueAfterFlag(args, "--monitor-shim"),
    artifactPath: valueAfterFlag(args, "--artifact"),
    activity: valueAfterFlag(args, "--activity"),
    lockSliceId: valueAfterFlag(args, "--lock-slice"),
    developOverridesPath: valueAfterFlag(args, "--develop-overrides"),
    httpBind: valueAfterFlag(args, "--http"),
    debounceMs: if debounceText.len > 0: parseInt(debounceText) else: 250)
  runDevSessionSupervisor(config)

proc runDevSessionHttpHelper(args: openArray[string]): int =
  let portText = valueAfterFlag(args, "--port")
  runDevSessionHttpServer(DevSessionHttpConfig(
    sessionDir: valueAfterFlag(args, "--session-dir"),
    host: valueAfterFlag(args, "--host"),
    port: if portText.len > 0: parseInt(portText) else: 0))

const
  DirenvManagedBlockId = "repro-dev-env-direnv"
  DirenvActivationGuard = "REPRO_DIRENV_ACTIVATING"
  NativeShellManagedBlockPrefix = "repro-dev-env-native-"
  NativeShellActivationGuard = "REPRO_NATIVE_SHELL_HOOK_RUNNING"
  VcsDispatcherMarker = "reprobuild hook dispatcher"
  VcsHookNames = ["pre-push", "post-commit"]

type
  HookActionKind = enum
    hakEnsure
    hakReinstall
    hakUninstall

  NativeShellKind = enum
    nskBash
    nskZsh
    nskFish
    nskPowerShell

  ParsedHooksCommand = object
    action: HookActionKind
    targetPath: string
    shellDirenv: bool
    vcs: bool
    nativeShells: seq[NativeShellKind]

  NativeShellActivationRequest = object
    cwd: string
    shell: NativeShellKind
    previousArtifact: string
    previousProjectRoot: string
    statsPath: string

proc nativeShellName(shell: NativeShellKind): string =
  case shell
  of nskBash: "bash"
  of nskZsh: "zsh"
  of nskFish: "fish"
  of nskPowerShell: "powershell"

proc parseNativeShell(value: string): NativeShellKind =
  case value.normalize()
  of "bash":
    nskBash
  of "zsh":
    nskZsh
  of "fish":
    nskFish
  of "powershell", "pwsh", "ps1":
    nskPowerShell
  else:
    raise newException(ValueError,
      "unsupported shell for repro hooks --shell: " & value)

proc nativeShellFormat(shell: NativeShellKind): DevEnvPrintFormat =
  case shell
  of nskBash, nskZsh:
    depPosix
  of nskFish:
    depFish
  of nskPowerShell:
    depPowerShell

proc nativeShellBlockId(shell: NativeShellKind): string =
  NativeShellManagedBlockPrefix & shell.nativeShellName()

proc nativeShellRcPath(shell: NativeShellKind; homeDir = getEnv("HOME")): string =
  case shell
  of nskBash:
    homeDir / ".bashrc"
  of nskZsh:
    homeDir / ".zshrc"
  of nskFish:
    let xdg = getEnv("XDG_CONFIG_HOME")
    if xdg.len > 0:
      xdg / "fish" / "config.fish"
    else:
      homeDir / ".config" / "fish" / "config.fish"
  of nskPowerShell:
    when defined(windows):
      let profileHome = getEnv("USERPROFILE", homeDir)
      profileHome / "Documents" / "PowerShell" /
        "Microsoft.PowerShell_profile.ps1"
    else:
      homeDir / ".config" / "powershell" /
        "Microsoft.PowerShell_profile.ps1"

proc containsNixStoreSegment(path: string): bool =
  let normalized = path.replace('\\', '/')
  normalized.startsWith("/nix/store/") or normalized.contains("/nix/store/")

proc absoluteSymlinkTarget(linkPath: string): string =
  let rawTarget = expandSymlink(extendedPath(linkPath))
  if rawTarget.isAbsolute:
    os.normalizedPath(rawTarget)
  else:
    os.normalizedPath(parentDir(linkPath) / rawTarget)

proc rcFileWritePath(rcPath: string): string =
  ## Return the file to edit for a shell rc managed block. Refuses Nix-managed
  ## read-only symlinks instead of replacing the symlink with a regular file.
  let expandedRc = extendedPath(rcPath)
  if symlinkExists(expandedRc):
    let target = absoluteSymlinkTarget(rcPath)
    if target.containsNixStoreSegment():
      raise newException(ValueError,
        "refusing to write shell rc file " & rcPath &
          ": it is a Nix-managed symlink into the Nix store (" & target &
          "). Edit the source file in your dotfiles/home-manager " &
          "configuration and rebuild with home-switch.")
    if fileExists(extendedPath(target)):
      let permissions = getFilePermissions(extendedPath(target))
      if fpUserWrite notin permissions:
        raise newException(ValueError,
          "refusing to write shell rc file " & rcPath &
            ": it points at a read-only file (" & target &
            "). Edit the owning source file instead.")
    return target
  if expandedRc.containsNixStoreSegment():
    raise newException(ValueError,
      "refusing to write shell rc file in the Nix store: " & rcPath &
        ". Edit the source file in your dotfiles/home-manager configuration " &
        "and rebuild with home-switch.")
  if fileExists(expandedRc):
    let permissions = getFilePermissions(expandedRc)
    if fpUserWrite notin permissions:
      raise newException(ValueError,
        "refusing to write read-only shell rc file " & rcPath &
          ". Edit the owning source file instead.")
  rcPath

proc posixLiteral(value: string): string =
  result = "'"
  for ch in value:
    if ch == '\'':
      result.add("'\\''")
    else:
      result.add(ch)
  result.add("'")

proc fishLiteral(value: string): string =
  result = "'"
  for ch in value:
    case ch
    of '\'':
      result.add("\\'")
    of '\\':
      result.add("\\\\")
    else:
      result.add(ch)
  result.add("'")

proc powerShellLiteral(value: string): string =
  "'" & value.replace("'", "''") & "'"

const NativeMetadataNames = [
  "REPRO_DEV_ENV_ARTIFACT",
  "REPRO_DEV_ENV_PROJECT_ROOT",
  "REPRO_DEV_ENV_SELECTED_ACTIVITIES",
  "REPRO_DEV_ENV_TASKS",
  "REPRO_DEV_ENV_SERVICES"
]

proc sortedUnique(values: seq[string]): seq[string] =
  var seen: HashSet[string]
  for value in values:
    if value.len > 0 and value notin seen:
      seen.incl(value)
      result.add(value)
  result.sort()

proc nativeUnsetNames(artifact: DevEnvArtifact): seq[string] =
  var names: seq[string] = @[]
  for op in artifact.shellOps:
    case op.kind
    of deskSetEnv, deskSetPathList, deskUnsetEnv:
      names.add(op.name)
    of deskPrependPath, deskAppendPath, deskSetWorkingDirectory:
      discard
  for name in NativeMetadataNames:
    names.add(name)
  names.sortedUnique()

proc nativePathRemovals(artifact: DevEnvArtifact):
    seq[tuple[name, value, separator: string]] =
  var seen: HashSet[string]
  for op in artifact.shellOps:
    case op.kind
    of deskPrependPath, deskAppendPath:
      let sep = if op.separator.len > 0: op.separator else: $PathSep
      let key = op.name & "\0" & op.value & "\0" & sep
      if key notin seen:
        seen.incl(key)
        result.add((name: op.name, value: op.value, separator: sep))
    else:
      discard

proc renderPosixDevEnvUnload(artifact: DevEnvArtifact): string =
  result = "# Reprobuild native shell unload\n"
  let removals = nativePathRemovals(artifact)
  if removals.len > 0:
    result.add("__repro_native_remove_path() {\n")
    result.add("  __repro_native_var=$1\n")
    result.add("  __repro_native_remove=$2\n")
    result.add("  __repro_native_sep=$3\n")
    result.add("  eval \"__repro_native_value=\\${$__repro_native_var-}\"\n")
    result.add("  __repro_native_out=\n")
    result.add("  __repro_native_old_ifs=$IFS\n")
    result.add("  IFS=$__repro_native_sep\n")
    result.add("  for __repro_native_part in $__repro_native_value; do\n")
    result.add("    if [ \"$__repro_native_part\" != \"$__repro_native_remove\" ]; then\n")
    result.add("      if [ -n \"$__repro_native_out\" ]; then\n")
    result.add("        __repro_native_out=$__repro_native_out$__repro_native_sep$__repro_native_part\n")
    result.add("      else\n")
    result.add("        __repro_native_out=$__repro_native_part\n")
    result.add("      fi\n")
    result.add("    fi\n")
    result.add("  done\n")
    result.add("  IFS=$__repro_native_old_ifs\n")
    result.add("  export \"$__repro_native_var=$__repro_native_out\"\n")
    result.add("}\n")
    for removal in removals:
      result.add("__repro_native_remove_path " & posixLiteral(removal.name) &
        " " & posixLiteral(removal.value) & " " &
        posixLiteral(removal.separator) & "\n")
    result.add("unset -f __repro_native_remove_path 2>/dev/null || true\n")
    result.add("unset __repro_native_var __repro_native_remove __repro_native_sep __repro_native_value __repro_native_out __repro_native_old_ifs __repro_native_part\n")
  let names = nativeUnsetNames(artifact)
  if names.len > 0:
    result.add("unset " & names.join(" ") & "\n")

proc renderFishDevEnvUnload(artifact: DevEnvArtifact): string =
  result = "# Reprobuild native shell unload\n"
  let removals = nativePathRemovals(artifact)
  if removals.len > 0:
    result.add("function __repro_native_remove_path\n")
    result.add("  set -l __repro_native_var $argv[1]\n")
    result.add("  set -l __repro_native_remove $argv[2]\n")
    result.add("  set -l __repro_native_kept\n")
    result.add("  for __repro_native_part in $$__repro_native_var\n")
    result.add("    if test \"$__repro_native_part\" != \"$__repro_native_remove\"\n")
    result.add("      set __repro_native_kept $__repro_native_kept \"$__repro_native_part\"\n")
    result.add("    end\n")
    result.add("  end\n")
    result.add("  if test (count $__repro_native_kept) -gt 0\n")
    result.add("    set -gx $__repro_native_var $__repro_native_kept\n")
    result.add("  else\n")
    result.add("    set -e $__repro_native_var\n")
    result.add("  end\n")
    result.add("end\n")
    for removal in removals:
      result.add("__repro_native_remove_path " & fishLiteral(removal.name) &
        " " & fishLiteral(removal.value) & "\n")
    result.add("functions -e __repro_native_remove_path\n")
  for name in nativeUnsetNames(artifact):
    result.add("set -e " & name & "\n")

proc renderPowerShellDevEnvUnload(artifact: DevEnvArtifact): string =
  result = "# Reprobuild native shell unload\n"
  let removals = nativePathRemovals(artifact)
  if removals.len > 0:
    result.add("function __ReproNativeRemovePath($Name, $Value, $Sep) {\n")
    result.add("  $current = [Environment]::GetEnvironmentVariable($Name, 'Process')\n")
    result.add("  if ($null -eq $current) { return }\n")
    result.add("  $kept = @()\n")
    result.add("  foreach ($part in $current -split [regex]::Escape($Sep)) {\n")
    result.add("    if ($part -ne $Value) { $kept += $part }\n")
    result.add("  }\n")
    result.add("  if ($kept.Count -gt 0) { Set-Item -Path \"Env:$Name\" -Value ($kept -join $Sep) }\n")
    result.add("  else { Remove-Item -Path \"Env:$Name\" -ErrorAction SilentlyContinue }\n")
    result.add("}\n")
    for removal in removals:
      result.add("__ReproNativeRemovePath " &
        powerShellLiteral(removal.name) & " " &
        powerShellLiteral(removal.value) & " " &
        powerShellLiteral(removal.separator) & "\n")
    result.add("Remove-Item Function:__ReproNativeRemovePath -ErrorAction SilentlyContinue\n")
  for name in nativeUnsetNames(artifact):
    result.add("Remove-Item Env:" & name & " -ErrorAction SilentlyContinue\n")

proc renderDevEnvUnload(artifact: DevEnvArtifact;
                        format: DevEnvPrintFormat): string =
  case format
  of depPosix:
    renderPosixDevEnvUnload(artifact)
  of depFish:
    renderFishDevEnvUnload(artifact)
  of depPowerShell:
    renderPowerShellDevEnvUnload(artifact)
  of depJson:
    raise newException(ValueError,
      "json is not a native shell activation format")

proc renderNativeShellTransition(previousArtifactPath: string;
                                 nextArtifact: Option[DevEnvArtifact];
                                 nextArtifactPath: string;
                                 format: DevEnvPrintFormat): string =
  if previousArtifactPath.len > 0 and
      fileExists(extendedPath(previousArtifactPath)):
    result.add(renderDevEnvUnload(readDevEnvArtifact(previousArtifactPath),
      format))
  elif previousArtifactPath.len > 0:
    for name in NativeMetadataNames:
      case format
      of depPosix:
        result.add("unset " & name & "\n")
      of depFish:
        result.add("set -e " & name & "\n")
      of depPowerShell:
        result.add("Remove-Item Env:" & name &
          " -ErrorAction SilentlyContinue\n")
      of depJson:
        discard
  if nextArtifact.isSome:
    result.add(renderDevEnvArtifact(nextArtifact.get(), nextArtifactPath,
      format))

proc findDevEnvProjectRoot(startPath: string): string =
  var cursor = os.normalizedPath(absolutePath(startPath))
  if fileExists(extendedPath(cursor)) and not dirExists(extendedPath(cursor)):
    cursor = parentDir(cursor)
  while cursor.len > 0:
    if fileExists(extendedPath(cursor / "reprobuild.nim")):
      return cursor
    let parent = parentDir(cursor)
    if parent == cursor or parent.len == 0:
      break
    cursor = parent
  ""

proc direnvOpenSentinel(): string =
  ResourceOpenSentinelPrefix & DirenvManagedBlockId & ResourceOpenSentinelSuffix

proc direnvCloseSentinel(): string =
  ResourceCloseSentinelPrefix & DirenvManagedBlockId &
    ResourceCloseSentinelSuffix

proc direnvManagedBlockContent(): string =
  let guard = DirenvActivationGuard
  result = "# Generated by repro hooks ensure --shell-direnv. Do not edit this block.\n"
  result.add("_repro_direnv_activate() {\n")
  result.add("  if [ -n \"${" & guard & ":-}\" ]; then\n")
  result.add("    return 0\n")
  result.add("  fi\n")
  result.add("  export " & guard & "=1\n")
  result.add("  local repro_cmd=\"${REPROBUILD_REPRO:-repro}\"\n")
  result.add("  if ! command -v \"$repro_cmd\" >/dev/null 2>&1 && [ ! -x \"$repro_cmd\" ]; then\n")
  result.add("    echo \"repro hooks: repro CLI not found; set REPROBUILD_REPRO or put repro on PATH\" >&2\n")
  result.add("    unset " & guard & "\n")
  result.add("    return 1\n")
  result.add("  fi\n")
  result.add("  \"$repro_cmd\" hooks ensure --vcs \"$PWD\" >/dev/null 2>&1 || true\n")
  result.add("  local repro_status=0\n")
  result.add("  if [ -n \"${REPRO_DIRENV_STATS:-}\" ]; then\n")
  result.add("    eval \"$(\"$repro_cmd\" __repro-direnv-activate \"$PWD\" --dev-env-stats \"$REPRO_DIRENV_STATS\")\" || repro_status=$?\n")
  result.add("  else\n")
  result.add("    eval \"$(\"$repro_cmd\" __repro-direnv-activate \"$PWD\")\" || repro_status=$?\n")
  result.add("  fi\n")
  result.add("  unset " & guard & "\n")
  result.add("  return \"$repro_status\"\n")
  result.add("}\n")
  result.add("_repro_direnv_activate\n")
  result.add("_repro_direnv_status=$?\n")
  result.add("unset -f _repro_direnv_activate\n")
  result.add("return \"$_repro_direnv_status\"\n")

proc resolveHooksTarget(path: string): string =
  let raw = if path.len > 0: path else: "."
  result = os.normalizedPath(absolutePath(raw))
  if fileExists(extendedPath(result)) and not dirExists(extendedPath(result)):
    result = parentDir(result)

proc managedBlockMalformed(content: string): bool =
  let openIdx = content.find(direnvOpenSentinel())
  let closeIdx = content.find(direnvCloseSentinel())
  (openIdx >= 0 and closeIdx < 0) or (openIdx < 0 and closeIdx >= 0) or
    (openIdx >= 0 and closeIdx >= 0 and closeIdx <= openIdx)

proc contentOutsideManagedBlock(content: string): string =
  let openS = direnvOpenSentinel()
  let closeS = direnvCloseSentinel()
  let openIdx = content.find(openS)
  let closeIdx = content.find(closeS)
  if openIdx < 0 or closeIdx < 0 or closeIdx <= openIdx:
    return content
  var openLineStart = openIdx
  while openLineStart > 0 and content[openLineStart - 1] != '\n':
    dec openLineStart
  var closeLineEnd = closeIdx + closeS.len
  if closeLineEnd < content.len and content[closeLineEnd] == '\n':
    inc closeLineEnd
  content[0 ..< openLineStart] & content[closeLineEnd .. ^1]

proc hasUnmanagedDirenvConflict(content: string): bool =
  let outside = content.contentOutsideManagedBlock().toLowerAscii()
  for marker in [
    "__repro-direnv-activate",
    "repro shell",
    "repro exec",
    "repro_dev_env_",
    "repro_direnv_",
    "reprobuild_repro"
  ]:
    if outside.contains(marker):
      return true

proc validateEnvrcForEnsure(envrcPath: string) =
  if not fileExists(extendedPath(envrcPath)):
    return
  let content = readFile(extendedPath(envrcPath))
  if content.managedBlockMalformed():
    raise newException(ValueError,
      "conflicting .envrc: found an incomplete Reprobuild managed block in " &
        envrcPath & "; repair or remove the sentinels before running ensure")
  if content.hasUnmanagedDirenvConflict():
    raise newException(ValueError,
      "conflicting unmanaged .envrc in " & envrcPath &
        ": existing user-owned content appears to activate Reprobuild. " &
        "Move that logic into the Reprobuild-managed block by removing it " &
        "or run uninstall first.")

proc ensureDirenvHook(targetPath: string; reinstall = false) =
  let projectRoot = resolveHooksTarget(targetPath)
  createDir(extendedPath(projectRoot))
  let envrcPath = projectRoot / ".envrc"
  if reinstall:
    destroyManagedBlockResource(envrcPath, DirenvManagedBlockId)
  validateEnvrcForEnsure(envrcPath)
  discard applyManagedBlockResource(envrcPath, DirenvManagedBlockId,
    direnvManagedBlockContent())
  echo "repro hooks: ensured direnv .envrc block at " & envrcPath

proc uninstallDirenvHook(targetPath: string) =
  let projectRoot = resolveHooksTarget(targetPath)
  let envrcPath = projectRoot / ".envrc"
  if fileExists(extendedPath(envrcPath)) and
      readFile(extendedPath(envrcPath)).managedBlockMalformed():
    raise newException(ValueError,
      "conflicting .envrc: found an incomplete Reprobuild managed block in " &
        envrcPath & "; refusing to edit user-owned content")
  destroyManagedBlockResource(envrcPath, DirenvManagedBlockId)
  echo "repro hooks: removed direnv .envrc block from " & envrcPath

proc nativePosixHookContent(shell: NativeShellKind): string =
  let shellName = shell.nativeShellName()
  let shellArg = if shell == nskZsh: "zsh" else: "bash"
  result = "# Generated by repro hooks ensure --shell " & shellName &
    ". Do not edit this block.\n"
  result.add("__repro_native_shell_hook() {\n")
  result.add("  if [ -n \"${" & NativeShellActivationGuard & ":-}\" ]; then\n")
  result.add("    return 0\n")
  result.add("  fi\n")
  result.add("  export " & NativeShellActivationGuard & "=1\n")
  result.add("  local __repro_native_repro=\"${REPROBUILD_REPRO:-repro}\"\n")
  result.add("  if ! command -v \"$__repro_native_repro\" >/dev/null 2>&1 && [ ! -x \"$__repro_native_repro\" ]; then\n")
  result.add("    echo \"repro hooks: repro CLI not found; set REPROBUILD_REPRO or put repro on PATH\" >&2\n")
  result.add("    unset " & NativeShellActivationGuard & "\n")
  result.add("    return 1\n")
  result.add("  fi\n")
  result.add("  local __repro_native_status=0\n")
  result.add("  local __repro_native_script\n")
  result.add("  if [ -n \"${REPRO_NATIVE_SHELL_STATS:-}\" ]; then\n")
  result.add("    __repro_native_script=\"$(\"$__repro_native_repro\" __repro-native-shell-activate \"$PWD\" --shell " & shellArg & " --previous-artifact \"${REPRO_DEV_ENV_ARTIFACT:-}\" --previous-project-root \"${REPRO_DEV_ENV_PROJECT_ROOT:-}\" --dev-env-stats \"$REPRO_NATIVE_SHELL_STATS\")\" || __repro_native_status=$?\n")
  result.add("  else\n")
  result.add("    __repro_native_script=\"$(\"$__repro_native_repro\" __repro-native-shell-activate \"$PWD\" --shell " & shellArg & " --previous-artifact \"${REPRO_DEV_ENV_ARTIFACT:-}\" --previous-project-root \"${REPRO_DEV_ENV_PROJECT_ROOT:-}\")\" || __repro_native_status=$?\n")
  result.add("  fi\n")
  result.add("  if [ \"$__repro_native_status\" -eq 0 ]; then\n")
  result.add("    eval \"$__repro_native_script\"\n")
  result.add("  else\n")
  result.add("    printf '%s\\n' \"$__repro_native_script\" >&2\n")
  result.add("  fi\n")
  result.add("  unset " & NativeShellActivationGuard & "\n")
  result.add("  unset __repro_native_repro __repro_native_script\n")
  result.add("  return \"$__repro_native_status\"\n")
  result.add("}\n")
  case shell
  of nskBash:
    result.add("cd() { builtin cd \"$@\" || return $?; __repro_native_shell_hook; }\n")
    result.add("pushd() { builtin pushd \"$@\" || return $?; __repro_native_shell_hook; }\n")
    result.add("popd() { builtin popd \"$@\" || return $?; __repro_native_shell_hook; }\n")
  of nskZsh:
    result.add("autoload -Uz add-zsh-hook\n")
    result.add("add-zsh-hook chpwd __repro_native_shell_hook\n")
  else:
    discard
  result.add("__repro_native_shell_hook\n")

proc nativeFishHookContent(): string =
  result = "# Generated by repro hooks ensure --shell fish. Do not edit this block.\n"
  result.add("function __repro_native_shell_hook --on-variable PWD\n")
  result.add("  if set -q " & NativeShellActivationGuard & "\n")
  result.add("    return 0\n")
  result.add("  end\n")
  result.add("  set -gx " & NativeShellActivationGuard & " 1\n")
  result.add("  set -l __repro_native_repro \"$REPROBUILD_REPRO\"\n")
  result.add("  if test -z \"$__repro_native_repro\"\n")
  result.add("    set __repro_native_repro repro\n")
  result.add("  end\n")
  result.add("  if not test -x \"$__repro_native_repro\"; and not type -q \"$__repro_native_repro\"\n")
  result.add("    echo \"repro hooks: repro CLI not found; set REPROBUILD_REPRO or put repro on PATH\" >&2\n")
  result.add("    set -e " & NativeShellActivationGuard & "\n")
  result.add("    return 1\n")
  result.add("  end\n")
  result.add("  set -l __repro_native_tmp (mktemp)\n")
  result.add("  if set -q REPRO_NATIVE_SHELL_STATS\n")
  result.add("    \"$__repro_native_repro\" __repro-native-shell-activate \"$PWD\" --shell fish --previous-artifact \"$REPRO_DEV_ENV_ARTIFACT\" --previous-project-root \"$REPRO_DEV_ENV_PROJECT_ROOT\" --dev-env-stats \"$REPRO_NATIVE_SHELL_STATS\" > \"$__repro_native_tmp\"\n")
  result.add("  else\n")
  result.add("    \"$__repro_native_repro\" __repro-native-shell-activate \"$PWD\" --shell fish --previous-artifact \"$REPRO_DEV_ENV_ARTIFACT\" --previous-project-root \"$REPRO_DEV_ENV_PROJECT_ROOT\" > \"$__repro_native_tmp\"\n")
  result.add("  end\n")
  result.add("  set -l __repro_native_status $status\n")
  result.add("  if test $__repro_native_status -eq 0\n")
  result.add("    source \"$__repro_native_tmp\"\n")
  result.add("  else\n")
  result.add("    cat \"$__repro_native_tmp\" >&2\n")
  result.add("  end\n")
  result.add("  rm -f \"$__repro_native_tmp\"\n")
  result.add("  set -e " & NativeShellActivationGuard & "\n")
  result.add("  return $__repro_native_status\n")
  result.add("end\n")
  result.add("__repro_native_shell_hook\n")

proc nativePowerShellHookContent(): string =
  result = "# Generated by repro hooks ensure --shell powershell. Do not edit this block.\n"
  result.add("function Invoke-ReproNativeShellHook {\n")
  result.add("  if ($env:" & NativeShellActivationGuard & ") { return }\n")
  result.add("  $env:" & NativeShellActivationGuard & " = '1'\n")
  result.add("  $reproCmd = if ($env:REPROBUILD_REPRO) { $env:REPROBUILD_REPRO } else { 'repro' }\n")
  result.add("  $args = @('__repro-native-shell-activate', (Get-Location).Path, '--shell', 'powershell', '--previous-artifact', $env:REPRO_DEV_ENV_ARTIFACT, '--previous-project-root', $env:REPRO_DEV_ENV_PROJECT_ROOT)\n")
  result.add("  if ($env:REPRO_NATIVE_SHELL_STATS) { $args += @('--dev-env-stats', $env:REPRO_NATIVE_SHELL_STATS) }\n")
  result.add("  $script = & $reproCmd @args\n")
  result.add("  if ($LASTEXITCODE -eq 0) { Invoke-Expression ($script -join \"`n\") }\n")
  result.add("  else { [Console]::Error.WriteLine(($script -join \"`n\")) }\n")
  result.add("  Remove-Item Env:" & NativeShellActivationGuard & " -ErrorAction SilentlyContinue\n")
  result.add("}\n")
  result.add("function Set-Location {\n")
  result.add("  Microsoft.PowerShell.Management\\Set-Location @args\n")
  result.add("  if ($?) { Invoke-ReproNativeShellHook }\n")
  result.add("}\n")
  result.add("Set-Alias cd Set-Location -Option AllScope\n")
  result.add("Set-Alias chdir Set-Location -Option AllScope\n")
  result.add("Set-Alias sl Set-Location -Option AllScope\n")
  result.add("Invoke-ReproNativeShellHook\n")

proc nativeShellHookContent(shell: NativeShellKind): string =
  case shell
  of nskBash, nskZsh:
    nativePosixHookContent(shell)
  of nskFish:
    nativeFishHookContent()
  of nskPowerShell:
    nativePowerShellHookContent()

proc ensureNativeShellHook(shell: NativeShellKind; reinstall = false) =
  let rcPath = nativeShellRcPath(shell)
  let writePath = rcFileWritePath(rcPath)
  if reinstall:
    destroyManagedBlockResource(writePath, nativeShellBlockId(shell))
  discard applyManagedBlockResource(writePath, nativeShellBlockId(shell),
    nativeShellHookContent(shell))
  echo "repro hooks: ensured native " & shell.nativeShellName() &
    " shell block at " & rcPath

proc uninstallNativeShellHook(shell: NativeShellKind) =
  let rcPath = nativeShellRcPath(shell)
  let writePath = rcFileWritePath(rcPath)
  destroyManagedBlockResource(writePath, nativeShellBlockId(shell))
  echo "repro hooks: removed native " & shell.nativeShellName() &
    " shell block from " & rcPath

proc gitTopLevel(targetPath: string): string =
  let res = execCmdEx(shellCommand(@["git", "-C", resolveHooksTarget(targetPath),
    "rev-parse", "--show-toplevel"]))
  if res.exitCode == 0:
    result = os.normalizedPath(res.output.strip())

proc gitHooksDir(targetPath: string): string =
  let repoRoot = gitTopLevel(targetPath)
  if repoRoot.len == 0:
    raise newException(ValueError,
      "VCS hook target is not inside a Git repository: " &
        resolveHooksTarget(targetPath))
  let res = execCmdEx(shellCommand(@["git", "-C", repoRoot, "rev-parse",
    "--absolute-git-dir"]))
  if res.exitCode != 0:
    raise newException(ValueError,
      "could not locate Git hooks directory for " & repoRoot & ": " &
        res.output.strip())
  result = os.normalizedPath(res.output.strip()) / "hooks"

proc hookPath(hooksDir, hookName: string): string =
  hooksDir / hookName

proc localHookPath(hooksDir, hookName: string): string =
  hooksDir / (hookName & ".repro-local")

proc managedHookPath(hooksDir, hookName: string): string =
  hooksDir / (hookName & ".repro-managed")

proc fileContains(path, marker: string): bool =
  fileExists(extendedPath(path)) and readFile(extendedPath(path)).contains(marker)

proc isReprobuildVcsHook(path, hookName: string): bool =
  fileContains(path, VcsDispatcherMarker) or
    fileContains(path, "reprobuild managed " & hookName & " hook")

proc ensureExecutable(path: string) =
  if not fileExists(extendedPath(path)):
    return
  var permissions = getFilePermissions(extendedPath(path))
  permissions.incl(fpUserExec)
  permissions.incl(fpGroupExec)
  permissions.incl(fpOthersExec)
  setFilePermissions(extendedPath(path), permissions)

proc writeExecutableIfChanged(path, content: string): bool =
  if fileExists(extendedPath(path)) and readFile(extendedPath(path)) == content:
    ensureExecutable(path)
    return false
  writeFile(extendedPath(path), content)
  ensureExecutable(path)
  true

proc removeFileIfExists(path: string): bool =
  if fileExists(extendedPath(path)):
    removeFile(extendedPath(path))
    return true
  false

proc moveFileReplacing(source, dest: string) =
  if fileExists(extendedPath(dest)):
    removeFile(extendedPath(dest))
  moveFile(extendedPath(source), extendedPath(dest))

proc vcsDispatcherContent(hookName: string): string =
  result = "#!/usr/bin/env sh\n"
  result.add("# " & VcsDispatcherMarker & "\n")
  result.add("# Dispatches preserved user hooks and Reprobuild-managed " &
    hookName & " logic.\n")
  result.add("set -eu\n\n")
  result.add("HOOK_DIR=$(CDPATH= cd -- \"$(dirname -- \"$0\")\" && pwd)\n")
  result.add("LOCAL_HOOK=\"$HOOK_DIR/" & hookName & ".repro-local\"\n")
  result.add("MANAGED_HOOK=\"$HOOK_DIR/" & hookName & ".repro-managed\"\n\n")
  if hookName == "pre-push":
    result.add("TMP_FILE=$(mktemp \"${TMPDIR:-/tmp}/reprobuild-pre-push.XXXXXX\")\n")
    result.add("trap 'rm -f \"$TMP_FILE\"' EXIT HUP INT TERM\n")
    result.add("cat > \"$TMP_FILE\"\n")
    result.add("if [ -x \"$LOCAL_HOOK\" ]; then \"$LOCAL_HOOK\" \"$@\" < \"$TMP_FILE\" || exit $?; fi\n")
    result.add("if [ -x \"$MANAGED_HOOK\" ]; then \"$MANAGED_HOOK\" \"$@\" < \"$TMP_FILE\" || exit $?; fi\n")
  else:
    result.add("if [ -x \"$LOCAL_HOOK\" ]; then \"$LOCAL_HOOK\" \"$@\" || exit $?; fi\n")
    result.add("if [ -x \"$MANAGED_HOOK\" ]; then \"$MANAGED_HOOK\" \"$@\" || exit $?; fi\n")
  result.add("exit 0\n")

proc vcsManagedHookContent(hookName: string): string =
  result = "#!/usr/bin/env sh\n"
  result.add("# reprobuild managed " & hookName & " hook\n")
  result.add("set -eu\n\n")
  result.add("find_workspace_cmd() {\n")
  result.add("  if [ -n \"${REPO_WORKSPACES_FRAMEWORK:-}\" ] && [ -x \"$REPO_WORKSPACES_FRAMEWORK/bin/workspace\" ]; then\n")
  result.add("    printf '%s\\n' \"$REPO_WORKSPACES_FRAMEWORK/bin/workspace\"\n")
  result.add("    return 0\n")
  result.add("  fi\n")
  result.add("  dir=$PWD\n")
  result.add("  while [ \"$dir\" != \"/\" ]; do\n")
  result.add("    if [ -x \"$dir/repo-workspaces/bin/workspace\" ]; then\n")
  result.add("      printf '%s\\n' \"$dir/repo-workspaces/bin/workspace\"\n")
  result.add("      return 0\n")
  result.add("    fi\n")
  result.add("    if [ -x \"$dir/../repo-workspaces/bin/workspace\" ]; then\n")
  result.add("      printf '%s\\n' \"$dir/../repo-workspaces/bin/workspace\"\n")
  result.add("      return 0\n")
  result.add("    fi\n")
  result.add("    dir=$(dirname -- \"$dir\")\n")
  result.add("  done\n")
  result.add("  command -v workspace 2>/dev/null || return 1\n")
  result.add("}\n\n")
  result.add("REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)\n")
  result.add("cd \"$REPO_ROOT\"\n")
  result.add("if WORKSPACE_CMD=$(find_workspace_cmd); then\n")
  if hookName == "pre-push":
    result.add("  REFS_FILE=$(mktemp \"${TMPDIR:-/tmp}/reprobuild-pre-push-backend.XXXXXX\")\n")
    result.add("  trap 'rm -f \"$REFS_FILE\"' EXIT HUP INT TERM\n")
    result.add("  cat > \"$REFS_FILE\"\n")
    result.add("  \"$WORKSPACE_CMD\" __hook pre-push --refs-file \"$REFS_FILE\" \"$@\"\n")
  else:
    result.add("  \"$WORKSPACE_CMD\" __hook post-commit \"$@\"\n")
  result.add("  exit $?\n")
  result.add("fi\n")
  result.add("echo \"repro hooks: workspace VCS hook backend not found; skipping " &
    hookName & "\" >&2\n")
  result.add("exit 0\n")

proc ensureVcsHook(hooksDir, hookName: string): bool =
  createDir(extendedPath(hooksDir))
  let standard = hookPath(hooksDir, hookName)
  let local = localHookPath(hooksDir, hookName)
  let managed = managedHookPath(hooksDir, hookName)
  if fileExists(extendedPath(local)) and isReprobuildVcsHook(local, hookName):
    result = removeFileIfExists(local) or result
  if fileExists(extendedPath(standard)) and
      not isReprobuildVcsHook(standard, hookName):
    if fileExists(extendedPath(local)):
      raise newException(ValueError,
        "cannot install " & hookName & ": " & standard &
          " is user-owned and " & local & " already exists")
    moveFileReplacing(standard, local)
    ensureExecutable(local)
    result = true
  result = writeExecutableIfChanged(managed,
    vcsManagedHookContent(hookName)) or result
  result = writeExecutableIfChanged(standard,
    vcsDispatcherContent(hookName)) or result

proc uninstallVcsHook(hooksDir, hookName: string): bool =
  let standard = hookPath(hooksDir, hookName)
  let local = localHookPath(hooksDir, hookName)
  let managed = managedHookPath(hooksDir, hookName)
  if fileExists(extendedPath(standard)) and
      isReprobuildVcsHook(standard, hookName):
    result = removeFileIfExists(standard) or result
    if fileExists(extendedPath(local)):
      moveFileReplacing(local, standard)
      ensureExecutable(standard)
      result = true
  elif fileExists(extendedPath(standard)) and
      fileExists(extendedPath(managed)):
    raise newException(ValueError,
      "refusing to uninstall " & hookName & ": " & standard &
        " is not Reprobuild-managed")
  result = removeFileIfExists(managed) or result
  if fileExists(extendedPath(local)) and isReprobuildVcsHook(local, hookName):
    result = removeFileIfExists(local) or result

proc runVcsHooksCommand(action: HookActionKind; targetPath: string) =
  let hooksDir = gitHooksDir(targetPath)
  let actionName =
    case action
    of hakEnsure: "ensure"
    of hakReinstall: "reinstall"
    of hakUninstall: "uninstall"
  var changed = false
  if action == hakReinstall:
    for hookName in VcsHookNames:
      changed = uninstallVcsHook(hooksDir, hookName) or changed
  case action
  of hakEnsure, hakReinstall:
    for hookName in VcsHookNames:
      changed = ensureVcsHook(hooksDir, hookName) or changed
  of hakUninstall:
    for hookName in VcsHookNames:
      changed = uninstallVcsHook(hooksDir, hookName) or changed
  let status = if changed: "updated" else: "already current"
  echo "repro hooks: VCS hooks " & actionName & " " & status & " at " &
    hooksDir

proc parseHooksCommand(args: openArray[string]): ParsedHooksCommand =
  if args.len == 0:
    raise newException(ValueError,
      "repro hooks requires ensure, reinstall, or uninstall")
  case args[0]
  of "ensure":
    result.action = hakEnsure
  of "reinstall":
    result.action = hakReinstall
  of "uninstall":
    result.action = hakUninstall
  else:
    raise newException(ValueError,
      "unsupported hooks action: " & args[0])
  var i = 1
  while i < args.len:
    let arg = args[i]
    case arg
    of "--shell-direnv":
      result.shellDirenv = true
    of "--vcs":
      result.vcs = true
    of "--shell-autocomplete":
      raise newException(ValueError,
        "repro hooks --shell-autocomplete is not implemented yet")
    of "--shell":
      result.nativeShells.add(parseNativeShell(valueFromFlag(args, i,
        "--shell")))
    else:
      if arg.startsWith("--shell="):
        var value = arg["--shell=".len .. ^1]
        if value.len == 0:
          raise newException(ValueError,
            "missing value for --shell")
        result.nativeShells.add(parseNativeShell(value))
      elif arg.startsWith("-"):
        raise newException(ValueError, "unsupported hooks flag: " & arg)
      elif result.targetPath.len > 0:
        raise newException(ValueError,
          "repro hooks accepts at most one path argument")
      else:
        result.targetPath = arg
    inc i
  if not result.shellDirenv and not result.vcs and
      result.nativeShells.len == 0:
    result.shellDirenv = true
    result.vcs = true

proc runHooksCommand(args: openArray[string]): int =
  let parsed = parseHooksCommand(args)
  case parsed.action
  of hakEnsure:
    if parsed.shellDirenv:
      ensureDirenvHook(parsed.targetPath)
    if parsed.vcs:
      runVcsHooksCommand(parsed.action, parsed.targetPath)
    for shell in parsed.nativeShells:
      ensureNativeShellHook(shell)
  of hakReinstall:
    if parsed.shellDirenv:
      ensureDirenvHook(parsed.targetPath, reinstall = true)
    if parsed.vcs:
      runVcsHooksCommand(parsed.action, parsed.targetPath)
    for shell in parsed.nativeShells:
      ensureNativeShellHook(shell, reinstall = true)
  of hakUninstall:
    if parsed.shellDirenv:
      uninstallDirenvHook(parsed.targetPath)
    if parsed.vcs:
      runVcsHooksCommand(parsed.action, parsed.targetPath)
    for shell in parsed.nativeShells:
      uninstallNativeShellHook(shell)
  0

proc parseNativeShellActivationRequest(args: openArray[string]):
    NativeShellActivationRequest =
  if args.len == 0:
    raise newException(ValueError,
      "__repro-native-shell-activate requires a directory argument")
  result.cwd = args[0]
  result.shell = nskBash
  var i = 1
  while i < args.len:
    let arg = args[i]
    if arg == "--shell" or arg.startsWith("--shell="):
      result.shell = parseNativeShell(valueFromFlag(args, i, "--shell"))
    elif arg == "--previous-artifact" or
        arg.startsWith("--previous-artifact="):
      result.previousArtifact = valueFromFlag(args, i,
        "--previous-artifact")
    elif arg == "--previous-project-root" or
        arg.startsWith("--previous-project-root="):
      result.previousProjectRoot = valueFromFlag(args, i,
        "--previous-project-root")
    elif arg == "--dev-env-stats" or arg.startsWith("--dev-env-stats="):
      result.statsPath = valueFromFlag(args, i, "--dev-env-stats")
    elif arg.startsWith("-"):
      raise newException(ValueError,
        "unsupported native shell activation flag: " & arg)
    else:
      raise newException(ValueError,
        "unexpected native shell activation argument: " & arg)
    inc i

proc runReproNativeShellActivationHelper(args: openArray[string];
                                         publicCliPath: string): int =
  let request = parseNativeShellActivationRequest(args)
  let format = nativeShellFormat(request.shell)
  let projectRoot = findDevEnvProjectRoot(request.cwd)
  if projectRoot.len == 0:
    stdout.write(renderNativeShellTransition(request.previousArtifact,
      none(DevEnvArtifact), "", format))
    return 0
  var selection = DevEnvCliSelection(
    selector: projectRoot,
    activity: "default",
    statsPath: request.statsPath)
  selection.resolveDevEnvSelection()
  let edge = computePublicDevEnv(selection, publicCliPath, renderShell = true)
  writeDevEnvStats(selection.statsPath, edge, "hooks shell-native")
  let artifact = readDevEnvArtifact(edge.artifactPath)
  if emitDevEnvDiagnostics(artifact):
    return 1
  stdout.write(renderNativeShellTransition(request.previousArtifact,
    some(artifact), edge.artifactPath, format))
  return 0

proc runReproDirenvActivationHelper(args: openArray[string];
                                    publicCliPath: string): int =
  var selection = DevEnvCliSelection()
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--activity" or arg.startsWith("--activity="):
      selection.activity.appendActivitySelection(valueFromFlag(args, i,
        "--activity"))
    elif arg == "--work-root" or arg.startsWith("--work-root="):
      selection.workRoot = valueFromFlag(args, i, "--work-root")
    elif arg == "--lock-slice" or arg.startsWith("--lock-slice="):
      selection.lockSliceId = valueFromFlag(args, i, "--lock-slice")
    elif arg == "--dev-env-stats" or arg.startsWith("--dev-env-stats="):
      selection.statsPath = valueFromFlag(args, i, "--dev-env-stats")
    elif arg.startsWith("-"):
      raise newException(ValueError, "unsupported direnv activation flag: " & arg)
    elif selection.selector.len == 0:
      selection.selector = arg
    else:
      raise newException(ValueError,
        "unexpected direnv activation argument: " & arg)
    inc i
  selection.resolveDevEnvSelection()
  let edge = computePublicDevEnv(selection, publicCliPath, renderShell = true)
  writeDevEnvStats(selection.statsPath, edge, "hooks shell-direnv")
  stdout.write(readFile(extendedPath(edge.shellFragmentPath)))
  stdout.write(renderDevEnvShellOps([
    DevEnvShellOp(kind: deskSetEnv, name: "REPRO_DEV_ENV_ARTIFACT",
      value: edge.artifactPath),
    DevEnvShellOp(kind: deskSetEnv, name: "REPRO_DEV_ENV_PROJECT_ROOT",
      value: selection.projectRoot),
    DevEnvShellOp(kind: deskSetEnv, name: "REPRO_DEV_ENV_SELECTED_ACTIVITIES",
      value: selection.activity)
  ], depPosix))
  0

proc sourceLocation(file: string): SourceLocation =
  SourceLocation(file: file, line: 1)

proc cmakeNixExecutable(name: string): string =
  # Windows: Nix store binaries have a `.exe` suffix. The forked CMake build
  # tree from `metacraft-labs/reprobuild-cmake` also produces `cmake.exe`,
  # `cc.exe`, etc. Emit relative paths with `.exe` on Windows so the path-only
  # / Nix executablePath actually points at a runnable file.
  when defined(windows):
    case name
    of "cmake":
      "bin/cmake.exe"
    of "cc":
      "bin/cc.exe"
    of "c++":
      "bin/c++.exe"
    else:
      "bin/" & name & ".exe"
  else:
    case name
    of "cmake":
      "bin/cmake"
    of "cc":
      "bin/cc"
    of "c++":
      "bin/c++"
    else:
      "bin/" & name

proc cmakeNixSelector(name: string): string =
  case name
  of "cmake":
    "nixpkgs#cmake"
  of "cc", "c++":
    "nixpkgs#clang"
  else:
    "nixpkgs#" & name

proc cmakeToolUse(sourceRoot, name: string): InterfaceToolUse =
  let loc = sourceLocation(sourceRoot / "CMakeLists.txt")
  InterfaceToolUse(
    rawConstraint: name & " >=1.0 <2.0",
    packageSelector: name,
    executableName: name,
    nixProvisioning: @[InterfaceNixProvisioning(
      packageName: name,
      selector: cmakeNixSelector(name),
      executablePath: cmakeNixExecutable(name),
      packageId: cmakeNixSelector(name),
      lockIdentity: cmakeNixSelector(name),
      location: loc)],
    location: loc)

proc cmakeDevelopArtifact(sourceRoot: string): ProjectInterfaceArtifact =
  artifactFor(ProjectInterface(
    projectName: "cmakeDevelop",
    packageName: "cmakeDevelop",
    toolUses: @[
      cmakeToolUse(sourceRoot, "cmake"),
      cmakeToolUse(sourceRoot, "cc"),
      cmakeToolUse(sourceRoot, "c++")
    ],
    location: sourceLocation(sourceRoot / "CMakeLists.txt")))

proc cmakeDevelopOutDir(sourceRoot, workRoot: string): string =
  let scopedRoot = scopedWorktreeRoot(sourceRoot / "CMakeLists.txt", workRoot)
  if scopedRoot.len > 0:
    scopedRoot / "develop-cmake"
  else:
    sourceRoot / ".repro" / "develop-cmake"

proc profileFor(identity: PathOnlyBuildIdentity; executableName: string):
    PathOnlyToolProfile =
  for profile in identity.profiles:
    if profile.executableName == executableName:
      return profile
  raise newException(ValueError,
    "cmake develop profile did not resolve required tool: " & executableName)

proc pathListJoin(values: openArray[string]; separator: char): string =
  var filtered: seq[string] = @[]
  for value in values:
    if value.len > 0 and not filtered.contains(value):
      filtered.add(value)
  filtered.join($separator)

proc profilePrefixes(identity: PathOnlyBuildIdentity): seq[string] =
  for profile in identity.profiles:
    if profile.selectedStorePath.len > 0 and dirExists(
        extendedPath(profile.selectedStorePath)):
      if not result.contains(profile.selectedStorePath):
        result.add(profile.selectedStorePath)
    let binDir = parentDir(profile.resolvedExecutablePath)
    if binDir.len > 0:
      let prefix = parentDir(binDir)
      if prefix.len > 0 and dirExists(extendedPath(prefix)) and not result.contains(prefix):
        result.add(prefix)

proc pkgConfigPaths(prefixes: openArray[string]): seq[string] =
  for prefix in prefixes:
    for suffix in ["lib/pkgconfig", "share/pkgconfig"]:
      let candidate = prefix / suffix
      if dirExists(extendedPath(candidate)) and not result.contains(candidate):
        result.add(candidate)

proc cmakeEscape(value: string): string =
  value.replace("\\", "\\\\").replace("\"", "\\\"").replace("$", "\\$")

proc cmakeSet(name, kind, value: string; force = true): string =
  if value.len == 0:
    return ""
  "set(" & name & " \"" & cmakeEscape(value) & "\" CACHE " & kind &
    " \"Generated by repro develop --cmake\"" &
    (if force: " FORCE" else: "") & ")\n"

proc sdkRootForCMake(): string =
  let explicit = getEnv("SDKROOT")
  if explicit.len > 0 and dirExists(extendedPath(explicit)):
    return explicit

proc writeCMakeToolchain(path: string; identity: PathOnlyBuildIdentity;
                         mode: ToolProvisioningMode; identityPath,
                         inspectionPath: string) =
  let cProfile = identity.profileFor("cc")
  let cxxProfile = identity.profileFor("c++")
  let prefixes = profilePrefixes(identity)
  let prefixValue = pathListJoin(prefixes, ';')
  let pkgValue = pathListJoin(pkgConfigPaths(prefixes), PathSep)
  let sdkRoot = sdkRootForCMake()
  var content = "# Generated by repro develop --cmake. Do not edit.\n"
  content.add(cmakeSet("CMAKE_C_COMPILER", "FILEPATH",
    cProfile.resolvedExecutablePath))
  content.add(cmakeSet("CMAKE_CXX_COMPILER", "FILEPATH",
    cxxProfile.resolvedExecutablePath))
  content.add(cmakeSet("CMAKE_PREFIX_PATH", "STRING", prefixValue))
  when defined(macosx):
    content.add(cmakeSet("CMAKE_OSX_SYSROOT", "PATH", sdkRoot))
  elif defined(windows):
    # Windows: MSVC has no sysroot concept; the Windows SDK is selected
    # implicitly via the toolchain (vcvars / VS install), so we deliberately
    # omit both CMAKE_SYSROOT and CMAKE_OSX_SYSROOT here. Proper Windows SDK
    # pinning is a follow-up.
    discard
  else:
    content.add(cmakeSet("CMAKE_SYSROOT", "PATH", sdkRoot))
  content.add(cmakeSet("REPROBUILD_CMAKE_TOOL_PORTABILITY", "STRING",
    mode.modeName))
  content.add(cmakeSet("REPROBUILD_TOOL_PROFILE_ARTIFACT", "FILEPATH",
    identityPath))
  content.add(cmakeSet("REPROBUILD_TOOL_PROFILE_INSPECTION", "FILEPATH",
    inspectionPath))
  if pkgValue.len > 0:
    content.add("set(ENV{PKG_CONFIG_PATH} \"" & cmakeEscape(pkgValue) & "\")\n")
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), content)

proc shellAssign(name, value: string): string =
  name & "=" & q(value) & "\n"

proc resolveCMakeExecutable(candidate: string): string =
  # Windows: the resolved executable path may be recorded without the .exe
  # suffix (for example when it came from a Nix-style "bin/cmake" entry).
  # Probe for a .exe variant first so the wrapper actually points at a
  # runnable file. POSIX paths are returned unchanged.
  when defined(windows):
    if candidate.len == 0:
      return candidate
    if fileExists(extendedPath(candidate)):
      return candidate
    if not candidate.endsWith(".exe"):
      let withExe = candidate & ".exe"
      if fileExists(extendedPath(withExe)):
        return withExe
    candidate
  else:
    candidate

proc ps1SingleQuote(value: string): string =
  # Windows: emit a PowerShell single-quoted literal. PS single-quoted strings
  # do not expand variables and only escape the single quote itself by
  # doubling it.
  "'" & value.replace("'", "''") & "'"

proc writeCMakeConfigureWrapperPosix(path: string;
                                     selectedCmake, toolchainPath,
                                     identityPath, inspectionPath, sourceRoot,
                                     reproPath, sourceRepoRoot, prefixValue,
                                     pkgValue, sdkRoot,
                                     modeName: string) =
  var content = "#!/bin/sh\nset -eu\n"
  content.add(shellAssign("cmake_bin", selectedCmake))
  content.add(shellAssign("toolchain_file", toolchainPath))
  content.add(shellAssign("prefix_path", prefixValue))
  content.add(shellAssign("pkg_config_path", pkgValue))
  content.add(shellAssign("sdk_root", sdkRoot))
  content.add(shellAssign("repro_cli", reproPath))
  content.add(shellAssign("repro_source_root", sourceRepoRoot))
  content.add("export REPROBUILD_REPRO=\"$repro_cli\"\n")
  content.add("export REPROBUILD_SOURCE_ROOT=\"$repro_source_root\"\n")
  content.add("export REPRO_TOOL_PROFILE_ARTIFACT=" & q(identityPath) & "\n")
  content.add("export REPRO_TOOL_PROFILE_INSPECTION=" & q(inspectionPath) & "\n")
  content.add("export REPRO_PROJECT_ROOT=" & q(sourceRoot) & "\n")
  content.add("if [ -n \"$pkg_config_path\" ]; then\n")
  content.add("  if [ -n \"${PKG_CONFIG_PATH:-}\" ]; then\n")
  content.add("    export PKG_CONFIG_PATH=\"$pkg_config_path:$PKG_CONFIG_PATH\"\n")
  content.add("  else\n")
  content.add("    export PKG_CONFIG_PATH=\"$pkg_config_path\"\n")
  content.add("  fi\n")
  content.add("fi\n")
  content.add("extra_sysroot_args=\n")
  content.add("if [ -n \"$sdk_root\" ]; then\n")
  when defined(macosx):
    content.add("  extra_sysroot_args=\"-DCMAKE_OSX_SYSROOT=$sdk_root\"\n")
  else:
    content.add("  extra_sysroot_args=\"-DCMAKE_SYSROOT=$sdk_root\"\n")
  content.add("fi\n")
  content.add("exec \"$cmake_bin\" -G Reprobuild ")
  content.add("-DCMAKE_TOOLCHAIN_FILE=\"$toolchain_file\" ")
  content.add("-DCMAKE_PREFIX_PATH=\"$prefix_path\" ")
  content.add("-DREPROBUILD_CMAKE_TOOL_PORTABILITY=" & modeName & " ")
  content.add("-DREPROBUILD_TOOL_PROFILE_ARTIFACT=" & q(identityPath) & " ")
  content.add("-DREPROBUILD_TOOL_PROFILE_INSPECTION=" & q(inspectionPath) & " ")
  content.add("$extra_sysroot_args \"$@\"\n")
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), content)
  setFilePermissions(extendedPath(path), {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc writeCMakeConfigureWrapperWindows(path: string;
                                       selectedCmake, toolchainPath,
                                       identityPath, inspectionPath, sourceRoot,
                                       reproPath, sourceRepoRoot, prefixValue,
                                       pkgValue,
                                       modeName: string) =
  # Windows: emit a PowerShell wrapper instead of a POSIX `sh` script. The
  # script behaviour mirrors the POSIX wrapper: define the same variables,
  # export the same REPRO_* environment, prepend PKG_CONFIG_PATH if any, and
  # invoke the forked cmake.exe with -G Reprobuild plus any caller args.
  # CMAKE_(OSX_)SYSROOT is intentionally omitted: MSVC has no sysroot concept
  # and the Windows SDK is selected implicitly by the active toolchain.
  var content = "# Generated by repro develop --cmake. Do not edit.\n"
  content.add("$ErrorActionPreference = 'Stop'\n")
  content.add("$cmake_bin = " & ps1SingleQuote(selectedCmake) & "\n")
  content.add("$toolchain_file = " & ps1SingleQuote(toolchainPath) & "\n")
  content.add("$prefix_path = " & ps1SingleQuote(prefixValue) & "\n")
  content.add("$pkg_config_path = " & ps1SingleQuote(pkgValue) & "\n")
  content.add("$repro_cli = " & ps1SingleQuote(reproPath) & "\n")
  content.add("$repro_source_root = " & ps1SingleQuote(sourceRepoRoot) & "\n")
  content.add("$env:REPROBUILD_REPRO = $repro_cli\n")
  content.add("$env:REPROBUILD_SOURCE_ROOT = $repro_source_root\n")
  content.add("$env:REPRO_TOOL_PROFILE_ARTIFACT = " &
    ps1SingleQuote(identityPath) & "\n")
  content.add("$env:REPRO_TOOL_PROFILE_INSPECTION = " &
    ps1SingleQuote(inspectionPath) & "\n")
  content.add("$env:REPRO_PROJECT_ROOT = " & ps1SingleQuote(sourceRoot) & "\n")
  # Windows: $env:PATH uses ';' as separator; use [IO.Path]::PathSeparator
  # so the wrapper stays correct even if cross-shelled later.
  content.add("if ($pkg_config_path) {\n")
  content.add("  $sep = [IO.Path]::PathSeparator\n")
  content.add("  if ($env:PKG_CONFIG_PATH) {\n")
  content.add("    $env:PKG_CONFIG_PATH = \"$pkg_config_path$sep$($env:PKG_CONFIG_PATH)\"\n")
  content.add("  } else {\n")
  content.add("    $env:PKG_CONFIG_PATH = $pkg_config_path\n")
  content.add("  }\n")
  content.add("}\n")
  # Build the cmake argv as a PowerShell array. We store the identity and
  # inspection paths in $env:... already and re-reference them here via
  # PowerShell variables so each array element is a single value PS-side
  # (avoids `+` concatenation surprises that CMake mis-parsed as extra
  # source-dir paths).
  content.add("$tool_profile_artifact = " &
    ps1SingleQuote(identityPath) & "\n")
  content.add("$tool_profile_inspection = " &
    ps1SingleQuote(inspectionPath) & "\n")
  content.add("$cmake_args = @(\n")
  content.add("  '-G', 'Reprobuild',\n")
  content.add("  \"-DCMAKE_TOOLCHAIN_FILE=$toolchain_file\",\n")
  content.add("  \"-DCMAKE_PREFIX_PATH=$prefix_path\",\n")
  content.add("  '-DREPROBUILD_CMAKE_TOOL_PORTABILITY=" & modeName & "',\n")
  content.add("  \"-DREPROBUILD_TOOL_PROFILE_ARTIFACT=$tool_profile_artifact\",\n")
  content.add("  \"-DREPROBUILD_TOOL_PROFILE_INSPECTION=$tool_profile_inspection\"\n")
  content.add(")\n")
  content.add("& $cmake_bin @cmake_args @args\n")
  content.add("exit $LASTEXITCODE\n")
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), content)

proc cmakeConfigureWrapperBaseName(): string =
  # Windows: emit a `.ps1` wrapper instead of an extensionless shell script so
  # PowerShell (and the develop runner) picks the right interpreter.
  when defined(windows):
    "repro-cmake-configure.ps1"
  else:
    "repro-cmake-configure"

proc writeCMakeConfigureWrapper(path: string; identity: PathOnlyBuildIdentity;
                                mode: ToolProvisioningMode; cmakeBinary,
                                toolchainPath, identityPath, inspectionPath,
                                sourceRoot, reproPath, sourceRepoRoot: string) =
  let cmakeProfile = identity.profileFor("cmake")
  let rawSelected =
    if cmakeBinary.len > 0:
      absolutePath(cmakeBinary)
    else:
      cmakeProfile.resolvedExecutablePath
  let selectedCmake = resolveCMakeExecutable(rawSelected)
  let prefixes = profilePrefixes(identity)
  # CMake list values (CMAKE_PREFIX_PATH and friends) ALWAYS use ';' as the
  # separator, independent of host platform. PKG_CONFIG_PATH uses the host
  # shell's PATH separator (`PathSep` is ';' on Windows, ':' on POSIX).
  let prefixValue = pathListJoin(prefixes, ';')
  let pkgValue = pathListJoin(pkgConfigPaths(prefixes), PathSep)
  when defined(windows):
    # Windows: the SDK / sysroot concept does not apply to MSVC.
    writeCMakeConfigureWrapperWindows(path, selectedCmake, toolchainPath,
      identityPath, inspectionPath, sourceRoot, reproPath, sourceRepoRoot,
      prefixValue, pkgValue, mode.modeName)
  else:
    let sdkRoot = sdkRootForCMake()
    writeCMakeConfigureWrapperPosix(path, selectedCmake, toolchainPath,
      identityPath, inspectionPath, sourceRoot, reproPath, sourceRepoRoot,
      prefixValue, pkgValue, sdkRoot, mode.modeName)

proc runCMakeDevelopCommand(target: string; mode: ToolProvisioningMode;
                            command: openArray[string]; workRoot,
                            cmakeBinary: string): int =
  if mode notin {tpmPathOnly, tpmNix}:
    raise newException(ValueError,
      "repro develop --cmake requires --tool-provisioning=path|nix")
  let sourceRoot = absolutePath(target)
  if not dirExists(extendedPath(sourceRoot)):
    raise newException(IOError, "cmake source directory not found: " & sourceRoot)
  if not fileExists(extendedPath(sourceRoot / "CMakeLists.txt")):
    raise newException(IOError,
      "cmake source directory does not contain CMakeLists.txt: " & sourceRoot)
  if cmakeBinary.len > 0 and not fileExists(extendedPath(cmakeBinary)):
    raise newException(IOError, "cmake binary not found: " & cmakeBinary)

  let outDir = cmakeDevelopOutDir(sourceRoot, workRoot)
  let interfacePath = outDir / "cmake-develop-interface.rbsz"
  let artifact = cmakeDevelopArtifact(sourceRoot)
  writeInterfaceArtifact(interfacePath, artifact)
  let resolved = resolveAndWriteIdentity(artifact, outDir, mode)
  let toolchainPath = outDir / "reprobuild-cmake-toolchain.cmake"
  # Windows: filename includes .ps1 so PowerShell will execute it directly.
  let wrapperPath = outDir / "bin" / cmakeConfigureWrapperBaseName()
  writeCMakeToolchain(toolchainPath, resolved.identity, mode,
    resolved.identityPath, resolved.inspectionPath)
  writeCMakeConfigureWrapper(wrapperPath, resolved.identity, mode, cmakeBinary,
    toolchainPath, resolved.identityPath, resolved.inspectionPath, sourceRoot,
    stablePublicCliPath(), reprobuildLibraryWorkDir())

  echo "repro develop: compatibility cmake dev-env path active " &
    "(provider-driven artifact integration pending, tool-provisioning=" &
    mode.modeName & ")"
  echo "project: " & artifact.projectInterface.projectName
  echo "interface: " & interfacePath
  echo "toolIdentity: " & resolved.identityPath
  echo "inspection: " & resolved.inspectionPath
  echo "toolchain: " & toolchainPath
  echo "configureWrapper: " & wrapperPath
  echo "cachePortability: " & (if mode == tpmNix: "portable" else: "local-only")
  echo "binDirs: " & binDirsForDevelop(resolved.identity).join($PathSep)
  for profile in resolved.identity.profiles:
    echo "tool: " & profile.executableName & " " &
      profile.resolvedExecutablePath

  if command.len == 0:
    return 0
  var devCommand = @["sh", "-c",
    "PATH=" & q(parentDir(wrapperPath) & $PathSep &
      binDirsForDevelop(resolved.identity).join($PathSep) & $PathSep &
      getEnv("PATH")) & " " & shellCommand(command)]
  runInDevelopEnvironment(devCommand, sourceRoot, resolved.identity,
    resolved.identityPath, resolved.inspectionPath, interfacePath)

proc runBuildCommand(args: openArray[string]; publicCliPath: string): int =
  var target = ""
  var mode = tpmUnspecified
  var workRoot = ""
  var progressMode = configuredBuildProgressMode()
  var statsMode = configuredBuildStatsMode()
  var reportMode = configuredBuildReportMode()
  var logMode = configuredBuildLogMode()
  var prepareOnly = false
  var skipCmakeRegeneration = false
  # Default: use runquota when reachable; --no-runquota forces full bypass.
  var bypassRunQuota = getEnv("REPROBUILD_NO_RUNQUOTA").normalize in
    ["1", "true", "yes", "on"]
  for arg in args:
    if arg.startsWith("--tool-provisioning="):
      mode = parseToolProvisioning(arg.split("=", maxsplit = 1)[1])
    elif arg == "--tool-provisioning":
      raise newException(ValueError,
        "--tool-provisioning requires an inline value, for example " &
          "--tool-provisioning=path")
    elif arg.startsWith("--work-root="):
      workRoot = arg.split("=", maxsplit = 1)[1]
    elif arg == "--work-root":
      raise newException(ValueError,
        "--work-root requires an inline value, for example --work-root=.repro")
    elif arg.startsWith("--progress="):
      progressMode = parseBuildProgressMode(arg.split("=", maxsplit = 1)[1])
    elif arg == "--progress":
      raise newException(ValueError,
        "--progress requires an inline value, for example --progress=auto")
    elif arg.startsWith("--stats="):
      statsMode = parseBuildStatsMode(arg.split("=", maxsplit = 1)[1])
    elif arg == "--stats":
      statsMode = bsmText
    elif arg.startsWith("--report="):
      reportMode = parseBuildReportMode(arg.split("=", maxsplit = 1)[1])
    elif arg == "--report":
      raise newException(ValueError,
        "--report requires an inline value, for example --report=full")
    elif arg.startsWith("--log="):
      logMode = parseBuildLogMode(arg.split("=", maxsplit = 1)[1])
    elif arg == "--log":
      raise newException(ValueError,
        "--log requires an inline value, for example --log=summary")
    elif arg == "--prepare-only":
      prepareOnly = true
    elif arg == "--skip-cmake-regeneration":
      skipCmakeRegeneration = true
    elif arg == "--no-runquota":
      bypassRunQuota = true
    elif arg == "--runquota":
      bypassRunQuota = false
    elif arg.startsWith("-"):
      raise newException(ValueError, "unsupported build flag: " & arg)
    elif target.len == 0:
      target = arg
    else:
      raise newException(ValueError, "unexpected build argument: " & arg)

  let targetWasOmitted = target.len == 0
  if targetWasOmitted:
    target = "."

  executeBuildTarget(target, mode, publicCliPath,
    selectDefaultAction = targetWasOmitted,
    workRoot = workRoot,
    progressMode = progressMode,
    statsMode = statsMode,
    reportMode = reportMode,
    logMode = logMode,
    prepareOnly = prepareOnly,
    skipCmakeRegeneration = skipCmakeRegeneration,
    bypassRunQuotaExplicit = bypassRunQuota).exitCode

proc parsePositiveIntFlag(flagName, value: string): int =
  try:
    result = parseInt(value)
  except ValueError:
    raise newException(ValueError, flagName & " must be an integer")
  if result <= 0:
    raise newException(ValueError, flagName & " must be greater than zero")

const CodetracerHcrSupportProfile =
  "macos-arm64-direct-hcr-in-codetracer-v1"

type
  HcrWatchConfig = object
    socketPath: string
    artifacts: string
    metadataPath: string

  HcrWatchPatchMetadata* = object
    functionName*: string
    targetSymbol*: string
    objectSymbol*: string
    objectPath*: string
    sourcePath*: string

  HcrWatchObjectBaseline* = object
    objectPath*: string
    sourcePath*: string
    generation0Object*: string

  HcrWatchInferredPatch* = object
    metadata*: HcrWatchPatchMetadata
    oldObject*: string
    newObject*: string

  HcrWatchSession = object
    enabled: bool
    config: HcrWatchConfig
    metadata: HcrWatchPatchMetadata
    inferredBaselines: seq[HcrWatchObjectBaseline]
    listener: HcrAgentUnixListener
    connection: HcrAgentSocketConnection
    client: HcrCoordinatorClient
    connected: bool
    oldObject: string
    newObject: string

proc writeJsonFile(path: string; node: JsonNode) =
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), pretty(node))

proc hcrSourceDigest(path: string): string =
  byteDigest(readFile(extendedPath(path)).bytesOf())

proc objectFunctionBytes(objectPath, symbolName: string): seq[byte] =
  let graph = parseMachOArm64Object(objectPath)
  let symbol = graph.findSymbol(symbolName)
  result = graph.functionBytes(symbol)
  if result.len == 0:
    raise newException(ValueError,
      "could not extract function bytes for " & symbolName & " from " &
        objectPath)

proc hcrWatchEnabled(config: HcrWatchConfig): bool =
  config.socketPath.len > 0 or config.artifacts.len > 0 or
    config.metadataPath.len > 0

proc validateHcrWatchConfig(config: HcrWatchConfig) =
  if not config.hcrWatchEnabled:
    return
  if config.socketPath.len == 0:
    raise newException(ValueError,
      "--hcr-agent-socket is required when HCR watch mode is enabled")
  if config.artifacts.len == 0:
    raise newException(ValueError,
      "--hcr-artifacts is required when HCR watch mode is enabled")

proc resolveProjectPath(projectRoot, path: string): string =
  if path.len == 0:
    return ""
  result =
    if path.isAbsolute:
      path
    else:
      projectRoot / path
  result = os.normalizedPath(result)

proc requiredJsonString(node: JsonNode; key, context: string): string =
  if node.kind != JObject or not node.hasKey(key):
    raise newException(ValueError, context & " missing required field " & key)
  result = node[key].getStr()
  if result.len == 0:
    raise newException(ValueError, context & " field " & key &
      " must not be empty")

proc optionalJsonString(node: JsonNode; key: string): string =
  if node.kind == JObject and node.hasKey(key):
    result = node[key].getStr()

proc defaultObjectSymbol(functionName: string): string =
  when defined(macosx):
    "_" & functionName
  else:
    functionName

proc readHcrWatchPatchMetadata(projectRoot, metadataPath: string):
    HcrWatchPatchMetadata =
  let resolvedMetadataPath = resolveProjectPath(projectRoot, metadataPath)
  if not fileExists(extendedPath(resolvedMetadataPath)):
    raise newException(ValueError,
      "HCR watch metadata does not exist: " & resolvedMetadataPath)
  let root = parseFile(resolvedMetadataPath)
  var patch: JsonNode = nil
  if root.kind == JObject and root.hasKey("patches") and
      root["patches"].kind == JArray and root["patches"].len > 0:
    patch = root["patches"][0]
  else:
    patch = root

  result.functionName = patch.requiredJsonString("function", "HCR patch metadata")
  result.targetSymbol = patch.optionalJsonString("targetSymbol")
  if result.targetSymbol.len == 0:
    result.targetSymbol = result.functionName
  result.objectSymbol = patch.optionalJsonString("objectSymbol")
  if result.objectSymbol.len == 0:
    result.objectSymbol = defaultObjectSymbol(result.functionName)
  result.objectPath = resolveProjectPath(
    projectRoot, patch.requiredJsonString("object", "HCR patch metadata"))
  result.sourcePath = resolveProjectPath(
    projectRoot, patch.requiredJsonString("source", "HCR patch metadata"))

proc jsonStringSeqField(node: JsonNode; key: string): seq[string] =
  let values = node{key}
  if values.kind != JArray:
    return
  for value in values:
    if value.kind == JString and value.getStr().len > 0:
      result.add value.getStr()

proc materialReportPath(projectRoot, path: string): string =
  if path.len == 0:
    return ""
  result =
    if path.isAbsolute:
      path
    else:
      projectRoot / path
  result = os.normalizedPath(result)

proc isCxxSource(path: string): bool =
  splitFile(path).ext.toLowerAscii in [".c", ".cc", ".cpp", ".cxx"]

proc isObjectFile(path: string): bool =
  splitFile(path).ext.toLowerAscii in [".o", ".obj"]

proc stripObjectSymbolPrefix(symbol: string): string =
  if symbol.startsWith("_") and symbol.len > 1:
    symbol[1 .. ^1]
  else:
    symbol

proc hcrWatchObjectCandidatesFromReport*(projectRoot, buildReportPath: string):
    seq[HcrWatchObjectBaseline] =
  if buildReportPath.len == 0 or not fileExists(extendedPath(buildReportPath)):
    raise newException(ValueError,
      "HCR watch inference requires a build report")
  let report = parseFile(buildReportPath)
  for action in report{"actions"}:
    let evidence = action{"evidence"}
    if evidence.kind != JObject:
      continue

    var inputs: seq[string]
    for key in ["declaredInputs", "depfileInputs", "monitorReads"]:
      for path in evidence.jsonStringSeqField(key):
        inputs.addUnique(projectRoot.materialReportPath(path))
    var sourceInputs: seq[string]
    for path in inputs:
      if path.isCxxSource and fileExists(extendedPath(path)):
        sourceInputs.addUnique(path)
    if sourceInputs.len != 1:
      continue

    for path in evidence.jsonStringSeqField("declaredOutputs"):
      let objectPath = projectRoot.materialReportPath(path)
      if objectPath.isObjectFile and fileExists(extendedPath(objectPath)):
        result.add HcrWatchObjectBaseline(
          objectPath: objectPath,
          sourcePath: sourceInputs[0])

proc captureInferredHcrWatchBaseline*(projectRoot, buildReportPath,
                                      artifacts: string):
    seq[HcrWatchObjectBaseline] =
  result = hcrWatchObjectCandidatesFromReport(projectRoot, buildReportPath)
  if result.len == 0:
    raise newException(ValueError,
      "HCR watch could not infer any C/C++ object outputs from the build report")
  createDir(extendedPath(artifacts))
  for i in 0 ..< result.len:
    let objectSegment = safePathSegment(result[i].objectPath, "object")
    result[i].generation0Object =
      artifacts / ("generation0-" & align($i, 4, '0') & "-" & objectSegment)
    copyFile(extendedPath(result[i].objectPath),
      extendedPath(result[i].generation0Object))

proc inferHcrWatchPatch*(baselines: openArray[HcrWatchObjectBaseline];
                         artifacts: string; cycle: int):
    HcrWatchInferredPatch =
  type Candidate = object
    baseline: HcrWatchObjectBaseline
    objectSymbol: string

  var candidates: seq[Candidate]
  for baseline in baselines:
    if not fileExists(extendedPath(baseline.generation0Object)) or
        not fileExists(extendedPath(baseline.objectPath)):
      continue
    let oldGraph = parseMachOArm64Object(baseline.generation0Object)
    let newGraph = parseMachOArm64Object(baseline.objectPath)
    let diff = diffFunctions(oldGraph, newGraph)
    for entry in diff.functions:
      case entry.kind
      of fckUnchanged:
        discard
      of fckRemoved:
        raise newException(ValueError,
          "HCR watch does not support removed function " & entry.name)
      of fckChangedCode, fckRelocationSignatureChanged, fckAdded:
        candidates.add Candidate(
          baseline: baseline,
          objectSymbol: entry.name)

  if candidates.len == 0:
    raise newException(ValueError,
      "HCR watch did not find a changed function in rebuilt object outputs")
  if candidates.len > 1:
    var names: seq[string]
    for candidate in candidates:
      names.add candidate.objectSymbol
    raise newException(ValueError,
      "HCR watch currently requires exactly one changed function; found " &
        names.join(", "))

  let candidate = candidates[0]
  let functionName = stripObjectSymbolPrefix(candidate.objectSymbol)
  let newObject = artifacts /
    (safePathSegment(functionName, "patch") & "-generation" &
      $(cycle - 1) & ".o")
  copyFile(extendedPath(candidate.baseline.objectPath), extendedPath(newObject))
  result = HcrWatchInferredPatch(
    metadata: HcrWatchPatchMetadata(
      functionName: functionName,
      targetSymbol: functionName,
      objectSymbol: candidate.objectSymbol,
      objectPath: candidate.baseline.objectPath,
      sourcePath: candidate.baseline.sourcePath),
    oldObject: candidate.baseline.generation0Object,
    newObject: newObject)

proc initHcrWatchSession(config: HcrWatchConfig): HcrWatchSession =
  config.validateHcrWatchConfig()
  result.enabled = config.hcrWatchEnabled
  result.config = config
  if result.enabled:
    createDir(extendedPath(config.artifacts))
    result.listener = listenHcrAgentUnixSocket(config.socketPath)
    result.client = initHcrCoordinatorClient(CodetracerHcrSupportProfile)

proc closeHcrWatchSession(session: var HcrWatchSession) =
  if session.enabled:
    if session.connected:
      session.connection.close()
      session.connected = false
    session.listener.close()

proc captureHcrWatchBaseline(session: var HcrWatchSession;
                             outcome: BuildCommandOutcome) =
  if not session.enabled:
    return
  if session.config.metadataPath.len > 0:
    session.metadata = readHcrWatchPatchMetadata(
      outcome.projectRoot, session.config.metadataPath)
    if not fileExists(extendedPath(session.metadata.objectPath)):
      raise newException(ValueError,
        "HCR watch object does not exist after initial build: " &
          session.metadata.objectPath)
    session.oldObject = session.config.artifacts /
      (safePathSegment(session.metadata.functionName, "patch") & "-generation0.o")
    copyFile(extendedPath(session.metadata.objectPath),
      extendedPath(session.oldObject))
    writeJsonFile(session.config.artifacts / "hcr-watch-baseline.json", %*{
      "schemaId": "reprobuild.hcr.watch-baseline.v1",
      "supportProfile": CodetracerHcrSupportProfile,
      "mode": "metadata",
      "function": session.metadata.functionName,
      "targetSymbol": session.metadata.targetSymbol,
      "objectSymbol": session.metadata.objectSymbol,
      "object": session.metadata.objectPath,
      "source": session.metadata.sourcePath,
      "generation0Object": session.oldObject
    })
    echo "repro watch: hcr baseline captured object=" &
      session.metadata.objectPath
  else:
    session.inferredBaselines = captureInferredHcrWatchBaseline(
      outcome.projectRoot, outcome.buildReportPath, session.config.artifacts)
    var objects = newJArray()
    for baseline in session.inferredBaselines:
      objects.add %*{
        "object": baseline.objectPath,
        "source": baseline.sourcePath,
        "generation0Object": baseline.generation0Object
      }
    writeJsonFile(session.config.artifacts / "hcr-watch-baseline.json", %*{
      "schemaId": "reprobuild.hcr.watch-baseline.v1",
      "supportProfile": CodetracerHcrSupportProfile,
      "mode": "inferred",
      "objects": objects
    })
    echo "repro watch: hcr baseline inferred objects=" &
      $session.inferredBaselines.len
  echo "repro watch: hcr waiting for agent socket=" & session.config.socketPath
  flushStdout()
  session.connection = acceptHcrAgentConnection(session.listener)
  session.connected = true
  discard session.client.receiveAgentMessage(session.connection)
  session.client.sendCoordinatorMessage(
    session.connection, session.client.coordinatorHelloAckMessage())
  echo "repro watch: hcr agent connected"
  flushStdout()

proc deliverHcrWatchPatch(session: var HcrWatchSession;
                          outcome: BuildCommandOutcome; cycle: int) =
  if not session.enabled:
    return
  if not session.connected:
    raise newException(ValueError,
      "HCR watch cannot deliver a patch before the target agent connects")
  if session.config.metadataPath.len > 0:
    session.metadata = readHcrWatchPatchMetadata(
      outcome.projectRoot, session.config.metadataPath)
    if not fileExists(extendedPath(session.metadata.objectPath)):
      raise newException(ValueError,
        "HCR watch object does not exist after rebuild: " &
          session.metadata.objectPath)
    session.newObject = session.config.artifacts /
      (safePathSegment(session.metadata.functionName, "patch") & "-generation" &
        $(cycle - 1) & ".o")
    copyFile(extendedPath(session.metadata.objectPath),
      extendedPath(session.newObject))
  else:
    let inferred = inferHcrWatchPatch(
      session.inferredBaselines, session.config.artifacts, cycle)
    session.metadata = inferred.metadata
    session.oldObject = inferred.oldObject
    session.newObject = inferred.newObject
    echo "repro watch: hcr inferred changed function=" &
      session.metadata.functionName & " object=" & session.metadata.objectPath
  if not fileExists(extendedPath(session.metadata.sourcePath)):
    raise newException(ValueError,
      "HCR watch source does not exist after rebuild: " &
        session.metadata.sourcePath)

  let patchBytes = objectFunctionBytes(session.newObject,
    session.metadata.objectSymbol)
  let sourceGeneration = HcrSourceGenerationEntry(
    sourcePath: session.metadata.sourcePath,
    generation: uint32(cycle - 1),
    snapshotDigest: hcrSourceDigest(session.metadata.sourcePath),
    lineTableDigest: byteDigest(patchBytes))
  let objectBytes = readFile(extendedPath(session.newObject)).bytesOf()
  let plan = directPatchPlanFromBytes(
    session.metadata.functionName, patchBytes,
    supportProfile = CodetracerHcrSupportProfile,
    snapshotId = "repro-watch-hcr-generation-" & $(cycle - 1))
  let request = directPatchRequest(
    patchId = "repro-watch-hcr-patch-" & align($(cycle - 1), 4, '0'),
    supportProfile = CodetracerHcrSupportProfile,
    changedFunctions = [session.metadata.functionName],
    targetSymbols = [session.metadata.targetSymbol],
    directPatchBytes = patchBytes,
    debugObjectBytes = objectBytes,
    unwindMetadataBytes = minimalAarch64EhFrameTemplate(),
    sourceGenerationMap = [sourceGeneration])
  session.client.sendCoordinatorMessage(
    session.connection, session.client.coordinatorPatchRequestMessage(request))
  while session.client.session.state == hssPatchRequested:
    discard session.client.receiveAgentMessage(session.connection)

  let delivery = HcrCoordinatorDelivery(
    session: session.client.session,
    transcript: session.client.transcript,
    patchApplied: session.client.patchApplied,
    patchFailed: session.client.patchFailed)
  writeJsonFile(session.config.artifacts / "hcr-coordinator-report.json",
    coordinatorDeliveryJson(delivery))
  writeJsonFile(session.config.artifacts / "agent-protocol-transcript.json",
    transcriptJson(session.client.transcript))
  writeJsonFile(session.config.artifacts / "patch-bundle-metadata.json", %*{
    "schemaId": "reprobuild.hcr.codetracer-patch-bundle-metadata.v1",
    "supportProfile": CodetracerHcrSupportProfile,
    "patchId": request.patchId,
    "changedFunction": session.metadata.functionName,
    "targetSymbol": session.metadata.targetSymbol,
    "objectSymbol": session.metadata.objectSymbol,
    "oldObject": session.oldObject,
    "newObject": session.newObject,
    "patchByteCount": patchBytes.len,
    "patchDigest": byteDigest(patchBytes),
    "debugObjectDigest": request.debugObjectPayload.digest,
    "unwindMetadataDigest": request.unwindMetadataPayload.digest,
    "sourceGeneration": %*{
      "sourcePath": sourceGeneration.sourcePath,
      "generation": sourceGeneration.generation,
      "snapshotDigest": sourceGeneration.snapshotDigest,
      "lineTableDigest": sourceGeneration.lineTableDigest
    },
    "patchPlan": patchPlanJson(plan),
    "watch": {
      "cycle": cycle,
      "sourceEditObservedByFilesystemWatcher": true
    }
  })

  if session.client.patchFailed.isSome:
    raise newException(ValueError,
      "HCR watch patch failed: " & session.client.patchFailed.get().message)
  if session.client.patchApplied.isNone:
    raise newException(ValueError,
      "HCR watch did not receive a patchApplied response")
  echo "repro watch: hcr patch applied patchId=" & request.patchId
  flushStdout()

proc runWatchCommand(args: openArray[string]; publicCliPath: string): int =
  var target = ""
  var mode = tpmUnspecified
  var maxCycles = 0
  var debounceMs = 250
  var workRoot = ""
  var hcrConfig: HcrWatchConfig

  for arg in args:
    if arg.startsWith("--tool-provisioning="):
      mode = parseToolProvisioning(arg.split("=", maxsplit = 1)[1])
    elif arg == "--tool-provisioning":
      raise newException(ValueError,
        "--tool-provisioning requires an inline value, for example " &
          "--tool-provisioning=path")
    elif arg.startsWith("--work-root="):
      workRoot = arg.split("=", maxsplit = 1)[1]
    elif arg == "--work-root":
      raise newException(ValueError,
        "--work-root requires an inline value, for example --work-root=.repro")
    elif arg.startsWith("--max-cycles="):
      maxCycles = parsePositiveIntFlag("--max-cycles",
        arg.split("=", maxsplit = 1)[1])
    elif arg.startsWith("--debounce-ms="):
      debounceMs = parsePositiveIntFlag("--debounce-ms",
        arg.split("=", maxsplit = 1)[1])
    elif arg.startsWith("--hcr-agent-socket="):
      hcrConfig.socketPath = arg.split("=", maxsplit = 1)[1]
    elif arg == "--hcr-agent-socket":
      raise newException(ValueError,
        "--hcr-agent-socket requires an inline value, for example " &
          "--hcr-agent-socket=/tmp/repro-hcr.sock")
    elif arg.startsWith("--hcr-artifacts="):
      hcrConfig.artifacts = arg.split("=", maxsplit = 1)[1]
    elif arg == "--hcr-artifacts":
      raise newException(ValueError,
        "--hcr-artifacts requires an inline value, for example " &
          "--hcr-artifacts=.repro/hcr")
    elif arg.startsWith("--hcr-metadata="):
      hcrConfig.metadataPath = arg.split("=", maxsplit = 1)[1]
    elif arg == "--hcr-metadata":
      raise newException(ValueError,
        "--hcr-metadata requires an inline value, for example " &
          "--hcr-metadata=build/hcr-metadata.json")
    elif arg.startsWith("-"):
      raise newException(ValueError, "unsupported watch flag: " & arg)
    elif target.len == 0:
      target = arg
    else:
      raise newException(ValueError, "unexpected watch argument: " & arg)

  let targetWasOmitted = target.len == 0
  if targetWasOmitted:
    target = "."
  if mode notin {tpmPathOnly, tpmNix, tpmTarball, tpmScoop}:
    raise newException(ValueError,
      "repro watch requires --tool-provisioning=path|nix|tarball|scoop")
  # Windows: kqueue gate dropped — Windows now reaches the live watch loop
  # via ReadDirectoryChangesW in repro_cli_support/watch. Linux still
  # surfaces the deferred-backend OSError from openFilesystemWatcher.

  echo "repro watch: target=" & target & " tool-provisioning=" &
    mode.modeName & " debounceMs=" & $debounceMs &
    (if maxCycles > 0: " maxCycles=" & $maxCycles else: " maxCycles=unbounded") &
    (if hcrConfig.hcrWatchEnabled: " hcr=enabled" else: " hcr=disabled")
  flushStdout()

  var hcrSession = initHcrWatchSession(hcrConfig)
  defer:
    hcrSession.closeHcrWatchSession()

  var cycle = 0
  while true:
    cycle.inc
    echo "repro watch: cycle " & $cycle & " start" &
      (if cycle == 1: " initial" else: " rebuild")
    flushStdout()
    let outcome = executeBuildTarget(target, mode, publicCliPath,
      selectDefaultAction = targetWasOmitted,
      workRoot = workRoot)
    echo "repro watch: cycle " & $cycle & " result exitCode=" &
      $outcome.exitCode
    flushStdout()
    if outcome.exitCode != 0:
      return outcome.exitCode
    if hcrSession.enabled:
      if cycle == 1:
        hcrSession.captureHcrWatchBaseline(outcome)
      else:
        hcrSession.deliverHcrWatchPatch(outcome, cycle)
    if maxCycles > 0 and cycle >= maxCycles:
      echo "repro watch: max cycles reached"
      flushStdout()
      return 0

    let paths = watchPathsFromReport(outcome)
    var watcher = openFilesystemWatcher(paths)
    try:
      echo "repro watch: watching paths=" & $watcher.watchedPathCount
      flushStdout()
      let event = watcher.waitForEvent()
      echo "repro watch: event seen path=" & event.path &
        " detail=" & event.detail
      flushStdout()
      let coalesced = watcher.drainDebouncedEvents(debounceMs)
      echo "repro watch: debounce complete coalesced=" & $coalesced
      echo "repro watch: rebuild cycle after filesystem event"
      flushStdout()
    finally:
      watcher.closeFilesystemWatcher()

proc runDevelopCommand(args: openArray[string]): int =
  var target = ""
  var mode = tpmUnspecified
  var command: seq[string] = @[]
  var afterSeparator = false
  var workRoot = ""
  var cmakeMode = false
  var cmakeBinary = ""
  var listOverrides = false
  var intoPath = ""
  var i = 0
  while i < args.len:
    let arg = args[i]
    if afterSeparator:
      command.add(arg)
    elif arg == "--":
      afterSeparator = true
    elif arg == "--cmake":
      cmakeMode = true
    elif arg == "--list":
      listOverrides = true
    elif arg == "--into" or arg.startsWith("--into="):
      intoPath = valueFromFlag(args, i, "--into")
    elif arg.startsWith("--tool-provisioning="):
      mode = parseToolProvisioning(arg.split("=", maxsplit = 1)[1])
    elif arg == "--tool-provisioning":
      raise newException(ValueError,
        "--tool-provisioning requires an inline value, for example " &
        "--tool-provisioning=nix")
    elif arg.startsWith("--cmake-binary="):
      cmakeBinary = arg.split("=", maxsplit = 1)[1]
    elif arg == "--cmake-binary":
      raise newException(ValueError,
        "--cmake-binary requires an inline value, for example " &
          "--cmake-binary=/path/to/cmake")
    elif arg.startsWith("--work-root="):
      workRoot = arg.split("=", maxsplit = 1)[1]
    elif arg == "--work-root":
      raise newException(ValueError,
        "--work-root requires an inline value, for example --work-root=.repro")
    elif arg.startsWith("-"):
      raise newException(ValueError, "unsupported develop flag: " & arg)
    elif target.len == 0:
      target = arg
    else:
      raise newException(ValueError, "unexpected develop argument before --: " & arg)
    inc i

  if listOverrides:
    if target.len > 0 or intoPath.len > 0 or command.len > 0 or cmakeMode:
      raise newException(ValueError,
        "repro develop --list does not accept a target, --into, --cmake, or a command")
    let projectRoot = activeProjectRootFromCwd()
    for entry in readDevelopOverrides(developOverridesMetadataPath(projectRoot)):
      echo entry.node & "\t" & entry.path
    return 0

  if intoPath.len > 0:
    if cmakeMode or mode != tpmUnspecified or command.len > 0:
      raise newException(ValueError,
        "repro develop <dependency> --into=PATH cannot be combined with " &
          "--cmake, --tool-provisioning, or -- <command>")
    if target.len == 0:
      raise newException(ValueError,
        "repro develop --into=PATH requires a dependency name")
    let projectRoot = activeProjectRootFromCwd()
    let localPath = resolveDevelopOverrideCheckout(target, intoPath)
    let metadataPath = upsertDevelopOverride(projectRoot, target, localPath)
    echo target & "\t" & localPath
    echo "metadata\t" & metadataPath
    return 0

  if target.len == 0:
    raise newException(ValueError, "missing develop target")

  if cmakeMode:
    if mode == tpmUnspecified:
      raise newException(ValueError,
        "repro develop --cmake requires --tool-provisioning=path|nix")
    return runCMakeDevelopCommand(target, mode, command, workRoot, cmakeBinary)

  let modulePath = absolutePath(moduleForTarget(target))
  if not fileExists(extendedPath(modulePath)):
    raise newException(IOError, "develop target module not found: " & modulePath)

  let scopedRoot = scopedWorktreeRoot(modulePath, workRoot)
  let outDir =
    if scopedRoot.len > 0:
      scopedRoot / "develop"
    else:
      parentDir(modulePath) / ".repro" / "develop"
  let interfacePath = outDir / "project-interface.rbsz"
  let stubPath = outDir / "project-interface.nim"
  let compileWorkDir = reprobuildLibraryWorkDir()
  let compileScratchDir = outDir / "provider-work"
  let artifact = extractInterfaceFromModule(modulePath, interfacePath, stubPath,
    compileWorkDir, compileScratchDir)

  if artifact.projectInterface.toolUses.len > 0 and mode == tpmUnspecified:
    raise newException(ValueError,
      "typed tool provisioning is required for uses declarations; refusing " &
        "implicit PATH fallback. Pass --tool-provisioning=path for the weak " &
        "local profile, or --tool-provisioning=nix|tarball for a provisioned " &
        "development environment.")

  if mode == tpmUnspecified:
    echo "repro develop: compatibility dev-env path active (provider-driven " &
      "artifact integration pending); no external tools requested"
    if command.len == 0:
      return 0
    return runInDevelopEnvironment(command, projectRootForModule(modulePath),
      PathOnlyBuildIdentity(projectName: artifact.projectInterface.projectName,
        interfaceFingerprint: artifact.interfaceFingerprint),
      "", "", interfacePath)

  if mode notin {tpmPathOnly, tpmNix, tpmTarball, tpmScoop}:
    raise newException(ValueError,
      "unsupported develop tool provisioning mode: " & mode.modeName)

  let resolved = resolveAndWriteIdentity(artifact, outDir, mode)
  echo "repro develop: compatibility dev-env path active (provider-driven " &
    "artifact integration pending, tool-provisioning=" & mode.modeName & ")"
  echo "project: " & artifact.projectInterface.projectName
  echo "interface: " & interfacePath
  echo "toolIdentity: " & resolved.identityPath
  echo "inspection: " & resolved.inspectionPath
  echo "binDirs: " & binDirsForDevelop(resolved.identity).join($PathSep)

  if command.len == 0:
    for profile in resolved.identity.profiles:
      echo "tool: " & profile.executableName & " " &
        profile.resolvedExecutablePath
    return 0

  runInDevelopEnvironment(command, projectRootForModule(modulePath),
    resolved.identity, resolved.identityPath, resolved.inspectionPath,
    interfacePath)

proc runStoreCommand*(args: seq[string]): int =
  ## Implements `repro store <subcommand>` for the M56 unified local
  ## content-addressed store. Supported subcommands:
  ##
  ##   gc       — eager garbage collection (SQL dead-set query plus a
  ##              filesystem move into `gc/pending-deletion/` and a
  ##              post-grace unlink sweep).
  ##   recover  — `PRAGMA quick_check`, sweep `tmp/`, and reconcile
  ##              on-disk `prefixes/...` directories against the
  ##              SQLite index.
  ##   roots    — list the currently-registered roots.
  ##   list     — list every realized prefix recorded in the index.
  ##
  ## Each subcommand accepts an optional `--store-root=PATH` to
  ## override the per-user default; the `$REPRO_STORE_ROOT` env var
  ## is honoured otherwise.
  if args.len == 0:
    echo "usage: repro store {gc | recover | roots | list} " &
      "[--store-root=PATH] [--grace-seconds=N]"
    return 2
  var storeRootOverride = ""
  var graceSeconds = DefaultGcGraceSeconds
  var sub = ""
  for raw in args:
    if raw.startsWith("--store-root="):
      storeRootOverride = raw[len("--store-root=") .. ^1]
    elif raw.startsWith("--grace-seconds="):
      graceSeconds = parseInt(raw[len("--grace-seconds=") .. ^1])
    elif raw.startsWith("--"):
      stderr.writeLine("repro store: unknown flag: " & raw)
      return 2
    elif sub.len == 0:
      sub = raw
    else:
      stderr.writeLine("repro store: unexpected argument: " & raw)
      return 2
  if sub.len == 0:
    stderr.writeLine("repro store: missing subcommand")
    return 2

  let root = resolveStoreRoot(storeRootOverride)
  try:
    var store = openStore(root)
    defer: store.close()
    case sub
    of "gc":
      let report = store.gc(graceSeconds = graceSeconds)
      echo "repro store gc: store-root=" & root
      echo "quarantined: " & $report.quarantined.len
      for row in report.quarantined:
        echo "  - " & row.adapter & " " & row.packageName & " " &
          row.version
      echo "reclaimed: " & $report.reclaimed.len
      for path in report.reclaimed:
        echo "  - " & path
      return 0
    of "recover":
      let report = store.recover()
      echo "repro store recover: store-root=" & root
      echo "quick_check: " & report.quickCheck
      echo "swept staging dirs: " & $report.sweptStagingDirs.len
      for path in report.sweptStagingDirs: echo "  - " & path
      echo "reinserted prefixes: " & $report.reinsertedPrefixes.len
      for path in report.reinsertedPrefixes: echo "  - " & path
      echo "quarantined prefixes: " & $report.quarantinedPrefixes.len
      for path in report.quarantinedPrefixes: echo "  - " & path
      return 0
    of "roots":
      echo "repro store roots: store-root=" & root
      for row in store.listRoots():
        echo "  - " & row.rootId & " (" & row.kind & ")"
      return 0
    of "list":
      echo "repro store list: store-root=" & root
      for row in store.listPrefixes():
        echo "  - " & row.adapter & " " & row.packageName & " " &
          row.version & " " & row.realizedPath
      return 0
    else:
      stderr.writeLine("repro store: unknown subcommand: " & sub)
      return 2
  except CatchableError as err:
    stderr.writeLine("repro store " & sub & ": error: " & err.msg)
    return 1

proc runLaunchPlanCommand*(args: seq[string]): int =
  ## Implements `repro launch-plan <subcommand>`. v1 subcommands:
  ##
  ##   show <hex-id>      Render the LaunchPlan stored in the local M56
  ##                      CAS as a JSON inspection view. The JSON form
  ##                      is debug output only — the canonical record is
  ##                      the binary RBLP envelope.
  ##   id <path>          Compute the BLAKE3-256 launchPlanId of a
  ##                      LaunchPlan envelope on disk without opening
  ##                      the store. Useful when verifying activation
  ##                      artifacts.
  ##
  ## Both subcommands accept `--store-root=PATH` and honour
  ## `$REPRO_STORE_ROOT` exactly as `repro store ...` does.
  if args.len == 0:
    echo "usage: repro launch-plan {show <hex-id> | id <path>} " &
      "[--store-root=PATH]"
    return 2
  var storeRootOverride = ""
  var positional: seq[string] = @[]
  for raw in args:
    if raw.startsWith("--store-root="):
      storeRootOverride = raw[len("--store-root=") .. ^1]
    elif raw.startsWith("--"):
      stderr.writeLine("repro launch-plan: unknown flag: " & raw)
      return 2
    else:
      positional.add(raw)
  if positional.len == 0:
    stderr.writeLine("repro launch-plan: missing subcommand")
    return 2
  let sub = positional[0]
  case sub
  of "show":
    if positional.len < 2:
      stderr.writeLine("repro launch-plan show: missing <hex-id>")
      return 2
    let hex = positional[1].toLowerAscii
    if hex.len != 64:
      stderr.writeLine(
        "repro launch-plan show: expected 64-char hex digest, got " &
        $hex.len & " chars")
      return 2
    let root = resolveStoreRoot(storeRootOverride)
    try:
      var store = openStore(root)
      defer: store.close()
      var id: PrefixIdBytes
      for i in 0 ..< 32:
        let hi = parseHexInt($hex[i * 2])
        let lo = parseHexInt($hex[i * 2 + 1])
        id[i] = byte((hi shl 4) or lo)
      let plan = store.loadLaunchPlan(id)
      echo launchPlanToJson(plan)
      return 0
    except CatchableError as err:
      stderr.writeLine("repro launch-plan show: error: " & err.msg)
      return 1
  of "id":
    if positional.len < 2:
      stderr.writeLine("repro launch-plan id: missing <path>")
      return 2
    let path = positional[1]
    try:
      let raw = readFile(extendedPath(path))
      var buf = newSeq[byte](raw.len)
      for i, ch in raw: buf[i] = byte(ord(ch))
      let plan = decodeLaunchPlan(buf)
      echo launchPlanIdHex(plan)
      return 0
    except CatchableError as err:
      stderr.writeLine("repro launch-plan id: error: " & err.msg)
      return 1
  else:
    stderr.writeLine("repro launch-plan: unknown subcommand: " & sub)
    return 2

type
  HcrCoordinateArgs = object
    project: string
    target: string
    socketPath: string
    sourceEditDriver: string
    artifacts: string
    patchFunction: string

proc parseHcrCoordinateArgs(args: seq[string]): HcrCoordinateArgs =
  result.patchFunction = "reprobuild_hcr_patchable_value"
  var index = 0
  while index < args.len:
    let arg = args[index]
    proc valueFor(flag: string): string =
      let prefix = flag & "="
      if arg.startsWith(prefix):
        return arg[prefix.len .. ^1]
      if arg == flag:
        if index + 1 >= args.len:
          raise newException(ValueError, flag & " requires a value")
        index.inc
        return args[index]
      raise newException(ValueError, "internal HCR argument parse error")

    if arg == "--project" or arg.startsWith("--project="):
      result.project = valueFor("--project")
    elif arg == "--target" or arg.startsWith("--target="):
      result.target = valueFor("--target")
    elif arg == "--socket" or arg.startsWith("--socket="):
      result.socketPath = valueFor("--socket")
    elif arg == "--source-edit-driver" or
        arg.startsWith("--source-edit-driver="):
      result.sourceEditDriver = valueFor("--source-edit-driver")
    elif arg == "--artifacts" or arg.startsWith("--artifacts="):
      result.artifacts = valueFor("--artifacts")
    elif arg == "--patch-function" or arg.startsWith("--patch-function="):
      result.patchFunction = valueFor("--patch-function")
    else:
      raise newException(ValueError, "unsupported HCR coordinate flag: " & arg)
    index.inc

proc requireHcrArg(value, name: string) =
  if value.len == 0:
    raise newException(ValueError, name & " is required")

proc requireHcrFile(path, name: string) =
  requireHcrArg(path, name)
  if not fileExists(extendedPath(path)):
    raise newException(ValueError, name & " does not exist: " & path)

proc requireHcrDir(path, name: string) =
  requireHcrArg(path, name)
  if not dirExists(extendedPath(path)):
    raise newException(ValueError, name & " does not exist: " & path)

proc runHcrBuildCycle(project, target, logPath: string): string =
  let targetArg = project & "#" & target
  let command = shellCommand([
    getAppFilename(), "build", targetArg,
    "--tool-provisioning=path",
    "--progress=none",
    "--log=actions"])
  let res = execCmdEx(command, workingDir = project)
  result = res.output
  createDir(extendedPath(parentDir(logPath)))
  writeFile(extendedPath(logPath), res.output)
  if res.exitCode != 0:
    raise newException(ValueError,
      "repro build failed during HCR coordination with exit code " &
        $res.exitCode & "\n" & res.output)

type HcrPrepareObjectArgs = object
  input: string
  output: string
  functionName: string
  segmentName: string
  allCodeSections: bool

proc parseHcrPrepareObjectArgs(args: seq[string]): HcrPrepareObjectArgs =
  result.segmentName = "__HCR"
  var index = 0
  proc valueFor(name: string): string =
    let arg = args[index]
    let prefix = name & "="
    if arg.startsWith(prefix):
      arg[prefix.len .. ^1]
    else:
      index.inc
      if index >= args.len:
        raise newException(ValueError, name & " requires a value")
      args[index]

  while index < args.len:
    let arg = args[index]
    if arg == "--input" or arg.startsWith("--input="):
      result.input = valueFor("--input")
    elif arg == "--output" or arg.startsWith("--output="):
      result.output = valueFor("--output")
    elif arg == "--function" or arg.startsWith("--function="):
      result.functionName = valueFor("--function")
    elif arg == "--all-code":
      result.allCodeSections = true
    elif arg == "--segment" or arg.startsWith("--segment="):
      result.segmentName = valueFor("--segment")
    else:
      raise newException(ValueError,
        "unsupported HCR prepare-object flag: " & arg)
    index.inc

proc runHcrPrepareObjectCommand(args: seq[string]): int =
  let parsed = parseHcrPrepareObjectArgs(args)
  requireHcrFile(parsed.input, "--input")
  requireHcrArg(parsed.output, "--output")
  if parsed.functionName.len == 0 and not parsed.allCodeSections:
    raise newException(ValueError, "--function or --all-code is required")
  if parsed.functionName.len > 0 and parsed.allCodeSections:
    raise newException(ValueError, "--function and --all-code are mutually exclusive")
  requireHcrArg(parsed.segmentName, "--segment")
  createDir(extendedPath(parentDir(parsed.output)))
  if parsed.allCodeSections:
    let count = rewriteMachOArm64CodeSectionSegments(
      parsed.input, parsed.output, parsed.segmentName)
    echo "repro hcr prepare-object: output=" & parsed.output &
      " codeSections=" & $count & " segment=" & parsed.segmentName
  else:
    rewriteMachOArm64FunctionSectionSegment(
      parsed.input, parsed.output, parsed.functionName, parsed.segmentName)
    echo "repro hcr prepare-object: output=" & parsed.output &
      " function=" & parsed.functionName & " segment=" & parsed.segmentName
  0

proc runHcrCoordinateCommand(args: seq[string]): int =
  if args.len == 0:
    stderr.writeLine(
      "repro hcr coordinate --project PATH --target NAME --socket PATH " &
      "--source-edit-driver PATH --artifacts PATH\n" &
      "repro hcr prepare-object --input PATH --output PATH " &
      "(--function NAME|--all-code) " &
      "[--segment NAME]")
    return 2
  if args[0] == "prepare-object":
    return runHcrPrepareObjectCommand(args[1 .. ^1])
  if args[0] != "coordinate":
    stderr.writeLine("repro hcr: unknown subcommand: " & args[0])
    return 2

  var parsed = parseHcrCoordinateArgs(args[1 .. ^1])
  requireHcrDir(parsed.project, "--project")
  requireHcrArg(parsed.target, "--target")
  requireHcrArg(parsed.socketPath, "--socket")
  requireHcrFile(parsed.sourceEditDriver, "--source-edit-driver")
  requireHcrArg(parsed.artifacts, "--artifacts")
  createDir(extendedPath(parsed.artifacts))

  let patchObject = parsed.project / "build" / "patchable.o"
  requireHcrFile(patchObject, "initial patchable object")
  let oldObject = parsed.artifacts / "patchable-generation0.o"
  copyFile(extendedPath(patchObject), extendedPath(oldObject))

  var listener = listenHcrAgentUnixSocket(parsed.socketPath)
  defer: listener.close()
  var connection = acceptHcrAgentConnection(listener)
  defer: connection.close()

  var client = initHcrCoordinatorClient(CodetracerHcrSupportProfile)
  discard client.receiveAgentMessage(connection)
  client.sendCoordinatorMessage(connection, client.coordinatorHelloAckMessage())

  let edit = execCmdEx(shellCommand([parsed.sourceEditDriver, parsed.project]),
    workingDir = parsed.project)
  writeFile(extendedPath(parsed.artifacts / "source-edit-driver.log"), edit.output)
  if edit.exitCode != 0:
    raise newException(ValueError,
      "source edit driver failed with exit code " & $edit.exitCode &
        "\n" & edit.output)

  discard runHcrBuildCycle(parsed.project, parsed.target,
    parsed.artifacts / "reprobuild-build-report.txt")
  requireHcrFile(patchObject, "rebuilt patchable object")
  let newObject = parsed.artifacts / "patchable-generation1.o"
  copyFile(extendedPath(patchObject), extendedPath(newObject))

  let symbolName = "_" & parsed.patchFunction
  let patchBytes = objectFunctionBytes(newObject, symbolName)
  let sourcePath = parsed.project / "src" / "patchable.c"
  let sourceGeneration = HcrSourceGenerationEntry(
    sourcePath: sourcePath,
    generation: 1'u32,
    snapshotDigest: hcrSourceDigest(sourcePath),
    lineTableDigest: byteDigest(patchBytes))
  let objectBytes = readFile(extendedPath(newObject)).bytesOf()
  let plan = directPatchPlanFromBytes(parsed.patchFunction, patchBytes,
    supportProfile = CodetracerHcrSupportProfile,
    snapshotId = "codetracer-hcr-generation-1")
  let request = directPatchRequest(
    patchId = "codetracer-hcr-patch-0001",
    supportProfile = CodetracerHcrSupportProfile,
    changedFunctions = [parsed.patchFunction],
    targetSymbols = [parsed.patchFunction],
    directPatchBytes = patchBytes,
    debugObjectBytes = objectBytes,
    unwindMetadataBytes = minimalAarch64EhFrameTemplate(),
    sourceGenerationMap = [sourceGeneration])
  client.sendCoordinatorMessage(connection,
    client.coordinatorPatchRequestMessage(request))
  while client.session.state == hssPatchRequested:
    discard client.receiveAgentMessage(connection)

  let delivery = HcrCoordinatorDelivery(
    session: client.session,
    transcript: client.transcript,
    patchApplied: client.patchApplied,
    patchFailed: client.patchFailed)
  writeJsonFile(parsed.artifacts / "hcr-coordinator-report.json",
    coordinatorDeliveryJson(delivery))
  writeJsonFile(parsed.artifacts / "agent-protocol-transcript.json",
    transcriptJson(client.transcript))
  writeJsonFile(parsed.artifacts / "patch-bundle-metadata.json", %*{
    "schemaId": "reprobuild.hcr.codetracer-patch-bundle-metadata.v1",
    "supportProfile": CodetracerHcrSupportProfile,
    "patchId": request.patchId,
    "changedFunction": parsed.patchFunction,
    "targetSymbol": parsed.patchFunction,
    "objectSymbol": symbolName,
    "oldObject": oldObject,
    "newObject": newObject,
    "patchByteCount": patchBytes.len,
    "patchDigest": byteDigest(patchBytes),
    "debugObjectDigest": request.debugObjectPayload.digest,
    "unwindMetadataDigest": request.unwindMetadataPayload.digest,
    "sourceGeneration": %*{
      "sourcePath": sourceGeneration.sourcePath,
      "generation": sourceGeneration.generation,
      "snapshotDigest": sourceGeneration.snapshotDigest,
      "lineTableDigest": sourceGeneration.lineTableDigest
    },
    "patchPlan": patchPlanJson(plan)
  })

  if client.patchFailed.isSome:
    stderr.writeLine("repro hcr coordinate: agent patch failed: " &
      client.patchFailed.get().message)
    return 1
  if client.patchApplied.isNone:
    stderr.writeLine("repro hcr coordinate: no patchApplied response")
    return 1
  0

proc runPrivilegedBrokerMode(args: openArray[string]): int =
  ## The hidden `repro --privileged-broker --channel <name> --token
  ## <nonce> [--file-prefix <dir>]` entrypoint (M81 deliverable 3).
  ## The broker is the SAME `repro` binary re-execed; this mode
  ## connects back to the launching parent over the authenticated
  ## RBEB channel and services the closed, typed `PrivilegedOperation`
  ## stream. It is one-shot — it exits when the parent sends `Done`.
  try:
    let parsed = parseBrokerModeArgs(args)
    doAssert parsed.isBrokerMode
    let ctx = FixtureContext(filePrefix: parsed.filePrefix)
    return runBrokerSession(parsed.token, ctx)
  except EElevation as err:
    stderr.writeLine("repro --privileged-broker: " & err.msg)
    return 7
  except CatchableError as err:
    stderr.writeLine("repro --privileged-broker: error: " & err.msg)
    return 7

proc runThinApp*(programName: string): int =
  let args = commandLineParams()
  let publicCliPath = stablePublicCliPath()
  if programName == "repro" and args.len > 0 and
      args[0] == BrokerModeFlag:
    return runPrivilegedBrokerMode(args)
  if wantsVersion(args):
    echo renderVersion(programName)
    return 0
  if programName == "repro-fs-snoop":
    return runFsSnoopCli(programName, args)
  if args.len > 0 and args[0] == "__repro-runquota-helper":
    let helperArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    return runRunQuotaHelperCli(helperArgs)
  if args.len > 0 and args[0] == "__repro-compile-provider":
    let helperArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    return runProviderCompileHelper(helperArgs)
  if args.len > 0 and args[0] == "__repro-dev-env-introspect":
    let helperArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    return runDevEnvIntrospectionHelper(helperArgs)
  if args.len > 0 and args[0] == "__repro-render-dev-env-shell":
    let helperArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    return runDevEnvShellRenderHelper(helperArgs)
  if args.len > 0 and args[0] == "__repro-direnv-activate":
    let helperArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    try:
      return runReproDirenvActivationHelper(helperArgs, publicCliPath)
    except CatchableError as err:
      stderr.writeLine("repro direnv activate: error: " & err.msg)
      return 1
  if args.len > 0 and args[0] == "__repro-native-shell-activate":
    let helperArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    try:
      return runReproNativeShellActivationHelper(helperArgs, publicCliPath)
    except CatchableError as err:
      stderr.writeLine("repro native shell activate: error: " & err.msg)
      return 1
  if args.len > 0 and args[0] == "__repro-dev-session-supervisor":
    let helperArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    try:
      return runDevSessionSupervisorHelper(helperArgs, publicCliPath)
    except CatchableError as err:
      stderr.writeLine("repro dev-session supervisor: error: " & err.msg)
      return 1
  if args.len > 0 and args[0] == "__repro-dev-session-http":
    let helperArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    try:
      return runDevSessionHttpHelper(helperArgs)
    except CatchableError as err:
      stderr.writeLine("repro dev-session http: error: " & err.msg)
      return 1
  if args.len > 0 and args[0] == "__repro-cmake-regenerate":
    let helperArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    try:
      return runCmakeRegenerationHelper(helperArgs)
    except CatchableError as err:
      stderr.writeLine("repro cmake regeneration: error: " & err.msg)
      return 1
  if programName == "repro" and args.len >= 2 and args[0] == "debug" and
      args[1] == "fs-snoop":
    let fsArgs =
      if args.len > 2:
        args[2 .. ^1]
      else:
        @[]
    return runFsSnoopCli("repro debug fs-snoop", fsArgs)
  if programName == "repro" and args.len > 0 and args[0] == "capabilities":
    try:
      let capabilityArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runCapabilitiesCommand(capabilityArgs)
    except CatchableError as err:
      stderr.writeLine("repro capabilities: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "build":
    try:
      let buildArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runBuildCommand(buildArgs, publicCliPath)
    except CatchableError as err:
      stderr.writeLine("repro build: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "exec":
    try:
      let execArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runReproExecCommand(execArgs, publicCliPath)
    except CatchableError as err:
      stderr.writeLine("repro exec: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "shell":
    try:
      let shellArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runReproShellCommand(shellArgs, publicCliPath)
    except CatchableError as err:
      stderr.writeLine("repro shell: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "up":
    try:
      let upArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runUpOrDevCommand(upArgs, publicCliPath, dsmUp)
    except CatchableError as err:
      stderr.writeLine("repro up: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "down":
    try:
      let downArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runDownCommand(downArgs)
    except CatchableError as err:
      stderr.writeLine("repro down: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "dev":
    try:
      let devArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runUpOrDevCommand(devArgs, publicCliPath, dsmDev)
    except CatchableError as err:
      stderr.writeLine("repro dev: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "hooks":
    try:
      let hookArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runHooksCommand(hookArgs)
    except CatchableError as err:
      stderr.writeLine("repro hooks: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "watch":
    try:
      let watchArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runWatchCommand(watchArgs, publicCliPath)
    except CatchableError as err:
      stderr.writeLine("repro watch: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "hcr":
    try:
      let hcrArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runHcrCoordinateCommand(hcrArgs)
    except CatchableError as err:
      stderr.writeLine("repro hcr: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "develop":
    try:
      let developArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runDevelopCommand(developArgs)
    except CatchableError as err:
      stderr.writeLine("repro develop: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "store":
    let storeArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    return runStoreCommand(storeArgs)
  if programName == "repro" and args.len > 0 and args[0] == "launch-plan":
    let lpArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    return runLaunchPlanCommand(lpArgs)
  if programName == "repro" and args.len > 0 and args[0] == "home":
    let homeArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    return runHomeCommand(homeArgs)
  if programName == "repro" and args.len > 0 and args[0] == "infra":
    let infraArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    return runInfraCommand(infraArgs)
  if programName == "repro" and args.len > 0 and args[0] == "system":
    let systemArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    return runSystemCommand(systemArgs)
  stderr.writeLine(renderUsage(programName))
  2

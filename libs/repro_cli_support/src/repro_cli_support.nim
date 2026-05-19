import std/[algorithm, json, options, os, osproc, sequtils, sets, strutils,
    tables, terminal, times]
import repro_core
import repro_build_engine
import repro_depfile
import repro_interface_artifacts
import repro_monitor_depfile/fs_snoop
import repro_provider_runtime
import repro_project_dsl
import repro_runquota
import repro_hash
import repro_tool_profiles
import repro_local_store
import repro_launch_plan
import repro_cli_support/watch

proc wantsVersion*(args: openArray[string]): bool =
  args.len == 1 and args[0] in ["--version", "-V"]

proc renderVersion*(programName: string): string =
  programName & " " & versionString()

proc renderUsage*(programName: string): string =
  if programName == "repro":
    programName & " " & versionString() & "\nusage: " & programName &
      " --version\n       " & programName &
      " capabilities [--format=json|text]\n       " & programName &
      " build [target[#name]] --tool-provisioning=path|nix|tarball|scoop [--work-root=PATH] [--progress=auto|plain|none] [--stats[=text|none]]\n       " &
          programName &
      " watch [target[#name]] --tool-provisioning=path|nix|tarball|scoop [--work-root=PATH] [--max-cycles=N] [--debounce-ms=N]\n       " &
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
    if dirExists(parts.base):
      let fragmentModule = parts.base / (parts.fragment & ".nim")
      if fileExists(fragmentModule):
        return ParsedBuildTarget(
          modulePath: fragmentModule,
          outputName: parts.fragment,
          fragmentKind: tfkModule)
      let rootModule = parts.base / "reprobuild.nim"
      if fileExists(rootModule):
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
    if dirExists(parts.base):
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
  base / "worktrees" / (safePathSegment(tail, "worktree") & "-" & hash[0 .. 15])

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
  if path.len == 0 or not fileExists(path):
    return
  for rawLine in readFile(path).splitLines():
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
  if path.len == 0 or not fileExists(path):
    return
  parseCmakeQuotedList(readFile(path), setName)

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

proc cmakeRegenerationInputs(meta: CmakeRegenerationMetadata): seq[string] =
  result.addUniquePath(meta.metadataFile)
  if meta.cmakeCommand.isAbsolute and fileExists(meta.cmakeCommand):
    result.addUniquePath(meta.cmakeCommand)
  let checkPath = meta.materializeCmakePath(meta.checkFile)
  result.addUniquePath(checkPath)
  result.addUniquePath(meta.binaryDir / "CMakeCache.txt")
  result.addUniquePath(meta.binaryDir / "CMakeFiles" / "cmake.check_cache")
  if meta.globVerifyScript.len > 0 and fileExists(meta.globVerifyScript):
    result.addUniquePath(meta.globVerifyScript)
  for input in parseCmakeListFromFile(checkPath, "CMAKE_MAKEFILE_DEPENDS"):
    result.addUniquePath(meta.materializeCmakePath(input))

proc cmakeRegenerationHasGlobVerification(meta: CmakeRegenerationMetadata): bool =
  meta.globVerifyScript.len > 0 and fileExists(meta.globVerifyScript)

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

proc cmakeRegenerationFingerprint(meta: CmakeRegenerationMetadata):
    ContentDigest =
  var payload = ""
  payload.addCmakeFingerprintField("reprobuild.cmake.regeneration.v1")
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
    inputs = cmakeRegenerationInputs(meta),
    outputs = cmakeRegenerationOutputs(meta),
    commandStatsId = "repro cmake regeneration edge",
    cacheable = not hasGlobVerification,
    weakFingerprint = cmakeRegenerationFingerprint(meta),
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
    dirExists(root / "libs" / "repro_project_dsl" / "src")

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
  for line in readFile(modulePath).splitLines:
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
  createDir(parentDir(path))
  writeFile(path, root.pretty())

proc hasFailedActions(buildResult: BuildRunResult): bool =
  for item in buildResult.results:
    if item.status in {asFailed, asBlocked}:
      return true

proc providerCompileBuildAction(plan: ProviderCompilePlan;
                                modulePath, interfacePath, artifactPath,
                                publicCliPath, workDir: string): BuildAction =
  var inputs = plan.inputSources
  if not inputs.contains(interfacePath):
    inputs.add(interfacePath)
  action("__repro_provider_compile", @[
    publicCliPath,
    "__repro-compile-provider",
    "--module", modulePath,
    "--out", plan.outputBinaryPath,
    "--artifact", artifactPath,
    "--interface", interfacePath,
    "--work-dir", workDir
  ],
    cwd = workDir,
    inputs = inputs,
    outputs = @[plan.outputBinaryPath, artifactPath],
    commandStatsId = "repro provider compile edge",
    cacheable = true,
    weakFingerprint = plan.compileEdge.actionFingerprint,
    dependencyPolicy = declaredOnlyPolicy())

proc invalidateStaleProviderCompileArtifact(plan: ProviderCompilePlan;
                                            artifactPath: string) =
  if artifactPath.len == 0 or not fileExists(artifactPath):
    return
  if providerCompileArtifactFresh(artifactPath, plan.outputBinaryPath,
      plan.interfaceFingerprint, plan.providerFingerprint):
    return
  removeFile(artifactPath)

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
  if path.len == 0 or not fileExists(path):
    return ""
  readFile(path)

proc runLoggedCommand(argv: openArray[string]; cwd: string): int =
  let command = shellCommand(argv)
  let res = execCmdEx(command, workingDir = cwd)
  if res.output.len > 0:
    stdout.write(res.output)
    stdout.flushFile()
  res.exitCode

proc removeManifestEntries(path: string) =
  if path.len == 0 or not fileExists(path):
    return
  for rawLine in readFile(path).splitLines():
    let filePath = rawLine.strip()
    if filePath.len > 0 and fileExists(filePath):
      removeFile(filePath)

proc invalidateCmakeProviderDerivedState(meta: CmakeRegenerationMetadata) =
  if meta.providerRoot.len > 0:
    let pattern = meta.providerRoot / "worktrees" / "*" / "build" /
      "reprobuild" / "provider-graph" / "provider-fragments.rbsz"
    for fragment in walkFiles(pattern):
      removeFile(fragment)
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
  if meta.globVerifyScript.len > 0 and fileExists(meta.globVerifyScript):
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
  createDir(parentDir(meta.providerStateFile))
  writeFile(meta.providerStateFile, providerAfter)
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
  if not fileExists(cacheIdentityPath):
    return
  try:
    let identity = readPathOnlyBuildIdentity(cacheIdentityPath)
    if identity.interfaceFingerprint != artifact.interfaceFingerprint:
      return
    writePathOnlyBuildIdentity(stableIdentityPath, identity)
    if fileExists(cacheInspectionPath):
      createDir(parentDir(stableInspectionPath))
      copyFile(cacheInspectionPath, stableInspectionPath)
    else:
      writeInspectionJson(stableInspectionPath, identity)
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
  if fileExists(candidate):
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

proc executeBuildTarget(target: string; mode: ToolProvisioningMode;
                        publicCliPath: string;
                        selectDefaultAction = false;
                        workRoot = "";
                        progressMode = bpmAuto;
                        statsMode = bsmNone):
    BuildCommandOutcome =
  let statsEnabled = statsMode == bsmText
  var buildStats: BuildStats
  let buildTotalStart = statStart(statsEnabled)
  var parsedTarget = parseBuildTarget(target)
  parsedTarget.modulePath = absolutePath(parsedTarget.modulePath)
  let modulePath = parsedTarget.modulePath
  if not fileExists(modulePath):
    raise newException(IOError, "build target module not found: " & modulePath)

  let outDir = outputDirForTarget(parsedTarget, workRoot)
  result.modulePath = modulePath
  result.projectRoot = projectRootForModule(modulePath)
  result.outDir = outDir
  var bypassRunQuota = false
  if mode in {tpmPathOnly, tpmScoop} and not isRunQuotaDaemonReachable():
    bypassRunQuota = true

  var cmakeRegenerationResult: BuildRunResult
  let cmakeMeta = cmakeRegenerationMetadataForModule(modulePath)
  cmakeMeta.applyCmakeProviderEnvironment()
  if cmakeMeta.enabled:
    echo "cmakeRegeneration: started"
    let cmakeRegenerationStart = statStart(statsEnabled)
    let cmakeRegenerationAction =
      cmakeRegenerationBuildAction(cmakeMeta, publicCliPath)
    var cmakeRegenerationConfig = BuildEngineConfig(
      cacheRoot: outDir / "build-engine-cache",
      runQuotaCliPath: publicCliPath,
      monitorCliPath: siblingFsSnoopPath(publicCliPath),
      maxParallelism: 1'u32,
      stdoutLimit: 1024 * 1024,
      stderrLimit: 1024 * 1024,
      rebuildMissingOutputsOnCacheHit: true,
      bypassRunQuota: bypassRunQuota)
    cmakeRegenerationConfig.statsEnabled = statsEnabled
    cmakeRegenerationResult = runBuild(graph([cmakeRegenerationAction]),
      cmakeRegenerationConfig)
    buildStats.mergeStats(cmakeRegenerationResult.stats)
    finishStat(buildStats, statsEnabled, "repro cmake regeneration",
      cmakeRegenerationStart)
    for item in cmakeRegenerationResult.results:
      echo "cmakeRegenerationAction: " & item.id & " status=" &
        $item.status & " launched=" & $item.launched & " cache=" &
        $item.cacheDecision
      if item.stdout.len > 0:
        stdout.write(item.stdout)
        stdout.flushFile()
      if item.stderr.len > 0:
        stderr.write(item.stderr)
        stderr.flushFile()
    if cmakeRegenerationResult.hasFailedActions():
      raise newException(OSError,
        "CMake regeneration edge failed: " &
          providerCompileFailure(cmakeRegenerationResult))

  let interfacePath = outDir / "project-interface.rbsz"
  let stubPath = outDir / "project-interface.nim"
  let compileWorkDir = reprobuildLibraryWorkDir()
  let interfaceStart = statStart(statsEnabled)
  let artifact = extractInterfaceFromModule(modulePath, interfacePath, stubPath,
    compileWorkDir)
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
    echo "repro build: tool provisioning active (tool-provisioning=" &
      mode.modeName & ")"
    if mode == tpmPathOnly:
      echo "repro build: provisioning-disabled mode active (tool-provisioning=path)"
    echo "project: " & artifact.projectInterface.projectName
    echo "interface: " & interfacePath
    echo "toolIdentity: " & resolved.identityPath
    echo "inspection: " & resolved.inspectionPath
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
    echo "cachePortability: " & portability
    echo "runQuotaSocket: " & runQuotaSocketDiagnostic()
    if not moduleHasBuildBlock(modulePath):
      result.exitCode = 0
      return
    let providerBinaryPath = outDir / "provider" / "project-provider"
    let providerArtifactPath = outDir / "provider-compile.rbsz"
    if mode in {tpmPathOnly, tpmScoop} and not isRunQuotaDaemonReachable():
      bypassRunQuota = true
      echo "repro build: WARNING runquotad is not reachable; using " &
        "RunQuota bypass for tool-provisioning=" & mode.modeName &
        " (no quotas/leases enforced). Start `runquotad` and rerun to " &
        "use the real lease coordinator."
    echo "providerCompile: started"
    let providerCompileStart = statStart(statsEnabled)
    var providerCompileResult: BuildRunResult
    var provider: ProviderCompileArtifact
    let cachedProvider = readFreshProviderCompileArtifact(providerArtifactPath,
      modulePath, providerBinaryPath, artifact.interfaceFingerprint)
    if cachedProvider.isSome:
      provider = cachedProvider.get()
    else:
      let providerPlan = providerCompilePlan(modulePath, providerBinaryPath,
        artifact.interfaceFingerprint, compileWorkDir)
      invalidateStaleProviderCompileArtifact(providerPlan, providerArtifactPath)
      let providerCompileAction = providerCompileBuildAction(providerPlan,
        modulePath, interfacePath, providerArtifactPath, publicCliPath,
        compileWorkDir)
      var providerCompileConfig = BuildEngineConfig(
        cacheRoot: outDir / "build-engine-cache",
        runQuotaCliPath: publicCliPath,
        maxParallelism: 1'u32,
        stdoutLimit: 1024 * 1024,
        stderrLimit: 1024 * 1024,
        rebuildMissingOutputsOnCacheHit: true,
        bypassRunQuota: bypassRunQuota)
      providerCompileConfig.statsEnabled = statsEnabled
      providerCompileResult = runBuild(graph([providerCompileAction]),
        providerCompileConfig)
      buildStats.mergeStats(providerCompileResult.stats)
      for item in providerCompileResult.results:
        echo "providerCompileAction: " & item.id & " status=" & $item.status &
          " launched=" & $item.launched & " cache=" & $item.cacheDecision
      if providerCompileResult.hasFailedActions():
        raise newException(OSError, providerCompileFailure(providerCompileResult))
      if not fileExists(providerArtifactPath):
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
    echo "providerBinary: " & provider.outputBinaryPath
    echo "providerCompileArtifact: " & providerArtifactPath
    echo "providerArtifact: " & providerArtifactId

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
    echo "providerGraphSnapshot: " & refresh.persistedSnapshotPath
    echo "providerInvocations: " & $refresh.invoked.len

    var selectedActionId = parsedTarget.selectedActionId
    if selectDefaultAction and selectedActionId.len == 0:
      selectedActionId = defaultBuildActionId(refresh.snapshot)
      if selectedActionId.len > 0:
        echo "defaultTarget: " & selectedActionId

    let graphLowerStart = statStart(statsEnabled)
    let lowered = lowerProviderSnapshot(refresh.snapshot, identity, projectRoot,
      selectedActionId)
    finishStat(buildStats, statsEnabled, "repro graph lower", graphLowerStart)
    if parsedTarget.fragmentKind == tfkActionSelection:
      echo "selectedTarget: " & parsedTarget.selectedActionId
    elif selectDefaultAction and selectedActionId.len > 0:
      echo "selectedTarget: " & selectedActionId
    echo "scheduler: actions=" & $lowered.actions.len
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
      bypassRunQuota: bypassRunQuota)
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
    finishStat(buildStats, statsEnabled, "repro build total", buildTotalStart)
    buildResult.stats = buildStats
    let reportPath = outDir / "build-report.json"
    writeBuildReport(reportPath, provider, refresh, cmakeRegenerationResult,
      providerCompileResult, buildResult)
    result.buildReportPath = reportPath
    for item in buildResult.results:
      echo "action: " & item.id & " status=" & $item.status &
        " launched=" & $item.launched & " cache=" & $item.cacheDecision &
        " runquota=" & item.runQuotaBackend &
        " socket=" & (if item.runQuotaSocket.len >
            0: item.runQuotaSocket else: "default") &
        " lease=" & $item.leaseId &
        " evidence=depfile:" & $item.evidence.depfileInputs.len
    echo "buildReport: " & reportPath
    if statsEnabled:
      stderr.write(renderBuildStats(buildResult.stats))
      stderr.flushFile()
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
  if outcome.buildReportPath.len > 0 and fileExists(outcome.buildReportPath):
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
        if dirExists(binDir) and not result.contains(binDir):
          result.add(binDir)
    else:
      for binDir in profile.pathSearchList:
        if binDir.len > 0 and dirExists(binDir) and not result.contains(binDir):
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
  var envPrefix: seq[string] = @[
    "PATH=" & q(pathValue),
    "REPRO_TOOL_PROFILE_ARTIFACT=" & q(identityPath),
    "REPRO_TOOL_PROFILE_INSPECTION=" & q(inspectionPath),
    "REPRO_PROJECT_INTERFACE=" & q(interfacePath),
    "REPRO_PROJECT_ROOT=" & q(projectRoot)
  ]
  let res = execCmdEx("cd " & q(projectRoot) & " && " &
    envPrefix.join(" ") & " " & shellCommand(command))
  if res.output.len > 0:
    stdout.write(res.output)
  res.exitCode

proc valueAfterFlag(args: openArray[string]; flag: string): string =
  var i = 0
  while i < args.len:
    if args[i] == flag and i + 1 < args.len:
      return args[i + 1]
    inc i
  ""

proc runProviderCompileHelper(args: openArray[string]): int =
  let modulePath = valueAfterFlag(args, "--module")
  let outputPath = valueAfterFlag(args, "--out")
  let artifactPath = valueAfterFlag(args, "--artifact")
  let interfacePath = valueAfterFlag(args, "--interface")
  let workDir = valueAfterFlag(args, "--work-dir")
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
    let provider = compileProviderBinary(modulePath, outputPath,
      interfaceArtifact.interfaceFingerprint, artifactPath, workDir)
    echo "providerBinary: " & provider.outputBinaryPath
    echo "providerArtifact: " & digestHex(provider.providerFingerprint)
    return 0
  except CatchableError as err:
    stderr.writeLine("repro provider compile: error: " & err.msg)
    return 1

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
        profile.selectedStorePath):
      if not result.contains(profile.selectedStorePath):
        result.add(profile.selectedStorePath)
    let binDir = parentDir(profile.resolvedExecutablePath)
    if binDir.len > 0:
      let prefix = parentDir(binDir)
      if prefix.len > 0 and dirExists(prefix) and not result.contains(prefix):
        result.add(prefix)

proc pkgConfigPaths(prefixes: openArray[string]): seq[string] =
  for prefix in prefixes:
    for suffix in ["lib/pkgconfig", "share/pkgconfig"]:
      let candidate = prefix / suffix
      if dirExists(candidate) and not result.contains(candidate):
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
  if explicit.len > 0 and dirExists(explicit):
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
  createDir(parentDir(path))
  writeFile(path, content)

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
    if fileExists(candidate):
      return candidate
    if not candidate.endsWith(".exe"):
      let withExe = candidate & ".exe"
      if fileExists(withExe):
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
  createDir(parentDir(path))
  writeFile(path, content)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
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
  createDir(parentDir(path))
  writeFile(path, content)

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
  if not dirExists(sourceRoot):
    raise newException(IOError, "cmake source directory not found: " & sourceRoot)
  if not fileExists(sourceRoot / "CMakeLists.txt"):
    raise newException(IOError,
      "cmake source directory does not contain CMakeLists.txt: " & sourceRoot)
  if cmakeBinary.len > 0 and not fileExists(cmakeBinary):
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

  echo "repro develop: cmake profile active (tool-provisioning=" &
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
    statsMode = statsMode).exitCode

proc parsePositiveIntFlag(flagName, value: string): int =
  try:
    result = parseInt(value)
  except ValueError:
    raise newException(ValueError, flagName & " must be an integer")
  if result <= 0:
    raise newException(ValueError, flagName & " must be greater than zero")

proc runWatchCommand(args: openArray[string]; publicCliPath: string): int =
  var target = ""
  var mode = tpmUnspecified
  var maxCycles = 0
  var debounceMs = 250
  var workRoot = ""

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
    (if maxCycles > 0: " maxCycles=" & $maxCycles else: " maxCycles=unbounded")
  flushStdout()

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
  for arg in args:
    if afterSeparator:
      command.add(arg)
    elif arg == "--":
      afterSeparator = true
    elif arg == "--cmake":
      cmakeMode = true
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

  if target.len == 0:
    raise newException(ValueError, "missing develop target")

  if cmakeMode:
    if mode == tpmUnspecified:
      raise newException(ValueError,
        "repro develop --cmake requires --tool-provisioning=path|nix")
    return runCMakeDevelopCommand(target, mode, command, workRoot, cmakeBinary)

  let modulePath = absolutePath(moduleForTarget(target))
  if not fileExists(modulePath):
    raise newException(IOError, "develop target module not found: " & modulePath)

  let scopedRoot = scopedWorktreeRoot(modulePath, workRoot)
  let outDir =
    if scopedRoot.len > 0:
      scopedRoot / "develop"
    else:
      parentDir(modulePath) / ".repro" / "develop"
  let interfacePath = outDir / "project-interface.rbsz"
  let stubPath = outDir / "project-interface.nim"
  let artifact = extractInterfaceFromModule(modulePath, interfacePath, stubPath)

  if artifact.projectInterface.toolUses.len > 0 and mode == tpmUnspecified:
    raise newException(ValueError,
      "typed tool provisioning is required for uses declarations; refusing " &
        "implicit PATH fallback. Pass --tool-provisioning=path for the weak " &
        "local profile, or --tool-provisioning=nix|tarball for a provisioned " &
        "development environment.")

  if mode == tpmUnspecified:
    echo "repro develop: no external tools requested"
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
  echo "repro develop: tool provisioning active (tool-provisioning=" &
    mode.modeName & ")"
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
      let raw = readFile(path)
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

proc runThinApp*(programName: string): int =
  let args = commandLineParams()
  let publicCliPath = stablePublicCliPath()
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
  echo renderUsage(programName)
  0

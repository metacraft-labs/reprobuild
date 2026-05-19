import std/[algorithm, json, os, osproc, sequtils, sets, strutils, tables]
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
import repro_cli_support/watch

proc wantsVersion*(args: openArray[string]): bool =
  args.len == 1 and args[0] in ["--version", "-V"]

proc renderVersion*(programName: string): string =
  programName & " " & versionString()

proc renderUsage*(programName: string): string =
  if programName == "repro":
    programName & " " & versionString() & "\nusage: " & programName &
      " --version\n       " & programName &
      " build [target[#name]] --tool-provisioning=path|nix|tarball [--work-root=PATH]\n       " &
          programName &
      " watch [target[#name]] --tool-provisioning=path|nix|tarball [--work-root=PATH] [--max-cycles=N] [--debounce-ms=N]\n       " &
          programName &
      " develop <target[#name]> --tool-provisioning=path|nix|tarball [--work-root=PATH] -- <command> [args...]\n       " &
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

proc writeBuildReport(path: string; provider: ProviderCompileArtifact;
                      refresh: ProviderRefreshReport;
                      buildResult: BuildRunResult) =
  var actions = newJArray()
  for item in buildResult.results:
    # Windows: include exitCode/stdout/stderr in the build report so failed
    # actions can be diagnosed without re-running them. Without this, the JSON
    # report only carries status/cacheDecision/etc. and failures look opaque.
    actions.add(%*{
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
    })
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
    "providerSnapshot": refresh.persistedSnapshotPath,
    "providerInvocations": refresh.invoked.len,
    "actions": actions,
    "trace": trace
  }
  createDir(parentDir(path))
  writeFile(path, root.pretty())

proc hasFailedActions(buildResult: BuildRunResult): bool =
  for item in buildResult.results:
    if item.status in {asFailed, asBlocked}:
      return true

proc identityPaths(outDir: string; mode: ToolProvisioningMode):
    tuple[identityPath: string; inspectionPath: string] =
  case mode
  of tpmNix:
    (identityPath: outDir / "nix-tool-identities.rbtp",
      inspectionPath: outDir / "nix-tool-identities.inspect.json")
  of tpmTarball:
    (identityPath: outDir / "tarball-tool-identities.rbtp",
      inspectionPath: outDir / "tarball-tool-identities.inspect.json")
  else:
    (identityPath: outDir / "path-only-tool-identities.rbtp",
      inspectionPath: outDir / "path-only-tool-identities.inspect.json")

proc resolveAndWriteIdentity(artifact: ProjectInterfaceArtifact;
                             outDir: string;
                             mode: ToolProvisioningMode):
    tuple[identity: PathOnlyBuildIdentity; identityPath: string;
      inspectionPath: string] =
  let identity = toolBuildIdentity(artifact, mode,
    storeRoot = outDir / "tool-store")
  let paths = identityPaths(outDir, mode)
  writePathOnlyBuildIdentity(paths.identityPath, identity)
  writeInspectionJson(paths.inspectionPath, identity)
  (identity: identity, identityPath: paths.identityPath,
    inspectionPath: paths.inspectionPath)

proc modeName(mode: ToolProvisioningMode): string =
  case mode
  of tpmPathOnly: "path"
  of tpmNix: "nix"
  of tpmTarball: "tarball"
  else: "unspecified"

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

type
  BuildCommandOutcome = object
    exitCode: int
    modulePath: string
    projectRoot: string
    outDir: string
    buildReportPath: string

proc executeBuildTarget(target: string; mode: ToolProvisioningMode;
                        publicCliPath: string;
                        selectDefaultAction = false;
                        workRoot = ""):
    BuildCommandOutcome =
  var parsedTarget = parseBuildTarget(target)
  parsedTarget.modulePath = absolutePath(parsedTarget.modulePath)
  let modulePath = parsedTarget.modulePath
  if not fileExists(modulePath):
    raise newException(IOError, "build target module not found: " & modulePath)

  let outDir = outputDirForTarget(parsedTarget, workRoot)
  result.modulePath = modulePath
  result.projectRoot = projectRootForModule(modulePath)
  result.outDir = outDir

  let interfacePath = outDir / "project-interface.rbsz"
  let stubPath = outDir / "project-interface.nim"
  let compileWorkDir = reprobuildLibraryWorkDir()
  let artifact = extractInterfaceFromModule(modulePath, interfacePath, stubPath,
    compileWorkDir)

  if artifact.projectInterface.toolUses.len > 0 and mode == tpmUnspecified:
    raise newException(ValueError,
      "typed tool provisioning is required for uses declarations; refusing " &
        "implicit PATH fallback. Pass --tool-provisioning=path to use the " &
        "explicit weak local profile.")

  if mode in {tpmPathOnly, tpmNix, tpmTarball}:
    let resolved = resolveAndWriteIdentity(artifact, outDir, mode)
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
      else:
        "local-only"
    echo "cachePortability: " & portability
    echo "runQuotaSocket: " & runQuotaSocketDiagnostic()
    if not moduleHasBuildBlock(modulePath):
      result.exitCode = 0
      return
    let providerBinaryPath = outDir / "provider" / "project-provider"
    let providerArtifactPath = outDir / "provider-compile.rbsz"
    echo "providerCompile: started"
    let provider = compileProviderBinary(modulePath, providerBinaryPath,
      artifact.interfaceFingerprint, providerArtifactPath, compileWorkDir)
    let providerArtifactId = digestHex(provider.providerFingerprint)
    echo "providerBinary: " & provider.outputBinaryPath
    echo "providerCompileArtifact: " & providerArtifactPath
    echo "providerArtifact: " & providerArtifactId

    let projectRoot = result.projectRoot
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
    echo "providerGraphSnapshot: " & refresh.persistedSnapshotPath
    echo "providerInvocations: " & $refresh.invoked.len

    var selectedActionId = parsedTarget.selectedActionId
    if selectDefaultAction and selectedActionId.len == 0:
      selectedActionId = defaultBuildActionId(refresh.snapshot)
      if selectedActionId.len > 0:
        echo "defaultTarget: " & selectedActionId

    let lowered = lowerProviderSnapshot(refresh.snapshot, identity, projectRoot,
      selectedActionId)
    if parsedTarget.fragmentKind == tfkActionSelection:
      echo "selectedTarget: " & parsedTarget.selectedActionId
    elif selectDefaultAction and selectedActionId.len > 0:
      echo "selectedTarget: " & selectedActionId
    echo "scheduler: actions=" & $lowered.actions.len
    if lowered.actions.len == 0:
      result.exitCode = 0
      return
    # Path-mode escape hatch: when the local RunQuota daemon is not reachable
    # (e.g. nothing started runquotad and `--tool-provisioning=path` is being
    # used in a smoke test), fall back to spawning actions directly with
    # osproc so the build can still finish. The bypass is only allowed in
    # path-only mode; full provisioning still requires a real daemon.
    # Windows: pre-port checkouts used to gate this purely on
    # `defined(windows)`. Now that runquota supports named pipes, the gate is
    # platform-agnostic and reflects actual daemon availability.
    var bypassRunQuota = false
    if mode == tpmPathOnly and not isRunQuotaDaemonReachable():
      bypassRunQuota = true
      echo "repro build: WARNING runquotad is not reachable; using " &
        "path-mode RunQuota bypass (no quotas/leases enforced). Start " &
        "`runquotad` and rerun to use the real lease coordinator."
    let buildResult = runBuild(graph(lowered.actions, lowered.pools),
        BuildEngineConfig(
      cacheRoot: outDir / "build-engine-cache",
      runQuotaCliPath: publicCliPath,
      maxParallelism: buildMaxParallelism(),
      stdoutLimit: 1024 * 1024,
      stderrLimit: 1024 * 1024,
      rebuildMissingOutputsOnCacheHit: true,
      bypassRunQuota: bypassRunQuota))
    let reportPath = outDir / "build-report.json"
    writeBuildReport(reportPath, provider, refresh, buildResult)
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
    workRoot = workRoot).exitCode

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
  if mode notin {tpmPathOnly, tpmNix, tpmTarball}:
    raise newException(ValueError,
      "repro watch requires --tool-provisioning=path|nix|tarball")
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

  if mode notin {tpmPathOnly, tpmNix, tpmTarball}:
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
  if programName == "repro" and args.len >= 2 and args[0] == "debug" and
      args[1] == "fs-snoop":
    let fsArgs =
      if args.len > 2:
        args[2 .. ^1]
      else:
        @[]
    return runFsSnoopCli("repro debug fs-snoop", fsArgs)
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
  echo renderUsage(programName)
  0

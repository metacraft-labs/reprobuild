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

proc wantsVersion*(args: openArray[string]): bool =
  args.len == 1 and args[0] in ["--version", "-V"]

proc renderVersion*(programName: string): string =
  programName & " " & versionString()

proc renderUsage*(programName: string): string =
  if programName == "repro":
    programName & " " & versionString() & "\nusage: " & programName &
      " --version\n       " & programName &
      " build <target[#name]> --tool-provisioning=path|nix\n       " & programName &
      " develop <target[#name]> --tool-provisioning=nix -- <command> [args...]\n       " & programName &
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
  else:
    raise newException(ValueError, "unsupported --tool-provisioning=" & value)

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

proc outputDirForTarget(target: ParsedBuildTarget): string =
  parentDir(target.modulePath) / ".repro" / "build" / target.outputName

proc digestHex(digest: ContentDigest): string =
  toHex(digest.bytes)

proc q(value: string): string =
  quoteShell(value)

proc shellCommand(args: openArray[string]): string =
  args.mapIt(q(it)).join(" ")

proc projectRootForModule(modulePath: string): string =
  parentDir(modulePath)

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
  result = @[profile.resolvedExecutablePath, call.subcommand]

  proc addEncodedValue(outp: var seq[string]; arg: PublicCliArg) =
    if arg.nimType.normalize == "seq[string]":
      if arg.encodedValue.len > 0:
        for item in arg.encodedValue.split("\x1f"):
          outp.add(item)
    else:
      outp.add(arg.encodedValue)

  var positional: seq[PublicCliArg] = @[]
  for arg in call.arguments:
    let name = arg.name
    let nimType = arg.nimType
    let value = arg.encodedValue
    if arg.kind == cpkPositional:
      positional.add(arg)
      continue
    let flagName =
      if arg.alias.len > 0:
        arg.alias
      else:
        "--" & name
    if nimType.normalize == "bool":
      if value.normalize == "true":
        result.add(flagName)
    else:
      result.add(flagName)
      result.addEncodedValue(arg)

  positional.sort do (a, b: PublicCliArg) -> int:
    cmp(a.position, b.position)
  for arg in positional:
    result.addEncodedValue(arg)

proc depfilePolicy(depfile: string): DependencyGatheringPolicy =
  if depfile.len == 0:
    return declaredOnlyPolicy()
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

proc lowerGraphAction(node: GraphNode; profiles: Table[string, PathOnlyToolProfile];
                      projectRoot: string): BuildAction =
  let payload = decodeBuildActionPayload(toBytes(node.payload))
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
    depfile = depfile,
    cacheable = payload.cacheable,
    weakFingerprint = weakFingerprintFromText(fingerprintText),
    dependencyPolicy = depfilePolicy(depfile),
    commandStatsId = commandStatsId)

proc lowerProviderSnapshot(snapshot: ProviderGraphSnapshot;
                           identity: PathOnlyBuildIdentity;
                           projectRoot: string;
                           selectedActionId = ""): seq[BuildAction] =
  let profiles = profileIndex(identity)
  var actionNodes: seq[tuple[node: GraphNode; payload: BuildActionDef]] = @[]
  for fragment in snapshot.fragments:
    for node in fragment.nodes:
      if node.kind == gnkAction:
        actionNodes.add((
          node: node,
          payload: decodeBuildActionPayload(toBytes(node.payload))))
  if selectedActionId.len == 0:
    for item in actionNodes:
      result.add(lowerGraphAction(item.node, profiles, projectRoot))
    return

  var byId = initTable[string, BuildActionDef]()
  for item in actionNodes:
    byId[item.payload.id] = item.payload
  if not byId.hasKey(selectedActionId):
    var available: seq[string] = @[]
    for item in actionNodes:
      available.add(item.payload.id)
    available.sort()
    raise newException(ValueError,
      "unknown build target/action id: " & selectedActionId &
        (if available.len > 0: " (available: " & available.join(", ") & ")"
         else: " (project defines no build actions)"))

  var selected = initHashSet[string]()
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

  includeClosure(selectedActionId)
  for item in actionNodes:
    if selected.contains(item.payload.id):
      result.add(lowerGraphAction(item.node, profiles, projectRoot))

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
    actions.add(%*{
      "id": item.id,
      "status": $item.status,
      "launched": item.launched,
      "cacheDecision": $item.cacheDecision,
      "dependencyPolicyKind": $item.dependencyPolicyKind,
      "runQuotaBackend": item.runQuotaBackend,
      "runQuotaSocket": item.runQuotaSocket,
      "leaseId": item.leaseId,
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
  else:
    (identityPath: outDir / "path-only-tool-identities.rbtp",
      inspectionPath: outDir / "path-only-tool-identities.inspect.json")

proc resolveAndWriteIdentity(artifact: ProjectInterfaceArtifact;
                             outDir: string;
                             mode: ToolProvisioningMode):
    tuple[identity: PathOnlyBuildIdentity; identityPath: string;
      inspectionPath: string] =
  let identity = toolBuildIdentity(artifact, mode)
  let paths = identityPaths(outDir, mode)
  writePathOnlyBuildIdentity(paths.identityPath, identity)
  writeInspectionJson(paths.inspectionPath, identity)
  (identity: identity, identityPath: paths.identityPath,
    inspectionPath: paths.inspectionPath)

proc modeName(mode: ToolProvisioningMode): string =
  case mode
  of tpmPathOnly: "path"
  of tpmNix: "nix"
  else: "unspecified"

proc runQuotaSocketDiagnostic(): string =
  let socket = getEnv("RUNQUOTA_SOCKET", "")
  if socket.len > 0:
    socket
  else:
    "default"

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

proc runBuildCommand(args: openArray[string]): int =
  var target = ""
  var mode = tpmUnspecified
  for arg in args:
    if arg.startsWith("--tool-provisioning="):
      mode = parseToolProvisioning(arg.split("=", maxsplit = 1)[1])
    elif arg == "--tool-provisioning":
      raise newException(ValueError,
        "--tool-provisioning requires an inline value, for example " &
          "--tool-provisioning=path")
    elif arg.startsWith("-"):
      raise newException(ValueError, "unsupported build flag: " & arg)
    elif target.len == 0:
      target = arg
    else:
      raise newException(ValueError, "unexpected build argument: " & arg)

  if target.len == 0:
    raise newException(ValueError, "missing build target")

  var parsedTarget = parseBuildTarget(target)
  parsedTarget.modulePath = absolutePath(parsedTarget.modulePath)
  let modulePath = parsedTarget.modulePath
  if not fileExists(modulePath):
    raise newException(IOError, "build target module not found: " & modulePath)

  let outDir = outputDirForTarget(parsedTarget)
  let interfacePath = outDir / "project-interface.rbsz"
  let stubPath = outDir / "project-interface.nim"
  let artifact = extractInterfaceFromModule(modulePath, interfacePath, stubPath)

  if artifact.projectInterface.toolUses.len > 0 and mode == tpmUnspecified:
    raise newException(ValueError,
      "typed tool provisioning is required for uses declarations; refusing " &
        "implicit PATH fallback. Pass --tool-provisioning=path to use the " &
        "explicit weak local profile.")

  if mode in {tpmPathOnly, tpmNix}:
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
      else:
        "local-only"
    echo "cachePortability: " & portability
    echo "runQuotaSocket: " & runQuotaSocketDiagnostic()
    if not moduleHasBuildBlock(modulePath):
      return 0
    let providerBinaryPath = outDir / "provider" / "project-provider"
    let providerArtifactPath = outDir / "provider-compile.rbsz"
    echo "providerCompile: started"
    let provider = compileProviderBinary(modulePath, providerBinaryPath,
      artifact.interfaceFingerprint, providerArtifactPath, getCurrentDir())
    let providerArtifactId = digestHex(provider.providerFingerprint)
    echo "providerBinary: " & provider.outputBinaryPath
    echo "providerCompileArtifact: " & providerArtifactPath
    echo "providerArtifact: " & providerArtifactId

    let projectRoot = projectRootForModule(modulePath)
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

    let actions = lowerProviderSnapshot(refresh.snapshot, identity, projectRoot,
      parsedTarget.selectedActionId)
    if parsedTarget.fragmentKind == tfkActionSelection:
      echo "selectedTarget: " & parsedTarget.selectedActionId
    echo "scheduler: actions=" & $actions.len
    if actions.len == 0:
      return 0
    let buildResult = runBuild(graph(actions), BuildEngineConfig(
      cacheRoot: outDir / "build-engine-cache",
      runQuotaCliPath: getAppFilename(),
      maxParallelism: 8'u32,
      stdoutLimit: 1024 * 1024,
      stderrLimit: 1024 * 1024,
      rebuildMissingOutputsOnCacheHit: true))
    let reportPath = outDir / "build-report.json"
    writeBuildReport(reportPath, provider, refresh, buildResult)
    for item in buildResult.results:
      echo "action: " & item.id & " status=" & $item.status &
        " launched=" & $item.launched & " cache=" & $item.cacheDecision &
        " runquota=" & item.runQuotaBackend &
        " socket=" & (if item.runQuotaSocket.len > 0: item.runQuotaSocket else: "default") &
        " lease=" & $item.leaseId &
        " evidence=depfile:" & $item.evidence.depfileInputs.len
    echo "buildReport: " & reportPath
    if buildResult.hasFailedActions():
      return 1
    return 0

  echo "repro build: no external tools requested"
  echo "interface: " & interfacePath
  0

proc runDevelopCommand(args: openArray[string]): int =
  var target = ""
  var mode = tpmUnspecified
  var command: seq[string] = @[]
  var afterSeparator = false
  for arg in args:
    if afterSeparator:
      command.add(arg)
    elif arg == "--":
      afterSeparator = true
    elif arg.startsWith("--tool-provisioning="):
      mode = parseToolProvisioning(arg.split("=", maxsplit = 1)[1])
    elif arg == "--tool-provisioning":
      raise newException(ValueError,
        "--tool-provisioning requires an inline value, for example " &
          "--tool-provisioning=nix")
    elif arg.startsWith("-"):
      raise newException(ValueError, "unsupported develop flag: " & arg)
    elif target.len == 0:
      target = arg
    else:
      raise newException(ValueError, "unexpected develop argument before --: " & arg)

  if target.len == 0:
    raise newException(ValueError, "missing develop target")

  let modulePath = absolutePath(moduleForTarget(target))
  if not fileExists(modulePath):
    raise newException(IOError, "develop target module not found: " & modulePath)

  let outDir = parentDir(modulePath) / ".repro" / "develop"
  let interfacePath = outDir / "project-interface.rbsz"
  let stubPath = outDir / "project-interface.nim"
  let artifact = extractInterfaceFromModule(modulePath, interfacePath, stubPath)

  if artifact.projectInterface.toolUses.len > 0 and mode == tpmUnspecified:
    raise newException(ValueError,
      "typed tool provisioning is required for uses declarations; refusing " &
        "implicit PATH fallback. Pass --tool-provisioning=nix to resolve a " &
        "Nix-backed development environment.")

  if mode == tpmUnspecified:
    echo "repro develop: no external tools requested"
    if command.len == 0:
      return 0
    return runInDevelopEnvironment(command, projectRootForModule(modulePath),
      PathOnlyBuildIdentity(projectName: artifact.projectInterface.projectName,
        interfaceFingerprint: artifact.interfaceFingerprint),
      "", "", interfacePath)

  if mode notin {tpmPathOnly, tpmNix}:
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
      return runBuildCommand(buildArgs)
    except CatchableError as err:
      stderr.writeLine("repro build: error: " & err.msg)
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

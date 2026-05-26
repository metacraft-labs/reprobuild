## Direct provider binary for CMake TryCompile projects (Tier 2a).
##
## The Reprobuild engine routes any work-dir that contains
## ``trycompile.rbsz`` to this binary instead of compiling a per-project
## ``reprobuild.nim``. The binary reads the metadata, registers the
## synthesised build actions via the standard DSL primitives, and lets
## the DSL runtime emit the graph fragment for the engine.
##
## The ``providerArtifactId`` reported here is a constant per ``repro``
## release (``TryCompileProviderArtifactId``), so every TryCompile on
## the same toolchain that produces byte-identical metadata shares the
## same provider artifact identity and contributes to a shared action
## cache.
##
## Per Provider-Compile-Tiering.md §"2a — repro-cmake-trycompile-provider".

import std/[os, strutils]

import repro_cmake_trycompile
import repro_core
import repro_project_dsl

proc dependencyPolicyForAction(action: TryCompileActionDef):
    BuildActionDependencyPolicy =
  if action.depfile.len > 0:
    makeDepfilePolicy(action.depfile)
  else:
    declaredOnlyDependencyPolicy()

proc registerAction(action: TryCompileActionDef): BuildActionDef
    {.discardable.} =
  let call =
    if action.inline:
      inlineExecCall(action.inlineArgv, action.inlineCwd)
    else:
      publicCliCall(action.toolId, action.toolId, "",
        action.toolId & ".call",
        @[cliArgSeq("args", action.args, cpkPositional, 0)])
  buildAction(
    action.id,
    call,
    deps = action.deps,
    inputs = action.inputs,
    outputs = action.outputs,
    pool = action.pool,
    poolUnits = action.poolUnits,
    depfile = action.depfile,
    dynamicDepsFile = action.dynamicDepsFile,
    cacheable = action.cacheable,
    commandStatsId = action.commandStatsId,
    dependencyPolicy = dependencyPolicyForAction(action))

proc readMetadataFromProjectRoot(projectRoot: string): TryCompileMetadata =
  let path = projectRoot / "trycompile.rbsz"
  if not fileExists(extendedPath(path)):
    raise newException(IOError,
      "trycompile direct provider invoked without metadata at " & path)
  let raw = readFile(extendedPath(path))
  decodeTryCompileMetadata(toBytes(raw))

when defined(reproProviderMode):
  proc syntheticPackage(): PackageDef =
    PackageDef(
      packageName: TryCompileProviderPackageName,
      sourceFile: "",
      hasDevEnv: false,
      devEnvBodyHash: "",
      toolUses: @[])

  proc syntheticManifest(providerArtifactId: string): ProviderManifest =
    ProviderManifest(
      providerArtifactId:
        if providerArtifactId.len > 0: providerArtifactId
        else: TryCompileProviderArtifactId,
      protocolVersion: ProviderProtocolVersion,
      entryPoints: @[
        GraphEntryPointDescriptor(
          id: TryCompileProviderRootEntryPointId,
          kind: gpkProjectRoot,
          stableName: TryCompileProviderPackageName,
          bodyHash: TryCompileProviderRootBodyHash,
          argumentSchemaId: "reprobuild.project-root.v1",
          outputSchemaId: "reprobuild.graph-fragment.v1")
      ])

  proc directBuildFragment(meta: TryCompileMetadata;
                           request: ProviderGraphRequest): GraphFragment =
    let pkg = syntheticPackage()
    let registerAll = proc() =
      for pool in meta.pools:
        discard buildPool(pool.name, pool.capacity)
      var registered: seq[BuildActionDef] = @[]
      for action in meta.actions:
        registered.add(registerAction(action))
      if meta.targetName.len > 0:
        if meta.targetActionIds.len == 0:
          discard target(meta.targetName, registered)
        else:
          var byId: seq[BuildActionDef] = @[]
          for id in meta.targetActionIds:
            for action in registered:
              if action.id == id:
                byId.add(action)
                break
          discard target(meta.targetName, byId)
    buildPackageFragment(pkg, request, registerAll, includeDefault = false)

  proc runDirectProvider(): int =
    try:
      let paths = parseProviderProtocolArgs(commandLineParams())
      let request = readProviderRequestFile(paths.requestPath)
      let manifest = syntheticManifest(request.providerArtifactId)
      case request.kind
      of prkManifest:
        writeProviderResponseFile(paths.responsePath,
          manifestResponse(manifest))
      of prkGraphInvocation:
        if request.entryPointId != TryCompileProviderRootEntryPointId:
          stderr.writeLine(
            "repro-cmake-trycompile-provider: unknown entry point: " &
            request.entryPointId)
          return 2
        let meta = readMetadataFromProjectRoot(request.arguments)
        let fragment = directBuildFragment(meta, request)
        writeProviderResponseFile(paths.responsePath,
          graphResponse(manifest, fragment))
      of prkDevEnvIntrospection:
        stderr.writeLine(
          "repro-cmake-trycompile-provider: dev-env introspection not supported")
        return 2
      0
    except CatchableError as err:
      stderr.writeLine("repro-cmake-trycompile-provider: " & err.msg)
      1

  when isMainModule:
    quit runDirectProvider()
else:
  when isMainModule:
    stderr.writeLine(
      "repro-cmake-trycompile-provider must be compiled with -d:reproProviderMode")
    quit 2

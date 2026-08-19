import std/unittest

when defined(reproProviderMode):
  import std/[os, strutils]

  import repro_core
  import repro_project_dsl
  import repro_dsl_stdlib/constructors

  proc dummyRequest(projectRoot, packageName: string): ProviderGraphRequest =
    ProviderGraphRequest(
      kind: prkGraphInvocation,
      providerArtifactId: "test-provider",
      entryPointId: packageName & ".root",
      entryPointBodyHash: "test-body",
      reason: girExplicitUserRequest,
      arguments: projectRoot,
      namespace: "project")

  proc extractActions(fragment: GraphFragment): seq[BuildActionDef] =
    for node in fragment.nodes:
      if node.kind == gnkAction:
        result.add(decodeBuildActionPayload(toBytes(node.payload)))

  proc findById(actions: openArray[BuildActionDef]; id: string): BuildActionDef =
    for action in actions:
      if action.id == id:
        return action
    raise newException(ValueError, "action not found: " & id)

  proc inlineArgv(action: BuildActionDef): seq[string] =
    for arg in action.call.arguments:
      if arg.name == "argv":
        return arg.encodedValue.split("\x1f")

  proc cmakeCleanup(projectRoot, generator: string;
                    cacheVars: seq[string]): BuildActionDef =
    let packageName = "cmakeCleanupTest"
    let pkg = PackageDef(
      packageName: packageName,
      sourceFile: projectRoot / "repro.nim",
      hasDevEnv: false,
      devEnvBodyHash: "",
      toolUses: @[])
    let fragment = buildPackageFragment(
      pkg,
      dummyRequest(projectRoot, packageName),
      proc() =
        discard cmake_package(
          srcDir = "src",
          buildDir = "build-cmake",
          generator = generator,
          cacheVars = cacheVars),
      includeDefault = false)
    findById(extractActions(fragment),
      "cmake-clean-build-dir-" & packageName)

  proc mesonCleanup(projectRoot, buildtype: string;
                    options: seq[string]): BuildActionDef =
    let packageName = "mesonCleanupTest"
    let pkg = PackageDef(
      packageName: packageName,
      sourceFile: projectRoot / "repro.nim",
      hasDevEnv: false,
      devEnvBodyHash: "",
      toolUses: @[])
    let fragment = buildPackageFragment(
      pkg,
      dummyRequest(projectRoot, packageName),
      proc() =
        discard meson_package(
          srcDir = "src",
          buildDir = "build-meson",
          buildtype = buildtype,
          configureOptions = options),
      includeDefault = false)
    findById(extractActions(fragment),
      "meson-clean-build-dir-" & packageName)

suite "configure build-tree cleanup caching":
  test "CMake cleanup is reusable until configure identity changes":
    when defined(reproProviderMode):
      let root = getTempDir() / "repro-cmake-cleanup-cache"
      if dirExists(root):
        removeDir(root)
      createDir(root)
      defer:
        if dirExists(root):
          removeDir(root)
      writeFile(root / "repro.nim", "package cmakeCleanupTest:\n  discard\n")

      let first = cmakeCleanup(root, "Ninja", @["FEATURE=ON"])
      let same = cmakeCleanup(root, "Ninja", @["FEATURE=ON"])
      let changed = cmakeCleanup(root, "Unix Makefiles", @["FEATURE=ON"])

      check first.cacheable
      check first.dependencyPolicy.kind == bdpAutomaticMonitor
      check first.dependencyPolicy.ignoredInputPrefixes ==
        @[root / "build-cmake"]
      check first.inlineArgv() == same.inlineArgv()
      check first.inlineArgv() != changed.inlineArgv()
    else:
      skip()

  test "Meson cleanup is reusable until setup identity changes":
    when defined(reproProviderMode):
      let root = getTempDir() / "repro-meson-cleanup-cache"
      if dirExists(root):
        removeDir(root)
      createDir(root)
      defer:
        if dirExists(root):
          removeDir(root)
      writeFile(root / "repro.nim", "package mesonCleanupTest:\n  discard\n")

      let first = mesonCleanup(root, "release", @["feature=enabled"])
      let same = mesonCleanup(root, "release", @["feature=enabled"])
      let changed = mesonCleanup(root, "debug", @["feature=enabled"])

      check first.cacheable
      check first.dependencyPolicy.kind == bdpAutomaticMonitor
      check first.dependencyPolicy.ignoredInputPrefixes ==
        @[root / "build-meson"]
      check first.inlineArgv() == same.inlineArgv()
      check first.inlineArgv() != changed.inlineArgv()
    else:
      skip()

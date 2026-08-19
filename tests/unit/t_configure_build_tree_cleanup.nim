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

  proc cmakeActions(projectRoot, generator: string;
                    cacheVars: seq[string]): seq[BuildActionDef] =
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
    extractActions(fragment)

  proc mesonActions(projectRoot, buildtype: string;
                    options: seq[string]): seq[BuildActionDef] =
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
    extractActions(fragment)

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

      let first = findById(cmakeActions(root, "Ninja", @["FEATURE=ON"]),
        "cmake-clean-build-dir-cmakeCleanupTest")
      let same = findById(cmakeActions(root, "Ninja", @["FEATURE=ON"]),
        "cmake-clean-build-dir-cmakeCleanupTest")
      let changed = findById(cmakeActions(root, "Unix Makefiles",
        @["FEATURE=ON"]), "cmake-clean-build-dir-cmakeCleanupTest")

      check first.cacheable
      check first.dependencyPolicy.kind == bdpAutomaticMonitor
      check first.dependencyPolicy.ignoredInputPrefixes ==
        @[root / "build-cmake"]
      check first.inlineArgv() == same.inlineArgv()
      check first.inlineArgv() != changed.inlineArgv()

  test "CMake pipeline excludes its shared mutable build tree":
    when defined(reproProviderMode):
      let root = getTempDir() / "repro-cmake-mutable-tree"
      if dirExists(root):
        removeDir(root)
      createDir(root)
      defer:
        if dirExists(root):
          removeDir(root)
      writeFile(root / "repro.nim", "package cmakeCleanupTest:\n  discard\n")

      let actions = cmakeActions(root, "Ninja", @["FEATURE=ON"])
      let cleanup = findById(actions,
        "cmake-clean-build-dir-cmakeCleanupTest")
      var configure, build, install: BuildActionDef
      for action in actions:
        if action.call.packageName == "cmake" and
            action.call.subcommand == "configure":
          configure = action
        elif action.id == "cmake-build-cmakeCleanupTest":
          build = action
        elif action.id == "cmake-install-cmakeCleanupTest":
          install = action

      check configure.id.len > 0
      check build.id.len > 0
      check install.id.len > 0
      check configure.dependencyPolicy.ignoredInputPrefixes ==
        @[root / "build-cmake"]
      check build.dependencyPolicy.ignoredInputPrefixes ==
        @[root / "build-cmake"]
      check install.dependencyPolicy.ignoredInputPrefixes ==
        @[root / "build-cmake", root / "build-cmake" / "out"]
      check build.inputs == cleanup.outputs
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

      let first = findById(mesonActions(root, "release",
        @["feature=enabled"]), "meson-clean-build-dir-mesonCleanupTest")
      let same = findById(mesonActions(root, "release",
        @["feature=enabled"]), "meson-clean-build-dir-mesonCleanupTest")
      let changed = findById(mesonActions(root, "debug",
        @["feature=enabled"]), "meson-clean-build-dir-mesonCleanupTest")

      check first.cacheable
      check first.dependencyPolicy.kind == bdpAutomaticMonitor
      check first.dependencyPolicy.ignoredInputPrefixes ==
        @[root / "build-meson"]
      check first.inlineArgv() == same.inlineArgv()
      check first.inlineArgv() != changed.inlineArgv()

  test "Meson pipeline excludes its shared mutable build tree":
    when defined(reproProviderMode):
      let root = getTempDir() / "repro-meson-mutable-tree"
      if dirExists(root):
        removeDir(root)
      createDir(root)
      defer:
        if dirExists(root):
          removeDir(root)
      writeFile(root / "repro.nim", "package mesonCleanupTest:\n  discard\n")

      let actions = mesonActions(root, "release", @["feature=enabled"])
      let cleanup = findById(actions,
        "meson-clean-build-dir-mesonCleanupTest")
      let refresh = findById(actions,
        "meson-refresh-generated-mtime-mesonCleanupTest")
      var setup, compile: BuildActionDef
      for action in actions:
        if action.call.packageName == "meson" and
            action.call.subcommand == "setup":
          setup = action
        elif action.call.packageName == "meson" and
            action.call.subcommand == "compile":
          compile = action

      check setup.id.len > 0
      check compile.id.len > 0
      for action in [setup, refresh, compile]:
        check action.dependencyPolicy.ignoredInputPrefixes ==
          @[root / "build-meson"]
      check refresh.cacheable
      check refresh.inputs == cleanup.outputs
      check compile.inputs == cleanup.outputs
    else:
      skip()

import std/unittest

when defined(reproProviderMode):
  import std/[os, osproc, strutils, tempfiles]

  import repro_core
  import repro_project_dsl
  import repro_dsl_stdlib/constructors

  package cmakeCleanupTest:
    nativeBuildDeps:
      "chmod"
    config:
      discard

  package mesonCleanupTest:
    nativeBuildDeps:
      "chmod"
    config:
      discard

  package autotoolsCleanupTest:
    config:
      discard

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
                    cacheVars: seq[string];
                    srcPatches: seq[string] = @[];
                    freshConfigure = false): seq[BuildActionDef] =
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
          cacheVars = cacheVars,
          srcPatches = srcPatches,
          freshConfigure = freshConfigure),
      includeDefault = false)
    extractActions(fragment)

  proc mesonActions(projectRoot, buildtype: string;
                    options: seq[string];
                    srcPatches: seq[string] = @[]): seq[BuildActionDef] =
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
          configureOptions = options,
          srcPatches = srcPatches),
      includeDefault = false)
    extractActions(fragment)

  proc exerciseCleanup(action: BuildActionDef; root, buildDir: string) =
    let stamp = action.outputs[0]
    let stampDir = parentDir(stamp)
    let unrelated = root / "unrelated" / "keep.txt"
    createDir(parentDir(unrelated))
    writeFile(unrelated, "keep\n")
    for attempt in 0 .. 1:
      # Graph extraction or a previous build must not prepare the action's cwd.
      if dirExists(stampDir):
        removeDir(stampDir)
      createDir(root / buildDir)
      writeFile(root / buildDir / "stale.txt", "stale\n")
      let execution = execCmdEx(quoteShellCommand(action.inlineArgv()),
        workingDir = root)
      checkpoint execution.output
      check execution.exitCode == 0
      check fileExists(stamp)
      check not dirExists(root / buildDir)
      check readFile(unrelated) == "keep\n"

  proc autotoolsConfigure(root, srcDir, buildDir: string;
                         srcPatches: seq[string] = @[];
                         bootstrap = false;
                         skipConfigure = false;
                         configureOutputFiles: seq[string] = @["Makefile"]): BuildActionDef =
    let name = "autotoolsCleanupTest"
    let pkg = PackageDef(packageName: name, sourceFile: root / "repro.nim")
    let fragment = buildPackageFragment(pkg, dummyRequest(root, name),
      proc() =
        discard autotools_package(srcDir = srcDir, buildDir = buildDir,
          srcPatches = srcPatches, patchHardcodedFile = bootstrap,
          skipConfigure = skipConfigure,
          configureOutputFiles = configureOutputFiles),
      includeDefault = false)
    for action in extractActions(fragment):
      if action.commandStatsId == "autotools_package.configure":
        return action
    raise newException(ValueError, "missing Autotools configure action")

suite "configure build-tree cleanup caching":
  test "Autotools excludes only the discarded out-of-tree configure state":
    when defined(reproProviderMode):
      let root = createTempDir("repro-autotools-discarded-", "")
      defer: removeDir(root)
      writeFile(root / "repro.nim", "discard\n")
      let configure = autotoolsConfigure(root, "src", "build")
      check configure.dependencyPolicy.kind == bdpAutomaticMonitor
      check configure.dependencyPolicy.ignoredInputPrefixes == @[root / "build"]
      check configure.outputs == @[root / "build" / ".repro-configure.stamp",
        root / "build" / "Makefile"]
      check root / "src" in configure.readOnlyRoots

  test "Autotools custom configure files are relative to the build directory":
    when defined(reproProviderMode):
      let root = createTempDir("repro-autotools-custom-outputs-", "")
      defer: removeDir(root)
      writeFile(root / "repro.nim", "discard\n")
      let configure = autotoolsConfigure(root, "src", "build",
        configureOutputFiles = @["GNUmakefile", "generated/config.h"])
      check configure.outputs == @[root / "build" / ".repro-configure.stamp",
        root / "build" / "GNUmakefile", root / "build" / "generated/config.h"]

  test "Autotools in-source configure retains its observed inputs":
    when defined(reproProviderMode):
      let root = createTempDir("repro-autotools-in-source-", "")
      defer: removeDir(root)
      writeFile(root / "repro.nim", "discard\n")
      let configure = autotoolsConfigure(root, "./src", "src")
      check configure.dependencyPolicy.kind == bdpAutomaticMonitor
      check configure.dependencyPolicy.ignoredInputPrefixes.len == 0
      check configure.outputs == @[root / "src" / "Makefile"]

  test "Autotools pre-cleanup patches and bootstrap retain observed inputs":
    when defined(reproProviderMode):
      let root = createTempDir("repro-autotools-before-clean-", "")
      defer: removeDir(root)
      writeFile(root / "repro.nim", "discard\n")
      let patched = autotoolsConfigure(root, "src", "build",
        srcPatches = @["test ! -f build/input || cp build/input src/settings"])
      let bootstrapped = autotoolsConfigure(root, "src", "build", bootstrap = true)
      check patched.dependencyPolicy.ignoredInputPrefixes.len == 0
      check bootstrapped.dependencyPolicy.ignoredInputPrefixes.len == 0

  test "Autotools raw Makefile copying creates its configure stamp in the build tree":
    when defined(reproProviderMode) and not defined(windows):
      let root = createTempDir("repro-autotools-copy-stamp-", "")
      defer: removeDir(root)
      writeFile(root / "repro.nim", "discard\n")
      createDir(root / "src")
      writeFile(root / "src" / "Makefile", "all:\n\t@true\n")
      let configure = autotoolsConfigure(root, "src", "build", skipConfigure = true)
      check configure.dependencyPolicy.ignoredInputPrefixes == @[root / "build"]
      let execution = execCmdEx(quoteShellCommand(configure.inlineArgv()),
        workingDir = root)
      checkpoint execution.output
      check execution.exitCode == 0
      check fileExists(root / "build" / ".repro-configure.stamp")
      check readFile(root / "build" / "Makefile") == readFile(root / "src" / "Makefile")
    else:
      skip()

  test "CMake cleanup creates its missing stamp directory at execution":
    when defined(reproProviderMode) and not defined(windows):
      let root = createTempDir("repro-cmake-clean-exec-", "")
      defer: removeDir(root)
      writeFile(root / "repro.nim", "discard\n")
      let cleanup = findById(cmakeActions(root, "Ninja", @[]),
        "cmake-clean-build-dir-cmakeCleanupTest")
      exerciseCleanup(cleanup, root, "build-cmake")
    else:
      skip()

  test "Meson cleanup creates its missing stamp directory at execution":
    when defined(reproProviderMode) and not defined(windows):
      let root = createTempDir("repro-meson-clean-exec-", "")
      defer: removeDir(root)
      writeFile(root / "repro.nim", "discard\n")
      let cleanup = findById(mesonActions(root, "release", @[]),
        "meson-clean-build-dir-mesonCleanupTest")
      exerciseCleanup(cleanup, root, "build-meson")
    else:
      skip()

  test "source patch actions inherit recipe tool identities":
    when defined(reproProviderMode):
      let root = getTempDir() / "repro-configure-patch-tools"
      if dirExists(root):
        removeDir(root)
      createDir(root)
      defer:
        if dirExists(root):
          removeDir(root)
      writeFile(root / "repro.nim", "discard\n")

      let cmakePatch = findById(cmakeActions(root, "Ninja", @[],
        srcPatches = @["chmod +x src/tool"]),
        "cmake-patch-cmakeCleanupTest")
      let mesonPatch = findById(mesonActions(root, "release", @[],
        srcPatches = @["chmod +x src/tool"]),
        "meson-patch-mesonCleanupTest")

      check cmakePatch.toolIdentityRefs == @["sh", "chmod"]
      check mesonPatch.toolIdentityRefs == @["sh", "chmod"]
    else:
      skip()

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
      check first.toolIdentityRefs == @["sh", "rm", "mkdir"]
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

      let freshActions = cmakeActions(root, "Ninja", @["FEATURE=ON"],
        freshConfigure = true)
      let freshCleanup = findById(freshActions, cleanup.id)
      check freshCleanup.cacheable
      check freshCleanup.inlineArgv() == cleanup.inlineArgv()
      for action in freshActions:
        if action.call.packageName == "cmake" and
            action.call.subcommand == "configure":
          check action.cacheable
          check action.id != configure.id
          var foundFresh = false
          for arg in action.call.arguments:
            if arg.name == "fresh":
              foundFresh = arg.alias == "--fresh" and arg.encodedValue == "true"
          check foundFresh
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
      check first.toolIdentityRefs == @["sh", "rm", "mkdir"]
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

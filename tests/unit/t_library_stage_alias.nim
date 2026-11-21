import std/unittest
import repro_test_support/reasoned_skip

when defined(reproProviderMode):
  import std/[os, osproc, strutils, tempfiles]

  import repro_core
  import repro_project_dsl
  import repro_dsl_stdlib/constructors
  import repro_dsl_stdlib/types/package_result

  proc dummyRequest(projectRoot: string): ProviderGraphRequest =
    ProviderGraphRequest(
      kind: prkGraphInvocation,
      providerArtifactId: "test-provider",
      entryPointId: "libraryAliasPkg.root",
      entryPointBodyHash: "test-body",
      reason: girExplicitUserRequest,
      arguments: projectRoot,
      namespace: "project")

  proc createRecipeRoot(projectRoot: string) =
    ## A package's project root carries the recipe its ``PackageDef`` names.
    ## The source cache identity hashes those bytes as its provider-revision
    ## component and refuses a root without one (``CacheKeyError``), so a
    ## fixture root has to hold a real, non-empty ``repro.nim`` -- one per
    ## package, naming it, so two fixture packages never share a revision.
    createDir(projectRoot)
    writeFile(projectRoot / "repro.nim",
      "# fixture recipe for " & projectRoot.extractFilename & "\n")

  proc extractActions(fragment: GraphFragment): seq[BuildActionDef] =
    for node in fragment.nodes:
      if node.kind == gnkAction:
        result.add(decodeBuildActionPayload(toBytes(node.payload)))

  proc findById(actions: seq[BuildActionDef]; id: string): BuildActionDef =
    for action in actions:
      if action.id == id:
        return action
    raise newException(ValueError, "action not found: " & id)

  proc inlineScriptOf(action: BuildActionDef): string =
    for arg in action.call.arguments:
      if arg.name == "argv":
        let argv = arg.encodedValue.split("\x1f")
        if argv.len >= 3:
          return argv[2]
    ""

suite "library stage aliases":
  test "preserve the installed name behind the public artifact name":
    when defined(reproProviderMode):
      let scratch = getTempDir() / "repro-library-stage-alias"
      let projectRoot = scratch / "libraryAliasPkg"
      if dirExists(scratch):
        removeDir(scratch)
      createRecipeRoot(projectRoot)
      defer:
        if dirExists(scratch):
          removeDir(scratch)

      let pkg = PackageDef(
        packageName: "libraryAliasPkg",
        sourceFile: projectRoot / "repro.nim",
        hasDevEnv: false,
        devEnvBodyHash: "",
        toolUses: @[])
      let fragment = buildPackageFragment(
        pkg,
        dummyRequest(projectRoot),
        proc() =
        setCurrentOwningPackageOverride("libraryAliasPkg")
        try:
          let build = autotools_package(
            srcDir = "./src",
            skipConfigure = true)
          let library = build.libraryAlias("libPublic", "upstream-runtime")
          check library.installPrefix == "usr/lib"
        finally:
          clearCurrentOwningPackageOverride(),
        includeDefault = false)

      let actions = extractActions(fragment)
      let stage = findById(actions,
        "autotools-stage-library-libraryAliasPkg-libPublic")
      let mirror = findById(actions, "install-mirror-libraryAliasPkg")
      let script = stage.inlineScriptOf()
      let expectedOutput = projectRoot / ".repro" / "output" /
        "libPublic" / "libPublic"

      check stage.outputs == @[expectedOutput]
      check stage.deps == @["autotools-la-cleanup-libraryAliasPkg-build"]
      check stage.toolIdentityRefs == @[
        "sh", "mkdir", "cp", "ls", "sort", "head"]
      check mirror.id.len > 0
      when defined(windows):
        check "build/out/usr/bin/upstream-runtime.dll" in script
        check "build/out/usr/bin/libPublic.dll" notin script
      else:
        check "upstream-runtime" in script
    else:
      skip()

suite "autotools multi-build action identities":
  test "scope cleanup edges by build directory":
    when defined(reproProviderMode):
      let scratch = getTempDir() / "repro-autotools-multi-build"
      let projectRoot = scratch / "multiBuildPkg"
      if dirExists(scratch):
        removeDir(scratch)
      createRecipeRoot(projectRoot)
      defer:
        if dirExists(scratch):
          removeDir(scratch)

      let pkg = PackageDef(
        packageName: "multiBuildPkg",
        sourceFile: projectRoot / "repro.nim",
        hasDevEnv: false,
        devEnvBodyHash: "",
        toolUses: @[])
      let fragment = buildPackageFragment(
        pkg,
        dummyRequest(projectRoot),
        proc() =
        registerFetchSpec(
          packageName = "multiBuildPkg",
          url = "https://example.org/multi-build.tar.xz",
          gitRevision = "",
          hashAlg = dshaSha256,
          hashHex = "b53606f443ac8f01d1d5fc9c39497f2a" &
            "f322d99e14cea5c0b4b124d630379365",
          kind = dfkTarball,
          extractStrip = 1,
          extractedRoot = "")
        setCurrentOwningPackageOverride("multiBuildPkg")
        try:
          discard autotools_package(
            srcDir = "./src",
            buildDir = "build-bios",
            skipConfigure = true)
          discard autotools_package(
            srcDir = "./src",
            buildDir = "build-efi",
            skipConfigure = true)
        finally:
          clearCurrentOwningPackageOverride(),
        includeDefault = false)

      let actions = extractActions(fragment)
      var fetchCount = 0
      for action in actions:
        if action.id == "autotools-fetch-multiBuildPkg":
          inc fetchCount
      check fetchCount == 1
      check findById(actions,
        "autotools-la-cleanup-multiBuildPkg-build-bios").id.len > 0
      check findById(actions,
        "autotools-la-cleanup-multiBuildPkg-build-efi").id.len > 0
    else:
      skip()

suite "executable stage aliases":
  test "stage a host-native executable under its public interface name":
    when defined(reproProviderMode):
      let scratch = getTempDir() / "repro-executable-stage-alias"
      let projectRoot = scratch / "executableAliasPkg"
      if dirExists(scratch):
        removeDir(scratch)
      createRecipeRoot(projectRoot)
      defer:
        if dirExists(scratch):
          removeDir(scratch)

      let pkg = PackageDef(
        packageName: "executableAliasPkg",
        sourceFile: projectRoot / "repro.nim",
        hasDevEnv: false,
        devEnvBodyHash: "",
        toolUses: @[])
      let fragment = buildPackageFragment(
        pkg,
        dummyRequest(projectRoot),
        proc() =
        setCurrentOwningPackageOverride("executableAliasPkg")
        try:
          let build = autotools_package(
            srcDir = "./src",
            skipConfigure = true)
          let executable = build.executableAlias(
            "toolAlias", "upstream-tool")
          check executable.cli.executableName == "toolAlias"
          discard build.executable("regularTool")
        finally:
          clearCurrentOwningPackageOverride(),
        includeDefault = false)

      let actions = extractActions(fragment)
      let stage = findById(actions,
        "autotools-stage-alias-executableAliasPkg-toolAlias")
      let regularStage = findById(actions,
        "autotools-stage-executable-executableAliasPkg-regularTool")
      let script = stage.inlineScriptOf()
      let outputDir = projectRoot / ".repro" / "output" / "toolAlias"

      when defined(windows):
        check stage.toolIdentityRefs == @["sh", "mkdir", "cp"]
      else:
        check stage.toolIdentityRefs == @[
          "sh", "mkdir", "cp", "chmod", "ln"]
      check regularStage.toolIdentityRefs == @[
        "sh", "mkdir", "rm", "cp", "chmod", "mv"]

      when defined(windows):
        check stage.outputs == @[
          outputDir / "toolAlias.exe",
          outputDir / "upstream-tool.exe",
        ]
        check "build/out/usr/bin/upstream-tool.exe" in script
        check "toolAlias.exe" in script
        check "#!/bin/sh" notin script
      else:
        check stage.outputs == @[
          outputDir / "toolAlias",
          outputDir / "upstream-tool",
        ]
        check "build/out/usr/bin/upstream-tool" in script
        check "#!/bin/sh" in script
        check "ln -sfn \"toolAlias\"" in script
    else:
      skip()

suite "executable stage copy writes its declared output":
  test "an installed executable is staged under the declared name":
    # The engine fails a cacheable action that exits 0 without a declared
    # output (reprobuild-pm Build-Engine-And-Scheduler.md, "A declared
    # output is an obligation"). The stage copy declares
    # `.repro/output/<name>/<name>`. On Windows the install tree holds
    # `<name>.exe`, and MSYS `sh` resolves the bare `<name>` probe to it and
    # `cp` appends `.exe` to the destination, so only `<name>.exe` used to
    # be written. This runs the emitted stage-copy script for real (the
    # host's own `sh`, `cp`, `mv`) against an install tree holding the
    # executable the host's toolchain would install, and checks the
    # declared output exists. No mock: the script is the one the action
    # carries.
    when defined(reproProviderMode):
      let sh = findExe("sh")
      if sh.len == 0:
        skip("sh not on PATH: cannot run the stage-copy script")
      else:
        let scratch = createTempDir("repro-executable-stage-copy-real-", "")
        let projectRoot = scratch / "stageCopyRealPkg"
        createRecipeRoot(projectRoot)
        defer:
          if dirExists(scratch):
            removeDir(scratch)
        let pkg = PackageDef(
          packageName: "stageCopyRealPkg",
          sourceFile: projectRoot / "repro.nim",
          hasDevEnv: false,
          devEnvBodyHash: "",
          toolUses: @[])
        let fragment = buildPackageFragment(
          pkg,
          dummyRequest(projectRoot),
          proc() =
          setCurrentOwningPackageOverride("stageCopyRealPkg")
          try:
            let build = autotools_package(
              srcDir = "./src",
              skipConfigure = true)
            discard build.executable("realTool")
          finally:
            clearCurrentOwningPackageOverride(),
          includeDefault = false)
        let stage = findById(extractActions(fragment),
          "autotools-stage-executable-stageCopyRealPkg-realTool")
        require stage.cacheable
        require stage.outputs.len == 1
        # What `make install` puts in the DESTDIR tree on this host.
        let installedName =
          when defined(windows): "realTool.exe" else: "realTool"
        let installedPath = projectRoot / "build" / "out" / "usr" / "bin" /
          installedName
        createDir(parentDir(installedPath))
        # Run twice: the second run starts with the first run's outputs
        # in place, as a rebuild does, and the installed executable has
        # changed in between. The declared output must carry the bytes of
        # the run that wrote it, not the previous build's: under MSYS a
        # copy through the bare name writes only `<out>.exe`, so a stale
        # literal `<out>` would otherwise survive the rebuild.
        # The script goes through a file: a Windows command line does not
        # carry this script's quoting to MSYS `sh` intact.
        let scriptFile = scratch / "stage-copy.sh"
        writeFile(scriptFile, stage.inlineScriptOf())
        for attempt in 0 .. 1:
          let contents = "MZ-fixture-build-" & $attempt
          writeFile(installedPath, contents)
          let run = execCmdEx(quoteShellCommand(@[sh, scriptFile]),
            workingDir = projectRoot)
          checkpoint "attempt " & $attempt & ": " & run.output
          require run.exitCode == 0
          for output in stage.outputs:
            checkpoint "declared output: " & output
            check fileExists(output)
            check readFile(output) == contents
    else:
      skip("needs -d:reproProviderMode: the stage-copy action is emitted only by the provider-mode DSL")

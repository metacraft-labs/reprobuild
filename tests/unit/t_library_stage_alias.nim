import std/unittest

when defined(reproProviderMode):
  import std/[os, strutils]

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
      createDir(projectRoot)
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
      createDir(projectRoot)
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
      createDir(projectRoot)
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
        finally:
          clearCurrentOwningPackageOverride(),
        includeDefault = false)

      let actions = extractActions(fragment)
      let stage = findById(actions,
        "autotools-stage-alias-executableAliasPkg-toolAlias")
      let script = stage.inlineScriptOf()
      let outputDir = projectRoot / ".repro" / "output" / "toolAlias"

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

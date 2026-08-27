import std/[os, unittest]

when defined(reproProviderMode):
  import repro_core
  import repro_project_dsl
  import repro_dsl_stdlib/constructors

  type ConstructorKind = enum
    ckCmake,
    ckMeson,
    ckAutotools

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

  proc constructorActions(projectRoot, packageName: string;
                          kind: ConstructorKind): seq[BuildActionDef] =
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
        case kind
        of ckCmake:
          discard cmake_package(srcDir = "src")
        of ckMeson:
          discard meson_package(srcDir = "src")
        of ckAutotools:
          discard autotools_package(srcDir = "src"),
      includeDefault = false)
    extractActions(fragment)

  proc registerSha256Fetch(packageName: string) =
    registerFetchSpec(
      packageName = packageName,
      url = "https://example.invalid/source.tar.gz",
      gitRevision = "",
      hashAlg = dshaSha256,
      hashHex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      kind = dfkTarball,
      extractStrip = 1,
      extractedRoot = "")

  proc customSynthActions(projectRoot, packageName: string):
      seq[BuildActionDef] =
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
        resetDslPortShellStateForPackage(packageName)
        let state = beginBuildBlock(packageName, "executable", "probe")
        try:
          shell "mkdir -p $out/bin"
        finally:
          endBuildBlock(state)
        synthesizeCustomShellBuildActions(packageName),
      includeDefault = false)
    extractActions(fragment)

suite "constructor fetch tool identities":
  test "CMake, Meson, and Autotools declare every shell command tool":
    when defined(reproProviderMode):
      resetDslPortFetchState()
      defer:
        resetDslPortFetchState()
      let root = getTempDir() / "repro-constructor-fetch-tool-refs"
      if dirExists(root):
        removeDir(root)
      createDir(root)
      defer:
        if dirExists(root):
          removeDir(root)
      writeFile(root / "repro.nim", "package fetchToolRefsTest:\n  discard\n")

      let cases = [
        ("cmakeFetchTest", ckCmake, "cmake-fetch-cmakeFetchTest"),
        ("mesonFetchTest", ckMeson, "meson-fetch-mesonFetchTest"),
        ("autotoolsFetchTest", ckAutotools,
          "autotools-fetch-autotoolsFetchTest"),
      ]
      let expected = @["sh", "rm", "mkdir", "curl", "mv", "sha256sum",
        "tar", "gzip"]
      check shellFetchToolIdentityRefs(@["b2sum", "blake3sum"],
        copiesDataFile = true) ==
          @["sh", "rm", "mkdir", "curl", "mv", "b2sum", "blake3sum",
            "cp"]
      check shellFetchToolIdentityRefs(@["sha256sum"],
        archiveUrl = "https://example.invalid/source.tar.xz?mirror=1") ==
          @["sh", "rm", "mkdir", "curl", "mv", "sha256sum", "tar", "xz"]
      for (packageName, kind, actionId) in cases:
        registerSha256Fetch(packageName)
        let action = findById(constructorActions(root, packageName, kind),
          actionId)
        check action.toolIdentityRefs == expected
    else:
      skip()

  test "custom-shell synthesis declares every fetch command tool":
    when defined(reproProviderMode):
      const PackageName = "customFetchTest"
      resetDslPortFetchState()
      resetDslPortShellStateForPackage(PackageName)
      defer:
        resetDslPortFetchState()
        resetDslPortShellStateForPackage(PackageName)
      let root = getTempDir() / "repro-custom-fetch-tool-refs"
      if dirExists(root):
        removeDir(root)
      createDir(root)
      defer:
        if dirExists(root):
          removeDir(root)
      writeFile(root / "repro.nim", "package customFetchTest:\n  discard\n")

      registerSha256Fetch(PackageName)
      let action = findById(customSynthActions(root, PackageName),
        "ccpp-fetch-" & PackageName)
      check action.toolIdentityRefs ==
        @["sh", "rm", "mkdir", "curl", "mv", "sha256sum", "tar", "gzip"]
    else:
      skip()

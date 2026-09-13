import std/[os, sequtils, strutils, tempfiles, unittest]

when defined(reproProviderMode):
  import repro_core
  import repro_project_dsl
  import repro_dsl_stdlib/constructors
  import repro_standard_provider/conventions/fetch_action

  proc expectedFetchEnv(): seq[(string, string)] =
    when defined(macosx):
      @[("LD_LIBRARY_PATH", ""), ("DYLD_LIBRARY_PATH", "")]
    elif defined(posix):
      @[("LD_LIBRARY_PATH", "")]
    else:
      @[]

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

  proc registerTestFetch(packageName: string; hashAlg = dshaSha256) =
    registerFetchSpec(
      packageName = packageName,
      url = "https://example.invalid/source.tar.gz",
      gitRevision = "",
      hashAlg = hashAlg,
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
      check shellFetchToolIdentityRefs(@["b3sum"],
        copiesDataFile = true) ==
          @["sh", "rm", "mkdir", "curl", "mv", "b3sum",
            "cp"]
      check shellFetchToolIdentityRefs(@["sha256sum"],
        archiveUrl = "https://example.invalid/source.tar.xz?mirror=1") ==
          @["sh", "rm", "mkdir", "curl", "mv", "sha256sum", "tar", "xz"]
      for (packageName, kind, actionId) in cases:
        registerTestFetch(packageName)
        let action = findById(constructorActions(root, packageName, kind),
          actionId)
        check action.toolIdentityRefs == expected
        check action.env.filterIt(it[0] != "OUT_MIRROR") == expectedFetchEnv()
        check action.dependencyPolicy == automaticMonitorPolicy()
        for other in constructorActions(root, packageName, kind):
          if other.id != actionId:
            check ("LD_LIBRARY_PATH", "") notin other.env
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

      registerTestFetch(PackageName)
      let action = findById(customSynthActions(root, PackageName),
        "ccpp-fetch-" & PackageName)
      check action.toolIdentityRefs ==
        @["sh", "rm", "mkdir", "curl", "mv", "sha256sum", "tar", "gzip"]
      check action.env.filterIt(it[0] != "OUT_MIRROR") == expectedFetchEnv()
      check action.dependencyPolicy == automaticMonitorPolicy()
    else:
      skip()

  test "standard fetch isolates its loader paths for every source kind":
    when defined(reproProviderMode):
      let root = createTempDir("repro-standard-fetch-env-", "")
      defer: removeDir(root)
      for kind in DslFetchKind:
        let spec = DslFetchSpec(
          url: "https://example.invalid/source.tar.gz",
          gitRevision: "v1",
          hashAlg: dshaSha256,
          hashHex: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          kind: kind,
          extractStrip: 1)
        let action = emitFetchAction(root, "standardFetchEnv", spec)
        check action.env == expectedFetchEnv()
        check action.dependencyPolicy == automaticMonitorPolicy()
        check not action.cacheable
    else:
      skip()

  test "BLAKE3 fetch commands and identities select b3sum together":
    when defined(reproProviderMode):
      resetDslPortFetchState()
      let root = createTempDir("repro-blake3-fetch-", "")
      defer:
        resetDslPortFetchState()
        removeDir(root)
      writeFile(root / "repro.nim", "package blake3FetchTest:\n  discard\n")
      for kind in ConstructorKind:
        let packageName = "blake3Fetch" & $kind
        registerTestFetch(packageName, dshaBlake3)
        var checked = false
        for action in constructorActions(root, packageName, kind):
          if "b3sum" notin action.toolIdentityRefs:
            continue
          checked = true
          check "b2sum" notin action.toolIdentityRefs
          check "blake3sum" notin action.toolIdentityRefs
          check "| b3sum -c -;" in action.call.arguments[0].encodedValue
          check "b2sum -a" notin action.call.arguments[0].encodedValue
        check checked
    else:
      skip()

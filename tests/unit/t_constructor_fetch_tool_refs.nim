import std/[os, osproc, sequtils, strutils, tempfiles, times, unittest]

when defined(reproProviderMode):
  import repro_core
  import repro_core/ambient_execution
  import repro_project_dsl
  import repro_dsl_stdlib/constructors
  import repro_standard_provider/conventions/fetch_action
  import nimcrypto/sha2

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

  proc executeArgv(argv: seq[string]): int =
    # Exercise emitted shell bytes directly; full engine reuse has a separate
    # integration probe. Inherit the test environment's declared host tools.
    let process = uncontrolledStartProcess(findExe(argv[0]), args = argv[1 .. ^1],
      options = {poParentStreams})
    try:
      result = process.waitForExit()
    finally:
      process.close()

  proc executeFetch(action: BuildActionDef): int =
    for argument in action.call.arguments:
      if argument.name == "argv":
        let argv = argument.encodedValue.split('\x1f')
        doAssert argv.len == 3
        return executeArgv(argv)
    raise newException(ValueError, "fetch has no argv")

  proc fetchFor(root, packageName: string; emitter: int;
                spec: DslFetchSpec): BuildActionDef =
    resetDslPortFetchState()
    registerFetchSpec(packageName, spec.url, spec.gitRevision, spec.hashAlg,
      spec.hashHex, spec.kind, spec.extractStrip, spec.extractedRoot)
    if emitter == 4:
      return emitFetchAction(root, packageName, spec)
    let actions =
      if emitter == 3: customSynthActions(root, packageName)
      else: constructorActions(root, packageName, ConstructorKind(emitter))
    for action in actions:
      if "-fetch-" in action.id:
        return action
    raise newException(ValueError, "missing emitted fetch action")

  proc dataFetchSpec(root: string): DslFetchSpec =
    let source = root / "payload"
    writeFile(source, "fetch-stamp-regression\n")
    DslFetchSpec(url: "file://" & source.replace('\\', '/'),
      hashAlg: dshaSha256, hashHex: ($sha256.digest(readFile(source))).toLowerAscii(),
      kind: dfkDataFile, extractStrip: 0, extractedRoot: "src")

suite "constructor fetch tool identities":
  test "verified unchanged fetches preserve consumer stamp timestamps":
    when defined(reproProviderMode):
      let root = createTempDir("repro-fetch-stamp-reuse-", "")
      defer:
        resetDslPortFetchState()
        removeDir(root)
      for emitter in 0 .. 4:
        let project = root / $emitter
        createDir(project)
        writeFile(project / "repro.nim", "package stampReuse:\n  discard\n")
        let spec = dataFetchSpec(project)
        let action = fetchFor(project, "stampReuse" & $emitter, emitter, spec)
        check not action.cacheable
        require executeFetch(action) == 0
        let stamp = action.outputs[0]
        require fileExists(project / "src" / "source")
        check readFile(project / "src" / "source") == "fetch-stamp-regression\n"
        setLastModificationTime(stamp, fromUnix(1_700_000_000))
        let before = getLastModificationTime(stamp)
        writeFile(project / "src" / "source", "locally damaged extraction")
        require executeFetch(action) == 0
        check readFile(project / "src" / "source") == "fetch-stamp-regression\n"
        check getLastModificationTime(stamp) == before
    else:
      skip()

  test "changed fetch programs update stamps and malformed stamps are repaired":
    when defined(reproProviderMode):
      let root = createTempDir("repro-fetch-stamp-identity-", "")
      defer:
        resetDslPortFetchState()
        removeDir(root)
      for emitter in 0 .. 4:
        let project = root / $emitter
        createDir(project)
        writeFile(project / "repro.nim", "package stampIdentity:\n  discard\n")
        var spec = dataFetchSpec(project)
        let action = fetchFor(project, "stampIdentity" & $emitter, emitter, spec)
        require executeFetch(action) == 0
        let stamp = action.outputs[0]
        let original = readFile(stamp)
        # A different URL with identical verified bytes still changes the
        # acquisition contract. The cached archive remains valid and local.
        spec.url.add("-new-location")
        let changed = fetchFor(project, "stampIdentity" & $emitter, emitter, spec)
        setLastModificationTime(stamp, fromUnix(1_700_000_000))
        let before = getLastModificationTime(stamp)
        require executeFetch(changed) == 0
        check getLastModificationTime(stamp) != before
        check readFile(stamp) != original
        let expected = readFile(stamp)
        for malformed in ["", "wrong\n", expected & "extra\n", expected & "tail"]:
          writeFile(stamp, malformed)
          require executeFetch(changed) == 0
          check readFile(stamp) == expected
        removeFile(stamp)
        require executeFetch(changed) == 0
        check readFile(stamp) == expected
    else:
      skip()

  test "failed verification leaves the previous stamp and extraction untouched":
    when defined(reproProviderMode):
      let root = createTempDir("repro-fetch-stamp-failure-", "")
      defer:
        resetDslPortFetchState()
        removeDir(root)
      for emitter in 0 .. 4:
        let project = root / $emitter
        createDir(project)
        writeFile(project / "repro.nim", "package stampFailure:\n  discard\n")
        let spec = dataFetchSpec(project)
        let action = fetchFor(project, "stampFailure" & $emitter, emitter, spec)
        require executeFetch(action) == 0
        let stamp = action.outputs[0]
        let expected = readFile(stamp)
        setLastModificationTime(stamp, fromUnix(1_700_000_000))
        let before = getLastModificationTime(stamp)
        writeFile(project / ".repro" / "fetch" / (spec.hashHex & ".tar"), "bad archive")
        check executeFetch(action) != 0
        check getLastModificationTime(stamp) == before
        check readFile(stamp) == expected
        check readFile(project / "src" / "source") == "fetch-stamp-regression\n"
    else:
      skip()

  test "archive replay preserves stamps but changed extraction settings invalidate them":
    when defined(reproProviderMode):
      let root = createTempDir("repro-fetch-stamp-archive-", "")
      defer:
        resetDslPortFetchState()
        removeDir(root)
      createDir(root / "vendor" / "outer" / "inner")
      writeFile(root / "vendor" / "outer" / "inner" / "payload", "archive payload\n")
      let archive = root / "source.tar"
      require executeArgv(@["tar", "-cf", archive, "-C", root / "vendor", "outer"]) == 0
      for emitter in 0 .. 4:
        let project = root / $emitter
        createDir(project)
        writeFile(project / "repro.nim", "package archiveStamp:\n  discard\n")
        var spec = DslFetchSpec(url: "file://" & archive.replace('\\', '/'),
          hashAlg: dshaSha256, hashHex: ($sha256.digest(readFile(archive))).toLowerAscii(),
          kind: dfkTarball, extractStrip: 1, extractedRoot: "src")
        let action = fetchFor(project, "archiveStamp" & $emitter, emitter, spec)
        require executeFetch(action) == 0
        let stamp = action.outputs[0]
        let original = readFile(stamp)
        setLastModificationTime(stamp, fromUnix(1_700_000_000))
        let before = getLastModificationTime(stamp)
        require executeFetch(action) == 0
        check getLastModificationTime(stamp) == before
        check readFile(project / "src" / "inner" / "payload") == "archive payload\n"
        spec.extractStrip = 2
        let changed = fetchFor(project, "archiveStamp" & $emitter, emitter, spec)
        require executeFetch(changed) == 0
        check readFile(project / "src" / "payload") == "archive payload\n"
        check not dirExists(project / "src" / "inner")
        check readFile(stamp) != original
        check getLastModificationTime(stamp) != before

        let invalidArchive = project / "invalid.tar"
        writeFile(invalidArchive, "valid hash, invalid tar")
        spec.url = "file://" & invalidArchive.replace('\\', '/')
        spec.hashHex = ($sha256.digest(readFile(invalidArchive))).toLowerAscii()
        let failed = fetchFor(project, "archiveStamp" & $emitter, emitter, spec)
        check executeFetch(failed) != 0
        check not fileExists(failed.outputs[0])
        check readFile(project / "src" / "payload") == "archive payload\n"
    else:
      skip()

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

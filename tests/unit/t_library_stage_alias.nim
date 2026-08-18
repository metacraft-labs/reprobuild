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
      check stage.deps == @["autotools-la-cleanup-libraryAliasPkg"]
      check mirror.id.len > 0
      when defined(windows):
        check "build/out/usr/bin/upstream-runtime.dll" in script
        check "build/out/usr/bin/libPublic.dll" notin script
      else:
        check "upstream-runtime" in script
    else:
      skip()

## M9.R.83 provider-mode action-shape coverage for install mirror
## publication. This pins the emitted BuildActionDef, not source text.

import std/[os, strutils, unittest]

import repro_core
import repro_project_dsl
import repro_dsl_stdlib/types/package_result

when defined(reproProviderMode):
  proc dummyRequest(projectRoot: string): ProviderGraphRequest =
    ProviderGraphRequest(
      kind: prkGraphInvocation,
      providerArtifactId: "test-provider",
      entryPointId: "test.entry",
      entryPointBodyHash: "test-body",
      reason: girExplicitUserRequest,
      arguments: projectRoot,
      namespace: "project")

  proc extractActions(fragment: GraphFragment): seq[BuildActionDef] =
    for node in fragment.nodes:
      if node.kind != gnkAction:
        continue
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

suite "M9.R.83 install mirror emitted action shape":

  test "typed emitInstallTreeMirror keeps legacy copy and adds publish":
    when defined(reproProviderMode):
      let scratch = getTempDir() / "m9r83-typed-action-shape"
      let projectRoot = scratch / "typed-recipe"
      if dirExists(scratch):
        removeDir(scratch)
      createDir(projectRoot)
      defer:
        if dirExists(scratch):
          removeDir(scratch)

      const PackageName = "m9r83TypedPkg"
      let pkg = PackageDef(
        packageName: PackageName,
        sourceFile: projectRoot / "repro.nim",
        hasDevEnv: false,
        devEnvBodyHash: "",
        toolUses: @[])
      let fragment = buildPackageFragment(pkg, dummyRequest(projectRoot),
        proc() =
          registerVersion(PackageName, DslVersionInfo(version: "2.4.6"))
          let installEdge = buildAction(
            id = "m9r83-install",
            call = inlineExecCall(@["sh", "-c", "true"], projectRoot),
            outputs = @[projectRoot / "build" / "dest" /
              ".install.stamp"],
            pool = "compile",
            toolIdentityRefs = @["sh"])
          emitInstallTreeMirror(installEdge, "build", "dest", PackageName,
            "autotools"),
        includeDefault = false)

      let actions = extractActions(fragment)
      let mirror = findById(actions, "install-mirror-" & PackageName)
      let sidecar = realizationInfoPath(parentDir(projectRoot),
        projectRoot.extractFilename)
      let stamp = projectRoot / ".repro" / "output" / "install" /
        ".m9r14e_2_install_mirror.stamp"
      let script = inlineScriptOf(mirror)

      check mirror.deps == @["m9r83-install"]
      check mirror.inputs == @[projectRoot / "build" / "dest" /
        ".install.stamp"]
      check stamp in mirror.outputs
      check sidecar in mirror.outputs
      check "sh" in mirror.toolIdentityRefs
      check InstallMirrorPublishToolName in mirror.toolIdentityRefs
      when defined(linux):
        check "patchelf" in mirror.toolIdentityRefs
      check "rm -rf" in script
      check "build/dest/usr" in script
      check "cp -a --" in script
      check ".m9r14e_2_install_mirror.stamp" in script
      check InstallMirrorPublishToolName in script
      check InstallMirrorModeEnvVar in script
      check "hashed|hashed-with-legacy-fallback" in script
      check "--package \"typed-recipe\"" in script
      check "--package \"" & PackageName & "\"" notin script
      check "--version \"2.4.6\"" in script
      check "--source \"" & (projectRoot / ".repro" / "output" /
        "install").replace("\\", "/") & "\"" in script
      check "*) mkdir -p \"" & parentDir(sidecar).replace("\\", "/") &
        "\"; : > \"" & sidecar.replace("\\", "/") & "\"; ;; esac" in script
    else:
      check true

  test "custom-shell synthesizer emits mirror publish action":
    when defined(reproProviderMode):
      let scratch = getTempDir() / "m9r83-custom-shell-action-shape"
      let projectRoot = scratch / "custom-shell-recipe"
      if dirExists(scratch):
        removeDir(scratch)
      createDir(projectRoot)
      defer:
        if dirExists(scratch):
          removeDir(scratch)

      const PackageName = "m9r83CustomShellPkg"
      let pkg = PackageDef(
        packageName: PackageName,
        sourceFile: projectRoot / "repro.nim",
        hasDevEnv: false,
        devEnvBodyHash: "",
        toolUses: @[])
      let fragment = buildPackageFragment(pkg, dummyRequest(projectRoot),
        proc() =
          resetDslPortShellStateForPackage(PackageName)
          registerVersion(PackageName, DslVersionInfo(version: "8.3.0"))
          let state = beginBuildBlock(PackageName, "library", "libM9r83")
          try:
            shell "mkdir -p $out/lib"
            shell "printf x > $out/lib/libm9r83.a"
          finally:
            endBuildBlock(state)
          synthesizeCustomShellBuildActions(PackageName),
        includeDefault = false)

      let actions = extractActions(fragment)
      let mirror = findById(actions, "from-source-custom-mirror-" &
        PackageName)
      let sidecar = realizationInfoPath(parentDir(projectRoot),
        projectRoot.extractFilename)
      let script = inlineScriptOf(mirror)

      check actions.len == 3
      check mirror.deps == @["from-source-custom-shell-2-" & PackageName]
      check "sh" in mirror.toolIdentityRefs
      check InstallMirrorPublishToolName in mirror.toolIdentityRefs
      check sidecar in mirror.outputs
      check InstallMirrorPublishToolName in script
      check InstallMirrorModeEnvVar in script
      check "hashed|hashed-with-legacy-fallback" in script
      check "--package \"custom-shell-recipe\"" in script
      check "--package \"" & PackageName & "\"" notin script
      check "--version \"8.3.0\"" in script
      check "*) mkdir -p \"" & parentDir(sidecar).replace("\\", "/") &
        "\"; : > \"" & sidecar.replace("\\", "/") & "\"; ;; esac" in script
    else:
      check true

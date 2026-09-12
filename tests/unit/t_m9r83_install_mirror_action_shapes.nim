## M9.R.83 provider-mode action-shape coverage for install mirror
## publication. This pins the emitted BuildActionDef, not source text.

import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_core
import repro_core/ambient_execution
import repro_test_support
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

when defined(linux) and defined(reproProviderMode):
  proc verifyLibexecMirror(custom, propagated: bool) =
    let scratch = createTempDir("repro-libexec-mirror-", "")
    defer: removeDir(scratch)
    let patchelf = findExe("patchelf", followSymlinks = false)
    require patchelf.len > 0
    let fixtures = graphArtifactPath("build/test-fixtures/install-mirror-runtime")
    requireBinary(fixtures / "probe", "reprobuild.test_fixtures.install_mirror_probe")
    requireBinary(fixtures / "librepro_mirror_fixture.so",
      "reprobuild.test_fixtures.install_mirror_library")
    let packageName = if custom: "customLibexecRuntime" & $propagated
      else: "typedLibexecRuntime"
    let projectRoot = scratch / packageName
    let staging = projectRoot / ".repro/build/from-source-custom" / packageName
    let installedUsr = staging / "install/usr"
    let inputBinary = installedUsr / "libexec/compiler/cc1-probe"
    let directMirror = scratch / "direct" / ".repro/output/install"
    let transitiveLib = scratch / "transitive" / ".repro/output/install/usr/lib"
    let library = transitiveLib / "librepro_mirror_fixture.so"
    createDir(inputBinary.parentDir)
    createDir(directMirror / "usr/lib")
    createDir(transitiveLib)
    if propagated:
      writeFile(directMirror / m9r30PropagatedManifestName,
        transitiveLib & "\n" & transitiveLib & "\n")
    copyFileWithPermissions(fixtures / "librepro_mirror_fixture.so", library)
    copyFileWithPermissions(fixtures / "probe", inputBinary)
    require fpUserExec in getFilePermissions(inputBinary)

    proc run(argv: seq[string]; cwd = ""): tuple[output: string, exitCode: int] =
      uncontrolledExecCmdEx(quoteShellCommand(argv), workingDir = cwd)

    require run(@[patchelf, "--remove-rpath", inputBinary]).exitCode == 0
    let interpreter = run(@[patchelf, "--print-interpreter", inputBinary])
    require interpreter.exitCode == 0

    let priorLd = getEnv("LD_LIBRARY_PATH")
    let priorLink = getEnv("LIBRARY_PATH")
    let priorCheck = getEnv("REPRO_M9R30_NEEDED_CHECK")
    let priorMode = getEnv(InstallMirrorModeEnvVar)
    defer:
      putEnv("LD_LIBRARY_PATH", priorLd)
      putEnv("LIBRARY_PATH", priorLink)
      putEnv("REPRO_M9R30_NEEDED_CHECK", priorCheck)
      putEnv(InstallMirrorModeEnvVar, priorMode)
    putEnv("LD_LIBRARY_PATH", "")
    putEnv("LIBRARY_PATH", interpreter.output.strip().parentDir)
    putEnv("REPRO_M9R30_NEEDED_CHECK", "1")
    putEnv(InstallMirrorModeEnvVar, "legacy")
    let unpatched = run(@[inputBinary])
    checkpoint unpatched.output
    require unpatched.exitCode != 0
    require "librepro_mirror_fixture.so" in unpatched.output
    putEnv("LD_LIBRARY_PATH", "")

    let pkg = PackageDef(packageName: packageName,
      sourceFile: projectRoot / "repro.nim")
    let fragment = buildPackageFragment(pkg, dummyRequest(projectRoot),
      proc() =
        registerVersion(packageName, DslVersionInfo(version: "1.0.0"))
        registerPackageDep(packageName, "runtime", "direct >=1")
        if custom:
          resetDslPortShellStateForPackage(packageName)
          let state = beginBuildBlock(packageName, "executable", "probe")
          try:
            shell "true"
          finally:
            endBuildBlock(state)
          synthesizeCustomShellBuildActions(packageName)
        else:
          let installEdge = buildAction(id = "fixture-install",
            call = inlineExecCall(@["sh", "-c", "true"], projectRoot),
            outputs = @[staging / "install.stamp"])
          emitInstallTreeMirror(installEdge, relativePath(staging, projectRoot),
            "install", packageName, "autotools"),
      includeDefault = false)
    let mirrorId = (if custom: "from-source-custom-mirror-" else: "install-mirror-") & packageName
    let mirror = findById(extractActions(fragment), mirrorId)
    let scriptPath = scratch / "mirror.sh"
    writeFile(scriptPath, inlineScriptOf(mirror))
    if not propagated:
      putEnv("LD_LIBRARY_PATH", transitiveLib)
    let mirrored = run(@["sh", scriptPath], projectRoot)
    checkpoint mirrored.output
    require mirrored.exitCode == 0
    let mirrorRoot = projectRoot / ".repro/output/install"
    let binary = mirrorRoot / "usr/libexec/compiler/cc1-probe"
    require fileExists(binary)
    putEnv("LD_LIBRARY_PATH", "")
    let executed = run(@[binary])
    checkpoint executed.output
    check executed.exitCode == 0
    let manifest = mirrorRoot / m9r30PropagatedManifestName
    require fileExists(manifest)
    check readFile(manifest).splitLines().count(transitiveLib) == 1
    check transitiveLib in run(@[patchelf, "--print-rpath", binary]).output.strip().split(':')

    removeFile(library)
    for output in mirror.outputs:
      if fileExists(output): removeFile(output)
    let rejected = run(@["sh", scriptPath], projectRoot)
    checkpoint rejected.output
    check rejected.exitCode == 75
    check "UNRESOLVED NEEDED" in rejected.output
    check "librepro_mirror_fixture.so" in rejected.output
    for output in mirror.outputs:
      check not fileExists(output)

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
      for toolName in InstallMirrorCoreToolNames:
        check toolName in mirror.toolIdentityRefs
      check "sed" in mirror.toolIdentityRefs
      check "chmod" in mirror.toolIdentityRefs
      check InstallMirrorPublishToolName in mirror.toolIdentityRefs
      when defined(linux):
        for toolName in ["find", "head", "od", "tr", "sort", "grep",
                         "dirname", "basename", "wc", "patchelf", "readlink",
                         "mktemp", "mv", "readelf"]:
          check toolName in mirror.toolIdentityRefs
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
        "\"; : > \"" & sidecar.replace("\\", "/") in script
      check "printf '%s\\n' 'platform=" & currentRealizationPlatformTag() &
        "' > \"" & sidecar.replace("\\", "/") & "\"; ;; esac" in script
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
          registerPackageDep(PackageName, "native", "nativeMirrorDep >=1")
          registerPackageDep(PackageName, "build", "buildMirrorDep >=2")
          registerPackageDep(PackageName, "runtime", "runtimeMirrorDep >=3")
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
      for shellAction in actions[0 .. 1]:
        for toolName in ["sh", "mkdir", "touch"]:
          check toolName in shellAction.toolIdentityRefs
      check mirror.deps == @["from-source-custom-shell-2-" & PackageName]
      for toolName in InstallMirrorCoreToolNames:
        check toolName in mirror.toolIdentityRefs
      check "sed" in mirror.toolIdentityRefs
      check InstallMirrorPublishToolName in mirror.toolIdentityRefs
      for toolName in typedInstallMirrorShellTools(PackageName):
        check toolName in mirror.toolIdentityRefs
      for dep in ["nativeMirrorDep", "buildMirrorDep", "runtimeMirrorDep"]:
        check dep in mirror.toolIdentityRefs
        check (scratch / dep / ".repro/output/install/usr/lib").replace("\\", "/") in script
        check (scratch / dep / ".repro/output/install" /
          m9r30PropagatedManifestName).replace("\\", "/") in script
      check (projectRoot / ".repro/output/install" /
        m9r30PropagatedManifestName).replace("\\", "/") in script
      check sidecar in mirror.outputs
      check InstallMirrorPublishToolName in script
      check InstallMirrorModeEnvVar in script
      check "hashed|hashed-with-legacy-fallback" in script
      check "--package \"custom-shell-recipe\"" in script
      check "--package \"" & PackageName & "\"" notin script
      check "--version \"8.3.0\"" in script
      check "*) mkdir -p \"" & parentDir(sidecar).replace("\\", "/") &
        "\"; : > \"" & sidecar.replace("\\", "/") in script
      check "printf '%s\\n' 'platform=" & currentRealizationPlatformTag() &
        "' > \"" & sidecar.replace("\\", "/") & "\"; ;; esac" in script
    else:
      check true

  when defined(linux) and defined(reproProviderMode):
    test "typed libexec closure executes and rejects missing libraries":
      verifyLibexecMirror(custom = false, propagated = true)

    test "custom libexec closure executes and rejects missing libraries":
      verifyLibexecMirror(custom = true, propagated = true)

    test "custom libexec resolves provisioned runtime libraries":
      verifyLibexecMirror(custom = true, propagated = false)

  test "distinct packages each get their own mirror gate":
    # The mirror gate is keyed per PACKAGE, not per process: two packages
    # realised in the same process must EACH emit their own
    # ``install-mirror-<package>`` action, while a repeat of the SAME
    # package must not emit a second one.
    #
    # Home of this case: it previously lived in
    # ``t_m9r14e_2_install_tree_mirror.nim``, which builds without
    # ``reproProviderMode``. There ``activeProviderProjectRoot()`` is the
    # empty string by construction, ``emitInstallTreeMirror`` early-returns
    # before touching the gate, and the case could assert nothing. It moved
    # here because this file already compiles in provider mode and drives
    # the gate through the real ``buildPackageFragment`` entry point.
    when defined(reproProviderMode):
      let scratch = getTempDir() / "m9r83-per-package-mirror-gate"
      if dirExists(scratch):
        removeDir(scratch)
      defer:
        if dirExists(scratch):
          removeDir(scratch)

      proc actionIdsFor(packageName: string): seq[string] =
        ## Realise ``packageName`` as its own fragment and return the ids
        ## of every action the fragment emitted.
        let projectRoot = scratch / packageName
        createDir(projectRoot)
        let pkg = PackageDef(
          packageName: packageName,
          sourceFile: projectRoot / "repro.nim",
          hasDevEnv: false,
          devEnvBodyHash: "",
          toolUses: @[])
        let fragment = buildPackageFragment(pkg, dummyRequest(projectRoot),
          proc() =
            registerVersion(packageName, DslVersionInfo(version: "1.0.0"))
            let installEdge = buildAction(
              id = "gate-install-" & packageName,
              call = inlineExecCall(@["sh", "-c", "true"], projectRoot),
              outputs = @[projectRoot / "build" / "dest" /
                ".install.stamp"],
              pool = "compile",
              toolIdentityRefs = @["sh"])
            emitInstallTreeMirror(installEdge, "build", "dest", packageName,
              "autotools"),
          includeDefault = false)
        for action in extractActions(fragment):
          result.add(action.id)

      let alphaIds = actionIdsFor("m9r83GatePkgAlpha")
      let betaIds = actionIdsFor("m9r83GatePkgBeta")
      let alphaRepeatIds = actionIdsFor("m9r83GatePkgAlpha")

      # Each package emitted ITS OWN mirror ...
      check "install-mirror-m9r83GatePkgAlpha" in alphaIds
      check "install-mirror-m9r83GatePkgBeta" in betaIds
      # ... and neither leaked into the other's fragment.
      check "install-mirror-m9r83GatePkgBeta" notin alphaIds
      check "install-mirror-m9r83GatePkgAlpha" notin betaIds
      # The gate state is process-wide, which is what makes the two
      # assertions above load-bearing: realising alpha a SECOND time
      # emits no further mirror. Were the gate keyed per process rather
      # than per package, beta would have been suppressed exactly like
      # this repeat is.
      check "gate-install-m9r83GatePkgAlpha" in alphaRepeatIds
      check "install-mirror-m9r83GatePkgAlpha" notin alphaRepeatIds
    else:
      check true

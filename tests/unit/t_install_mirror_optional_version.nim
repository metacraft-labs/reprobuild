import std/[os, strutils, tempfiles, unittest]

import repro_core
import repro_project_dsl
import repro_dsl_stdlib/types/package_result
import repro_standard_provider/conventions/from_source_custom

when not defined(reproProviderMode):
  {.error: "This test requires reproProviderMode".}

type MirrorKind = enum
  mkTyped, mkCustomDsl, mkCustomConvention

proc mirrorAction(root, packageName, version: string;
                  kind: MirrorKind): BuildActionDef =
  let projectRoot = root / packageName
  createDir(projectRoot)
  writeFile(projectRoot / "repro.nim", "package " & packageName &
    ":\n  executable probe:\n    discard\n  build:\n    discard\n")
  let pkg = PackageDef(packageName: packageName,
    sourceFile: projectRoot / "repro.nim")
  registerPackageDef(pkg)
  if version.len > 0:
    registerVersion(packageName, DslVersionInfo(version: version))
  let request = ProviderGraphRequest(kind: prkGraphInvocation,
    providerArtifactId: "optional-version", entryPointId: "test.entry",
    entryPointBodyHash: "test-body", reason: girExplicitUserRequest,
    arguments: projectRoot, namespace: "project")
  var fragment = buildPackageFragment(pkg, request,
    proc() =
      if kind == mkTyped:
        let install = buildAction(id = "install",
          call = inlineExecCall(@["sh", "-c", "true"], projectRoot),
          outputs = @[projectRoot / "build/install.stamp"])
        emitInstallTreeMirror(install, "build", "dest", packageName, "cmake")
      else:
        resetDslPortShellStateForPackage(packageName)
        let state = beginBuildBlock(packageName, "executable", "probe")
        try:
          shell "mkdir -p $out/bin"
          shell "printf probe > $out/bin/probe"
        finally:
          endBuildBlock(state)
        if kind == mkCustomDsl:
          synthesizeCustomShellBuildActions(packageName),
    includeDefault = false)
  if kind == mkCustomConvention:
    let convention = fromSourceCustomConvention()
    if not convention.recognize(projectRoot, request):
      raise newException(ValueError, "custom fixture not recognized")
    fragment = convention.emitFragment(projectRoot, request)
  let expectedId = (if kind == mkTyped: "install-mirror-"
                    else: "from-source-custom-mirror-") & packageName
  for node in fragment.nodes:
    if node.kind == gnkAction:
      let action = decodeBuildActionPayload(toBytes(node.payload))
      if action.id == expectedId:
        return action
  raise newException(ValueError, "missing mirror action: " & expectedId)

proc checkMirrorVersions(kind: MirrorKind) =
  let scratch = createTempDir("mirror-optional-version-", "")
  defer: removeDir(scratch)
  for version in ["", "1.0.0"]:
    let packageName = "optionalVersion" & $kind &
      (if version.len == 0: "Absent" else: "Present")
    let action = mirrorAction(scratch, packageName, version, kind)
    let sidecar = realizationInfoPath(scratch, packageName)
    var script = ""
    for argument in action.call.arguments:
      if argument.name == "argv":
        script = argument.encodedValue.split("\x1f")[2]
    check script.len > 0
    check action.outputs.len == (if version.len == 0: 1 else: 2)
    check (sidecar in action.outputs) == (version.len > 0)
    check (sidecar in script) == (version.len > 0)
    check (InstallMirrorPublishToolName in script) == (version.len > 0)
    if kind == mkCustomConvention:
      check (sidecar in action.declaredOutputs) == (version.len > 0)
    check latestRegisteredPackageVersion(packageName) == version

suite "install mirror optional package versions":
  test "typed mirror declares only the metadata it emits":
    checkMirrorVersions(mkTyped)
  test "DSL custom mirror declares only the metadata it emits":
    checkMirrorVersions(mkCustomDsl)
  test "standard custom convention declares only the metadata it emits":
    checkMirrorVersions(mkCustomConvention)

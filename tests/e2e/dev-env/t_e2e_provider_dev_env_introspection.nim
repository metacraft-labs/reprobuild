import std/[options, os, sequtils, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_provider_runtime

proc writeDevEnvFixture(dir: string) =
  createDir(dir)
  createDir(dir / "src")
  createDir(dir / "tools" / "bin")
  writeFile(dir / "dev-env-value.txt", "alpha\n")
  writeFile(dir / "src" / "main.nim", "echo \"fixture\"\n")
  writeFile(dir / "fixture_provider.nim",
    "import std/strutils\n" &
    "import repro_project_dsl\n\n" &
    "package fixture:\n" &
    "  uses:\n" &
    "    \"nim >=2.2 <3.0\"\n" &
    "  devEnv:\n" &
    "    activity \"default\"\n" &
    "    activity \"docs\"\n" &
    "    setEnv \"FIXTURE_MODE\", \"dev\"\n" &
    "    setEnv \"DOCS_MODE\", \"on\", activities = [\"docs\"]\n" &
    "    setEnv \"AUX_VALUE\", readDevEnvFile(\"dev-env-value.txt\").strip()\n" &
    "    prependPath \"PATH\", \"tools/bin\"\n" &
    "    useTool \"fixture-tool\", packageSelector = \"nim\", executableName = \"nim\"\n" &
    "    task \"build\", command = \"nim c src/main.nim\", description = \"Build fixture\"\n" &
    "    servicePlaceholder \"database\", metadata = \"placeholder\"\n" &
    "    diagnostic \"dev env ready\"\n")

proc compileFixtureProvider(projectRoot, outDir: string): ProviderCompileArtifact =
  let modulePath = projectRoot / "fixture_provider.nim"
  let interfacePath = outDir / "fixture-interface.rbsz"
  let stubPath = outDir / "fixture-interface.nim"
  let artifact = extractInterfaceFromModule(modulePath, interfacePath, stubPath,
    getCurrentDir())
  compileProviderBinary(
    modulePath,
    outDir / "fixture-provider",
    artifact.interfaceFingerprint,
    outDir / "fixture-provider-compile.rbsz",
    getCurrentDir())

proc providerConfig(provider: ProviderCompileArtifact; tempRoot,
                    workingDir: string): ProviderExecutionConfig =
  ProviderExecutionConfig(
    binaryPath: provider.outputBinaryPath,
    workingDir: workingDir,
    tempRoot: tempRoot / "provider-protocol-tmp")

proc providerArtifactId(provider: ProviderCompileArtifact): string =
  for b in provider.providerFingerprint.bytes:
    result.add(toHex(ord(b), 2).toLowerAscii())

proc findShellOp(devEnv: DevEnvResult; name: string): Option[DevEnvShellOp] =
  for op in devEnv.shellOps:
    if op.name == name:
      return some(op)
  none(DevEnvShellOp)

proc inputDigest(devEnv: DevEnvResult; identityTail: string): string =
  for input in devEnv.evaluationInputs:
    if input.identity.endsWith(identityTail):
      return input.digest
  ""

suite "e2e_provider_dev_env_introspection":
  test "e2e_provider_dev_env_introspection_fixture":
    let tempRoot = createTempDir("repro-m1-dev-env", "")
    defer: removeDir(tempRoot)
    let projectRoot = tempRoot / "project"
    let outDir = tempRoot / "out"
    writeDevEnvFixture(projectRoot)
    createDir(outDir)

    let provider = compileFixtureProvider(projectRoot, outDir)
    let result = invokeProviderDevEnvIntrospection(
      providerConfig(provider, tempRoot, getCurrentDir()),
      provider.providerArtifactId,
      projectRoot,
      activity = "default,docs",
      lockSliceId = "lock-m1")

    check result.schemaVersion == 1'u32
    check result.providerEntryPointId == "fixture.dev-env"
    check result.providerEntryPointBodyHash.len > 0
    check result.projectRoot == projectRoot
    check result.lockSliceId == "lock-m1"
    check result.selectedActivities == @["default", "docs"]
    check result.declaredActivities == @["default", "docs"]
    check result.shellOps.anyIt(it.kind == deskSetEnv and
      it.name == "FIXTURE_MODE" and it.value == "dev")
    check result.shellOps.anyIt(it.kind == deskSetEnv and
      it.name == "DOCS_MODE" and it.value == "on" and
      it.activityRequirements == @["docs"])
    check result.shellOps.anyIt(it.kind == deskSetEnv and
      it.name == "AUX_VALUE" and it.value == "alpha")
    check result.shellOps.anyIt(it.kind == deskPrependPath and
      it.name == "PATH" and it.value == "tools/bin")
    check result.toolRequirements.anyIt(it.logicalName == "fixture-tool" and
      it.packageSelector == "nim" and it.executableName == "nim")
    check result.toolRequirements.anyIt(it.logicalName == "nim" and
      it.packageSelector == "nim")
    check result.tasks.anyIt(it.name == "build" and
      it.command == "nim c src/main.nim")
    check result.services.anyIt(it.name == "database" and
      it.metadata == "placeholder")
    check result.diagnostics.anyIt(it.severity == dedsInfo and
      it.message == "dev env ready")
    check result.evaluationInputs.anyIt(it.kind == gevFileRead and
      it.identity.endsWith("fixture_provider.nim"))
    check result.evaluationInputs.anyIt(it.kind == gevFileRead and
      it.identity.endsWith("dev-env-value.txt"))
    check result.sourceFingerprints.anyIt(it.kind == "provider-source" and
      it.identity.endsWith("fixture_provider.nim") and it.digest.len > 0)
    check result.sourceFingerprints.anyIt(it.kind == "file-read" and
      it.identity.endsWith("dev-env-value.txt") and it.digest.len > 0)

  test "e2e_provider_dev_env_reads_are_observable":
    let tempRoot = createTempDir("repro-m1-dev-env-observable", "")
    defer: removeDir(tempRoot)
    let projectRoot = tempRoot / "project"
    let outDir = tempRoot / "out"
    writeDevEnvFixture(projectRoot)
    createDir(outDir)

    let provider = compileFixtureProvider(projectRoot, outDir)
    let config = providerConfig(provider, tempRoot, getCurrentDir())
    let first = invokeProviderDevEnvIntrospection(config,
      provider.providerArtifactId, projectRoot, activity = "default",
      lockSliceId = "lock-m1")
    writeFile(projectRoot / "dev-env-value.txt", "bravo\n")
    let second = invokeProviderDevEnvIntrospection(config,
      provider.providerArtifactId, projectRoot, activity = "default",
      lockSliceId = "lock-m1")

    check first.findShellOp("AUX_VALUE").get().value == "alpha"
    check second.findShellOp("AUX_VALUE").get().value == "bravo"
    check first.inputDigest("dev-env-value.txt").len > 0
    check second.inputDigest("dev-env-value.txt").len > 0
    check first.inputDigest("dev-env-value.txt") !=
      second.inputDigest("dev-env-value.txt")

import std/[options, os, osproc, sequtils, strutils, tempfiles, unittest]

import cbor
import repro_core
import repro_core/paths as corepaths
import repro_domain_types
import repro_hash
import repro_interface_artifacts
import repro_test_support

# Resolve the host's ``nim`` once at compile time so the test can spawn
# subprocesses by absolute path. ``command -v`` is POSIX-only; on
# Windows we fall back to ``where nim``. Both return the canonical
# executable path so the rest of the test works unchanged across
# platforms.
const ExpectedNimCompiler =
  when defined(windows):
    staticExec("where nim").splitLines()[0].strip()
  else:
    staticExec("command -v nim").strip()

type
  ThinConsumerEdge = object
    actionSpec: ActionSpec
    declaredInputs: seq[string]
    actionFingerprint: ContentDigest

proc runNim(args: openArray[string]; cwd = getCurrentDir()):
    tuple[code: int; output: string] =
  let res = runShell(shellCommand(@args), cwd)
  (code: res.code, output: res.output)

proc requireNimSuccess(args: openArray[string]; cwd = getCurrentDir()): string =
  let res = runNim(args, cwd)
  check res.code == 0
  if res.code != 0:
    checkpoint(res.output)
  res.output

proc requireNimFailure(args: openArray[string]; cwd = getCurrentDir()): string =
  let res = runNim(args, cwd)
  check res.code != 0
  res.output

proc pathFlags(paths: openArray[string]): seq[string] =
  for path in paths:
    result.add("--path:" & path)

proc writeProviderFixture(dir: string; formatType = "string"; helperSalt = "one") =
  createDir(dir)
  writeFile(dir / "private_dependency.nim",
    "const privateDependencyMarker* = \"private-dependency\"\n")
  writeFile(dir / "private_helper.nim",
    "import private_dependency\n\n" &
    "proc privateImplementationSalt*(): string =\n" &
    "  \"" & helperSalt & "-\" & privateDependencyMarker\n")
  writeFile(dir / "asset_pack_provider.nim",
    "when not defined(reproInterfaceMode):\n" &
    "  import private_helper\n\n" &
    "import repro_project_dsl\n\n" &
    "package assetPack:\n" &
    "  executable assetPackCli:\n" &
    "    name \"asset-pack\"\n" &
    "    cli:\n" &
    "      subcmd \"bundle\":\n" &
    "        pos inputs, seq[string], position = -1\n" &
    "        flag output, string, alias = \"-o\", required = true\n" &
    "        flag format, " & formatType & "\n" &
    "    build:\n" &
    "      discard privateImplementationSalt()\n\n" &
    "when isMainModule:\n" &
    "  when not defined(reproInterfaceMode):\n" &
    "    echo privateImplementationSalt()\n" &
    "  else:\n" &
    "    echo \"interface-mode\"\n")

proc writeThinConsumer(path: string; callText: string) =
  writeFile(path,
    "import repro_project_dsl\n" &
    "import asset_pack_interface\n\n" &
    "when isMainModule:\n" &
    "  let call = " & callText & "\n" &
    "  echo call.callIdentity\n")

proc writeSourceConsumer(path: string; callText: string) =
  writeFile(path,
    "import repro_project_dsl\n" &
    "import asset_pack_provider\n\n" &
    "when isMainModule:\n" &
    "  let call = " & callText & "\n" &
    "  echo call.callIdentity\n")

proc lastNonEmptyLine(output: string): string =
  for i in countdown(output.splitLines.len - 1, 0):
    let line = output.splitLines[i].strip()
    if line.len > 0:
      return line
  ""

proc stableIdFromDigest(digest: ContentDigest): StableId =
  var raw: array[16, byte]
  for i in 0 ..< raw.len:
    raw[i] = digest.bytes[i]
  stableId(raw)

proc addFramedText(payload: var string; value: string) =
  payload.add($value.len)
  payload.add(":")
  payload.add(value)
  payload.add("\n")

proc thinConsumerFingerprint(consumerPath, interfacePath: string;
                             interfaceFingerprint: ContentDigest;
                             command: openArray[string]): ContentDigest =
  var payload = ""
  payload.addFramedText("reprobuild.thinConsumerCheck.v1")
  payload.addFramedText(consumerPath)
  payload.addFramedText(readFile(consumerPath))
  payload.addFramedText(interfacePath)
  payload.addFramedText(toHex(interfaceFingerprint.bytes))
  for arg in command:
    payload.addFramedText(arg)
  blake3DomainDigest(toBytes(payload), hdActionFingerprint)

proc thinConsumerEdge(consumerPath, interfacePath: string;
                      interfaceFingerprint: ContentDigest;
                      command: openArray[string];
                      workDir: string): ThinConsumerEdge =
  var processArgs: seq[string] = @[]
  for i in 1 ..< command.len:
    processArgs.add(command[i])
  let fingerprint =
    thinConsumerFingerprint(consumerPath, interfacePath, interfaceFingerprint, command)
  ThinConsumerEdge(
    actionSpec: ActionSpec(
      actionId: stableIdFromDigest(fingerprint),
      process: directProcess(corepaths.normalizedPath(command[0]), processArgs,
        corepaths.normalizedPath(workDir)),
      dependencyPolicy: declaredOnlyPolicy(),
      metadata: cborMap([
        entry("kind", cborText("thinConsumerCheck")),
        entry("schema", cborUInt(1)),
        entry("interfaceFingerprint", cborText(toHex(interfaceFingerprint.bytes)))
      ])),
    declaredInputs: @[consumerPath, interfacePath],
    actionFingerprint: fingerprint)

when isNixSupported:
  suite "integration_project_interface_artifact_import_modes":
    test "interface artifacts, thin/source imports, and provider compile edge":
      let repoRoot = getCurrentDir()
      let dslPath = repoRoot / "libs" / "repro_project_dsl" / "src"
      let tempRoot = createTempDir("repro-m7-interface", "")
      defer: removeDir(tempRoot)

      let providerDir = tempRoot / "provider"
      let outDir = tempRoot / "out"
      let scratchDir = outDir / "scratch"
      let thinDir = tempRoot / "thin"
      let binDir = tempRoot / "bin"
      createDir(outDir)
      createDir(thinDir)
      createDir(binDir)

      writeProviderFixture(providerDir)

      let providerModule = providerDir / "asset_pack_provider.nim"
      let artifactPath = outDir / "asset_pack.rbsz"
      let stubPath = thinDir / "asset_pack_interface.nim"

      let artifact1 =
        extractInterfaceFromModule(providerModule, artifactPath, stubPath,
          repoRoot, scratchDir)

      check fileExists(artifactPath)
      check fileExists(stubPath)
      check dirExists(scratchDir / "m7-temp")
      check fileExists(artifactPath & ".inputs")
      check fileExists(artifactPath & ".inputs.meta")
      let raw = readFile(artifactPath)
      check raw.len > 12
      check raw[0 .. 3] == "RBSZ"
      check raw[0] != '{'
      check readInterfaceArtifact(artifactPath).interfaceFingerprint ==
        artifact1.interfaceFingerprint
      check artifact1.projectInterface.packageName == "assetPack"
      check artifact1.projectInterface.publicExecutables.len == 1
      check artifact1.projectInterface.publicExecutables[0].binaryName == "asset-pack"
      check artifact1.projectInterface.publicExecutables[0].commands[0].name == "bundle"
      check artifact1.projectInterface.publicExecutables[0].commands[0].
        providerEntrypointId == "assetPack.assetPackCli.bundle"
      check artifact1.projectInterface.publicSignatureDependencies.len == 0
      check artifact1.projectInterface.location.file.endsWith("asset_pack_provider.nim")

      let stubSource = readFile(stubPath)
      check stubSource.contains("proc bundle*")
      check stubSource.contains("inputs: seq[string]")
      check stubSource.contains("output: string")
      check stubSource.contains("format: string = \"\"")
      check not stubSource.contains("private_helper")
      check not stubSource.contains("private_dependency")
      check not stubSource.contains("asset_pack_provider")
      check not stubSource.contains("privateImplementationSalt")

      let thinConsumer = tempRoot / "thin_consumer.nim"
      let sourceConsumer = tempRoot / "source_consumer.nim"
      let callText =
        "assetPack.bundle(@[\"public/index.html\", \"public/app.css\"], " &
        "output = \"dist/site.tar\", format = \"tar\")"
      writeThinConsumer(thinConsumer, callText)
      writeSourceConsumer(sourceConsumer, callText)

      let thinCheckCommand = @["nim", "check"] & pathFlags([thinDir, dslPath]) &
        @["--nimcache:" & (tempRoot / "nimcache-thin-check"), thinConsumer]
      let thinEdge1 = thinConsumerEdge(thinConsumer, stubPath,
        artifact1.interfaceFingerprint, thinCheckCommand, repoRoot)
      check thinEdge1.actionSpec.process.executable.value == "nim"
      check thinEdge1.actionSpec.process.args.contains("check")
      check thinEdge1.declaredInputs.contains(thinConsumer)
      check thinEdge1.declaredInputs.contains(stubPath)
      check not thinEdge1.declaredInputs.anyIt(it.endsWith("private_helper.nim"))
      discard requireNimSuccess(thinCheckCommand)

      let badThinConsumer = tempRoot / "thin_private_reject.nim"
      writeFile(badThinConsumer,
        "import repro_project_dsl\n" &
        "import asset_pack_interface\n\n" &
        "discard privateImplementationSalt()\n")
      let badOutput = requireNimFailure(@["nim", "check"] & pathFlags([thinDir, dslPath]) &
        @["--nimcache:" & (tempRoot / "nimcache-thin-private"), badThinConsumer])
      check badOutput.contains("undeclared identifier")
      check badOutput.contains("privateImplementationSalt")

      let thinRunOut = requireNimSuccess(@["nim", "c", "-r", "--verbosity:0",
        "--hints:off"] & pathFlags([thinDir, dslPath]) &
        @["--nimcache:" & (tempRoot / "nimcache-thin-run"),
          "--out:" & (binDir / "thin-consumer"), thinConsumer])

      let sourceRunOut = requireNimSuccess(@["nim", "c", "-r", "--verbosity:0",
        "--hints:off"] & pathFlags([providerDir, dslPath]) &
        @["--nimcache:" & (tempRoot / "nimcache-source-run"),
          "--out:" & (binDir / "source-consumer"), sourceConsumer])
      check lastNonEmptyLine(thinRunOut) == lastNonEmptyLine(sourceRunOut)
      check lastNonEmptyLine(thinRunOut).contains(
        "assetPack|asset-pack|bundle|assetPack.assetPackCli.bundle")

      let providerArtifactPath = outDir / "asset_pack_provider.rbsz"
      let provider1 = compileProviderBinary(
        providerModule,
        binDir / "asset-pack-provider-one",
        artifact1.interfaceFingerprint,
        providerArtifactPath,
        repoRoot,
        scratchDir)
      check fileExists(provider1.outputBinaryPath)
      check provider1.compilerCommand.len > 0
      check ExpectedNimCompiler.len > 0
      check provider1.compilerCommand[0] == ExpectedNimCompiler
      check provider1.compilerCommand.contains("c")
      check provider1.compilerCommand.anyIt(
        it.startsWith("--nimcache:" & (scratchDir / "nimcache-provider")))
      check provider1.compileEdge.actionSpec.process.kind == ckDirect
      check provider1.compileEdge.actionSpec.process.executable.value ==
        ExpectedNimCompiler
      check provider1.compileEdge.actionSpec.process.args.contains("c")
      check provider1.compileEdge.actionSpec.process.cwd.value == repoRoot
      check provider1.compileEdge.declaredOutputs == @[provider1.outputBinaryPath]
      check provider1.inputSources.anyIt(it.endsWith("asset_pack_provider.nim"))
      check provider1.inputSources.anyIt(it.endsWith("private_helper.nim"))
      check provider1.inputSources.anyIt(it.endsWith("private_dependency.nim"))
      check provider1.compileEdge.declaredInputs.anyIt(
        it.endsWith("asset_pack_provider.nim"))
      check provider1.compileEdge.declaredInputs.anyIt(it.endsWith("private_helper.nim"))
      check provider1.compileEdge.declaredInputs.anyIt(
        it.endsWith("private_dependency.nim"))
      check provider1.interfaceFingerprint == artifact1.interfaceFingerprint
      check provider1.providerFingerprint.algorithm == haBlake3_256
      check provider1.compileEdge.actionFingerprint.algorithm == haBlake3_256
      check provider1.outputBinaryFingerprint.algorithm == haBlake3_256
      check provider1.executionResult.exitCode == 0
      check fileExists(providerArtifactPath & ".inputs")
      let providerRead = readProviderCompileArtifact(providerArtifactPath)
      check providerRead.providerFingerprint == provider1.providerFingerprint
      check providerRead.compileEdge.actionFingerprint ==
        provider1.compileEdge.actionFingerprint
      check providerRead.compileEdge.declaredOutputs == @[provider1.outputBinaryPath]
      let freshProvider = readFreshProviderCompileArtifact(providerArtifactPath,
        providerModule, provider1.outputBinaryPath, artifact1.interfaceFingerprint)
      check freshProvider.isSome
      check fileExists(providerArtifactPath & ".inputs")
      # Provider-compile freshness tracks the *imported* source closure (see
      # `discoverNimSources` in repro_interface_artifacts); a sibling .nim file
      # that no module imports has no effect on the compiled provider binary
      # and therefore must NOT invalidate the cache. Mutating an imported
      # private source (private_dependency.nim, reached via private_helper.nim)
      # is the canonical implementation-edit that does invalidate, per
      # `Project-Interface-Artifacts-And-Import-Modes.md`: "changing a private
      # helper used only by implementation does not recompile downstream
      # projects" — but it must still re-compile the provider itself.
      let priorPrivateDependency =
        readFile(providerDir / "private_dependency.nim")
      writeFile(providerDir / "private_dependency.nim",
        "const privateDependencyMarker* = \"private-dependency-edited\"\n")
      check readFreshProviderCompileArtifact(providerArtifactPath, providerModule,
        provider1.outputBinaryPath, artifact1.interfaceFingerprint).isNone
      writeFile(providerDir / "private_dependency.nim", priorPrivateDependency)
      # Sanity check: restoring the imported source bytes brings the cache
      # back to a fresh state (no other inputs changed).
      check readFreshProviderCompileArtifact(providerArtifactPath, providerModule,
        provider1.outputBinaryPath, artifact1.interfaceFingerprint).isSome
      writeFile(provider1.outputBinaryPath, "corrupt provider binary\n")
      check readFreshProviderCompileArtifact(providerArtifactPath, providerModule,
        provider1.outputBinaryPath, artifact1.interfaceFingerprint).isNone

      writeProviderFixture(providerDir, helperSalt = "two")
      let artifactAfterPrivateEdit =
        extractInterfaceFromModule(providerModule, outDir / "asset_pack_private_edit.rbsz",
          stubPath, repoRoot, scratchDir)
      check artifactAfterPrivateEdit.interfaceFingerprint == artifact1.interfaceFingerprint

      let thinEdgeAfterPrivateEdit = thinConsumerEdge(thinConsumer, stubPath,
        artifactAfterPrivateEdit.interfaceFingerprint, thinCheckCommand, repoRoot)
      check thinEdgeAfterPrivateEdit.actionFingerprint == thinEdge1.actionFingerprint
      check thinEdgeAfterPrivateEdit.actionSpec.actionId == thinEdge1.actionSpec.actionId
      discard requireNimSuccess(thinCheckCommand)

      let provider2 = compileProviderBinary(
        providerModule,
        binDir / "asset-pack-provider-two",
        artifactAfterPrivateEdit.interfaceFingerprint,
        outDir / "asset_pack_provider_private_edit.rbsz",
        repoRoot,
        scratchDir)
      check provider2.providerFingerprint != provider1.providerFingerprint
      check provider2.compileEdge.actionFingerprint !=
        provider1.compileEdge.actionFingerprint
      check provider2.compileEdge.actionSpec.actionId !=
        provider1.compileEdge.actionSpec.actionId

      writeProviderFixture(providerDir, formatType = "int", helperSalt = "two")
      let artifactAfterPublicEdit =
        extractInterfaceFromModule(providerModule, outDir / "asset_pack_public_edit.rbsz",
          stubPath, repoRoot, scratchDir)
      check artifactAfterPublicEdit.interfaceFingerprint != artifact1.interfaceFingerprint
      check readFile(stubPath).contains("format: int = 0")
      let thinEdgeAfterPublicEdit = thinConsumerEdge(thinConsumer, stubPath,
        artifactAfterPublicEdit.interfaceFingerprint, thinCheckCommand, repoRoot)
      check thinEdgeAfterPublicEdit.actionFingerprint != thinEdge1.actionFingerprint
      check thinEdgeAfterPublicEdit.actionSpec.actionId != thinEdge1.actionSpec.actionId
      let oldStringOutput = requireNimFailure(thinCheckCommand)
      check oldStringOutput.contains("type mismatch")

      let intConsumer = tempRoot / "thin_int_after_public_edit.nim"
      writeThinConsumer(intConsumer,
        "assetPack.bundle(@[\"public/index.html\"], output = \"dist/site.tar\", " &
        "format = 9)")
      discard requireNimSuccess(@["nim", "check"] &
        pathFlags([thinDir, dslPath]) &
        @["--nimcache:" & (tempRoot / "nimcache-public-edit-new"),
          intConsumer])

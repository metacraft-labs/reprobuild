import std/[json, options, os, sequtils, strutils, tempfiles, unittest]

import repro_dev_env_artifacts
import repro_interface_artifacts
import repro_provider_runtime
import ssz_serialization

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

proc writePolicyPathFixture(dir: string) =
  ## A recipe whose `uses:` block carries one top-level entry and one entry
  ## nested two policy levels deep, so the artifact's tool profiles hold both
  ## an empty and a non-empty `uses:` nesting path.
  createDir(dir)
  writeFile(dir / "fixture_provider.nim",
    "import repro_project_dsl\n\n" &
    "package fixture:\n" &
    "  uses:\n" &
    "    \"nim >=2.2 <3.0\"\n" &
    "    lint:\n" &
    "      strict:\n" &
    "        \"python >=3.10\"\n" &
    "  devEnv:\n" &
    "    activity \"default\"\n")

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

proc bytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc findShellOp(ops: openArray[DevEnvShellOp]; name: string): Option[DevEnvShellOp] =
  for op in ops:
    if op.name == name:
      return some(op)
  none(DevEnvShellOp)

proc generatedArtifact(tempRoot: string): tuple[path: string; artifact: DevEnvArtifact] =
  let projectRoot = tempRoot / "project"
  let outDir = tempRoot / "out"
  writeDevEnvFixture(projectRoot)
  createDir(outDir)
  let provider = compileFixtureProvider(projectRoot, outDir)
  let artifact = produceDevEnvArtifact(
    providerConfig(provider, tempRoot, getCurrentDir()),
    provider.providerArtifactId,
    projectRoot,
    activity = "default,docs",
    lockSliceId = "lock-m2")
  let artifactPath = outDir / "fixture-dev-env.rbde"
  writeDevEnvArtifact(artifactPath, artifact)
  (path: artifactPath, artifact: artifact)

suite "integration_dev_env_artifact":
  test "integration_dev_env_artifact_ssz_round_trip":
    let tempRoot = createTempDir("repro-m2-dev-env-artifact", "")
    defer: removeDir(tempRoot)

    let produced = generatedArtifact(tempRoot)
    let raw = readFile(produced.path)
    check raw.len > 4
    check raw[0] == 'R'
    check raw[1] == 'B'
    check raw[2] == 'D'
    check raw[3] == 'E'
    check raw[0] != '{'

    let decoded = readDevEnvArtifact(produced.path)
    check decoded.schemaVersion == DevEnvArtifactSchemaVersion
    check decoded.providerEntryPointName == "fixture.dev-env"
    check decoded.selectedActivities == @["default", "docs"]
    check decoded.shellOps.findShellOp("AUX_VALUE").get().value == "alpha"
    check decoded.toolProfiles.anyIt(it.logicalName == "fixture-tool")
    check decoded.tasks.anyIt(it.name == "build" and
      it.command == "nim c src/main.nim")
    check decoded.services.anyIt(it.name == "database")
    check decoded.sourceFingerprints.anyIt(it.kind == "file-read" and
      it.identity.endsWith("dev-env-value.txt"))

    let payload = devEnvArtifactSszPayload(bytes(raw))
    let wire = SSZ.decode(payload, DevEnvArtifactSsz)
    check SSZ.encode(wire) == payload
    check decodeDevEnvArtifactSszPayload(payload).artifactId == decoded.artifactId
    check canonicalDevEnvArtifactSszPayload(decoded) == payload

    let encodedAgain = encodeDevEnvArtifact(decoded)
    check encodedAgain == bytes(raw)
    let jsonView = toJsonInspection(decoded)
    check jsonView[0] == '{'
    check jsonView.contains("\"kind\":\"DevEnvArtifact\"")
    check jsonView.contains("\"shellOps\"")
    check jsonView.contains("\"tasks\"")

    var corrupt = encodedAgain
    corrupt[corrupt.len - 1] = corrupt[corrupt.len - 1] xor 0xff'u8
    expect DevEnvArtifactCodecError:
      discard decodeDevEnvArtifact(corrupt)

    var truncatedPayload = payload
    truncatedPayload.setLen(truncatedPayload.len - 1)
    expect DevEnvArtifactCodecError:
      discard decodeDevEnvArtifactSszPayload(truncatedPayload)

    var corruptPayload = payload
    corruptPayload[corruptPayload.len - 1] = corruptPayload[^1] xor 0xff'u8
    expect DevEnvArtifactCodecError:
      discard decodeDevEnvArtifactSszPayload(corruptPayload)

  test "integration_dev_env_artifact_navigator_hot_path":
    let tempRoot = createTempDir("repro-m2-dev-env-navigator", "")
    defer: removeDir(tempRoot)

    let produced = generatedArtifact(tempRoot)
    var stats: DevEnvNavigatorStats
    let ops = shellOpsFromNavigatorFile(produced.path, stats)
    check ops.findShellOp("AUX_VALUE").get().value == "alpha"
    check ops.findShellOp("FIXTURE_MODE").get().value == "dev"
    check stats.shellOpRecordsDecoded == ops.len
    check stats.taskRecordsDecoded == 0
    check stats.serviceRecordsDecoded == 0
    check stats.payloadHeaderBytesRead > 0
    check stats.payloadHeaderBytesRead == fixedPortionSize(DevEnvArtifactSsz)
    check stats.shellOpsSectionStart >= stats.payloadHeaderBytesRead
    check stats.shellOpsSectionEnd <= stats.tasksSectionStart
    check stats.maxDecodedPayloadOffset == stats.shellOpsSectionEnd
    check stats.maxDecodedPayloadOffset <= stats.tasksSectionStart
    check stats.maxDecodedPayloadOffset < stats.payloadBytesHashed

    let decoded = readDevEnvArtifact(produced.path)
    check decoded.tasks.len > 0
    check decoded.services.len > 0

  test "integration_dev_env_artifact_tool_profile_carries_policy_path_not_prefix":
    ## Regression: reprobuild-pm issue
    ## 2026-09-24-dev-env-realized-prefix-holds-the-policy-path. The tool
    ## profile field the JSON view printed as `realizedPrefix` held the
    ## `uses:` nesting path, so every top-level tool showed an empty
    ## "prefix" and readers concluded nothing had been realized. The stored
    ## artifact is content-addressed and cannot know a host-specific prefix
    ## (realization happens at activation), so the field must be named for
    ## what it carries. The checks go through parsed JSON so this test
    ## compiles against both the old and the new field name and fails at
    ## runtime on the old one.
    let tempRoot = createTempDir("repro-dev-env-policy-path", "")
    defer: removeDir(tempRoot)

    let projectRoot = tempRoot / "project"
    let outDir = tempRoot / "out"
    writePolicyPathFixture(projectRoot)
    createDir(outDir)
    let provider = compileFixtureProvider(projectRoot, outDir)
    let artifact = produceDevEnvArtifact(
      providerConfig(provider, tempRoot, getCurrentDir()),
      provider.providerArtifactId,
      projectRoot,
      activity = "default")
    let artifactPath = outDir / "policy-path-dev-env.rbde"
    writeDevEnvArtifact(artifactPath, artifact)

    # Inspect what a reader of `repro shell --print-env=json` sees: the JSON
    # view of the artifact after it round-trips through storage.
    let view = parseJson(toJsonInspection(readDevEnvArtifact(artifactPath)))
    let profiles = view["toolProfiles"]
    check profiles.kind == JArray
    checkpoint("toolProfiles: " & $profiles)

    var policyPathBySelector: seq[(string, string)] = @[]
    for profile in profiles:
      check not profile.hasKey("realizedPrefix")
      check profile.hasKey("policyPath")
      if profile.hasKey("policyPath"):
        policyPathBySelector.add((profile["packageIdentity"].getStr(),
          profile["policyPath"].getStr()))
    checkpoint("policyPath by packageIdentity: " & $policyPathBySelector)

    let topLevel = policyPathBySelector.filterIt(it[0].startsWith("nim"))
    let nested = policyPathBySelector.filterIt(it[0].startsWith("python"))
    check topLevel.len == 1
    check nested.len == 1
    if topLevel.len == 1:
      check topLevel[0][1] == ""
    if nested.len == 1:
      check nested[0][1] == "lint:strict"

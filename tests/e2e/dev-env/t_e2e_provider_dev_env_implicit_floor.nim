## Windows-dev-env M1: a recipe with a ``uses:`` toolchain floor but NO
## explicit ``devEnv:`` block must still expose a ``gpkDevEnvIntrospection``
## entry point, and introspection must return the toolchain-floor
## environment (the ``uses:`` tools as tool requirements) with no extra
## dev-env body (no shell ops / tasks / services). This is the implicit
## floor-derived dev-env — the same machinery an explicit ``devEnv:``
## recipe uses, just with an empty "extra" body.

import std/[os, sequtils, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_provider_runtime

proc writeUsesOnlyFixture(dir: string) =
  ## A ``uses:``-only recipe (mirrors nim-acp's shape): a toolchain floor
  ## declared via ``uses:`` and a library, but no ``devEnv:`` block.
  createDir(dir)
  createDir(dir / "src")
  writeFile(dir / "src" / "main.nim", "echo \"fixture\"\n")
  writeFile(dir / "floor_provider.nim",
    "import repro_project_dsl\n\n" &
    "package floorfixture:\n" &
    "  defaultToolProvisioning \"path\"\n" &
    "  uses:\n" &
    "    \"nim >=2.2 <3.0\"\n" &
    "    \"gcc >=12\"\n" &
    "  library floorfixture\n" &
    # A minimal ``build:`` block so the DSL emits the provider serve loop
    # (a recipe with neither ``build:`` nor ``devEnv:`` produces no
    # provider at all). This mirrors real uses:-only leaf recipes such as
    # nim-acp, which always carry a ``build:`` body. The block declares no
    # actions — the point is the implicit floor dev-env, not the graph.
    "  build:\n" &
    "    discard\n")

proc compileFloorProvider(projectRoot, outDir: string): ProviderCompileArtifact =
  let modulePath = projectRoot / "floor_provider.nim"
  let interfacePath = outDir / "floor-interface.rbsz"
  let stubPath = outDir / "floor-interface.nim"
  let artifact = extractInterfaceFromModule(modulePath, interfacePath, stubPath,
    getCurrentDir())
  compileProviderBinary(
    modulePath,
    outDir / "floor-provider",
    artifact.interfaceFingerprint,
    outDir / "floor-provider-compile.rbsz",
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

suite "e2e_provider_dev_env_implicit_floor":
  test "uses_only_manifest_exposes_dev_env_introspection":
    ## Acceptance (1): a ``uses:``-only package's compiled provider
    ## manifest exposes a ``gpkDevEnvIntrospection`` entry point.
    let tempRoot = createTempDir("repro-m1-implicit-floor", "")
    defer: removeDir(tempRoot)
    let projectRoot = tempRoot / "project"
    let outDir = tempRoot / "out"
    writeUsesOnlyFixture(projectRoot)
    createDir(outDir)

    let provider = compileFloorProvider(projectRoot, outDir)
    let manifest = readProviderManifest(
      providerConfig(provider, tempRoot, getCurrentDir()),
      provider.providerArtifactId)

    let devEnvEntries = manifest.entryPoints.filterIt(
      it.kind == gpkDevEnvIntrospection)
    check devEnvEntries.len == 1
    check devEnvEntries[0].id == "floorfixture.dev-env"
    # The implicit entry carries a deterministic, floor-derived body hash.
    check devEnvEntries[0].bodyHash.len > 0

  test "uses_only_introspection_returns_toolchain_floor":
    ## Acceptance (2): dev-env introspection on a ``uses:``-only recipe
    ## resolves and returns the toolchain-floor env — the ``uses:`` tools
    ## as tool requirements — with NO extra dev-env body (no shell ops /
    ## tasks / services, because there is no ``devEnv:`` block).
    let tempRoot = createTempDir("repro-m1-implicit-floor-introspect", "")
    defer: removeDir(tempRoot)
    let projectRoot = tempRoot / "project"
    let outDir = tempRoot / "out"
    writeUsesOnlyFixture(projectRoot)
    createDir(outDir)

    let provider = compileFloorProvider(projectRoot, outDir)
    let result = invokeProviderDevEnvIntrospection(
      providerConfig(provider, tempRoot, getCurrentDir()),
      provider.providerArtifactId,
      projectRoot,
      activity = "default",
      lockSliceId = "lock-m1-floor")

    check result.schemaVersion == 1'u32
    check result.providerEntryPointId == "floorfixture.dev-env"
    check result.providerEntryPointBodyHash.len > 0
    check result.projectRoot == projectRoot
    check result.lockSliceId == "lock-m1-floor"
    check result.selectedActivities == @["default"]
    # The toolchain floor flows through as tool requirements — the same
    # append an explicit ``devEnv:`` recipe gets.
    check result.toolRequirements.anyIt(it.logicalName == "nim" and
      it.packageSelector == "nim")
    check result.toolRequirements.anyIt(it.logicalName == "gcc" and
      it.packageSelector == "gcc")
    # No explicit ``devEnv:`` body means no extra tasks / services and no
    # extra declared activities beyond the implicit "default".
    check result.tasks.len == 0
    check result.services.len == 0
    check result.declaredActivities.len == 0
    # The provider source is still recorded as an evaluation input / source
    # fingerprint for cache-keying, same as the explicit path.
    check result.evaluationInputs.anyIt(it.kind == gevFileRead and
      it.identity.endsWith("floor_provider.nim"))
    check result.sourceFingerprints.anyIt(it.kind == "provider-source" and
      it.identity.endsWith("floor_provider.nim") and it.digest.len > 0)

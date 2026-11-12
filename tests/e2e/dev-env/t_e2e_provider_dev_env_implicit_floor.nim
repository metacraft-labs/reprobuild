## Windows-dev-env M1: a recipe with a ``uses:`` toolchain floor but NO
## explicit ``devEnv:`` block must still expose a ``gpkDevEnvIntrospection``
## entry point, and introspection must return the toolchain-floor
## environment (the ``uses:`` tools as tool requirements) with no extra
## dev-env body (no shell ops / tasks / services). This is the implicit
## floor-derived dev-env — the same machinery an explicit ``devEnv:``
## recipe uses, just with an empty "extra" body.
##
## The entry point is answered whatever bodies the recipe has: a recipe
## with no ``build:`` and no ``devEnv:`` body is still a provider binary
## that serves dev-env introspection, and it refuses a graph request
## rather than report an empty graph.

import std/[os, sequtils, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_provider_runtime

const
  usesOnlyTail = ""
    ## The genuinely ``uses:``-only shape: a toolchain floor and nothing
    ## else. No ``build:`` and no ``devEnv:`` body, so the provider
    ## dispatcher must exist without either.
  buildControlTail = "  build:\n    discard\n"
    ## Control: an empty ``build:`` body alongside the floor.
  devEnvControlTail = "  devEnv:\n    discard\n"
    ## Control: an explicit, empty ``devEnv:`` body alongside the floor.

proc writeFloorFixture(dir: string; tail = usesOnlyTail) =
  ## A recipe declaring a toolchain floor via ``uses:`` and a library
  ## (mirrors nim-acp's shape), followed by ``tail`` -- empty for the
  ## ``uses:``-only case, or one of the control bodies.
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
    tail)

proc writeBuildOnlyFixture(dir: string) =
  ## A build-only recipe: no ``uses:`` and no ``devEnv:`` (the shape of
  ## reprobuild-pm issue 2026-11-12-repro-exec-on-a-recipe-without-devenv).
  createDir(dir)
  writeFile(dir / "floor_provider.nim",
    "import repro_project_dsl\n\n" &
    "package floorfixture:\n" &
    "  build:\n" &
    "    discard\n")

proc writeBodilessFixture(dir: string) =
  ## A recipe with no toolchain floor and no ``build:`` or ``devEnv:``
  ## body: a package declaration and a library, nothing else.
  createDir(dir)
  writeFile(dir / "floor_provider.nim",
    "import repro_project_dsl\n\n" &
    "package floorfixture:\n" &
    "  library floorfixture\n")

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

proc toolchainFloorMismatches(devEnv: DevEnvResult;
                              projectRoot: string): seq[string] =
  ## The properties of the floor-derived environment that ``devEnv`` does
  ## NOT have, by name; empty when it is the expected environment.
  template expect(name: string; cond: bool) =
    if not cond: result.add(name)
  expect "schemaVersion", devEnv.schemaVersion == 1'u32
  expect "providerEntryPointId",
    devEnv.providerEntryPointId == "floorfixture.dev-env"
  expect "providerEntryPointBodyHash",
    devEnv.providerEntryPointBodyHash.len > 0
  expect "projectRoot", devEnv.projectRoot == projectRoot
  expect "lockSliceId", devEnv.lockSliceId == "lock-m1-floor"
  expect "selectedActivities", devEnv.selectedActivities == @["default"]
  # The toolchain floor flows through as tool requirements -- the same
  # append an explicit ``devEnv:`` recipe gets.
  expect "toolRequirements has nim", devEnv.toolRequirements.anyIt(
    it.logicalName == "nim" and it.packageSelector == "nim")
  expect "toolRequirements has gcc", devEnv.toolRequirements.anyIt(
    it.logicalName == "gcc" and it.packageSelector == "gcc")
  # No ``devEnv:`` body with content means no extra tasks / services and
  # no extra declared activities beyond the implicit "default".
  expect "no tasks", devEnv.tasks.len == 0
  expect "no services", devEnv.services.len == 0
  expect "no declaredActivities", devEnv.declaredActivities.len == 0
  # The provider source is still recorded as an evaluation input / source
  # fingerprint for cache-keying.
  expect "provider source read", devEnv.evaluationInputs.anyIt(
    it.kind == gevFileRead and it.identity.endsWith("floor_provider.nim"))
  expect "provider source fingerprint", devEnv.sourceFingerprints.anyIt(
    it.kind == "provider-source" and
    it.identity.endsWith("floor_provider.nim") and it.digest.len > 0)

proc introspectFloorFixture(tempRoot, tail: string): DevEnvResult =
  let projectRoot = tempRoot / "project"
  let outDir = tempRoot / "out"
  writeFloorFixture(projectRoot, tail)
  createDir(outDir)
  let provider = compileFloorProvider(projectRoot, outDir)
  invokeProviderDevEnvIntrospection(
    providerConfig(provider, tempRoot, getCurrentDir()),
    provider.providerArtifactId,
    projectRoot,
    activity = "default",
    lockSliceId = "lock-m1-floor")

suite "e2e_provider_dev_env_implicit_floor":
  test "uses_only_manifest_exposes_dev_env_introspection":
    ## Acceptance (1): a ``uses:``-only package's compiled provider
    ## manifest exposes a ``gpkDevEnvIntrospection`` entry point.
    let tempRoot = createTempDir("repro-m1-implicit-floor", "")
    defer: removeDir(tempRoot)
    let projectRoot = tempRoot / "project"
    let outDir = tempRoot / "out"
    writeFloorFixture(projectRoot)
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
    ## -- no ``build:`` and no ``devEnv:`` body -- reaches the provider's
    ## dispatcher and returns the toolchain-floor env: the ``uses:`` tools
    ## as tool requirements, with no shell ops / tasks / services.
    let tempRoot = createTempDir("repro-m1-implicit-floor-introspect", "")
    defer: removeDir(tempRoot)
    let devEnv = introspectFloorFixture(tempRoot, usesOnlyTail)
    check toolchainFloorMismatches(devEnv, tempRoot / "project") ==
      newSeq[string]()

  test "build_and_explicit_dev_env_controls_return_the_same_floor":
    ## Controls for the ``uses:``-only case: adding an empty ``build:``
    ## body, or an explicit empty ``devEnv:`` body, yields the same
    ## floor-derived environment through the same entry point.
    for tail in [buildControlTail, devEnvControlTail]:
      let tempRoot = createTempDir("repro-m1-implicit-floor-control", "")
      defer: removeDir(tempRoot)
      let devEnv = introspectFloorFixture(tempRoot, tail)
      check toolchainFloorMismatches(devEnv, tempRoot / "project") ==
        newSeq[string]()

  test "bodiless_recipe_exposes_base_environment_and_refuses_a_graph":
    ## A recipe with no floor and no body at all answers dev-env
    ## introspection with the base environment, and refuses a graph
    ## request by naming the package instead of reporting an empty graph.
    let tempRoot = createTempDir("repro-bodiless-dev-env", "")
    defer: removeDir(tempRoot)
    let projectRoot = tempRoot / "project"
    let outDir = tempRoot / "out"
    writeBodilessFixture(projectRoot)
    createDir(outDir)

    let provider = compileFloorProvider(projectRoot, outDir)
    let config = providerConfig(provider, tempRoot, getCurrentDir())
    let devEnv = invokeProviderDevEnvIntrospection(config,
      provider.providerArtifactId, projectRoot,
      activity = "default", lockSliceId = "lock-bodiless")
    check devEnv.providerEntryPointId == "floorfixture.dev-env"
    check devEnv.selectedActivities == @["default"]
    check devEnv.toolRequirements.len == 0
    check devEnv.tasks.len == 0
    check devEnv.services.len == 0

    let manifest = readProviderManifest(config, provider.providerArtifactId)
    let roots = manifest.entryPoints.filterIt(
      it.kind != gpkDevEnvIntrospection)
    check roots.len == 1
    var refusal = ""
    try:
      discard invokeProviderEntryPoint(config, ProviderGraphRequest(
        kind: prkGraphInvocation,
        providerArtifactId: provider.providerArtifactId,
        entryPointId: roots[0].id,
        entryPointBodyHash: roots[0].bodyHash,
        reason: girExplicitUserRequest,
        arguments: projectRoot,
        lockSliceId: "lock-bodiless"))
    except ProviderRuntimeError as err:
      refusal = err.msg
    check "package floorfixture declares no build: body" in refusal

  test "build_only_recipe_exposes_base_environment":
    ## A recipe with neither ``uses:`` nor ``devEnv:`` still exposes
    ## dev-env introspection, and it resolves to the base environment:
    ## no tool requirements, tasks, services or activities.
    let tempRoot = createTempDir("repro-build-only-dev-env", "")
    defer: removeDir(tempRoot)
    let projectRoot = tempRoot / "project"
    let outDir = tempRoot / "out"
    writeBuildOnlyFixture(projectRoot)
    createDir(outDir)

    let provider = compileFloorProvider(projectRoot, outDir)
    let config = providerConfig(provider, tempRoot, getCurrentDir())
    let manifest = readProviderManifest(config, provider.providerArtifactId)
    let entries = manifest.entryPoints.filterIt(
      it.kind == gpkDevEnvIntrospection)
    check entries.len == 1
    check entries[0].bodyHash.len > 0

    let result = invokeProviderDevEnvIntrospection(config,
      provider.providerArtifactId, projectRoot,
      activity = "default", lockSliceId = "lock-build-only")
    check result.providerEntryPointId == "floorfixture.dev-env"
    check result.selectedActivities == @["default"]
    check result.toolRequirements.len == 0
    check result.tasks.len == 0
    check result.services.len == 0

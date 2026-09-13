import std/[algorithm, options, os, tempfiles, unittest]

import repro_core
import repro_hash
import repro_interface_artifacts

suite "provider source discovery":
  test "unimported siblings and build directories do not enter the closure":
    let root = createTempDir("repro-source-discovery-", "")
    defer: removeDir(root)
    let recipe = root / "repro.nim"
    writeFile(recipe, "discard\n")
    let before = discoverNimSources(recipe)
    writeFile(root / "unused.nim", "const unused = true\n")
    writeFile(root / "unused.nims", "echo \"unused\"\n")
    createDir(root / "build")
    createDir(root / "src")
    writeFile(root / "src" / "generated.nim", "discard\n")
    check before == @[recipe]
    check discoverNimSources(recipe) == before

  test "a recipe edit adds its newly imported transitive sources":
    let root = createTempDir("repro-source-import-", "")
    defer: removeDir(root)
    let recipe = root / "repro.nim"
    let helper = root / "helper.nim"
    let nested = root / "private" / "detail.nim"
    createDir(root / "private")
    writeFile(recipe, "discard\n")
    writeFile(helper, "import private/detail\n")
    writeFile(nested, "const value = true\n")
    check discoverNimSources(recipe) == @[recipe]
    writeFile(recipe, "import helper\n")
    var expected = @[recipe, helper, nested]
    expected.sort()
    check discoverNimSources(recipe) == expected

  test "legacy freshness retains non-imported Nim payload coverage":
    let root = createTempDir("repro-source-legacy-", "")
    defer: removeDir(root)
    let project = root / "project"
    let work = root / "work"
    createDir(project)
    createDir(work)
    let recipe = project / "repro.nim"
    let payload = project / "payload.nim"
    let binary = root / "provider"
    let artifact = root / "provider.rbsz"
    writeFile(recipe, "const value = staticRead(\"payload.nim\")\n")
    writeFile(payload, "alpha\n")
    writeFile(binary, "provider containing alpha")
    let fingerprint = casDigest(toBytes("legacy-source-interface"))
    let plan = providerCompilePlan(recipe, binary, fingerprint, work,
      includeSiblingSources = true)
    check payload in plan.inputSources
    writeProviderCompileArtifact(artifact, ProviderCompileArtifact(
      inputSources: plan.inputSources, outputBinaryPath: plan.outputBinaryPath,
      compilerCommand: plan.compilerCommand, compileEdge: plan.compileEdge,
      interfaceFingerprint: fingerprint, providerFingerprint: plan.providerFingerprint,
      outputBinaryFingerprint: casDigest(toBytes(readFile(binary))),
      executionResult: ProviderCompileExecutionResult(exitCode: 0)))
    check readFreshProviderCompileArtifact(artifact, recipe, binary,
      fingerprint, work).isSome
    writeFile(payload, "bravo changed\n")
    check readFreshProviderCompileArtifact(artifact, recipe, binary,
      fingerprint, work).isNone

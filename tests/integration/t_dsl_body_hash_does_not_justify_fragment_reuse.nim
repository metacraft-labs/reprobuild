## The premise of reprobuild-pm
## issues/2026-11-12-reusing-fragments-by-body-hash-is-unsound-and-production-doesnt-use-symbodyhash.md,
## measured on the REAL frontend, and the engine's answer to it.
##
## The spec used to let the engine keep a stored fragment across a provider
## change when the entry point id and body hash were unchanged. The body
## hashes the DSL ships are not closure-complete: the project root's is the
## constant `<package>.build.v1`, and a `foreach` body's is a digest of the
## body's UNTYPED SYNTAX (`liftForeachStatements` in `macros_b.nim`), which
## covers no callee. So two recipes that differ only in a helper proc the
## body calls compile to providers whose manifests carry IDENTICAL root and
## foreach body hashes, yet emit different graphs.
##
## This test compiles both variants through the product path
## (`extractInterfaceFromModule` + `compileProviderBinary`), reads their
## manifests, and checks that premise first. It then refreshes one store
## with the first provider and the next with the second, and requires the
## second refresh to re-produce every fragment -- the graph afterwards is the
## second variant's, not a stale copy of the first's. That holds both under
## each provider's own artifact id and under ONE shared id, the case where
## nothing but the binary-bound provider-source record on each fragment tells
## the two providers apart.
##
## No mocks: the providers are real DSL recipes compiled by the product
## compile, driven through the real provider protocol.

import std/[os, sequtils, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_provider_runtime

const PackageName = "bodyHashProbe"

proc writeRecipe(projectRoot, outputDir: string) =
  ## The two variants differ ONLY in the value the helper proc returns. The
  ## `foreach` body, and everything else in the `build:` block, is
  ## byte-identical, so its syntax-based body hash is too.
  createDir(projectRoot / "items")
  writeFile(projectRoot / "items" / "alpha.txt", "alpha\n")
  writeFile(projectRoot / "items" / "beta.txt", "beta\n")
  writeFile(projectRoot / "repro.nim",
    "import std/os\n" &
    "import repro_project_dsl\n\n" &
    "proc outputDir(): string = \"" & outputDir & "\"\n\n" &
    "package " & PackageName & ":\n" &
    "  build:\n" &
    "    foreach item in dirListing(\"items\"):\n" &
    "      let name = splitFile(item).name\n" &
    "      fs.writeText(actionId = \"item-\" & name,\n" &
    "        output = outputDir() & \"/\" & name & \".txt\",\n" &
    "        text = name & \"\\n\")\n")

proc compileRecipe(projectRoot, outDir: string): ProviderCompileArtifact =
  createDir(outDir)
  let modulePath = projectRoot / "repro.nim"
  let artifact = extractInterfaceFromModule(modulePath,
    outDir / "interface.rbsz", outDir / "interface.nim", getCurrentDir())
  compileProviderBinary(modulePath, outDir / "provider",
    artifact.interfaceFingerprint, outDir / "provider-compile.rbsz",
    getCurrentDir())

proc artifactIdOf(provider: ProviderCompileArtifact): string =
  for b in provider.providerFingerprint.bytes:
    result.add(toHex(ord(b), 2).toLowerAscii())

proc manifestOf(provider: ProviderCompileArtifact; tempRoot: string):
    ProviderManifest =
  readProviderManifest(ProviderExecutionConfig(
    binaryPath: provider.outputBinaryPath, workingDir: getCurrentDir(),
    tempRoot: tempRoot / "protocol-tmp"), artifactIdOf(provider))

proc bodyHashes(manifest: ProviderManifest):
    seq[tuple[id: string; kind: GraphEntryPointKind; hash: string]] =
  for descriptor in manifest.entryPoints:
    if descriptor.kind in {gpkProjectRoot, gpkStructuralIteratorBody}:
      result.add((id: descriptor.id, kind: descriptor.kind,
        hash: descriptor.bodyHash))

proc refresh(provider: ProviderCompileArtifact; artifactId, store,
             projectRoot: string): ProviderRefreshReport =
  refreshProviderGraph(RefreshConfig(
    storeRoot: store,
    providerBinaryPath: provider.outputBinaryPath,
    providerArtifactId: artifactId,
    rootEntryPointId: PackageName & ".root",
    rootArguments: projectRoot,
    namespace: "project",
    lockSliceId: "lock-v1",
    activity: "build",
    providerWorkingDir: projectRoot))

proc memberInvocations(report: ProviderRefreshReport): int =
  report.invoked.countIt(it.entryPointId.startsWith(PackageName & ".foreach."))

proc graphMentions(snapshot: ProviderGraphSnapshot; text: string): bool =
  for fragment in snapshot.fragments:
    for node in fragment.nodes:
      if text in node.payload:
        return true
    for claim in fragment.effectClaims:
      if text in claim.identity or text in claim.payload:
        return true
  false

suite "a DSL body hash does not justify fragment reuse":
  test "two recipes with identical body hashes get each provider's own graph":
    let tempRoot = createTempDir("repro-body-hash-reuse", "")
    defer: removeDir(tempRoot)
    let projectV1 = tempRoot / "v1" / "project"
    let projectV2 = tempRoot / "v2" / "project"
    writeRecipe(projectV1, "public")
    writeRecipe(projectV2, "generated")
    let providerV1 = compileRecipe(projectV1, tempRoot / "v1" / "out")
    let providerV2 = compileRecipe(projectV2, tempRoot / "v2" / "out")
    let idV1 = artifactIdOf(providerV1)
    let idV2 = artifactIdOf(providerV2)

    # THE PREMISE. The two providers are different builds of different
    # recipes, yet every root and foreach body hash in their manifests is
    # the same, so an "unchanged id/body hash pair" cannot tell them apart.
    check idV1 != idV2
    check fileContentDigest(providerV1.outputBinaryPath) !=
      fileContentDigest(providerV2.outputBinaryPath)
    let hashesV1 = bodyHashes(manifestOf(providerV1, tempRoot))
    let hashesV2 = bodyHashes(manifestOf(providerV2, tempRoot))
    checkpoint("v1 body hashes: " & $hashesV1)
    checkpoint("v2 body hashes: " & $hashesV2)
    check hashesV1.anyIt(it.kind == gpkProjectRoot and
      it.hash == PackageName & ".build.v1")
    check hashesV1.anyIt(it.kind == gpkStructuralIteratorBody)
    check hashesV1 == hashesV2

    # Both variants are refreshed against ONE project tree (v1's), so the
    # stored fragments' ids, arguments and inputs coincide as well and the
    # provider is the only thing that differs.
    for (label, secondId) in [("own artifact ids", idV2),
                              ("one shared artifact id", idV1)]:
      checkpoint(label)
      let store = tempRoot / ("store-" & label.replace(' ', '-'))
      let cold = refresh(providerV1, idV1, store, projectV1)
      check memberInvocations(cold) == 2
      check graphMentions(cold.snapshot, "public/alpha.txt")
      check not graphMentions(cold.snapshot, "generated/alpha.txt")

      # The control: the same provider again reuses everything, so the
      # re-production below is caused by the provider change.
      let warm = refresh(providerV1, idV1, store, projectV1)
      check warm.invoked.len == 0

      let second = refresh(providerV2, secondId, store, projectV1)
      checkpoint("invoked: " & $second.invoked.mapIt(it.entryPointId & " " &
        it.arguments))
      check second.invoked.anyIt(it.entryPointId == PackageName & ".root")
      check memberInvocations(second) == 2
      check graphMentions(second.snapshot, "generated/alpha.txt")
      check graphMentions(second.snapshot, "generated/beta.txt")
      check not graphMentions(second.snapshot, "public/alpha.txt")
      check not graphMentions(second.snapshot, "public/beta.txt")
      let digestV2 = fileContentDigest(providerV2.outputBinaryPath)
      for fragment in loadProviderGraphSnapshot(store).fragments:
        let sources = fragment.evaluationInputs.filterIt(
          it.kind == gevProviderSource)
        check sources.len == 1
        check sources.allIt(it.identity == secondId and it.digest == digestV2)

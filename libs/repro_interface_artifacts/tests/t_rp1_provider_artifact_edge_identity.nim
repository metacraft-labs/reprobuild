## RP1 (Project-Provider-Runtime-Protocol.milestones.org) — provider-binary
## compilation as a content-addressed build edge.
##
## These are HERMETIC identity tests: they exercise the v1-named
## ``ProviderArtifactId`` / ``ProviderCompileActionKey`` computations
## (Provider-Runtime-Protocol-v1.md §1) against real on-disk source trees
## WITHOUT invoking the (slow) Nim provider compile. The compile-materializes
## + cache-HIT behaviour on the real engine edge is covered separately by
## ``t_rp1_provider_compile_edge_materializes`` (registered with a real
## ``nim`` provider compile) — here we prove the KEY semantics that make the
## edge a correct build-graph edge:
##
##   1. Stable key: recomputing the ProviderArtifactId / ActionKey over the
##      same source yields the SAME digest (⇒ a rebuild is a cache HIT).
##   2. Non-vacuous invalidation: changing a keyed input (source body, a
##      public dependency interface fingerprint, or the frontend runtime
##      identity) changes the key (⇒ a forced rebuild).
##   3. Sharing: two DISTINCT consumers resolving the SAME dependency version
##      compute the SAME ProviderArtifactId ⇒ they bind the SAME cached
##      artifact (built once, not per-consumer).

import std/[os, unittest]

import repro_interface_artifacts
import repro_core
import repro_hash

proc digestFromText(text: string): ContentDigest =
  blake3DomainDigest(toBytes(text), hdActionFingerprint)

proc writeProject(root: string; body: string): string =
  ## Materialize a minimal single-file provider project and return its
  ## module path. ``discoverNimSources`` walks the project root, so the
  ## file must physically exist for the identity procs to read it.
  createDir(extendedPath(root))
  let modulePath = root / "reprobuild.nim"
  writeFile(extendedPath(modulePath), body)
  modulePath

let scratch = getTempDir() / "rp1-provider-identity-" & $getCurrentProcessId()
removeDir(extendedPath(scratch))
createDir(extendedPath(scratch))

# A representative small project source and a fixed interface fingerprint
# (the identity procs treat it as an opaque input).
const projectBody = """
import repro

package "widget":
  build:
    discard
"""
let ifaceFp = digestFromText("widget.interface.v1")

suite "RP1 provider-artifact-edge identity":

  test "ProviderArtifactId is stable across recomputation (cache HIT)":
    let root = scratch / "stable"
    let modulePath = writeProject(root, projectBody)
    let sources = discoverNimSources(modulePath)
    let idA = computeProviderArtifactId(sources, ifaceFp,
      publicDependencyInterfaceFingerprints = @["dep-a@1.0"],
      workDir = root)
    let idB = computeProviderArtifactId(sources, ifaceFp,
      publicDependencyInterfaceFingerprints = @["dep-a@1.0"],
      workDir = root)
    check idA == idB
    # The action key is likewise stable, so the engine edge is a cache HIT.
    let keyA = computeProviderCompileActionKey(idA, sources, sources)
    let keyB = computeProviderCompileActionKey(idB, sources, sources)
    check keyA == keyB

  test "editing the provider source body re-keys the artifact (rebuild)":
    let root = scratch / "srcedit"
    let modulePath = writeProject(root, projectBody)
    let sources = discoverNimSources(modulePath)
    let before = computeProviderArtifactId(sources, ifaceFp, workDir = root)
    # A material source edit (add a build action) must move the id.
    writeFile(extendedPath(modulePath), projectBody & "\n# changed body\n")
    let after = computeProviderArtifactId(sources, ifaceFp, workDir = root)
    check before != after
    # And the compile action key moves with it.
    check computeProviderCompileActionKey(before, sources, sources) !=
      computeProviderCompileActionKey(after, sources, sources)

  test "changing a public dependency interface fingerprint re-keys (rebuild)":
    let root = scratch / "depfp"
    let modulePath = writeProject(root, projectBody)
    let sources = discoverNimSources(modulePath)
    let v1 = computeProviderArtifactId(sources, ifaceFp,
      publicDependencyInterfaceFingerprints = @["dep-a@1.0"], workDir = root)
    let v2 = computeProviderArtifactId(sources, ifaceFp,
      publicDependencyInterfaceFingerprints = @["dep-a@2.0"], workDir = root)
    check v1 != v2

  test "changing the project interface fingerprint re-keys (public signature)":
    let root = scratch / "ifacefp"
    let modulePath = writeProject(root, projectBody)
    let sources = discoverNimSources(modulePath)
    let a = computeProviderArtifactId(sources, ifaceFp, workDir = root)
    let b = computeProviderArtifactId(sources,
      digestFromText("widget.interface.v2"), workDir = root)
    check a != b

  test "changing provider compile options re-keys the artifact":
    let root = scratch / "opts"
    let modulePath = writeProject(root, projectBody)
    let sources = discoverNimSources(modulePath)
    let a = computeProviderArtifactId(sources, ifaceFp,
      providerCompileOptions = @["--define:reproProviderMode"], workDir = root)
    let b = computeProviderArtifactId(sources, ifaceFp,
      providerCompileOptions = @["--define:reproProviderMode", "-d:release"],
      workDir = root)
    check a != b

  test "ProviderCompileActionKey is keyed by nim compiler identity":
    let root = scratch / "compilerid"
    let modulePath = writeProject(root, projectBody)
    let sources = discoverNimSources(modulePath)
    let id = computeProviderArtifactId(sources, ifaceFp, workDir = root)
    let key = computeProviderCompileActionKey(id, sources, sources)
    # nimCompilerIdentity contributes a non-empty compiler banner/path.
    check nimCompilerIdentity().len > 0
    # A different artifact id under the same compiler yields a different key.
    let otherId = computeProviderArtifactId(sources,
      digestFromText("other"), workDir = root)
    check key != computeProviderCompileActionKey(otherId, sources, sources)

  test "SHARING: two consumers of the same dependency version converge":
    # Two DISTINCT consumer project trees whose byte-identical provider
    # source resolves the SAME dependency version compute the SAME
    # ProviderArtifactId ⇒ they bind the SAME cached artifact (built once).
    let consumerA = scratch / "consumerA"
    let consumerB = scratch / "consumerB"
    let moduleA = writeProject(consumerA, projectBody)
    let moduleB = writeProject(consumerB, projectBody)
    let sourcesA = discoverNimSources(moduleA)
    let sourcesB = discoverNimSources(moduleB)
    let depFps = @["libcore@3.4.1"]
    # projectSourceSemanticIdentity is content-addressed (path-normalized on
    # content, not absolute path), so identical source ⇒ identical semantic
    # identity across the two distinct roots.
    check projectSourceSemanticIdentity(sourcesA) ==
      projectSourceSemanticIdentity(sourcesB)
    let idA = computeProviderArtifactId(sourcesA, ifaceFp,
      publicDependencyInterfaceFingerprints = depFps, workDir = consumerA)
    let idB = computeProviderArtifactId(sourcesB, ifaceFp,
      publicDependencyInterfaceFingerprints = depFps, workDir = consumerB)
    check idA == idB

  test "SHARING breaks when the resolved dependency version differs":
    # The negative of the sharing property: a consumer that resolves a
    # DIFFERENT dependency version must NOT share the artifact.
    let consumerA = scratch / "shareA"
    let consumerB = scratch / "shareB"
    let moduleA = writeProject(consumerA, projectBody)
    let moduleB = writeProject(consumerB, projectBody)
    let sourcesA = discoverNimSources(moduleA)
    let sourcesB = discoverNimSources(moduleB)
    let idA = computeProviderArtifactId(sourcesA, ifaceFp,
      publicDependencyInterfaceFingerprints = @["libcore@3.4.1"],
      workDir = consumerA)
    let idB = computeProviderArtifactId(sourcesB, ifaceFp,
      publicDependencyInterfaceFingerprints = @["libcore@3.5.0"],
      workDir = consumerB)
    check idA != idB

removeDir(extendedPath(scratch))

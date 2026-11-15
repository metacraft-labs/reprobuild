import std/[os, tempfiles, unittest]

import repro_provider_runtime

const Artifact = "provider-artifact"

proc boundFragment(binary: string;
                   extra: openArray[GraphEvaluationInput] = []):
    StoredGraphFragment =
  ## A fragment as ``executePlan`` stores a root: bound to the binary, and
  ## recording the provider source that produced it.
  result = StoredGraphFragment(evaluationInputs: @[fileReadInput(binary),
    providerSourceInput(Artifact, fileContentDigest(binary))])
  for input in extra:
    result.evaluationInputs.add(input)

proc childFragment(source: openArray[GraphEvaluationInput]):
    StoredGraphFragment =
  ## A child fragment: no binary binding of its own, only its source record.
  StoredGraphFragment(evaluationInputs: @source)

suite "provider snapshot binary binding":
  test "legacy snapshots cannot answer a binary freshness check":
    let root = createTempDir("provider-snapshot-legacy", "")
    defer: removeDir(root)
    let binary = root / "provider"
    writeFile(binary, "alpha")
    let snapshot = ProviderGraphSnapshot(providerArtifactId: Artifact,
      fragments: @[StoredGraphFragment()])
    check not providerSnapshotBinaryFresh(snapshot, binary)

  test "changed and missing binaries invalidate the snapshot":
    let root = createTempDir("provider-snapshot-binary", "")
    defer: removeDir(root)
    let binary = root / "provider"
    writeFile(binary, "alpha")
    let snapshot = ProviderGraphSnapshot(providerArtifactId: Artifact,
      fragments: @[boundFragment(binary)])
    check providerSnapshotBinaryFresh(snapshot, binary)
    writeFile(binary, "bravo")
    check not providerSnapshotBinaryFresh(snapshot, binary)
    removeFile(binary)
    check not providerSnapshotBinaryFresh(snapshot, binary)

  test "a matching binding cannot hide a conflicting binding":
    let root = createTempDir("provider-snapshot-conflict", "")
    defer: removeDir(root)
    let binary = root / "provider"
    writeFile(binary, "alpha")
    let old = fileReadInput(binary)
    writeFile(binary, "bravo")
    let current = fileReadInput(binary)
    for inputs in [@[old, current], @[current, old]]:
      let snapshot = ProviderGraphSnapshot(providerArtifactId: Artifact,
        fragments: @[StoredGraphFragment(evaluationInputs: inputs &
          @[providerSourceInput(Artifact, fileContentDigest(binary))])])
      check not providerSnapshotBinaryFresh(snapshot, binary)

  test "every fragment must record the current provider source":
    ## Reprobuild-pm issue 2026-11-12 (reusing fragments by body hash is
    ## unsound): a child fragment carries no binary binding, so its
    ## provider-source record is the only thing that ties it to the
    ## provider that produced it. A child that lacks one, or names another
    ## artifact or another binary, makes the snapshot not reusable even
    ## though the root's binding is fresh.
    let root = createTempDir("provider-snapshot-source", "")
    defer: removeDir(root)
    let binary = root / "provider"
    writeFile(binary, "alpha")
    let digest = fileContentDigest(binary)
    let current = providerSourceInput(Artifact, digest)
    check current.kind == gevProviderSource
    check current.identity == Artifact
    check current.digest == digest
    check current.digest == fileReadInput(binary).digest

    # The control: root and child both carry the current record.
    check providerSnapshotBinaryFresh(ProviderGraphSnapshot(
      providerArtifactId: Artifact,
      fragments: @[boundFragment(binary), childFragment([current])]), binary)

    for child in [
        childFragment([]),
        childFragment([providerSourceInput("another-artifact", digest)]),
        childFragment([providerSourceInput(Artifact, "another-binary")]),
        childFragment([current, providerSourceInput(Artifact, "another-binary")])]:
      check not providerSnapshotBinaryFresh(ProviderGraphSnapshot(
        providerArtifactId: Artifact,
        fragments: @[boundFragment(binary), child]), binary)

    # The record names the SNAPSHOT's artifact, so a snapshot of another
    # artifact cannot borrow a record that names this one.
    check not providerSnapshotBinaryFresh(ProviderGraphSnapshot(
      providerArtifactId: "another-artifact",
      fragments: @[boundFragment(binary), childFragment([current])]), binary)

    # The source record alone is not the binary binding.
    check not providerSnapshotBinaryFresh(ProviderGraphSnapshot(
      providerArtifactId: Artifact,
      fragments: @[childFragment([current])]), binary)

import std/[os, tempfiles, unittest]

import repro_provider_runtime

suite "provider snapshot binary binding":
  test "legacy snapshots cannot answer a binary freshness check":
    let root = createTempDir("provider-snapshot-legacy", "")
    defer: removeDir(root)
    let binary = root / "provider"
    writeFile(binary, "alpha")
    let snapshot = ProviderGraphSnapshot(fragments: @[StoredGraphFragment()])
    check not providerSnapshotBinaryFresh(snapshot, binary)

  test "changed and missing binaries invalidate the snapshot":
    let root = createTempDir("provider-snapshot-binary", "")
    defer: removeDir(root)
    let binary = root / "provider"
    writeFile(binary, "alpha")
    let snapshot = ProviderGraphSnapshot(fragments: @[
      StoredGraphFragment(evaluationInputs: @[fileReadInput(binary)])])
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
      let snapshot = ProviderGraphSnapshot(fragments: @[
        StoredGraphFragment(evaluationInputs: inputs)])
      check not providerSnapshotBinaryFresh(snapshot, binary)

## Provider graph filesystem inputs are watch evidence even when no selected
## action reads those directories. The public-resource watch e2e exercises the
## real nested-addition regression; these cases cover the extraction boundary
## and persisted-snapshot route without a compiler or watcher timing dependency.
## No mocks: actual filesystem input constructors, temporary files/directories,
## and the provider snapshot's production disk codec are used here.

import std/[os, tempfiles, unittest]

import repro_cli_support
import repro_provider_runtime

suite "provider evaluation watch inputs":
  test "file reads and nested enumerations survive the cached snapshot":
    let root = createTempDir("provider-watch-inputs", "")
    defer: removeDir(root)
    let publicRoot = root / "public"
    let nestedRoot = publicRoot / "shared"
    createDir(nestedRoot)
    let existingFile = nestedRoot / "existing.svg"
    writeFile(existingFile, "existing resource\n")
    let snapshot = ProviderGraphSnapshot(fragments: @[
      StoredGraphFragment(evaluationInputs: @[
        fileReadInput(existingFile),
        directoryEnumerationInput(publicRoot, "", "")]),
      StoredGraphFragment(evaluationInputs: @[
        directoryEnumerationInput(nestedRoot, "", "")])])
    let expected = @[existingFile, publicRoot, nestedRoot]
    check providerEvaluationInputPaths(snapshot) == expected

    let storeRoot = root / "provider-graph"
    saveProviderGraphSnapshot(storeRoot, snapshot)
    let cached = loadProviderGraphSnapshot(storeRoot)
    check cached.fragments.len == 2
    check providerEvaluationInputPaths(cached) == expected

  test "non-filesystem identities and empty paths are not watch paths":
    var fragment = StoredGraphFragment()
    for kind in GraphEvaluationInputKind:
      fragment.evaluationInputs.add(GraphEvaluationInput(
        kind: kind,
        identity: if kind in {gevFileRead, gevDirectoryEnumeration}: ""
                  else: "not-a-filesystem-path"))
    let snapshot = ProviderGraphSnapshot(fragments: @[fragment])
    check providerEvaluationInputPaths(snapshot).len == 0
    check providerEvaluationInputPaths(ProviderGraphSnapshot()).len == 0

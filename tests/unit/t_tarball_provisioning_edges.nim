## Tarball realization is a build-graph edge, and an archive's extractor is a
## provisioned package reached through a DEPENDENCY EDGE of it.
##
## Dependency-Provisioning-In-Build-Graph.md sections 2-4. What is asserted:
##
##   * graph shape -- an archive that needs 7-Zip or zstd yields the
##     extractor's provisioning edge FIRST, and the tool's edge names it in
##     `deps` and takes its receipt as a declared input; an archive the OS
##     tools read (tar.gz, zip, raw, msi) yields a single edge. On Windows
##     the extractor edge is a tarball edge pinned to the stdlib catalog; on
##     POSIX it is a Nix provisioning edge;
##   * the edge is `bakForeignProvision` with provisioner `"tarball"`, a
##     declared network fetch of exactly the pinned URLs;
##   * the action cache serves a repeat realization -- the edge is not
##     re-executed;
##   * a changed pin invalidates: the SAME edge (same id, same receipt path)
##     misses and re-executes, its receipt names the new prefix, and a
##     consumer edge that reads the receipt re-executes after it;
##   * a receipt whose prefix was deleted is re-realized rather than trusted;
##   * the engine refuses a provisioner it has no executor for, by name.
##
## No mocks: the archives are real local files (`file://` URLs, `raw`
## archives, so no extractor is involved in the cache half), realized into a
## real temporary tool store through the real engine.

import std/[json, os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_interface_artifacts
import repro_tool_profiles

proc writeRawTool(dir, name, body: string): tuple[url, sha256: string] =
  createDir(dir)
  let path = dir / name
  writeFile(path, body)
  (url: "file://" & path.replace('\\', '/'), sha256: fileSha256Hex(path))

proc rawUse(selector, url, sha256: string): InterfaceToolUse =
  result = InterfaceToolUse(rawConstraint: "edgefixture",
    packageSelector: selector, executableName: "edgefixture")
  result.tarballProvisioning = @[InterfaceTarballProvisioning(
    packageName: "edgefixture", url: url, sha256: sha256,
    archiveType: "raw", executablePath: "bin/edgefixture.cmd",
    packageId: selector, lockIdentity: "tarball:" & selector & ":" & sha256)]

proc archiveUse(archiveType: string): InterfaceToolUse =
  ## A use whose archive type decides its extractor. Never realized, so the
  ## URL need not resolve.
  result = InterfaceToolUse(rawConstraint: "shapefixture",
    packageSelector: "shapefixture@1.0", executableName: "shapefixture")
  result.tarballProvisioning = @[InterfaceTarballProvisioning(
    packageName: "shapefixture",
    url: "https://example.invalid/shapefixture." & archiveType,
    sha256: repeat("ab", 32), archiveType: archiveType,
    executablePath: "bin/shapefixture", packageId: "shapefixture@1.0")]

proc actionById(edges: ProvisioningEdges; id: string): BuildAction =
  for action in edges.actions:
    if action.id == id:
      return action
  raise newException(KeyError, "no edge " & id)

proc resultFor(run: BuildRunResult; id: string): ActionResult =
  for item in run.results:
    if item.id == id:
      return item
  raise newException(KeyError, "no result for " & id)

suite "tarball provisioning edges":
  putEnv("REPRO_CACHE_DISABLE", "1")
  let tempRoot = createTempDir("repro-provision-edges-", "")
  let storeRoot = tempRoot / "store"

  test "a 7z archive depends on the 7-Zip provisioning edge":
    let edges = tarballProvisioningEdges(archiveUse("7z.exe"), storeRoot)
    check edges.actions.len == 2
    let extractor = edges.actions[0]
    let root = edges.actions[^1]
    check root.id == edges.rootId
    check edges.rootReceipt in root.outputs
    check extractor.kind == bakForeignProvision
    check root.kind == bakForeignProvision
    check root.argv[0] == TarballProvisionerName
    # The extractor precedes its consumer: named as a dependency, and its
    # receipt is a declared input, so re-realizing it invalidates the root.
    check extractor.id in root.deps
    check extractor.outputs[0] in root.inputs
    when defined(windows):
      check extractor.argv == @[TarballProvisionerName, "7zip@26.01"]
      let spec = parseJson(extractor.builtinText)
      # The MSI, then the standalone decoder as a pinned alternative.
      check spec["plans"].len == 2
      check spec["plans"][0]["archiveType"].getStr() == "msi"
      check spec["plans"][1]["archiveType"].getStr() == "raw"
      check extractor.deps.len == 0
    else:
      check extractor.argv[0] == "nix"
      check extractor.argv[1].endsWith("#_7zz")

  test "a tar.zst or conda archive depends on the zstd provisioning edge":
    for archiveType in ["tar.zst", "pkg.tar.zst", "conda"]:
      let edges = tarballProvisioningEdges(archiveUse(archiveType), storeRoot)
      check edges.actions.len == 2
      let extractor = edges.actions[0]
      check extractor.id in edges.actions[^1].deps
      when defined(windows):
        check extractor.argv == @[TarballProvisionerName, "zstd@1.5.6"]
        # zstd's own archive is a zip, which the OS extracts: no further edge.
        check extractor.deps.len == 0
      else:
        check extractor.argv[0] == "nix"
        check extractor.argv[1].endsWith("#zstd")

  test "an archive the OS tools read has no extractor edge":
    for archiveType in ["tar.gz", "tar.xz", "zip", "raw"]:
      let edges = tarballProvisioningEdges(archiveUse(archiveType), storeRoot)
      check edges.actions.len == 1
      check edges.actions[0].deps.len == 0

  test "the edge is a declared fetch of exactly its pinned URLs":
    var use = archiveUse("tar.gz")
    use.tarballProvisioning[0].mirrors = @["https://mirror.invalid/x.tar.gz"]
    let root = tarballProvisioningEdges(use, storeRoot).actions[0]
    check root.networkMode == netFetch
    check root.netDestinations == @[
      "https://example.invalid/shapefixture.tar.gz",
      "https://mirror.invalid/x.tar.gz"]
    check root.cacheable

  test "the action cache serves a repeat; a changed pin invalidates":
    let v1 = writeRawTool(tempRoot / "v1", "edgefixture.cmd", "@echo v1\r\n")
    let v2 = writeRawTool(tempRoot / "v2", "edgefixture.cmd", "@echo v2\r\n")
    let useV1 = rawUse("edgefixture@1.0", v1.url, v1.sha256)
    let useV2 = rawUse("edgefixture@1.0", v2.url, v2.sha256)
    let edgesV1 = tarballProvisioningEdges(useV1, storeRoot)
    let edgesV2 = tarballProvisioningEdges(useV2, storeRoot)
    # A re-pin is the SAME edge with a different fingerprint, so consumers
    # keep reading one receipt path whose content changes.
    check edgesV1.rootId == edgesV2.rootId
    check edgesV1.rootReceipt == edgesV2.rootReceipt
    check edgesV1.actions[0].weakFingerprint != edgesV2.actions[0].weakFingerprint

    # A consumer edge downstream of the provisioning edge: it copies the
    # receipt, so its output says which realization it last saw.
    let consumerOut = tempRoot / "consumer" / "seen.receipt"
    proc withConsumer(edges: ProvisioningEdges): ProvisioningEdges =
      result = edges
      result.actions.add(builtinAction(bakCopyFile, "consumer",
        governingLockIdentity = lockIdentityOutsideSolvedGraph(),
        cwd = tempRoot, deps = [edges.rootId], inputs = [edges.rootReceipt],
        outputs = [consumerOut]))

    let first = runProvisioningEdges(withConsumer(edgesV1), storeRoot)
    check first.resultFor(edgesV1.rootId).status == asSucceeded
    check first.resultFor(edgesV1.rootId).cacheDecision == cdMiss
    check first.resultFor("consumer").status == asSucceeded
    let receiptV1 = readTarballProvisionReceipt(edgesV1.rootReceipt)
    check fileExists(receiptV1.executable)
    check readFile(receiptV1.executable) == "@echo v1\r\n"
    check readFile(consumerOut) == readFile(edgesV1.rootReceipt)

    let again = runProvisioningEdges(withConsumer(edgesV1), storeRoot)
    check again.resultFor(edgesV1.rootId).status in {asUpToDate, asCacheHit}
    check not again.resultFor(edgesV1.rootId).launched
    check again.resultFor("consumer").status in {asUpToDate, asCacheHit}

    let repinned = runProvisioningEdges(withConsumer(edgesV2), storeRoot)
    check repinned.resultFor(edgesV2.rootId).status == asSucceeded
    check repinned.resultFor(edgesV2.rootId).cacheDecision == cdMiss
    let receiptV2 = readTarballProvisionReceipt(edgesV2.rootReceipt)
    check receiptV2.prefix != receiptV1.prefix
    check readFile(receiptV2.executable) == "@echo v2\r\n"
    # The consumer re-executed after the provisioning edge, on its new output.
    check repinned.resultFor("consumer").status == asSucceeded
    check readFile(consumerOut) == readFile(edgesV2.rootReceipt)

    # And the profile `resolveTarballTool` hands to tool resolution is the
    # edge's realization.
    let profile = resolveTarballTool(useV2, storeRoot)
    check profile.resolvedExecutablePath == receiptV2.executable
    check profile.selectedStorePath == receiptV2.prefix

  test "a receipt whose prefix was deleted is re-realized":
    let v3 = writeRawTool(tempRoot / "v3", "edgefixture.cmd", "@echo v3\r\n")
    let use = rawUse("edgefixture-gc@1.0", v3.url, v3.sha256)
    let before = resolveTarballTool(use, storeRoot)
    removeDir(before.selectedStorePath)
    check not fileExists(before.resolvedExecutablePath)
    let after = resolveTarballTool(use, storeRoot)
    check after.resolvedExecutablePath == before.resolvedExecutablePath
    check fileExists(after.resolvedExecutablePath)

  test "a failing realization reports the realizer's own error":
    let use = rawUse("edgefixture-bad@1.0",
      "file://" & (tempRoot / "absent.cmd").replace('\\', '/'), repeat("cd", 32))
    expect OSError:
      discard resolveTarballTool(use, storeRoot)
    try:
      discard resolveTarballTool(use, storeRoot)
    except OSError as err:
      check "all tarball archive URLs failed" in err.msg

  test "the engine refuses a provisioner with no executor, by name":
    let action = block:
      var a = builtinAction(bakForeignProvision, "unknown-provision",
        governingLockIdentity = lockIdentityOutsideSolvedGraph(),
        cwd = tempRoot, outputs = [tempRoot / "unknown.receipt"])
      a.argv = @["no-such-provisioner", "pkg"]
      a
    let res = executeBuiltinAction(action)
    check res.status == asFailed
    check "no executor is registered for provisioner \"no-such-provisioner\"" in
      res.stderr
    check TarballProvisionerName in res.stderr

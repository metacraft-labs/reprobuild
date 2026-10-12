## Scoop realization is a build-graph edge.
##
## Dependency-Provisioning-In-Build-Graph.md sections 2-4: a package
## materialization is a `bakForeignProvision` edge routed by its provisioner
## name (`"scoop"` here), cached by the action cache, invalidated by its
## pinned inputs, with a receipt as its output that the consumers of the tool
## declare as an input. Before this test `resolveScoopTool` realized a Scoop
## app inline: no edge, no receipt, no action-cache entry.
##
## What is asserted:
##
##   * a realization leaves the edge's receipt in the tool store's
##     provisioning state, and the profile names it;
##   * the edge is `bakForeignProvision` with provisioner `"scoop"`, declares
##     the bucket manifest as an input, and a network fetch of the pinned app
##     and the manifest's download URL;
##   * the receipt's content names the realization store-relatively, so it
##     reads the same on any host that realizes the same pin;
##   * a repeat realization is served by the action cache -- the edge is not
##     re-executed;
##   * an in-place edit of the bucket manifest re-executes the edge;
##   * a realization whose prefix was removed is realized again.
##
## No mocks. A real Scoop install is required on the host (the realization
## resolves the Scoop executable), and `$SCOOP` points it at a sandboxed root
## whose app is pre-positioned, so no `scoop install` and no network are
## needed. Windows only; elsewhere every case is a reported skip.

import std/[json, os, strutils, tempfiles]

import std/unittest
import repro_test_support/reasoned_skip

import repro_build_engine
import repro_tool_profiles

import ./scoop_sandbox

const HostRunsGate = defined(windows)

const PlatformSkipReason =
  "[platform N/A] e2e_scoop_provisioning_edge: " &
    "this gate requires Windows and a real Scoop install"

template gatedTest(name: string; body: untyped) =
  ## A runtime guard on a compile-time constant, so the body is still
  ## type-checked on hosts that skip it (see `t_e2e_scoop_practical_hardening`).
  test name:
    if HostRunsGate:
      body
    else:
      skip(PlatformSkipReason)

proc resultFor(run: BuildRunResult; id: string): ActionResult =
  for item in run.results:
    if item.id == id:
      return item
  raise newException(KeyError, "no result for " & id)

proc scoopReceipts(storeRoot: string): seq[string] =
  let dir = storeRoot / "provisioning" / "receipts"
  if dirExists(dir):
    for kind, path in walkDir(dir):
      if kind == pcFile and path.extractFilename.startsWith("scoop-provision.") and
          path.endsWith(".receipt"):
        result.add(path)

suite "e2e_scoop_provisioning_edge":
  gatedTest "a scoop realization goes through its provisioning edge":
    let scoopBinary = resolveScoopBinary()
    if scoopBinary.len == 0:
      raise newException(OSError,
        "this gate requires a real scoop binary on PATH (none found).")
    let tempRoot = createTempDir("repro-scoop-edge-", "")
    defer: safeRemoveTempRoot(tempRoot)
    let sandbox = setupScoopSandbox(tempRoot, "main")
    let storeRoot = tempRoot / "tool-store"
    let fixture = populateScoopApp(sandbox, app = "edge-app",
      version = "1.0.0", executableName = "edge-cli.cmd",
      executablePayload = fixtureExecutablePayload("edge 1.0.0"))
    let useDef = fixtureUseDef(
      packageSelector = "edge-pkg",
      executableName = "edge-cli",
      bucket = sandbox.bucketName,
      app = fixture.name,
      version = "1.0.0",
      preferredVersion = "",
      manifestChecksum = "",
      executablePath = fixture.executableName,
      requiresExecutionProfileChecksum = true)

    # A realization leaves the edge's receipt in the store.
    let profile = resolveScoopTool(useDef, storeRoot)
    check profile.installMethod == "scoop"
    check fileExists(profile.resolvedExecutablePath)
    let receipts = scoopReceipts(storeRoot)
    check receipts.len == 1
    check profile.provisioningReceipt.len > 0
    if receipts.len == 1:
      check sameFile(profile.provisioningReceipt, receipts[0])

    # The edge's shape.
    let edges = scoopProvisioningEdges(useDef, storeRoot)
    check edges.actions.len == 1
    let edge = edges.actions[0]
    check edge.id == edges.rootId
    check edge.kind == bakForeignProvision
    check edge.argv == @[ScoopProvisionerName, "edge-pkg"]
    check edges.rootReceipt in edge.outputs
    check edges.rootReceipt == profile.provisioningReceipt
    check fixture.manifestPath in edge.inputs
    check edge.networkMode == netFetch
    check "scoop://main/edge-app" in edge.netDestinations
    check ("file:///" & fixture.executablePath.replace('\\', '/')) in
      edge.netDestinations
    check edge.cacheable

    # The receipt names the realization relative to the store.
    let receipt = parseFile(edges.rootReceipt)
    check receipt{"bucket"}.getStr() == "main"
    check receipt{"resolvedVersion"}.getStr() == "1.0.0"
    let recordedPrefix = receipt{"prefix"}.getStr()
    check recordedPrefix.len > 0
    check not isAbsolute(recordedPrefix)
    check sameFile(storeRoot / recordedPrefix, profile.selectedStorePath)
    check not isAbsolute(receipt{"executable"}.getStr())

    # A repeat is served by the action cache.
    let again = runProvisioningEdges(edges, storeRoot)
    check again.resultFor(edges.rootId).status in {asUpToDate, asCacheHit}
    check not again.resultFor(edges.rootId).launched
    let profileAgain = resolveScoopTool(useDef, storeRoot)
    check profileAgain.selectedStorePath == profile.selectedStorePath
    check profileAgain.profileFingerprint == profile.profileFingerprint

    # An in-place manifest edit is a changed input: the edge re-executes.
    let manifest = parseJson(readFile(fixture.manifestPath))
    manifest["homepage"] = newJString("https://example.invalid/edited")
    writeFile(fixture.manifestPath, manifest.pretty())
    let edited = runProvisioningEdges(edges, storeRoot)
    check edited.resultFor(edges.rootId).status == asSucceeded
    check edited.resultFor(edges.rootId).launched

    # The edit changed the manifest checksum, which the prefix is keyed on,
    # so the edge realized a new prefix.
    let current = resolveScoopTool(useDef, storeRoot)
    check current.selectedStorePath != profile.selectedStorePath
    check fileExists(current.resolvedExecutablePath)

    # A removed prefix is realized again rather than trusted: the receipt the
    # action cache keeps still names it, so the edge is forced to run.
    deleteJunctionsRec(current.selectedStorePath)
    removeDir(current.selectedStorePath)
    check not dirExists(current.selectedStorePath)
    let restored = resolveScoopTool(useDef, storeRoot)
    check restored.selectedStorePath == current.selectedStorePath
    check dirExists(restored.selectedStorePath / "bin")
    check fileExists(restored.resolvedExecutablePath)

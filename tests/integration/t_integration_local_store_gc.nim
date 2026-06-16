## M56 integration verification gate `integration_local_store_gc`.
##
## Per the milestone description: register two roots, one referencing
## one prefix; un-root the second root; run `repro store gc`; verify
## the unreferenced prefix moves to `gc/pending-deletion/`, the
## `gc_audit` row records the decision, and post-grace-period unlink
## reclaims the directory.

import std/[os, osproc, sequtils, strutils, tempfiles, times, unittest]

import repro_local_store
# Only ``requireBinary`` is pulled in from the test-support library: the
# module also exports a ``shellCommand`` that returns a ``CmdSpec``, which
# would clash with this file's local string-returning ``shellCommand`` helper.
from repro_test_support import requireBinary, MissingTestFixtureError

proc q(value: string): string = quoteShell(value)

proc shellCommand(args: openArray[string]): string =
  args.mapIt(q(it)).join(" ")

proc findReproRepoRoot(): string =
  ## Locate the in-repo root by walking up from the test binary location
  ## until the tree containing ``libs`` and ``apps/repro/repro.nim`` is found.
  var current = getAppFilename().parentDir
  for _ in 0 .. 8:
    if dirExists(current / "libs") and
        fileExists(current / "apps" / "repro" / "repro.nim"):
      return current
    let p = current.parentDir
    if p == current: break
    current = p
  ""

proc reproBinary(): string =
  ## Test-Fixtures-In-Build-Graph M1: ``repro`` is a build-graph artifact
  ## (``reprobuild.apps.repro`` → ``build/bin/repro``, built by
  ## ``just bootstrap`` / the apps collection before tests run). Assert it
  ## exists and drive it instead of recompiling ``apps/repro/repro.nim`` at
  ## test runtime.
  let root = findReproRepoRoot()
  doAssert root.len > 0, "could not locate the reprobuild repo root"
  requireBinary(root / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc realizeSimple(store: var Store; packageName, version: string;
                  payload: string): RealizeResult =
  let hint = StoreReceiptHint(
    adapter: "tarball",
    packageName: packageName,
    version: version,
    declaredExecutablePath: "bin/tool",
    lockIdentity: "tarball:" & packageName & "@" & version,
    materializationMechanism: "directory")
  let prefixId = computeRealizationHash(hint.packageName, hint.version,
    hint.adapter, hint.lockIdentity, hint.declaredExecutablePath)
  store.realizePrefix(prefixId, hint,
    proc (stagingDir: string; mechanism: var string) =
      createDir(stagingDir / "bin")
      writeFile(stagingDir / "bin" / "tool", payload)
      mechanism = "directory")

suite "integration_local_store_gc":

  test "gc_quarantines_unrooted_prefix_and_audits":
    let root = createTempDir("repro-m56-gc-", "")
    defer:
      try: removeDir(root) except OSError: discard
    var store = openStore(root / "store")
    defer: store.close()

    # Realize two prefixes; root each one.
    let realA = store.realizeSimple("alpha", "1.0.0", "alpha-body\n")
    let realB = store.realizeSimple("beta", "2.0.0", "beta-body\n")
    check realA.outcome == roPublished
    check realB.outcome == roPublished

    store.registerRoot("session.alpha", rkSession)
    store.attachPrefixToRoot("session.alpha", realA.prefixId)
    store.registerRoot("session.beta", rkSession)
    store.attachPrefixToRoot("session.beta", realB.prefixId)

    # Both prefixes are live; GC must not move anything.
    let firstReport = store.gc(graceSeconds = 0)
    check firstReport.quarantined.len == 0

    # Now unroot beta. The alpha root still keeps alpha alive.
    store.deleteRoot("session.beta")
    let dead = store.deadSet()
    check dead.len == 1
    check dead[0].packageName == "beta"

    # Run GC with grace = 0 so reclamation happens in the same pass.
    let reportA = store.gc(graceSeconds = 0)
    check reportA.quarantined.len == 1
    check reportA.quarantined[0].packageName == "beta"
    check reportA.quarantinedPaths.len == 1
    check not dirExists(realB.absolutePath)

    # Audit log: there must be a quarantine row for beta.
    let audit1 = store.listAudit()
    var quarantineForBeta = false
    for row in audit1:
      if row.action == "quarantine" and row.hasPrefixId and
          row.prefixId == realB.prefixId:
        quarantineForBeta = true
    check quarantineForBeta

    # Post-grace-period: the pending-deletion entry should already be
    # gone because we ran with graceSeconds = 0. Verify the directory
    # was unlinked (reclaim audit row exists).
    var reclaimSeen = false
    for row in store.listAudit():
      if row.action == "reclaim":
        reclaimSeen = true
    check reclaimSeen

    # Verify alpha was not touched.
    let lookupAlpha = store.lookupPrefix(realA.prefixId)
    check lookupAlpha.found
    check dirExists(realA.absolutePath)

  test "gc_respects_nonzero_grace_period":
    ## A non-zero grace prevents immediate reclaim. The pending-
    ## deletion directory MUST still hold the quarantined tree after
    ## the first pass; a follow-up call with a long-enough grace must
    ## reclaim it.
    let root = createTempDir("repro-m56-gc-grace-", "")
    defer:
      try: removeDir(root) except OSError: discard
    var store = openStore(root / "store")
    defer: store.close()

    let realC = store.realizeSimple("gamma", "0.1.0", "gamma-body\n")
    check realC.outcome == roPublished
    store.registerRoot("session.gamma", rkSession)
    store.attachPrefixToRoot("session.gamma", realC.prefixId)
    store.deleteRoot("session.gamma")

    let report1 = store.gc(graceSeconds = 60)
    check report1.quarantined.len == 1
    check report1.reclaimed.len == 0     # Grace not elapsed yet.

    # Quarantined directory still lives under gc/pending-deletion.
    var pendingCount = 0
    for kind, _ in walkDir(store.gcPendingRoot, relative = false):
      if kind in {pcDir, pcLinkToDir}:
        inc pendingCount
    check pendingCount == 1

    # Force-age the entry by rewinding the directory mtime.
    for kind, path in walkDir(store.gcPendingRoot, relative = false):
      if kind in {pcDir, pcLinkToDir}:
        # On Windows, setLastModificationTime on a directory works.
        setLastModificationTime(path,
          fromUnix(getTime().toUnix - 7200))

    let report2 = store.gc(graceSeconds = 60)
    check report2.reclaimed.len == 1
    var pendingAfter = 0
    for kind, _ in walkDir(store.gcPendingRoot, relative = false):
      if kind in {pcDir, pcLinkToDir}:
        inc pendingAfter
    check pendingAfter == 0

  test "public_cli_repro_store_gc_drives_the_same_protocol":
    ## End-to-end coverage of the actual `repro store gc` public CLI
    ## binary. Builds the CLI in a temp dir, lays out a rooted prefix,
    ## un-roots it, invokes `repro store gc --store-root=<root>`, and
    ## checks the prefix moved into `gc/pending-deletion/`.
    let root = createTempDir("repro-m56-gc-cli-", "")
    defer:
      try: removeDir(root) except OSError: discard
    let reproBin = reproBinary()
    check fileExists(reproBin)

    let storeRoot = root / "store"
    block init:
      var s = openStore(storeRoot)
      defer: s.close()
      let real = s.realizeSimple("delta", "9.9.9", "delta-body\n")
      check real.outcome == roPublished
      s.registerRoot("session.delta", rkSession)
      s.attachPrefixToRoot("session.delta", real.prefixId)
      s.deleteRoot("session.delta")

    let res = execCmdEx(shellCommand([reproBin, "store", "gc",
      "--store-root=" & storeRoot, "--grace-seconds=0"]))
    check res.exitCode == 0
    check res.output.contains("quarantined: 1")

    # Verify the prefix's index row is gone and the prefix tree is no
    # longer under prefixes/.
    var verifier = openStore(storeRoot)
    defer: verifier.close()
    check verifier.listPrefixes().len == 0

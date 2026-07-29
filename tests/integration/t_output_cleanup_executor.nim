## Integration test for the owned-effect-claim output cleanup executor (M84).
##
## The provider graph refresh already emits `ProviderRefreshReport.staleEffects`
## (one cleanup candidate per owned effect a vanished/replaced edge dropped).
## This test drives the executor (`planOutputCleanup` / `applyOutputCleanup`)
## over hand-built refresh reports and a real temporary output tree, asserting
## the deletion / retention / refusal rules from the "Graph Replacement And
## Pruning" section of Project-Provider-Graph-Protocol.md.
##
## No mocks beyond synthetic graph fragments and a tempdir: the executor logic
## and the filesystem boundary are the real components under test.

import std/[os, tempfiles, unittest]
import repro_provider_runtime

proc fileClaim(path: string;
               policy = cplDeleteWhenUnclaimed;
               kind = oekFile): OwnedEffectClaim =
  OwnedEffectClaim(kind: kind, stableName: path, identity: path,
    cleanupPolicy: policy, payload: "producing-action")

proc staleOf(claim: OwnedEffectClaim; key = "inv-old"): StaleOwnedEffect =
  StaleOwnedEffect(invocationKey: key, claim: claim)

proc reportWith(stales: seq[StaleOwnedEffect];
                surviving: seq[OwnedEffectClaim] = @[]): ProviderRefreshReport =
  var snap = ProviderGraphSnapshot(providerArtifactId: "art")
  if surviving.len > 0:
    snap.fragments.add(StoredGraphFragment(
      invocationKey: "inv-live", effectClaims: surviving))
  ProviderRefreshReport(snapshot: snap, staleEffects: stales)

proc touchUnder(root, rel: string): string =
  result = root / rel
  createDir(result.parentDir)
  writeFile(result, "orphan")

proc outcomeOf(res: OutputCleanupResult; identity: string): OutputCleanupOutcome =
  for act in res.actions:
    if act.claim.identity == identity:
      return act.outcome
  raise newException(ValueError, "no cleanup action for " & identity)

suite "output cleanup executor (M84)":

  test "cplDeleteWhenUnclaimed file that vanished is deleted":
    let root = createTempDir("rb-cleanup-", "-del")
    defer: removeDir(root)
    let f = touchUnder(root, "build/clips/a.wav")
    let report = reportWith(@[staleOf(fileClaim("build/clips/a.wav"))])
    let res = applyOutputCleanup(report, root)
    check res.deleted == 1
    check not fileExists(f)
    check outcomeOf(res, "build/clips/a.wav") == ocoDeleted

  test "explicit-destroy and never-delete policies are retained":
    let root = createTempDir("rb-cleanup-", "-policy")
    defer: removeDir(root)
    let f1 = touchUnder(root, "keep1.txt")
    let f2 = touchUnder(root, "keep2.txt")
    let f3 = touchUnder(root, "keep3.txt")
    let report = reportWith(@[
      staleOf(fileClaim("keep1.txt", cplRequireExplicitDestroy)),
      staleOf(fileClaim("keep2.txt", cplNeverDeleteAutomatically)),
      staleOf(fileClaim("keep3.txt", cplKeepAsGarbageCollectable))])
    let res = applyOutputCleanup(report, root)
    check res.deleted == 0
    check res.skipped == 3
    check fileExists(f1) and fileExists(f2) and fileExists(f3)
    check outcomeOf(res, "keep1.txt") == ocoSkippedPolicy

  test "effect still claimed by a surviving fragment is retained (shared)":
    let root = createTempDir("rb-cleanup-", "-shared")
    defer: removeDir(root)
    let f = touchUnder(root, "shared.out")
    # The same effect vanished from one fragment but is claimed by a live one.
    let report = reportWith(
      @[staleOf(fileClaim("shared.out"))],
      surviving = @[fileClaim("shared.out")])
    let res = applyOutputCleanup(report, root)
    check res.deleted == 0
    check fileExists(f)
    check outcomeOf(res, "shared.out") == ocoSkippedShared

  test "paths escaping the project root are refused":
    let root = createTempDir("rb-cleanup-", "-root")
    defer: removeDir(root)
    # A sibling file OUTSIDE the project root that a malicious/buggy claim
    # identity tries to reach via traversal and via an absolute path.
    let outside = root.parentDir / ("escape-" & root.lastPathPart & ".txt")
    writeFile(outside, "must survive")
    defer: (if fileExists(outside): removeFile(outside))
    let report = reportWith(@[
      staleOf(fileClaim("../" & outside.lastPathPart)),
      staleOf(fileClaim(outside))])           # absolute, outside root
    let res = applyOutputCleanup(report, root)
    check res.deleted == 0
    check res.refused == 2
    check fileExists(outside)

  test "the project root itself is never deleted":
    let root = createTempDir("rb-cleanup-", "-self")
    defer: removeDir(root)
    let report = reportWith(@[staleOf(fileClaim("."))])
    let res = applyOutputCleanup(report, root)
    check res.refused == 1
    check dirExists(root)

  test "already-absent output is an idempotent no-op":
    let root = createTempDir("rb-cleanup-", "-absent")
    defer: removeDir(root)
    let report = reportWith(@[staleOf(fileClaim("build/gone.wav"))])
    let res = applyOutputCleanup(report, root)
    check res.deleted == 0
    check res.alreadyAbsent == 1
    check outcomeOf(res, "build/gone.wav") == ocoAlreadyAbsent

  test "dry-run reports candidates but deletes nothing":
    let root = createTempDir("rb-cleanup-", "-dry")
    defer: removeDir(root)
    let f = touchUnder(root, "build/clips/b.wav")
    let report = reportWith(@[staleOf(fileClaim("build/clips/b.wav"))])
    let res = applyOutputCleanup(report, root, dryRun = true)
    check res.deleted == 0
    check res.wouldDelete == 1
    check fileExists(f)
    check outcomeOf(res, "build/clips/b.wav") == ocoWouldDelete

  test "non-file effect kinds are left to the resource planner":
    let root = createTempDir("rb-cleanup-", "-kind")
    defer: removeDir(root)
    let report = reportWith(@[
      staleOf(fileClaim("some-service", kind = oekService))])
    let res = applyOutputCleanup(report, root)
    check res.deleted == 0
    check outcomeOf(res, "some-service") == ocoSkippedKind

  test "empty directory claim is deleted; non-empty is retained":
    let root = createTempDir("rb-cleanup-", "-dir")
    defer: removeDir(root)
    createDir(root / "build/emptydir")
    createDir(root / "build/fulldir")
    writeFile(root / "build/fulldir/unowned.txt", "not ours")
    let report = reportWith(@[
      staleOf(fileClaim("build/emptydir", kind = oekDirectory)),
      staleOf(fileClaim("build/fulldir", kind = oekDirectory))])
    let res = applyOutputCleanup(report, root)
    check outcomeOf(res, "build/emptydir") == ocoDeleted
    check not dirExists(root / "build/emptydir")
    check outcomeOf(res, "build/fulldir") == ocoSkippedNotEmpty
    check fileExists(root / "build/fulldir/unowned.txt")

  test "a symlinked output is removed as a link, not followed":
    let root = createTempDir("rb-cleanup-", "-link")
    defer: removeDir(root)
    let target = root.parentDir / ("linktarget-" & root.lastPathPart & ".txt")
    writeFile(target, "must survive")
    defer: (if fileExists(target): removeFile(target))
    let link = root / "build/link.wav"
    createDir(link.parentDir)
    createSymlink(target, link)
    let report = reportWith(@[staleOf(fileClaim("build/link.wav"))])
    let res = applyOutputCleanup(report, root)
    check res.deleted == 1
    check not symlinkExists(link)
    check fileExists(target)      # the symlink target outside root is untouched

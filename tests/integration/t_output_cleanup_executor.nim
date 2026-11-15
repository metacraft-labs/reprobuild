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

proc snapshotClaiming(claims: seq[OwnedEffectClaim];
                      key = "inv-a"): ProviderGraphSnapshot =
  ProviderGraphSnapshot(providerArtifactId: "art",
    fragments: @[StoredGraphFragment(invocationKey: key, effectClaims: claims)])

suite "project clean (repro clean)":

  test "every claimed file of the build state is removed, unclaimed kept":
    let root = createTempDir("rb-clean-", "-files")
    defer: removeDir(root)
    let a = touchUnder(root, "build/a.o")
    let b = touchUnder(root, "build/b.o")
    let mine = touchUnder(root, "build/notes.txt")
    let res = applyProjectClean(
      @[snapshotClaiming(@[fileClaim("build/a.o"), fileClaim("build/b.o")])],
      root)
    check res.deleted == 2
    check not fileExists(a)
    check not fileExists(b)
    check fileExists(mine)

  test "a declared output that is a directory is removed with its tree":
    # The DSL claims every declared output as ``oekFile``, directory outputs
    # included. A graph refresh treats that mismatch as a failure; a clean
    # removes the tree, because the whole of it is the action's product.
    let root = createTempDir("rb-clean-", "-tree")
    defer: removeDir(root)
    discard touchUnder(root, "build/nimcache/m.c")
    discard touchUnder(root, "build/nimcache/sub/n.c")
    let mine = touchUnder(root, "build/keep.txt")
    let res = applyProjectClean(
      @[snapshotClaiming(@[fileClaim("build/nimcache")])], root)
    check outcomeOf(res, "build/nimcache") == ocoDeleted
    check not dirExists(root / "build/nimcache")
    check fileExists(mine)
    # The refresh executor keeps its stricter reading of the same claim.
    discard touchUnder(root, "build/nimcache/m.c")
    let refresh = applyOutputCleanup(
      reportWith(@[staleOf(fileClaim("build/nimcache"))]), root)
    check outcomeOf(refresh, "build/nimcache") == ocoFailed
    check fileExists(root / "build/nimcache/m.c")

  test "a symlink inside a removed tree is unlinked, not followed":
    let root = createTempDir("rb-clean-", "-treelink")
    defer: removeDir(root)
    let outside = createTempDir("rb-clean-", "-outside")
    defer: removeDir(outside)
    writeFile(outside / "precious.txt", "must survive")
    createDir(root / "build/out")
    createSymlink(outside, root / "build/out/link")
    let res = applyProjectClean(
      @[snapshotClaiming(@[fileClaim("build/out")])], root)
    check outcomeOf(res, "build/out") == ocoDeleted
    check not dirExists(root / "build/out")
    check fileExists(outside / "precious.txt")

  test "cleanup policy, root containment and dry run still apply":
    let root = createTempDir("rb-clean-", "-rules")
    defer: removeDir(root)
    let gc = touchUnder(root, "build/gc.bin")
    let destroy = touchUnder(root, "build/state.db")
    let del = touchUnder(root, "build/del.o")
    let snapshot = snapshotClaiming(@[
      fileClaim("build/gc.bin", policy = cplKeepAsGarbageCollectable),
      fileClaim("build/state.db", policy = cplRequireExplicitDestroy),
      fileClaim("build/del.o"),
      fileClaim("../escape.o")])
    let dry = applyProjectClean(@[snapshot], root, dryRun = true)
    check dry.wouldDelete == 1
    check fileExists(del)
    let res = applyProjectClean(@[snapshot], root)
    check outcomeOf(res, "build/gc.bin") == ocoSkippedPolicy
    check outcomeOf(res, "build/state.db") == ocoSkippedPolicy
    check outcomeOf(res, "../escape.o") == ocoRefusedOutsideRoot
    check outcomeOf(res, "build/del.o") == ocoDeleted
    check fileExists(gc)
    check fileExists(destroy)
    check not fileExists(del)

  test "a claim shared by two snapshots is considered once":
    # Two variant snapshots of one target claim the same output path.
    let root = createTempDir("rb-clean-", "-shared")
    defer: removeDir(root)
    discard touchUnder(root, "build/x.o")
    let res = applyProjectClean(@[
      snapshotClaiming(@[fileClaim("build/x.o")], key = "inv-debug"),
      snapshotClaiming(@[fileClaim("build/x.o")], key = "inv-release")], root)
    check res.actions.len == 1
    check res.deleted == 1
    check res.failed == 0

  test "no snapshots means nothing to remove":
    let root = createTempDir("rb-clean-", "-empty")
    defer: removeDir(root)
    let mine = touchUnder(root, "build/a.o")
    let res = applyProjectClean(newSeq[ProviderGraphSnapshot](), root)
    check res.actions.len == 0
    check fileExists(mine)

suite "project clean of container directory outputs":
  # An ``oekDirectory`` claim is a CONTAINER: a directory its action declares
  # only to say that it exists, while other writers fill it
  # (Incremental-Invalidation.md §"Non-regular outputs", "Container directory
  # outputs"). ``repro clean`` classifies ``fs.ensureDir`` and a
  # ``fs.preserveTree`` root this way. Unlike an opaque directory output (the
  # ``oekFile`` case above), it is never removed with its tree.

  test "a container that still holds an unclaimed file is kept":
    let root = createTempDir("rb-clean-", "-container-kept")
    defer: removeDir(root)
    let member = touchUnder(root, "build/c/main.o")
    let mine = touchUnder(root, "build/c/notes.txt")
    let res = applyProjectClean(@[snapshotClaiming(@[
      fileClaim("build/c", kind = oekDirectory),
      fileClaim("build/c/main.o")])], root)
    check outcomeOf(res, "build/c/main.o") == ocoDeleted
    check outcomeOf(res, "build/c") == ocoSkippedNotEmpty
    check not fileExists(member)
    check fileExists(mine)
    check res.failed == 0

  test "a container whose members were its only entries is removed":
    let root = createTempDir("rb-clean-", "-container-empty")
    defer: removeDir(root)
    discard touchUnder(root, "build/pub/top.txt")
    discard touchUnder(root, "build/pub/nested/deep/leaf.txt")
    let mine = touchUnder(root, "build/README.txt")
    let res = applyProjectClean(@[snapshotClaiming(@[
      fileClaim("build/pub", kind = oekDirectory),
      fileClaim("build/pub/top.txt"),
      fileClaim("build/pub/nested/deep/leaf.txt")])], root)
    check outcomeOf(res, "build/pub") == ocoDeleted
    check not dirExists(root / "build/pub")
    # The directory that holds the container is not the container's.
    check dirExists(root / "build")
    check fileExists(mine)

  test "emptied directories are pruned only below the container":
    let root = createTempDir("rb-clean-", "-container-prune")
    defer: removeDir(root)
    discard touchUnder(root, "build/pub/a/b/leaf.txt")
    let sibling = touchUnder(root, "build/pub/a/keep.txt")
    # An empty directory beside the members, which nothing removed, stays.
    createDir(root / "build/pub/empty-of-mine")
    let res = applyProjectClean(@[snapshotClaiming(@[
      fileClaim("build/pub", kind = oekDirectory),
      fileClaim("build/pub/a/b/leaf.txt")])], root)
    check outcomeOf(res, "build/pub/a/b/leaf.txt") == ocoDeleted
    check not dirExists(root / "build/pub/a/b")
    check fileExists(sibling)
    check dirExists(root / "build/pub/empty-of-mine")
    check outcomeOf(res, "build/pub") == ocoSkippedNotEmpty

  test "a member outside every container prunes nothing":
    let root = createTempDir("rb-clean-", "-no-container")
    defer: removeDir(root)
    discard touchUnder(root, "out/x/y.o")
    let res = applyProjectClean(@[snapshotClaiming(@[
      fileClaim("out/x/y.o")])], root)
    check outcomeOf(res, "out/x/y.o") == ocoDeleted
    check dirExists(root / "out/x")

  test "a container that is a symlink is unlinked, not followed":
    let root = createTempDir("rb-clean-", "-container-link")
    defer: removeDir(root)
    let outside = createTempDir("rb-clean-", "-container-outside")
    defer: removeDir(outside)
    writeFile(outside / "precious.txt", "must survive")
    createDir(root / "build")
    createSymlink(outside, root / "build/c")
    let res = applyProjectClean(@[snapshotClaiming(@[
      fileClaim("build/c", kind = oekDirectory)])], root)
    check outcomeOf(res, "build/c") == ocoDeleted
    check not symlinkExists(root / "build/c")
    check fileExists(outside / "precious.txt")

  test "a container is kept under a dry run":
    let root = createTempDir("rb-clean-", "-container-dry")
    defer: removeDir(root)
    let member = touchUnder(root, "build/c/main.o")
    let res = applyProjectClean(@[snapshotClaiming(@[
      fileClaim("build/c", kind = oekDirectory),
      fileClaim("build/c/main.o")])], root, dryRun = true)
    check res.wouldDelete == 2
    check fileExists(member)

  test "a nested container leaves no emptied directories to its container":
    # ``fs.ensureDir("build/a/b")`` inside ``fs.ensureDir("build")``: the
    # inner container's removal takes ``build/a``, which it left empty, so
    # the outer container is empty in its turn and is removed too.
    let root = createTempDir("rb-clean-", "-container-nested")
    defer: removeDir(root)
    discard touchUnder(root, "build/a/b/x.o")
    let res = applyProjectClean(@[snapshotClaiming(@[
      fileClaim("build", kind = oekDirectory),
      fileClaim("build/a/b", kind = oekDirectory),
      fileClaim("build/a/b/x.o")])], root)
    check outcomeOf(res, "build/a/b/x.o") == ocoDeleted
    check outcomeOf(res, "build/a/b") == ocoDeleted
    check outcomeOf(res, "build") == ocoDeleted
    check not dirExists(root / "build")
    check res.failed == 0

  test "a directory a kept claim names is not pruned":
    let root = createTempDir("rb-clean-", "-container-kept-claim")
    defer: removeDir(root)
    discard touchUnder(root, "build/pub/keep/x.txt")
    let res = applyProjectClean(@[snapshotClaiming(@[
      fileClaim("build/pub", kind = oekDirectory),
      fileClaim("build/pub/keep", cplNeverDeleteAutomatically,
        kind = oekDirectory),
      fileClaim("build/pub/keep/x.txt")])], root)
    check outcomeOf(res, "build/pub/keep/x.txt") == ocoDeleted
    check outcomeOf(res, "build/pub/keep") == ocoSkippedPolicy
    check dirExists(root / "build/pub/keep")
    check outcomeOf(res, "build/pub") == ocoSkippedNotEmpty

  test "pruning does not follow a symlinked directory inside a container":
    # ``build/pub/link`` points outside the project. Removing the member
    # through it must not go on to remove the directory it emptied there.
    let root = createTempDir("rb-clean-", "-container-prune-link")
    defer: removeDir(root)
    let outside = createTempDir("rb-clean-", "-container-prune-outside")
    defer: removeDir(outside)
    createDir(outside / "sub")
    writeFile(outside / "sub" / "x.txt", "member")
    createDir(root / "build/pub")
    createSymlink(outside, root / "build/pub/link")
    let res = applyProjectClean(@[snapshotClaiming(@[
      fileClaim("build/pub", kind = oekDirectory),
      fileClaim("build/pub/link/sub/x.txt")])], root)
    check outcomeOf(res, "build/pub/link/sub/x.txt") == ocoDeleted
    check dirExists(outside / "sub")
    check symlinkExists(root / "build/pub/link")
    check outcomeOf(res, "build/pub") == ocoSkippedNotEmpty

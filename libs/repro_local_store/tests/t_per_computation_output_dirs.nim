## Per-computation output directories, at the cache layer —
## Hermetic-Builds-And-Path-Independence.md §"Per-computation output
## directories" (owner decision 2026-10-29).
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every record is written through the production `recordActionResult` into a
## real `ActionCache` and `LocalCas` on a real temporary directory, from real
## input and output files; lookups go through the production
## `lookupActionResult`, eviction through the production per-edge cap, and the
## orphan sweep reads the same on-disk records the engine writes. The clock
## for the sweep's grace period is injected (`nowUnix`), which replaces a
## sleep, not a collaborator. So are the inputs' modification times (see
## `writeInput`), which replaces waiting for the filesystem clock to tick.
##
## The defect this layer must not have (measured 2026-10-29 at reprobuild
## `3f5a229979`): two computations that share a weak fingerprint wrote their
## outputs to ONE directory, so a metadata-only record of the first failed
## "output metadata changed" as soon as the second had run, although none of
## its inputs had changed.

import std/[os, sets, strutils, tempfiles, times, unittest]

import repro_core
import repro_hash
import repro_local_store

proc weakOf(name: string): ContentDigest =
  ## The construction `repro_build_engine.weakFingerprintFromText` uses,
  ## written out so this test does not depend on the layer above.
  var bytes = newSeq[byte](name.len)
  for i, ch in name:
    bytes[i] = byte(ord(ch))
  blake3DomainDigest(bytes, hdActionFingerprint)

type Fixture = object
  root: string          ## plays the action-cache root (`<R>`)
  work: string          ## where the action's inputs live
  identityDir: string   ## `<R>/recipe-compiles/provider/<identity>`
  staging: string
  cache: ActionCache
  cas: LocalCas
  inputWrites: int      ## how many times `writeInput` has run

proc newFixture(prefix: string): Fixture =
  result.root = createTempDir(prefix, "")
  result.work = result.root / "work"
  createDir(result.work)
  result.identityDir = result.root / RecipeCompilesDirName / "provider" /
    "0123456789abcdef"
  result.staging = result.identityDir / ComputationStagingDirName
  result.cache = openActionCache(result.root / "action-cache",
    attachShm = false)
  result.cas = openLocalCas(result.root / "cas")

proc close(fx: var Fixture) =
  fx.cache.closeShmTier()
  try: removeDir(fx.root)
  except OSError: discard

const InputClockBase = 1_700_000_000'i64
  ## A fixed past instant; `writeInput` counts whole seconds up from it.

proc writeInput(fx: var Fixture; content: string) =
  ## Write the action's one input and give it a modification time no earlier
  ## write had.
  ##
  ## The lookups here run under `ffpHybrid`, which compares an input's
  ## recorded (kind, size, mtime) FIRST and hashes its content only when
  ## that metadata changed (Incremental-Invalidation.md §"File Fingerprint
  ## Policies"). The filesystem clock is coarse -- about a millisecond on
  ## Linux -- and this file rewrites one 1-byte input as "X", "Y", "X" in
  ## well under that, so the third write could carry the second one's size
  ## AND mtime to the nanosecond. The policy then rightly reads X's input as
  ## unchanged since Y's record, and Y's metadata-only record (strong
  ## fingerprint dropped by `hotMetadataRecord`) answered the lookup of X:
  ## reprobuild-pm issue
  ## 2026-11-15-per-computation-in-place-hit-returns-an-empty-record-on-linux.md,
  ## where one run in five failed. A rewrite a test means as a change must
  ## therefore be a metadata change, and an explicit clock makes it one on
  ## every run rather than on most. Whole seconds survive every platform's
  ## timestamp resolution, including `setLastModificationTime`'s.
  let input = fx.work / "sibling.nim"
  writeFile(input, content)
  inc fx.inputWrites
  setLastModificationTime(input,
    fromUnix(InputClockBase + int64(fx.inputWrites)))

proc stagedOutputs(fx: Fixture): seq[string] =
  @[fx.staging / "provider" / "project-provider",
    fx.staging / "provider-compile.rbsz"]

proc runComputation(fx: var Fixture; weak: ContentDigest;
                    inputContent, outputContent: string):
    ActionResultRecord =
  ## One execution: the input decides the computation, the run writes its
  ## outputs into staging, and the publish binds them.
  let input = fx.work / "sibling.nim"
  fx.writeInput(inputContent)
  createDir(fx.staging / "provider")
  writeFile(fx.staging / "provider" / "project-provider", outputContent)
  writeFile(fx.staging / "provider-compile.rbsz", "artifact:" & outputContent)
  fx.cache.recordActionResult(fx.cas, weak, ffpHybrid, [input],
    fx.stagedOutputs(), outputRoot = fx.work, storeOutputBlobs = false,
    computationStagingDir = fx.staging)

proc lookupInPlace(fx: var Fixture; weak: ContentDigest;
                   inputContent: string): ActionCacheLookup =
  fx.writeInput(inputContent)
  fx.cache.lookupActionResult(fx.cas, weak, ffpHybrid,
    verifyOutputBlobs = false, allowMetadataOnlyHit = true,
    outputRoot = fx.work)

proc craftedOutside(fx: Fixture; record: ActionResultRecord;
                    outside: string): ActionResultRecord =
  ## `record` with its outputs moved below `outside/<computation name>/`, as
  ## a hostile `.rec` carried in a store bundle could name them: the name
  ## the cleanup paths look for, in a directory outside the action cache.
  result = record
  let victim = outside / computationDirName(record.strongFingerprint)
  for i in 0 ..< result.outputs.len:
    result.outputs[i].path = victim / extractFilename(result.outputs[i].path)

suite "per-computation output directories (cache layer)":

  test "a publish moves staging to the record's computation directory":
    var fx = newFixture("percomp-publish-")
    defer: fx.close()
    let record = fx.runComputation(weakOf("edge-a"), "X", "binary-x")
    let expected = fx.identityDir / computationDirName(record.strongFingerprint)
    check recordComputationDir(record) == expected
    check dirExists(expected)
    check not dirExists(fx.staging)
    check fileExists(expected / "provider" / "project-provider")
    for output in record.outputs:
      check output.path.startsWith(expected & "/")
    check computationDirName(record.strongFingerprint).len == 32

  test "alternating computations each keep their outputs and hit in place":
    var fx = newFixture("percomp-alternate-")
    defer: fx.close()
    let weak = weakOf("edge-alternate")
    let x = fx.runComputation(weak, "X", "binary-x")
    let y = fx.runComputation(weak, "Y", "binary-yy")
    check x.strongFingerprint != y.strongFingerprint
    check dirExists(recordComputationDir(x))
    check dirExists(recordComputationDir(y))
    check recordComputationDir(x) != recordComputationDir(y)
    # X again: its record matches on inputs and its outputs are where it
    # left them, untouched by Y's run — the in-place (metadata-only) hit
    # the shared directory made impossible.
    let again = fx.lookupInPlace(weak, "X")
    check again.status in {aclHit, aclHybridCutoff}
    check again.record.strongFingerprint == x.strongFingerprint
    # The record that answered names X's outputs, where X left them. This
    # holds on every lookup path, including the metadata-only one that
    # carries no strong fingerprint, so it is what says WHICH computation hit.
    check again.record.outputs.len == x.outputs.len
    for output in again.record.outputs:
      check output.path.startsWith(recordComputationDir(x) & "/")
    let andY = fx.lookupInPlace(weak, "Y")
    check andY.status in {aclHit, aclHybridCutoff}
    check andY.record.strongFingerprint == y.strongFingerprint
    check andY.record.outputs.len == y.outputs.len
    for output in andY.record.outputs:
      check output.path.startsWith(recordComputationDir(y) & "/")

  test "a computation directory that was removed is a miss, not a stale hit":
    var fx = newFixture("percomp-removed-")
    defer: fx.close()
    let weak = weakOf("edge-removed")
    let x = fx.runComputation(weak, "X", "binary-x")
    # Never `removeDir` a computed path unchecked: an empty one makes
    # `removeDir("")` walk and delete the process's CURRENT DIRECTORY, which
    # is the checkout the test was run from (it did, on Windows, where
    # `recordComputationDir` returns "" -- reprobuild-pm issue
    # 2026-11-05-per-computation-output-dirs-are-never-bound-on-windows.md).
    let dir = recordComputationDir(x)
    check dir.len > 0
    if dir.len > 0:
      removeDir(dir)
    let lookup = fx.lookupInPlace(weak, "X")
    check lookup.status == aclRejectedCorruptOutput

  test "eviction by the per-edge cap removes the evicted record's directory":
    var fx = newFixture("percomp-evict-")
    defer: fx.close()
    let weak = weakOf("edge-evict")
    var records: seq[ActionResultRecord] = @[]
    # One more distinct computation than the per-edge cap keeps (8).
    for i in 0 ..< 9:
      records.add(fx.runComputation(weak, "input-" & $i, "binary-" & $i))
    let oldest = recordComputationDir(records[0])
    check oldest.len > 0
    check not dirExists(oldest)
    for i in 1 ..< 9:
      check dirExists(recordComputationDir(records[i]))

  test "the orphan sweep collects only directories no live record names":
    var fx = newFixture("percomp-sweep-")
    defer: fx.close()
    let weak = weakOf("edge-sweep")
    let kept = fx.runComputation(weak, "kept", "binary-kept")
    let dropped = fx.runComputation(weak, "dropped", "binary-dropped")
    let keptDir = recordComputationDir(kept)
    let droppedDir = recordComputationDir(dropped)
    # The record goes the way an older binary, or a crash before the record
    # write, would leave it: its `.rec` file is gone, its directory is not.
    let edgeDir = fx.root / "action-cache" / "hot-records" /
      perEdgeRecordFileName(weak)
    let droppedRec = edgeDir / (toHex(dropped.strongFingerprint.bytes) & ".rec")
    check fileExists(droppedRec)
    removeFile(droppedRec)
    # A run in progress owns `staging/`, and a legacy single-directory
    # layout leaves `work/` that no record names.
    createDir(fx.staging / "work")
    createDir(fx.identityDir / "work")
    let pending = fx.root / "gc" / "pending-deletion"
    let now = toUnix(getTime()) + 3600
    # Within the grace period nothing is collected.
    let young = sweepOrphanComputationDirs(fx.root, pending, 7200,
      nowUnix = now)
    check young.refused == ""
    check young.orphaned.len == 0
    check young.skippedYoung == 2
    check dirExists(droppedDir)
    # Past it, the orphan and the legacy directory go to pending deletion;
    # the live record's directory and staging stay.
    let sweep = sweepOrphanComputationDirs(fx.root, pending, 60,
      nowUnix = now)
    check sweep.refused == ""
    check sweep.orphaned.toHashSet ==
      [droppedDir, fx.identityDir / "work"].toHashSet
    check sweep.quarantined.len == 2
    check not dirExists(droppedDir)
    check not dirExists(fx.identityDir / "work")
    check dirExists(keptDir)
    check dirExists(fx.staging)
    for moved in sweep.quarantined:
      check moved.startsWith(pending & "/")
      check dirExists(moved)
    # The live record still hits after the sweep.
    let hit = fx.lookupInPlace(weak, "kept")
    check hit.status in {aclHit, aclHybridCutoff}

suite "a record cannot have a directory outside recipe-compiles deleted":
  ## reprobuild-pm issue
  ## 2026-11-17-carried-action-records-may-name-output-paths-outside-the-bundle-roots.md:
  ## the cleanup paths deleted the directory a record's OWN output paths
  ## named, wherever it was. Store-Bundles.md §5.1 and
  ## Hermetic-Builds-And-Path-Independence.md §"Ownership and cleanup".

  test "ownedComputationDir admits only <recipe-compiles>/<kind>/<identity>/<entry>":
    var fx = newFixture("percomp-owned-")
    defer: fx.close()
    let x = fx.runComputation(weakOf("edge-owned"), "X", "binary-x")
    let recipeRoot = fx.cache.recipeCompilesRootOf
    check ownedComputationDir(x, recipeRoot) == recordComputationDir(x)
    check ownedComputationDir(x, "") == ""
    let outside = fx.root / "outside"
    check ownedComputationDir(fx.craftedOutside(x, outside), recipeRoot) == ""
    # Inside recipe-compiles, but not at the entry level.
    check ownedComputationDir(fx.craftedOutside(x, recipeRoot / "provider"),
      recipeRoot) == ""
    check ownedComputationDir(fx.craftedOutside(x,
      fx.identityDir / "nested"), recipeRoot) == ""

  test "evicting a crafted record leaves the directory it names alone":
    var fx = newFixture("percomp-evict-outside-")
    defer: fx.close()
    let weak = weakOf("edge-evict-outside")
    let first = fx.runComputation(weak, "input-0", "binary-0")
    let outside = fx.root / "outside"
    let crafted = fx.craftedOutside(first, outside)
    let victim = recordComputationDir(crafted)
    check victim == outside / computationDirName(first.strongFingerprint)
    createDir(victim)
    writeFile(victim / "precious", "not the cache's")
    # Replace the real record with the crafted one, still the oldest.
    fx.cache.writePerEdgeRecords(weak, [crafted])
    for i in 1 ..< 9:
      discard fx.runComputation(weak, "input-" & $i, "binary-" & $i)
    let edgeDir = fx.root / "action-cache" / "hot-records" /
      perEdgeRecordFileName(weak)
    # The crafted record was the one evicted ...
    check not fileExists(edgeDir /
      (toHex(first.strongFingerprint.bytes) & ".rec"))
    # ... and the directory it named outside the cache survived.
    check fileExists(victim / "precious")

  test "the retention GC never claims a directory outside recipe-compiles":
    var fx = newFixture("percomp-gc-outside-")
    defer: fx.close()
    let weak = weakOf("edge-gc-outside")
    let first = fx.runComputation(weak, "X", "binary-x")
    let crafted = fx.craftedOutside(first, fx.root / "outside")
    fx.cache.writePerEdgeRecords(weak, [crafted])
    let victim = recordComputationDir(crafted)
    var found = false
    for entry in fx.cache.scanCacheEntries(RetentionGcPolicy()):
      check victim notin entry.computationDirs
      found = true
    check found

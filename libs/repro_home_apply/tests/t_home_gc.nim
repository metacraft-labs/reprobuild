## M10 — ``repro home gc`` engine tests.
##
## Three hermetic test areas:
##
##   1. The keep-set / orphan diff against a synthetic generation
##      registry + sandbox store. (Covers the spec's
##      ``t_home_gc_identifies_orphaned_prefixes`` and
##      ``t_home_gc_respects_keep_generations_threshold`` gates.)
##
##   2. The junction-hazard regression: a sandbox store prefix
##      containing a junction-into-real-user-data; ``gc --force``
##      removes the junction but the user-data target's bytes are
##      identical before + after. (The spec's
##      ``t_home_gc_junction_hazard_regression`` gate — the explicit
##      defense for ``project_reprobuild_store_junction_hazard``.)
##
##   3. The active generation is NEVER deleted even if it is not in
##      the top-N by activation timestamp (spec: "the
##      ``--keep-generations`` flag must always preserve at least 1
##      (the active one)").

import std/[os, sets, strutils, times, unittest]
from repro_core/paths import extendedPath

import blake3
import repro_home_apply/gc
import repro_home_apply/junction_aware_remove
import repro_home_generations
import repro_local_store

const FixtureRoot = "build/test-tmp/t-home-gc"

# ---------------------------------------------------------------------------
# Sandbox helpers.
# ---------------------------------------------------------------------------

proc resetDir(path: string) =
  if dirExists(extendedPath(path)):
    # Use junction-aware to avoid recursing through leftover junctions
    # from a previous run (the test creates real junctions on Windows).
    removeJunctionAware(path)
  createDir(extendedPath(path))

proc digestFromTag(tag: string): Digest256 =
  ## Deterministic 32-byte BLAKE3 derivation of an arbitrary tag —
  ## gives each synthetic prefix a stable, unique id.
  var buf: seq[byte] = @[]
  for ch in tag: buf.add(byte(ord(ch)))
  let d = blake3.digest(buf)
  for i in 0 ..< 32:
    result[i] = d[i]

proc prefixIdFromTag(tag: string): PrefixIdBytes =
  let d = digestFromTag(tag)
  for i in 0 ..< 32:
    result[i] = d[i]

proc seedPrefix(store: var Store; packageName, version, tag: string;
               contentBytes: int): tuple[id: PrefixIdBytes; digest: Digest256;
                                         absPath: string] =
  ## Create a synthetic prefix on disk + an index row referencing it.
  ## ``contentBytes`` controls the size of a single payload file inside
  ## the prefix so the gc footprint accounting can be exercised.
  let id = prefixIdFromTag(tag)
  let relative = prefixRelativePath(packageName, version, id)
  let abs = store.absolutePrefixPath(relative)
  createDir(extendedPath(parentDir(abs)))
  createDir(extendedPath(abs))
  if contentBytes > 0:
    writeFile(extendedPath(abs / "payload.bin"), "x".repeat(contentBytes))
  # Insert a minimal index row. Receipt digest is reused as the prefix
  # id (the test never validates receipt content) — keeps the gc test
  # focused on its own concerns.
  let row = PrefixRow(
    prefixId: id,
    packageName: packageName,
    version: version,
    realizedPath: relative.replace('\\', '/'),
    adapter: "scoop",
    receiptDigest: id,
    createdAtUnix: getTime().toUnix)
  discard store.insertPrefixOrIgnore(row)
  result.id = id
  result.digest = digestFromTag(tag)
  result.absPath = abs

proc seedGeneration(stateDir: string; store: var Store;
                    tag: string; activationTs: int64;
                    prefixDigests: seq[Digest256];
                    setActive = false): string =
  ## Write a real generation via the M83 registry's public writer.
  ## Returns the hex generation id. ``setActive`` updates the
  ## ``current`` marker.
  var envelope = PointerEnvelope(
    schemaVersion: 1'u16,
    activationTimestamp: activationTs,
    hostIdentity: "test-host",
    realizedPrefixIds: prefixDigests)
  for i in 0 ..< 32:
    envelope.intentSnapshotDigest[i] = byte(0x10 + i)
    envelope.configurableGraphDigest[i] = byte(0x40 + i)
    envelope.activationManifestDigest[i] = byte(0x80 + i)
  envelope.generationId = computeGenerationId(envelope.intentSnapshotDigest,
    envelope.hostIdentity & "-" & tag, envelope.activationTimestamp)
  # ``writeGeneration`` requires CAS-resident manifest / snapshot /
  # rbcg blobs. We pass small distinct sentinel bytes so each
  # generation seals into a different CAS entry.
  let manifestBytes = @[byte('m'), byte('a'), byte('n'),
                        byte(ord('0') + (activationTs mod 10))]
  let snapshotBytes = @[byte('s'), byte('n'), byte('p'),
                        byte(ord('0') + (activationTs mod 10))]
  let rbcgBytes = @[byte('r'), byte('b'), byte('c'), byte('g'),
                    byte(ord('0') + (activationTs mod 10))]
  writeGeneration(stateDir, envelope, manifestBytes, snapshotBytes,
    rbcgBytes, store)
  result = generationIdHex(envelope.generationId)
  if setActive:
    writeCurrentGenerationId(stateDir, result)

# ---------------------------------------------------------------------------
# Tests.
# ---------------------------------------------------------------------------

suite "M10 — repro home gc engine":

  test "test_m10_gc_identifies_orphaned_prefixes":
    ## 3 generations + 5 prefixes; 3 prefixes are referenced by some
    ## generation in the top-2 keep window; 2 prefixes are orphaned.
    ## ``gc --dry-run`` lists the 2 orphans + their footprint; the
    ## 3 live prefixes are NOT in the candidate list.
    let stateDir = FixtureRoot / "scenario-orphans/state"
    let storeRoot = FixtureRoot / "scenario-orphans/store"
    resetDir(stateDir)
    resetDir(storeRoot)
    var store = openStore(storeRoot)

    # 5 prefixes with distinct sizes so we can assert per-prefix
    # footprint accounting.
    let p1 = seedPrefix(store, "pkg-live-1", "1.0.0", "live-1", 128)
    let p2 = seedPrefix(store, "pkg-live-2", "1.0.0", "live-2", 256)
    let p3 = seedPrefix(store, "pkg-live-3", "1.0.0", "live-3", 64)
    let p4 = seedPrefix(store, "pkg-orphan-1", "0.9", "orph-1", 1024)
    let p5 = seedPrefix(store, "pkg-orphan-2", "0.8", "orph-2", 2048)

    # 3 generations, oldest first. Gen-old references the to-be-
    # orphaned p4 + p5; gen-mid + gen-new (the keep window when
    # --keep-generations=2) reference p1/p2 and p2/p3 respectively.
    discard seedGeneration(stateDir, store, "old", 1700000000'i64,
      @[p4.digest, p5.digest])
    discard seedGeneration(stateDir, store, "mid", 1700001000'i64,
      @[p1.digest, p2.digest])
    let activeId = seedGeneration(stateDir, store, "new", 1700002000'i64,
      @[p2.digest, p3.digest], setActive = true)
    store.close()

    var opts = GcOptions(
      dryRun: true,
      keepGenerations: 2,
      storeRoot: storeRoot,
      stateDir: stateDir)
    let report = runHomeGc(opts)
    check report.outcome == goSkippedDryRun
    check report.keptGenerationIds.len == 2
    check activeId in report.keptGenerationIds
    check report.candidates.len == 2

    var orphanPaths: seq[string]
    var orphanIds: HashSet[string]
    for c in report.candidates:
      orphanPaths.add(c.absolutePath)
      orphanIds.incl(c.prefixIdHex)
    check p4.absPath in orphanPaths
    check p5.absPath in orphanPaths
    check (p1.absPath notin orphanPaths)
    check (p2.absPath notin orphanPaths)
    check (p3.absPath notin orphanPaths)

    # Footprint accounting: the 2 orphan payloads sum to ~3072 bytes
    # (plus ~0 for the empty receipt-less dir overhead). We assert a
    # tight lower bound; the upper bound is loose because dir entries
    # may or may not pull in filesystem metadata bytes.
    check report.candidateBytes >= 1024 + 2048
    check report.candidateBytes < 1024 + 2048 + 4096

    # Dry-run MUST NOT delete anything.
    check dirExists(extendedPath(p1.absPath))
    check dirExists(extendedPath(p2.absPath))
    check dirExists(extendedPath(p3.absPath))
    check dirExists(extendedPath(p4.absPath))
    check dirExists(extendedPath(p5.absPath))

  test "test_m10_gc_force_deletes_orphans_keeps_live":
    ## Same fixture; this time --force runs the real delete. Orphan
    ## prefixes are GONE, live prefixes are intact, the M83 registry
    ## is NOT mutated.
    let stateDir = FixtureRoot / "scenario-force/state"
    let storeRoot = FixtureRoot / "scenario-force/store"
    resetDir(stateDir)
    resetDir(storeRoot)
    var store = openStore(storeRoot)
    let p1 = seedPrefix(store, "live-a", "1.0", "live-a", 100)
    let p2 = seedPrefix(store, "live-b", "1.0", "live-b", 100)
    let p3 = seedPrefix(store, "live-c", "1.0", "live-c", 100)
    let p4 = seedPrefix(store, "orphan-a", "1.0", "orphan-a", 500)
    let p5 = seedPrefix(store, "orphan-b", "1.0", "orphan-b", 500)
    discard seedGeneration(stateDir, store, "old", 1700000000'i64,
      @[p4.digest, p5.digest])
    discard seedGeneration(stateDir, store, "mid", 1700001000'i64,
      @[p1.digest, p2.digest])
    discard seedGeneration(stateDir, store, "new", 1700002000'i64,
      @[p2.digest, p3.digest], setActive = true)
    store.close()

    # Snapshot the registry generation count BEFORE gc so we can
    # assert no registry mutation post-gc.
    let preGens = enumerateGenerations(stateDir)
    check preGens.len == 3

    var opts = GcOptions(
      autoConfirm: true,
      keepGenerations: 2,
      storeRoot: storeRoot,
      stateDir: stateDir)
    let report = runHomeGc(opts)
    check report.outcome == goDeleted
    check report.deletedCount == 2
    check report.failedCount == 0
    check report.reclaimedBytes >= 1000

    # Live prefixes survive.
    check dirExists(extendedPath(p1.absPath))
    check dirExists(extendedPath(p2.absPath))
    check dirExists(extendedPath(p3.absPath))
    # Orphan prefixes are gone.
    check (not dirExists(extendedPath(p4.absPath)))
    check (not dirExists(extendedPath(p5.absPath)))

    # Registry is UNTOUCHED — exact same 3 generations + same ids.
    let postGens = enumerateGenerations(stateDir)
    check postGens.len == 3
    for i in 0 ..< 3:
      check postGens[i].generationId == preGens[i].generationId

  test "test_m10_gc_respects_keep_generations_threshold":
    ## Prefix orphaned for EXACTLY 1 generation. Default
    ## --keep-generations=2 keeps it; --keep-generations=1 reports
    ## it.
    let stateDir = FixtureRoot / "scenario-threshold/state"
    let storeRoot = FixtureRoot / "scenario-threshold/store"
    resetDir(stateDir)
    resetDir(storeRoot)
    var store = openStore(storeRoot)
    let pA = seedPrefix(store, "thresh-a", "1.0", "thresh-a", 100)
    let pB = seedPrefix(store, "thresh-b", "1.0", "thresh-b", 100)
    # gen-old refs pA only (so pA will be 1-generation-orphaned
    # when we ship gen-new with only pB).
    discard seedGeneration(stateDir, store, "old", 1700000000'i64,
      @[pA.digest])
    discard seedGeneration(stateDir, store, "new", 1700001000'i64,
      @[pB.digest], setActive = true)
    store.close()

    # Default keep=2 → both generations are in the keep set; pA is
    # still referenced by gen-old; report is empty.
    let r1 = runHomeGc(GcOptions(
      dryRun: true,
      keepGenerations: 2,
      storeRoot: storeRoot,
      stateDir: stateDir))
    check r1.outcome == goNoCandidates
    check r1.candidates.len == 0

    # keep=1 → only gen-new (the active one) is in the keep set; pA
    # is no longer referenced; pA is reported.
    let r2 = runHomeGc(GcOptions(
      dryRun: true,
      keepGenerations: 1,
      storeRoot: storeRoot,
      stateDir: stateDir))
    check r2.outcome == goSkippedDryRun
    check r2.candidates.len == 1
    check r2.candidates[0].absolutePath == pA.absPath

  test "test_m10_gc_active_generation_always_preserved":
    ## Even with --keep-generations=1 and the active generation
    ## being the OLDEST by timestamp, the active gen's prefixes
    ## must NOT be deleted. The spec is explicit: "the
    ## --keep-generations flag must always preserve at least 1
    ## (the active one)".
    let stateDir = FixtureRoot / "scenario-active/state"
    let storeRoot = FixtureRoot / "scenario-active/store"
    resetDir(stateDir)
    resetDir(storeRoot)
    var store = openStore(storeRoot)
    let pActive = seedPrefix(store, "active-pkg", "1.0", "active-pkg", 100)
    let pNewer = seedPrefix(store, "newer-pkg", "1.0", "newer-pkg", 100)
    # Active is OLDEST by ts. With keep=1, naive logic would pick
    # gen-newer (the top-1 by ts) and ORPHAN pActive — that would
    # be a hazard. The engine must override with the active marker.
    let activeId = seedGeneration(stateDir, store, "active",
      1700000000'i64, @[pActive.digest], setActive = true)
    discard seedGeneration(stateDir, store, "newer", 1700001000'i64,
      @[pNewer.digest])
    store.close()

    let report = runHomeGc(GcOptions(
      dryRun: true,
      keepGenerations: 1,
      storeRoot: storeRoot,
      stateDir: stateDir))
    check activeId in report.keptGenerationIds
    # The active prefix MUST NOT be a candidate.
    for c in report.candidates:
      check c.absolutePath != pActive.absPath

  test "test_m10_gc_junction_hazard_regression":
    ## CRITICAL — per ``project_reprobuild_store_junction_hazard``.
    ## An orphaned prefix contains a junction (Windows) / symlink
    ## (POSIX) pointing INTO a separate "user-data" tree. gc
    ## --force unlinks the orphan; the user-data target's bytes
    ## are IDENTICAL before + after.
    let stateDir = FixtureRoot / "scenario-junction/state"
    let storeRoot = FixtureRoot / "scenario-junction/store"
    let userData = FixtureRoot / "scenario-junction/userdata"
    resetDir(stateDir)
    resetDir(storeRoot)
    resetDir(userData)
    # Build the "user data" outside the store.
    writeFile(extendedPath(userData / "must-survive.txt"),
      "REAL USER DATA — gc MUST NOT touch this\n")
    writeFile(extendedPath(userData / "second.txt"), "intact\n")
    createDir(extendedPath(userData / "nested"))
    writeFile(extendedPath(userData / "nested" / "deep.txt"),
      "deep content\n")
    let beforeMain = readFile(extendedPath(userData / "must-survive.txt"))
    let beforeSecond = readFile(extendedPath(userData / "second.txt"))
    let beforeDeep = readFile(extendedPath(userData /
      "nested" / "deep.txt"))

    var store = openStore(storeRoot)
    # Seed an orphaned prefix with a junction inside it.
    let orphan = seedPrefix(store, "orphan-junction", "1.0",
      "orph-with-junction", 32)
    let junctionPath = orphan.absPath / "user-data-junction"
    when defined(windows):
      let rc = execShellCmd("cmd /c mklink /J " &
        quoteShell(junctionPath) & " " & quoteShell(absolutePath(userData)))
      check rc == 0
    else:
      createSymlink(absolutePath(userData), junctionPath)
    check isJunction(junctionPath)
    check fileExists(extendedPath(junctionPath / "must-survive.txt"))

    # Active generation references a different prefix so orphan is
    # ACTUALLY orphaned.
    let unrelated = seedPrefix(store, "active-unrelated", "1.0",
      "active-unrelated", 32)
    discard seedGeneration(stateDir, store, "active", 1700000000'i64,
      @[unrelated.digest], setActive = true)
    store.close()

    let report = runHomeGc(GcOptions(
      autoConfirm: true,
      keepGenerations: 2,
      storeRoot: storeRoot,
      stateDir: stateDir))
    check report.outcome == goDeleted
    check report.deletedCount >= 1
    check (not dirExists(extendedPath(orphan.absPath)))

    # THE CRITICAL ASSERT: the user-data target survives,
    # byte-identical to the pre-gc snapshot.
    check dirExists(extendedPath(userData))
    check fileExists(extendedPath(userData / "must-survive.txt"))
    check fileExists(extendedPath(userData / "second.txt"))
    check fileExists(extendedPath(userData / "nested" / "deep.txt"))
    check readFile(extendedPath(userData / "must-survive.txt")) == beforeMain
    check readFile(extendedPath(userData / "second.txt")) == beforeSecond
    check readFile(extendedPath(userData /
      "nested" / "deep.txt")) == beforeDeep

  test "test_m10_gc_confirm_callback_no_proceeds_without_delete":
    ## The operator's "n" answer leaves all candidates intact.
    let stateDir = FixtureRoot / "scenario-cancel/state"
    let storeRoot = FixtureRoot / "scenario-cancel/store"
    resetDir(stateDir)
    resetDir(storeRoot)
    var store = openStore(storeRoot)
    let live = seedPrefix(store, "live", "1.0", "cancel-live", 100)
    let orph = seedPrefix(store, "orph", "1.0", "cancel-orph", 100)
    discard seedGeneration(stateDir, store, "g1", 1700000000'i64,
      @[live.digest], setActive = true)
    store.close()

    var prompted = false
    proc noConfirm(n: int; b: int64): bool {.gcsafe.} =
      prompted = true
      false

    let report = runHomeGc(GcOptions(
      keepGenerations: 2,
      storeRoot: storeRoot,
      stateDir: stateDir,
      confirm: noConfirm))
    check prompted
    check report.outcome == goSkippedCancelled
    check report.deletedCount == 0
    # The orphan candidate was identified BUT not deleted.
    check report.candidates.len == 1
    check dirExists(extendedPath(orph.absPath))
    check dirExists(extendedPath(live.absPath))

  test "test_m10_gc_no_candidates_on_clean_store":
    ## Every prefix in the store is referenced by the active
    ## generation; gc reports no candidates + outcome=noCandidates.
    let stateDir = FixtureRoot / "scenario-clean/state"
    let storeRoot = FixtureRoot / "scenario-clean/store"
    resetDir(stateDir)
    resetDir(storeRoot)
    var store = openStore(storeRoot)
    let p1 = seedPrefix(store, "p1", "1.0", "clean-p1", 100)
    let p2 = seedPrefix(store, "p2", "1.0", "clean-p2", 100)
    discard seedGeneration(stateDir, store, "g1", 1700000000'i64,
      @[p1.digest, p2.digest], setActive = true)
    store.close()
    let r = runHomeGc(GcOptions(
      dryRun: true,
      keepGenerations: 2,
      storeRoot: storeRoot,
      stateDir: stateDir))
    check r.outcome == goNoCandidates
    check r.candidates.len == 0
    check r.candidateBytes == 0

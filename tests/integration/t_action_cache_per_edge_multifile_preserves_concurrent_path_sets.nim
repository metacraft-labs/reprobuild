import std/[os, strutils, tempfiles, unittest]

import repro_hash
import repro_local_store

import repro_test_support

# AC-1b (Action-Cache-Per-Edge-Store.md §3, §8): Tier-1 stores each edge as a
# DIRECTORY `hot-records/<key>/` of `<nonce>.rec` path-set files instead of a
# single `hot-records/<key>` file. Two INDEPENDENT concurrent builds of the
# SAME edge (same weak fingerprint) that observed DIFFERENT path-sets (different
# strong fingerprints — e.g. one saw an optional input, the other didn't) must
# BOTH survive: a later lookup matching path-set A hits A's record, a later
# lookup matching path-set B hits B's record. Neither clobbers the other.
#
# Falsifiable: revert to AC-1's single-file last-rename-wins and recording B
# overwrites A's file — the "path-set A present" lookup no longer hits A's
# distinct record (only B survives), so the A-specific assertion fails.
#
# Convergence: re-recording an IDENTICAL path-set (same strong fingerprint)
# targets the SAME nonce file (an atomic overwrite), so the directory does not
# accumulate duplicates — the file count stays bounded.

proc asBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc weakFor(name: string): ContentDigest =
  blake3DomainDigest(asBytes("reprobuild.ac1b.multifile." & name),
    hdActionFingerprint)

proc recFilesFor(cacheRoot: string; weak: ContentDigest): seq[string] =
  ## The `<nonce>.rec` path-set files inside the edge's directory.
  let dir = cacheRoot / "hot-records" / perEdgeRecordFileName(weak)
  if not dirExists(dir):
    return
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".rec"):
      result.add(path)

suite "integration_action_cache_per_edge_multifile_preserves_concurrent_path_sets":
  when isNixSupported:
    test "two concurrent path-sets for one edge both survive; identical path-sets converge":
      let tempRoot = createTempDir("repro-ac1b-multifile", "")
      defer: removeDir(tempRoot)

      let reproRoot = tempRoot / ".repro"
      let cacheRoot = reproRoot / "action-cache"
      let cas = openLocalCas(reproRoot / "cas")
      var cache = openActionCache(cacheRoot)

      let actionRoot = tempRoot / "action"
      createDir(actionRoot)

      # One edge (one weak fingerprint), observed by two independent builds.
      let weak = weakFor("shared-edge")

      let inputPath = actionRoot / "input.txt"
      let outputPath = actionRoot / "out.txt"

      # -- Build A: observed path-set A (input content "alpha"). Under
      # ffpChecksum the strong fingerprint is over the input CONTENT hash, so a
      # distinct content ⇒ a distinct strong fingerprint ⇒ a distinct path-set.
      # Its output is distinctive so a hit can be attributed to path-set A.
      writeFile(inputPath, "alpha\n")
      writeFile(outputPath, "OUTPUT-FROM-PATHSET-A\n")
      let recordA = cache.recordActionResult(cas, weak, ffpChecksum,
        [inputPath], ["out.txt"], actionRoot)
      let strongA = recordA.strongFingerprint

      # -- Build B: an INDEPENDENT concurrent build of the SAME edge that
      # observed a DIFFERENT path-set B (input content "bravo") and produced a
      # distinctive output. AC-1's single-file rename would CLOBBER A here.
      writeFile(inputPath, "bravo\n")
      writeFile(outputPath, "OUTPUT-FROM-PATHSET-B\n")
      let recordB = cache.recordActionResult(cas, weak, ffpChecksum,
        [inputPath], ["out.txt"], actionRoot)
      let strongB = recordB.strongFingerprint

      # The two builds genuinely disagree on the path-set.
      check strongA != strongB

      # BOTH path-sets are preserved on disk: the edge directory holds two
      # distinct `<nonce>.rec` files (one per path-set), not one clobbered file.
      check dirExists(cacheRoot / "hot-records" / perEdgeRecordFileName(weak))
      check recFilesFor(cacheRoot, weak).len == 2

      # -- A later lookup matching path-set A hits A's record (not B's).
      writeFile(inputPath, "alpha\n")
      removeFile(outputPath)
      let hitA = cache.lookupActionResult(cas, weak, ffpChecksum)
      check hitA.status == aclHit
      check hitA.record.strongFingerprint == strongA
      cas.restoreOutputs(hitA.record, actionRoot)
      check readFile(outputPath) == "OUTPUT-FROM-PATHSET-A\n"

      # -- A later lookup matching path-set B hits B's record (not A's). This is
      # the record AC-1 would have LOST to last-rename-wins.
      writeFile(inputPath, "bravo\n")
      removeFile(outputPath)
      let hitB = cache.lookupActionResult(cas, weak, ffpChecksum)
      check hitB.status == aclHit
      check hitB.record.strongFingerprint == strongB
      cas.restoreOutputs(hitB.record, actionRoot)
      check readFile(outputPath) == "OUTPUT-FROM-PATHSET-B\n"

      # -- Convergence: re-recording an IDENTICAL path-set (same content ⇒ same
      # strong fingerprint) targets the SAME nonce file. The directory does NOT
      # accumulate — still exactly two `.rec` files after many rewrites.
      for _ in 0 ..< 50:
        writeFile(inputPath, "alpha\n")
        writeFile(outputPath, "OUTPUT-FROM-PATHSET-A\n")
        discard cache.recordActionResult(cas, weak, ffpChecksum,
          [inputPath], ["out.txt"], actionRoot)
        writeFile(inputPath, "bravo\n")
        writeFile(outputPath, "OUTPUT-FROM-PATHSET-B\n")
        discard cache.recordActionResult(cas, weak, ffpChecksum,
          [inputPath], ["out.txt"], actionRoot)
      check recFilesFor(cacheRoot, weak).len == 2

      # -- Re-open (a fresh process view): both path-sets still resolve, proving
      # the union read merges every `.rec` in the edge directory.
      var reopened = openActionCache(cacheRoot)
      writeFile(inputPath, "alpha\n")
      removeFile(outputPath)
      let reA = reopened.lookupActionResult(cas, weak, ffpChecksum)
      check reA.status == aclHit
      check reA.record.strongFingerprint == strongA
      writeFile(inputPath, "bravo\n")
      let reB = reopened.lookupActionResult(cas, weak, ffpChecksum)
      check reB.status == aclHit
      check reB.record.strongFingerprint == strongB

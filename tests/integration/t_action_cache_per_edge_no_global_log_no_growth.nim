import std/[os, tempfiles, unittest]

import repro_hash
import repro_local_store

import repro_test_support

# AC-1 (Action-Cache-Per-Edge-Store.md §2, §3): the action cache stores each
# edge's record set in a single authoritative `hot-records/<key>` file written
# by temp-file + atomic rename. There is NO global `action-results.*`
# append-log/index anymore, so:
#   * a build writes ONLY per-edge files, and
#   * re-executing the SAME edge rewrites its one file (dedup within the file),
#     keeping total cache size BOUNDED instead of growing per write.
# Falsifiable: reinstating an append leg (or recreating the global files) makes
# the global files reappear and/or the total size grow unboundedly.

proc asBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc weakFor(name: string): ContentDigest =
  blake3DomainDigest(asBytes("reprobuild.ac1.per-edge." & name),
    hdActionFingerprint)

const GlobalStoreFiles = [
  "action-results.records",
  "action-results.hot.records",
  "action-results.hot.index"]

proc noGlobalStoreFiles(cacheRoot: string): bool =
  for name in GlobalStoreFiles:
    if fileExists(cacheRoot / name):
      return false
  true

# AC-1b: `hot-records/<key>` is a DIRECTORY of `<nonce>.rec` files (one per
# observed path-set). "Per-edge" now means one directory; total on-disk record
# footprint is the sum of every `.rec` file across all edge directories.
proc perEdgeCount(cacheRoot: string): int =
  ## Number of edges (directories) in the store.
  let dir = cacheRoot / "hot-records"
  if not dirExists(dir):
    return 0
  for kind, path in walkDir(dir):
    if kind == pcDir:
      inc result

proc perEdgeStoreBytes(cacheRoot: string): int =
  let dir = cacheRoot / "hot-records"
  if not dirExists(dir):
    return 0
  for kind, path in walkDir(dir):
    if kind == pcDir:
      for k2, p2 in walkDir(path):
        if k2 == pcFile:
          result += int(getFileSize(p2))

suite "integration_action_cache_per_edge_no_global_log_no_growth":
  when isNixSupported:
    test "only per-edge files are written and re-execution stays bounded":
      let tempRoot = createTempDir("repro-ac1-no-growth", "")
      defer: removeDir(tempRoot)

      let reproRoot = tempRoot / ".repro"
      let cacheRoot = reproRoot / "action-cache"
      let cas = openLocalCas(reproRoot / "cas")
      var cache = openActionCache(cacheRoot)

      let actionRoot = tempRoot / "action"
      createDir(actionRoot)
      let inputPath = actionRoot / "input.txt"
      let outputPath = actionRoot / "out.txt"
      writeFile(inputPath, "alpha\n")
      writeFile(outputPath, "output-alpha\n")

      let weak = weakFor("edge-a")

      # First record for the edge.
      let record = cache.recordActionResult(cas, weak, ffpChecksum,
        [inputPath], ["out.txt"], actionRoot)
      check record.inputs.len == 1

      # Exactly one per-edge directory, and NO global append-log/index files.
      check perEdgeCount(cacheRoot) == 1
      check noGlobalStoreFiles(cacheRoot)
      check dirExists(cacheRoot / "hot-records")

      # The per-edge directory's name is derived from the edge's weak
      # fingerprint; it holds the edge's `<nonce>.rec` path-set files (AC-1b).
      check dirExists(cacheRoot / "hot-records" / perEdgeRecordFileName(weak))

      # The record is a cache hit.
      removeFile(outputPath)
      let hit = cache.lookupActionResult(cas, weak, ffpChecksum)
      check hit.status == aclHit
      cas.restoreOutputs(hit.record, actionRoot)
      check readFile(outputPath) == "output-alpha\n"

      # Re-execute the SAME edge (same inputs → same strong fingerprint) many
      # times. Each write is a REWRITE of the one per-edge file, so the store
      # stays a single file and the total size does not grow.
      let sizeAfterFirst = perEdgeStoreBytes(cacheRoot)
      check sizeAfterFirst > 0
      for _ in 0 ..< 200:
        discard cache.recordActionResult(cas, weak, ffpChecksum,
          [inputPath], ["out.txt"], actionRoot)
      check perEdgeCount(cacheRoot) == 1
      check perEdgeStoreBytes(cacheRoot) == sizeAfterFirst
      check noGlobalStoreFiles(cacheRoot)

      # A DIFFERENT edge gets its own file; the store grows by one bounded file,
      # never by an ever-growing global log.
      let weakB = weakFor("edge-b")
      let inputB = actionRoot / "input-b.txt"
      let outputB = actionRoot / "out-b.txt"
      writeFile(inputB, "bravo\n")
      writeFile(outputB, "output-bravo\n")
      discard cache.recordActionResult(cas, weakB, ffpChecksum,
        [inputB], ["out-b.txt"], actionRoot)
      check perEdgeCount(cacheRoot) == 2
      check noGlobalStoreFiles(cacheRoot)

      # Re-open across process-simulated boundary: still hits, still no global
      # files, still bounded.
      var reopened = openActionCache(cacheRoot)
      let reopenedHit = reopened.lookupActionResult(cas, weak, ffpChecksum)
      check reopenedHit.status == aclHit
      check noGlobalStoreFiles(cacheRoot)
      check perEdgeCount(cacheRoot) == 2

    test "pre-existing global files are ignored then deleted on open":
      let tempRoot = createTempDir("repro-ac1-legacy-cleanup", "")
      defer: removeDir(tempRoot)

      let cacheRoot = tempRoot / ".repro" / "action-cache"
      createDir(cacheRoot)
      # Simulate a cache migrated from the old global-log layout.
      for name in GlobalStoreFiles:
        writeFile(cacheRoot / name, "stale legacy global store bytes")
      check not noGlobalStoreFiles(cacheRoot)

      var cache = openActionCache(cacheRoot)
      # openActionCache ignores-then-deletes the legacy global files.
      check noGlobalStoreFiles(cacheRoot)
      # The (empty) cache still functions.
      let weak = weakFor("edge-after-cleanup")
      let cas = openLocalCas(tempRoot / ".repro" / "cas")
      let miss = cache.lookupActionResult(cas, weak, ffpChecksum)
      check miss.status == aclMissNoRecord

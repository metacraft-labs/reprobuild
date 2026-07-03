import std/[os, osproc, streams, tempfiles, unittest]

import repro_hash
import repro_local_store

import repro_test_support

# AC-1 (Action-Cache-Per-Edge-Store.md §2.1): two independent builds executing
# the SAME edge concurrently is benign — the edge is deterministic, so writers
# converge on an equivalent per-edge file via temp-file + atomic `rename()`.
# This test launches N worker PROCESSES that all write the record for one edge
# to one shared cache root. All complete, the single `hot-records/<key>` file
# ends VALID (decodes to a correct record), and the total store size stays
# bounded (one file, not an append log).
#
# Falsifiable: a non-atomic write (truncate-then-write with no rename) would let
# a reader / another writer observe a torn, half-written file under the
# concurrent writers — the final file would fail to decode or hold a garbled
# record.

proc asBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc weakFor(name: string): ContentDigest =
  blake3DomainDigest(asBytes("reprobuild.ac1.concurrent." & name),
    hdActionFingerprint)

const
  WorkerFlag = "--ac1-write-same-edge-worker"
  EdgeName = "shared-concurrent-edge"

proc runWorker(cacheRoot, casRoot, inputPath, outputRoot: string) =
  ## Child-process body: open the shared cache + CAS and write the shared
  ## edge's record repeatedly, so many writers' publish windows overlap.
  ## Kept deterministic so every worker produces an equivalent record.
  let cas = openLocalCas(casRoot)
  var cache = openActionCache(cacheRoot)
  let weak = weakFor(EdgeName)
  for _ in 0 ..< 40:
    discard cache.recordActionResult(cas, weak, ffpChecksum,
      [inputPath], ["out.txt"], outputRoot)

when isMainModule:
  let params = commandLineParams()
  if params.len >= 1 and params[0] == WorkerFlag:
    # params: flag, cacheRoot, casRoot, inputPath, outputRoot
    runWorker(params[1], params[2], params[3], params[4])
    quit(0)

proc perEdgeStoreBytes(cacheRoot: string): int =
  let dir = cacheRoot / "hot-records"
  if not dirExists(dir):
    return 0
  for kind, path in walkDir(dir):
    if kind == pcFile:
      result += int(getFileSize(path))

proc perEdgeFileCount(cacheRoot: string): int =
  let dir = cacheRoot / "hot-records"
  if not dirExists(dir):
    return 0
  for kind, path in walkDir(dir):
    if kind == pcFile:
      inc result

suite "integration_action_cache_concurrent_same_edge_converges_atomically":
  when isNixSupported:
    test "N concurrent writers of one edge converge on a valid bounded file":
      let tempRoot = createTempDir("repro-ac1-concurrent", "")
      defer: removeDir(tempRoot)

      let reproRoot = tempRoot / ".repro"
      let cacheRoot = reproRoot / "action-cache"
      let casRoot = reproRoot / "cas"
      let actionRoot = tempRoot / "action"
      createDir(actionRoot)
      let inputPath = actionRoot / "input.txt"
      let outputPath = actionRoot / "out.txt"
      writeFile(inputPath, "shared-input\n")
      writeFile(outputPath, "shared-output\n")

      # Pre-create the roots so every worker attaches to the same store.
      discard openLocalCas(casRoot)
      discard openActionCache(cacheRoot)

      let self = getAppFilename()
      let workerCount = 16
      let weak = weakFor(EdgeName)
      let perEdgeFile = cacheRoot / "hot-records" / perEdgeRecordFileName(weak)

      # Launch all workers as close to simultaneously as possible so their
      # temp-file + rename windows overlap.
      var procs: seq[Process] = @[]
      for _ in 0 ..< workerCount:
        procs.add(startProcess(self,
          args = @[WorkerFlag, cacheRoot, casRoot, inputPath, actionRoot],
          options = {poStdErrToStdOut}))

      # While the workers hammer the shared edge, a concurrent reader keeps
      # reading the per-edge file. Under atomic rename it must NEVER observe a
      # torn file: every non-empty snapshot decodes as a byte-complete record
      # set. A non-atomic truncate-then-write would let this reader catch a
      # half-written file. `torn` is the falsification signal.
      var torn = false
      var sawRecord = false
      proc anyRunning(): bool =
        for p in procs:
          if p.running():
            return true
        false
      while anyRunning():
        if fileExists(perEdgeFile):
          var raw: string
          try:
            raw = readFile(perEdgeFile)
          except CatchableError:
            raw = ""
          if raw.len > 0:
            var bytesSeq = newSeq[byte](raw.len)
            for i, ch in raw:
              bytesSeq[i] = byte(ord(ch))
            if perEdgeRecordFileIsIntact(bytesSeq):
              sawRecord = true
            else:
              torn = true

      var allOk = true
      for p in procs:
        let code = p.waitForExit()
        if code != 0:
          allOk = false
          checkpoint("worker exited with code " & $code & ": " &
            p.outputStream.readAll())
        p.close()
      check allOk
      # A reader concurrent with the writers never saw a torn file.
      check not torn
      check sawRecord

      # Exactly one per-edge file survives (one edge → one file), and it
      # decodes to a valid record for this edge.
      check perEdgeFileCount(cacheRoot) == 1
      check fileExists(cacheRoot / "hot-records" / perEdgeRecordFileName(weak))

      let cas = openLocalCas(casRoot)
      var cache = openActionCache(cacheRoot)
      removeFile(outputPath)
      let hit = cache.lookupActionResult(cas, weak, ffpChecksum)
      check hit.status == aclHit
      check hit.record.weakFingerprint == weak
      check hit.record.inputs.len == 1
      cas.restoreOutputs(hit.record, actionRoot)
      check readFile(outputPath) == "shared-output\n"

      # Total store size is bounded: one edge, at most
      # MaxRecordsPerWeakFingerprint path-sets — not N appended records.
      let singleRecordBytes = block:
        let soloRoot = tempRoot / "solo" / "action-cache"
        let soloCasRoot = tempRoot / "solo" / "cas"
        let soloCas = openLocalCas(soloCasRoot)
        var soloCache = openActionCache(soloRoot)
        discard soloCache.recordActionResult(soloCas, weak, ffpChecksum,
          [inputPath], ["out.txt"], actionRoot)
        perEdgeStoreBytes(soloRoot)
      # The concurrent store is no larger than a couple of single-edge writes.
      check perEdgeStoreBytes(cacheRoot) <= singleRecordBytes * 2

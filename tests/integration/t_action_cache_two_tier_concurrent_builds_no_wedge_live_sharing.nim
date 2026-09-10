import std/[os, osproc, streams, strutils, tempfiles, times, unittest]

import repro_hash
import repro_local_store

import repro_test_support

when defined(posix):
  import std/posix

# Action-Cache-Per-Edge-Store.md §1, §2, §6, §8 — the CAPSTONE.
# Wire the two-tier action cache into REAL concurrent build/engine processes
# sharing ONE cache root and assert the properties Tier 2 exists to deliver:
#
#   * NO WEDGE — N concurrent engine processes each record + look up many
#     overlapping edges and all complete within a bounded wall-time; the cache
#     root stays O(edges), never O(all-history).
#   * LIVE CROSS-BUILD SHARING — a record produced by build A becomes visible
#     to build B through shared memory the instant A's CAS lands, with no
#     process in between.
#   * CORRECTNESS — every hit is a VALID hit (strong-fp-correct; restored
#     outputs byte-correct); no false hit.
#   * FALLBACK — with the index DISABLED the same build still works (pure
#     Tier-1), proving the accelerator is optional.
#
# THE LIVE-SHARING SUBTEST WAS RE-SPECIFIED, AND THE REASON MATTERS. Under the
# ring tier it proved "served from shm" by DELETING build B's Tier-1 view of the
# edge, because the ring's shared table carried the whole record and could
# answer without the file. Under a REFERENCE model that same fixture is exactly
# the unresolvable case of §8 step 5 — a live key that does not resolve — whose
# specified outcome is the union fallback and a MISS. Keeping the old assertion
# would have required the index to serve a record whose file is gone, i.e. to
# assert the opposite of the semantics under test.
#
# What replaces it is the natural race rather than a contrived one: B reads the
# edge BEFORE A writes it (a genuine miss, which warms the index and marks the
# edge complete and EMPTY), A then writes and inserts, and B's next lookup must
# see the new record. That is the property live sharing actually means — one
# engine's publication is visible to another without either re-reading the
# world — and it is falsifiable in both directions, which the deletion fixture
# was not.

proc asBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc weakFor(name: string): ContentDigest =
  blake3DomainDigest(asBytes("reprobuild.ac4c.two-tier." & name),
    hdActionFingerprint)

const
  # A real `repro build`/engine records + looks up N overlapping edges against
  # ONE shared cache root; the binary re-execs itself as the worker.
  WorkerFlag = "--ac4c-build-worker"
  NumEdges = 24            ## edges each worker builds (overlapping across workers)
  NumWorkers = 8           ## concurrent engine PROCESSES sharing the cache root
  BoundedSeconds = 45.0    ## no-wedge wall-time bound for the whole concurrent run

proc runBuildWorker(cacheRoot, casRoot, workerRoot: string) =
  ## One REAL engine process: open the shared two-tier cache (create-or-attach
  ## on the chain) and, for every edge, record its result then look it up (a hit
  ## that restores the output). Overlapping edges across workers means
  ## cross-build contention on the SAME cache root — the wedge conditions. Each
  ## worker uses its OWN materialisation dir (`workerRoot`) so output restores do
  ## not race sibling workers, while the CACHE ROOT is shared (the tier under
  ## test). The recorded inputs are deterministic per edge, so all workers'
  ## records for an edge share one strong fingerprint and converge.
  createDir(workerRoot)
  let cas = openLocalCas(casRoot)
  var cache = openActionCache(cacheRoot)
  for round in 0 ..< 3:
    for e in 0 ..< NumEdges:
      let weak = weakFor("edge-" & $e)
      let inputPath = workerRoot / ("in-" & $e & ".txt")
      let outPath = workerRoot / ("out-" & $e & ".txt")
      # Deterministic content per edge (identical across workers ⇒ same strong
      # fp ⇒ convergence, no per-worker path-set blowup).
      writeFile(inputPath, "input-" & $e & "\n")
      writeFile(outPath, "output-" & $e & "\n")
      discard cache.recordActionResult(cas, weak, ffpChecksum,
        [inputPath], ["out-" & $e & ".txt"], workerRoot)
      # Look it up back (the hot path the whole tier accelerates). Remove the
      # output first so a hit must RESTORE it correctly (correctness gate).
      removeFile(outPath)
      let hit = cache.lookupActionResult(cas, weak, ffpChecksum)
      if hit.status != aclHit:
        quit(11)                          # a valid record must hit
      if hit.record.weakFingerprint != weak:
        quit(12)                          # wrong record => false hit
      cas.restoreOutputs(hit.record, workerRoot)
      if readFile(outPath) != "output-" & $e & "\n":
        quit(13)                          # restored output wrong
  cache.closeShmTier()
  quit(0)

when isMainModule:
  let params = commandLineParams()
  if params.len >= 3 and params[0] == WorkerFlag:
    runBuildWorker(params[1], params[2], params[3])
    quit(0)

proc perEdgeDirCount(cacheRoot: string): int =
  let dir = cacheRoot / "hot-records"
  if not dirExists(dir): return 0
  for kind, _ in walkDir(dir):
    if kind == pcDir: inc result

proc cacheRootBytes(cacheRoot: string): int =
  ## Total on-disk footprint of the per-edge store (all `.rec` files). Bounded
  ## by O(edges) — the anti-wedge invariant. A reinstated global append-log
  ## would make this grow with total history instead.
  let dir = cacheRoot / "hot-records"
  if not dirExists(dir): return 0
  for kind, path in walkDir(dir):
    if kind == pcDir:
      for k2, p2 in walkDir(path):
        if k2 == pcFile and p2.splitFile.ext == ".rec":
          try:
            result += int(getFileSize(p2))
          except OSError as err:
            # Atomic publish can rename a file between walkDir and stat. Only
            # durable `.rec` files count toward the bounded-store assertion.
            when defined(posix):
              if err.errorCode != ENOENT:
                raise
            else:
              raise

proc indexBytes(cacheRoot: string): int =
  ## The chain's on-disk footprint. §12.C's claim is that references cost three
  ## orders of magnitude less than a resident mirror of the record bytes would;
  ## measuring both here makes that a number rather than an inherited assertion.
  let dir = cacheRoot / "action-index"
  if not dirExists(dir): return 0
  for kind, path in walkDir(dir):
    if kind == pcFile:
      try: result += int(getFileSize(path))
      except OSError: discard

suite "integration_action_cache_two_tier_concurrent_builds_no_wedge_live_sharing":
  when isNixSupported:

    test "N concurrent builds: no wedge, bounded size, all correct":
      let tempRoot = createTempDir("repro-ac4c-nowedge", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / ".repro" / "action-cache"
      let casRoot = tempRoot / ".repro" / "cas"
      let actionRoot = tempRoot / "action"
      createDir(actionRoot)
      # Pre-create the shared roots so every worker attaches to the same store
      # and the same chain.
      discard openLocalCas(casRoot)
      var seed = openActionCache(cacheRoot)
      seed.closeShmTier()

      let self = getAppFilename()
      let started = epochTime()
      var procs: seq[Process] = @[]
      for w in 0 ..< NumWorkers:
        procs.add(startProcess(self,
          args = @[WorkerFlag, cacheRoot, casRoot, actionRoot / ("w" & $w)],
          options = {poStdErrToStdOut}))
      var allOk = true
      for p in procs:
        let code = p.waitForExit()
        if code != 0:
          allOk = false
          checkpoint("worker exited " & $code & ": " & p.outputStream.readAll())
        p.close()
      let elapsed = epochTime() - started
      check allOk
      # NO WEDGE: the whole concurrent run finished well within the bound. There
      # is no lock, no election and no drain loop for it to wedge on — every
      # participant only ever inserts into a structure whose merge is union.
      check elapsed < BoundedSeconds
      # BOUNDED SIZE: exactly one directory per edge — O(edges), never
      # O(all-history) despite NumWorkers*3 rounds of records per edge.
      check perEdgeDirCount(cacheRoot) == NumEdges
      let perEdge = block:
        let soloRoot = tempRoot / "solo" / "action-cache"
        let soloCas = openLocalCas(tempRoot / "solo" / "cas")
        var solo = openActionCache(soloRoot)
        writeFile(actionRoot / "in-solo.txt", "input-solo\n")
        writeFile(actionRoot / "out-solo.txt", "output-solo\n")
        discard solo.recordActionResult(soloCas, weakFor("solo"), ffpChecksum,
          [actionRoot / "in-solo.txt"], ["out-solo.txt"], actionRoot)
        solo.closeShmTier()
        cacheRootBytes(soloRoot)
      # Each edge holds at most the per-key `.rec` cap (8) of distinct worker
      # path-sets; the store is bounded by O(edges), independent of round count.
      check cacheRootBytes(cacheRoot) <= perEdge * NumEdges * 10
      checkpoint("tier-1 bytes=" & $cacheRootBytes(cacheRoot) &
        " index bytes=" & $indexBytes(cacheRoot) &
        " over " & $NumEdges & " edges")

    when actionIndexSupported:
      test "live cross-build sharing: B sees A's record without re-reading the world":
        let tempRoot = createTempDir("repro-ac4c-share", "")
        defer: removeDir(tempRoot)
        let cacheRoot = tempRoot / ".repro" / "action-cache"
        let casRoot = tempRoot / ".repro" / "cas"
        let actionRoot = tempRoot / "action"
        createDir(actionRoot)
        let cas = openLocalCas(casRoot)

        # Two independent engine handles on one root, exactly as two concurrent
        # `repro build` processes would be. Neither owns the chain; there is no
        # third party.
        var buildA = openActionCache(cacheRoot)
        var buildB = openActionCache(cacheRoot)
        defer:
          buildA.closeShmTier()
          buildB.closeShmTier()
        check buildA.shm.enabled
        check buildB.shm.enabled

        let weak = weakFor("shared-edge")
        writeFile(actionRoot / "shared-in.txt", "shared-input\n")
        writeFile(actionRoot / "shared-out.txt", "shared-output\n")

        # B READS FIRST, and this is the state the whole subtest turns on: a
        # genuine miss on an edge that does not exist yet. The miss warms the
        # index, so B now holds a live `edge-complete` element asserting the
        # edge is EMPTY — the strongest possible stale claim, and the one a
        # naive index would go on trusting.
        let beforeAny = buildB.lookupActionResult(cas, weak, ffpChecksum,
          outputRoot = actionRoot)
        check beforeAny.status == aclMissNoRecord
        let emptyView = buildB.shm.idx.enumerateEdge(weak)
        check emptyView.complete
        check emptyView.liveStrong.len == 0

        # A writes. §9: Tier-1 atomic rename, then cap, then the element
        # insert. The record is visible to every other engine on the host the
        # instant the CAS lands — no publish step, no daemon, no wakeup.
        let recorded = buildA.recordActionResult(cas, weak, ffpChecksum,
          [actionRoot / "shared-in.txt"], ["shared-out.txt"], actionRoot)

        # B's view of the edge is no longer empty, and B never re-read the
        # directory to learn it. Falsifiable in both directions: drop the
        # element insert from the write path and B's enumeration stays empty
        # (so B misses); drop B's enumeration and B is reading the directory
        # again, which is the thing this tier exists to avoid.
        let afterWrite = buildB.shm.idx.enumerateEdge(weak)
        check afterWrite.complete
        check afterWrite.liveStrong.len == 1
        check afterWrite.liveStrong[0] == recorded.strongFingerprint

        # And the lookup that follows is a real hit that restores real bytes.
        removeFile(actionRoot / "shared-out.txt")
        let served = buildB.lookupActionResult(cas, weak, ffpChecksum,
          outputRoot = actionRoot)
        check served.status == aclHit
        check served.record.weakFingerprint == weak
        check served.record.strongFingerprint == recorded.strongFingerprint
        cas.restoreOutputs(served.record, actionRoot)
        check readFile(actionRoot / "shared-out.txt") == "shared-output\n"

        # On a healthy root every §11 counter is zero. This is the assertion
        # that would catch a tier which "worked" only by falling back.
        let counters = buildB.actionIndexCounters()
        check counters.growthFailed == 0
        check counters.unresolvedReferences == 0
        check counters.bypassWrites == 0

    test "fallback: the index disabled still builds correctly (pure Tier-1)":
      # Force the accelerator OFF; the same record+lookup+restore must still work
      # entirely on the durable Tier-1 disk store, proving the index is OPTIONAL.
      putEnv("REPRO_ACTION_CACHE_SHM", "0")
      defer: delEnv("REPRO_ACTION_CACHE_SHM")
      let tempRoot = createTempDir("repro-ac4c-fallback", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / ".repro" / "action-cache"
      let casRoot = tempRoot / ".repro" / "cas"
      let actionRoot = tempRoot / "action"
      createDir(actionRoot)
      let cas = openLocalCas(casRoot)
      var cache = openActionCache(cacheRoot)
      check cache.shm == nil or not cache.shm.enabled   # the tier is OFF
      let weak = weakFor("fallback-edge")
      writeFile(actionRoot / "fb-in.txt", "fb-input\n")
      writeFile(actionRoot / "fb-out.txt", "fb-output\n")
      discard cache.recordActionResult(cas, weak, ffpChecksum,
        [actionRoot / "fb-in.txt"], ["fb-out.txt"], actionRoot)
      removeFile(actionRoot / "fb-out.txt")
      let hit = cache.lookupActionResult(cas, weak, ffpChecksum)
      check hit.status == aclHit
      cache.closeShmTier()

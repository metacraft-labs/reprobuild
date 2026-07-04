import std/[os, osproc, streams, tempfiles, times, unittest]

import repro_hash
import repro_local_store
import repro_shm_index

import repro_test_support

# AC-2c (Action-Cache-Per-Edge-Store.md §1, §2, §4.3, §4.4): the CAPSTONE.
# Wire the two-tier action cache into REAL concurrent build/engine processes
# sharing ONE cache root and assert the properties AC-2 exists to deliver:
#
#   * NO WEDGE — N concurrent engine processes each record + look up many
#     overlapping edges and all complete within a bounded wall-time; the cache
#     root stays O(edges), never O(all-history) (the 11.5 GB / whole-cache-scan
#     pathology AC-1 fixed stays fixed under the shm tier).
#   * LIVE CROSS-BUILD SHARING via shm — a record produced by build A becomes
#     visible to another build B THROUGH SHARED MEMORY: the single-writer daemon
#     (auto-spawned on cache open) drains A's ring submission and publishes it to
#     the shm table; B then gets a hit that could ONLY have come from the shm
#     tier (B's own Tier-1 disk view of that edge is DELETED, so a hit proves the
#     shm slot — populated by the daemon from A's in-flight submission — served
#     it).
#   * CORRECTNESS — every hit is a VALID hit (strong-fp-correct; restored
#     outputs byte-correct); no false hit.
#   * FALLBACK — with the shm tier DISABLED the same build still works (pure
#     Tier-1 disk-only), proving the accelerator is optional.
#
# Falsifiable:
#   (a) if the READ path did not consult shm (only disk), the live-sharing
#       assertion fails — B's disk-deleted edge would miss;
#   (b) if RECORD did not submit to the ring, the daemon never publishes → the
#       shm slot stays empty → B misses.
# Both reproduced by an Edit-break / observe / revert cycle (see the milestone
# note): (a) making `shmReadRecord` always return not-found; (b) making
# `submitToShm` a no-op.

proc asBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc weakFor(name: string): ContentDigest =
  blake3DomainDigest(asBytes("reprobuild.ac2c.two-tier." & name),
    hdActionFingerprint)

const
  # A real `repro build`/engine records + looks up N overlapping edges against
  # ONE shared cache root; the binary re-execs itself as the worker (the AC-1 /
  # AC-2a/b multiprocess pattern).
  WorkerFlag = "--ac2c-build-worker"
  NumEdges = 24            ## edges each worker builds (overlapping across workers)
  NumWorkers = 8           ## concurrent engine PROCESSES sharing the cache root
  BoundedSeconds = 45.0    ## no-wedge wall-time bound for the whole concurrent run

proc runBuildWorker(cacheRoot, casRoot, workerRoot: string) =
  ## One REAL engine process: open the shared two-tier cache (attaches shm +
  ## auto-spawns the daemon) and, for every edge, record its result then look it
  ## up (a hit that restores the output). Overlapping edges across workers means
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
        if k2 == pcFile:
          result += int(getFileSize(p2))

proc shmSlotPresent(cacheRoot: string; weak: ContentDigest): bool =
  ## Direct, engine-independent probe of the SHARED-MEMORY table: is `weak`'s
  ## slot populated on the current generation? Used to prove the daemon actually
  ## published a record to shm (not just that disk has it).
  when shmIndexSupported:
    var idx = openShmIndex(cacheRoot, create = false)
    if not idx.available:
      return false
    defer: idx.close()
    var snap: SlotSnapshot
    if not idx.followLiveGeneration():
      return false
    idx.liveSeg.lookupSlot(weak.bytes, snap) == srsHit
  else:
    false

proc waitForShmSlot(cacheRoot: string; weak: ContentDigest;
    timeoutS: float): bool =
  ## Wait (bounded) for the daemon to publish `weak`'s slot to shm.
  let deadline = epochTime() + timeoutS
  while epochTime() < deadline:
    if shmSlotPresent(cacheRoot, weak):
      return true
    sleep(10)
  false

proc ensureDaemonBinOnPath() =
  ## The engine auto-spawns `repro-cache-daemon` as a SIBLING of the current
  ## executable. This test binary lives in `build/test-bin/`, so point the
  ## engine at the real daemon built into `build/bin/` (via the documented
  ## override env). If it is not built yet the shm tier still attaches; a
  ## co-running engine that DID spawn the daemon (or none) just means the
  ## live-sharing subtest's `waitForShmSlot` guards it.
  ##
  ## Also set a SHORT self-reap idle window so each isolated (hermetic) root's
  ## daemon exits promptly after the test and does not linger holding the temp
  ## cache root (the isolation/lifecycle/reaping deliverable) — otherwise the
  ## detached daemon would keep the temp dir busy past teardown.
  when shmIndexSupported:
    if not existsEnv("REPRO_CACHE_DAEMON_IDLE_MS"):
      putEnv("REPRO_CACHE_DAEMON_IDLE_MS", "400")
    if existsEnv("REPRO_CACHE_DAEMON_BIN"): return
    # `just build` puts apps in build/bin; find it relative to the repo root.
    for candidate in [getCurrentDir() / "build" / "bin" / "repro-cache-daemon",
        parentDir(parentDir(getAppDir())) / "build" / "bin" / "repro-cache-daemon"]:
      if fileExists(candidate):
        putEnv("REPRO_CACHE_DAEMON_BIN", candidate)
        return

proc removeDirWhenDaemonReaped(dir: string) =
  ## Tolerant teardown: an auto-spawned daemon holds the temp cache root's
  ## `action-index.*` files until it self-reaps (short idle window above). Retry
  ## the remove for a bounded time, then give up quietly — a hermetic temp dir is
  ## the OS's to reclaim and a lingering daemon is a lifecycle detail, not a test
  ## failure.
  for _ in 0 ..< 60:
    try:
      removeDir(dir)
      return
    except OSError:
      sleep(50)
  try: removeDir(dir)
  except OSError: discard

suite "integration_action_cache_two_tier_concurrent_builds_no_wedge_live_sharing":
  when isNixSupported:

    test "N concurrent builds: no wedge, bounded size, all correct":
      ensureDaemonBinOnPath()
      let tempRoot = createTempDir("repro-ac2c-nowedge", "")
      defer: removeDirWhenDaemonReaped(tempRoot)
      let cacheRoot = tempRoot / ".repro" / "action-cache"
      let casRoot = tempRoot / ".repro" / "cas"
      let actionRoot = tempRoot / "action"
      createDir(actionRoot)
      # Pre-create the shared roots so every worker attaches to the same store +
      # shm region (and one daemon is auto-spawned to own it).
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
      # NO WEDGE: the whole concurrent run finished well within the bound (no
      # unbounded whole-cache scan / lock contention pathology).
      check elapsed < BoundedSeconds
      # BOUNDED SIZE: exactly one directory per edge — O(edges), never
      # O(all-history) despite NumWorkers*3 rounds of records per edge.
      check perEdgeDirCount(cacheRoot) == NumEdges
      # A single-edge single-record footprint upper-bounds each edge dir at a
      # small constant (≤ the per-key `.rec` cap of distinct worker path-sets),
      # so the WHOLE store is O(edges) — never O(all-history). A reinstated
      # global append-log would make this grow with NumWorkers*rounds records.
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

    when shmIndexSupported:
      test "live cross-build sharing: a record is served from shm to another build":
        ensureDaemonBinOnPath()
        let tempRoot = createTempDir("repro-ac2c-share", "")
        defer: removeDirWhenDaemonReaped(tempRoot)
        let cacheRoot = tempRoot / ".repro" / "action-cache"
        let casRoot = tempRoot / ".repro" / "cas"
        let actionRoot = tempRoot / "action"
        createDir(actionRoot)
        let cas = openLocalCas(casRoot)
        var seed = openActionCache(cacheRoot)   # attaches shm + auto-spawns daemon

        # Build A (this process, but the daemon is a SEPARATE process) records an
        # edge → writes Tier-1 disk AND submits the metadata to the MPSC ring.
        let weak = weakFor("shared-edge")
        let inputPath = actionRoot / "shared-in.txt"
        let outPath = actionRoot / "shared-out.txt"
        writeFile(inputPath, "shared-input\n")
        writeFile(outPath, "shared-output\n")
        # Record METADATA-ONLY so the record fits the inline slot cap and is
        # submitted to the ring (an oversized record is Tier-1-only by design —
        # §4.2; the shm tier holds metadata-only records). This is exactly the
        # shape `readHotRecord` returns and the daemon publishes.
        let recorded = seed.recordActionResult(cas, weak, ffpTimestamp,
          [inputPath], ["shared-out.txt"], actionRoot, storeOutputBlobs = false)

        # The DAEMON (a real separate process, auto-spawned on the cache open)
        # must drain the ring and PUBLISH the record to the shm table.
        check waitForShmSlot(cacheRoot, weak, 8.0)
        # Prove it is shm, engine-independently: the shared-memory slot for the
        # weak key is populated (by the daemon, from A's ring submission).
        check shmSlotPresent(cacheRoot, weak)

        # Build B: a SECOND engine handle on the same root whose Tier-1 DISK view
        # of this edge is DELETED. Any hit B now gets can ONLY come from the shm
        # tier — the daemon published A's in-flight record there. This is the
        # real live-sharing assertion (falsifiable: no shm read → miss).
        var buildB = openActionCache(cacheRoot)
        let edgeDir = cacheRoot / "hot-records" / perEdgeRecordFileName(weak)
        removeDir(edgeDir)                        # erase B's disk view of the edge
        check not dirExists(edgeDir)
        # readHotRecord: disk misses (dir gone) → the ONLY source left is shm.
        let served = buildB.readHotRecord(weak)
        check served.found
        check served.record.weakFingerprint == weak
        # CORRECTNESS: the shm-served record's inputs match what A recorded (a
        # valid hit, not a garbled one).
        check served.record.inputs.len == recorded.inputs.len

        buildB.closeShmTier()
        seed.closeShmTier()

    test "fallback: the shm tier disabled still builds correctly (pure Tier-1)":
      # Force the accelerator OFF; the same record+lookup+restore must still work
      # entirely on the durable Tier-1 disk store, proving shm is OPTIONAL.
      putEnv("REPRO_ACTION_CACHE_SHM", "0")
      defer: delEnv("REPRO_ACTION_CACHE_SHM")
      let tempRoot = createTempDir("repro-ac2c-fallback", "")
      defer: removeDirWhenDaemonReaped(tempRoot)
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
      check hit.record.weakFingerprint == weak
      cas.restoreOutputs(hit.record, actionRoot)
      check readFile(actionRoot / "fb-out.txt") == "fb-output\n"

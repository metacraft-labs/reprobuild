## Action-Cache-Per-Edge-Store.md §5.2 — the write sequence a publish is
## stamped with is above every container that survives in its edge
## directory, and distinct across concurrent writers sharing a cache root.
##
## Regression test for reprobuild-pm
## issues/2026-11-12-the-seq-counter-is-neither-durable-nor-strictly-monotonic.md.
## The counter `hot-records/.seq` is not fsynced, and it used to be rewritten
## by a truncating `writeFile` and allocated from without the lock when the
## lock could not be taken. A counter that came back empty or missing — a
## crash mid-truncate, a power loss, an operator deleting it — then stamped
## the next record as the OLDEST in its edge: the retention cap evicted the
## record just written, newest-wins chose a stale candidate, and a convergent
## rewrite repeated its predecessor's sequence, which is what the newest alias
## and the sidecars use to tell a rewrite from the file they describe.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every case drives the production `ActionCache` over a real `Store` on a
## real temporary directory, publishes through the production
## `recordActionResult`, and reads through the production `readHotRecord` and
## `loadPerEdgeRecords`.
## The counter is damaged the way a crash or an operator damages it: by
## deleting or truncating the real file. The concurrent case runs real
## processes — this binary re-executed — because the property is about
## processes sharing a root, and threads in one process would share the very
## state a cross-process lock exists to serialize.
##
## WHY THE TRAILER IS READ BY HAND
##
## `trailerSequence` reads the last eight bytes of a container rather than
## calling a store decoder: a test that took the sequence from the
## implementation could not notice the implementation misreading it. The
## format (§5.1) puts an 8-byte little-endian `writeSequence` at the very end
## of every intact v2 container, and every container here is written whole by
## this binary.

import std/[algorithm, os, osproc, sequtils, sets, strtabs, strutils, tempfiles,
            unittest]

import repro_core
import repro_hash
import repro_local_store

const ChildEnv = "REPRO_TEST_WRITE_SEQUENCE_CHILD"
  ## Set to `<cacheRoot>|<childIndex>|<recordCount>` when this binary is
  ## re-executed as one of the concurrent writers.

proc weakOf(name: string): ContentDigest =
  ## The same construction `repro_build_engine.weakFingerprintFromText` uses,
  ## written out rather than imported: a `repro_local_store` test must not
  ## depend on the layer above it.
  var bytes = newSeq[byte](name.len)
  for i, ch in name:
    bytes[i] = byte(ord(ch))
  blake3DomainDigest(bytes, hdActionFingerprint)

type Fixture = object
  root: string
  workRoot: string
  cache: ActionCache
  store: Store

proc openFixture(tag: string): Fixture =
  let root = createTempDir("repro-write-seq-" & tag & "-", "")
  let workRoot = root / "work"
  createDir(workRoot)
  Fixture(
    root: root,
    workRoot: workRoot,
    cache: openActionCache(root / "action-cache", attachShm = false),
    store: openStore(root / "store"))

proc closeFixture(f: var Fixture) =
  f.cache.closeShmTier()
  close(f.store)
  try: removeDir(f.root)
  except OSError: discard

proc counterPath(f: Fixture): string =
  ## Spelled out rather than exported from the store: the counter's name is
  ## part of the on-disk layout §5.1 documents.
  f.cache.hotRecordsRoot / ".seq"

proc edgeDir(f: Fixture; weak: ContentDigest): string =
  f.cache.hotRecordsRoot / perEdgeRecordFileName(weak)

proc trailerSequence(path: string): uint64 =
  let raw = readFile(path)
  doAssert raw.len >= 8, "container too short to carry a trailer: " & path
  for i in countdown(raw.len - 1, raw.len - 8):
    result = (result shl 8) or uint64(ord(raw[i]))

proc sequencesIn(dir: string): seq[tuple[name: string; sequence: uint64]] =
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".rec"):
      result.add((name: path.extractFilename, sequence: trailerSequence(path)))
  result.sort(proc (a, b: tuple[name: string; sequence: uint64]): int =
    cmp(a.sequence, b.sequence))

proc recFileOf(f: Fixture; record: ActionResultRecord): string =
  f.edgeDir(record.weakFingerprint) /
    (toHex(record.strongFingerprint.bytes) & ".rec")

proc recordVariant(cache: var ActionCache; store: var Store; workRoot: string;
                   weak: ContentDigest; variant: int): ActionResultRecord =
  ## One PATH-SET for `weak`: each variant observes a different set of input
  ## files, so each gets its own strong fingerprint and its own container.
  ## The same variant recorded twice at unchanged inputs is a convergent
  ## rewrite of the same container.
  var inputs: seq[string] = @[]
  for i in 0 .. variant:
    let p = workRoot / ("src" & $i & ".c")
    if not fileExists(p):
      writeFile(p, "int v" & $i & "(void){return " & $i & ";}\n")
    inputs.add(p)
  let outputPath = workRoot / "out.o"
  writeFile(outputPath, "object-bytes-" & $variant & "\n")
  cache.recordActionResult(store, weak, ffpTimestamp,
    inputs, [outputPath], outputRoot = "", storeOutputBlobs = true)

proc recordVariant(f: var Fixture; weak: ContentDigest; variant: int):
    ActionResultRecord =
  recordVariant(f.cache, f.store, f.workRoot, weak, variant)

proc childMain(spec: string) =
  ## One concurrent writer: publish `count` records, each to its own edge, so
  ## the retention cap never evicts one and every sequence handed out stays
  ## on disk for the parent to inspect.
  let parts = spec.split('|')
  let cacheRoot = parts[0]
  let index = parseInt(parts[1])
  let count = parseInt(parts[2])
  let scratch = cacheRoot.parentDir / ("child-" & $index)
  createDir(scratch / "work")
  var cache = openActionCache(cacheRoot, attachShm = false)
  var store = openStore(scratch / "store")
  for k in 0 ..< count:
    discard recordVariant(cache, store, scratch / "work",
      weakOf("concurrent." & $index & "." & $k), 0)
  cache.closeShmTier()
  close(store)

if existsEnv(ChildEnv):
  childMain(getEnv(ChildEnv))
  quit(0)

suite "the write sequence never falls behind a surviving record":

  for damage in ["deleted", "truncated to empty"]:
    test "a counter " & damage & " does not send the next record to the back":
      var f = openFixture("lost")
      defer: closeFixture(f)
      let weak = weakOf("write-seq.lost." & damage)
      for variant in 0 ..< 3:
        discard f.recordVariant(weak, variant)
      let before = sequencesIn(f.edgeDir(weak))
      check before.len == 3
      if damage == "deleted":
        removeFile(f.counterPath)
      else:
        writeFile(f.counterPath, "")
      let fresh = f.recordVariant(weak, 3)
      let freshSeq = trailerSequence(f.recFileOf(fresh))
      checkpoint("sequences before the damage: " & $before.mapIt(it.sequence) &
        "; the record published after it: " & $freshSeq)
      check freshSeq > before[^1].sequence
      # §5.3's union read, ordered oldest -> newest: its last element is the
      # candidate newest-wins tries first.
      let ordered = f.cache.loadPerEdgeRecords(weak)
      check ordered.len == 4
      check ordered[^1].strongFingerprint == fresh.strongFingerprint
      # And the consultation's own newest view: variant 3 observed 4 inputs.
      let newest = f.cache.readHotRecord(weak)
      check newest.found
      check newest.record.inputs.len == fresh.inputs.len

  test "the retention cap keeps the record just written after a lost counter":
    var f = openFixture("cap")
    defer: closeFixture(f)
    let weak = weakOf("write-seq.cap")
    for variant in 0 ..< 8:
      discard f.recordVariant(weak, variant)
    let before = sequencesIn(f.edgeDir(weak))
    check before.len == 8
    removeFile(f.counterPath)
    let fresh = f.recordVariant(weak, 8)
    checkpoint("containers left: " & $sequencesIn(f.edgeDir(weak)))
    # Checked first because the survival check alone is a coin toss on a
    # broken counter: a fresh record that TIES the oldest survives or not by
    # strong-fingerprint hex, which varies with the temp directory.
    check fileExists(f.recFileOf(fresh))
    if fileExists(f.recFileOf(fresh)):
      check trailerSequence(f.recFileOf(fresh)) > before[^1].sequence
    check sequencesIn(f.edgeDir(weak)).len == 8

  test "a convergent rewrite after a lost counter moves the sequence":
    ## The newest alias and the `.octime` / `.det` sidecars detect a rewrite
    ## in place by its sequence changing (§5.5 C1 "As implemented"). A
    ## rewrite that repeated its predecessor's sequence would be invisible.
    var f = openFixture("converge")
    defer: closeFixture(f)
    let weak = weakOf("write-seq.converge")
    let first = f.recordVariant(weak, 0)
    let firstSeq = trailerSequence(f.recFileOf(first))
    removeFile(f.counterPath)
    let again = f.recordVariant(weak, 0)
    check again.strongFingerprint == first.strongFingerprint
    let againSeq = trailerSequence(f.recFileOf(again))
    checkpoint("first publish: " & $firstSeq & "; rewrite: " & $againSeq)
    check againSeq > firstSeq

  test "a writer that cannot take the counter lock does not publish":
    ## Obstruct the lock alone, by putting a directory where its file goes,
    ## and leave the counter intact. §5.2: a writer that cannot take the
    ## lock does not publish, and never falls back to an unlocked read and
    ## increment, which hands two concurrent processes the same value. A
    ## publish that succeeded here would have allocated without the lock, so
    ## every publish must be refused.
    var f = openFixture("unlockable")
    defer: closeFixture(f)
    let weak = weakOf("write-seq.unlockable")
    discard f.recordVariant(weak, 0)
    let baseline = sequencesIn(f.edgeDir(weak))[^1].sequence
    check fileExists(f.counterPath)
    let lockPath = f.cache.hotRecordsRoot / ".seq.lock"
    if fileExists(lockPath):
      removeFile(lockPath)
    createDir(lockPath)
    var published: seq[uint64] = @[]
    var refused = 0
    for variant in 1 .. 2:
      try:
        let rec = f.recordVariant(weak, variant)
        published.add(trailerSequence(f.recFileOf(rec)))
      except OSError, IOError:
        inc refused
    checkpoint("baseline " & $baseline & "; published " & $published &
      "; refused " & $refused)
    check published.len == 0
    check refused == 2
    check sequencesIn(f.edgeDir(weak)).len == 1

suite "the write sequence is distinct across processes sharing a root":

  test "concurrent writers never receive the same sequence":
    ## Four processes publish twenty records each to one cache root at once.
    ## A probabilistic guard: with the lock taken on the renamed counter it
    ## failed in 7 of 8 runs when measured, so it catches that regression
    ## reliably across CI runs, not in every single one.
    ## Every publish allocates from the shared counter, so all eighty
    ## sequences must be distinct. This fails if the lock and the counter
    ## are ever the same file again: the counter is replaced by rename, and
    ## a lock on the inode a rename unlinks excludes nobody.
    const Children = 4
    const PerChild = 20
    let root = createTempDir("repro-write-seq-concurrent-", "")
    defer:
      try: removeDir(root)
      except OSError: discard
    let cacheRoot = root / "action-cache"
    discard openActionCache(cacheRoot, attachShm = false)
    var procs: seq[Process] = @[]
    for i in 0 ..< Children:
      var env = newStringTable()
      for k, v in envPairs():
        env[k] = v
      env[ChildEnv] = cacheRoot & "|" & $i & "|" & $PerChild
      procs.add(startProcess(getAppFilename(), env = env,
        options = {poParentStreams}))
    for p in procs:
      check p.waitForExit() == 0
      p.close()
    var all: seq[uint64] = @[]
    for kind, dir in walkDir(cacheRoot / "hot-records"):
      if kind == pcDir:
        for entry in sequencesIn(dir):
          all.add(entry.sequence)
    check all.len == Children * PerChild
    let unique = all.toHashSet
    checkpoint("sequences: " & $all.len & ", distinct: " & $unique.len)
    check unique.len == all.len

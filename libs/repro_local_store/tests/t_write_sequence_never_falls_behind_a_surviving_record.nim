## Action-Cache-Per-Edge-Store.md §5.2 — the write sequence a publish is
## stamped with is above every container that survives in its edge
## directory, and distinct across concurrent writers sharing a cache root.
##
## Regression test for reprobuild-pm
## issues/2026-11-12-the-seq-counter-is-neither-durable-nor-strictly-monotonic.md,
## and for issues/2026-11-18-per-edge-write-sequence-floor-trusts-an-unchecked-trailer.md:
## the trailer is the one part of a container without a checksum, so a
## trailer above the largest sequence the store issues (2^48, §5.1) is not
## evidence of a sequence handed out and must not become the floor, a counter
## holding such a value reads as lost, and the floor is read under the
## counter lock so a writer that waited for the lock sees what was renamed in
## meanwhile.
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
## deleting or truncating the real file. A trailer is damaged the way bit rot
## or a foreign file damages it: by rewriting the real container's last eight
## bytes. The lock race is staged by holding the real `.seq.lock` with
## `flock(2)` from this process while a re-executed child waits on it. The concurrent case runs real
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
when defined(posix):
  import std/posix

import repro_core
import repro_hash
import repro_local_store

const ChildEnv = "REPRO_TEST_WRITE_SEQUENCE_CHILD"
  ## Set to `<cacheRoot>|<childIndex>|<recordCount>|<mode>` when this binary
  ## is re-executed as one of the concurrent writers. Mode `own` publishes
  ## each record to an edge of its own; mode `shared` publishes record `k` to
  ## the edge `shared.<k>` that every child also publishes into.
const RaceChildEnv = "REPRO_TEST_WRITE_SEQUENCE_RACE_CHILD"
  ## Set to `<cacheRoot>|<edgeName>` when this binary is re-executed as the
  ## writer that waits for the counter lock.
const MaxWriteSequence = 1'u64 shl 48
  ## The largest write sequence the store issues (§5.1). Spelled out rather
  ## than imported, for the reason `trailerSequence` is read by hand.

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

proc setTrailerSequence(path: string; value: uint64) =
  ## Overwrite a container's trailer in place, leaving its checksummed body
  ## intact: what a bit flip in those eight bytes, or a foreign file, leaves.
  var raw = readFile(path)
  doAssert raw.len >= 8, "container too short to carry a trailer: " & path
  for i in 0 ..< 8:
    raw[raw.len - 8 + i] = char((value shr (8 * i)) and 0xff'u64)
  writeFile(path, raw)

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
  let shared = parts[3] == "shared"
  let scratch = cacheRoot.parentDir / ("child-" & $index)
  createDir(scratch / "work")
  var cache = openActionCache(cacheRoot, attachShm = false)
  var store = openStore(scratch / "store")
  for k in 0 ..< count:
    let edge =
      if shared: "shared." & $k
      else: "concurrent." & $index & "." & $k
    discard recordVariant(cache, store, scratch / "work", weakOf(edge), 0)
  cache.closeShmTier()
  close(store)

proc raceChildMain(spec: string) =
  ## The writer that waits: one publish into `edgeName`, from its own work
  ## directory, so its container has a strong fingerprint of its own.
  let parts = spec.split('|')
  let cacheRoot = parts[0]
  let scratch = cacheRoot.parentDir / "race-child"
  createDir(scratch / "work")
  var cache = openActionCache(cacheRoot, attachShm = false)
  var store = openStore(scratch / "store")
  discard recordVariant(cache, store, scratch / "work", weakOf(parts[1]), 1)
  cache.closeShmTier()
  close(store)

if existsEnv(ChildEnv):
  childMain(getEnv(ChildEnv))
  quit(0)
if existsEnv(RaceChildEnv):
  raceChildMain(getEnv(RaceChildEnv))
  quit(0)

proc childEnv(name, value: string): StringTableRef =
  result = newStringTable()
  for k, v in envPairs():
    result[k] = v
  result[name] = value

proc runChildren(cacheRoot: string; children, perChild: int; mode: string) =
  var procs: seq[Process] = @[]
  for i in 0 ..< children:
    procs.add(startProcess(getAppFilename(),
      env = childEnv(ChildEnv,
        cacheRoot & "|" & $i & "|" & $perChild & "|" & mode),
      options = {poParentStreams}))
  for p in procs:
    check p.waitForExit() == 0
    p.close()

when defined(posix):
  proc cFlock(fd: cint; op: cint): cint {.importc: "flock",
    header: "<sys/file.h>".}
  const LockEx = 2.cint
  const LockUn = 8.cint

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

  for bogus in [high(uint64), high(uint64) - 1, MaxWriteSequence + 1]:
    test "a container whose trailer reads " & $bogus &
        " does not become the floor":
      ## The trailer has no checksum (§5.1). A flipped high bit, or a foreign
      ## file, can make it read near the top of the sequence space. Taken as
      ## the floor, it pushed the counter there: one publish later every
      ## publish to the root raised, and since a raising publish never reaches
      ## the retention cap the container was never evicted.
      var f = openFixture("bogus")
      defer: closeFixture(f)
      let weak = weakOf("write-seq.bogus." & $bogus)
      let rotten = f.recordVariant(weak, 0)
      setTrailerSequence(f.recFileOf(rotten), bogus)
      var published: seq[uint64] = @[]
      var refused = 0
      for variant in 1 .. 3:
        try:
          let rec = f.recordVariant(weak, variant)
          published.add(trailerSequence(f.recFileOf(rec)))
        except OSError, IOError:
          inc refused
      checkpoint("published " & $published & "; refused " & $refused &
        "; counter " & readFile(f.counterPath).strip)
      check refused == 0
      check published.len == 3
      for s in published:
        check s <= MaxWriteSequence
      check published.isSorted
      check parseBiggestUInt(readFile(f.counterPath).strip).uint64 <=
        MaxWriteSequence
      # The rotten container is a candidate like any other, but the oldest:
      # newest-wins tries the last record published first.
      let ordered = f.cache.loadPerEdgeRecords(weak)
      check ordered.len == 4
      if ordered.len == 4:
        check ordered[0].strongFingerprint == rotten.strongFingerprint
        check ordered[^1].inputs.len == 4

  for counter in [high(uint64), MaxWriteSequence]:
    test "a counter at " & $counter & " reads as lost":
      ## A root jammed before the ceiling existed, or a counter at the
      ## ceiling itself: kept, it would refuse every publish to every edge of
      ## the root. It recovers from the edge's surviving trailers, as a
      ## deleted counter does.
      var f = openFixture("wedged")
      defer: closeFixture(f)
      let weak = weakOf("write-seq.wedged." & $counter)
      let first = f.recordVariant(weak, 0)
      let firstSeq = trailerSequence(f.recFileOf(first))
      writeFile(f.counterPath, $counter)
      var published: seq[uint64] = @[]
      var refused = 0
      for variant in 1 .. 2:
        try:
          let rec = f.recordVariant(weak, variant)
          published.add(trailerSequence(f.recFileOf(rec)))
        except OSError, IOError:
          inc refused
      checkpoint("first " & $firstSeq & "; published " & $published &
        "; refused " & $refused)
      check refused == 0
      check published.len == 2
      if published.len == 2:
        check published[0] > firstSeq
        check published[1] > published[0]
        check published[1] < MaxWriteSequence

  test "exhaustion refuses only the edge whose floor is at the ceiling":
    ## §5.2: when the next value in an edge would exceed 2^48 a publish to
    ## that edge fails rather than wrap to 0 or issue a value every reader
    ## would ignore. Other edges of the root keep publishing.
    var f = openFixture("exhausted")
    defer: closeFixture(f)
    let weak = weakOf("write-seq.exhausted")
    let other = weakOf("write-seq.exhausted.other")
    let topped = f.recordVariant(weak, 0)
    setTrailerSequence(f.recFileOf(topped), MaxWriteSequence)
    var refused = 0
    try:
      discard f.recordVariant(weak, 1)
    except OSError, IOError:
      inc refused
    check refused == 1
    check sequencesIn(f.edgeDir(weak)).len == 1
    let elsewhere = f.recordVariant(other, 0)
    check trailerSequence(f.recFileOf(elsewhere)) < MaxWriteSequence
    # One below the ceiling is still issued: the ceiling itself.
    setTrailerSequence(f.recFileOf(topped), MaxWriteSequence - 1)
    let last = f.recordVariant(weak, 1)
    check trailerSequence(f.recFileOf(last)) == MaxWriteSequence

  test "a temp file left by a crash under the lock does not accumulate":
    ## The counter is replaced by temp file and rename under the lock, so a
    ## crash between the two leaves the temp file behind. Every writer holds
    ## the lock while it writes, so one fixed temp name suffices, and the next
    ## publish renames over what the crash left. No crash is staged: the
    ## file is planted under the name §5.1 gives the temp file, and the check
    ## is that no publish leaves any other `.seq.tmp*` name behind.
    var f = openFixture("tmp")
    defer: closeFixture(f)
    let weak = weakOf("write-seq.tmp")
    discard f.recordVariant(weak, 0)
    writeFile(f.counterPath & ".tmp", "12")
    for variant in 1 .. 3:
      discard f.recordVariant(weak, variant)
    var leftovers: seq[string] = @[]
    for kind, path in walkDir(f.cache.hotRecordsRoot):
      if path.extractFilename.startsWith(".seq.tmp"):
        leftovers.add(path.extractFilename)
    checkpoint("left over: " & $leftovers)
    check leftovers.len == 0

  when defined(posix):
    test "a symlink planted at the temp name is not written through":
      ## The temp name is fixed, so on a root shared by several users another
      ## user can predict it. A `.seq.tmp` symlink must be replaced, not
      ## followed: the file it points at keeps its content, and the publish
      ## still advances the counter.
      var f = openFixture("tmplink")
      defer: closeFixture(f)
      let weak = weakOf("write-seq.tmplink")
      let first = f.recordVariant(weak, 0)
      let victim = f.root / "victim.txt"
      writeFile(victim, "keep me")
      createSymlink(victim, f.counterPath & ".tmp")
      let second = f.recordVariant(weak, 1)
      let firstSeq = trailerSequence(f.recFileOf(first))
      let secondSeq = trailerSequence(f.recFileOf(second))
      checkpoint("victim: " & readFile(victim) & "; first " & $firstSeq &
        "; second " & $secondSeq)
      check readFile(victim) == "keep me"
      check secondSeq > firstSeq
      check not symlinkExists(f.counterPath & ".tmp")

  test "a directory planted at the temp name does not refuse publishes":
    ## A directory at the fixed temp name cannot be replaced by the counter's
    ## temp file. Removing it is not safe either: a recursive delete walks by
    ## name, and a co-user who swaps a subdirectory for a symlink mid-walk
    ## redirects it into the publisher's own files. So the directory is left
    ## exactly as planted, the counter goes through a per-writer temp name,
    ## and that name is renamed onto the counter rather than left behind.
    var f = openFixture("tmpdir")
    defer: closeFixture(f)
    let weak = weakOf("write-seq.tmpdir")
    let first = f.recordVariant(weak, 0)
    let planted = f.counterPath & ".tmp"
    createDir(planted / "inner")
    writeFile(planted / "inner" / "keep.txt", "keep me")
    let second = f.recordVariant(weak, 1)
    let third = f.recordVariant(weak, 2)
    let firstSeq = trailerSequence(f.recFileOf(first))
    let secondSeq = trailerSequence(f.recFileOf(second))
    let thirdSeq = trailerSequence(f.recFileOf(third))
    var leftovers: seq[string] = @[]
    for kind, path in walkDir(f.cache.hotRecordsRoot):
      if path.extractFilename.startsWith(".seq.tmp"):
        leftovers.add(path.extractFilename)
    checkpoint("first " & $firstSeq & "; second " & $secondSeq & "; third " &
      $thirdSeq & "; temp names: " & $leftovers)
    check secondSeq > firstSeq
    check thirdSeq > secondSeq
    check readFile(f.counterPath).strip == $thirdSeq
    check readFile(planted / "inner" / "keep.txt") == "keep me"
    check leftovers == @[".seq.tmp"]

  when defined(posix):
    test "a FIFO named like a container does not stall the counter lock":
      ## The floor is read under the root-wide lock (§5.2). A `.rec` that is
      ## not a regular file would block that read while the lock is held, and
      ## so every publisher on the root, not only those to its own edge.
      ## Whatever else a publish to the FIFO's edge does with it is outside
      ## this property; the check is that a publish to ANOTHER edge finishes.
      var f = openFixture("fifo")
      defer: closeFixture(f)
      let weak = weakOf("write-seq.fifo")
      discard f.recordVariant(weak, 0)
      let fifo = f.edgeDir(weak) / (repeat('e', 64) & ".rec")
      doAssert mkfifo(fifo.cstring, Mode(0o600)) == 0
      let cacheRoot = f.cache.hotRecordsRoot.parentDir
      let stuck = startProcess(getAppFilename(),
        env = childEnv(RaceChildEnv, cacheRoot & "|write-seq.fifo"),
        options = {poParentStreams})
      os.sleep(1000)
      let bystander = startProcess(getAppFilename(),
        env = childEnv(ChildEnv, cacheRoot & "|9|1|own"),
        options = {poParentStreams})
      var finished = false
      for _ in 0 ..< 100:
        if not bystander.running:
          finished = true
          break
        os.sleep(100)
      for p in [stuck, bystander]:
        if p.running:
          p.kill()
        discard p.waitForExit()
      check finished
      if finished:
        check bystander.peekExitCode() == 0
      stuck.close()
      bystander.close()

    test "a writer that waited for the lock allocates above what was renamed in meanwhile":
      ## §5.2: the floor is read under the counter lock. Staged: this process
      ## holds `.seq.lock`; a child starts a publish into the edge and blocks
      ## on it. While it waits, a container with the next sequence is renamed
      ## into the edge (another writer's publish) and the counter is lost.
      ## A floor read before the lock misses that container, and the child
      ## would be handed the sequence it carries.
      var f = openFixture("race")
      defer: closeFixture(f)
      let edgeName = "write-seq.race"
      let weak = weakOf(edgeName)
      let first = f.recordVariant(weak, 0)
      let firstSeq = trailerSequence(f.recFileOf(first))
      let lockPath = f.cache.hotRecordsRoot / ".seq.lock"
      let fd = posix.open(lockPath.cstring, O_RDONLY or O_CLOEXEC)
      doAssert fd >= 0, "cannot open " & lockPath
      doAssert cFlock(fd, LockEx) == 0
      let child = startProcess(getAppFilename(),
        env = childEnv(RaceChildEnv, f.cache.hotRecordsRoot.parentDir & "|" &
          edgeName),
        options = {poParentStreams})
      # Long enough for the child to read the floor and block on the lock.
      # Too short a wait can only make this test pass on unfixed code, never
      # fail on fixed code.
      os.sleep(1500)
      let interloper = f.edgeDir(weak) / (repeat('f', 64) & ".rec")
      copyFile(f.recFileOf(first), interloper)
      setTrailerSequence(interloper, firstSeq + 1)
      removeFile(f.counterPath)
      discard cFlock(fd, LockUn)
      discard posix.close(fd)
      check child.waitForExit() == 0
      child.close()
      var childSeq = 0'u64
      for entry in sequencesIn(f.edgeDir(weak)):
        if entry.name != f.recFileOf(first).extractFilename and
            entry.name != interloper.extractFilename:
          childSeq = entry.sequence
      checkpoint("first " & $firstSeq & "; renamed in while waiting " &
        $(firstSeq + 1) & "; the waiting writer got " & $childSeq)
      check childSeq > firstSeq + 1

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
    runChildren(cacheRoot, Children, PerChild, "own")
    var all: seq[uint64] = @[]
    for kind, dir in walkDir(cacheRoot / "hot-records"):
      if kind == pcDir:
        for entry in sequencesIn(dir):
          all.add(entry.sequence)
    check all.len == Children * PerChild
    let unique = all.toHashSet
    checkpoint("sequences: " & $all.len & ", distinct: " & $unique.len)
    check unique.len == all.len

  test "concurrent writers to the same edges never receive the same sequence":
    ## The same race with every child publishing into the same twenty edges,
    ## so each edge directory takes four containers written at once and each
    ## publish reads its floor from a directory the others are renaming into.
    const Children = 4
    const PerEdge = 20
    let root = createTempDir("repro-write-seq-shared-", "")
    defer:
      try: removeDir(root)
      except OSError: discard
    let cacheRoot = root / "action-cache"
    discard openActionCache(cacheRoot, attachShm = false)
    runChildren(cacheRoot, Children, PerEdge, "shared")
    var all: seq[uint64] = @[]
    for kind, dir in walkDir(cacheRoot / "hot-records"):
      if kind == pcDir:
        let inEdge = sequencesIn(dir)
        check inEdge.len == Children
        for entry in inEdge:
          all.add(entry.sequence)
    check all.len == Children * PerEdge
    check all.toHashSet.len == all.len

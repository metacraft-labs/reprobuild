## A record that cannot fit an inline shm slot must be refused WITHOUT being
## encoded first, and the refusal must be COUNTABLE from outside the process.
##
## MOCK POLICY -- NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED. The
## test drives the real `runBuild` scheduler, the real `ActionCache` with the
## real POSIX shared-memory index attached (an explicit `actionCacheRoot` is
## what attaches it), real subprocesses and real files in real temporary
## directories, and compares the real `encodedRecordSizeFloor` against the real
## `encodeActionResultRecord`. The property is about what production DOES on a
## real rejection path, so the rejection has to be the real one.
##
## THE DEFECT. `submitToShm` encoded every record and only then compared the
## result against `SlotInlineCap` (256 B). For a build whose records are far
## over the cap that is work with no possible consumer, and it is paid on EVERY
## build rather than once: because the submit always fails, the slot is never
## populated, so `readHotRecord` misses in shm, so its warm-on-miss path
## re-submits the same doomed record next time. The loop cannot converge by
## construction for any record over the cap -- which, per
## `noteOversizedShmSubmit`'s own note about a ~102-character path cliff, is
## any sufficiently deep checkout. Measured on a warm no-op of the zlib CMake
## project: 37 submits, 37 rejections, ~897 KB encoded and discarded, 6.9 ms of
## a 58.7 ms `cache lookup`, identically every run.
##
## THE PROPERTIES, in the order they are asserted:
##
##   1. SOUNDNESS. `encodedRecordSizeFloor(r) <= encodeActionResultRecord(r).len`
##      for every record shape. This is the assertion that matters most: a
##      floor that ever came in ABOVE the truth would refuse a record that
##      fits, silently turning the tier off for it. Checked over an explicit
##      corpus of shapes AND over every record two real builds produce.
##   2. NO DOOMED ENCODE. An over-cap record is refused on the floor, before
##      the encode. Observable because the diagnostic says "encodes to at
##      least" -- a phrasing only the pre-encode path can produce, since the
##      post-encode path knows the exact width and says "encoded".
##   3. THE COUNTER IS SURFACED. `shmSubmitStats().oversized` is non-zero and
##      the build emits a `repro shm oversized submit` timing row. Before this
##      the count existed in `ShmTier.oversizedSubmits` and was read by
##      nothing, so an 8 ms structural stall needed a profiler to find.
##   4. NON-VACUITY. A build whose records DO fit submits them, reports
##      nothing, and leaves the counter at zero. A counter that is always
##      non-zero measures nothing.

import std/[os, posix, sequtils, strutils, tempfiles, unittest]

import repro_build_engine
import repro_hash
import repro_local_store
import repro_shm_index

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("shm-floor." & name)

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

proc metricCount(res: BuildRunResult; name: string): int =
  for metric in res.stats.metrics:
    if metric.name == name:
      return metric.count
  -1  # distinguishable from a row that exists and reads zero

type Capture = object
  savedFd: cint
  path: string

proc beginCapture(path: string): Capture =
  stderr.flushFile()
  let saved = dup(2)
  let fd = posix.open(path.cstring,
    O_WRONLY or O_CREAT or O_TRUNC, 0o644.Mode)
  doAssert fd >= 0, "could not open " & path
  discard dup2(fd, 2)
  discard close(fd)
  Capture(savedFd: saved, path: path)

proc endCapture(c: Capture): string =
  stderr.flushFile()
  discard dup2(c.savedFd, 2)
  discard close(c.savedFd)
  readFile(c.path)

type BuildProbe = object
  records: seq[ActionResultRecord]
  stderrText: string
  oversized: int
  oversizedFloorBytes: int64
  metricRow: int

proc buildUnder(root: string): BuildProbe =
  ## Run one cacheable edge with the shm tier attached (an explicit
  ## `actionCacheRoot` is what attaches it) and report the records it wrote
  ## plus everything production said and counted while writing them.
  ##
  ## Only the ROOT differs between the two calls below. The encoded record is
  ## dominated by absolute path strings, so root length alone decides which
  ## side of the 256 B cap the record lands on -- which is the point
  ## `noteOversizedShmSubmit` makes about the ~102-character cliff, and the
  ## reason a deep checkout gets no shm tier at all.
  let workRoot = root / "work"
  let cacheRoot = root / "cache"
  let actionCacheRoot = root / "acr"
  createDir(workRoot / "src")
  createDir(actionCacheRoot)
  writeFile(workRoot / "src" / "i.txt", "payload\n")

  let copy = builtinAction(bakCopyFile, "shmfloor/copy",
    cwd = workRoot,
    inputs = ["src/i.txt"],
    outputs = ["out/c.txt"],
    cacheable = true,
    weakFingerprint = weak(root),
    actionCachePolicy = ffpTimestamp,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

  var config = defaultBuildEngineConfig(cacheRoot, actionCacheRoot)
  config.rebuildMissingOutputsOnCacheHit = true
  config.deferLocalOutputBlobs = true
  config.bypassRunQuota = true
  config.maxParallelism = 1'u32
  config.statsEnabled = true

  let capture = beginCapture(root / "stderr.txt")
  var built: BuildRunResult
  try:
    built = runBuild(graph([copy]), config)
  finally:
    result.stderrText = endCapture(capture)
  doAssert built.byId("shmfloor/copy").status == asSucceeded

  let submits = shmSubmitStats()
  result.oversized = submits.oversized
  result.oversizedFloorBytes = submits.oversizedFloorBytes
  result.metricRow = built.metricCount("repro shm oversized submit")

  var probe = openActionCache(actionCacheRoot / "action-cache",
    attachShm = false)
  result.records = probe.loadPerEdgeRecords(copy.weakFingerprint)

proc corpus(): seq[ActionResultRecord] =
  ## Record shapes the floor has to be sound for, chosen at the boundaries of
  ## every term it sums: nothing at all, one of each part, an env section, both
  ## output payload kinds, empty and separator-only paths (which
  ## `splitPathPrefix` handles without normalising), and one long path.
  let digest = blake3DomainDigest(@[1'u8, 2'u8], hdActionFingerprint)
  proc input(path: string; hasHash = false): FileFingerprint =
    FileFingerprint(path: path, policy: ffpTimestamp,
      metadata: FileMetadata(kind: ffkRegular, sizeBytes: 7, mtimeNs: 11),
      hasLocalHash: hasHash)
  proc output(path: string): OutputBlob =
    OutputBlob(path: path,
      metadata: FileMetadata(kind: ffkRegular, sizeBytes: 7, mtimeNs: 11),
      permissions: {fpUserRead, fpUserWrite})

  # 1: entirely empty.
  result.add(ActionResultRecord(weakFingerprint: digest,
    strongFingerprint: digest, policy: ffpTimestamp,
    outputPayloadKind: opkMetadataOnly))
  # 2: one input, no outputs.
  result.add(ActionResultRecord(weakFingerprint: digest,
    strongFingerprint: digest, policy: ffpTimestamp,
    outputPayloadKind: opkMetadataOnly, inputs: @[input("/a/b.txt")]))
  # 3: one input carrying a local hash (the optional per-input tail).
  result.add(ActionResultRecord(weakFingerprint: digest,
    strongFingerprint: digest, policy: ffpTimestamp,
    outputPayloadKind: opkMetadataOnly,
    inputs: @[input("/a/b.txt", hasHash = true)]))
  # 4: metadata-only outputs.
  result.add(ActionResultRecord(weakFingerprint: digest,
    strongFingerprint: digest, policy: ffpTimestamp,
    outputPayloadKind: opkMetadataOnly,
    inputs: @[input("/a/b.txt")], outputs: @[output("/a/out.txt")]))
  # 5: CAS-blob outputs (the +42 B per output arm).
  result.add(ActionResultRecord(weakFingerprint: digest,
    strongFingerprint: digest, policy: ffpTimestamp,
    outputPayloadKind: opkCasBlobs,
    inputs: @[input("/a/b.txt")], outputs: @[output("/a/out.txt")]))
  # 6: an env section.
  result.add(ActionResultRecord(weakFingerprint: digest,
    strongFingerprint: digest, policy: ffpTimestamp,
    outputPayloadKind: opkMetadataOnly,
    inputs: @[input("/a/b.txt")],
    envInputs: @[EnvFingerprint(name: "CC", present: true, value: "clang"),
                 EnvFingerprint(name: "NOPE", present: false, value: "")]))
  # 7: degenerate paths -- empty, separator-only, no separator at all.
  result.add(ActionResultRecord(weakFingerprint: digest,
    strongFingerprint: digest, policy: ffpTimestamp,
    outputPayloadKind: opkMetadataOnly,
    inputs: @[input(""), input("/"), input("bare"), input("/trailing/")]))
  # 8: many inputs sharing one long prefix -- the interning case, and the one
  #    the real workload is made of.
  var wide: seq[FileFingerprint]
  let prefix = "/" & repeat("deep/", 30)
  for i in 0 ..< 200:
    wide.add(input(prefix & "file" & $i & ".o"))
  result.add(ActionResultRecord(weakFingerprint: digest,
    strongFingerprint: digest, policy: ffpTimestamp,
    outputPayloadKind: opkCasBlobs, inputs: wide,
    outputs: @[output(prefix & "linked")]))
  # 9: many inputs with NO shared prefix -- the case interning cannot help,
  #    where the table is as large as the input list.
  var scattered: seq[FileFingerprint]
  for i in 0 ..< 200:
    scattered.add(input("/root" & $i & "/sub" & $i & "/f.o"))
  result.add(ActionResultRecord(weakFingerprint: digest,
    strongFingerprint: digest, policy: ffpTimestamp,
    outputPayloadKind: opkMetadataOnly, inputs: scattered))

# The load-bearing halves of the diagnostic's two phrasings.
const
  ExactPhrasing = "encoded "
  FloorPhrasing = "encodes to at least "
  SharedMarkers = ["shared-memory", "inline slot cap"]

proc mentionsOversizedDrop(text: string): bool =
  for marker in SharedMarkers:
    if marker notin text:
      return false
  true

suite "the shm inline-slot floor is sound":

  test "the floor never exceeds the real encoding, over every record shape":
    for index, record in corpus():
      let floor = encodedRecordSizeFloor(record)
      let actual = encodeActionResultRecord(record).len
      checkpoint("shape " & $(index + 1) & ": floor=" & $floor &
        " actual=" & $actual & " inputs=" & $record.inputs.len &
        " outputs=" & $record.outputs.len)
      # THE property. Not `<`: a shape whose variable-length payloads really
      # are all empty may legitimately sit exactly on the floor.
      check floor <= actual
      # Non-vacuity: a floor of zero would satisfy the line above for free.
      check floor > 0

  test "the floor is over the cap exactly when it should refuse early":
    # A record with a handful of inputs sits under the cap and must NOT be
    # refused on the floor -- it has to be encoded and measured. A record with
    # hundreds cannot possibly fit and must be.
    let shapes = corpus()
    let empty = shapes[0]
    let wide = shapes[7]
    checkpoint("empty floor=" & $encodedRecordSizeFloor(empty) &
      " wide floor=" & $encodedRecordSizeFloor(wide) &
      " cap=" & $SlotInlineCap)
    check encodedRecordSizeFloor(empty) <= SlotInlineCap
    check encodedRecordSizeFloor(wide) > SlotInlineCap

suite "an impossible shm submit is refused without encoding, and counted":

  test "a deep-root record is refused on the floor; a shallow one is encoded":
    when not shmIndexSupported:
      checkpoint("shared-memory index unsupported on this host; the refusal " &
        "path under test does not exist here")
      skip()
    else:
      let root = createTempDir("repro-shm-floor-", "")
      defer: removeDir(root)

      # A DEEP root. The path bytes alone put the record's FLOOR over the cap,
      # so the refusal happens before any encode.
      let deepRoot = root / repeat("d", 40) / repeat("e", 40) /
        repeat("f", 40)
      createDir(deepRoot)
      let wide = buildUnder(deepRoot)
      check wide.records.len > 0
      for record in wide.records:
        checkpoint("deep-root record: floor=" &
          $encodedRecordSizeFloor(record) & " actual=" &
          $encodeActionResultRecord(record).len & " cap=" & $SlotInlineCap)
        # Non-vacuity: the floor must be the thing that refused it, not the
        # encode. If the floor were under the cap this test would be measuring
        # the OLD path and would say nothing about the new one.
        check encodedRecordSizeFloor(record) > SlotInlineCap

      # Soundness again, this time over records production actually wrote.
      for record in wide.records:
        check encodedRecordSizeFloor(record) <=
          encodeActionResultRecord(record).len

      checkpoint("wide stderr: " & wide.stderrText.strip())
      check mentionsOversizedDrop(wide.stderrText)
      # NO DOOMED ENCODE: only the pre-encode path can say "at least", because
      # the post-encode path knows the exact width.
      check FloorPhrasing in wide.stderrText
      check ExactPhrasing & "2" notin wide.stderrText

      # THE COUNTER IS SURFACED, both as a stats accessor and as a timing row.
      check wide.oversized > 0
      check wide.oversizedFloorBytes > int64(SlotInlineCap)
      check wide.metricRow == wide.oversized

  test "a record that fits is submitted, unreported and uncounted":
    when not shmIndexSupported:
      skip()
    else:
      # A SHORT root keeps the encoding under the cap, so the tier carries the
      # record and must say nothing about it. Without this half the counter
      # and the diagnostic could both be unconditional and still pass above.
      let shortRoot = "/tmp/rbfloor-" & $getCurrentProcessId()
      removeDir(shortRoot)
      createDir(shortRoot)
      defer: removeDir(shortRoot)

      let narrow = buildUnder(shortRoot)
      check narrow.records.len > 0
      let encoded = narrow.records.mapIt(encodeActionResultRecord(it).len)
      checkpoint("narrow encoded sizes: " & $encoded & " cap " & $SlotInlineCap)

      # Non-vacuity: if the short root did not actually land under the cap this
      # test can say nothing, so say THAT rather than pass.
      check encoded.len > 0
      for size in encoded:
        check size <= SlotInlineCap
        check encodedRecordSizeFloor(narrow.records[0]) <= size

      check not mentionsOversizedDrop(narrow.stderrText)
      check FloorPhrasing notin narrow.stderrText
      check narrow.oversized == 0
      check narrow.oversizedFloorBytes == 0'i64
      # A zero counted metric is dropped before rendering, so the row is
      # absent rather than present-and-zero. Either way it must not claim a
      # drop that did not happen.
      check narrow.metricRow <= 0

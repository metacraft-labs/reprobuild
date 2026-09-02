## Local-CAS-Hardlink-Materialization M4 — the store's DISK COST, measured
## from the volume rather than inferred from the mechanism label.
##
## Spec: ``reprobuild-specs/Local-Content-Addressed-Store.md``
##       §"Hardlink, Reflink, and Copy Policy" (normative).
##
## M1 and M2 assert which mechanism ran and that the bytes are right. M2's
## "Not done here" says why neither of those is a cost claim, and the
## reason is M0's: the probe verifies a reflink by comparing BYTES, so a
## filesystem that silently degraded a clone to a full copy would still be
## recorded ``reflink = true``. A safe outcome, and a wrong cost claim. So
## nothing in this campaign may read a mechanism label as evidence of a
## saving, and nothing here does: every verdict below is computed from
## bytes of volume, and the mechanism is only ever reported alongside it.
##
## *The instrument is the volume, and that is a finding rather than a
## preference.* Two cheaper per-file oracles were tried on the reference
## host and both are disproved:
##
##   * ``GetCompressedFileSizeW`` reports a ReFS block clone at its FULL
##     logical size — measured here, 64 MiB source, four clones, every one
##     reported 64 MiB on disk while the volume's free space did not move.
##     The last suite in this file pins that, so a future Windows that
##     makes the cheap number sharing-aware fails a test and says so
##     instead of leaving the expensive instrument in place forever.
##   * ``FSCTL_GET_RETRIEVAL_POINTERS`` — the physical cluster map, which
##     WOULD be an exact per-file oracle — does not answer usefully on
##     ReFS here: over one 16 MiB file it reported a 249-extent map whose
##     first eight entries were identical for a clone, a ``CopyFileW``
##     copy AND a chunked stream copy, and comparing the full map then
##     reported a file as sharing with itself AFTER a truncating rewrite
##     had replaced its contents. Two mutually contradictory answers from
##     one call is not an oracle. It is not used, and it is recorded so it
##     is not re-tried in the belief that nobody looked.
##
## What is left is volume free space, and free space on ReFS is the trap
## this file exists to make executable. *ReFS defers the accounting.*
## Measured here: four 64 MiB clones read as 256 MiB consumed at t = 5 s,
## t = 10 s and t = 15 s — three consecutive, stable, agreeing samples
## that say "the reflink saved nothing" — and then as ZERO from t = 20 s
## onwards, flat for the next 30 s. The reference host's own S7 review
## fell into exactly this: it held a reading across a four-second window
## and called it settled, and the reclaim did not land until roughly 100
## seconds in. A short stability window here is not a settling check, it
## is a way of sampling the wrong number twice.
##
## ``settledConsumption`` is therefore the substance of the always-on half
## of this file, and its rule is: *the answer is the TERMINAL plateau, and
## only when that plateau is both long enough and old enough.* A run of
## agreeing samples in the middle of a series proves nothing, because the
## ReFS series above contains one. There is no "poll a bit longer and take
## whatever you have" arm: a series that has not settled yields "cannot
## measure", never a number.
##
## The live measurement — a real store, real blobs, real free space — is
## behind ``REPRO_M4_STORE_COST=1`` because it moves the better part of a
## gigabyte and polls for minutes, which is not a suite's business to do
## on every run. The always-on cases are the instrument; the gated ones
## are the reading. Both halves are needed: an instrument nobody points at
## anything is not evidence, and a reading taken with an instrument nobody
## checked is how the four-second window happened.
##
## Scope: the live arms and the size-on-disk arm are Windows-only, in the
## same way as the rest of this campaign. POSIX ``statvfs`` polling and
## ``st_blocks`` are not exercised here and no claim is made about them.

import std/[os, sequtils, strutils, times, unittest]

from repro_core/paths import extendedPath

import repro_cas_store

const CostGateEnv = "REPRO_M4_STORE_COST"

# ---------------------------------------------------------------------------
# The instrument: turning a free-space sample series into a verdict.
#
# Pure, so the ReFS trap can be replayed as data instead of waited for.
# ---------------------------------------------------------------------------

type
  VolumeSample = object
    ## One free-space observation. ``atSeconds`` is relative to the start
    ## of polling; only differences matter.
    atSeconds: float
    freeBytes: int64

  SettleVerdict = object
    settled: bool
      ## When false, ``consumed`` is NOT a measurement and MUST NOT be
      ## read as one. There is deliberately no third state.
    consumed: int64
    plateauSamples: int
    plateauSeconds: float
    reason: string

const
  SettleToleranceBytes = 8'i64 * 1024 * 1024
    ## Two samples this close count as the same reading. A live volume
    ## drifts under other processes; the reference host's ``D:`` swung by
    ## 15 GB while nominally idle, which is why the ABSOLUTE numbers here
    ## are only ever compared against a payload size chosen to dwarf the
    ## drift, never against zero.
  MinPlateauSamples = 4
  MinPlateauSeconds = 30.0
    ## Longer than the four-second window that produced the opposite
    ## conclusion on this host, and longer than the 15 s the deferred
    ## reclaim took here — but NOT longer than the ~100 s it took during
    ## S7's review, which is why the polling loop's own budget is minutes
    ## and why "not settled" has to be a reportable outcome rather than a
    ## failure.

proc settledConsumption(baselineFree: int64;
                        samples: openArray[VolumeSample];
                        toleranceBytes = SettleToleranceBytes;
                        minPlateauSamples = MinPlateauSamples;
                        minPlateauSeconds = MinPlateauSeconds): SettleVerdict =
  ## Consumption between ``baselineFree`` and the end of ``samples``, or a
  ## refusal to answer.
  ##
  ## The plateau is the LONGEST SUFFIX of the series whose samples are all
  ## within ``toleranceBytes`` of the final one. Taking the suffix rather
  ## than the first agreeing run is the whole point: on ReFS the series
  ## opens with a perfectly stable plateau at the un-reclaimed figure, so
  ## a rule that stopped at the first one would report that the clone
  ## saved nothing, with three agreeing samples behind it.
  if samples.len == 0:
    return SettleVerdict(settled: false, reason: "no samples were taken")
  let final = samples[^1]
  var firstOfPlateau = samples.len - 1
  while firstOfPlateau > 0 and
      abs(samples[firstOfPlateau - 1].freeBytes - final.freeBytes) <=
        toleranceBytes:
    dec firstOfPlateau
  result = SettleVerdict(
    settled: false,
    consumed: baselineFree - final.freeBytes,
    plateauSamples: samples.len - firstOfPlateau,
    plateauSeconds: final.atSeconds - samples[firstOfPlateau].atSeconds)
  if result.plateauSamples < minPlateauSamples:
    result.reason = "the terminal plateau is " & $result.plateauSamples &
      " sample(s); the volume is still moving, so no consumption figure " &
      "can be read off it"
    return
  if result.plateauSeconds < minPlateauSeconds:
    result.reason = "the terminal plateau spans only " &
      formatFloat(result.plateauSeconds, ffDecimal, 1) &
      " s; on a filesystem that defers free-space accounting a short " &
      "stable window samples the pre-reclaim figure twice rather than " &
      "settling"
    return
  result.settled = true

proc describe(v: SettleVerdict): string =
  if v.settled:
    "settled: " & $v.consumed & " B consumed (plateau " &
      $v.plateauSamples & " samples / " &
      formatFloat(v.plateauSeconds, ffDecimal, 1) & " s)"
  else:
    "NOT settled — " & v.reason

proc series(baselineFree: int64;
            deltasMib: openArray[float];
            everySeconds = 5.0): seq[VolumeSample] =
  ## A sample series expressed as "MiB consumed relative to baseline",
  ## which is how the reference measurements below were recorded.
  result = @[]
  for i, mib in deltasMib:
    result.add(VolumeSample(
      atSeconds: float(i + 1) * everySeconds,
      freeBytes: baselineFree - int64(mib * 1048576.0)))

const
  ReferenceBaseline = 1_000_000_000_000'i64
  # Measured on this host, 2026-08-25: one 64 MiB source on the ReFS
  # volume ``M:``, four ``attemptReflink`` clones of it, polled every 5 s.
  RefsReferenceDeltas = [256.25, 256.28, 255.94, -0.20, -0.43, -0.43,
                         -0.43, -0.43, -0.43, -0.43]
  # The same shape on a volume with no block cloning: the consumption is
  # real and it never goes away. Four copies of 64 MiB.
  NtfsReferenceDeltas = [256.30, 256.31, 256.28, 256.31, 256.29, 256.30,
                         256.28, 256.31, 256.30, 256.29]

# ---------------------------------------------------------------------------
# Host volumes. Same discovery approach as M0's and M1's test files: the
# host's real volumes decide which arms can be exercised, and an arm the
# host cannot supply announces rather than silently passing.
# ---------------------------------------------------------------------------

when defined(windows):
  import std/winlean

  proc getCompressedFileSizeW(name: WideCString; high: ptr DWORD): DWORD
    {.stdcall, dynlib: "kernel32", importc: "GetCompressedFileSizeW".}

  proc getDiskFreeSpaceExW(dir: WideCString;
                           freeToCaller, total, free: ptr int64): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "GetDiskFreeSpaceExW".}

  proc sizeOnDisk(path: string): int64 =
    ## The allocated size the FILESYSTEM reports for one file. Disproved
    ## as a sharing oracle by the last suite in this file; kept because
    ## disproving it is what justifies the expensive instrument.
    var hi: DWORD
    let lo = getCompressedFileSizeW(newWideCString(extendedPath(path)),
                                    addr hi)
    if lo == high(DWORD) and osLastError().int != 0:
      return -1
    (int64(uint32(hi)) shl 32) or int64(uint32(lo))

  proc volumeFreeBytes(dir: string): int64 =
    var freeToCaller, total, free: int64
    if getDiskFreeSpaceExW(newWideCString(extendedPath(dir)),
                           addr freeToCaller, addr total, addr free) == 0:
      return -1
    free

else:
  proc sizeOnDisk(path: string): int64 = -1
  proc volumeFreeBytes(dir: string): int64 = -1

type
  CostVolume = object
    dir: string
    fsName: string
    reflink: bool
    hardlink: bool

var scratchDirs: seq[string] = @[]

proc claimScratchDir(parent, tag: string): string =
  if parent.len == 0 or not dirExists(extendedPath(parent)):
    return ""
  let candidate = parent / ("repro-m4-" & $getCurrentProcessId() & "-" & tag)
  try:
    createDir(extendedPath(candidate))
    let witness = candidate / "witness"
    writeFile(extendedPath(witness), "ok")
    removeFile(extendedPath(witness))
  except CatchableError, Defect:
    return ""
  scratchDirs.add(candidate)
  candidate

proc candidateParents(): seq[string] =
  result = @[getTempDir()]
  when defined(windows):
    for letter in 'A' .. 'Z':
      result.add($letter & ":\\")
  else:
    for p in ["/tmp", "/var/tmp", getHomeDir()]:
      result.add(p)
  result.add(currentSourcePath().parentDir())

proc discoverVolumes(): seq[CostVolume] =
  result = @[]
  var seenKeys: seq[string] = @[]
  var tag = 0
  for parent in candidateParents():
    if parent.len == 0 or not dirExists(extendedPath(parent)):
      continue
    let key = filesystemPairKey(parent, parent)
    if key in seenKeys:
      continue
    let dir = claimScratchDir(parent, "vol" & $tag)
    tag.inc
    if dir.len == 0:
      continue
    seenKeys.add(key)
    var cache: LinkCapabilityCache
    let cap = probeLinkCapabilities(cache, dir, dir)
    result.add(CostVolume(dir: dir, fsName: filesystemName(dir),
                          reflink: cap.reflink, hardlink: cap.hardlink))

let volumes = discoverVolumes()

proc reflinkVolumes(): seq[CostVolume] = volumes.filterIt(it.reflink)
proc copyOnlyVolumes(): seq[CostVolume] = volumes.filterIt(not it.reflink)

proc describeHost(): string =
  volumes.mapIt(it.dir & "(" & it.fsName & " reflink=" & $it.reflink & ")")
    .join(", ")

# ---------------------------------------------------------------------------
# The live measurement.
# ---------------------------------------------------------------------------

const
  LivePayloadBytes = 128 * 1024 * 1024
  LiveMaterializations = 6
  LivePollSeconds = 5.0
  LivePollBudgetSeconds = 300.0

proc pollUntilSettled(dir: string; baselineFree: int64): SettleVerdict =
  ## Poll ``dir``'s volume until the free-space figure stops moving, or
  ## until the budget runs out. Returns the refusal rather than a guess.
  var samples: seq[VolumeSample] = @[]
  let started = epochTime()
  while true:
    sleep(int(LivePollSeconds * 1000))
    let now = epochTime() - started
    samples.add(VolumeSample(atSeconds: now, freeBytes: volumeFreeBytes(dir)))
    let verdict = settledConsumption(baselineFree, samples)
    if verdict.settled:
      return verdict
    if now >= LivePollBudgetSeconds:
      return verdict

proc writePayload(path: string; size: int) =
  ## Streamed rather than built as one string: the point of this file is
  ## disk, and a fixture that peaks at twice the payload in RAM is a
  ## different measurement's problem walking into this one.
  var chunk = newString(1024 * 1024)
  for i in 0 ..< chunk.len:
    chunk[i] = char((i * 131 + 7) and 0xFF)
  let f = open(extendedPath(path), fmWrite)
  var written = 0
  while written < size:
    let n = min(chunk.len, size - written)
    discard f.writeBuffer(addr chunk[0], n)
    written += n
  f.close()

type LiveResult = object
  ran: bool
  note: string
  logicalBytes: int64
  verdict: SettleVerdict
  mechanisms: seq[string]

proc measureStoreCost(vol: CostVolume): LiveResult =
  ## Ingest one payload into a CAS rooted on ``vol``, materialize it
  ## ``LiveMaterializations`` times onto the same volume, and report what
  ## the VOLUME says it cost. The mechanism is collected for the log line
  ## only; no assertion in this file reads it as evidence of a saving.
  let root = vol.dir / "cost"
  createDir(extendedPath(root))
  let source = root / "source.bin"
  writePayload(source, LivePayloadBytes)

  # Baseline AFTER the source exists and AFTER it has settled, so the
  # figure describes what the STORE added and not what the fixture did.
  let settleSource = pollUntilSettled(root, volumeFreeBytes(root))
  if not settleSource.settled:
    return LiveResult(ran: false,
      note: "the volume never went quiet even before the store was " &
        "touched (" & settleSource.describe & "), so nothing measured " &
        "afterwards would describe the store")
  let baseline = volumeFreeBytes(root)

  var cas = openCasStore(root / "store")
  var mechanisms: seq[string] = @[]
  var hash: ContentHash
  try:
    let put = cas.casPutPathDetailed(source)
    hash = put.hash
    mechanisms.add("ingest=" & $put.mechanism)
    var entries: seq[CasMaterialization] = @[]
    for i in 0 ..< LiveMaterializations:
      entries.add(CasMaterialization(hash: hash,
        destination: root / "out" / ("copy" & $i & ".bin")))
    for outcome in cas.casMaterializeDetailed(entries):
      mechanisms.add("restore=" & $outcome.mechanism)
  finally:
    cas.close()

  LiveResult(
    ran: true,
    # The source file is NOT counted: it existed before the baseline. What
    # the store added is the blob plus every materialization.
    logicalBytes: int64(LivePayloadBytes) * int64(LiveMaterializations + 1),
    verdict: pollUntilSettled(root, baseline),
    mechanisms: mechanisms)

# ---------------------------------------------------------------------------
# The instrument, asserted as data.
# ---------------------------------------------------------------------------

suite "M4 store occupancy — the instrument":

  test "a settled series reports what the volume actually gave back":
    ## The ReFS reference series measured on this host. The answer has to
    ## be the reclaimed figure, which is the LAST plateau, not the stable
    ## un-reclaimed one the series opens with.
    let samples = series(ReferenceBaseline, RefsReferenceDeltas)
    let verdict = settledConsumption(ReferenceBaseline, samples)
    checkpoint(verdict.describe)
    check verdict.settled
    # Four 64 MiB clones. A cost claim of "one copy" would be 64 MiB and
    # "no saving" would be 256 MiB; the volume gave back everything.
    check abs(verdict.consumed) < SettleToleranceBytes

  test "the first plateau is not the answer, and taking it inverts it":
    ## This is the failure the terminal-plateau rule exists to prevent,
    ## asserted directly: the opening three samples of the same series are
    ## stable, agree with each other, and say the clone saved nothing.
    let samples = series(ReferenceBaseline, RefsReferenceDeltas)
    let openingPlateau = samples[0 .. 2]
    check openingPlateau.len == 3
    for s in openingPlateau:
      check abs((ReferenceBaseline - s.freeBytes) - 256'i64 * 1048576) <
        SettleToleranceBytes
    # Same data, whole series: the opposite conclusion.
    let verdict = settledConsumption(ReferenceBaseline, samples)
    check verdict.settled
    check abs(verdict.consumed) < SettleToleranceBytes

  test "a four-second window over the same series refuses to conclude":
    ## S7's review held a reading across a four-second window and called
    ## it settled; the reclaim landed roughly 100 seconds later. The
    ## instrument must decline, not answer.
    ##
    ## Sampled densely enough that the SAMPLE-count condition is
    ## satisfied — five agreeing readings — so the case exercises the
    ## elapsed-time condition rather than passing for the easier reason.
    var samples: seq[VolumeSample] = @[]
    for i in 0 .. 4:
      samples.add(VolumeSample(atSeconds: float(i),
        freeBytes: ReferenceBaseline - 256'i64 * 1048576))
    let verdict = settledConsumption(ReferenceBaseline, samples)
    checkpoint(verdict.describe)
    check verdict.plateauSamples >= MinPlateauSamples
    check not verdict.settled
    check "defers free-space accounting" in verdict.reason
    # And the number it declined to report is the WRONG one — the
    # pre-reclaim figure, sampled five times.
    check abs(verdict.consumed - 256'i64 * 1048576) < SettleToleranceBytes

  test "a series that is still moving is not a measurement":
    var deltas: seq[float] = @[]
    for i in 0 .. 11:
      deltas.add(float(i) * 40.0)
    let samples = series(ReferenceBaseline, deltas)
    let verdict = settledConsumption(ReferenceBaseline, samples)
    checkpoint(verdict.describe)
    check not verdict.settled
    check verdict.plateauSamples < MinPlateauSamples

  test "no samples is a refusal, never a zero":
    ## ``consumed`` defaults to 0, and 0 is the "the reflink was free"
    ## answer. An empty series must not be able to produce it.
    let verdict = settledConsumption(ReferenceBaseline, @[])
    check not verdict.settled
    check verdict.reason.len > 0

  test "a real cost is settled and REPORTED, not excused":
    ## The direction that matters for M0's caveat. A filesystem that
    ## silently degraded every clone to a full copy would still be
    ## recorded ``reflink = true`` by the probe, because the probe
    ## compares bytes. The instrument does not consult the label, so the
    ## degraded series settles at the full 256 MiB and says so.
    let samples = series(ReferenceBaseline, NtfsReferenceDeltas)
    let verdict = settledConsumption(ReferenceBaseline, samples)
    checkpoint(verdict.describe)
    check verdict.settled
    check verdict.consumed > 250'i64 * 1048576
    check verdict.consumed < 262'i64 * 1048576

  test "the plateau must be long in samples AND in seconds":
    ## The two conditions are not the same one, and neither is redundant:
    ## a fast poll can collect four agreeing samples in a second, and a
    ## slow poll can span a minute in two.
    let dense = @[
      VolumeSample(atSeconds: 0.0, freeBytes: ReferenceBaseline),
      VolumeSample(atSeconds: 0.3, freeBytes: ReferenceBaseline),
      VolumeSample(atSeconds: 0.6, freeBytes: ReferenceBaseline),
      VolumeSample(atSeconds: 0.9, freeBytes: ReferenceBaseline),
      VolumeSample(atSeconds: 1.2, freeBytes: ReferenceBaseline)]
    let denseVerdict = settledConsumption(ReferenceBaseline, dense)
    check denseVerdict.plateauSamples >= MinPlateauSamples
    check not denseVerdict.settled

    let sparse = @[
      VolumeSample(atSeconds: 0.0, freeBytes: ReferenceBaseline),
      VolumeSample(atSeconds: 90.0, freeBytes: ReferenceBaseline)]
    let sparseVerdict = settledConsumption(ReferenceBaseline, sparse)
    check sparseVerdict.plateauSeconds >= MinPlateauSeconds
    check not sparseVerdict.settled

# ---------------------------------------------------------------------------
# Why the volume has to be the instrument.
# ---------------------------------------------------------------------------

suite "M4 store occupancy — the cheap oracle that does not work":

  test "size-on-disk reports a block clone at its full logical size":
    ## If this ever fails, the cheap per-file number has become
    ## sharing-aware on this host and the whole polling apparatus above
    ## can be replaced by two ``GetCompressedFileSizeW`` calls. That is a
    ## good failure to have, which is why it is an assertion and not a
    ## comment.
    checkpoint("host volumes: " & describeHost())
    let vols = reflinkVolumes()
    const windowsHost = defined(windows)
    if not windowsHost:
      checkpoint("[platform N/A] size-on-disk is queried through " &
        "GetCompressedFileSizeW; the POSIX st_blocks equivalent is not " &
        "exercised by this campaign")
      skip()
    elif vols.len == 0:
      checkpoint("[host N/A] no volume on this host supports block " &
        "cloning, so there is no clone to mis-measure")
      skip()
    else:
      let vol = vols[0]
      let dir = vol.dir / "oracle"
      createDir(extendedPath(dir))
      let src = dir / "src.bin"
      const Size = 16 * 1024 * 1024
      writePayload(src, Size)
      let clone = dir / "clone.bin"
      let attempt = attemptReflink(src, clone)
      checkpoint("reflink on " & vol.fsName & ": " & $attempt.outcome)
      check attempt.outcome == loOk
      let srcOnDisk = sizeOnDisk(src)
      let cloneOnDisk = sizeOnDisk(clone)
      echo "    ", vol.fsName, ": logical ", Size, " B; source on disk ",
        srcOnDisk, " B; clone on disk ", cloneOnDisk, " B"
      check getFileSize(extendedPath(clone)) == Size
      # The clone shares every extent with the source and costs the
      # volume nothing, and the per-file number still reports a full
      # allocation for it. That is the disproof.
      check cloneOnDisk >= int64(Size) - 1048576
      check srcOnDisk >= int64(Size) - 1048576
      removeDir(extendedPath(dir))

# ---------------------------------------------------------------------------
# The reading.
# ---------------------------------------------------------------------------

suite "M4 store occupancy — the live measurement":

  test "a reflink store does not pay for a materialization":
    ## M4's economics claim, as an assertion: one blob plus six
    ## materializations of it is 896 MiB of logical data, and on a store
    ## volume with block cloning it must cost the volume LESS THAN ONE
    ## extra copy. The verdict is computed from free space; the mechanism
    ## is logged and never tested, because a degraded clone reports
    ## ``reflink`` too.
    let vols = reflinkVolumes()
    if getEnv(CostGateEnv).len == 0:
      checkpoint("[sandbox-gated] " & CostGateEnv & " not set — this " &
        "case moves ~896 MiB and polls volume free space for minutes")
      skip()
    elif vols.len == 0:
      checkpoint("[host N/A] no volume on this host supports block " &
        "cloning")
      skip()
    else:
      let res = measureStoreCost(vols[0])
      # ECHOED rather than checkpointed. A cost figure that is only
      # visible when the assertion FAILS is prose again on every green
      # run, and the number is the whole point of the case.
      echo "    reflink store volume ", vols[0].dir, " (", vols[0].fsName,
        "): ", res.mechanisms.join(", ")
      if not res.ran:
        echo "    NOT MEASURED: ", res.note
      else:
        echo "    logical ", res.logicalBytes, " B; ", res.verdict.describe
      check res.ran
      check res.verdict.settled
      check res.verdict.consumed < int64(LivePayloadBytes)

  test "a store volume without block cloning pays for every copy":
    ## The other half, and the reason the flag S7 added is opt-in rather
    ## than the default. Same store, same call, same assertions computed
    ## the same way — a filesystem that cannot share extents must show up
    ## as the full logical set.
    let vols = copyOnlyVolumes()
    if getEnv(CostGateEnv).len == 0:
      checkpoint("[sandbox-gated] " & CostGateEnv & " not set")
      skip()
    elif vols.len == 0:
      checkpoint("[host N/A] every volume on this host supports block " &
        "cloning, so the copy arm's cost cannot be measured here")
      skip()
    else:
      let res = measureStoreCost(vols[0])
      echo "    copy-only store volume ", vols[0].dir, " (", vols[0].fsName,
        "): ", res.mechanisms.join(", ")
      if not res.ran:
        echo "    NOT MEASURED: ", res.note
      else:
        echo "    logical ", res.logicalBytes, " B; ", res.verdict.describe
      check res.ran
      check res.verdict.settled
      check res.verdict.consumed >
        (res.logicalBytes - int64(LivePayloadBytes)) div 2

suite "M4 store occupancy — teardown":

  test "every scratch directory this suite created is removed":
    var surviving: seq[string] = @[]
    for dir in scratchDirs:
      try:
        removeDir(extendedPath(dir))
      except CatchableError, Defect:
        discard
      if dirExists(extendedPath(dir)):
        surviving.add(dir)
    # NAMED rather than counted — M3 made the same change to its own
    # teardown, and the reason holds here: the only interesting question
    # about a survivor is WHICH volume it is on.
    if surviving.len > 0:
      echo "    surviving: ", surviving.join(", ")
    check surviving.len == 0

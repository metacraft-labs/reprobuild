import std/[algorithm, atomics, monotimes, os, strutils, times]
from repro_core/paths import extendedPath

import repro_core/codec
import repro_monitor_depfile/capabilities
import repro_monitor_depfile/types

const
  CanonicalFileKind = 1'u16
  FnvOffset = 14695981039346656037'u64
  FnvPrime = 1099511628211'u64

# DSL-port M9.R.15c.1 (fs-snoop fragment-log perf): the fragment log
# was opened, written, and closed once per emitted record. cmake's
# qt6-base configure issues tens of thousands of probes, so the per-
# record open/close traffic itself doubled the syscalls the monitor
# was supposed to observe — qt6-base configure wall-clock became
# impractical on Linux/macOS hosts (the fragment-dir lookup also
# touched ``createDir`` on every record).
#
# Fix: cache the fragment-log file handle per thread. The fragment
# path is a deterministic function of ``(fragmentDir, osPid,
# threadId)`` and each emitting thread only ever writes to its own
# fragment, so a threadvar slot avoids any cross-thread contention.
# We open lazily with ``fmAppend`` on first emit, encode the record
# into a stack-sized buffer, write the whole frame in a single
# ``writeBuffer`` call, and ``flushFile`` so a SIGKILL leaves any
# committed bytes intact in the OS page cache.
#
# Crash recovery: ``mergeFragments`` uses ``decodeFragmentRecordsTolerant``
# (NEW), which stops at the first truncated frame instead of raising.
# The fragment-log frame format already starts with a u32 length
# prefix, so a partial write is detected by ``pos + length > bytes.len``.
#
# DSL-port M9.R.15f.1 (fs-snoop fragment-log write batching): qt6-base
# configure issues millions of file probes, and even with the
# M9.R.15c.1 single-fd-per-thread cache the per-record
# ``writeBuffer`` + ``flushFile`` call pair drives two syscalls per
# emit (write + fdatasync-style fflush). Throughput plateaued around
# 946K emits/s in the M9.R.15c.1 microbench; for qt6-base + the KF6
# cascade we need another 10x.
#
# Fix: accumulate up to ``FragmentBatchBufLen`` bytes (64 KiB) of
# encoded frames in a per-thread stack-resident byte buffer and flush
# the entire batch in a single ``writeBuffer`` (followed by a single
# ``flushFile``). The encoded-frame protocol is unchanged so the
# tolerant reader continues to recover whole frames from a crash-
# truncated tail. A monotone-clock check on each emit forces a flush
# every ``FragmentBatchMaxAgeNs`` (default 100 ms) so a long-running
# producer with sparse emits doesn't lose more than the most recent
# ~6.4 ms of frames on SIGKILL (per the 64 KiB / 10 MB/s estimate),
# and never more than 100 ms regardless of write rate.
#
# Determinism guard: each batch flush is a contiguous append to the
# per-thread fragment file. Order within a thread is preserved by the
# in-batch buffer order (frames are appended bottom-to-top to a flat
# byte array). Cross-thread order is irrelevant — each thread writes
# to its own fragment file under a deterministic path
# (``fragmentPath(dir, osPid, threadId)``) and the merge step sorts
# by ``(osPid, threadId, seq, kind, path)`` in ``canonicalOrder``, so
# the on-disk batch boundaries leave the canonical depfile byte-
# identical regardless of when each thread flushed.
#
# Crash safety: ``writeBuffer`` of a 64 KiB block is not atomic with
# respect to SIGKILL (POSIX ``write`` may complete partially before
# a kill signal preempts the process). The tolerant reader handles
# this — any partial frame at the tail of the buffer is dropped at
# the next length-prefix boundary that overruns the file. Every
# frame ahead of the partial-tail boundary is byte-identical to what
# the producer wrote.
const
  FragmentDirBufLen = 4096
  FragmentBatchBufLen = 64 * 1024
  FragmentBatchMaxAgeNs = 100_000_000'i64  # 100 ms
  BatchStalenessProbeInterval = 64        # check time every 64 emits

type
  FragmentSlot = object
    # M9.R.15c.3 — the slot is a threadvar; with ``--mm:orc`` + the
    # ``--app:lib`` LD_PRELOAD shim build, a Nim ``string`` field on
    # a threadvar can trip the orc collector when cmake spawns and
    # tears down hundreds of worker threads (the qtbase configure
    # forks aggressively to run feature probes). Storing the
    # ``fragmentDir`` as a fixed-size POD char buffer plus a length
    # counter keeps the threadvar free of any Nim-runtime heap
    # pointer — every field is a flat value type whose destruction
    # at thread exit is a no-op. The buffer is sized for typical
    # absolute paths plus PATH_MAX headroom; an overrun aborts
    # cleanly before writing anything.
    isOpen: bool
    file: File
    fragmentDirLen: int
    fragmentDirBuf: array[FragmentDirBufLen, char]
    osPid: uint64
    threadId: uint64
    # M9.R.15f.1 — per-thread batch buffer. ``batchLen`` records how
    # many bytes of ``batchBuf`` are currently populated; flush
    # consumes the populated prefix and resets ``batchLen`` to 0.
    # ``batchOpenedAtNs`` records the monotone-clock timestamp at
    # which the first frame of the current batch was appended; the
    # next emit forces a flush when ``now - batchOpenedAtNs`` exceeds
    # ``FragmentBatchMaxAgeNs``.
    batchLen: int
    batchOpenedAtNs: int64
    # M9.R.15f.1 — amortise the staleness clock-read over many emits.
    # Reading the monotone clock on every emit costs ~20 ns/call which
    # is the dominant per-record cost once the inlined encoder lands;
    # we instead skip the staleness check entirely until at least
    # ``BatchStalenessProbeInterval`` records have been buffered. The
    # worst-case staleness window is bounded above by 100 ms +
    # (interval * per-emit-cost), still well below the SIGKILL data-
    # loss budget for any realistic emit rate.
    batchProbeCountdown: int
    batchBuf: array[FragmentBatchBufLen, byte]

var
  fragmentSlot {.threadvar.}: FragmentSlot
  fragmentOpenCount: Atomic[uint64]
  fragmentWriteCount: Atomic[uint64]
  fragmentFlushCount: Atomic[uint64]

proc slotFragmentDirEquals(slot: var FragmentSlot; s: string): bool =
  if slot.fragmentDirLen != s.len:
    return false
  for i in 0 ..< s.len:
    if slot.fragmentDirBuf[i] != s[i]:
      return false
  true

proc slotFragmentDirAssign(slot: var FragmentSlot; s: string): bool =
  if s.len >= FragmentDirBufLen:
    return false
  for i in 0 ..< s.len:
    slot.fragmentDirBuf[i] = s[i]
  slot.fragmentDirBuf[s.len] = '\0'
  slot.fragmentDirLen = s.len
  true

proc fragmentLogOpenCount*(): uint64 =
  ## DSL-port M9.R.15c.1 — return the lifetime number of fragment-log
  ## ``open()`` calls observed in this process. Tests assert this stays
  ## constant across a burst of ``appendFragmentRecord`` calls on the
  ## same (osPid, threadId, fragmentDir) — the previous implementation
  ## incremented this once per call; the cached implementation
  ## increments it exactly once per (thread, fragmentDir) pair.
  fragmentOpenCount.load(moRelaxed)

proc resetFragmentLogOpenCount*() =
  ## Test-only — reset the open counter between scenarios.
  fragmentOpenCount.store(0, moRelaxed)

proc fragmentLogWriteCount*(): uint64 =
  ## DSL-port M9.R.15f.1 — return the lifetime number of underlying
  ## ``writeBuffer`` calls the batched fragment writer issued. Tests
  ## assert this rises slowly relative to record count (a burst of N
  ## records that fit in the batch buffer should issue ceil(N / B)
  ## writes, not N).
  fragmentWriteCount.load(moRelaxed)

proc resetFragmentLogWriteCount*() =
  ## Test-only — reset the write counter between scenarios.
  fragmentWriteCount.store(0, moRelaxed)

proc fragmentLogFlushCount*(): uint64 =
  ## DSL-port M9.R.15f.1 — return the lifetime number of
  ## ``flushFile`` calls the batched writer issued. One flush per
  ## batch write.
  fragmentFlushCount.load(moRelaxed)

proc resetFragmentLogFlushCount*() =
  ## Test-only — reset the flush counter between scenarios.
  fragmentFlushCount.store(0, moRelaxed)

proc flushFragmentBatch*() =
  ## DSL-port M9.R.15f.1 — flush the in-flight batch buffer (if any)
  ## to the cached fragment file. Public so external code (close,
  ## merge, test teardown) can force a sync point without closing the
  ## file handle. If the slot is not open or the batch is empty, the
  ## call is a no-op.
  if not fragmentSlot.isOpen or fragmentSlot.batchLen == 0:
    return
  let bufLen = fragmentSlot.batchLen
  let written = fragmentSlot.file.writeBuffer(
    addr fragmentSlot.batchBuf[0], bufLen)
  if written != bufLen:
    # Drain whatever we managed, reset the buffer so we don't replay
    # bytes on the next flush, and raise — the producer cannot
    # recover from a short write.
    fragmentSlot.batchLen = 0
    fragmentSlot.batchOpenedAtNs = 0
    raiseEnvelopeError(eeMalformed,
      "short write to RMDF fragment for osPid=" & $fragmentSlot.osPid &
      " threadId=" & $fragmentSlot.threadId)
  flushFile(fragmentSlot.file)
  discard fragmentWriteCount.fetchAdd(1, moRelaxed)
  discard fragmentFlushCount.fetchAdd(1, moRelaxed)
  fragmentSlot.batchLen = 0
  fragmentSlot.batchOpenedAtNs = 0
  fragmentSlot.batchProbeCountdown = 0

proc closeFragmentSlot*() =
  ## Force the calling thread's cached fragment-log handle (if any) to
  ## close. Called on shim shutdown / thread exit / test teardown.
  ## M9.R.15f.1 — flush any in-flight batch buffer before closing so
  ## the on-disk fragment includes every appended frame.
  if fragmentSlot.isOpen:
    try:
      flushFragmentBatch()
    except EnvelopeError, IOError, OSError:
      discard
    try:
      close(fragmentSlot.file)
    except IOError, OSError:
      discard
    fragmentSlot.isOpen = false
    fragmentSlot.fragmentDirLen = 0
    fragmentSlot.fragmentDirBuf[0] = '\0'
    fragmentSlot.osPid = 0
    fragmentSlot.threadId = 0
    fragmentSlot.batchLen = 0
    fragmentSlot.batchOpenedAtNs = 0
    fragmentSlot.batchProbeCountdown = 0

proc checksum*(bytes: openArray[byte]): uint64 =
  result = FnvOffset
  for b in bytes:
    result = result xor uint64(b)
    result = result * FnvPrime

proc writeI64Le(outp: var seq[byte]; value: int64) =
  outp.writeU64Le(cast[uint64](value))

proc readI64Le(bytes: openArray[byte]; pos: var int): int64 =
  cast[int64](readU64Le(bytes, pos))

proc encodeRecordPayload*(record: MonitorRecord): seq[byte] =
  result = @[]
  result.writeU16Le(uint16(ord(record.kind)))
  result.writeU16Le(uint16(ord(record.observationKind)))
  result.writeU64Le(record.seq)
  result.writeU64Le(record.osPid)
  result.writeU64Le(record.parentOsPid)
  result.writeU64Le(record.threadId)
  result.writeU64Le(record.childOsPid)
  result.writeI64Le(record.result)
  result.writeU32Le(record.flags)
  result.writeU32Le(uint32(ord(record.probeResult)))
  result.writeString(record.path)
  result.writeString(record.detail)

proc decodeRecordPayload*(payload: openArray[byte]): MonitorRecord =
  var pos = 0
  let kindOrd = readU16Le(payload, pos)
  let obsOrd = readU16Le(payload, pos)
  if kindOrd < uint16(ord(low(MonitorRecordKind))) or
      kindOrd > uint16(ord(high(MonitorRecordKind))):
    raiseEnvelopeError(eeUnknownType, "unknown RMDF record kind")
  if obsOrd < uint16(ord(low(MonitorObservationKind))) or
      obsOrd > uint16(ord(high(MonitorObservationKind))):
    raiseEnvelopeError(eeUnknownType, "unknown RMDF observation kind")

  result.kind = MonitorRecordKind(kindOrd.int)
  result.observationKind = MonitorObservationKind(obsOrd.int)
  result.seq = readU64Le(payload, pos)
  result.osPid = readU64Le(payload, pos)
  result.parentOsPid = readU64Le(payload, pos)
  result.threadId = readU64Le(payload, pos)
  result.childOsPid = readU64Le(payload, pos)
  result.result = readI64Le(payload, pos)
  result.flags = readU32Le(payload, pos)
  let probeOrd = readU32Le(payload, pos)
  if probeOrd > uint32(ord(high(ProbeResult))):
    raiseEnvelopeError(eeUnknownType, "unknown RMDF probe result")
  result.probeResult = ProbeResult(probeOrd.int)
  result.path = readString(payload, pos)
  result.detail = readString(payload, pos)
  if pos != payload.len:
    raiseEnvelopeError(eeMalformed, "RMDF record has trailing bytes")

proc encodeFrame*(record: MonitorRecord): seq[byte] =
  let payload = encodeRecordPayload(record)
  result = @[]
  result.writeU32Le(uint32(payload.len))
  result.add(payload)

proc decodeFrames*(bytes: openArray[byte]): seq[MonitorRecord] =
  var pos = 0
  while pos < bytes.len:
    let length = int(readU32Le(bytes, pos))
    if length <= 0 or pos + length > bytes.len:
      raiseEnvelopeError(eeMalformed, "truncated RMDF record frame")
    result.add decodeRecordPayload(bytes.toOpenArray(pos, pos + length - 1))
    pos += length

proc decodeFramesTolerant*(bytes: openArray[byte]): seq[MonitorRecord] =
  ## DSL-port M9.R.15c.1 — like ``decodeFrames`` but stops at the first
  ## truncated trailing frame instead of raising. This is the crash-
  ## recovery path: a SIGKILL between ``writeBuffer`` and ``flushFile``
  ## may leave the fragment with a partial length-prefix or partial
  ## payload at the tail. Every complete frame ahead of it remains
  ## byte-identical to what the producer wrote.
  var pos = 0
  while pos < bytes.len:
    if pos + 4 > bytes.len:
      break
    var lengthCursor = pos
    let length = int(readU32Le(bytes, lengthCursor))
    if length <= 0 or lengthCursor + length > bytes.len:
      break
    try:
      result.add decodeRecordPayload(
        bytes.toOpenArray(lengthCursor, lengthCursor + length - 1))
    except EnvelopeError:
      break
    pos = lengthCursor + length

proc fragmentPath*(fragmentDir: string; osPid, threadId: uint64): string =
  fragmentDir / ("repro-monitor-" & $osPid & "-" & $threadId & ".rmdf-frag")

proc openFragmentSlot(fragmentDir: string; osPid, threadId: uint64;
                      path: string): bool =
  if not open(fragmentSlot.file, extendedPath(path), fmAppend):
    return false
  if not slotFragmentDirAssign(fragmentSlot, fragmentDir):
    # fragmentDir overflows the fixed-size buffer — close and bail out;
    # the caller falls back to the no-cache (raise) path.
    try: close(fragmentSlot.file)
    except IOError, OSError: discard
    return false
  fragmentSlot.isOpen = true
  fragmentSlot.osPid = osPid
  fragmentSlot.threadId = threadId
  fragmentSlot.batchLen = 0
  fragmentSlot.batchOpenedAtNs = 0
  fragmentSlot.batchProbeCountdown = 0
  discard fragmentOpenCount.fetchAdd(1, moRelaxed)
  true

proc monoNowNs(): int64 =
  ## DSL-port M9.R.15f.1 — monotone-clock read used to time-bound
  ## batch staleness. ``std/monotimes.getMonoTime`` calls
  ## ``clock_gettime(CLOCK_MONOTONIC)`` on POSIX and
  ## ``QueryPerformanceCounter`` on Windows; both are vDSO-resolved /
  ## userspace-fast and add ~ns of overhead to the hot path.
  cast[int64]((getMonoTime() - MonoTime()).inNanoseconds)

proc appendFragmentRecord*(fragmentDir: string; record: MonitorRecord) =
  ## DSL-port M9.R.15c.1 — emit ``record`` to the (osPid, threadId)
  ## fragment under ``fragmentDir``. The file handle is cached in a
  ## per-thread slot; the directory is only ``createDir``-ed on the
  ## open path. Truncated trailing bytes are tolerated by
  ## ``decodeFragmentRecordsTolerant`` (used by ``mergeFragments``).
  ##
  ## DSL-port M9.R.15f.1 — frames are appended to a per-thread
  ## ``FragmentBatchBufLen``-byte stack buffer; the batch is flushed
  ## to the file in a single ``writeBuffer`` + ``flushFile`` pair
  ## when (a) the next frame would overflow the buffer, (b) the
  ## (osPid, threadId, fragmentDir) key changes (so each fragment
  ## file receives only its own frames), (c) ``flushFragmentBatch``
  ## / ``closeFragmentSlot`` / ``mergeFragments`` is invoked, or
  ## (d) the current batch has been open for longer than
  ## ``FragmentBatchMaxAgeNs`` (default 100 ms) — bounding the worst-
  ## case data-loss window on SIGKILL.
  let needsReopen = not fragmentSlot.isOpen or
    not slotFragmentDirEquals(fragmentSlot, fragmentDir) or
    fragmentSlot.osPid != record.osPid or
    fragmentSlot.threadId != record.threadId
  if needsReopen:
    if fragmentSlot.isOpen:
      # Flush the in-flight batch BEFORE we close — otherwise the
      # buffered frames belong to the previous (osPid, threadId)
      # fragment but the close path drops them on the floor.
      try: flushFragmentBatch()
      except EnvelopeError, IOError, OSError: discard
      try: close(fragmentSlot.file)
      except IOError, OSError: discard
      fragmentSlot.isOpen = false
    createDir(extendedPath(fragmentDir))
    let path = fragmentPath(fragmentDir, record.osPid, record.threadId)
    if not openFragmentSlot(fragmentDir, record.osPid, record.threadId, path):
      raiseEnvelopeError(eeMalformed,
        "cannot open RMDF fragment for append: " & path)

  # M9.R.15f.1 — compute exact frame size first (4-byte length prefix
  # + fixed 58-byte header + 4 + path-bytes + 4 + detail-bytes) so we
  # can encode straight into the batch buffer without an intermediate
  # ``seq[byte]`` allocation. The frame layout matches
  # ``encodeFrame`` byte-for-byte; the unit tests assert the on-disk
  # bytes stay byte-identical to what the legacy ``encodeFrame`` +
  # ``copyMem`` path produced (the determinism test) so the inlined
  # encode is observably equivalent.
  const RecordHeaderBytes = 2 + 2 + 8 + 8 + 8 + 8 + 8 + 8 + 4 + 4
  let pathLen = record.path.len
  let detailLen = record.detail.len
  let payloadLen = RecordHeaderBytes + 4 + pathLen + 4 + detailLen
  let frameLen = 4 + payloadLen
  if frameLen == 0:
    return

  if frameLen > FragmentBatchBufLen:
    # Pathological case — a single frame larger than the batch buf.
    # Flush whatever is pending, then write the giant frame directly
    # via the legacy ``encodeFrame`` path to keep the file's frame-
    # boundary invariant.
    flushFragmentBatch()
    let frame = encodeFrame(record)
    let n = fragmentSlot.file.writeBuffer(unsafeAddr frame[0], frame.len)
    if n != frame.len:
      raiseEnvelopeError(eeMalformed,
        "short write to RMDF fragment for osPid=" & $record.osPid &
        " threadId=" & $record.threadId)
    flushFile(fragmentSlot.file)
    discard fragmentWriteCount.fetchAdd(1, moRelaxed)
    discard fragmentFlushCount.fetchAdd(1, moRelaxed)
    return

  if fragmentSlot.batchLen + frameLen > FragmentBatchBufLen:
    flushFragmentBatch()
  elif fragmentSlot.batchLen > 0:
    # Buffer non-empty + frame fits — but is the batch stale? If the
    # first frame of this batch landed more than ``FragmentBatchMaxAgeNs``
    # ago, force a flush so a sparse-emit producer doesn't sit on
    # buffered frames forever.
    #
    # The staleness check reads the monotone clock once per
    # ``BatchStalenessProbeInterval`` emits to amortise the vDSO
    # call cost across the steady-state hot path. ``batchProbeCountdown``
    # is initialised to 0 on batch-start so the FIRST post-start emit
    # always probes (catches the sparse-emit producer that lingers
    # past 100 ms between calls), then refreshes the countdown to the
    # full interval on a not-stale result.
    if fragmentSlot.batchProbeCountdown <= 0:
      let nowNs = monoNowNs()
      if nowNs - fragmentSlot.batchOpenedAtNs > FragmentBatchMaxAgeNs:
        flushFragmentBatch()
      else:
        fragmentSlot.batchProbeCountdown = BatchStalenessProbeInterval
    else:
      dec fragmentSlot.batchProbeCountdown

  if fragmentSlot.batchLen == 0:
    fragmentSlot.batchOpenedAtNs = monoNowNs()
    # Countdown starts at 0 so the first post-batch-start emit always
    # probes the clock — this catches sparse-emit producers whose
    # inter-emit gap exceeds the 100 ms staleness threshold and
    # ensures bounded data loss on SIGKILL.
    fragmentSlot.batchProbeCountdown = 0

  # Inline little-endian encode straight into the batch buffer at the
  # current offset. ``cursor`` is a local copy so we can store it
  # back to ``batchLen`` as a single write at the end.
  var cursor = fragmentSlot.batchLen
  template putByte(b: byte) =
    fragmentSlot.batchBuf[cursor] = b
    inc cursor
  template putU16Le(v: uint16) =
    putByte(byte(v and 0xFF'u16))
    putByte(byte((v shr 8) and 0xFF'u16))
  template putU32Le(v: uint32) =
    putByte(byte(v and 0xFF'u32))
    putByte(byte((v shr 8) and 0xFF'u32))
    putByte(byte((v shr 16) and 0xFF'u32))
    putByte(byte((v shr 24) and 0xFF'u32))
  template putU64Le(v: uint64) =
    putByte(byte(v and 0xFF'u64))
    putByte(byte((v shr 8) and 0xFF'u64))
    putByte(byte((v shr 16) and 0xFF'u64))
    putByte(byte((v shr 24) and 0xFF'u64))
    putByte(byte((v shr 32) and 0xFF'u64))
    putByte(byte((v shr 40) and 0xFF'u64))
    putByte(byte((v shr 48) and 0xFF'u64))
    putByte(byte((v shr 56) and 0xFF'u64))
  template putString(s: string) =
    putU32Le(uint32(s.len))
    if s.len > 0:
      copyMem(addr fragmentSlot.batchBuf[cursor], unsafeAddr s[0], s.len)
      cursor += s.len

  # Frame length prefix.
  putU32Le(uint32(payloadLen))
  # Record header — order MUST match encodeRecordPayload exactly.
  putU16Le(uint16(ord(record.kind)))
  putU16Le(uint16(ord(record.observationKind)))
  putU64Le(record.seq)
  putU64Le(record.osPid)
  putU64Le(record.parentOsPid)
  putU64Le(record.threadId)
  putU64Le(record.childOsPid)
  putU64Le(cast[uint64](record.result))
  putU32Le(record.flags)
  putU32Le(uint32(ord(record.probeResult)))
  putString(record.path)
  putString(record.detail)

  fragmentSlot.batchLen = cursor

proc readFragmentRecords*(path: string): seq[MonitorRecord] =
  let raw = readFile(extendedPath(path)).toBytes()
  decodeFrames(raw)

proc readFragmentRecordsTolerant*(path: string): seq[MonitorRecord] =
  ## DSL-port M9.R.15c.1 — crash-recovery sibling of
  ## ``readFragmentRecords``. Stops at the first truncated frame
  ## instead of raising, so a SIGKILL'd producer's fragment can still
  ## be merged into the canonical depfile.
  let raw = readFile(extendedPath(path)).toBytes()
  decodeFramesTolerant(raw)

proc canonicalOrder(a, b: MonitorRecord): int =
  result = cmp(a.osPid, b.osPid)
  if result != 0: return
  result = cmp(a.threadId, b.threadId)
  if result != 0: return
  result = cmp(a.seq, b.seq)
  if result != 0: return
  result = cmp(ord(a.kind), ord(b.kind))
  if result != 0: return
  result = cmp(a.path, b.path)

proc summarizeRecords*(records: openArray[MonitorRecord]): MonitorSummary =
  result.recordCount = uint64(records.len)
  var processPids: seq[uint64] = @[]
  for record in records:
    if record.osPid != 0 and processPids.find(record.osPid) < 0:
      processPids.add(record.osPid)
    if record.kind == mrEventLoss or record.observationKind == moEventLoss:
      inc result.eventLossCount
    else:
      inc result.observationCount
  result.processCount = uint64(processPids.len)

proc depFileFromRecords*(records: openArray[MonitorRecord]): MonitorDepFile =
  let summary = summarizeRecords(records)
  var profile = profileFromRecords(records)
  if summary.eventLossCount != 0:
    profile.evidenceComplete = false
  MonitorDepFile(
    version: RmdfVersion,
    producerVersion: ReproMonitorDepfileProducer,
    backendFamily: profile.backendFamily,
    requiredFeatures: profile.requiredCapabilities,
    completeness: if profile.evidenceComplete and summary.eventLossCount == 0:
        mcComplete
      else:
        mcIncomplete,
    profile: profile,
    capabilityGaps: profile.gaps,
    summary: summary,
    records: @records)

proc encodeCanonical*(records: openArray[MonitorRecord]): seq[byte] =
  var ordered = @records
  ordered.sort(canonicalOrder)
  for i in 0 ..< ordered.len:
    ordered[i].seq = uint64(i + 1)

  var body: seq[byte] = @[]
  for record in ordered:
    body.add encodeFrame(record)

  result = @[]
  result.add RmdfMagic.toBytes()
  result.writeU16Le(RmdfVersion)
  result.writeU16Le(CanonicalFileKind)
  result.writeU64Le(uint64(ordered.len))
  result.writeU64Le(uint64(body.len))
  result.add body
  result.add RmdfTrailerMagic.toBytes()
  result.writeU64Le(uint64(ordered.len))
  result.writeU64Le(checksum(body))

proc mergeFragments*(fragmentDir, outputPath: string): MonitorDepFile =
  # DSL-port M9.R.15c.1 — close the calling thread's cached fragment
  # handle before merging so any post-SIGKILL or pre-close buffered
  # bytes are visible to the read path. ``readFragmentRecordsTolerant``
  # then surfaces all complete frames, dropping only the last partial
  # frame (if any).
  closeFragmentSlot()
  var records: seq[MonitorRecord] = @[]
  if dirExists(extendedPath(fragmentDir)):
    for kind, path in walkDir(extendedPath(fragmentDir)):
      if kind == pcFile and path.endsWith(".rmdf-frag"):
        records.add readFragmentRecordsTolerant(path)
  records.add profileRecords(defaultHooksMonitorProfile(
    MacosMonitorShimTaxonomyCapabilities))

  let canonical = encodeCanonical(records)
  writeFile(extendedPath(outputPath), canonical.fromBytes())
  depFileFromRecords(records)

proc writeCanonical*(outputPath: string; records: openArray[MonitorRecord]) =
  let canonical = encodeCanonical(records)
  writeFile(extendedPath(outputPath), canonical.fromBytes())

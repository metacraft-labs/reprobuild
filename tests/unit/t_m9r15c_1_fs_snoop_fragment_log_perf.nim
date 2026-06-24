## DSL-port M9.R.15c.1 — fs-snoop fragment-log open-once + crash-recoverable.
##
## ## Context
##
## io-mon ``io_mon/writer.nim``'s
## ``appendFragmentRecord`` originally opened, wrote, and closed the
## fragment file on every emitted ``MonitorRecord``. cmake's qt6-base
## configure issues tens of thousands of file probes; the doubled
## syscall load (every ``openat`` triggered a follow-on
## open/write/close to append a fragment record) made wall-clock
## configure times impractical and was the blocker M9.R.15a flagged
## before stalling on qt6-base.
##
## M9.R.15c.1 caches the fragment-log file handle in a per-thread
## ``FragmentSlot`` threadvar. On the hot path ``appendFragmentRecord``
## now:
##
##   * opens the fragment file lazily on the first emit (or when the
##     ``(fragmentDir, osPid, threadId)`` key changes);
##   * encodes the record into a stack buffer and emits the whole
##     frame in a single ``writeBuffer`` call;
##   * ``flushFile``s so the OS page cache holds every completed frame
##     even if the producer is SIGKILL'd between writes.
##
## Crash recovery: ``mergeFragments`` now uses
## ``readFragmentRecordsTolerant``/``decodeFramesTolerant``, which
## stop at the first truncated trailing frame instead of raising.
## Every complete frame ahead of the partial tail is byte-identical
## to what the producer wrote, so the depfile remains parseable after
## SIGKILL.
##
## ## Coverage
##
## 1. **Open-once invariant** — emit 1000 records on the same
##    ``(fragmentDir, osPid, threadId)`` key and assert
##    ``fragmentLogOpenCount`` reports exactly one ``open()`` call.
##    Bursting more records must NOT amortise into additional opens.
## 2. **Determinism** — emit the same input twice into two separate
##    fragment dirs and assert the byte content is identical (the
##    fragment-frame format is deterministic and the per-thread
##    handle does not introduce nondeterminism).
## 3. **Crash recovery** — write N complete frames + truncate a final
##    partial frame, then assert ``readFragmentRecordsTolerant``
##    returns exactly the N complete records and ``mergeFragments``
##    parses the directory without raising.

import std/[os, strutils, unittest]

import io_mon/types
import io_mon/writer

proc sampleRecord(seq: uint64; osPid, threadId: uint64;
                  path: string): MonitorRecord =
  result = MonitorRecord(
    kind: mrFileOpen,
    observationKind: moFileOpen,
    seq: seq,
    osPid: osPid,
    parentOsPid: 1,
    threadId: threadId,
    childOsPid: 0,
    result: 3,
    flags: 0,
    probeResult: prUnknown,
    path: path,
    detail: "")

suite "DSL-port M9.R.15c.1 — fs-snoop fragment-log perf & crash recovery":

  test "1000 emits share a single open() call":
    # Start each scenario from a clean threadvar slot so the open-count
    # invariant measures only this burst — a sibling test on the same
    # thread (in the same process) would otherwise leave the slot warm.
    closeFragmentSlot()
    resetFragmentLogOpenCount()

    let fragmentDir = getTempDir() / ("m9r15c-1-perf-" & $getCurrentProcessId())
    createDir(fragmentDir)
    defer:
      closeFragmentSlot()
      removeDir(fragmentDir)

    const N = 1000
    let osPid = 4242'u64
    let threadId = 99'u64
    for i in 1 .. N:
      let record = sampleRecord(uint64(i), osPid, threadId,
        "/usr/include/header-" & $i & ".h")
      appendFragmentRecord(fragmentDir, record)

    # Hot-path invariant: a single open() per (thread, fragmentDir).
    check fragmentLogOpenCount() == 1

    # Sanity: every record made it onto disk. ``closeFragmentSlot``
    # flushes the FILE* so subsequent reads see all bytes.
    closeFragmentSlot()
    let fragmentFile = fragmentPath(fragmentDir, osPid, threadId)
    let records = readFragmentRecords(fragmentFile)
    check records.len == N
    for i in 0 ..< N:
      check records[i].seq == uint64(i + 1)
      check records[i].path == "/usr/include/header-" & $(i + 1) & ".h"

  test "determinism — same input produces byte-identical fragment file":
    closeFragmentSlot()

    let dirA = getTempDir() / ("m9r15c-1-det-a-" & $getCurrentProcessId())
    let dirB = getTempDir() / ("m9r15c-1-det-b-" & $getCurrentProcessId())
    createDir(dirA)
    createDir(dirB)
    defer:
      closeFragmentSlot()
      removeDir(dirA)
      removeDir(dirB)

    const N = 250
    let osPid = 1234'u64
    let threadId = 5'u64
    proc emitInto(dir: string) =
      closeFragmentSlot()
      for i in 1 .. N:
        let record = sampleRecord(uint64(i), osPid, threadId,
          "/det/path-" & $i)
        appendFragmentRecord(dir, record)
      closeFragmentSlot()

    emitInto(dirA)
    emitInto(dirB)

    let bytesA = readFile(fragmentPath(dirA, osPid, threadId))
    let bytesB = readFile(fragmentPath(dirB, osPid, threadId))
    check bytesA == bytesB
    check bytesA.len > 0

  test "crash recovery — truncated tail is tolerated; complete frames preserved":
    closeFragmentSlot()

    let fragmentDir = getTempDir() / ("m9r15c-1-crash-" & $getCurrentProcessId())
    createDir(fragmentDir)
    defer:
      closeFragmentSlot()
      removeDir(fragmentDir)

    const N = 100
    let osPid = 7777'u64
    let threadId = 13'u64
    for i in 1 .. N:
      let record = sampleRecord(uint64(i), osPid, threadId,
        "/crash/path-" & $i)
      appendFragmentRecord(fragmentDir, record)
    closeFragmentSlot()

    let fragmentFile = fragmentPath(fragmentDir, osPid, threadId)

    # Simulate mid-write SIGKILL: append a partial length prefix plus
    # a few payload bytes that don't constitute a complete record. The
    # writer already flushed every complete frame ahead of this tail
    # (cached handle was closed via ``closeFragmentSlot``), so the
    # tolerant reader must return exactly N records and skip the tail.
    let raw = readFile(fragmentFile)
    let truncatedTail = "\xff\xff\xff\xff" & "AB"
      # u32 length 0xFFFFFFFF — would overrun the file, so the
      # tolerant decoder stops; plus 2 stray bytes that mimic a
      # partial payload write.
    writeFile(fragmentFile, raw & truncatedTail)

    let recovered = readFragmentRecordsTolerant(fragmentFile)
    check recovered.len == N
    for i in 0 ..< N:
      check recovered[i].seq == uint64(i + 1)
      check recovered[i].path == "/crash/path-" & $(i + 1)

    # mergeFragments uses the tolerant reader, so the entire directory
    # parses without raising and the canonical depfile contains every
    # complete record.
    let outputPath = fragmentDir / "merged.rdep"
    let dep = mergeFragments(fragmentDir, outputPath)
    var fileOpenCount = 0
    for r in dep.records:
      if r.kind == mrFileOpen and r.path.startsWith("/crash/path-"):
        inc fileOpenCount
    check fileOpenCount == N

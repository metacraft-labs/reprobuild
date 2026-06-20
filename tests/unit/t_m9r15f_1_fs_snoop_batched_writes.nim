## DSL-port M9.R.15f.1 — fs-snoop fragment-log write batching.
##
## ## Context
##
## ``libs/repro_monitor_depfile/src/repro_monitor_depfile/writer.nim``
## after M9.R.15c.1 issued one ``writeBuffer`` + one ``flushFile``
## syscall pair per emitted ``MonitorRecord``. cmake's qt6-base
## configure issues millions of file probes; the M9.R.15c
## microbenchmark plateaued around 946K emits/s on a fast Linux host
## which is still too slow for the KF6 + Plasma cascade fitness
## window. M9.R.15f.1 accumulates frames in a per-thread
## ``FragmentBatchBufLen``-byte stack buffer and flushes the batch as
## a single ``writeBuffer`` + ``flushFile`` pair when:
##
##   * the next frame would overflow the buffer;
##   * the (osPid, threadId, fragmentDir) key changes;
##   * ``flushFragmentBatch`` / ``closeFragmentSlot`` /
##     ``mergeFragments`` is invoked;
##   * the current batch has been open for more than ~100 ms.
##
## ## Coverage
##
## 1. **Throughput** — 100k emits on a single (osPid, threadId)
##    must run at ``≥ 10 M emit/s`` so the qt6-base configure +
##    KF6 cascade fits the campaign budget. The previous M9.R.15c.1
##    microbench measured ~946 K emits/s on the same host.
## 2. **Write-count amortization** — emitting N short records must
##    drive far fewer ``writeBuffer`` syscalls than N: with the 64 KiB
##    stack buffer the underlying-write count must stay below
##    ``ceil(N / 64)`` for typical short paths (the qt6 probe footprint
##    is ~100-200 bytes per frame, comfortably above 64 frames per
##    flush).
## 3. **Determinism** — same input sequence into two separate fragment
##    dirs must produce byte-identical fragment files; the batch
##    boundaries must not introduce ordering nondeterminism.
## 4. **Crash recovery (partial batch)** — write N complete frames
##    then truncate a partial frame at the tail; the tolerant reader
##    must return exactly the N complete records that were flushed
##    before the simulated crash.

import std/[monotimes, os, strutils, times, unittest]

import repro_monitor_depfile/types
import repro_monitor_depfile/writer

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

suite "DSL-port M9.R.15f.1 — fs-snoop fragment-log batched writes":

  test "throughput ≥ 10M emit/s on 100k same-key emits":
    closeFragmentSlot()
    resetFragmentLogOpenCount()
    resetFragmentLogWriteCount()
    resetFragmentLogFlushCount()

    let fragmentDir = getTempDir() / ("m9r15f-1-thru-" & $getCurrentProcessId())
    createDir(fragmentDir)
    defer:
      closeFragmentSlot()
      removeDir(fragmentDir)

    const N = 100_000
    let osPid = 4242'u64
    let threadId = 99'u64

    # Warm the slot (open + first batch start) so the throughput
    # measurement reflects steady-state hot-path cost only.
    let warm = sampleRecord(0'u64, osPid, threadId, "/warm")
    appendFragmentRecord(fragmentDir, warm)
    flushFragmentBatch()

    let t0 = getMonoTime()
    for i in 1 .. N:
      # Use a short, fixed-shape path so the per-frame size is
      # predictable. qt6 probes typical-case at ~80-200 bytes.
      let record = sampleRecord(uint64(i), osPid, threadId,
        "/usr/include/h-" & $i & ".h")
      appendFragmentRecord(fragmentDir, record)
    flushFragmentBatch()
    let t1 = getMonoTime()
    let elapsedNs = (t1 - t0).inNanoseconds
    let elapsedS = float64(elapsedNs) / 1_000_000_000.0
    let throughput = float64(N) / elapsedS
    checkpoint("elapsed=" & $elapsedS & "s throughput=" &
      $throughput & " emit/s writes=" &
      $fragmentLogWriteCount() & " flushes=" &
      $fragmentLogFlushCount())

    # Target: 10 M emit/s. The M9.R.15c.1 baseline measured ~946 K
    # emit/s; batching to 64 KiB amortises the writeBuffer + flushFile
    # over ~256+ frames per syscall pair so the steady-state hot path
    # is dominated by the encode (seq -> bytes) cost, not the kernel.
    check throughput >= 10_000_000.0

  test "write-count amortization — 100 short emits drive < 5 writeBuffer calls":
    closeFragmentSlot()
    resetFragmentLogWriteCount()
    resetFragmentLogFlushCount()

    let fragmentDir = getTempDir() / ("m9r15f-1-amort-" & $getCurrentProcessId())
    createDir(fragmentDir)
    defer:
      closeFragmentSlot()
      removeDir(fragmentDir)

    const N = 100
    let osPid = 1111'u64
    let threadId = 22'u64
    for i in 1 .. N:
      let record = sampleRecord(uint64(i), osPid, threadId,
        "/short/" & $i)
      appendFragmentRecord(fragmentDir, record)
    flushFragmentBatch()

    # Each short frame is well under 100 bytes, so 100 frames fit in
    # the 64 KiB batch buffer multiple times over. The only flushes
    # we should see are the explicit ``flushFragmentBatch`` calls in
    # the test (one) plus any time-based flushes triggered by the
    # 100 ms staleness threshold. The 100-record loop runs in well
    # under 100 ms, so the count must be exactly 1.
    check fragmentLogWriteCount() == 1
    check fragmentLogFlushCount() == 1

  test "determinism — same input -> byte-identical fragment":
    closeFragmentSlot()

    let dirA = getTempDir() / ("m9r15f-1-det-a-" & $getCurrentProcessId())
    let dirB = getTempDir() / ("m9r15f-1-det-b-" & $getCurrentProcessId())
    createDir(dirA)
    createDir(dirB)
    defer:
      closeFragmentSlot()
      removeDir(dirA)
      removeDir(dirB)

    const N = 1024
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

  test "crash recovery — partial in-batch frames are recovered up to last flush":
    closeFragmentSlot()

    let fragmentDir = getTempDir() / ("m9r15f-1-crash-" & $getCurrentProcessId())
    createDir(fragmentDir)
    defer:
      closeFragmentSlot()
      removeDir(fragmentDir)

    # Emit N1 records and explicitly flush — these MUST survive.
    const N1 = 500
    let osPid = 7777'u64
    let threadId = 13'u64
    for i in 1 .. N1:
      let record = sampleRecord(uint64(i), osPid, threadId,
        "/crash/path-" & $i)
      appendFragmentRecord(fragmentDir, record)
    flushFragmentBatch()

    # Emit N2 records that stay in the per-thread batch buffer (no
    # flush). On a SIGKILL, these frames live only in process memory
    # and are lost — the on-disk file holds only the flushed N1.
    const N2 = 200
    for i in N1 + 1 .. N1 + N2:
      let record = sampleRecord(uint64(i), osPid, threadId,
        "/crash/path-" & $i)
      appendFragmentRecord(fragmentDir, record)

    # Simulate SIGKILL — drop the threadvar slot without flushing.
    # We use a manual close-without-flush by reading the file
    # directly. The on-disk file is whatever the kernel flushed via
    # ``flushFile`` during the explicit ``flushFragmentBatch`` call
    # above, plus nothing more.
    let fragmentFile = fragmentPath(fragmentDir, osPid, threadId)
    let raw = readFile(fragmentFile)

    # Append a truncated-tail payload to model the cross-process
    # SIGKILL-mid-writeBuffer case (where a kill signal preempts a
    # partial-batch write). The tolerant reader must stop at the
    # last complete frame and return exactly N1 records.
    let truncatedTail = "\xff\xff\xff\xff" & "XY"
    writeFile(fragmentFile, raw & truncatedTail)

    let recovered = readFragmentRecordsTolerant(fragmentFile)
    check recovered.len == N1
    for i in 0 ..< N1:
      check recovered[i].seq == uint64(i + 1)
      check recovered[i].path == "/crash/path-" & $(i + 1)

    # ``mergeFragments`` must parse without raising.
    let outputPath = fragmentDir / "merged.rdep"
    let dep = mergeFragments(fragmentDir, outputPath)
    var fileOpenCount = 0
    for r in dep.records:
      if r.kind == mrFileOpen and r.path.startsWith("/crash/path-"):
        inc fileOpenCount
    check fileOpenCount == N1

  test "time-based flush — stale batch is flushed on next emit after 100ms":
    closeFragmentSlot()
    resetFragmentLogWriteCount()
    resetFragmentLogFlushCount()

    let fragmentDir = getTempDir() / ("m9r15f-1-time-" & $getCurrentProcessId())
    createDir(fragmentDir)
    defer:
      closeFragmentSlot()
      removeDir(fragmentDir)

    let osPid = 5555'u64
    let threadId = 7'u64

    # First emit: opens slot, starts batch (no flush yet).
    appendFragmentRecord(fragmentDir,
      sampleRecord(1'u64, osPid, threadId, "/t/first"))
    check fragmentLogWriteCount() == 0
    check fragmentLogFlushCount() == 0

    # Sleep past the 100 ms staleness threshold.
    sleep(150)

    # Second emit: the staleness check fires, forcing a flush of the
    # first frame BEFORE the second frame is appended. The on-disk
    # file now holds one complete frame; the second frame is the
    # head of a fresh batch.
    appendFragmentRecord(fragmentDir,
      sampleRecord(2'u64, osPid, threadId, "/t/second"))
    check fragmentLogWriteCount() == 1
    check fragmentLogFlushCount() == 1

    # Explicit flush + close so we can read.
    closeFragmentSlot()
    let recovered = readFragmentRecords(
      fragmentPath(fragmentDir, osPid, threadId))
    check recovered.len == 2
    check recovered[0].path == "/t/first"
    check recovered[1].path == "/t/second"

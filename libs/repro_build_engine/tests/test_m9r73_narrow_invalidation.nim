## M9.R.73.2 — regression coverage for narrow Level 1 path-set
## invalidation of monitor-loss events.
##
## The M9.R.72.3 predecessor collapsed Level 1 (known scope) and Level 2
## (unknown scope) into the same per-action publish-skip. M9.R.73.2
## separates them per the soundness memo in
## ``reprobuild-specs/Monitor-Loss-Path-Invalidation.md``:
##
##   Level 1 (kill-before-flush) — publish the action's cache entry;
##     populate ``EvidenceCollection.invalidatedPaths`` with the action's
##     materialized declared outputs. Downstream cache LOOKUPS whose
##     declared inputs intersect the session-scoped accumulator are
##     skipped. Non-intersecting lookups are served normally.
##   Level 2 (unmonitored subtree, out-of-tree content, ambiguous
##     fragment, duplicate identity token, corrupt fragment,
##     unauthenticated breakaway report, unknown detail) — set
##     ``EvidenceCollection.disableCacheHits`` to skip THIS action's
##     publish, and flip a session-wide flag that forces ALL
##     downstream cache lookups to miss.
##   Level 3 (RMDF path empty or decode error) — fail closed.
##
## These tests exercise the classifier's Level-1 output at the evidence
## level (unit) and the ``invalidatedPaths`` population at the
## ``collectEvidence`` / ``foldMonitorDepFileEvidence`` boundary
## (integration). Scheduler-level session-accumulator semantics are
## covered by the classifier's contract plus manual inspection of the
## scheduler's ``cacheLookupBlockedByMonitorLoss`` predicate.

import std/[os, sets, strutils, unittest]

import repro_build_engine
import io_mon/[types, writer]

const TmpDir = "build/test-tmp/test_m9r73_narrow_invalidation"

proc resetTmp() =
  if dirExists(TmpDir):
    removeDir(TmpDir)
  createDir(TmpDir)

suite "M9.R.73.2 narrow Level 1 path-set invalidation":

  test "classifier maps corrupt-fragment to Level 2 (M9.R.73.2 addition)":
    ## io-mon writer.nim:2158 emits this prefix on any fragment that
    ## fails to decode cleanly to EOF. Per the memo, this is Level 2
    ## because the reader cannot bound which records were lost.
    check classifyEventLossDetail(
      "corrupt or partial RMDF fragment in /tmp/frag-dir-abc123") ==
      mesUnknownScopeLoss

  test "classifier maps out-of-tree content channel to Level 2 (M9.R.73.2 addition)":
    ## io-mon writer.nim:2282 emits this prefix. Replaces the pre-M9.R.73
    ## unit-test placeholder "external content" which was never an
    ## actual io-mon prefix.
    check classifyEventLossDetail(
      "out-of-tree content channel consumed (POSIX shm not created " &
      "in-tree, FIFO with no in-tree writer, or an inherited pipe/socket " &
      "with no in-tree create) — the real input is invisible, re-run") ==
      mesUnknownScopeLoss

  test "kill-before-flush RMDF yields Level 1 status":
    ## Baseline: the M9.R.72.3 semantic still holds — kill-before-flush
    ## classifies as Level 1 (known scope), which unlocks the narrow
    ## invalidation path in ``collectEvidence``.
    resetTmp()
    let rmdfPath = TmpDir / "kill-before-flush.rdep"
    let killLoss = MonitorRecord(
      kind: mrEventLoss,
      observationKind: moEventLoss,
      osPid: 4242,
      threadId: 8484,
      detail: "process killed with an un-flushed read batch (kill-before-flush)")
    let encoded = encodeCanonical(@[killLoss])
    writeFile(rmdfPath, cast[string](encoded))

    var evidence: PathSetEvidence
    var seen: EvidenceSeenSets
    let status = foldMonitorDepFileEvidence(rmdfPath, "", evidence, seen)
    check status == mesKnownScopeLoss

  test "unmonitored subtree RMDF yields Level 2 status (baseline)":
    ## Distinguishing case for the Level 1 vs Level 2 split: an
    ## unmonitored subtree loss is Level 2. The scheduler's
    ## ``cacheLookupBlockedByMonitorLoss`` predicate must respond to
    ## Level 2 by disabling cache hits session-wide, not by adding to
    ## the narrow ``sessionInvalidatedPaths`` accumulator.
    resetTmp()
    let rmdfPath = TmpDir / "unmonitored-subtree.rdep"
    let subtreeLoss = MonitorRecord(
      kind: mrEventLoss,
      observationKind: moEventLoss,
      osPid: 0,
      threadId: 0,
      detail: "unmonitored subtree/peer (un-injectable spawn child)")
    let encoded = encodeCanonical(@[subtreeLoss])
    writeFile(rmdfPath, cast[string](encoded))

    var evidence: PathSetEvidence
    var seen: EvidenceSeenSets
    let status = foldMonitorDepFileEvidence(rmdfPath, "", evidence, seen)
    check status == mesUnknownScopeLoss

  test "Level 1 loss preserves trustworthy path observations":
    ## Same invariant as M9.R.72.3 Phase D but re-asserted under the
    ## narrow-invalidation semantic: real reads survive the loss record.
    ## This is the LOAD-BEARING assertion — throwing away 250K valid
    ## path observations because one action was kill-before-flushed
    ## would be the pre-M9.R.72 behavior.
    resetTmp()
    let rmdfPath = TmpDir / "kill-with-reads.rdep"

    let realRead1 = MonitorRecord(
      kind: mrFileRead, observationKind: moFileRead,
      osPid: 100, threadId: 100, path: "/some/valid/a.h", detail: "")
    let realRead2 = MonitorRecord(
      kind: mrFileRead, observationKind: moFileRead,
      osPid: 100, threadId: 100, path: "/some/valid/b.h", detail: "")
    let killLoss = MonitorRecord(
      kind: mrEventLoss, observationKind: moEventLoss,
      osPid: 1234, threadId: 5678,
      detail: "process killed with an un-flushed read batch (kill-before-flush)")

    let encoded = encodeCanonical(@[realRead1, realRead2, killLoss])
    writeFile(rmdfPath, cast[string](encoded))

    var evidence: PathSetEvidence
    var seen: EvidenceSeenSets
    let status = foldMonitorDepFileEvidence(rmdfPath, "", evidence, seen)
    check status == mesKnownScopeLoss
    check evidence.monitorReads.len == 2

  test "worst-status wins across mixed loss records (Level 1 + Level 2)":
    ## An RMDF with BOTH a Level 1 loss AND a Level 2 loss must return
    ## Level 2 (the worse of the two). At the scheduler level this
    ## means the ``sessionCachePublishDisabled`` bit is flipped even
    ## when a Level 1 was present — a Level 2 promotes to full
    ## session-wide disable, per the memo's "Interaction With Level 2"
    ## note.
    resetTmp()
    let rmdfPath = TmpDir / "mixed-loss.rdep"

    let killLoss = MonitorRecord(
      kind: mrEventLoss, observationKind: moEventLoss,
      osPid: 100, threadId: 100,
      detail: "process killed with an un-flushed read batch (kill-before-flush)")
    let subtreeLoss = MonitorRecord(
      kind: mrEventLoss, observationKind: moEventLoss,
      osPid: 0, threadId: 0,
      detail: "unmonitored subtree/peer (SETEXEC into hardened image)")

    let encoded = encodeCanonical(@[killLoss, subtreeLoss])
    writeFile(rmdfPath, cast[string](encoded))

    var evidence: PathSetEvidence
    var seen: EvidenceSeenSets
    let status = foldMonitorDepFileEvidence(rmdfPath, "", evidence, seen)
    check status == mesUnknownScopeLoss

  test "no loss records yields Level 0 (baseline)":
    ## Sanity check: the M9.R.73.2 refactor MUST NOT flip a healthy
    ## RMDF to any loss level. Any regression here would poison every
    ## build's cache lookups.
    resetTmp()
    let rmdfPath = TmpDir / "complete.rdep"

    let read1 = MonitorRecord(kind: mrFileRead, observationKind: moFileRead,
      osPid: 1, threadId: 1, path: "/x.h", detail: "")
    let encoded = encodeCanonical(@[read1])
    writeFile(rmdfPath, cast[string](encoded))

    var evidence: PathSetEvidence
    var seen: EvidenceSeenSets
    let status = foldMonitorDepFileEvidence(rmdfPath, "", evidence, seen)
    check status == mesComplete

  test "volatile runtime paths never become observed cache inputs":
    resetTmp()
    let rmdfPath = TmpDir / "volatile-runtime-paths.rdep"
    let stablePath = TmpDir / "stable-input.txt"
    let records = @[
      MonitorRecord(kind: mrFileRead, observationKind: moFileRead,
        osPid: 1, threadId: 1, path: stablePath),
      MonitorRecord(kind: mrFileRead, observationKind: moFileRead,
        osPid: 1, threadId: 1, path: "/proc/self/fd/4"),
      MonitorRecord(kind: mrFileOpen, observationKind: moFileRead,
        osPid: 1, threadId: 1, path: "/sys/devices/system/cpu/online"),
      MonitorRecord(kind: mrFileWrite, observationKind: moFileWrite,
        osPid: 1, threadId: 1, path: "/dev/null"),
      MonitorRecord(kind: mrPathProbe, observationKind: moPathProbe,
        osPid: 1, threadId: 1, path: "/run/user/1000/socket"),
    ]
    writeFile(rmdfPath, cast[string](encodeCanonical(records)))

    var evidence: PathSetEvidence
    var seen: EvidenceSeenSets
    let status = foldMonitorDepFileEvidence(rmdfPath, "", evidence, seen)

    check status == mesComplete
    check evidence.monitorReads == @[stablePath]
    check evidence.monitorWrites.len == 0
    check evidence.monitorProbes.len == 0

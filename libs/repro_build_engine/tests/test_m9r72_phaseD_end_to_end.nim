## M9.R.72.3 Phase D — end-to-end validation of the spec-graded
## monitor-loss ladder.
##
## Phase C1's unit test (test_m9r72_monitor_loss_classifier.nim)
## exercises the classifier in isolation. This Phase D test constructs
## a synthetic RMDF file with real io-mon-encoded records including
## a mrEventLoss entry, then runs it through
## foldMonitorDepFileEvidence to verify the returned status matches
## the classifier's mapping AND that path-set evidence is still
## folded from the trustworthy portion of the depfile.
##
## The load-bearing assertion: an RMDF with kill-before-flush loss +
## real file-read records must produce mesKnownScopeLoss, NOT
## mesMonitorUnavailable, and the monitorReads MUST still contain the
## trustworthy paths — because the M9.R.60.D / M9.R.68 / M9.R.70
## symptom is exactly "throwing away 250K valid path observations
## because 182 kill-before-flush markers turned into synthetic
## mrEventLoss records".

import std/[os, strutils, unittest]

import repro_build_engine
import io_mon/[types, writer]

const TmpDir = "build/test-tmp/test_m9r72_phaseD"

proc resetTmp() =
  if dirExists(TmpDir):
    removeDir(TmpDir)
  createDir(TmpDir)

suite "M9.R.72.3 Phase D end-to-end monitor-loss handling":

  test "kill-before-flush + real reads yields Level 1, path set preserved":
    ## Build an RMDF with:
    ##   * a real file-read record on /some/valid/input.h
    ##   * a mrEventLoss with detail = kill-before-flush prefix
    ## The engine's foldMonitorDepFileEvidence should:
    ##   * return mesKnownScopeLoss (Level 1)
    ##   * still populate evidence.monitorReads with /some/valid/input.h
    ## This is the CORRECT direction — the trustworthy 250K path
    ## observations survive the kill-before-flush event-loss and can
    ## still contribute to the strong fingerprint.
    resetTmp()
    let rmdfPath = TmpDir / "kill-before-flush.rdep"

    let realRead = MonitorRecord(
      kind: mrFileRead,
      observationKind: moFileRead,
      osPid: 1000,
      threadId: 1000,
      path: "/some/valid/input.h",
      detail: "")

    let killLoss = MonitorRecord(
      kind: mrEventLoss,
      observationKind: moEventLoss,
      osPid: 1234,
      threadId: 5678,
      detail: "process killed with an un-flushed read batch (kill-before-flush) diag-ctx=[pid=1234]")

    let encoded = encodeCanonical(@[realRead, killLoss])
    writeFile(rmdfPath, cast[string](encoded))

    # The engine consumes the RMDF via collectEvidence -> the same
    # foldMonitorDepFileEvidence proc. Verify the return code matches
    # the classifier's mapping and the good read survived.
    var evidence: PathSetEvidence
    var seen: EvidenceSeenSets
    let status = foldMonitorDepFileEvidence(rmdfPath, "", evidence, seen)
    check status == mesKnownScopeLoss
    # The trustworthy file-read record must still be in the path set.
    var found = false
    for r in evidence.monitorReads:
      if r.endsWith("input.h"):
        found = true
    check found

  test "unmonitored subtree yields Level 2":
    ## An RMDF with only a Level-2 loss and no real reads must
    ## still return mesUnknownScopeLoss (Level 2). Path-set is empty
    ## because the fixture doesn't add any file records.
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

  test "complete RMDF yields Level 0":
    ## No loss records -> mesComplete. Baseline: the engine must not
    ## treat a healthy RMDF as anything other than complete.
    resetTmp()
    let rmdfPath = TmpDir / "complete.rdep"

    let read1 = MonitorRecord(kind: mrFileRead, observationKind: moFileRead,
      osPid: 1, threadId: 1, path: "/a.h", detail: "")
    let read2 = MonitorRecord(kind: mrFileRead, observationKind: moFileRead,
      osPid: 1, threadId: 1, path: "/b.h", detail: "")

    let encoded = encodeCanonical(@[read1, read2])
    writeFile(rmdfPath, cast[string](encoded))

    var evidence: PathSetEvidence
    var seen: EvidenceSeenSets
    let status = foldMonitorDepFileEvidence(rmdfPath, "", evidence, seen)
    check status == mesComplete
    check evidence.monitorReads.len == 2

  test "worst-status wins across mixed loss records":
    ## An RMDF with BOTH kill-before-flush (Level 1) AND
    ## unmonitored-subtree (Level 2) records must return the WORSE of
    ## the two — mesUnknownScopeLoss (Level 2) — so the caller's
    ## downstream logic uses the more conservative handling.
    resetTmp()
    let rmdfPath = TmpDir / "mixed-loss.rdep"

    let killLoss = MonitorRecord(kind: mrEventLoss,
      observationKind: moEventLoss,
      osPid: 100, threadId: 100,
      detail: "process killed with an un-flushed read batch (kill-before-flush)")
    let subtreeLoss = MonitorRecord(kind: mrEventLoss,
      observationKind: moEventLoss,
      osPid: 0, threadId: 0,
      detail: "unmonitored subtree/peer (SETEXEC into hardened image)")

    let encoded = encodeCanonical(@[killLoss, subtreeLoss])
    writeFile(rmdfPath, cast[string](encoded))

    var evidence: PathSetEvidence
    var seen: EvidenceSeenSets
    let status = foldMonitorDepFileEvidence(rmdfPath, "", evidence, seen)
    check status == mesUnknownScopeLoss

  test "benign raw-syscall loss alone yields Level 0 and keeps the path set":
    ## The `t_zero_output_edge_is_cacheable` execute edge's real RMDF
    ## contains 13 `libc raw syscall unsupported nr=436` records and
    ## nothing else. Before the benign-syscall allowlist those records
    ## folded to Level 2 and the edge never published a cache record, so
    ## it re-executed on every build forever. Folding them must now yield
    ## Level 0 with the recorded reads intact.
    resetTmp()
    let rmdfPath = TmpDir / "benign-syscall.rdep"

    let read1 = MonitorRecord(kind: mrFileRead, observationKind: moFileRead,
      osPid: 1, threadId: 1, path: "/a.h", detail: "")
    let closeRange = MonitorRecord(kind: mrEventLoss,
      observationKind: moEventLoss,
      osPid: 1, threadId: 1,
      detail: "libc raw syscall unsupported nr=436")
    let getPid = MonitorRecord(kind: mrEventLoss,
      observationKind: moEventLoss,
      osPid: 1, threadId: 1,
      detail: "libc raw syscall unsupported nr=39")

    let encoded = encodeCanonical(@[read1, closeRange, getPid])
    writeFile(rmdfPath, cast[string](encoded))

    var evidence: PathSetEvidence
    var seen: EvidenceSeenSets
    let status = foldMonitorDepFileEvidence(rmdfPath, "", evidence, seen)
    when defined(linux) and defined(amd64):
      check status == mesComplete
    check evidence.monitorReads.len == 1

  test "benign raw syscall does not rescue an RMDF that also lost a subtree":
    ## THE NEGATIVE CONTROL, at the fold level.
    ##
    ## `t_monitor_fault_fails_the_action_not_the_daemon`'s execute edge
    ## carries BOTH 3 benign `nr=436` records AND 2 genuine
    ## unmonitored-subtree records. The subtree loss is a real Level 2
    ## blind spot and must keep the whole session fail-closed: the
    ## benign-syscall allowlist must not soften it.
    ##
    ## This is the gate that `worseMonitorStatus` provides inside the
    ## fold. The classifier-level suite cannot fail if that fold rule is
    ## inverted (verified by mutation); this test can.
    resetTmp()
    let rmdfPath = TmpDir / "benign-plus-subtree.rdep"

    let closeRange = MonitorRecord(kind: mrEventLoss,
      observationKind: moEventLoss,
      osPid: 1, threadId: 1,
      detail: "libc raw syscall unsupported nr=436")
    let subtreeLoss = MonitorRecord(kind: mrEventLoss,
      observationKind: moEventLoss,
      osPid: 0, threadId: 0,
      detail: "unmonitored subtree/peer (un-injectable spawn child, " &
        "SETEXEC into a hardened image, or IPC connect to an out-of-tree " &
        "breakaway daemon)")

    # Both record orders, so the result cannot depend on which record the
    # fold happens to see last.
    for records in [@[closeRange, subtreeLoss], @[subtreeLoss, closeRange]]:
      let encoded = encodeCanonical(records)
      writeFile(rmdfPath, cast[string](encoded))
      var evidence: PathSetEvidence
      var seen: EvidenceSeenSets
      check foldMonitorDepFileEvidence(rmdfPath, "", evidence, seen) ==
        mesUnknownScopeLoss

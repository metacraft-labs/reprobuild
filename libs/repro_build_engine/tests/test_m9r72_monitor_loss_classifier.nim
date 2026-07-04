## M9.R.72.3 — spec-graded monitor-loss classifier regression test.
##
## Verifies that ``classifyEventLossDetail`` maps io-mon's eventLoss
## ``detail`` strings to the correct ``MonitorEvidenceStatus`` per the
## ladder specified in Failure-Semantics.md §"Monitoring Failures":
##
##   Level 0 (mesComplete):        no loss.
##   Level 1 (mesKnownScopeLoss):  known-scope loss (e.g. subprocess
##                                 kill-before-flush with pid attribution).
##   Level 2 (mesUnknownScopeLoss): unknown-scope loss (unmonitored
##                                 subtree/peer, ambiguous fragment,
##                                 duplicate identity token, external
##                                 content channel, breakaway report).
##   Level 3 (mesMonitorUnavailable): monitor entirely unavailable —
##                                 handled by ``collectEvidence`` for the
##                                 empty-RMDF-path case, not by the
##                                 classifier itself.
##
## The load-bearing behaviour is that ``mesKnownScopeLoss`` and
## ``mesUnknownScopeLoss`` are LESS SEVERE than ``mesMonitorUnavailable``,
## so cacheable actions receive a session cache-skip (successful
## action, no cache publish) instead of a hard fail. See
## ``recipes/reproos-image/run-evidence/m9r72/m9r72_phaseB_gap_enumeration.txt``
## Gap I for the class-of-issue this closes (M9.R.60.D / M9.R.68 / M9.R.70
## symptom: exit=0 flipped to asFailed).

import std/unittest

import repro_build_engine

suite "M9.R.72.3 monitor-loss classifier":

  test "kill-before-flush maps to Level 1 (known scope)":
    # io-mon writer.nim:2205 / :2224 emit this exact prefix. A subprocess
    # died before flushing its per-thread read-batch tail; the io-mon
    # writer knows which pid/tid it lost, and every OTHER RMDF record is
    # trustworthy. Spec says invalidate the affected path set (Level 1) —
    # currently implemented as session cache-skip until Gap II ships the
    # per-class narrow invalidation.
    check classifyEventLossDetail(
      "process killed with an un-flushed read batch (kill-before-flush)") ==
      mesKnownScopeLoss
    check classifyEventLossDetail(
      "process killed with an un-flushed read batch (kill-before-flush) " &
      "diag-ctx=[pid=1234 tid=5678]") == mesKnownScopeLoss

  test "unmonitored subtree/peer maps to Level 2 (unknown scope)":
    # io-mon writer.nim:2266. A spawn/exec subtree ran under NO monitoring
    # OR the client talked to an out-of-tree breakaway daemon. Content
    # from that peer is invisible. Spec says disable cache hits for the
    # session (Level 2).
    check classifyEventLossDetail(
      "unmonitored subtree/peer (un-injectable spawn child, SETEXEC into " &
      "a hardened image, or IPC connect to an out-of-tree breakaway daemon)") ==
      mesUnknownScopeLoss

  test "ambiguous unstamped fragment record maps to Level 2":
    # io-mon writer.nim:2062. Two runs shared a pid slot and we can't
    # attribute a record to either — unknown scope.
    check classifyEventLossDetail(
      "ambiguous unstamped fragment record for reused pid in run abc123") ==
      mesUnknownScopeLoss

  test "duplicate identity token maps to Level 2":
    # io-mon writer.nim:2034 / :2068. Record-ordering integrity is
    # compromised — unknown scope.
    check classifyEventLossDetail("duplicate identity token in fragment record") ==
      mesUnknownScopeLoss
    check classifyEventLossDetail(
      "duplicate identity token in fragment record for run xyz789") ==
      mesUnknownScopeLoss

  test "external content channel maps to Level 2":
    # io-mon writer.nim:2280 (ROUND-3 S1). POSIX shm object not created
    # in-tree or a FIFO with no in-tree writer — the producer is outside
    # the monitored tree.
    check classifyEventLossDetail(
      "external content channel (shm/fifo with out-of-tree producer)") ==
      mesUnknownScopeLoss

  test "breakaway-report daemon maps to Level 2":
    # io-mon writer.nim breakaway compensation path — cooperating daemon
    # emitted a report but authenticate failed / partial coverage.
    check classifyEventLossDetail(
      "breakaway-report unauthenticated daemon") == mesUnknownScopeLoss

  test "unknown detail fails closed to Level 2 (unknown scope)":
    # Per Failure-Semantics.md R3 (Core Invariants): ambiguous correctness
    # failures MUST fail closed. An unrecognized detail is NOT treated as
    # Level 0 (complete) — that would be a soundness hole. It's mapped
    # to mesUnknownScopeLoss so the session cache-skip applies and a
    # future rebuild will re-execute rather than trust the incomplete
    # evidence.
    check classifyEventLossDetail("some future loss reason we don't recognize") ==
      mesUnknownScopeLoss
    check classifyEventLossDetail("") == mesUnknownScopeLoss

  test "status ordering (worseMonitorStatus semantics)":
    # The `worseMonitorStatus` helper picks the more severe status. The
    # ordering is mesComplete < mesKnownScopeLoss < mesUnknownScopeLoss <
    # mesMonitorUnavailable. The classifier itself never emits
    # mesComplete or mesMonitorUnavailable, but the caller's fold-over
    # loop uses the ordering to keep the worst observed status across
    # the whole RMDF.
    check ord(mesComplete) < ord(mesKnownScopeLoss)
    check ord(mesKnownScopeLoss) < ord(mesUnknownScopeLoss)
    check ord(mesUnknownScopeLoss) < ord(mesMonitorUnavailable)

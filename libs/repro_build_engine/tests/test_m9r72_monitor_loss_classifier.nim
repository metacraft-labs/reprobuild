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
##                                 empty-iomon-path case, not by the
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
    # writer knows which pid/tid it lost, and every OTHER iomon record is
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

  test "benign raw syscall numbers map to Level 0 (complete)":
    # io-mon linux_preload.nim `recordRawSyscallClassification`. The shim saw
    # a raw syscall it does not model and emitted the number. For the
    # individually-justified allowlist in `benignRawSyscallLoss` the number
    # alone proves the call names no path and moves no content, so the record
    # represents no lost filesystem information.
    when defined(linux) and defined(amd64):
      # nr=436 close_range, nr=39 getpid on x86_64 — the two numbers actually
      # observed in this repo's own iomon depfiles.
      check classifyEventLossDetail(
        "libc raw syscall unsupported nr=436") == mesComplete
      check classifyEventLossDetail(
        "libc raw syscall unsupported nr=39") == mesComplete
      # The inline-trap route emits the same class under a different source
      # name; it must classify identically.
      check classifyEventLossDetail(
        "inline raw syscall unsupported nr=436") == mesComplete
      check classifyEventLossDetail(
        "inline raw syscall unsupported nr=39") == mesComplete
    elif defined(linux) and defined(arm64):
      check classifyEventLossDetail(
        "libc raw syscall unsupported nr=436") == mesComplete
      check classifyEventLossDetail(
        "libc raw syscall unsupported nr=172") == mesComplete

  test "the detail shape a REAL iomon carries classifies as Level 0":
    # THE REGRESSION THIS SUITE ORIGINALLY MISSED.
    #
    # Every record the Linux shim emits goes through `stampRunId`
    # (io-mon `linux_preload.nim`), which appends a whitespace-separated
    # `run=<id>` token to `detail`. The strings below are copied verbatim
    # out of
    #   .repro/build/repro/build-engine-cache/monitor-depfiles/
    #     reprobuild.test_execute.t_zero_output_edge_is_cacheable.iomon
    # produced by a real `repro build '.#test#t_zero_output_edge_is_cacheable'`
    # on this host. The first version of `benignRawSyscallLoss` required the
    # remainder after `nr=` to be a bare decimal, so it matched NONE of them:
    # every synthetic case above passed while the edge this class was written
    # to rescue kept re-executing on every build.
    #
    # A synthetic detail string is not evidence about a real iomon. Keep at
    # least one case here that is a byte-for-byte capture.
    when defined(linux) and defined(amd64):
      check classifyEventLossDetail(
        "libc raw syscall unsupported nr=436 run=1787695082.5534084") ==
        mesComplete
      check classifyEventLossDetail(
        "libc raw syscall unsupported nr=39 run=1787695082.5534084") ==
        mesComplete
      check classifyEventLossDetail(
        "inline raw syscall unsupported nr=436 run=1787695082.5534084") ==
        mesComplete
      # The run stamp must not launder a number that is NOT on the allowlist.
      check classifyEventLossDetail(
        "libc raw syscall unsupported nr=257 run=1787695082.5534084") ==
        mesUnknownScopeLoss

  test "unrecognised trailing tokens fail closed":
    # The trailing-token list is an allowlist for the same reason the number
    # table is: a token this classifier has not reasoned about could carry
    # meaning. A future io-mon stamp landing here costs cache, not soundness.
    check classifyEventLossDetail(
      "libc raw syscall unsupported nr=436 run=17.5 diag-ctx=[phase=init]") ==
      mesUnknownScopeLoss
    check classifyEventLossDetail(
      "libc raw syscall unsupported nr=436 nr=257 run=17.5") ==
      mesUnknownScopeLoss
    # A valueless stamp is not a shape the stamper produces.
    check classifyEventLossDetail(
      "libc raw syscall unsupported nr=436 run=") == mesUnknownScopeLoss

  test "raw syscall numbers outside the allowlist still fail closed":
    # The allowlist is an allowlist, not an inversion of the default. Every
    # number that has not been individually justified stays Level 2.
    check classifyEventLossDetail(
      "libc raw syscall unsupported nr=257") == mesUnknownScopeLoss   # openat
    check classifyEventLossDetail(
      "libc raw syscall unsupported nr=0") == mesUnknownScopeLoss     # read
    check classifyEventLossDetail(
      "libc raw syscall unsupported nr=425") == mesUnknownScopeLoss   # io_uring_setup
    check classifyEventLossDetail(
      "libc raw syscall unsupported nr=426") == mesUnknownScopeLoss   # io_uring_enter
    check classifyEventLossDetail(
      "inline raw syscall unsupported nr=257") == mesUnknownScopeLoss
    when defined(linux) and defined(amd64):
      # On the asm-generic table (arm64/riscv64) nr=39 is umount2 and nr=172
      # is getpid; on x86_64 it is the other way round. The allowlist is
      # selected by the compile-time architecture precisely so a number that
      # is benign on one table is not waved through on the other. On x86_64
      # nr=172 is `iopl`, which is NOT justified here.
      check classifyEventLossDetail(
        "libc raw syscall unsupported nr=172") == mesUnknownScopeLoss

  test "malformed raw syscall detail fails closed":
    # Anything other than a bare decimal after the prefix is a detail shape
    # this classifier has not reasoned about.
    check classifyEventLossDetail(
      "libc raw syscall unsupported nr=") == mesUnknownScopeLoss
    check classifyEventLossDetail(
      "libc raw syscall unsupported nr=436 extra") == mesUnknownScopeLoss
    check classifyEventLossDetail(
      "libc raw syscall unsupported nr=0x1b4") == mesUnknownScopeLoss
    check classifyEventLossDetail(
      "libc raw syscall unsupported nr=-436") == mesUnknownScopeLoss
    # `parseInt` accepts a leading sign, so the digit-class guard is what
    # keeps "+436" out of the allowlist. Removing that guard makes this line
    # fail.
    check classifyEventLossDetail(
      "libc raw syscall unsupported nr=+436") == mesUnknownScopeLoss
    # Out of range for `int` — the ValueError handler is what keeps this from
    # escaping as an unhandled exception.
    check classifyEventLossDetail(
      "libc raw syscall unsupported nr=99999999999999999999999") ==
      mesUnknownScopeLoss
    # The prefix itself is part of the match: a detail that is not one of the
    # two io-mon source names is not this class at all.
    check classifyEventLossDetail(
      "raw syscall unsupported nr=436") == mesUnknownScopeLoss

  test "benign raw syscalls never downgrade a co-occurring Level 2 loss":
    # The benign prefixes are disjoint from every Level 1/2 prefix, so a
    # subtree detail cannot be swallowed by the Level 0 arm no matter where
    # that arm sits in the chain.
    #
    # This test only pins the CLASSIFIER half of the property. The half that
    # actually keeps `t_monitor_fault_fails_the_action_not_the_daemon`
    # fail-closed is the `worseMonitorStatus` fold in
    # `foldMonitorDepFileEvidence`, which this suite cannot reach: inverting
    # that fold leaves every check here passing (verified by mutation). The
    # fold-level gate lives in `test_m9r72_phaseD_end_to_end.nim`, "benign raw
    # syscall does not rescue an iomon that also lost a subtree".
    let subtree = classifyEventLossDetail(
      "unmonitored subtree/peer (un-injectable spawn child, SETEXEC into " &
      "a hardened image, or IPC connect to an out-of-tree breakaway daemon)")
    let benign = classifyEventLossDetail("libc raw syscall unsupported nr=436")
    check subtree == mesUnknownScopeLoss
    check ord(benign) < ord(subtree)

  test "status ordering (worseMonitorStatus semantics)":
    # The `worseMonitorStatus` helper picks the more severe status. The
    # ordering is mesComplete < mesKnownScopeLoss < mesUnknownScopeLoss <
    # mesMonitorUnavailable. The classifier emits mesComplete only for the
    # justified benign raw-syscall allowlist and never emits
    # mesMonitorUnavailable; the caller's fold-over loop uses the ordering to
    # keep the worst observed status across the whole iomon.
    check ord(mesComplete) < ord(mesKnownScopeLoss)
    check ord(mesKnownScopeLoss) < ord(mesUnknownScopeLoss)
    check ord(mesUnknownScopeLoss) < ord(mesMonitorUnavailable)

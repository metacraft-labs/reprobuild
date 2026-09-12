## A session record's writer must be recognisable for as long as it runs, and
## unrecognisable answers must read as LIVE.
##
## WHAT THIS DEFENDS. A `repro build` that is killed leaves its record
## `running` forever. Measured on a developer machine: 19 such records, every
## one with a dead writer pid, some three weeks old. `restartCandidateReady`
## counted them as live work, so the dev self-restart was permanently
## deferred -- and said so 949,394 times, 93% of an 82 MB log.
##
## THE FAILURE DIRECTION IS ASYMMETRIC, and it is the whole reason this is
## identity rather than a pid check. Declaring a LIVE writer dead would let
## two builds believe they own one session; a record that lingers only defers
## a restart. So every case below that cannot establish identity asserts
## `wlUnknown`, never `wlDead`, and the reclamation treats unknown as live.
##
## Two approximations are tested as REJECTED rather than merely unused:
## "the pid is not alive" is defeated by pid reuse, and "the record predates
## this daemon" misclassifies a long build that spans a daemon restart. The
## reused-pid case is the one that proves the start stamp is load-bearing.
##
## MOCK POLICY: no mocks, and none may be added. Liveness is a question about
## real processes, so the cases interrogate this process, a real spawned child
## before and after it exits, and pids that cannot exist. A fake process table
## would decide by fiat the one thing under test.

import std/[options, os, osproc, strutils, unittest]

import repro_daemon_core/writer_identity

suite "writer identity recognises a live writer and only a dead one":
  test "this process is live under its own recorded identity":
    let me = currentWriterIdentity()
    let encoded = encodeWriterIdentity(me)
    checkpoint("encoded=" & encoded)
    check encoded.len > 0
    check writerLiveness(encoded) == wlLive

  test "the encoding round-trips":
    let me = currentWriterIdentity()
    let decoded = decodeWriterIdentity(encodeWriterIdentity(me))
    check decoded.isSome
    check decoded.get().bootId == me.bootId
    check decoded.get().pid == me.pid
    check decoded.get().startStamp == me.startStamp

  test "a pid that cannot exist is dead":
    var absent = currentWriterIdentity()
    absent.pid = 999_999
    check writerLiveness(encodeWriterIdentity(absent)) == wlDead

  test "a reused pid is dead, which a pid-only check would call live":
    # THE CASE THAT MAKES THE START STAMP LOAD-BEARING. The pid is this live
    # process, so "is the pid alive" answers yes; only the start stamp can
    # say it is not the process that wrote the record.
    var reused = currentWriterIdentity()
    reused.startStamp = "1.1"
    check reused.pid == currentWriterIdentity().pid
    checkpoint("same live pid, different start stamp")
    check writerLiveness(encodeWriterIdentity(reused)) == wlDead

  test "a record from another boot is dead without probing any process":
    # After a reboot every pid is recycled from 1, so a pid-only rule is at
    # its worst here. The boot id answers before any process is consulted.
    var otherBoot = currentWriterIdentity()
    otherBoot.bootId = otherBoot.bootId - 1
    check writerLiveness(encodeWriterIdentity(otherBoot)) == wlDead

  test "a real child is live while it runs and dead once it exits":
    # End to end against an actual process lifetime rather than a synthesised
    # identity: the same encoded value must change its answer when, and only
    # when, the process goes away.
    let child = startProcess("/bin/sh", args = @["-c", "sleep 30"],
      options = {})
    let childPid = child.processID
    let stamp = processStartStamp(childPid)
    check stamp.len > 0
    let encoded = encodeWriterIdentity(WriterIdentity(
      bootId: currentWriterIdentity().bootId, pid: childPid,
      startStamp: stamp))
    check writerLiveness(encoded) == wlLive
    child.terminate()
    discard child.waitForExit()
    child.close()
    # Give the kernel a moment to reap it so the pid stops resolving.
    for _ in 0 ..< 200:
      if processStartStamp(childPid).len == 0: break
      sleep(10)
    checkpoint("after exit, stamp=" & processStartStamp(childPid))
    check writerLiveness(encoded) == wlDead

  test "every unestablishable identity reads LIVE, never dead":
    # The asymmetry, asserted directly. An empty, partial, or unparsable
    # value must not be reclaimable.
    for encoded in ["", "not-a-triple", "1:2", "1:2:", ":::",
                    "abc:2:3.4", "1:xyz:3.4"]:
      checkpoint("value=" & encoded)
      check writerLiveness(encoded) == wlUnknown
      check decodeWriterIdentity(encoded).isNone

  test "an identity with no start stamp does not encode at all":
    # A partial triple must not be storable, because a stored partial would
    # later read as authoritative.
    var unknown = currentWriterIdentity()
    unknown.startStamp = ""
    check encodeWriterIdentity(unknown) == ""
    check writerLiveness(encodeWriterIdentity(unknown)) == wlUnknown

  test "the Linux /proc/<pid>/stat field-22 path":
    when defined(linux):
      # Field 22 is counted from the LAST ')' because `comm` is
      # parenthesised and may contain spaces and parentheses itself.
      let stamp = processStartStamp(int(getCurrentProcessId()))
      checkpoint("self starttime ticks=" & stamp)
      check stamp.len > 0
      check stamp.allCharsInSet({'0' .. '9'})
      # A second reading of the same process must agree: starttime is fixed
      # for the life of the process, which is what makes it an identity.
      check stamp == processStartStamp(int(getCurrentProcessId()))
    else:
      skip()
      # SKIPPED WITH A REASON, not omitted: the Linux reader was written and
      # reviewed on macOS and has never been executed on Linux. A Linux run
      # of this suite executes the case above and reports it; on any other
      # platform this line records that it remains unverified rather than
      # letting the suite pass vacuously.

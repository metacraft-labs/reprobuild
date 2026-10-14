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
## MOCK POLICY: the process table is never mocked. macOS error cases use a
## native syscall interposer to inject EPERM for one real process probe (or
## boot probe), since ordinary kernel permissions do not reliably deny these
## sysctls. Every other syscall and the recorded identity remain real.
## This fault injection exercises the error boundary rather than inventing
## a process lifetime. Liveness is a question about
## real processes, so the cases interrogate this process, a real spawned child
## before and after it exits, and pids that cannot exist. A fake process table
## would decide by fiat the one thing under test.

import std/[options, os, osproc, strutils, streams, json, unittest]

import repro_daemon_core/writer_identity
import shm_gset

when defined(macosx):
  {.emit: """
#include <sys/types.h>
#include <sys/sysctl.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
int sysctl(int *mib, unsigned n, void *p, size_t *len, void *np, size_t nl) {
  if (getenv("DENIED_PID") && n == 4 && mib[0] == CTL_KERN && mib[1] == KERN_PROC &&
      mib[2] == KERN_PROC_PID && mib[3] == atoi(getenv("DENIED_PID"))) {
    fprintf(stderr, "injected EPERM\n"); errno = EPERM; return -1;
  }
  int (*real)(int *, unsigned, void *, size_t *, void *, size_t) = dlsym(RTLD_NEXT, "sysctl");
  return real(mib, n, p, len, np, nl);
}
int sysctlbyname(const char *name, void *p, size_t *len, void *np, size_t nl) {
  if (getenv("DENIED_BOOT") && strcmp(name, "kern.boottime") == 0) {
    fprintf(stderr, "injected EPERM\n"); errno = EPERM; return -1;
  }
  int (*real)(const char *, void *, size_t *, void *, size_t) = dlsym(RTLD_NEXT, "sysctlbyname");
  return real(name, p, len, np, nl);
}
""".}
  if paramCount() == 2 and paramStr(1) == "--probe-writer":
    echo writerLiveness(paramStr(2))
    quit(0)

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

  test "noncanonical self stamps cannot prove pid reuse":
    let me = currentWriterIdentity()
    let encoded = encodeWriterIdentity(me)
    require encoded.len > 0
    require writerLiveness(encoded) == wlLive
    var stamps = @["0" & me.startStamp, "+" & me.startStamp,
      " " & me.startStamp, me.startStamp & " ", "not-a-start-time"]
    when defined(macosx):
      let parts = me.startStamp.split('.')
      require parts.len == 2
      stamps.add(parts[0] & ".0" & parts[1])
      stamps.add(parts[0] & ".+" & parts[1])
      stamps.add(@["0.0", "-1.0", "1.-1", "1.1000000",
        "9223372036854775808.0", "1.9223372036854775808", "1.2.3", "1"])
    elif defined(linux):
      stamps.add(@["-1", "1.1", "18446744073709551616"])
    for stamp in stamps:
      var altered = me
      altered.startStamp = stamp
      let persisted = encodeWriterIdentity(altered)
      checkpoint("self pid=" & $me.pid & " persisted stamp=" & stamp)
      check persisted.len > 0
      check decodeWriterIdentity(persisted).isNone
      check writerLiveness(persisted) == wlUnknown
      # Invalid identity remains uncertain even if another field would
      # otherwise establish death; it never reaches a liveness comparison.
      altered.bootId = altered.bootId - 1
      check writerLiveness(encodeWriterIdentity(altered)) == wlUnknown

  test "canonical native range boundaries remain valid identities":
    var identity = currentWriterIdentity()
    when defined(macosx):
      let stamps = ["1.0", "1.999999", "9223372036854775807.0",
        "9223372036854775807.999999"]
    elif defined(linux):
      let stamps = ["0", "1", "18446744073709551615"]
    else:
      let stamps: array[0, string] = []
    for stamp in stamps:
      identity.startStamp = stamp
      let decoded = decodeWriterIdentity(encodeWriterIdentity(identity))
      checkpoint("canonical boundary=" & stamp)
      require decoded.isSome
      check decoded.get().startStamp == stamp

  test "a pid that cannot exist is dead":
    var absent = currentWriterIdentity()
    absent.pid = 999_999
    check writerLiveness(encodeWriterIdentity(absent)) == wlDead

  test "a reused pid is dead, which a pid-only check would call live":
    # THE CASE THAT MAKES THE START STAMP LOAD-BEARING. The pid is this live
    # process, so "is the pid alive" answers yes; only the start stamp can
    # say it is not the process that wrote the record.
    var reused = currentWriterIdentity()
    reused.startStamp = when defined(macosx): "1.1" else: "1"
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

  test "a live identity survives advancing wall clock seconds":
    let me = currentWriterIdentity()
    let boot = bootId()
    let encoded = encodeWriterIdentity(me)
    require encoded.len > 0
    check boot == me.bootId
    sleep(2200)
    check bootId() == boot
    check writerLiveness(encoded) == wlLive

  when defined(macosx):
    test "a denied process or boot probe is unknown and never dead":
      let identity = currentWriterIdentity()
      let encoded = encodeWriterIdentity(identity)
      require encoded.len > 0
      # Positive control: the unmodified child can interrogate this live parent.
      let control = execCmdEx(quoteShell(getAppFilename()) &
        " --probe-writer " & quoteShell(encoded))
      check control.exitCode == 0
      check control.output.strip() == "wlLive"
      for denyBoot in [false, true]:
        let oldPid = os.getEnv("DENIED_PID")
        let oldBoot = os.getEnv("DENIED_BOOT")
        putEnv("DENIED_PID", if denyBoot: "0" else: $identity.pid)
        if denyBoot: putEnv("DENIED_BOOT", "1")
        let child = startProcess(getAppFilename(), args = @["--probe-writer", encoded],
          options = {poStdErrToStdOut})
        putEnv("DENIED_PID", oldPid)
        if oldBoot.len == 0: delEnv("DENIED_BOOT")
        else: putEnv("DENIED_BOOT", oldBoot)
        let output = child.outputStream.readAll()
        let status = child.waitForExit()
        child.close()
        checkpoint("denyBoot=" & $denyBoot & " output=" & output)
        check status == 0
        check "injected EPERM" in output
        check output.strip().endsWith("wlUnknown")

  test "packaged boot source pin and CI source pin stay aligned":
    let root = currentSourcePath().parentDir.parentDir.parentDir.parentDir
    let node = parseJson(readFile(root / "flake.lock"))["nodes"]["nim-shm-gset-src"]
    let rev = node["locked"]["rev"].getStr()
    check rev == node["original"]["rev"].getStr()
    check rev != "c646982b354cb5b1fa8734f94b951a660419d75c"
    check ("github:metacraft-labs/nim-shm-gset/" & rev) in readFile(root / "flake.nix")
    check ("nim-shm-gset=" & rev) in readFile(root / ".github" / "sibling-repos")

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
## boot probe), or shift a successful real boot-time response by +/-120 seconds,
## since ordinary kernel permissions and calendar corrections cannot safely be
## triggered by this test. These are narrow fault injections at the native
## sysctls. Every other syscall and the recorded identity remain real.
## This fault injection exercises the error boundary rather than inventing
## a process lifetime. Liveness is a question about
## real processes, so the cases interrogate this process, a real spawned child
## before and after it exits, and pids that cannot exist. A fake process table
## would decide by fiat the one thing under test.

import std/[options, os, osproc, strutils, streams, json, times, unittest]

import repro_daemon_core/writer_identity
import shm_gset

when defined(macosx):
  {.emit: """
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/time.h>
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
  int rc = real(mib, n, p, len, np, nl);
  if (getenv("BOOT_SHIFT_SECONDS") && n == 4 && mib[0] == CTL_KERN &&
      mib[1] == KERN_PROC && mib[2] == KERN_PROC_PID)
    fprintf(stderr, "forwarded process probe %d\n", mib[3]);
  return rc;
}
int sysctlbyname(const char *name, void *p, size_t *len, void *np, size_t nl) {
  if (getenv("DENIED_BOOT") && strcmp(name, "kern.boottime") == 0) {
    fprintf(stderr, "injected EPERM\n"); errno = EPERM; return -1;
  }
  int (*real)(const char *, void *, size_t *, void *, size_t) = dlsym(RTLD_NEXT, "sysctlbyname");
  int rc = real(name, p, len, np, nl);
  if (rc == 0 && getenv("BOOT_SHIFT_SECONDS") && strcmp(name, "kern.boottime") == 0 &&
      p && len && *len == sizeof(struct timeval)) {
    struct timeval *tv = p;
    long delta = atol(getenv("BOOT_SHIFT_SECONDS"));
    fprintf(stderr, "injected boot shift %ld seconds\n", delta);
    tv->tv_sec += delta;
  }
  return rc;
}
""".}
  if paramCount() == 2 and paramStr(1) == "--probe-writer":
    echo writerLiveness(paramStr(2))
    quit(0)

  if paramCount() == 2 and paramStr(1) == "--probe-shifted-writer":
    echo "boot=" & $bootId()
    echo writerLiveness(paramStr(2))
    quit(0)

  proc shiftedWriterProbe(encoded: string; shift: int; deniedPid = ""):
      tuple[output: string, exitCode: int] =
    let oldShift = os.getEnv("BOOT_SHIFT_SECONDS")
    let oldPid = os.getEnv("DENIED_PID")
    defer:
      if oldShift.len == 0: delEnv("BOOT_SHIFT_SECONDS")
      else: putEnv("BOOT_SHIFT_SECONDS", oldShift)
      if oldPid.len == 0: delEnv("DENIED_PID")
      else: putEnv("DENIED_PID", oldPid)
    putEnv("BOOT_SHIFT_SECONDS", $shift)
    if deniedPid.len == 0: delEnv("DENIED_PID")
    else: putEnv("DENIED_PID", deniedPid)
    let child = startProcess(getAppFilename(),
      args = @["--probe-shifted-writer", encoded], options = {poStdErrToStdOut})
    result.output = child.outputStream.readAll()
    result.exitCode = child.waitForExit()
    child.close()

suite "writer identity recognises a live writer and only a dead one":
  test "this process is live under its own recorded identity":
    let me = currentWriterIdentity()
    let encoded = encodeWriterIdentity(me)
    checkpoint("encoded=" & encoded)
    check encoded.len > 0
    check writerLiveness(encoded) == wlLive

  test "a live legacy writer survives a boot-source migration":
    let me = currentWriterIdentity()
    require processStartStamp(me.pid) == me.startStamp
    # The old packaged Darwin source recorded wall-clock seconds. This raw
    # persisted triple deliberately bypasses the current encoder.
    let legacyBoot = uint64(getTime().toUnix()) or 1'u64
    require legacyBoot != me.bootId
    let legacy = $legacyBoot & ":" & $me.pid & ":" & me.startStamp
    checkpoint("legacy=" & legacy & " current boot=" & $me.bootId)
    check writerLiveness(legacy) == wlLive

  test "legacy process interrogation decides live absent and reused writers":
    let me = currentWriterIdentity()
    for boot in [me.bootId, me.bootId - 1]:
      let prefix = $boot & ":"
      check writerLiveness(prefix & $me.pid & ":" & me.startStamp) == wlLive
      check writerLiveness(prefix & "999999:" & me.startStamp) == wlDead
      let reused = when defined(macosx): "1.1" else: "1"
      require reused != me.startStamp
      check writerLiveness(prefix & $me.pid & ":" & reused) == wlDead

  test "unknown or malformed provenance cannot establish death":
    let me = currentWriterIdentity()
    let encoded = encodeWriterIdentity(me)
    require encoded.startsWith("v1:")
    let fields = encoded.split(':')
    require fields.len == 5
    for prefix in ["v2:" & fields[1], "v1:unknown", "v1:", "v0:" & fields[1]]:
      let unsupported = prefix & ":1:999999:" & me.startStamp
      checkpoint(unsupported)
      check decodeWriterIdentity(unsupported).isNone
      check writerLiveness(unsupported) == wlUnknown
    for malformed in [encoded & ":extra", "v1:" & fields[1] & ":1:999999",
        "v1:" & fields[1] & ":1:999999:0" & me.startStamp]:
      check decodeWriterIdentity(malformed).isNone
      check writerLiveness(malformed) == wlUnknown

  test "the encoding round-trips":
    let me = currentWriterIdentity()
    let decoded = decodeWriterIdentity(encodeWriterIdentity(me))
    check decoded.isSome
    check decoded.get().bootSource == me.bootSource
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

  test "native boot mismatches use the platform's evidence of death":
    # Linux's boot UUID proves a different boot. Darwin's calendar-based
    # boot stamp can change while this process remains alive, so the native
    # process start stamp must settle its liveness instead.
    var otherBoot = currentWriterIdentity()
    otherBoot.bootId = otherBoot.bootId - 1
    when defined(macosx):
      check writerLiveness(encodeWriterIdentity(otherBoot)) == wlLive
    else:
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
    let me = currentWriterIdentity()
    let encoded = encodeWriterIdentity(WriterIdentity(
      bootSource: me.bootSource, bootId: me.bootId, pid: childPid,
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
    test "calendar corrections in either direction preserve a real live writer":
      let identity = currentWriterIdentity()
      let encoded = encodeWriterIdentity(identity)
      require encoded.len > 0
      # The child must recognise its actual live parent without injection first.
      let control = execCmdEx(quoteShell(getAppFilename()) &
        " --probe-writer " & quoteShell(encoded))
      require control.exitCode == 0
      require control.output.strip() == "wlLive"
      for shift in [-120, 120]:
        let child = shiftedWriterProbe(encoded, shift)
        checkpoint("shift=" & $shift & " output=" & child.output)
        require child.exitCode == 0
        require ("injected boot shift " & $shift & " seconds") in child.output
        let shiftedBoot = uint64(int64(identity.bootId) + int64(shift) * 1_000_000) or 1'u64
        require ("boot=" & $shiftedBoot) in child.output
        check ("forwarded process probe " & $identity.pid) in child.output
        check child.output.strip().endsWith("wlLive")

    test "calendar correction still requires evidence of absence or pid reuse":
      let identity = currentWriterIdentity()
      for shift in [-120, 120]:
        var absent = identity
        absent.pid = 999_999
        var reused = identity
        reused.startStamp = "1.1"
        require reused.startStamp != identity.startStamp
        for entry in [(identity, $identity.pid, "wlUnknown"),
            (absent, "", "wlDead"), (reused, "", "wlDead")]:
          let child = shiftedWriterProbe(encodeWriterIdentity(entry[0]), shift, entry[1])
          checkpoint("shift=" & $shift & " expected=" & entry[2] & " output=" & child.output)
          require child.exitCode == 0
          require ("injected boot shift " & $shift & " seconds") in child.output
          let shiftedBoot = uint64(int64(identity.bootId) + int64(shift) * 1_000_000) or 1'u64
          require ("boot=" & $shiftedBoot) in child.output
          if entry[1].len > 0:
            check "injected EPERM" in child.output
          else:
            check ("forwarded process probe " & $entry[0].pid) in child.output
          check child.output.strip().endsWith(entry[2])

  when defined(macosx):
    test "a denied process is unknown while a denied Darwin boot probe permits liveness":
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
        if denyBoot:
          # The calendar boot stamp is not evidence of death or a prerequisite
          # for successful native process interrogation.
          check output.strip() == "wlLive"
        else:
          check "injected EPERM" in output
          check output.strip().endsWith("wlUnknown")

  when defined(macosx):
    test "legacy writers survive denied boot probes and retain denied process probes":
      let me = currentWriterIdentity()
      let legacy = $(me.bootId - 1) & ":" & $me.pid & ":" & me.startStamp
      for denyBoot in [false, true]:
        let oldPid = os.getEnv("DENIED_PID")
        let oldBoot = os.getEnv("DENIED_BOOT")
        if denyBoot:
          delEnv("DENIED_PID")
          putEnv("DENIED_BOOT", "1")
        else:
          putEnv("DENIED_PID", $me.pid)
          delEnv("DENIED_BOOT")
        let child = startProcess(getAppFilename(), args = @["--probe-writer", legacy],
          options = {poStdErrToStdOut})
        if oldPid.len == 0: delEnv("DENIED_PID")
        else: putEnv("DENIED_PID", oldPid)
        if oldBoot.len == 0: delEnv("DENIED_BOOT")
        else: putEnv("DENIED_BOOT", oldBoot)
        let output = child.outputStream.readAll()
        let status = child.waitForExit()
        child.close()
        checkpoint("denyBoot=" & $denyBoot & " output=" & output)
        check status == 0
        if denyBoot:
          check output.strip() == "wlLive"
        else:
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

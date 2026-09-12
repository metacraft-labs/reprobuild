## Who wrote a session record, and is that writer still running?
##
## A session record left non-terminal by a crashed or killed `repro build` is
## indistinguishable, to everything that reads it, from a build still in
## flight. On the machine this was found on, 19 records sat in `state=running`
## with writers dead for up to three weeks; `restartCandidateReady` counted
## them as live work and the dev self-restart was PERMANENTLY DEFERRED,
## logging about it 949,394 times.
##
## The question "is that writer still running" has to be answered EXACTLY,
## not approximated, and the two obvious approximations both fail:
##
## * **"the pid is not alive"** is defeated by pid reuse. A recycled pid makes
##   a dead writer look live, which leaves the bug in place, and on a busy
##   machine pid reuse is not rare.
## * **"the record predates the current daemon"** misclassifies a long-running
##   build that legitimately spans a daemon restart -- a real and ordinary
##   thing for a large build -- as abandoned.
##
## So the writer records a triple that pins its own identity for as long as it
## exists: the boot it is running under, its pid, and its own start time. A
## recycled pid fails the start-time comparison. A reboot fails the boot id.
##
## THE FAILURE DIRECTION IS ASYMMETRIC AND THE CODE LEANS THE SAFE WAY.
## Declaring a LIVE writer dead is far worse than the reverse: two builds
## would believe they own one session. So every path that cannot establish
## identity exactly -- an unparsable stamp, a platform with no start time, a
## probe that errors -- answers `wlUnknown`, and the caller treats unknown as
## LIVE and never reclaims. A record that lingers costs a deferred restart; a
## record reclaimed out from under its writer corrupts a build.
##
## BOOT IDENTITY COMES FROM `shm_gset`, DELIBERATELY. It is the same notion of
## boot already deciding action-index staleness (`action_index.nim`: "a chain
## whose creator boot id does not match the current boot is STALE"), so this
## introduces no second answer to the question. It does make `shm_gset` a
## direct dependency of this library rather than a transitive one.

import std/[options, strutils]

import shm_gset

when defined(posix):
  import std/posix

type
  WriterIdentity* = object
    ## Enough to recognise one process for as long as it runs. Empty
    ## `startStamp` means "not established"; see `wlUnknown`.
    bootId*: uint64
    pid*: int
    startStamp*: string

  WriterLiveness* = enum
    wlLive        ## the recorded writer is running right now
    wlDead        ## provably not running: same boot, and pid absent or reused
    wlUnknown     ## identity could not be established; callers MUST assume live

const WriterIdentityFieldSep = ':'

when defined(macosx):
  # `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID, pid)` yields `kinfo_proc`, whose
  # `kp_proc.p_starttime` is the process's own start time to microsecond
  # resolution. An absent pid returns success with a ZERO-LENGTH result, which
  # is how "no such process" is told apart from an error.
  #
  # Bound directly because `std/posix` exposes neither `kinfo_proc` nor the
  # KERN_PROC_PID mib. Only the two `timeval` fields are read, through a
  # helper compiled against the real header, so no struct layout is restated
  # here -- restating it is how a binding silently reads the wrong offsets
  # after an SDK bump.
  {.emit: """
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/proc.h>

static int repro_proc_start_time(int pid, long long *sec, long long *usec) {
  struct kinfo_proc kp;
  size_t len = sizeof(kp);
  int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
  if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0) return -1;  /* error */
  if (len == 0) return 1;                                  /* no such process */
  *sec = (long long)kp.kp_proc.p_starttime.tv_sec;
  *usec = (long long)kp.kp_proc.p_starttime.tv_usec;
  return 0;
}
""".}
  proc reproProcStartTime(pid: cint; sec, usec: ptr int64): cint
    {.importc: "repro_proc_start_time", nodecl.}

  proc processStartStamp*(pid: int): string =
    ## "" when the process does not exist or cannot be interrogated.
    var sec, usec: int64
    if reproProcStartTime(cint(pid), addr sec, addr usec) != 0:
      return ""
    $sec & "." & $usec

elif defined(linux):
  proc processStartStamp*(pid: int): string =
    ## Field 22 of `/proc/<pid>/stat` -- `starttime`, in clock ticks since
    ## boot. Only meaningful WITHIN a boot, which is exactly why `bootId` is
    ## part of the identity rather than an extra.
    ##
    ## The field is counted from the CLOSE of the comm field rather than by
    ## splitting the whole line: `comm` is parenthesised and may itself
    ## contain spaces and parentheses, so a naive split puts every later
    ## field at the wrong index. This is the standard hazard of reading this
    ## file and the reason the scan starts at the last ')'.
    ##
    ## NOT VERIFIED ON A LINUX HOST. This was written and reviewed on macOS;
    ## `t_daemon_writer_identity.nim` carries a case for it that `skip()`s
    ## with that reason on other platforms, so a Linux run reports it as
    ## unverified rather than passing vacuously.
    try:
      let raw = readFile("/proc/" & $pid & "/stat")
      let close = raw.rfind(')')
      if close < 0:
        return ""
      # After "(comm)" the next token is `state`, i.e. field 3. `starttime`
      # is field 22, so it is the 20th token after the parenthesis.
      let rest = raw[close + 1 .. ^1].strip().splitWhitespace()
      if rest.len < 20:
        return ""
      rest[19]
    except CatchableError:
      return ""

else:
  proc processStartStamp*(pid: int): string =
    ## No start time on this platform, so identity cannot be established and
    ## every record reads `wlUnknown` -- i.e. live, i.e. never reclaimed.
    ## Losing the reclamation is the safe direction; guessing is not.
    discard pid
    ""

proc currentWriterIdentity*(): WriterIdentity =
  ## The identity of THIS process, to be written into a session record.
  let pid = when defined(posix): int(getpid()) else: 0
  WriterIdentity(bootId: bootId(), pid: pid, startStamp: processStartStamp(pid))

proc encodeWriterIdentity*(identity: WriterIdentity): string =
  ## `<bootId>:<pid>:<startStamp>`; "" when the start stamp is unknown, so an
  ## unestablished identity is stored as absent rather than as a partial
  ## triple that later reads as authoritative.
  if identity.startStamp.len == 0:
    return ""
  $identity.bootId & WriterIdentityFieldSep & $identity.pid &
    WriterIdentityFieldSep & identity.startStamp

proc decodeWriterIdentity*(encoded: string): Option[WriterIdentity] =
  ## `none` for anything that is not a whole triple. A partially parsable
  ## value is NOT repaired into a usable identity: half an identity answers
  ## the liveness question wrongly, and `none` answers it `wlUnknown`.
  if encoded.len == 0:
    return none(WriterIdentity)
  let parts = encoded.split(WriterIdentityFieldSep, maxsplit = 2)
  if parts.len != 3 or parts[2].len == 0:
    return none(WriterIdentity)
  try:
    some(WriterIdentity(bootId: parseBiggestUInt(parts[0]),
      pid: parseInt(parts[1]), startStamp: parts[2]))
  except ValueError:
    none(WriterIdentity)

proc writerLiveness*(encoded: string): WriterLiveness =
  ## Is the writer named by `encoded` still running?
  ##
  ## Every uncertain answer is `wlUnknown`, which callers treat as live. The
  ## only `wlDead` is: same boot, and the pid either has no process or has a
  ## process that started at a different time (i.e. the pid was reused).
  let parsed = decodeWriterIdentity(encoded)
  if parsed.isNone:
    return wlUnknown
  let identity = parsed.get()
  let currentBoot = bootId()
  if identity.bootId != currentBoot:
    # A DIFFERENT BOOT. Nothing recorded before this boot can still be
    # running, so this is the one case that needs no process probe at all --
    # and it is the case a pid-only rule gets wrong most often after a
    # reboot recycles every pid from 1.
    return wlDead
  let liveStamp = processStartStamp(identity.pid)
  if liveStamp.len == 0:
    # No such process, or it could not be interrogated. On a platform with no
    # start time at all this is also the answer for a LIVE process, which is
    # why that platform's `processStartStamp` is documented as making
    # everything `wlUnknown`: there, `decodeWriterIdentity` never yields an
    # identity in the first place, because nothing could encode one.
    return wlDead
  if liveStamp == identity.startStamp:
    wlLive
  else:
    # The pid exists but is not the process that wrote this: it was reused.
    wlDead

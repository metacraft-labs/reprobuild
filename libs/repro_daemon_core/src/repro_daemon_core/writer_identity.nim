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
## recycled pid fails the start-time comparison. Linux's boot UUID also proves
## a reboot; Darwin's calendar-based boot stamp can change within one boot.
##
## THE FAILURE DIRECTION IS ASYMMETRIC AND THE CODE LEANS THE SAFE WAY.
## Declaring a LIVE writer dead is far worse than the reverse: two builds
## would believe they own one session. So every path that cannot establish
## identity exactly -- an unparsable stamp, a platform with no start time, a
## probe that errors -- answers `wlUnknown`, and the caller treats unknown as
## LIVE and never reclaims. A record that lingers costs a deferred restart; a
## record reclaimed out from under its writer corrupts a build.
##
## Boot provenance is part of new identities. Legacy triples used boot sources
## that changed across releases (including a wall-clock fallback on Darwin),
## so their boot values cannot prove death. They require process interrogation.
## Only a recognized version and Linux's native boot UUID permit a boot-only
## shortcut. Darwin always requires process interrogation, independently of
## current boot-probe availability, because calendar corrections adjust
## `kern.boottime` while live writers retain their recorded boot stamps.

import std/[options, strutils]

when defined(posix):
  import std/posix

type
  WriterIdentity* = object
    ## Enough to recognise one process for as long as it runs. Empty
    ## `startStamp` means "not established"; see `wlUnknown`.
    bootSource*: string  ## Empty for an unversioned legacy triple.
    bootId*: uint64
    pid*: int
    startStamp*: string

  ProcessStartStatus* = enum
    pssPresent, pssAbsent, pssUnknown

  ProcessStartProbe* = object
    ## Absence is an authoritative kernel answer, never a failed read.
    status*: ProcessStartStatus
    stamp*: string

  WriterLiveness* = enum
    wlLive        ## the recorded writer is running right now
    wlDead        ## provably gone: comparable boot differs, absent or reused pid
    wlUnknown     ## identity could not be established; callers MUST assume live

const WriterIdentityFieldSep = ':'
const NativeWriterBootSource =
  when defined(macosx): "darwin-kern-boottime-us-or1"
  elif defined(linux): "linux-boot-uuid-fnv1a64-or1"
  else: "unsupported"

proc decodeProcStatStartTime*(raw: string): Option[string] =
  ## Field 22 (`starttime`) of one Linux `/proc/<pid>/stat` record, or none
  ## when the record is incomplete or malformed. Pure, so the record format
  ## is checked on every platform, not only where `/proc` exists.
  ##
  ## Only a record ending in the newline that Linux's `do_task_stat` emits
  ## after its last field is complete. A short read cut inside field 22
  ## leaves a numeric prefix ("809" of "8097736") that otherwise reads as a
  ## different start time, i.e. as false proof of pid reuse. None is an
  ## unknown probe, never evidence of death.
  if not raw.endsWith('\n'): return none(string)
  # comm can contain spaces and parentheses: field 22 is counted from
  # its final closing parenthesis, not from whitespace in the whole line.
  let close = raw.rfind(')')
  if close < 0: return none(string)
  let rest = raw[close + 1 .. ^1].strip().splitWhitespace()
  if rest.len < 20 or rest[19].len == 0 or
      not rest[19].allCharsInSet({'0' .. '9'}):
    return none(string)
  try:
    discard parseBiggestUInt(rest[19])
  except ValueError:
    return none(string)
  some(rest[19])

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
  if (len != sizeof(kp)) return -1;
  *sec = (long long)kp.kp_proc.p_starttime.tv_sec;
  *usec = (long long)kp.kp_proc.p_starttime.tv_usec;
  return 0;
}
""".}
  proc reproProcStartTime(pid: cint; sec, usec: ptr int64): cint
    {.importc: "repro_proc_start_time", nodecl.}

  proc probeProcessStart*(pid: int): ProcessStartProbe =
    if pid <= 0 or pid > int(high(int32)):
      return ProcessStartProbe(status: pssUnknown)
    var sec, usec: int64
    case reproProcStartTime(cint(pid), addr sec, addr usec)
    of 1: return ProcessStartProbe(status: pssAbsent)
    of 0:
      if sec > 0 and usec >= 0 and usec < 1_000_000:
        return ProcessStartProbe(status: pssPresent, stamp: $sec & "." & $usec)
    else: discard
    ProcessStartProbe(status: pssUnknown)

elif defined(linux):
  proc probeProcessStart*(pid: int): ProcessStartProbe =
    if pid <= 0 or pid > int(high(int32)):
      return ProcessStartProbe(status: pssUnknown)
    let path = "/proc/" & $pid & "/stat"
    try:
      let stamp = decodeProcStatStartTime(readFile(path))
      if stamp.isNone: return ProcessStartProbe(status: pssUnknown)
      ProcessStartProbe(status: pssPresent, stamp: stamp.get())
    except CatchableError:
      # ENOENT is also possible under hidepid=2. Only ESRCH from kill proves
      # absence; EPERM, malformed data, and failed reads remain uncertainty.
      if kill(Pid(pid), 0) != 0 and errno == ESRCH:
        return ProcessStartProbe(status: pssAbsent)
      ProcessStartProbe(status: pssUnknown)

else:
  proc probeProcessStart*(pid: int): ProcessStartProbe =
    discard pid
    ProcessStartProbe(status: pssUnknown)

proc processStartStamp*(pid: int): string =
  ## Convenience for recording a stamp. Liveness uses the structured probe
  ## so an unavailable stamp is never mistaken for confirmed absence.
  probeProcessStart(pid).stamp

proc exactWriterBootId(): Option[uint64] =
  ## Match shm_gset's authoritative encoding, but never its wall-clock
  ## fallback. Shard warm-up tolerates a drifting id; reclaiming a LIVE
  ## session cannot. Keep this encoding aligned with shm_gset/platform.
  when defined(macosx):
    proc sysctlbyname(name: cstring; oldp: pointer; oldlenp: ptr csize_t;
        newp: pointer; newlen: csize_t): cint
      {.importc, header: "<sys/sysctl.h>".}
    var tv: Timeval
    var size = csize_t(sizeof(tv))
    if sysctlbyname("kern.boottime", addr tv, addr size, nil, 0) == 0 and
        size == csize_t(sizeof(tv)) and int64(tv.tv_sec) > 0 and
        tv.tv_usec >= 0 and tv.tv_usec < 1_000_000:
      return some((uint64(tv.tv_sec) * 1_000_000'u64 +
        uint64(tv.tv_usec)) or 1'u64)
  elif defined(linux):
    try:
      let raw = readFile("/proc/sys/kernel/random/boot_id")
      let uuid = raw.strip()
      if uuid.len != 36: return none(uint64)
      for i, ch in uuid:
        if i in [8, 13, 18, 23]:
          if ch != '-': return none(uint64)
        elif ch notin {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}:
          return none(uint64)
      var h = 1469598103934665603'u64
      for ch in raw:
        if ch != '-' and ch != '\n':
          h = (h xor uint64(ord(ch))) * 1099511628211'u64
      return some(h or 1'u64)
    except CatchableError: discard
  none(uint64)

proc currentWriterIdentity*(): WriterIdentity =
  ## The identity of THIS process, to be written into a session record.
  let pid = when defined(posix): int(getpid()) else: 0
  let boot = exactWriterBootId()
  if boot.isNone: return WriterIdentity()
  WriterIdentity(bootSource: NativeWriterBootSource, bootId: boot.get(),
    pid: pid, startStamp: processStartStamp(pid))

proc encodeWriterIdentity*(identity: WriterIdentity): string =
  ## `v1:<source>:<bootId>:<pid>:<startStamp>` for a current identity;
  ## preserve legacy triples when encoding a decoded legacy identity.
  ## "" when the start stamp is unknown, so an
  ## unestablished identity is stored as absent rather than as a partial
  ## triple that later reads as authoritative.
  if identity.startStamp.len == 0:
    return ""
  let prefix = if identity.bootSource.len > 0:
    "v1:" & identity.bootSource & ":"
  else: ""
  prefix & $identity.bootId & WriterIdentityFieldSep & $identity.pid &
    WriterIdentityFieldSep & identity.startStamp

proc canonicalDecimalInRange(text: string; minimum, maximum: uint64): bool =
  # Native probes emit unpadded unsigned decimal components. Accepting another
  # spelling would make string inequality falsely prove that a live pid was
  # reused. Check the spelling and the native range before any comparison.
  if text.len == 0 or not text.allCharsInSet({'0' .. '9'}) or
      (text.len > 1 and text[0] == '0'):
    return false
  try:
    let value = parseBiggestUInt(text)
    value >= minimum and value <= maximum
  except ValueError:
    false

proc canonicalStartStamp(stamp: string): bool =
  when defined(macosx):
    let parts = stamp.split('.')
    parts.len == 2 and
      canonicalDecimalInRange(parts[0], 1'u64, uint64(high(int64))) and
      canonicalDecimalInRange(parts[1], 0'u64, 999_999'u64)
  elif defined(linux):
    canonicalDecimalInRange(stamp, 0'u64, high(uint64))
  else:
    false

proc decodeWriterIdentity*(encoded: string): Option[WriterIdentity] =
  ## Accept a recognized v1 record or a legacy triple with a canonical native
  ## start stamp. A partially parsable
  ## value is NOT repaired into a usable identity: half an identity answers
  ## the liveness question wrongly, and `none` answers it `wlUnknown`.
  if encoded.len == 0:
    return none(WriterIdentity)
  var parts = encoded.split(WriterIdentityFieldSep)
  var source = ""
  if parts.len == 5:
    # Unknown versions or sources cannot borrow this version's comparison
    # rules. Older daemons similarly reject v1 rather than reclaiming it.
    if parts[0] != "v1" or parts[1] != NativeWriterBootSource:
      return none(WriterIdentity)
    source = parts[1]
    parts = parts[2 .. 4]
  if parts.len != 3 or not canonicalStartStamp(parts[2]):
    return none(WriterIdentity)
  try:
    some(WriterIdentity(bootSource: source, bootId: parseBiggestUInt(parts[0]),
      pid: parseInt(parts[1]), startStamp: parts[2]))
  except ValueError:
    none(WriterIdentity)

proc writerLiveness*(encoded: string): WriterLiveness =
  ## Is the writer named by `encoded` still running?
  ##
  ## Every uncertain answer is `wlUnknown`, which callers treat as live. The
  ## only `wlDead` is a proven different Linux boot, absent pid, or reused pid.
  let parsed = decodeWriterIdentity(encoded)
  if parsed.isNone:
    return wlUnknown
  let identity = parsed.get()
  when not defined(macosx):
    if identity.bootSource == NativeWriterBootSource:
      let currentBoot = exactWriterBootId()
      if currentBoot.isNone: return wlUnknown
      if identity.bootId != currentBoot.get():
        # Linux's native UUID is stable for a boot; a legacy mismatch might
        # only mean that a different release chose a different source.
        return wlDead
  # Neither legacy boot values nor Darwin's calendar-based boot stamp can
  # prove death. In particular, XNU adjusts kern.boottime on calendar changes:
  # https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/clock.c
  # Interrogate the process even if the current boot probe is unavailable.
  let probe = probeProcessStart(identity.pid)
  case probe.status
  of pssUnknown: wlUnknown
  of pssAbsent: wlDead
  of pssPresent:
    if probe.stamp == identity.startStamp: wlLive
    else: wlDead  # Successful interrogation proves this pid was reused.

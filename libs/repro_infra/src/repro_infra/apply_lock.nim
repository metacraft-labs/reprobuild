## The per-host `repro infra apply` lock — reclaim rules included.
##
## Concurrent system applies are serialized through
## `<state-dir>/locks/apply.lock` per the spec's validation criterion.
##
## The lock MUST be reclaimable, and there are TWO ways an apply stops
## making progress:
##
##   1. **The owner is gone.** A crash, a SIGKILL, a severed remote
##      session that orphans an apply, a service-manager start timeout —
##      the process dies without reaching `releaseApplyLock` and leaves
##      the file behind. Treating mere presence as "busy" then refuses
##      EVERY subsequent apply forever. `processAlive` closes that case.
##
##   2. **The owner is alive but hung.** This is the case that actually
##      wedges hosts in practice: a long-running apply on a Windows host
##      held the lock for four hours while consuming ~7 seconds of CPU
##      in total and none at all across a 20-second sample. `kill(pid,0)`
##      correctly reports it ALIVE, so a liveness-only rule never
##      reclaims and every apply is refused indefinitely.
##
## Case 2 is what this module's heartbeat is for. The lock record carries
## a **progress heartbeat**: the holder calls `refreshApplyLock` as it
## works, which bumps a monotonic `beats` counter and the `heartbeat`
## timestamp. A lock whose heartbeat has not advanced for longer than the
## configured window is treated as hung and is reclaimable.
##
## The heartbeat is deliberately driven by the apply's own forward
## progress and NOT by a background timer thread. A timer thread would
## keep beating from a process blocked forever in a child-process wait or
## a stuck network read — exactly the hangs we need to detect — so a
## timer heartbeat would only ever catch a process that is dead or
## SIGSTOPped, which the liveness probe already covers.
##
## **Where the beats come from decides whether any of this is sound.**
## Beating only at phase boundaries would be a trap: `runInfraApply`'s
## privileged phase runs the WHOLE planned set in one stretch, and its
## action-edge phase is one dispatcher call over every edge, so a
## perfectly healthy apply of a large profile would fall silent for hours
## and be indistinguishable from a hung one. So the beat is per UNIT OF
## WORK, threaded down as `repro_elevation.ApplyProgressHook`:
##
##   * once per completed privileged operation, from both
##     `driveBrokerApply` (the broker streams an `OperationResult` per
##     operation) and `applyPrivilegedSetInProcess`;
##   * once per resolved action edge, from the build-action dispatcher —
##     including from inside `runBuild`, via the engine's own per-action
##     progress events.
##
## The remaining silence is therefore bounded by ONE unit of work, not by
## the apply. That is what lets "no beat for N seconds" mean STUCK rather
## than BUSY, and it is what the staleness default is calibrated against.
##
## SAFETY — never reclaim a lock whose owner is making progress. A false
## reclaim means two concurrent applies mutating system state, which is
## far worse than a wedge. So reclaiming a LIVE owner requires all of:
##
##   * the recorded heartbeat is older than
##     `ApplyLockPolicy.heartbeatStaleSeconds` — one hour by default,
##     chosen to exceed the slowest SINGLE operation in the closed set
##     (a full Visual Studio workload install, tens of minutes on a slow
##     host) with room to spare. Before per-unit beats the same number
##     would have had to cover a whole apply, which is unbounded; now it
##     only has to cover one operation, which is not;
##   * or the lock is older than an explicitly configured `maxAgeSeconds`
##     age-out (disabled by default, because a long legitimate apply must
##     not be cut short);
##   * and a SECOND observation, taken after `reclaimConfirmMs`, shows
##     the heartbeat and beat counter still unmoved. This is the cheap
##     last-moment race closer, not the primary defence: it catches a
##     beat that lands between our read and our write, and an owner whose
##     units of work are short enough to beat inside the window. The
##     staleness threshold is what protects a slow-but-working owner.
##
## A lock written by an older `repro` (a bare PID, no heartbeat) is never
## reclaimed from a live owner automatically — there is nothing to judge
## progress by. `--force-unlock` still works on it.
##
## WHY AUTOMATIC RECLAIM AT ALL, given `--force-unlock` exists. Because
## the hosts this protects are unattended: an apply that wedges on a
## runner at 03:00 has no operator to type `--force-unlock`, and the
## failure mode is silent — the host simply stops converging until
## somebody notices. `--force-unlock` covers the attended case; automatic
## reclaim covers the case that actually motivated this work. The reason
## it is defensible NOW and would not have been with phase-boundary beats
## is exactly the bound above: silence longer than the slowest single
## operation is evidence of a stuck apply, whereas silence longer than a
## phase was evidence of nothing. Operators who disagree can set
## `REPRO_INFRA_APPLY_LOCK_STALE_SECONDS=0`, which disables
## heartbeat-based reclaim and leaves dead-owner reclaim plus the escape
## hatch.
##
## We do NOT kill the hung owner. Reclaiming the lock is a decision about
## THIS host's serialization; terminating another process is a decision
## about somebody else's in-flight system mutation. A hung apply is
## typically blocked inside a privileged child (an installer, a service
## control call) that owns real system state, and killing the reprobuild
## parent neither kills that child nor rolls back what it did — and a
## non-elevated parent generally cannot signal an elevated child at all.
## So a reclaim REPORTS the displaced pid (recorded as `reclaimed-from`
## in the new lock and printed by the CLI) and the operator is told to
## verify the process is gone. Callers that want the stronger guarantee
## should terminate the reported pid before re-running.
##
## NOTE on the primitive: this is a cooperative advisory lock and the
## check-then-write is not atomic — it serializes ordinary sequential
## applies, which is what the spec asks for.
## `repro_system_apply/locks.nim` holds the stronger OS-level primitive
## (exclusive `CreateFileW` / `flock`, released by the kernel on process
## death). It is NOT the better foundation for the hung-owner case: a
## live-but-hung process holds an `flock` just as firmly as a healthy
## one, so the OS primitive fixes nothing here and would remove the
## readable owner/heartbeat record this module needs. Swapping to it
## would still be the right move if strict mutual exclusion against a
## racing acquirer is ever required; the heartbeat record would have to
## be layered on top of it either way.

import std/[os, strutils, times]

when defined(windows):
  import std/winlean
else:
  import std/posix

import ./state_dir

const
  ApplyLockStaleEnvVar* = "REPRO_INFRA_APPLY_LOCK_STALE_SECONDS"
    ## Operator override for `heartbeatStaleSeconds`. `0` disables
    ## heartbeat-based reclaim entirely (dead-owner reclaim stays).
  ApplyLockMaxAgeEnvVar* = "REPRO_INFRA_APPLY_LOCK_MAX_AGE_SECONDS"
    ## Operator override for the age-out. `0` (the default) disables it.
  ApplyLockConfirmEnvVar* = "REPRO_INFRA_APPLY_LOCK_CONFIRM_MS"
    ## Operator override for the confirm-a-second-time window.

  DefaultHeartbeatStaleSeconds* = 3600
    ## One hour with no unit of work completing. Beats are per privileged
    ## operation and per action edge, so this has to exceed the slowest
    ## SINGLE operation in the closed set — a full Visual Studio workload
    ## install, tens of minutes — not the slowest whole apply. Raise it
    ## on hosts that run slower individual operations.
  DefaultMaxLockAgeSeconds* = 0
    ## Age-out disabled by default: a long legitimate apply that keeps
    ## beating must never be reclaimed just for being long.
  DefaultReclaimConfirmMs* = 5000
    ## How long to watch a live owner's heartbeat before taking its
    ## lock. Only paid on the (rare) reclaim path, so it is cheap to be
    ## generous.

type
  ApplyLockRecord* = object
    ## The parsed contents of `<state-dir>/locks/apply.lock`.
    pid*: int                 ## owner; 0 when absent/unparseable
    acquiredAt*: int64        ## unix seconds; 0 when unknown
    heartbeatAt*: int64       ## unix seconds of the last progress beat
    beats*: int               ## monotonic progress counter
    reclaimedFrom*: int       ## pid this lock was reclaimed from, else 0
    present*: bool            ## the lock file exists on disk
    legacy*: bool             ## a bare-PID lock from an older `repro`

  ApplyLockPolicy* = object
    ## When a lock held by a LIVE, different process may be reclaimed.
    heartbeatStaleSeconds*: int
    maxAgeSeconds*: int
    reclaimConfirmMs*: int
    forceUnlock*: bool
      ## The operator escape hatch (`repro infra apply --force-unlock`):
      ## take the lock regardless of owner liveness or heartbeat.

  ApplyLockReclaim* = enum
    ## Why the acquirer was allowed to take an existing lock.
    alrNone = "none"                    ## no existing lock, or re-entry
    alrDeadOwner = "dead-owner"
    alrMalformed = "malformed-lock"
    alrStaleHeartbeat = "stale-heartbeat"
    alrAgedOut = "aged-out"
    alrForced = "forced"

  ApplyLockAcquisition* = object
    ## The outcome of an acquire attempt, with enough detail for the
    ## CLI to tell the operator what happened and what to do next.
    acquired*: bool
    reclaim*: ApplyLockReclaim
    previousOwner*: int       ## pid recorded in the lock we found, if any
    heldForSeconds*: int64    ## how long that lock had existed
    sinceHeartbeatSeconds*: int64  ## how long since its last progress beat

const
  ReclaimedFromLiveOwner* = {alrStaleHeartbeat, alrAgedOut, alrForced}
    ## Reclaims that displaced a process which was still ALIVE. The CLI
    ## warns on these — the displaced process was not terminated.

# ---------------------------------------------------------------------------
# Process liveness.
# ---------------------------------------------------------------------------

when defined(windows):
  const
    StillActive: DWORD = 259
    ProcessQueryLimitedInformation: DWORD = 0x1000
    # Win32 code returned by OpenProcess for a pid that does not exist.
    # Declared here because std/winlean does not export it.
    ErrorInvalidParameter: int32 = 87

  proc openProcessK32(desiredAccess: DWORD; inheritHandle: WINBOOL;
                      processId: DWORD): Handle
    {.importc: "OpenProcess", stdcall, dynlib: "kernel32".}

  proc getExitCodeProcessK32(process: Handle; exitCode: ptr DWORD): WINBOOL
    {.importc: "GetExitCodeProcess", stdcall, dynlib: "kernel32".}

proc processAlive*(pid: int): bool =
  ## True when a process with `pid` currently exists.
  ##
  ## Deliberately conservative: anything we cannot positively establish as
  ## dead is reported ALIVE, so an unexpected probe failure preserves the
  ## lock rather than letting two applies run concurrently.
  if pid <= 0:
    return false
  when defined(windows):
    let h = openProcessK32(ProcessQueryLimitedInformation, 0, DWORD(pid))
    if h == 0:
      # Cannot open: the process is gone (ERROR_INVALID_PARAMETER) or we
      # lack rights to it (ERROR_ACCESS_DENIED). Access-denied implies it
      # EXISTS, so only treat "not found" as dead.
      return getLastError() != ErrorInvalidParameter
    defer: discard closeHandle(h)
    var code: DWORD = 0
    if getExitCodeProcessK32(h, addr code) == 0:
      return true
    code == StillActive
  else:
    # kill(pid, 0) performs the permission + existence checks without
    # sending a signal: ESRCH means gone, EPERM means it exists but is
    # owned by another user.
    if posix.kill(Pid(pid), cint(0)) == 0:
      return true
    errno != ESRCH

# ---------------------------------------------------------------------------
# The lock record: a tolerant `key=value` text file.
#
# The old on-disk form was a bare decimal PID. It is still READ (so an
# upgrade across a held lock does not misfire) but never written.
# ---------------------------------------------------------------------------

proc parseApplyLockRecord*(text: string): ApplyLockRecord =
  ## Parse the lock body. An unparseable body yields `pid == 0`, which
  ## every caller treats as "nobody can prove ownership".
  let body = text.strip()
  if body.len == 0:
    return
  if '=' notin body:
    # A bare-PID lock written by an older `repro`.
    try:
      result.pid = parseInt(body)
      result.legacy = true
    except ValueError:
      result = ApplyLockRecord()
    return
  for rawLine in body.splitLines():
    let line = rawLine.strip()
    if line.len == 0:
      continue
    let eq = line.find('=')
    if eq <= 0:
      continue
    let key = line[0 ..< eq].strip()
    let value = line[eq + 1 .. ^1].strip()
    try:
      case key
      of "pid": result.pid = parseInt(value)
      of "acquired": result.acquiredAt = int64(parseBiggestInt(value))
      of "heartbeat": result.heartbeatAt = int64(parseBiggestInt(value))
      of "beats": result.beats = parseInt(value)
      of "reclaimed-from": result.reclaimedFrom = parseInt(value)
      else: discard
    except ValueError:
      # A half-parsed record must not be half-trusted: fall back to
      # "unreadable", which is reclaimable.
      return ApplyLockRecord()

proc renderApplyLockRecord*(rec: ApplyLockRecord): string =
  result = "pid=" & $rec.pid & "\n" &
           "acquired=" & $rec.acquiredAt & "\n" &
           "heartbeat=" & $rec.heartbeatAt & "\n" &
           "beats=" & $rec.beats & "\n"
  if rec.reclaimedFrom != 0:
    result.add("reclaimed-from=" & $rec.reclaimedFrom & "\n")

proc writeApplyLockRecord(lockPath: string; rec: ApplyLockRecord) =
  ## Replace the lock file in one step. The heartbeat rewrites this file
  ## repeatedly during an apply; a truncate-then-write would give a
  ## concurrent acquirer a window in which the lock reads as EMPTY (i.e.
  ## reclaimable). Rename-into-place removes that window.
  let text = renderApplyLockRecord(rec)
  let tmpPath = lockPath & ".new." & $getCurrentProcessId()
  try:
    writeFile(tmpPath, text)
    moveFile(tmpPath, lockPath)
  except OSError, IOError:
    try: removeFile(tmpPath)
    except OSError, IOError: discard
    writeFile(lockPath, text)

proc readApplyLockRecord*(stateDir: string): ApplyLockRecord =
  ## The lock's current contents. `present == false` when there is no
  ## lock file at all.
  let lockPath = applyLockPath(stateDir)
  if not fileExists(lockPath):
    return
  try:
    result = parseApplyLockRecord(readFile(lockPath))
  except IOError, OSError:
    result = ApplyLockRecord()
  result.present = true

proc applyLockOwner*(stateDir: string): int =
  ## PID recorded in the apply lock, or 0 when absent/unparseable.
  readApplyLockRecord(stateDir).pid

# ---------------------------------------------------------------------------
# Policy.
# ---------------------------------------------------------------------------

proc envSeconds(name: string; fallback: int): int =
  let raw = getEnv(name).strip()
  if raw.len == 0:
    return fallback
  try:
    let parsed = parseInt(raw)
    if parsed < 0: fallback else: parsed
  except ValueError:
    fallback

proc defaultApplyLockPolicy*(): ApplyLockPolicy =
  ## The shipped policy, with the documented environment overrides
  ## applied. `forceUnlock` is never on by default — it is an explicit
  ## operator action.
  ApplyLockPolicy(
    heartbeatStaleSeconds:
      envSeconds(ApplyLockStaleEnvVar, DefaultHeartbeatStaleSeconds),
    maxAgeSeconds: envSeconds(ApplyLockMaxAgeEnvVar, DefaultMaxLockAgeSeconds),
    reclaimConfirmMs: envSeconds(ApplyLockConfirmEnvVar, DefaultReclaimConfirmMs),
    forceUnlock: false)

proc liveOwnerReclaim(rec: ApplyLockRecord; policy: ApplyLockPolicy;
                      now: int64): ApplyLockReclaim =
  ## Classify a lock held by a DIFFERENT, LIVE process. `alrNone` means
  ## "not provably stale" — the lock stays held.
  if policy.forceUnlock:
    return alrForced
  if rec.heartbeatAt > 0 and policy.heartbeatStaleSeconds > 0 and
     now - rec.heartbeatAt > int64(policy.heartbeatStaleSeconds):
    # No apply milestone for longer than the configured window: hung.
    # (A legacy bare-PID lock has no heartbeat and is never judged here.)
    return alrStaleHeartbeat
  if rec.acquiredAt > 0 and policy.maxAgeSeconds > 0 and
     now - rec.acquiredAt > int64(policy.maxAgeSeconds):
    return alrAgedOut
  alrNone

proc progressed(before, after: ApplyLockRecord): bool =
  ## True when `after` shows the owner moved since `before` was read.
  before.pid != after.pid or
    before.beats != after.beats or
    before.heartbeatAt != after.heartbeatAt

# ---------------------------------------------------------------------------
# Acquire / beat / release.
# ---------------------------------------------------------------------------

proc tryAcquireApplyLock*(stateDir: string;
                          policy = defaultApplyLockPolicy()):
    ApplyLockAcquisition =
  ## Take the apply lock, reporting WHY an existing lock was taken (or
  ## why the attempt was refused). `acquireApplyLock` is the bool-only
  ## form.
  ensureSystemStateDir(stateDir)
  let lockPath = applyLockPath(stateDir)
  let me = getCurrentProcessId()
  let now = getTime().toUnix()
  let existing = readApplyLockRecord(stateDir)
  var reclaim = alrNone
  if existing.present:
    result.previousOwner = existing.pid
    if existing.acquiredAt > 0:
      result.heldForSeconds = now - existing.acquiredAt
    if existing.heartbeatAt > 0:
      result.sinceHeartbeatSeconds = now - existing.heartbeatAt
    if existing.pid == 0:
      # Unreadable/malformed: nobody can prove ownership, so it is
      # reclaimable rather than a permanent wedge.
      reclaim = alrMalformed
    elif existing.pid != me:
      if not processAlive(existing.pid):
        reclaim = alrDeadOwner
      else:
        reclaim = liveOwnerReclaim(existing, policy, now)
        if reclaim == alrNone:
          return
        if reclaim != alrForced and policy.reclaimConfirmMs > 0:
          # Watch the owner once more before displacing it. Any beat at
          # all in this window means the apply IS progressing, and a
          # progressing apply is never reclaimed.
          sleep(policy.reclaimConfirmMs)
          let recheck = readApplyLockRecord(stateDir)
          if not recheck.present:
            reclaim = alrNone       # released while we watched
          elif progressed(existing, recheck):
            return
  var fresh = ApplyLockRecord(
    pid: me, acquiredAt: now, heartbeatAt: now, beats: 0)
  if existing.present and existing.pid == me:
    # Re-entry by the current process keeps its own history.
    if existing.acquiredAt > 0: fresh.acquiredAt = existing.acquiredAt
    fresh.beats = existing.beats
    fresh.reclaimedFrom = existing.reclaimedFrom
  elif reclaim in ReclaimedFromLiveOwner and existing.pid != 0:
    # Record whose lock this was: the process was NOT terminated and the
    # operator needs the pid to check on it.
    fresh.reclaimedFrom = existing.pid
  writeApplyLockRecord(lockPath, fresh)
  result.acquired = true
  result.reclaim = reclaim

proc acquireApplyLock*(stateDir: string;
                       policy = defaultApplyLockPolicy()): bool =
  ## Returns true when the lock was acquired. The lock file holds the
  ## owning PID plus a progress heartbeat; a stale lock — from a dead
  ## process, or from a live owner that has stopped making progress — is
  ## reclaimed.
  tryAcquireApplyLock(stateDir, policy).acquired

proc refreshApplyLock*(stateDir: string): bool {.discardable.} =
  ## Record forward progress: bump the beat counter and heartbeat
  ## timestamp of a lock THIS process owns. Called at each apply
  ## milestone; a no-op (returning false) when this process does not own
  ## the lock, so library code can beat unconditionally.
  let lockPath = applyLockPath(stateDir)
  if not fileExists(lockPath):
    return false
  var rec = readApplyLockRecord(stateDir)
  if rec.pid != getCurrentProcessId():
    return false
  rec.legacy = false
  rec.beats = rec.beats + 1
  rec.heartbeatAt = getTime().toUnix()
  if rec.acquiredAt == 0:
    rec.acquiredAt = rec.heartbeatAt
  writeApplyLockRecord(lockPath, rec)
  true

proc releaseApplyLock*(stateDir: string) =
  let lockPath = applyLockPath(stateDir)
  if fileExists(lockPath):
    try: removeFile(lockPath) except OSError: discard

proc describeApplyLockHolder*(stateDir: string;
                              acq: ApplyLockAcquisition): string =
  ## Operator-facing detail for a REFUSED acquire: who holds the lock,
  ## for how long, and when it last made progress.
  result = "lock held at " & applyLockPath(stateDir)
  if acq.previousOwner != 0:
    result.add(" by pid " & $acq.previousOwner)
  if acq.heldForSeconds > 0:
    result.add(", held for " & $acq.heldForSeconds & "s")
  if acq.sinceHeartbeatSeconds > 0:
    result.add(", last progress " & $acq.sinceHeartbeatSeconds & "s ago")

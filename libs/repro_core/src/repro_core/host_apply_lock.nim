## The host-wide apply lock: at most one system apply changes a host at a time.
##
## The per-state-directory apply lock (``repro_infra/apply_lock``) serialises
## applies that share a state directory, and only those. Two applies with
## different state directories -- a deploy-agent tick and an operator's
## ``repro infra apply``, or two agents started with different
## ``--state-dir`` -- would otherwise change the same host at once. On rpi2
## (2026-10-30, reprobuild d7c86107b) exactly that happened: a timer-driven
## tick with a mis-rendered ``--state-dir`` ran beside a manual tick, and the
## two corrupted each other's closure realisations. The deploy agent took no
## apply lock at all.
##
## Rules (System-Profile-And-Infra-Apply.md, validation criteria):
##
## * **One path per host**: ``/run/repro-apply.lock`` on Linux and macOS,
##   ``%ProgramData%\repro-apply.lock`` on Windows. It is deliberately NOT
##   under ``/run/repro``: that directory is an add-on root, and the add-on
##   preflight refuses anything in it but ``secrets``. A lock file there made
##   every preflight after the first apply incompatible.
## * **Every privileged mutation runs under it**: ``runInfraApply`` and the
##   in-process privileged set, the privileged broker session (Windows), the
##   infra and add-on rollbacks, the add-on apply, bootstrap and switch
##   recovery, and the ReproOS system apply and rollback. Each takes it
##   FIRST, before any state directory's own lock.
## * **Only a privileged process takes it.** The file is created ``0600``
##   by root, so an unprivileged process can neither create nor open it, and
##   no local user can hold it to stall the host's applies. An unprivileged
##   process cannot change the host through ``repro`` either: on Linux and
##   macOS a non-root apply has no broker and is refused before the
##   privileged set, and on Windows its elevated broker takes the lock
##   itself. So a non-privileged acquisition is a no-op.
## * It is an ``flock``, re-entrant within a process (a reference count),
##   and the kernel drops it when the holder dies: there is nothing to
##   reclaim. A second apply waits up to a deadline, then refuses naming the
##   holder's PID. Switch recovery does not wait at all
##   (``tryAcquireHostApplyLock``): a held lock means a switch is running,
##   and that switch is what started the recovery unit.
##
## ``REPRO_HOST_APPLY_LOCK`` names another lock file for tests. An
## unprivileged process honours it (and then does lock); root honours it only
## in a binary built with ``-d:reproHostApplyLockTestOverride``, so a
## production root apply can never be pointed at a private lock.

import std/[os, strutils]
when not defined(windows):
  import std/posix

import ./file_lock

const
  HostApplyLockEnvVar* = "REPRO_HOST_APPLY_LOCK"
  HostApplyLockWaitEnvVar* = "REPRO_HOST_APPLY_LOCK_WAIT_SECONDS"
  SystemHostApplyLockPath* = "/run/repro-apply.lock"
  WindowsHostApplyLockName* = "repro-apply.lock"
  DefaultHostApplyLockWaitSeconds* = 600
    ## A deploy-agent tick that meets an operator apply waits this long,
    ## then refuses (the next tick retries).
  RootMayOverrideHostLock* = defined(reproHostApplyLockTestOverride)

type
  HostApplyLock* = object
    held: bool

var
  hostLock: ReproFileLock
  hostLockDepth = 0

proc processIsPrivileged*(): bool =
  ## Root on Linux and macOS. On Windows the caller says (it knows whether
  ## its token is elevated); the default is unprivileged.
  when defined(windows): false
  else: geteuid() == 0

proc hostApplyLockPathFor*(privileged: bool; env: string;
                           programData = ""): string =
  ## Pure: the lock file for a process, given ``REPRO_HOST_APPLY_LOCK``.
  if env.len > 0 and (not privileged or RootMayOverrideHostLock):
    return env
  when defined(windows):
    (if programData.len > 0: programData else: "C:\\ProgramData") /
      WindowsHostApplyLockName
  else:
    discard programData
    SystemHostApplyLockPath

proc hostApplyLockPath*(privileged = processIsPrivileged()): string =
  hostApplyLockPathFor(privileged, getEnv(HostApplyLockEnvVar),
    getEnv("ProgramData"))

proc hostApplyLockWaitMs*(): int =
  let raw = getEnv(HostApplyLockWaitEnvVar).strip()
  var seconds = DefaultHostApplyLockWaitSeconds
  if raw.len > 0:
    try: seconds = max(0, parseInt(raw))
    except ValueError: discard
  seconds * 1000

proc acquireHostApplyLock*(what: string; waitMs = hostApplyLockWaitMs();
                           privileged = processIsPrivileged()):
    HostApplyLock =
  ## Take the host-wide apply lock for ``what`` (named in the refusal).
  ## Re-entrant within the process. A process that is not ``privileged``
  ## takes nothing (see the module header) unless a test lock is named.
  ## Raises ``ELockTimeout`` when another process still holds it after
  ## ``waitMs``.
  if hostLockDepth > 0:
    inc hostLockDepth
    return HostApplyLock(held: true)
  let override = getEnv(HostApplyLockEnvVar)
  if not privileged and override.len == 0:
    return HostApplyLock(held: false)
  let path = hostApplyLockPathFor(privileged, override, getEnv("ProgramData"))
  try:
    hostLock = acquireExclusiveLockWithin(path, waitMs, mode = 0o600)
  except ELockTimeout as e:
    e.msg = what & ": another apply is changing this host (" & e.msg & ")"
    raise
  hostLockDepth = 1
  HostApplyLock(held: true)

proc tryAcquireHostApplyLock*(what: string;
                              privileged = processIsPrivileged()):
    tuple[lock: HostApplyLock; holder: string] =
  ## Zero-wait form: ``lock.held`` false and ``holder`` describing who has
  ## it when another process holds it now.
  try:
    result.lock = acquireHostApplyLock(what, 0, privileged)
  except ELockTimeout as e:
    result.holder = e.msg

proc release*(lock: var HostApplyLock) =
  ## Release one reference; the flock is dropped with the last.
  if not lock.held: return
  lock.held = false
  dec hostLockDepth
  if hostLockDepth == 0:
    releaseExclusiveFileLock(hostLock)

proc hostApplyLockHeldHere*(): bool =
  hostLockDepth > 0

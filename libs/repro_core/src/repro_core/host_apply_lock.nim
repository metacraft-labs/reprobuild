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
## This lock is keyed on the host, not on a state directory. Every path that
## changes system state takes it for its whole duration: ``runInfraApply``
## (the operator's ``repro infra apply``, the deploy agent's tick, an add-on
## apply and the rollbacks that run through it), add-on bootstrap, and the
## ReproOS ``repro system`` apply and rollback pipelines.
##
## * It is an ``flock`` on ``/run/repro/apply.lock`` (root), so the kernel
##   releases it when the holder dies: there is nothing to reclaim.
## * It is re-entrant within a process (a reference count): an add-on apply
##   that calls ``runInfraApply`` takes it once.
## * A second apply waits up to a deadline, then refuses naming the
##   holder's PID (``ELockTimeout``).
##
## A process that is not root cannot change host state without elevating,
## and cannot create ``/run/repro``. It locks a per-user file instead, which
## serialises that user's applies with each other (tests included).
## ``REPRO_HOST_APPLY_LOCK`` names the lock file explicitly (a confined
## harness, or a test that must not share the user's lock); it is never set
## in production.

import std/[os, strutils]
when not defined(windows):
  import std/posix

import ./file_lock

const
  HostApplyLockEnvVar* = "REPRO_HOST_APPLY_LOCK"
  HostApplyLockWaitEnvVar* = "REPRO_HOST_APPLY_LOCK_WAIT_SECONDS"
  SystemHostApplyLockPath* = "/run/repro/apply.lock"
  DefaultHostApplyLockWaitSeconds* = 600
    ## A deploy-agent tick that meets an operator apply waits this long,
    ## then refuses (the next tick retries). Ten minutes covers a typical
    ## apply; an apply that runs longer is reported, not waited out.

type
  HostApplyLock* = object
    held: bool

var
  hostLock: ReproFileLock
  hostLockDepth = 0

proc hostApplyLockPathFor*(euid: int; env: string; tempDir: string): string =
  ## Pure: the lock file for a process with ``euid``, given the
  ## ``REPRO_HOST_APPLY_LOCK`` value ``env``.
  if env.len > 0: env
  elif euid == 0: SystemHostApplyLockPath
  else: tempDir / ("repro-host-apply-" & $euid & ".lock")

proc hostApplyLockPath*(): string =
  when defined(windows):
    hostApplyLockPathFor(1, getEnv(HostApplyLockEnvVar), getTempDir())
  else:
    hostApplyLockPathFor(int(geteuid()), getEnv(HostApplyLockEnvVar),
      getTempDir())

proc hostApplyLockWaitMs(): int =
  let raw = getEnv(HostApplyLockWaitEnvVar).strip()
  var seconds = DefaultHostApplyLockWaitSeconds
  if raw.len > 0:
    try: seconds = max(0, parseInt(raw))
    except ValueError: discard
  seconds * 1000

proc acquireHostApplyLock*(what: string): HostApplyLock =
  ## Take the host-wide apply lock for ``what`` (named in the refusal).
  ## Re-entrant within the process. Raises ``ELockTimeout`` when another
  ## process still holds it at the deadline.
  if hostLockDepth > 0:
    inc hostLockDepth
    return HostApplyLock(held: true)
  let path = hostApplyLockPath()
  try:
    hostLock = acquireExclusiveLockWithin(path, hostApplyLockWaitMs())
  except ELockTimeout as e:
    e.msg = what & ": another apply is changing this host (" & e.msg & ")"
    raise
  hostLockDepth = 1
  HostApplyLock(held: true)

proc release*(lock: var HostApplyLock) =
  ## Release one reference; the flock is dropped with the last.
  if not lock.held: return
  lock.held = false
  dec hostLockDepth
  if hostLockDepth == 0:
    releaseExclusiveFileLock(hostLock)

proc hostApplyLockHeldHere*(): bool =
  hostLockDepth > 0

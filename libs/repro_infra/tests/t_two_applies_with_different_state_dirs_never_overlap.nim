## Two applies with DIFFERENT state directories never run at once on one host.
##
## rpi2, 2026-10-30, reprobuild d7c86107b: a timer-driven deploy-agent tick
## with a mis-rendered `--state-dir` ran beside a manual tick. The
## per-state-directory apply lock did not see them as the same apply (and
## the agent took no lock at all), so both changed the host at once and
## corrupted each other's closure realisations. Every apply now holds the
## host-wide apply lock (`repro_core/host_apply_lock`) for its whole run.
##
## Two real processes run the real `runInfraApply`, each with its own state
## directory. A is held inside its apply. B, with no wait allowed, must be
## refused and told A's PID. It must not apply.
##
## MOCK JUSTIFICATION. A's build-action dispatcher is injected: it blocks on
## a pipe, which is how A is held mid-apply deterministically, and it
## performs no build. This is the dispatcher seam every runInfraApply test
## uses (t_smoke_phase_g_runinfraapply_dispatch). The lock, the apply
## pipeline and the state directories are the production ones.
## `REPRO_HOST_APPLY_LOCK` points both processes at a lock file private to
## this test, so the test neither takes nor waits on the user's real lock.

import std/[os, strutils, tempfiles, unittest]
when defined(posix):
  import std/posix

import repro_core/file_lock
import repro_core/host_apply_lock
import repro_elevation
import repro_infra
import repro_profile

proc options(stateDir: string): ApplyOptions =
  result.stateDir = stateDir
  result.hostIdentity = "host-lock-test"
  result.reproExe = "/usr/bin/false"
  result.elevationMode = emNoElevate
  result.noPreview = true

when defined(posix):
  suite "host-wide apply lock":
    test "a second apply with another state directory is refused while the first runs":
      let tmp = createTempDir("host-apply-lock-", "")
      defer: removeDir(tmp)
      putEnv(HostApplyLockEnvVar, tmp / "apply.lock")
      defer: delEnv(HostApplyLockEnvVar)
      var inside, release: array[2, cint]
      doAssert pipe(inside) == 0 and pipe(release) == 0
      let a = fork()
      doAssert a >= 0
      if a == 0:
        var opts = options(tmp / "state-a")
        opts.buildActions = @[ProfileBuildAction(id: "hold",
          argv: @["/bin/true"])]
        opts.buildActionDispatcher = proc(actions: seq[ProfileBuildAction];
            onProgress: ApplyProgressHook): seq[BuildActionApplyOutcome]
            {.gcsafe.} =
          {.cast(gcsafe).}:
            var c = 'i'
            discard posix.write(inside[1], addr c, 1)
            discard posix.read(release[0], addr c, 1)
            for x in actions:
              result.add(BuildActionApplyOutcome(id: x.id, address: x.id,
                ok: true))
        var code = 0
        try:
          discard runInfraApply("", opts)
        except CatchableError as e:
          stderr.writeLine("apply A failed: " & e.msg)
          code = 1
        exitnow(cint(code))
      var c: char
      doAssert posix.read(inside[0], addr c, 1) == 1   # A is mid-apply
      # B: another state directory, no waiting.
      putEnv(HostApplyLockWaitEnvVar, "0")
      defer: delEnv(HostApplyLockWaitEnvVar)
      var refused = false
      var named = false
      try:
        discard runInfraApply("", options(tmp / "state-b"))
      except ELockTimeout as e:
        refused = true
        named = a.int in e.holderPids and ("pid " & $a) in e.msg
      check refused
      check named
      check not dirExists(tmp / "state-b")
      c = 'r'
      doAssert posix.write(release[1], addr c, 1) == 1
      var status: cint
      doAssert waitpid(a, status, 0) == a
      check WIFEXITED(status) and WEXITSTATUS(status) == 0
      # With A done, B goes through.
      discard runInfraApply("", options(tmp / "state-b"))
      check not hostApplyLockHeldHere()

    test "the lock is re-entrant within one process":
      let tmp = createTempDir("host-apply-lock-reentrant-", "")
      defer: removeDir(tmp)
      putEnv(HostApplyLockEnvVar, tmp / "apply.lock")
      defer: delEnv(HostApplyLockEnvVar)
      var outer = acquireHostApplyLock("outer")
      discard runInfraApply("", options(tmp / "state"))   # takes it again
      check hostApplyLockHeldHere()
      outer.release()
      check not hostApplyLockHeldHere()

    test "the system lock lives outside every state directory":
      check hostApplyLockPathFor(0, "", "/tmp") == SystemHostApplyLockPath
      check hostApplyLockPathFor(1000, "", "/tmp") ==
        "/tmp/repro-host-apply-1000.lock"
      check hostApplyLockPathFor(0, "/x/l", "/tmp") == "/x/l"

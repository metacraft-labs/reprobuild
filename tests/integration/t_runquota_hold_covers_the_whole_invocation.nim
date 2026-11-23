## The hold on an adopted, retiring `runquotad` lasts for the whole `repro
## test` / `repro build`, not for one of its steps.
##
## THE DEFECT. The adoption hold on a retiring `runquotad` ended with the
## dev-env preparation. `repro test` runs
## the RunQuota auto-start twice: while it prepares the dev env, and again when
## the build opens its session. Each step released its own hold. On a fresh
## one-job runner (nim-termctl run 44842642371, attempt 2) setup's `repro
## dev-env` passes had started a `runquotad` from another build; `repro test`
## adopted it, asked it to retire, and let go of it when the dev-env step
## ended. Its other clients left too, so it exited before the build's step,
## which then found no daemon.
##
## WHAT IS GRADED. The real `startAutoRunQuotaIfNeeded` /
## `releaseAutoRunQuotaProcess` pair, twice, against a scratch per-user
## endpoint (`isolateUserRunQuota`), with real daemons:
##
## 1. A "foreign" `runquotad` is started: a copy of the real one with one byte
##    appended, so its image digest differs from the install's ("from another
##    build"), exactly as RunQuota decides it.
## 2. One extra client connects to it, standing for the other jobs' clients
##    the CI log counted, so the retirement waits instead of vacating at once.
## 3. With the install's `runquotad` as the candidate, the dev-env step's
##    auto-start adopts the foreign daemon and asks it to retire, then the
##    step releases. The extra client then leaves.
## 4. Inside `withInvocationRunQuotaHold` the foreign daemon must still be
##    alive and answering when the build's step starts; it must exit once the
##    scope ends.
##
## NEGATIVE CONTROL. The same sequence without the scope: the foreign daemon
## exits after step 3, which is the defect.
##
## NO MOCKS. Real `runquotad` processes on a real socket. Skipped only when no
## `runquotad` can be found on this host.

import std/[os, osproc, tempfiles, unittest]

import repro_cli_support
import repro_runquota
import runquota_client
import repro_test_support/per_user_runquota
import repro_test_support/reasoned_skip

when defined(posix):
  proc waitGone(pid: int; timeoutMs: int): bool =
    var waited = 0
    while waited <= timeoutMs:
      if not pidAlive(pid):
        return true
      sleep(100)
      waited += 100
    false

  proc stillAliveAfter(pid: int; ms: int): bool =
    not waitGone(pid, ms)

  type Staged = object
    foreignPid: int
    other: RunQuotaClient

  proc stageForeignDaemon(foreignBin, realBin: string): Staged =
    ## Steps 1-3 up to the dev-env step's release: the foreign daemon is
    ## running, adopted, asked to retire, and one other client is connected.
    putEnv("RUNQUOTAD_BIN", foreignBin)
    var started = startAutoRunQuotaIfNeeded(false)
    doAssert started != nil, "the foreign runquotad did not start"
    result.foreignPid = processID(started)
    releaseAutoRunQuotaProcess(started)
    result.other = connectDefault()
    resetInvocationRunQuotaDaemonBin()
    putEnv("RUNQUOTAD_BIN", realBin)

suite "the RunQuota hold covers the whole invocation":
  when defined(posix):
    test "a retiring daemon adopted by the dev-env step still serves the build's step":
      let realDaemon = findRunQuotaDaemonBin()
      if realDaemon.len == 0:
        checkpoint("no runquotad on this host")
        skip("no runquotad on this host")
      else:
        let scratch = createTempDir("repro-rqhold-", "")
        let foreign = scratch / "runquotad"
        copyFileWithPermissions(realDaemon, foreign)
        # A Nix-store binary is copied read-only.
        setFilePermissions(foreign, {fpUserRead, fpUserWrite, fpUserExec})
        block:
          var f = open(foreign, fmAppend)
          f.write("\0")
          f.close()
        let savedBin = getEnv("RUNQUOTAD_BIN")
        let hadBin = existsEnv("RUNQUOTAD_BIN")
        let savedAuto = getEnv("REPROBUILD_AUTO_RUNQUOTA")
        let hadAuto = existsEnv("REPROBUILD_AUTO_RUNQUOTA")
        putEnv("REPROBUILD_AUTO_RUNQUOTA", "1")
        var pids: seq[int] = @[]
        let isolated = isolateUserRunQuota()
        defer:
          for pid in pids:
            stopUserDaemon(isolated.socket, pid)
          isolated.release()
          if hadBin: putEnv("RUNQUOTAD_BIN", savedBin)
          else: delEnv("RUNQUOTAD_BIN")
          if hadAuto: putEnv("REPROBUILD_AUTO_RUNQUOTA", savedAuto)
          else: delEnv("REPROBUILD_AUTO_RUNQUOTA")
          resetInvocationRunQuotaDaemonBin()
          removeDir(scratch)

        # NEGATIVE CONTROL: per-step holds. The foreign daemon exits once the
        # dev-env step and the other client have both let go.
        block perStep:
          resetInvocationRunQuotaDaemonBin()
          var staged = stageForeignDaemon(foreign, realDaemon)
          pids.add(staged.foreignPid)
          var devEnv = startAutoRunQuotaIfNeeded(false)
          check devEnv == nil              # adopted, not started
          check pidAlive(staged.foreignPid)
          releaseAutoRunQuotaProcess(devEnv)
          staged.other.close()
          check waitGone(staged.foreignPid, 10_000)
          require waitLifetimeLockFree(isolated.socket, 30_000)

        # THE FIX: one hold for the invocation.
        block perInvocation:
          resetInvocationRunQuotaDaemonBin()
          var staged = stageForeignDaemon(foreign, realDaemon)
          pids.add(staged.foreignPid)
          withInvocationRunQuotaHold:
            var devEnv = startAutoRunQuotaIfNeeded(false)
            check devEnv == nil
            releaseAutoRunQuotaProcess(devEnv)
            staged.other.close()
            # The gap between the two steps: the daemon must not go.
            check stillAliveAfter(staged.foreignPid, 3_000)
            var buildStep = startAutoRunQuotaIfNeeded(false)
            check buildStep == nil         # still the adopted one
            check pidAlive(staged.foreignPid)
            releaseAutoRunQuotaProcess(buildStep)
            check pidAlive(staged.foreignPid)
          # The scope released the hold: now the retiring daemon goes.
          check waitGone(staged.foreignPid, 10_000)

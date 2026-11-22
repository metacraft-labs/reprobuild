## One invocation's later auto-start starts the `runquotad` its first one found.
##
## THE DEFECT (reprobuild-pm issue 2026-11-21, "`repro test` on a long-lived
## runner adopts a retiring `runquotad`, then cannot find a `runquotad` to
## start when it exits"). `repro test` runs the RunQuota auto-start twice: once
## while it prepares the dev env, and again when the build opens its own
## session. On a persistent runner the first one adopted a daemon from another
## build, which retires once this invocation lets go of it. The first search
## had found the install's `runquotad` on `PATH` (the handover named it); the
## second ran after the dev-env preparation, found nothing, and returned nil,
## so the build stopped with "runquota daemon unreachable and bypass is
## disabled".
##
## WHAT IS GRADED. The real `startAutoRunQuotaIfNeeded`, twice in one process,
## against a scratch per-user endpoint (`isolateUserRunQuota`; the real one is
## shared with every process of this uid). The first call finds the real
## daemon through `RUNQUOTAD_BIN` and starts it. That daemon is then stopped,
## which leaves the endpoint as the retiring daemon left it: nobody alive
## there. The discovery environment is then changed so the search finds
## nothing (no `RUNQUOTAD_BIN`, an empty `PATH`, a working directory with no
## `../runquota` sibling), and the search's emptiness is asserted rather than
## assumed. The second call must start a daemon anyway, from the binary the
## first call found.
##
## NEGATIVE CONTROL. The same second call after `resetInvocationRunQuotaDaemonBin`
## returns nil and starts nothing, so it is the remembered binary, and not some
## other discovery route, that the positive case depends on.
##
## NO MOCKS. The daemon is the real `runquotad`, started detached by the real
## launcher on a real socket; the search is the real `findRunQuotaDaemonBin`.
## The case is skipped only when no `runquotad` can be found at all, and when
## the sibling-checkout fallback answers from this test binary's location,
## which the case cannot switch off.

import std/[os, osproc, tempfiles, unittest]

import repro_cli_support
import repro_test_support/per_user_runquota
import repro_test_support/reasoned_skip

proc writeExecutable(path: string) =
  writeFile(path, "#!/bin/sh\nexit 0\n")
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

suite "runquota auto-start keeps the daemon it found":
  test "a fresh answer is remembered and wins; an empty one falls back to it":
    resetInvocationRunQuotaDaemonBin()
    defer: resetInvocationRunQuotaDaemonBin()
    let scratch = createTempDir("repro-rqmemo-", "")
    defer: removeDir(scratch)
    let first = scratch / "first-runquotad"
    let second = scratch / "second-runquotad"
    writeExecutable(first)
    writeExecutable(second)
    check invocationRunQuotaDaemonBinFor("") == ""
    check invocationRunQuotaDaemonBinFor(first) == first
    check invocationRunQuotaDaemonBinFor("") == first
    # A later search that finds another daemon (an operator's RUNQUOTAD_BIN,
    # a changed PATH) is never overridden by the remembered one.
    check invocationRunQuotaDaemonBinFor(second) == second
    check invocationRunQuotaDaemonBinFor("") == second
    # A remembered binary that is gone is not offered.
    removeFile(second)
    check invocationRunQuotaDaemonBinFor("") == ""

  when defined(posix):
    test "the build's auto-start starts the daemon the dev-env auto-start found":
      let realDaemon = findRunQuotaDaemonBin()
      if realDaemon.len == 0:
        checkpoint("no runquotad on this host")
        skip("no runquotad can be found on this host")
      else:
        resetInvocationRunQuotaDaemonBin()
        let isolated = isolateUserRunQuota()
        let savedBin = getEnv("RUNQUOTAD_BIN")
        let hadBin = existsEnv("RUNQUOTAD_BIN")
        let savedPath = getEnv("PATH")
        let savedAuto = getEnv("REPROBUILD_AUTO_RUNQUOTA")
        let hadAuto = existsEnv("REPROBUILD_AUTO_RUNQUOTA")
        let savedCwd = getCurrentDir()
        let emptyDir = createTempDir("repro-rqmemo-path-", "")
        var startedPids: seq[int] = @[]
        defer:
          setCurrentDir(savedCwd)
          putEnv("PATH", savedPath)
          if hadBin: putEnv("RUNQUOTAD_BIN", savedBin)
          else: delEnv("RUNQUOTAD_BIN")
          if hadAuto: putEnv("REPROBUILD_AUTO_RUNQUOTA", savedAuto)
          else: delEnv("REPROBUILD_AUTO_RUNQUOTA")
          for pid in startedPids:
            stopUserDaemon(isolated.socket, pid)
          isolated.release()
          resetInvocationRunQuotaDaemonBin()
          removeDir(emptyDir)
        putEnv("REPROBUILD_AUTO_RUNQUOTA", "1")
        putEnv("RUNQUOTAD_BIN", realDaemon)

        # The dev-env preparation's auto-start: finds and starts the daemon.
        var devEnvDaemon = startAutoRunQuotaIfNeeded(false)
        check devEnvDaemon != nil
        if devEnvDaemon != nil:
          startedPids.add(processID(devEnvDaemon))
        check getEnv("RUNQUOTA_SOCKET") == isolated.socket
        releaseAutoRunQuotaProcess(devEnvDaemon)
        # The daemon goes away, as the retiring one did once this invocation
        # let go of it.
        for pid in startedPids:
          stopUserDaemon(isolated.socket, pid)
        require waitLifetimeLockFree(isolated.socket, 30_000)

        # The environment the build's auto-start then searches.
        delEnv("RUNQUOTAD_BIN")
        putEnv("PATH", emptyDir)
        setCurrentDir(emptyDir)
        let searched = findRunQuotaDaemonBin()
        if searched.len > 0:
          checkpoint("the sibling-checkout fallback answers here: " & searched)
          skip("the sibling-checkout fallback finds a runquotad from this test binary's location")
        else:
          # NEGATIVE CONTROL first, so its nil cannot be a daemon the positive
          # case left running.
          let remembered = invocationRunQuotaDaemonBinFor("")
          check remembered == realDaemon
          resetInvocationRunQuotaDaemonBin()
          var forgotten = startAutoRunQuotaIfNeeded(false)
          check forgotten == nil
          check not lifetimeLockHeld(isolated.socket)
          releaseAutoRunQuotaProcess(forgotten)

          # The build's auto-start, with the dev-env one's answer remembered.
          discard invocationRunQuotaDaemonBinFor(realDaemon)
          var buildDaemon = startAutoRunQuotaIfNeeded(false)
          check buildDaemon != nil
          if buildDaemon != nil:
            startedPids.add(processID(buildDaemon))
          check lifetimeLockHeld(isolated.socket)
          check getEnv("RUNQUOTA_SOCKET") == isolated.socket
          releaseAutoRunQuotaProcess(buildDaemon)

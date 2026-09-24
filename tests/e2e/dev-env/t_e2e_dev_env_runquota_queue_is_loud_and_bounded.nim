## `repro exec` waiting behind somebody else's RunQuota leases says so, says
## who, and gives up with a diagnosis instead of hanging.
##
## ## The defect this locks out
##
## 2026-09-24, from ~10:54: `repro exec -- echo hi` in `D:\ah\dev\agent-harbor`
## hung -- and with it every `just` recipe of that repository, whose Justfile
## runs recipes through `repro exec`. Another workspace had started a
## seventy-minute `repro build` through the per-user daemon. `repro exec`
## compiles the recipe's provider as an engine action, the engine offered that
## action to the host's one `runquotad`, and the daemon QUEUED it: "waiting for
## resource budget". The engine's inline-RunQuota wait loop then polled for a
## grant with no output and no bound, for as long as the other build held the
## budget. Two leases whose supervisors had died were also pinning 8.7 GiB of
## the daemon's 16 GiB, which nothing on screen could have told anyone.
##
## Reproduced here the same way, minus the other workspace: a private
## `runquotad` whose whole CPU budget is held by a `runquota acquire` lease,
## and a cold `repro exec` whose provider compile therefore cannot be admitted.
## Before the fix this case never returned. After it:
##
## * the wait is announced on stderr, naming the queued action, the daemon's
##   reason, the endpoint, and the lease that holds the budget -- and repeated
##   while it lasts;
## * with a bound (`REPRO_RUNQUOTA_QUEUE_TIMEOUT`; the dev-env default is two
##   minutes, shortened here) the command fails, non-zero, with the same facts
##   and the remedies, and does not start the user's command.
##
## Mocking: none. Real `runquotad`, real `runquota acquire`, real `repro`.

import std/[os, osproc, strtabs, strutils, times, unittest]

import repro_test_support
import ./dev_env_export_helper

const
  holdFlag = "--repro-test-hold-until"
  printFlag = "--repro-test-print"

# Two helper roles, both played by this very test binary re-executed with a
# flag, so they are the same program on every platform and need no shell:
# the lease holder `runquota acquire` keeps running, and the user command
# `repro exec` must never get to start.
#
# The holder does not rely on being killed: terminating `runquota acquire` does
# not terminate ITS child on Windows, so the holder also leaves as soon as the
# release file it was handed appears (or after ten minutes, whichever is first).
block:
  let params = commandLineParams()
  if params.len == 2 and params[0] == holdFlag:
    let releaseFile = params[1]
    for _ in 0 ..< 600 * 10:
      if fileExists(releaseFile):
        break
      sleep(100)
    quit(0)
  if params.len == 2 and params[0] == printFlag:
    echo params[1]
    quit(0)

type
  PrivateRunQuota = object
    daemon: Process
    holder: Process
    socket: string
    releaseFile: string

proc waitForDaemon(socket, cli: string; env: StringTableRef) =
  ## The daemon is ready once a status round trip on its endpoint answers.
  for _ in 0 ..< 200:
    let probe = startProcess(cli, args = ["status"], env = env,
      options = {poStdErrToStdOut})
    let code = probe.waitForExit()
    probe.close()
    if code == 0:
      return
    sleep(50)
  raise newException(OSError, "private runquotad did not answer on " & socket)

proc overlayOf(env: StringTableRef): seq[tuple[name, value: string]] =
  for key, value in env:
    result.add((name: key, value: value))

proc holderLeaseVisible(cli: string; env: StringTableRef): bool =
  let res = runShell(shellCommand(@[cli, "leases", "--json"], overlayOf(env)),
    timeoutMs = 30_000)
  res.code == 0 and "holds the whole budget" in res.output and
    "\"running\"" in res.output

proc startSaturatedRunQuota(c: M74Case; env: StringTableRef): PrivateRunQuota =
  ## A private daemon with one CPU of budget, and a lease holding all of it.
  let daemonBin = requireRunQuotaDaemonBin(c.repoRoot)
  let cli = requireRunQuotaCliBin(c.repoRoot)
  result.socket = runquotaSocketEndpoint("repro-queue-" &
    $getCurrentProcessId())
  result.releaseFile = c.tempRoot / "release-holder"
  env["RUNQUOTA_SOCKET"] = result.socket
  result.daemon = startProcess(daemonBin, args = [
    "--socket", result.socket,
    "--cpu-milli", "1000",
    "--memory-bytes", $(4'i64 * 1024 * 1024 * 1024),
    "--no-write-stats",
    "--estimate-db", c.tempRoot / "runquota-estimates.db"],
    env = env, options = {})
  waitForDaemon(result.socket, cli, env)
  result.holder = startProcess(cli, args = [
    "acquire", "--cpu", "1000", "--mem", $(64 * 1024 * 1024),
    "--label", "another workspace's build (holds the whole budget)",
    "--", getAppFilename(), holdFlag, result.releaseFile],
    env = env, options = {})
  for _ in 0 ..< 200:
    if holderLeaseVisible(cli, env):
      return
    sleep(50)
  raise newException(OSError, "the holder lease never appeared")

proc stop(rq: var PrivateRunQuota) =
  try:
    writeFile(rq.releaseFile, "release\n")
    sleep(500)
  except CatchableError, OSError:
    discard
  for p in [rq.holder, rq.daemon]:
    if p != nil:
      try:
        p.terminate()
        discard p.waitForExit(5_000)
        p.close()
      except CatchableError, OSError:
        discard

proc removeScratch(dir: string) =
  ## Best-effort: a background writer the activation started (the action
  ## cache's hot-record flush) can still be finishing when the case ends, and
  ## a scratch directory that outlives its test is not a test failure.
  for _ in 0 ..< 20:
    try:
      removeDir(dir)
      return
    except OSError:
      sleep(250)

proc prepareExecCase(prefix: string): M74Case =
  ## The shared M74 fixture, with its recipe replaced by the smallest one that
  ## still needs a provider compile: no tool uses, so nothing but the recipe
  ## compile itself runs before the user's command (the M74 recipe declares a
  ## Nix-provisioned ``nim``, which a Windows host cannot realise).
  result = prepareCase(prefix)
  writeFile(result.projectRoot / "reprobuild.nim", """
import repro_project_dsl

package fixture:
  defaultToolProvisioning "path"
  devEnv:
    activity "default"
    setEnv "FIXTURE_MODE", "dev"
""")

when isIoMonitorSupported:
  suite "a dev-env activation blocked at RunQuota":

    test "is announced, names the holder, and is bounded":
      let c = prepareExecCase("repro-queue-bounded")
      defer: removeScratch(c.tempRoot)
      var env = c.envFor()
      env["REPROBUILD_PROGRESS"] = "quiet"
      env["REPRO_RUNQUOTA_QUEUE_TIMEOUT"] = "8000"
      if env.hasKey("REPROBUILD_NO_RUNQUOTA"):
        env.del("REPROBUILD_NO_RUNQUOTA")
      var rq = startSaturatedRunQuota(c, env)
      defer: stop(rq)

      let marker = "USER-COMMAND-RAN"
      let overlay = overlayOf(env)
      let started = epochTime()
      # Bounded by the TEST as well, so that the regression this case exists
      # for -- a wait with no end -- fails it instead of wedging the suite.
      # Generous, because the recipe's interface is extracted (a real
      # compile) before the provider compile gets as far as queueing.
      let res = runShell(shellCommand(@[c.reproBin, "exec", c.projectRoot,
        "--", getAppFilename(), printFlag, marker], overlay), c.repoRoot,
        timeoutMs = 15 * 60 * 1000)
      let elapsed = epochTime() - started
      let logPath = getTempDir() / ("t_e2e_dev_env_runquota_queue-" &
        $getCurrentProcessId() & ".log")
      writeFile(logPath, res.output)
      checkpoint "elapsed " & $elapsed & "s; full output: " & logPath &
        " (" & $res.output.len & " bytes)"
      let stderrText = res.output
      let stdoutText = res.output

      # Bounded: it RETURNED, and as a failure.
      check res.code != runShellTimedOutCode
      check res.code != 0
      # Announced while waiting, before giving up.
      check "runquota.waiting __repro_provider_compile" in stderrText
      # What it waited on: the daemon's reason and WHO holds the budget.
      check "waiting for resource budget" in stderrText
      check "another workspace's build (holds the whole budget)" in stderrText
      check "state=running" in stderrText
      # The give-up, with the remedies.
      check "gave up after" in stderrText
      check "REPRO_RUNQUOTA_QUEUE_TIMEOUT" in stderrText
      check "REPROBUILD_NO_RUNQUOTA=1" in stderrText
      # And the user's command never started.
      check marker notin stdoutText

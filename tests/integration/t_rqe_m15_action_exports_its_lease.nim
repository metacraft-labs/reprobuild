## An action launched under a RunQuota lease names that lease as the parent of
## its own RunQuota clients (reprobuild-pm
## `spec/RunQuota-Protocol-And-Client-Libraries.md` "Nested bridges").
##
## WHY THE ENGINE MUST DO IT. A sized action's tree can contain a RunQuota
## client of its own: a recipe that runs `runquota jobserver -- make`, a test
## that starts a nested build. With no parent named it asks the HOST for slots,
## on top of the slots its own action already holds. On a host whose budget the
## action fills, that request queues behind its own parent and the build never
## finishes. With `RUNQUOTA_PARENT_LEASE` set it takes a sub-lease from the
## parent's grant (`SubLease`), which the host ledger never sees.
##
## WHAT IS GUARDED, with the mutation that breaks it:
##
## * nested_client_does_not_wait_on_the_host: a 1-slot host budget is held
##   whole by an action that runs the real `runquota jobserver --width 1 --
##   true` under a 30 s bound. The nested bridge finishes (exit 0). Mutation:
##   `applyGrant` not exporting the parent lease (it returns the width-applied
##   command only): the bridge asks the host, queues behind its own parent and
##   the bound ends it (exit 124).
## * the_parent_is_this_actions_lease: each action's `RUNQUOTA_PARENT_LEASE` is
##   a lease id of its own, never the value the build inherited from the
##   process that started it. Mutation: leaving the inherited value alone
##   hands both actions the inherited id.
##
## NO MOCKS, ONE FIXTURE: the "action" is this file's own executable in
## `fixture-action` mode (it records what it received), and the nested client
## is the real `runquota` CLI. The daemon is the real `runquotad`, started by
## this file on an endpoint it owns.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_build_engine
import repro_runquota

import repro_test_support
import rqe_m15_width_fixture

const InheritedParent = "999999"
  ## What the build inherits from "the process that started it": a lease id
  ## that is not one of this build's.

proc fixtureMain(args: seq[string]) =
  ## `fixture-action record-parent <path>`: the parent lease the action
  ## sees, or `unset`.
  if args.len != 3 or args[1] != "record-parent": quit 64
  createDir(args[2].splitPath.head)
  writeFile(args[2], getEnv("RUNQUOTA_PARENT_LEASE", "unset") & "\n")

when defined(macosx) or defined(linux):
  var cachedMonitorTools: MonitorTools
  var cachedMonitorToolsReady = false
  proc monitorTools(repoRoot: string): MonitorTools =
    if not cachedMonitorToolsReady:
      cachedMonitorTools = prepareMonitorTools(repoRoot,
        repoRoot / "build" / "test-monitor-m15-lease", "m15-lease-monitor")
      putEnv("REPRO_MONITOR_SHIM_LIB", cachedMonitorTools.shim)
      cachedMonitorToolsReady = true
    cachedMonitorTools

when isMainModule:
  let params = commandLineParams()
  if params.len > 0 and params[0] == "fixture-action":
    fixtureMain(params)
    quit 0
  if params.len > 0 and params[0] == "__repro-runquota-helper":
    quit runRunQuotaHelperCli(params[1 .. ^1])

suite "an action's RunQuota clients are its lease's children":

  when isNixSupported:
    test "nested_client_does_not_wait_on_the_host, and the_parent_is_this_" &
        "actions_lease":
      let repoRoot = getCurrentDir()
      let tempRoot = createTempDir("repro-m15-lease", "")
      defer: removeDir(tempRoot)
      # One slot: the action below holds the whole host budget.
      var daemon = startPrivateDaemon(repoRoot, 1000)
      defer: daemon.stop()
      let runquotaCli = requireRunQuotaCliBin(repoRoot)

      let had = existsEnv("RUNQUOTA_PARENT_LEASE")
      let prior = getEnv("RUNQUOTA_PARENT_LEASE")
      putEnv("RUNQUOTA_PARENT_LEASE", InheritedParent)
      defer:
        if had: putEnv("RUNQUOTA_PARENT_LEASE", prior)
        else: delEnv("RUNQUOTA_PARENT_LEASE")

      let app = getAppFilename()
      let workRoot = tempRoot / "work"
      createDir(workRoot)
      let recordA = action("record-a",
        @[app, "fixture-action", "record-parent", workRoot / "a.txt"],
        cwd = workRoot, outputs = ["a.txt"], commandStatsId = "record-a",
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      var recordB = action("record-b",
        @[app, "fixture-action", "record-parent", workRoot / "b.txt"],
        cwd = workRoot, outputs = ["b.txt"], commandStatsId = "record-b",
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      recordB.deps = @["record-a"]
      # The nested client: the real runquota bridge, bounded so that a
      # failure to nest ends the case with a status instead of a hang.
      var nested = action("nested",
        @["sh", "-c",
          "timeout 30 \"$0\" jobserver --width 1 -- true; " &
          "echo $? > nested.status", runquotaCli],
        cwd = workRoot, outputs = ["nested.status"],
        commandStatsId = "nested",
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      nested.deps = @["record-b"]

      let buildResult = runBuild(graph(@[recordA, recordB, nested], []),
        BuildEngineConfig(
          cacheRoot: tempRoot / ".repro-cache",
          runQuotaCliPath: app,
          monitorCliPath: monitorTools(repoRoot).monitorCliPath,
          monitorCliArgs: monitorTools(repoRoot).monitorCliArgs,
          maxParallelism: 4'u32,
          stdoutLimit: 256 * 1024,
          stderrLimit: 256 * 1024,
          inlineRunQuota: true))
      for item in buildResult.results:
        checkpoint item.id & ": " & $item.status & " " & item.stderr
        check item.status == asSucceeded
      check not buildResult.runQuotaBypassed

      proc recorded(file: string): string =
        readFile(workRoot / file).strip()
      # The nested bridge took its width from the action's grant.
      check recorded("nested.status") == "0"
      # Each action sees a lease id of its own, not the inherited one.
      let a = recorded("a.txt")
      let b = recorded("b.txt")
      check a != InheritedParent
      check b != InheritedParent
      check a != "unset" and a.allCharsInSet(Digits)
      check b != "unset" and b.allCharsInSet(Digits)
      check a != b

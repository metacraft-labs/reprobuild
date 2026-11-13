## Graph-built negative control: an engine with no embedded SIP replacements.
## The nonempty monitor CLI marks the action monitored but is intentionally
## never executed: missing shell injection must reject launch before that point.
import std/[os, strutils, tempfiles]
import stackable_hooks/propagation
import repro_build_engine

when defined(macosx):
  doAssert StackableHooksBuiltToolsDir.len == 0,
    "the graph must build this fixture without embedded replacement tools"
  block:
    let tempRoot = createTempDir("repro-b1-failsafe", "")
    defer: removeDir(tempRoot)
    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / ".repro-cache"
    let emptyBin = tempRoot / "empty-bin"  # no `sh` here
    createDir(workRoot)
    createDir(emptyBin)

    let prevPath = getEnv("PATH")
    let prevSandbox = getEnv("CT_SANDBOX_TOOLS_DIR")
    let prevTools = getEnv("STACKABLE_HOOKS_TOOLS_DIR")
    putEnv("PATH", emptyBin)
    # An owned empty root also excludes a preexisting legacy global sandbox.
    putEnv("CT_SANDBOX_TOOLS_DIR", emptyBin)
    delEnv("STACKABLE_HOOKS_TOOLS_DIR")
    defer:
      putEnv("PATH", prevPath)
      if prevSandbox.len > 0: putEnv("CT_SANDBOX_TOOLS_DIR", prevSandbox)
      if prevTools.len > 0: putEnv("STACKABLE_HOOKS_TOOLS_DIR", prevTools)

    # Sanity: in this environment no non-SIP shell resolves.
    doAssert resolveNonSipShell().len == 0

    var config = defaultBuildEngineConfig(cacheRoot)
    config.bypassRunQuota = true
    config.maxParallelism = 1'u32
    config.stdoutLimit = 65536
    config.stderrLimit = 65536
    # Wire a (dummy but non-empty) monitor CLI path so the engine tags the
    # action as monitored (monitorDepfile gets set) and routes it through the
    # bypass launch — where the SIP-safe gate lives. The monitor itself is
    # never actually exec'd because the launch fails first.
    config.monitorCliPath = "/usr/bin/true"
    config.monitorCliArgs = @[]

    let buildResult = runBuild(graph([
      action("sip-failsafe", ["/usr/bin/true"], cwd = workRoot,
        outputs = @[], commandStatsId = "b1-failsafe",
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
    ]), config)

    var sawAction = false
    for item in buildResult.results:
      if item.id == "sip-failsafe":
        sawAction = true
        # The action MUST be failed (conservative fail-safe), not succeeded.
        doAssert item.status == asFailed
        # The diagnostic MUST explain the SIP-safety refusal so the failure
        # is actionable (conservative failure diagnostics).
        doAssert item.stderr.contains("SIP-safe") or
          item.stderr.contains("non-SIP shell")
    doAssert sawAction
  echo "SIP_NO_BUNDLE_FAIL_CLOSED"

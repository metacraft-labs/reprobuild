## RA-19 — Windows workspace bootstrap parity (decision/plan layer).
##
## The repo-workspaces pilot provisions the host toolchain on Windows
## (``env.ps1`` + ``windows/ensure-{gcc,gh,gpg,just,nim,python,repo}.ps1``)
## and activates a PowerShell env; the async post-commit cache push is
## POSIX-only (``setsid … &``). RA-19 adds the reprobuild equivalents:
##
##   * ``windowsProvisioningPlan`` — the ordered toolchain ensure-steps
##     (gcc/gh/gpg/just/nim/python/repo) + a PowerShell env activation.
##   * ``cachePushSpawnCommand`` — the platform-parameterized detached
##     cache-push command (POSIX ``setsid … &`` vs Windows ``start /b``).
##
## Both are PURE, platform-PARAMETERIZED functions (they take a
## ``WorkspaceTargetOs`` / install root, NOT ``when defined(windows)``), so
## the Windows decision logic is exercisable on this Linux host WITHOUT
## running any Windows tool. We assert the COMPUTED plan + command, never
## their execution.
##
## DEFERRED (cannot run on Linux): live Windows toolchain provisioning
## (the actual ``pwsh`` ensure-steps) and the real detached
## ``cmd /c start /b`` spawn. This test covers the decision/plan layer only.
##
## Falsifiability:
##   * If the Windows plan omits a required tool (or is empty), the
##     per-tool assertions fail.
##   * If the cache-push builder returns the POSIX ``setsid``/``&`` form for
##     a Windows target (or vice versa), the form assertions fail.
##   * If a step lacks a check or install command, those assertions fail.
##
## Hermetic: no network, no git, no subprocess — pure function calls.

import std/[strutils, unittest]

import repro_cli_support

const requiredTools = ["gcc", "gh", "gpg", "just", "nim", "python", "repo"]

suite "RA-19 — Windows workspace bootstrap parity (plan/decision layer)":

  test "test_ra19_windows_provisioning_plan_ensures_each_tool":
    # Drive the PURE plan builder with a Windows-style install root. This
    # runs on Linux because the OS is a PARAMETER of the plan, not a
    # compile-time guard.
    let plan = windowsProvisioningPlan("D:\\toolchains", "x64")

    # The plan is non-empty (a broken/empty plan fails here).
    check plan.steps.len > 0

    # Every required tool is present, each with a check + install command
    # and a skip toggle. An omitted tool, or a step missing its check /
    # install command, fails these assertions.
    for tool in requiredTools:
      var found = false
      for step in plan.steps:
        if step.tool == tool:
          found = true
          check step.checkCommand.len > 0
          check step.checkCommand.contains(tool)
          # The check is an idempotent --version probe.
          check step.checkCommand.contains("--version")
          check step.installCommand.len > 0
          # The install/ensure command names the tool (parity with the
          # pilot ``ensure-<tool>.ps1``).
          check step.installCommand.contains("ensure-" & tool)
          # An operator skip toggle exists for the tool.
          check step.skipEnvVar.len > 0
          check step.skipEnvVar.contains(tool.toUpperAscii())
          break
      check found

    # The plan carries exactly the seven required tools (no more, no less).
    check plan.steps.len == requiredTools.len

  test "test_ra19_windows_provisioning_plan_orders_build_tools_first":
    # nim + gcc are needed to build/run the native workspace tools, so they
    # must come before the per-workspace dev tools. A reordering that put a
    # dev tool ahead of both build tools fails here.
    let plan = windowsProvisioningPlan("D:\\toolchains")
    var order: seq[string]
    for step in plan.steps:
      order.add(step.tool)
    let nimIdx = order.find("nim")
    let gccIdx = order.find("gcc")
    let justIdx = order.find("just")
    check nimIdx >= 0
    check gccIdx >= 0
    check justIdx >= 0
    # Both build tools precede the first dev tool.
    check nimIdx < justIdx
    check gccIdx < justIdx

  test "test_ra19_windows_plan_activates_powershell_env":
    # The plan activates a Windows PowerShell env (the reprobuild analogue
    # of dot-sourcing env.ps1). Absent/empty activation fails here.
    let plan = windowsProvisioningPlan("D:\\toolchains")
    check plan.activation.targetOs == wtWindows
    check plan.activation.shell == "powershell"
    check plan.activation.activateCommand.len > 0
    # It references the env.ps1 dot-source.
    check plan.activation.activateCommand.contains("env.ps1")

  test "test_ra19_cache_push_windows_uses_detached_start_not_posix_fork":
    # Windows target → detached ``start /b`` form, NOT the POSIX
    # ``setsid``/``&`` fork form.
    let spec = cachePushSpawnCommand(wtWindows, "C:\\repro.exe",
      "C:\\ws\\repo", "myworkspace")
    check spec.targetOs == wtWindows
    check spec.shellInvocation.len > 0
    check spec.detach == "start /b"
    check spec.shellInvocation.contains("start /b")
    # It re-invokes the cache-push entry point with the right args.
    check spec.shellInvocation.contains("hooks")
    check spec.shellInvocation.contains("cache-push")
    check spec.shellInvocation.contains("myworkspace")
    # Crucially it must NOT be the POSIX form (this is the regression guard:
    # if Windows fell back to the POSIX ``setsid … &`` it would fail here).
    check not spec.shellInvocation.contains("setsid")
    check not spec.shellInvocation.contains("/dev/null")
    check not spec.shellInvocation.endsWith("&")

  test "test_ra19_cache_push_posix_keeps_setsid_fork_form_unchanged":
    # POSIX target → existing ``setsid … &`` detached form (no regression).
    let spec = cachePushSpawnCommand(wtPosix, "/usr/bin/repro",
      "/ws/repo", "myworkspace")
    check spec.targetOs == wtPosix
    check spec.shellInvocation.len > 0
    check spec.detach == "setsid&"
    check spec.shellInvocation.startsWith("setsid ")
    check spec.shellInvocation.contains("/dev/null")
    check spec.shellInvocation.endsWith("&")
    check spec.shellInvocation.contains("cache-push")
    check spec.shellInvocation.contains("myworkspace")
    # And it must NOT be the Windows form.
    check not spec.shellInvocation.contains("start /b")

  test "test_ra19_cache_push_empty_inputs_produce_no_invocation":
    # No workspace name (or no exe) → nothing to launch, on either target.
    let noName = cachePushSpawnCommand(wtWindows, "C:\\repro.exe",
      "C:\\ws\\repo", "")
    check noName.shellInvocation.len == 0
    let noExe = cachePushSpawnCommand(wtPosix, "", "/ws/repo", "myworkspace")
    check noExe.shellInvocation.len == 0

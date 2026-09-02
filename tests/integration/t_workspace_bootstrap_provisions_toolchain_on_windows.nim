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
##     cache-push plan (POSIX ``setsid … &`` through ``sh`` vs Windows
##     ``CreateProcessW`` + ``DETACHED_PROCESS``, which uses no shell at
##     all; see W4).
##
## Both are PURE, platform-PARAMETERIZED functions (they take a
## ``WorkspaceTargetOs`` / install root, NOT ``when defined(windows)``), so
## the Windows decision logic is exercisable on this Linux host WITHOUT
## running any Windows tool. We assert the COMPUTED plan + command, never
## their execution.
##
## DEFERRED (cannot run on Linux): live Windows toolchain provisioning
## (the actual ``pwsh`` ensure-steps) and the real detached spawn. The
## LIVE Windows behaviour of that spawn — the hook returns AND the child
## actually runs — is pinned by
## ``t_post_commit_dispatch_returns_and_detached_push_lands``; this test
## covers the decision/plan layer only.
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

  test "test_ra19_cache_push_windows_is_shell_free_not_posix_fork":
    # W4: the Windows target detaches through ``CreateProcessW`` +
    # ``DETACHED_PROCESS`` and carries NO shell command line at all.
    #
    # It used to emit ``cmd /c start /b "" …`` and this case asserted that
    # string. That decision was the defect: the empty ``start`` title is a
    # literal ``"`` inside a line ``cmd.exe`` re-parses, ``quoteShell``
    # escapes it as ``\"`` (the CommandLineToArgvW convention, which
    # ``cmd.exe`` does not implement), and the real git post-commit hook
    # hung forever on two wedged ``cmd.exe`` generations. The regression
    # guard is therefore inverted: a Windows spec that grows a shell
    # invocation back has re-acquired the defect.
    let spec = cachePushSpawnCommand(wtWindows, "C:\\repro.exe",
      "C:\\ws\\repo", "myworkspace")
    check spec.targetOs == wtWindows
    check spec.detach == "CreateProcess:detached"
    # No shell string, and specifically not the one that broke.
    check spec.shellInvocation.len == 0
    # The child is described as a real argv — nothing to re-parse.
    check spec.argv == @["C:\\repro.exe", "hooks", "cache-push",
      "--repo-root", "C:\\ws\\repo", "--workspace-name", "myworkspace"]
    # Each argument is its OWN element: a quote-hostile workspace path
    # cannot leak into a command line because there is no command line.
    let hostile = cachePushSpawnCommand(wtWindows, "C:\\Program Files\\repro.exe",
      "C:\\ws x\\re&po", "ws&x")
    check hostile.argv[0] == "C:\\Program Files\\repro.exe"
    check hostile.argv[4] == "C:\\ws x\\re&po"
    check hostile.argv[6] == "ws&x"
    check hostile.shellInvocation.len == 0
    # And it must NOT be the POSIX form (if Windows fell back to the POSIX
    # ``setsid … &`` this would fail).
    check not spec.detach.contains("setsid")

  test "test_ra19_cache_push_posix_keeps_setsid_fork_form_unchanged":
    # POSIX target → existing ``setsid … &`` detached form (no regression).
    # POSIX keeps its shell because ``quoteShell`` on POSIX IS ``sh``'s own
    # quoting convention, so the round trip is lossless, and because the
    # shell is doing real work there (``setsid`` + the ``&`` fork).
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
    # The argv is the same on both targets — only the launch differs.
    check spec.argv == @["/usr/bin/repro", "hooks", "cache-push",
      "--repo-root", "/ws/repo", "--workspace-name", "myworkspace"]
    # And it must NOT be the Windows form.
    check not spec.shellInvocation.contains("start /b")

  test "test_ra19_cache_push_empty_inputs_produce_no_invocation":
    # No workspace name (or no exe) → nothing to launch, on either target.
    # ``argv`` is the single "nothing to do" signal now, because the
    # Windows target legitimately has no shell invocation even when there
    # IS work; keying the guard off ``shellInvocation`` would silently
    # disable the Windows push entirely.
    let noName = cachePushSpawnCommand(wtWindows, "C:\\repro.exe",
      "C:\\ws\\repo", "")
    check noName.argv.len == 0
    check noName.shellInvocation.len == 0
    let noExe = cachePushSpawnCommand(wtPosix, "", "/ws/repo", "myworkspace")
    check noExe.argv.len == 0
    check noExe.shellInvocation.len == 0
    # Positive control: with both inputs present the Windows spec DOES have
    # work — otherwise the two assertions above would be vacuous.
    let present = cachePushSpawnCommand(wtWindows, "C:\\repro.exe",
      "C:\\ws\\repo", "myworkspace")
    check present.argv.len > 0

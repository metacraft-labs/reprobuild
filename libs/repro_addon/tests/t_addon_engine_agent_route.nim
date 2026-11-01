## The full engine's `repro deploy-agent` on an add-on host never applies
## outside the A8 rules (ReproOS Add-On Mode §9, owner decision 29).
##
## ``engineAgentRoute`` is the one decision `runDeployAgentCommand` takes
## before it builds its apply hook. Before this test existed, an agent
## started with the add-on's own state directory as its ``--state-dir`` on an
## add-on host fell through to the plain `repro infra apply` hook: no v3
## attestation block, the profile compiled in the root process, no
## management-path, managed-prefix or compiled-profile pin check. That
## configuration is now refused, under every spelling of the same directory.
##
## Falsifier: ``-d:reproAddonMutation=engine-agent-shares-addon-state``
## restores the fall-through (``scripts/run_addon_unit_mutation.sh
## t_addon_engine_agent_route engine-agent-shares-addon-state``), and the
## refusal cases below go red.
##
## *Mocking.* None. An add-on host is recognised by the ledger copy in its
## state directory (``isAddonHost``), which a test writes on the real
## filesystem; the route reads nothing else.

import std/[os, tempfiles, unittest]

import repro_addon/addon_apply
import repro_addon/agent_switch
import repro_addon/ledger

proc fakeAddonHost(stateDir: string) =
  createDir(stateDir)
  writeLedger(ledgerCopyPath(stateDir), Ledger(generation: "", entries: @[]))

suite "the engine agent's route on an add-on host":
  test "not an add-on host: the ordinary apply":
    let tmp = createTempDir("engine-agent-route-plain-", "")
    defer: removeDir(tmp)
    check engineAgentRoute(tmp / "system", tmp / "agent") == earPlainApply
    check engineAgentRoute(tmp / "system", tmp / "system") == earPlainApply

  test "an add-on host with an agent state of its own: the add-on switch":
    let tmp = createTempDir("engine-agent-route-switch-", "")
    defer: removeDir(tmp)
    fakeAddonHost(tmp / "system")
    check engineAgentRoute(tmp / "system", tmp / "agent") == earAddonSwitch
    # A directory inside the add-on's is still the agent's own.
    check engineAgentRoute(tmp / "system", tmp / "system" / "agent") ==
      earAddonSwitch

  test "the add-on's own state directory as the agent's: refused":
    let tmp = createTempDir("engine-agent-route-shared-", "")
    defer: removeDir(tmp)
    let addonState = tmp / "system"
    fakeAddonHost(addonState)
    check engineAgentRoute(addonState, addonState) == earRefuseSharedState
    # The same directory spelled differently: a trailing slash, a `.`
    # segment, a `..` round trip, and a symbolic link to it.
    check engineAgentRoute(addonState, addonState & "/") ==
      earRefuseSharedState
    check engineAgentRoute(addonState, tmp / "." / "system") ==
      earRefuseSharedState
    check engineAgentRoute(addonState, tmp / "system" / ".." / "system") ==
      earRefuseSharedState
    createSymlink(addonState, tmp / "alias")
    check engineAgentRoute(addonState, tmp / "alias") == earRefuseSharedState

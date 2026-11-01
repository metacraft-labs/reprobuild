## ``t_addon_agent_refuses_a_pin_not_for_addon``: an add-on agent applies a
## pinned source profile only when the pin selects the add-on mode (A12
## review finding 12; Deploy-Agent.md §"The compiled-profile pin"; ReproOS
## Add-On Mode §8.2).
##
## An add-on host realises the add-on projection only. A pin with no system
## selection was compiled for ``default`` realised in full, and one whose
## mode is ``full`` for a full host; neither is what this host may apply,
## whatever its compile reproduces. ``compiledProfileCheck`` -- the check
## both add-on agent paths (the fetch/apply units and the engine's add-on
## switch) run on a compile -- refuses them with ``EAddOnCompiledProfile``
## before it compares digests, and accepts ``addOn`` with no activity (the
## add-on default) and ``addOn`` with activities when the compile matches.
##
## Falsifying build: ``-d:reproAddonMutation=addon-agent-accepts-full-pin``
## turns the two refusals off, and the test goes red.
##
## *Mocking.* None: the production check on real manifests and real digests.

import std/[strutils, unittest]

import repro_deploy_agent/manifest
import repro_addon/agent_checks

const
  Canonical = "fs.systemFile {\n  path = \"/etc/a12-pin\"\n}\n"
  Actions = "[]"
  Revision = "rev-a12"

proc pinned(mode: string; activities: seq[string]): DeployManifest =
  ## A manifest whose pin is the honest digest of the compile above for
  ## this selection.
  var pin = CompiledProfilePin(compilerRevision: Revision, platform: "linux",
    arch: "x86_64", host: "addon-host", systemMode: mode,
    systemActivities: activities)
  pin.digest = compiledProfileDigest(Canonical, Actions,
                                     systemSelectionText(pin))
  DeployManifest(target: "addon-host", sequence: 1, deploymentId: "d",
                 profileText: "import repro_profile\n", compiledProfile: pin)

suite "an add-on agent applies only a pin for the add-on mode":
  test "the add-on default and an add-on selection are accepted":
    check compiledProfileCheck(pinned("addOn", @[]), Canonical, Actions,
                               Revision) == ""
    check compiledProfileCheck(pinned("addOn", @["web"]), Canonical, Actions,
                               Revision) == ""

  test "a pin with no selection is refused before its digest is compared":
    let why = compiledProfileCheck(pinned("", @[]), Canonical, Actions,
                                   Revision)
    checkpoint why
    check why.startsWith(CompiledProfileRefusal)
    check "names no system selection" in why

  test "a pin for mode full is refused, with or without activities":
    for acts in [@["web"], @["backup", "web"]]:
      let why = compiledProfileCheck(pinned("full", acts), Canonical, Actions,
                                     Revision)
      checkpoint why
      check why.startsWith(CompiledProfileRefusal)
      check "system mode is 'full'" in why

  test "an add-on pin whose compile does not reproduce it is still refused":
    let why = compiledProfileCheck(pinned("addOn", @[]), Canonical & "x",
                                   Actions, Revision)
    check why.startsWith(CompiledProfileRefusal)
    check "digest mismatch" in why

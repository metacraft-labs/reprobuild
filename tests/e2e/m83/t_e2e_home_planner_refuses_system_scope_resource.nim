## A home profile that declares a system-scope resource is refused by the home
## planner, naming the resource, instead of planning without it -- and the
## converse: a system profile that declares a home-scope resource is refused
## by the system planner (`repro infra plan`).
##
## The defect this pins (reprobuild-pm
## issues/2026-10-14-home-planner-silently-drops-a-system-scope-resource.md):
## the home adapter skipped every resource kind it did not list as home-scope,
## so a profile declaring `fsSystemFile(path = "/etc/...")` exported and
## planned with exit 0, `evaluation.resources` silently omitted the file and
## the plan previewed nothing for it -- a declaration that never takes effect
## while the run reports success (Core-Invariants.md §Unrecognised Input Is
## Rejected, Not Skipped).
##
## Primary assertion -- `e2e_home_planner_refuses_system_scope_resource`:
## the same profile through `repro home export` (with and without `--target`)
## and `repro home plan` exits non-zero, and the diagnostic names the kind,
## the resource's address and that it is system-scope.
##
## Vacuity guard: the control profile -- identical but for the system-scope
## line -- exports and plans with exit 0, so the refusal is caused by that
## resource and not by anything else in the profile; the control's export
## carries its home-scope resource.
##
## Second assertion -- `e2e_system_planner_refuses_home_scope_resource`:
## `repro infra plan --profile` of a system profile declaring a
## `homebrewCask` (what dotfiles' `system_mac.nim` used to do) exits
## non-zero naming the resource and that it is home-scope; the same profile
## without that line plans with exit 0 (vacuity guard). Planning reads the
## live system but changes nothing, and needs no elevation.
##
## Falsifying mutations (performed 2026-10-14): `buildResourcesBlock`
## (`adapter_home.nim`) skipping the non-home kinds again, as it did before
## the fix -- every home refusal check fails (export exit 0) while the
## control stays green; `profileIntentToSystemProfile` (`adapter_system.nim`)
## skipping the non-system kinds again -- the system refusal check fails
## (plan exit 0) while its control stays green.
##
## No mocks: real `build/bin/repro`, real Nim, real filesystem, isolated
## sandbox (harness header). Nothing is applied.
##
## Platforms: every host.

import std/[json, os, strutils, unittest]

import ./profile_compile_edge_harness

const ControlProfile = """
import repro_profile

profile "scopeControl":
  activity default:
    ripgrep
  resources:
    envUserVariable(name = "EDITOR", value = "nvim")
"""

const MisplacedProfile = """
import repro_profile

profile "scopeMisplaced":
  activity default:
    ripgrep
  resources:
    envUserVariable(name = "EDITOR", value = "nvim")
    fsSystemFile(path = "/etc/gm-scope.conf", content = "y")
"""

proc checkNamesTheResource(diagnostic: string) =
  check "fs.systemFile" in diagnostic
  check "/etc/gm-scope.conf" in diagnostic
  check "system-scope" in diagnostic
  check "repro infra apply" in diagnostic

suite "the home planner refuses a system-scope resource":

  test "e2e_home_planner_refuses_system_scope_resource":
    block control:
      let sb = newProfileSandbox("scope-control", ControlProfile)
      defer: sb.dispose()
      let exported = sb.runRepro(["home", "export", "--host", "m1"], host = "")
      checkpoint("control export stderr:\n" & exported.stderr)
      require exported.exitCode == 0
      let doc = parseJson(exported.stdout)
      check doc["intent"]["resources"].len == 1
      check doc["intent"]["resources"][0]["kind"].getStr == "env.userVariable"
      let plan = sb.runHomePlan()
      checkpoint("control plan:\n" & plan.output)
      check plan.exitCode == 0

    let sb = newProfileSandbox("scope-misplaced", MisplacedProfile)
    defer: sb.dispose()

    let exported = sb.runRepro(["home", "export", "--host", "m1"], host = "")
    checkpoint("export stdout:\n" & exported.stdout)
    checkpoint("export stderr:\n" & exported.stderr)
    check exported.exitCode != 0
    checkNamesTheResource(exported.stderr)

    let targeted = sb.runRepro(["home", "export", "--host", "m1", "--target",
      "x86_64-linux"], host = "")
    checkpoint("export --target stderr:\n" & targeted.stderr)
    check targeted.exitCode != 0
    checkNamesTheResource(targeted.stderr)

    let plan = sb.runHomePlan()
    checkpoint("plan:\n" & plan.output)
    check plan.exitCode != 0
    checkNamesTheResource(plan.output)

const SystemControlProfile = """
import repro_profile

profile "scopeSystemControl":
  resources:
    fsSystemFile(path = "/etc/gm-scope-system.conf", content = "y")
"""

const SystemMisplacedProfile = """
import repro_profile

profile "scopeSystemMisplaced":
  resources:
    fsSystemFile(path = "/etc/gm-scope-system.conf", content = "y")
    homebrewCask(name = "ghostty")
"""

suite "the system planner refuses a home-scope resource":

  test "e2e_system_planner_refuses_home_scope_resource":
    # The sandbox's own `home.nim` is not used here; each case writes a
    # system profile beside it and names it with `--profile`.
    let sb = newProfileSandbox("scope-system", ControlProfile)
    defer: sb.dispose()
    sb.writeProfileFile("system_control.nim", SystemControlProfile)
    sb.writeProfileFile("system_misplaced.nim", SystemMisplacedProfile)
    let stateDir = sb.root / "infra-state"

    let control = sb.runRepro(["infra", "plan", "--state-dir", stateDir,
      "--profile", sb.profileDir / "system_control.nim"], host = "")
    checkpoint("control plan stdout:\n" & control.stdout)
    checkpoint("control plan stderr:\n" & control.stderr)
    check control.exitCode == 0

    let misplaced = sb.runRepro(["infra", "plan", "--state-dir", stateDir,
      "--profile", sb.profileDir / "system_misplaced.nim"], host = "")
    checkpoint("plan stdout:\n" & misplaced.stdout)
    checkpoint("plan stderr:\n" & misplaced.stderr)
    check misplaced.exitCode != 0
    check "pkg.homebrewCask" in misplaced.stderr
    check "ghostty" in misplaced.stderr
    check "home-scope" in misplaced.stderr
    check "repro home apply" in misplaced.stderr

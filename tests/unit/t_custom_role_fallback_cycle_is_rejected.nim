## custom_role_fallback_cycle_is_rejected — and a dangling `fallback`
## (Workspace-Branch-Roles.md §9).
##
## §2.4: a custom role's `fallback` names a built-in or another custom role,
## and following `fallback` links from any role must reach `mainline` without
## a cycle; a cycle or a dangling name is a validation error naming the
## settings file and the chain. §3.5: the failure is reported when the
## manifest is LOADED and the workspace does not resolve.
##
## Legs, each against a real `repro-workspace.toml`:
##   1. positive control — `beta -> rc -> stable` loads and resolves;
##   2. PRIMARY (cycle) — `alpha -> omega -> alpha` is refused by the settings
##      reader, naming the file, `branch-roles.alpha.fallback` and the chain;
##      and resolving a project in that workspace is refused the same way;
##   3. a role that falls back to itself is a cycle too;
##   4. PRIMARY (dangling) — `beta -> gamma`, with no `gamma` anywhere, is
##      refused naming the file, `branch-roles.beta.fallback` and `gamma`;
##      and so is the project load.
##
## Mutation-checked in roles.nim `validateRoleSettings`: (a) skipping the
## fallback walk fails legs 2–4 on "expected a refusal"; (b) letting a
## dangling name end the walk instead of raising fails leg 4 only.
##
## No mocks: real files, the real settings reader and resolver.

import std/[os, strutils, unittest]

import repro_workspace_manifests
import ./branch_roles_fixture

proc settingsRefusal(fx: RolesFixture): ref WorkspaceManifestParseError =
  refusal(proc () = discard readWorkspaceSettings(fx.settingsPath))

proc loadRefusal(fx: RolesFixture): ref WorkspaceManifestParseError =
  refusal(proc () = discard fx.resolveDemo())

suite "custom_role_fallback_cycle_is_rejected":

  test "custom_role_fallback_cycle_is_rejected":
    var fx = newRolesFixture("repro-role-cycle-")
    defer: fx.dispose()
    fx.addRepo("core", "mainline = \"dev\"")

    # 1. Positive control: a chain through a custom role to a built-in.
    fx.writeSettings("[branch-roles.beta]\nfallback = \"rc\"\n\n" &
      "[branch-roles.rc]\nfallback = \"stable\"\n")
    check fx.settingsRefusal().isNil
    let ok = fx.resolveDemo().repo("core")
    check ok.role("beta").branch == "dev"
    check ok.role("beta").fallbackPath == @["beta", "rc", "stable", "mainline"]

    # 2. PRIMARY: a two-role cycle.
    fx.writeSettings("[branch-roles.alpha]\nfallback = \"omega\"\n\n" &
      "[branch-roles.omega]\nfallback = \"alpha\"\n")
    let cycle = fx.settingsRefusal()
    check not cycle.isNil
    if not cycle.isNil:
      checkpoint(cycle.msg)
      check cycle.path == fx.settingsPath
      check cycle.keyPath == "branch-roles.alpha.fallback"
      check "alpha -> omega -> alpha" in cycle.msg
    let cycleLoad = fx.loadRefusal()
    check not cycleLoad.isNil
    if not cycleLoad.isNil:
      check cycleLoad.path == fx.settingsPath
      check cycleLoad.keyPath == "branch-roles.alpha.fallback"

    # 3. A role that falls back to itself.
    fx.writeSettings("[branch-roles.loop]\nfallback = \"loop\"\n")
    let selfCycle = fx.settingsRefusal()
    check not selfCycle.isNil
    if not selfCycle.isNil:
      check selfCycle.keyPath == "branch-roles.loop.fallback"
      check "loop -> loop" in selfCycle.msg

    # 4. PRIMARY: a dangling fallback.
    fx.writeSettings("[branch-roles.beta]\nfallback = \"gamma\"\n")
    let dangling = fx.settingsRefusal()
    check not dangling.isNil
    if not dangling.isNil:
      checkpoint(dangling.msg)
      check dangling.path == fx.settingsPath
      check dangling.keyPath == "branch-roles.beta.fallback"
      check "'gamma'" in dangling.msg
      check "beta -> gamma" in dangling.msg
    let danglingLoad = fx.loadRefusal()
    check not danglingLoad.isNil
    if not danglingLoad.isNil:
      check danglingLoad.path == fx.settingsPath
      check danglingLoad.keyPath == "branch-roles.beta.fallback"

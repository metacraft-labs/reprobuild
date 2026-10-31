## false_declares_absence (Workspace-Branch-Roles.md §9).
##
## §3.1: a role's value is a branch name or `false`, and `false` declares the
## tier ABSENT for this repo, so the role falls back exactly as if nothing had
## declared it. §3.3: the first declarer that declares the role wins — and
## `false` is a declaration — so a fragment's `unstable = false` overrides the
## `unstable = "agents"` of the profile it names, instead of letting the
## profile's value through. That is how a product repo that has no `agents`
## branch says so while its profile declares one.
##
## Legs:
##   1. positive control — the same profile without the fragment's `false`
##      resolves `unstable` to `agents`, from the profile;
##   2. PRIMARY — with `unstable = false` in the fragment, `unstable` falls
##      back to the mainline (`dev`, which the profile supplies), with the
##      path `unstable -> mainline`;
##   3. the same through the workspace DEFAULT profile, for a fragment that
##      names no profile;
##   4. `false` in a profile declares the tier absent for every repo
##      following it.
##
## Mutation-checked by making `false` fall through to the next declarer
## (`resolveRole`'s `brvAbsent` arm in roles.nim `discard` instead of
## `break`): leg 2 then resolves `agents` and fails its primary assertion.
##
## No mocks: real files, the real reader and resolver.

import std/[os, unittest]

import repro_workspace_manifests
import ./branch_roles_fixture

suite "false_declares_absence":

  test "false_declares_absence":
    var fx = newRolesFixture("repro-role-false-")
    defer: fx.dispose()
    fx.writeSettings(
      "[workspace]\ndefault_profile = \"product\"\n\n" &
      "[profiles.product]\nmainline = \"dev\"\nunstable = \"agents\"\n\n" &
      "[profiles.quiet]\nmainline = \"trunk\"\nunstable = false\n")
    fx.addRepo("follows", "profile = \"product\"")
    fx.addRepo("opts-out", "profile = \"product\"\nunstable = false")
    fx.addRepo("default-opts-out", "unstable = false")
    fx.addRepo("quiet", "profile = \"quiet\"")
    let project = fx.resolveDemo()

    # 1. Positive control: the profile's `unstable` applies.
    let follows = project.repo("follows")
    check follows.role("unstable").branch == "agents"
    check follows.role("unstable").declaredBy == rdkProfile
    check follows.role("unstable").profile == "product"

    # 2. PRIMARY: the fragment's `false` beats the profile's `agents`.
    let optsOut = project.repo("opts-out")
    check optsOut.role("unstable").branch == "dev"
    check optsOut.role("unstable").resolvedRole == "mainline"
    check optsOut.role("unstable").fallbackPath == @["unstable", "mainline"]
    check optsOut.role("unstable").declaredBy == rdkProfile
    check optsOut.branch == "dev"

    # 3. The same against the workspace default profile.
    let defaultOptsOut = project.repo("default-opts-out")
    check defaultOptsOut.profile == "product"
    check defaultOptsOut.role("unstable").branch == "dev"
    check defaultOptsOut.role("unstable").fallbackPath ==
      @["unstable", "mainline"]
    check defaultOptsOut.role("unstable").declaredBy == rdkDefaultProfile

    # 4. `false` in a named profile: absent for its followers.
    let quiet = project.repo("quiet")
    check quiet.role("unstable").branch == "trunk"
    check quiet.role("unstable").fallbackPath == @["unstable", "mainline"]

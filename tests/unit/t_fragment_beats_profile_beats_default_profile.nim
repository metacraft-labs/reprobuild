## fragment_beats_profile_beats_default_profile (Workspace-Branch-Roles.md §9).
##
## §3.3's resolution order: for a repo R and a role T, the first of
##   1. R's fragment,
##   2. the profile R names,
##   3. the workspace default profile, WHEN R NAMES NONE,
## that declares T wins. The fixture declares two profiles that disagree on
## every role and makes one of them the default:
##
##   * `inherits-default` names no profile: every role comes from the default
##     profile (`main` / `next` / `release`);
##   * `names-product` names `product`: its roles come from `product`, and the
##     default profile is NOT consulted at all — `product` declares no
##     `stable`, so `stable` falls back to `product`'s mainline rather than
##     picking up the default profile's `release`;
##   * `overrides` names `product` and declares its own `unstable` and
##     `stable`: those win over the profile, while `mainline` still comes
##     from the profile;
##   * the resolved mainline is what `ResolvedRepo.branch` and (no pin being
##     declared) `revision` carry, whichever declarer supplied it.
##
## Primary assertions: `overrides`' `unstable` is the fragment's, and
## `names-product`' `stable` is NOT the default profile's. Mutation-checked
## twice in roles.nim: (a) consulting the profile before the fragment in
## `fragmentDeclarers` fails the `overrides` assertions; (b) applying the
## default profile even when the fragment names one fails the
## `names-product` `stable` assertion.
##
## No mocks: real files, the real reader and resolver.

import std/[os, unittest]

import repro_workspace_manifests
import ./branch_roles_fixture

suite "fragment_beats_profile_beats_default_profile":

  test "fragment_beats_profile_beats_default_profile":
    var fx = newRolesFixture("repro-role-order-")
    defer: fx.dispose()
    fx.writeSettings(
      "[workspace]\ndefault_profile = \"base\"\n\n" &
      "[profiles.base]\nmainline = \"main\"\nunstable = \"next\"\n" &
      "stable = \"release\"\n\n" &
      "[profiles.product]\nmainline = \"dev\"\nunstable = \"agents\"\n")
    fx.addRepo("inherits-default", "")
    fx.addRepo("names-product", "profile = \"product\"")
    fx.addRepo("overrides",
      "profile = \"product\"\nunstable = \"mine\"\nstable = \"shipped\"")
    let project = fx.resolveDemo()

    # 3. No profile named: the default profile supplies every role.
    let d = project.repo("inherits-default")
    check d.profile == "base"
    check d.role("mainline").branch == "main"
    check d.role("mainline").declaredBy == rdkDefaultProfile
    check d.role("unstable").branch == "next"
    check d.role("stable").branch == "release"
    check d.role("production").branch == "release"
    check d.branch == "main"
    check d.revision == "main"

    # 2. A named profile replaces the default profile entirely.
    let p = project.repo("names-product")
    check p.profile == "product"
    check p.role("mainline").branch == "dev"
    check p.role("mainline").declaredBy == rdkProfile
    check p.role("unstable").branch == "agents"
    # PRIMARY: the default profile's `release` does not leak in.
    check p.role("stable").branch == "dev"
    check p.role("stable").fallbackPath == @["stable", "mainline"]
    check p.branch == "dev"
    check p.revision == "dev"

    # 1. The fragment beats the profile it names.
    let o = project.repo("overrides")
    # PRIMARY: the fragment's value, not the profile's `agents`.
    check o.role("unstable").branch == "mine"
    check o.role("unstable").declaredBy == rdkFragment
    check o.role("stable").branch == "shipped"
    check o.role("production").branch == "shipped"
    check o.role("production").fallbackPath == @["production", "stable"]
    check o.role("mainline").branch == "dev"
    check o.role("mainline").declaredBy == rdkProfile
    check o.branch == "dev"

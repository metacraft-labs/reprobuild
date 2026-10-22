## role_falls_back_toward_mainline (Workspace-Branch-Roles.md §9).
##
## §2.2: when a repo does not declare a role, the role resolves to its
## neighbour on the mainline side, recursively — `unstable`, `staging` and
## `stable` to `mainline`; `production` and `lts` to `stable` — so every chain
## ends at `mainline`. The claim under test:
##
##   * a repo declaring ONLY `mainline` resolves every built-in role to it,
##     and `production` (and `lts`) reach it THROUGH `stable`: the recorded
##     fallback path is `production -> stable -> mainline`, not a direct edge;
##   * a repo that declares `stable` resolves `production` to `stable`'s
##     branch, one edge, and leaves `unstable` on the mainline;
##   * a declared custom role with no declaration anywhere falls back along
##     its `fallback` to the same end;
##   * `ResolvedRepo.branch` (what every existing consumer reads) is the
##     resolved mainline, and so is `revision` when nothing pins one.
##
## Primary assertion: the `production` fallback path. Mutation-checked by
## re-pointing `production`'s built-in edge straight at `mainline`
## (`builtinFallback` in roles.nim): the branch is still `dev` but the path
## loses `stable` and this test fails on it.
##
## No mocks: real files, the real reader and resolver (see
## branch_roles_fixture.nim, which also points every repo at a remote that
## does not exist, so a resolver that consulted the remote would fail here).

import std/[os, unittest]

import repro_workspace_manifests
import ./branch_roles_fixture

suite "role_falls_back_toward_mainline":

  test "role_falls_back_toward_mainline":
    var fx = newRolesFixture("repro-role-fallback-")
    defer: fx.dispose()
    fx.writeSettings("[branch-roles.beta]\nfallback = \"stable\"\n")
    fx.addRepo("only-mainline", "mainline = \"dev\"")
    fx.addRepo("with-stable", "mainline = \"dev\"\nstable = \"release\"")
    let project = fx.resolveDemo()

    let r = project.repo("only-mainline")
    # Positive control: the declared role is declared, not fallen back to.
    check r.role("mainline").branch == "dev"
    check r.role("mainline").fallbackPath == @["mainline"]
    check r.role("mainline").declaredBy == rdkFragment

    # Every built-in resolves to the mainline.
    for role in builtinRoleOrder:
      check r.role(role).branch == "dev"
      check r.role(role).resolvedRole == "mainline"

    # PRIMARY: production and lts reach the mainline THROUGH stable.
    check r.role("production").fallbackPath ==
      @["production", "stable", "mainline"]
    check r.role("lts").fallbackPath == @["lts", "stable", "mainline"]
    check r.role("unstable").fallbackPath == @["unstable", "mainline"]
    check r.role("staging").fallbackPath == @["staging", "mainline"]
    check r.role("stable").fallbackPath == @["stable", "mainline"]

    # A custom role nobody declares follows its `fallback` to the same end.
    check r.role("beta").branch == "dev"
    check r.role("beta").fallbackPath == @["beta", "stable", "mainline"]

    # Every built-in and every declared custom role is carried.
    check r.roles.len == builtinRoleOrder.len + 1

    # What every existing consumer reads is the resolved mainline.
    check r.branch == "dev"
    check r.revision == "dev"

    # A declared `stable` stops `production` one edge away.
    let s = project.repo("with-stable")
    check s.role("production").branch == "release"
    check s.role("production").resolvedRole == "stable"
    check s.role("production").fallbackPath == @["production", "stable"]
    check s.role("lts").branch == "release"
    check s.role("unstable").branch == "dev"
    check s.role("beta").branch == "release"
    check s.branch == "dev"

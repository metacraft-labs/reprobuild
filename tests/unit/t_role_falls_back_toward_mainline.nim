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

  test "workspace branch defaults to root declarations independently of repos":
    # Every case resolves real manifests. A member repo's product profile must
    # never become the root's workspace default merely because it resolves first.
    for (rootKeys, expected) in [
        ("mainline = \"root-direct\"\nprofile = \"root\"", "root-direct"),
        ("profile = \"root\"", "root-profile"),
        ("default_profile = \"root\"", "root-profile"),
        ("", "")]:
      var fx = newRolesFixture("repro-workspace-default-")
      defer: fx.dispose()
      fx.writeSettings("[workspace]\n" & rootKeys &
        "\n[profiles.root]\nmainline = \"root-profile\"\n" &
        "[profiles.product]\nmainline = \"member-mainline\"\n")
      fx.addRepo("core", "profile = \"product\"")
      let project = fx.resolveDemo()
      check project.workspaceMainline == expected
      check project.defaultWorkspaceBranch == expected
      check project.repo("core").branch == "member-mainline"

      # Explicit trunk is retained in the source-facing field and overrides
      # the root for every consumer of the effective workspace default.
      let path = fx.projectFile()
      writeFile(path, readFile(path) & "trunk = \"legacy-trunk\"\n")
      let legacy = resolveProject(path)
      check legacy.workspaceMainline == expected
      check legacy.trunk == "legacy-trunk"
      check legacy.defaultWorkspaceBranch == "legacy-trunk"

  test "repo sets and variants carry the same root workspace default":
    var fx = newRolesFixture("repro-workspace-default-forms-")
    defer: fx.dispose()
    fx.writeSettings("[workspace]\nmainline = \"root-dev\"\n" &
      "[profiles.member]\nmainline = \"member-mainline\"\n")
    fx.addRepo("core", "mainline = \"member-mainline\"")
    discard fx.projectFile()
    createDir(fx.root / "repo-sets")
    let setPath = fx.root / "repo-sets" / "all.toml"
    writeFile(setPath, "schema = \"reprobuild.workspace.repo-set.v1\"\n" &
      "member_repos = [\"core\"]\n[repo-set]\nname = \"all\"\n")
    check resolveRepoSet(setPath).defaultWorkspaceBranch == "root-dev"
    createDir(fx.root / "variants")
    let variantPath = fx.root / "variants" / "local.toml"
    writeFile(variantPath, "schema = \"reprobuild.workspace.variant.v1\"\n" &
      "[variant]\nname = \"local\"\nbase = \"projects/demo.toml\"\n")
    check resolveVariant(variantPath).defaultWorkspaceBranch == "root-dev"

    # Composition carries the root policy across real local_path layers.
    # The external layer declares deliberately conflicting root/profile
    # settings: neither may replace the workspace root's policy.
    var layer = newRolesFixture("repro-workspace-default-layer-")
    defer: layer.dispose()
    layer.writeSettings("[workspace]\nmainline = \"layer-root-wrong\"\n" &
      "[profiles.member]\nmainline = \"layer-member-wrong\"\n")
    layer.addRepo("extra", "profile = \"member\"")
    discard layer.projectFile()
    let local = WorkspaceLocal(workspace: WorkspaceBody(project: "demo"),
      manifest: @[ManifestLayer(local_path: some(fx.root), visibility: "public"),
                  ManifestLayer(local_path: some(layer.root), visibility: "public")])
    let composed = composeManifestLayers(local, fx.root)
    check composed.trunk == ""
    # Mutation control: removing only the composer's workspaceMainline copy
    # fails these default assertions while both member mainlines remain valid.
    check composed.workspaceMainline == "root-dev"
    check composed.defaultWorkspaceBranch == "root-dev"
    check composed.repos.len == 2
    check composed.repo("core").branch == "member-mainline"
    check composed.repo("extra").branch == "member-mainline"

## The workspace ROOT repository resolves its branch roles from the settings
## file's `[workspace]` table (Workspace-Branch-Roles.md §3.4).
##
## §3.4: the root `repro-workspace` repository's roles are declared in
## `repro-workspace.toml`, in a fragment's shape — `[workspace]`'s own keys,
## then the profile `[workspace] profile` names, else the default profile —
## and resolve by the same procedure as any repo's (§3.3). This replaces the
## old chain that read the root's mainline from the bootstrap
## `[manifest] branch` and then from the root repo's `origin/HEAD`; inferring
## a mainline from `origin/HEAD` is the inference the roles model forbids, and
## the root gets no exemption.
##
## Legs (real settings files read by the real reader):
##   1. `[workspace]` declares `mainline` and `unstable`: the root resolves
##      every role from them, with the fallback edges of §2.2;
##   2. `[workspace] profile` supplies the mainline;
##   3. only `default_profile` is set: it supplies the mainline;
##   4. `[workspace]`'s own `mainline` beats its profile's;
##   5. PRIMARY — a `settings.v1` file that declares NO root mainline: asking
##      for the root's mainline (`rootMainline`, which `repro branch
##      --from-mainlines` reads) RAISES naming the file and
##      `workspace.mainline`; it does not answer `none` (which would let a
##      caller fall through to `origin/HEAD`);
##   6. the old `.repro-workspace.toml` (`bootstrap.v1`) keeps its behaviour:
##      `[manifest] branch` when it has one and the caller has established
##      that the record store is the root repo itself (`legacyStoreIsRoot`),
##      `none` when it has not (the caller then reads `origin/HEAD`, as
##      before). A `settings.v1` file ignores `legacyStoreIsRoot`: it has no
##      `[manifest]` pointer. §3.4's rule applies to
##      the file that can declare `[workspace]`.
##
## Mutation-checked: making `rootMainline` return `none` for a settings.v1
## file that declares no root mainline (the previous behaviour) fails leg 5 on
## "expected a refusal". The CLI half (`repro branch --from-mainlines`
## refusing without consulting `origin/HEAD`) is
## tests/integration/t_role_validation_refused_through_repro.nim.
##
## No mocks: real files, the real settings reader.

import std/[options, os, strutils, tempfiles, unittest]

import repro_workspace_manifests
import ./branch_roles_fixture

proc settingsWith(dir, body: string): WorkspaceSettings =
  let path = dir / "repro-workspace.toml"
  writeFile(path, "schema = \"reprobuild.workspace.settings.v1\"\n\n" & body)
  readWorkspaceSettings(path)

suite "the root repo resolves from [workspace]":

  test "t_root_repo_resolves_from_workspace_settings":
    delEnv("REPRO_WORKSPACE_CONFIG")
    let dir = createTempDir("repro-root-roles-", "")
    defer: removeDir(dir)

    # 1. Explicit keys.
    let explicit = settingsWith(dir,
      "[workspace]\nmainline = \"dev\"\nunstable = \"agents\"\n")
    let roles = resolveRootRoles(explicit)
    check roles.findRole("mainline").get().branch == "dev"
    check roles.findRole("mainline").get().declaredBy == rdkWorkspace
    check roles.findRole("unstable").get().branch == "agents"
    check roles.findRole("production").get().branch == "dev"
    check roles.findRole("production").get().fallbackPath ==
      @["production", "stable", "mainline"]
    check rootMainline(explicit, legacyStoreIsRoot = true) == some("dev")

    # 2. The profile `[workspace] profile` names.
    let viaProfile = settingsWith(dir,
      "[workspace]\nprofile = \"product\"\n\n" &
      "[profiles.product]\nmainline = \"dev\"\nunstable = \"agents\"\n")
    check rootMainline(viaProfile, legacyStoreIsRoot = true) == some("dev")
    check resolveRootRoles(viaProfile).findRole("unstable").get().declaredBy ==
      rdkProfile

    # 3. Only a default profile.
    let viaDefault = settingsWith(dir,
      "[workspace]\ndefault_profile = \"spec\"\n\n" &
      "[profiles.spec]\nmainline = \"latest\"\n")
    check rootMainline(viaDefault, legacyStoreIsRoot = true) == some("latest")
    check resolveRootRoles(viaDefault).findRole("mainline").get().declaredBy ==
      rdkDefaultProfile

    # 4. `[workspace]`'s own key beats its profile.
    let override = settingsWith(dir,
      "[workspace]\nprofile = \"product\"\nmainline = \"trunk\"\n\n" &
      "[profiles.product]\nmainline = \"dev\"\n")
    check rootMainline(override, legacyStoreIsRoot = true) == some("trunk")

    # 5. PRIMARY: no root mainline is an error naming the file and key.
    for body in ["",
                 "[projects]\ndefault = [\"demo\"]\n",
                 "[workspace]\nunstable = \"agents\"\n",
                 "[workspace]\nprofile = \"bare\"\n\n" &
                   "[profiles.bare]\nunstable = \"next\"\n"]:
      let undeclared = settingsWith(dir, body)
      let err = refusal(proc () =
        discard rootMainline(undeclared, legacyStoreIsRoot = true))
      checkpoint("settings body: " & body)
      check not err.isNil
      if not err.isNil:
        checkpoint(err.msg)
        check err.path == dir / "repro-workspace.toml"
        check err.keyPath == "workspace.mainline"
        check "origin/HEAD" in err.msg

    # 6. bootstrap.v1 keeps `[manifest] branch`, then `none`.
    let legacyPath = dir / ".repro-workspace.toml"
    removeFile(dir / "repro-workspace.toml")
    writeFile(legacyPath, "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
      "[manifest]\nurl = \"https://git.example.invalid/acme/ws.git\"\n" &
      "branch = \"latest\"\n")
    check rootMainline(readWorkspaceSettings(legacyPath),
      legacyStoreIsRoot = true) == some("latest")
    writeFile(legacyPath, "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
      "[manifest]\nurl = \"https://git.example.invalid/acme/ws.git\"\n")
    check rootMainline(readWorkspaceSettings(legacyPath),
      legacyStoreIsRoot = true).isNone

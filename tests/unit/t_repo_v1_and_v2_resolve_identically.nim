## A `repo.v1` fragment no longer resolves; its `repo.v2` rewrite does.
##
## Workspace-Branch-Roles.md §3.1 renamed the fragment key `branch` to
## `mainline` under a schema bump (`reprobuild.workspace.repo.v2`, §3.6), and
## §6 step 3 retires reading `repo.v1` once every workspace has rewritten its
## fragments. Until then this test proved the mechanical rewrite changed
## nothing about how a repo resolves; now it proves the other half of the
## retirement through the resolver itself: the SAME project, with the SAME
## fragment written both ways at the same path, fails to load in the retired
## spelling — naming the fragment and the rewrite — and resolves to the
## declared mainline in the current one.
##
## A positive control precedes the refusal: the v2 fragment must resolve the
## branch to `dev`, so the refusal cannot pass because the project itself is
## broken.
##
## No mocks: the fragment and project are real files in a temporary
## directory, resolved through the real reader and resolver.

import std/[options, os, strutils, tempfiles, unittest]

import repro_workspace_manifests

const projectToml = """schema = "reprobuild.workspace.project.v1"

includes = [
  "repos/widget.toml",
]

[project]
name = "demo"

[[remote]]
name = "acme"
fetch = "https://git.example.invalid/acme"
"""

const fragmentV1 = """schema = "reprobuild.workspace.repo.v1"

[repo]
name = "widget"
path = "widget"
remote = "acme"
branch = "dev"
tags = ["tools"]
depends = ["gizmo"]
"""

const fragmentV2 = """schema = "reprobuild.workspace.repo.v2"

[repo]
name = "widget"
path = "widget"
remote = "acme"
mainline = "dev"
tags = ["tools"]
depends = ["gizmo"]
"""

suite "a repo.v1 fragment no longer resolves; its repo.v2 rewrite does":

  test "t_repo_v1_and_v2_resolve_identically":
    let root = createTempDir("repro-repo-v1-v2-", "")
    defer: removeDir(root)
    createDir(root / "projects")
    createDir(root / "repos")
    writeFile(root / "projects" / "demo.toml", projectToml)
    let fragment = root / "repos" / "widget.toml"

    # Positive control: the current spelling resolves to its mainline.
    writeFile(fragment, fragmentV2)
    let v2 = resolveProject(root / "projects" / "demo.toml")
    check v2.repos.len == 1
    check v2.repos[0].branch == "dev"
    check v2.repos[0].revision == "dev"
    check v2.repos[0].tags == @["tools"]
    check readRepoFragment(fragment).repo.mainline == some("dev")

    # Primary assertion: the retired spelling of the same fragment does not
    # load, and the refusal names the file and the rewrite.
    writeFile(fragment, fragmentV1)
    var refused = false
    try:
      discard resolveProject(root / "projects" / "demo.toml")
    except WorkspaceManifestParseError as e:
      refused = true
      check e.path == fragment
      check e.keyPath == "schema"
      check e.observedSchema == "reprobuild.workspace.repo.v1"
      check "reprobuild.workspace.repo.v2" in e.innerMessage
      check "`mainline`" in e.innerMessage
    check refused

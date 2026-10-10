## A `repo.v1` fragment and its `repo.v2` rewrite resolve to the same repo.
##
## Workspace-Branch-Roles.md §3.1 renames the fragment key `branch` to
## `mainline` under a schema bump (`reprobuild.workspace.repo.v2`, §3.6), and
## §6 step 1 requires a `repro` that reads both before any manifest changes.
## The migration that follows rewrites every fragment mechanically —
## `branch` -> `mainline`, schema -> v2 — and is only safe if that rewrite
## changes NOTHING about how the repo resolves. This test is that claim: the
## same project resolves one fragment written both ways, and the two
## `ResolvedRepo` values are compared whole, so any field that resolves
## differently (the tracked branch, the revision it supplies, the fetch URL,
## anything) fails the primary assertion.
##
## A positive control precedes the comparison: both must resolve the branch
## to `dev`, so equality cannot pass vacuously because both lost the value.
##
## No mocks: the fragment and project are real files in a temporary
## directory, resolved through the real reader and resolver. The fragment is
## written to the SAME path both times so `fragmentPath` (an absolute path)
## is equal by construction rather than by excluding it from the comparison.

import std/[options, os, tempfiles, unittest]

import repro_workspace_manifests

const projectToml = """schema = "reprobuild.workspace.project.v1"

includes = [
  "repos/widget.toml",
]

[project]
name = "demo"
default_revision = "main"
trunk = "main"

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

proc resolveWith(root, fragmentText: string): ResolvedRepo =
  writeFile(root / "repos" / "widget.toml", fragmentText)
  let project = resolveProject(root / "projects" / "demo.toml")
  check project.repos.len == 1
  project.repos[0]

suite "repo.v1 and repo.v2 resolve identically":

  test "t_repo_v1_and_v2_resolve_identically":
    let root = createTempDir("repro-repo-v1-v2-", "")
    defer: removeDir(root)
    createDir(root / "projects")
    createDir(root / "repos")
    writeFile(root / "projects" / "demo.toml", projectToml)

    let v1 = resolveWith(root, fragmentV1)
    let v2 = resolveWith(root, fragmentV2)

    # Positive control: the declared mainline reached both.
    check v1.branch == "dev"
    check v2.branch == "dev"
    check v1.revision == "dev"

    # Primary assertion: the whole resolved repo is the same value.
    check v1 == v2

    # And the typed fragments agree on the mainline, whichever key held it.
    let f1 = block:
      writeFile(root / "repos" / "widget.toml", fragmentV1)
      readRepoFragment(root / "repos" / "widget.toml")
    let f2 = block:
      writeFile(root / "repos" / "widget.toml", fragmentV2)
      readRepoFragment(root / "repos" / "widget.toml")
    check f1.repo.mainlineBranch == some("dev")
    check f2.repo.mainlineBranch == some("dev")
    check f1.repo.roleDecls == f2.repo.roleDecls

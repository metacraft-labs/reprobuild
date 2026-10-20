## The manifest editor never leaves a repo fragment in a mix of two schemas.
##
## A `repo.v1` fragment names its mainline `branch`; `repo.v2` names it
## `mainline` and adds the role keys (Workspace-Branch-Roles.md §3.1, §3.6).
## The reader refuses a file that mixes them, so a writer that produced one
## would break the workspace for everyone who reads it. The rule, enforced by
## the editor (`guardFragmentSchema`) rather than by each caller:
##
## * an edit of a key BOTH schemas have (`depends`, `tags`, …) leaves a v1
##   file v1 — byte for byte outside the edited span. Upgrading on every
##   unrelated edit would make an older pinned `repro` refuse the file
##   ("unknown major schema version") because someone ran `repro add`;
## * setting `mainline` on a v1 file writes `branch`, the v1 spelling of the
##   same key, and the file stays v1;
## * writing a key only v2 can say (a role, `profile`, a custom role) into a
##   v1 file upgrades the WHOLE file first — schema line and `branch` ->
##   `mainline` together — in one save;
## * writing `branch` into a v2 file is refused;
## * a NEW fragment that declares a key only v2 can say is written as v2
##   with `mainline`, whatever spelling the typed value used. (One that does
##   not is written as v1: t_repo_fragment_writer_emits_v1_when_v1_can_say_it.)
##
## Every result is read back through the strict reader, so "one schema" is
## checked by the component that would refuse a mix.
##
## No mocks: real files in a temporary directory, the real editor and reader.

import std/[options, os, strutils, tempfiles, unittest]

import repro_workspace_manifests

const v1Fragment = """schema = "reprobuild.workspace.repo.v1"

# Vendored fork; the mainline is where our patches land.
[repo]
name = "widget"
path = "widget"
remote = "acme"
branch = "dev"   # our patch branch
depends = ["gizmo"]
"""

suite "the manifest editor keeps a fragment in one schema":

  test "a shared-key edit leaves a v1 fragment v1 and readable":
    let dir = createTempDir("repro-editor-schema-", "")
    defer: removeDir(dir)
    let path = dir / "widget.toml"
    writeFile(path, v1Fragment)
    check addArrayMemberInFile(path, "repo", "depends", "sprocket")
    let text = readFile(path)
    check text.startsWith("schema = \"reprobuild.workspace.repo.v1\"")
    check "branch = \"dev\"   # our patch branch" in text
    check "mainline =" notin text
    let f = readRepoFragment(path)
    check f.schema == schemaRepoFragmentV1
    check f.repo.mainlineBranch == some("dev")
    check f.repo.depends == @["gizmo", "sprocket"]

  test "a v2-only key upgrades the whole v1 file in one save":
    let dir = createTempDir("repro-editor-schema-", "")
    defer: removeDir(dir)
    let path = dir / "widget.toml"
    writeFile(path, v1Fragment)
    var doc = loadManifestDoc(path)
    check doc.setKey("repo", "unstable", tomlStr("agents"))
    doc.saveManifestDoc()
    let text = readFile(path)
    # The schema line and the key were changed together; the comment that
    # rode on the renamed key, and every other line, survived.
    check text == v1Fragment.replace("repo.v1", "repo.v2").replace(
      "branch = \"dev\"   # our patch branch",
      "mainline = \"dev\"   # our patch branch").replace(
      "depends = [\"gizmo\"]\n", "depends = [\"gizmo\"]\nunstable = \"agents\"\n")
    let f = readRepoFragment(path)
    check f.schema == schemaRepoFragmentV2
    check f.repo.mainline == some("dev")
    check f.repo.unstable == roleBranch("agents")

  test "setting mainline on a v1 file rewrites branch rather than adding a second key":
    let dir = createTempDir("repro-editor-schema-", "")
    defer: removeDir(dir)
    let path = dir / "widget.toml"
    writeFile(path, v1Fragment)
    var doc = loadManifestDoc(path)
    check doc.setKey("repo", "mainline", tomlStr("main"))
    doc.saveManifestDoc()
    let f = readRepoFragment(path)
    check f.schema == schemaRepoFragmentV1
    check f.repo.mainlineBranch == some("main")
    check readFile(path).count("branch =") == 1
    check "mainline =" notin readFile(path)

  test "branch is refused in a v2 fragment":
    let dir = createTempDir("repro-editor-schema-", "")
    defer: removeDir(dir)
    let path = dir / "widget.toml"
    writeFile(path, v1Fragment.replace("repo.v1", "repo.v2").replace(
      "branch = ", "mainline = "))
    var doc = loadManifestDoc(path)
    expect ManifestEditError:
      discard doc.setKey("repo", "branch", tomlStr("dev"))

  test "a new fragment declaring a role is written as repo.v2 with mainline":
    let dir = createTempDir("repro-editor-schema-", "")
    defer: removeDir(dir)
    let path = dir / "new.toml"
    # A typed value still carrying the v1 spelling.
    writeWorkspaceManifestFile(path, repoFragmentText(RepoFragment(
      schema: schemaRepoFragmentV1, repo: RepoBody(name: "n", path: "n",
        branch: some("dev"), stable: roleAbsent(),
        `branch-roles`: CustomRoleTable(entries: @[("beta", roleBranch("b"))])))))
    let text = readFile(path)
    check text == "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
      "name = \"n\"\npath = \"n\"\nmainline = \"dev\"\nstable = false\n\n" &
      "[repo.branch-roles]\nbeta = \"b\"\n"
    let f = readRepoFragment(path)
    check f.repo.mainline == some("dev")
    check f.repo.stable == roleAbsent()
    check f.repo.`branch-roles`.entries == @[("beta", roleBranch("b"))]

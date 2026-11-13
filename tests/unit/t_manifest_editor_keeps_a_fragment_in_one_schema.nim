## The manifest editor never leaves a repo fragment in a retired spelling.
##
## A repo fragment has one schema, `repo.v2`, whose mainline key is
## `mainline` (Workspace-Branch-Roles.md §3.1, §3.6). The `repo.v1` schema and
## its `branch` key are retired: the reader refuses both, so a writer that
## produced either would break the workspace for everyone who reads it. The
## rule, enforced by the editor (`guardFragmentSchema`) rather than by each
## caller:
##
## * an edit of a v2 fragment — a shared key (`depends`, `tags`, …) or a role
##   — is in place, byte for byte outside the edited span, and the file stays
##   v2 and readable;
## * writing `branch` into a fragment is refused, naming `mainline`;
## * a retired `repo.v1` fragment is not edited at all — any edit, even of a
##   key the two schemas shared, is refused naming the rewrite — because the
##   result would still not load;
## * a NEW fragment is written as v2 with `mainline`
##   (t_repo_fragment_writer_emits_only_repo_v2).
##
## Every result is read back through the strict reader, so "one schema" is
## checked by the component that would refuse anything else.
##
## No mocks: real files in a temporary directory, the real editor and reader.

import std/[options, os, strutils, tempfiles, unittest]

import repro_workspace_manifests

const v2Fragment = """schema = "reprobuild.workspace.repo.v2"

# Vendored fork; the mainline is where our patches land.
[repo]
name = "widget"
path = "widget"
remote = "acme"
mainline = "dev"   # our patch branch
depends = ["gizmo"]
"""

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

  test "a shared-key edit leaves a v2 fragment v2 and readable":
    let dir = createTempDir("repro-editor-schema-", "")
    defer: removeDir(dir)
    let path = dir / "widget.toml"
    writeFile(path, v2Fragment)
    check addArrayMemberInFile(path, "repo", "depends", "sprocket")
    let text = readFile(path)
    check text == v2Fragment.replace("depends = [\"gizmo\"]",
      "depends = [\"gizmo\", \"sprocket\"]")
    let f = readRepoFragment(path)
    check f.schema == schemaRepoFragmentV2
    check f.repo.mainline == some("dev")
    check f.repo.depends == @["gizmo", "sprocket"]

  test "a role is added in place, in the same schema":
    let dir = createTempDir("repro-editor-schema-", "")
    defer: removeDir(dir)
    let path = dir / "widget.toml"
    writeFile(path, v2Fragment)
    var doc = loadManifestDoc(path)
    check doc.setKey("repo", "unstable", tomlStr("agents"))
    doc.saveManifestDoc()
    # The new scalar lands with the table's other scalars, below `mainline`
    # and above the `depends` array
    # (t_manifest_editor_places_a_new_scalar_with_the_scalars); the comment
    # and every other line survive.
    check readFile(path) == v2Fragment.replace(
      "mainline = \"dev\"   # our patch branch\n",
      "mainline = \"dev\"   # our patch branch\nunstable = \"agents\"\n")
    let f = readRepoFragment(path)
    check f.schema == schemaRepoFragmentV2
    check f.repo.mainline == some("dev")
    check f.repo.unstable == roleBranch("agents")

  test "setting mainline rewrites the one key rather than adding a second":
    let dir = createTempDir("repro-editor-schema-", "")
    defer: removeDir(dir)
    let path = dir / "widget.toml"
    writeFile(path, v2Fragment)
    var doc = loadManifestDoc(path)
    check doc.setKey("repo", "mainline", tomlStr("main"))
    doc.saveManifestDoc()
    let f = readRepoFragment(path)
    check f.schema == schemaRepoFragmentV2
    check f.repo.mainline == some("main")
    check readFile(path).count("mainline =") == 1
    check "branch =" notin readFile(path)

  test "branch is refused in a fragment":
    let dir = createTempDir("repro-editor-schema-", "")
    defer: removeDir(dir)
    let path = dir / "widget.toml"
    writeFile(path, v2Fragment)
    var doc = loadManifestDoc(path)
    expect ManifestEditError:
      discard doc.setKey("repo", "branch", tomlStr("dev"))
    check readFile(path) == v2Fragment

  test "a retired repo.v1 fragment is not edited":
    let dir = createTempDir("repro-editor-schema-", "")
    defer: removeDir(dir)
    let path = dir / "widget.toml"
    writeFile(path, v1Fragment)
    for (key, value) in [("mainline", tomlStr("main")),
                         ("unstable", tomlStr("agents")),
                         ("tags", tomlStrings(@["x"]))]:
      var doc = loadManifestDoc(path)
      try:
        discard doc.setKey("repo", key, value)
        checkpoint("editing `" & key & "` of a retired repo.v1 file was accepted")
        fail()
      except ManifestEditError as e:
        check "reprobuild.workspace.repo.v2" in e.msg
        check "`mainline`" in e.msg
    check readFile(path) == v1Fragment

  test "a new fragment declaring a role is written as repo.v2 with mainline":
    let dir = createTempDir("repro-editor-schema-", "")
    defer: removeDir(dir)
    let path = dir / "new.toml"
    writeWorkspaceManifestFile(path, repoFragmentText(RepoFragment(
      repo: RepoBody(name: "n", path: "n",
        mainline: some("dev"), stable: roleAbsent(),
        `branch-roles`: CustomRoleTable(entries: @[("beta", roleBranch("b"))])))))
    let text = readFile(path)
    check text == "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
      "name = \"n\"\npath = \"n\"\nmainline = \"dev\"\nstable = false\n\n" &
      "[repo.branch-roles]\nbeta = \"b\"\n"
    let f = readRepoFragment(path)
    check f.repo.mainline == some("dev")
    check f.repo.stable == roleAbsent()
    check f.repo.`branch-roles`.entries == @[("beta", roleBranch("b"))]

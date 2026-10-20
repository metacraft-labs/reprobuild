## A repo fragment is written as `repo.v1` whenever v1 can say everything it
## holds, and as `repo.v2` only when it must (Workspace-Branch-Roles.md §6).
##
## Why: an older pinned `repro` reads only `reprobuild.workspace.repo.v1`, and
## refuses the WHOLE workspace on the first v2 fragment it meets
## ("schema version mismatch"). `repro ws repos add --branch=dev` used to write
## every new fragment as v2 with `mainline = "dev"` — a fragment v1 says just
## as well as `branch = "dev"` — and that one file broke the pre-push gate of
## every unrelated repo in the workspace for every host still on the older
## pin (reprobuild-pm issue
## 2026-10-15-repo-fragment-v2-writer-breaks-pinned-repro-pre-push).
##
## The rule checked here:
##
## * `repoFragmentText` writes v1, with the mainline as `branch`, when the
##   fragment declares no role other than the mainline, no `profile` and no
##   custom role — whether the typed value carries the mainline as `mainline`
##   or as `branch`, and when it carries no mainline at all;
## * any of the five optional roles (a branch name OR `false`), `profile`, or
##   a custom role makes it v2 with `mainline`;
## * the in-place editor follows the same rule: setting `mainline` on a v1
##   file writes `branch` and keeps the file v1, while a v2-only key still
##   upgrades it.
##
## Every result is read back through the strict reader — the component the
## older `repro` uses to refuse a file.
##
## No mocks: real files in a temporary directory, the real writer, editor and
## reader.

import std/[options, os, strutils, tempfiles, unittest]

import repro_workspace_manifests

proc written(dir, name: string; body: RepoBody): (string, RepoFragment) =
  ## Write `body` as a new fragment through the production writer and read it
  ## back. Returns the file text and the decoded record.
  let path = dir / (name & ".toml")
  writeWorkspaceManifestFile(path, repoFragmentText(RepoFragment(
    schema: schemaRepoFragmentV2, repo: body)))
  (readFile(path), readRepoFragment(path))

suite "the repo fragment writer emits v1 when v1 can say it":

  test "a mainline-only fragment is written as v1 with branch":
    let dir = createTempDir("repro-writer-v1-", "")
    defer: removeDir(dir)
    let (text, f) = written(dir, "brew", RepoBody(name: "brew", path: "brew",
      remote: some("origin"), mainline: some("dev")))
    check text == "schema = \"reprobuild.workspace.repo.v1\"\n\n[repo]\n" &
      "name = \"brew\"\npath = \"brew\"\nremote = \"origin\"\nbranch = \"dev\"\n"
    check "mainline" notin text
    check f.schema == schemaRepoFragmentV1
    check f.repo.mainlineBranch == some("dev")

  test "a v1-style branch on the typed value is written as v1 too":
    let dir = createTempDir("repro-writer-v1-", "")
    defer: removeDir(dir)
    let (text, f) = written(dir, "w", RepoBody(name: "w", path: "w",
      url_prefix: some("acme"), branch: some("main")))
    check text.startsWith("schema = \"reprobuild.workspace.repo.v1\"\n")
    check "branch = \"main\"\n" in text
    check "mainline" notin text
    check f.repo.mainlineBranch == some("main")

  test "a fragment without any branch is written as v1":
    let dir = createTempDir("repro-writer-v1-", "")
    defer: removeDir(dir)
    let (text, f) = written(dir, "r", RepoBody(name: "r", path: "r",
      remote: some("origin"), revision: some("main")))
    check text == "schema = \"reprobuild.workspace.repo.v1\"\n\n[repo]\n" &
      "name = \"r\"\npath = \"r\"\nremote = \"origin\"\nrevision = \"main\"\n"
    check f.schema == schemaRepoFragmentV1
    check f.repo.mainlineBranch.isNone

  test "each v2-only declaration makes the fragment v2 with mainline":
    let dir = createTempDir("repro-writer-v1-", "")
    defer: removeDir(dir)
    let base = RepoBody(name: "x", path: "x", mainline: some("dev"))
    var cases: seq[(string, RepoBody)]
    for absent in [false, true]:
      let v = if absent: roleAbsent() else: roleBranch("b")
      let tag = if absent: "-false" else: ""
      var b = base
      b.unstable = v
      cases.add(("unstable" & tag, b))
      b = base
      b.staging = v
      cases.add(("staging" & tag, b))
      b = base
      b.stable = v
      cases.add(("stable" & tag, b))
      b = base
      b.production = v
      cases.add(("production" & tag, b))
      b = base
      b.lts = v
      cases.add(("lts" & tag, b))
      b = base
      b.`branch-roles` = CustomRoleTable(entries: @[("beta", v)])
      cases.add(("custom" & tag, b))
    var p = base
    p.profile = some("product")
    cases.add(("profile", p))
    for (name, body) in cases:
      checkpoint(name)
      let (text, f) = written(dir, name, body)
      check text.startsWith("schema = \"reprobuild.workspace.repo.v2\"\n")
      check "mainline = \"dev\"\n" in text
      check "branch = " notin text
      check f.schema == schemaRepoFragmentV2
      check f.repo.mainline == some("dev")

  test "the editor writes mainline into a v1 file as branch and keeps it v1":
    let dir = createTempDir("repro-writer-v1-", "")
    defer: removeDir(dir)
    let path = dir / "e.toml"
    let original = "schema = \"reprobuild.workspace.repo.v1\"\n\n[repo]\n" &
      "name = \"e\"\npath = \"e\"\nbranch = \"dev\"   # patches land here\n"
    writeFile(path, original)
    var doc = loadManifestDoc(path)
    check doc.setKey("repo", "mainline", tomlStr("main"))
    doc.saveManifestDoc()
    check readFile(path) == original.replace("\"dev\"", "\"main\"")
    let f = readRepoFragment(path)
    check f.schema == schemaRepoFragmentV1
    check f.repo.mainlineBranch == some("main")
    # Setting the value it already has is not a change.
    var again = loadManifestDoc(path)
    check not again.setKey("repo", "mainline", tomlStr("main"))

    # A v1 file without a branch gains `branch`, not `mainline`.
    let bare = dir / "bare.toml"
    writeFile(bare, "schema = \"reprobuild.workspace.repo.v1\"\n\n[repo]\n" &
      "name = \"bare\"\npath = \"bare\"\n")
    var bareDoc = loadManifestDoc(bare)
    check bareDoc.setKey("repo", "mainline", tomlStr("dev"))
    bareDoc.saveManifestDoc()
    check readFile(bare) == "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
      "[repo]\nname = \"bare\"\npath = \"bare\"\nbranch = \"dev\"\n"
    check readRepoFragment(bare).repo.mainlineBranch == some("dev")

    # A role still needs v2, so it upgrades the file (branch -> mainline).
    var roleDoc = loadManifestDoc(path)
    check roleDoc.setKey("repo", "unstable", tomlStr("agents"))
    roleDoc.saveManifestDoc()
    let g = readRepoFragment(path)
    check g.schema == schemaRepoFragmentV2
    check g.repo.mainline == some("main")
    check g.repo.unstable == roleBranch("agents")

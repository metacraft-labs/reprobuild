## A repo fragment is written in the one fragment schema, `repo.v2`, with its
## mainline as `mainline` (Workspace-Branch-Roles.md §3.1, §6 step 3).
##
## Until every pinned `repro` read `repo.v2`, the writer emitted the OLDEST
## schema that could say a fragment, because an older `repro` refused the whole
## workspace on the first v2 fragment it met. That reader is retired now, and
## so is the writer rule: a `repo.v1` fragment no longer loads, so writing one
## would author a file every `repro` refuses. Checked here:
##
## * `repoFragmentText` writes `repo.v2` for every fragment — the mainline as
##   `mainline`, a commit pin as `revision` beside it, and no mainline key at
##   all when a profile supplies it — never the retired `branch` key;
## * any role (a branch name OR `false`), `profile`, or a custom role is
##   written in the same schema;
## * the in-place editor keeps a v2 file v2, refuses to write the retired
##   `branch` key, and refuses to edit a retired `repo.v1` file (naming the
##   rewrite) rather than produce a file that still does not load.
##
## Every result is read back through the strict reader.
##
## No mocks: real files in a temporary directory, the real writer, editor and
## reader.

import std/[options, os, strutils, tempfiles, unittest]

import repro_workspace_manifests

proc written(dir, name: string; body: RepoBody): (string, RepoFragment) =
  ## Write `body` as a new fragment through the production writer and read it
  ## back. Returns the file text and the decoded record.
  let path = dir / (name & ".toml")
  writeWorkspaceManifestFile(path, repoFragmentText(RepoFragment(repo: body)))
  (readFile(path), readRepoFragment(path))

suite "the repo fragment writer emits only repo.v2":

  test "a mainline-only fragment is written as v2 with mainline":
    let dir = createTempDir("repro-writer-v2-", "")
    defer: removeDir(dir)
    let (text, f) = written(dir, "brew", RepoBody(name: "brew", path: "brew",
      remote: some("origin"), mainline: some("dev")))
    check text == "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
      "name = \"brew\"\npath = \"brew\"\nremote = \"origin\"\nmainline = \"dev\"\n"
    check "branch" notin text
    check f.schema == schemaRepoFragmentV2
    check f.repo.mainline == some("dev")

  test "a commit pin is written beside the mainline":
    let dir = createTempDir("repro-writer-v2-", "")
    defer: removeDir(dir)
    let pin = "0123456789abcdef0123456789abcdef01234567"
    let (text, f) = written(dir, "r", RepoBody(name: "r", path: "r",
      remote: some("origin"), mainline: some("main"), revision: some(pin)))
    check text == "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
      "name = \"r\"\npath = \"r\"\nremote = \"origin\"\nmainline = \"main\"\n" &
      "revision = \"" & pin & "\"\n"
    check f.repo.mainline == some("main")
    check f.repo.revision == some(pin)

  test "a fragment whose profile supplies the mainline carries none":
    let dir = createTempDir("repro-writer-v2-", "")
    defer: removeDir(dir)
    let (text, f) = written(dir, "p", RepoBody(name: "p", path: "p",
      url_prefix: some("acme"), profile: some("product")))
    check text.startsWith("schema = \"reprobuild.workspace.repo.v2\"\n")
    check "mainline" notin text
    check "branch" notin text
    check f.repo.mainline.isNone
    check f.repo.profile == some("product")

  test "each role declaration is written in the same schema":
    let dir = createTempDir("repro-writer-v2-", "")
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

  test "the editor keeps a v2 file v2 and refuses the retired spellings":
    let dir = createTempDir("repro-writer-v2-", "")
    defer: removeDir(dir)
    let path = dir / "e.toml"
    let original = "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
      "name = \"e\"\npath = \"e\"\nmainline = \"dev\"   # patches land here\n"
    writeFile(path, original)
    var doc = loadManifestDoc(path)
    check doc.setKey("repo", "mainline", tomlStr("main"))
    doc.saveManifestDoc()
    check readFile(path) == original.replace("\"dev\"", "\"main\"")
    check readRepoFragment(path).repo.mainline == some("main")
    # Setting the value it already has is not a change.
    var again = loadManifestDoc(path)
    check not again.setKey("repo", "mainline", tomlStr("main"))
    # A role is written in place, in the same schema.
    var roleDoc = loadManifestDoc(path)
    check roleDoc.setKey("repo", "unstable", tomlStr("agents"))
    roleDoc.saveManifestDoc()
    let g = readRepoFragment(path)
    check g.schema == schemaRepoFragmentV2
    check g.repo.mainline == some("main")
    check g.repo.unstable == roleBranch("agents")

    # The retired key is refused, naming the current one; nothing is written.
    let before = readFile(path)
    var branchDoc = loadManifestDoc(path)
    try:
      discard branchDoc.setKey("repo", "branch", tomlStr("dev"))
      checkpoint("setting the retired `branch` key was accepted")
      fail()
    except ManifestEditError as e:
      check "mainline" in e.msg
    check readFile(path) == before

    # A retired repo.v1 file is not edited: the result would still not load.
    let v1 = dir / "v1.toml"
    let v1Text = "schema = \"reprobuild.workspace.repo.v1\"\n\n[repo]\n" &
      "name = \"v\"\npath = \"v\"\nbranch = \"dev\"\n"
    writeFile(v1, v1Text)
    var v1Doc = loadManifestDoc(v1)
    try:
      discard v1Doc.setKey("repo", "tags", tomlStrings(@["x"]))
      checkpoint("editing a retired repo.v1 fragment was accepted")
      fail()
    except ManifestEditError as e:
      check "reprobuild.workspace.repo.v2" in e.msg
    check readFile(v1) == v1Text

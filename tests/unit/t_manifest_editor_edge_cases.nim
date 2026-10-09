## Edge cases of the manifest editor (`repro_workspace_manifests/manifest_editor`).
##
## The two named properties — unrelated text survives, member edits hit the
## named array — have their own tests. This file covers the shapes those tests
## do not: empty and missing arrays, inline versus one-per-line arrays, a key
## of the same name in another table, idempotence, arrays of tables in both
## TOML spellings, files without a final newline, malformed input, and the
## typed renderers (each round-trips through the strict reader, and the ones
## that replaced string-built stubs produce the bytes those stubs produced).
##
## No mocks: real files where the reader is involved, the real reader.

import std/[options, os, strutils, tempfiles, unittest]

import repro_workspace_manifests

proc edited(text: string; op: proc (doc: var ManifestDoc)): string =
  var doc = manifestDocFromText(text)
  op(doc)
  doc.manifestDocText

suite "manifest editor edge cases":

  test "an empty multi-line array gains its first member on its own line":
    let src = "member_repos = [\n]\n\n[repo-set]\nname = \"s\"\n"
    check edited(src, proc (d: var ManifestDoc) =
      check d.addArrayMember("", "member_repos", "a")) ==
      "member_repos = [\n  \"a\",\n]\n\n[repo-set]\nname = \"s\"\n"

  test "an empty inline array stays inline":
    let src = "member_repos = []\n\n[repo-set]\nname = \"s\"\n"
    check edited(src, proc (d: var ManifestDoc) =
      check d.addArrayMember("", "member_repos", "a")) ==
      "member_repos = [\"a\"]\n\n[repo-set]\nname = \"s\"\n"

  test "a missing top-level array is created above the first header":
    # ...and above the comment block that introduces that header, which
    # belongs to the header rather than to whatever precedes it.
    let src = "# Project header comment\n[project]\nname = \"p\"\n"
    check edited(src, proc (d: var ManifestDoc) =
      check d.addArrayMember("", "member_repos", "a")) ==
      "member_repos = [\n  \"a\",\n]\n\n# Project header comment\n" &
      "[project]\nname = \"p\"\n"

  test "a missing top-level array follows the last top-level key":
    let src = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
      "[project]\nname = \"p\"\ntrunk = \"main\"\n"
    let got = edited(src, proc (d: var ManifestDoc) =
      check d.addArrayMember("", "member_repos", "a"))
    check got == "schema = \"reprobuild.workspace.project.v1\"\n\n" &
      "member_repos = [\n  \"a\",\n]\n\n[project]\nname = \"p\"\ntrunk = \"main\"\n"

  test "the key-order rule holds for a scalar top-level key too":
    let src = "[project]\nname = \"p\"\n"
    let got = edited(src, proc (d: var ManifestDoc) =
      check d.setKey("", "schema", tomlStr("reprobuild.workspace.project.v1")))
    check got.startsWith("schema = ")
    check got.find("schema") < got.find("[project]")

  test "a key of the same name in a later table is not the top-level key":
    let src = "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
      "[repo]\nname = \"r\"\npath = \"r\"\ndepends = [\"x\"]\n"
    var doc = manifestDocFromText(src)
    check not doc.hasKey("", "name")
    check not doc.hasKey("", "depends")
    check doc.hasKey("repo", "depends")
    check doc.arrayMembers("", "depends").len == 0
    check not doc.removeArrayMember("", "depends", "x")
    check doc.manifestDocText == src
    check doc.addArrayMember("repo", "depends", "y", alInline)
    check doc.manifestDocText == src.replace("[\"x\"]", "[\"x\", \"y\"]")

  test "includes written after the last [[remote]] is extended where it is":
    # Hand-written projects put `includes` below the remotes; the pinned
    # reader reads it as top-level, so the editor must not declare a second
    # `includes` above `[project]`.
    let dir = createTempDir("repro-editor-stray-", "")
    defer: removeDir(dir)
    let path = dir / "p.toml"
    let src = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
      "[project]\nname = \"p\"\n\n[[remote]]\nname = \"o\"\n" &
      "fetch = \"https://x\"\n\nincludes = [\n  \"repos/a.toml\",\n]\n"
    writeFile(path, src)
    var doc = loadManifestDoc(path)
    check doc.hasKey("", "includes")
    check doc.appendInclude("repos/b.toml")
    doc.saveManifestDoc()
    check readFile(path) == src.replace("\"repos/a.toml\",\n",
      "\"repos/a.toml\",\n  \"repos/b.toml\",\n")
    check readProjectManifest(path).includes == @["repos/a.toml", "repos/b.toml"]

  test "add and remove are idempotent":
    let src = "member_repos = [\n  \"a\",\n]\n"
    var doc = manifestDocFromText(src)
    check not doc.addArrayMember("", "member_repos", "a")
    check not doc.changed
    check not doc.removeArrayMember("", "member_repos", "b")
    check not doc.changed
    check doc.removeArrayMember("", "member_repos", "a")
    check not doc.removeArrayMember("", "member_repos", "a")
    check doc.manifestDocText == "member_repos = [\n]\n"

  test "the last element without a trailing comma gets one":
    let src = "member_repos = [\n  \"a\",\n  \"b\"\n]\n"
    check edited(src, proc (d: var ManifestDoc) =
      check d.addArrayMember("", "member_repos", "c")) ==
      "member_repos = [\n  \"a\",\n  \"b\",\n  \"c\",\n]\n"

  test "comments inside a one-per-line array survive an edit":
    let src = "member_repos = [\n  # tools\n  \"a\",  # first\n" &
      "  \"b\",\n]\n"
    check edited(src, proc (d: var ManifestDoc) =
      check d.removeArrayMember("", "member_repos", "b")
      check d.addArrayMember("", "member_repos", "c")) ==
      "member_repos = [\n  # tools\n  \"a\",  # first\n  \"c\",\n]\n"

  test "a mixed-layout array is rewritten one element per line":
    let src = "member_repos = [ \"a\", \"b\",\n  \"c\" ]\n"
    check edited(src, proc (d: var ManifestDoc) =
      check d.removeArrayMember("", "member_repos", "b")) ==
      "member_repos = [\n  \"a\",\n  \"c\",\n]\n"

  test "a non-string array is refused as a member list":
    var doc = manifestDocFromText("depth = [1, 2]\n")
    expect ManifestEditError:
      discard doc.addArrayMember("", "depth", "x")

  test "malformed text raises ManifestEditError naming the line":
    var doc = manifestDocFromText("schema = \"x\"\nthis is not toml\n", "f.toml")
    try:
      discard doc.addArrayMember("", "member_repos", "a")
      check false
    except ManifestEditError as e:
      check "f.toml" in e.msg
      check "line 2" in e.msg

  test "a file with no final newline is extended cleanly":
    let src = "member_repos = [\"a\"]"
    check edited(src, proc (d: var ManifestDoc) =
      check d.setKey("", "member_sets", tomlStrings(["s"]))) ==
      "member_repos = [\"a\"]\nmember_sets = [\"s\"]\n"

  test "replacing a value keeps a trailing comment and the key spelling":
    let src = "[repo]\n\"name\"   =   'r'   # literal string\n"
    check edited(src, proc (d: var ManifestDoc) =
      check d.setKey("repo", "name", tomlStr("s"))) ==
      "[repo]\n\"name\"   =   \"s\"   # literal string\n"

  test "a missing table is appended under its own header":
    let src = "schema = \"x\"\n\n[repo]\nname = \"r\"\n"
    check edited(src, proc (d: var ManifestDoc) =
      check d.setKey("repo.branch-roles", "staging-partner",
        tomlStr("staging-partner"))) ==
      src & "\n[repo.branch-roles]\nstaging-partner = \"staging-partner\"\n"

  test "a [[remote]] entry is added once, after the last remote block":
    let src = "member_repos = [\n]\n\n[project]\nname = \"p\"\n\n" &
      "[[remote]]\nname = \"origin\"\nfetch = \"https://a\"\n\n" &
      "[certificates]\ngate_mode = \"off\"\n"
    var doc = manifestDocFromText(src)
    let fields = @[tomlField("name", tomlStr("upstream")),
                   tomlField("fetch", tomlStr("https://b"))]
    check doc.ensureArrayTableEntry("remote", fields)
    check not doc.ensureArrayTableEntry("remote", fields)
    check not doc.ensureArrayTableEntry("remote",
      @[tomlField("name", tomlStr("origin")), tomlField("fetch", tomlStr("x"))])
    check doc.manifestDocText == src.replace("fetch = \"https://a\"\n",
      "fetch = \"https://a\"\n\n[[remote]]\nname = \"upstream\"\n" &
      "fetch = \"https://b\"\n")

  test "an inline-table array keeps its spelling when an entry is added":
    let src = "binary_dependency = [\n  { name = \"zlib\", remote = \"https://z\" },\n]\n\n" &
      "[project]\nname = \"p\"\n"
    var doc = manifestDocFromText(src)
    check not doc.ensureArrayTableEntry("binary_dependency",
      @[tomlField("name", tomlStr("zlib")), tomlField("remote", tomlStr("y"))])
    check doc.ensureArrayTableEntry("binary_dependency",
      @[tomlField("name", tomlStr("bz2")), tomlField("remote", tomlStr("https://b"))])
    check doc.manifestDocText == src.replace("\"https://z\" },\n",
      "\"https://z\" },\n  { name = \"bz2\", remote = \"https://b\" },\n")

  test "typed renderers round-trip through the strict reader":
    let dir = createTempDir("repro-editor-render-", "")
    defer: removeDir(dir)

    let fragment = RepoFragment(schema: schemaRepoFragmentV1, repo: RepoBody(
      name: "llvm-project", path: "refs/llvm-project",
      url_prefix: some("github"), url_suffix: some("llvm/llvm-project"),
      branch: some("main"), tags: @["refs"], depends: @["mold"],
      copyfile: @[CopyLinkFileEntry(src: "a", dest: "b")]))
    writeWorkspaceManifestFile(dir / "repos" / "llvm-project.toml",
      repoFragmentText(fragment))
    let f = readRepoFragment(dir / "repos" / "llvm-project.toml")
    check f.repo.name == "llvm-project"
    check f.repo.url_suffix == some("llvm/llvm-project")
    check f.repo.branch == some("main")
    check f.repo.tags == @["refs"]
    check f.repo.depends == @["mold"]
    check f.repo.copyfile.len == 1 and f.repo.copyfile[0].dest == "b"

    let project = ProjectManifest(schema: schemaProjectManifestV1,
      project: ProjectBody(name: "p", trunk: some("main")),
      member_repos: @["a"],
      remote: @[RemoteEntry(name: "origin", fetch: "https://x")],
      binary_dependency: @[BinaryDependencyEntry(name: "zlib",
        remote: "https://z", revision: some("v1"))])
    writeWorkspaceManifestFile(dir / "p.toml", projectManifestText(project))
    let p = readProjectManifest(dir / "p.toml")
    check p.member_repos == @["a"]
    check p.member_sets.len == 0
    check p.remote.len == 1 and p.remote[0].fetch == "https://x"
    check p.binary_dependency.len == 1
    check p.binary_dependency[0].revision == some("v1")
    check p.project.trunk == some("main")

    var cfg = WorkspaceBootstrap(schema: schemaWorkspaceBootstrapV1)
    cfg.manifest.url = "https://github.com/example/repro-workspace.git"
    cfg.manifest.publish_locks = some(true)
    cfg.projects.default = @["reprobuild"]
    cfg.develop.org_urls = @["https://github.com/example/"]
    cfg.locking.route = @[LockingRouteEntry(visibility: "team",
      backend: "git-checkout", path: some(".repro/manifests"),
      repos: @["a", "b"])]
    writeWorkspaceManifestFile(dir / ".repro-workspace.toml",
      workspaceBootstrapText(cfg))
    let b = readWorkspaceBootstrap(dir / ".repro-workspace.toml")
    check b.manifest.url == cfg.manifest.url
    check b.manifest.publish_locks == some(true)
    check b.projects.default == @["reprobuild"]
    check b.develop.org_urls == cfg.develop.org_urls
    check b.locking.route.len == 1
    check b.locking.route[0].repos == @["a", "b"]

    var local = WorkspaceLocal(schema: schemaWorkspaceLocalV1)
    local.workspace.project = "a"
    local.workspace.projects = @["a", "b"]
    local.workspace.branch = some("feature/x")
    local.manifest = @[ManifestLayer(url: some("https://m"), visibility: "public")]
    writeWorkspaceManifestFile(dir / "state.toml", workspaceStateText(local))
    let st = readWorkspaceLocal(dir / "state.toml")
    check st.workspace.projects == @["a", "b"]
    check st.workspace.branch == some("feature/x")
    check st.manifest.len == 1

  test "the renderers reproduce the layouts the CLI stubs used to write":
    check repoFragmentText(RepoFragment(repo: RepoBody(name: "r", path: "r",
      remote: some("origin"), revision: some("main")))) ==
      "schema = \"reprobuild.workspace.repo.v1\"\n\n[repo]\nname = \"r\"\n" &
      "path = \"r\"\nremote = \"origin\"\nrevision = \"main\"\n"
    check urlPrefixText(UrlPrefixManifest(`url-prefix`: UrlPrefixBody(
      name: "gh", url: "https://github.com/o"))) ==
      "schema = \"reprobuild.workspace.url-prefix.v1\"\n\n[url-prefix]\n" &
      "name = \"gh\"\nurl = \"https://github.com/o\"\n"
    check projectManifestText(ProjectManifest(project: ProjectBody(name: "p",
      trunk: some("main")))) ==
      "schema = \"reprobuild.workspace.project.v1\"\n\n[project]\n" &
      "name = \"p\"\ntrunk = \"main\"\n"
    check projectManifestText(ProjectManifest(project: ProjectBody(name: "p",
      trunk: some("main")), member_sets: @["s"])) ==
      "schema = \"reprobuild.workspace.project.v1\"\n\n" &
      "member_sets = [\n  \"s\",\n]\n\nmember_repos = [\n]\n\n" &
      "[project]\nname = \"p\"\ntrunk = \"main\"\n"
    # A new repo-set's arrays now sit ABOVE its identity table, as the
    # key-order rule asks and as every repo-set in the metacraft manifest
    # repo is laid out.
    check repoSetText(RepoSetManifest(`repo-set`: RepoSetBody(name: "s"))) ==
      "schema = \"reprobuild.workspace.repo-set.v1\"\n\n" &
      "member_sets = [\n]\n\nmember_repos = [\n]\n\n[repo-set]\nname = \"s\"\n"

  test "the state file keeps a hand comment across a project-set update":
    let dir = createTempDir("repro-editor-state-", "")
    defer: removeDir(dir)
    createDir(dir / ".repro")
    let path = workspaceTomlPath(dir)
    let src = "schema = \"reprobuild.workspace.local.v1\"\n\n" &
      "# managed by repro; this comment is mine\n[workspace]\n" &
      "project = \"a\"\nbranch = \"main\"\n"
    writeFile(path, src)
    writeWorkspaceProjects(dir, @["a", "b"])
    check readFile(path) == src.replace("project = \"a\"\n",
      "project = \"a\"\nprojects = [\"a\", \"b\"]\n")
    writeWorkspaceProjects(dir, @["a"])
    check readFile(path) == src
    writeWorkspaceBranchWithStarted(dir, "a", "feature/y", featureStarted = true)
    check readFile(path) == src.replace("branch = \"main\"\n",
      "branch = \"feature/y\"\nfeature_started = true\n")
    writeWorkspaceBranchWithStarted(dir, "a", "main", featureStarted = false)
    check readFile(path) == src

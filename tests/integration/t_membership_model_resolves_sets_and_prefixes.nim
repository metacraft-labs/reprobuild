## Workspace-Membership-Model.md step 2 — RESOLUTION of the membership model:
## `members`, repo-sets, `url-prefixes/`, per-binding url prefixes, and
## `branch`.
##
## Everything here is additive. The load-bearing assertion is the LAST one: an
## unconverted project — old `includes` paths, a project-level `[[remote]]`
## table, `revision`, no `url-prefixes/` directory anywhere — must resolve to
## exactly what it resolved to before, field for field. That property is what
## lets the manifest-repo conversion land as a separate, separately-reviewable
## change; without it the conversion and the resolver would have to move
## together and neither could be verified against the other.
##
## Asserted:
##   1. A `members` list expands, and a member that names a repo-set expands to
##      ITS members, recursively — the shared-infrastructure case, where one
##      set is pulled in by many.
##   2. A cycle is refused with the FULL path named (`a -> b -> a`). A stack
##      overflow names nothing and is indistinguishable from a compiler bug.
##   3. Dedup identity is the checkout PATH: a repo reached by two routes is
##      ONE entry and merges silently, while two members declaring one path
##      with different facts is a refusal naming the path, both sources, and
##      the differing fields.
##   4. `url = url_prefix + "/" + url_suffix`, `url_suffix` defaults to `name`,
##      and a per-binding `url_prefix` / `url_suffix` puts a fork's `upstream`
##      at a DIFFERENT path than its `origin` — the case that was previously
##      inexpressible, because one shared `name` could only ever compose
##      `<other-prefix>/<same-name>`.
##   5. The primary binding is always the local git remote `origin`.
##   6. `branch` wins over `revision` when both are present; `revision` still
##      resolves alone.
##   7. A name carried by BOTH `repos/` and `repo-sets/` is refused. Members
##      resolve against both namespaces together, so one name cannot mean two
##      things, and silently preferring one would make the workspace depend on
##      which.
##   8. An UNCONVERTED project resolves identically to before — the regression
##      guard described above.
##
## No mocks: real TOML files on disk, driven through the real
## `resolveProject` / `resolveRepoSet` entry points.

import std/[os, strutils, tempfiles, unittest]

import repro_workspace_manifests

proc writeManifest(root, relPath, body: string) =
  let abs = root / relPath
  createDir(abs.parentDir)
  writeFile(abs, body)

proc urlPrefix(root, name, url: string) =
  writeManifest(root, "url-prefixes" / (name & ".toml"),
    "schema = \"reprobuild.workspace.url-prefix.v1\"\n\n" &
    "[url-prefix]\n" &
    "name = \"" & name & "\"\n" &
    "url = \"" & url & "\"\n")

proc repoSet(root, name: string; members: openArray[string]) =
  var body = "schema = \"reprobuild.workspace.repo-set.v1\"\n\n" &
    "[repo-set]\n" &
    "name = \"" & name & "\"\n\n" &
    "members = [\n"
  for m in members:
    body.add("  \"" & m & "\",\n")
  body.add("]\n")
  writeManifest(root, "repo-sets" / (name & ".toml"), body)

proc repoFragment(root, name, body: string) =
  writeManifest(root, "repos" / (name & ".toml"),
    "schema = \"reprobuild.workspace.repo.v1\"\n\n[repo]\n" & body)

proc findRepo(resolved: ResolvedProject; path: string): ResolvedRepo =
  for repo in resolved.repos:
    if repo.path == path:
      return repo
  checkpoint("no resolved repo at path '" & path & "'")
  fail()

suite "membership model — resolution":

  test "t_repo_set_expands_including_a_nested_set":
    let root = createTempDir("repro-mm-expand-", "")
    defer: removeDir(root)
    urlPrefix(root, "metacraft-labs", "https://github.com/metacraft-labs")
    for name in ["infra", "garm", "metacraft-dev-guidelines", "product"]:
      repoFragment(root, name,
        "name = \"" & name & "\"\n" &
        "path = \"" & name & "\"\n" &
        "branch = \"dev\"\n" &
        "url_prefix = \"metacraft-labs\"\n")
    repoSet(root, "shared-infrastructure",
      ["infra", "garm", "metacraft-dev-guidelines"])
    # A set whose members include another SET. Depth-first, so the nested set's
    # members land where the reference to it sat.
    #
    # The set is NOT named after the product repo it contains, because the two
    # namespaces are resolved together and a name in both is refused — see
    # `t_member_that_is_both_a_repo_and_a_set_is_refused`.
    repoSet(root, "product-set", ["shared-infrastructure", "product"])

    let resolved = resolveRepoSet(root / "repo-sets" / "product-set.toml")
    check resolved.projectName == "product-set"
    var paths: seq[string]
    for repo in resolved.repos:
      paths.add(repo.path)
    check paths == @["infra", "garm", "metacraft-dev-guidelines", "product"]
    let infra = findRepo(resolved, "infra")
    check infra.fetchUrl == "https://github.com/metacraft-labs/infra"
    # The primary binding is ALWAYS `origin`: a checkout's remotes have to look
    # like an ordinary clone's.
    check infra.remotes.len == 1
    check infra.remotes[0].localName == "origin"
    check infra.remotes[0].fetchUrl == infra.fetchUrl

  test "t_repo_set_cycle_is_refused_naming_the_path":
    let root = createTempDir("repro-mm-cycle-", "")
    defer: removeDir(root)
    urlPrefix(root, "acme", "https://git.example.invalid/acme")
    repoSet(root, "a", ["b"])
    repoSet(root, "b", ["a"])

    var refused = false
    try:
      discard resolveRepoSet(root / "repo-sets" / "a.toml")
    except WorkspaceManifestParseError as err:
      refused = true
      # The FULL path, not just "a cycle was detected". The operator has to be
      # able to see which edge to cut.
      check "a -> b -> a" in err.innerMessage
      check "cycle" in err.innerMessage
    check refused

  test "t_members_dedup_by_checkout_path":
    let root = createTempDir("repro-mm-dedup-", "")
    defer: removeDir(root)
    urlPrefix(root, "metacraft-labs", "https://github.com/metacraft-labs")
    repoFragment(root, "metacraft-dev-guidelines",
      "name = \"metacraft-dev-guidelines\"\n" &
      "path = \"metacraft-dev-guidelines\"\n" &
      "branch = \"latest\"\n" &
      "url_prefix = \"metacraft-labs\"\n")
    repoFragment(root, "app",
      "name = \"app\"\npath = \"app\"\nbranch = \"dev\"\n" &
      "url_prefix = \"metacraft-labs\"\n")
    repoSet(root, "left", ["metacraft-dev-guidelines", "app"])
    repoSet(root, "right", ["metacraft-dev-guidelines"])
    repoSet(root, "both", ["left", "right"])

    # The common case: two sets both pull in the shared repo. One checkout,
    # one entry, no complaint.
    let resolved = resolveRepoSet(root / "repo-sets" / "both.toml")
    var guidelines = 0
    for repo in resolved.repos:
      if repo.path == "metacraft-dev-guidelines": inc guidelines
    check guidelines == 1
    check resolved.repos.len == 2

    # A genuine disagreement about one path is a refusal, not a winner.
    repoFragment(root, "app-fork",
      "name = \"app\"\npath = \"app\"\nbranch = \"dev\"\n" &
      "url_prefix = \"metacraft-labs\"\n" &
      "url_suffix = \"app-fork\"\n")
    repoSet(root, "right-conflicting", ["app-fork"])
    repoSet(root, "conflicting", ["left", "right-conflicting"])
    var conflicted = false
    try:
      discard resolveRepoSet(root / "repo-sets" / "conflicting.toml")
    except WorkspaceProjectSetConflictError as err:
      conflicted = true
      check "app" in err.innerMessage
      check "fetch url" in err.innerMessage
      check "app-fork" in err.innerMessage
    check conflicted

  test "t_fork_upstream_resolves_to_a_different_path_than_origin":
    let root = createTempDir("repro-mm-fork-", "")
    defer: removeDir(root)
    urlPrefix(root, "metacraft-labs", "https://github.com/metacraft-labs")
    urlPrefix(root, "kitware", "https://github.com/Kitware")
    urlPrefix(root, "github", "https://github.com")
    # `reprobuild-cmake` forks `Kitware/CMake`. Prefix-plus-shared-name would
    # compose `Kitware/reprobuild-cmake`, which is not a repository.
    repoFragment(root, "reprobuild-cmake",
      "name = \"reprobuild-cmake\"\n" &
      "path = \"reprobuild-cmake\"\n" &
      "branch = \"reprobuild\"\n" &
      "url_prefix = \"metacraft-labs\"\n" &
      "remotes = [{ name = \"upstream\", url_prefix = \"kitware\", " &
        "url_suffix = \"CMake\" }]\n")
    # And the other half of splitting `name`: identity stops carrying URL
    # structure. `0install/0install` was the NAME; now it is the suffix.
    repoFragment(root, "0install",
      "name = \"0install\"\npath = \"0install\"\nbranch = \"master\"\n" &
      "url_prefix = \"github\"\n" &
      "url_suffix = \"0install/0install\"\n")
    repoSet(root, "forks", ["reprobuild-cmake", "0install"])

    let resolved = resolveRepoSet(root / "repo-sets" / "forks.toml")
    let cmake = findRepo(resolved, "reprobuild-cmake")
    check cmake.fetchUrl ==
      "https://github.com/metacraft-labs/reprobuild-cmake"
    check cmake.branch == "reprobuild"
    check cmake.revision == "reprobuild"
    check cmake.remotes.len == 2
    check cmake.remotes[0].localName == "origin"
    check cmake.remotes[0].fetchUrl == cmake.fetchUrl
    check cmake.remotes[1].localName == "upstream"
    check cmake.remotes[1].fetchUrl == "https://github.com/Kitware/CMake"

    let zeroInstall = findRepo(resolved, "0install")
    check zeroInstall.name == "0install"
    check zeroInstall.fetchUrl == "https://github.com/0install/0install"

  test "t_member_that_is_both_a_repo_and_a_set_is_refused":
    let root = createTempDir("repro-mm-collide-", "")
    defer: removeDir(root)
    urlPrefix(root, "acme", "https://git.example.invalid/acme")
    repoFragment(root, "tools",
      "name = \"tools\"\npath = \"tools\"\nbranch = \"dev\"\n" &
      "url_prefix = \"acme\"\n")
    repoSet(root, "tools", [])
    repoSet(root, "top", ["tools"])

    var refused = false
    try:
      discard resolveRepoSet(root / "repo-sets" / "top.toml")
    except WorkspaceManifestParseError as err:
      refused = true
      check "tools" in err.innerMessage
      check "repos/tools.toml" in err.innerMessage.replace('\\', '/')
      check "repo-sets/tools.toml" in err.innerMessage.replace('\\', '/')
    check refused

  test "t_project_members_and_branch_precedence":
    let root = createTempDir("repro-mm-project-", "")
    defer: removeDir(root)
    urlPrefix(root, "acme", "https://git.example.invalid/acme")
    repoFragment(root, "lib-a",
      "name = \"lib-a\"\npath = \"lib-a\"\n" &
      "url_prefix = \"acme\"\n" &
      # Both present. `branch` wins: it is the field that only ever holds a
      # branch name, so it is the one that is always a legal `--branch`
      # argument. A pin belongs in the lock.
      "branch = \"dev\"\n" &
      "revision = \"v1.2.3\"\n")
    repoFragment(root, "lib-b",
      "name = \"lib-b\"\npath = \"lib-b\"\n" &
      "url_prefix = \"acme\"\n" &
      "revision = \"main\"\n")
    repoSet(root, "libs", ["lib-a", "lib-b"])
    # `members` sits BEFORE `[project]`. This is the TOML trap the model's
    # "Consequences" section describes, and it is not fully gone for project
    # manifests: a bare key written after a table binds to THAT table, so
    # `members` under `[project]` is read as `[project] members` and the strict
    # decode rejects it. Repo-set manifests accept either order (verified), so
    # only the transitional `[project] + members` shape has to care.
    writeManifest(root, "projects" / "app.toml",
      "schema = \"reprobuild.workspace.project.v1\"\n\n" &
      "members = [\"libs\"]\n\n" &
      "[project]\nname = \"app\"\n")

    let resolved = resolveProject(root / "projects" / "app.toml")
    check resolved.repos.len == 2
    let a = findRepo(resolved, "lib-a")
    check a.branch == "dev"
    check a.revision == "dev"
    let b = findRepo(resolved, "lib-b")
    check b.branch == ""
    check b.revision == "main"

  test "t_unconverted_project_resolves_unchanged":
    let root = createTempDir("repro-mm-legacy-", "")
    defer: removeDir(root)
    # Deliberately the pre-membership-model spelling in every respect: include
    # PATHS, a project-level `[[remote]]` table, `revision`, a
    # `remotes = [{ name, remote }]` binding list, a `.git` fetch base that
    # `getFetchUrl` uses verbatim, and NO `url-prefixes/` directory at all.
    repoFragment(root, "lib-a",
      "name = \"lib-a\"\npath = \"lib-a\"\nremote = \"acme\"\n" &
      "revision = \"v1.2.3\"\n")
    repoFragment(root, "lib-b",
      "name = \"lib-b\"\npath = \"lib-b\"\n")
    repoFragment(root, "vendored",
      "name = \"vendored\"\npath = \"vendored\"\nremote = \"one-off\"\n")
    repoFragment(root, "forked",
      "name = \"forked\"\npath = \"forked\"\n" &
      "remotes = [{ name = \"origin\", remote = \"acme\" }, " &
        "{ name = \"upstream\", remote = \"other\" }]\n")
    writeManifest(root, "projects" / "legacy.toml",
      "schema = \"reprobuild.workspace.project.v1\"\n\n" &
      "[project]\nname = \"legacy\"\n" &
      "default_revision = \"dev\"\ndefault_remote = \"acme\"\n" &
      "trunk = \"dev\"\n\n" &
      "[[remote]]\nname = \"acme\"\n" &
      "fetch = \"https://git.example.invalid/acme\"\n\n" &
      "[[remote]]\nname = \"other\"\n" &
      "fetch = \"https://git.example.invalid/other\"\n\n" &
      "[[remote]]\nname = \"one-off\"\n" &
      "fetch = \"https://git.example.invalid/x/vendored.git\"\n\n" &
      "includes = [\n  \"repos/lib-a.toml\",\n  \"repos/lib-b.toml\",\n" &
      "  \"repos/vendored.toml\",\n  \"repos/forked.toml\",\n]\n")

    let resolved = resolveProject(root / "projects" / "legacy.toml")
    check resolved.projectName == "legacy"
    check resolved.defaultRevision == "dev"
    check resolved.trunk == "dev"
    check resolved.repos.len == 4

    let a = findRepo(resolved, "lib-a")
    check a.projectRemote == "acme"
    check a.fetchUrl == "https://git.example.invalid/acme/lib-a"
    check a.revision == "v1.2.3"
    check a.branch == ""
    check a.remotes.len == 1
    check a.remotes[0].localName == "origin"

    # No `remote` on the fragment: the project's `default_remote` applies, and
    # the project's `default_revision` supplies the revision.
    let b = findRepo(resolved, "lib-b")
    check b.projectRemote == "acme"
    check b.fetchUrl == "https://git.example.invalid/acme/lib-b"
    check b.revision == "dev"

    # `getFetchUrl`'s verbatim case: a `fetch` base already pointing at ONE
    # repository is used as-is rather than having the name appended. It
    # survives on the OLD path only — the new one composes unconditionally.
    let vendored = findRepo(resolved, "vendored")
    check vendored.fetchUrl == "https://git.example.invalid/x/vendored.git"

    # The documented `remotes`-without-`remote` irregularity: `projectRemote`
    # holds the FIRST binding's LOCAL name rather than a `[[remote]]` key.
    let forked = findRepo(resolved, "forked")
    check forked.projectRemote == "origin"
    check forked.fetchUrl == "https://git.example.invalid/acme/forked"
    check forked.remotes.len == 2
    check forked.remotes[1].localName == "upstream"
    check forked.remotes[1].projectRemote == "other"
    check forked.remotes[1].fetchUrl == "https://git.example.invalid/other/forked"

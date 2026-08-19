## Workspace-Membership-Model.md — the authoring surface: `repro ws sets` and
## `repro ws repos add --set=`.
##
## "Repo set" is the user-facing term, not only the schema's, so the CLI has to
## have the verb before the manifest repo can be converted to use it. The
## retained `repro ws projects` spelling is asserted here too, because the
## manifest repo is NOT converted yet and a verb that names the files an
## operator is looking at cannot fail as unknown while that is true.
##
## Fixture (hermetic): a workspace root that is itself the manifest repo — a
## real `git init` checkout, matching the native `<org>/repro-workspace`
## layout — carrying one pre-existing project `alpha`, so every assertion is
## made in the half-converted state the migration actually passes through.
##
## Asserted:
##   1. `sets add` defines a `repo-sets/<name>.toml` that the real strict
##      reader accepts, and does NOT enable it.
##   2. `repos add --set=` writes a fragment carrying `url_prefix` (not
##      `remote`), mints ONE org-named `url-prefixes/<org>.toml`, and names the
##      repo in the set's `member_repos` — the key chosen from what the name
##      actually resolves to in the manifest repo, never from the verb.
##   3. A second repo from the SAME org reuses that prefix and mints nothing —
##      the property that stops the prefix table growing one entry per repo.
##   4. A repo whose path under the org differs from its name gets a
##      `url_suffix`, and one whose path matches does NOT: identity stops
##      carrying URL structure, so restating it would put the coupling back.
##   5. What the CLI authored RESOLVES — driven through `resolveRepoSet`, so
##      the authoring and resolution halves cannot drift apart silently.
##   6. `sets` and `projects` are ONE namespace: `sets add` refuses a name an
##      existing project already defines, `sets list` shows both, and
##      `sets remove` removes either. Only `add` differs, in which directory it
##      scaffolds into — which is what keeps the alias from converting a
##      manifest repo one file at a time.
##   7. Mixing `--set` and `--project` in one `repos add` is refused: a
##      fragment carries one spelling of where it comes from, and a fragment
##      that half-resolves for one of two targets is worse than a refusal.
##   8. The `--json` surfaces name what the model HAS. "Project" was a ROLE a
##      set plays when enabled, not a kind, so a schema keyed on it described a
##      distinction that does not exist. Both the schema STRING and the payload
##      key move together, so a consumer keyed on the schema breaks loudly on
##      the shape change rather than reading a `sets` payload as the old
##      `projects` one.
##
## No mocks: the manifest edits are read back through the real strict readers
## and the real resolver, and the commits land in a real git repo.

import std/[json, options, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests

proc q(value: string): string = quoteShell(value)

proc requireGit(command: string): string =
  let res = execCmdEx(command)
  if res.exitCode != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.exitCode &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-mm-cli-" & slug & "-", "")
  result.reproBin = reproBinary()
  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot / "projects")
  createDir(workspaceRoot / "repos")
  # A pre-existing PROJECT, so every assertion below is made in the
  # half-converted state rather than in a greenfield repo that would never
  # exercise the alias.
  writeFile(workspaceRoot / "projects" / "alpha.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"alpha\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"acme\"\n" &
    "fetch = \"https://git.example.invalid/acme\"\n")
  discard requireGit(q(gitBin) & " init -b main " & q(workspaceRoot))
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
    " config user.name \"MM Tester\"")
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
    " commit -m fixture")
  result.workspaceRoot = workspaceRoot

proc runRepro(fx: Fixture; args: openArray[string]): CmdResult =
  var argv = @[fx.reproBin]
  for a in args: argv.add(a)
  argv.add("--workspace-root=" & fx.workspaceRoot)
  runShell(shellCommand(argv))

suite "membership model — `repro ws sets` authoring":

  test "t_sets_add_and_repos_add_author_the_new_shape":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "author")
      defer: removeDir(fx.scratch)

      let added = runRepro(fx, ["ws", "sets", "add", "shared-infrastructure",
        "-m", "Repos every set pulls in."])
      if added.code != 0:
        checkpoint("output: " & added.output)
      check added.code == 0
      let setFile = fx.workspaceRoot / "repo-sets" / "shared-infrastructure.toml"
      check fileExists(setFile)
      # Defined, not enabled — the two axes stay separate.
      check readWorkspaceProjects(fx.workspaceRoot).len == 0
      check readRepoSet(setFile).`repo-set`.name == "shared-infrastructure"

      # ---- first repo: mints ONE org-named prefix -------------------------
      let infra = runRepro(fx, ["ws", "repos", "add", "infra",
        "--set=shared-infrastructure",
        "--remote=https://git.example.invalid/acme/infra",
        "--branch=dev", "-m", "Infrastructure."])
      if infra.code != 0:
        checkpoint("output: " & infra.output)
      check infra.code == 0
      let infraFragment = readRepoFragment(
        fx.workspaceRoot / "repos" / "infra.toml")
      check infraFragment.repo.url_prefix.get("") == "acme"
      check infraFragment.repo.branch.get("") == "dev"
      # The NEW spelling only. A fragment naming a project's `[[remote]]` key
      # is not shareable without every consumer learning that key.
      check infraFragment.repo.remote.isNone
      # `url_suffix` is omitted when it would merely restate `name`.
      check infraFragment.repo.url_suffix.get("") == ""
      let prefixFile = fx.workspaceRoot / "url-prefixes" / "acme.toml"
      check fileExists(prefixFile)
      check readUrlPrefix(prefixFile).`url-prefix`.url ==
        "https://git.example.invalid/acme"
      check "infra" in readRepoSet(setFile).member_repos

      # ---- second repo, same org: reuses the prefix -----------------------
      check runRepro(fx, ["ws", "repos", "add", "garm",
        "--set=shared-infrastructure",
        "--remote=https://git.example.invalid/acme/garm",
        "--branch=dev"]).code == 0
      var prefixCount = 0
      for kind, path in walkDir(fx.workspaceRoot / "url-prefixes"):
        if kind in {pcFile, pcLinkToFile} and path.splitFile.ext == ".toml":
          inc prefixCount
      check prefixCount == 1

      # ---- a fork: its path under the org is NOT its name -----------------
      check runRepro(fx, ["ws", "repos", "add", "reprobuild-cmake",
        "--set=shared-infrastructure",
        "--remote=https://git.example.invalid/kitware/CMake",
        "--branch=reprobuild"]).code == 0
      let forkFragment = readRepoFragment(
        fx.workspaceRoot / "repos" / "reprobuild-cmake.toml")
      check forkFragment.repo.name == "reprobuild-cmake"
      check forkFragment.repo.url_prefix.get("") == "kitware"
      check forkFragment.repo.url_suffix.get("") == "CMake"

      # ---- and it all RESOLVES --------------------------------------------
      let resolved = resolveRepoSet(setFile)
      check resolved.projectName == "shared-infrastructure"
      var byPath: seq[string]
      for repo in resolved.repos:
        byPath.add(repo.path)
      check byPath == @["infra", "garm", "reprobuild-cmake"]
      for repo in resolved.repos:
        check repo.remotes.len >= 1
        check repo.remotes[0].localName == "origin"
        if repo.name == "infra":
          check repo.fetchUrl == "https://git.example.invalid/acme/infra"
          check repo.branch == "dev"
        elif repo.name == "reprobuild-cmake":
          check repo.fetchUrl == "https://git.example.invalid/kitware/CMake"

  test "t_sets_and_projects_are_one_namespace":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "namespace")
      defer: removeDir(fx.scratch)

      # `sets add` will not define a second `alpha` beside the project of that
      # name: to every reader they are one namespace, so two definitions have
      # no answer.
      let clash = runRepro(fx, ["ws", "sets", "add", "alpha"])
      check clash.code == 1
      check clash.output.contains("already exists")
      check clash.output.contains("repro ws enable alpha")
      check not fileExists(fx.workspaceRoot / "repo-sets" / "alpha.toml")

      check runRepro(fx, ["ws", "sets", "add", "beta"]).code == 0
      # The retained spelling still scaffolds a PROJECT, so the alias cannot
      # convert a manifest repo one file at a time behind the operator's back.
      check runRepro(fx, ["ws", "projects", "add", "gamma"]).code == 0
      check fileExists(fx.workspaceRoot / "repo-sets" / "beta.toml")
      check fileExists(fx.workspaceRoot / "projects" / "gamma.toml")

      # ...and one listing covers all three, whichever verb asks.
      let listed = runRepro(fx, ["ws", "sets", "list"])
      check listed.code == 0
      for name in ["alpha", "beta", "gamma"]:
        check listed.output.contains(name & "\tdisabled")
      let aliasListed = runRepro(fx, ["ws", "projects", "list"])
      for name in ["alpha", "beta", "gamma"]:
        check aliasListed.output.contains(name & "\tdisabled")

      # `sets remove` removes either kind.
      check runRepro(fx, ["ws", "sets", "remove", "gamma"]).code == 0
      check not fileExists(fx.workspaceRoot / "projects" / "gamma.toml")

      # ...but not one this workspace is standing on.
      writeWorkspaceProjects(fx.workspaceRoot, @["beta"])
      let refused = runRepro(fx, ["ws", "sets", "remove", "beta"])
      check refused.code == 2
      check refused.output.contains("repro ws disable beta")
      check fileExists(fx.workspaceRoot / "repo-sets" / "beta.toml")

  test "t_repos_add_refuses_mixing_a_set_and_a_project":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "mixed")
      defer: removeDir(fx.scratch)

      check runRepro(fx, ["ws", "sets", "add", "beta"]).code == 0
      let refused = runRepro(fx, ["ws", "repos", "add", "lib-x",
        "--set=beta", "--project=alpha",
        "--remote=https://git.example.invalid/acme/lib-x"])
      check refused.code == 2
      check refused.output.contains("mix")
      # Nothing was written: a refusal that half-applied would be worse than
      # the mixed request it refused.
      check not fileExists(fx.workspaceRoot / "repos" / "lib-x.toml")

  test "t_repos_remove_drops_the_member_and_keeps_the_fragment":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "remove")
      defer: removeDir(fx.scratch)

      check runRepro(fx, ["ws", "sets", "add", "beta"]).code == 0
      check runRepro(fx, ["ws", "sets", "add", "delta"]).code == 0
      check runRepro(fx, ["ws", "repos", "add", "lib-y",
        "--set=beta", "--set=delta",
        "--remote=https://git.example.invalid/acme/lib-y",
        "--branch=dev"]).code == 0
      check "lib-y" in readRepoSet(
        fx.workspaceRoot / "repo-sets" / "beta.toml").member_repos
      check "lib-y" in readRepoSet(
        fx.workspaceRoot / "repo-sets" / "delta.toml").member_repos

      # --delete-fragment is refused while another set still names it.
      let refused = runRepro(fx, ["ws", "repos", "remove", "lib-y",
        "--set=beta", "--delete-fragment"])
      check refused.code == 2
      check fileExists(fx.workspaceRoot / "repos" / "lib-y.toml")
      check "lib-y" notin readRepoSet(
        fx.workspaceRoot / "repo-sets" / "beta.toml").member_repos
      check "lib-y" in readRepoSet(
        fx.workspaceRoot / "repo-sets" / "delta.toml").member_repos

      # With no target it stops declaring the repo everywhere, and the
      # fragment survives as a reusable declaration.
      check runRepro(fx, ["ws", "repos", "remove", "lib-y"]).code == 0
      check "lib-y" notin readRepoSet(
        fx.workspaceRoot / "repo-sets" / "delta.toml").member_repos
      check fileExists(fx.workspaceRoot / "repos" / "lib-y.toml")

      # Now that nothing declares it, deleting it is allowed.
      check runRepro(fx, ["ws", "repos", "remove", "lib-y",
        "--delete-fragment"]).code == 0
      check not fileExists(fx.workspaceRoot / "repos" / "lib-y.toml")

      # ...and with the fragment gone the name resolves to NEITHER namespace,
      # so a later `remove` has no key to edit. It says so and exits 2 rather
      # than stripping whichever array happens to mention the name — a set of
      # that name could legitimately sit in `member_sets`.
      let unguessable = runRepro(fx, ["ws", "repos", "remove", "lib-y",
        "--set=delta"])
      check unguessable.code == 2
      check unguessable.output.contains("resolves to neither")

  test "t_json_surfaces_are_set_based":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "json")
      defer: removeDir(fx.scratch)

      check runRepro(fx, ["ws", "sets", "add", "beta"]).code == 0
      check runRepro(fx, ["ws", "repos", "add", "lib-j",
        "--set=beta",
        "--remote=https://git.example.invalid/acme/lib-j",
        "--branch=dev"]).code == 0

      # ---- sets list --json --------------------------------------------
      let setsJson = runRepro(fx, ["ws", "sets", "list", "--json"])
      check setsJson.code == 0
      let setsDoc = parseJson(setsJson.output)
      check setsDoc["schema"].getStr() == "reprobuild.workspace-sets-list.v1"
      check setsDoc.hasKey("sets")
      # The retired spellings are ABSENT, not merely joined by the new ones:
      # emitting both would leave a consumer free to keep reading the old key
      # and never learn the model changed.
      check not setsDoc.hasKey("projects")
      var names: seq[string]
      for row in setsDoc["sets"]:
        names.add(row["name"].getStr())
      check "alpha" in names   # a project…
      check "beta" in names    # …and a repo-set, in ONE listing.

      # ---- repos list --json -------------------------------------------
      let reposJson = runRepro(fx, ["ws", "repos", "list", "--json",
        "--set=beta"])
      check reposJson.code == 0
      let reposDoc = parseJson(reposJson.output)
      check reposDoc["schema"].getStr() ==
        "reprobuild.workspace-set-repos-list.v1"
      check reposDoc["set"].getStr() == "beta"
      check not reposDoc.hasKey("project")
      var repoNames: seq[string]
      for row in reposDoc["repos"]:
        repoNames.add(row["repo"].getStr())
      check repoNames == @["lib-j"]

      # The retained `--project=` flag names the SAME namespace, so it reports
      # under the same key — the scope word is the model's, not the flag's.
      let aliasJson = runRepro(fx, ["ws", "repos", "list", "--json",
        "--project=beta"])
      check aliasJson.code == 0
      check parseJson(aliasJson.output)["set"].getStr() == "beta"

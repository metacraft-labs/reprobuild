## Workspace metadata resolves at a git REVISION of the metadata repository,
## without a working tree and without writing anything.
##
## reprobuild-pm issue
## `2026-10-09-workspace-metadata-is-readable-only-from-a-working-tree.md`:
## every reader and resolver in `repro_workspace_manifests` took a filesystem
## path, so a project set could only be resolved from a checkout, and the
## string seam `resolveProjectFromString` even WROTE its manifest into the
## tree. The fix routes every read through a `ManifestSource` — a directory,
## or a `(git dir, revision)` pair read with `git ls-tree` / `cat-file`.
##
## Fixture: a real git repository `meta/` holding the metadata layout
## (`url-prefixes/`, `repos/`, `repo-sets/`, `projects/`, `variants/`).
##
##   * Revision A: `app` includes `repos/alpha.toml` and the member set
##     `infra` (= `shared`); variant `app-pinned` overrides alpha's revision;
##     `broken` includes a fragment that does not exist; a set of symlinks is
##     staged through the index (`git update-index --cacheinfo 120000,…`, so
##     the fixture is portable to hosts without filesystem symlinks): one
##     resolving inside the tree, one escaping it, one dangling, a two-link
##     cycle, and a symlinked DIRECTORY.
##   * Revision B: alpha's mainline changes, `infra` gains `beta`, the variant
##     is deleted.
##   * Then the working tree is dirtied (a fragment rewritten, a project
##     deleted, an untracked project added), so any read that observes the
##     working tree resolves something neither revision contains.
##   * `git clone --bare` of it, for the bare-repository case.
##
## Asserted:
##   a. resolution at A and at B (by commit id and by ref name) yields each
##      revision's closure, never the working tree's, in the non-bare repo and
##      in the bare clone alike — the bare clone also under git's
##      `safe.bareRepository=explicit` hardening;
##   b. nothing is written: every file under `.git` (and the bare clone) is
##      byte-identical afterwards, no `worktrees/` appears, and the working
##      tree is unchanged;
##   c. the directory source resolves exactly what the path-based resolver
##      resolves, and the git source at the committed state matches both in
##      every field except the two that name WHERE a manifest was read from
##      (`projectFile`, `fragmentPath`), which carry the documented
##      `<git dir>@<short commit>:<path>` display form;
##   d. `resolveProjectFromString` / `resolveVariantFromString` neither create
##      nor overwrite `basePath`;
##   e. an unknown revision, a non-commit object, a missing include at a
##      revision (diagnostic names the revision display path), and the
##      symlink rule (escaping, dangling and cyclic links refused; an inside
##      link and a symlinked directory followed).
##
## No mocks: real git repositories in a temporary directory, read through the
## real readers and resolvers.

import std/[algorithm, options, os, osproc, sequtils, strutils, tempfiles,
  unittest]
from std/hashes import hash

import repro_workspace_manifests

const FetchBase = "https://git.example.invalid/acme"

proc git(dir: string; args: varargs[string]): string =
  ## Run git in `dir` with a fixed identity; any failure fails the fixture.
  var cmd = "git -C " & quoteShell(dir) &
    " -c user.name=fixture -c user.email=fixture@example.invalid" &
    " -c commit.gpgsign=false -c init.defaultBranch=main"
  for a in args:
    cmd.add(" " & quoteShell(a))
  let (output, code) = execCmdEx(cmd)
  if code != 0:
    raise newException(OSError, cmd & " failed: " & output)
  output.strip()

proc writeManifest(root, relPath, body: string) =
  let abs = root / relPath
  createDir(abs.parentDir)
  writeFile(abs, body)

proc fragment(name, mainline: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n[repo]\n" &
    "name = \"" & name & "\"\npath = \"" & name & "\"\n" &
    "branch = \"" & mainline & "\"\nurl_prefix = \"acme\"\n"

proc repoSet(name: string; memberRepos: openArray[string]): string =
  result = "schema = \"reprobuild.workspace.repo-set.v1\"\n\n" &
    "[repo-set]\nname = \"" & name & "\"\n\nmember_repos = ["
  result.add(memberRepos.mapIt("\"" & it & "\"").join(", "))
  result.add("]\n")

proc project(name: string; includes, memberSets: openArray[string]): string =
  result = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "includes = [" & includes.mapIt("\"" & it & "\"").join(", ") & "]\n" &
    "member_sets = [" & memberSets.mapIt("\"" & it & "\"").join(", ") &
    "]\n\n[project]\nname = \"" & name & "\"\n"

const variantPinned = """schema = "reprobuild.workspace.variant.v1"

[variant]
name = "app-pinned"
base = "projects/app.toml"

[[override]]
fragment = "repos/alpha.toml"
revision = "v1.0"
"""

proc stageSymlink(repo, relPath, target: string) =
  ## Put a symlink (mode 120000) into the index without touching the
  ## filesystem: git stores a link as a blob holding the target bytes.
  let blobFile = repo.parentDir / "link-target.txt"
  writeFile(blobFile, target)
  let oid = git(repo, "hash-object", "-w", blobFile)
  removeFile(blobFile)
  discard git(repo, "update-index", "--add", "--cacheinfo",
    "120000," & oid & "," & relPath)

proc snapshot(root: string): seq[string] =
  ## Every entry under `root` with its kind, size and content hash: a file
  ## created, deleted or rewritten anywhere (refs, index, objects, logs,
  ## worktrees) changes it.
  for path in walkDirRec(root, yieldFilter = {pcFile, pcDir, pcLinkToFile,
                                              pcLinkToDir}):
    let info = getFileInfo(path, followSymlink = false)
    var line = relativePath(path, root) & "\t" & $info.kind & "\t" &
      $info.size
    if info.kind == pcFile:
      line.add("\t" & $hash(readFile(path)))
    result.add(line)
  result.sort()

proc paths(resolved: ResolvedProject): seq[string] =
  resolved.repos.mapIt(it.path)

proc findRepo(resolved: ResolvedProject; path: string): ResolvedRepo =
  for repo in resolved.repos:
    if repo.path == path:
      return repo
  checkpoint("no resolved repo at path '" & path & "'")
  fail()

proc withoutLocations(resolved: ResolvedProject): ResolvedProject =
  ## The resolution with the two fields that name WHERE a manifest was read
  ## from blanked, so a git-source and a directory-source resolution of the
  ## same tree compare equal on everything that is a FACT of the manifests.
  result = resolved
  result.projectFile = ""
  for repo in result.repos.mitems:
    repo.fragmentPath = ""

proc expectManifestError(body: proc ()): string =
  ## The message of the `WorkspaceManifestParseError` `body` raises.
  try:
    body()
  except WorkspaceManifestParseError as e:
    return e.msg
  checkpoint("expected a WorkspaceManifestParseError")
  fail()

proc expectUnresolvedName(body: proc ()): string =
  ## The message of the error the by-name ladder raises for a name no
  ## manifest defines (a `ValueError`, as it always has been).
  try:
    body()
  except ValueError as e:
    return e.msg
  checkpoint("expected the ladder's unresolved-name error")
  fail()

type Fixture = object
  scratch, repo, bare, revA, revB: string

proc setupFixture(): Fixture =
  result.scratch = createTempDir("repro-metadata-at-rev-", "")
  let repo = result.scratch / "meta"
  createDir(repo)
  discard git(repo, "init", "--quiet")
  writeManifest(repo, "url-prefixes/acme.toml",
    "schema = \"reprobuild.workspace.url-prefix.v1\"\n\n" &
    "[url-prefix]\nname = \"acme\"\nurl = \"" & FetchBase & "\"\n")
  writeManifest(repo, "repos/alpha.toml", fragment("alpha", "main"))
  writeManifest(repo, "repos/shared.toml", fragment("shared", "main"))
  writeManifest(repo, "repos/beta.toml", fragment("beta", "main"))
  writeManifest(repo, "repo-sets/infra.toml", repoSet("infra", ["shared"]))
  writeManifest(repo, "projects/app.toml",
    project("app", ["repos/alpha.toml"], ["infra"]))
  writeManifest(repo, "projects/broken.toml",
    project("broken", ["repos/missing.toml"], []))
  writeManifest(repo, "variants/app-pinned.toml", variantPinned)
  # Symlink rule fixtures, staged in the index only.
  writeManifest(repo, "shared-fragments/keep.txt", "a directory to link to\n")
  discard git(repo, "add", "-A")
  stageSymlink(repo, "repos/linked.toml", "alpha.toml")
  stageSymlink(repo, "repos/escape.toml", "../../outside.toml")
  stageSymlink(repo, "repos/absolute.toml", "/etc/hosts")
  stageSymlink(repo, "repos/dangling.toml", "nothere.toml")
  stageSymlink(repo, "repos/loop-a.toml", "loop-b.toml")
  stageSymlink(repo, "repos/loop-b.toml", "loop-a.toml")
  stageSymlink(repo, "linked-repos", "repos")
  for name, target in {"linkok": "repos/linked.toml",
                        "escape": "repos/escape.toml",
                        "absolute": "repos/absolute.toml",
                        "dangling": "repos/dangling.toml",
                        "loop": "repos/loop-a.toml",
                        "viadir": "linked-repos/shared.toml"}.items:
    writeManifest(repo, "projects/" & name & ".toml",
      project(name, [target], []))
    discard git(repo, "add", "projects/" & name & ".toml")
  discard git(repo, "commit", "--quiet", "-m", "revision A")
  result.revA = git(repo, "rev-parse", "HEAD")
  discard git(repo, "tag", "rev-a")

  # Revision B: a changed fragment, a grown set, a deleted variant.
  discard git(repo, "reset", "--quiet", "--hard")
  writeManifest(repo, "repos/alpha.toml", fragment("alpha", "release"))
  writeManifest(repo, "repo-sets/infra.toml",
    repoSet("infra", ["shared", "beta"]))
  removeFile(repo / "variants/app-pinned.toml")
  discard git(repo, "add", "-A")
  discard git(repo, "commit", "--quiet", "-m", "revision B")
  result.revB = git(repo, "rev-parse", "HEAD")

  result.bare = result.scratch / "meta-bare.git"
  discard git(result.scratch, "clone", "--quiet", "--bare", repo, result.bare)

  # Dirty the working tree: every one of these would change the answer if a
  # revision read observed it.
  writeManifest(repo, "repos/alpha.toml", fragment("alpha", "dirty"))
  writeManifest(repo, "repo-sets/infra.toml", repoSet("infra", ["alpha"]))
  removeFile(repo / "projects/broken.toml")
  writeManifest(repo, "projects/untracked.toml",
    project("untracked", ["repos/alpha.toml"], []))
  result.repo = repo

suite "workspace metadata resolves at a git revision":

  test "t_metadata_resolves_at_each_revision_not_the_working_tree":
    let fx = setupFixture()
    defer: removeDir(fx.scratch)
    let gitBefore = snapshot(fx.repo / ".git")
    let treeBefore = snapshot(fx.repo)
    let bareBefore = snapshot(fx.bare)

    for repository in [fx.repo, fx.bare]:
      checkpoint("repository: " & repository)
      for (rev, commit) in [(fx.revA, fx.revA), ("rev-a", fx.revA),
                            (fx.revB, fx.revB), ("main", fx.revB)]:
        let source = openGitRevisionSource(repository, rev)
        defer: source.close()
        check source.resolvedCommit == commit
        let app = resolveProjectSetAt(source, ["app"])
        check app.projectName == "app"
        if commit == fx.revA:
          check paths(app) == @["alpha", "shared"]
          check findRepo(app, "alpha").branch == "main"
          let pinned = resolveProjectSetAt(source, ["app-pinned"])
          check pinned.projectName == "app-pinned"
          check findRepo(pinned, "alpha").revision == "v1.0"
        else:
          check paths(app) == @["alpha", "shared", "beta"]
          check findRepo(app, "alpha").branch == "release"
          # The variant was deleted at B; the ladder must not find it.
          let msg = expectUnresolvedName(proc () =
            discard resolveProjectSetAt(source, ["app-pinned"]))
          check source.displayPath("variants/app-pinned.toml") in msg
          # `broken` still exists at B (it was deleted only in the working
          # tree), and `untracked` exists only in the working tree.
          check "repos/missing.toml" in expectManifestError(proc () =
            discard resolveProjectSetAt(source, ["broken"]))
          check "untracked" in expectUnresolvedName(proc () =
            discard resolveProjectSetAt(source, ["untracked"]))
        check findRepo(app, "shared").fetchUrl == FetchBase & "/shared"
        # The set resolves on its own through the same ladder, and the union
        # dedups the path both names reach.
        let union = resolveProjectSetAt(source, ["app", "infra"])
        check paths(union) == paths(app)
        let display = source.displayPath("projects/app.toml")
        check app.projectFile == display
        check display.endsWith("@" & commit[0 ..< 12] & ":projects/app.toml")

    # `safe.bareRepository=explicit` refuses to DISCOVER a bare repository;
    # naming one explicitly is what it permits, and a source names its
    # repository explicitly. Before the source passed `--git-dir`, this open
    # failed with "cannot use bare repository".
    let hardened = fx.scratch / "hardened.gitconfig"
    writeFile(hardened, "[safe]\n\tbareRepository = explicit\n")
    let priorGlobal = getEnv("GIT_CONFIG_GLOBAL")
    let hadGlobal = existsEnv("GIT_CONFIG_GLOBAL")
    putEnv("GIT_CONFIG_GLOBAL", hardened)
    try:
      let explicitBare = openGitRevisionSource(fx.bare, fx.revA)
      defer: explicitBare.close()
      check explicitBare.resolvedCommit == fx.revA
      check paths(resolveProjectSetAt(explicitBare, ["app"])) ==
        @["alpha", "shared"]
    finally:
      if hadGlobal: putEnv("GIT_CONFIG_GLOBAL", priorGlobal)
      else: delEnv("GIT_CONFIG_GLOBAL")
    removeFile(hardened)

    # Nothing was written anywhere: not the repository's git dir (refs,
    # index, objects, logs, config), not a `worktrees/` entry, not the
    # working tree, not the bare clone.
    check snapshot(fx.repo / ".git") == gitBefore
    check not dirExists(fx.repo / ".git" / "worktrees")
    check snapshot(fx.repo) == treeBefore
    check snapshot(fx.bare) == bareBefore

  test "t_metadata_directory_source_matches_path_resolver_and_git_source":
    let fx = setupFixture()
    defer: removeDir(fx.scratch)
    # Put the working tree back at B, so the three readings share one tree.
    discard git(fx.repo, "checkout", "--quiet", "--", ".")
    discard git(fx.repo, "clean", "--quiet", "-fdx")
    let projectFile = fx.repo / "projects" / "app.toml"
    let byPath = resolveProject(projectFile)
    let dirSource = newDirectorySource(fx.repo)
    let byDir = resolveProjectAt(dirSource, "projects/app.toml")
    check byDir == byPath
    check byDir.projectFile == absolutePath(projectFile)
    check findRepo(byDir, "alpha").fragmentPath ==
      fx.repo / "repos" / "alpha.toml"
    check resolveProjectSet(fx.repo, ["app", "infra"]) ==
      resolveProjectSetAt(dirSource, ["app", "infra"])
    check resolveRepoSet(fx.repo / "repo-sets" / "infra.toml") ==
      resolveRepoSetAt(dirSource, "repo-sets/infra.toml")

    let gitSource = openGitRevisionSource(fx.repo, "HEAD")
    defer: gitSource.close()
    let byGit = resolveProjectAt(gitSource, "projects/app.toml")
    check withoutLocations(byGit) == withoutLocations(byPath)
    check findRepo(byGit, "alpha").fragmentPath ==
      gitSource.displayPath("repos/alpha.toml")

    # The variant composer over both sources, at A (where it exists).
    let atA = openGitRevisionSource(fx.repo, fx.revA)
    defer: atA.close()
    discard git(fx.repo, "checkout", "--quiet", fx.revA, "--", ".")
    let variantByPath = resolveVariant(fx.repo / "variants" / "app-pinned.toml")
    let variantByGit = resolveVariantAt(atA, "variants/app-pinned.toml")
    check withoutLocations(variantByGit) == withoutLocations(variantByPath)

  test "t_metadata_from_string_does_not_write_base_path":
    let fx = setupFixture()
    defer: removeDir(fx.scratch)
    discard git(fx.repo, "checkout", "--quiet", "--", ".")
    discard git(fx.repo, "clean", "--quiet", "-fdx")
    let inline = project("inline", ["repos/alpha.toml"], ["infra"])
    # A basePath that does not exist must not be created...
    let fresh = fx.repo / "projects" / "inline.toml"
    let resolved = resolveProjectFromString(inline, fresh)
    check resolved.projectName == "inline"
    check resolved.projectFile == fresh
    check paths(resolved) == @["alpha", "shared", "beta"]
    check not fileExists(fresh)
    # ...and one that does exist must not be overwritten.
    let existing = fx.repo / "projects" / "app.toml"
    let before = readFile(existing)
    check resolveProjectFromString(inline, existing).projectName == "inline"
    check readFile(existing) == before
    # The variant seam, likewise.
    let variantPath = fx.repo / "variants" / "inline-variant.toml"
    let variant = resolveVariantFromString(
      variantPinned.replace("name = \"app-pinned\"",
                            "name = \"inline-variant\""), variantPath)
    check variant.projectName == "inline-variant"
    check findRepo(variant, "alpha").revision == "v1.0"
    check not fileExists(variantPath)
    check not dirExists(fx.repo / "variants")

  test "t_metadata_revision_source_refusals":
    let fx = setupFixture()
    defer: removeDir(fx.scratch)

    # An unknown revision, and an object that is not a commit.
    let unknown = expectManifestError(proc () =
      discard openGitRevisionSource(fx.repo, "no-such-ref"))
    check "no-such-ref" in unknown
    let tree = git(fx.repo, "rev-parse", fx.revA & "^{tree}")
    check "does not resolve to a commit" in expectManifestError(proc () =
      discard openGitRevisionSource(fx.repo, tree))
    # Option-shaped revisions are not passed to git as options.
    check "--all" in expectManifestError(proc () =
      discard openGitRevisionSource(fx.repo, "--all"))
    # A directory that is not a repository — including one INSIDE a
    # repository, which must not be resolved against the enclosing one.
    check "not a git repository" in expectManifestError(proc () =
      discard openGitRevisionSource(fx.scratch, "HEAD"))
    check "not a git repository" in expectManifestError(proc () =
      discard openGitRevisionSource(fx.repo / "projects", "HEAD"))

    let source = openGitRevisionSource(fx.bare, fx.revA)
    defer: source.close()
    # A missing include at a revision names the revision display path.
    let missing = expectManifestError(proc () =
      discard resolveProjectSetAt(source, ["broken"]))
    check source.displayPath("projects/broken.toml") in missing
    check source.displayPath("repos/missing.toml") in missing

    # Symlinks: a link inside the committed tree is followed (to a file and
    # through a directory); escaping, absolute, dangling and cyclic links are
    # refused.
    let linked = resolveProjectSetAt(source, ["linkok"])
    check paths(linked) == @["alpha"]
    check paths(resolveProjectSetAt(source, ["viadir"])) == @["shared"]
    check source.readText("repos/linked.toml") ==
      source.readText("repos/alpha.toml")
    for name in ["escape", "absolute"]:
      check "escapes the committed tree" in expectManifestError(proc () =
        discard resolveProjectSetAt(source, [name]))
    check "dangling" in expectManifestError(proc () =
      discard resolveProjectSetAt(source, ["dangling"]))
    check "cycl" in expectManifestError(proc () =
      discard resolveProjectSetAt(source, ["loop"]))

    # Directories and absent paths are not files; listing is sorted and
    # names only `.toml` entries of that directory.
    check source.readText("repos").isNone
    check source.readText("repos/nope.toml").isNone
    check not source.hasFile("projects")
    check source.hasFile("projects/app.toml")
    check source.listTomlFiles("url-prefixes") == @["url-prefixes/acme.toml"]
    check source.listTomlFiles("no-such-dir").len == 0
    let repos = source.listTomlFiles("repos")
    check repos == repos.sorted()
    check "repos/alpha.toml" in repos

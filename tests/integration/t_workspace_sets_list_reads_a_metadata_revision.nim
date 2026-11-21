## `repro workspace sets list --at=REV` (and its retained spelling
## `projects list`) lists the names the manifest repository DEFINES AT A
## COMMIT, read from the repository's objects: no working tree is needed and
## nothing is written.
##
## reprobuild-pm issue
## `2026-11-17-projects-list-cannot-read-the-projects-of-a-metadata-revision.md`:
## `resolve <name>... --at=REV` evaluated a project set as a pure function of
## *(metadata repository, revision, selection)*, but nothing listed the names
## a revision defines, so the function could be evaluated only for a name the
## caller already knew. `list` rejected `--at` as an unknown flag, and in a
## bare repository had no working tree to read.
##
## Fixture: a flat workspace (its root is the manifests root) made a git
## repository.
##
##   * Revision A defines `projects/{alpha,beta,gamma}.toml`.
##   * Revision B deletes `gamma` and adds `projects/delta.toml`,
##     `variants/vee.toml` and `repo-sets/infra.toml` (the three directories
##     are one namespace), plus a `repo-sets/alpha.toml` whose name a project
##     already carries (listed once), and four entries that are not names in
##     a working tree and so must not be names at a revision either:
##     `projects/notes.md`, the dot-file `projects/.toml`, a directory
##     `projects/dir.toml/`, and `projects/dirlink.toml`, a symlink to a
##     directory (staged through the index, so the fixture needs no
##     filesystem symlinks). A symlink to a file, `projects/link.toml`, IS a
##     name.
##   * The working tree is then dirtied: `alpha` deleted, an untracked `omega`
##     added. `alpha` is the workspace's one ENABLED set.
##   * `git clone --bare` of it, for the no-working-tree case.
##
## Asserted:
##   1. `--at=A` and `--at=B` (by commit id and by ref name) each list exactly
##      that revision's names, sorted, never the working tree's; the JSON
##      report keeps schema `reprobuild.workspace-sets-list.v1`, carries the
##      full commit id as `metadataRevision`, an empty `primary`, and
##      `enabled: false` for every set — including the one this workspace has
##      enabled, because a revision has no membership;
##   2. `sets list`, `projects list` and the bare namespace are one command;
##   3. the human form prints `<name>\tdisabled` per name;
##   4. it works on a bare clone, where there is no working tree at all,
##      named by `--workspace-root` or by being the current directory;
##   5. without `--at` the working tree is listed and no `metadataRevision` is
##      claimed;
##   6. `--enabled` / `--disabled` with `--at` and an empty `--at=` are usage
##      errors (exit 2); a root that is not a git repository and a revision
##      that names no commit fail (exit 1) with nothing on stdout;
##   7. nothing is written: `.git`, the bare clone and the working tree are
##      unchanged, and no `worktrees/` appears.
##
## No mocks: the real `repro` binary against real git repositories in a
## temporary directory.

import std/[algorithm, json, os, osproc, sequtils, strutils, tempfiles, times,
  unittest]

import repro_test_support
import repro_workspace_manifests

const
  ListSchema = "reprobuild.workspace-sets-list.v1"
  FetchBase = "https://git.example.invalid/acme"

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc projectFile(name: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"" & name & "\"\n\n" &
    "[[remote]]\nname = \"acme\"\nfetch = \"" & FetchBase & "\"\n\n" &
    "includes = [\n]\n"

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

proc treeSnapshot(root: string): seq[string] =
  ## Every path under `root` with its size and mtime — enough to see a file
  ## created, removed or rewritten by a command that claims to be read-only.
  for path in walkDirRec(root, yieldFilter = {pcFile, pcDir, pcLinkToFile,
      pcLinkToDir}, checkDir = false):
    var entry = path.relativePath(root)
    try:
      let info = getFileInfo(path, followSymlink = false)
      entry.add(" " & $info.size & " " & $info.lastWriteTime.toUnix)
    except CatchableError:
      entry.add(" ?")
    result.add(entry)
  result.sort()

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string

proc run(fx: Fixture; args: openArray[string]): CmdSplitResult =
  ## Run from the scratch dir, OUTSIDE the workspace, so only the explicit
  ## `--workspace-root=` can name it.
  var argv = @[fx.reproBin]
  for a in args: argv.add(a)
  argv.add("--workspace-root=" & fx.workspaceRoot)
  runShellSplit(shellCommand(argv), cwd = fx.scratch)

proc setNames(doc: JsonNode): seq[string] =
  for s in doc["sets"]:
    result.add(s["name"].getStr)

suite "workspace sets list --at — the names a metadata revision defines":

  test "t_workspace_sets_list_at_revision_reads_the_commit_not_the_working_tree":
    var fx = Fixture(
      scratch: createTempDir("repro-sets-list-at-", ""),
      reproBin: reproBinary())
    defer: removeDir(fx.scratch)
    let root = fx.scratch / "workspace"
    fx.workspaceRoot = root
    createDir(root / "projects")
    for name in ["alpha", "beta", "gamma"]:
      writeFile(root / "projects" / (name & ".toml"), projectFile(name))
    # `alpha` is enabled here, so a listing that consulted this workspace's
    # membership would mark it so.
    writeWorkspaceProjects(root, @["alpha"])

    # Before the repository exists `--at` has no history to read. It fails,
    # and prints no listing a consumer could mistake for an empty revision.
    let notRepo = fx.run(["ws", "projects", "list", "--at=HEAD", "--json"])
    check notRepo.code == 1
    check notRepo.stdout.strip.len == 0
    check "not a git repository" in notRepo.stderr

    discard git(root, "init", "--quiet")
    discard git(root, "add", "projects")
    discard git(root, "commit", "--quiet", "-m", "revision A")
    let revA = git(root, "rev-parse", "HEAD")

    removeFile(root / "projects" / "gamma.toml")
    writeFile(root / "projects" / "delta.toml", projectFile("delta"))
    writeFile(root / "projects" / "notes.md", "not a definition\n")
    writeFile(root / "projects" / ".toml", "# a dot-file, not a name\n")
    createDir(root / "projects" / "dir.toml")
    writeFile(root / "projects" / "dir.toml" / "inner.toml", "# nested\n")
    createDir(root / "variants")
    writeFile(root / "variants" / "vee.toml", "# listed, never parsed\n")
    createDir(root / "repo-sets")
    writeFile(root / "repo-sets" / "infra.toml", "# listed, never parsed\n")
    writeFile(root / "repo-sets" / "alpha.toml", "# the name of a project\n")
    discard git(root, "add", "-A", "projects", "variants", "repo-sets")
    # Two links, staged as index entries: one to a file, one to a directory.
    for link in [("link.toml", "beta.toml"), ("dirlink.toml", "dir.toml")]:
      let (oid, code) = execCmdEx("git -C " & quoteShell(root) &
        " hash-object -w --stdin", input = link[1])
      check code == 0
      discard git(root, "update-index", "--add", "--cacheinfo",
        "120000," & oid.strip() & ",projects/" & link[0])
    discard git(root, "commit", "--quiet", "-m", "revision B")
    let revB = git(root, "rev-parse", "HEAD")
    check revA != revB

    # The working tree now disagrees with both revisions. (The two links
    # exist only in the index and the commit; the tree never had them.)
    removeFile(root / "projects" / "alpha.toml")
    writeFile(root / "projects" / "omega.toml", projectFile("omega"))

    let bare = fx.scratch / "meta-bare.git"
    discard git(fx.scratch, "clone", "--quiet", "--bare", root, bare)

    let gitBefore = treeSnapshot(root / ".git")
    let treeBefore = treeSnapshot(root)
    let bareBefore = treeSnapshot(bare)

    const
      NamesA = @["alpha", "beta", "gamma"]
      NamesB = @["alpha", "beta", "delta", "infra", "link", "vee"]

    proc listAt(spelling: openArray[string]; rev: string): JsonNode =
      let res = fx.run(@spelling & @["--at=" & rev, "--json"])
      if res.code != 0:
        checkpoint("stdout: " & res.stdout & "\nstderr: " & res.stderr)
      check res.code == 0
      parseJson(res.stdout)

    proc checkRevisionListing(doc: JsonNode; names: seq[string];
                              commit: string) =
      check doc["schema"].getStr == ListSchema
      check setNames(doc) == names
      check doc["metadataRevision"].getStr == commit
      check doc["primary"].getStr == ""
      for s in doc["sets"]:
        check s["enabled"].getBool == false
        check s["defined"].getBool == true

    # 1. Each revision's names, by commit id and by ref name.
    checkRevisionListing(listAt(["ws", "projects", "list"], revA), NamesA,
      revA)
    checkRevisionListing(listAt(["ws", "projects", "list"], revB), NamesB,
      revB)
    checkRevisionListing(listAt(["ws", "projects", "list"], "main"), NamesB,
      revB)
    # 2. One command under three spellings; `--all` is the default it names,
    # and overrides a selector as it does without `--at`.
    checkRevisionListing(listAt(["ws", "sets", "list"], revA), NamesA, revA)
    checkRevisionListing(listAt(["ws", "sets"], revA), NamesA, revA)
    checkRevisionListing(listAt(["ws", "projects"], revA), NamesA, revA)
    checkRevisionListing(listAt(["ws", "sets", "list", "--all"], revA),
      NamesA, revA)
    checkRevisionListing(listAt(["ws", "sets", "list", "--all", "--enabled"],
      revA), NamesA, revA)

    # 3. The human form.
    let human = fx.run(["ws", "sets", "list", "--at=" & revA])
    check human.code == 0
    check human.stdout.strip.splitLines == NamesA.mapIt(it & "\tdisabled")

    # 4. In a bare clone there is no working tree to list at all. Named
    # explicitly, and then found as the current directory (the scratch
    # directory is inside no workspace, so nothing encloses it).
    let namedBare = runShellSplit(shellCommand(@[fx.reproBin, "ws", "projects",
      "list", "--json", "--at=" & revB, "--workspace-root=" & bare]),
      cwd = fx.scratch)
    if namedBare.code != 0:
      checkpoint("stdout: " & namedBare.stdout & "\nstderr: " &
        namedBare.stderr)
    check namedBare.code == 0
    checkRevisionListing(parseJson(namedBare.stdout), NamesB, revB)
    let inBare = runShellSplit(shellCommand(@[fx.reproBin, "ws", "projects",
      "list", "--json", "--at=" & revA]), cwd = bare)
    if inBare.code != 0:
      checkpoint("stdout: " & inBare.stdout & "\nstderr: " & inBare.stderr)
    check inBare.code == 0
    checkRevisionListing(parseJson(inBare.stdout), NamesA, revA)
    let bareHead = runShellSplit(shellCommand(@[fx.reproBin, "ws", "sets",
      "list", "--json", "--at=HEAD"]), cwd = bare)
    check bareHead.code == 0
    checkRevisionListing(parseJson(bareHead.stdout), NamesB, revB)

    # 5. Without --at the working tree is what is listed (the untracked
    # `omega`; the enabled `alpha` leads, though its project file is gone and
    # only the repo-set of that name still defines it), and no revision is
    # claimed.
    let plain = fx.run(["ws", "projects", "list", "--json"])
    check plain.code == 0
    let plainDoc = parseJson(plain.stdout)
    check setNames(plainDoc) ==
      @["alpha", "beta", "delta", "infra", "omega", "vee"]
    check plainDoc["primary"].getStr == "alpha"
    check plainDoc["sets"][0]["enabled"].getBool == true
    check not plainDoc.hasKey("metadataRevision")

    # 6. Refusals.
    for selector in ["--enabled", "--disabled"]:
      let refused = fx.run(["ws", "sets", "list", selector, "--at=" & revA,
        "--json"])
      check refused.code == 2
      check refused.stdout.strip.len == 0
      check "membership" in refused.stderr
    let emptyAt = fx.run(["ws", "sets", "list", "--at="])
    check emptyAt.code == 2
    check emptyAt.stdout.strip.len == 0
    let unknown = fx.run(["ws", "sets", "list", "--at=no-such-rev", "--json"])
    check unknown.code == 1
    check unknown.stdout.strip.len == 0
    check "no-such-rev" in unknown.stderr

    # 7. Read-only.
    check treeSnapshot(root / ".git") == gitBefore
    check not dirExists(root / ".git" / "worktrees")
    check treeSnapshot(root) == treeBefore
    check treeSnapshot(bare) == bareBefore
    check not dirExists(bare / "worktrees")

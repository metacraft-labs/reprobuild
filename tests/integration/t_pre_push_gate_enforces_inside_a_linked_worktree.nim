## The publication gate must ENFORCE from inside a linked git worktree.
##
## `repro check --mode=pre-push` resolves its workspace root by walking UP from
## `--current-repo`. A linked worktree is checked out ANYWHERE — commonly a
## scratch directory outside the workspace entirely — so that ascent passes
## through no workspace at all: `<root>/.repro/workspace.toml`,
## `<root>/.repro/manifests/*.toml` and `<root>/repro.lock` are all probed at
## paths that are not there. The gate then reported "not a workspace; nothing
## to enforce" and exited 0.
##
## That is fail-OPEN, the one direction a publication gate must never fail:
## every push made from a worktree landed unverified while printing a success.
##
## The fix is the resolution Unified-Locking-And-Hooks.md §4.3 already mandates
## for VCS-private paths — `git rev-parse --git-common-dir`, "because a
## worktree's `.git` is a file, and its private dir is the common dir" — and
## that push-hook-publication-protocol.md requires for binding canonical
## worktree identity. The common dir walks a linked worktree back to the
## repository it belongs to, and the ascent continues from there.
##
## Both directions are asserted, so the test cannot pass vacuously:
##
##   * a linked worktree of a repo inside a bona fide workspace must ENFORCE
##     (and must resolve the WORKSPACE root, not the worktree directory);
##   * a linked worktree of a plain git repo that is in no workspace must still
##     NO-OP with exit 0 — the fix must not manufacture a workspace out of the
##     common dir's parent.
##
## No mocks: real git repositories, a real `git worktree add`, a real local bare
## origin (so publication checks stay offline), and the built `repro` binary.

import std/[os, osproc, strutils, unittest]

const SourceRoot = currentSourcePath().parentDir.parentDir.parentDir
const ReproBinary = SourceRoot / "build" / "bin" / addFileExt("repro", ExeExt)

proc q(value: string): string = quoteShell(value)

proc run(command: string): tuple[code: int; output: string] =
  let res = execCmdEx(command, options = {poStdErrToStdOut, poUsePath})
  (res.exitCode, res.output)

proc git(gitBin, repo, rest: string): tuple[code: int; output: string] =
  if repo.len == 0: run(q(gitBin) & " " & rest)
  else: run(q(gitBin) & " -C " & q(repo) & " " & rest)

proc requireGit(gitBin, repo, rest: string) =
  let res = git(gitBin, repo, rest)
  if res.code != 0:
    raise newException(IOError, "git failed: " & rest & "\nexit=" &
      $res.code & "\n" & res.output)

proc seedRepo(gitBin, path, origin: string) =
  ## A real git repo with one commit, published to a local bare origin, so the
  ## gate's publication checks resolve offline instead of reaching a network.
  requireGit(gitBin, "", "init --bare -b main " & q(origin))
  createDir(path)
  requireGit(gitBin, "", "init -b main " & q(path))
  requireGit(gitBin, path, "config user.email gate@example.invalid")
  requireGit(gitBin, path, "config user.name \"Gate Fixture\"")
  writeFile(path / "README.md", "linked-worktree gate fixture\n")
  requireGit(gitBin, path, "add README.md")
  requireGit(gitBin, path, "commit -m seed")
  requireGit(gitBin, path, "remote add origin " & q(origin))
  requireGit(gitBin, path, "push -u origin main")

proc checkPrePush(currentRepo: string): tuple[code: int; output: string] =
  ## Exactly the shape the managed pre-push hook uses: `--current-repo` is the
  ## pushed repo's toplevel and `--workspace-root` is deliberately OMITTED, so
  ## the resolver under test is the one that decides.
  run(q(ReproBinary) & " check --mode=pre-push --current-repo=" & q(currentRepo))

const NoopMarker = "not a workspace"

suite "the publication gate enforces inside a linked worktree":
  test "t_pre_push_gate_enforces_inside_a_linked_worktree":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs real repositories and a real " &
        "`git worktree add`")
    elif not fileExists(ReproBinary):
      skip("build/bin/repro is missing; run `just build` first — this case " &
        "drives the real gate through the built binary")
    else:
      let scratch = getTempDir() / "repro-wt-gate-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      # Local bare origins, so every remote the gate consults is on disk and
      # the test never touches a network.
      let origins = scratch / "origins"
      createDir(origins)

      # ---- a bona fide workspace: marker + resolved manifest checkout ----
      let workspace = scratch / "workspace"
      createDir(workspace)
      createDir(workspace / ".repro")
      writeFile(workspace / ".repro" / "workspace.toml", """
schema = "reprobuild.workspace.local.v1"

[workspace]
project = "demo"
""")
      createDir(workspace / "projects")
      # `member_repos` MUST precede the `[project]` header: a bare array after a
      # table header binds to that table, and the strict reader then rejects
      # `project.member_repos`.
      writeFile(workspace / "projects" / "demo.toml", """
schema = "reprobuild.workspace.project.v1"

member_repos = [
  "member",
]

[project]
name = "demo"
""")
      createDir(workspace / "repos")
      writeFile(workspace / "repos" / "member.toml", """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "member"
path = "member"
url_prefix = "example"
branch = "main"
""")
      createDir(workspace / "url-prefixes")
      writeFile(workspace / "url-prefixes" / "example.toml",
        "schema = \"reprobuild.workspace.url-prefix.v1\"\n\n" &
        "[url-prefix]\n" &
        "name = \"example\"\n" &
        "url = \"" & origins & "\"\n")

      let member = workspace / "member"
      seedRepo(gitBin, member, origins / "member")

      # The linked worktree lives OUTSIDE the workspace, which is what makes a
      # plain path ascent from it miss the workspace entirely.
      let linked = scratch / "linked-worktree"
      requireGit(gitBin, member,
        "worktree add --detach " & q(linked) & " HEAD")
      check fileExists(linked / ".git")   # a worktree's .git is a FILE
      check not linked.isRelativeTo(workspace)

      # ---- a plain git repo in NO workspace, plus a worktree of it ----
      let plain = scratch / "plain"
      seedRepo(gitBin, plain, origins / "plain")
      let plainLinked = scratch / "plain-linked-worktree"
      requireGit(gitBin, plain,
        "worktree add --detach " & q(plainLinked) & " HEAD")

      # ---- ENFORCE: the worktree must resolve the workspace above its repo --
      let enforced = checkPrePush(linked)
      check NoopMarker notin enforced.output
      check "pre-push gate is a no-op" notin enforced.output
      # The gate announces its resolved mode/project once it is enforcing.
      check "mode=pre-push" in enforced.output
      # ...and it must have resolved the WORKSPACE, never the worktree dir.
      check linked notin enforced.output

      # ---- NO-OP: a plain repo's worktree must NOT become a workspace -------
      let plainWt = checkPrePush(plainLinked)
      check NoopMarker in plainWt.output
      check plainWt.code == 0

      # ---- and the plain repo's MAIN tree keeps no-opping as before ---------
      let plainMain = checkPrePush(plain)
      check NoopMarker in plainMain.output
      check plainMain.code == 0

      # ---- the cwd-based resolver must agree with the hook-based one --------
      # `repro prompt` resolves by walking up from the CWD rather than from
      # `--current-repo`, so it is the second resolver the same defect reached:
      # run from a linked worktree it reported no workspace at all. Both
      # directions again, so the walk cannot be vacuously true.
      let previousDir = getCurrentDir()
      defer: setCurrentDir(previousDir)

      setCurrentDir(linked)
      let promptInWorkspace = run(q(ReproBinary) & " prompt")
      check promptInWorkspace.code == 0
      check promptInWorkspace.output.strip().len > 0

      setCurrentDir(plainLinked)
      let promptOutside = run(q(ReproBinary) & " prompt")
      check promptOutside.code == 0
      check promptOutside.output.strip().len == 0

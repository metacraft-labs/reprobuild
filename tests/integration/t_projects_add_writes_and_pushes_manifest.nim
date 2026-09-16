## RA-6 — `repro workspace projects add` writes + commits + pushes a project
## manifest to the manifest repo (hermetic: a local bare upstream).
##
## The manifest repo (the workspace root) is a real git repo whose `origin`
## is a local bare repo. `repro workspace projects add <name>` writes
## `projects/<name>.toml`, commits it, and pushes to the bare. The test
## asserts: the project file exists locally, a commit landed, and the bare
## upstream received the commit (the project file is present in the bare's
## tree).
##
## `repos add` then records a repo fragment + membership edge and pushes again.
## The edge is asserted to be the SETS one — the repo as a name under
## `member_repos` — because a project scaffolded with no `--template` carries
## neither membership array, and "which spelling does a brand-new project get"
## is decided here and nowhere else. It used to get the deprecated `includes`
## array, so every project created by this CLI was born on the superseded
## mechanism.
##
## The second case pins WHICH repository those verbs act on: a workspace root
## that is a plain directory nested inside an unrelated checkout must be
## refused, with that enclosing repository left without a commit, with nothing
## staged and with a clean tracked tree.
##
## Skip rule: `git` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc gitConfig(gitBin, repoPath: string) =
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.name \"RA6 Tester\"")

suite "RA-6/WV-3 — repro workspace projects add (writes + pushes manifest)":

  test "test_ra6_projects_add_and_repos_add_push_to_bare_upstream":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra6-projnew-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      # Bare manifest upstream.
      let bare = scratch / "manifests.git"
      discard requireGit(q(gitBin) & " init --bare -b main " & q(bare))

      # Workspace with a real manifest repo whose origin is the bare.
      let workspaceRoot = scratch / "workspace"
      let manifestRoot = workspaceRoot
      createDir(manifestRoot)
      discard requireGit(q(gitBin) & " init -b main " & q(manifestRoot))
      gitConfig(gitBin, manifestRoot)
      writeFile(manifestRoot / "README.md", "RA6 manifest\n")
      discard requireGit(q(gitBin) & " -C " & q(manifestRoot) &
        " add README.md")
      discard requireGit(q(gitBin) & " -C " & q(manifestRoot) &
        " commit -m init")
      discard requireGit(q(gitBin) & " -C " & q(manifestRoot) &
        " remote add origin " & q(bare))
      discard requireGit(q(gitBin) & " -C " & q(manifestRoot) &
        " push -u origin main")

      # `projects add myproj`.
      let newRes = runShell(shellCommand(@[reproBin, "workspace", "projects",
        "add", "myproj", "-m", "My project",
        "--workspace-root=" & workspaceRoot]))
      if newRes.code != 0:
        checkpoint("new output: " & newRes.output)
      check newRes.code == 0

      # The project file landed locally.
      check fileExists(manifestRoot / "projects" / "myproj.toml")
      # A commit landed.
      let log = requireGit(q(gitBin) & " -C " & q(manifestRoot) &
        " log --oneline")
      check log.contains("Add project myproj")
      # The bare upstream received the project file (git show on the bare).
      let bareShow = runCmd(q(gitBin) & " -C " & q(bare) &
        " show main:projects/myproj.toml")
      check bareShow.code == 0
      check bareShow.output.contains("name = \"myproj\"")
      # The command reported a push.
      check newRes.output.contains("pushed")

      # `repos add lib-x --project=myproj --remote=...`.
      let addRes = runShell(shellCommand(@[reproBin, "workspace", "repos",
        "add", "lib-x", "--project=myproj",
        "--remote=https://example.invalid/lib-x.git", "--branch=dev",
        "--workspace-root=" & workspaceRoot]))
      if addRes.code != 0:
        checkpoint("repo add output: " & addRes.output)
      check addRes.code == 0
      check fileExists(manifestRoot / "repos" / "lib-x.toml")
      # The membership edge landed in the project file, pushed to the bare.
      let bareProj = runCmd(q(gitBin) & " -C " & q(bare) &
        " show main:projects/myproj.toml")
      check bareProj.code == 0
      # On the SETS mechanism — the repo as a NAME under `member_repos` —
      # not as a fragment path under the deprecated `includes`.
      #
      # This is the one file kind that reaches the authoring path with NEITHER
      # array present: `projects add` with no `--template` scaffolds a manifest
      # carrying only `schema` and `[project]`. It used to be authored as an
      # `includes` edge, which made every freshly created project the one shape
      # a manifest conversion exists to remove — none of the project manifests
      # in the metacraft manifest repo carries `includes` any more.
      check bareProj.output.contains("member_repos")
      check bareProj.output.contains("\"lib-x\"")
      check not bareProj.output.contains("includes")
      check not bareProj.output.contains("repos/lib-x.toml")
      # And the array PARSES BACK as a top-level key, which is the trap this
      # file is uniquely exposed to: with no array to extend, the writer takes
      # its new-array fallback, and a bare `member_repos = [ … ]` appended
      # after the `[project]` header would be standard-TOML-bound to that
      # table — the strict decode would then reject `project.member_repos` and
      # the manifest would stop parsing entirely. Asserted through the reader
      # rather than by eyeballing the text, because the text looks identical
      # either way; only the position differs.
      let m = readProjectManifest(manifestRoot / "projects" / "myproj.toml")
      check m.member_repos == @["lib-x"]
      check m.includes.len == 0
      # The edge RESOLVES: the repo is listed for the project by the same CLI
      # surface an operator would use to check.
      let listRes = runShell(shellCommand(@[reproBin, "workspace", "repos",
        "list", "--project=myproj", "--workspace-root=" & workspaceRoot]))
      if listRes.code != 0:
        checkpoint("repos list output: " & listRes.output)
      check listRes.code == 0
      check listRes.output.contains("lib-x")

  test "test_ra6_projects_add_refuses_a_workspace_root_inside_another_checkout":
    ## The manifest verbs commit and PUSH; which repository they act on is
    ## decided by Git's repository discovery, which walks UPWARDS. With a
    ## workspace root that is a plain directory nested inside somebody else's
    ## checkout, ``git -C <workspace-root> add -- projects/x.toml`` succeeds
    ## against that ENCLOSING repository — these are ordinary new files, so no
    ## ignore rule intervenes — ``git commit`` writes a commit there, and the
    ## push publishes that repository's branch. Not forcing the stage is no
    ## protection: only asking whether the root IS a checkout root is.
    ##
    ## Falsifiable: the command must fail with a diagnostic naming the
    ## not-a-checkout root, and the enclosing repository must gain no commit,
    ## stage nothing, and keep a clean tracked tree. Hermetic: one local
    ## ``git init``; no upstream, no network.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra6-nested-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      let outer = scratch / "outer"
      createDir(outer)
      discard requireGit(q(gitBin) & " init -b main " & q(outer))
      gitConfig(gitBin, outer)
      writeFile(outer / "README.md", "unrelated checkout\n")
      discard requireGit(q(gitBin) & " -C " & q(outer) & " add README.md")
      discard requireGit(q(gitBin) & " -C " & q(outer) & " commit -m seed")
      let outerCommits = requireGit(q(gitBin) & " -C " & q(outer) &
        " rev-list --count HEAD").strip()

      # A plain directory inside it, handed to the manifest verb as the
      # workspace (and therefore manifest-repo) root.
      let nested = outer / "workspace"
      createDir(nested)
      let res = runShell(shellCommand(@[reproBin, "workspace", "projects",
        "add", "nested-proj", "-m", "Nested", "--workspace-root=" & nested]))
      checkpoint("nested projects add output: " & res.output)
      check res.code != 0
      check res.output.contains("is not a git checkout")
      check res.output.contains(nested)

      # The enclosing repository took no part: no commit, nothing staged, no
      # tracked change. (The written manifest file is left as untracked
      # residue of the refused verb; that is not a publication side effect.)
      check requireGit(q(gitBin) & " -C " & q(outer) &
        " rev-list --count HEAD").strip() == outerCommits
      let staged = runCmd(q(gitBin) & " -C " & q(outer) &
        " diff --cached --name-only")
      check staged.code == 0
      check staged.output.strip().len == 0
      let porcelain = runCmd(q(gitBin) & " -C " & q(outer) &
        " status --porcelain --untracked-files=no")
      check porcelain.code == 0
      check porcelain.output.strip().len == 0

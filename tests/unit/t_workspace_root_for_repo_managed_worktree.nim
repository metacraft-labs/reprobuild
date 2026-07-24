## Test fixture-root discovery from an Android-repo-managed Git common dir.
##
## A linked worktree may live under /tmp while the primary workspace uses the
## ``<workspace>/.repo/projects/<repo>.git`` layout. An unrelated, incomplete
## sibling directory beside the worktree must not hide the real workspace.

import std/[os, osproc, tempfiles, unittest]

import repro_test_support

proc q(value: string): string = quoteShell(value)

proc require(command: string) =
  let res = execCmdEx(command, options = {poStdErrToStdOut, poUsePath})
  if res.exitCode != 0:
    checkpoint(command & "\n" & res.output)
  require res.exitCode == 0

suite "workspace root discovery for repo-managed worktrees":
  test "ignores an incomplete temp sibling and follows .repo common dir":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-workspace-root-repo-layout-", "")
      defer: removeDir(scratch)
      let workspace = scratch / "workspace"
      let commonDir = workspace / ".repo" / "projects" / "reprobuild.git"
      let seed = scratch / "seed"
      let outside = scratch / "outside"
      let worktree = outside / "reprobuild"
      createDir(commonDir.parentDir)
      createDir(outside / "codetracer")
      createDir(workspace / "reprobuild-examples")

      require(q(gitBin) & " init --bare -b main " & q(commonDir))
      require(q(gitBin) & " init -b main " & q(seed))
      require(q(gitBin) & " -C " & q(seed) &
        " -c user.email=test@example.invalid -c user.name=Test" &
        " commit --allow-empty -m seed")
      require(q(gitBin) & " -C " & q(seed) & " remote add origin " &
        q(commonDir))
      require(q(gitBin) & " -C " & q(seed) & " push origin main")
      require(q(gitBin) & " --git-dir=" & q(commonDir) & " worktree add " &
        q(worktree) & " main")

      check sameFile(workspaceRootForRepo(worktree), workspace)

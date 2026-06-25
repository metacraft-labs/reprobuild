## RA-6 — `repro workspace project new` writes + commits + pushes a project
## manifest to the manifest repo (hermetic: a local bare upstream).
##
## The manifest repo (`.repo/manifests`) is a real git repo whose `origin`
## is a local bare repo. `repro workspace project new <name>` writes
## `projects/<name>.toml`, commits it, and pushes to the bare. The test
## asserts: the project file exists locally, a commit landed, and the bare
## upstream received the commit (the project file is present in the bare's
## tree).
##
## `project repo add` then records a repo fragment + include and pushes again.
##
## Skip rule: `git` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support

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

suite "RA-6 — repro workspace project new (writes + pushes manifest)":

  test "test_ra6_project_new_and_repo_add_push_to_bare_upstream":
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
      let manifestRoot = workspaceRoot / ".repo" / "manifests"
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

      # `project new myproj`.
      let newRes = runShell(shellCommand(@[reproBin, "workspace", "project",
        "new", "myproj", "-m", "My project",
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

      # `project repo add myproj lib-x --remote=...`.
      let addRes = runShell(shellCommand(@[reproBin, "workspace", "project",
        "repo", "add", "myproj", "lib-x",
        "--remote=https://example.invalid/lib-x.git",
        "--workspace-root=" & workspaceRoot]))
      if addRes.code != 0:
        checkpoint("repo add output: " & addRes.output)
      check addRes.code == 0
      check fileExists(manifestRoot / "repos" / "lib-x.toml")
      # The include landed in the project file, pushed to the bare.
      let bareProj = runCmd(q(gitBin) & " -C " & q(bare) &
        " show main:projects/myproj.toml")
      check bareProj.code == 0
      check bareProj.output.contains("repos/lib-x.toml")

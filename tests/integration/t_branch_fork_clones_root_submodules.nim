## The fork materializes the root workspace repo's SUBMODULES.
##
## The workspace root repo may itself declare git submodules — shared tooling
## that is part of the workspace rather than a member repo the manifest owns.
## Reprobuild's "a develop-mode sibling is a submodule replacement" rule governs
## the repos the MANIFEST declares; it says nothing about the root repo's own
## git dependencies, and the root repo is cloned by git, not by the manifest.
##
## `cloneOrgRootRepo` cloned it plainly, so every submodule path arrived as an
## empty directory: present enough that nothing reported it missing, empty
## enough that whatever needed it failed later and somewhere else. The visible
## symptom on Windows was `reprobuild/env.ps1` aborting on a missing
## `../repo-workspaces/env.ps1` — a brand-new workspace that could not build.
##
## Asserted: after `repro branch <path>`, the submodule directory in the NEW
## workspace carries the submodule's content, not just an empty placeholder.
##
## Falsifiable: drop `--recurse-submodules` from `cloneOrgRootRepo` and the
## content check fails while the directory still exists — which is precisely
## the failure mode that went unnoticed.
##
## Real components (NO mocks): real `git`, real bare repos, the engine-built
## `build/bin/repro` as a subprocess, `file://` URLs for hermetic remotes.
##
## Skip rule: `git` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

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

proc gitConfig(gitBin, repoPath: string) =
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.name \"Submodule Tester\"")

proc seedGitOrigin(gitBin, originPath, workPath, marker: string) =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  gitConfig(gitBin, workPath)
  writeFile(workPath / marker, "content\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(fileUrl(originPath)))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")

suite "repro branch fork materialises the root repo's submodules":

  test "t_fork_populates_root_workspace_submodule":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-fork-submodule-", "")
      defer: removeDirEventually(scratch)

      # A member repo (manifest-owned) and a framework repo (root submodule).
      let memberOrigin = scratch / "origin-lib-a.git"
      seedGitOrigin(gitBin, memberOrigin, scratch / "seed-lib-a", "README.md")
      let frameworkOrigin = scratch / "origin-framework.git"
      seedGitOrigin(gitBin, frameworkOrigin, scratch / "seed-framework",
        "env.ps1")

      # The root workspace repo: manifests at top level PLUS a submodule.
      let rootWork = scratch / "seed-root"
      createDir(rootWork / "projects")
      createDir(rootWork / "repos")
      writeFile(rootWork / "projects" / "alpha.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"alpha\"\ndefault_revision = \"main\"\n" &
        "trunk = \"main\"\n\n" &
        "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" &
          fileUrl(memberOrigin) & "\"\n\n" &
        "includes = [\n  \"repos/lib-a.toml\",\n]\n")
      writeFile(rootWork / "repos" / "lib-a.toml",
        "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
        "[repo]\nname = \"lib-a\"\npath = \"lib-a\"\n" &
        "remote = \"lib-a-origin\"\nrevision = \"main\"\n")
      discard requireGit(q(gitBin) & " init -b main " & q(rootWork))
      gitConfig(gitBin, rootWork)
      discard requireGit(q(gitBin) & " -C " & q(rootWork) &
        " -c protocol.file.allow=always submodule add " &
        q(fileUrl(frameworkOrigin)) & " framework")
      discard requireGit(q(gitBin) & " -C " & q(rootWork) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(rootWork) & " commit -m fixture")

      let rootBare = scratch / "origin-repro-workspace.git"
      discard requireGit(q(gitBin) & " clone --bare " & q(rootWork) & " " &
        q(rootBare))

      # The SOURCE workspace, as `workspace init` would leave it.
      let source = scratch / "source-workspace"
      discard requireGit(q(gitBin) &
        " -c protocol.file.allow=always clone --recurse-submodules " &
        q(fileUrl(rootBare)) & " " & q(source))
      gitConfig(gitBin, source)
      discard requireGit(q(gitBin) & " clone " & q(fileUrl(memberOrigin)) &
        " " & q(source / "lib-a"))
      gitConfig(gitBin, source / "lib-a")
      writeWorkspaceBranch(source, project = "alpha", branch = "main")

      let dest = scratch / "feature-work"
      let res = runShell(shellCommand(
        @[reproBinary(), "branch", dest, "--workspace-root=" & source],
        @[("GIT_CONFIG_COUNT", "1"),
          ("GIT_CONFIG_KEY_0", "protocol.file.allow"),
          ("GIT_CONFIG_VALUE_0", "always")]))
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      # The member repo is the manifest's job and was never in doubt.
      check dirExists(dest / "lib-a" / ".git")

      # The submodule is the root repo's job. Before the fix the directory
      # existed and was EMPTY, so assert on content rather than existence.
      check fileExists(dest / "framework" / "env.ps1")
      check readFile(dest / "framework" / "env.ps1").strip() == "content"

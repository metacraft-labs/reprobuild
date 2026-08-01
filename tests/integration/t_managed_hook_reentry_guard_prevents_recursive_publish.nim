## Managed post-commit recursion context — legacy sentinel cannot bypass.
##
## The real installed dispatcher always runs the preserved user hook after
## scrubbing the legacy sentinel and private context. A user-supplied sentinel
## plus forged context must still run the managed post-commit body and produce
## its report. Only Reprobuild's exact typed lock-commit context suppresses the
## best-effort managed refresh that would otherwise recurse after an internal
## manifest lock commit; the preserved hook still runs and sees no internal
## values. The fixture is one real Git repo in a one-repo workspace.
##
## Falsifiable: accepting the retired sentinel removes the first report;
## forwarding either internal value contaminates the preserved log; failing to
## recognize the exact internal context creates the second report. The test is
## hermetic on every platform with Git's hook shell and mocks no hook process.

import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_test_support
import repro_cli_support/push_hook_protocol
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
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

suite "managed post-commit recursion context":

  test "t_managed_hook_reentry_guard_prevents_recursive_publish":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra7-reentry-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      # A single-repo git workspace whose project resolves to one repo.
      let origin = scratch / "origin.git"
      discard requireGit(q(gitBin) & " init --bare -b main " & q(origin))
      let workspaceRoot = scratch / "workspace"
      let repoPath = workspaceRoot / "lib-a"
      discard requireGit(q(gitBin) & " init -b main " & q(repoPath))
      discard requireGit(q(gitBin) & " -C " & q(repoPath) &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(repoPath) &
        " config user.name 'Post-commit Context Tester'")
      writeFile(repoPath / "README.md", "seed\n")
      discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add README.md")
      discard requireGit(q(gitBin) & " -C " & q(repoPath) &
        " commit -m seed")

      let manifestsRoot = workspaceRoot
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "lib-a.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"lib-a\"\ndefault_revision = \"main\"\n" &
        "trunk = \"main\"\n\n" &
        "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" &
          fileUrl(origin) & "\"\n\n" &
        "includes = [\n  \"repos/lib-a.toml\",\n]\n")
      writeFile(manifestsRoot / "repos" / "lib-a.toml",
        "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
        "[repo]\nname = \"lib-a\"\npath = \"lib-a\"\n" &
        "remote = \"lib-a-origin\"\nrevision = \"main\"\n")
      writeWorkspaceBranch(workspaceRoot, project = "lib-a", branch = "main")

      # Install a real preserved hook before the canonical dispatcher wraps it.
      let preservedLog = scratch / "preserved.log"
      let originalHook = repoPath / ".git" / "hooks" / "post-commit"
      writeFile(originalHook,
        "#!/usr/bin/env sh\n" &
        "printf 'legacy=%s context=%s\\n' \"${" & LegacyHookSentinelEnv &
        ":-}\" \"${" & InternalHookContextEnv & ":-}\" >> " &
        q(preservedLog) & "\nexit 0\n")
      var originalPerms = getFilePermissions(originalHook)
      originalPerms.incl({fpUserExec, fpGroupExec, fpOthersExec})
      setFilePermissions(originalHook, originalPerms)

      # ---- Install the real dispatcher and managed body ----------------
      let res = runShell(shellCommand(@[
        reproBin, "hooks", "ensure", "--vcs",
        "--workspace-root", workspaceRoot, workspaceRoot]))
      if res.code != 0:
        checkpoint("ensure output: " & res.output)
      check res.code == 0

      let hooksDir = repoPath / ".git" / "hooks"
      let dispatcher = hooksDir / "post-commit"
      let managed = hooksDir / "post-commit.repro-managed"
      check fileExists(dispatcher)
      check fileExists(managed)

      # The legacy name remains only so the dispatcher can scrub it.
      check readFile(dispatcher).contains("REPROBUILD_HOOK_ACTIVE")
      check readFile(managed).contains(InternalLockCommitContext)

      let report = workspaceRoot / ".repro" / "workspace" /
        "post-commit-report.json"
      if fileExists(report): removeFile(report)

      # A fixed legacy marker and arbitrary context are not authorization.
      let forged = runCmd("env REPROBUILD_REPRO=" & q(reproBin) & " " &
        LegacyHookSentinelEnv & "=1 " & InternalHookContextEnv &
        "=forged " & q(dispatcher), repoPath)
      if forged.code != 0: checkpoint(forged.output)
      check forged.code == 0
      check fileExists(report)

      removeFile(report)
      let internal = runCmd("env REPROBUILD_REPRO=" & q(reproBin) & " " &
        InternalHookContextEnv & "=" & InternalLockCommitContext & " " &
        q(dispatcher), repoPath)
      if internal.code != 0: checkpoint(internal.output)
      check internal.code == 0
      check not fileExists(report)

      let preserved = readFile(preservedLog).splitLines().filterIt(it.len > 0)
      check preserved.len == 2
      for line in preserved:
        check line == "legacy= context="

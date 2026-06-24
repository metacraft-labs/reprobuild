## RA-7 — managed-hook re-entry guard.
##
## Lock publication PUSHES the manifest repo, and that repo carries the
## same managed VCS hooks, so a publish-push would re-fire the dispatcher
## and recurse (the nested push would publish again, …). The managed-hook
## dispatcher template sets a sentinel env var (``REPROBUILD_HOOK_ACTIVE``)
## on first entry; a nested invocation that sees it already set
## short-circuits with ``exit 0`` BEFORE re-running any hook body.
##
## This test installs the real dispatcher via ``repro hooks ensure --vcs``,
## then replaces the managed body (``<hook>.repro-managed``) with a body
## whose only effect is to append a marker line to a file (a stand-in for
## "the body ran, which would trigger another publish-push"). It then runs
## the dispatcher twice:
##
##   * with ``REPROBUILD_HOOK_ACTIVE=1`` already in the environment (the
##     nested-invocation case): the dispatcher must short-circuit, exit 0,
##     and the body's side effect must NOT happen — no marker line.
##   * without the sentinel (the first-entry case): the dispatcher runs the
##     body and the marker line DOES appear.
##
## Falsifiable: the two runs differ only by the sentinel env var; if the
## guard were absent, the first run would also append the marker and the
## "must not run" assertion would fail. Hermetic: a single local ``git
## init`` repo + a metadata-only workspace under one ``createTempDir``; no
## network. Skip only when ``git`` is missing.

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
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

suite "RA-7 — managed-hook re-entry guard prevents recursive publish":

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

      let manifestsRoot = workspaceRoot / ".repo" / "manifests"
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

      # ---- Install the real dispatcher ---------------------------------
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

      # The dispatcher carries the RA-7 re-entry guard.
      check readFile(dispatcher).contains("REPROBUILD_HOOK_ACTIVE")

      # ---- Replace the managed body with an observable side effect -----
      # The body appends one line to BODY_RAN each time it runs. A nested
      # invocation (sentinel already set) must NOT reach this body.
      let bodyRan = scratch / "body-ran.txt"
      var body = "#!/usr/bin/env sh\n"
      body.add("# reprobuild managed post-commit hook\n")
      body.add("printf 'BODY-RAN\\n' >> " & q(bodyRan) & "\n")
      body.add("exit 0\n")
      writeFile(managed, body)
      var perms = getFilePermissions(managed)
      perms.incl({fpUserExec, fpGroupExec, fpOthersExec})
      setFilePermissions(managed, perms)

      proc bodyRunCount(): int =
        if not fileExists(bodyRan): return 0
        result = 0
        for line in readFile(bodyRan).splitLines():
          if line.strip() == "BODY-RAN": inc result

      # ---- (A) nested invocation: sentinel set → short-circuit ---------
      let nested = runCmd("env REPROBUILD_HOOK_ACTIVE=1 " & q(dispatcher),
        repoPath)
      check nested.code == 0
      # The body did NOT run — the guard short-circuited before it.
      check bodyRunCount() == 0

      # ---- (B) first entry: no sentinel → body runs (falsifiable) ------
      let firstEntry = runCmd(q(dispatcher), repoPath)
      check firstEntry.code == 0
      # The body DID run exactly once.
      check bodyRunCount() == 1

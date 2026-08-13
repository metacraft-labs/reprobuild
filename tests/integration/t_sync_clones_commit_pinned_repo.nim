## A repo fragment pinned to a COMMIT ID must clone, and a clone that fails
## must fail the run.
##
## Two defects that compounded into one silent failure mode, both reproduced
## here against real local git repositories:
##
##   1. `executeClone` passed the fragment's `revision` to `git clone
##      --branch`, which accepts only a branch or tag. A SHA-pinned fragment
##      therefore could NEVER be cloned — every attempt died with
##      "Remote branch <sha> not found in upstream origin".
##
##   2. `workspace sync` classified that failure as `skipped`, reported
##      `failed 0`, and exited 0. So the workspace was left missing a declared
##      repo while every signal a script or a human checks said success. That
##      is what let (1) go unnoticed: the workspace silently rotted, and the
##      first visible symptom was an unrelated command refusing much later.
##
## Asserted:
##   1. A fragment pinned to a commit id that is NOT a branch tip clones, and
##      the checkout lands on exactly that commit.
##   2. A fragment whose pinned commit does not exist fails the sync: the repo
##      is reported `clone_failed`, the summary counts it, and the exit code is
##      non-zero — while the OTHER repos in the same run still converge (the
##      partial-advance contract is preserved, only the reporting is honest).
##
## No mocks: real `git init --bare` upstreams, the real clone action, and the
## engine-built `build/bin/repro`.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support

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

proc seedOrigin(gitBin, originPath, workPath: string): string =
  ## Two commits on `main`, then return the FIRST commit's sha — a commit that
  ## is genuinely not a branch tip, which is the case `--branch` cannot express.
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"Pin Tester\"")
  writeFile(workPath / "first.txt", "first\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add first.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m first")
  let pinned = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()
  writeFile(workPath / "second.txt", "second\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add second.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m second")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  pinned

proc repoFragment(name, remote, revision: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"" & revision & "\"\n"

proc projectFile(remotes: string; includes: openArray[string]): string =
  var body = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"pinned\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" & remotes & "includes = [\n"
  for inc in includes:
    body.add("  \"" & inc & "\",\n")
  body.add("]\n")
  body

suite "sync clones a commit-pinned repo, and a failed clone fails the run":

  test "t_sync_clones_repo_pinned_to_a_non_tip_commit":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-pinclone-ok-", "")
      defer: removeDir(scratch)
      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot / "projects")
      createDir(workspaceRoot / "repos")

      let origin = scratch / "origin-pinned-lib.git"
      let pinned = seedOrigin(gitBin, origin, scratch / "seed-pinned-lib")
      writeFile(workspaceRoot / "repos" / "pinned-lib.toml",
        repoFragment("pinned-lib", "pinned-origin", pinned))
      writeFile(workspaceRoot / "projects" / "pinned.toml",
        projectFile("[[remote]]\nname = \"pinned-origin\"\nfetch = \"" &
          fileUrl(origin) & "\"\n\n", ["repos/pinned-lib.toml"]))

      let res = runShell(shellCommand(@[reproBinary(), "workspace", "enable",
        "pinned", "--workspace-root=" & workspaceRoot]))
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      # The checkout exists AND sits on exactly the pinned commit — not on the
      # branch tip, which is what a `--branch`-shaped clone would have given
      # even if the flag had accepted a commit id.
      check dirExists(workspaceRoot / "pinned-lib" / ".git")
      let head = requireGit(q(gitBin) & " -C " &
        q(workspaceRoot / "pinned-lib") & " rev-parse HEAD").strip()
      check head == pinned
      check fileExists(workspaceRoot / "pinned-lib" / "first.txt")
      check not fileExists(workspaceRoot / "pinned-lib" / "second.txt")

  test "t_sync_fails_when_a_declared_repo_cannot_be_cloned":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-pinclone-bad-", "")
      defer: removeDir(scratch)
      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot / "projects")
      createDir(workspaceRoot / "repos")

      # One healthy repo and one pinned to a commit that does not exist.
      let goodOrigin = scratch / "origin-good-lib.git"
      discard seedOrigin(gitBin, goodOrigin, scratch / "seed-good-lib")
      let badOrigin = scratch / "origin-bad-lib.git"
      discard seedOrigin(gitBin, badOrigin, scratch / "seed-bad-lib")
      const missing = "0123456789012345678901234567890123456789"

      writeFile(workspaceRoot / "repos" / "good-lib.toml",
        repoFragment("good-lib", "good-origin", "main"))
      writeFile(workspaceRoot / "repos" / "bad-lib.toml",
        repoFragment("bad-lib", "bad-origin", missing))
      writeFile(workspaceRoot / "projects" / "pinned.toml",
        projectFile(
          "[[remote]]\nname = \"good-origin\"\nfetch = \"" &
            fileUrl(goodOrigin) & "\"\n\n" &
          "[[remote]]\nname = \"bad-origin\"\nfetch = \"" &
            fileUrl(badOrigin) & "\"\n\n",
          ["repos/good-lib.toml", "repos/bad-lib.toml"]))

      let res = runShell(shellCommand(@[reproBinary(), "workspace", "enable",
        "pinned", "--write-report",
        "--workspace-root=" & workspaceRoot]))
      checkpoint("output: " & res.output)

      # The run FAILS. Previously this exited 0 with the failure filed under
      # `skipped`, which is the whole reason the defect went unnoticed.
      check res.code != 0
      check res.output.contains("FAILED to clone")

      # ...and the other repo still converged: continuing past a failed clone
      # is deliberate, only the reporting was wrong.
      check dirExists(workspaceRoot / "good-lib" / ".git")
      check not dirExists(workspaceRoot / "bad-lib" / ".git")

      let reportPath = workspaceRoot / ".repro" / "build" / "reports" /
        "sync-report.json"
      check fileExists(reportPath)
      let report = parseFile(reportPath)
      check report["summary"]["cloneFailed"].getInt() == 1
      var badStatus = ""
      for entry in report["repos"]:
        if entry["path"].getStr() == "bad-lib":
          badStatus = entry["executionStatus"].getStr()
      check badStatus == "clone_failed"

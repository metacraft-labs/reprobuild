## ``repro workspace sync --force-sync`` — the digest counts the overwrite
## it performed.
##
## WHY THIS TEST EXISTS
##
## ``summarize`` folds each repo row into the end-of-run digest by switching
## on ``executionStatus`` first, and only the ``noop`` and fallback arms then
## asked whether ``action == "force_reset"``. A force-reset that SUCCEEDS
## reports ``executionStatus = "succeeded"``, so it was claimed by the
## switch's first arm and the force-reset tests were never reached.
##
## Measured at ca49246a: three repos overwritten, ``summary.forceReset`` = 0,
## all three counted as ordinary successes. The one line in the digest that
## says destruction happened read zero while it was happening — and the
## digest is what an operator or a CI job scans after a ``--force-sync``.
##
## The counts are asserted on BOTH sides. ``forceReset == 1`` alone would
## pass against an implementation that double-counted the row; the
## accompanying ``succeeded == 0`` and ``total == 1`` say it moved rather
## than multiplied.
##
## Skip rule: ``git`` missing on PATH (the convention this suite follows).

import std/[json, os, osproc, strutils, tempfiles, unittest]

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
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"Force Tester\"")
  writeFile(workPath / "README.md", "force fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

suite "repro workspace sync — the digest counts a force-reset":

  test "t_workspace_sync_summary_counts_a_force_reset":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-sync-forcereset-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()
      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot / "projects")
      createDir(workspaceRoot / "repos")

      let origin = scratch / "origin-lib.git"
      let lockedSha = seedOrigin(gitBin, origin, scratch / "seed-lib")
      discard requireGit(q(gitBin) & " clone " & q(fileUrl(origin)) & " " &
        q(workspaceRoot / "lib"))
      discard requireGit(q(gitBin) & " -C " & q(workspaceRoot / "lib") &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(workspaceRoot / "lib") &
        " config user.name \"Force Tester\"")

      # An unpublished local commit: the planner refuses this
      # (``locally_unpublished``), which is exactly the state ``--force-sync``
      # exists to overwrite.
      writeFile(workspaceRoot / "lib" / "local.txt", "unpublished\n")
      discard requireGit(q(gitBin) & " -C " & q(workspaceRoot / "lib") &
        " add local.txt")
      discard requireGit(q(gitBin) & " -C " & q(workspaceRoot / "lib") &
        " commit -m \"local only\"")
      let divergedSha = requireGit(q(gitBin) & " -C " &
        q(workspaceRoot / "lib") & " rev-parse HEAD").strip()
      check divergedSha != lockedSha

      writeFile(workspaceRoot / "repos" / "lib.toml",
        "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
        "[repo]\nname = \"lib\"\npath = \"lib\"\nremote = \"lib-origin\"\n" &
        "revision = \"main\"\n")
      writeFile(workspaceRoot / "projects" / "forceproject.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"forceproject\"\n" &
        "default_revision = \"main\"\ntrunk = \"main\"\n\n" &
        "[[remote]]\nname = \"lib-origin\"\nfetch = \"" & fileUrl(origin) &
        "\"\n\nincludes = [\n  \"repos/lib.toml\",\n]\n")

      let res = runShell(shellCommand(@[
        reproBin, "workspace", "sync", "forceproject",
        "--force-sync", "--yes", "--write-report",
        "--workspace-root=" & workspaceRoot,
      ]))
      let reportPath = workspaceRoot / ".repro" / "build" / "reports" /
        "sync-report.json"
      if not fileExists(reportPath):
        checkpoint("no sync report written; exit=" & $res.code & "; " &
          res.output)
      check fileExists(reportPath)
      let doc = parseFile(reportPath)

      check doc["repos"].len == 1
      let entry = doc["repos"][0]
      # The premise: this row IS a force-reset that succeeded. If the
      # overwrite did not happen the digest assertion below would be about
      # nothing.
      check entry["action"].getStr() == "force_reset"
      check entry["executionStatus"].getStr() == "succeeded"

      let summary = doc["summary"]
      check summary["total"].getInt() == 1
      check summary["forceReset"].getInt() == 1
      # Moved, not multiplied: the row is counted once, as the thing it was.
      check summary["succeeded"].getInt() == 0
      check summary["noop"].getInt() == 0
      check summary["refused"].getInt() == 0
      check summary["failed"].getInt() == 0

      # And the overwrite really happened: the checkout is back at the
      # locked revision, not on the diverged commit.
      let head = requireGit(q(gitBin) & " -C " & q(workspaceRoot / "lib") &
        " rev-parse HEAD").strip()
      check head == lockedSha
      check head != divergedSha

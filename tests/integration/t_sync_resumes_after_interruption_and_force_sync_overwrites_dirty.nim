## RA-16 — Resumable sync and ``--force-sync``.
##
## Two falsifiable, hermetic behaviors proven end-to-end through the
## ``repro workspace sync`` CLI (``runWorkspaceSyncCommand``):
##
## (a) RESUME. A multi-repo sync interrupted partway must be safely
##     re-runnable. We run a 3-repo clone sync, then simulate an
##     interruption that left ONE repo incomplete (its checkout deleted /
##     half-populated with no ``.git`` and no receipt) while the others
##     finished. A re-run must:
##       - NOT redo the completed repos (a sentinel dropped into a
##         finished checkout survives — the completed repos' clone
##         receipts persist and the planner classifies them as
##         clean-at-locked / noop rather than re-cloning), and
##       - finish the incomplete repo (re-clone it to the locked SHA,
##         cleaning up a half-cloned non-git leftover dir), so the final
##         state equals an uninterrupted sync (all repos at the locked
##         SHA).
##     Falsifiable: if resume redid the completed repos the sentinel
##     would be gone; if it ignored the incomplete repo it would still be
##     missing ``.git``.
##
## (b) FORCE. A checkout that diverged from the locked revision is
##     report-only SKIPPED by a NORMAL sync (unchanged — the only
##     overwrite path is ``--force-sync``), but OVERWRITTEN to the locked
##     SHA by ``repro workspace sync --force-sync --yes`` (``git reset
##     --hard`` + ``git clean -ffdx``). We also assert that
##     ``--force-sync`` WITHOUT ``--yes`` in a non-TTY context REFUSES
##     cleanly (non-zero, does not hang, does not overwrite) — the test
##     process is itself non-interactive, so this exercises the
##     destructive-command safety guard directly.
##
## Hermetic: local ``git init --bare`` upstreams in a tempdir; the same
## workspace root (and therefore the same engine cache root under
## ``.repro/workspace/engine-cache``) is reused across the resume runs.
## Skip rule: only when ``git`` is missing from PATH.

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
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  ## Bare origin with one commit; returns the seeded HEAD SHA.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " & q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA16 Tester\"")
  writeFile(workPath / "README.md", "RA16 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc headOf(gitBin, repoPath: string): string =
  requireGit(q(gitBin) & " -C " & q(repoPath) & " rev-parse HEAD").strip()

# ---- manifest TOML --------------------------------------------------------

proc projectToml(remotes: seq[tuple[name, url: string]];
                 includes: seq[string]): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"myproject\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n"
  for r in remotes:
    result.add("[[remote]]\nname = \"" & r.name & "\"\nfetch = \"" &
      r.url & "\"\n\n")
  result.add("includes = [\n")
  for inc in includes:
    result.add("  \"" & inc & "\",\n")
  result.add("]\n")

proc repoFragment(name, path, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & path & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"main\"\n"

# ---- the suite -------------------------------------------------------------

suite "RA-16 — resumable sync + --force-sync":

  test "t_sync_resumes_after_interruption_and_force_sync_overwrites_dirty":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra16-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      # --- Three hermetic bare origins -----------------------------------
      var origins: array[3, string]
      var lockedShas: array[3, string]
      for i in 0 ..< 3:
        let origin = scratch / ("origin-" & $i & ".git")
        let seed = scratch / ("seed-" & $i)
        lockedShas[i] = seedGitOrigin(gitBin, origin, seed)
        origins[i] = origin

      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot)
      let manifestsRoot = workspaceRoot / ".repo" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      var remotes: seq[tuple[name, url: string]]
      var includes: seq[string]
      for i in 0 ..< 3:
        remotes.add((name: "origin-" & $i, url: fileUrl(origins[i])))
        includes.add("repos/repo" & $i & ".toml")
        writeFile(manifestsRoot / "repos" / ("repo" & $i & ".toml"),
          repoFragment("repo" & $i, "repo" & $i, "origin-" & $i))
      writeFile(manifestsRoot / "projects" / "myproject.toml",
        projectToml(remotes, includes))

      proc invokeSync(extra: seq[string] = @[]): CmdResult =
        runShell(shellCommand(@[reproBin, "workspace", "sync", "myproject",
          "--workspace-root=" & workspaceRoot] & extra))

      proc readReport(): JsonNode =
        let p = workspaceRoot / ".repro" / "workspace" / "sync-report.json"
        check fileExists(p)
        parseFile(p)

      proc entryFor(report: JsonNode; path: string): JsonNode =
        for e in report["repos"]:
          if e["path"].getStr() == path:
            return e
        checkpoint("no report entry for " & path)
        check false
        newJObject()

      # ===================================================================
      # (a) RESUME
      # ===================================================================

      # First sync: all three repos missing → all cloned.
      block:
        let res = invokeSync()
        if res.code != 0:
          checkpoint("run1 output: " & res.output)
        check res.code == 0
        for i in 0 ..< 3:
          check dirExists(workspaceRoot / ("repo" & $i) / ".git")
          check headOf(gitBin, workspaceRoot / ("repo" & $i)) == lockedShas[i]
        let report = readReport()
        for i in 0 ..< 3:
          let e = entryFor(report, "repo" & $i)
          check e["syncCase"].getStr() == "missing_checkout"
          check e["executionStatus"].getStr() == "succeeded"

      # Clone receipts from run 1 persist on disk (the resume mechanism).
      let receiptsDir = workspaceRoot / ".repro" / "workspace" / "receipts"
      check dirExists(receiptsDir)
      var cloneReceipts = 0
      for f in walkDir(receiptsDir):
        if f.path.extractFilename.startsWith("sync-clone-"):
          inc cloneReceipts
      check cloneReceipts == 3

      # Capture an identity for the COMPLETED repos (0 and 2) that a
      # re-clone WOULD change but a planner-level skip preserves: the inode
      # of ``.git/config`` (a fresh clone recreates ``.git`` from scratch,
      # giving the file a new inode). Asserting it is unchanged after the
      # resume run proves those repos were NOT redone — without dirtying
      # the working tree (which would change their classification).
      proc gitConfigInode(repoPath: string): tuple[device: DeviceId; file: FileId] =
        getFileInfo(repoPath / ".git" / "config").id
      let repo0InodeBefore = gitConfigInode(workspaceRoot / "repo0")
      let repo2InodeBefore = gitConfigInode(workspaceRoot / "repo2")

      # Simulate the interruption: repo1 left HALF-CLONED — a directory
      # with no ``.git`` and no receipt (a partial clone artifact). The
      # re-run must clean it up and re-clone repo1, untouched-skip 0 and 2.
      removeDir(workspaceRoot / "repo1")
      createDir(workspaceRoot / "repo1")
      writeFile(workspaceRoot / "repo1" / "partial.tmp", "half-written\n")

      # Re-run (resume): same workspace root → same engine cache root.
      block:
        let res = invokeSync()
        if res.code != 0:
          checkpoint("resume output: " & res.output)
        check res.code == 0

        # Completed repos NOT redone: their ``.git/config`` inode is
        # unchanged (a re-clone would have recreated ``.git``), still at
        # the locked SHA.
        check gitConfigInode(workspaceRoot / "repo0") == repo0InodeBefore
        check gitConfigInode(workspaceRoot / "repo2") == repo2InodeBefore
        check headOf(gitBin, workspaceRoot / "repo0") == lockedShas[0]
        check headOf(gitBin, workspaceRoot / "repo2") == lockedShas[2]

        # Incomplete repo finished: re-cloned, half-clone leftover gone.
        check dirExists(workspaceRoot / "repo1" / ".git")
        check not fileExists(workspaceRoot / "repo1" / "partial.tmp")
        check headOf(gitBin, workspaceRoot / "repo1") == lockedShas[1]

        # The report shows the completed repos as clean noops on the
        # resume run (NOT re-cloned), repo1 as a fresh clone.
        let report = readReport()
        for i in [0, 2]:
          let e = entryFor(report, "repo" & $i)
          check e["syncCase"].getStr() == "clean_at_locked_revision"
          check e["action"].getStr() == "none"
          check e["executionStatus"].getStr() == "noop"
        let e1 = entryFor(report, "repo1")
        check e1["syncCase"].getStr() == "missing_checkout"
        check e1["action"].getStr() == "clone"
        check e1["executionStatus"].getStr() == "succeeded"

      # ===================================================================
      # (b) FORCE
      # ===================================================================

      # Diverge repo0 from the locked revision: stay on main but reset the
      # working tree to a different (older) state AND dirty it. We create
      # divergence by committing a local-only change that is NOT on origin,
      # then leaving uncommitted edits — classified as dirty / divergent.
      let repo0 = workspaceRoot / "repo0"
      discard requireGit(q(gitBin) & " -C " & q(repo0) &
        " switch -c diverged-branch")
      writeFile(repo0 / "divergent.txt", "off-manifest work\n")
      discard requireGit(q(gitBin) & " -C " & q(repo0) & " add divergent.txt")
      discard requireGit(q(gitBin) & " -C " & q(repo0) &
        " commit -m \"divergent commit\"")
      let divergedSha = headOf(gitBin, repo0)
      # Leave an uncommitted edit + a stray untracked file too.
      writeFile(repo0 / "dirty.txt", "uncommitted\n")
      check divergedSha != lockedShas[0]

      # NORMAL sync (no --force-sync): repo0 must be SKIPPED / report-only,
      # left UNCHANGED. The only overwrite path is --force-sync.
      block:
        let res = invokeSync()
        # dirty/locally-unpublished is a refuse-and-report (exit 2).
        check res.code in [0, 2]
        # Untouched: still on the diverged commit, dirty file intact.
        check headOf(gitBin, repo0) == divergedSha
        check fileExists(repo0 / "dirty.txt")
        check fileExists(repo0 / "divergent.txt")
        let e = entryFor(readReport(), "repo0")
        check e["action"].getStr() == "none"
        check e["executionStatus"].getStr() in ["noop", "refused"]
        check e["syncCase"].getStr() in
          ["dirty", "locally_unpublished", "divergent_feature_branch"]

      # --force-sync WITHOUT --yes in a non-TTY: REFUSE cleanly (the test
      # process is non-interactive). Must not hang, must not overwrite.
      block:
        let res = invokeSync(@["--force-sync"])
        check res.code != 0
        check ("non-interactive" in res.output) or ("--yes" in res.output)
        # Still untouched — the refusal did NOT overwrite.
        check headOf(gitBin, repo0) == divergedSha
        check fileExists(repo0 / "dirty.txt")

      # --force-sync --yes: OVERWRITE repo0 to the locked SHA. The diverged
      # commit, the dirty edit, and the stray untracked file are all gone.
      block:
        let res = invokeSync(@["--force-sync", "--yes"])
        if res.code != 0:
          checkpoint("force-sync output: " & res.output)
        check res.code == 0
        check headOf(gitBin, repo0) == lockedShas[0]
        check not fileExists(repo0 / "dirty.txt")
        check not fileExists(repo0 / "divergent.txt")
        let e = entryFor(readReport(), "repo0")
        check e["action"].getStr() == "force_reset"
        check e["executionStatus"].getStr() == "succeeded"
        # The other repos remained at the locked revision throughout.
        check headOf(gitBin, workspaceRoot / "repo1") == lockedShas[1]
        check headOf(gitBin, workspaceRoot / "repo2") == lockedShas[2]

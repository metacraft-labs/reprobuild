## RA-11 — ``repro workspace pull`` converges every repo to its
## MANIFEST-DECLARED revision on a LOCAL TRACKING BRANCH.
##
## This contrasts ``pull`` with ``sync``:
##   - ``sync`` honors each repo's CURRENT branch (fetch + ff to its own
##     ``@{u}``); it does NOT realign to the manifest revision.
##   - ``pull`` converges TO the manifest revision and attaches a local
##     tracking branch matching that revision (never detached).
##
## Fixture (all hermetic local repos via ``file://`` origins):
##
##   - ``lib-a``: manifest revision ``dev``. The checkout is parked on a
##     DIFFERENT local branch (``scratch``) at an OLDER commit. ``pull``
##     must move it onto branch ``dev`` at ``origin/dev``'s tip.
##   - ``lib-b``: manifest revision ``dev`` but the checkout is DETACHED
##     at an old commit. ``pull`` must attach it to branch ``dev`` at
##     ``origin/dev``'s tip — proving "tracking branch, not detached".
##
## Assertions after ``pull``:
##   * each repo's HEAD == ``origin/dev`` tip (the manifest revision),
##   * each repo is ON branch ``dev`` (``symbolic-ref`` succeeds; HEAD is
##     attached), and
##   * the report records ``trackingBranch == "dev"``.
##
## Falsifiability:
##   - If ``pull`` behaved like ``sync`` (honor current branch), ``lib-a``
##     would stay on ``scratch`` (not ``dev``) and ``lib-b`` would stay
##     detached — both assertions would fail.
##   - If ``pull`` left HEAD detached, the ``symbolic-ref`` check fails.
##   - If ``pull`` did not advance to ``origin/dev``, the HEAD-SHA check
##     fails.
##
## A companion call to ``sync`` on a fresh clone of the same workspace is
## made to confirm the contrast: ``sync`` leaves ``lib-a`` on ``scratch``
## (its current branch), NOT realigned to ``dev``.
##
## Skip rule: ``git`` missing on PATH.

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

proc gitConfig(gitBin, repoPath: string) =
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.name \"RA11 Tester\"")

proc seedOrigin(gitBin, originPath, workPath, branch: string): string =
  ## Seed a bare origin on ``branch`` with two commits; return the tip SHA.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  gitConfig(gitBin, workPath)
  writeFile(workPath / "README.md", "RA11 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m first")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  # Second commit advances origin/<branch>.
  writeFile(workPath / "next.txt", "second\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add next.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m second")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(originPath)) & " " &
    q(targetPath))
  gitConfig(gitBin, targetPath)

proc currentBranch(gitBin, repoPath: string): string =
  let res = runCmd(q(gitBin) & " -C " & q(repoPath) &
    " symbolic-ref --short -q HEAD")
  if res.code == 0: res.output.strip() else: ""

proc headSha(gitBin, repoPath: string): string =
  requireGit(q(gitBin) & " -C " & q(repoPath) & " rev-parse HEAD").strip()

proc firstParentSha(gitBin, repoPath: string): string =
  requireGit(q(gitBin) & " -C " & q(repoPath) & " rev-parse HEAD~1").strip()

# ---- manifest TOML --------------------------------------------------------

proc projectToml(aUrl, bUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"myproject\"\n" &
  "default_revision = \"dev\"\n" &
  "trunk = \"dev\"\n\n" &
  "[[remote]]\nname = \"a-origin\"\nfetch = \"" & aUrl & "\"\n\n" &
  "[[remote]]\nname = \"b-origin\"\nfetch = \"" & bUrl & "\"\n\n" &
  "includes = [\n" &
  "  \"repos/lib-a.toml\",\n" &
  "  \"repos/lib-b.toml\",\n" &
  "]\n"

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "a-origin"
revision = "dev"
"""

const libBFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-b"
path = "lib-b"
remote = "b-origin"
revision = "dev"
"""

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    aOrigin, bOrigin: string
    aSeed, bSeed: string
    aTip, bTip: string

proc writeManifest(workspaceRoot, aOrigin, bOrigin: string) =
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "myproject.toml",
    projectToml(fileUrl(aOrigin), fileUrl(bOrigin)))
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  writeFile(manifestsRoot / "repos" / "lib-b.toml", libBFragmentToml)

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-ra11pull-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.aOrigin = result.scratch / "origin-lib-a.git"
  result.bOrigin = result.scratch / "origin-lib-b.git"
  result.aSeed = result.scratch / "seed-lib-a"
  result.bSeed = result.scratch / "seed-lib-b"
  result.aTip = seedOrigin(gitBin, result.aOrigin, result.aSeed, "dev")
  result.bTip = seedOrigin(gitBin, result.bOrigin, result.bSeed, "dev")
  result.workspaceRoot = result.scratch / "workspace"
  createDir(result.workspaceRoot)
  writeManifest(result.workspaceRoot, result.aOrigin, result.bOrigin)

proc readPullReport(workspaceRoot: string): JsonNode =
  let reportPath = workspaceRoot / ".repro" / "workspace" / "pull-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc readSyncReport(workspaceRoot: string): JsonNode =
  let reportPath = workspaceRoot / ".repro" / "workspace" / "sync-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc repoEntry(report: JsonNode; path: string): JsonNode =
  for entry in report["repos"]:
    if entry["path"].getStr() == path:
      return entry
  checkpoint("no report entry for path " & path)
  fail()
  newJObject()

suite "RA-11 — pull converges to manifest revision on a tracking branch":

  test "t_workspace_pull_converges_each_repo_to_manifest_revision_tracking_branch":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "converge")
      defer: removeDir(fx.scratch)

      # lib-a: clone, then park on a DIFFERENT branch (``scratch``) at an
      # OLDER commit so a manifest-converge is observable.
      cloneInto(gitBin, fx.aOrigin, fx.workspaceRoot / "lib-a")
      let aOld = firstParentSha(gitBin, fx.workspaceRoot / "lib-a")
      discard requireGit(q(gitBin) & " -C " & q(fx.workspaceRoot / "lib-a") &
        " checkout -b scratch " & aOld)
      check currentBranch(gitBin, fx.workspaceRoot / "lib-a") == "scratch"
      check headSha(gitBin, fx.workspaceRoot / "lib-a") == aOld

      # lib-b: clone, then DETACH at an older commit.
      cloneInto(gitBin, fx.bOrigin, fx.workspaceRoot / "lib-b")
      let bOld = firstParentSha(gitBin, fx.workspaceRoot / "lib-b")
      discard requireGit(q(gitBin) & " -C " & q(fx.workspaceRoot / "lib-b") &
        " checkout --detach " & bOld)
      check currentBranch(gitBin, fx.workspaceRoot / "lib-b") == ""  # detached

      # ---- pull ----
      let pull = runShell(shellCommand(@[
        fx.reproBin, "workspace", "pull", "myproject",
        "--workspace-root=" & fx.workspaceRoot,
      ]))
      if pull.code != 0:
        checkpoint("pull output: " & pull.output)
      check pull.code == 0

      # Each repo converged to the manifest revision (origin/dev tip).
      check headSha(gitBin, fx.workspaceRoot / "lib-a") == fx.aTip
      check headSha(gitBin, fx.workspaceRoot / "lib-b") == fx.bTip
      # Each repo is on a TRACKING BRANCH ``dev`` — attached, not detached.
      check currentBranch(gitBin, fx.workspaceRoot / "lib-a") == "dev"
      check currentBranch(gitBin, fx.workspaceRoot / "lib-b") == "dev"

      let pullReport = readPullReport(fx.workspaceRoot)
      check repoEntry(pullReport, "lib-a")["trackingBranch"].getStr() == "dev"
      check repoEntry(pullReport, "lib-a")["headSha"].getStr() == fx.aTip
      check repoEntry(pullReport, "lib-a")["outcome"].getStr() == "converged"
      check repoEntry(pullReport, "lib-b")["trackingBranch"].getStr() == "dev"
      check repoEntry(pullReport, "lib-b")["headSha"].getStr() == fx.bTip

  test "t_workspace_sync_honors_current_branch_unlike_pull":
    # The contrast half: ``sync`` honors the repo's current branch and does
    # NOT realign to the manifest revision. A repo parked on ``scratch``
    # stays on ``scratch`` (not ``dev``) after sync.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "contrast")
      defer: removeDir(fx.scratch)

      cloneInto(gitBin, fx.aOrigin, fx.workspaceRoot / "lib-a")
      let aOld = firstParentSha(gitBin, fx.workspaceRoot / "lib-a")
      discard requireGit(q(gitBin) & " -C " & q(fx.workspaceRoot / "lib-a") &
        " checkout -b scratch " & aOld)
      cloneInto(gitBin, fx.bOrigin, fx.workspaceRoot / "lib-b")

      let sync = runShell(shellCommand(@[
        fx.reproBin, "workspace", "sync", "myproject",
        "--workspace-root=" & fx.workspaceRoot,
      ]))
      check sync.code in [0, 2]

      # sync did NOT realign lib-a to the manifest revision ``dev``: it is
      # still on its own branch ``scratch`` (the per-repo-upstream
      # semantics), proving pull's converge-to-manifest is the new path.
      check currentBranch(gitBin, fx.workspaceRoot / "lib-a") == "scratch"
      let syncReport = readSyncReport(fx.workspaceRoot)
      # lib-a on ``scratch`` (no remote upstream) is a divergent/report-only
      # case for sync — never realigned to ``dev``.
      check repoEntry(syncReport, "lib-a")["syncCase"].getStr() in
        ["divergent_feature_branch", "locally_unpublished",
         "clean_at_locked_revision"]

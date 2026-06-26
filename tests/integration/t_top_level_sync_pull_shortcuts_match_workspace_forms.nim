## Top-level ``repro sync`` / ``repro pull`` shortcuts behave identically
## to ``repro workspace sync`` / ``repro workspace pull``.
##
## The sibling workspace verbs (``push``/``add``/``remove``/``checkout``/
## ``branch``) all have top-level shortcuts that route to their
## ``workspace`` handler, and ``CLI/sync.md`` documents ``repro sync`` /
## ``repro pull`` as real top-level commands. This test pins the parity:
##
##   1. ``repro sync --dry-run`` (top-level) honors the plan-only contract:
##      exit 0, NO mutation — the fast-forwardable repo stays at its old
##      tip. (Same flag surface as ``repro workspace sync``.)
##   2. ``repro sync`` (top-level) then fast-forwards the repo to its OWN
##      ``origin/dev`` tip — byte-identical effect to the ``workspace``
##      form, which a control clone synced via ``workspace sync`` proves.
##   3. ``repro pull`` (top-level) converges a parked clone to the
##      manifest revision ``dev`` on a tracking branch — identical to
##      ``repro workspace pull``.
##
## Falsifiability: BEFORE the top-level arms exist, ``repro sync`` /
## ``repro pull`` fall through to the usage banner and do NOT touch any
## repo — so assertions (2)/(3) (HEAD advanced / branch realigned) fail,
## and (1) (exit 0) fails because the banner exits non-zero. Removing the
## new ``args[0] == "sync"`` / ``"pull"`` arms in ``runThinApp`` makes this
## test fail.
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
    " config user.name \"Shortcut Tester\"")

proc seedOrigin(gitBin, originPath, workPath, branch: string): string =
  ## Seed a bare origin on ``branch`` with two commits; return the tip SHA.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  gitConfig(gitBin, workPath)
  writeFile(workPath / "README.md", "shortcut fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m first")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  # Second commit advances origin/<branch> so a clone of the first commit
  # becomes fast-forwardable.
  writeFile(workPath / "next.txt", "second\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add next.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m second")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneFirstCommit(gitBin, originPath, targetPath, branch: string): string =
  ## Clone, then reset the working clone back to the FIRST commit on
  ## ``branch`` (parent of the tip) so a fast-forward to ``origin/branch``
  ## is observable. Returns the old (pre-sync) HEAD sha.
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(originPath)) & " " &
    q(targetPath))
  gitConfig(gitBin, targetPath)
  let oldSha = requireGit(q(gitBin) & " -C " & q(targetPath) &
    " rev-parse HEAD~1").strip()
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " reset --hard " & oldSha)
  result = oldSha

proc currentBranch(gitBin, repoPath: string): string =
  let res = runCmd(q(gitBin) & " -C " & q(repoPath) &
    " symbolic-ref --short -q HEAD")
  if res.code == 0: res.output.strip() else: ""

proc headSha(gitBin, repoPath: string): string =
  requireGit(q(gitBin) & " -C " & q(repoPath) & " rev-parse HEAD").strip()

# ---- manifest TOML --------------------------------------------------------

proc projectToml(aUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"myproject\"\n" &
  "default_revision = \"dev\"\n" &
  "trunk = \"dev\"\n\n" &
  "[[remote]]\nname = \"a-origin\"\nfetch = \"" & aUrl & "\"\n\n" &
  "includes = [\n" &
  "  \"repos/lib-a.toml\",\n" &
  "]\n"

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "a-origin"
revision = "dev"
"""

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    aOrigin, aSeed, aTip: string

proc writeManifest(workspaceRoot, aOrigin: string) =
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "myproject.toml",
    projectToml(fileUrl(aOrigin)))
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-toplevel-syncpull-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.aOrigin = result.scratch / "origin-lib-a.git"
  result.aSeed = result.scratch / "seed-lib-a"
  result.aTip = seedOrigin(gitBin, result.aOrigin, result.aSeed, "dev")
  result.workspaceRoot = result.scratch / "workspace"
  createDir(result.workspaceRoot)
  writeManifest(result.workspaceRoot, result.aOrigin)

proc readSyncReport(workspaceRoot: string): JsonNode =
  let reportPath = workspaceRoot / ".repro" / "workspace" / "sync-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc readPullReport(workspaceRoot: string): JsonNode =
  let reportPath = workspaceRoot / ".repro" / "workspace" / "pull-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc repoEntry(report: JsonNode; path: string): JsonNode =
  for entry in report["repos"]:
    if entry["path"].getStr() == path:
      return entry
  checkpoint("no report entry for path " & path)
  fail()
  newJObject()

suite "Top-level sync/pull shortcuts match the workspace forms":

  test "t_top_level_sync_pull_shortcuts_match_workspace_forms":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # -------------------------------------------------------------------
      # Part 1+2: top-level ``repro sync`` (dry-run, then real) vs the
      # ``workspace sync`` control on an identical clone.
      # -------------------------------------------------------------------
      let fx = setupFixture(gitBin, "sync")
      defer: removeDir(fx.scratch)

      let oldSha =
        cloneFirstCommit(gitBin, fx.aOrigin, fx.workspaceRoot / "lib-a", "dev")
      check headSha(gitBin, fx.workspaceRoot / "lib-a") == oldSha
      check oldSha != fx.aTip

      # (1) ``repro sync --dry-run`` (TOP-LEVEL) is plan-only: exit 0, NO
      #     mutation. Before the fix this exits non-zero (usage banner) and
      #     never reaches the plan path.
      let dryRun = runShell(shellCommand(@[
        fx.reproBin, "sync", "myproject",
        "--workspace-root=" & fx.workspaceRoot, "--dry-run",
      ]))
      if dryRun.code != 0:
        checkpoint("dry-run output: " & dryRun.output)
      check dryRun.code == 0
      check headSha(gitBin, fx.workspaceRoot / "lib-a") == oldSha  # untouched

      # (2) ``repro sync`` (TOP-LEVEL) fast-forwards lib-a to origin/dev's
      #     tip — the same effect as ``repro workspace sync``.
      let sync = runShell(shellCommand(@[
        fx.reproBin, "sync", "myproject",
        "--workspace-root=" & fx.workspaceRoot,
      ]))
      if sync.code != 0:
        checkpoint("sync output: " & sync.output)
      check sync.code == 0
      check headSha(gitBin, fx.workspaceRoot / "lib-a") == fx.aTip
      check currentBranch(gitBin, fx.workspaceRoot / "lib-a") == "dev"

      let syncReport = readSyncReport(fx.workspaceRoot)
      check repoEntry(syncReport, "lib-a")["syncCase"].getStr() ==
        "clean_fast_forwardable"
      check repoEntry(syncReport, "lib-a")["executionStatus"].getStr() ==
        "succeeded"

      # Control: a SECOND clone synced through ``repro workspace sync`` lands
      # at the very same tip — proving the top-level shortcut and the
      # workspace form converge identically.
      let ctlFx = setupFixture(gitBin, "sync-control")
      defer: removeDir(ctlFx.scratch)
      let ctlOld =
        cloneFirstCommit(gitBin, ctlFx.aOrigin, ctlFx.workspaceRoot / "lib-a",
          "dev")
      check ctlOld != ctlFx.aTip
      let ctlSync = runShell(shellCommand(@[
        ctlFx.reproBin, "workspace", "sync", "myproject",
        "--workspace-root=" & ctlFx.workspaceRoot,
      ]))
      check ctlSync.code == 0
      check headSha(gitBin, ctlFx.workspaceRoot / "lib-a") == ctlFx.aTip
      # Both forms left the repo on the same branch at the manifest tip.
      check currentBranch(gitBin, ctlFx.workspaceRoot / "lib-a") ==
        currentBranch(gitBin, fx.workspaceRoot / "lib-a")

      # -------------------------------------------------------------------
      # Part 3: top-level ``repro pull`` converges a parked clone to the
      # manifest revision on a tracking branch — like ``workspace pull``.
      # -------------------------------------------------------------------
      let pf = setupFixture(gitBin, "pull")
      defer: removeDir(pf.scratch)

      let pOld =
        cloneFirstCommit(gitBin, pf.aOrigin, pf.workspaceRoot / "lib-a", "dev")
      # Park on a DIFFERENT branch at the OLD commit so a converge is
      # observable (pull must realign to the manifest revision ``dev``).
      discard requireGit(q(gitBin) & " -C " & q(pf.workspaceRoot / "lib-a") &
        " checkout -b scratch " & pOld)
      check currentBranch(gitBin, pf.workspaceRoot / "lib-a") == "scratch"

      let pull = runShell(shellCommand(@[
        pf.reproBin, "pull", "myproject",
        "--workspace-root=" & pf.workspaceRoot,
      ]))
      if pull.code != 0:
        checkpoint("pull output: " & pull.output)
      check pull.code == 0
      check headSha(gitBin, pf.workspaceRoot / "lib-a") == pf.aTip
      check currentBranch(gitBin, pf.workspaceRoot / "lib-a") == "dev"

      let pullReport = readPullReport(pf.workspaceRoot)
      check repoEntry(pullReport, "lib-a")["trackingBranch"].getStr() == "dev"
      check repoEntry(pullReport, "lib-a")["headSha"].getStr() == pf.aTip

## RA-25 — `repro push --sync` reconciles upstream movement BEFORE publishing
## the closure (CLI/push.md §"--sync flavor"), and STOPS with a remedy on a
## conflict that needs human judgment (publishing nothing misleading).
##
## Part 1 — integrate-then-publish (--rebase). A closure member (``lib``) has
## a LOCAL unpublished commit AND its upstream advanced (a teammate pushed a
## non-conflicting commit to a different file). Plain ``repro push`` would
## refuse this divergence; ``repro push --sync --rebase`` fetches, REBASES the
## local commit onto the teammate's commit (integrating the upstream movement
## FIRST), then publishes the closure on top. Assertions:
##   - the push succeeds (exit 0);
##   - the teammate's upstream commit is now in lib's LOCAL history
##     (integrated);
##   - lib's local commit is now PUBLISHED (the bare advanced past the
##     teammate commit), i.e. published AFTER the integration.
## Falsifiable: skip the sync step (plain ``repro push``) and lib refuses
## (non-zero, divergent) — the upstream is never integrated. A control at the
## end runs plain ``repro push`` on the same divergence and asserts it refuses.
##
## Part 2 — conflict stops with a remedy. The teammate's upstream commit and
## the local commit edit the SAME line. ``repro push --sync --rebase`` cannot
## auto-integrate: it STOPS (non-zero) with a remedy NAMING the repo, and
## publishes nothing (the manifest bare is untouched).
##
## Hermetic: only local ``git init`` / ``git init --bare`` repos; no network.
## Skip rule: ``git`` missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]

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
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedGitOrigin(gitBin, originPath, workPath, seedFile: string;
                   branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA25 Tester\"")
  writeFile(workPath / seedFile, "base\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add " & seedFile)
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(originPath)) & " " & q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"RA25 Tester\"")

proc commitFile(gitBin, repoPath, file, content, message: string): string =
  writeFile(repoPath / file, content)
  discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add " & file)
  discard requireGit(q(gitBin) & " -C " & q(repoPath) & " commit -m " & q(message))
  result = requireGit(q(gitBin) & " -C " & q(repoPath) &
    " rev-parse HEAD").strip()

proc teammatePush(gitBin, origin, scratch, slug, file, content: string): string =
  ## Simulate a teammate: clone the bare, commit, push — so ``origin`` now has
  ## a commit the workspace clone has not yet seen.
  let mate = scratch / ("mate-" & slug)
  cloneInto(gitBin, origin, mate)
  result = commitFile(gitBin, mate, file, content, "teammate commit")
  discard requireGit(q(gitBin) & " -C " & q(mate) & " push origin main")

proc projectToml(appUrl, libUrl: string): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"app\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"app-origin\"\nfetch = \"" & appUrl & "\"\n\n" &
    "[[remote]]\nname = \"lib-origin\"\nfetch = \"" & libUrl & "\"\n\n" &
    "includes = [\n" &
    "  \"repos/app.toml\",\n" &
    "  \"repos/lib.toml\",\n" &
    "]\n"

const appFragment = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "app"
path = "app"
remote = "app-origin"
revision = "main"
depends = ["lib"]
"""

const libFragment = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib"
path = "lib"
remote = "lib-origin"
revision = "main"
"""

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    manifestBare: string
    appOrigin: string
    libOrigin: string

proc seedManifestGitLayer(gitBin, manifestsRoot, bare: string; branch = "main") =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " & q(bare))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(manifestsRoot))
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " config user.name \"RA25 Tester\"")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) & " add projects repos")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " commit -m \"seed manifest\"")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " remote add origin " & q(bare))
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " push -u origin " & branch)

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-ra25-sync-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.appOrigin = result.scratch / "origin-app.git"
  discard seedGitOrigin(gitBin, result.appOrigin,
    result.scratch / "seed-app", "README.md")
  result.libOrigin = result.scratch / "origin-lib.git"
  discard seedGitOrigin(gitBin, result.libOrigin,
    result.scratch / "seed-lib", "shared.txt")

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "app.toml",
    projectToml(fileUrl(result.appOrigin), fileUrl(result.libOrigin)))
  writeFile(manifestsRoot / "repos" / "app.toml", appFragment)
  writeFile(manifestsRoot / "repos" / "lib.toml", libFragment)
  result.manifestBare = result.scratch / "manifest.git"
  seedManifestGitLayer(gitBin, manifestsRoot, result.manifestBare)

  cloneInto(gitBin, result.appOrigin, workspaceRoot / "app")
  cloneInto(gitBin, result.libOrigin, workspaceRoot / "lib")
  result.workspaceRoot = workspaceRoot
  writeWorkspaceBranch(workspaceRoot, project = "app", branch = "main")

proc invokePush(fx: Fixture; extra: openArray[string]): CmdResult =
  var argv = @[fx.reproBin, "push"]
  for e in extra: argv.add(e)
  argv.add("--no-certify")
  argv.add("--workspace-root=" & fx.workspaceRoot)
  argv.add("--current-repo=" & (fx.workspaceRoot / "app"))
  argv.add("--json")
  runShell(shellCommand(argv))

proc readReport(fx: Fixture): JsonNode =
  let p = fx.workspaceRoot / ".repro" / "workspace" / "push-report.json"
  check fileExists(p)
  parseFile(p)

proc libContainsInLocalHistory(gitBin, repoPath, sha: string): bool =
  ## True iff ``sha`` is reachable from the local HEAD (the teammate commit
  ## was integrated).
  let r = runCmd(q(gitBin) & " -C " & q(repoPath) &
    " merge-base --is-ancestor " & sha & " HEAD")
  r.code == 0

proc bareHead(gitBin, bare: string): string =
  requireGit(q(gitBin) & " -C " & q(bare) & " rev-parse refs/heads/main").strip()

suite "RA-25 — repro push --sync integrates upstream then publishes":

  test "t_repro_push_sync_integrates_upstream_then_publishes":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # ---- Part 1: --sync --rebase integrates upstream, then publishes ----
      let fx = setupFixture(gitBin, "ok")
      defer: removeDir(fx.scratch)

      # Teammate advances lib's upstream on a DIFFERENT file (no conflict).
      let mateSha = teammatePush(gitBin, fx.libOrigin, fx.scratch, "ok",
        "teammate.txt", "from teammate\n")

      # Our local lib commit (unpublished) edits yet another file.
      discard commitFile(gitBin, fx.workspaceRoot / "lib", "local.txt",
        "local work\n", "lib local work")
      # The teammate commit is NOT yet in our local history (we haven't synced).
      check not libContainsInLocalHistory(gitBin, fx.workspaceRoot / "lib",
        mateSha)

      let res = invokePush(fx, ["--sync", "--rebase"])
      checkpoint("sync push output: " & res.output)
      check res.code == 0
      let report = readReport(fx)
      check report["exitCode"].getInt() == 0

      # The sync step integrated upstream movement (rebase or fast-forward)
      # for lib BEFORE publishing.
      var libIntegrated = false
      for sr in report["syncResults"]:
        if sr["name"].getStr() == "lib":
          libIntegrated = sr["integrated"].getBool()
      check libIntegrated

      # The teammate's upstream commit is now in lib's LOCAL history.
      # Falsifiable: a no-op sync leaves it absent.
      check libContainsInLocalHistory(gitBin, fx.workspaceRoot / "lib", mateSha)

      # lib's local commit is PUBLISHED on top of the teammate commit: the
      # bare's main now contains both local.txt and teammate.txt, and the
      # teammate commit is an ancestor of the published tip.
      let libBareTip = bareHead(gitBin, fx.libOrigin)
      let mateAncestor = runCmd(q(gitBin) & " -C " &
        q(fx.workspaceRoot / "lib") & " merge-base --is-ancestor " &
        mateSha & " " & libBareTip)
      check mateAncestor.code == 0
      let ls = runCmd(q(gitBin) & " -C " & q(fx.libOrigin) &
        " ls-tree -r --name-only refs/heads/main")
      check ls.code == 0
      check ls.output.contains("local.txt")
      check ls.output.contains("teammate.txt")
      check report["lockPublished"].getBool()

      # ---- Control: plain push (no --sync) REFUSES the divergence ---------
      # Same divergence, fresh fixture: without --sync the divergent member
      # is not reconciled and the push refuses (proving the sync step is
      # load-bearing).
      let fxc = setupFixture(gitBin, "ctrl")
      defer: removeDir(fxc.scratch)
      let mateShaC = teammatePush(gitBin, fxc.libOrigin, fxc.scratch, "ctrl",
        "teammate.txt", "from teammate\n")
      discard commitFile(gitBin, fxc.workspaceRoot / "lib", "local.txt",
        "local work\n", "lib local work")
      # Fetch so the local clone SEES the divergence (origin/main ahead).
      discard requireGit(q(gitBin) & " -C " & q(fxc.workspaceRoot / "lib") &
        " fetch origin")
      let plain = invokePush(fxc, [])
      checkpoint("plain push output: " & plain.output)
      check plain.code != 0
      # The teammate commit was NOT integrated by the refused plain push.
      check not libContainsInLocalHistory(gitBin, fxc.workspaceRoot / "lib",
        mateShaC)

  test "t_repro_push_sync_conflict_stops_with_remedy":
    # A conflicting upstream commit cannot be auto-integrated: push --sync
    # STOPS (non-zero) with a remedy naming the repo, publishing nothing.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "conflict")
      defer: removeDir(fx.scratch)
      let manifestBefore = bareHead(gitBin, fx.manifestBare)

      # Teammate edits shared.txt; our local commit edits the SAME file's
      # same content differently → rebase conflict.
      let mateSha = teammatePush(gitBin, fx.libOrigin, fx.scratch, "conflict",
        "shared.txt", "teammate version\n")
      discard commitFile(gitBin, fx.workspaceRoot / "lib", "shared.txt",
        "local version\n", "lib local conflicting work")

      let res = invokePush(fx, ["--sync", "--rebase"])
      checkpoint("conflict push output: " & res.output)
      # STOPS with a non-zero exit.
      check res.code != 0
      let report = readReport(fx)
      check report["exitCode"].getInt() != 0

      # A sync result for lib is STOPPED with a remedy naming the repo.
      var libStopped = false
      var remedyNamesLib = false
      for sr in report["syncResults"]:
        if sr["name"].getStr() == "lib" and sr["stopped"].getBool():
          libStopped = true
          remedyNamesLib = sr["remediation"].getStr().contains("lib") or
            sr["diagnostic"].getStr().contains("lib")
      check libStopped
      check remedyNamesLib

      # Published NOTHING misleading: the manifest bare did not advance, and
      # lib's local commit never reached its bare.
      check bareHead(gitBin, fx.manifestBare) == manifestBefore
      discard mateSha

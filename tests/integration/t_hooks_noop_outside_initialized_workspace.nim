## RA-10 — Workspace marker; hooks no-op outside an initialized workspace.
##
## The managed VCS hooks (pre-push gate + post-commit lock refresh) are
## installed per participating repo by ``repro hooks ensure --vcs`` and,
## at git time, dispatch into ``repro hooks dispatch <hook> --repo-root
## <repo> ...`` (pre-push additionally forwards ``--refs-file``). A
## managed hook may end up running under a *half-bootstrapped* or
## *non-workspace* parent — a plain git repo, or a bare ``.repo/`` that
## ``repo init`` left behind before the manifest repo was actually
## checked out. In that case there is nothing to enforce, and the hooks
## MUST no-op with success: they exit 0 and do nothing, never blocking
## the commit/push with a fatal error.
##
## The canonical "initialized workspace" marker is the presence of a
## *resolved manifest checkout* — a ``.repo/workspace.toml`` OR at least
## one resolved ``projects/*.toml`` / ``variants/*.toml`` under
## ``.repo/manifests`` — NOT merely a bare ``.repo/`` directory. The
## shared predicate ``isInitializedWorkspace`` (re-exported from
## ``repro_workspace_manifests``) backs both the hook-skip logic and any
## init-skip logic.
##
## This suite is falsifiable + hermetic:
##   * Falsifiable — it asserts the EXACT no-op contract (exit 0, the
##     "not a workspace" diagnostic, no lock file written) for genuine
##     non-workspaces AND, by contrast, asserts that a REAL initialized
##     workspace's hooks still RUN (pre-push gate exits 0 only after the
##     actual checks pass; post-commit writes a lock). If the no-op were
##     to fire inside a real workspace, or fail to fire outside one,
##     these checks fail.
##   * Hermetic — every git repo and manifest checkout lives in a fresh
##     tempdir; nothing touches ``$HOME`` or any shared cache.
##
## Skip rule: ``git`` missing on PATH (same convention as M17 / M18 /
## M19).

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests

# ---- helpers --------------------------------------------------------------

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
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA10 Tester\"")
  writeFile(workPath / "README.md", "RA10 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(originPath)) & " " & q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"RA10 Tester\"")

proc projectTomlWith3Remotes(libAUrl, libBUrl, libCUrl: string): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"lib-a\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
    "[[remote]]\nname = \"lib-b-origin\"\nfetch = \"" & libBUrl & "\"\n\n" &
    "[[remote]]\nname = \"lib-c-origin\"\nfetch = \"" & libCUrl & "\"\n\n" &
    "includes = [\n" &
    "  \"repos/lib-a.toml\",\n" &
    "  \"repos/lib-b.toml\",\n" &
    "  \"repos/lib-c.toml\",\n" &
    "]\n"

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "main"
"""

const libBFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-b"
path = "lib-b"
remote = "lib-b-origin"
revision = "main"
"""

const libCFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-c"
path = "lib-c"
remote = "lib-c-origin"
revision = "main"
"""

type
  RepoSeed = object
    name: string
    origin: string
    seedPath: string
    sha: string

  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    libA: RepoSeed
    libB: RepoSeed
    libC: RepoSeed

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-ra10-" & slug & "-", "")
  result.reproBin = reproBinary()

  result.libA.name = "lib-a"
  result.libA.origin = result.scratch / "origin-lib-a.git"
  result.libA.seedPath = result.scratch / "seed-lib-a"
  result.libA.sha = seedGitOrigin(gitBin, result.libA.origin,
    result.libA.seedPath)
  result.libB.name = "lib-b"
  result.libB.origin = result.scratch / "origin-lib-b.git"
  result.libB.seedPath = result.scratch / "seed-lib-b"
  result.libB.sha = seedGitOrigin(gitBin, result.libB.origin,
    result.libB.seedPath)
  result.libC.name = "lib-c"
  result.libC.origin = result.scratch / "origin-lib-c.git"
  result.libC.seedPath = result.scratch / "seed-lib-c"
  result.libC.sha = seedGitOrigin(gitBin, result.libC.origin,
    result.libC.seedPath)

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "lib-a.toml",
    projectTomlWith3Remotes(
      fileUrl(result.libA.origin),
      fileUrl(result.libB.origin),
      fileUrl(result.libC.origin)))
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  writeFile(manifestsRoot / "repos" / "lib-b.toml", libBFragmentToml)
  writeFile(manifestsRoot / "repos" / "lib-c.toml", libCFragmentToml)
  result.workspaceRoot = workspaceRoot

proc cloneAll(gitBin: string; fx: Fixture) =
  cloneInto(gitBin, fx.libA.origin, fx.workspaceRoot / "lib-a")
  cloneInto(gitBin, fx.libB.origin, fx.workspaceRoot / "lib-b")
  cloneInto(gitBin, fx.libC.origin, fx.workspaceRoot / "lib-c")

proc seedWorkspaceToml(fx: Fixture) =
  writeWorkspaceBranch(fx.workspaceRoot, project = "lib-a", branch = "main")

proc invokeEnsure(fx: Fixture): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "hooks", "ensure", "--vcs",
    "--workspace-root=" & fx.workspaceRoot,
  ]))

proc invokeDispatchPostCommit(fx: Fixture; repoRoot: string): CmdResult =
  ## Exact argv the managed post-commit hook body uses.
  runShell(shellCommand(@[
    fx.reproBin, "hooks", "dispatch", "post-commit",
    "--repo-root", repoRoot, "--",
  ]))

proc writeRefsFile(path: string; localRef, localSha: string) =
  let zeroSha = "0000000000000000000000000000000000000000"
  writeFile(path, localRef & " " & localSha & " " &
    "refs/heads/main " & zeroSha & "\n")

proc invokeDispatchPrePush(fx: Fixture; repoRoot, refsFile: string):
    CmdResult =
  ## Exact argv the managed pre-push hook body uses: ``--repo-root`` plus
  ## ``--refs-file`` pointing at the refs git streamed on stdin.
  runShell(shellCommand(@[
    fx.reproBin, "hooks", "dispatch", "pre-push",
    "--repo-root", repoRoot,
    "--refs-file", refsFile,
    "--",
  ]))

proc invokeCheckPrePush(fx: Fixture; workspaceRoot, currentRepo,
                        refsFile: string): CmdResult =
  ## Direct ``repro check --mode=pre-push`` — the body the dispatcher
  ## calls into. We exercise it directly so the no-op decision is
  ## observable independent of the dispatch ``--refs-file`` short-circuit.
  runShell(shellCommand(@[
    fx.reproBin, "check", "--mode=pre-push",
    "--workspace-root=" & workspaceRoot,
    "--current-repo=" & currentRepo,
    "--pushed-refs=" & refsFile,
  ]))

proc postCommitReport(fx: Fixture; workspaceRoot: string): JsonNode =
  let reportPath = workspaceRoot / ".repro" / "workspace" /
    "post-commit-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

# ---- the suite -------------------------------------------------------------

suite "RA-10 — hooks no-op outside an initialized workspace":

  test "t_hooks_noop_outside_initialized_workspace":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # ============================================================
      # Part 1 — a genuine NON-workspace: a plain git repo whose parent
      # has NO ``.repo/`` at all. Install the managed hooks against a real
      # workspace first, then point the dispatched hook bodies at a
      # standalone repo that is not under any workspace. The hooks must
      # exit 0 and do nothing.
      # ============================================================
      let fx = setupFixture(gitBin, "noop")
      defer: removeDir(fx.scratch)
      cloneAll(gitBin, fx)
      seedWorkspaceToml(fx)

      # Install the real managed hooks (proves the no-op is in the hook
      # COMMAND, not a side effect of skipping installation).
      let ensureRes = invokeEnsure(fx)
      if ensureRes.code != 0:
        checkpoint("ensure output: " & ensureRes.output)
      check ensureRes.code == 0

      # A plain git repo with NO ``.repo/`` anywhere above it.
      let lonePath = fx.scratch / "lone-repo"
      cloneInto(gitBin, fx.libA.origin, lonePath)
      let loneSha = requireGit(q(gitBin) & " -C " & q(lonePath) &
        " rev-parse HEAD").strip()

      # post-commit dispatched under the non-workspace → exit 0, no-op.
      let pcLone = invokeDispatchPostCommit(fx, lonePath)
      check pcLone.code == 0
      # No workspace root is reachable from the lone repo, so no report
      # is written there — and crucially NO lock file is produced.
      check not dirExists(lonePath / ".repo")

      # pre-push body dispatched under the non-workspace → exit 0, no-op,
      # with the clear "not a workspace" diagnostic.
      let loneRefs = fx.scratch / "lone-refs.txt"
      writeRefsFile(loneRefs, "refs/heads/main", loneSha)
      let ppLoneDispatch = invokeDispatchPrePush(fx, lonePath, loneRefs)
      check ppLoneDispatch.code == 0
      # Direct ``repro check`` against the lone repo: walks up, finds no
      # ``.repo/`` (falls back to cwd), no resolved manifest checkout →
      # no-op exit 0 + diagnostic. (Falsifiable: before RA-10 this raised
      # a blocking exit 1.)
      let ppLoneCheck = invokeCheckPrePush(fx,
        workspaceRoot = lonePath, currentRepo = lonePath,
        refsFile = loneRefs)
      check ppLoneCheck.code == 0
      check ppLoneCheck.output.contains("not a workspace")

      # ============================================================
      # Part 2 — a HALF-BOOTSTRAPPED parent: a bare ``.repo/`` with NO
      # resolved manifest checkout (no workspace.toml, no projects/*.toml).
      # The canonical marker must reject this and the hooks must no-op.
      # ============================================================
      let halfRoot = fx.scratch / "half-bootstrapped"
      createDir(halfRoot / ".repo")            # bare .repo/, nothing else
      let halfRepo = halfRoot / "lib-a"
      cloneInto(gitBin, fx.libA.origin, halfRepo)
      let halfSha = requireGit(q(gitBin) & " -C " & q(halfRepo) &
        " rev-parse HEAD").strip()

      # post-commit under the half-bootstrapped parent → exit 0,
      # ``skipped-no-workspace`` with the "not a workspace" diagnostic,
      # NO lock file written.
      let pcHalf = invokeDispatchPostCommit(fx, halfRepo)
      check pcHalf.code == 0
      let halfReport = postCommitReport(fx, halfRoot)
      check halfReport["exitCode"].getInt() == 0
      check halfReport["outcome"].getStr() == "skipped-no-workspace"
      check halfReport["lockFilePath"].getStr() == ""
      check halfReport["diagnostic"].getStr().contains("not a workspace")
      # No lock subtree created under the bare ``.repo/``.
      check not dirExists(halfRoot / ".repo" / "manifests")

      # pre-push under the half-bootstrapped parent → exit 0 + diagnostic.
      let halfRefs = fx.scratch / "half-refs.txt"
      writeRefsFile(halfRefs, "refs/heads/main", halfSha)
      let ppHalf = invokeCheckPrePush(fx,
        workspaceRoot = halfRoot, currentRepo = halfRepo,
        refsFile = halfRefs)
      check ppHalf.code == 0
      check ppHalf.output.contains("not a workspace")

      # ============================================================
      # Part 3 — CONTRAST: a REAL initialized workspace still ENFORCES.
      # The no-op must fire ONLY for genuine non-workspaces. Here the
      # post-commit writes a lock and the pre-push gate runs the actual
      # checks (and passes only because the fixture is clean + published).
      # ============================================================
      let realRepo = fx.workspaceRoot / "lib-a"
      let pcReal = invokeDispatchPostCommit(fx, realRepo)
      check pcReal.code == 0
      let realReport = postCommitReport(fx, fx.workspaceRoot)
      check realReport["exitCode"].getInt() == 0
      # It RAN the lock refresh — outcome "ok", a lock file was written.
      check realReport["outcome"].getStr() == "ok"
      let realLock = realReport["lockFilePath"].getStr()
      check realLock.len > 0
      check fileExists(realLock)
      # The diagnostic is NOT the no-op message.
      check not realReport["diagnostic"].getStr().contains("not a workspace")

      # The real pre-push gate runs the actual checks and does NOT print
      # the no-op diagnostic.
      let realRefs = fx.scratch / "real-refs.txt"
      writeRefsFile(realRefs, "refs/heads/main", fx.libA.sha)
      let ppReal = invokeCheckPrePush(fx,
        workspaceRoot = fx.workspaceRoot, currentRepo = realRepo,
        refsFile = realRefs)
      check ppReal.code == 0
      check not ppReal.output.contains("not a workspace")

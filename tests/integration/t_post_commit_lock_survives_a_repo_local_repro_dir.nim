## The managed ``post-commit`` hook must refresh the workspace lock for a repo
## that carries its own ``.repro/`` directory.
##
## Every repo that has ever been built by ``repro`` has a repo-local
## ``.repro/`` (build reports, engine caches), and every repo that carries a
## committed ``repro.lock`` is, on its own, a manifest-optional workspace
## (MO-2). Put those two facts together and the post-commit hook's upward
## search for the workspace root — which stopped at the FIRST ancestor holding
## a ``.repro/`` directory — stopped at the repo itself. It then asked the
## strict lock writer to lock a "workspace" that has no ``.repro/workspace.toml``
## and no project, and the writer refused:
##
##   repro post-commit: no-lock-failed: NO lock written: `repro workspace lock`
##   requires either `.repro/workspace.toml` or a <project> argument; neither
##   was present at <repo>
##
## The hook exits 0 by design, so the refusal is not fatal — it is silent
## starvation: every commit in every built repo of a real workspace wrote no
## lock at all, and the report naming the failure was filed under the REPO's
## ``.repro/`` where nothing looks for it.
##
## This test drives the REAL entry point: ``repro hooks ensure --vcs`` installs
## the managed hooks and a plain ``git commit`` fires them. Assertions, each
## falsifiable:
##
##   1. The trap is present — the repo carries both a ``.repro/`` directory and
##      a committed ``repro.lock`` BEFORE the commit. (Without these the test
##      would pass against the defect and prove nothing.)
##   2. The commit succeeds (post-commit is non-blocking either way).
##   3. The post-commit report is filed at the WORKSPACE root and names the
##      WORKSPACE as ``workspaceRoot`` — not the repo.
##   4. A lock record was actually WRITTEN: ``lockWritten`` is true, the
##      outcome is not ``no-lock-failed``, and the file named by
##      ``lockFilePath`` exists on disk at
##      ``locks/<project>/<repo>/<sha>.toml`` for the sha just committed.
##      This is the strong form — a report string alone would not prove a lock.
##   5. No post-commit report was filed inside the repo's own ``.repro/``:
##      the hook did not mistake the repo for the workspace.
##
## The second case covers the layer underneath, which only becomes visible once
## the workspace root resolves correctly. A workspace participates in a SET of
## projects, and post-commit was supplying the PRIMARY project's name as if the
## operator had passed ``repro workspace lock <project>``. Naming a project is
## how you ask for exactly that project, so the lock resolver stopped unioning
## the active set — and every commit in a repo declared by a NON-primary
## project refused with
##
##   triggering repo at '<repo>' is not declared in project '<primary>';
##   no lock can be anchored at it
##
## again silently, because post-commit never blocks. Nobody passed post-commit
## a project; it must let the workspace speak for itself. The case commits in a
## repo declared ONLY by the non-primary project and requires a lock record on
## disk.
##
## Hermetic: local ``git init --bare`` upstream + workspace under one
## ``createTempDir``; no network. Skip rule: ``git`` missing on PATH.

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
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc configIdentity(gitBin, repoPath: string) =
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.name \"PostCommit Tester\"")

suite "post-commit lock refresh survives a repo-local .repro directory":

  test "t_post_commit_lock_survives_a_repo_local_repro_dir":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-postcommit-repolocal-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      # ---- upstream + seed commit -------------------------------------
      let origin = scratch / "origin.git"
      let seedPath = scratch / "seed"
      discard requireGit(q(gitBin) & " init --bare -b main " & q(origin))
      discard requireGit(q(gitBin) & " init -b main " & q(seedPath))
      configIdentity(gitBin, seedPath)
      writeFile(seedPath / "README.md", "post-commit fixture\n")
      discard requireGit(q(gitBin) & " -C " & q(seedPath) & " add README.md")
      discard requireGit(q(gitBin) & " -C " & q(seedPath) & " commit -m base")
      discard requireGit(q(gitBin) & " -C " & q(seedPath) &
        " remote add origin " & q(origin))
      discard requireGit(q(gitBin) & " -C " & q(seedPath) & " push origin main")
      let originUrl = fileUrl(origin)

      # ---- workspace + manifests --------------------------------------
      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot)
      createDir(workspaceRoot / "projects")
      createDir(workspaceRoot / "repos")
      writeFile(workspaceRoot / "projects" / "lib-a.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"lib-a\"\ndefault_revision = \"main\"\n" &
        "trunk = \"main\"\n\n" &
        "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" &
          originUrl & "\"\n\n" &
        "includes = [\n  \"repos/lib-a.toml\",\n]\n")
      writeFile(workspaceRoot / "repos" / "lib-a.toml",
        "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
        "[repo]\nname = \"lib-a\"\npath = \"lib-a\"\n" &
        "remote = \"lib-a-origin\"\nrevision = \"main\"\n")
      writeWorkspaceBranch(workspaceRoot, project = "lib-a", branch = "main")

      # A manifest-backed lock route must be DECLARED, not inferred, so the
      # manifest layer is a real git checkout.
      let lockStore = workspaceRoot / ".repro" / "manifests"
      createDir(lockStore)
      discard requireGit(q(gitBin) & " init -b main " & q(lockStore))
      configIdentity(gitBin, lockStore)
      writeFile(lockStore / ".gitkeep", "")
      discard requireGit(q(gitBin) & " -C " & q(lockStore) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(lockStore) &
        " commit -m \"seed lock store\"")

      # ---- the participating repo -------------------------------------
      let repoPath = workspaceRoot / "lib-a"
      discard requireGit(q(gitBin) & " clone --branch main " & q(originUrl) &
        " " & q(repoPath))
      configIdentity(gitBin, repoPath)

      # (1) THE TRAP. A repo that has been built by `repro` carries a
      # repo-local `.repro/` holding build reports, and a repo that pins its
      # own dependencies carries a committed `repro.lock`. Neither makes the
      # repo the workspace.
      createDir(repoPath / ".repro" / "build" / "reports")
      writeFile(repoPath / ".repro" / "build" / "reports" / "build-report.json",
        "{}\n")
      # `.repro/` is build output, so a real repo ignores it — which is exactly
      # why it can sit there unnoticed and mislead a workspace-root search.
      writeFile(repoPath / ".gitignore", ".repro/\n")
      writeFile(repoPath / "repro.lock",
        "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
        "[lock]\nplatform = \"\"\noptimal = false\n" &
        "inputs_digest = \"\"\nvariants = []\npackages = []\ndeps = []\n")
      discard requireGit(q(gitBin) & " -C " & q(repoPath) &
        " add .gitignore repro.lock")
      discard requireGit(q(gitBin) & " -C " & q(repoPath) &
        " commit -m \"pin dependencies\"")
      check dirExists(repoPath / ".repro")
      check fileExists(repoPath / "repro.lock")

      # ---- install the managed hooks ----------------------------------
      let ensured = runShell(shellCommand(@[
        reproBin, "hooks", "ensure", "--vcs",
        "--workspace-root=" & workspaceRoot]))
      checkpoint("hooks ensure output: " & ensured.output)
      check ensured.code == 0
      check fileExists(repoPath / ".git" / "hooks" / "post-commit")

      # ---- (2) a REAL commit fires the REAL managed hook ---------------
      writeFile(repoPath / "feature.txt", "new work\n")
      discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add feature.txt")
      let committed = runShell(shellCommand(@[
        gitBin, "-C", repoPath, "commit", "-m", "lib-a feature"],
        @[(name: "REPROBUILD_REPRO", value: reproBin)]))
      checkpoint("git commit output: " & committed.output)
      check committed.code == 0
      let newSha = requireGit(q(gitBin) & " -C " & q(repoPath) &
        " rev-parse HEAD").strip()

      # ---- (3) the report is filed at the WORKSPACE, about the WORKSPACE
      let reportPath = workspaceRoot / ".repro" / "workspace" /
        "post-commit-report.json"
      check fileExists(reportPath)
      let report = parseFile(reportPath)
      checkpoint("post-commit report: " & $report)
      check report["workspaceRoot"].getStr() == workspaceRoot

      # ---- (4) a lock RECORD exists on disk ---------------------------
      # Falsifiable: under the defect the outcome is `no-lock-failed`,
      # `lockWritten` is false and `lockFilePath` is empty.
      check report["outcome"].getStr() != "no-lock-failed"
      check report["lockWritten"].getBool()
      let lockPath = report["lockFilePath"].getStr()
      check lockPath == workspaceRoot / ".repro" / "manifests" / "locks" /
        "lib-a" / "lib-a" / (newSha & ".toml")
      check fileExists(lockPath)

      # ---- (5) the repo was never mistaken for the workspace ----------
      check not fileExists(repoPath / ".repro" / "workspace" /
        "post-commit-report.json")

  test "t_post_commit_lock_covers_a_repo_of_a_non_primary_project":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-postcommit-multiproject-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      # ---- one upstream per project repo ------------------------------
      proc seedUpstream(name: string): string =
        let origin = scratch / (name & ".git")
        let seedPath = scratch / ("seed-" & name)
        discard requireGit(q(gitBin) & " init --bare -b main " & q(origin))
        discard requireGit(q(gitBin) & " init -b main " & q(seedPath))
        configIdentity(gitBin, seedPath)
        writeFile(seedPath / "README.md", name & " fixture\n")
        discard requireGit(q(gitBin) & " -C " & q(seedPath) & " add README.md")
        discard requireGit(q(gitBin) & " -C " & q(seedPath) & " commit -m base")
        discard requireGit(q(gitBin) & " -C " & q(seedPath) &
          " remote add origin " & q(origin))
        discard requireGit(q(gitBin) & " -C " & q(seedPath) &
          " push origin main")
        fileUrl(origin)

      let alphaUrl = seedUpstream("alpha-repo")
      let betaUrl = seedUpstream("beta-repo")

      # ---- a workspace participating in TWO projects ------------------
      # ``alpha`` is the PRIMARY; ``beta-repo`` is declared ONLY by ``beta``.
      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot)
      createDir(workspaceRoot / "projects")
      createDir(workspaceRoot / "repos")
      proc writeProject(project, repoName, url: string) =
        writeFile(workspaceRoot / "projects" / (project & ".toml"),
          "schema = \"reprobuild.workspace.project.v1\"\n\n" &
          "[project]\nname = \"" & project & "\"\n" &
          "default_revision = \"main\"\ntrunk = \"main\"\n\n" &
          "[[remote]]\nname = \"" & repoName & "-origin\"\nfetch = \"" &
            url & "\"\n\n" &
          "includes = [\n  \"repos/" & repoName & ".toml\",\n]\n")
        writeFile(workspaceRoot / "repos" / (repoName & ".toml"),
          "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
          "[repo]\nname = \"" & repoName & "\"\npath = \"" & repoName & "\"\n" &
          "remote = \"" & repoName & "-origin\"\nrevision = \"main\"\n")

      writeProject("alpha", "alpha-repo", alphaUrl)
      writeProject("beta", "beta-repo", betaUrl)
      createDir(workspaceRoot / ".repro")
      writeFile(workspaceRoot / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\nproject = \"alpha\"\n" &
        "projects = [\"alpha\", \"beta\"]\n")

      let lockStore = workspaceRoot / ".repro" / "manifests"
      createDir(lockStore)
      discard requireGit(q(gitBin) & " init -b main " & q(lockStore))
      configIdentity(gitBin, lockStore)
      writeFile(lockStore / ".gitkeep", "")
      discard requireGit(q(gitBin) & " -C " & q(lockStore) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(lockStore) &
        " commit -m \"seed lock store\"")

      for (repoName, url) in [("alpha-repo", alphaUrl), ("beta-repo", betaUrl)]:
        discard requireGit(q(gitBin) & " clone --branch main " & q(url) & " " &
          q(workspaceRoot / repoName))
        configIdentity(gitBin, workspaceRoot / repoName)

      # ---- commit in the NON-PRIMARY project's repo -------------------
      let betaRepo = workspaceRoot / "beta-repo"
      writeFile(betaRepo / "feature.txt", "beta work\n")
      discard requireGit(q(gitBin) & " -C " & q(betaRepo) & " add feature.txt")
      discard requireGit(q(gitBin) & " -C " & q(betaRepo) &
        " commit -m \"beta feature\"")
      let betaSha = requireGit(q(gitBin) & " -C " & q(betaRepo) &
        " rev-parse HEAD").strip()

      let dispatched = runShell(shellCommand(@[
        reproBin, "hooks", "dispatch", "post-commit",
        "--repo-root", betaRepo, "--"]))
      checkpoint("post-commit output: " & dispatched.output)
      check dispatched.code == 0

      let reportPath = workspaceRoot / ".repro" / "workspace" /
        "post-commit-report.json"
      check fileExists(reportPath)
      let report = parseFile(reportPath)
      checkpoint("post-commit report: " & $report)
      # Falsifiable: with the primary project's name supplied as if it were an
      # operator's `<project>` argument, the active set is not unioned,
      # `beta-repo` is not declared in `alpha`, and the outcome is
      # `no-lock-failed` with an empty `lockFilePath`.
      check report["outcome"].getStr() != "no-lock-failed"
      check report["lockWritten"].getBool()
      check report["triggerRepo"].getStr() == "beta-repo"
      let lockPath = report["lockFilePath"].getStr()
      check lockPath.len > 0
      check fileExists(lockPath)
      # The record is anchored at the repo whose commit fired the hook.
      check lockPath.endsWith("beta-repo" / (betaSha & ".toml"))

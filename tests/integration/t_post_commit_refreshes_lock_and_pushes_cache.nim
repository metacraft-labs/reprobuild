## RA-4 — post-commit refreshes the lock locally AND pushes the branch to
## the namespaced cache ref, without blocking the commit.
##
## Models repo-workspaces `d358ecb` (async post-commit cache push) layered
## on the M19 best-effort lock refresh. Scenario:
##
##   * One repo (`lib-a`) in a metadata-only workspace, cloned from a local
##     upstream and wired to a per-upstream shared bare (RA-5) via
##     `objects/info/alternates`.
##   * A commit fires the post-commit hook dispatch
##     (`repro hooks dispatch post-commit --repo-root <repo>`).
##
## Assertions (each falsifiable):
##
##   1. The dispatch returns 0 immediately — the commit is never blocked by
##      the (detached) cache push. (Falsifiable: a blocking/erroring push
##      would surface a non-zero exit or a long stall.)
##   2. The per-repo lock TOML is refreshed locally under
##      `locks/<project>/<repo>/<sha>.toml` (no network). (Falsifiable:
##      absent if the lock refresh regressed.)
##   3. The just-committed branch lands at `refs/cache/<workspace>/main` in
##      the shared bare, pointing at the new commit — pushed by the detached
##      child. We POLL for it (the push is asynchronous). (Falsifiable: a
##      negative control proves the ref is ABSENT before the commit; if the
##      detached push never fired, the poll times out and the test fails.)
##
## Hermetic: local `git init --bare` upstream + shared bare under one
## `createTempDir`, `REPRO_WORKSPACE_CLONES` pinned into that tempdir so the
## detached child resolves the SAME cache root. No network. Skip only when
## `git` is missing.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests
import shared_clones

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
    " config user.name \"RA4 Tester\"")

suite "RA-4 — post-commit refreshes lock and pushes cache ref":

  test "test_ra4_post_commit_refreshes_lock_and_pushes_cache_nonblocking":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra4-postcommit-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      # ---- upstream + seed commit -------------------------------------
      let origin = scratch / "origin.git"
      let seedPath = scratch / "seed"
      discard requireGit(q(gitBin) & " init --bare -b main " & q(origin))
      discard requireGit(q(gitBin) & " init -b main " & q(seedPath))
      configIdentity(gitBin, seedPath)
      writeFile(seedPath / "README.md", "ra4 fixture\n")
      discard requireGit(q(gitBin) & " -C " & q(seedPath) & " add README.md")
      discard requireGit(q(gitBin) & " -C " & q(seedPath) & " commit -m base")
      discard requireGit(q(gitBin) & " -C " & q(seedPath) &
        " remote add origin " & q(origin))
      discard requireGit(q(gitBin) & " -C " & q(seedPath) &
        " push origin main")
      let originUrl = fileUrl(origin)

      # ---- workspace + manifest ---------------------------------------
      # The workspace directory's basename becomes the cache namespace.
      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot)
      let wsName = extractFilename(workspaceRoot)

      let manifestsRoot = workspaceRoot / ".repo" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "lib-a.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"lib-a\"\ndefault_revision = \"main\"\n" &
        "trunk = \"main\"\n\n" &
        "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" &
          originUrl & "\"\n\n" &
        "includes = [\n  \"repos/lib-a.toml\",\n]\n")
      writeFile(manifestsRoot / "repos" / "lib-a.toml",
        "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
        "[repo]\nname = \"lib-a\"\npath = \"lib-a\"\n" &
        "remote = \"lib-a-origin\"\nrevision = \"main\"\n")
      writeWorkspaceBranch(workspaceRoot, project = "lib-a", branch = "main")

      # ---- shared bare (RA-5) pinned via REPRO_WORKSPACE_CLONES --------
      let cacheRoot = scratch / "clones-cache"
      putEnv("REPRO_WORKSPACE_CLONES", cacheRoot)
      defer: delEnv("REPRO_WORKSPACE_CLONES")

      let refreshed = refreshSharedBare(gitBin, cacheRoot, originUrl)
      check refreshed.ok
      let bare = refreshed.sharedBarePath
      # Confirm the path the production code will compute matches.
      check bare == sharedBarePath(cacheRoot, originUrl)

      # ---- clone lib-a and wire it to the shared bare -----------------
      let repoPath = workspaceRoot / "lib-a"
      discard requireGit(q(gitBin) & " clone --branch main " & q(originUrl) &
        " " & q(repoPath))
      configIdentity(gitBin, repoPath)
      check wireAlternates(repoPath, bare).ok
      check isWiredTo(repoPath, bare)

      # ---- new commit in lib-a ----------------------------------------
      writeFile(repoPath / "feature.txt", "new work\n")
      discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add feature.txt")
      discard requireGit(q(gitBin) & " -C " & q(repoPath) &
        " commit -m \"lib-a feature\"")
      let newSha = requireGit(q(gitBin) & " -C " & q(repoPath) &
        " rev-parse HEAD").strip()

      # Negative control (falsifiability): BEFORE the post-commit push the
      # cache ref does not exist in the shared bare.
      let beforeRef = runCmd(q(gitBin) & " -C " & q(bare) &
        " rev-parse --verify --quiet refs/cache/" & wsName & "/main")
      check beforeRef.code != 0

      # ---- fire the post-commit dispatch ------------------------------
      let res = runShell(shellCommand(@[
        reproBin, "hooks", "dispatch", "post-commit",
        "--repo-root", repoPath, "--"]))
      if res.code != 0:
        checkpoint("post-commit output: " & res.output)
      # (1) Non-blocking, never fails the commit.
      check res.code == 0

      # (2) The lock was refreshed LOCALLY under the per-repo path.
      let reportPath = workspaceRoot / ".repro" / "workspace" /
        "post-commit-report.json"
      check fileExists(reportPath)
      let report = parseFile(reportPath)
      check report["outcome"].getStr() == "ok"
      check report["triggerSha"].getStr() == newSha
      let lockPath = report["lockFilePath"].getStr()
      check lockPath == workspaceRoot / ".repo" / "manifests" / "locks" /
        "lib-a" / "lib-a" / (newSha & ".toml")
      check fileExists(lockPath)

      # (3) The detached push lands the cache ref. It is asynchronous, so
      # poll (bounded). Falsifiable: if the push never fires the ref stays
      # absent and the loop times out → the final check fails.
      var landed = false
      var refSha = ""
      for _ in 0 ..< 200:  # up to ~10s
        let probe = runCmd(q(gitBin) & " -C " & q(bare) &
          " rev-parse --verify --quiet refs/cache/" & wsName & "/main")
        if probe.code == 0:
          refSha = probe.output.strip()
          landed = true
          break
        sleep(50)
      check landed
      check refSha == newSha

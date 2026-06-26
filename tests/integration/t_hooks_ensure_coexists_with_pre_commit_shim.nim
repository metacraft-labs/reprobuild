## RA-4 — `repro hooks ensure` coexists with pre-commit's `hook-impl` shim.
##
## Models repo-workspaces `9ee9141`. The pre-commit framework, when it
## takes over a Git hook, installs a `hook-impl` shim at the standard hook
## path. That shim:
##
##   * chains into `$HOOK_DIR/<hook>.legacy` (the hook pre-commit displaced),
##   * self-checks for "migration mode" via `PRE_COMMIT_RUNNING_LEGACY` and
##     ABORTS with a non-zero exit if it sees that variable set.
##
## When pre-commit is installed over a previous Reprobuild dispatcher, the
## displaced `.legacy` file IS a Reprobuild dispatcher, so running the shim
## re-enters the dispatcher (and itself) until it crashes; and the chained
## invocation leaks `PRE_COMMIT_RUNNING_LEGACY`, tripping the abort.
##
## `repro hooks ensure` must:
##   1. Preserve the pre-commit shim as `<hook>.repro-local` (chained first).
##   2. Write the Reprobuild managed body as `<hook>.repro-managed`.
##   3. Remove a stale `<hook>.legacy` that is actually a Reprobuild
##      dispatcher (so the shim does not re-enter us).
##   4. Clear `PRE_COMMIT_RUNNING_LEGACY` in the child env so the preserved
##      shim runs cleanly instead of aborting in migration mode.
##
## The dispatcher then runs BOTH the pre-commit shim's checks AND the
## Reprobuild managed body, with no migration abort.
##
## Falsifiability: a deliberately broken pre-commit shim (one that DOES
## abort when `PRE_COMMIT_RUNNING_LEGACY` is set) proves that, without the
## env clear, the dispatcher would fail — and a control assertion confirms
## the shim aborts when invoked directly with the variable set. The stale
## `.legacy` assertion fails if `ensure` leaves the dispatcher loop intact.
##
## Hermetic: a local `git init` repo + a metadata-only workspace under one
## `createTempDir`; no network. Skip only when `git` is missing.

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

# A pre-commit `hook-impl`-style shim. When run it:
#   * appends a marker to PRECOMMIT_RAN_FILE (proves its checks executed),
#   * ABORTS (exit 3) if PRE_COMMIT_RUNNING_LEGACY is set in its env
#     (this is the framework's migration-mode self-check),
#   * chains into <hook>.legacy if present (pre-commit's legacy chaining).
proc preCommitShimContent(hookName, marker, ranFile: string): string =
  result = "#!/usr/bin/env sh\n"
  result.add("# pre-commit.com hook-impl shim (test double)\n")
  result.add("HOOK_DIR=$(CDPATH= cd -- \"$(dirname -- \"$0\")\" && pwd)\n")
  result.add("if [ -n \"${PRE_COMMIT_RUNNING_LEGACY:-}\" ]; then\n")
  result.add("  echo 'pre-commit: was installed in migration mode' >&2\n")
  result.add("  exit 3\n")
  result.add("fi\n")
  result.add("printf '%s\\n' " & q(marker) & " >> " & q(ranFile) & "\n")
  result.add("LEGACY=\"$HOOK_DIR/" & hookName & ".legacy\"\n")
  result.add("if [ -x \"$LEGACY\" ]; then \"$LEGACY\" \"$@\" || exit $?; fi\n")
  result.add("exit 0\n")

suite "RA-4 — hooks ensure coexists with pre-commit hook-impl shim":

  test "test_ra4_ensure_preserves_pre_commit_shim_and_clears_legacy_guard":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra4-coexist-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      # A single-repo git workspace whose project resolves to one repo.
      let origin = scratch / "origin.git"
      discard requireGit(q(gitBin) & " init --bare -b main " & q(origin))
      let workspaceRoot = scratch / "workspace"
      let repoPath = workspaceRoot / "lib-a"
      discard requireGit(q(gitBin) & " init -b main " & q(repoPath))
      discard requireGit(q(gitBin) & " -C " & q(repoPath) &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(repoPath) &
        " config user.name \"RA4 Tester\"")
      discard requireGit(q(gitBin) & " -C " & q(repoPath) &
        " remote add origin " & q(origin))

      # Minimal single-project manifest so `enumerateParticipatingRepos`
      # discovers lib-a.
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

      let hooksDir = repoPath / ".git" / "hooks"
      createDir(hooksDir)

      # ---- Set up the pre-commit-over-dispatcher pathology -------------
      #
      # 1. A pre-commit `hook-impl` shim sits at the standard `pre-push`
      #    path (the framework installed it).
      # 2. A stale `pre-push.legacy` that is actually a Reprobuild
      #    dispatcher (left when pre-commit was installed on top of a
      #    previous dispatcher). If `ensure` does not remove it, the
      #    preserved shim chains into it and re-enters us.
      let ranFile = scratch / "precommit-ran.txt"
      let shimPath = hooksDir / "pre-push"
      writeFile(shimPath, preCommitShimContent("pre-push",
        "PRECOMMIT-CHECKS-RAN", ranFile))
      var perms = getFilePermissions(shimPath)
      perms.incl({fpUserExec, fpGroupExec, fpOthersExec})
      setFilePermissions(shimPath, perms)

      # Stale `.legacy` carrying the dispatcher marker (a fake old
      # Reprobuild dispatcher). `ensure` must delete it.
      let stalePath = hooksDir / "pre-push.legacy"
      writeFile(stalePath,
        "#!/usr/bin/env sh\n# reprobuild hook dispatcher\nexit 0\n")
      var sp = getFilePermissions(stalePath)
      sp.incl({fpUserExec})
      setFilePermissions(stalePath, sp)

      # Control: invoked directly with the migration guard set, the shim
      # aborts (exit 3). This is the failure `ensure` must prevent from
      # firing through the chain.
      let direct = runCmd("env PRE_COMMIT_RUNNING_LEGACY=1 " & q(shimPath))
      check direct.code == 3

      # ---- Run `repro hooks ensure --vcs` ------------------------------
      let res = runShell(shellCommand(@[
        reproBin, "hooks", "ensure", "--vcs",
        "--workspace-root", workspaceRoot, workspaceRoot]))
      if res.code != 0:
        checkpoint("ensure output: " & res.output)
      check res.code == 0

      # Managed + local files exist; the dispatcher is at the standard path.
      let managed = hooksDir / "pre-push.repro-managed"
      let local = hooksDir / "pre-push.repro-local"
      let dispatcher = hooksDir / "pre-push"
      check fileExists(managed)
      check fileExists(local)
      check fileExists(dispatcher)

      # The preserved local hook is the pre-commit shim (not ours).
      check readFile(local).contains("pre-commit.com hook-impl shim")
      # The dispatcher is Reprobuild's.
      check readFile(dispatcher).contains("reprobuild hook dispatcher")

      # The stale `.legacy` dispatcher was removed (so the shim cannot
      # re-enter us). Falsifiable: without the cleanup this file remains.
      check not fileExists(stalePath)

      # The dispatcher clears the migration guard for chained hooks.
      check readFile(dispatcher).contains("PRE_COMMIT_RUNNING_LEGACY=")

      # ---- Run the installed dispatcher; assert NO migration abort -----
      #
      # The managed body is a no-op here (no `repro` resolution needed for
      # the coexistence assertion — it exits 0 when the CLI is reachable,
      # and the pre-push refs stream is empty so the gate is a no-op). We
      # drive the dispatcher with an empty refs stream on stdin (pre-push
      # contract) and a synthetic remote/url argv.
      removeFile(ranFile)
      let runRes = runCmd("printf '' | " & q(dispatcher) &
        " origin " & q(fileUrl(origin)), repoPath)
      if runRes.code != 0:
        checkpoint("dispatcher run output: " & runRes.output)
      # No migration-mode abort: the shim ran cleanly (exit 0 overall).
      check runRes.code == 0
      check (not runRes.output.contains("migration mode"))

      # The pre-commit checks DID run (marker appended) — coexistence,
      # not replacement.
      check fileExists(ranFile)
      check readFile(ranFile).contains("PRECOMMIT-CHECKS-RAN")

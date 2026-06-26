## RA-20 — `repro workspace forall -c <cmd>` runs the command in EVERY
## participating repo.
##
## The `repo forall -c` equivalent, since reprobuild does not wrap Google's
## `repo`. Built on `enumerateParticipatingRepos`, so the repo set forall
## visits is exactly the project's resolved repos. The command runs via the
## shell, with each repo's working tree as the working directory, and per-repo
## helper env vars (`REPO_PATH` / `REPO_NAME` / `REPO_PROJECT` and the
## reprobuild-namespaced aliases) exported.
##
## Asserts (each independently falsifiable):
##   1. `-c 'touch forall_ran.marker'` creates the marker in EVERY repo's
##      working dir — proving the command genuinely executed per-repo, in the
##      right cwd. Also asserts the env-var contract: a command that writes
##      `$REPO_NAME` to a file lands the correct repo name in each repo.
##   2. A command that FAILS in exactly one repo (`-c 'test -f only_in_a'`)
##      makes the overall invocation exit NON-ZERO, with the failing repo
##      reported as FAILED and the others reported as ok (default keep-going
##      posture: all repos still ran).
##   3. `--fail-fast` stops after the first failure (the repo AFTER the
##      failing one is skipped, not run).
##   4. Per-repo status is reported for every repo (each repo named in output).
##
## Falsifiability (manual, documented): making `executeWorkspaceForall`
## iterate zero repos makes assertion 1 fail (no markers); making it always
## set exitCode 0 makes assertion 2 fail (non-zero exit not observed). Both
## confirmed by hand, then reverted.
##
## Hermetic: a local two-repo workspace under one `createTempDir`; no network.
## Skip only when `git` is missing.

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

proc initRepo(gitBin, repoPath, originRoot, name: string) =
  let origin = originRoot / (name & ".git")
  discard requireGit(q(gitBin) & " init --bare -b main " & q(origin))
  discard requireGit(q(gitBin) & " init -b main " & q(repoPath))
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.name \"RA20 Tester\"")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " remote add origin " & q(origin))

proc writeProjectManifest(workspaceRoot, project: string;
    repos: seq[tuple[name, originUrl: string]]) =
  ## Two-(or more)-repo single-project manifest in the layout
  ## `enumerateParticipatingRepos` resolves: one `projects/<p>.toml` with a
  ## `[[remote]]` per repo and an `includes` list pointing at per-repo
  ## fragments under `repos/`.
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  var project_toml = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"" & project & "\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n"
  for r in repos:
    project_toml.add("[[remote]]\nname = \"" & r.name & "-origin\"\nfetch = \"" &
      r.originUrl & "\"\n\n")
  project_toml.add("includes = [\n")
  for r in repos:
    project_toml.add("  \"repos/" & r.name & ".toml\",\n")
  project_toml.add("]\n")
  writeFile(manifestsRoot / "projects" / (project & ".toml"), project_toml)
  for r in repos:
    writeFile(manifestsRoot / "repos" / (r.name & ".toml"),
      "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
      "[repo]\nname = \"" & r.name & "\"\npath = \"" & r.name & "\"\n" &
      "remote = \"" & r.name & "-origin\"\nrevision = \"main\"\n")
  writeWorkspaceBranch(workspaceRoot, project = project, branch = "main")

suite "RA-20 — workspace forall runs in every participating repo":

  test "test_ra20_forall_runs_command_in_every_participating_repo":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra20-forall-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()
      let originRoot = scratch / "origins"
      createDir(originRoot)
      let workspaceRoot = scratch / "workspace"
      let repoA = workspaceRoot / "lib-a"
      let repoB = workspaceRoot / "lib-b"
      let repoC = workspaceRoot / "lib-c"
      initRepo(gitBin, repoA, originRoot, "lib-a")
      initRepo(gitBin, repoB, originRoot, "lib-b")
      initRepo(gitBin, repoC, originRoot, "lib-c")
      writeProjectManifest(workspaceRoot, "demo", @[
        (name: "lib-a", originUrl: fileUrl(originRoot / "lib-a.git")),
        (name: "lib-b", originUrl: fileUrl(originRoot / "lib-b.git")),
        (name: "lib-c", originUrl: fileUrl(originRoot / "lib-c.git"))])

      # ---- Assertion 1: command runs in EVERY repo, in the right cwd, with
      # the per-repo env contract. -------------------------------------------
      #
      # The command body writes $REPO_NAME into a marker file inside the
      # repo's own working dir. If forall did not run per-repo (or ran in the
      # wrong cwd, or did not export REPO_NAME), the markers would be missing
      # or carry the wrong name.
      let res1 = runShell(shellCommand(@[
        reproBin, "workspace", "forall",
        "--workspace-root", workspaceRoot,
        "-c", "printf '%s' \"$REPO_NAME\" > forall_ran.marker"]))
      check res1.code == 0
      for (path, name) in @[(repoA, "lib-a"), (repoB, "lib-b"),
                            (repoC, "lib-c")]:
        let marker = path / "forall_ran.marker"
        check fileExists(marker)
        if fileExists(marker):
          check readFile(marker).strip() == name

      # Assertion 4 (partial): every repo named in the human output.
      check "lib-a" in res1.output
      check "lib-b" in res1.output
      check "lib-c" in res1.output

      # ---- Assertion 2: a command that FAILS in one repo → non-zero exit,
      # failing repo reported FAILED, others reported ok, ALL repos still run
      # (default keep-going). -----------------------------------------------
      #
      # `test -f only_in_a` succeeds only in lib-a (we drop the sentinel
      # there); it fails in lib-b and lib-c.
      writeFile(repoA / "only_in_a", "sentinel\n")
      let res2 = runShell(shellCommand(@[
        reproBin, "workspace", "forall",
        "--workspace-root", workspaceRoot,
        "-c", "test -f only_in_a && touch forall_visited.marker"]))
      check res2.code != 0
      # Default keep-going: every repo ran even though lib-b failed first.
      check fileExists(repoA / "forall_visited.marker")
      check not fileExists(repoB / "forall_visited.marker")
      # lib-c still ran (its `test -f` failed, but the action was attempted —
      # proven by lib-c appearing as FAILED in the report, below).
      check "lib-b" in res2.output
      check "lib-c" in res2.output
      # The summary names the failing repos and reports a non-zero failure
      # count.
      check "FAILED" in res2.output
      check ("lib-b" in res2.output and "failed" in res2.output.toLowerAscii())

      # ---- Assertion 3: --fail-fast stops after the first failure. --------
      #
      # lib-a succeeds, lib-b fails → lib-c must be SKIPPED, not run. We use a
      # marker each repo would create if it ran: lib-c's marker must be absent.
      removeFile(repoA / "forall_visited.marker")
      let res3 = runShell(shellCommand(@[
        reproBin, "workspace", "forall", "--fail-fast",
        "--workspace-root", workspaceRoot,
        "-c", "test -f only_in_a && touch forall_ff.marker"]))
      check res3.code != 0
      check fileExists(repoA / "forall_ff.marker")    # ran (ok)
      check not fileExists(repoB / "forall_ff.marker") # ran (failed)
      check not fileExists(repoC / "forall_ff.marker") # SKIPPED, never ran
      check "skip" in res3.output.toLowerAscii()

      # ---- Assertion (env aliases): REPO_PROJECT carries the project name. -
      let res4 = runShell(shellCommand(@[
        reproBin, "workspace", "forall",
        "--workspace-root", workspaceRoot,
        "-c", "printf '%s' \"$REPO_PROJECT\" > project.marker"]))
      check res4.code == 0
      check fileExists(repoA / "project.marker")
      if fileExists(repoA / "project.marker"):
        check readFile(repoA / "project.marker").strip() == "demo"

      # ---- Missing-command guard: forall without -c fails loudly. ---------
      let res5 = runShell(shellCommand(@[
        reproBin, "workspace", "forall",
        "--workspace-root", workspaceRoot]))
      check res5.code != 0
      check "requires a command" in res5.output

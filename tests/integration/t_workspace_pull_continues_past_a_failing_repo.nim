## `repro workspace pull` sweeps the WHOLE workspace, even when a repo fails.
##
## The defect this closes. `pull` iterated the declared repos and `break`-ed out
## of the loop on the first clone or converge failure. In a 100-repo workspace
## that converged four repos, hit one failure, and returned — leaving ~96
## checkouts at whatever stale revision they already had, with no line in the
## report even mentioning them, because a repo that is never attempted produces
## no entry.
##
## Why that is worse than a plain bug. `pull` is the command whose entire
## purpose is "get this workspace onto the declared revisions". A developer runs
## it, sees the convergence lines scroll past (and the failure buried under the
## trailing auto-trust "trusted shell hook" lines), and proceeds on the belief
## that the workspace converged. The next build fails against a stale sibling,
## and the evidence points at that sibling's source rather than at the
## convergence that never ran. The diagnosis lands on the wrong repo, twice.
##
## The contract asserted here is the partial-advance contract every other sweep
## in this surface follows — `sync` states it explicitly for the RA-23 clone
## failure ("a clone failure does not abort the run — the other repos still
## converge... it DOES fail the run"):
##
##   1. A repo that fails does not stop the sweep: every repo declared after it
##      is still attempted and still converges.
##   2. EVERY failure is collected, not just the first one.
##   3. Every declared repo appears in the report, so "not mentioned" can never
##      mean "silently skipped".
##   4. The exit code is 1. A partly-converged workspace is not a success.
##   5. The end-of-run digest NAMES the failed repos and is the LAST thing
##      printed, after the auto-trust pass — the position a `tail` of a build
##      log is guaranteed to show.
##
## The first failure is reproduced the way it was actually hit in the field: a
## broken `.git/hooks/post-checkout` in the checkout, which makes the
## convergence `git checkout -B` exit non-zero. The second is a
## manifest-declared branch the remote does not carry.
##
## No mocks: real `git init --bare` origins over `file://`, real clones, and the
## engine-built `build/bin/repro`. Skipped only when `git` is missing from PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support

proc q(value: string): string = quoteShell(value)

proc git(gitBin, args: string): tuple[code: int; output: string] =
  let res = execCmdEx(q(gitBin) & " " & args)
  (code: res.exitCode, output: res.output)

proc requireGit(gitBin, args: string): string =
  let res = git(gitBin, args)
  if res.code != 0:
    checkpoint("git " & args & " failed: exit=" & $res.code & "\n" & res.output)
    fail()
  res.output

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedBare(gitBin, bareDir, branch, marker: string) =
  let work = bareDir & "-seed"
  createDir(work)
  discard requireGit(gitBin, "init --quiet --initial-branch " & q(branch) &
    " " & q(work))
  writeFile(work / "README.md", marker & "\n")
  discard requireGit(gitBin, "-C " & q(work) & " add .")
  discard requireGit(gitBin, "-C " & q(work) &
    " -c user.email=t@example.invalid -c user.name=t commit --quiet -m " &
    q("seed " & marker))
  discard requireGit(gitBin, "clone --quiet --bare " & q(work) & " " &
    q(bareDir))
  removeDir(work)

proc advanceBare(gitBin, bareDir, branch, marker: string) =
  ## Move the remote's branch forward so convergence is a real operation
  ## rather than a no-op that would pass regardless.
  let work = bareDir & "-advance"
  discard requireGit(gitBin, "clone --quiet --branch " & q(branch) & " " &
    q(bareDir) & " " & q(work))
  writeFile(work / (marker & ".txt"), marker & "\n")
  discard requireGit(gitBin, "-C " & q(work) & " add .")
  discard requireGit(gitBin, "-C " & q(work) &
    " -c user.email=t@example.invalid -c user.name=t commit --quiet -m " &
    q("advance " & marker))
  discard requireGit(gitBin, "-C " & q(work) & " push --quiet origin " &
    q(branch))
  removeDir(work)

proc headBranch(gitBin, checkout: string): string =
  let res = git(gitBin, "-C " & q(checkout) & " symbolic-ref --short -q HEAD")
  if res.code != 0: "" else: res.output.strip()

proc buildWorkspace(root, prefix: string;
                    repos: openArray[tuple[name, branch: string]]) =
  ## Declaration ORDER is the sweep order, and it is load-bearing here: the
  ## failing repos are declared FIRST so the repos behind them are exactly the
  ## ones the old `break` abandoned.
  createDir(root / "projects")
  createDir(root / "repos")
  createDir(root / ".repro")
  var includes: seq[string]
  for repo in repos:
    writeFile(root / "repos" / (repo.name & ".toml"),
      "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
      "[repo]\nname = \"" & repo.name & "\"\npath = \"" & repo.name & "\"\n" &
      "remote = \"org\"\nbranch = \"" & repo.branch & "\"\n")
    includes.add("repos/" & repo.name & ".toml")
  var project = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"demo\"\n\n" &
    "[[remote]]\nname = \"org\"\nfetch = \"" & prefix & "\"\n\n" &
    "includes = [\n"
  for inc in includes:
    project.add("  \"" & inc & "\",\n")
  project.add("]\n")
  writeFile(root / "projects" / "demo.toml", project)
  writeFile(root / ".repro" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n\n" &
    "[workspace]\nproject = \"demo\"\nprojects = [\"demo\"]\n")

proc breakPostCheckoutHook(checkout: string) =
  ## The field failure verbatim: an unparseable `post-checkout`. `git checkout`
  ## propagates the hook's non-zero exit, so convergence fails for this repo
  ## and only this repo.
  let hook = checkout / ".git" / "hooks" / "post-checkout"
  createDir(parentDir(hook))
  writeFile(hook, "#!/usr/bin/env bash\nif true\nthen)\nfi\n")
  when not defined(windows):
    discard execCmdEx("chmod +x " & q(hook))

proc pull(root: string): CmdResult =
  runShell(shellCommand(@[reproBinary(), "workspace", "pull",
    "--workspace-root=" & root]))

suite "workspace pull continues past a failing repo":

  test "t_pull_converges_every_remaining_repo_after_a_failure":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-pull-continue-", "")
      defer: removeDirEventually(scratch)
      let remotes = scratch / "remotes"
      createDir(remotes)

      # `broken-hook-lib` and `missing-branch-lib` fail; the three behind them
      # are the ones the old `break` never reached.
      const declared = [
        (name: "broken-hook-lib", branch: "dev"),
        (name: "missing-branch-lib", branch: "no-such-branch"),
        (name: "behind-failure-a", branch: "dev"),
        (name: "behind-failure-b", branch: "dev"),
        (name: "behind-failure-c", branch: "dev"),
      ]
      for repo in declared:
        seedBare(gitBin, remotes / repo.name, "dev", repo.name)
      let prefix = fileUrl(remotes)

      let root = scratch / "workspace"
      buildWorkspace(root, prefix, declared)
      for repo in declared:
        discard requireGit(gitBin, "clone --quiet " &
          q(prefix & "/" & repo.name) & " " & q(root / repo.name))
      for repo in declared:
        advanceBare(gitBin, remotes / repo.name, "dev", "upstream")

      breakPostCheckoutHook(root / "broken-hook-lib")

      let res = pull(root)
      checkpoint("pull: " & res.output)

      # (4) A workspace that did not converge is not a success.
      check res.code == 1

      # (1) Every repo declared BEHIND a failure still converged. This is the
      # whole defect: before the fix these three were never attempted.
      for name in ["behind-failure-a", "behind-failure-b", "behind-failure-c"]:
        check headBranch(gitBin, root / name) == "dev"
        check fileExists(root / name / "upstream.txt")

      # (5) The digest names the failures and is the LAST line — not buried
      # above the trailing auto-trust output.
      check res.output.contains("broken-hook-lib")
      check res.output.contains("missing-branch-lib")
      let lines = res.output.strip().splitLines()
      check lines[^1].startsWith("workspace pull summary:")
      check lines[^1].contains("FAILED 2")
      var digestIdx = -1
      for i, line in lines:
        if line.contains("repo(s) FAILED to converge"):
          digestIdx = i
      check digestIdx >= 0
      check lines[digestIdx].contains("broken-hook-lib")
      check lines[digestIdx].contains("missing-branch-lib")

      # (2) + (3) The report accounts for EVERY declared repo, with both
      # failures recorded — not just the first one.
      let reportPath = root / ".repro" / "build" / "reports" /
        "pull-failure-report.json"
      check fileExists(reportPath)
      let report = parseFile(reportPath)["report"]
      var outcomes: seq[tuple[path, outcome: string]]
      for entry in report["repos"]:
        outcomes.add((entry["path"].getStr(), entry["outcome"].getStr()))
      check outcomes.len == declared.len
      check ("broken-hook-lib", "failed") in outcomes
      check ("missing-branch-lib", "failed") in outcomes
      check ("behind-failure-a", "converged") in outcomes
      check ("behind-failure-b", "converged") in outcomes
      check ("behind-failure-c", "converged") in outcomes
      check report["exitCode"].getInt() == 1

      # Rerunning after the cause is removed converges the last holdout, so the
      # partial state really is resumable rather than wedged.
      removeFile(root / "broken-hook-lib" / ".git" / "hooks" / "post-checkout")
      let again = pull(root)
      checkpoint("rerun: " & again.output)
      check again.code == 1   # `missing-branch-lib` still has no such branch
      check headBranch(gitBin, root / "broken-hook-lib") == "dev"
      check fileExists(root / "broken-hook-lib" / "upstream.txt")

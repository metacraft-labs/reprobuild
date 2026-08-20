## `repro workspace pull` converges a checkout to the manifest revision by
## repointing a branch ref — and must not do that over commits no remote has.
##
## The asymmetry this closes. `pull`'s convergence step is
## `git checkout -B <branch> --track <remote>/<branch>`, and `-B` RESETS the
## branch to the start point. A developer with commits on `dev` that they have
## not pushed loses them from the branch: nothing references them afterwards,
## and nothing in the report suggests going to look. Meanwhile `workspace
## disable` refuses to delete that same checkout over a single uncommitted
## file. Two verbs in one tool, one refusing to touch a tree to protect work
## and the other rewinding it silently, is not a defensible position — and
## "the reflog still has it" is not a defence when the developer has no reason
## to suspect anything happened.
##
## Convergence remains the documented behaviour; only the silence goes. A repo
## carrying work is SKIPPED and named, the rest of the workspace still
## converges (the partial-advance contract every other verb here follows), the
## exit code says so, and `--force` — the same spelling `disable` and `remove`
## use — restores the old semantics for anyone who genuinely wants them.
##
## The gate is deliberately NARROWER than the one guarding deletion. Deleting a
## tree destroys everything in it, so that check asks about every local branch.
## Repointing `dev` cannot harm a commit on an unrelated feature branch, and a
## gate that fired on those would be useless: nearly every real checkout has an
## unpushed branch somewhere, so it would train people to type `--force` by
## reflex, which is worse than no gate at all. Hence the branch-scoped probe,
## plus the detached-HEAD case, which the all-branches probe structurally
## cannot see — a commit made while HEAD is detached is on no branch, so
## `rev-list --branches --not --remotes` counts none of them, and moving HEAD
## away strands it exactly as reattaching would.
##
## Asserted:
##   1. A repo with unpushed commits ON THE BRANCH BEING REPOINTED is skipped:
##      the branch still points at those commits afterwards, the report names
##      the blocker and the remedy, and the exit code is 2.
##   2. A repo with uncommitted changes is skipped, and the changes survive.
##   3. A repo whose commits exist only at a detached HEAD is skipped.
##   4. Unpushed commits on an UNRELATED branch do NOT block convergence — the
##      gate is scoped, not blanket.
##   5. Every other repo in the same run still converges. A skip is not an
##      abort.
##   6. `--force` converges the skipped repo anyway and exits 0, so the old
##      behaviour remains reachable by an explicit decision.
##
## No mocks: real `git init --bare` origins over `file://`, real clones with
## real unpublished commits, and the engine-built `build/bin/repro`. Skipped
## only when `git` is missing from PATH.

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
  ## Move the remote's branch forward, so convergence has something to
  ## converge TO. Without this the local branch already equals the remote tip
  ## and `checkout -B` would be a no-op — the test would pass for the wrong
  ## reason.
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

proc commitIn(gitBin, checkout, file, body, message: string): string =
  writeFile(checkout / file, body)
  discard requireGit(gitBin, "-C " & q(checkout) & " add " & q(file))
  discard requireGit(gitBin, "-C " & q(checkout) &
    " -c user.email=t@example.invalid -c user.name=t commit --quiet -m " &
    q(message))
  requireGit(gitBin, "-C " & q(checkout) & " rev-parse HEAD").strip()

proc headSha(gitBin, checkout: string): string =
  requireGit(gitBin, "-C " & q(checkout) & " rev-parse HEAD").strip()

proc refSha(gitBin, checkout, refName: string): string =
  let res = git(gitBin, "-C " & q(checkout) & " rev-parse --verify --quiet " &
    q(refName))
  if res.code != 0: "" else: res.output.strip()

proc headBranch(gitBin, checkout: string): string =
  let res = git(gitBin, "-C " & q(checkout) & " symbolic-ref --short -q HEAD")
  if res.code != 0: "" else: res.output.strip()

proc buildWorkspace(root, prefix: string; names: openArray[string]) =
  createDir(root / "projects")
  createDir(root / "repos")
  createDir(root / ".repro")
  var includes: seq[string]
  for name in names:
    writeFile(root / "repos" / (name & ".toml"),
      "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
      "[repo]\nname = \"" & name & "\"\npath = \"" & name & "\"\n" &
      "remote = \"org\"\nbranch = \"dev\"\n")
    includes.add("repos/" & name & ".toml")
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

proc pull(root: string; extra: openArray[string] = []): CmdResult =
  var argv = @[reproBinary(), "workspace", "pull",
    "--workspace-root=" & root]
  for e in extra:
    argv.add(e)
  runShell(shellCommand(argv))

suite "workspace pull refuses to rewind unpublished work":

  test "t_pull_skips_repos_whose_branch_carries_unpublished_commits":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-pull-gate-", "")
      defer: removeDirEventually(scratch)
      let remotes = scratch / "remotes"
      createDir(remotes)
      const names = ["unpushed-lib", "dirty-lib", "detached-lib",
                     "other-branch-lib", "clean-lib"]
      for name in names:
        seedBare(gitBin, remotes / name, "dev", name)
      let prefix = fileUrl(remotes)

      let root = scratch / "workspace"
      buildWorkspace(root, prefix, names)
      for name in names:
        discard requireGit(gitBin, "clone --quiet " &
          q(prefix & "/" & name) & " " & q(root / name))
      # Every remote moves forward, so convergence is a real operation in all
      # five repos rather than a no-op that would pass regardless.
      for name in names:
        advanceBare(gitBin, remotes / name, "dev", "upstream")

      # (1) unpublished commits on `dev` — the branch pull is about to repoint.
      let unpushedSha = commitIn(gitBin, root / "unpushed-lib", "mine.txt",
        "my work\n", "unpublished work on dev")

      # (2) uncommitted changes.
      writeFile(root / "dirty-lib" / "README.md", "edited, not committed\n")

      # (3) commits held only by a detached HEAD.
      discard requireGit(gitBin, "-C " & q(root / "detached-lib") &
        " checkout --quiet --detach HEAD")
      let detachedSha = commitIn(gitBin, root / "detached-lib",
        "detached.txt", "made while detached\n", "detached work")

      # (4) unpublished commits on an UNRELATED branch. `dev` itself is clean,
      # so this repo must converge — the gate is scoped to the branch being
      # repointed, and a blanket check would strand this one.
      discard requireGit(gitBin, "-C " & q(root / "other-branch-lib") &
        " checkout --quiet -b side-quest")
      let sideSha = commitIn(gitBin, root / "other-branch-lib", "side.txt",
        "side\n", "work on an unrelated branch")
      discard requireGit(gitBin, "-C " & q(root / "other-branch-lib") &
        " checkout --quiet dev")

      let res = pull(root, ["--write-report"])
      checkpoint("pull: " & res.output)

      # Exit 2 — "some checkouts were left alone to protect work" is neither
      # success nor failure, and a caller must be able to tell without reading
      # prose.
      check res.code == 2

      # The three at-risk repos were skipped and their work is intact.
      check refSha(gitBin, root / "unpushed-lib", "refs/heads/dev") ==
        unpushedSha
      check readFile(root / "dirty-lib" / "README.md") ==
        "edited, not committed\n"
      check headBranch(gitBin, root / "detached-lib") == ""
      check headSha(gitBin, root / "detached-lib") == detachedSha

      # ...and the report says why, per repo, with the remedy attached.
      check res.output.contains("unpushed-lib")
      check res.output.contains("skipped_work_at_risk")
      check res.output.contains("would put work at risk")
      check res.output.contains("--force")
      check res.output.contains("left untouched to protect work")

      # (4) and (5): a scoped gate lets the unrelated-branch repo through, and
      # the wholly clean repo too. A skip is not an abort.
      check headBranch(gitBin, root / "other-branch-lib") == "dev"
      check fileExists(root / "other-branch-lib" / "upstream.txt")
      # ...and the unrelated branch is untouched by the convergence.
      check refSha(gitBin, root / "other-branch-lib",
        "refs/heads/side-quest") == sideSha
      check headBranch(gitBin, root / "clean-lib") == "dev"
      check fileExists(root / "clean-lib" / "upstream.txt")

      let reportPath = root / ".repro" / "build" / "reports" /
        "pull-report.json"
      check fileExists(reportPath)
      let report = parseFile(reportPath)
      var skipped: seq[string]
      var converged: seq[string]
      for entry in report["repos"]:
        if entry["outcome"].getStr() == "skipped_work_at_risk":
          skipped.add(entry["path"].getStr())
        elif entry["outcome"].getStr() == "converged":
          converged.add(entry["path"].getStr())
      check "unpushed-lib" in skipped
      check "dirty-lib" in skipped
      check "detached-lib" in skipped
      check "other-branch-lib" in converged
      check "clean-lib" in converged

      # Re-running does not wear the refusal down.
      let again = pull(root)
      check again.code == 2
      check refSha(gitBin, root / "unpushed-lib", "refs/heads/dev") ==
        unpushedSha

  test "t_pull_force_converges_a_skipped_repo":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-pull-force-", "")
      defer: removeDirEventually(scratch)
      let remotes = scratch / "remotes"
      createDir(remotes)
      seedBare(gitBin, remotes / "unpushed-lib", "dev", "unpushed-lib")
      let prefix = fileUrl(remotes)

      let root = scratch / "workspace"
      buildWorkspace(root, prefix, ["unpushed-lib"])
      discard requireGit(gitBin, "clone --quiet " &
        q(prefix & "/unpushed-lib") & " " & q(root / "unpushed-lib"))
      advanceBare(gitBin, remotes / "unpushed-lib", "dev", "upstream")
      let mine = commitIn(gitBin, root / "unpushed-lib", "mine.txt",
        "my work\n", "unpublished work on dev")

      # Without the flag: refused.
      let refused = pull(root)
      check refused.code == 2
      check refSha(gitBin, root / "unpushed-lib", "refs/heads/dev") == mine

      # With it: the pre-gate behaviour, reached by an explicit decision rather
      # than by default.
      let forced = pull(root, ["--force"])
      checkpoint("forced: " & forced.output)
      check forced.code == 0
      check headBranch(gitBin, root / "unpushed-lib") == "dev"
      check refSha(gitBin, root / "unpushed-lib", "refs/heads/dev") != mine
      check fileExists(root / "unpushed-lib" / "upstream.txt")

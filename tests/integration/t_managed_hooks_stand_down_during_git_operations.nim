## The managed `post-checkout` / `post-commit` hooks stand down while git is
## mid-operation, and never move a ref.
##
## THE DEFECT
##
## Git fires `post-checkout` for every ref update INSIDE a rebase, a bisect
## and a sequencer run. The managed hook's local-state reconciliation reacted
## to the resulting detached HEAD exactly the way `repro workspace migrate`
## does — by running `git checkout <declared branch>`. Inside a rebase that
## reattaches HEAD to the mainline branch mid-flight, and the rebase then
## replays the topic commits onto the MAINLINE and reports "Successfully
## rebased and updated refs/heads/topic" with exit 0. Observed live: `main`
## moved by two commits, silently.
##
## WHY THESE TESTS ENTER THROUGH A REAL `git rebase`
##
## The bug is about WHEN the hook runs, not what the hook computes. A unit
## test on the discriminator would have been green throughout, and a test
## that dispatched `repro hooks dispatch post-checkout` directly would have
## had to guess the argv and the in-flight state git actually produces. These
## cases install the real managed hooks with `repro hooks ensure --vcs`, put
## `repro` on PATH under its own name (the condition under which the defect
## was observed — clearing REPROBUILD_REPRO does NOT disable the hook, it
## falls back to PATH), and then run a real `git rebase` / `git cherry-pick`.
##
## AVOIDING A VACUOUS GREEN
##
## "The mainline did not move" is also what a fixture in which the hook never
## fired at all would report. Every case therefore carries a positive control
## that the hook DID run: the exact stand-down line, naming the marker that
## proved it, must be present in the hook's own cache log. And the rebase must
## demonstrably have done work — the topic SHA must CHANGE — so a rebase that
## silently did nothing cannot pass either.
##
## No mocks: real `git init --bare` origins over `file://`, real clones, the
## engine-built `build/bin/repro`, and git's own hook invocations.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support

proc q(value: string): string = quoteShell(value)

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

type
  Fixture = object
    scratch, workspace, app, origin, cacheHome, binDir, gitBin: string

proc sh(fx: Fixture; command: string): tuple[code: int; output: string] =
  ## Run a command with `repro` FULLY on PATH under its own name and the
  ## hook's cache log redirected into the fixture. This is the shape of the
  ## environment in which the defect was observed.
  let prefixed = "PATH=" & q(fx.binDir) & ":$PATH " &
    "XDG_CACHE_HOME=" & q(fx.cacheHome) & " " &
    "REPROBUILD_REPRO= " & command
  let res = execCmdEx(prefixed, options = {poStdErrToStdOut, poUsePath})
  (code: res.exitCode, output: res.output)

proc git(fx: Fixture; args: string; cwd = ""): tuple[code: int; output: string] =
  let dir = if cwd.len > 0: cwd else: fx.app
  fx.sh(q(fx.gitBin) & " -C " & q(dir) & " " & args)

proc requireGit(fx: Fixture; args: string; cwd = ""): string =
  let res = fx.git(args, cwd)
  if res.code != 0:
    checkpoint("git " & args & " failed: exit=" & $res.code & "\n" & res.output)
    fail()
  res.output

proc revParse(fx: Fixture; spec: string; cwd = ""): string =
  fx.requireGit("rev-parse " & q(spec), cwd).strip()

proc headBranch(fx: Fixture; cwd = ""): string =
  let res = fx.git("symbolic-ref --short -q HEAD", cwd)
  if res.code != 0: "" else: res.output.strip()

proc hookLog(fx: Fixture): string =
  let path = fx.cacheHome / "repro" / "manifest-refresh.log"
  if fileExists(path): readFile(path) else: ""

proc postCommitLog(fx: Fixture): string =
  let path = fx.workspace / ".repro" / "workspace" / "post-commit-lock.log"
  if fileExists(path): readFile(path) else: ""

proc setup(gitBin: string): Fixture =
  ## A workspace with native root membership and one participating repo whose
  ## fragment declares `main` — the branch the reconciler would reattach to.
  result.gitBin = gitBin
  result.scratch = createTempDir("repro-hook-stand-down-", "")
  result.workspace = result.scratch / "workspace"
  result.app = result.workspace / "app"
  result.origin = result.scratch / "origin.git"
  result.cacheHome = result.scratch / "cache"
  result.binDir = result.scratch / "bin"
  createDir(result.workspace)
  createDir(result.cacheHome)
  createDir(result.binDir)
  createDir(result.workspace / ".repro" / "workspace")

  # `repro` resolvable from PATH under its own name. Not exporting
  # REPROBUILD_REPRO does not disable the managed hook — it falls back to
  # PATH — so the reproduction has to reproduce that too.
  let repro = reproBinary()
  when defined(windows):
    copyFileWithPermissions(repro, result.binDir / "repro.exe")
  else:
    createSymlink(repro, result.binDir / "repro")

  let fx = result
  discard fx.sh(q(gitBin) & " init --quiet --bare -b main " & q(fx.origin))

  let seed = fx.scratch / "seed"
  discard fx.sh(q(gitBin) & " init --quiet -b main " & q(seed))
  discard fx.requireGit("config user.email t@example.invalid", seed)
  discard fx.requireGit("config user.name Tester", seed)
  writeFile(seed / "README.md", "seed\n")
  discard fx.requireGit("add -A", seed)
  discard fx.requireGit("commit --quiet -m seed", seed)
  discard fx.requireGit("remote add origin " & q(fileUrl(fx.origin)), seed)
  discard fx.requireGit("push --quiet --no-verify origin main", seed)

  discard fx.sh(q(gitBin) & " clone --quiet " & q(fileUrl(fx.origin)) & " " &
    q(fx.app))
  discard fx.requireGit("config user.email t@example.invalid")
  discard fx.requireGit("config user.name Tester")

  createDir(fx.workspace / "projects")
  createDir(fx.workspace / "repos")
  writeFile(fx.workspace / ".repro" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n\n" &
    "[workspace]\nproject = \"app\"\nprojects = [\"app\"]\n")
  writeFile(fx.workspace / "projects" / "app.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"app\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"origin\"\nfetch = \"" & fileUrl(fx.origin) &
    "\"\n\nincludes = [\"repos/app.toml\"]\n")
  writeFile(fx.workspace / "repos" / "app.toml",
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\nname = \"app\"\npath = \"app\"\n" &
    "remote = \"origin\"\nrevision = \"main\"\n")

proc installHooks(fx: Fixture) =
  ## Installed AFTER the fixture's own seed commits, so the only hook firings
  ## in a case are the ones its git operation causes. A fixture whose setup
  ## also fires the hooks makes "did the hook run HERE?" unanswerable from the
  ## log, and that question is this file's entire positive control.
  let ensured = fx.sh(q(reproBinary()) & " hooks ensure --vcs " &
    q(fx.workspace))
  if ensured.code != 0:
    checkpoint("hooks ensure failed:\n" & ensured.output)
    fail()

proc seedPublishedTopic(fx: Fixture) =
  ## `topic` (two commits) and `main` (one further commit), BOTH pushed.
  ##
  ## Publication is load-bearing, not incidental: the reconciler's work-loss
  ## guard refuses to attach a HEAD carrying unpushed commits, so an
  ## all-unpushed fixture would be saved by that guard and would prove
  ## nothing about the reattachment. A clean, fully-published workspace —
  ## the ordinary state of somebody about to rebase a pushed topic branch —
  ## is the one in which the guard passes and the checkout fires.
  discard fx.requireGit("checkout --quiet -b topic")
  writeFile(fx.app / "one.txt", "one\n")
  discard fx.requireGit("add -A")
  discard fx.requireGit("commit --quiet -m " & q("topic one"))
  writeFile(fx.app / "two.txt", "two\n")
  discard fx.requireGit("add -A")
  discard fx.requireGit("commit --quiet -m " & q("topic two"))
  discard fx.requireGit("push --quiet --no-verify -u origin topic")
  discard fx.requireGit("checkout --quiet main")
  writeFile(fx.app / "base.txt", "base\n")
  discard fx.requireGit("add -A")
  discard fx.requireGit("commit --quiet -m " & q("main advances"))
  discard fx.requireGit("push --quiet --no-verify origin main")
  discard fx.requireGit("checkout --quiet topic")

suite "managed hooks stand down while git is mid-operation":

  test "t_rebase_leaves_the_mainline_branch_exactly_where_it_was":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setup(gitBin)
      defer: removeDirEventually(fx.scratch)
      fx.seedPublishedTopic()
      fx.installHooks()

      let mainBefore = fx.revParse("refs/heads/main")
      let topicBefore = fx.revParse("refs/heads/topic")
      check mainBefore != topicBefore

      let rebase = fx.git("rebase main")
      checkpoint("rebase output:\n" & rebase.output)
      check rebase.code == 0
      check rebase.output.contains("Successfully rebased")

      # POSITIVE CONTROL. Without this, "the mainline did not move" is also
      # what a fixture whose hook never fired would report. The hook must
      # have run, recognised the rebase, and named the marker that proved it.
      let log = fx.hookLog()
      checkpoint("hook log:\n" & log)
      check log.contains("post-checkout skipped: a git operation is in " &
        "progress (rebase-merge)")

      # THE DEFECT. `main` is a mainline branch nobody asked to move.
      check fx.revParse("refs/heads/main") == mainBefore

      # ...and the rebase really did rebase, so the case cannot pass by
      # virtue of nothing having happened.
      check fx.revParse("refs/heads/topic") != topicBefore
      check fx.headBranch() == "topic"
      check fx.revParse("HEAD") == fx.revParse("refs/heads/topic")

      # The topic commits landed on topic and NOWHERE else.
      let onMain = fx.requireGit("log --oneline " & q("refs/heads/main"))
      check not onMain.contains("topic one")
      check not onMain.contains("topic two")
      let onTopic = fx.requireGit("log --oneline " & q("refs/heads/topic"))
      check onTopic.contains("topic one")
      check onTopic.contains("topic two")

      # The ref-moving sentence must appear nowhere at all.
      check not rebase.output.contains("detached HEAD attached")
      check not log.contains("detached HEAD attached")

  test "t_rebase_in_a_linked_worktree_is_detected_too":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setup(gitBin)
      defer: removeDirEventually(fx.scratch)
      fx.seedPublishedTopic()
      fx.installHooks()
      discard fx.requireGit("checkout --quiet main")

      # A linked worktree keeps its rebase state under
      # `<common-dir>/worktrees/<name>/`, and its own `.git` is a FILE. A
      # naive `<repo>/.git/rebase-merge` test is therefore unconditionally
      # false here — it would miss every worktree rebase — which is why the
      # probe resolves the path with `git rev-parse --git-path`.
      let wt = fx.scratch / "wt"
      discard fx.requireGit("worktree add --quiet " & q(wt) & " topic")
      check fileExists(wt / ".git")      # a file, not a directory
      check not dirExists(wt / ".git")
      check not fileExists(fx.app / ".git" / "rebase-merge")

      let mainBefore = fx.revParse("refs/heads/main")
      let topicBefore = fx.revParse("refs/heads/topic")

      let rebase = fx.git("rebase main", wt)
      checkpoint("worktree rebase output:\n" & rebase.output)
      check rebase.code == 0

      let log = fx.hookLog()
      checkpoint("hook log:\n" & log)
      check log.contains("post-checkout skipped: a git operation is in " &
        "progress (rebase-merge)")
      check log.contains(wt)             # resolved against the WORKTREE

      check fx.revParse("refs/heads/main") == mainBefore
      check fx.revParse("refs/heads/topic") != topicBefore
      check fx.headBranch(wt) == "topic"

  test "t_the_am_backend_rebase_is_detected_before_its_state_dir_exists":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setup(gitBin)
      defer: removeDirEventually(fx.scratch)
      fx.seedPublishedTopic()
      fx.installHooks()

      # `git rebase --apply` rewinds HEAD onto the upstream and fires
      # `post-checkout` — detached, flag 1 — BEFORE creating `rebase-apply`.
      # A state-path-only probe answers "idle" at that instant, for a rebase
      # that has already started. What git does have is the reflog entry it
      # just wrote: `rebase (start): checkout main`.
      let mainBefore = fx.revParse("refs/heads/main")
      let topicBefore = fx.revParse("refs/heads/topic")

      let rebase = fx.git("rebase --apply main")
      checkpoint("rebase --apply output:\n" & rebase.output)
      check rebase.code == 0

      let log = fx.hookLog()
      checkpoint("hook log:\n" & log)
      check log.contains("post-checkout skipped: a git operation is in " &
        "progress (HEAD reflog: rebase")
      # ...and it was the reflog that caught it, not a state directory: this
      # is what makes the second discriminator non-redundant.
      check not log.contains("progress (rebase-apply)")

      check fx.revParse("refs/heads/main") == mainBefore
      check fx.revParse("refs/heads/topic") != topicBefore
      check fx.headBranch() == "topic"

  test "t_bisect_keeps_its_detached_head":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setup(gitBin)
      defer: removeDirEventually(fx.scratch)
      fx.seedPublishedTopic()
      fx.installHooks()

      # `git bisect` checks out a detached commit per step. Reattaching a
      # branch mid-bisect destroys the bisect the same way it destroys a
      # rebase, and `BISECT_LOG` is the marker that names it.
      let mainBefore = fx.revParse("refs/heads/main")
      discard fx.requireGit("bisect start")
      discard fx.requireGit("bisect bad topic")
      let step = fx.git("bisect good main")
      checkpoint("bisect step:\n" & step.output)
      check step.code == 0

      let log = fx.hookLog()
      checkpoint("hook log:\n" & log)
      check log.contains("post-checkout skipped: a git operation is in " &
        "progress (BISECT_LOG)")

      # The bisect is still a bisect: HEAD detached, on a commit inside the
      # range, and the mainline untouched.
      check fx.headBranch() == ""
      check fx.revParse("refs/heads/main") == mainBefore
      check fx.requireGit("bisect log").contains("bad")
      discard fx.requireGit("bisect reset")

  test "t_a_checkout_outside_any_operation_still_runs_the_hook":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setup(gitBin)
      defer: removeDirEventually(fx.scratch)
      fx.seedPublishedTopic()
      fx.installHooks()

      # The anti-over-fire control. A discriminator that answered "in
      # progress" for everything would pass every other case in this file, so
      # one case has to prove the ordinary path is untouched: an ordinary
      # `git checkout` fires the hook and the hook does its ordinary work.
      let before = fx.hookLog()
      let checkout = fx.git("checkout --quiet main")
      check checkout.code == 0
      let after = fx.hookLog()
      check after.len > before.len
      let fresh = after[before.len .. ^1]
      checkpoint("fresh log lines:\n" & fresh)
      check fresh.contains("post-checkout")
      check not fresh.contains("skipped: a git operation is in progress")
      check not fresh.contains("inert")

  test "t_post_commit_stands_down_during_a_cherry_pick":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setup(gitBin)
      defer: removeDirEventually(fx.scratch)
      fx.seedPublishedTopic()
      fx.installHooks()
      discard fx.requireGit("checkout --quiet main")

      # `post-commit` shares the exposure: git fires it once per commit a
      # sequencer run replays, and the arm behind it writes `repro.lock`
      # into the working tree and spawns a ref push.
      let mainBefore = fx.revParse("refs/heads/main")
      let pick = fx.git("cherry-pick " & q("topic~1") & " " & q("topic"))
      checkpoint("cherry-pick output:\n" & pick.output)
      check pick.code == 0
      check fx.revParse("refs/heads/main") != mainBefore   # it really picked

      let log = fx.postCommitLog()
      checkpoint("post-commit log:\n" & log)
      check log.contains("skipped-git-operation-in-progress")
      check log.contains("post-commit skipped: a git operation is in progress")
      # `sequencer` is present for every picked commit; `CHERRY_PICK_HEAD`
      # only for a conflicted one. Either name is a correct proof, and
      # asserting the disjunction keeps the case honest about which fired.
      check log.contains("(sequencer)") or log.contains("(CHERRY_PICK_HEAD)")

  test "t_hook_is_inert_and_says_so_when_the_git_state_cannot_be_read":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setup(gitBin)
      defer: removeDirEventually(fx.scratch)

      # "I could not tell" must not read as "nothing is happening". Point the
      # dispatcher at a directory that is not a git checkout at all: the
      # probe cannot answer, and the contract is that the hook is inert AND
      # says so — on stderr, not only in a log nobody reads until afterwards.
      let notARepo = fx.scratch / "not-a-repo"
      createDir(notARepo)
      let res = fx.sh(q(reproBinary()) & " hooks dispatch post-checkout " &
        "--repo-root " & q(notARepo) & " -- aaa bbb 1")
      checkpoint("dispatch output:\n" & res.output)
      check res.code == 0                       # never blocks git
      check res.output.contains("post-checkout inert")
      check res.output.contains("cannot determine whether a git operation")
      check res.output.contains("nothing was inspected or modified")
      let log = fx.hookLog()
      checkpoint("hook log:\n" & log)
      check log.contains("post-checkout inert")

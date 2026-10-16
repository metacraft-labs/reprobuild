## The managed `pre-commit` dispatcher cannot lose unstaged work, whatever its
## chained `pre-commit.repro-local` hook does — issue
## `reprobuild-pm/issues/2026-09-27-managed-pre-commit-hook-destroys-unstaged-work-when-interrupted.md`.
##
## THE SCENARIO. On a partial commit the pre-commit framework (chained as
## `pre-commit.repro-local` by `repro hooks ensure --vcs`) writes the unstaged
## half of the working tree to a patch file under `~/.cache/pre-commit`, runs
## `git checkout -- .` to remove it, runs its hooks, and only then applies the
## patch back. A hook killed in between — the issue's `just lint` was killed
## after many minutes on a loaded host — never reaches the restore step: the
## unstaged edits silently revert to the index and `git stash list` is empty,
## so the ordinary recovery reflex finds nothing.
##
## WHAT IS ASSERTED, through the hooks `repro hooks ensure --vcs` installs and
## real `git commit` invocations:
##
##   (a) SIGTERM to the commit's whole process group while the chained hook is
##       running: once every process of the group is gone, each unstaged file
##       is back in the working tree BYTE-IDENTICAL (an LF file, a CRLF file, a
##       binary file, and a file that also has a staged change), the staged
##       content is still staged, HEAD did not move, and no stash entry of the
##       dispatcher's is left behind.
##   (b) SIGKILL of the whole group — nothing gets to run a trap: the work is
##       recoverable from `git stash list`. Exactly one entry carries the
##       dispatcher's message, and `git stash apply` of it restores every file
##       byte-identically while the index keeps the staged content.
##   (c) A normal partial commit that passes, and one whose chained hook
##       fails, leave the working tree intact and no stash entry of the
##       dispatcher's — and never touch a stash entry the user made.
##   (d) The next commit after (b) prints a notice naming the leftover entry.
##
## Positive control: (b) first asserts that the working tree DID lose the
## work (the framework double removed it and the kill prevented its restore),
## so the recovery assertions are about a real loss rather than about a
## double that never stashed anything.
##
## Falsified against the unmodified dispatcher (reprobuild `744d6240`): (a)
## fails on the working-tree byte-identity checks (the unstaged files are left
## at their index content) and (b) on the stash-list check (`git stash list`
## is empty) — the two observations the issue records. Every case runs under
## `diff.noprefix=true`; a dispatcher that settles with porcelain `git diff`
## fails (a) and (c) there, because the prefix-less patch never applies.
##
## TEST DOUBLE, justified. The chained `pre-commit.repro-local` is a short sh
## script that performs the pre-commit framework's stash-and-restore cycle
## with the framework's own git commands (`staged_files_only.py` in
## pre-commit 4.x: `git diff-index --ignore-submodules --binary --exit-code
## --no-color --no-ext-diff <tree of the index> --` into a patch file,
## `git checkout -- .`, run the hooks,
## `git -c core.autocrlf=false apply --whitespace=nowarn <patch>`), then
## blocks, passes or fails as the case needs. It stands in for the Python
## `pre-commit` package so the case runs on every POSIX host without a Python
## environment or a network fetch of hook repositories; the dispatcher cannot
## tell the two apart, because what it must survive is exactly that sequence
## of git operations followed by an interruption. The issue's literal
## reproduction with the real framework is recorded beside the fix. Everything
## else — `repro`, `git`, the hook installer, the dispatcher, the signals — is
## real.
##
## POSIX only: the case is about process-group signals delivered to a hook
## mid-run, which Windows does not have; it skips there with that reason.

import repro_test_support/reasoned_skip
import std/[os, osproc, sequtils, streams, strtabs, strutils, tempfiles, times,
  unittest]
when defined(posix):
  import std/posix

import repro_test_support

## The stash message prefix the dispatcher records. Spelled here rather than
## imported: the test asserts the user-visible contract, and an operator
## searching `git stash list` reads this text, not a Nim constant.
const ProtectedStashPrefix =
  "reprobuild pre-commit: unstaged work protected while hooks ran"

## The notice a later commit prints for an entry an earlier, killed run left.
const LeftoverNoticeFragment = "interrupted pre-commit"

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(reproBinaryPath(repoRoot()), "reprobuild.apps.repro")

type Fixture = object
  scratch: string
  repo: string
  repro: string
  patchDir: string
  mark: string

proc commandEnv(fx: Fixture; mode: string): StringTableRef =
  ## The environment every git invocation in this file runs under: the
  ## caller's, plus the variables the framework double reads, plus
  ## `REPROBUILD_REPRO` so the managed body resolves the `repro` under test
  ## rather than whatever release `PATH` carries.
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    result[k] = v
  # A run from inside another git hook (a pre-push that runs the suite)
  # inherits that repository's location; it must not leak into this one.
  for leaked in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX",
      "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
      "GIT_ALTERNATE_OBJECT_DIRECTORIES"]:
    if result.hasKey(leaked): result.del(leaked)
  result["REPROBUILD_REPRO"] = fx.repro
  result["FRAMEWORK_MODE"] = mode
  result["FRAMEWORK_PATCH_DIR"] = fx.patchDir
  result["FRAMEWORK_STASHED_MARK"] = fx.mark
  # A developer's global config must not decide line endings or the stash
  # behaviour under test.
  result["GIT_CONFIG_NOSYSTEM"] = "1"
  # Every commit object in this file gets the same timestamp. `commit-tree`
  # is deterministic to the second, so this makes the next commit in (d)
  # rebuild exactly the snapshot the killed run in (b) left behind — on
  # every run, not only when the two land in the same wall-clock second.
  # A dispatcher that cannot tell that entry from its own drops it there.
  result["GIT_AUTHOR_DATE"] = "2026-10-16T00:00:00Z"
  result["GIT_COMMITTER_DATE"] = "2026-10-16T00:00:00Z"

proc runIn(fx: Fixture; mode: string; exe: string; args: openArray[string]):
    tuple[code: int; output: string] =
  let p = startProcess(exe, workingDir = fx.repo, args = args,
    env = fx.commandEnv(mode), options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  let output = p.outputStream.readAll()
  (code: p.waitForExit(), output: output)

proc git(fx: Fixture; args: varargs[string]): tuple[code: int; output: string] =
  fx.runIn("pass", "git", @args)

proc mustGit(fx: Fixture; args: varargs[string]): string =
  let res = fx.runIn("pass", "git", @args)
  if res.code != 0:
    checkpoint("git " & @args.join(" ") & " failed (" & $res.code & "):\n" &
      res.output)
    doAssert false, "git " & @args.join(" ") & " failed"
  res.output

proc frameworkDoubleContent(): string =
  ## The pre-commit framework's stash-run-restore cycle (see the header).
  ## `FRAMEWORK_STASHED_MARK` is created only after the unstaged half has been
  ## removed, so a test that waits for it signals the hook at the moment the
  ## issue's hook was killed.
  "#!/bin/sh\n" &
  "# pre-commit framework stash-and-restore double " &
    "(t_pre_commit_hook_keeps_unstaged_work_when_interrupted)\n" &
  "set -eu\n" &
  "patch=\"$FRAMEWORK_PATCH_DIR/patch-$$\"\n" &
  "stashed=0\n" &
  "tree=$(git write-tree)\n" &
  "if ! git diff-index --ignore-submodules --binary --exit-code --no-color " &
    "--no-ext-diff \"$tree\" -- > \"$patch\"; then\n" &
  "  echo \"[INFO] Stashing unstaged files to $patch.\"\n" &
  "  git -c submodule.recurse=0 checkout -- .\n" &
  "  stashed=1\n" &
  "else\n" &
  "  rm -f \"$patch\"\n" &
  "fi\n" &
  ": > \"$FRAMEWORK_STASHED_MARK\"\n" &
  "status=0\n" &
  "case \"$FRAMEWORK_MODE\" in\n" &
  "  block) while :; do sleep 1; done ;;\n" &
  "  fail) echo 'framework double: hook failed'; status=1 ;;\n" &
  "esac\n" &
  "if [ \"$stashed\" = 1 ]; then\n" &
  "  git -c core.autocrlf=false apply --whitespace=nowarn \"$patch\"\n" &
  "  rm -f \"$patch\"\n" &
  "fi\n" &
  "exit \"$status\"\n"

proc binaryBytes(seed: int): string =
  ## Bytes git classifies as binary (NULs included), varied by `seed`.
  result = newString(512)
  for i in 0 ..< result.len:
    result[i] = char((i * 7 + seed) mod 256)

const
  StagedA = "a2\n"
  StagedS = "s1\ns2\n"
  WorkS = "s1\ns2\ns3\n"
  WorkB = "b2\n"
  WorkCrlf = "one\r\nTWO\r\nthree\r\n"

proc workBin(): string = binaryBytes(3)

proc setupFixture(slug: string): Fixture =
  result.scratch = createTempDir("repro-pc-unstaged-" & slug & "-", "")
  result.repo = result.scratch / "repo"
  result.patchDir = result.scratch / "framework-cache"
  result.mark = result.scratch / "framework-stashed"
  result.repro = reproBinary()
  createDir(result.patchDir)
  createDir(result.repo)
  let fx = result
  discard fx.mustGit("init", "-q", "-b", "main")
  discard fx.mustGit("config", "user.email", "tester@example.invalid")
  discard fx.mustGit("config", "user.name", "Unstaged Work Tester")
  discard fx.mustGit("config", "core.autocrlf", "false")
  # A common developer setting that changes the shape of every porcelain
  # `git diff` (no `a/` `b/` prefixes). The dispatcher must restore and
  # settle the work regardless, so every case runs under it.
  discard fx.mustGit("config", "diff.noprefix", "true")
  writeFile(fx.repo / "a.txt", "a1\n")
  writeFile(fx.repo / "b.txt", "b1\n")
  writeFile(fx.repo / "s.txt", "s1\n")
  writeFile(fx.repo / "crlf.txt", "one\r\ntwo\r\n")
  writeFile(fx.repo / "bin.dat", binaryBytes(0))
  discard fx.mustGit("add", "-A")
  discard fx.mustGit("commit", "-q", "--no-verify", "-m", "initial")

  # The user's own pre-commit hook — the framework double — sits at the
  # standard path, exactly where `pre-commit install` puts its shim; `ensure`
  # preserves it as `pre-commit.repro-local` and chains it first.
  let hook = fx.repo / ".git" / "hooks" / "pre-commit"
  createDir(hook.parentDir)
  writeFile(hook, frameworkDoubleContent())
  setFilePermissions(hook, getFilePermissions(hook) +
    {fpUserExec, fpGroupExec, fpOthersExec})
  let ensured = fx.runIn("pass", fx.repro,
    ["hooks", "ensure", "--vcs", fx.repo])
  if ensured.code != 0:
    checkpoint("repro hooks ensure --vcs:\n" & ensured.output)
  doAssert ensured.code == 0, "repro hooks ensure --vcs failed"
  doAssert readFile(fx.repo / ".git" / "hooks" / "pre-commit.repro-local").
    contains("stash-and-restore double"), "framework double not chained"
  doAssert readFile(fx.repo / ".git" / "hooks" / "pre-commit").
    contains("reprobuild hook dispatcher"), "dispatcher not installed"

proc makePartialChange(fx: Fixture) =
  ## A staged half and an unstaged half, the shape that makes the framework
  ## stash: `a.txt` staged only, `s.txt` staged AND further edited, and
  ## `b.txt` (LF), `crlf.txt` (CRLF) and `bin.dat` (binary) unstaged only.
  writeFile(fx.repo / "a.txt", StagedA)
  writeFile(fx.repo / "s.txt", StagedS)
  discard fx.mustGit("add", "a.txt", "s.txt")
  writeFile(fx.repo / "s.txt", WorkS)
  writeFile(fx.repo / "b.txt", WorkB)
  writeFile(fx.repo / "crlf.txt", WorkCrlf)
  writeFile(fx.repo / "bin.dat", workBin())

proc checkWorkingTreeHasTheUnstagedWork(fx: Fixture) =
  check readFile(fx.repo / "b.txt") == WorkB
  check readFile(fx.repo / "s.txt") == WorkS
  check readFile(fx.repo / "crlf.txt") == WorkCrlf
  # Compared as a boolean so a failure does not print 512 raw bytes.
  let binaryIntact = readFile(fx.repo / "bin.dat") == workBin()
  check binaryIntact

proc checkStagedContentIsStillStaged(fx: Fixture) =
  check fx.mustGit("diff", "--cached", "--name-only").splitLines().
    filterIt(it.len > 0) == @["a.txt", "s.txt"]
  check fx.mustGit("show", ":a.txt") == StagedA
  check fx.mustGit("show", ":s.txt") == StagedS

proc ourStashEntries(fx: Fixture): seq[string] =
  for line in fx.mustGit("stash", "list").splitLines():
    if line.contains(ProtectedStashPrefix):
      result.add(line)

proc stashEntries(fx: Fixture): seq[string] =
  for line in fx.mustGit("stash", "list").splitLines():
    if line.len > 0:
      result.add(line)

when defined(posix):
  proc spawnCommitInOwnGroup(fx: Fixture; mode, logPath: string): Pid =
    ## `git commit` as the leader of a new process group, so a signal to the
    ## group reaches git, the dispatcher and everything the chained hook
    ## started — what a terminal's Ctrl-C, a CI runner's cancellation or an
    ## agent harness's timeout delivers. Built on fork/setpgid because
    ## `osproc` has no process-group option. Everything the child needs is
    ## allocated before the fork.
    let env = fx.commandEnv(mode)
    var envSeq: seq[string]
    for k, v in env.pairs:
      envSeq.add(k & "=" & v)
    let argv = allocCStringArray(["git", "commit", "-m", "partial"])
    let envp = allocCStringArray(envSeq)
    let gitPath = findExe("git")
    let cwd = fx.repo
    let pid = fork()
    if pid == 0:
      discard setpgid(0, 0)
      if chdir(cwd.cstring) != 0: exitnow(126)
      let fd = posix.open(logPath.cstring, O_WRONLY or O_CREAT or O_TRUNC,
        0o600)
      if fd >= 0:
        discard dup2(fd, 1)
        discard dup2(fd, 2)
      discard execve(gitPath.cstring, argv, envp)
      exitnow(127)
    deallocCStringArray(argv)
    deallocCStringArray(envp)
    doAssert pid > 0, "fork failed"
    # Close the race with the child's own setpgid: whichever runs first wins
    # and both name the same group.
    discard setpgid(pid, pid)
    pid

  proc waitForFile(path: string; timeout: Duration): bool =
    let deadline = getTime() + timeout
    while getTime() < deadline:
      if fileExists(path): return true
      sleep(50)
    false

  proc interruptMidHook(fx: Fixture; sig: cint): tuple[code: int; log: string] =
    ## Start a partial commit whose chained hook blocks after removing the
    ## unstaged half, signal the whole group, then wait until EVERY process
    ## of the group is gone: git dies first, and the dispatcher's own
    ## cleanup (if any) runs after it — asserting before it finished would
    ## race the code under test.
    if fileExists(fx.mark): removeFile(fx.mark)
    let logPath = fx.scratch / "commit.log"
    let pid = fx.spawnCommitInOwnGroup("block", logPath)
    let reached = waitForFile(fx.mark, initDuration(seconds = 120))
    if not reached:
      discard kill(-pid, SIGKILL)
    doAssert reached, "the chained hook never reached its stash point:\n" &
      (if fileExists(logPath): readFile(logPath) else: "")
    doAssert kill(-pid, sig) == 0, "could not signal the commit's group"
    var status: cint
    discard waitpid(pid, status, 0)
    let deadline = getTime() + initDuration(seconds = 60)
    while kill(-pid, 0) == 0 and getTime() < deadline:
      sleep(50)
    doAssert kill(-pid, 0) != 0, "the commit's process group outlived 60s"
    let code =
      if WIFEXITED(status): int(WEXITSTATUS(status))
      elif WIFSIGNALED(status): 128 + int(WTERMSIG(status))
      else: -1
    (code: code, log: readFile(logPath))

suite "pre-commit dispatcher keeps unstaged work when its hook is interrupted":

  test "sigterm_mid_hook_puts_the_unstaged_work_back":
    when not defined(posix):
      skip("process-group signals to a running git hook are POSIX-only")
    else:
      if findExe("git").len == 0:
        skip("git not on PATH; this test commits through real git hooks")
      else:
        let fx = setupFixture("term")
        defer: removeDir(fx.scratch)
        let head = fx.mustGit("rev-parse", "HEAD")
        fx.makePartialChange()
        let res = fx.interruptMidHook(SIGTERM)
        checkpoint("commit (SIGTERM) exit " & $res.code & ":\n" & res.log)
        check res.code != 0
        check fx.mustGit("rev-parse", "HEAD") == head
        fx.checkWorkingTreeHasTheUnstagedWork()
        fx.checkStagedContentIsStillStaged()
        check fx.ourStashEntries().len == 0
        check fx.stashEntries().len == 0

  test "sigkill_mid_hook_leaves_the_work_in_git_stash_list":
    when not defined(posix):
      skip("process-group signals to a running git hook are POSIX-only")
    else:
      if findExe("git").len == 0:
        skip("git not on PATH; this test commits through real git hooks")
      else:
        let fx = setupFixture("kill")
        defer: removeDir(fx.scratch)
        let head = fx.mustGit("rev-parse", "HEAD")
        fx.makePartialChange()
        let res = fx.interruptMidHook(SIGKILL)
        checkpoint("commit (SIGKILL) exit " & $res.code & ":\n" & res.log)
        check res.code == 128 + int(SIGKILL)
        check fx.mustGit("rev-parse", "HEAD") == head
        # A SIGKILLed `git commit` cannot remove its own lock; an operator
        # removes it, exactly as git's own message tells them to.
        if fileExists(fx.repo / ".git" / "index.lock"):
          removeFile(fx.repo / ".git" / "index.lock")

        # Positive control: the work really was removed from the tree.
        check readFile(fx.repo / "b.txt") == "b1\n"
        check readFile(fx.repo / "crlf.txt") == "one\r\ntwo\r\n"

        # ---- (b) recoverable through the ordinary reflex ---------------
        let ours = fx.ourStashEntries()
        checkpoint("git stash list:\n" & fx.mustGit("stash", "list"))
        check ours.len == 1
        if ours.len == 1:
          check ours[0].startsWith("stash@{0}: ")
          let applied = fx.git("stash", "apply", "stash@{0}")
          checkpoint("git stash apply:\n" & applied.output)
          check applied.code == 0
          fx.checkWorkingTreeHasTheUnstagedWork()
          fx.checkStagedContentIsStillStaged()

          # ---- (d) the next commit names the leftover entry -------------
          let next = fx.runIn("pass", "git", ["commit", "-m", "next"])
          checkpoint("next commit:\n" & next.output)
          check next.code == 0
          check next.output.contains(LeftoverNoticeFragment)
          check next.output.contains("stash@{0}")
          # That commit's own protection came and went; the leftover is the
          # operator's to drop, so it is still there.
          check fx.ourStashEntries().len == 1
          fx.checkWorkingTreeHasTheUnstagedWork()

  test "normal_pass_and_failure_leave_no_stash_and_the_tree_intact":
    when not defined(posix):
      skip("process-group signals to a running git hook are POSIX-only")
    else:
      if findExe("git").len == 0:
        skip("git not on PATH; this test commits through real git hooks")
      else:
        let fx = setupFixture("normal")
        defer: removeDir(fx.scratch)
        # A stash entry the USER made, which nothing here may touch.
        writeFile(fx.repo / "b.txt", "user wip\n")
        discard fx.mustGit("stash", "push", "-q", "-m", "user wip")
        let userStash = fx.mustGit("rev-parse", "refs/stash")

        # ---- a hook that passes ----------------------------------------
        fx.makePartialChange()
        let head = fx.mustGit("rev-parse", "HEAD")
        let passed = fx.runIn("pass", "git", ["commit", "-m", "partial"])
        checkpoint("passing commit:\n" & passed.output)
        check passed.code == 0
        check fx.mustGit("rev-parse", "HEAD") != head
        check fx.mustGit("show", "HEAD:a.txt") == StagedA
        check fx.mustGit("show", "HEAD:s.txt") == StagedS
        fx.checkWorkingTreeHasTheUnstagedWork()
        check fx.ourStashEntries().len == 0
        check not passed.output.contains(LeftoverNoticeFragment)

        # ---- a hook that fails -----------------------------------------
        writeFile(fx.repo / "a.txt", "a3\n")
        discard fx.mustGit("add", "a.txt")
        let head2 = fx.mustGit("rev-parse", "HEAD")
        let failed = fx.runIn("fail", "git", ["commit", "-m", "refused"])
        checkpoint("failing commit:\n" & failed.output)
        check failed.code != 0
        check failed.output.contains("framework double: hook failed")
        check fx.mustGit("rev-parse", "HEAD") == head2
        check fx.mustGit("show", ":a.txt") == "a3\n"
        fx.checkWorkingTreeHasTheUnstagedWork()
        check fx.ourStashEntries().len == 0

        # The user's own entry is untouched and still the only one.
        check fx.stashEntries().len == 1
        check fx.mustGit("rev-parse", "refs/stash") == userStash

## NF-2 (Nix-Flake-Coexistence.md §3.1, §4; Unified-Locking-And-Hooks.md
## §13.1) — **every commit form carries the refreshed `flake.lock`, through
## the hook `repro hooks ensure --vcs` actually installs**.
##
## ## Why this case exists separately from the other NF-2 cases
##
## The NF-2 behavioural cases drive a `pre-commit` hook that the fixture writes
## itself (`installPreCommitDispatch`), because a developer machine's `PATH`
## carries whatever `repro` the dev shell pins and the managed body's contract
## handshake would refuse it, firing nothing. That shortcut is sound for
## everything those cases assert — and it hid a defect, because the managed
## body does one thing the fixture's hook does not: it **scrubs git's
## repository-local environment** (`unset` over `GitRepositoryLocalEnv`,
## `repro_workspace_vcs/src/git_tool.nim`) before dispatching.
##
## `GIT_INDEX_FILE` is on that list, and it is the one variable the refresh has
## to reach: it names the index the commit in flight is being built from.
## Measured on this host with git 2.50.1, printing it from a real pre-commit
## hook:
##
##   | `git commit`            | `.git/index`                       |
##   | `git commit --amend`    | `.git/index`                       |
##   | `git commit -a`         | `<root>/.git/index.lock`           |
##   | `git commit -- <paths>` | `<root>/.git/next-index-<pid>.lock`|
##
## The first two land on the default index, which is where a `git add` with no
## `GIT_INDEX_FILE` writes anyway — so they worked through the installed hook
## by luck. The other two do not: git holds `.git/index.lock` for the commit in
## flight, so a `git add` that ignores the variable exits **128**, the commit
## goes out naming the OLD sibling revision, and the refreshed lock is left as
## a working-tree modification. That is §3.1's headline failure — you publish
## something you never built — reproduced for two of the four ways people
## commit.
##
## So this case drives the REAL installed hook, and drives all four forms. The
## property it pins is as much "the test exercises the installed path" as it is
## "the installed path works": a shortcut harness cannot observe the scrub, and
## the scrub is where the failure lives.
##
## ## What is asserted
##
##   1. `git commit`, `git commit --amend`, `git commit -a` and
##      `git commit -- <paths>` each refresh `flake.lock` from the sibling that
##      moved AND stage it, so `git show HEAD:flake.lock` — what the commit
##      CARRIES — names the sibling's `HEAD`;
##   2. the working tree agrees with the commit for `flake.lock` afterwards
##      (`git diff HEAD -- flake.lock` is empty), so nothing is left behind for
##      somebody to notice later;
##   3. the pre-commit log says `staged into this commit` for each of them. A
##      refresh that rewrote the file but could not stage it logs `NOT STAGED`,
##      which is the exact shape of the defect this case was written for;
##   4. the managed body hands the index over to `repro` under a PRIVATE name
##      and still scrubs every git repository-local binding from the dispatch —
##      including `GIT_INDEX_FILE` itself. That second half is not decoration:
##      the general scrub exists so a `git -C <sibling>` call inside `repro`
##      cannot be bound to the invoking repository, and this workspace has 150+
##      siblings. Closing the staging gap by simply preserving the variable
##      would trade a loud defect for a silent one.
##
## ## Mutation (both directions)
##
##   * make `stageRefreshedFlakeLock` read the scrubbed environment again ⇒
##     the `-a` and `-- <paths>` arms go red (`NOT STAGED … exit 128`);
##   * hand the captured value to the dispatch as `GIT_INDEX_FILE` rather than
##     under the private name ⇒ assertion (4) goes red.
##
## ## Test-double policy: one instrument, no doubles of the code under test
##
## Everything in arms (1)–(3) is real: real git repositories, a real
## `repro hooks ensure --vcs`, the real `./build/bin/repro`, real `git commit`
## invocations in all four forms. See `nf2_flake_lock_fixture.nim`'s header for
## the full inventory.
##
## Arm (4) points `REPROBUILD_REPRO` at a small shell script that answers the
## contract probe and then writes its own environment to a file. That script is
## an INSTRUMENT, not a mock of `repro`: the question "what environment does
## the managed body hand its dispatch child?" can only be answered by being
## that child, and no assertion here depends on the script behaving like the
## CLI. The same precedent is already set — and justified — by assertion (5) of
## `t_hooks_ensure_installs_a_managed_pre_commit_hook`. The instrument cannot
## make this file vacuous either: arms (1)–(3) above run the genuine binary
## through the same installed hook.

import std/[os, strutils, unittest]

import repro_cli_support/push_hook_protocol
import git_tool

import nf2_flake_lock_fixture

proc worktreeMatchesCommit(fx: Nf2Fixture): bool =
  ## `flake.lock` in the working tree is byte-identical to the one HEAD
  ## carries. Asked as a git diff rather than as `status --porcelain == ""`
  ## because `git commit -- <paths>` deliberately leaves git's MAIN index
  ## behind (it commits a temporary one), so that form ends with a stale index
  ## entry for every path it was not given. What matters — and what this asks —
  ## is that the revision and the tree agree about the lock.
  let res = run(q(fx.gitBin) & " -C " & q(fx.app) &
    " diff --name-only HEAD -- flake.lock")
  res.code == 0 and res.output.strip().len == 0

proc installManagedPreCommitHook(fx: Nf2Fixture) =
  ## Replace the fixture's directly-written dispatch with the one the real
  ## installer produces, and point the managed body's interpreter resolution at
  ## the binary under test. Without the second half the body resolves `repro`
  ## from `PATH`, the contract handshake refuses whatever release is there, and
  ## every assertion below would pass over a hook that never ran.
  removePreCommitDispatch(fx)
  let ensured = run(q(fx.repro) & " hooks ensure --vcs " & q(fx.app),
    cwd = fx.app)
  if ensured.code != 0:
    stderr.writeLine("FIXTURE ABORT: `repro hooks ensure --vcs` failed:\n" &
      ensured.output)
    checkpoint("`repro hooks ensure --vcs` failed:\n" & ensured.output)
    quit 1
  putEnv("REPROBUILD_REPRO", fx.repro)

suite "NF-2: every commit form stages through the installed hook":

  test "t_every_commit_form_stages_through_the_installed_hook":
    if not nf2Prerequisites(
        "t_every_commit_form_stages_through_the_installed_hook"):
      skip()
    else:
      let fx = setupNf2Fixture("commit-forms")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      installManagedPreCommitHook(fx)
      defer: delEnv("REPROBUILD_REPRO")

      # A tracked file the `-a` and `-- <paths>` forms can modify. Seeded and
      # committed FIRST, while nothing has moved, so those forms are the only
      # commits with a refresh to do when their turn comes.
      writeFile(fx.app / "tracked.txt", "seed\n")
      discard requireCmd(q(fx.gitBin) & " -C " & q(fx.app) & " add -A")
      discard requireCmd(q(fx.gitBin) & " -C " & q(fx.app) &
        " commit -q -m " & q("seed a tracked file"))

      # ---- form 1: `git commit`. GIT_INDEX_FILE=.git/index. --------------
      let alphaTwo = moveSibling(fx, "alpha", "revision 2")
      let plain = tryCommitInApp(fx, "plain commit")
      if plain.code != 0:
        checkpoint("`git commit` failed:\n" & plain.output & "\nlog:\n" &
          preCommitLog(fx))
      check plain.code == 0
      if not lockInCommit(fx).contains(alphaTwo):
        checkpoint("`git commit` did not CARRY the refresh.\nlog:\n" &
          preCommitLog(fx) & "\nlock in commit:\n" & lockInCommit(fx))
      check lockInCommit(fx).contains(alphaTwo)
      check readFile(lockPath(fx)).contains(alphaTwo)
      check worktreeMatchesCommit(fx)
      check lastFlakeLogLine(fx).contains("staged into this commit")

      # ---- form 2: `git commit --amend`. Also .git/index. -----------------
      let betaTwo = moveSibling(fx, "beta", "revision 2")
      let amended = run(q(fx.gitBin) & " -C " & q(fx.app) &
        " commit -q --amend --no-edit")
      if amended.code != 0:
        checkpoint("`git commit --amend` failed:\n" & amended.output &
          "\nlog:\n" & preCommitLog(fx))
      check amended.code == 0
      if not lockInCommit(fx).contains(betaTwo):
        checkpoint("`git commit --amend` did not CARRY the refresh.\nlog:\n" &
          preCommitLog(fx))
      check lockInCommit(fx).contains(betaTwo)
      # The amend did not undo the previous form's pin either.
      check lockInCommit(fx).contains(alphaTwo)
      check worktreeMatchesCommit(fx)
      check lastFlakeLogLine(fx).contains("staged into this commit")

      # ---- form 3: `git commit -a`. GIT_INDEX_FILE=.git/index.lock. -------
      # The first of the two forms the managed body's scrub broke: git is
      # already holding that lock for the commit in flight, so a `git add`
      # without the variable exits 128 rather than staging somewhere harmless.
      let gammaTwo = moveSibling(fx, "gamma", "revision 2")
      writeFile(fx.app / "tracked.txt", "modified, committed with -a\n")
      let dashA = run(q(fx.gitBin) & " -C " & q(fx.app) &
        " commit -q -a -m " & q("commit -a against a moved gamma"))
      if dashA.code != 0:
        checkpoint("`git commit -a` failed:\n" & dashA.output & "\nlog:\n" &
          preCommitLog(fx))
      check dashA.code == 0
      if not lockInCommit(fx).contains(gammaTwo):
        checkpoint("`git commit -a` did not CARRY the refresh — the " &
          "refreshed lock is a working-tree modification and the commit " &
          "names the old revision.\nlog:\n" & preCommitLog(fx))
      check lockInCommit(fx).contains(gammaTwo)
      check readFile(lockPath(fx)).contains(gammaTwo)
      check worktreeMatchesCommit(fx)
      check lastFlakeLogLine(fx).contains("staged into this commit")
      check "NOT STAGED" notin lastFlakeLogLine(fx)

      # ---- form 4: `git commit -- <paths>`. next-index-<pid>.lock. --------
      # The form that had no case at all. git builds a temporary index from
      # HEAD plus the named paths and commits THAT tree, so a refresh staged
      # into the default index would be absent from the commit even where the
      # `git add` succeeded.
      let alphaThree = moveSibling(fx, "alpha", "revision 3")
      writeFile(fx.app / "tracked.txt", "modified, committed by pathspec\n")
      let pathspec = run(q(fx.gitBin) & " -C " & q(fx.app) &
        " commit -q -m " & q("pathspec commit against a moved alpha") &
        " -- tracked.txt")
      if pathspec.code != 0:
        checkpoint("`git commit -- <paths>` failed:\n" & pathspec.output &
          "\nlog:\n" & preCommitLog(fx))
      check pathspec.code == 0
      if not lockInCommit(fx).contains(alphaThree):
        checkpoint("`git commit -- <paths>` did not CARRY the refresh.\n" &
          "log:\n" & preCommitLog(fx))
      check lockInCommit(fx).contains(alphaThree)
      check readFile(lockPath(fx)).contains(alphaThree)
      check worktreeMatchesCommit(fx)
      check lastFlakeLogLine(fx).contains("staged into this commit")
      check "NOT STAGED" notin lastFlakeLogLine(fx)
      # The pathspec form committed the file it was given, so the refresh
      # travelled in the same revision rather than in one of its own.
      check gitIn(fx, fx.app, "show --stat --format= HEAD").contains(
        "tracked.txt")

  test "t_the_managed_body_hands_the_index_over_under_a_private_name":
    ## The other side of the fix: the index reaches `repro`, and NOTHING ELSE
    ## of git's repository-local environment does.
    if not nf2Prerequisites(
        "t_the_managed_body_hands_the_index_over_under_a_private_name"):
      skip()
    else:
      let fx = setupNf2Fixture("index-handoff")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      installManagedPreCommitHook(fx)
      defer: delEnv("REPROBUILD_REPRO")

      # The instrument: answers the contract probe, then records the
      # environment the managed body handed it. See the header for why a
      # recorder rather than the real binary is the only way to ask this.
      let envDump = fx.scratch / "dispatch-env.txt"
      let recorder = fx.scratch / "record-dispatch-env"
      writeFile(recorder,
        "#!/usr/bin/env sh\n" &
        "case \"${1:-}.${2:-}\" in\n" &
        "  hooks.protocol) exit 0 ;;\n" &
        "  hooks.dispatch) env > " & q(envDump) & "; exit 0 ;;\n" &
        "esac\n" &
        "exit 0\n")
      var perms = getFilePermissions(recorder)
      perms.incl({fpUserExec, fpGroupExec, fpOthersExec})
      setFilePermissions(recorder, perms)
      putEnv("REPROBUILD_REPRO", recorder)

      proc recorded(name: string): tuple[present: bool; value: string] =
        for line in readFile(envDump).splitLines():
          let eq = line.find('=')
          if eq > 0 and line[0 ..< eq] == name:
            return (true, line[eq + 1 .. ^1])
        (false, "")

      # Fire the INSTALLED dispatcher with git's repository-local environment
      # set the way git sets it for a temporary-index commit. An absolute
      # value first, because that is what `git commit -a` and
      # `git commit -- <paths>` were measured to pass.
      let absoluteIndex = fx.app / ".git" / "next-index-4242.lock"
      var poisoned = "GIT_INDEX_FILE=" & q(absoluteIndex) &
        " GIT_DIR=" & q(fx.app / ".git") &
        " GIT_WORK_TREE=" & q(fx.app) &
        " GIT_PREFIX= GIT_CONFIG_COUNT=1" &
        " GIT_CONFIG_KEY_0=core.bare GIT_CONFIG_VALUE_0=false"
      let fired = run("env " & poisoned & " " & q(preCommitHookPath(fx)),
        cwd = fx.app)
      if fired.code != 0 or not fileExists(envDump):
        checkpoint("the installed dispatcher did not reach the dispatch " &
          "child: exit=" & $fired.code & "\n" & fired.output)
      check fired.code == 0
      check fileExists(envDump)

      # (a) the index arrived, under the private name, absolute.
      let handed = recorded(HookGitIndexFileEnv)
      if not handed.present:
        checkpoint("the managed body did not hand the index over at all; " &
          "the two temporary-index commit forms cannot stage without it")
      check handed.present
      check handed.value == absoluteIndex

      # (b) …and NOT under git's own name, nor any other repository-local
      # binding. This is the hazard the general scrub exists to prevent: with
      # `GIT_INDEX_FILE` live in `repro`'s environment, a `git -C <sibling>`
      # that ever skipped the in-process scrubber would read the invoking
      # repository's in-flight index as the sibling's, and this workspace has
      # 150+ siblings for it to be wrong about.
      for name in GitRepositoryLocalEnv:
        let leaked = recorded(name)
        if leaked.present:
          checkpoint("the managed body leaked " & name & "=" & leaked.value &
            " into the dispatch; the scrub is what keeps a sibling " &
            "operation from being bound to the committing repository")
        check not leaked.present
      for prefix in GitRepositoryLocalEnvPrefixes:
        for line in readFile(envDump).splitLines():
          if line.startsWith(prefix):
            checkpoint("the managed body leaked " & line & " into the dispatch")
          check not line.startsWith(prefix)

      # (c) a RELATIVE value — what `git commit` and `git commit --amend` were
      # measured to pass — is absolutised before it is handed over. `repro`
      # runs `git -C <repo>`, so a relative index path interpreted from
      # anywhere but the repository root is a different file, or none.
      removeFile(envDump)
      poisoned = "GIT_INDEX_FILE=.git/index GIT_DIR=.git"
      let relative = run("env " & poisoned & " " & q(preCommitHookPath(fx)),
        cwd = fx.app)
      check relative.code == 0
      check fileExists(envDump)
      let handedRelative = recorded(HookGitIndexFileEnv)
      check handedRelative.present
      check handedRelative.value == fx.app / ".git" / "index"

      # (d) an invocation that passes NO index — a hand-run hook, or a git that
      # did not export one. The handover is EMPTY rather than absent, and the
      # reader treats empty as "git named no index" and falls through to the
      # default one; what it must never be is a stray path.
      removeFile(envDump)
      let bare = run(q(preCommitHookPath(fx)), cwd = fx.app)
      check bare.code == 0
      check fileExists(envDump)
      check recorded(HookGitIndexFileEnv).value.len == 0

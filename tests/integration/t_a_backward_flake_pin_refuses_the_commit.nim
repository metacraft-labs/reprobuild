## The commit-time `flake.lock` refresh never moves a pin BACKWARD silently,
## and a refusal by EITHER committed lock writes NEITHER
## (Nix-Flake-Coexistence.md §3.2 "Rule, at commit" and §4 "Regressions";
## Unified-Locking-And-Hooks.md §13.3).
##
## WHY. `flake.lock` is the second committed lock the managed `pre-commit`
## hook maintains, and it fails exactly like `repro.lock`: a substituted
## sibling BEHIND its pin almost always means a stale checkout, so recording
## its HEAD would publish a downgrade nobody chose. The refresh therefore
## records an input whose sibling is behind, diverged, or missing the pinned
## commit only when the committer names that input in
## `REPRO_ALLOW_PIN_REGRESSION`; otherwise the commit is refused. One variable
## covers both locks in the commit, and only the names it lists.
##
## Cases (the behind / unfetched refusals themselves are pinned by the NF-2
## cases `t_a_behind_pin_sibling_is_not_recorded_as_the_new_pin`,
## `t_a_behind_pin_skip_names_the_sibling_distance_and_remedy` and
## `t_a_sibling_whose_pin_is_not_fetched_is_not_recorded`):
##   * a behind input named in the variable commits the older pin, printed and
##     logged with both revisions;
##   * the variable naming a different input still refuses, with a note;
##   * the variable naming an input that is not regressing passes, with a note;
##   * a diverged input refuses (it used to be recorded), names
##     `repro ws sync`, and is committed when named;
##   * a commit made while a rebase is stopped stands down even with a behind
##     input;
##   * with a committed `repro.lock` beside the flake: a `repro.lock` refusal
##     leaves `flake.lock` unwritten, one variable naming the `repro.lock`
##     sibling lets the commit carry both refreshed locks, a `flake.lock`
##     refusal leaves `repro.lock` unwritten, and naming only one of two
##     regressing siblings still refuses — for the other one alone, with
##     nothing written and no "not regressing" note for the one named.
##
## Falsifiability (observed at the base commit this change was written on):
## the allowance, note, diverged and both-locks cases fail there — the refresh
## withholds a behind input and lets the commit proceed, records a diverged
## one, and prints nothing about the variable. The stopped-rebase case is a
## guard; it was shown to go red with the stand-down disabled, and the
## both-locks case's last step went red with the "named input that regressed
## counts as used" rule removed.
##
## Test-double policy: NO mocks, doubles or fakes — real bare git origins,
## real clones, a real `flake.lock` in nix's on-disk shape, a real committed
## `repro.lock` written by `repro lock refresh`, the real `./build/bin/repro`,
## and a REAL `.git/hooks/pre-commit` fired by a real `git commit`. See the
## headers of `nf2_flake_lock_fixture.nim` and `nf3_override_state_fixture.nim`.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip

import nf3_override_state_fixture

const AllowEnv = "REPRO_ALLOW_PIN_REGRESSION"

proc commitWith(fx: Nf2Fixture; message: string; allow = ""):
    tuple[code: int; output: string] =
  ## A real `git commit` in app, firing the installed hook, with
  ## `REPRO_ALLOW_PIN_REGRESSION` set explicitly (empty unless ``allow``) so an
  ## exported value in the environment running the suite cannot leak in.
  let stamp = message.replace(" ", "-")
  writeFile(fx.app / (stamp & ".txt"), message & "\n")
  discard requireCmd(q(fx.gitBin) & " -C " & q(fx.app) & " add -A")
  run(AllowEnv & "=" & q(allow) & " " & q(fx.gitBin) & " -C " & q(fx.app) &
    " commit -q -m " & q(message))

proc lineWith(text: string; needles: varargs[string]): string =
  for line in text.splitLines():
    var all = true
    for n in needles:
      if n notin line:
        all = false
        break
    if all: return line
  ""

proc depEntryPresent(reproLockText, path: string): bool =
  ## Does the committed `repro.lock` carry a `deps` entry at ``path``?
  ("path = \"" & path & "\"") in reproLockText

proc lockedRev(lockText, node: string): string =
  ## `locked.rev` of one node, read from its raw text.
  let body = nodeText(lockText, node)
  let key = "\"rev\": \""
  let at = body.find(key)
  if at < 0: return ""
  let stop = body.find('"', at + key.len)
  body[at + key.len ..< stop]

proc gammaBehindByTwo(fx: Nf2Fixture): tuple[pinned, checkout: string] =
  ## The flake pins gamma two commits ahead of where its checkout sits; the
  ## pinned objects stay in gamma's store, so the relation is BEHIND.
  result.pinned = advanceSibling(fx, "gamma", 2)
  result.checkout = rewindSibling(fx, "gamma", 2)
  setFlakePins(fx, fx.seedSha[0], fx.seedSha[1], result.pinned)
  commitLockAndPublish(fx, "a lock pinned two ahead of the gamma checkout")

suite "the commit-time flake.lock refresh never moves a pin backward silently":

  test "t_a_behind_flake_input_named_in_the_variable_commits_the_older_pin":
    if not nf2Prerequisites("t_a_behind_flake_input_named_in_the_variable_" &
        "commits_the_older_pin"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      let fx = setupNf2Fixture("flake-allowed")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      let gamma = gammaBehindByTwo(fx)
      let c = commitWith(fx, "deliberately older gamma", allow = "gamma-src")
      checkpoint(c.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check c.code == 0
      let carried = lockInCommit(fx)
      check lockedRev(carried, "gamma-src") == gamma.checkout
      check lockedRev(readFile(lockPath(fx)), "gamma-src") == gamma.checkout
      let announced = lineWith(c.output, "allowed pin regression",
        "flake.lock input 'gamma-src'")
      checkpoint("announced: " & announced)
      check announced.len > 0
      check ("from " & gamma.pinned & " to " & gamma.checkout) in announced
      check "behind by 2 commit(s)" in announced
      let logged = lineWith(preCommitLog(fx), "flake-lock",
        "allowed pin regression", "gamma-src")
      checkpoint("logged: " & logged)
      check ("from " & gamma.pinned & " to " & gamma.checkout) in logged
      check "REFUSED" notin c.output

  test "t_the_variable_naming_another_input_still_refuses":
    if not nf2Prerequisites("t_the_variable_naming_another_input_still_" &
        "refuses"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      let fx = setupNf2Fixture("flake-allow-other")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      let gamma = gammaBehindByTwo(fx)
      let before = readFile(lockPath(fx))
      let headBefore = headOf(fx, fx.app)
      let c = commitWith(fx, "allowing the wrong input", allow = "alpha-src")
      checkpoint(c.output)
      check c.code != 0
      check headOf(fx, fx.app) == headBefore
      check readFile(lockPath(fx)) == before
      check lineWith(c.output, "flake.lock input 'gamma-src'",
        "behind by 2 commit(s)", gamma.pinned, gamma.checkout).len > 0
      check lineWith(c.output, AllowEnv & " names 'alpha-src'",
        "does not move backward").len > 0

  test "t_the_variable_naming_a_non_regressing_input_passes_with_a_note":
    if not nf2Prerequisites("t_the_variable_naming_a_non_regressing_input_" &
        "passes_with_a_note"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      let fx = setupNf2Fixture("flake-allow-idle")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      let alphaHead = advancePublishedSibling(fx, "alpha", 1)
      let c = commitWith(fx, "nothing regresses", allow = "beta-src")
      checkpoint(c.output)
      check c.code == 0
      check lockedRev(lockInCommit(fx), "alpha-src") == alphaHead
      check lineWith(c.output, AllowEnv & " names 'beta-src'",
        "does not move backward", "Ignored").len > 0
      check "allowed pin regression" notin c.output

  test "t_a_diverged_flake_input_refuses_the_commit":
    if not nf2Prerequisites("t_a_diverged_flake_input_refuses_the_commit"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      let fx = setupNf2Fixture("flake-diverged")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      # The flake pins gamma's newest published commit…
      let pinned = moveAndPublishSibling(fx, "gamma", "revision 2")
      setFlakePins(fx, fx.seedSha[0], fx.seedSha[1], pinned)
      commitLockAndPublish(fx, "pin gamma at revision 2")
      # …and the checkout leaves that line: one back, then its own commit,
      # published on another branch so the revision is obtainable.
      discard rewindSibling(fx, "gamma", 1)
      let forked = moveSibling(fx, "gamma", "a fork of revision 1")
      discard gitIn(fx, siblingDir(fx, "gamma"),
        "push -q origin HEAD:refs/heads/fork")
      check siblingRevIsPublished(fx, "gamma", forked)
      let before = readFile(lockPath(fx))
      let headBefore = headOf(fx, fx.app)

      let c = commitWith(fx, "work on a forked gamma")
      checkpoint(c.output)
      check c.code != 0
      check headOf(fx, fx.app) == headBefore
      check readFile(lockPath(fx)) == before
      let headline = lineWith(c.output, "flake.lock input 'gamma-src'",
        "diverged: 1 and 1 commits apart")
      checkpoint("headline: " & headline)
      check headline.len > 0
      check pinned in headline
      check forked in headline
      let forward = backtickedCommands(lineWith(c.output,
        "bring the checkout forward"))
      checkpoint("forward: " & $forward)
      check forward.len == 1
      if forward.len == 1:
        check forward[0].startsWith("repro ws sync")

      let allowed = run(AllowEnv & "=gamma-src " & q(fx.gitBin) & " -C " &
        q(fx.app) & " commit -q -m " & q("track the forked gamma"))
      checkpoint(allowed.output)
      check allowed.code == 0
      check lockedRev(lockInCommit(fx), "gamma-src") == forked
      check lineWith(allowed.output, "allowed pin regression", "gamma-src",
        "diverged").len > 0

  test "t_a_behind_flake_input_during_a_stopped_rebase_stands_down":
    if not nf2Prerequisites("t_a_behind_flake_input_during_a_stopped_rebase_" &
        "stands_down"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      let fx = setupNf2Fixture("flake-rebase-stand-down")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      # The lock pins gamma's checkout; two commits follow; then the checkout
      # is rewound, so every commit the rebase stops on pins a newer gamma.
      let pinned = advanceSibling(fx, "gamma", 2)
      setFlakePins(fx, fx.seedSha[0], fx.seedSha[1], pinned)
      commitLockAndPublish(fx, "pin gamma two ahead")
      check commitWith(fx, "history one").code == 0
      check commitWith(fx, "history two").code == 0
      discard rewindSibling(fx, "gamma", 2)
      let before = readFile(lockPath(fx))
      let stopped = run("GIT_SEQUENCE_EDITOR=" & q("sed -i 1s/^pick/edit/") &
        " " & q(fx.gitBin) & " -C " & q(fx.app) & " rebase -i HEAD~2",
        cwd = fx.app)
      checkpoint(stopped.output)
      check stopped.code == 0
      check dirExists(fx.app / ".git" / "rebase-merge")
      writeFile(fx.app / "during-rebase.txt", "edited mid-rebase\n")
      discard requireCmd(q(fx.gitBin) & " -C " & q(fx.app) & " add -A")
      let amended = run(AllowEnv & "= " & q(fx.gitBin) & " -C " & q(fx.app) &
        " commit -q --amend --no-edit")
      checkpoint(amended.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check amended.code == 0
      check "REFUSED" notin amended.output
      check readFile(lockPath(fx)) == before
      check lastFlakeLogLine(fx).contains("skipped-git-operation-in-progress")
      discard requireCmd("GIT_EDITOR=true " & q(fx.gitBin) & " -C " &
        q(fx.app) & " rebase --continue")
      check readFile(lockPath(fx)) == before

  test "t_a_refusal_in_either_lock_writes_neither":
    if not nf2Prerequisites("t_a_refusal_in_either_lock_writes_neither"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      let fx = setupNf2Fixture("both-locks")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      # app also carries a committed repro.lock, written by the explicit door;
      # its develop set is alpha, beta and epsilon (the workspace lock's
      # `depends`), so alpha is pinned by BOTH locks and epsilon only by
      # repro.lock.
      writeFile(fx.app / "repro.solver",
        "package app\nversions: 0.1.0\ndepends: nim >=2.2.0 <3.0.0\n\n" &
        "package nim\nversions: 2.2.0\n")
      writeFile(fx.app / ".gitignore", ".repro/\n")
      let refresh = run(q(fx.repro) & " lock refresh " & q(fx.app))
      checkpoint("lock refresh:\n" & refresh.output)
      check refresh.code == 0
      commitLockAndPublish(fx, "commit repro.lock beside the flake")
      let reproLock = fx.app / "repro.lock"
      check depEntryPresent(readFile(reproLock), "../epsilon")
      check depEntryPresent(readFile(reproLock), "../alpha")

      # epsilon advances and a commit records it (ahead), then its checkout
      # is rewound: repro.lock now pins epsilon one ahead of the checkout.
      let epsilonPinned = moveAndPublishSibling(fx, "epsilon", "revision 2")
      check commitWith(fx, "adopt epsilon revision 2").code == 0
      check epsilonPinned in readFile(reproLock)
      discard rewindSibling(fx, "epsilon", 1)
      # alpha moves forward, so BOTH locks would advance it.
      let alphaHead = moveAndPublishSibling(fx, "alpha", "revision 2")
      let flakeBefore = readFile(lockPath(fx))
      let reproBefore = readFile(reproLock)

      # ---- a repro.lock refusal leaves flake.lock unwritten --------------
      let refused = commitWith(fx, "work against a stale epsilon")
      checkpoint(refused.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check refused.code != 0
      check readFile(lockPath(fx)) == flakeBefore
      check readFile(reproLock) == reproBefore
      check lineWith(refused.output, "repro.lock sibling 'epsilon'",
        "behind by 1 commit(s)").len > 0
      check lastFlakeLogLine(fx).contains("not-written-commit-refused")
      check alphaHead notin readFile(lockPath(fx))

      # ---- one variable naming the repro.lock sibling carries both -------
      let allowed = run(AllowEnv & "=epsilon " & q(fx.gitBin) & " -C " &
        q(fx.app) & " commit -q -m " & q("deliberately older epsilon"))
      checkpoint(allowed.output)
      check allowed.code == 0
      check lockedRev(lockInCommit(fx), "alpha-src") == alphaHead
      let committedRepro = gitIn(fx, fx.app, "show HEAD:repro.lock")
      check alphaHead in committedRepro
      check epsilonPinned notin committedRepro
      check lineWith(allowed.output, "allowed pin regression",
        "repro.lock sibling 'epsilon'").len > 0

      # ---- a flake.lock refusal leaves repro.lock unwritten --------------
      # epsilon moves ahead again and is recorded, so that it can be made to
      # regress once more below. It first returns to the line its origin
      # carries, so the new revision publishes as a fast-forward.
      discard gitIn(fx, siblingDir(fx, "epsilon"), "merge -q --ff-only " &
        epsilonPinned)
      discard moveAndPublishSibling(fx, "epsilon", "revision 3")
      check commitWith(fx, "adopt epsilon revision 3").code == 0
      let gammaPinned = moveSibling(fx, "gamma", "revision 2")
      discard rewindSibling(fx, "gamma", 1)
      let flakeNow = readFile(lockPath(fx))
      writeFile(lockPath(fx), flakeNow.replace(nodeText(flakeNow, "gamma-src"),
        nodeText(flakeNow, "gamma-src").replace(fx.seedSha[2], gammaPinned)))
      commitLockAndPublish(fx, "pin gamma one ahead")
      let alphaNext = moveAndPublishSibling(fx, "alpha", "revision 3")
      let flakeHeld = readFile(lockPath(fx))
      let reproHeld = readFile(reproLock)
      let second = commitWith(fx, "work against a stale gamma")
      checkpoint(second.output)
      check second.code != 0
      check readFile(lockPath(fx)) == flakeHeld
      check readFile(reproLock) == reproHeld
      check alphaNext notin readFile(reproLock)
      check lineWith(second.output, "flake.lock input 'gamma-src'",
        "behind by 1 commit(s)").len > 0
      check lineWith(preCommitLog(fx), "repro-lock",
        "not-written-commit-refused").len > 0

      # ---- naming one regression does not excuse the other ---------------
      # Both locks regress now; the variable names only the flake input. The
      # commit is refused for epsilon alone, nothing is written, and the named
      # input is not reported as "not moving backward" — it was, and it was
      # allowed; it is only unwritten because the commit was refused.
      discard rewindSibling(fx, "epsilon", 1)
      let third = commitWith(fx, "allow gamma only", allow = "gamma-src")
      checkpoint(third.output)
      check third.code != 0
      check readFile(lockPath(fx)) == flakeHeld
      check readFile(reproLock) == reproHeld
      check lineWith(third.output, "repro.lock sibling 'epsilon'",
        "behind by 1 commit(s)").len > 0
      check lineWith(third.output, "flake.lock input 'gamma-src'",
        "behind by").len == 0
      check lineWith(third.output, "names 'gamma-src'").len == 0
      check "allowed pin regression" notin third.output

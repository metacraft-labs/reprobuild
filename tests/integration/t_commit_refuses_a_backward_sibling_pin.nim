## The managed `pre-commit` hook never moves a committed `repro.lock` pin
## BACKWARD silently (Unified-Locking-And-Hooks.md §13.3, "A pin never moves
## backward silently").
##
## WHY. The hook re-pins each sibling of a committed `repro.lock` from the
## checkout beside the repo. A sibling BEHIND its pin almost always means a
## stale checkout, not a chosen downgrade, so re-pinning it silently turns "my
## checkout is old" into "the published lock is old" for every consumer. The
## hook therefore relates the observed revision to the pinned one in the
## sibling's own history: ahead advances; behind, diverged, or a pinned commit
## absent from the checkout (unprovable) refuses the commit unless the
## committer names the sibling in `REPRO_ALLOW_PIN_REGRESSION` for that commit.
##
## Fixture: `committed_lock_siblings_fixture.nim` — a real manifest workspace
## (app → lib-b → lib-c, lib-d unrelated) of real git repositories cloned from
## real bare origins. The lock is written by `repro lock refresh` and
## published, then lib-b is advanced twice and a first commit re-pins it
## (ahead), so every case starts from "the lock pins lib-b at its newest
## published commit". A REAL `.git/hooks/pre-commit` in app issues the
## byte-identical dispatch the managed hook body issues, naming the built
## binary by absolute path so a dev-shell `repro` on PATH cannot stand in for
## the one under test; every case observes what a real `git commit`,
## `git commit --amend`, `git rebase -i` or `git cherry-pick` produced.
##
## Cases:
##   * an ahead sibling still advances, with no refusal;
##   * a behind sibling refuses the commit (nonzero exit, HEAD and the lock —
##     working tree and index — untouched) with a message naming the sibling,
##     the relation, the distance, both revisions, a forward command and the
##     variable; the named `git log` lists exactly what would be dropped, and
##     the named forward command really brings the checkout forward, after
##     which the same commit proceeds;
##   * the behind sibling named in `REPRO_ALLOW_PIN_REGRESSION` commits the
##     older pin, and the regression is printed and logged with both revisions;
##   * the variable naming a DIFFERENT sibling still refuses, with a note;
##   * the variable naming a sibling that is not regressing passes with a note
##     (and a wildcard value is reported, never matched);
##   * a diverged sibling refuses, naming `repro ws sync <project>`, which
##     resolves to a plan that covers the sibling;
##   * a pinned commit absent from the checkout refuses and names a fetch;
##     after the named fetch the same sibling classifies as behind;
##   * a commit made while a rebase is stopped, and one concluding a
##     conflicted cherry-pick, stand down — a behind sibling refuses neither;
##   * `git commit --amend` is idempotent: over unmoved siblings the lock is
##     byte- and mtime-identical, and after an allowed regression the amend
##     needs no variable and announces nothing.
##
## Falsifiability (observed at the base commit this change was written on):
## the refusal, allowance, note and diverged/unprovable cases fail there — the
## hook re-pins every sibling to its HEAD, backward included, and exits 0. The
## ahead, stand-down and amend cases are guards on behaviour this change must
## keep; each was shown to go red under a targeted mutation of the new code:
## ahead siblings left alone (the ahead case), the stand-down disabled (the
## rebase and cherry-pick cases), and the lock rewritten when no byte changed
## (the amend case).
##
## NO MOCKS. The one arrangement is writing the hook file by hand instead of
## `repro hooks ensure --vcs`, for the PATH reason above; its body is the
## managed body's dispatch line.

import std/[os, strutils, times, unittest]
import repro_test_support
import ./committed_lock_siblings_fixture

const AllowEnv = "REPRO_ALLOW_PIN_REGRESSION"

proc hookPath(fx: SiblingFixture): string =
  fx.app / ".git" / "hooks" / "pre-commit"

proc installHook(fx: SiblingFixture) =
  let hook = fx.hookPath()
  createDir(hook.parentDir)
  writeFile(hook,
    "#!/usr/bin/env sh\nset -eu\n" &
    "REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)\n" &
    "cd \"$REPO_ROOT\"\nREPRO_STATUS=0\n" &
    q(fx.repro) & " hooks dispatch pre-commit --repo-root \"$REPO_ROOT\" " &
      "-- \"$@\" || REPRO_STATUS=$?\nexit $REPRO_STATUS\n")
  var perms = getFilePermissions(hook)
  perms.incl({fpUserExec, fpGroupExec, fpOthersExec})
  setFilePermissions(hook, perms)

proc removeHook(fx: SiblingFixture) =
  if fileExists(fx.hookPath()): removeFile(fx.hookPath())

proc gitCmd(fx: SiblingFixture; repo, args: string; allow = ""): string =
  ## One git command line in ``repo``, with `REPRO_ALLOW_PIN_REGRESSION` set
  ## explicitly (empty unless ``allow``), so an exported value in the
  ## environment running the suite cannot leak into a case.
  AllowEnv & "=" & q(allow) & " " & q(fx.gitBin) & " -C " & q(repo) & " " &
    args

proc tryCommit(fx: SiblingFixture; label: string; allow = ""):
    tuple[code: int; output: string] =
  writeFile(fx.app / (label & ".txt"), label & "\n")
  discard fx.git(fx.app, "add " & q(label & ".txt"))
  runCmd(fx.gitCmd(fx.app, "commit -m " & q(label), allow))

proc preCommitLog(fx: SiblingFixture): string =
  let path = fx.ws / ".repro" / "workspace" / "pre-commit-lock.log"
  if fileExists(path): readFile(path) else: ""

proc pinOf(lockBody, path: string): string =
  ## The `revision` of the `deps` entry at ``path``.
  let entry = depEntry(lockBody, path)
  let key = "revision = \""
  let at = entry.find(key)
  if at < 0: return ""
  let stop = entry.find('"', at + key.len)
  entry[at + key.len ..< stop]

proc backticked(text: string): seq[string] =
  var i = 0
  while true:
    let open = text.find('`', i)
    if open < 0: break
    let close = text.find('`', open + 1)
    if close < 0: break
    result.add(text[open + 1 ..< close])
    i = close + 1

proc lineWith(text: string; needles: varargs[string]): string =
  for line in text.splitLines():
    var all = true
    for n in needles:
      if n notin line:
        all = false
        break
    if all: return line
  ""

proc runNamed(fx: SiblingFixture; command: string; cwd: string):
    tuple[code: int; output: string] =
  ## Run a command exactly as a refusal printed it, from ``cwd``; a leading
  ## `repro` is the binary under test.
  var cmd = command.strip()
  if cmd.startsWith("repro "):
    cmd = q(fx.repro) & cmd["repro".len .. ^1]
  runCmd(cmd, cwd)

type Started = object
  fx: SiblingFixture
  libB: string        ## ws/lib-b
  seed: string        ## lib-b's first commit
  mid: string         ## lib-b one advance later
  pinned: string      ## lib-b's newest published commit — what the lock pins

proc startPinnedAtNewest(label: string): Started =
  ## The lock pins lib-b at its newest published commit, recorded by a real
  ## commit through the hook (the ahead case, which is the baseline).
  var fx = setupSiblingFixture(label)
  result.libB = fx.ws / "lib-b"
  fx.refreshAndPublishLock()
  result.seed = fx.headOf(result.libB)
  result.mid = fx.advance("lib-b")
  result.pinned = fx.advance("lib-b")
  fx.installHook()
  let first = fx.tryCommit("adopt-newer-lib-b")
  checkpoint("baseline commit:\n" & first.output)
  doAssert first.code == 0, "the baseline commit failed:\n" & first.output
  let committed = fx.git(fx.app, "show HEAD:repro.lock")
  doAssert pinOf(committed, "../lib-b") == result.pinned,
    "the baseline commit did not pin lib-b's newest commit"
  result.fx = fx

proc rewindLibB(s: Started; steps: int): string =
  discard s.fx.git(s.libB, "reset -q --hard HEAD~" & $steps)
  s.fx.headOf(s.libB)

suite "pre-commit never moves a repro.lock pin backward silently":

  test "t_an_ahead_sibling_pin_still_advances":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      var s = startPinnedAtNewest("ahead-advances")
      defer: removeDir(s.fx.scratch)
      let next = s.fx.advance("lib-b")
      let c = s.fx.tryCommit("after-another-advance")
      checkpoint(c.output)
      check c.code == 0
      check pinOf(s.fx.git(s.fx.app, "show HEAD:repro.lock"), "../lib-b") ==
        next
      check "REFUSED" notin c.output
      check "allowed pin regression" notin c.output

  test "t_a_behind_sibling_refuses_the_commit_and_names_the_remedies":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      var s = startPinnedAtNewest("behind-refused")
      defer: removeDir(s.fx.scratch)
      let fx = s.fx
      let observed = s.rewindLibB(2)
      check observed == s.seed
      let headBefore = fx.headOf(fx.app)
      let lockBefore = readFile(fx.app / "repro.lock")

      let c = fx.tryCommit("work-against-a-stale-lib-b")
      checkpoint(c.output)
      checkpoint("pre-commit log:\n" & fx.preCommitLog())
      # The commit is refused, and refused cleanly: no new commit, the lock
      # untouched in the working tree and not staged.
      check c.code != 0
      check fx.headOf(fx.app) == headBefore
      check readFile(fx.app / "repro.lock") == lockBefore
      check fx.git(fx.app, "diff --cached --name-only").strip() ==
        "work-against-a-stale-lib-b.txt"
      check pinOf(readFile(fx.app / "repro.lock"), "../lib-b") == s.pinned

      # It names the sibling, the relation and distance, both revisions, the
      # variable, and when using the variable is and is not appropriate.
      let headline = lineWith(c.output, "repro.lock sibling 'lib-b'",
        "behind by 2 commit(s)")
      checkpoint("headline: " & headline)
      check headline.len > 0
      check s.pinned in headline
      check observed in headline
      check (AllowEnv & "=lib-b git commit") in c.output
      check "reverting a dependency upgrade" in c.output
      check "bisecting" in c.output
      check "another branch" in c.output
      check "rewritten" in c.output
      check "have not pulled" in c.output
      check "refused-pin-regression" in fx.preCommitLog()

      # The named `git log` lists exactly the commits the lock would drop.
      let dropLine = lineWith(c.output, "would drop from the published lock")
      let dropCmds = backticked(dropLine)
      check dropCmds.len == 1
      if dropCmds.len == 1:
        let dropped = fx.runNamed(dropCmds[0], fx.app)
        checkpoint("ran `" & dropCmds[0] & "`:\n" & dropped.output)
        check dropped.code == 0
        check dropped.output.strip().splitLines().len == 2

      # The forward command runs where the message is printed and brings the
      # checkout up to the pin; the same commit then proceeds.
      let forwardLine = lineWith(c.output, "bring the checkout forward")
      let forward = backticked(forwardLine)
      checkpoint("forward line: " & forwardLine)
      check forward.len == 1
      if forward.len == 1:
        check "merge --ff-only" in forward[0]
        let ran = fx.runNamed(forward[0], fx.app)
        checkpoint("ran `" & forward[0] & "`:\n" & ran.output)
        check ran.code == 0
        check fx.headOf(s.libB) == s.pinned
        let again = runCmd(fx.gitCmd(fx.app, "commit -m " &
          q("work-after-bringing-lib-b-forward")))
        checkpoint(again.output)
        check again.code == 0
        check pinOf(fx.git(fx.app, "show HEAD:repro.lock"), "../lib-b") ==
          s.pinned

  test "t_an_allowed_behind_regression_commits_the_older_pin_and_is_logged":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      var s = startPinnedAtNewest("behind-allowed")
      defer: removeDir(s.fx.scratch)
      let fx = s.fx
      let observed = s.rewindLibB(2)
      let c = fx.tryCommit("deliberately-older-lib-b", allow = "lib-b")
      checkpoint(c.output)
      check c.code == 0
      let committed = fx.git(fx.app, "show HEAD:repro.lock")
      check pinOf(committed, "../lib-b") == observed
      check ("integrity = \"git-sha1:" & observed & "\"") in
        depEntry(committed, "../lib-b")
      check fx.git(fx.app, "status --porcelain").strip().len == 0
      # Printed into the commit's output, and logged, with both revisions.
      let announced = lineWith(c.output, "allowed pin regression",
        "repro.lock sibling 'lib-b'")
      checkpoint("announced: " & announced)
      check announced.len > 0
      check ("from " & s.pinned & " to " & observed) in announced
      let logged = lineWith(fx.preCommitLog(), "allowed pin regression",
        "lib-b")
      checkpoint("logged: " & logged)
      check ("from " & s.pinned & " to " & observed) in logged
      check "REFUSED" notin c.output

  test "t_the_variable_naming_another_sibling_still_refuses":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      var s = startPinnedAtNewest("allow-other-sibling")
      defer: removeDir(s.fx.scratch)
      let fx = s.fx
      discard s.rewindLibB(1)
      let headBefore = fx.headOf(fx.app)
      let c = fx.tryCommit("allowing-the-wrong-sibling", allow = "lib-c")
      checkpoint(c.output)
      check c.code != 0
      check fx.headOf(fx.app) == headBefore
      check pinOf(readFile(fx.app / "repro.lock"), "../lib-b") == s.pinned
      check lineWith(c.output, "repro.lock sibling 'lib-b'",
        "behind by 1 commit(s)").len > 0
      check lineWith(c.output, AllowEnv & " names 'lib-c'",
        "does not move backward").len > 0

  test "t_the_variable_naming_a_non_regressing_sibling_passes_with_a_note":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      var s = startPinnedAtNewest("allow-not-regressing")
      defer: removeDir(s.fx.scratch)
      let fx = s.fx
      let next = fx.advance("lib-b")
      let c = fx.tryCommit("nothing-regresses", allow = "lib-c,nope,*")
      checkpoint(c.output)
      checkpoint("pre-commit log:\n" & fx.preCommitLog())
      check c.code == 0
      check pinOf(fx.git(fx.app, "show HEAD:repro.lock"), "../lib-b") == next
      check lineWith(c.output, AllowEnv & " names 'lib-c'",
        "does not move backward", "Ignored").len > 0
      check lineWith(c.output, AllowEnv & " names 'nope'",
        "neither a repro.lock sibling nor a flake.lock input").len > 0
      check lineWith(c.output, AllowEnv & " value '*'", "no wildcard").len > 0
      check lineWith(fx.preCommitLog(), "note", "'lib-c'").len > 0
      check "allowed pin regression" notin c.output

  test "t_a_diverged_sibling_refuses_the_commit":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      var s = startPinnedAtNewest("diverged-refused")
      defer: removeDir(s.fx.scratch)
      let fx = s.fx
      # lib-b leaves the pin's line: one commit back, then a local commit the
      # pin does not have.
      discard s.rewindLibB(1)
      writeFile(s.libB / "fork.txt", "a line the pin never saw\n")
      discard fx.git(s.libB, "add fork.txt")
      discard fx.git(s.libB, "commit -q -m fork")
      let observed = fx.headOf(s.libB)
      let headBefore = fx.headOf(fx.app)
      let c = fx.tryCommit("work-on-a-forked-lib-b")
      checkpoint(c.output)
      check c.code != 0
      check fx.headOf(fx.app) == headBefore
      check pinOf(readFile(fx.app / "repro.lock"), "../lib-b") == s.pinned
      let headline = lineWith(c.output, "repro.lock sibling 'lib-b'",
        "diverged: 1 and 1 commits apart")
      checkpoint("headline: " & headline)
      check headline.len > 0
      check s.pinned in headline
      check observed in headline
      # The forward command is `repro ws sync <project>`, and it resolves: its
      # dry run plans lib-b.
      let forward = backticked(lineWith(c.output,
        "bring the checkout forward"))
      checkpoint("forward: " & $forward)
      check forward.len == 1
      if forward.len == 1:
        check forward[0].startsWith("repro ws sync app ")
        let plan = fx.runNamed(forward[0] & " --dry-run --json", fx.app)
        checkpoint("dry run:\n" & plan.output)
        check plan.code == 0
        check "\"lib-b\"" in plan.output
      # …and the deliberate course works for a diverged sibling too.
      let allowed = runCmd(fx.gitCmd(fx.app, "commit -m " &
        q("track-the-forked-lib-b"), allow = "lib-b"))
      checkpoint(allowed.output)
      check allowed.code == 0
      check pinOf(fx.git(fx.app, "show HEAD:repro.lock"), "../lib-b") ==
        observed
      check lineWith(allowed.output, "allowed pin regression",
        "diverged").len > 0

  test "t_a_pinned_commit_absent_from_the_checkout_refuses_and_names_a_fetch":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      var s = startPinnedAtNewest("unprovable-refused")
      defer: removeDir(s.fx.scratch)
      let fx = s.fx
      # Somebody else publishes a newer lib-b and a lock pinning it; this
      # workspace's lib-b never fetches it.
      var origin = ""
      for (name, path) in fx.origins:
        if name == "lib-b": origin = path
      let side = fx.scratch / "side-lib-b"
      discard requireCmd(q(fx.gitBin) & " clone -q " & q(fileUrl(origin)) &
        " " & q(side))
      discard fx.git(side, "config user.email tester@example.invalid")
      discard fx.git(side, "config user.name \"Lock Tester\"")
      discard fx.git(side, "config commit.gpgsign false")
      writeFile(side / "elsewhere.txt", "published from another clone\n")
      discard fx.git(side, "add elsewhere.txt")
      discard fx.git(side, "commit -q -m elsewhere")
      discard fx.git(side, "push -q origin HEAD:main")
      let absent = fx.headOf(side)
      let lock = readFile(fx.app / "repro.lock")
      let entry = depEntry(lock, "../lib-b")
      writeFile(fx.app / "repro.lock",
        lock.replace(entry, entry.replace(s.pinned, absent)))
      fx.removeHook()
      discard fx.git(fx.app, "add repro.lock")
      discard fx.git(fx.app, "commit -q -m " & q("a colleague's lock"))
      fx.installHook()
      check runCmd(q(fx.gitBin) & " -C " & q(s.libB) & " cat-file -e " &
        absent & "^{commit}").code != 0

      let headBefore = fx.headOf(fx.app)
      let c = fx.tryCommit("work-without-fetching-lib-b")
      checkpoint(c.output)
      check c.code != 0
      check fx.headOf(fx.app) == headBefore
      check pinOf(readFile(fx.app / "repro.lock"), "../lib-b") == absent
      let headline = lineWith(c.output, "repro.lock sibling 'lib-b'",
        "pinned commit " & absent & " not present in")
      checkpoint("headline: " & headline)
      check headline.len > 0
      let fetchLine = lineWith(c.output, "fetch it so the direction can be " &
        "decided")
      let fetch = backticked(fetchLine)
      check fetch.len == 1
      if fetch.len == 1:
        check "fetch" in fetch[0]
        let ran = fx.runNamed(fetch[0], fx.app)
        checkpoint("ran `" & fetch[0] & "`:\n" & ran.output)
        check ran.code == 0
        check runCmd(q(fx.gitBin) & " -C " & q(s.libB) & " cat-file -e " &
          absent & "^{commit}").code == 0
        # Now the direction is decidable: behind by one, still refused.
        let again = runCmd(fx.gitCmd(fx.app, "commit -m " &
          q("work-after-fetching-lib-b")))
        checkpoint(again.output)
        check again.code != 0
        check lineWith(again.output, "repro.lock sibling 'lib-b'",
          "behind by 1 commit(s)").len > 0

  test "t_a_rebase_stopped_for_editing_stands_down":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      var s = startPinnedAtNewest("rebase-stand-down")
      defer: removeDir(s.fx.scratch)
      let fx = s.fx
      check fx.tryCommit("history-one").code == 0
      check fx.tryCommit("history-two").code == 0
      let lockBefore = readFile(fx.app / "repro.lock")
      discard s.rewindLibB(2)
      let stopped = runCmd("GIT_SEQUENCE_EDITOR=" &
        q("sed -i 1s/^pick/edit/") & " " & fx.gitCmd(fx.app,
        "rebase -i HEAD~2"), fx.app)
      checkpoint(stopped.output)
      check stopped.code == 0
      check dirExists(fx.app / ".git" / "rebase-merge")
      writeFile(fx.app / "during-rebase.txt", "edited mid-rebase\n")
      discard fx.git(fx.app, "add during-rebase.txt")
      let amended = runCmd(fx.gitCmd(fx.app, "commit -q --amend --no-edit"))
      checkpoint(amended.output)
      checkpoint("pre-commit log:\n" & fx.preCommitLog())
      check amended.code == 0
      check "REFUSED" notin amended.output
      check readFile(fx.app / "repro.lock") == lockBefore
      check lineWith(fx.preCommitLog(), "repro-lock",
        "skipped-git-operation-in-progress", "rebase-merge").len > 0
      let finished = runCmd("GIT_EDITOR=true " & fx.gitCmd(fx.app,
        "rebase --continue"), fx.app)
      checkpoint(finished.output)
      check finished.code == 0
      check readFile(fx.app / "repro.lock") == lockBefore

  test "t_a_conflicted_cherry_pick_stands_down":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      var s = startPinnedAtNewest("cherry-pick-stand-down")
      defer: removeDir(s.fx.scratch)
      let fx = s.fx
      discard fx.git(fx.app, "checkout -q -b side")
      writeFile(fx.app / "contested.txt", "side\n")
      discard fx.git(fx.app, "add contested.txt")
      check runCmd(fx.gitCmd(fx.app, "commit -q -m side")).code == 0
      discard fx.git(fx.app, "checkout -q main")
      writeFile(fx.app / "contested.txt", "main\n")
      discard fx.git(fx.app, "add contested.txt")
      check runCmd(fx.gitCmd(fx.app, "commit -q -m main")).code == 0
      let lockBefore = readFile(fx.app / "repro.lock")
      discard s.rewindLibB(2)
      let picked = runCmd(fx.gitCmd(fx.app, "cherry-pick side"))
      checkpoint(picked.output)
      check picked.code != 0
      check fileExists(fx.app / ".git" / "CHERRY_PICK_HEAD")
      writeFile(fx.app / "contested.txt", "resolved\n")
      discard fx.git(fx.app, "add contested.txt")
      let concluded = runCmd(fx.gitCmd(fx.app, "commit -q --no-edit"))
      checkpoint(concluded.output)
      checkpoint("pre-commit log:\n" & fx.preCommitLog())
      check concluded.code == 0
      check "REFUSED" notin concluded.output
      check not fileExists(fx.app / ".git" / "CHERRY_PICK_HEAD")
      check readFile(fx.app / "repro.lock") == lockBefore
      check lineWith(fx.preCommitLog(), "repro-lock",
        "skipped-git-operation-in-progress", "CHERRY_PICK_HEAD").len > 0

  test "t_commit_amend_is_idempotent":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      var s = startPinnedAtNewest("amend-idempotent")
      defer: removeDir(s.fx.scratch)
      let fx = s.fx
      # Over unmoved siblings: byte- and mtime-identical.
      let lockPath = fx.app / "repro.lock"
      let before = readFile(lockPath)
      sleep(1100)
      let mtime = getLastModificationTime(lockPath)
      let amended = runCmd(fx.gitCmd(fx.app, "commit -q --amend --no-edit"))
      checkpoint(amended.output)
      check amended.code == 0
      check readFile(lockPath) == before
      check getLastModificationTime(lockPath) == mtime
      check fx.git(fx.app, "show HEAD:repro.lock") == before
      # After an allowed regression, the amend needs no variable: the pin now
      # IS the observed revision, so nothing regresses and nothing is announced.
      let observed = s.rewindLibB(1)
      let allowed = fx.tryCommit("deliberate-downgrade", allow = "lib-b")
      checkpoint(allowed.output)
      check allowed.code == 0
      check pinOf(fx.git(fx.app, "show HEAD:repro.lock"), "../lib-b") ==
        observed
      let downgraded = readFile(lockPath)
      let again = runCmd(fx.gitCmd(fx.app, "commit -q --amend --no-edit"))
      checkpoint(again.output)
      check again.code == 0
      check "allowed pin regression" notin again.output
      check "REFUSED" notin again.output
      check readFile(lockPath) == downgraded

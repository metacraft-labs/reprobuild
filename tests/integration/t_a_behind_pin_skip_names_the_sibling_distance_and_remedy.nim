## NF-2 — **the behind-pin notice names the sibling, the distance and remedies
## that actually run and actually work.**
##
## Spec: Nix-Flake-Coexistence.md §3.2 ("Rule, at commit": the hook withholds
## the input — its node committed byte-identical — unless the committer names
## it in `REPRO_ALLOW_PIN_REGRESSION`, and the withholding notice names the
## sibling, the distance and the reconciling command) and
## Unified-Locking-And-Hooks.md §13.3 ("What the hook prints for a kept pin":
## the sibling, the relation and its distance, the pinned and observed
## revisions, the forward command and
## `REPRO_ALLOW_PIN_REGRESSION=<sibling> git commit --amend --no-edit`).
##
## ## Why the message needs a case of its own
##
## `t_a_behind_pin_sibling_is_not_recorded_as_the_new_pin` asserts that the
## pin was kept and nothing was written. That is satisfied equally by a notice
## that tells the operator what to do and by one that only says "skipped" —
## and a notice nobody can act on leaves a stale checkout unexplained. So the
## CONTENT is asserted here, and not by matching a pattern: every command the
## notice quotes is lifted out of the text, parsed as a shell command, RUN from
## the repository the message was printed in, and checked to have done what it
## was named for.
##
## That rule was broken once by a message this case inherits from. NF-3's first
## behind-pin remedy read
##
##     `git -C <dir> merge --ff-only <sha>  (or, to record the downgrade
##      instead: repro flake refresh-lock --flake=… --workspace-root=…)`
##
## — one command and a parenthesised aside inside ONE pair of backticks, which
## pastes as `bash: syntax error near unexpected token '('`.
##
## ## What is asserted
##
##   1. the commit is made, the lock untouched, and the notice names the
##      INPUT and the NUMERIC distance (`3 commit(s) BEHIND`) with both
##      revisions;
##   2. every backticked chunk is ONE pasteable line — a single physical line
##      that `bash -n` accepts, with no parenthesised aside;
##   3. the DELIBERATE course is truthful: the printed
##      `REPRO_ALLOW_PIN_REGRESSION=… git commit --amend --no-edit`, run
##      exactly as printed in the repository, records the downgrade in the
##      commit the notice was printed for and announces it;
##   4. the FIRST remedy brings the checkout forward: run as printed it exits 0
##      and the sibling ends AT the pinned revision;
##   5. …after which the hook proceeds, touching nothing and withholding
##      nothing. The remedy resolved the thing it was named for rather than
##      leaving the operator to loop.
##
## ## Mutations
##
##   * drop the distance from `flakeRowSentence` ⇒ RED on (1);
##   * fold a remedy into another's backticks as a parenthesised aside ⇒ RED on
##     (2);
##   * print the variable without the input's name ⇒ RED on (3): the amended
##     commit keeps the pin again and announces no regression;
##   * print a plain `git commit` as the course ⇒ RED on (3): with nothing
##     staged git reports "nothing to commit" and records nothing.
##
## Test-double policy: NO mocks, doubles or fakes. See the headers of
## `nf2_flake_lock_fixture.nim` and `nf3_override_state_fixture.nim`.

import std/[os, osproc, strutils, unittest]

import nf3_override_state_fixture

proc lineWith(text: string; needles: varargs[string]): string =
  for line in text.splitLines():
    var all = true
    for n in needles:
      if n notin line:
        all = false
        break
    if all: return line
  ""

suite "NF-2: a behind-pin notice names the sibling, distance and remedies":

  test "t_a_behind_pin_skip_names_the_sibling_distance_and_remedy":
    const caseName = "t_a_behind_pin_skip_names_the_sibling_distance_and_remedy"
    if not nf2Prerequisites(caseName):
      skip()
    else:
      let shell = findExe("bash")
      if shell.len == 0:
        echo "SKIPPED (loudly): " & caseName & " needs `bash` on PATH to " &
          "check that the printed commands parse as shell commands; " &
          "bash=MISSING"
        skip()
      else:
        let fx = setupNf2Fixture("behind-remedy")
        defer: removeDir(fx.scratch)
        isolateNf2Config(fx)
        defer: releaseNf2Config()

        # The pin names a PUBLISHED revision, as every recorded pin does
        # (Nix-Flake-Coexistence.md §4: only published revisions are
        # recorded): the deliberate downgrade below re-reads the pinned
        # source to compare dependency locks, and an unfetchable one is
        # withheld, not recorded.
        let gammaPinned = advancePublishedSibling(fx, "gamma", 3)
        let gammaCheckout = rewindSibling(fx, "gamma", 3)
        check gammaCheckout == fx.seedSha[2]
        setFlakePins(fx, fx.seedSha[0], fx.seedSha[1], gammaPinned)
        commitLockAndPublish(fx, "a lock pinned three ahead of gamma")

        let before = readFile(lockPath(fx))
        let headBefore = headOf(fx, fx.app)

        let committed = tryCommitInApp(fx, "work made against a stale gamma")
        checkpoint("commit output:\n" & committed.output)
        check committed.code == 0
        check committed.head != headBefore
        check readFile(lockPath(fx)) == before
        check lockInCommit(fx) == before
        let headAfter = committed.head

        # ---- (1) the input, the DISTANCE and both revisions -------------
        let headline = lineWith(committed.output,
          "flake.lock NOT refreshed for input 'gamma-src'",
          "3 commit(s) BEHIND")
        checkpoint("headline: " & headline)
        check headline.len > 0
        check headline.contains(gammaPinned[0 ..< 12])
        check headline.contains(gammaCheckout[0 ..< 12])

        # ---- (2) every quoted chunk is ONE pasteable line ---------------
        let commands = backtickedCommands(headline)
        checkpoint("commands: " & $commands)
        check commands.len == 2
        for cmd in backtickedCommands(committed.output):
          check cmd.splitLines().len == 1
          check not cmd.contains("(")
          let parsed = execCmdEx(q(shell) & " -n -c " & q(cmd))
          checkpoint("bash -n `" & cmd & "` -> " & $parsed.exitCode & " " &
            parsed.output)
          check parsed.exitCode == 0

        if commands.len == 2:
          let forward = commands[0]
          let deliberate = commands[1]
          check "merge --ff-only" in forward
          check deliberate ==
            "REPRO_ALLOW_PIN_REGRESSION=gamma-src git commit --amend --no-edit"
          # ---- (3) the DELIBERATE course commits the downgrade ----------
          # Run exactly as printed: it amends the commit just made.
          let alt = run(deliberate, cwd = fx.app)
          checkpoint("ran `" & deliberate & "` -> " & $alt.code & "\n" &
            alt.output)
          check alt.code == 0
          check gitIn(fx, fx.app, "rev-parse HEAD~1").strip() == headBefore
          let downgraded = lockInCommit(fx)
          check nodeText(downgraded, "gamma-src").contains(gammaCheckout)
          check not nodeText(downgraded, "gamma-src").contains(gammaPinned)
          check alt.output.contains("allowed pin regression")
          # Back to the kept state, so the remaining remedy runs against the
          # situation the notice was printed about.
          discard gitIn(fx, fx.app, "reset -q --hard " & headAfter)
          check readFile(lockPath(fx)) == before

          # ---- (4) the FIRST remedy brings the checkout forward ---------
          let res = runNamedCommand(fx, forward, fx.app)
          checkpoint("ran `" & forward & "` -> " & $res.code & "\n" &
            res.output)
          check res.code == 0
          check headOf(fx, siblingDir(fx, "gamma")) == gammaPinned

          # ---- (5) …and the hook proceeds, touching nothing -------------
          let again = firePreCommitHook(fx)
          checkpoint("re-fired hook -> " & $again.code & "\n" & again.output)
          check again.code == 0
          check not again.output.contains("REFUSED")
          check not again.output.contains("NOT refreshed")
          check readFile(lockPath(fx)) == before

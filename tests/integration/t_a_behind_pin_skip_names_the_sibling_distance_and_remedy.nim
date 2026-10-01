## NF-2 — **the behind-pin refusal names the sibling, the distance and remedies
## that actually run and actually work.**
##
## Spec: Nix-Flake-Coexistence.md §3.2 ("Rule, at commit": the refresh refuses
## the commit unless the committer names the input in
## `REPRO_ALLOW_PIN_REGRESSION`) and Unified-Locking-And-Hooks.md §13.3 ("What
## the refusal prints": the sibling, the relation and its distance, the pinned
## and observed revisions, then two courses of action, each with a command that
## runs where the message is printed).
##
## ## Why the message needs a case of its own
##
## `t_a_behind_pin_sibling_is_not_recorded_as_the_new_pin` asserts that the
## commit was refused and nothing was written. That is satisfied equally by a
## refusal that tells the operator what to do and by one that only says no —
## and a refusal nobody can act on is how a hook gets uninstalled. So the
## CONTENT is asserted here, and not by matching a pattern: every command the
## refusal quotes is lifted out of the text, parsed as a shell command, RUN from
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
##   1. the refusal names the INPUT and the NUMERIC distance
##      (`behind by 3 commit(s)`) with both revisions;
##   2. every backticked chunk is ONE pasteable line — a single physical line
##      that `bash -n` accepts, with no parenthesised aside;
##   3. the DELIBERATE course is truthful: the printed
##      `REPRO_ALLOW_PIN_REGRESSION=… git commit`, run in the repository with a
##      message appended, commits the downgrade and announces it;
##   4. the named `git log` lists exactly the three commits the lock would drop;
##   5. the FIRST remedy brings the checkout forward: run as printed it exits 0
##      and the sibling ends AT the pinned revision;
##   6. …after which the hook proceeds, touching nothing. The remedy resolved
##      the thing it was named for rather than leaving the operator to loop.
##
## ## Mutations
##
##   * drop the distance from `pinRegressionDistance` ⇒ RED on (1);
##   * fold a remedy into another's backticks as a parenthesised aside ⇒ RED on
##     (2);
##   * print the variable without the sibling's name ⇒ RED on (3): the re-run
##     commit is refused again.
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

suite "NF-2: a behind-pin refusal names the sibling, distance and remedies":

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

        let gammaPinned = advanceSibling(fx, "gamma", 3)
        let gammaCheckout = rewindSibling(fx, "gamma", 3)
        check gammaCheckout == fx.seedSha[2]
        setFlakePins(fx, fx.seedSha[0], fx.seedSha[1], gammaPinned)
        commitLockAndPublish(fx, "a lock pinned three ahead of gamma")

        let before = readFile(lockPath(fx))
        let headBefore = headOf(fx, fx.app)

        let committed = tryCommitInApp(fx, "work made against a stale gamma")
        checkpoint("commit output:\n" & committed.output)
        check committed.code != 0
        check committed.head == headBefore
        check readFile(lockPath(fx)) == before

        # ---- (1) the input, the DISTANCE and both revisions -------------
        let headline = lineWith(committed.output,
          "flake.lock input 'gamma-src'", "behind by 3 commit(s)")
        checkpoint("headline: " & headline)
        check headline.len > 0
        check headline.contains(gammaPinned)
        check headline.contains(gammaCheckout)

        # ---- (2) every quoted chunk is ONE pasteable line ---------------
        let commands = backtickedCommands(committed.output)
        checkpoint("commands: " & $commands)
        check commands.len >= 4
        for cmd in commands:
          check cmd.splitLines().len == 1
          check not cmd.contains("(")
          let parsed = execCmdEx(q(shell) & " -n -c " & q(cmd))
          checkpoint("bash -n `" & cmd & "` -> " & $parsed.exitCode & " " &
            parsed.output)
          check parsed.exitCode == 0

        let forward = backtickedCommands(lineWith(committed.output,
          "bring the checkout forward"))
        let dropped = backtickedCommands(lineWith(committed.output,
          "would drop from the published lock"))
        let deliberate = backtickedCommands(lineWith(committed.output,
          "REPRO_ALLOW_PIN_REGRESSION=gamma-src git commit"))
        check forward.len == 1
        check dropped.len == 1
        check deliberate.len == 1
        if forward.len == 1 and dropped.len == 1 and deliberate.len == 1:
          # ---- (3) the DELIBERATE course commits the downgrade ----------
          let alt = run(deliberate[0] & " -q -m " &
            q("deliberately older gamma"), cwd = fx.app)
          checkpoint("ran `" & deliberate[0] & "` -> " & $alt.code & "\n" &
            alt.output)
          check alt.code == 0
          let downgraded = lockInCommit(fx)
          check nodeText(downgraded, "gamma-src").contains(gammaCheckout)
          check not nodeText(downgraded, "gamma-src").contains(gammaPinned)
          check alt.output.contains("allowed pin regression")
          # Back to the refused state, so the remaining remedies run against
          # the situation the refusal was printed about.
          discard gitIn(fx, fx.app, "reset -q --hard " & headBefore)
          check readFile(lockPath(fx)) == before

          # ---- (4) the named log lists what the lock would drop ---------
          let log = runNamedCommand(fx, dropped[0], fx.app)
          checkpoint("ran `" & dropped[0] & "` -> " & $log.code & "\n" &
            log.output)
          check log.code == 0
          check log.output.strip().splitLines().len == 3

          # ---- (5) the FIRST remedy brings the checkout forward ---------
          let res = runNamedCommand(fx, forward[0], fx.app)
          checkpoint("ran `" & forward[0] & "` -> " & $res.code & "\n" &
            res.output)
          check res.code == 0
          check headOf(fx, siblingDir(fx, "gamma")) == gammaPinned

          # ---- (6) …and the hook proceeds, touching nothing -------------
          let again = firePreCommitHook(fx)
          checkpoint("re-fired hook -> " & $again.code & "\n" & again.output)
          check again.code == 0
          check not again.output.contains("REFUSED")
          check readFile(lockPath(fx)) == before

## NF-2 — **the behind-pin skip names the sibling, the distance and a remedy
## that actually runs and actually works.**
##
## Spec: Nix-Flake-Coexistence.md §3.2 ("reported ambiently, naming the sibling,
## the distance, and the command that reconciles it") and
## Unified-Locking-And-Hooks.md §"the named command must RUN where the message
## is printed".
##
## ## Why the message needs a case of its own
##
## `t_a_behind_pin_sibling_is_not_recorded_as_the_new_pin` asserts that nothing
## was written. That assertion is satisfied equally by a hook that skipped and
## warned and by one that silently did nothing — and "silently did nothing while
## looking like it worked" is the failure mode this whole campaign exists to
## remove. So the CONTENT of the notice is asserted here, and not by matching a
## pattern: every command the notice quotes is lifted out of the text, parsed as
## a shell command, RUN from the directory the message itself names, and checked
## to have moved the state it was named for.
##
## That rule has already been broken once by a message that quotes it. NF-3's
## first behind-pin remedy read
##
##     `git -C <dir> merge --ff-only <sha>  (or, to record the downgrade
##      instead: repro flake refresh-lock --flake=… --workspace-root=…)`
##
## — one command and a parenthesised aside inside ONE pair of backticks, which
## pastes as `bash: syntax error near unexpected token '('`. This case inherits
## NF-3's fix rather than growing a second remedy generator: the strings under
## test here are produced by `flakeReconcileCommand` /
## `flakeReconcileAlternative`, the same two procs the pre-push refusal uses.
##
## ## What is asserted
##
##   1. the notice names the SIBLING (`gamma`) and the NUMERIC distance
##      (`3 commit(s) BEHIND`). A notice that says "a sibling is behind" without
##      saying which or by how much cannot be acted on;
##   2. every backticked chunk is ONE pasteable line — a single physical line
##      that `bash -n` accepts, which is exactly the check a human paste
##      performs;
##   3. the ALTERNATIVE remedy is truthful: run from the named directory, it
##      really does record the downgrade the notice says it records. This is the
##      half a message can satisfy in prose and fail in a terminal, and it is a
##      live risk here precisely because the default refresh now declines to
##      record a downgrade — so the alternative had to become an explicit
##      opt-in, and a message still naming the old spelling would be a lie;
##   4. the FIRST remedy reconciles: run from the named directory it exits 0 and
##      the sibling ends AT the pinned revision;
##   5. …and the hook then stops warning, without touching the lock. The remedy
##      resolved the thing it was named for rather than leaving the operator to
##      loop.
##
## ## Mutations
##
##   * drop the distance from the sentence (`$row.behindBy`) ⇒ RED on (1);
##   * fold the alternative back inside the first pair of backticks as a
##     parenthesised aside ⇒ RED on (2) (`bash -n` rejects it, and it is no
##     longer one line's worth of command) and RED on (4) (the lifted string is
##     not runnable);
##   * emit the alternative WITHOUT its explicit opt-in flag ⇒ RED on (3): the
##     command runs, exits 0, and records nothing.
##
## Test-double policy: NO mocks, doubles or fakes. See the headers of
## `nf2_flake_lock_fixture.nim` and `nf3_override_state_fixture.nim`.

import std/[os, osproc, strutils, unittest]

import nf3_override_state_fixture

proc behindNotice(text: string): string =
  ## The one line of the hook's output that announces the withheld refresh.
  ## Scoped to the line rather than taken as the whole stream, because
  ## `backtickedCommands` over the whole stream would happily pick up a command
  ## quoted by some unrelated diagnostic and the case would then assert about a
  ## string the withholding never produced.
  for line in text.splitLines():
    if line.contains("NOT refreshed") and line.contains("gamma-src"):
      return line
  ""

suite "NF-2: a behind-pin skip names the sibling, distance and remedy":

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

        let committed = tryCommitInApp(fx, "work made against a stale gamma")
        checkpoint("commit output:\n" & committed.output)
        check committed.code == 0
        check readFile(lockPath(fx)) == before

        let notice = behindNotice(committed.output)
        checkpoint("notice: " & notice)
        check notice.len > 0
        if notice.len == 0:
          checkpoint("pre-commit log:\n" & preCommitLog(fx))
        else:
          # ---- (1) the sibling, and the DISTANCE ------------------------
          check notice.contains("gamma")
          check notice.contains("3 commit(s) BEHIND")

          # ---- (2) every quoted chunk is ONE pasteable line -------------
          let namedDir = directoryNamedForRunning(notice)
          checkpoint("named directory: " & namedDir)
          check namedDir.len > 0
          check dirExists(namedDir)

          let commands = backtickedCommands(notice)
          checkpoint("commands: " & $commands)
          check commands.len == 2
          for cmd in commands:
            check cmd.splitLines().len == 1
            check not cmd.contains("(")
            let parsed = execCmdEx(q(shell) & " -n -c " & q(cmd))
            checkpoint("bash -n `" & cmd & "` -> " & $parsed.exitCode & " " &
              parsed.output)
            check parsed.exitCode == 0

          if commands.len == 2:
            # ---- (3) the ALTERNATIVE really records the downgrade -------
            let alt = runNamedCommand(fx, commands[1], namedDir)
            checkpoint("ran `" & commands[1] & "` in " & namedDir & " -> " &
              $alt.code & "\n" & alt.output)
            check alt.code == 0
            let downgraded = readFile(lockPath(fx))
            check nodeText(downgraded, "gamma-src").contains(gammaCheckout)
            check downgraded != before
            # Put the lock back, so (4) and (5) run against the state the
            # notice was printed about rather than against the downgrade this
            # step deliberately filed.
            discard gitIn(fx, fx.app, "checkout -- flake.lock")
            check readFile(lockPath(fx)) == before

            # ---- (4) the FIRST remedy reconciles -----------------------
            let res = runNamedCommand(fx, commands[0], namedDir)
            checkpoint("ran `" & commands[0] & "` in " & namedDir & " -> " &
              $res.code & "\n" & res.output)
            check res.code == 0
            check headOf(fx, siblingDir(fx, "gamma")) == gammaPinned

            # ---- (5) …and the hook stops warning, touching nothing -----
            let again = firePreCommitHook(fx)
            checkpoint("re-fired hook -> " & $again.code & "\n" & again.output)
            check again.code == 0
            check behindNotice(again.output).len == 0
            check readFile(lockPath(fx)) == before
            let logLine = lastFlakeLogLine(fx)
            checkpoint("last flake-lock log line: " & logLine)
            check not logLine.contains("BEHIND")

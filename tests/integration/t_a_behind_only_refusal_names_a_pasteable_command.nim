## NF-3 — **every command a refusal prints can be pasted into a shell.**
##
## Spec: Unified-Locking-And-Hooks.md §"the named command must RUN where the
## message is printed"; Nix-Flake-Coexistence.md §4 ("names a command that runs
## from where the message is printed") and §3.2 (a behind-pin sibling is named
## with "the command that reconciles it").
##
## ## Why a case of its own, and why BEHIND
##
## `t_push_refuses_when_the_lock_disagrees_with_the_siblings` constructs an
## AHEAD offender, whose remedy is a single `repro flake refresh-lock …`. The
## BEHIND branch emits a different remedy, and it was never reached by any
## case: that test's execution loop skips any chunk not starting with `repro `,
## so a behind remedy could have been anything at all and stayed green.
##
## It was not anything at all. It was:
##
##     `git -C <dir> merge --ff-only <sha>  (or, to record the downgrade
##      instead: repro flake refresh-lock --flake=… --workspace-root=…)`
##
## — one command and a parenthesised alternative inside ONE pair of backticks.
## Pasted from the directory the message names, that is
## `bash: syntax error near unexpected token '('`. The rule the headline test
## exists to enforce was broken by the very message that quotes it.
##
## ## What is asserted
##
##   1. the gate refuses on a BEHIND-only offender (the direction reached by no
##      other gate case) with a `flake_lock_stale` failure naming the distance;
##   2. **every** backticked chunk of the refusal is a syntactically valid
##      shell command line — asserted by handing each one to `bash -n`, which
##      is the exact check a human paste performs and the one the old message
##      failed;
##   3. the FIRST such command, run in the directory the message names, exits 0
##      and actually reconciles the state: the sibling ends at the pinned
##      revision;
##   4. and the gate then stops refusing — the remedy resolved the thing it was
##      named for, rather than exiting 0 and leaving the operator to loop.
##
## Assert (3)+(4) together are the rule; (2) is the half that a message can
## satisfy in prose and fail in a terminal.
##
## ## Mutation
##
## Restore the parenthesised alternative into the single backticked chunk
## ⇒ RED on (2), and RED on (3) because the lifted "command" is not runnable.
##
## Test-double policy: NO mocks, doubles or fakes. See the headers of
## `nf2_flake_lock_fixture.nim` and `nf3_override_state_fixture.nim`.

import std/[json, os, osproc, strutils, unittest]

import nf3_override_state_fixture

suite "NF-3: a behind-only refusal names a pasteable command":

  test "t_a_behind_only_refusal_names_a_pasteable_command":
    const caseName = "t_a_behind_only_refusal_names_a_pasteable_command"
    if not nf3Prerequisites(caseName):
      skip()
    else:
      let shell = findExe("bash")
      if shell.len == 0:
        echo "SKIPPED (loudly): " & caseName & " needs `bash` on PATH to " &
          "check that the printed commands parse as shell commands; bash=MISSING"
        skip()
      else:
        let fx = setupNf2Fixture("behind-gate")
        defer: removeDir(fx.scratch)
        isolateNf2Config(fx)
        defer: releaseNf2Config()
        removePreCommitDispatch(fx)

        # gamma's history gains three revisions, the lock records the newest,
        # and the CHECKOUT is left where it was — 3 commits BEHIND its pin, and
        # the ONLY row that disagrees.
        let gammaPinned = advanceSibling(fx, "gamma", 3)
        let gammaCheckout = rewindSibling(fx, "gamma", 3)
        check gammaCheckout == fx.seedSha[2]
        setFlakePins(fx, fx.seedSha[0], fx.seedSha[1], gammaPinned)
        publishAll(fx)
        commitLockAndPublish(fx, "a lock pinned ahead of the gamma checkout")

        # ---- (1) the gate refuses, on the behind direction -----------------
        let gate = gatePrePush(fx)
        checkpoint("gate output:\n" & gate.output)
        check gate.code == 2
        check hasGateFailure(gate.report, "flake_lock_stale")
        if not hasGateFailure(gate.report, "flake_lock_stale"):
          checkpoint("report:\n" & pretty(gate.report, indent = 2))
        else:
          let failure = gateFailureOf(gate.report, "flake_lock_stale")
          let evidence = failure["evidence"].getStr()
          let remediation = failure["remediation"].getStr()
          checkpoint("evidence: " & evidence)
          checkpoint("remediation: " & remediation)
          check evidence.contains("input=gamma-src")
          check evidence.contains("relation=behind")
          check evidence.contains("behind=3")
          check not evidence.contains("input=alpha-src")
          check not evidence.contains("input=beta-src")
          check remediation.contains("3 commit(s) BEHIND")

          let namedDir = directoryNamedForRunning(remediation)
          checkpoint("named directory: " & namedDir)
          check namedDir.len > 0
          check dirExists(namedDir)

          let commands = backtickedCommands(remediation)
          checkpoint("commands: " & $commands)
          check commands.len > 0

          # ---- (2) each one PARSES as a shell command ---------------------
          # `bash -n` reads the command and stops before running it, so this
          # asks exactly the question a paste asks and nothing else.
          for cmd in commands:
            let parsed = execCmdEx(q(shell) & " -n -c " & q(cmd))
            checkpoint("bash -n `" & cmd & "` -> " & $parsed.exitCode &
              " " & parsed.output)
            check parsed.exitCode == 0

          # ---- (3) the first one RUNS there, and reconciles ---------------
          let res = runNamedCommand(fx, commands[0], namedDir)
          checkpoint("ran `" & commands[0] & "` in " & namedDir & " -> " &
            $res.code & "\n" & res.output)
          check res.code == 0
          check headOf(fx, siblingDir(fx, "gamma")) == gammaPinned

          # ---- (4) …and the gate stops refusing ---------------------------
          publishAll(fx)
          let again = gatePrePush(fx)
          checkpoint("second gate output:\n" & again.output)
          check not hasGateFailure(again.report, "flake_lock_stale")

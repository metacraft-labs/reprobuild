## NF-3 — **the pre-push gate and NF-2's refresh must agree about an
## unpublished sibling.**
##
## Spec: Nix-Flake-Coexistence.md §3.1 (the gate refuses an ahead sibling at the
## publication boundary), Workspace-And-Develop-Mode.md §"Reproducibility And
## `repro check`" ("dirty **or only locally committed**"), and
## Unified-Locking-And-Hooks.md §"the named command must RUN where the message
## is printed".
##
## ## The failure mode this exists to prevent
##
## NF-2 now declines to record a sibling revision that exists only in the local
## checkout. The pre-push gate computes its verdict from the same rows, and the
## remedy it prints for an AHEAD offender is, by default, "run the refresh".
## Left alone, that produces a loop with no exit: the gate refuses the push and
## names the refresh; the refresh declines to record the unpublished revision
## and changes nothing; the gate refuses again with the same command. A refusal
## whose remedy cannot work is the exact defect this campaign has already
## recorded once, when NF-2 wrote a downgrade that NF-3 then rejected — one half
## writing what the other half refuses.
##
## So the gate annotates the same publication axis and orders the commands: the
## PUSH that makes the revision obtainable comes first, and the refresh that
## records it second.
##
## ## Why the sibling is `gamma` and not `alpha`
##
## The gate's stage 2 already refuses an unpublished HEAD anywhere in the
## PUSHED REPO'S DEVELOP-SET CLOSURE, and it returns there — so for a closure
## member the flake stage is never reached and the loop above cannot form. The
## reachable shape is a substituted flake input that is NOT a closure member,
## which is `gamma` in this fixture (`app`'s lock entry declares
## `depends = "alpha,beta,epsilon"`). Choosing it is what makes this case test
## the stage it claims to test rather than passing on stage 2's refusal — and
## it is also the honest statement of the exposure: the flake stage is the only
## thing in the system that looks at such a sibling at all.
##
## ## What is asserted
##
##   1. the sibling really is unpublished, asked with git's own predicate;
##   2. the gate REFUSES (exit 2) with a `flake_lock_stale` failure, and its
##      evidence says so explicitly (`unpublished=true`) rather than describing
##      the row as ordinary drift;
##   3. the remediation names BOTH commands, push first, each a single pasteable
##      line;
##   4. running them IN THE PRINTED ORDER, from the directory the message names,
##      really clears the state: the revision becomes published, the lock
##      records it, and the gate stops refusing on the flake stage;
##   5. …and running the refresh ALONE first would not have — the same
##      assertion the ordering exists for, made by running it and checking the
##      lock did not move.
##
## ## Mutation
##
## Restore the gate to quoting only each row's FIRST command
## (`flakeReconcileCommand` instead of `flakeReconcileCommands`) ⇒ RED on (3)
## and (4): only the push is printed, the lock is never refreshed, and the
## second gate still refuses.
##
## Test-double policy: NO mocks, doubles or fakes. See the headers of
## `nf2_flake_lock_fixture.nim` and `nf3_override_state_fixture.nim`.

import std/[json, os, osproc, strutils, unittest]

import nf3_override_state_fixture

suite "NF-3: a gate refusal over an unpublished sibling names the push first":

  test "t_a_gate_refusal_over_an_unpublished_sibling_names_the_push_first":
    const caseName =
      "t_a_gate_refusal_over_an_unpublished_sibling_names_the_push_first"
    if not nf3Prerequisites(caseName):
      skip()
    else:
      let shell = findExe("bash")
      if shell.len == 0:
        echo "SKIPPED (loudly): " & caseName & " needs `bash` on PATH to " &
          "check that the printed commands parse as shell commands; " &
          "bash=MISSING"
        skip()
      else:
        let fx = setupNf2Fixture("gate-unpublished")
        defer: removeDir(fx.scratch)
        isolateNf2Config(fx)
        defer: releaseNf2Config()

        # The refresh must not repair the arrangement on the way in: the whole
        # point is a COMMITTED lock that disagrees with an unpublished sibling.
        removePreCommitDispatch(fx)
        let gammaHead = advanceSibling(fx, "gamma", 2)
        check gammaHead != fx.seedSha[2]
        publishRepo(fx, fx.app)
        commitLockAndPublish(fx, "work committed against an unpushed gamma")

        # ---- (1) the arrangement is what the case claims ------------------
        check not siblingRevIsPublished(fx, "gamma", gammaHead)

        let lockBefore = readFile(lockPath(fx))
        check lockBefore.contains(fx.seedSha[2])
        check not lockBefore.contains(gammaHead)

        # ---- (2) the gate refuses, and SAYS why ---------------------------
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
          check evidence.contains("relation=ahead")
          check evidence.contains("unpublished=true")

          # ---- (3) both commands, push FIRST, each pasteable --------------
          let namedDir = directoryNamedForRunning(remediation)
          checkpoint("named directory: " & namedDir)
          check namedDir.len > 0
          check dirExists(namedDir)
          let commands = backtickedCommands(remediation)
          checkpoint("commands: " & $commands)
          check commands.len == 2
          for cmd in commands:
            check cmd.splitLines().len == 1
            let parsed = execCmdEx(q(shell) & " -n -c " & q(cmd))
            checkpoint("bash -n `" & cmd & "` -> " & $parsed.exitCode & " " &
              parsed.output)
            check parsed.exitCode == 0
          if commands.len == 2:
            check commands[0].contains(" push ")
            check commands[0].contains(gammaHead)
            check commands[1].contains("refresh-lock")

            # ---- (5) the refresh ALONE would not have cleared it ----------
            # Run second-first, deliberately: this is the ordering claim, and
            # it is only worth making if the other order really fails.
            let premature = runNamedCommand(fx, commands[1], namedDir)
            checkpoint("ran `" & commands[1] & "` FIRST in " & namedDir &
              " -> " & $premature.code & "\n" & premature.output)
            # 3, not 0: the refresh RAN and WITHHELD, so the lock is not correct
            # afterwards and the status says so (`flakeRefreshWithheldExit`).
            # This assertion used to read `== 0`, which made the ordering claim
            # below invisible to anything that reads only the status — a script
            # running the two commands in the wrong order was told the first one
            # had succeeded. The lock comparison on the next line is still the
            # subject; this is now the second, cheaper witness of it.
            check premature.code == 3
            check readFile(lockPath(fx)) == lockBefore

            # ---- (4) in the printed order, they clear it ------------------
            let push = runNamedCommand(fx, commands[0], namedDir)
            checkpoint("ran `" & commands[0] & "` in " & namedDir & " -> " &
              $push.code & "\n" & push.output)
            check push.code == 0
            check siblingRevIsPublished(fx, "gamma", gammaHead)

            let refresh = runNamedCommand(fx, commands[1], namedDir)
            checkpoint("ran `" & commands[1] & "` in " & namedDir & " -> " &
              $refresh.code & "\n" & refresh.output)
            check refresh.code == 0
            let lockAfter = readFile(lockPath(fx))
            check lockAfter.contains(gammaHead)
            check not lockAfter.contains(fx.seedSha[2])

            commitLockAndPublish(fx, "record the published gamma revision")
            let again = gatePrePush(fx)
            checkpoint("second gate output:\n" & again.output)
            check not hasGateFailure(again.report, "flake_lock_stale")

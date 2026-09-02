## NF-3 — **the gate VERIFIES rather than produces, and its refusal names a
## command that RUNS from where the message is printed.**
##
## Spec: Nix-Flake-Coexistence.md §4 ("Pre-push refuses when `flake.lock`'s
## overridden inputs do not match the observable siblings, and names a command
## that runs from where the message is printed") and §3.1 (the failure that
## makes it worth refusing: what you built is not what you published);
## Unified-Locking-And-Hooks.md §13.1 (an IN-TREE lock is written at
## pre-commit and the gate "verifies only"), §13.5 and §"the named command
## must RUN where the message is printed".
##
## ## The starting state, and why it is reachable in the field
##
## After NF-2 this gate should almost never fire, because the `pre-commit`
## hook refreshes `flake.lock` from the observed siblings as part of forming
## the revision. It fires when the commit path was BYPASSED — `--no-verify`, a
## repo whose hooks were never installed, a lock edited by hand, a sibling
## moved after the commit. The fixture reproduces that directly: the hook is
## taken out, a sibling is moved forward, and the stale lock is committed and
## published. Everything else in the workspace is clean and published, so the
## gate's earlier stages pass and this one is what speaks.
##
## ## What is asserted
##
##   1. the gate REFUSES (exit 2) with a `flake_lock_stale` failure;
##   2. the failure NAMES the offender — the sibling repo, the flake input, the
##      pinned revision, the sibling's revision, and the DISTANCE;
##   3. it names a DIRECTORY to run from, and a command;
##   4. **that command, executed with the working directory the message names,
##      succeeds** — this is the half that a message can look right and still
##      fail, and it is the whole subject of the rule being applied;
##   5. after running it, `flake.lock` names the sibling's HEAD;
##   6. and the gate then passes the flake stage.
##
## Assert (4) is why this case runs the command instead of matching it against
## a pattern. A refusal that prints `repro flake refresh-lock --flake=<some
## other directory>` satisfies "names a command" and "names a directory" and is
## still useless to the person reading it.
##
## ## Mutation (from the milestone): print a command that must be run elsewhere
##
## ⇒ RED. Point the emitted `--flake=` at the workspace root instead of the
## repo whose lock is stale: assert (4) still exits 0 (the verb answers
## `not-a-locked-flake` for a directory with no flake) but assert (5) fails —
## the lock was never refreshed — and assert (6) fails, because the gate
## refuses exactly as before. The operator would loop.
##
## Test-double policy: NO mocks, doubles or fakes. See the headers of
## `nf2_flake_lock_fixture.nim` and `nf3_override_state_fixture.nim`.

import std/[json, os, strutils, unittest]

import nf3_override_state_fixture

suite "NF-3: push refuses when the lock disagrees with the siblings":

  test "t_push_refuses_when_the_lock_disagrees_with_the_siblings":
    const caseName = "t_push_refuses_when_the_lock_disagrees_with_the_siblings"
    if not nf3Prerequisites(caseName):
      skip()
    else:
      let fx = setupNf2Fixture("gate-stale")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      # `alpha` moves two commits ahead of the revision `flake.lock` names —
      # §3.1's situation exactly: the dev shell substitutes THIS, the lock
      # still names the older one, and CI would build the older one.
      removePreCommitDispatch(fx)
      let alphaHead = advanceSibling(fx, "alpha", 2)
      check alphaHead != fx.seedSha[0]
      publishAll(fx)
      commitLockAndPublish(fx, "work committed against the newer alpha")

      let lockBefore = readFile(lockPath(fx))
      check lockBefore.contains(fx.seedSha[0])
      check not lockBefore.contains(alphaHead)

      # ---- (1) the gate refuses -------------------------------------------
      let gate = gatePrePush(fx)
      checkpoint("gate output:\n" & gate.output)
      check gate.code == 2
      check hasGateFailure(gate.report, "flake_lock_stale")
      if not hasGateFailure(gate.report, "flake_lock_stale"):
        checkpoint("report:\n" & pretty(gate.report, indent = 2))
      else:
        let failure = gateFailureOf(gate.report, "flake_lock_stale")
        # ---- (2) it names the offender, with the distance ------------------
        let evidence = failure["evidence"].getStr()
        let remediation = failure["remediation"].getStr()
        checkpoint("evidence: " & evidence)
        checkpoint("remediation: " & remediation)
        check evidence.contains("input=alpha-src")
        check evidence.contains("repo=alpha")
        check evidence.contains("relation=ahead")
        check evidence.contains("ahead=2")
        check evidence.contains("pinned=" & fx.seedSha[0])
        check evidence.contains("sibling=" & alphaHead)
        check remediation.contains("'alpha'")
        check remediation.contains("2 commit(s) AHEAD")

        # ---- (3) a directory, and a command --------------------------------
        let namedDir = directoryNamedForRunning(remediation)
        checkpoint("named directory: " & namedDir)
        check namedDir.len > 0
        check dirExists(namedDir)
        let commands = backtickedCommands(remediation)
        check commands.len > 0

        # ---- (4) the command RUNS from the directory the message named -----
        var ran = false
        for cmd in commands:
          if not cmd.startsWith("repro "): continue
          let res = runNamedCommand(fx, cmd, namedDir)
          checkpoint("ran `" & cmd & "` in " & namedDir & " -> " & $res.code &
            "\n" & res.output)
          check res.code == 0
          ran = true
        check ran

        # ---- (5) the lock now names the sibling's HEAD ---------------------
        let lockAfter = readFile(lockPath(fx))
        check lockAfter.contains(alphaHead)
        check not lockAfter.contains(fx.seedSha[0])

        # ---- (6) and the gate stops refusing on the flake stage ------------
        commitLockAndPublish(fx, "record the observed alpha revision")
        let again = gatePrePush(fx)
        checkpoint("second gate output:\n" & again.output)
        check not hasGateFailure(again.report, "flake_lock_stale")

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

  test "opaque history does not hide stale flake pins":
    require nf3Prerequisites("independent pre-push refusals")
    let fx = setupNf2Fixture("independent-refusals")
    defer: removeDir(fx.scratch)
    isolateNf2Config(fx)
    defer: releaseNf2Config()
    removePreCommitDispatch(fx)
    let alphaHead = advanceSibling(fx, "alpha", 2)
    publishAll(fx)
    commitLockAndPublish(fx, "leave stale pins for the gate to diagnose")
    let lockBefore = readFile(lockPath(fx))
    let committedBefore = readFile(fx.ws / "repro.lock")
    let appBefore = headOf(fx, fx.app)
    let refs = fx.scratch / "opaque-refs"
    let missingOld = repeat('a', 40)
    check run(q(fx.gitBin) & " -C " & q(fx.app) &
      " cat-file -e " & missingOld & "^{commit}").code != 0
    writeFile(refs, "refs/heads/main " & appBefore &
      " refs/heads/main " & missingOld & "\n")
    let reportPath = checkReportPath(fx)
    # Receive-pack cannot advertise a nonexistent object, so drive the real
    # managed dispatch boundary with an explicitly unobservable remote tip.
    # Unlike a direct check, dispatch supplies Git's remote identity too.
    let gate = run(q(fx.repro) & " hooks dispatch pre-push --protocol=2" &
      " --repo-root=" & q(fx.app) & " --refs-file=" & q(refs) &
      " -- origin " & q(originUrl(fx, "app")), cwd = fx.app)
    checkpoint(gate.output)
    require fileExists(reportPath)
    let report = parseJson(readFile(reportPath))
    check gate.code == 2
    check hasGateFailure(report, "history-rewrite-unverifiable")
    check hasGateFailure(report, "flake_lock_stale")
    check gate.output.contains("history-rewrite-unverifiable")
    check gate.output.contains("flake_lock_stale")
    if hasGateFailure(report, "flake_lock_stale"):
      let failure = gateFailureOf(report, "flake_lock_stale")
      check failure["evidence"].getStr().contains(alphaHead)
      check failure["remediation"].getStr().len > 0
    check readFile(lockPath(fx)) == lockBefore
    check readFile(fx.ws / "repro.lock") == committedBefore
    check headOf(fx, fx.app) == appBefore

  test "dirty and unpublished siblings do not hide stale flake pins":
    require nf3Prerequisites("independent checkout refusals")
    let fx = setupNf2Fixture("independent-checkouts")
    defer: removeDir(fx.scratch)
    isolateNf2Config(fx)
    defer: releaseNf2Config()
    publishAll(fx)
    removePreCommitDispatch(fx)
    let alphaHead = advanceSibling(fx, "alpha", 1)
    writeFile(siblingDir(fx, "beta") / "dirty.txt", "uncommitted\n")
    let lockBefore = readFile(lockPath(fx))
    let gate = gatePrePush(fx)
    checkpoint(gate.output)
    check gate.code == 2
    for property in ["dirty", "unpublished", "flake_lock_stale"]:
      check hasGateFailure(gate.report, property)
      check gate.output.contains(property)
    check readFile(lockPath(fx)) == lockBefore

    # A revision-pinned recipe that disagrees with its committed lock is
    # independent of dirty/unpublished siblings and stale checkout pins.
    # Alpha becomes exact-pinned below; gamma stays floating and stale.
    discard advanceSibling(fx, "gamma", 1)
    let recipePath = fx.app / "flake.nix"
    let recipeBefore = readFile(recipePath)
    let pinnedRecipe = recipeBefore.replace(originUrl(fx, "alpha") & "?ref=main\";",
      originUrl(fx, "alpha") & "?ref=main&rev=" & alphaHead & "\";")
    require pinnedRecipe != recipeBefore
    writeFile(recipePath, pinnedRecipe)
    discard commitInApp(fx, "pin recipe without refreshing the lock")
    let consistencyGate = gatePrePush(fx)
    checkpoint(consistencyGate.output)
    check consistencyGate.code == 2
    for property in ["recipe_lock_constraint_violated", "dirty", "unpublished",
        "flake_lock_stale"]:
      check hasGateFailure(consistencyGate.report, property)
      check consistencyGate.output.contains(property)
    check readFile(lockPath(fx)) == lockBefore
    writeFile(recipePath, recipeBefore)
    discard commitInApp(fx, "restore floating recipe")

    # The same independence holds within one develop override: a dirty tree
    # does not prevent observing that its HEAD also needs publication.
    writeFile(siblingDir(fx, "alpha") / "dirty.txt", "uncommitted\n")
    writeFile(fx.ws / ".repro" / "develop-overrides.toml",
      "schema = \"reprobuild.workspace.develop-overrides.v1\"\n\n" &
      "[[override]]\npackage = \"alpha\"\nlocal_path = \"alpha\"\n" &
      "state = \"editable\"\ncreated_at = \"2026-07-22T00:00:00Z\"\n")
    let overrideGate = gatePrePush(fx)
    checkpoint(overrideGate.output)
    check overrideGate.code == 2
    for property in ["develop_override_dirty", "develop_override_unpublished",
        "flake_lock_stale"]:
      check hasGateFailure(overrideGate.report, property)
    check readFile(lockPath(fx)) == lockBefore

    # A missing private dependency is a blocker, but cannot hide observations
    # about the checkouts that are present. Epsilon is not a flake input, so
    # withdrawing its source leaves stale alpha pins independently observable.
    let workspaceLock = fx.ws / "repro.lock"
    var lockText = readFile(workspaceLock)
    let epsilonStart = lockText.find("{ name = \"epsilon\"")
    require epsilonStart >= 0
    let epsilonEnd = lockText.find('}', epsilonStart)
    require epsilonEnd > epsilonStart
    let epsilonEntry = lockText[epsilonStart .. epsilonEnd]
    let privateEntry = epsilonEntry.replace("visibility = \"public\"",
      "visibility = \"team\"")
    require privateEntry != epsilonEntry
    lockText = lockText.replace(epsilonEntry, privateEntry)
    writeFile(workspaceLock, lockText)
    removeDir(siblingDir(fx, "epsilon"))
    let privateGate = gatePrePush(fx)
    checkpoint(privateGate.output)
    check privateGate.code == 2
    var privateRefusal = false
    for failure in privateGate.report["failures"]:
      let property = failure["property"].getStr()
      if property == "clone-required" or property.startsWith("evidence-only-"):
        privateRefusal = true
    check privateRefusal
    for property in ["dirty", "unpublished", "flake_lock_stale"]:
      check hasGateFailure(privateGate.report, property)
      check privateGate.output.contains(property)
    check readFile(lockPath(fx)) == lockBefore
    check readFile(workspaceLock) == lockText

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

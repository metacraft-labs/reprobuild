## NF-3 — **a refusal over siblings drifting in different directions clears in
## one pass, when its commands are run in the order printed.**
##
## Spec: Nix-Flake-Coexistence.md §4, "The remedy follows the direction, and it
## clears the refusal in one pass" (every checkout move first, the refresh
## LAST and once; an unfetched row is fetched AND fast-forwarded to its pin);
## Unified-Locking-And-Hooks.md §"the named command must RUN where the message
## is printed".
##
## ## The defect this pins
##
## Issue `2026-10-08-no-reprobuild-push-can-pass-the-pre-push-gate-from-this-
## workspace`: one sibling AHEAD of its pin, one BEHIND, one whose pinned
## revision had never been fetched. The refusal collected each row's remedy in
## offender-row order, so the ahead row listed first put
## `repro flake refresh-lock …` FIRST. Run as printed, the refresh executed
## while the behind row was still behind and withheld it (status 3); and the
## unfetched row's whole remedy was `git fetch --all`, after which it was
## BEHIND and the gate refused a second time. The operator was left either
## looping or reaching for `--record-downgrade` — repinning the lock to OLDER
## revisions than the ones every other consumer builds, which is exactly the
## regression the gate exists to prevent.
##
## Every other refusal case constructs ONE direction, and each of those
## remedies is correct on its own. Only the mix exposes ordering, so this case
## is the mix and nothing else.
##
## ## What is asserted
##
##   1. the gate refuses with `flake_lock_stale`, naming all three rows with
##      their own relations (ahead / behind / unfetched);
##   2. the refresh is named exactly ONCE, and LAST;
##   3. every backticked command, run IN THE PRINTED ORDER from the directory
##      the message names, exits 0;
##   4. afterwards no pin has moved backward: beta's and gamma's pins are what
##      they were, and alpha's is its HEAD — the one forward move the refusal
##      was about;
##   5. with the refreshed lock committed and published, the gate no longer
##      refuses on `flake_lock_stale`.
##
## ## Mutation
##
## Collect the remedies in row order again (the unfixed behaviour) ⇒ RED on
## (2) and on (3): the refresh runs first and exits 3. Drop the fast-forward
## from the unfetched row's remedy ⇒ RED on (5): gamma is left BEHIND its pin
## and the gate refuses again.
##
## Test-double policy: NO mocks, doubles or fakes. Real git, real bare
## origins, a real side clone pushing to gamma's origin, the real
## `./build/bin/repro` for both the gate and the refresh. See the headers of
## `nf2_flake_lock_fixture.nim` and `nf3_override_state_fixture.nim`.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip
import nf3_override_state_fixture

proc pinOf(lockText, node: string): string =
  ## The `locked.rev` of one node, read from the raw node text. The first
  ## `"rev"` in a node is `locked`'s (see `lockedNode`'s member order).
  let text = nodeText(lockText, node)
  const key = "\"rev\": \""
  let at = text.find(key)
  if at < 0: return ""
  let start = at + key.len
  let stop = text.find('"', start)
  if stop < 0: return ""
  text[start ..< stop]

suite "NF-3: a mixed-direction refusal clears in one pass":

  test "t_a_mixed_direction_refusal_clears_in_one_pass":
    const caseName = "t_a_mixed_direction_refusal_clears_in_one_pass"
    if not nf3Prerequisites(caseName):
      skip("git not on PATH or ./build/bin/repro not built; this case " &
        "drives the real gate over a real git workspace")
    else:
      let fx = setupNf2Fixture("mixed-one-pass")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      removePreCommitDispatch(fx)

      # alpha: two published commits AHEAD of its pin (the seed) — §3.1, the
      # row the refresh is right for.
      let alphaHead = advancePublishedSibling(fx, "alpha", 2)
      check alphaHead != fx.seedSha[0]

      # beta: its origin carries three newer revisions and the lock pins the
      # newest, but the CHECKOUT is left three behind it — the release-branch
      # shape of the issue. The pin is published, as it is in the field.
      let betaPinned = advancePublishedSibling(fx, "beta", 3)
      let betaCheckout = rewindSibling(fx, "beta", 3)
      check betaCheckout == fx.seedSha[1]
      check siblingRevIsPublished(fx, "beta", betaPinned)

      # gamma: the pin exists only on its ORIGIN, pushed from a side clone;
      # this checkout has never fetched it, so the row cannot be classified.
      let gammaPinned = advanceOriginWithoutFetching(fx, "gamma", 2)
      check not pinIsFetched(fx, "gamma", gammaPinned)

      setFlakePins(fx, fx.seedSha[0], betaPinned, gammaPinned)
      commitLockAndPublish(fx, "a lock refreshed elsewhere for beta and gamma")
      let lockBefore = readFile(lockPath(fx))
      check pinOf(lockBefore, "alpha-src") == fx.seedSha[0]
      check pinOf(lockBefore, "beta-src") == betaPinned
      check pinOf(lockBefore, "gamma-src") == gammaPinned

      # ---- (1) the gate refuses, naming every direction ---------------------
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
        check evidence.contains("input=alpha-src")
        check evidence.contains("input=beta-src")
        check evidence.contains("input=gamma-src")
        check evidence.contains("relation=ahead")
        check evidence.contains("relation=behind")
        check evidence.contains("relation=unfetched")

        let namedDir = directoryNamedForRunning(remediation)
        checkpoint("named directory: " & namedDir)
        check namedDir.len > 0
        check dirExists(namedDir)

        let commands = backtickedCommands(remediation)
        checkpoint("commands, in printed order: " & $commands)
        check commands.len > 0

        # ---- (2) the refresh is named once, and last ------------------------
        var refreshes = 0
        for cmd in commands:
          if cmd.startsWith("repro flake refresh-lock"): inc refreshes
        check refreshes == 1
        if commands.len > 0:
          check commands[^1].startsWith("repro flake refresh-lock")

        # ---- (3) every command, in printed order, exits 0 -------------------
        for cmd in commands:
          let res = runNamedCommand(fx, cmd, namedDir)
          checkpoint("ran `" & cmd & "` in " & namedDir & " -> " & $res.code &
            "\n" & res.output)
          check res.code == 0

        # ---- (4) no pin moved backward --------------------------------------
        let lockAfter = readFile(lockPath(fx))
        check pinOf(lockAfter, "alpha-src") == alphaHead
        check pinOf(lockAfter, "beta-src") == betaPinned
        check pinOf(lockAfter, "gamma-src") == gammaPinned
        # …and the checkouts were the half that moved.
        check headOf(fx, siblingDir(fx, "beta")) == betaPinned
        check headOf(fx, siblingDir(fx, "gamma")) == gammaPinned

        # ---- (5) one pass: the gate stops refusing --------------------------
        commitLockAndPublish(fx, "record the observed alpha revision")
        let again = gatePrePush(fx)
        checkpoint("second gate output:\n" & again.output)
        check not hasGateFailure(again.report, "flake_lock_stale")
        if hasGateFailure(again.report, "flake_lock_stale"):
          checkpoint("second refusal: " &
            gateFailureOf(again.report, "flake_lock_stale")["remediation"].getStr())

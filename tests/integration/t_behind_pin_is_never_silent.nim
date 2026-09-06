## NF-3 — **behind-pin is never silent: the regression test for the measured
## three-commits-behind case.**
##
## Spec: Nix-Flake-Coexistence.md §3.2, and the milestone's own record of the
## failure this reproduces:
##
##   > *Checkouts drift below their pins unnoticed.* Measured in this
##   > workspace: `reprobuild-ct-test-runner` sat **3 commits behind** its pin
##   > while `io-mon` was 7 ahead and `nim-shm-gset` 9 ahead. Nothing reported
##   > any of it.
##
## The shape of that measurement is the shape of the case, distances included:
## one sibling **3 behind**, one **7 ahead**, one **9 ahead**. Both halves of
## the original observation are reproduced, because they interact — the loud,
## fast-moving siblings are the noise the quiet one has to survive. An
## implementation that reported "there is drift" without saying WHICH direction
## and WHICH sibling would have been just as useless in the field as saying
## nothing.
##
## ## What is asserted
##
##   1. the 3-behind sibling is named, with the distance `3`, in a WARNING;
##   2. the two large ahead-distances are reported as their own states with
##      their own distances (7 and 9) and are NOT warned about — §3.2's
##      asymmetry, under the conditions that produced the field measurement;
##   3. the warning names the reconciling command;
##   4. the accounting line is complete: three substituted inputs, one behind,
##      two ahead, zero at pin. A report that had dropped a row would still
##      satisfy (1)-(3).
##
## ## Mutation (from the milestone): suppress when the distance is small
##
## ⇒ RED. Gate the behind warning on `row.behindBy >= 5`. Three commits is
## below any threshold anyone would pick — which is the point: the measured
## case was three, and it hid for as long as nothing looked. Assert (1) fails
## and assert (4)'s count of warnings fails with it.
##
## Test-double policy: NO mocks, doubles or fakes. See the headers of
## `nf2_flake_lock_fixture.nim` and `nf3_override_state_fixture.nim`.

import std/[os, strutils, unittest]

import nf3_override_state_fixture

suite "NF-3: behind-pin is never silent":

  test "t_behind_pin_is_never_silent":
    const caseName = "t_behind_pin_is_never_silent"
    if not nf3Prerequisites(caseName):
      skip()
    else:
      let fx = setupNf2Fixture("behind-silent")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      removePreCommitDispatch(fx)

      # alpha stands in for `reprobuild-ct-test-runner`: its history gains
      # three revisions, the lock records the newest, and the checkout is left
      # where it was — 3 commits BEHIND its pin.
      let alphaPinned = advanceSibling(fx, "alpha", 3)
      let alphaCheckout = rewindSibling(fx, "alpha", 3)
      check alphaCheckout == fx.seedSha[0]

      # beta stands in for `io-mon` (7 ahead) and gamma for `nim-shm-gset`
      # (9 ahead): loud, fast-moving siblings whose drift is NORMAL.
      let betaHead = advanceSibling(fx, "beta", 7)
      let gammaHead = advanceSibling(fx, "gamma", 9)
      check betaHead != fx.seedSha[1]
      check gammaHead != fx.seedSha[2]

      setFlakePins(fx, alphaPinned, fx.seedSha[1], fx.seedSha[2])

      let status = flakeStatus(fx)
      checkpoint("override-status stderr:\n" & status.stderr)
      check status.code == 0

      # ---- (1) the quiet one is NAMED, with its distance, as a WARNING ----
      check status.stderr.contains("WARNING")
      check status.stderr.contains("'alpha'")
      check status.stderr.contains("3 commit(s) BEHIND")

      # ---- (2) the loud ones are stated, with their distances, unwarned ----
      check status.stderr.contains("'beta'")
      check status.stderr.contains("7 commit(s) AHEAD")
      check status.stderr.contains("'gamma'")
      check status.stderr.contains("9 commit(s) AHEAD")
      var warnings = 0
      for line in status.stderr.splitLines():
        if line.contains("WARNING"): inc warnings
      check warnings == 1

      # ---- (3) the reconciling command -------------------------------------
      check status.stderr.contains("git -C " & siblingDir(fx, "alpha") &
        " merge --ff-only " & alphaPinned)

      # ---- (4) the accounting line is complete ----------------------------
      check status.stderr.contains("3 substituted input(s)")
      check status.stderr.contains("0 at pin, 2 ahead, 1 behind")

## HL-11 H3 — **the commit-time re-pin is one plan over both locks, and it
## moves lock resolutions only, never a recipe constraint**
## (Unified-Locking-And-Hooks.md §16.3 H3 and §16.4), plus the H1 / H2 checks
## of §16.3 in a repo outside any workspace.
##
## WHY. The managed `pre-commit` hook re-pins `repro.lock` and refreshes
## `flake.lock` from the sibling checkouts it observes. They were two writers.
## A repository resolved by both locks could be moved in one and left in the
## other — a dirty or unpublished sibling the flake refresh withholds, an
## exact `rev=` in `flake.nix` the flake refresh declines to move past — and
## the hook then wrote a state in which the two locks disagree. Committing
## HL-11 M1 showed it: the hook re-pinned `nim-stackable-hooks` in
## `repro.lock` while `flake.nix` pinned it at an older revision. And where a
## recipe constraint excluded the observed revision, the flake half declined
## with a warning and let the commit through, so an experiment run under an
## explicit develop override was one `git commit` away from being published.
##
## Cases:
##
##   * `t_commit_repin_moves_both_locks_or_neither` — `app` carries both locks
##     and both resolve `beta` (one repository, `beta` in `repro.lock`,
##     `beta-src` in `flake.lock`). (a) Positive control: nothing moved, the
##     commit passes. (b) `beta` moves and is published: BOTH locks are moved
##     to it in the same commit. (c) `beta` moves but is NOT published: the
##     flake refresh withholds it, so the `repro.lock` move is held too —
##     neither lock moves, the commit proceeds, and the hook says so. (d)
##     `repro.nim` pins `beta ==3.0.0` exactly, under an explicit develop
##     override, and `beta` moves past that version's sourceRevision: neither
##     lock is written (the floating `flake.lock` input would have moved), the
##     index is untouched, and the commit is refused naming the `repro.nim`
##     line, both revisions and both lock resolutions left alone.
##   * `t_commit_repin_never_rewrites_a_recipe_constraint` — `flake.nix` pins
##     `beta-src` by revision, `beta` is substituted by an explicit override
##     and moves ahead. The commit is refused; the refusal names the observed
##     revision, the pinned one, the `flake.nix` line, the runnable
##     `repro lock update beta-src --to <observed> --repo-root=<app>` (HL-11
##     M4) and the drop-the-override remedy with the override file and a runnable
##     `git -C <sibling> checkout <pinned>`. `flake.nix`, both locks and the
##     index are byte-identical. Running the named `git` command clears it;
##     moving the pin in `flake.nix` (the edit remedy) moves both locks.
##   * `t_commit_repin_never_rewrites_a_uses_range_constraint` — the same rule
##     for a `repro.nim` `uses:` range: the producer's `versions:` table maps
##     the observed revision to 2.0.0 and the range is `>=1.0 <2`. Refused,
##     nothing written in either lock, naming the range line and the version;
##     the backticked checkout remedy, run as printed, clears it.
##   * `t_a_repro_nim_exact_pin_is_not_compared_in_either_lock` — §16.5 for a
##     repository `repro.nim` pins exactly (no override) and `flake.nix`
##     resolves through a FLOATING input: the sibling moves ahead and neither
##     lock is compared with it, at commit (no move, no `repin-held`) or at
##     push. Without this the commit held both locks on every commit and the
##     push gate's `flake_lock_stale` remedy led into an H2 refusal.
##   * `t_h1_h2_run_outside_a_workspace_at_commit` and
##     `t_h1_h2_run_outside_a_workspace_at_push` — a standalone clone (no
##     initialised workspace above it) is held to H1 at commit and at push;
##     each first passes its consistent shape, and the push case asserts it
##     really ran on the non-workspace path. Only H1 can arise there: a repo
##     that commits a `repro.lock` is its own manifest-optional workspace
##     (MO-2), so a repo with both locks, which H2 needs, always takes the
##     workspace path, where M2 already runs H1 and H2.
##
## Falsifiability: against the tree before this change, (b) passes, (c)'s
## commit is REFUSED as an H2 disagreement the hook itself produced, (d) is
## refused as H1 rather than by the re-pin, case 2's commit is refused as H2
## (and, without a `repro.lock`, accepted with a warning), case 3's commit
## succeeds and moves both locks, case 4's commit is refused as H1 (the exact
## pin was re-pinned in `repro.lock`), and both standalone cases accept the
## inconsistent state (exit 0).
##
## `repro lock update <dependency> --to <observed>` is named by the refusal
## in backticks since HL-11 M4, because it runs where the message is printed;
## running it (it re-locks through nix) is
## `t_the_h3_refusals_lock_update_command_runs_and_the_commit_succeeds`. The
## backticked `git -C … checkout …` remedy IS run here, through
## `runNamedCommand`. nix itself is not run, for the reason
## `nf2_flake_lock_fixture.nim` gives.
##
## Test-double policy: NO mocks, doubles or fakes. Real bare origins, real
## clones, real `flake.lock` / `repro.lock` documents in their on-disk shapes,
## the real `./build/bin/repro`, the real `repro develop --only=beta` to record
## an explicit override, a REAL `.git/hooks/pre-commit` fired by a real
## `git commit` (`installPreCommitDispatch`; see `nf2_flake_lock_fixture.nim`
## for why the hook file is written rather than installed), and the real
## `repro check --mode=pre-push`.

import std/[os, strutils, unittest]

import hl11_two_lock_fixture
import repro_test_support/reasoned_skip

const H3Head = "H3 (the commit-time re-pin moves lock resolutions, never a " &
  "recipe constraint)"

proc writeAppReproLock(fx: Nf2Fixture; betaRev: string) =
  ## `app`'s committed `repro.lock`, resolving `beta`'s origin as `beta`.
  writeFile(fx.app / "repro.lock", reproLockText(fx, "app", headOf(fx, fx.app),
    [lockDepEntry(fx, "beta", "../beta", "beta", betaRev)]))

proc commitBetaRecipe(fx: Nf2Fixture; versions: openArray[(string, string)];
    tagAs: string): string =
  ## Commit a `repro.nim` to `beta` whose `versions:` maps each version to a
  ## tag, tag the new commit ``tagAs``, publish, and return the commit.
  let dir = siblingDir(fx, "beta")
  var text = "import repro_project_dsl\n\npackage beta:\n  versions:\n"
  for (version, tag) in versions:
    text.add("    \"" & version & "\":\n      sourceRevision = \"refs/tags/" &
      tag & "\"\n")
  writeFile(dir / "repro.nim", text)
  discard gitIn(fx, dir, "add -A")
  discard gitIn(fx, dir, "commit -q -m " & q("beta recipe"))
  result = headOf(fx, dir)
  discard gitIn(fx, dir, "tag " & tagAs)
  discard gitIn(fx, dir, "push -q origin HEAD:main --tags")

proc appRecipe(usesEntry: string): string =
  "import repro_project_dsl\n\npackage app:\n  uses:\n" &
    "    # the constraint under test\n" &
    "    \"" & usesEntry & "\"\n"

suite "HL-11 H3: one plan over both locks; constraints win":

  test "t_commit_repin_moves_both_locks_or_neither":
    if not nf3Prerequisites("t_commit_repin_moves_both_locks_or_neither"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      let fx = setupNf2Fixture("h3-both")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      # The explicit override is recorded up front, while `beta` is still at
      # the revision the workspace lock names (the run adopts the checkout
      # rather than resetting it). It changes nothing until arm (d) gives
      # `repro.nim` an exact pin: an override matters to exact pins only.
      overrideExplicitly(fx, "beta")
      let betaSeed = fx.seedSha[1]
      writeAppReproLock(fx, betaSeed)
      publishAll(fx)

      # ---- (a) positive control: nothing moved. ---------------------------
      let ok = tryCommitInApp(fx, "both locks at the seed")
      checkpoint(ok.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check ok.code == 0
      check reproLockRevisionOf(committedText(fx, "repro.lock"), "beta") ==
        betaSeed
      check lockedRevOfNode(committedText(fx, "flake.lock"), "beta-src") ==
        betaSeed
      publishRepo(fx, fx.app)

      # ---- (b) beta moves and is published: BOTH locks move. -------------
      let betaTwo = moveAndPublishSibling(fx, "beta", "revision 2")
      check betaTwo != betaSeed
      let b = tryCommitInApp(fx, "beta moved")
      checkpoint(b.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check b.code == 0
      check reproLockRevisionOf(committedText(fx, "repro.lock"), "beta") ==
        betaTwo
      check lockedRevOfNode(committedText(fx, "flake.lock"), "beta-src") ==
        betaTwo
      check "repin-held" notin preCommitLog(fx)
      publishRepo(fx, fx.app)

      # ---- (c) beta moves, NOT published: neither lock moves. ------------
      # The flake refresh withholds an unpublished revision (nobody else can
      # fetch it); the `repro.lock` re-pin alone would record it. Moving one
      # lock only is what H3 forbids, so both keep `betaTwo`.
      let betaThree = moveSibling(fx, "beta", "revision 3")
      check not siblingRevIsPublished(fx, "beta", betaThree)
      let c = tryCommitInApp(fx, "beta moved, unpublished")
      checkpoint(c.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check c.code == 0
      check reproLockRevisionOf(committedText(fx, "repro.lock"), "beta") ==
        betaTwo
      check lockedRevOfNode(committedText(fx, "flake.lock"), "beta-src") ==
        betaTwo
      check readFile(fx.app / "repro.lock").contains(betaTwo)
      check not readFile(fx.app / "repro.lock").contains(betaThree)
      check ("was moved in NEITHER: repro.lock would move 'beta' " & betaTwo &
        " -> " & betaThree & ", but flake.lock leaves input 'beta-src' at " &
        betaTwo & " (the flake.lock refresh withheld it") in c.output
      check ("repin-held: repository ") in preCommitLog(fx)
      # Not a refusal of any kind, and not an H2 disagreement.
      check "REFUSED" notin c.output
      check "H2 (" notin c.output
      # Publishing the revision lets both move together.
      publishSibling(fx, "beta")
      let c2 = tryCommitInApp(fx, "beta published")
      checkpoint(c2.output)
      check c2.code == 0
      check reproLockRevisionOf(committedText(fx, "repro.lock"), "beta") ==
        betaThree
      check lockedRevOfNode(committedText(fx, "flake.lock"), "beta-src") ==
        betaThree
      publishRepo(fx, fx.app)

      # ---- (d) one lock constrained away: neither written, refused. ------
      # `beta` gains a recipe whose `versions:` maps 3.0.0 to a tag on the
      # recipe commit, and `app` requires exactly 3.0.0. The positive control
      # first: at the tagged commit the constraint admits the checkout, and
      # both locks move to it.
      let betaRecipe = commitBetaRecipe(fx, [("3.0.0", "v3.0.0")], "v3.0.0")
      let betaRecipeFile = siblingDir(fx, "beta") / "repro.nim"
      let versionLine = lineNumberOf(readFile(betaRecipeFile), "\"3.0.0\":")
      writeFile(fx.app / "repro.nim", appRecipe("beta ==3.0.0"))
      let usesLine = lineNumberOf(readFile(fx.app / "repro.nim"),
        "\"beta ==3.0.0\"")
      check usesLine == 6
      check versionLine == 5
      let d0 = tryCommitInApp(fx, "require beta 3.0.0")
      checkpoint(d0.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check d0.code == 0
      check reproLockRevisionOf(committedText(fx, "repro.lock"), "beta") ==
        betaRecipe
      check lockedRevOfNode(committedText(fx, "flake.lock"), "beta-src") ==
        betaRecipe
      publishRepo(fx, fx.app)

      # `beta` moves past 3.0.0. The floating flake input WOULD move; the
      # exact `uses:` version excludes the new revision.
      let betaNext = moveAndPublishSibling(fx, "beta", "revision 4")
      let headBefore = headOf(fx, fx.app)
      let reproLockBefore = readFile(fx.app / "repro.lock")
      let flakeLockBefore = readFile(lockPath(fx))
      let d = tryCommitKeepingIndex(fx, "beta past its exact version")
      checkpoint(d.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check d.code != 0
      check d.head == headBefore
      check d.treeAfter == d.treeBefore
      check readFile(fx.app / "repro.lock") == reproLockBefore
      check readFile(lockPath(fx)) == flakeLockBefore
      check stagedText(fx, "repro.lock") == reproLockBefore
      check stagedText(fx, "flake.lock") == flakeLockBefore
      check (H3Head & ": the sibling checkout " & siblingDir(fx, "beta") &
        " is at " & betaNext & ", but " & fx.app / "repro.nim" & ":" &
        $usesLine & " requires 'beta ==3.0.0', which " & betaRecipeFile &
        ":" & $versionLine & " maps to sourceRevision " & betaRecipe &
        "; the re-pin wrote nothing for this repository in either lock (" &
        fx.app / "repro.lock" & " 'beta' stays at " & betaRecipe & "; " &
        fx.app / "flake.lock" & " input 'beta-src' stays at " & betaRecipe &
        ")") in d.output
      # The whole refusal paragraph, byte for byte: the summary, then both
      # remedies — the intended upgrade (the runnable `repro lock update`),
      # and the experiment with the override's file and a command that runs
      # as printed.
      let usesWhere = fx.app / "repro.nim" & ":" & $usesLine
      let paragraph = "repro pre-commit: " & H3Head &
        ": the sibling checkout " & siblingDir(fx, "beta") & " is at " &
        betaNext & ", but " & usesWhere & " requires 'beta ==3.0.0', which " &
        betaRecipeFile & ":" & $versionLine & " maps to sourceRevision " &
        betaRecipe & "; the re-pin wrote nothing for this repository in " &
        "either lock (" & fx.app / "repro.lock" & " 'beta' stays at " &
        betaRecipe & "; " & fx.app / "flake.lock" & " input 'beta-src' " &
        "stays at " & betaRecipe & "). (1) If " & betaNext & " is the " &
        "intended upgrade, run `repro lock update beta --to " & betaNext &
        " --repo-root=" & fx.app & "`: it changes the uses: entry at " &
        usesWhere & " to the version whose sourceRevision is " & betaNext &
        " and moves both locks with it (it refuses when no versions: entry " &
        "of " & betaRecipeFile & " maps " & betaNext & "; add that entry " &
        "first); then commit again. " &
        "(2) If " & betaNext & " was a temporary experiment, drop the " &
        "develop override of 'beta' (remove its entry from " &
        fx.ws / ".repro" / "develop-overrides.toml" & "; no repro command " &
        "removes a single override yet), or check the sibling out at the " &
        "pinned revision: `git -C " & siblingDir(fx, "beta") & " checkout " &
        betaRecipe & "`; then commit again."
      check paragraph in d.output.splitLines()
      check "not available yet" notin d.output
      check ("flake.lock NOT refreshed because the commit is refused for a " &
        "recipe constraint the re-pin may not move (H3)") in preCommitLog(fx)
      check ("repin-constraint refused: rule=H3 system=repro " &
        "dependency=beta") in preCommitLog(fx)
      # Refused by the re-pin, not by the consistency check after it.
      check "H1 (" notin d.output
      check "H2 (" notin d.output

  test "t_commit_repin_never_rewrites_a_recipe_constraint":
    if not nf3Prerequisites(
        "t_commit_repin_never_rewrites_a_recipe_constraint"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      let fx = setupNf2Fixture("h3-pin", revPinned = ["beta-src"])
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      overrideExplicitly(fx, "beta")
      let betaSeed = fx.seedSha[1]
      writeAppReproLock(fx, betaSeed)
      publishAll(fx)
      let flakeNixPath = fx.app / "flake.nix"
      let pinLine = lineNumberOf(readFile(flakeNixPath), "beta-src.url")
      check pinLine > 0
      check ("rev=" & betaSeed) in readFile(flakeNixPath)

      # ---- positive control: the checkout is at the pin. ------------------
      let ok = tryCommitInApp(fx, "pinned and at the pin")
      checkpoint(ok.output)
      check ok.code == 0
      publishRepo(fx, fx.app)

      # ---- the overridden sibling moves ahead of the pin. -----------------
      let betaNext = moveAndPublishSibling(fx, "beta", "revision 2")
      check betaNext != betaSeed
      let headBefore = headOf(fx, fx.app)
      let flakeNixBefore = readFile(flakeNixPath)
      let flakeLockBefore = readFile(lockPath(fx))
      let reproLockBefore = readFile(fx.app / "repro.lock")
      let c = tryCommitKeepingIndex(fx, "work against the moved beta")
      checkpoint(c.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check c.code != 0
      check c.head == headBefore
      # Nothing was written or staged, and no recipe was edited.
      check c.treeAfter == c.treeBefore
      check readFile(flakeNixPath) == flakeNixBefore
      check readFile(lockPath(fx)) == flakeLockBefore
      check readFile(fx.app / "repro.lock") == reproLockBefore
      check stagedText(fx, "flake.lock") == flakeLockBefore
      check stagedText(fx, "repro.lock") == reproLockBefore
      check stagedText(fx, "flake.nix") == flakeNixBefore
      # What the refusal names: the observed and pinned revisions, the line,
      # and every lock resolution it left alone.
      check (H3Head & ": the sibling checkout " & siblingDir(fx, "beta") &
        " is at " & betaNext & ", but " & flakeNixPath & ":" & $pinLine &
        " pins input 'beta-src' at revision " & betaSeed &
        "; the re-pin wrote nothing for this repository in either lock (" &
        fx.app / "repro.lock" & " 'beta' stays at " & betaSeed & "; " &
        fx.app / "flake.lock" & " input 'beta-src' stays at " & betaSeed &
        ")") in c.output
      # Remedy 1: the intended upgrade, as the runnable one-step command.
      let updateCmd = "repro lock update beta-src --to " & betaNext &
        " --repo-root=" & fx.app
      check ("If " & betaNext & " is the intended upgrade, run `" &
        updateCmd & "`: it changes rev=" & betaSeed & " to rev=" & betaNext &
        " in that input's url in " & flakeNixPath) in c.output
      check updateCmd in backtickedCommands(c.output)
      check "not available yet" notin c.output
      # Remedy 2: the experiment, with the override's file and a command
      # that runs where the message is printed.
      let checkoutCmd = "git -C " & siblingDir(fx, "beta") & " checkout " &
        betaSeed
      check ("If " & betaNext & " was a temporary experiment, drop the " &
        "develop override of 'beta' (remove its entry from " &
        fx.ws / ".repro" / "develop-overrides.toml" & "; no repro command " &
        "removes a single override yet), or check the sibling out at the " &
        "pinned revision: `" & checkoutCmd & "`; then commit again") in
        c.output
      check checkoutCmd in backtickedCommands(c.output)
      check "stale" notin c.output.toLowerAscii()
      check "repin-constraint refused: rule=H3 system=flake " &
        "dependency=beta-src" in preCommitLog(fx)

      # ---- remedy 2, run as printed, clears it. ---------------------------
      let ran = runNamedCommand(fx, checkoutCmd, fx.app)
      checkpoint(ran.output)
      check ran.code == 0
      check headOf(fx, siblingDir(fx, "beta")) == betaSeed
      let back = tryCommitInApp(fx, "back at the pin")
      checkpoint(back.output)
      check back.code == 0
      check reproLockRevisionOf(committedText(fx, "repro.lock"), "beta") ==
        betaSeed
      check lockedRevOfNode(committedText(fx, "flake.lock"), "beta-src") ==
        betaSeed

      # ---- remedy 1 (the edit), and the re-pin moves BOTH locks. ----------
      discard gitIn(fx, siblingDir(fx, "beta"), "checkout -q main")
      check headOf(fx, siblingDir(fx, "beta")) == betaNext
      writeFile(flakeNixPath, readFile(flakeNixPath).replace(
        "rev=" & betaSeed, "rev=" & betaNext))
      # nix's half of the re-lock: `original` mirrors the flake-ref.
      let lock = readFile(lockPath(fx))
      let node = nodeText(lock, "beta-src")
      let originalAt = node.find("\"original\"")
      check originalAt > 0
      writeFile(lockPath(fx), lock.replace(node, node[0 ..< originalAt] &
        node[originalAt .. ^1].replace(betaSeed, betaNext)))
      let up = tryCommitInApp(fx, "adopt the new beta")
      checkpoint(up.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check up.code == 0
      check reproLockRevisionOf(committedText(fx, "repro.lock"), "beta") ==
        betaNext
      check lockedRevOfNode(committedText(fx, "flake.lock"), "beta-src") ==
        betaNext

  test "t_commit_repin_never_rewrites_a_uses_range_constraint":
    if not nf3Prerequisites(
        "t_commit_repin_never_rewrites_a_uses_range_constraint"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      # No override: a range is compared whatever substitutes the sibling.
      let fx = setupNf2Fixture("h3-range")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      publishAll(fx)
      let betaOne = commitBetaRecipe(fx,
        [("1.0.0", "v1.0.0"), ("2.0.0", "v2.0.0")], "v1.0.0")
      writeAppReproLock(fx, betaOne)
      writeFile(fx.app / "repro.nim", appRecipe("beta >=1.0 <2"))
      let rangeLine = lineNumberOf(readFile(fx.app / "repro.nim"),
        "\"beta >=1.0 <2\"")
      let betaRecipeFile = siblingDir(fx, "beta") / "repro.nim"
      let twoLine = lineNumberOf(readFile(betaRecipeFile), "\"2.0.0\":")
      check rangeLine == 6
      check twoLine > 0

      # ---- positive control: the checkout is 1.0.0, inside the range. -----
      let ok = tryCommitInApp(fx, "beta 1.0.0 in range")
      checkpoint(ok.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check ok.code == 0
      check reproLockRevisionOf(committedText(fx, "repro.lock"), "beta") ==
        betaOne
      publishRepo(fx, fx.app)

      # ---- beta moves to 2.0.0, which the range excludes. -----------------
      let betaTwo = moveSibling(fx, "beta", "revision 2.0.0")
      discard gitIn(fx, siblingDir(fx, "beta"), "tag v2.0.0")
      discard gitIn(fx, siblingDir(fx, "beta"),
        "push -q origin HEAD:main --tags")
      let headBefore = headOf(fx, fx.app)
      let reproLockBefore = readFile(fx.app / "repro.lock")
      let flakeLockBefore = readFile(lockPath(fx))
      let c = tryCommitKeepingIndex(fx, "beta 2.0.0 out of range")
      checkpoint(c.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check c.code != 0
      check c.head == headBefore
      check c.treeAfter == c.treeBefore
      check readFile(fx.app / "repro.lock") == reproLockBefore
      check readFile(lockPath(fx)) == flakeLockBefore
      # The whole refusal paragraph, byte for byte. No override substitutes
      # `beta`, so the experiment remedy is a checkout, not an override drop.
      let rangeWhere = fx.app / "repro.nim" & ":" & $rangeLine
      let checkoutCmd = "git -C " & siblingDir(fx, "beta") & " checkout " &
        betaOne
      let paragraph = "repro pre-commit: " & H3Head &
        ": the sibling checkout " & siblingDir(fx, "beta") & " is at " &
        betaTwo & ", but " & rangeWhere & " requires 'beta >=1.0 <2', " &
        "which does not admit version 2.0.0 (" & betaRecipeFile & ":" &
        $twoLine & " maps " & betaTwo & " to it); the re-pin wrote nothing " &
        "for this repository in either lock (" & fx.app / "repro.lock" &
        " 'beta' stays at " & betaOne & "; " & fx.app / "flake.lock" &
        " input 'beta-src' stays at " & betaOne & "). (1) If version 2.0.0 " &
        "is the intended upgrade, widen the range at " & rangeWhere &
        " so it admits 2.0.0, and commit again (repro lock update will not " &
        "widen a range: that is the author's decision). (2) If " & betaTwo &
        " was a temporary experiment, " &
        "check the sibling out at a revision the recipe admits, such as the " &
        "one the locks name now: `" & checkoutCmd & "`; then commit again."
      check paragraph in c.output.splitLines()
      check "drop the develop override" notin c.output
      # The backticked remedy runs as printed and clears the refusal.
      let ran = runNamedCommand(fx, checkoutCmd, fx.app)
      checkpoint(ran.output)
      check ran.code == 0
      let back = tryCommitInApp(fx, "beta back at 1.0.0")
      checkpoint(back.output)
      check back.code == 0
      check reproLockRevisionOf(committedText(fx, "repro.lock"), "beta") ==
        betaOne

  test "t_a_repro_nim_exact_pin_is_not_compared_in_either_lock":
    if not nf3Prerequisites(
        "t_a_repro_nim_exact_pin_is_not_compared_in_either_lock"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      # §16.5 exempts a REPOSITORY a recipe pins exactly, whichever recipe:
      # here `repro.nim` pins `beta ==3.0.0`, no override substitutes it, and
      # `flake.nix` resolves the same repository through the FLOATING input
      # `beta-src`. A sibling ahead of the pin is ordinary, so neither lock is
      # compared with it, at commit or at push.
      let fx = setupNf2Fixture("h3-uses-pin")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      publishAll(fx)
      let betaRecipe = commitBetaRecipe(fx, [("3.0.0", "v3.0.0")], "v3.0.0")
      writeAppReproLock(fx, betaRecipe)
      setFlakePins(fx, fx.seedSha[0], betaRecipe, fx.seedSha[2])
      writeFile(fx.app / "repro.nim", appRecipe("beta ==3.0.0"))
      let usesLine = lineNumberOf(readFile(fx.app / "repro.nim"),
        "\"beta ==3.0.0\"")
      check usesLine == 6

      # ---- positive control: both locks at the pin, the checkout too. -----
      let ok = tryCommitInApp(fx, "both locks at the exact version")
      checkpoint(ok.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check ok.code == 0
      check lockedRevOfNode(committedText(fx, "flake.lock"), "beta-src") ==
        betaRecipe
      check reproLockRevisionOf(committedText(fx, "repro.lock"), "beta") ==
        betaRecipe
      publishRepo(fx, fx.app)

      # ---- the sibling moves past the pin: nothing is compared. -----------
      let betaNext = moveAndPublishSibling(fx, "beta", "revision 4")
      check betaNext != betaRecipe
      let c = tryCommitInApp(fx, "beta ahead of the exact version")
      checkpoint(c.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check c.code == 0
      check lockedRevOfNode(committedText(fx, "flake.lock"), "beta-src") ==
        betaRecipe
      check reproLockRevisionOf(committedText(fx, "repro.lock"), "beta") ==
        betaRecipe
      # Neither re-pinned nor held: the flake input was not consulted.
      check "repin-held" notin preCommitLog(fx)
      check "repin-held" notin c.output
      check "beta-src" notin c.output
      check ("pinned by recipe, not compared: beta-src=beta@" & fx.app /
        "repro.nim:" & $usesLine & " (rev " & betaRecipe & ")") in
        preCommitLog(fx)
      publishRepo(fx, fx.app)
      let g = gatePrePush(fx)
      checkpoint(g.output)
      check g.code == 0
      check not hasGateFailure(g.report, "flake_lock_stale")
      check not hasGateFailure(g.report, "committed_lock_sibling_pin_stale")
      check not hasGateFailure(g.report, "cross_lock_revision_disagreement")

suite "HL-11 H1 / H2 outside a workspace":

  test "t_h1_h2_run_outside_a_workspace_at_commit":
    if not nf3Prerequisites("t_h1_h2_run_outside_a_workspace_at_commit"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      let base = setupNf2Fixture("h12-standalone-commit",
        revPinned = ["beta-src"])
      defer: removeDir(base.scratch)
      isolateNf2Config(base)
      defer: releaseNf2Config()
      publishAll(base)
      # A clone of `app` OUTSIDE the workspace directory: no initialised
      # workspace encloses it.
      var fx = base
      fx.app = base.scratch / "standalone"
      discard requireCmd(q(base.gitBin) & " clone -q " &
        q(originUrl(base, "app")) & " " & q(fx.app))
      discard gitIn(fx, fx.app, "config user.email tester@example.invalid")
      discard gitIn(fx, fx.app, "config user.name \"NF2 Tester\"")
      installPreCommitDispatch(fx)
      let pinned = base.seedSha[1]
      let pinLine = lineNumberOf(readFile(fx.app / "flake.nix"),
        "beta-src.url")

      # ---- positive control: a consistent commit passes. ------------------
      let ok = tryCommitInApp(fx, "consistent standalone")
      checkpoint(ok.output)
      check ok.code == 0

      # ---- locked.rev moves alone: H1. ------------------------------------
      let other = moveAndPublishSibling(base, "beta", "revision 2")
      let lock = readFile(lockPath(fx))
      let node = nodeText(lock, "beta-src")
      let lockedEnd = node.find("\"original\"")
      check lockedEnd > 0
      writeFile(lockPath(fx), lock.replace(node,
        node[0 ..< lockedEnd].replace(pinned, other) & node[lockedEnd .. ^1]))
      check lockedRevOfNode(readFile(lockPath(fx)), "beta-src") == other
      let headBefore = headOf(fx, fx.app)
      let c = tryCommitInApp(fx, "standalone lock disagrees with its pin")
      checkpoint(c.output)
      check c.code != 0
      check c.head == headBefore
      check "H1 (the lock satisfies the recipe)" in c.output
      check (fx.app / "flake.nix" & ":" & $pinLine & " pins input " &
        "'beta-src' at revision " & pinned) in c.output
      check ("locks it at " & other) in c.output
      check ("`nix flake update beta-src --flake " & fx.app & "`") in c.output
      # The repo is outside any workspace: nothing was re-pinned or logged.
      check not fileExists(fx.app / ".repro")

  test "t_h1_h2_run_outside_a_workspace_at_push":
    if not nf3Prerequisites("t_h1_h2_run_outside_a_workspace_at_push"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      let base = setupNf2Fixture("h12-standalone-push",
        revPinned = ["beta-src"])
      defer: removeDir(base.scratch)
      isolateNf2Config(base)
      defer: releaseNf2Config()
      publishAll(base)
      var fx = base
      fx.app = base.scratch / "standalone"
      discard requireCmd(q(base.gitBin) & " clone -q " &
        q(originUrl(base, "app")) & " " & q(fx.app))
      discard gitIn(fx, fx.app, "config user.email tester@example.invalid")
      discard gitIn(fx, fx.app, "config user.name \"NF2 Tester\"")
      let pinned = base.seedSha[1]
      proc gate(): tuple[code: int; output: string] =
        ## The real pre-push gate, with NO workspace root: as the managed
        ## hook runs it in a standalone clone.
        let refs = base.scratch / "standalone-refs.txt"
        writeFile(refs, "refs/heads/main " & headOf(fx, fx.app) &
          " refs/heads/main " & ZeroSha & "\n")
        run(q(fx.repro) & " check --mode=pre-push --current-repo=" &
          q(fx.app) & " --pushed-refs=" & q(refs) &
          " --tool-provisioning=path", cwd = fx.app)

      let pinLine = lineNumberOf(readFile(fx.app / "flake.nix"),
        "beta-src.url")

      # ---- positive control: the consistent clone pushes. -----------------
      writeFile(fx.app / "standalone.txt", "a standalone change\n")
      commitWithoutHook(fx, "standalone, consistent")
      let ok = gate()
      checkpoint(ok.output)
      check ok.code == 0
      # It really ran on the non-workspace path (no repro.lock here: a repo
      # that commits one is its own manifest-optional workspace, MO-2).
      check "not a workspace; nothing to enforce" in ok.output

      # ---- locked.rev moved alone, committed past the hook: H1. -----------
      let other = moveAndPublishSibling(base, "beta", "revision 2")
      let lock = readFile(lockPath(fx))
      let node = nodeText(lock, "beta-src")
      let lockedEnd = node.find("\"original\"")
      check lockedEnd > 0
      writeFile(lockPath(fx), lock.replace(node,
        node[0 ..< lockedEnd].replace(pinned, other) & node[lockedEnd .. ^1]))
      commitWithoutHook(fx, "standalone, the lock disagrees with its pin")
      let g = gate()
      checkpoint(g.output)
      check g.code == 2
      check "push REFUSED (recipe_lock_constraint_violated)" in g.output
      check ("H1 (the lock satisfies the recipe): " & fx.app / "flake.nix" &
        ":" & $pinLine & " pins input 'beta-src' at revision " & pinned &
        ", but " & fx.app / "flake.lock" & " locks it at " & other) in g.output
      check ("`nix flake update beta-src --flake " & fx.app & "`") in g.output
      check "not a workspace; nothing to enforce" notin g.output

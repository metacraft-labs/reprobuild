## NF-2 — **a sibling BEHIND its pin must not have that pin rewritten.**
##
## Spec: Nix-Flake-Coexistence.md §3.2 —
##
##   > A sibling **ahead** means *you are developing*. A sibling **behind**
##   > almost always means *your checkout is stale*, not that you chose to
##   > downgrade — so the two warrant different treatment.
##   > **Rule.** A behind-pin sibling is reported **ambiently**, naming the
##   > sibling, the distance, and the command that reconciles it.
##
## ## The defect this is the regression test for
##
## NF-2 as first shipped refreshed every overridden input from its sibling's
## `HEAD` without asking which DIRECTION the sibling stood in. A sibling behind
## its pin therefore had its pin rewritten DOWNWARDS — a downgrade nobody chose,
## filed silently into the revision being formed.
##
## Observed live, during a landing in this workspace: the hook rewrote
## `codetracer-src` and `io-mon-src` down to stale sibling checkouts and
## contaminated two commits before anybody noticed. `codetracer` was 742 commits
## behind its pin (a `repro ws pull` had skipped it for carrying a stash) and
## `io-mon` 4 behind. The only workaround available at the time was
## `chmod 444 flake.lock`.
##
## It also put the two halves of the campaign in direct disagreement: NF-2 wrote
## the downgrade into the lock and NF-3's pre-push gate then refused the push
## because the lock disagreed with the siblings (`flake_lock_stale`). One half
## wrote what the other half rejected.
##
## ## The policy asserted here
##
## The first fix gave the behind-pin case the dirty-sibling shape: skip that
## input's refresh, leave the lock, let the commit proceed, and refuse at the
## push. §3.2's "Rule, at commit" (owner-decided 2026-09-30) replaced that:
## committing a downgrade is a different act from testing one, so the commit
## is **refused** unless the committer names the input in
## `REPRO_ALLOW_PIN_REGRESSION` for that commit. A stale checkout must not
## become a stale published lock, and it must not become a commit that goes
## out quietly and is caught only at the push either.
##
## ## What is asserted
##
##   1. the commit is REFUSED — nonzero, and no commit was made;
##   2. `flake.lock` in the working tree is **byte-identical** afterwards. Not
##      "the gamma node is unchanged" — the whole file, because a refresh that
##      moved the pin and then moved it back, or that reserialised the document,
##      is not the same thing as one that never touched it;
##   3. `flake.lock` **as HEAD carries it** is byte-identical too, and HEAD did
##      not move: no revision filed a downgrade;
##   4. the refusal is SAID, in the commit's output and in the pre-commit log,
##      naming the input, the relation and the distance. A refusal nobody can
##      read is indistinguishable from a broken hook.
##
## ## Mutation
##
## Record the behind-pin sibling anyway (treat `sprBehind` as not a
## regression in `isPinRegression`) ⇒ RED on (1), (2) and (3): the commit goes
## through and the `gamma-src` node names the older checkout revision.
##
## Test-double policy: NO mocks, doubles or fakes — real bare git origins, real
## clones, a real `flake.lock` in nix's on-disk shape, the real
## `./build/bin/repro`, and a REAL `.git/hooks/pre-commit` fired by a real
## `git commit`. See the header of `nf2_flake_lock_fixture.nim`.

import std/[os, strutils, unittest]

import nf3_override_state_fixture

suite "NF-2: a behind-pin sibling is not recorded as the new pin":

  test "t_a_behind_pin_sibling_is_not_recorded_as_the_new_pin":
    const caseName = "t_a_behind_pin_sibling_is_not_recorded_as_the_new_pin"
    if not nf2Prerequisites(caseName):
      skip()
    else:
      let fx = setupNf2Fixture("behind-not-recorded")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      # gamma's history gains two revisions; the lock records the NEWEST; the
      # CHECKOUT is rewound to where it started. The pinned objects stay in the
      # sibling's store, so the direction is computable and the row classifies
      # as BEHIND rather than as "cannot be classified until fetched" (which is
      # `t_a_sibling_whose_pin_is_not_fetched_is_not_recorded`'s subject).
      let gammaPinned = advanceSibling(fx, "gamma", 2)
      let gammaCheckout = rewindSibling(fx, "gamma", 2)
      check gammaCheckout == fx.seedSha[2]
      check gammaPinned != gammaCheckout
      setFlakePins(fx, fx.seedSha[0], fx.seedSha[1], gammaPinned)
      commitLockAndPublish(fx, "a lock pinned ahead of the gamma checkout")

      let before = readFile(lockPath(fx))
      check before.contains(gammaPinned)
      check nodeText(before, "gamma-src").contains(gammaPinned)

      # ---- (1) the commit is REFUSED ------------------------------------
      let headBefore = headOf(fx, fx.app)
      let committed = tryCommitInApp(fx, "work made against a stale gamma")
      checkpoint("commit output:\n" & committed.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check committed.code != 0
      check committed.head == headBefore

      # ---- (2) the working-tree lock is BYTE-identical ------------------
      let after = readFile(lockPath(fx))
      if after != before:
        checkpoint("gamma-src BEFORE:\n" & nodeText(before, "gamma-src"))
        checkpoint("gamma-src AFTER:\n" & nodeText(after, "gamma-src"))
      check after == before

      # Stated separately as well, so a failure says WHICH revision was filed
      # rather than only that some byte moved.
      check nodeText(after, "gamma-src").contains(gammaPinned)
      check not nodeText(after, "gamma-src").contains(gammaCheckout)

      # ---- (3) HEAD carries the unchanged lock --------------------------
      let carried = lockInCommit(fx)
      check carried.len > 0
      if carried != before:
        checkpoint("gamma-src AS COMMITTED:\n" & nodeText(carried, "gamma-src"))
      check carried == before
      check not nodeText(carried, "gamma-src").contains(gammaCheckout)

      # ---- (4) …and the refusal was SAID --------------------------------
      var refusal = ""
      for line in committed.output.splitLines():
        if line.contains("flake.lock input 'gamma-src'") and
            line.contains("behind by 2 commit(s)"):
          refusal = line
      checkpoint("refusal line: " & refusal)
      check refusal.contains(gammaPinned)
      check refusal.contains(gammaCheckout)
      check committed.output.contains("REPRO_ALLOW_PIN_REGRESSION=gamma-src")
      let logLine = lastFlakeLogLine(fx)
      checkpoint("last flake-lock log line: " & logLine)
      check logLine.len > 0
      check logLine.contains("refused-pin-regression")
      check logLine.contains("gamma-src behind by 2 commit(s)")

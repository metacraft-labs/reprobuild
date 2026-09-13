## NF-2 — **the asymmetry: a sibling whose revision IS published is still
## recorded.**
##
## Spec: Nix-Flake-Coexistence.md §3.1 ("a sibling ahead means you are
## developing; committing here records it in flake.lock") held against
## Workspace-And-Develop-Mode.md §"Reproducibility And `repro check`" ("dirty
## **or only locally committed**").
##
## ## Why this case exists
##
## `t_an_unpushed_sibling_revision_is_not_recorded` is satisfied by an
## implementation that stopped recording anything at all — and NF-2's whole
## purpose is to record. Every skip this campaign added has an asymmetry case
## for exactly this reason (`t_an_ahead_sibling_is_still_recorded` guards the
## behind-pin skip the same way), because a guard that fires on everything is
## indistinguishable, from the lock's point of view, from a guard that works.
##
## The two arrangements differ in exactly ONE real operation: a `git push` to a
## real bare origin. Nothing else about the sibling, the lock, the flake or the
## commit changes between them, so what is being isolated is publication and
## nothing else.
##
## ## What is asserted
##
##   1. the arrangement really is one — the sibling's HEAD IS reachable from a
##      remote-tracking ref, asked with git's own predicate;
##   2. the pin MOVES to that revision, in the working tree;
##   3. …and the COMMIT carries it, which is the §13.1 property (the lock is
##      part of the revision being formed, not a modification left behind);
##   4. nothing is withheld and no unpublished warning is printed — a refresh
##      that recorded the pin AND warned about it would be telling the operator
##      to fix something it had already filed;
##   5. `narHash`, `lastModified` and `revCount` are dropped from the moved
##      node, which is the existing NF-2 contract this case must not silently
##      lose.
##
## ## Mutation
##
## Skip pushed siblings too — make `flakeRowIsRecordable` return false for every
## row whose publication was examined, or set `unpublished` unconditionally in
## `flakeAnnotatePublication` ⇒ RED on (2), (3) and (4): the pin does not move
## and a notice is printed about a revision that is on the origin.
##
## Test-double policy: NO mocks, doubles or fakes. See the headers of
## `nf2_flake_lock_fixture.nim` and `nf3_override_state_fixture.nim`.

import std/[os, strutils, unittest]

import nf3_override_state_fixture

suite "NF-2: a pushed sibling is still recorded":

  test "t_a_pushed_sibling_is_still_recorded":
    const caseName = "t_a_pushed_sibling_is_still_recorded"
    if not nf2Prerequisites(caseName):
      skip()
    else:
      let fx = setupNf2Fixture("pushed-still-recorded")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      commitLockAndPublish(fx, "a lock that names every sibling's seed")
      let before = readFile(lockPath(fx))
      check nodeText(before, "gamma-src").contains(fx.seedSha[2])

      # The ONE difference from `t_an_unpushed_sibling_revision_is_not_recorded`
      # is the real `git push` inside this helper.
      let published = advancePublishedSibling(fx, "gamma", 1)
      check published != fx.seedSha[2]

      # ---- (1) the arrangement is what the case claims ------------------
      check siblingRevIsPublished(fx, "gamma", published)

      let committed = tryCommitInApp(fx, "work built against a pushed gamma")
      checkpoint("commit output:\n" & committed.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check committed.code == 0

      # ---- (2) the pin MOVED --------------------------------------------
      let after = readFile(lockPath(fx))
      let gammaAfter = nodeText(after, "gamma-src")
      checkpoint("gamma-src AFTER:\n" & gammaAfter)
      check gammaAfter.contains(published)
      check not gammaAfter.contains(fx.seedSha[2])

      # …and only that node: the rest of the document is untouched.
      let gammaBefore = nodeText(before, "gamma-src")
      check gammaBefore.len > 0
      check before.replace(gammaBefore, gammaAfter) == after

      # ---- (3) the COMMIT carries it ------------------------------------
      check lockInCommit(fx) == after

      # ---- (4) nothing was withheld -------------------------------------
      for line in committed.output.splitLines():
        if line.contains("NOT refreshed"):
          checkpoint("unexpected withheld notice: " & line)
        check not line.contains("NOT refreshed")
      check not committed.output.contains("ONLY in this local checkout")
      let logLine = lastFlakeLogLine(fx)
      checkpoint("last flake-lock log line: " & logLine)
      check logLine.contains("flake-lock refreshed")
      check not logLine.contains("WITHHELD")

      # ---- (5) the unverifiable fields were dropped ---------------------
      check not gammaAfter.contains("narHash")
      check not gammaAfter.contains("lastModified")
      check not gammaAfter.contains("revCount")

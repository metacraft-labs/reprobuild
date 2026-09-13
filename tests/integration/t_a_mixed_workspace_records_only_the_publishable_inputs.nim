## NF-2 — **one refresh, four siblings on two axes, and only the publishable
## input moves.**
##
## Spec: Nix-Flake-Coexistence.md §3.1 / §3.2 for the DIRECTION axis, and
## Workspace-And-Develop-Mode.md §"Reproducibility And `repro check`" — a
## develop-mode dependency that is "dirty **or only locally committed**" is not
## lockable for other people yet — for the PUBLICATION axis.
##
##   | sibling AHEAD of its pin, PUBLISHED   | recorded                     |
##   | sibling AHEAD of its pin, unpushed    | withheld (nobody can fetch it) |
##   | sibling BEHIND its pin                | withheld (your checkout is stale) |
##   | sibling AT its pin                    | untouched, not rewritten equal |
##   | a DIRTY sibling in the develop closure | the whole refresh is skipped |
##
## ## Why they have to meet in one refresh
##
## `t_a_mixed_workspace_records_only_the_ahead_inputs` makes this argument for
## the direction axis and it transfers unchanged: each single-sibling case is
## satisfied by an implementation that decides ONCE PER REFRESH — "withhold
## everything if anything is unpublished" passes every one of them and is
## catastrophic in a real workspace, where several of 86 flake-carrying repos
## are always drifting at once. The measured defect was exactly that shape: on
## 2026-09-13 `runquota`, `codetracer` and `codetracer-native-recorder` were all
## unpushed in the same moment while other siblings were fine.
##
## ## Why the dirty sibling gets its own phase
##
## The dirty-sibling policy is deliberately COARSER than the others: it is not a
## per-input withholding but a whole-refresh skip, because a modified working
## tree in the develop-set closure means the build the lock would describe is
## not the build that ran. So "pushed / unpushed / behind / dirty in one
## refresh" cannot mean "the publishable ones moved" — with dirt in scope
## NOTHING may move, and asserting otherwise would assert a policy this system
## does not have. Both facts are checked, in order:
##
##   * PHASE 1, dirt present: the file is byte-identical, including the input
##     that would otherwise have been recorded. The coarse policy dominates.
##   * PHASE 2, the same workspace with the dirt cleaned and nothing else
##     changed: exactly the publishable input moves and every other node is
##     byte-identical.
##
## ## What is asserted
##
##   1. each arrangement really is one: alpha's HEAD IS reachable from a
##      remote-tracking ref and beta's is NOT, asked with git's own predicate;
##   2. PHASE 1 — the dirty sibling blocks everything: whole-file byte-identity,
##      and the skip names `epsilon`;
##   3. PHASE 2 — exactly `alpha-src` moved, to alpha's published `HEAD`;
##   4. every other node — the unpublished one, the behind one, the at-pin one,
##      and the two non-sibling inputs — is BYTE-identical, and so is the whole
##      rest of the document (a stronger statement than four node comparisons:
##      it also catches reserialisation and member reordering elsewhere);
##   5. the two withheld inputs are named with DIFFERENT reasons — the
##      unpublished one with its revision and the push, the behind one with its
##      distance. Two skips that read alike leave an operator unable to tell
##      which remedy to apply.
##
## ## Mutation
##
## Make the publication decision per-refresh rather than per-input (withhold
## every input as soon as any row is unpublished) ⇒ RED on (3): `alpha-src`
## still names the old revision, and §3.1 is silently gone for the whole
## workspace whenever one sibling has an unpushed commit — which, in a workspace
## where you are developing, is most of the time.
##
## Test-double policy: NO mocks, doubles or fakes. See the headers of
## `nf2_flake_lock_fixture.nim` and `nf3_override_state_fixture.nim`. The
## four-input flake is written with the same generators the three-input one is,
## against the same real origins; the publication difference between alpha and
## beta is a real `git push` to a real bare repository.

import std/[os, strutils, unittest]

import nf3_override_state_fixture

suite "NF-2: a mixed workspace records only the publishable inputs":

  test "t_a_mixed_workspace_records_only_the_publishable_inputs":
    const caseName = "t_a_mixed_workspace_records_only_the_publishable_inputs"
    if not nf2Prerequisites(caseName):
      skip()
    else:
      let fx = setupNf2Fixture("mixed-publishable")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      # gamma: BEHIND by 3, with the pinned objects present locally.
      let gammaPinned = advanceSibling(fx, "gamma", 3)
      check rewindSibling(fx, "gamma", 3) == fx.seedSha[2]
      # delta is left exactly AT its pin; alpha and beta are pinned at their
      # seeds and moved forward below — one published, one not.
      useFourInputFlake(fx, fx.seedSha[0], fx.seedSha[1], gammaPinned,
        fx.seedSha[3])
      commitLockAndPublish(fx, "a four-input flake with siblings all over")

      let before = readFile(lockPath(fx))

      let alphaHead = advancePublishedSibling(fx, "alpha", 2)
      let betaHead = advanceSibling(fx, "beta", 2)
      check alphaHead != fx.seedSha[0]
      check betaHead != fx.seedSha[1]

      # ---- (1) the arrangements are what the case claims ----------------
      check siblingRevIsPublished(fx, "alpha", alphaHead)
      check not siblingRevIsPublished(fx, "beta", betaHead)

      # ==== PHASE 1: a dirty sibling in the closure blocks everything ====
      dirtySibling(fx, "epsilon")
      let blocked = tryCommitInApp(fx, "work while epsilon is dirty")
      checkpoint("phase-1 commit output:\n" & blocked.output)
      checkpoint("phase-1 pre-commit log:\n" & preCommitLog(fx))
      check blocked.code == 0

      # ---- (2) whole-file byte-identity, and the skip names epsilon -----
      let duringDirt = readFile(lockPath(fx))
      if duringDirt != before:
        checkpoint("alpha-src DURING DIRT:\n" & nodeText(duringDirt, "alpha-src"))
      check duringDirt == before
      check lockInCommit(fx) == before
      let dirtLine = lastFlakeLogLine(fx)
      checkpoint("phase-1 last flake-lock log line: " & dirtLine)
      check dirtLine.contains("skipped-dirty-sibling")
      check dirtLine.contains("epsilon")

      # ==== PHASE 2: the same workspace, dirt cleaned, nothing else ======
      discard gitIn(fx, siblingDir(fx, "epsilon"), "checkout -- .")
      let refreshed = firePreCommitHook(fx)
      checkpoint("phase-2 hook output:\n" & refreshed.output)
      check refreshed.code == 0

      let after = readFile(lockPath(fx))

      # ---- (3) exactly the PUBLISHABLE input moved -----------------------
      let alphaAfter = nodeText(after, "alpha-src")
      checkpoint("alpha-src AFTER:\n" & alphaAfter)
      check alphaAfter.contains(alphaHead)
      check not alphaAfter.contains(fx.seedSha[0])

      # ---- (4) every other node is BYTE-identical ------------------------
      for node in ["beta-src", "gamma-src", "delta-src", "flake-utils",
                   "nixpkgs"]:
        let was = nodeText(before, node)
        let now = nodeText(after, node)
        check was.len > 0
        if was != now:
          checkpoint(node & " BEFORE:\n" & was & "\n" & node & " AFTER:\n" & now)
        check was == now
      check nodeText(after, "beta-src").contains(fx.seedSha[1])
      check not after.contains(betaHead)
      check nodeText(after, "gamma-src").contains(gammaPinned)
      check nodeText(after, "delta-src").contains(fx.seedSha[3])

      # …and so is the whole rest of the document.
      let alphaBefore = nodeText(before, "alpha-src")
      check alphaBefore.len > 0
      check before.replace(alphaBefore, alphaAfter) == after

      # ---- (5) two withheld inputs, two DIFFERENT reasons ----------------
      var unpublishedNotice, behindNotice: string
      for line in refreshed.output.splitLines():
        if not line.contains("NOT refreshed"): continue
        if line.contains("beta-src"): unpublishedNotice = line
        if line.contains("gamma-src"): behindNotice = line
      checkpoint("unpublished notice: " & unpublishedNotice)
      checkpoint("behind notice: " & behindNotice)
      check unpublishedNotice.contains("ONLY in this local checkout")
      check unpublishedNotice.contains(betaHead)
      check unpublishedNotice.contains(" push ")
      check behindNotice.contains("3 commit(s) BEHIND")
      check not behindNotice.contains("ONLY in this local checkout")
      check unpublishedNotice != behindNotice

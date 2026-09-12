## NF-2 — **the asymmetry: an AHEAD sibling is still recorded.**
##
## Spec: Nix-Flake-Coexistence.md §3.1 ("What you built and tested is not what
## you published") and §3.2 ("A sibling **ahead** means *you are developing*. A
## sibling **behind** almost always means *your checkout is stale* … so the two
## warrant different treatment").
##
## ## Why this case exists beside the behind-pin cases
##
## The fix for the behind-pin defect withholds an input's refresh. The cheapest
## way to make every behind-pin assertion pass is to withhold every input's
## refresh — which would delete NF-2 entirely while leaving its test suite green
## in the direction the new cases look. The asymmetry IS the policy, so it needs
## a case that fails when the ahead half is lost.
##
## `t_commit_records_the_sibling_revision_the_shell_actually_used` asserts the
## same direction in far more detail (the dropped `narHash`/`lastModified`/
## `revCount`, the untouched sibling nodes, the staging, `git commit -a`). This
## case is deliberately narrow: it is the guard rail on the withholding change,
## and it states in one place that "not recordable" did not quietly grow to mean
## "nothing is recordable".
##
## ## What is asserted
##
##   1. an ahead sibling's pin MOVES to the sibling's `HEAD` — in the working
##      tree and in the blob the commit carries;
##   2. it moves for an ahead sibling standing beside a behind one in the same
##      workspace, because the withholding is per-INPUT and a per-REFRESH
##      implementation of it would pass a single-sibling case and lose §3.1 the
##      moment anything else drifted;
##   3. the refresh announces itself, naming the input and both revisions.
##
## ## Mutation
##
## Withhold ahead siblings too (add `fprAhead` to the not-recordable set) ⇒ RED
## on (1) and (2): the pin still names the old revision.
##
## Test-double policy: NO mocks, doubles or fakes. See the headers of
## `nf2_flake_lock_fixture.nim` and `nf3_override_state_fixture.nim`.

import std/[os, strutils, unittest]

import nf3_override_state_fixture

suite "NF-2: an ahead sibling is still recorded":

  test "t_an_ahead_sibling_is_still_recorded":
    const caseName = "t_an_ahead_sibling_is_still_recorded"
    if not nf2Prerequisites(caseName):
      skip()
    else:
      let fx = setupNf2Fixture("ahead-still-recorded")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      # gamma is left BEHIND its pin, in the same refresh, so the ahead half is
      # asserted in the presence of the case that withholds.
      let gammaPinned = advanceSibling(fx, "gamma", 2)
      discard rewindSibling(fx, "gamma", 2)
      setFlakePins(fx, fx.seedSha[0], fx.seedSha[1], gammaPinned)
      commitLockAndPublish(fx, "a lock pinned ahead of the gamma checkout")

      # alpha moves FORWARD: this is §3.1's situation exactly — the shell builds
      # this revision and the lock still names the older one.
      let alphaHead = advanceSibling(fx, "alpha", 1)
      check alphaHead != fx.seedSha[0]

      let committed = tryCommitInApp(fx, "work built against the newer alpha")
      checkpoint("commit output:\n" & committed.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check committed.code == 0

      # ---- (1) the pin MOVED, in the tree and in the commit --------------
      let after = readFile(lockPath(fx))
      let alphaNode = nodeText(after, "alpha-src")
      checkpoint("alpha-src AFTER:\n" & alphaNode)
      check alphaNode.contains(alphaHead)
      check not alphaNode.contains(fx.seedSha[0])

      let carried = lockInCommit(fx)
      check carried.len > 0
      check nodeText(carried, "alpha-src").contains(alphaHead)

      # ---- (2) …while the behind sibling beside it kept its pin ----------
      check nodeText(after, "gamma-src").contains(gammaPinned)
      check nodeText(carried, "gamma-src").contains(gammaPinned)

      # ---- (3) and the refresh said so ----------------------------------
      let logLine = lastFlakeLogLine(fx)
      checkpoint("last flake-lock log line: " & logLine)
      check logLine.contains("alpha-src")
      check logLine.contains(alphaHead)

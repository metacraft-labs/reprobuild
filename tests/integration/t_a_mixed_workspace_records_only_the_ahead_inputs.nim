## NF-2 — **one refresh, four siblings, four different answers.**
##
## Spec: Nix-Flake-Coexistence.md §3.1 and §3.2 (including §3.2's "Rule, at
## commit", owner-decided 2026-09-30). The case holds all four at once:
##
##   | sibling AHEAD of its pin       | recorded (§3.1 — you are developing)    |
##   | sibling AT its pin             | untouched, not even rewritten equal    |
##   | sibling BEHIND its pin         | refuses the commit (a downgrade)       |
##   | sibling whose pin is unfetched | refuses the commit (unprovable)        |
##
## ## Why the four have to meet in one refresh
##
## Each of the other cases moves one sibling and holds the rest still, so each
## of them is satisfied by implementations that get the COMBINATION wrong — "a
## regression anywhere records nothing, and says nothing", or "record every
## ahead input even when the commit is refused", or "once the regressions are
## resolved, record only what moved last". A real workspace has several
## siblings drifting in different directions at once: the defect that motivated
## the behind-pin rule was found where `codetracer` (742 behind) and `io-mon`
## (4 behind) were rewritten downwards during commits whose subject was a third
## repo entirely.
##
## ## What is asserted
##
##   PHASE 1 — the refusal.
##   1. the commit is refused, and `flake.lock` is BYTE-identical: a refused
##      commit writes nothing, not even the ahead input it would have recorded;
##   2. BOTH regressions are named, each with its own reason — the behind one
##      with its distance, the unfetched one with the absent commit and the
##      fetch it needs. Two refusals that read alike would leave an operator
##      unable to tell which remedy to apply.
##
##   PHASE 2 — the same workspace once both checkouts are brought forward by
##   the commands the refusal named (a fast-forward, a fetch).
##   3. exactly the AHEAD input's node moved, to that sibling's `HEAD`;
##   4. every other node — the at-pin sibling, the two siblings now at their
##      pins, and the two non-sibling inputs — is BYTE-identical, and the file
##      after the refresh is the file before it with ONE node substituted;
##   5. the commit carries that file.
##
## ## Mutations
##
##   * record the ahead input even though the commit is refused ⇒ RED on (1);
##   * render one reason for both regressions ⇒ RED on (2);
##   * decide per refresh rather than per input once nothing regresses ⇒ RED on
##     (3).
##
## Test-double policy: NO mocks, doubles or fakes. See the headers of
## `nf2_flake_lock_fixture.nim` and `nf3_override_state_fixture.nim`. The
## four-input flake this case installs is written with the same generators the
## three-input one is (`lockedNode`, `originUrl`), against the same real
## origins; it is an additional real input, not a stand-in for one.

import std/[os, strutils, unittest]

import nf3_override_state_fixture

proc lineWith(text: string; needles: varargs[string]): string =
  for line in text.splitLines():
    var all = true
    for n in needles:
      if n notin line:
        all = false
        break
    if all: return line
  ""

suite "NF-2: a mixed workspace records only the ahead inputs":

  test "t_a_mixed_workspace_records_only_the_ahead_inputs":
    const caseName = "t_a_mixed_workspace_records_only_the_ahead_inputs"
    if not nf2Prerequisites(caseName):
      skip()
    else:
      let fx = setupNf2Fixture("mixed-refresh")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      # gamma: BEHIND by 3, with the pinned objects present locally.
      let gammaPinned = advanceSibling(fx, "gamma", 3)
      check rewindSibling(fx, "gamma", 3) == fx.seedSha[2]
      # delta: its ORIGIN moves 4 ahead and the checkout never fetches, so the
      # pin about to be written is not in delta's object store.
      let deltaPinned = advanceOriginWithoutFetching(fx, "delta", 4)
      check not pinIsFetched(fx, "delta", deltaPinned)

      # beta is left exactly AT its pin, and alpha is pinned at its seed and
      # moved forward below — so the single refresh sees one of each.
      useFourInputFlake(fx, fx.seedSha[0], fx.seedSha[1], gammaPinned,
        deltaPinned)
      commitLockAndPublish(fx, "a four-input flake with siblings all over")

      let before = readFile(lockPath(fx))
      let alphaHead = advancePublishedSibling(fx, "alpha", 2)
      check alphaHead != fx.seedSha[0]

      # ==== PHASE 1: the refusal ==========================================
      let headBefore = headOf(fx, fx.app)
      let refused = tryCommitInApp(fx, "work built against the newer alpha")
      checkpoint("commit output:\n" & refused.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))

      # ---- (1) refused, and nothing written -----------------------------
      check refused.code != 0
      check refused.head == headBefore
      check readFile(lockPath(fx)) == before
      check not readFile(lockPath(fx)).contains(alphaHead)

      # ---- (2) both regressions named, with different reasons -----------
      let behindLine = lineWith(refused.output,
        "flake.lock input 'gamma-src'")
      let unfetchedLine = lineWith(refused.output,
        "flake.lock input 'delta-src'")
      checkpoint("behind line: " & behindLine)
      checkpoint("unfetched line: " & unfetchedLine)
      check behindLine.contains("behind by 3 commit(s)")
      check unfetchedLine.contains("pinned commit " & deltaPinned &
        " not present in")
      check not unfetchedLine.contains("behind by")
      check behindLine != unfetchedLine
      # One variable naming both, in the order the refusal lists them.
      check refused.output.contains(
        "REPRO_ALLOW_PIN_REGRESSION=delta-src,gamma-src git commit")

      # ==== PHASE 2: both checkouts brought forward ======================
      discard gitIn(fx, siblingDir(fx, "gamma"),
        "merge -q --ff-only " & gammaPinned)
      discard gitIn(fx, siblingDir(fx, "delta"), "fetch -q --all")
      discard gitIn(fx, siblingDir(fx, "delta"),
        "merge -q --ff-only " & deltaPinned)
      let committed = run(q(fx.gitBin) & " -C " & q(fx.app) &
        " commit -q -m " & q("work built against the newer alpha"))
      checkpoint("second commit output:\n" & committed.output)
      check committed.code == 0

      let after = readFile(lockPath(fx))

      # ---- (3) exactly the AHEAD input moved ----------------------------
      let alphaAfter = nodeText(after, "alpha-src")
      checkpoint("alpha-src AFTER:\n" & alphaAfter)
      check alphaAfter.contains(alphaHead)
      check not alphaAfter.contains(fx.seedSha[0])

      # ---- (4) every other node is BYTE-identical -----------------------
      for node in ["beta-src", "gamma-src", "delta-src", "flake-utils",
                   "nixpkgs"]:
        let was = nodeText(before, node)
        let now = nodeText(after, node)
        check was.len > 0
        if was != now:
          checkpoint(node & " BEFORE:\n" & was & "\n" & node & " AFTER:\n" & now)
        check was == now
      check nodeText(after, "gamma-src").contains(gammaPinned)
      check nodeText(after, "delta-src").contains(deltaPinned)
      check nodeText(after, "beta-src").contains(fx.seedSha[1])
      let alphaBefore = nodeText(before, "alpha-src")
      check alphaBefore.len > 0
      check before.replace(alphaBefore, alphaAfter) == after

      # ---- (5) the commit carries it -------------------------------------
      check lockInCommit(fx) == after

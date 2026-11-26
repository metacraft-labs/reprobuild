## NF-2 — **one refresh, four siblings, four different answers.**
##
## Spec: Nix-Flake-Coexistence.md §3.1 and §3.2 (including §3.2's "Rule, at
## commit", owner-decided 2026-09-30 and amended 2026-11-25). The case holds
## all four at once:
##
##   | sibling AHEAD of its pin       | recorded (§3.1 — you are developing)    |
##   | sibling AT its pin             | untouched, not even rewritten equal    |
##   | sibling BEHIND its pin         | withheld: pin kept (a downgrade)       |
##   | sibling whose pin is unfetched | withheld: pin kept (unprovable)        |
##
## ## Why the four have to meet in one refresh
##
## Each of the other cases moves one sibling and holds the rest still, so each
## of them is satisfied by implementations that get the COMBINATION wrong — "a
## regression anywhere records nothing, and says nothing", or "a kept pin
## holds back the ahead input too", or "record every input once one moves". A
## real workspace has several siblings drifting in different directions at
## once: the defect that motivated the behind-pin rule was found where
## `codetracer` (742 behind) and `io-mon` (4 behind) were rewritten downwards
## during commits whose subject was a third repo entirely — and a shared
## workspace root routinely holds checkouts behind the committing repo's pins.
##
## ## What is asserted
##
##   PHASE 1 — the commit, with both regressions present.
##   1. the commit is made, and exactly the AHEAD input's node moved, to that
##      sibling's `HEAD`;
##   2. every other node — the at-pin sibling, the two kept siblings, and the
##      two non-sibling inputs — is BYTE-identical, and the file after the
##      refresh is the file before it with ONE node substituted; the commit
##      carries that file;
##   3. BOTH kept pins are named, each with its own reason — the behind one
##      with its distance, the unfetched one with the fetch it needs — and
##      each with the variable naming that input. Two notices that read alike
##      would leave an operator unable to tell which remedy to apply.
##
##   PHASE 2 — the same workspace once both checkouts are brought forward by
##   the commands the notices named (a fast-forward, a fetch).
##   4. the next commit withholds nothing and leaves the lock byte-identical:
##      both siblings are now at their pins.
##
## ## Mutations
##
##   * hold the ahead input back whenever another input regresses ⇒ RED on
##     (1);
##   * record the behind input's checkout ⇒ RED on (2);
##   * render one reason for both regressions ⇒ RED on (3).
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

      # ==== PHASE 1: the commit =========================================
      let headBefore = headOf(fx, fx.app)
      let committed = tryCommitInApp(fx, "work built against the newer alpha")
      checkpoint("commit output:\n" & committed.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check committed.code == 0
      check committed.head != headBefore
      check not committed.output.contains("REFUSED")

      let after = readFile(lockPath(fx))

      # ---- (1) exactly the AHEAD input moved ----------------------------
      let alphaAfter = nodeText(after, "alpha-src")
      checkpoint("alpha-src AFTER:\n" & alphaAfter)
      check alphaAfter.contains(alphaHead)
      check not alphaAfter.contains(fx.seedSha[0])

      # ---- (2) every other node is BYTE-identical -----------------------
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
      check lockInCommit(fx) == after

      # ---- (3) both kept pins named, with different reasons -------------
      let behindLine = lineWith(committed.output,
        "flake.lock NOT refreshed for input 'gamma-src'")
      let unfetchedLine = lineWith(committed.output,
        "flake.lock NOT refreshed for input 'delta-src'")
      checkpoint("behind line: " & behindLine)
      checkpoint("unfetched line: " & unfetchedLine)
      check behindLine.contains("3 commit(s) BEHIND")
      check unfetchedLine.contains("CANNOT BE CLASSIFIED")
      check unfetchedLine.contains("fetch --all")
      check not unfetchedLine.contains("BEHIND")
      check behindLine != unfetchedLine
      check behindLine.contains(
        "REPRO_ALLOW_PIN_REGRESSION=gamma-src git commit --amend --no-edit")
      check unfetchedLine.contains(
        "REPRO_ALLOW_PIN_REGRESSION=delta-src git commit --amend --no-edit")

      # ==== PHASE 2: both checkouts brought forward ======================
      discard gitIn(fx, siblingDir(fx, "gamma"),
        "merge -q --ff-only " & gammaPinned)
      discard gitIn(fx, siblingDir(fx, "delta"), "fetch -q --all")
      discard gitIn(fx, siblingDir(fx, "delta"),
        "merge -q --ff-only " & deltaPinned)
      let again = tryCommitInApp(fx, "work after bringing both forward")
      checkpoint("second commit output:\n" & again.output)
      # ---- (4) nothing withheld, nothing moved ---------------------------
      check again.code == 0
      check not again.output.contains("NOT refreshed")
      check readFile(lockPath(fx)) == after
      check lockInCommit(fx) == after

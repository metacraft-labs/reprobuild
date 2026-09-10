## NF-2 — **one refresh, four siblings, four different answers.**
##
## Spec: Nix-Flake-Coexistence.md §3.1 and §3.2. The policy is a per-INPUT
## decision with four outcomes, and this is the case that holds all four at once:
##
##   | sibling AHEAD of its pin     | recorded (§3.1 — you are developing)   |
##   | sibling AT its pin           | untouched, not even rewritten equal   |
##   | sibling BEHIND its pin       | withheld (§3.2 — your checkout is stale) |
##   | sibling whose pin is unfetched | withheld (it cannot be classified)  |
##
## ## Why the four have to meet in one refresh
##
## Each of the other cases moves one sibling and holds the rest still, so each
## of them is satisfied by an implementation that decides ONCE PER REFRESH — for
## instance "withhold everything if anything is behind", or "record everything
## if anything is ahead". Both of those pass every single-sibling case and are
## catastrophic in a real workspace, where 86 repos carry a flake and several
## are always drifting in different directions at once. The defect that
## motivated this change was found in exactly such a workspace, where
## `codetracer` (742 behind) and `io-mon` (4 behind) were rewritten downwards
## during commits whose actual subject was a third repo entirely.
##
## ## What is asserted
##
##   1. exactly the AHEAD input's node moved, to that sibling's `HEAD`;
##   2. every other node — the at-pin sibling, the behind one, the unfetched
##      one, and the two non-sibling inputs — is BYTE-identical;
##   3. …and so is the rest of the document: the file after the refresh is the
##      file before it with ONE node substituted, which is a stronger statement
##      than four node comparisons (it also catches reserialisation, member
##      reordering and whitespace normalisation elsewhere);
##   4. the commit carries that file;
##   5. both withheld inputs are named, each with its own reason — the behind
##      one with its distance, the unfetched one with the fetch it needs. Two
##      skips that read alike would leave an operator unable to tell which
##      remedy to apply.
##
## ## Mutation
##
## Make the decision per-refresh rather than per-input (withhold everything as
## soon as any row is unrecordable) ⇒ RED on (1): `alpha-src` still names the
## old revision, and §3.1 is silently gone.
##
## Test-double policy: NO mocks, doubles or fakes. See the headers of
## `nf2_flake_lock_fixture.nim` and `nf3_override_state_fixture.nim`. The
## four-input flake this case installs is written with the same generators the
## three-input one is (`lockedNode`, `originUrl`), against the same real
## origins; it is an additional real input, not a stand-in for one.

import std/[os, strutils, unittest]

import nf3_override_state_fixture

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
      let alphaHead = advanceSibling(fx, "alpha", 2)
      check alphaHead != fx.seedSha[0]

      let committed = tryCommitInApp(fx, "work built against the newer alpha")
      checkpoint("commit output:\n" & committed.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check committed.code == 0

      let after = readFile(lockPath(fx))

      # ---- (1) exactly the AHEAD input moved ---------------------------
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

      # ---- (3) …and so is the whole rest of the document ----------------
      let alphaBefore = nodeText(before, "alpha-src")
      check alphaBefore.len > 0
      check before.replace(alphaBefore, alphaAfter) == after

      # ---- (4) the commit carries it ------------------------------------
      check lockInCommit(fx) == after

      # ---- (5) both withheld inputs are named, with different reasons ----
      var behindNotice, unfetchedNotice: string
      for line in committed.output.splitLines():
        if not line.contains("NOT refreshed"): continue
        if line.contains("gamma-src"): behindNotice = line
        if line.contains("delta-src"): unfetchedNotice = line
      checkpoint("behind notice: " & behindNotice)
      checkpoint("unfetched notice: " & unfetchedNotice)
      check behindNotice.contains("3 commit(s) BEHIND")
      check unfetchedNotice.contains("CANNOT BE CLASSIFIED")
      check not unfetchedNotice.contains("BEHIND")
      check behindNotice != unfetchedNotice

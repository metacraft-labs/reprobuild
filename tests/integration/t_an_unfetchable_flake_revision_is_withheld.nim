## NF-2 — **when nix cannot fetch the new revision, the pin is WITHHELD, not
## weakened.**
##
## Issue: reprobuild-pm `issues/2026-09-27-pre-commit-hook-repins-flake-lock-
## at-a-sibling-head-and-drops-narhash.md`. The refresh now writes the moved
## node's `narHash` / `lastModified` / `revCount` from what nix reports for the
## new revision. This case pins the other half of that contract: when nix
## cannot report them, the refresh must not fall back to the old behaviour of
## writing a `rev`-only node. It withholds that input through the same channel
## as every other §3.2 skip — lock byte-identical for it, commit proceeds, the
## skip SAID on stderr — and NF-3's pre-push gate refuses the lock that now
## lags its sibling, so nothing escapes.
##
## ## How the fetch is made to fail, and why that way
##
## The sibling's revision is pushed to its real bare origin, so every check
## the refresh makes BEFORE asking nix passes honestly: the sibling is ahead,
## and its HEAD is reachable from `refs/remotes/origin/main` (publication is
## judged from local remote-tracking refs, never over the network). Then the
## origin directory is moved aside. That is the real shape of "the forge is
## unreachable": the flake input's URL names a place nix cannot fetch from,
## and nix's own error says so. No component is replaced and nothing is
## stubbed — nix is the real nix, failing for a real reason. Moving the origin
## BACK then shows the stated remedy works.
##
## ## What is asserted
##
##   1. the commit SUCCEEDS;
##   2. the committed `flake.lock` and the working-tree file are byte-identical
##      to before — the old node, `narHash` and all;
##   3. stderr names the input, the revision, nix's error, and the remedy
##      (`repro flake refresh-lock --flake=<flake dir> --workspace-root=…`);
##   4. the operator verb withholds the same way and exits
##      `flakeRefreshWithheldExit` (3) — the lock is not correct afterwards;
##   5. with the origin restored, the remedy the message names moves the pin
##      and writes the derived fields (exit 0).
##
## ## Mutation
##
## Write the node without the derived fields when the fetch fails ⇒ (2) RED.
## Swallow the fetch error ⇒ (3) RED.
##
## Test-double policy: NO mocks, doubles or fakes; see the fixture header.
## Needs nix and SKIPS LOUDLY without it.

import std/[json, os, strutils, unittest]

import nf2_flake_lock_fixture
import repro_test_support/reasoned_skip

const caseName = "t_an_unfetchable_flake_revision_is_withheld"

suite "NF-2: an unfetchable revision is withheld, not weakened":

  test "t_an_unfetchable_flake_revision_is_withheld":
    if not nf2Prerequisites(caseName):
      skip("git or the built ./build/bin/repro is missing (named above)")
    elif findExe("nix").len == 0:
      echo "SKIPPED (loudly): " & caseName & " needs `nix` on PATH: the " &
        "subject is what the refresh does when NIX fails to fetch a " &
        "revision. nix=MISSING. NOT CHECKED by this run."
      skip("nix is not on PATH; this case is about nix failing to fetch")
    else:
      let fx = setupNf2Fixture("unfetchable")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      let before = readFile(lockPath(fx))
      let newAlpha = moveAndPublishSibling(fx, "alpha", "revision 2")
      check siblingRevIsPublished(fx, "alpha", newAlpha)

      let origin = fx.scratch / "origin-alpha.git"
      let away = fx.scratch / "origin-alpha.unreachable"
      moveDir(origin, away)

      let commit = tryCommitInApp(fx, "work while the forge is down")
      checkpoint("commit output:\n" & commit.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))

      # ---- (1) the commit proceeds ---------------------------------------
      check commit.code == 0

      # ---- (2) the lock is untouched, in the commit and on disk -----------
      check lockInCommit(fx) == before
      check readFile(lockPath(fx)) == before
      check gitIn(fx, fx.app, "status --porcelain").strip() == ""

      # ---- (3) said, with the reason and the remedy -----------------------
      var notice = ""
      for line in commit.output.splitLines():
        if line.contains("NOT refreshed") and line.contains("alpha-src"):
          notice = line
      checkpoint("notice: " & notice)
      check notice.len > 0
      check notice.startsWith("repro pre-commit:")
      check notice.contains(newAlpha)
      # nix's own error, not a paraphrase of it.
      check notice.contains("does not exist")
      check notice.contains("repro flake refresh-lock --flake=" & fx.app &
        " --workspace-root=" & fx.ws)
      check lastFlakeLogLine(fx).contains("alpha-src")

      # ---- (4) the operator verb withholds identically --------------------
      let verb = run(q(fx.repro) & " flake refresh-lock --flake=" & q(fx.app),
        cwd = fx.app)
      checkpoint("refresh-lock (origin away):\n" & verb.output)
      check verb.code == 3
      check verb.output.contains("NOT refreshed")
      check readFile(lockPath(fx)) == before

      # ---- (5) the remedy works once the revision is fetchable ------------
      moveDir(away, origin)
      let remedy = run(q(fx.repro) & " flake refresh-lock --flake=" &
        q(fx.app) & " --workspace-root=" & q(fx.ws), cwd = fx.app)
      checkpoint("refresh-lock (origin back):\n" & remedy.output)
      check remedy.code == 0
      let alphaLocked = parseJson(readFile(lockPath(fx)))["nodes"][
        "alpha-src"]["locked"]
      check alphaLocked["rev"].getStr() == newAlpha
      check alphaLocked.hasKey("narHash")
      check alphaLocked.hasKey("lastModified")
      check alphaLocked.hasKey("revCount")

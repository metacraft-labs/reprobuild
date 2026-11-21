## **`REPRO_SKIP_LOCK_REFRESH` makes one commit leave `flake.lock` alone.**
##
## Issue: reprobuild-pm `issues/2026-09-27-pre-commit-hook-repins-flake-lock-
## at-a-sibling-head-and-drops-narhash.md` — "a commit whose *stated* scope is
## 'no dependency pin change' cannot be produced from a workspace checkout at
## all". The hook re-pins every moved sibling into every commit, and there was
## no way to say "not in this one".
##
## ## What is asserted
##
##   1. `REPRO_SKIP_LOCK_REFRESH=1 git commit` with a sibling AHEAD of its pin
##      succeeds, and the commit's `flake.lock` is byte-identical to the one
##      before — and so is the working-tree file (nothing written, nothing
##      staged, nothing left behind for the next commit to sweep up);
##   2. the hook SAYS it skipped, naming the variable, the lock it would have
##      touched, and that the pre-push gate refuses until the pins are
##      recorded;
##   3. the opt-out covers ONE commit: the next commit without the variable
##      records the pin (and `REPRO_SKIP_LOCK_REFRESH=0` is "not set");
##   4. it skips the writers, not the checks: an opted-out commit carrying an
##      H1-inconsistent `flake.lock` is still refused (§16.3 H1 / H2).
##
## ## Mutation
##
## Ignore the variable ⇒ (1) RED: the commit carries the moved `alpha-src`
## node. Skip silently ⇒ (2) RED.
##
## Test-double policy: NO mocks, doubles or fakes; see the header of
## `nf2_flake_lock_fixture.nim`. Arm (3) records a pin, which needs nix to
## compute the node's narHash; without nix it is SKIPPED LOUDLY and arms (1)
## and (2) still run.

import std/[json, os, strutils, unittest]

import nf2_flake_lock_fixture
import repro_test_support/reasoned_skip

const caseName = "t_skip_lock_refresh_leaves_the_flake_lock_alone"

suite "REPRO_SKIP_LOCK_REFRESH: one commit leaves flake.lock alone":

  test "t_skip_lock_refresh_leaves_the_flake_lock_alone":
    if not nf2Prerequisites(caseName):
      skip("git or the built ./build/bin/repro is missing (named above)")
    else:
      let fx = setupNf2Fixture("skip-refresh")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      let before = readFile(lockPath(fx))
      let newAlpha = moveAndPublishSibling(fx, "alpha", "revision 2")

      # ---- (1) the opted-out commit carries the lock unchanged ----------
      putEnv("REPRO_SKIP_LOCK_REFRESH", "1")
      let skipped = tryCommitInApp(fx, "a commit with no pin change")
      delEnv("REPRO_SKIP_LOCK_REFRESH")
      checkpoint("commit output:\n" & skipped.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check skipped.code == 0
      check lockInCommit(fx) == before
      check readFile(lockPath(fx)) == before
      check gitIn(fx, fx.app, "status --porcelain").strip() == ""
      check "flake.lock" notin gitIn(fx, fx.app,
        "show --name-only --format= HEAD")

      # ---- (2) …and says so --------------------------------------------
      var notice = ""
      for line in skipped.output.splitLines():
        if line.startsWith("repro pre-commit:") and
            line.contains("REPRO_SKIP_LOCK_REFRESH"):
          notice = line
      checkpoint("notice: " & notice)
      check notice.len > 0
      check notice.contains("flake.lock")
      check notice.contains("pre-push")

      # ---- (3) one commit only -----------------------------------------
      if findExe("nix").len == 0:
        echo "SKIPPED (loudly): arm (3) of " & caseName & " records a pin, " &
          "which needs `nix` to compute the moved node's narHash. " &
          "nix=MISSING. NOT CHECKED by this run: that the opt-out lasts " &
          "exactly one commit."
      else:
        putEnv("REPRO_SKIP_LOCK_REFRESH", "0")
        let next = tryCommitInApp(fx, "the next commit records the pin")
        delEnv("REPRO_SKIP_LOCK_REFRESH")
        checkpoint("next commit output:\n" & next.output)
        check next.code == 0
        let carried = parseJson(lockInCommit(fx))
        check carried["nodes"]["alpha-src"]["locked"]["rev"].getStr() ==
          newAlpha
        check "flake.lock" in gitIn(fx, fx.app,
          "show --name-only --format= HEAD")

      # ---- (4) …and waives no CHECK ------------------------------------
      # The opt-out skips the writers, not the recipe/lock consistency rules
      # (§16.3 H1 / H2), which judge the locks the commit carries. A staged
      # `flake.lock` whose `alpha-src` node states one revision in `locked`
      # and another in `original` is H1-inconsistent; the opted-out commit is
      # refused exactly as an ordinary one would be.
      let current = readFile(lockPath(fx))
      let node = nodeText(current, "alpha-src")
      let lockedRev = parseJson(current)["nodes"]["alpha-src"]["locked"][
        "rev"].getStr()
      let otherRev = if lockedRev == fx.seedSha[0]: newAlpha else: fx.seedSha[0]
      let marker = "\"original\": {\n        \"ref\": \"main\",\n"
      check marker in node
      writeFile(lockPath(fx), current.replace(node, node.replace(marker,
        marker & "        \"rev\": \"" & otherRev & "\",\n")))
      let headBefore = gitIn(fx, fx.app, "rev-parse HEAD").strip()
      putEnv("REPRO_SKIP_LOCK_REFRESH", "1")
      let inconsistent = tryCommitInApp(fx, "an inconsistent lock")
      delEnv("REPRO_SKIP_LOCK_REFRESH")
      checkpoint("inconsistent commit output:\n" & inconsistent.output)
      check inconsistent.code != 0
      check gitIn(fx, fx.app, "rev-parse HEAD").strip() == headBefore
      check "H1 (" in inconsistent.output
      check "REFUSED" in inconsistent.output
      check "REPRO_SKIP_LOCK_REFRESH is set" in inconsistent.output

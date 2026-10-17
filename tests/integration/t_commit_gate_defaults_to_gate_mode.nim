## TC-9c — ``commit_gate`` defaults to the rule's ``gate_mode`` (operator
## decision D7; Test-Certificates.md §"Modes"), and the two gates read their
## own setting out of the same snapshot.
##
##   1. ``gate_mode = required`` with no ``commit_gate``: the pre-commit
##      phase REFUSES an uncovered commit, and says ``commit_gate =
##      required``.
##   2. ``gate_mode = required``, ``commit_gate = advisory``: the same kind of
##      commit is REPORTED and goes through; the client pre-push gate (the
##      real ``repro check --mode=pre-push``) REFUSES that very commit, under
##      the rule's ``gate_mode``.
##   3. A ``detachedHead`` rule applies on a detached ``HEAD``: required
##      there, the uncovered commit is refused, naming the rule.
##   4. From that detached ``HEAD``, a real ``git push origin HEAD:main`` is
##      judged by its DESTINATION (``main``, off) and goes through, although
##      the ``detachedHead`` rule would refuse the same commit.
##
## Each case commits a new snapshot (with ``--no-verify``), so the mode the
## gate applies is the one in the index it judges, with no re-install.
##
## Falsifiability: make the commit gate read ``gate_mode`` (ignore
## ``commit_gate``) → 2's commit is refused; make ``commit_gate`` default to
## ``off`` → 1 commits; make the pre-push gate read ``commit_gate`` → 2's push
## passes; judge a push by its local ref (``HEAD``, which the catch-all
## ``*`` rule requires) or by the checkout's detached ``HEAD`` instead of the
## destination → 4's push is refused.
##
## NO MOCKS: real repositories, the real hooks, real ``git commit``, the real
## pre-push gate. Skip rule: ``git`` or ``ssh-keygen`` missing.

import repro_test_support/reasoned_skip
import std/[json, os, osproc, strutils, unittest]

include policy_gate_fixture

proc toolsMissing(): bool =
  findExe("git").len == 0 or findExe("ssh-keygen").len == 0

suite "TC-9c — commit_gate defaults to gate_mode":

  test "t_commit_gate_defaults_to_gate_mode":
    if toolsMissing():
      skip("git or ssh-keygen not on PATH; this test signs certificates " &
        "and commits in real repositories")
    else:
      let fx = setupStoreFixture("", "tc9c-commit-gate", recordStore = false,
        committedLock = true)
      defer: removeDir(fx.scratch)

      # ---- 1. no commit_gate: the commit gate takes gate_mode -------------
      discard fx.commitPolicy(snapshotOf([
        policyRule(["main"], pmRequired, [req("pre-commit", "*")])]))
      check "commit_gate" notin readFile(fx.libAPath / "repro.lock")
      fx.ensureHooks()
      check hasCertificatePhase(fx.libAPath)
      writeFile(fx.libAPath / "a.txt", "alpha\n")
      discard fx.mustGit("add", "a.txt")
      let before1 = fx.head
      let c1 = fx.commit("-m", "uncovered")
      checkpoint("case 1:\n" & c1.output)
      check c1.code != 0
      check fx.head == before1
      check "REFUSED (commit_gate = required)" in c1.output
      check "'pre-commit' on any platform: run 'repro certify pre-commit'" in
        c1.output

      # ---- 2. commit_gate advisory, gate_mode required --------------------
      discard fx.mustGit("reset", "-q")
      discard fx.commitPolicy(snapshotOf([
        policyRule(["main"], pmRequired, [req("pre-commit", "*")],
          commitGate = pmAdvisory, commitGateSet = true)]))
      check "commit_gate = \"advisory\"" in readFile(fx.libAPath / "repro.lock")
      discard fx.mustGit("add", "a.txt")
      let before2 = fx.head
      let c2 = fx.commit("-m", "reported, not refused")
      checkpoint("case 2 commit:\n" & c2.output)
      check c2.code == 0
      check fx.head != before2
      check "advisory: the commit proceeds" in c2.output
      check fx.gateLogLines("reported not-covered") == 1
      # The same commit at push, through the generated pre-push hook of a
      # real `git push`: the rule's gate_mode.
      let pushedSha = fx.head
      let pushed = fx.git("push", "origin", "main")
      checkpoint("case 2 pre-push:\n" & pushed.output)
      check pushed.code != 0
      check fx.upstreamTip != pushedSha
      check "certificate-coverage" in pushed.output
      check "rule \"main\"" in pushed.output

      # ---- 3. a detachedHead rule applies on a detached HEAD --------------
      discard fx.commitPolicy(snapshotOf([
        policyRule(["main"], pmOff, []),
        policyRule([DetachedHeadPattern], pmRequired,
          [req("pre-commit", "*")]),
        # Any other branch name is required too, so case 4 can tell the
        # destination (`main`, off) from any other way of naming the push.
        policyRule(["*"], pmRequired, [req("pre-commit", "*")])]))
      discard fx.mustGit("checkout", "-q", "--detach")
      writeFile(fx.libAPath / "b.txt", "beta\n")
      discard fx.mustGit("add", "b.txt")
      let before3 = fx.head
      let c3 = fx.commit("-m", "detached, uncovered")
      checkpoint("case 3:\n" & c3.output)
      check c3.code != 0
      check fx.head == before3
      check "detached HEAD" in c3.output
      check "rule detachedHead" in c3.output

      # ---- 4. a client push from a detached HEAD: the destination decides --
      # Still detached, the tip is the uncovered policy commit. Judged as a
      # detached HEAD (the detachedHead rule, required) it would be refused;
      # `git push origin HEAD:main` is judged as `main`, whose rule is off.
      discard fx.mustGit("reset", "-q")
      removeFile(fx.libAPath / "b.txt")
      let detachedTip = fx.head
      let p4 = fx.git("push", "origin", "HEAD:main")
      checkpoint("case 4 push from a detached HEAD:\n" & p4.output)
      check p4.code == 0
      check fx.upstreamTip == detachedTip
      check "certificate-coverage" notin p4.output

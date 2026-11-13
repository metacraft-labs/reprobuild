## TC-9c — the pre-commit certificate gate requires what the rule for the
## commit's branch names (Test-Certificates.md §"How a gate computes
## coverage", §"Branch matching"), read from the ``[certificate_policy]``
## snapshot in the ``repro.lock`` of the index being committed.
##
## The policy (a snapshot committed in the developer clone):
##
##   rule "agents":  required, requires pre-commit (any platform)
##   rule "dev":     required, requires pre-commit (any platform) and
##                   unit-suite on linux/amd64
##
## Through the hooks ``repro hooks ensure --vcs`` generates and real
## ``git commit`` invocations, with one certificate — ``pre-commit`` on this
## host's platform — for each staged change:
##
##   1. on ``agents`` the commit is covered and goes through;
##   2. on ``dev`` the same kind of commit is REFUSED, naming ``unit-suite``,
##      ``linux/amd64`` and the command that produces it;
##   3. on ``feature/x`` (no rule matches) the same staged content commits,
##      and the gate says that no rule applies;
##   4. on a detached ``HEAD`` with no ``detachedHead`` rule the commit goes
##      through, and the gate says "detached HEAD: no branch rule applies".
##
## Every refusal here comes from the snapshot, the only policy input since
## TC-9d. The generated dispatcher carries the certificate phase
## only because the lock carries a policy (checked first).
##
## Falsifiability: read the rule for the wrong branch (ignore the branch, or
## take the last matching rule) → 1 or 2 inverts; drop the per-requirement
## platforms (judge every name on any platform) → 2 commits.
##
## NO MOCKS: real repositories, the real hooks, real ``git commit``, the
## production store and verifier, signatures by the real ``ssh-keygen``.
## Skip rule: ``git`` or ``ssh-keygen`` missing.

import repro_test_support/reasoned_skip
import std/[os, osproc, strutils, unittest]

include policy_gate_fixture

proc toolsMissing(): bool =
  findExe("git").len == 0 or findExe("ssh-keygen").len == 0

suite "TC-9c — the pre-commit gate requires what the branch rule names":

  test "t_pre_commit_gate_requires_what_the_branch_rule_names":
    if toolsMissing():
      skip("git or ssh-keygen not on PATH; this test signs certificates " &
        "and commits in real repositories")
    else:
      let fx = setupStoreFixture("", "tc9c-branch-rule", recordStore = false,
        committedLock = true)
      defer: removeDir(fx.scratch)
      discard fx.commitPolicy(snapshotOf([
        policyRule(["agents"], pmRequired, [req("pre-commit", "*")]),
        policyRule(["dev"], pmRequired,
          [req("pre-commit", "*"), req("unit-suite", "linux/amd64")])]))
      fx.ensureHooks()
      check hasCertificatePhase(fx.libAPath)

      # ---- 1. agents: pre-commit alone covers it -------------------------
      discard fx.mustGit("checkout", "-q", "-b", "agents")
      writeFile(fx.libAPath / "a.txt", "alpha\n")
      discard fx.mustGit("add", "a.txt")
      fx.certifyTargets(fx.indexContentId, @["pre-commit"])
      let before1 = fx.head
      let c1 = fx.commit("-m", "agents change")
      checkpoint("agents:\n" & c1.output)
      check c1.code == 0
      check fx.head != before1
      check fx.gateLogLines("covered") == 1

      # ---- 2. dev: also needs unit-suite on linux/amd64 ------------------
      discard fx.mustGit("checkout", "-q", "-b", "dev")
      writeFile(fx.libAPath / "b.txt", "beta\n")
      discard fx.mustGit("add", "b.txt")
      fx.certifyTargets(fx.indexContentId, @["pre-commit"])
      let before2 = fx.head
      let c2 = fx.commit("-m", "dev change")
      checkpoint("dev:\n" & c2.output)
      check c2.code != 0
      check fx.head == before2
      check "unit-suite" in c2.output
      check "linux/amd64" in c2.output
      check "repro certify unit-suite" in c2.output
      check "rule \"dev\"" in c2.output
      check "REFUSED (commit_gate = required)" in c2.output
      # pre-commit is covered, so it is not named as unmet.
      check "'pre-commit' on" notin c2.output
      check fx.gateLogLines("refused not-covered") == 1

      # ---- 3. feature/x: no rule, the same staged content commits --------
      discard fx.mustGit("checkout", "-q", "-b", "feature/x")
      let c3 = fx.commit("-m", "feature change")
      checkpoint("feature/x:\n" & c3.output)
      check c3.code == 0
      check fx.head != before2
      check "branch 'feature/x' matches no rule" in c3.output
      check fx.gateLogLines("no-rule") == 1

      # ---- 4. detached HEAD, no detachedHead rule -------------------------
      discard fx.mustGit("checkout", "-q", "--detach")
      writeFile(fx.libAPath / "c.txt", "gamma\n")
      discard fx.mustGit("add", "c.txt")
      let before4 = fx.head
      let c4 = fx.commit("-m", "detached change")
      checkpoint("detached:\n" & c4.output)
      check c4.code == 0
      check fx.head != before4
      check "detached HEAD: no branch rule applies" in c4.output

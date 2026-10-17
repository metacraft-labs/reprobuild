## TC-9c — ``repro ci plan`` reads ``ci_trust``, and the required names and
## platforms, from the ``[certificate_policy]`` snapshot of the BASE the job
## evaluates against, never from the candidate (Test-Certificates.md
## §"Modes": a commit cannot instruct CI to trust it).
##
## A committed-lock project whose candidate commit — the pull request's head,
## checked out clean — carries a snapshot with ``ci_trust = "skip"``, and a
## registered-signed certificate covering ``t-unit`` on this platform for the
## candidate's content:
##
##   1. Against a base whose snapshot says ``ci_trust = "advisory"`` (passed
##      as ``--base``): nothing is skipped, ``t-unit`` runs, the plan reports
##      ``ci_trust = advisory`` and ``policy.source = base``.
##   2. The SAME candidate against a base whose snapshot says ``skip``:
##      ``t-unit`` is skipped.
##   3. Against a base with NO snapshot: the candidate's rule supplies the
##      names (``t-unit`` is planned), but ``ci_trust`` stays ``advisory`` and
##      nothing is skipped (``policy.source = candidate``).
##   4. The base's rule decides the names too: a base whose rule for ``main``
##      requires ``t-int`` plans ``t-int``, not the candidate's ``t-unit``.
##   5. The candidate named as its own base (what ``origin/<branch>`` is on a
##      push event): it is no base, so ``ci_trust`` stays ``advisory`` and
##      nothing is skipped.
##
## Falsifiability: read ``ci_trust`` from the candidate → 1, 3 and 5 skip
## ``t-unit``; accept the candidate as its own base → 5 skips; take the names from the candidate when the base has a rule →
## 4 plans ``t-unit``.
##
## Hermetic: local repos, the built ``repro``; no network. Requires git and
## ssh-keygen.

import std/[json, os, osproc, strutils, unittest]

include policy_gate_fixture

proc ciPlanAgainst(fx: StoreFixture; base: string): JsonNode =
  let res = runArgv(@[fx.reproBin, "ci", "plan",
    "--platform=" & currentPlatformTag(), "--branch=main", "--base=" & base,
    "--workspace-root=" & fx.workspaceRoot, "--current-repo=" & fx.libAPath,
    "--json"])
  checkpoint("ci plan --base=" & base & ":\n" & res.output)
  doAssert res.code == 0, "repro ci plan failed:\n" & res.output
  let start = res.output.find("{\n")
  doAssert start >= 0, "no JSON in ci plan output:\n" & res.output
  parseJson(res.output[start .. ^1])

suite "TC-9c — the CI plan reads ci_trust from the base":

  test "t_ci_plan_reads_ci_trust_from_the_base_not_the_candidate":
    let host = currentPlatformTag()
    let fx = setupStoreFixture("", "tc9c-ciplan", recordStore = false,
      committedLock = true)
    defer: removeDir(fx.scratch)
    let seed = fx.head   # carries no snapshot
    let unitRule = policyRule(["main"], pmRequired, [req("t-unit", host)])
    let advisoryBase = fx.commitPolicy(
      snapshotOf([unitRule], ciTrust = pctAdvisory), "base: advisory")
    let skipBase = fx.commitPolicy(
      snapshotOf([unitRule], ciTrust = pctSkip), "base: skip")
    let intBase = fx.commitPolicy(snapshotOf([
      policyRule(["main"], pmRequired, [req("t-int", host)])],
      ciTrust = pctSkip), "base: requires t-int")
    # The candidate: its own snapshot raises ci_trust to skip.
    discard fx.commitPolicy(snapshotOf([unitRule], ciTrust = pctSkip),
      "candidate: trust me")
    writeFile(fx.libAPath / "change.txt", "the change under review\n")
    discard fx.mustGit("add", "change.txt")
    discard fx.mustGit("commit", "-q", "--no-verify", "-m", "the change")
    let candidate = fx.head
    let content = "git-tree-sha1:" & gitOut(fx.libAPath, "rev-parse",
      candidate & "^{tree}")
    fx.certifyTargets(content, @["t-unit", "t-int"])

    # ---- 1. base says advisory: nothing skipped ---------------------------
    let p1 = ciPlanAgainst(fx, advisoryBase)
    check p1["ci_trust"].getStr() == "advisory"
    check p1["policy"]["source"].getStr() == "base"
    check p1["policy"]["base"].getStr() == advisoryBase
    check p1["required_targets"].to(seq[string]) == @["t-unit"]
    let h1 = planPlatform(p1, host)
    check strings(h1, "skip").len == 0
    check strings(h1, "run") == @["t-unit"]
    check h1["matching_certs"].getInt() == 1   # covered, and still re-run

    # ---- 2. base says skip: the covered name is skipped -------------------
    let p2 = ciPlanAgainst(fx, skipBase)
    check p2["ci_trust"].getStr() == "skip"
    let h2 = planPlatform(p2, host)
    check strings(h2, "skip") == @["t-unit"]
    check strings(h2, "run").len == 0

    # ---- 3. base with no snapshot: names from the candidate, no trust -----
    let p3 = ciPlanAgainst(fx, seed)
    check p3["policy"]["source"].getStr() == "candidate"
    check p3["ci_trust"].getStr() == "advisory"
    check "never read" in p3["policy"]["detail"].getStr()
    let h3 = planPlatform(p3, host)
    check strings(h3, "skip").len == 0
    check strings(h3, "run") == @["t-unit"]

    # ---- 4. the base's rule decides the names -----------------------------
    let p4 = ciPlanAgainst(fx, intBase)
    check p4["required_targets"].to(seq[string]) == @["t-int"]
    let h4 = planPlatform(p4, host)
    check strings(h4, "skip") == @["t-int"]
    check "t-unit" notin strings(h4, "run")

    # ---- 5. the candidate as its own base: no trust -----------------------
    # On a push event `origin/<branch>` names the pushed commit itself; a
    # base that is the candidate must not let it raise its own ci_trust.
    let p5 = ciPlanAgainst(fx, candidate)
    check p5["policy"]["source"].getStr() == "candidate"
    check p5["policy"]["base"].getStr() == ""
    check p5["ci_trust"].getStr() == "advisory"
    check "is the candidate itself" in p5["policy"]["detail"].getStr()
    let h5 = planPlatform(p5, host)
    check strings(h5, "skip").len == 0
    check strings(h5, "run") == @["t-unit"]

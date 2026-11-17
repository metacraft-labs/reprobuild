## A CI job's certificate reaches the remote's notes ref through ``repro push``,
## so a later ``repro ci plan`` elsewhere can trust it.
##
## Test-Certificates.md §"`repro ci plan` — the machine-readable fast-track
## decision" and CLI/ci.md §"`repro ci plan`" say a CI job runs the plan's
## ``run`` set with ``repro test --certify`` and, on green, attaches the fresh
## certificate with ``repro push``. CI tests a commit that is ALREADY
## PUBLISHED, so that ``repro push`` pushes no commit and the managed
## ``pre-push`` hook, which carries only what a push introduces (Tooling
## §4.2), never runs. Only ``repro push``'s own carry for an
## ``already-published`` member (CLI/push.md §"Carrying certificates", TC-8f)
## can get the certificate there. reprobuild-pm issue
## ``issues/2026-11-12-ci-certificates-are-attached-with-repro-push-which-cannot-carry-them.md``
## recorded, from the older Transport text, that nothing would.
##
## The checkout is shaped the way a CI runner leaves it:
##
##   * DETACHED at the published commit, as a CI checkout of a SHA is;
##   * NO MANAGED HOOKS installed: a CI clone never ran ``repro hooks ensure``.
##     ``repro push`` refuses such a checkout at hook-preflight
##     (push-hook-publication-protocol.md §"`repro push` Completion And Partial
##     Success"), before its carry runs, so the step as the specs first stated
##     it -- "attaches ... with ``repro push``" -- publishes nothing. The test
##     asserts that refusal, then runs the specified step: ``repro hooks
##     ensure --vcs <repo>`` and ``repro push``. Even then nothing is pushed and
##     no hook runs, so only ``repro push``'s own carry gets the note there;
##   * NO ``test-certificates`` executable on ``PATH``: the remedy a developer
##     would type by hand is not available, the linked library has to do it;
##   * the certificate is issued by the real ``repro test --certify`` path, so
##     it sits in the local store and in no notes ref.
##
## Then a consumer's view: with the local notes ref deleted and fetched back
## from the upstream, ``repro ci plan`` under ``ci_trust = "skip"`` skips the
## target the CI job certified. Before the push it ran it.
##
## Last, a checkout that is not published (a synthesized merge commit) is
## refused by ``repro push``, which is why the specs send such a job to the
## reference tool's ``notes publish`` and ``notes push``.
##
## Falsifiability: drop the ``already-published`` carry from ``repro push``
## (or make it depend on the hook running) and the upstream has no notes ref;
## refuse a published detached checkout and the push fails; stop requiring
## the hook and the hook-less push no longer fails as the specs now say.
##
## Real git, real bares, the built ``repro``, the real signing primitive. No
## mocks; no gateway, because a CI job pushes straight to its forge.

import std/unittest

include certificate_push_fixture

proc ciReproPush(fx: StoreFixture): tuple[code: int; output: string] =
  ## The CI job's ``repro push``: no ``--no-certify``, so the certify step's
  ## coverage lookup runs too, as it would in a job.
  runArgv(@[fx.reproBin, "push", "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & fx.libAPath], fx.libAPath,
    @[(name: "PATH", value: pathWithoutTool()),
      (name: "REPROBUILD_REPRO", value: fx.reproBin)])

suite "a CI job publishes its certificate with repro push":
  test "a detached CI checkout of a published commit publishes its certificate":
    let host = currentPlatformTag()
    let fx = setupStoreFixture(
      requiredPolicy(@["t-unit"], @[host], mode = "advisory", ciTrust = "skip"),
      "ci-job-carry")
    defer: removeDir(fx.scratch)

    # A developer published this commit with no certificate.
    let commit = newCommit(fx, "change.txt", "published uncertified\n")
    let tree = gitOut(fx.libAPath, "rev-parse", commit & "^{tree}")
    let published = runArgv(@["git", "-C", fx.libAPath, "push", "--no-verify",
      "origin", "main"])
    check published.code == 0
    check upstreamTip(fx) == commit
    check not remoteHasNotes(fx.upstreamBare)

    # The CI checkout of that commit: detached, and no managed hook anywhere.
    discard gitOut(fx.libAPath, "checkout", "--detach", commit)
    check not fileExists(fx.libAPath / ".git" / "hooks" / "pre-push")
    seedLock(fx)

    # The plan runs t-unit: nothing certifies this content yet.
    let base = @["--base=" & fx.seedSha, "--branch=main"]
    proc plan(): JsonNode =
      let res = runArgv(@[fx.reproBin, "ci", "plan", "--platform=" & host,
        "--workspace-root=" & fx.workspaceRoot,
        "--current-repo=" & fx.libAPath, "--json"] & base)
      checkpoint("ci plan:\n" & res.output)
      doAssert res.code == 0, res.output
      parseJson(res.output[res.output.find("{\n") .. ^1])
    let before = planPlatform(plan(), host)
    check before.strings("run") == @["t-unit"]
    check before.strings("skip").len == 0

    # The job runs the run set and certifies it.
    let issued = issueViaReproTest(fx)
    checkpoint("repro test --certify:\n" & issued.output)
    check issued.code == 0
    check not remoteHasNotes(fx.upstreamBare)

    # ``repro push`` as the specs once stated the step, on a CI clone that
    # never ran ``repro hooks ensure``: it stops at hook-preflight before the
    # carry, names the remedy, and the certificate does not reach the remote.
    # This is why the publication step installs the hooks first.
    let hookless = ciReproPush(fx)
    checkpoint("repro push without managed hooks:\n" & hookless.output)
    check hookless.code != 0
    check "stage=hook-preflight" in hookless.output
    check "hooks ensure --vcs" in hookless.output
    check not remoteHasNotes(fx.upstreamBare)

    # The publication step: install the managed hooks, then repro push.
    installHooks(fx)
    let pushed = ciReproPush(fx)
    checkpoint("repro push:\n" & pushed.output)
    check pushed.code == 0
    check "already-published" in pushed.output
    check upstreamTip(fx) == commit
    check noteOnRemote(fx.upstreamBare, tree).count(
      "# --- test-certificate ---") == 1
    # Nothing is left for a human to do by hand.
    check "test-certificates notes publish" notin pushed.output

    # A consumer that has only what the remote holds now skips t-unit.
    discard gitOut(fx.libAPath, "update-ref", "-d", certificateNotesRef)
    discard gitOut(fx.libAPath, "fetch", "origin",
      "+" & certificateNotesRef & ":" & certificateNotesRef)
    let after = planPlatform(plan(), host)
    check after.strings("skip") == @["t-unit"]
    check after.strings("run").len == 0

    # A checkout that is NOT published (a synthesized merge commit, say) is
    # refused, and publishes nothing: the specs send that job to the
    # reference tool's ``notes publish`` and ``notes push`` instead.
    let synthesized = newCommit(fx, "merge.txt", "synthesized\n")
    seedLock(fx)
    let refused = ciReproPush(fx)
    checkpoint("unpublished detached push:\n" & refused.output)
    check refused.code != 0
    check "unpublished HEAD is detached" in refused.output
    check upstreamTip(fx) == commit
    check noteOnRemote(fx.upstreamBare,
      gitOut(fx.libAPath, "rev-parse", synthesized & "^{tree}")) == ""

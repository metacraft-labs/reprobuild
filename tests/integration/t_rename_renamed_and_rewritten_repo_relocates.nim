## Declared-Repository-Renames.md §5 — THE TEST THE MECHANISM IS FOR.
##
## A repository that was BOTH renamed and history-rewritten. It is not an edge
## case to be handled eventually: the repositories at the front of the rename
## queue are the ones whose histories have already been rewritten, so this is
## the FIRST case the mechanism meets in production.
##
## A `merge-base`-only identity check fails it, and fails in the worst
## direction: the candidate shares no commit with its new remote, so the check
## would report "different repository" and `sync` would either refuse or clone
## fresh and orphan the directory. `git filter-repo` rewrites commits and trees
## but CARRIES BLOBS ACROSS, which is why §3.3(b) falls back to object
## PRESENCE — and why this test asserts the fallback was the thing that fired,
## not merely that the move happened.
##
## Asserted:
##   1. The premise: the rewritten remote shares NO commit with the checkout,
##      and the blobs ARE shared. Without this the test would be re-testing the
##      easy case.
##   2. The relocation succeeds, and the evidence line names the blob sample
##      rather than a merge-base — i.e. the fallback carried it.
##   3. The relocated repo then classifies `force_push_rebase`, so the two
##      mechanisms compose in the specified order (relocation during
##      materialisation, rewritten-remote detection during classification).
##   4. No remedy that tells the user to PUSH, which would republish the
##      history the rewrite removed.

import std/[json, os, strutils, unittest]
import repro_test_support/reasoned_skip
import declared_rename_fixture

suite "declared rename — renamed AND rewritten":

  test "t_rename_renamed_and_rewritten_repo_relocates":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; the declared-rename fixture needs a repository")
    else:
      let fx = newRenameFixture(gitBin, "rewritten")
      defer: removeDir(fx.scratch)

      let seeded = fx.seedOrigin(gitBin, "widget-pm")
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm",
        previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }]")
      fx.writeProject(["widget-pm"])

      # A CLEAN checkout at the old path (the planner's `dirty` arm runs ahead
      # of the force-push arm, so a dirty tree would mask the case under test).
      let oldPath = fx.workspaceRoot / "widget-specs"
      fx.cloneInto(gitBin, "widget-pm", oldPath)
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " remote set-url origin " & q(fx.originUrl("widget-specs")))
      let checkoutHead = requireGit(q(gitBin) & " -C " & q(oldPath) &
        " rev-parse HEAD").strip()
      check checkoutHead == seeded.tipSha

      # Now rewrite the remote's history under it.
      let rewrittenTip = fx.rewriteOriginHistory(gitBin, "widget-pm",
        seeded.seedPath)

      # 1. THE PREMISE, asserted rather than assumed.
      check rewrittenTip != checkoutHead
      let mergeBase = run(q(gitBin) & " -C " & q(fx.originsDir / "widget-pm") &
        " merge-base " & q(rewrittenTip) & " " & q(checkoutHead))
      # The bare does not even have the old commit any more, so the probe
      # cannot succeed; either way there is no shared commit.
      check mergeBase.output.strip() != checkoutHead
      # The BLOBS are shared: the payload blob the rewritten tip names is
      # already in the candidate's object store.
      let payloadBlob = requireGit(q(gitBin) & " -C " &
        q(fx.originsDir / "widget-pm") & " rev-parse " &
        q(rewrittenTip & ":src/payload.txt")).strip()
      check payloadBlob.len == 40
      check run(q(gitBin) & " -C " & q(oldPath) & " cat-file -e " &
        q(payloadBlob)).code == 0

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      let entry = fx.readReport().entryFor("widget-pm")

      # 2. Relocated, on the OBJECT-PRESENCE evidence.
      check entry.field("relocation") == "relocated"
      check entry.field("relocatedFrom") == "widget-specs"
      let evidence = entry.field("relocationEvidence")
      checkpoint("evidence: " & evidence)
      check "sampled blob" in evidence
      # And NOT on a merge-base, which is the assertion that the fallback is
      # what carried it. A merge-base-only implementation fails here.
      check "merge-base" notin evidence
      check dirExists(fx.workspaceRoot / "widget-pm" / ".git")
      check not dirExists(oldPath)
      # The work is still there: HEAD is the pre-rewrite commit, untouched.
      check requireGit(q(gitBin) & " -C " &
        q(fx.workspaceRoot / "widget-pm") & " rev-parse HEAD").strip() ==
        checkoutHead

      # 3. The two mechanisms compose: classification ran AFTER the move, at
      #    the new path, on refs the fetch phase refreshed.
      check entry.field("syncCase") == "force_push_rebase"
      check res.code == 2

      # 4. Never a push remedy for a rewritten remote.
      let refusal = entry.field("refusalReason")
      checkpoint("refusal: " & refusal)
      check "git push" notin refusal
      check entry.field("syncCase") != "locally_unpublished"

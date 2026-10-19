## TC-8c — ``repro ci plan`` emits ``reprobuild.ci-plan.v2``, bound to the
## CONTENT CI checked out rather than to a commit and a lock.
##
## A committed-lock project (its ``repro.lock`` is tracked, so reprobuild's
## lock step reads it from the content) whose published base (``origin/main``)
## records a certificate policy with ``ci_trust = "skip"`` and required
## targets ``t-unit`` and ``t-int`` (TC-9d: the policy lives in the content's
## ``repro.lock``; the plan reads ``ci_trust`` from the base, so the checkout
## under test is a commit on top of it). Certificates are signed by the
## registered daemon key through the real signing primitive.
##
##   1. A CLEAN checkout binds ``content = git-tree-sha1:<HEAD^{tree}>`` (as git
##      reports it); ``commit`` is HEAD, for information; the v1 fields
##      (``lock_records_dir``) are gone. A certificate noted on that tree
##      skips ``t-unit``; ``t-int`` runs; the verdict is ``not-covered``.
##   2. A MODIFIED checkout binds ITS OWN content — the working tree's id, as
##      git computes it in a temporary index — not HEAD's tree; "dirty" is no
##      longer a reason to run everything.
##   3. A certificate issued BEFORE the commit — for that modified working
##      tree, delivered to the local store — skips ``t-unit`` there, and still
##      skips it once the content is committed: the clean checkout of the new
##      commit binds the same content.
##
## Falsifiability: bind HEAD's commit/tree for a modified checkout → 2 fails;
## keep the v1 fields → 1 fails; look certificates up by commit → 3's
## post-commit skip fails.
##
## Hermetic: local repos, the built ``repro``; no network. Requires git and
## ssh-keygen.

import std/[json, os, osproc, strutils, unittest]

include tc8c_store_fixture

suite "TC-8c — the CI plan binds the checked-out content":

  test "t_ci_plan_v2_binds_the_checked_out_content":
    let host = currentPlatformTag()
    let fx = setupStoreFixture(requiredPolicy(@["t-unit", "t-int"], @[host],
      ciTrust = "skip"), "ciplan", recordStore = false, committedLock = true)
    defer: removeDir(fx.scratch)
    # The candidate: a commit on top of the published base. A checkout that
    # IS the base would have no base to read ci_trust from (TC-9c).
    writeFile(fx.libAPath / "candidate.txt", "the change CI checks out\n")
    discard gitOut(fx.libAPath, "add", "candidate.txt")
    discard gitOut(fx.libAPath, "commit", "-q", "-m", "candidate")

    # ---- 1. a clean checkout --------------------------------------------
    let head = gitOut(fx.libAPath, "rev-parse", "HEAD")
    let headContent = "git-tree-sha1:" & gitOut(fx.libAPath, "rev-parse",
      "HEAD^{tree}")
    let bare = ciPlan(fx, host)
    check bare["schema"].getStr() == "reprobuild.ci-plan.v2"
    check bare["content"].getStr() == headContent
    check bare["commit"].getStr() == head
    check not bare.hasKey("lock_records_dir")
    check not bare.hasKey("lock")
    check bare["ci_trust"].getStr() == "skip"
    check bare["policy"]["source"].getStr() == "base"
    check planPlatform(bare, host)["verdict"].getStr() == "not-covered"
    check strings(planPlatform(bare, host), "run") == @["t-unit", "t-int"]

    check attachCertificate("git", fx.libAPath,
      signedCertFor(fx, headContent, head)).ok
    let noted = ciPlan(fx, host)
    let notedHost = planPlatform(noted, host)
    check strings(notedHost, "skip") == @["t-unit"]
    check strings(notedHost, "run") == @["t-int"]
    check notedHost["verdict"].getStr() == "not-covered"
    check notedHost["matching_certs"].getInt() == 1

    # ---- 2. a modified checkout binds its own content --------------------
    writeFile(fx.libAPath / "README.md", "TC-8c fixture, edited in CI\n")
    let worktree = workingTreeContentId(fx.libAPath)
    check worktree != headContent
    let modified = ciPlan(fx, host)
    check modified["content"].getStr() == worktree
    check modified["commit"].getStr() == head
    let modifiedHost = planPlatform(modified, host)
    # HEAD's certificate does not describe this content.
    check strings(modifiedHost, "skip").len == 0
    check strings(modifiedHost, "run") == @["t-unit", "t-int"]
    check modifiedHost["verdict"].getStr() == "not-covered"

    # ---- 3. issued before the commit: skips, before and after -------------
    let early = signedCertFor(fx, worktree, head)   # base: the OLD head
    let delivered = publishCertificateToLocalStore(early, fx.libAPath)
    check delivered.error == ""
    let before = planPlatform(ciPlan(fx, host), host)
    check strings(before, "skip") == @["t-unit"]
    check strings(before, "run") == @["t-int"]
    discard gitOut(fx.libAPath, "commit", "-am", "commit the tested content")
    let committed = gitOut(fx.libAPath, "rev-parse", "HEAD")
    check committed != head
    let after = ciPlan(fx, host)
    check after["content"].getStr() == worktree
    check after["commit"].getStr() == committed
    let afterHost = planPlatform(after, host)
    check strings(afterHost, "skip") == @["t-unit"]
    check strings(afterHost, "run") == @["t-int"]

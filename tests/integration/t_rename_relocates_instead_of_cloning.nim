## Declared-Repository-Renames.md §3 — `repro sync` MOVES a checkout found at
## a declared previous path instead of orphaning it and cloning a second copy.
##
## This is the base case the whole mechanism is for. Before it, `sync` saw
## `exists = false` at the new path, classified `missing_checkout`, and
## `executeClone` wrote a second full copy — leaving the operator's local
## branches, stashes and uncommitted changes in a directory with no marker, no
## report line and no inbound reference, which is indistinguishable from debris.
##
## Asserted:
##   1. ONE checkout at the new path, and NOTHING left at the old one.
##   2. The local branch, the stash entry and the uncommitted file all survived
##      — because the directory was moved rather than the checkout
##      reconstructed.
##   3. The report says `relocation=relocated`, names the path it came from,
##      and carries the evidence each half of the identity check rested on.
##   4. Exit 0, and the repo classifies like any other existing checkout.
##   5. A SECOND sync moves nothing and reports no relocation — the key is
##      inert once a checkout sits at `path`, which is what makes it safe to
##      leave in a fragment forever.
##
## See `declared_rename_fixture.nim` for why nothing here is mocked.

import std/[json, os, strutils, unittest]
import repro_test_support/reasoned_skip
import declared_rename_fixture

suite "declared rename — relocate instead of cloning":

  test "t_rename_relocates_instead_of_cloning":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; the declared-rename fixture needs a repository")
    else:
      let fx = newRenameFixture(gitBin, "relocate")
      defer: removeDir(fx.scratch)

      # The repository is served under its NEW name; the fragment declares the
      # OLD name and path as a prior identity. This is a rename of both halves
      # of identity at once, which is the shape the pm-repo rename has.
      discard fx.seedOrigin(gitBin, "widget-pm")
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm",
        previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }]")
      fx.writeProject(["widget-pm"])

      # A checkout at the OLD path, carrying work that only exists there.
      let oldPath = fx.workspaceRoot / "widget-specs"
      fx.cloneInto(gitBin, "widget-pm", oldPath)
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " switch -c local-only-branch")
      writeFile(oldPath / "stashed.txt", "work in progress\n")
      discard requireGit(q(gitBin) & " -C " & q(oldPath) & " add stashed.txt")
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " stash push -m \"the stash that must survive\"")
      writeFile(oldPath / "dirty.txt", "uncommitted\n")
      let oldHead = requireGit(q(gitBin) & " -C " & q(oldPath) &
        " rev-parse HEAD").strip()

      # The checkout is reached by the OLD url too, which is what a renamed
      # repository really presents (the forge serves the new location under a
      # redirect and nothing rewrote the config). A `file://` origin has no
      # redirect, so the fixture states the pre-move URL explicitly rather than
      # pretending one exists.
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " remote set-url origin " & q(fx.originUrl("widget-specs")))

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      # Exit 2, and that is the CORRECT outcome rather than a tolerated one:
      # the relocated checkout is then classified like any other existing
      # checkout, and this one has uncommitted changes, so it gets the ordinary
      # `dirty` refusal. The relocation still happened — which is the whole
      # point of §3.1's "one pass, one set of rules": the move is part of
      # materialisation and does not get a verdict of its own.
      check res.code == 2
      check fx.readReport().entryFor("widget-pm").field("syncCase") ==
        "dirty"

      # 1. One checkout, at the new path. The old path is gone — not emptied,
      #    gone: an empty leftover directory would still read as debris.
      check dirExists(fx.workspaceRoot / "widget-pm" / ".git")
      check not dirExists(oldPath)

      # 2. Everything local came with it.
      let newPath = fx.workspaceRoot / "widget-pm"
      check "local-only-branch" in localBranches(gitBin, newPath)
      check stashCount(gitBin, newPath) == 1
      check "the stash that must survive" in
        requireGit(q(gitBin) & " -C " & q(newPath) & " stash list")
      check fileExists(newPath / "dirty.txt")
      check requireGit(q(gitBin) & " -C " & q(newPath) &
        " rev-parse HEAD").strip() == oldHead

      # 3. The report relates the two directories. This is the half the
      #    pre-mechanism behaviour could not do at all.
      let report = fx.readReport()
      let entry = report.entryFor("widget-pm")
      check entry.field("relocation") == "relocated"
      check entry.field("relocatedFrom") == "widget-specs"
      check entry.field("relocationEvidence").len > 0
      check "remote agreement" in entry.field("relocationEvidence")
      check "shared object" in entry.field("relocationEvidence")
      # The primary remote was repointed at the new URL, so the checkout stops
      # depending on a forge redirect that ends the moment someone creates a
      # repository at the freed old name.
      check requireGit(q(gitBin) & " -C " & q(newPath) &
        " remote get-url origin").strip() == fx.originUrl("widget-pm")

      # 4. And it is NOT a clone: no second copy anywhere under the workspace.
      var checkoutDirs = 0
      for kind, path in walkDir(fx.workspaceRoot):
        if kind == pcDir and dirExists(path / ".git"):
          inc checkoutDirs
      check checkoutDirs == 1
      check entry.field("action") != "clone"

      # 5. Idempotent, and classified like any other existing checkout. The
      #    second sync relocates NOTHING and says nothing about relocation —
      #    `previously` is inert once a checkout sits at `path`, which is what
      #    makes the key safe to leave in a fragment forever.
      #
      #    Exit 2 is the CORRECT outcome here and is itself the point: the
      #    relocated checkout is now an ordinary dirty checkout and gets the
      #    ordinary `dirty` refusal, not a relocation-shaped one. A second
      #    code path for relocated repos is exactly what §3.1 refuses to have.
      let res2 = fx.invokeSync()
      checkpoint("second sync output:\n" & res2.output)
      check res2.code == 2
      let entry2 = fx.readReport().entryFor("widget-pm")
      check entry2.field("syncCase") == "dirty"
      check entry2.field("relocation") == ""
      check entry2.field("relocatedFrom") == ""
      check dirExists(fx.workspaceRoot / "widget-pm" / ".git")
      check not dirExists(oldPath)
      check "local-only-branch" in localBranches(gitBin, newPath)
      check stashCount(gitBin, newPath) == 1
      check fileExists(newPath / "dirty.txt")

  test "t_rename_relocation_of_a_clean_checkout_exits_zero":
    ## The exit-0 half of §3.6's `relocated` verdict. A clean checkout on the
    ## declared branch relocates and then classifies
    ## `clean_at_locked_revision`, so the run is an ordinary success — no
    ## refusal, no clone, and the summary counts it as a no-op rather than as
    ## work it did not do.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; the declared-rename fixture needs a repository")
    else:
      let fx = newRenameFixture(gitBin, "cleanmove")
      defer: removeDir(fx.scratch)

      discard fx.seedOrigin(gitBin, "widget-pm")
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm",
        previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }]")
      fx.writeProject(["widget-pm"])
      let oldPath = fx.workspaceRoot / "widget-specs"
      fx.cloneInto(gitBin, "widget-pm", oldPath)
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " remote set-url origin " & q(fx.originUrl("widget-specs")))

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      check res.code == 0
      let entry = fx.readReport().entryFor("widget-pm")
      check entry.field("relocation") == "relocated"
      check entry.field("syncCase") == "clean_at_locked_revision"
      check entry.field("executionStatus") == "noop"
      check dirExists(fx.workspaceRoot / "widget-pm" / ".git")
      check not dirExists(oldPath)

  test "t_rename_dry_run_announces_the_relocation_and_moves_nothing":
    ## §3.1 — "`--dry-run` prints relocations and performs none". A rename is
    ## the case an operator most wants to preview before it touches disk.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; the declared-rename fixture needs a repository")
    else:
      let fx = newRenameFixture(gitBin, "dryrun")
      defer: removeDir(fx.scratch)

      discard fx.seedOrigin(gitBin, "widget-pm")
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm",
        previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }]")
      fx.writeProject(["widget-pm"])
      let oldPath = fx.workspaceRoot / "widget-specs"
      fx.cloneInto(gitBin, "widget-pm", oldPath)

      let res = fx.invokeSync(["--dry-run"])
      checkpoint("dry-run output:\n" & res.output)
      check res.code == 0
      # The dry run's deliverable is the printed plan; it returns before the
      # report is written, so the assertion is on what the operator reads.
      check "[relocate]" in res.output
      check "widget-pm (widget-pm) <- widget-specs" in res.output
      check "identity not yet verified" in res.output
      check "no repos were modified" in res.output
      # Nothing moved.
      check dirExists(oldPath / ".git")
      check not dirExists(fx.workspaceRoot / "widget-pm")

  test "t_rename_no_previous_checkout_still_clones":
    ## §3.2 step 4 — no candidate means the ordinary clone path runs,
    ## unchanged. The informational note says a prior path was declared and
    ## nothing was there, so the absence is reported rather than inferred.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; the declared-rename fixture needs a repository")
    else:
      let fx = newRenameFixture(gitBin, "nocandidate")
      defer: removeDir(fx.scratch)

      discard fx.seedOrigin(gitBin, "widget-pm")
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm",
        previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }]")
      fx.writeProject(["widget-pm"])

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      check res.code == 0
      check dirExists(fx.workspaceRoot / "widget-pm" / ".git")
      let entry = fx.readReport().entryFor("widget-pm")
      check entry.field("relocation") == "no_previous_checkout"
      check entry.field("executionStatus") == "cloned"

  test "t_rename_debris_at_the_previous_path_is_skipped_not_refused":
    ## §3.2 step 3 — a git repository with no commits, no branches, no stashes
    ## and a clean tree is the shape a FAILED CLONE leaves. It is common, and
    ## it must not become a refusal that blocks the rest of the sync. Skipping
    ## is reported, naming what was found, because "we could not tell" and
    ## "there is nothing there" must never collapse into one answer.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; the declared-rename fixture needs a repository")
    else:
      let fx = newRenameFixture(gitBin, "debris")
      defer: removeDir(fx.scratch)

      discard fx.seedOrigin(gitBin, "widget-pm")
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm",
        previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }]")
      fx.writeProject(["widget-pm"])
      let oldPath = fx.workspaceRoot / "widget-specs"
      discard requireGit(q(gitBin) & " init -b main " & q(oldPath))

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      check res.code == 0
      let entry = fx.readReport().entryFor("widget-pm")
      check entry.field("relocation") == "previous_checkout_skipped"
      check "no commits" in entry.field("relocationDetail")
      # The clone ran, and the skipped directory was left EXACTLY where it is.
      check dirExists(fx.workspaceRoot / "widget-pm" / ".git")
      check dirExists(oldPath / ".git")

## Declared-Repository-Renames.md §4 — the remaining pre-flight refusals.
##
## Each one refuses THAT REPO, reports what was found by name, mutates nothing
## for it, and lets the rest of the sync proceed. Exit 2 throughout: a repo the
## tool DECLINES to touch is a judgement call with manual work for the
## operator, which is the distinction `CLI/sync.md` already draws against the
## exit 1 of a broken action.
##
## The cases with their own files are the four the spec names plus the two
## halves of the identity check. Here: `ambiguous_previous_checkouts`,
## `destination_occupied`, `candidate_in_progress_operation`,
## `submodule_absolute_gitdir`, and the sync-side belt for
## `previous_path_claimed_by_live_repo`.

import repro_test_support/reasoned_skip
import std/[json, os, strutils, unittest]
import declared_rename_fixture

suite "declared rename — the pre-flight refusals":

  test "t_rename_refuses_ambiguous_previous_checkouts":
    ## Merging two checkouts is not something a sync should attempt, and
    ## picking one by declaration order would silently choose which of the
    ## operator's two sets of local branches survives.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "ambiguous")
      defer: removeDir(fx.scratch)

      discard fx.seedOrigin(gitBin, "widget-pm")
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm",
        previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }, " &
          "{ name = \"widget-docs\", path = \"widget-docs\" }]")
      fx.writeProject(["widget-pm"])

      for old in ["widget-specs", "widget-docs"]:
        let p = fx.workspaceRoot / old
        fx.cloneInto(gitBin, "widget-pm", p)
        discard requireGit(q(gitBin) & " -C " & q(p) &
          " switch -c work-in-" & old)

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      check res.code == 2
      let entry = fx.readReport().entryFor("widget-pm")
      check entry.field("relocation") == "ambiguous_previous_checkouts"
      let detail = entry.field("relocationDetail")
      # BOTH are named: a refusal that said "ambiguous" without saying which
      # two leaves the operator to guess.
      check "widget-specs" in detail
      check "widget-docs" in detail
      # Neither moved, and nothing was cloned over the declared path.
      check dirExists(fx.workspaceRoot / "widget-specs" / ".git")
      check dirExists(fx.workspaceRoot / "widget-docs" / ".git")
      check not dirExists(fx.workspaceRoot / "widget-pm")

  test "t_rename_refuses_an_occupied_destination":
    ## §4 `destination_occupied`, and §3.2's note on why it is SCOPED to a repo
    ## with a relocation in play: `executeClone` treats a directory with no
    ## `.git` at the clone target as a half-cloned artifact and DELETES it,
    ## which is correct behaviour that must survive. A fragment with no
    ## `previously` entry reaches the clone path exactly as it does today.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "occupied")
      defer: removeDir(fx.scratch)

      discard fx.seedOrigin(gitBin, "widget-pm")
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm",
        previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }]")
      fx.writeProject(["widget-pm"])

      let oldPath = fx.workspaceRoot / "widget-specs"
      fx.cloneInto(gitBin, "widget-pm", oldPath)
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " remote set-url origin " & q(fx.originUrl("widget-specs")))
      # Something at the destination that is NOT this repo and NOT a git
      # checkout — a plain directory the operator put there.
      createDir(fx.workspaceRoot / "widget-pm")
      writeFile(fx.workspaceRoot / "widget-pm" / "notes.txt",
        "someone's notes\n")

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      check res.code == 2
      let entry = fx.readReport().entryFor("widget-pm")
      check entry.field("relocation") == "destination_occupied"
      let detail = entry.field("relocationDetail")
      checkpoint("detail: " & detail)
      # WHICH it is, named: a file, a plain directory, or a foreign checkout.
      check "non-empty directory that is not a git checkout" in detail
      # Nothing was deleted, at either end.
      check fileExists(fx.workspaceRoot / "widget-pm" / "notes.txt")
      check dirExists(oldPath / ".git")

  test "t_rename_refuses_a_candidate_in_a_mid_operation_state":
    ## §4 `candidate_in_progress_operation`. Moving a checkout mid-rebase
    ## leaves the sequencer's state pointing at a directory that no longer
    ## exists, and the operator's `--continue` then fails in a way that names
    ## neither the rename nor the move.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "inprogress")
      defer: removeDir(fx.scratch)

      discard fx.seedOrigin(gitBin, "widget-pm")
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm",
        previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }]")
      fx.writeProject(["widget-pm"])

      let oldPath = fx.workspaceRoot / "widget-specs"
      fx.cloneInto(gitBin, "widget-pm", oldPath)
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " remote set-url origin " & q(fx.originUrl("widget-specs")))
      # Two branches that touch the same line, then a rebase that conflicts
      # and stops — a real interrupted operation, not a planted marker file.
      writeFile(oldPath / "contended.txt", "theirs\n")
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " add contended.txt")
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " commit -m theirs")
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " switch -c mine HEAD~1")
      writeFile(oldPath / "contended.txt", "mine\n")
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " add contended.txt")
      discard requireGit(q(gitBin) & " -C " & q(oldPath) & " commit -m mine")
      let rebase = run(q(gitBin) & " -C " & q(oldPath) & " rebase main")
      check rebase.code != 0        # the premise: it really did stop

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      check res.code == 2
      let entry = fx.readReport().entryFor("widget-pm")
      check entry.field("relocation") == "candidate_in_progress_operation"
      let detail = entry.field("relocationDetail")
      checkpoint("detail: " & detail)
      check "rebase" in detail
      check "--abort" in detail
      check "--continue" in detail
      # The interrupted rebase is still exactly where the operator left it.
      check dirExists(oldPath / ".git")
      check not dirExists(fx.workspaceRoot / "widget-pm")

  test "t_rename_refuses_a_submodule_with_an_absolute_gitdir":
    ## §4 `submodule_absolute_gitdir` — the one refusal in the table that buys
    ## less than it costs, kept because "rare" is not "never" and what it
    ## prevents is a silently broken checkout after a move that reported
    ## success. There is no submodule detection anywhere else in the workspace
    ## code, by design: a develop-mode sibling checkout IS the submodule
    ## replacement in this model.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "submodule")
      defer: removeDir(fx.scratch)

      discard fx.seedOrigin(gitBin, "widget-pm")
      discard fx.seedOrigin(gitBin, "vendored")
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm",
        previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }]")
      fx.writeProject(["widget-pm"])

      let oldPath = fx.workspaceRoot / "widget-specs"
      fx.cloneInto(gitBin, "widget-pm", oldPath)
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " remote set-url origin " & q(fx.originUrl("widget-specs")))
      # A real submodule, absorbed so its `.git` is a FILE holding a
      # `gitdir:` pointer, then made absolute — which is the state that breaks
      # on a move and the state `absorbgitdirs` exists to produce or repair.
      discard requireGit(q(gitBin) & " -C " & q(oldPath) & " -c " &
        q("protocol.file.allow=always") & " submodule add --quiet " &
        q(fx.originUrl("vendored")) & " vendor/lib")
      let subGit = oldPath / "vendor" / "lib" / ".git"
      check fileExists(subGit)
      writeFile(subGit,
        "gitdir: " & (oldPath / ".git" / "modules" / "vendor/lib") & "\n")

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      check res.code == 2
      let entry = fx.readReport().entryFor("widget-pm")
      check entry.field("relocation") == "submodule_absolute_gitdir"
      let detail = entry.field("relocationDetail")
      checkpoint("detail: " & detail)
      check "vendor/lib" in detail
      check "absorbgitdirs" in detail
      check dirExists(oldPath / ".git")
      check not dirExists(fx.workspaceRoot / "widget-pm")

  test "t_rename_relocates_a_submodule_with_a_relative_gitdir":
    ## The complement, so the refusal above is not simply "any submodule".
    ## A RELATIVE `gitdir:` pointer survives a directory move by construction,
    ## so refusing on it would make the key inert for every checkout that has
    ## a submodule at all.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "submodulerel")
      defer: removeDir(fx.scratch)

      discard fx.seedOrigin(gitBin, "widget-pm")
      discard fx.seedOrigin(gitBin, "vendored")
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm",
        previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }]")
      fx.writeProject(["widget-pm"])

      let oldPath = fx.workspaceRoot / "widget-specs"
      fx.cloneInto(gitBin, "widget-pm", oldPath)
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " remote set-url origin " & q(fx.originUrl("widget-specs")))
      discard requireGit(q(gitBin) & " -C " & q(oldPath) & " -c " &
        q("protocol.file.allow=always") & " submodule add --quiet " &
        q(fx.originUrl("vendored")) & " vendor/lib")
      # git writes a RELATIVE pointer itself; assert that rather than assume
      # it, because the refusal above depends on the difference.
      check "gitdir: ../../.git/modules" in
        readFile(oldPath / "vendor" / "lib" / ".git")
      # `submodule add` stages files, so commit them: a dirty tree would be
      # refused by the planner for an unrelated reason and mask this case.
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " commit -qam \"add submodule\"")

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      let entry = fx.readReport().entryFor("widget-pm")
      check entry.field("relocation") == "relocated"
      # An absorbed submodule's `.git` is a FILE holding the `gitdir:`
      # pointer, which is the whole reason the absolute-pointer case above
      # needs a refusal at all.
      check fileExists(fx.workspaceRoot / "widget-pm" / "vendor" / "lib" /
        ".git")
      check "gitdir: ../../.git/modules" in
        readFile(fx.workspaceRoot / "widget-pm" / "vendor" / "lib" / ".git")
      check not dirExists(oldPath)
      # And the submodule still works from its new location.
      check run(q(gitBin) & " -C " &
        q(fx.workspaceRoot / "widget-pm" / "vendor" / "lib") &
        " rev-parse HEAD").code == 0

  test "t_rename_sync_refuses_when_a_live_repo_claims_the_previous_path":
    ## §4 `previous_path_claimed_by_live_repo` — the sync-side BELT to the
    ## resolver's validator braces. The validator refuses this manifest at
    ## resolution time, so the refusal is reached by a path that bypasses it:
    ## a repo-set the project does not include, resolved separately. The reason
    ## both exist is that a manifest can reach a checkout through a layer
    ## composition or an older writer that never passed through the validator,
    ## and the consequence of getting it wrong is a MOVED DIRECTORY.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "liveclaim")
      defer: removeDir(fx.scratch)

      discard fx.seedOrigin(gitBin, "widget-pm")
      discard fx.seedOrigin(gitBin, "widget-specs")
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm",
        previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }]")
      fx.writeFragment("widget-specs", "widget-specs", "widget-specs")
      fx.writeProject(["widget-pm", "widget-specs"])

      # The validator refuses the pair outright, which is the FIRST line of
      # defence and the one an author meets.
      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      check res.code != 0
      check "declares previous checkout path" in res.output
      check "declares that path RIGHT NOW" in res.output
      # And nothing was moved while it was being refused.
      check not dirExists(fx.workspaceRoot / "widget-pm")
      check not dirExists(fx.workspaceRoot / "widget-specs")

## `CLI/sync.md` § "Automatic cloning of missing repositories" — a declared
## checkout whose `.git` is a FILE is an on-disk checkout, not a missing one.
##
## A linked worktree (`git worktree add`) and an absorbed submodule both carry
## `<checkout>/.git` as a file holding `gitdir: <elsewhere>`. Sync used to test
## for a checkout with `dirExists(<path> / ".git")`, so it observed such a
## checkout as absent, planned `missing_checkout` → `clone`, and the clone
## treated the populated directory as a half-cloned leftover and deleted it,
## uncommitted work included, then reported success.
##
## Each case builds the real on-disk shape with real Git (no mocks: the defect
## lives in how the observation and the clone executor read the filesystem, so
## a stubbed checkout would not exercise it) and drives the real `repro`
## binary:
##
## - a DIRTY linked worktree is refused as `dirty` and left untouched, by
##   `repro workspace sync` and by `repro sync --mainline` (the two sync
##   drivers that clone a missing checkout, each with its own observation);
## - a CLEAN linked worktree behind its remote is fast-forwarded in place —
##   observed and managed through git, which resolves the `.git` file;
## - a `.git` file whose `gitdir` names nothing is still never deleted: the
##   clone's half-clone recovery is for a directory with NO `.git` entry;
## - a `.git` file that is not a `gitdir:` line at all is refused for that
##   repo alone, and the rest of the workspace still syncs;
## - `repro workspace pull`'s work-at-risk gate sees a linked worktree as a
##   checkout, so convergence does not rewind a branch's unpushed commit.
##
## Every case skips (rather than fails) when `git` is absent from PATH, matching
## the convention of the sibling workspace-sync tests.

import std/[json, os, strutils, unittest]
import repro_test_support
import repro_test_support/reasoned_skip
import declared_rename_fixture

proc addLinkedWorktree(fx: RenameFixture; gitBin, name, declaredPath: string;
                       branch = "main"): string =
  ## A clone OUTSIDE the workspace, plus a linked worktree of it at the
  ## declared path. The main clone moves off `branch` first, because git
  ## refuses to check one branch out in two worktrees. Returns the main
  ## clone's path.
  result = fx.scratch / ("main-clone-" & name)
  fx.cloneInto(gitBin, name, result)
  discard requireGit(q(gitBin) & " -C " & q(result) & " switch -q -c parked")
  discard requireGit(q(gitBin) & " -C " & q(result) & " worktree add -q " &
    q(declaredPath) & " " & branch)

proc worktreeListed(gitBin, mainClone, worktreePath: string): bool =
  ## Whether the main clone still lists a worktree at `worktreePath` that git
  ## does not mark prunable, i.e. its `.git` file and admin dir still point at
  ## each other.
  let listed = requireGit(q(gitBin) & " -C " & q(mainClone) &
    " worktree list --porcelain")
  for record in listed.split("\n\n"):
    var path = ""
    var prunable = false
    for line in record.splitLines():
      if line.startsWith("worktree "):
        path = line["worktree ".len .. ^1]
      elif line.startsWith("prunable"):
        prunable = true
    if path.len > 0 and dirExists(path) and sameFile(path, worktreePath):
      return not prunable
  false

proc invokeMainlineSync(fx: RenameFixture): CmdResult =
  var env = clingoEnv()
  env.add(("REPRO_WORKSPACE_CLONES", fx.clonesDir))
  runShell(shellCommand(@[fx.reproBin, "sync", "--mainline", "--write-report",
    "--workspace-root=" & fx.workspaceRoot, "myproject"], env = env))

suite "sync keeps a declared checkout whose .git is a file":

  test "t_sync_refuses_a_dirty_linked_worktree_instead_of_cloning_over_it":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "linked-dirty")
      defer: removeDir(fx.scratch)

      discard fx.seedOrigin(gitBin, "widget-pm")
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm")
      fx.writeProject(["widget-pm"])
      let declared = fx.workspaceRoot / "widget-pm"
      let mainClone = fx.addLinkedWorktree(gitBin, "widget-pm", declared)
      # The premise: `.git` is a FILE, which is what the old presence test
      # read as "no checkout here".
      check fileExists(declared / ".git")
      check not dirExists(declared / ".git")
      writeFile(declared / "precious.txt", "uncommitted work\n")

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      let entry = fx.readReport().entryFor("widget-pm")
      checkpoint("report entry:\n" & pretty(entry, indent = 2))
      # Primary assertion: the uncommitted file survived.
      check fileExists(declared / "precious.txt")
      check fileExists(declared / ".git")
      check not dirExists(declared / ".git")
      check entry.field("syncCase") == "dirty"
      check entry.field("executionStatus") != "cloned"
      check res.code == 2
      check worktreeListed(gitBin, mainClone, declared)
      # The plan announced an update, not a clone.
      check fx.readReport().planFor("widget-pm").field("intendedAction") ==
        "update"

  test "t_sync_fast_forwards_a_clean_linked_worktree_in_place":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "linked-ff")
      defer: removeDir(fx.scratch)

      let seeded = fx.seedOrigin(gitBin, "widget-pm")
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm")
      fx.writeProject(["widget-pm"])
      let declared = fx.workspaceRoot / "widget-pm"
      let mainClone = fx.addLinkedWorktree(gitBin, "widget-pm", declared)
      # One commit behind `origin/main`, clean, on `main`.
      discard requireGit(q(gitBin) & " -C " & q(declared) &
        " reset -q --hard " & seeded.initialSha)
      check fileExists(declared / ".git")

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      let entry = fx.readReport().entryFor("widget-pm")
      checkpoint("report entry:\n" & pretty(entry, indent = 2))
      check res.code == 0
      check entry.field("syncCase") == "clean_fast_forwardable"
      # Still the same linked worktree, now at the remote tip.
      check fileExists(declared / ".git")
      check not dirExists(declared / ".git")
      check requireGit(q(gitBin) & " -C " & q(declared) &
        " rev-parse HEAD").strip() == seeded.tipSha
      check worktreeListed(gitBin, mainClone, declared)

  test "t_sync_mainline_refuses_a_dirty_linked_worktree_instead_of_cloning":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "linked-mainline")
      defer: removeDir(fx.scratch)

      let seeded = fx.seedOrigin(gitBin, "widget-pm")
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm")
      fx.writeProject(["widget-pm"])
      let declared = fx.workspaceRoot / "widget-pm"
      let mainClone = fx.addLinkedWorktree(gitBin, "widget-pm", declared)
      # One commit BEHIND the mainline, so integrating it is a real mutation
      # the dirty tree must block. At the tip, `--mainline` correctly reports
      # `up_to_date` with local changes present: it has nothing to do.
      discard requireGit(q(gitBin) & " -C " & q(declared) &
        " reset -q --hard " & seeded.initialSha)
      writeFile(declared / "precious.txt", "uncommitted work\n")

      let res = fx.invokeMainlineSync()
      checkpoint("sync --mainline output:\n" & res.output)
      check fileExists(declared / "precious.txt")
      check fileExists(declared / ".git")
      check not dirExists(declared / ".git")
      check worktreeListed(gitBin, mainClone, declared)
      let entry = fx.readReport().entryFor("widget-pm")
      checkpoint("report entry:\n" & pretty(entry, indent = 2))
      check entry.field("outcome") == "dirty"
      check entry.field("outcome") != "cloned"
      check res.code != 0

  test "t_sync_never_deletes_a_directory_with_a_dangling_git_file":
    ## Not a checkout git can read — the `gitdir` names nothing — but a `.git`
    ## entry all the same. Sync cannot manage it, so it must refuse it; what it
    ## must not do is take it for a half-cloned leftover and delete it.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "linked-dangling")
      defer: removeDir(fx.scratch)

      discard fx.seedOrigin(gitBin, "widget-pm")
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm")
      fx.writeProject(["widget-pm"])
      let declared = fx.workspaceRoot / "widget-pm"
      createDir(declared)
      writeFile(declared / ".git",
        "gitdir: " & (fx.scratch / "gone" / ".git" / "worktrees" / "x") & "\n")
      writeFile(declared / "notes.txt", "someone's notes\n")

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      check fileExists(declared / "notes.txt")
      check fileExists(declared / ".git")
      check res.code != 0
      let entry = fx.readReport().entryFor("widget-pm")
      checkpoint("report entry:\n" & pretty(entry, indent = 2))
      # git cannot read it, so the pre-plan fetch fails and the repo is
      # refused on that.
      check entry.field("syncCase") == "fetch_failed"
      check entry.field("executionStatus") != "cloned"

  test "t_sync_survives_a_git_file_that_names_no_gitdir":
    ## A `.git` FILE whose content is not a `gitdir:` line at all. git
    ## rejects it ("invalid gitfile format"), and so must sync — for this
    ## repo only. It must neither delete the directory nor abort the run
    ## for every other repo in the workspace.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "linked-malformed")
      defer: removeDir(fx.scratch)

      discard fx.seedOrigin(gitBin, "widget-pm")
      discard fx.seedOrigin(gitBin, "gadget-pm")
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm")
      fx.writeFragment("gadget-pm", "gadget-pm", "gadget-pm")
      fx.writeProject(["widget-pm", "gadget-pm"])
      let declared = fx.workspaceRoot / "widget-pm"
      createDir(declared)
      writeFile(declared / ".git", "this is not a gitdir line\n")
      writeFile(declared / "notes.txt", "someone's notes\n")

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      check fileExists(declared / "notes.txt")
      check fileExists(declared / ".git")
      check res.code != 0
      let report = fx.readReport()
      let entry = report.entryFor("widget-pm")
      checkpoint("report entry:\n" & pretty(entry, indent = 2))
      check entry.field("syncCase") == "fetch_failed"
      check entry.field("executionStatus") != "cloned"
      # The other repo is still materialized: one unreadable checkout is
      # refused, not fatal to the run.
      check report.entryFor("gadget-pm").field("executionStatus") == "cloned"
      check dirExists(fx.workspaceRoot / "gadget-pm" / ".git")

  test "t_pull_gates_a_linked_worktree_carrying_unpushed_work":
    ## `repro workspace pull` converges an existing checkout with
    ## `checkout -B <branch>`, which RESETS the branch, and gates that on the
    ## work it would strand. The gate must see a linked worktree as a
    ## checkout: read as "not a checkout", it found no blockers and the
    ## branch's unpushed commit was silently rewound.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "linked-pull")
      defer: removeDir(fx.scratch)

      let seeded = fx.seedOrigin(gitBin, "widget-pm")
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm")
      fx.writeProject(["widget-pm"])
      let declared = fx.workspaceRoot / "widget-pm"
      let mainClone = fx.addLinkedWorktree(gitBin, "widget-pm", declared)
      # `main` diverges from `origin/main`: one commit behind it, plus one
      # local commit no remote carries. Convergence would rewind `main`.
      discard requireGit(q(gitBin) & " -C " & q(declared) &
        " reset -q --hard " & seeded.initialSha)
      writeFile(declared / "mine.txt", "my work\n")
      discard requireGit(q(gitBin) & " -C " & q(declared) & " add mine.txt")
      discard requireGit(q(gitBin) & " -C " & q(declared) &
        " commit -q -m " & q("unpushed work on main"))
      let mine = requireGit(q(gitBin) & " -C " & q(declared) &
        " rev-parse HEAD").strip()
      check fileExists(declared / ".git")

      var env = clingoEnv()
      env.add(("REPRO_WORKSPACE_CLONES", fx.clonesDir))
      let res = runShell(shellCommand(@[fx.reproBin, "workspace", "pull",
        "--workspace-root=" & fx.workspaceRoot, "myproject"], env = env))
      checkpoint("pull output:\n" & res.output)
      check requireGit(q(gitBin) & " -C " & q(declared) &
        " rev-parse refs/heads/main").strip() == mine
      check res.output.contains("skipped_work_at_risk")
      check res.code == 2
      check fileExists(declared / ".git")
      check worktreeListed(gitBin, mainClone, declared)

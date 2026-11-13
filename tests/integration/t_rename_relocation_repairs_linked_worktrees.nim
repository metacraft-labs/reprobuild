## Declared-Repository-Renames.md §3.5 "Linked worktrees" and §4
## `linked_worktree_unrepairable` — a relocation must not orphan the linked
## worktrees of the checkout it moves.
##
## A linked worktree's `.git` is a FILE holding `gitdir: <main>/.git/
## worktrees/<name>`. Before this was handled, the move renamed the main
## checkout and said nothing; every linked worktree then answered "not a git
## repository" until someone ran `git worktree repair` by hand. The live case
## that found it: a pm repo renamed while its prior checkout carried six linked
## worktrees under `~/.cache/…`, OUTSIDE the workspace, used by other sessions.
##
## Asserted:
##   1. A linked worktree OUTSIDE the workspace, holding uncommitted work, is
##      still a git checkout after the relocation, resolves to the moved
##      checkout's common directory, and keeps its work. The report names it.
##   2. A linked worktree INSIDE the moved checkout (it travelled with it) and
##      one created with relative paths are repaired too.
##   3. A MISSING linked worktree, and a LOCKED one, cannot be repaired by an
##      unattended sync: the relocation refuses (exit 2), names the worktree
##      and its remedy, and moves nothing.
##   4. A linked worktree inside the moved checkout is mapped to its new
##      location when the workspace root is reached through a symlink.
##   5. A candidate that is ITSELF a linked worktree is moved with its work,
##      re-registered with its common directory (no `prunable` entry left),
##      and then synced in place like any checkout, including one whose
##      `gitdir:` is relative and whose declared path is at another depth;
##      a LOCKED one is refused and left where it is, with its work.
##   6. A linked worktree the repair cannot rewrite after the move fails the
##      run (exit 1, `linked_worktree_repair_failed`) and names the command
##      that repairs it, while the moved checkout stays at its declared path.
##
## See `declared_rename_fixture.nim` for why nothing here is mocked: the defect
## is a fact about real `.git` files on a real filesystem.

import repro_test_support/reasoned_skip
import std/[json, os, strutils, unittest]
import declared_rename_fixture

proc commonDirOf(gitBin, dir: string): tuple[code: int; path: string] =
  ## `git rev-parse --git-common-dir`, resolved to an absolute path. A
  ## non-zero code is the orphaned state this file is about.
  let res = run(q(gitBin) & " -C " & q(dir) & " rev-parse --git-common-dir")
  if res.code != 0:
    return (res.code, res.output)
  let answer = res.output.strip()
  (0, if isAbsolute(answer): answer else: dir / answer)

proc rekeyedOf(entry: JsonNode): seq[string] =
  if entry.hasKey("relocationRekeyed"):
    for item in entry["relocationRekeyed"]:
      result.add(item.getStr())

proc supportsRelativeWorktrees(gitBin, repo: string): bool =
  ## `git worktree add --relative-paths` arrived in git 2.48. Probed from
  ## inside `repo` because `git worktree add -h` outside a repository dies
  ## with "not a git repository" before printing the usage, and matched on
  ## `relative-paths` because the usage spells the option `--[no-]relative-
  ## paths`, which does not contain the literal `--relative-paths`.
  let help = run(q(gitBin) & " -C " & q(repo) & " worktree add -h")
  "relative-paths" in help.output

proc setUpCandidate(fx: RenameFixture; gitBin: string): string =
  ## A clean checkout of `widget-pm` at its prior path `widget-specs`, reached
  ## by its old URL — the shape `t_rename_relocates_instead_of_cloning` uses.
  discard fx.seedOrigin(gitBin, "widget-pm")
  fx.writeFragment("widget-pm", "widget-pm", "widget-pm",
    previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }]")
  fx.writeProject(["widget-pm"])
  result = fx.workspaceRoot / "widget-specs"
  fx.cloneInto(gitBin, "widget-pm", result)
  discard requireGit(q(gitBin) & " -C " & q(result) &
    " remote set-url origin " & q(fx.originUrl("widget-specs")))

proc setUpLinkedCandidate(fx: RenameFixture; gitBin: string;
                          declaredPath = "widget-pm";
                          relative = false): tuple[mainClone, oldPath: string] =
  ## The prior checkout `widget-specs` as a LINKED worktree (on `main`, the
  ## branch the fragment names) of a clone outside the workspace that is
  ## reached by the old URL. `relative` creates it with `--relative-paths`
  ## (the caller checks the git supports it); `declaredPath` is where the
  ## fragment now declares the repo.
  discard fx.seedOrigin(gitBin, "widget-pm")
  fx.writeFragment("widget-pm", "widget-pm", declaredPath,
    previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }]")
  fx.writeProject(["widget-pm"])
  result.mainClone = fx.scratch / "main-clone"
  fx.cloneInto(gitBin, "widget-pm", result.mainClone)
  discard requireGit(q(gitBin) & " -C " & q(result.mainClone) &
    " remote set-url origin " & q(fx.originUrl("widget-specs")))
  # Free `main` for the linked worktree.
  discard requireGit(q(gitBin) & " -C " & q(result.mainClone) &
    " checkout --detach")
  result.oldPath = fx.workspaceRoot / "widget-specs"
  discard requireGit(q(gitBin) & " -C " & q(result.mainClone) &
    " worktree add " & (if relative: "--relative-paths " else: "") &
    q(result.oldPath) & " main")
  doAssert fileExists(result.oldPath / ".git")

proc gitAtLeast(versionLine: string; major, minor: int): bool =
  ## Whether `git --version` output (`git version 2.54.0`, possibly with a
  ## vendor suffix) names at least `major.minor`. Unparseable output answers
  ## true, so the caller's "only an old git may skip" check fails loudly
  ## rather than passing on a version it could not read.
  let words = versionLine.splitWhitespace()
  if words.len < 3:
    return true
  let parts = words[2].split('.')
  if parts.len < 2:
    return true
  try:
    let (a, b) = (parseInt(parts[0]), parseInt(parts[1]))
    a > major or (a == major and b >= minor)
  except ValueError:
    true

suite "declared rename — linked worktrees of the moved checkout":

  test "t_rename_relocation_repairs_an_outside_linked_worktree":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "wt-outside")
      defer: removeDir(fx.scratch)
      let oldPath = setUpCandidate(fx, gitBin)

      # Outside the workspace, as agent and verifier worktrees are.
      let linked = fx.scratch / "elsewhere" / "agent-wt"
      createDir(linked.parentDir)
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " worktree add -b agent-work " & q(linked))
      writeFile(linked / "in-flight.txt", "someone else's uncommitted work\n")
      # The premise: before the sync the worktree is a checkout of the
      # candidate.
      check commonDirOf(gitBin, linked).code == 0

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      let newPath = fx.workspaceRoot / "widget-pm"
      let entry = fx.readReport().entryFor("widget-pm")
      check entry.field("relocation") == "relocated"
      check dirExists(newPath / ".git")
      check not dirExists(oldPath)

      # 1. The linked worktree is still a git checkout, of the MOVED repo.
      let common = commonDirOf(gitBin, linked)
      checkpoint("linked worktree common dir: " & $common)
      check common.code == 0
      if common.code == 0:
        check sameFile(common.path, newPath / ".git")
      let status = run(q(gitBin) & " -C " & q(linked) & " status --porcelain")
      check status.code == 0
      check "in-flight.txt" in status.output
      check fileExists(linked / "in-flight.txt")
      check requireGit(q(gitBin) & " -C " & q(linked) &
        " symbolic-ref --short HEAD").strip() == "agent-work"
      # The main checkout still lists it, and not as prunable.
      let listing = requireGit(q(gitBin) & " -C " & q(newPath) &
        " worktree list --porcelain")
      check "prunable" notin listing

      # The report names the worktree it repointed; a silent repair would be
      # as unauditable as the silent breakage it replaced.
      var named = false
      for item in rekeyedOf(entry):
        if "agent-wt" in item and "linked worktree" in item:
          named = true
      check named
      check res.code == 0

  test "t_rename_relocation_repairs_inside_and_relative_linked_worktrees":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "wt-inside")
      defer: removeDir(fx.scratch)
      let oldPath = setUpCandidate(fx, gitBin)

      # Inside the candidate: it travels WITH the move, so its post-move path
      # is under the destination. Excluded so the main checkout stays clean.
      writeFile(oldPath / ".git" / "info" / "exclude", ".worktrees/\n")
      createDir(oldPath / ".worktrees")
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " worktree add -b inner-work " & q(oldPath / ".worktrees" / "inner"))
      var expected = @[fx.workspaceRoot / "widget-pm" / ".worktrees" / "inner"]
      if supportsRelativeWorktrees(gitBin, oldPath):
        # `gitdir:` RELATIVE to the linked worktree, which a move of the main
        # checkout breaks just as surely as an absolute one.
        let relative = fx.scratch / "rel-wt"
        discard requireGit(q(gitBin) & " -C " & q(oldPath) &
          " worktree add --relative-paths -b rel-work " & q(relative))
        check readFile(relative / ".git").startsWith("gitdir: ..")
        expected.add(relative)
      else:
        # Only an old git may leave the relative case out. A probe that
        # wrongly answers "unsupported" on a new git would otherwise drop the
        # case silently, as an earlier version of this probe did.
        let version = requireGit(q(gitBin) & " --version").strip()
        checkpoint("git lacks --relative-paths (" & version &
          "); relative case not exercised")
        check not gitAtLeast(version, 2, 48)

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      let newPath = fx.workspaceRoot / "widget-pm"
      check fx.readReport().entryFor("widget-pm").field("relocation") ==
        "relocated"
      check res.code == 0
      for wt in expected:
        let common = commonDirOf(gitBin, wt)
        checkpoint(wt & " -> " & $common)
        check common.code == 0
        if common.code == 0:
          check sameFile(common.path, newPath / ".git")
      # The BACKLINK too: the moved checkout's `worktrees/<id>/gitdir` must
      # name each worktree's new location. A stale one still resolves today
      # but is listed `prunable`, and the next `git worktree prune` (or gc)
      # deletes the administrative entry, orphaning the worktree after all.
      let listing = requireGit(q(gitBin) & " -C " & q(newPath) &
        " worktree list --porcelain")
      checkpoint("post-sync worktree list:\n" & listing)
      check "prunable" notin listing

  test "t_rename_refuses_a_missing_linked_worktree":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "wt-missing")
      defer: removeDir(fx.scratch)
      let oldPath = setUpCandidate(fx, gitBin)
      let linked = fx.scratch / "gone-wt"
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " worktree add -b gone " & q(linked))
      # Deleted without `git worktree remove` — or on a volume that is not
      # mounted right now. Nothing on disk is left to repoint.
      removeDir(linked)

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      check res.code == 2
      let entry = fx.readReport().entryFor("widget-pm")
      check entry.field("relocation") == "linked_worktree_unrepairable"
      let detail = entry.field("relocationDetail")
      checkpoint("detail: " & detail)
      check "gone-wt" in detail
      check "MISSING" in detail
      check "worktree prune" in detail
      # Nothing moved and nothing was cloned over the declared path.
      check dirExists(oldPath / ".git")
      check not dirExists(fx.workspaceRoot / "widget-pm")

  test "t_rename_refuses_a_locked_linked_worktree":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "wt-locked")
      defer: removeDir(fx.scratch)
      let oldPath = setUpCandidate(fx, gitBin)
      let linked = fx.scratch / "locked-wt"
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " worktree add -b held " & q(linked))
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " worktree lock --reason \"on the travel disk\" " & q(linked))

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      check res.code == 2
      let entry = fx.readReport().entryFor("widget-pm")
      check entry.field("relocation") == "linked_worktree_unrepairable"
      let detail = entry.field("relocationDetail")
      checkpoint("detail: " & detail)
      check "locked-wt" in detail
      check "LOCKED" in detail
      check "on the travel disk" in detail
      check "worktree unlock" in detail
      # Untouched: the locked worktree still resolves to the unmoved checkout.
      check dirExists(oldPath / ".git")
      check not dirExists(fx.workspaceRoot / "widget-pm")
      let common = commonDirOf(gitBin, linked)
      check common.code == 0
      if common.code == 0:
        check sameFile(common.path, oldPath / ".git")

  test "t_rename_relocation_repairs_an_inside_linked_worktree_via_a_symlinked_root":
    # Git records a linked worktree's path symlink-RESOLVED, while the
    # workspace root may be reached through a symlink (a linked home
    # directory, macOS `/tmp`). The worktree inside the moved checkout must
    # still be mapped to its post-move path, although by then the prior path
    # no longer exists to be resolved.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      var fx = newRenameFixture(gitBin, "wt-symlink")
      defer: removeDir(fx.scratch)
      let linkedRoot = fx.scratch / "ws-link"
      createSymlink(fx.workspaceRoot, linkedRoot)
      fx.workspaceRoot = linkedRoot
      let oldPath = setUpCandidate(fx, gitBin)
      writeFile(oldPath / ".git" / "info" / "exclude", ".worktrees/\n")
      createDir(oldPath / ".worktrees")
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " worktree add -b inner-work " & q(oldPath / ".worktrees" / "inner"))
      # The premise: git recorded the resolved spelling, not the linked one.
      let listing = requireGit(q(gitBin) & " -C " & q(oldPath) &
        " worktree list --porcelain")
      check (linkedRoot / "widget-specs") notin listing

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      let newPath = fx.workspaceRoot / "widget-pm"
      check fx.readReport().entryFor("widget-pm").field("relocation") ==
        "relocated"
      check res.code == 0
      let inner = newPath / ".worktrees" / "inner"
      let common = commonDirOf(gitBin, inner)
      checkpoint(inner & " -> " & $common)
      check common.code == 0
      if common.code == 0:
        check sameFile(common.path, newPath / ".git")

  test "t_rename_relocates_a_candidate_that_is_itself_a_linked_worktree":
    # The prior checkout is a LINKED worktree of a clone outside the
    # workspace: its `.git` is a file. Moving it cuts the link the other
    # way round from the cases above — the outside clone, which did not
    # move, still records the prior path, so git would list the moved
    # checkout `prunable` and the next `git worktree prune` would discard its
    # index and HEAD. The relocation re-registers it, and the sync then holds
    # it at the declared path like any checkout: its uncommitted work makes
    # it `dirty`, refused, never cloned over (sync.md "What counts as an
    # on-disk checkout").
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "wt-self")
      defer: removeDir(fx.scratch)
      let (mainClone, oldPath) = setUpLinkedCandidate(fx, gitBin)
      writeFile(oldPath / "in-flight.txt", "uncommitted work\n")

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      let newPath = fx.workspaceRoot / "widget-pm"
      let entry = fx.readReport().entryFor("widget-pm")
      check entry.field("relocation") == "relocated"
      check entry.field("syncCase") == "dirty"
      check entry.field("executionStatus") != "cloned"
      check res.code == 2
      check not dirExists(oldPath)
      # Still a linked worktree, with its work, of the outside clone.
      check fileExists(newPath / ".git")
      check fileExists(newPath / "in-flight.txt")
      let common = commonDirOf(gitBin, newPath)
      checkpoint("moved checkout common dir: " & $common)
      check common.code == 0
      if common.code == 0:
        check sameFile(common.path, mainClone / ".git")
      # The backlink: the outside clone lists the NEW path as a live
      # worktree, and nothing as prunable.
      let listing = requireGit(q(gitBin) & " -C " & q(mainClone) &
        " worktree list --porcelain")
      checkpoint("post-sync worktree list:\n" & listing)
      check "prunable" notin listing
      var listedAtNewPath = false
      for line in listing.splitLines():
        if line.startsWith("worktree ") and
            dirExists(line["worktree ".len .. ^1]) and
            sameFile(line["worktree ".len .. ^1], newPath):
          listedAtNewPath = true
      check listedAtNewPath
      check rekeyedOf(entry).len > 0

  test "t_rename_refuses_a_candidate_that_is_itself_a_locked_linked_worktree":
    # A lock is git's "do not move this worktree" marker (`git worktree move`
    # refuses one too); an unattended sync does not override it.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "wt-self-locked")
      defer: removeDir(fx.scratch)
      let (mainClone, oldPath) = setUpLinkedCandidate(fx, gitBin)
      writeFile(oldPath / "in-flight.txt", "uncommitted work\n")
      discard requireGit(q(gitBin) & " -C " & q(mainClone) &
        " worktree lock --reason \"on the travel disk\" " & q(oldPath))

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      check res.code == 2
      let entry = fx.readReport().entryFor("widget-pm")
      check entry.field("relocation") == "linked_worktree_unrepairable"
      let detail = entry.field("relocationDetail")
      checkpoint("detail: " & detail)
      check "LOCKED" in detail
      check "on the travel disk" in detail
      check "worktree unlock" in detail
      check not dirExists(fx.workspaceRoot / "widget-pm")
      # Left where it was, with its work, still a worktree of the outside
      # clone.
      check fileExists(oldPath / "in-flight.txt")
      let common = commonDirOf(gitBin, oldPath)
      check common.code == 0
      if common.code == 0:
        check sameFile(common.path, mainClone / ".git")

  test "t_rename_relocates_a_relative_linked_worktree_candidate_to_a_new_depth":
    # The candidate's `.git` file names its common directory RELATIVE to
    # itself, and the declared path is one level deeper, so the move breaks
    # BOTH links: the moved checkout's `../main-clone/...` no longer resolves,
    # and the outside clone's backlink names the prior path. The repair runs
    # from the common directory's side, which recovers both.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "wt-self-rel")
      defer: removeDir(fx.scratch)
      let version = requireGit(q(gitBin) & " --version").strip()
      if not gitAtLeast(version, 2, 48):
        skip("git " & version & " lacks `worktree add --relative-paths`")
      else:
        let (mainClone, oldPath) = setUpLinkedCandidate(fx, gitBin,
          declaredPath = "nested/widget-pm", relative = true)
        check readFile(oldPath / ".git").startsWith("gitdir: ..")
        writeFile(oldPath / "in-flight.txt", "uncommitted work\n")

        let res = fx.invokeSync()
        checkpoint("sync output:\n" & res.output)
        let newPath = fx.workspaceRoot / "nested" / "widget-pm"
        let entry = fx.readReport().entryFor("nested/widget-pm")
        checkpoint("report entry:\n" & pretty(entry, indent = 2))
        check entry.field("relocation") == "relocated"
        check entry.field("syncCase") == "dirty"
        check entry.field("executionStatus") != "cloned"
        check res.code == 2
        check not dirExists(oldPath)
        check fileExists(newPath / ".git")
        check fileExists(newPath / "in-flight.txt")
        let common = commonDirOf(gitBin, newPath)
        checkpoint("moved checkout common dir: " & $common)
        check common.code == 0
        if common.code == 0:
          check sameFile(common.path, mainClone / ".git")
        let listing = requireGit(q(gitBin) & " -C " & q(mainClone) &
          " worktree list --porcelain")
        checkpoint("post-sync worktree list:\n" & listing)
        check "prunable" notin listing
        var listedAtNewPath = false
        for line in listing.splitLines():
          if line.startsWith("worktree ") and
              dirExists(line["worktree ".len .. ^1]) and
              sameFile(line["worktree ".len .. ^1], newPath):
            listedAtNewPath = true
        check listedAtNewPath

  test "t_rename_reports_a_linked_worktree_the_repair_could_not_reach":
    # The post-move half of §3.5: a worktree that passed the pre-flight
    # (present, unlocked) but whose `.git` file the repair cannot rewrite —
    # here because it is read-only, as on a read-only mount. The move has
    # happened, so the checkout is at its declared path and synced as usual,
    # but the run must not exit 0: the report tags the relocation
    # `linked_worktree_repair_failed`, names the worktree and the command that
    # repairs it, and the run exits 1.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "wt-unwritable")
      defer: removeDir(fx.scratch)
      let oldPath = setUpCandidate(fx, gitBin)
      let linked = fx.scratch / "ro-wt"
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " worktree add -b ro-work " & q(linked))
      let readOnlyFile = {fpUserRead, fpGroupRead, fpOthersRead}
      let readOnlyDir = readOnlyFile + {fpUserExec, fpGroupExec, fpOthersExec}
      setFilePermissions(linked / ".git", readOnlyFile)
      setFilePermissions(linked, readOnlyDir)
      # Runs before the scratch removal above (defers unwind in reverse).
      defer:
        setFilePermissions(linked, readOnlyDir + {fpUserWrite})
        setFilePermissions(linked / ".git", readOnlyFile + {fpUserWrite})
      # The premise: the `.git` file really cannot be rewritten. A privileged
      # user ignores the mode bits, and then there is no failure to observe.
      var writable = false
      try:
        var probeFile: File
        if open(probeFile, linked / ".git", fmAppend):
          writable = true
          close(probeFile)
      except CatchableError:
        discard
      if writable:
        skip("the linked worktree's .git file stays writable despite its " &
          "mode bits (privileged user); the repair cannot be made to fail")
      else:
        let res = fx.invokeSync()
        checkpoint("sync output:\n" & res.output)
        check res.code == 1
        let newPath = fx.workspaceRoot / "widget-pm"
        let entry = fx.readReport().entryFor("widget-pm")
        check entry.field("relocation") == "linked_worktree_repair_failed"
        let detail = entry.field("relocationDetail")
        checkpoint("detail: " & detail)
        check "ro-wt" in detail
        check "worktree repair" in detail
        # The move happened and is not undone: the checkout is at its
        # declared path, and the worktree's own content is untouched.
        check dirExists(newPath / ".git")
        check not dirExists(oldPath)
        check fileExists(linked / ".git")

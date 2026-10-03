## Declared-Repository-Renames.md §4 `relocation_failed` — the one refusal that
## is EXIT 1 rather than exit 2, because it is a broken action rather than a
## judgement call.
##
## This is the Windows case in substance: a directory rename fails while any
## file under it is held open, and an editor or a language server is enough.
## The requirement is not that it be rare — it is that the refusal be CLEAN:
## nothing moved, nothing deleted, nothing half-written at the destination, and
## re-runnable once the obstruction is gone. It is staged here with a
## read-only parent directory, which fails the rename and the copy fallback for
## the same reason a held handle does, on a platform where the staging is
## reliable.
##
## Asserted:
##   1. Exit 1, and the repo reports `relocation_failed` with the OS error.
##   2. The candidate is untouched — still a checkout, still carrying its
##      local work.
##   3. NOTHING at the destination: not a half-moved tree, and not a clone
##      substituted for the failed move.
##   4. Re-runnable: with the obstruction removed, the same sync relocates.

import std/[json, os, osproc, strutils, unittest]
import declared_rename_fixture

suite "declared rename — a failed move is clean and re-runnable":

  test "t_rename_relocation_failed_moves_nothing_and_exits_one":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    elif defined(windows):
      # The staging below uses POSIX permission bits.
      skip()
    elif execCmdEx("id -u").output.strip() == "0":
      # root ignores the permission bits, so the obstruction cannot be staged
      # and a pass here would mean nothing.
      skip()
    else:
      let fx = newRenameFixture(gitBin, "movefail")
      defer:
        try:
          setFilePermissions(fx.workspaceRoot / "nest",
            {fpUserRead, fpUserWrite, fpUserExec})
        except CatchableError: discard
        removeDir(fx.scratch)

      discard fx.seedOrigin(gitBin, "widget-pm")
      # The declared path is NESTED, so the obstruction can sit on its parent
      # without making the workspace root itself unwritable (the sync has to
      # be able to write its own report).
      fx.writeFragment("widget-pm", "widget-pm", "nest/widget-pm",
        previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }]")
      fx.writeProject(["widget-pm"])

      let oldPath = fx.workspaceRoot / "widget-specs"
      fx.cloneInto(gitBin, "widget-pm", oldPath)
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " remote set-url origin " & q(fx.originUrl("widget-specs")))
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " switch -c local-only")
      let head = requireGit(q(gitBin) & " -C " & q(oldPath) &
        " rev-parse HEAD").strip()

      createDir(fx.workspaceRoot / "nest")
      setFilePermissions(fx.workspaceRoot / "nest",
        {fpUserRead, fpUserExec})

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)

      # 1. A BROKEN ACTION, not a judgement call: exit 1.
      check res.code == 1
      let entry = fx.readReport().entryFor("nest/widget-pm")
      check entry.field("relocation") == "relocation_failed"
      check entry.field("syncCase") == "relocation_failed"
      check entry.field("executionStatus") == "failed"
      let detail = entry.field("relocationDetail")
      checkpoint("detail: " & detail)
      check "widget-specs" in detail
      check "nest/widget-pm" in detail

      # 2. The candidate is exactly as it was.
      check dirExists(oldPath / ".git")
      check "local-only" in localBranches(gitBin, oldPath)
      check requireGit(q(gitBin) & " -C " & q(oldPath) &
        " rev-parse HEAD").strip() == head

      # 3. Nothing half-moved, and NO clone substituted for the failed move.
      #    Cloning fresh here would reproduce the orphan-beside-empty-clone
      #    outcome the mechanism exists to prevent, and do it knowingly.
      check not dirExists(fx.workspaceRoot / "nest" / "widget-pm")
      check entry.field("action") == "none"

      # 4. Re-runnable once the obstruction is gone.
      setFilePermissions(fx.workspaceRoot / "nest",
        {fpUserRead, fpUserWrite, fpUserExec})
      let res2 = fx.invokeSync()
      checkpoint("second sync output:\n" & res2.output)
      let entry2 = fx.readReport().entryFor("nest/widget-pm")
      check entry2.field("relocation") == "relocated"
      check dirExists(fx.workspaceRoot / "nest" / "widget-pm" / ".git")
      check not dirExists(oldPath)
      check "local-only" in
        localBranches(gitBin, fx.workspaceRoot / "nest" / "widget-pm")

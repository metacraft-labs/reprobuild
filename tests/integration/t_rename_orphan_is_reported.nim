## Declared-Repository-Renames.md §6 — an old `repro` against a new manifest.
##
## By §2.2 the `previously` key is INVISIBLE to a `repro` that predates it: the
## fragment parses, the clone runs, the orphan appears. That is the designed-for
## degradation and it is as far as PREVENTION can go — there is no channel
## through which a manifest can warn a binary that ignores the table the
## warning would sit in.
##
## What can be built is DETECTION, in the binary that does understand the key.
## A checkout at a declared prior path while the declared path also holds one is
## reported, ALWAYS. It is a notice rather than a refusal — the workspace is
## functional, the new clone works, and nothing is at risk until somebody
## deletes the old directory — but it is unconditional and it never scrolls
## past silently.
##
## This is also what makes the key worth landing even if the rollout order is
## got wrong, which the policy asking for the mechanism makes likely: the first
## correct `repro` to sync the workspace finds the orphan the old one left and
## says so.
##
## Asserted:
##   1. `relocation=orphaned_previous_checkout`, naming BOTH directories.
##   2. What the orphan contains — branch, dirty state, stash count, refs — so
##      the operator can tell whether it matters without opening it.
##   3. On EVERY subsequent sync, not once.
##   4. Printed in the default text output, not only in the JSON report and not
##      only under `--verbose`.
##   5. Nothing is moved, merged or deleted: `sync` must not merge two
##      checkouts.

import std/[json, os, strutils, unittest]
import repro_test_support/reasoned_skip
import declared_rename_fixture

suite "declared rename — the orphan an old repro left is reported":

  test "t_rename_orphan_is_reported":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; the declared-rename fixture needs a repository")
    else:
      let fx = newRenameFixture(gitBin, "orphan")
      defer: removeDir(fx.scratch)

      discard fx.seedOrigin(gitBin, "widget-pm")
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm",
        previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }]")
      fx.writeProject(["widget-pm"])

      # Exactly the state an old `repro` leaves behind: a fresh clone at the
      # NEW path, and the operator's original tree stranded at the old one.
      let newPath = fx.workspaceRoot / "widget-pm"
      let oldPath = fx.workspaceRoot / "widget-specs"
      fx.cloneInto(gitBin, "widget-pm", newPath)
      fx.cloneInto(gitBin, "widget-pm", oldPath)
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " switch -c the-branch-nobody-pushed")
      writeFile(oldPath / "unsaved.txt", "the work that gets deleted\n")
      discard requireGit(q(gitBin) & " -C " & q(oldPath) & " add unsaved.txt")
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " stash push -m keepme")
      writeFile(oldPath / "dirty.txt", "uncommitted\n")

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)

      let entry = fx.readReport().entryFor("widget-pm")
      # 1.
      check entry.field("relocation") == "orphaned_previous_checkout"
      let detail = entry.field("relocationDetail")
      checkpoint("detail: " & detail)
      check "widget-pm" in detail
      check "widget-specs" in detail
      # 2. What it contains.
      check "the-branch-nobody-pushed" in detail
      check "stash" in detail
      check "uncommitted change" in detail
      # 4. And in the text output an operator actually reads.
      check "orphaned_previous_checkout" in res.output
      check "widget-specs" in res.output

      # 5. Nothing was moved, merged or deleted; it is a NOTICE.
      check dirExists(newPath / ".git")
      check dirExists(oldPath / ".git")
      check "the-branch-nobody-pushed" in localBranches(gitBin, oldPath)
      check stashCount(gitBin, oldPath) == 1
      check fileExists(oldPath / "dirty.txt")
      # The live checkout is untouched too.
      check "the-branch-nobody-pushed" notin localBranches(gitBin, newPath)

      # 3. EVERY subsequent sync. A notice that fires once is a notice the
      #    next operator never sees.
      let res2 = fx.invokeSync()
      checkpoint("second sync output:\n" & res2.output)
      check "orphaned_previous_checkout" in res2.output
      let entry2 = fx.readReport().entryFor("widget-pm")
      check entry2.field("relocation") == "orphaned_previous_checkout"
      check dirExists(oldPath / ".git")

  test "t_rename_debris_at_the_previous_path_is_not_reported_as_an_orphan":
    ## The notice has to be worth reading, so it is scoped to a directory that
    ## HOLDS SOMETHING. An empty git repository at a prior path — the shape a
    ## failed clone leaves — is not an orphan, and reporting it on every sync
    ## forever is how an unconditional notice becomes noise people filter out.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; the declared-rename fixture needs a repository")
    else:
      let fx = newRenameFixture(gitBin, "orphandebris")
      defer: removeDir(fx.scratch)

      discard fx.seedOrigin(gitBin, "widget-pm")
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm",
        previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }]")
      fx.writeProject(["widget-pm"])

      fx.cloneInto(gitBin, "widget-pm", fx.workspaceRoot / "widget-pm")
      discard requireGit(q(gitBin) & " init -b main " &
        q(fx.workspaceRoot / "widget-specs"))

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      check res.code == 0
      let entry = fx.readReport().entryFor("widget-pm")
      check entry.field("relocation") == ""
      check "orphaned_previous_checkout" notin res.output

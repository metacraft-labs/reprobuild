## Declared-Repository-Renames.md §3.5 — after a relocation across a URL
## change, the relocated checkout borrows objects from BOTH shared bares, and
## every object its working tree needs still resolves.
##
## THE JUDGEMENT THIS PINS, stated as one. A shared bare is keyed by FETCH URL
## and by nothing else, so a rename slugs to a DIFFERENT bare while the
## relocated checkout is still alternated to the old one. The repair APPENDS
## the new bare and KEEPS the old entry. Keeping it is not laziness: objects
## borrowed from the old bare are not necessarily in the new one, which starts
## cold, and under the history-rewrite campaign the old bare may be the only
## remaining holder of pre-rewrite history. Dropping it in the same operation
## can make objects the working tree depends on UNREACHABLE — corrupting a
## checkout that may hold unpushed work, which is the loss the whole mechanism
## exists to prevent. Correctness of the operator's checkout wins because
## republication is guarded elsewhere and independently (the pre-push gate, and
## the refusal to push a branch sharing no history with its remote).
##
## The fixture is the real shape of that risk rather than a contrived one: the
## checkout's HEAD commit exists ONLY in the old bare, because the repository
## was rewritten at its new URL. So the test's negative control is exact —
## restrict the alternates to the new bare alone and the commit stops
## resolving.

import repro_test_support/reasoned_skip
import std/[json, os, strutils, unittest]
import declared_rename_fixture

proc alternatesOf(checkout: string): seq[string] =
  let path = checkout / ".git" / "objects" / "info" / "alternates"
  if not fileExists(path):
    return @[]
  for line in readFile(path).splitLines():
    let trimmed = line.strip()
    if trimmed.len > 0:
      result.add(trimmed)

suite "declared rename — alternates keep the old bare reachable":

  test "t_rename_alternates_keeps_old_bare_reachable":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "alternates")
      defer: removeDir(fx.scratch)

      # ---- phase 1: the workspace BEFORE the rename ----------------------
      let seeded = fx.seedOrigin(gitBin, "widget-specs")
      fx.writeFragment("widget-specs", "widget-specs", "widget-specs")
      fx.writeProject(["widget-specs"])

      let first = fx.invokeSync()
      checkpoint("first sync output:\n" & first.output)
      check first.code == 0
      let oldPath = fx.workspaceRoot / "widget-specs"
      check dirExists(oldPath / ".git")

      # The clone was accelerated from the shared bare for the OLD url and
      # BORROWS its objects (`--reference` without `--dissociate`), which is
      # the state every synced workspace is in.
      let beforeAlternates = alternatesOf(oldPath)
      checkpoint("alternates before: " & beforeAlternates.join(", "))
      check beforeAlternates.len == 1
      check "widget-specs.git" in beforeAlternates[0]
      check requireGit(q(gitBin) & " -C " & q(oldPath) &
        " rev-parse HEAD").strip() == seeded.tipSha

      # ---- phase 2: the rename, with a rewritten history at the new url --
      # The new URL serves the same CONTENT under different commit ids (the
      # `git filter-repo` shape), so the checkout's HEAD commit exists in the
      # OLD bare and nowhere else.
      discard requireGit(q(gitBin) & " init --bare -b main " &
        q(fx.originsDir / "widget-pm"))
      let rewrittenTip = fx.rewriteOriginHistory(gitBin, "widget-pm",
        seeded.seedPath)
      check rewrittenTip != seeded.tipSha
      # The premise: the new url's bare source does NOT carry the old tip.
      check run(q(gitBin) & " -C " & q(fx.originsDir / "widget-pm") &
        " cat-file -e " & q(seeded.tipSha)).code != 0

      removeFile(fx.workspaceRoot / "repos" / "widget-specs.toml")
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm",
        previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }]")
      fx.writeProject(["widget-pm"])

      let second = fx.invokeSync()
      checkpoint("second sync output:\n" & second.output)
      let newPath = fx.workspaceRoot / "widget-pm"
      let entry = fx.readReport().entryFor("widget-pm")
      check entry.field("relocation") == "relocated"
      check dirExists(newPath / ".git")
      check not dirExists(oldPath)

      # 1. TWO bares, the old one kept.
      let afterAlternates = alternatesOf(newPath)
      checkpoint("alternates after: " & afterAlternates.join(", "))
      check afterAlternates.len == 2
      var hasOld = false
      var hasNew = false
      for entryPath in afterAlternates:
        if "widget-specs.git" in entryPath: hasOld = true
        if "widget-pm.git" in entryPath: hasNew = true
      check hasOld
      check hasNew

      # 2. The report says so, and names the consolidation step rather than
      #    leaving the operator to discover a two-bare checkout.
      check (if "relocationAlternates" in entry:
               entry["relocationAlternates"].len
             else: 0) == 2
      check "shared-clones rewire" in second.output

      # 3. Every object the working tree needs resolves.
      check run(q(gitBin) & " -C " & q(newPath) & " cat-file -e " &
        q(seeded.tipSha)).code == 0
      check run(q(gitBin) & " -C " & q(newPath) &
        " rev-list --objects HEAD").code == 0
      check requireGit(q(gitBin) & " -C " & q(newPath) &
        " rev-parse HEAD").strip() == seeded.tipSha

      # 4. THE NEGATIVE CONTROL for the judgement above. Had the repair
      #    dropped the old entry — the "tidier" alternative — this is the
      #    checkout it would have produced: one that cannot resolve its own
      #    HEAD. Asserted by restricting the alternates and restoring them, so
      #    the test proves the kept entry is load-bearing rather than merely
      #    present.
      let altFile = newPath / ".git" / "objects" / "info" / "alternates"
      let saved = readFile(altFile)
      var newBareOnly = ""
      for entryPath in afterAlternates:
        if "widget-pm.git" in entryPath:
          newBareOnly = entryPath
      check newBareOnly.len > 0
      writeFile(altFile, newBareOnly & "\n")
      check run(q(gitBin) & " -C " & q(newPath) & " cat-file -e " &
        q(seeded.tipSha)).code != 0
      writeFile(altFile, saved)
      check run(q(gitBin) & " -C " & q(newPath) & " cat-file -e " &
        q(seeded.tipSha)).code == 0

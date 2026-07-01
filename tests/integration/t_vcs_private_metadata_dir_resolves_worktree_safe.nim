## Unified-Locking-And-Hooks HL-1 (§4.3) — ``vcsPrivateMetadataDir(repoRoot)``
## is VCS-agnostic and WORKTREE-SAFE.
##
## Layer 5 of the configuration plane stores its config under the repo's
## never-tracked VCS-private metadata dir. For git this MUST be the COMMON git
## dir (``git rev-parse --git-common-dir``), because a LINKED WORKTREE's
## ``.git`` is a FILE, not a directory, and its private data lives in the main
## checkout's common dir — never in the per-worktree ``.git`` subdir.
##
## This suite creates a main git checkout, adds a linked worktree, and asserts:
##   1. In the MAIN checkout, ``vcsPrivateMetadataDir`` == ``<main>/.git/repro``.
##   2. In the LINKED WORKTREE, ``vcsPrivateMetadataDir`` STILL resolves to the
##      MAIN checkout's ``.git/repro`` (the common dir) — NOT to the worktree's
##      own per-worktree git dir under ``.git/worktrees/<name>``.
##   3. A non-git directory falls back to ``<root>/.repro-private``.
##
## Falsifiable: if ``vcsPrivateMetadataDir`` used ``<repoRoot>/.git`` literally
## (the naive implementation), then inside the worktree ``<worktree>/.git`` is a
## FILE, and joining ``/repro`` onto it yields a path under a file — the
## common-dir assertion (2) fails. Confirmed by temporarily replacing the
## common-dir resolution with ``root / ".git" / "repro"``: assertion (2) then
## resolves to ``<worktree>/.git/repro`` and the ``== mainPrivate`` check trips.
##
## Hermetic: everything lives in a fresh tempdir; nothing touches ``$HOME`` or a
## shared cache. Skip rule: ``git`` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_cli_support

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

suite "HL-1 — vcsPrivateMetadataDir is VCS-agnostic + worktree-safe":

  test "t_vcs_private_metadata_dir_resolves_worktree_safe":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-hl1-vcsdir-", "")
      defer: removeDir(scratch)

      # ---- main checkout ------------------------------------------------
      let main = scratch / "main"
      createDir(main)
      discard requireGit(q(gitBin) & " init -b main " & q(main))
      discard requireGit(q(gitBin) & " -C " & q(main) &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(main) &
        " config user.name \"HL-1 Tester\"")
      writeFile(main / "seed.txt", "seed\n")
      discard requireGit(q(gitBin) & " -C " & q(main) & " add seed.txt")
      discard requireGit(q(gitBin) & " -C " & q(main) & " commit -m seed")

      # The common dir's private repro dir for the MAIN checkout.
      let mainPrivate = vcsPrivateMetadataDir(main, gitBin)
      check mainPrivate == (main / ".git" / "repro")

      # ---- a LINKED worktree of the same repo ---------------------------
      let wt = scratch / "wt"
      discard requireGit(q(gitBin) & " -C " & q(main) &
        " worktree add -b feature " & q(wt))

      # Sanity: a linked worktree's ``.git`` is a FILE (a gitdir pointer),
      # NOT a directory — the exact case the naive ``<root>/.git`` breaks on.
      check fileExists(wt / ".git")
      check not dirExists(wt / ".git")

      # The load-bearing assertion: inside the worktree, the private dir is
      # the MAIN checkout's common dir — never the per-worktree git dir.
      let wtPrivate = vcsPrivateMetadataDir(wt, gitBin)
      check wtPrivate == mainPrivate
      # And explicitly NOT the per-worktree dir under .git/worktrees/<name>.
      check "worktrees" notin wtPrivate

      # ---- non-git fallback ---------------------------------------------
      let plain = scratch / "plain"
      createDir(plain)
      check vcsPrivateMetadataDir(plain, gitBin) ==
        (absolutePath(plain) / ".repro-private")

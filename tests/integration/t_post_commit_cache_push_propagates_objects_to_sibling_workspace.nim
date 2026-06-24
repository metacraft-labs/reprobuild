## RA-5 — async cache-ref push propagates objects to a sibling workspace.
##
## Exercises the ``pushCacheRef`` mechanism directly (RA-4 later wires it
## into the post-commit hook; RA-5 ships + tests the function). Scenario:
##
##   * One shared bare clone of a local upstream (the per-upstream cache).
##   * Two sibling per-workspace repos W1 and W2, BOTH wired to the shared
##     bare via ``objects/info/alternates`` (so each reads the shared
##     object pool).
##   * A new commit is made in W1. ``pushCacheRef`` pushes W1's branch to
##     ``refs/cache/W1/<branch>`` in the shared bare
##     (``--force --no-verify``, workspace-namespaced).
##
## Assertions (each falsifiable):
##
##   1. The cache ref exists in the shared bare under
##      ``refs/cache/W1/<branch>`` and points at W1's new commit.
##      (Falsifiable: absent if ``pushCacheRef`` did nothing / used the
##      wrong namespace.)
##   2. W2 can read the NEW commit object — with NO explicit fetch into W2
##      — because W2 reads the shared bare's objects through alternates
##      and the push landed the objects there. We verify with
##      ``git -C W2 cat-file -e <newSha>`` and a full ``cat-file -p`` of
##      the commit. (Falsifiable: without the push the object is absent
##      from the shared pool, so the lookup fails.)
##   3. Namespacing: the ref lives under ``refs/cache/W1/`` and NOT under
##      ``refs/cache/W2/`` — a same-named branch from a different
##      workspace would not collide.
##
## Negative control inside the test proves falsifiability: BEFORE the
## push, the new object is NOT reachable from W2.
##
## Hermetic: local ``git init --bare`` upstream + bares under a single
## ``createTempDir``; no network. Skip only when ``git`` is missing.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import shared_clones

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA5 Tester\"")
  writeFile(workPath / "README.md", "ra5 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m base")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " &
    branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc configIdentity(gitBin, repoPath: string) =
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.name \"RA5 Tester\"")

suite "RA-5 — post-commit cache push propagates objects":

  test "test_ra5_cache_push_makes_w1_commit_visible_in_w2":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra5-push-", "")
      defer: removeDir(scratch)

      let origin = scratch / "origin.git"
      discard seedGitOrigin(gitBin, origin, scratch / "seed")
      let originUrl = fileUrl(origin)

      let cacheRoot = scratch / "clones-cache"

      # Build the shared bare via the RA-5 helper (clone-if-missing).
      let refreshed = refreshSharedBare(gitBin, cacheRoot, originUrl)
      check refreshed.ok
      let bare = refreshed.sharedBarePath
      check dirExists(bare / "objects")

      # W1 and W2: clone the upstream, then wire each to the shared bare.
      let w1 = scratch / "w1"
      let w2 = scratch / "w2"
      discard requireGit(q(gitBin) & " clone --branch main " & q(originUrl) &
        " " & q(w1))
      discard requireGit(q(gitBin) & " clone --branch main " & q(originUrl) &
        " " & q(w2))
      configIdentity(gitBin, w1)
      configIdentity(gitBin, w2)

      check wireAlternates(w1, bare).ok
      check wireAlternates(w2, bare).ok
      check isWiredTo(w1, bare)
      check isWiredTo(w2, bare)

      # New commit in W1.
      writeFile(w1 / "feature.txt", "new work in W1\n")
      discard requireGit(q(gitBin) & " -C " & q(w1) & " add feature.txt")
      discard requireGit(q(gitBin) & " -C " & q(w1) &
        " commit -m \"w1 feature\"")
      let newSha = requireGit(q(gitBin) & " -C " & q(w1) &
        " rev-parse HEAD").strip()

      # Negative control (falsifiability): BEFORE the push the new commit
      # object is NOT reachable from W2 (not in W2's own store and not in
      # the shared pool).
      let beforePush = runCmd(q(gitBin) & " -C " & q(w2) &
        " cat-file -e " & newSha)
      check beforePush.code != 0

      # The RA-5 mechanism: push W1's branch into the shared bare under
      # refs/cache/W1/<branch>.
      let pushed = pushCacheRef(gitBin, w1, bare, "W1")
      if not pushed.ok:
        checkpoint("pushCacheRef diagnostic: " & pushed.diagnostic)
      check pushed.ok

      # (1) The cache ref exists in the shared bare and points at newSha.
      let refSha = requireGit(q(gitBin) & " -C " & q(bare) &
        " rev-parse refs/cache/W1/main").strip()
      check refSha == newSha

      # (3) Namespacing: no ref leaked under refs/cache/W2/.
      let w2Ref = runCmd(q(gitBin) & " -C " & q(bare) &
        " rev-parse --verify --quiet refs/cache/W2/main")
      check w2Ref.code != 0

      # (2) W2 sees the new commit object WITHOUT any explicit fetch — it
      # reads the shared bare's objects through alternates.
      let afterPush = runCmd(q(gitBin) & " -C " & q(w2) &
        " cat-file -e " & newSha)
      if afterPush.code != 0:
        checkpoint("W2 cat-file after push: " & afterPush.output)
      check afterPush.code == 0

      # And the full commit content is readable (objects truly present).
      let commitBody = requireGit(q(gitBin) & " -C " & q(w2) &
        " cat-file -p " & newSha)
      check commitBody.contains("w1 feature")

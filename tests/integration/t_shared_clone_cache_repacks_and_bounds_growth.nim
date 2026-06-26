## RA-15 — shared-bare cache maintenance: gc/repack + dead-workspace prune.
##
## The RA-5 shared bare-clone cache accumulates loose objects from every
## ``refs/cache/<ws>/*`` push without bound. RA-15 adds an opportunistic,
## best-effort maintenance pass (``maintainSharedBare``) that:
##
##   1. prunes ``refs/cache/<ws>/*`` for workspaces that no longer exist on
##      disk (liveness predicate), and
##   2. runs ``git gc``/repack — bounded by a loose-object / size / age
##      budget — so the loose-object count drops and objects get packed.
##
## Scenario (hermetic: local ``git init --bare`` upstream + bares under one
## ``createTempDir``; no network; ``REPRO_WORKSPACE_CLONES`` is pinned):
##
##   * One shared bare clone of a local upstream.
##   * Two sibling per-workspace repos, W-live and W-dead, both wired to the
##     shared bare. W-dead is REMOVED from disk before maintenance to model a
##     workspace that no longer exists.
##   * Many cache-ref pushes drive distinct fresh commits into the bare under
##     ``refs/cache/W-live/*`` and ``refs/cache/W-dead/*`` (accumulating loose
##     objects).
##
## Assertions (each falsifiable):
##
##   1. BEFORE maintenance the bare holds many loose objects (the push churn
##      really accumulated). Negative control for the gc assertion.
##   2. AFTER maintenance the loose-object count DROPS sharply and packed
##      objects appear (``git count-objects -v`` loose ``count:`` vs
##      ``in-pack:``). Falsifiable: without the gc the loose count would not
##      fall.
##   3. The dead workspace's ``refs/cache/W-dead/*`` refs are GONE.
##      Falsifiable: skipping the prune leaves them.
##   4. The LIVE workspace's ``refs/cache/W-live/*`` refs SURVIVE — the
##      safety-critical invariant (a live workspace's cache must never be
##      dropped). Falsifiable: an over-broad prune would remove them.
##   5. The budget gate is real: on a freshly-gc'd bare a second pass with a
##      high loose-object budget is a no-op (``ran == false``), and a
##      ``force`` pass runs regardless.

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

proc configIdentity(gitBin, repoPath: string) =
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.name \"RA15 Tester\"")

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main") =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  configIdentity(gitBin, workPath)
  writeFile(workPath / "README.md", "ra15 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m base")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " &
    branch)

proc countInPack(gitBin, barePath: string): int =
  ## ``in-pack:`` field of ``git count-objects -v`` (packed object count).
  let output = requireGit(q(gitBin) & " -C " & q(barePath) &
    " count-objects -v")
  for line in output.splitLines:
    let t = line.strip()
    if t.startsWith("in-pack:"):
      return parseInt(t[len("in-pack:") .. ^1].strip())
  0

proc cacheRefNames(gitBin, barePath: string): seq[string] =
  let output = requireGit(q(gitBin) & " -C " & q(barePath) &
    " for-each-ref --format=" & q("%(refname)") & " refs/cache/")
  for line in output.splitLines:
    let t = line.strip()
    if t.len > 0:
      result.add(t)

proc hasRefsFor(refs: seq[string]; ws: string): bool =
  for r in refs:
    if r.startsWith("refs/cache/" & ws & "/"):
      return true
  false

suite "RA-15 — shared-bare cache maintenance":

  test "test_ra15_cache_repacks_and_prunes_dead_workspace_refs":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra15-gc-", "")
      defer: removeDir(scratch)

      let origin = scratch / "origin.git"
      seedGitOrigin(gitBin, origin, scratch / "seed")
      let originUrl = fileUrl(origin)

      let cacheRoot = scratch / "clones-cache"
      let refreshed = refreshSharedBare(gitBin, cacheRoot, originUrl)
      check refreshed.ok
      let bare = refreshed.sharedBarePath
      check dirExists(bare / "objects")

      # Two sibling per-workspace repos. ``wLive`` stays on disk; ``wDead``
      # is removed before maintenance to model a vanished workspace. Their
      # cache namespace is the directory basename (RA-4/RA-5 convention).
      let wLive = scratch / "w-live"
      let wDead = scratch / "w-dead"
      discard requireGit(q(gitBin) & " clone --branch main " & q(originUrl) &
        " " & q(wLive))
      discard requireGit(q(gitBin) & " clone --branch main " & q(originUrl) &
        " " & q(wDead))
      configIdentity(gitBin, wLive)
      configIdentity(gitBin, wDead)
      check wireAlternates(wLive, bare).ok
      check wireAlternates(wDead, bare).ok

      # Drive many cache-ref pushes: each commit is a fresh distinct object,
      # so the shared bare accumulates loose objects under both namespaces.
      proc churn(repo, ws: string; rounds: int) =
        for i in 0 ..< rounds:
          writeFile(repo / ("f" & $i & ".txt"),
            ws & " change " & $i & "\n")
          discard requireGit(q(gitBin) & " -C " & q(repo) & " add -A")
          discard requireGit(q(gitBin) & " -C " & q(repo) &
            " commit -m " & q(ws & "-" & $i))
          # Use a per-round branch name so each push lands a distinct ref +
          # objects rather than overwriting one moving ref.
          let pushed = pushCacheRef(gitBin, repo, bare, ws,
            branch = "b" & $i)
          if not pushed.ok:
            checkpoint("pushCacheRef: " & pushed.diagnostic)
          check pushed.ok

      churn(wLive, "w-live", 30)
      churn(wDead, "w-dead", 30)

      # (1) Negative control: the bare really accumulated loose objects.
      let looseBefore = looseObjectCount(gitBin, bare)
      check looseBefore > 50

      let refsBefore = cacheRefNames(gitBin, bare)
      check hasRefsFor(refsBefore, "w-live")
      check hasRefsFor(refsBefore, "w-dead")

      # Model the dead workspace: remove its directory. Only ``w-live`` is now
      # live on disk (the liveness predicate).
      removeDir(wDead)
      let liveWorkspaces = discoverLiveWorkspaceNames(
        [wLive, wDead])  # wDead no longer exists → excluded
      check "w-live" in liveWorkspaces
      check "w-dead" notin liveWorkspaces

      # Run the maintenance pass. Force so the gc runs deterministically even
      # if the default loose budget were higher than this fixture's churn.
      let m = maintainSharedBare(gitBin, bare, liveWorkspaces,
        defaultMaintenanceBudget(), force = true)
      if not m.ok:
        checkpoint("maintenance diagnostic: " & m.diagnostic)
      check m.ok
      check m.ran

      # (2) Loose objects dropped sharply and objects are now packed.
      let looseAfter = looseObjectCount(gitBin, bare)
      check looseAfter < looseBefore
      check countInPack(gitBin, bare) > 0

      # (3) Dead-workspace refs are pruned; (4) live-workspace refs survive.
      let refsAfter = cacheRefNames(gitBin, bare)
      check not hasRefsFor(refsAfter, "w-dead")
      check hasRefsFor(refsAfter, "w-live")
      # The prune list reported exactly the dead refs.
      check m.prunedRefs.len > 0
      for r in m.prunedRefs:
        check r.startsWith("refs/cache/w-dead/")

      # (5) Budget gate is real. After a gc the loose count is low, so a
      # second budgeted pass with a high loose limit is a no-op...
      let lenientBudget = MaintenanceBudget(
        looseObjectLimit: 100000, sizeBytesLimit: 0, ageSeconds: 0)
      let noop = maintainSharedBare(gitBin, bare, liveWorkspaces,
        lenientBudget, force = false)
      check noop.ok
      check not noop.ran
      # ...but a forced pass still runs.
      let forced = maintainSharedBare(gitBin, bare, liveWorkspaces,
        lenientBudget, force = true)
      check forced.ok
      check forced.ran

  test "test_ra15_empty_live_set_does_not_prune_any_cache_refs":
    # Safety: an empty live set means "unknown", NOT "all dead". The prune
    # MUST be skipped so we never wipe a live workspace's cache refs just
    # because the caller could not enumerate the live set.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra15-safety-", "")
      defer: removeDir(scratch)

      let origin = scratch / "origin.git"
      seedGitOrigin(gitBin, origin, scratch / "seed")
      let originUrl = fileUrl(origin)
      let cacheRoot = scratch / "clones-cache"
      let bare = refreshSharedBare(gitBin, cacheRoot, originUrl).sharedBarePath

      let w = scratch / "w-only"
      discard requireGit(q(gitBin) & " clone --branch main " & q(originUrl) &
        " " & q(w))
      configIdentity(gitBin, w)
      writeFile(w / "x.txt", "x\n")
      discard requireGit(q(gitBin) & " -C " & q(w) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(w) & " commit -m x")
      check pushCacheRef(gitBin, w, bare, "w-only").ok

      var emptyLive: seq[string]
      let m = maintainSharedBare(gitBin, bare, emptyLive,
        defaultMaintenanceBudget(), force = true)
      check m.ok
      check m.prunedRefs.len == 0
      # The cache ref still exists.
      let refs = cacheRefNames(gitBin, bare)
      check hasRefsFor(refs, "w-only")

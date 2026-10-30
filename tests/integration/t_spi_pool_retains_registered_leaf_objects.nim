## A shared bare (the pool) keeps what its registered borrowers name, and
## expires what nobody names.
##
## Spec: ``reprobuild-specs/spec/Shared-Clone-Pool-Integrity.md`` §3.1–§3.3,
## §3.6 (SPI-GOAL-2, SPI-GOAL-3, SPI-GOAL-5); milestone SPI-1.
##
## Design. Real ``git`` against real repositories on the filesystem: an
## upstream, a pool created by ``refreshSharedBare`` (the code path every
## refresh takes), and two checkouts that borrow from it through
## ``git clone --reference``. Leaf A is registered the way reprobuild
## registers a leaf (``wireAlternates``); leaf B is left unregistered, the
## way a checkout outside the sibling discovery domain would be. The discovery
## tests instead place B in a sibling workspace, representing an older
## reprobuild checkout that must be discovered and protected. Upstream then deletes
## the branches the leaves still point at, the pool's refresh prunes them, the
## pool's objects are aged past the two-week window, and the pool is gc'd.
## What survives is the assertion.
##
## Leaf A names two kinds of pool-only objects: its remote-tracking ref
## (``origin/feat``, whose commit lives only in the pool) and the PARENT of a
## commit A made itself (``mywork``, whose own commit lives in A but whose
## base lives only in the pool). The second one is the case a hook that
## printed only ref tips missed: git keeps what the hook prints "and
## everything it reaches", but reaching is computed in the pool, and A's own
## commit is not in the pool, so nothing reached its parent. Measured
## 2026-10-02 on git 2.54.0 before the hook learned to print that history.
##
## Every protecting case has a mutation case beside it that removes the
## mechanism and shows the same fixture losing the object, because a hook
## that prints nothing protects nothing and git does not warn:
##
##   - ``registered_leaf_survives_unregistered_expires`` — A's objects
##     (aged 30 days) survive ``maintainSharedBare``; B's expire, which is
##     also the proof that expiry actually ran (SPI-GOAL-3).
##   - ``mutation_hook_without_env_reset_protects_nothing`` — the same gc with
##     the hook's ``unset GIT_DIR …`` line removed: gc runs the hook with the
##     pool's ``GIT_DIR`` exported, and it overrides ``git -C <leaf>``. A hook
##     that skipped a leaf it could not read lost A's objects silently
##     (measured 2026-10-02); the hook now refuses such a leaf, so this
##     mutation surfaces as a failed gc that prunes nothing. The case keeps
##     its name so the history of the failure stays findable.
##   - ``mutation_hook_without_history_walk_loses_parent`` — the hook without
##     its walk behind leaf-only ids keeps ``origin/feat`` but loses the
##     parent of A's own commit. (This walk goes beyond the spec's §3.3 list
##     of what the hook prints; see the module comment above.)
##   - ``failing_hook_aborts_pruning`` — a hook that exits non-zero makes git
##     skip pruning: nothing is deleted, not even B's objects (SPI-GOAL-5).
##   - ``unreadable_registered_leaf_aborts_pruning`` — a registered leaf that
##     still exists but that git cannot open (a broken config standing in for
##     an ownership refusal) makes the hook refuse, so nothing is pruned;
##     ``mutation_unreadable_leaf_skipped_loses_its_objects`` shows the same
##     fixture losing A's objects when the hook merely skips such a leaf.
##   - ``missing_registry_aborts_pruning`` — expiry is only switched on once
##     the registry names a leaf, so a registry that has disappeared makes the
##     hook refuse; ``mutation_missing_registry_accepted_prunes_everything``
##     shows the loss when a missing registry is treated as "nothing to keep".
##   - ``empty_registry_or_old_git_keeps_never`` — a pool with no registered
##     leaf, and a pool driven by a git older than 2.42, both keep
##     ``gc.pruneExpire=never``; with a leaf registered and git >= 2.42 it is
##     ``2.weeks.ago``.
##
## Mocks: one. The below-2.42 half of the last case runs ``prepareSharedBare``
## through a two-line shell wrapper that answers ``git version`` with
## ``2.41.0`` and passes every other command to the real git. A real git
## 2.41 is not something a test host can be expected to carry, and the
## property under test is only that the version the tool REPORTS selects the
## fallback; everything the wrapper forwards is real git.
##
## Hermetic: everything lives under one ``createTempDir`` root; git config
## comes from a private ``GIT_CONFIG_GLOBAL``; probes run with
## ``GIT_NO_LAZY_FETCH=1`` so a probe can never heal the fixture by fetching.
## Index integrity regressions also seed real split chains and a multi-pack-index
## over two packs. They verify expired objects leave the pool's active indexes,
## registered borrowers migrate before pool layers disappear, and real graph
## locks fail maintenance without a success stamp. Broken chains and a pool
## with no reachable commits exercise migration and Git's empty-write no-op.
##
## Skip rule: legacy cases skip when ``git`` is missing or older than 2.42;
## index integrity regressions require the supported Git toolchain.
## The denied-traversal fixture additionally requires POSIX directory permissions.

import std/[os, osproc, strutils, tempfiles, times, unittest]
import repro_test_support/reasoned_skip

import shared_clones

proc q(value: string): string = quoteShell(value)

proc gitIn(cwd: string; args: varargs[string]): tuple[code: int;
                                                      output: string] =
  var cmd = "GIT_NO_LAZY_FETCH=1 git -C " & q(cwd)
  for a in args:
    cmd.add(" " & q(a))
  let res = execCmdEx(cmd)
  (code: res.exitCode, output: res.output.strip())

proc must(cwd: string; args: varargs[string]): string =
  let res = gitIn(cwd, args)
  if res.code != 0:
    checkpoint("git " & args.join(" ") & " in " & cwd & " failed: " &
      res.output)
  doAssert res.code == 0, "fixture git command failed: " & args.join(" ")
  res.output

proc commitFile(work, name, body: string) =
  writeFile(work / name, body)
  discard must(work, "add", name)
  discard must(work, "commit", "-q", "-m", name)

proc has(repo, id: string): bool =
  gitIn(repo, "cat-file", "-e", id).code == 0

type Fixture = object
  root, up, cache, pool, a, b, gitBin: string
  aFeat, aBase, aOwn, bFeat: string

const GlobalConfig = """
[user]
  name = SPI Tester
  email = tester@example.invalid
[init]
  defaultBranch = main
[gc]
  autoDetach = false
[maintenance]
  autoDetach = false
"""

proc ageObjects(pool: string) =
  let past = getTime() - initDuration(days = 30)
  for f in walkDirRec(pool / "objects"):
    setLastModificationTime(f, past)

proc setUp(root: string; siblingBorrower = false; splitGraphs = false): Fixture =
  result.root = root
  result.gitBin = findExe("git")
  result.up = root / "up"
  result.cache = root / "cache"
  writeFile(root / "gitconfig", GlobalConfig)
  putEnv("GIT_CONFIG_GLOBAL", root / "gitconfig")
  putEnv("GIT_CONFIG_NOSYSTEM", "1")
  let url = "file://" & result.up
  createDir(result.up)
  discard must(result.up, "init", "-q")
  for i in 1 .. 3:
    commitFile(result.up, "m" & $i, $i & "\n")
  for br in ["feat", "feat2", "feat3"]:
    discard must(result.up, "checkout", "-q", "-b", br, "main")
    commitFile(result.up, br & ".txt", br & "\n")
  discard must(result.up, "checkout", "-q", "main")

  let created = refreshSharedBare(result.gitBin, result.cache, url)
  doAssert created.ok, created.diagnostic
  result.pool = created.sharedBarePath
  if splitGraphs:
    discard must(result.pool, "commit-graph", "write", "--reachable", "--split")
  result.a = root / "ws-a" / "up"
  result.b = (if siblingBorrower: root / "ws-b" / "up"
    else: root / "outside" / "other" / "ws-b" / "up")
  for leaf in [result.a, result.b]:
    createDir(leaf.parentDir)
    discard must(root, "clone", "-q", "--reference", result.pool, url, leaf)
  # A is registered the way reprobuild wires a leaf; B is not.
  let wired = wireAlternates(result.a, result.pool, result.gitBin)
  doAssert wired.ok, wired.diagnostic
  doAssert readBorrowers(result.pool).len == 1

  result.aFeat = must(result.a, "rev-parse", "origin/feat")
  result.bFeat = must(result.b, "rev-parse", "origin/feat3")
  # A's own work: a commit made in A on top of upstream's feat2.
  discard must(result.a, "checkout", "-q", "-b", "mywork", "origin/feat2")
  commitFile(result.a, "mine.txt", "mine\n")
  result.aOwn = must(result.a, "rev-parse", "HEAD")
  result.aBase = must(result.a, "rev-parse", "HEAD~1")
  # Premises: every object under test lives only in the pool (A's own commit
  # only in A), so the leaves really depend on the pool keeping them.
  doAssert has(result.pool, result.aFeat) and has(result.pool, result.aBase)
  doAssert has(result.pool, result.bFeat)
  doAssert not has(result.pool, result.aOwn)
  for leaf in [result.a, result.b]:
    doAssert must(leaf, "count-objects", "-v").contains("in-pack: 0")
  # A names feat through its remote-tracking ref, feat2 only as the parent
  # of its own commit, and feat3 not at all. Drop the refs and reflogs that
  # would otherwise name feat2/feat3 directly, so the parent case rests on
  # the walk alone and feat3 is B's alone.
  discard must(result.a, "update-ref", "-d", "refs/remotes/origin/feat2")
  discard must(result.a, "update-ref", "-d", "refs/remotes/origin/feat3")
  removeDir(result.a / ".git" / "logs")

  if splitGraphs:
    discard must(result.a, "commit-graph", "write", "--reachable", "--split")
    let chain = readFile(result.a / ".git/objects/info/commit-graphs/commit-graph-chain")
    let poolChain = readFile(result.pool / "objects/info/commit-graphs/commit-graph-chain")
    doAssert chain.startsWith(poolChain), "leaf must really chain onto the pool"

  # Upstream deletes all three branches; the pool's refresh prunes them.
  discard must(result.up, "branch", "-q", "-D", "feat", "feat2", "feat3")
  let refreshed = refreshSharedBare(result.gitBin, result.cache, url)
  doAssert refreshed.ok, refreshed.diagnostic
  doAssert gitIn(result.pool, "rev-parse", "-q", "--verify",
    "refs/heads/feat").code != 0
  ageObjects(result.pool)

proc tearDown() =
  delEnv("GIT_CONFIG_GLOBAL")
  delEnv("GIT_CONFIG_NOSYSTEM")

proc gitAtLeast(major, minor: int): bool =
  let v = parseGitVersion(execCmdEx("git version").output)
  v.ok and (v.major > major or (v.major == major and v.minor >= minor))

proc mutateHook(pool, dropFrom, dropTo: string) =
  ## Rewrite the pool's hook with the lines from ``dropFrom`` up to (not
  ## including) ``dropTo`` removed.
  let script = readFile(retentionHookPath(pool))
  let i = script.find(dropFrom)
  let j = script.find(dropTo, i + 1)
  doAssert i >= 0 and j > i, "mutation anchors not found in the hook"
  writeFile(retentionHookPath(pool), script[0 ..< i] & script[j .. ^1])

proc seedMultiPackIndex(f: Fixture) =
  # A second real pack, overlapping the first, makes MIDX verification exercise
  # an actual index which gc must update when replacing the original packs.
  let ids = f.root / "pack-ids"
  writeFile(ids, must(f.pool, "rev-parse", "main") & "\n")
  let packed = execCmdEx("git -C " & q(f.pool) & " pack-objects " &
    q(f.pool / "objects/pack/pack") & " < " & q(ids))
  doAssert packed.exitCode == 0, packed.output
  var packs = 0
  for path in walkFiles(f.pool / "objects/pack/*.pack"):
    inc packs
  doAssert packs >= 2
  discard must(f.pool, "multi-pack-index", "write")
  doAssert fileExists(f.pool / "objects/pack/multi-pack-index")

proc seedBorrowerSplit(f: Fixture) =
  removeFile(f.a / ".git/objects/info/commit-graph")
  discard must(f.a, "commit-graph", "write", "--reachable", "--split")
  doAssert readFile(f.a / ".git/objects/info/commit-graphs/commit-graph-chain").startsWith(
    readFile(f.pool / "objects/info/commit-graphs/commit-graph-chain"))

suite "SPI-1: the pool retains what registered leaves name":

  test "discovery_keeps_never_until_registry_is_complete":
    let root = createTempDir("repro-spi1-discovery-ready-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root, siblingBorrower = true)
    writeFile(borrowersPath(f.pool), f.a & "\n")
    check prepareSharedBare(f.gitBin, f.pool) == ""
    check must(f.pool, "config", "--get", "gc.pruneExpire") == PoolNeverExpire
    check f.b in readBorrowers(f.pool)
    check prepareSharedBare(f.gitBin, f.pool) == ""
    check must(f.pool, "config", "--get", "gc.pruneExpire") == PoolPruneExpire

  test "hook_discovers_unregistered_sibling_and_retains_its_history":
    let root = createTempDir("repro-spi1-discovery-gc-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root, siblingBorrower = true)
    writeFile(borrowersPath(f.pool), f.a & "\n")
    # B's own tip is absent in the pool: discovering only tips loses its base.
    discard must(f.b, "checkout", "-q", "-b", "own", "origin/feat3")
    commitFile(f.b, "own", "own\n")
    discard must(f.b, "update-ref", "-d", "refs/remotes/origin/feat3")
    removeDir(f.b / ".git" / "logs")
    discard must(f.pool, "config", "gc.pruneExpire", PoolPruneExpire)
    let gc = gitIn(f.pool, "gc", "--quiet")
    checkpoint(gc.output)
    check gc.code == 0
    check has(f.pool, f.bFeat)
    check f.b in readBorrowers(f.pool)
    check gitIn(f.b, "fsck", "--connectivity-only").code == 0

  test "discovery_handles_nested_repos_relative_alternates_and_worktrees":
    let root = createTempDir("repro-spi1-discovery-paths-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root, siblingBorrower = true)
    let nested = root / ".ws-hidden" / "nested" / ".up"
    createDir(nested.parentDir)
    moveDir(f.b, nested)
    writeFile(alternatesFilePath(nested),
      relativePath(f.pool / "objects", nested / ".git" / "objects") & "\n")
    let linked = root / "ws-c" / "linked"
    createDir(linked.parentDir)
    discard must(nested, "worktree", "add", "-q", "--detach", linked)
    writeFile(borrowersPath(f.pool), f.a & "\n")
    let hook = execCmdEx("sh " & q(retentionHookPath(f.pool)))
    checkpoint(hook.output)
    check hook.exitCode == 0
    check f.bFeat in hook.output.splitLines()
    check nested in readBorrowers(f.pool)
    check linked in readBorrowers(f.pool)

  test "unreadable_discovered_sibling_refuses_expiry_and_gc":
    let root = createTempDir("repro-spi1-discovery-unreadable-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root, siblingBorrower = true)
    writeFile(borrowersPath(f.pool), f.a & "\n")
    writeFile(f.b / ".git" / "config", "[broken\n")
    check not poolRetentionReady(f.gitBin, f.pool)
    discard must(f.pool, "config", "gc.pruneExpire", PoolPruneExpire)
    let gc = gitIn(f.pool, "gc", "--quiet")
    checkpoint(gc.output)
    check gc.code != 0
    check has(f.pool, f.aFeat)
    check has(f.pool, f.bFeat)

  test "workspace_root_seed_uses_marked_workspace_parent":
    let root = createTempDir("repro-spi1-discovery-workspace-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root, siblingBorrower = true)
    let workspace = root / "domain" / "ws"
    let sibling = root / "domain" / "other" / "up"
    createDir(workspace.parentDir)
    createDir(sibling.parentDir)
    moveDir(f.a, workspace)
    moveDir(f.b, sibling)
    writeFile(workspace / "repro-workspace.toml", "")
    # If the workspace-root seed were treated as workspace/repo, scanning
    # would escape to root and this unrelated broken repository would refuse.
    let unrelated = root / "unrelated"
    createDir(unrelated)
    discard must(unrelated, "init", "-q")
    writeFile(unrelated / ".git" / "config", "[broken\n")
    writeFile(borrowersPath(f.pool), workspace & "\n")
    check not poolRetentionReady(f.gitBin, f.pool)
    check sibling in readBorrowers(f.pool)
    check poolRetentionReady(f.gitBin, f.pool)

  test "inaccessible_alternates_parent_refuses_expiry_and_gc":
    when defined(windows):
      skip("needs POSIX directory traversal permissions; chmod cannot deny traversal on Windows")
    else:
      let root = createTempDir("repro-spi1-discovery-inaccessible-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root, siblingBorrower = true)
      writeFile(borrowersPath(f.pool), f.a & "\n")
      let info = f.b / ".git" / "objects" / "info"
      let permissions = getFilePermissions(info)
      defer: setFilePermissions(info, permissions)
      setFilePermissions(info, {})
      # Positive control: this host must actually enforce the denied traversal.
      doAssert execCmdEx("test -x " & q(info)).exitCode != 0
      check not poolRetentionReady(f.gitBin, f.pool)
      discard must(f.pool, "config", "gc.pruneExpire", PoolPruneExpire)
      let gc = gitIn(f.pool, "gc", "--quiet")
      checkpoint(gc.output)
      check gc.code != 0
      check has(f.pool, f.bFeat)

  test "registered_leaf_survives_unregistered_expires":
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi1-retain-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      check must(f.pool, "config", "--get", "gc.pruneExpire") ==
        PoolPruneExpire
      check must(f.pool, "config", "--get", "gc.recentObjectsHook") ==
        retentionHookConfigValue(f.pool)
      let m = maintainSharedBare(f.gitBin, f.pool, ["ws-a", "ws-b"],
        force = true)
      checkpoint(m.diagnostic)
      check m.ok and m.ran
      # A: the remote-tracking ref's commit and the parent of A's own commit.
      check has(f.pool, f.aFeat)
      check has(f.pool, f.aBase)
      let fsck = gitIn(f.a, "fsck", "--connectivity-only")
      checkpoint("A fsck: " & fsck.output)
      check fsck.code == 0
      # B is not registered: its commit expired, so expiry really ran.
      check not has(f.pool, f.bFeat)

  test "gc_expires_objects_without_stale_pool_or_borrower_indexes":
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi-graph-expiry-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root, splitGraphs = true)
      seedMultiPackIndex(f)
      seedBorrowerSplit(f)
      let m = maintainSharedBare(f.gitBin, f.pool, ["ws-a", "ws-b"], force = true)
      checkpoint(m.diagnostic)
      check m.ok and m.ran
      check not has(f.pool, f.bFeat) # expiry must really happen
      check has(f.pool, f.aBase)
      for repo in [f.pool, f.a]:
        let fsck = gitIn(repo, "fsck", "--connectivity-only")
        checkpoint(repo & " fsck: " & $fsck.code & " " & fsck.output)
        check fsck.code == 0
        check "commit-graph" notin fsck.output
      check fileExists(f.pool / "objects/pack/multi-pack-index")
      let midx = gitIn(f.pool, "multi-pack-index", "verify")
      checkpoint(midx.output)
      check midx.code == 0
      check fileExists(f.pool / "objects/info/commit-graph")
      check fileExists(f.a / ".git/objects/info/commit-graph")
      check not fileExists(f.pool / "objects/info/commit-graphs/commit-graph-chain")
      check not fileExists(f.a / ".git/objects/info/commit-graphs/commit-graph-chain")

  test "borrower_graph_lock_aborts_gc_before_expiry":
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi-graph-locked-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root, splitGraphs = true)
      seedBorrowerSplit(f)
      writeFile(f.a / ".git/objects/info/commit-graph.lock", "locked\n")
      let m = maintainSharedBare(f.gitBin, f.pool, ["ws-a"], force = true)
      checkpoint(m.diagnostic)
      check not m.ok and not m.ran
      check "commit-graph" in m.diagnostic
      check has(f.pool, f.bFeat)
      check not fileExists(f.pool / MaintenanceStampRelPath)

  test "shallow_borrower_cannot_silently_skip_graph_migration":
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi-graph-shallow-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root, splitGraphs = true)
      seedBorrowerSplit(f)
      writeFile(f.a / ".git/shallow", must(f.a, "rev-parse", "HEAD~1") & "\n")
      # Git silently returns success without converting a shallow graph. The
      # migration must refuse instead of replacing the pool below that chain.
      let skipped = gitIn(f.a, "-c", "core.commitGraph=true",
        "commit-graph", "write", "--reachable")
      doAssert skipped.code == 0
      doAssert fileExists(f.a / ".git/objects/info/commit-graphs/commit-graph-chain")
      doAssert not fileExists(f.a / ".git/objects/info/commit-graph")
      let m = maintainSharedBare(f.gitBin, f.pool, ["ws-a"], force = true)
      checkpoint(m.diagnostic)
      check not m.ok and not m.ran
      check "commit-graph" in m.diagnostic
      check has(f.pool, f.bFeat)
      check not fileExists(f.pool / MaintenanceStampRelPath)

  test "pool_graph_noop_conditions_abort_before_expiry":
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      for blocker in ["shallow", "grafts"]:
        block:
          let root = createTempDir("repro-spi-pool-graph-noop-", "")
          defer:
            tearDown()
            removeDir(root)
          let f = setUp(root)
          discard must(f.pool, "commit-graph", "write", "--reachable")
          doAssert fileExists(f.pool / "objects/info/commit-graph")
          if blocker == "shallow":
            writeFile(f.pool / "shallow", must(f.pool, "rev-parse", "main~1") & "\n")
          else:
            writeFile(f.pool / "info/grafts", must(f.pool, "rev-parse", "main") & "\n")
          # A preexisting monolithic file cannot prove that a successful Git
          # exit refreshed the index. Both real Git conditions skip its write.
          doAssert gitIn(f.pool, "-c", "core.commitGraph=true",
            "commit-graph", "write", "--reachable").code == 0
          let m = maintainSharedBare(f.gitBin, f.pool, ["ws-a"], force = true)
          checkpoint(blocker & ": " & m.diagnostic)
          check not m.ok and not m.ran
          check "commit-graph" in m.diagnostic
          check has(f.pool, f.bFeat)
          check not fileExists(f.pool / MaintenanceStampRelPath)

  test "broken_borrower_chain_is_rebuilt_on_touch":
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi-graph-broken-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root, splitGraphs = true)
      seedBorrowerSplit(f)
      let chainDir = f.a / ".git/objects/info/commit-graphs"
      for path in walkFiles(chainDir / "graph-*.graph"):
        removeFile(path)
      let broken = gitIn(f.a, "fsck", "--connectivity-only")
      doAssert broken.code != 0 and "commit-graph" in broken.output
      check ensureLeafPoolConfig(f.gitBin, f.a, f.pool) == ""
      check fileExists(f.a / ".git/objects/info/commit-graph")
      let healed = gitIn(f.a, "fsck", "--connectivity-only")
      checkpoint(healed.output)
      check healed.code == 0

  test "empty_pool_drops_graph_for_expired_commits":
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi-graph-empty-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root, splitGraphs = true)
      discard must(f.pool, "commit-graph", "write", "--reachable")
      let tree = must(f.pool, "rev-parse", "main^{tree}")
      let head = must(f.pool, "rev-parse", "main")
      discard must(f.pool, "update-ref", "--no-deref", "HEAD", head)
      for line in must(f.pool, "for-each-ref", "--format=%(refname)").splitLines():
        discard must(f.pool, "update-ref", "-d", line)
      # Non-commit refs and a detached HEAD do not make --reachable write a
      # graph. Neither may leave the stale graph masquerading as a fresh one.
      discard must(f.pool, "update-ref", "refs/tags/tree-only", tree)
      # A remains registered, so expiry runs. Main and A's history are retained
      # through the hook even though the pool has no refs of its own.
      let m = maintainSharedBare(f.gitBin, f.pool, ["ws-a"], force = true)
      checkpoint(m.diagnostic)
      check m.ok and m.ran
      check not has(f.pool, f.bFeat)
      for repo in [f.pool, f.a]:
        let fsck = gitIn(repo, "fsck", "--connectivity-only")
        checkpoint(fsck.output)
        check fsck.code == 0

  test "pool_graph_lock_reports_failed_pass_without_stamp":
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi-pool-graph-locked-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      writeFile(f.pool / "objects/info/commit-graph.lock", "locked\n")
      let m = maintainSharedBare(f.gitBin, f.pool, ["ws-a"], force = true)
      checkpoint(m.diagnostic)
      check not m.ok and m.ran
      check "commit-graph" in m.diagnostic
      check not fileExists(f.pool / MaintenanceStampRelPath)

  test "mutation_hook_without_env_reset_protects_nothing":
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi1-noreset-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      mutateHook(f.pool, "unset GIT_DIR", "# Checkouts are partial clones")
      # The operator-run gc: the pool's own config, no reprobuild in between
      # (``maintainSharedBare`` would rewrite the hook first). Without the
      # reset, ``git -C <leaf>`` resolves the pool's exported GIT_DIR
      # relative to the leaf and fails. A hook that SKIPPED such a leaf
      # protected nothing and git did not warn; this hook refuses instead,
      # so the missing reset now surfaces as a failed gc that deleted
      # nothing.
      let gc = gitIn(f.pool, "gc", "--quiet")
      checkpoint("gc without the env reset: " & $gc.code & " " & gc.output)
      check gc.code != 0
      check has(f.pool, f.aFeat)
      check has(f.pool, f.aBase)
      check has(f.pool, f.bFeat)          # refused: nothing pruned at all

  test "mutation_hook_without_history_walk_loses_parent":
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi1-nowalk-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      mutateHook(f.pool, "  # Ids this pool does not hold", "done < ")
      discard must(f.pool, "gc", "--quiet")
      check has(f.pool, f.aFeat)          # the tip is still printed ...
      check not has(f.pool, f.aBase)      # ... but its parent is lost

  test "failing_hook_aborts_pruning":
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi1-failhook-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      writeFile(retentionHookPath(f.pool), "#!/bin/sh\nexit 1\n")
      let gc = gitIn(f.pool, "gc", "--quiet")
      checkpoint("gc with a failing hook: " & $gc.code & " " & gc.output)
      check has(f.pool, f.aFeat)
      check has(f.pool, f.aBase)
      check has(f.pool, f.bFeat)          # nothing at all was pruned

  test "unreadable_registered_leaf_aborts_pruning":
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi1-unreadable-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      # A is still a checkout that borrows from the pool, but git cannot open
      # it (a broken config stands in for an ownership refusal).
      let cfg = f.a / ".git" / "config"
      writeFile(cfg, readFile(cfg) & "[broken\n")
      doAssert gitIn(f.a, "rev-parse", "--git-dir").code != 0
      let gc = gitIn(f.pool, "gc", "--quiet")
      checkpoint("gc with an unreadable leaf: " & $gc.code & " " & gc.output)
      check has(f.pool, f.aFeat)
      check has(f.pool, f.aBase)
      check has(f.pool, f.bFeat)          # the hook refused: nothing pruned

  test "mutation_unreadable_leaf_skipped_loses_its_objects":
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi1-unreadable-mut-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      let cfg = f.a / ".git" / "config"
      writeFile(cfg, readFile(cfg) & "[broken\n")
      let hook = retentionHookPath(f.pool)
      let script = readFile(hook)
      let refuse = "|| { status=1; continue; }\n  : > "
      doAssert script.contains(refuse), "mutation anchor not found in the hook"
      let discoveryRefusal = "--git-common-dir 2>/dev/null) || return 1"
      doAssert script.contains(discoveryRefusal)
      writeFile(hook, script.replace(refuse, "|| continue\n  : > ").replace(
        discoveryRefusal, "--git-common-dir 2>/dev/null) || return 0"))
      discard must(f.pool, "gc", "--quiet")
      check not has(f.pool, f.aFeat)      # skipping the leaf expired its objects

  test "missing_registry_aborts_pruning":
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi1-noregistry-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      removeFile(borrowersPath(f.pool))
      let gc = gitIn(f.pool, "gc", "--quiet")
      checkpoint("gc with the registry gone: " & $gc.code & " " & gc.output)
      check has(f.pool, f.aFeat)
      check has(f.pool, f.bFeat)          # nothing pruned

  test "mutation_missing_registry_accepted_prunes_everything":
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi1-noregistry-mut-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      removeFile(borrowersPath(f.pool))
      let hook = retentionHookPath(f.pool)
      let script = readFile(hook)
      let refuse = "[ -f \"$registry\" ] || exit 1"
      doAssert script.contains(refuse), "mutation anchor not found in the hook"
      writeFile(hook, script.replace(refuse, "[ -f \"$registry\" ] || exit 0"))
      discard must(f.pool, "gc", "--quiet")
      check not has(f.pool, f.aFeat)      # A is registered no more: lost

  test "empty_registry_or_old_git_keeps_never":
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi1-never-", "")
      defer:
        tearDown()
        removeDir(root)
      writeFile(root / "gitconfig", GlobalConfig)
      putEnv("GIT_CONFIG_GLOBAL", root / "gitconfig")
      putEnv("GIT_CONFIG_NOSYSTEM", "1")
      let gitBin = findExe("git")
      let up = root / "up"
      createDir(up)
      discard must(up, "init", "-q")
      commitFile(up, "a", "a\n")
      let url = "file://" & up
      # No leaf registered: never.
      let pool = refreshSharedBare(gitBin, root / "cache", url).sharedBarePath
      check must(pool, "config", "--get", "gc.pruneExpire") == PoolNeverExpire
      check fileExists(retentionHookPath(pool))
      # A registered leaf and git >= 2.42: the expiry window.
      let leaf = root / "ws" / "leaf"
      discard must(root, "clone", "-q", "--reference", pool, url, leaf)
      check wireAlternates(leaf, pool, gitBin).ok
      check prepareSharedBare(gitBin, pool) == ""
      check must(pool, "config", "--get", "gc.pruneExpire") == PoolPruneExpire
      # The same pool through a git that reports 2.41: back to never.
      let stub = root / "git-2.41"
      writeFile(stub, "#!/bin/sh\n" &
        "if [ \"$1\" = version ] || [ \"$1\" = --version ]; then " &
        "echo 'git version 2.41.0'; exit 0; fi\n" &
        "exec " & q(gitBin) & " \"$@\"\n")
      setFilePermissions(stub, {fpUserRead, fpUserWrite, fpUserExec})
      check not gitSupportsRetentionHook(stub)
      check gitSupportsRetentionHook(gitBin)
      check prepareSharedBare(stub, pool) == ""
      check must(pool, "config", "--get", "gc.pruneExpire") == PoolNeverExpire

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
##   - ``resolved_conflict_stage_survives_gc`` — a conflicted stage that only
##     the index's resolve-undo record names (resolved, added, ``merge
##     --quit``) survives, and ``checkout -m`` recreates the conflict;
##     ``mutation_hook_without_resolve_undo_loses_conflict_stage`` shows
##     the hook without ``--resolve-undo`` losing it.
##   - ``sparse_linked_worktree_of_a_full_leaf_is_read_without_expansion`` —
##     a cone-mode sparse linked worktree of a non-sparse leaf: the hook
##     prints the tree its sparse entry names without opening it, and gc
##     keeps that tree;
##     ``mutation_hook_reading_indexes_under_the_leaf_config_expands_them``
##     reads the index by path under the leaf's configuration, as the hook
##     did before, and git expands it: the tree is not printed, and the
##     pool's copy is refreshed as a side effect.
##   - ``cache_tree_subtree_under_a_kept_root_survives_gc`` and
##     ``cache_tree_subtree_under_an_invalidated_root_survives_gc`` — a
##     cache-tree node only A holds, over a subtree only expired pool history
##     reaches: git reuses the topmost valid node without looking below it,
##     so the hook prints every valid node and the subtree survives;
##     ``mutation_hook_without_cache_tree_commits_a_missing_subtree`` shows
##     A's next commit exiting 0 over the pruned subtree, and
##     ``corrupt_cache_tree_extension_aborts_pruning`` that an index whose
##     extensions cannot be read makes the hook refuse;
##     ``cache_tree_nodes_are_read_from_every_index_layout`` reads the same
##     nodes from index versions 3 and 4, with EOIE, and from a split index.
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
##   - ``checkout_paths_start_no_borrower_discovery_pass`` — refreshing a pool
##     (``refreshSharedBare``, ``prepareSharedBare``: what clone, sync, branch
##     and ``ws enable`` run for every repo) starts no discovery pass, never
##     enables the window, and leaves an enabled one in place; the pass runs
##     once, in ``maintainSharedBare``, which is where a gc may prune. Each
##     pass walks every sibling workspace, and a workspace's repos each have
##     their own pool, so a pass per refresh made one ``repro ws enable`` of
##     20 repos take about two hours (reprobuild-pm
##     ``issues/2026-11-16-repro-ws-enable-runs-a-full-sibling-workspace-discovery-pass-once-per-repo.md``).
##   - ``refused_discovery_names_the_path_it_stopped_at`` — a pass that fails
##     says which checkout it could not vouch for, on stderr and in
##     ``poolRetentionReadiness``'s reason, so a pool that stays at ``never``
##     can be explained.
##
## Mocks: two, both thin wrappers around the real git. The below-2.42 half
## of ``empty_registry_or_old_git_keeps_never`` runs ``prepareSharedBare``
## through a two-line shell wrapper that answers ``git version`` with
## ``2.41.0`` and passes every other command to the real git. A real git
## 2.41 is not something a test host can be expected to carry, and the
## property under test is only that the version the tool REPORTS selects the
## fallback; everything the wrapper forwards is real git.
## ``checkout_paths_start_no_borrower_discovery_pass`` drives the production
## procs through a wrapper that appends a line to a log whenever it is asked
## to run the discovery alias, then runs the real git with the same
## arguments. Counting passes needs an observer at the process boundary, and
## the wrapper changes nothing git does.
##
## ``concurrent_engine_recordings_keep_every_engine`` covers the pool's other
## registry, ``<pool>/repro/engines`` (§3.4): eight real child processes of
## this executable record eight engines at the same moment, and every engine
## must be in the list afterwards.
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

# One of several concurrent recorders of a pool's engine list (§3.4): spin
# until the start file appears, then record ``engine`` once, as one of many
# repro processes wiring or checking leaves of one pool at the same moment
# would. A real separate process, so the contention is real OS locking.
when declared(recordPoolEngine):
  if paramCount() == 4 and paramStr(1) == "record-engine-child":
    # Spin rather than sleep, so the recorders start as close together as
    # possible; give up if the parent never writes the start file.
    let deadline = epochTime() + 60.0
    while not fileExists(paramStr(4)):
      if epochTime() > deadline: quit(2)
    let failed = recordPoolEngine(paramStr(2), paramStr(3))
    if failed.len > 0:
      stderr.writeLine(failed)
      quit(1)
    quit(0)

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
  # A refresh starts no borrower discovery pass, so it cannot enable the
  # expiry window. Run the pass the way maintenance and migration do (the
  # same production call), once: the cases below that gc the pool by hand
  # rest on the window being enabled, and would otherwise pass by pruning
  # nothing. With a sibling borrower this one pass registers B and keeps
  # ``never``, which is the state those cases start from.
  doAssert ensureSharedBareSafety(result.gitBin, result.pool,
    readinessPass = true)
  if not siblingBorrower:
    doAssert must(result.pool, "config", "--get", "gc.pruneExpire") ==
      PoolPruneExpire
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

proc stageExpiredBlob(f: Fixture; worktree: string): string =
  ## Stage in ``worktree`` the blob of ``feat3.txt``, which only B's
  ## unregistered history reaches, and return its id. The leaf reads it
  ## through its alternates, so it lives in the pool alone.
  result = must(f.pool, "rev-parse", f.bFeat & ":feat3.txt")
  doAssert has(f.pool, result)
  discard must(worktree, "checkout", f.bFeat, "--", "feat3.txt")
  doAssert result in must(worktree, "ls-files", "--stage", "feat3.txt")
  # Staging by path writes no object: A still has no copy of its own.
  doAssert must(f.a, "count-objects", "-v").contains("in-pack: 0")
  doAssert not fileExists(f.a / ".git" / "objects" / result[0 .. 1] /
    result[2 .. ^1])

proc resolveConflictWithExpiredStage(f: Fixture): string =
  ## In A, merge B's pool-only ``feat3`` commit over A's own ``feat3.txt``:
  ## an add/add conflict whose stage 3 is the blob only B's unregistered
  ## history reaches. Resolve it, ``git add`` it, and ``git merge --quit``,
  ## so the only thing in A that still names that blob is the index's
  ## resolve-undo record. Return the blob's id.
  result = must(f.pool, "rev-parse", f.bFeat & ":feat3.txt")
  commitFile(f.a, "feat3.txt", "ours\n")
  let merge = gitIn(f.a, "merge", "--no-edit", f.bFeat)
  doAssert merge.code != 0, "the merge must conflict: " & merge.output
  doAssert result in must(f.a, "ls-files", "--unmerged", "feat3.txt")
  writeFile(f.a / "feat3.txt", "resolved\n")
  discard must(f.a, "add", "feat3.txt")
  discard must(f.a, "merge", "--quit")
  doAssert gitIn(f.a, "rev-parse", "-q", "--verify", "MERGE_HEAD").code != 0
  doAssert result in must(f.a, "ls-files", "--resolve-undo")
  doAssert result notin must(f.a, "ls-files", "--stage")
  doAssert not fileExists(f.a / ".git" / "objects" / result[0 .. 1] /
    result[2 .. ^1])

proc sparseWorktreeOverExpiredTree(f: Fixture; wt: string): string =
  ## A linked worktree of A, at A's ``HEAD``, whose cone-mode sparse index
  ## collapses ``deep/`` into one sparse-directory entry naming a tree only
  ## expired pool history reaches. A itself is not sparse. ``wt`` must lie
  ## outside A's sibling discovery domain: a worktree discovery finds is
  ## registered and read from inside itself, under its own configuration,
  ## which hides the defect. Return the tree.
  # Upstream adds ``deep/`` on a branch and drops it again; the pool's
  # refreshes fetch it and then prune the ref, keeping the objects. Both
  # refreshes come before the worktree exists, so neither depends on where
  # it lies.
  let url = "file://" & f.up
  discard must(f.up, "checkout", "-q", "-b", "deep", "main")
  createDir(f.up / "deep")
  commitFile(f.up, "deep" / "inner.txt", "inner\n")
  let deep = must(f.up, "rev-parse", "HEAD")
  discard must(f.up, "checkout", "-q", "main")
  var refreshed = refreshSharedBare(f.gitBin, f.cache, url)
  doAssert refreshed.ok, refreshed.diagnostic
  result = must(f.pool, "rev-parse", deep & ":deep")
  discard must(f.up, "branch", "-q", "-D", "deep")
  refreshed = refreshSharedBare(f.gitBin, f.cache, url)
  doAssert refreshed.ok, refreshed.diagnostic
  doAssert has(f.pool, deep)
  createDir(wt.parentDir)
  discard must(f.a, "worktree", "add", "-q", "--detach", wt, "HEAD")
  # Staging by path writes no object; the sparse collapse reuses the tree
  # the pool already holds.
  discard must(wt, "checkout", deep, "--", "deep")
  discard must(f.a, "config", "extensions.worktreeConfig", "true")
  discard must(wt, "sparse-checkout", "set", "--cone", "--sparse-index")
  doAssert ("040000 " & result & " 0\tdeep/") in
    must(wt, "ls-files", "--stage", "--sparse")
  doAssert must(f.a, "config", "--bool", "--default", "false",
    "core.sparseCheckout") == "false"
  doAssert not fileExists(f.a / ".git" / "objects" / result[0 .. 1] /
    result[2 .. ^1])
  doAssert must(f.pool, "config", "gc.pruneExpire") != "never"
  ageObjects(f.pool)

proc cacheTreeOverExpiredSubtree(f: Fixture; invalidateRoot: bool):
    tuple[root, outer, deep: string] =
  ## In A, a cache-tree whose root and ``outer/`` are trees only A holds,
  ## written by ``git write-tree`` and named by nothing else, over
  ## ``outer/deep/``, a tree only expired pool history reaches. With
  ## ``invalidateRoot`` a later ``git add`` of a top-level file invalidates
  ## the root and leaves ``outer/`` valid. Git checks only that the topmost
  ## valid node exists before it reuses it, so A's next commit records
  ## whatever is below that node (issue 2026-11-20-a-cache-tree-root-the-pool-
  ## keeps-can-name-a-subtree-it-pruned).
  # Upstream adds ``outer/deep/`` on a branch and drops it again; the pool's
  # refreshes fetch it and then prune the ref, keeping the objects.
  let url = "file://" & f.up
  discard must(f.up, "checkout", "-q", "-b", "deep", "main")
  createDir(f.up / "outer" / "deep")
  commitFile(f.up, "outer" / "deep" / "inner.txt", "inner\n")
  let deep = must(f.up, "rev-parse", "HEAD")
  discard must(f.up, "checkout", "-q", "main")
  var refreshed = refreshSharedBare(f.gitBin, f.cache, url)
  doAssert refreshed.ok, refreshed.diagnostic
  result.deep = must(f.pool, "rev-parse", deep & ":outer/deep")
  discard must(f.up, "branch", "-q", "-D", "deep")
  refreshed = refreshSharedBare(f.gitBin, f.cache, url)
  doAssert refreshed.ok, refreshed.diagnostic
  doAssert has(f.pool, deep)
  # Staging by path writes no object; A's own file makes ``outer/`` a tree
  # the pool does not have.
  discard must(f.a, "checkout", deep, "--", "outer")
  writeFile(f.a / "outer" / "own.txt", "own\n")
  discard must(f.a, "add", "outer/own.txt")
  result.root = must(f.a, "write-tree")
  result.outer = must(f.a, "rev-parse", result.root & ":outer")
  doAssert must(f.a, "rev-parse", result.outer & ":deep") == result.deep
  for id in [result.root, result.outer]:
    doAssert not has(f.pool, id)
    doAssert fileExists(f.a / ".git" / "objects" / id[0 .. 1] / id[2 .. ^1])
  doAssert not fileExists(f.a / ".git" / "objects" / result.deep[0 .. 1] /
    result.deep[2 .. ^1])
  if invalidateRoot:
    writeFile(f.a / "extra.txt", "extra\n")
    discard must(f.a, "add", "extra.txt")
  doAssert must(f.pool, "config", "gc.pruneExpire") != "never"
  ageObjects(f.pool)

proc looseObjectPath(repo, id: string): string =
  result = repo / "objects" / id[0 .. 1] / id[2 .. ^1]
  doAssert fileExists(result), "expected a loose object: " & result

proc runRetentionHook(f: Fixture): tuple[code: int; ids: seq[string];
                                         stderr: string] =
  ## Run the pool's hook the way gc does (from the pool, with its
  ## ``GIT_DIR`` exported) and return what it printed.
  let err = f.root / "hook.stderr"
  let res = execCmdEx("cd " & q(f.pool) & " && GIT_DIR=" & q(f.pool) &
    " sh " & q(retentionHookPath(f.pool)) & " 2> " & q(err))
  (code: res.exitCode, ids: res.output.splitLines(),
   stderr: readFile(err))

proc reftableLeaf(f: Fixture): string =
  ## A registered leaf on the reftable backend, in a sibling workspace of A,
  ## whose detached HEAD is B's pool-only commit and which has no ref that
  ## reaches it.
  result = f.root / "ws-r" / "up"
  createDir(result.parentDir)
  discard must(f.root, "clone", "-q", "--ref-format=reftable", "--reference",
    f.pool, "file://" & f.up, result)
  doAssert must(result, "rev-parse", "--show-ref-format") == "reftable"
  discard must(result, "checkout", "-q", "--detach", f.bFeat)
  doAssert not dirExists(result / ".git" / "logs")
  let wired = wireAlternates(result, f.pool, f.gitBin)
  doAssert wired.ok, wired.diagnostic
  doAssert result in readBorrowers(f.pool)

suite "SPI-1: the pool retains what registered leaves name":

  test "discovery_keeps_never_until_registry_is_complete":
    let root = createTempDir("repro-spi1-discovery-ready-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root, siblingBorrower = true)
    writeFile(borrowersPath(f.pool), f.a & "\n")
    # The pass runs where a gc is about to prune (``maintainSharedBare``) and
    # in migration, which is what ``readinessPass = true`` selects.
    check ensureSharedBareSafety(f.gitBin, f.pool, readinessPass = true)
    check must(f.pool, "config", "--get", "gc.pruneExpire") == PoolNeverExpire
    check f.b in readBorrowers(f.pool)
    check ensureSharedBareSafety(f.gitBin, f.pool, readinessPass = true)
    check must(f.pool, "config", "--get", "gc.pruneExpire") == PoolPruneExpire

  test "checkout_paths_start_no_borrower_discovery_pass":
    let root = createTempDir("repro-spi1-discovery-count-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root)
    let url = "file://" & f.up
    let log = root / "discovery-passes.log"
    let counting = root / "git-counting-discovery"
    writeFile(counting, "#!/bin/sh\n" &
      "for arg in \"$@\"; do\n" &
      "  if [ \"$arg\" = " & RetentionDiscoverAlias & " ]; then " &
      "echo pass >> " & q(log) & "; fi\n" &
      "done\n" &
      "exec " & q(f.gitBin) & " \"$@\"\n")
    setFilePermissions(counting, {fpUserRead, fpUserWrite, fpUserExec})
    proc passes(): int =
      (if fileExists(log): readFile(log).count("pass\n") else: 0)
    # Positive control: the wrapper does see a pass when one is run.
    check poolRetentionReady(counting, f.pool)
    check passes() == 1
    removeFile(log)

    # A pool at ``never`` with a registered borrower: the state of every pool
    # of a freshly enabled workspace. Refreshing it, as each repo of a clone,
    # sync, branch or enable does, walks nothing and enables nothing.
    discard must(f.pool, "config", "gc.pruneExpire", PoolNeverExpire)
    for round in 1 .. 3:
      check prepareSharedBare(counting, f.pool) == ""
      let refreshed = refreshSharedBare(counting, f.cache, url)
      check refreshed.ok
    check passes() == 0
    check must(f.pool, "config", "--get", "gc.pruneExpire") == PoolNeverExpire

    # The pass runs where a gc may prune: once per maintenance, and that is
    # what enables the window.
    let m = maintainSharedBare(counting, f.pool, ["ws-a"], force = true)
    checkpoint(m.diagnostic)
    check m.ok and m.ran
    check m.expiryNotReadyReason == ""
    check passes() == 1
    check must(f.pool, "config", "--get", "gc.pruneExpire") == PoolPruneExpire

    # An enabled window survives later refreshes, again without a pass: the
    # hook discovers borrowers itself on every gc.
    removeFile(log)
    check prepareSharedBare(counting, f.pool) == ""
    check refreshSharedBare(counting, f.cache, url).ok
    check passes() == 0
    check must(f.pool, "config", "--get", "gc.pruneExpire") == PoolPruneExpire

    # ... but not the loss of its cheap preconditions: an emptied registry
    # goes back to ``never`` on the next refresh, still without a pass.
    writeFile(borrowersPath(f.pool), "")
    check prepareSharedBare(counting, f.pool) == ""
    check passes() == 0
    check must(f.pool, "config", "--get", "gc.pruneExpire") == PoolNeverExpire

  test "refused_discovery_names_the_path_it_stopped_at":
    let root = createTempDir("repro-spi1-discovery-names-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root, siblingBorrower = true)
    writeFile(borrowersPath(f.pool), f.a & "\n")
    writeFile(f.b / ".git" / "config", "[broken\n")
    let hook = execCmdEx("sh " & q(retentionHookPath(f.pool)) & " --discover")
    checkpoint(hook.output)
    check hook.exitCode == 1
    check ("retain-borrowed.sh: cannot vouch for " & f.b & ":") in hook.output
    let readiness = poolRetentionReadiness(f.gitBin, f.pool)
    checkpoint(readiness.reason)
    check not readiness.ready
    check ("cannot vouch for " & f.b & ":") in readiness.reason
    check '\n' notin readiness.reason
    # Maintenance carries the same reason, so a pool whose gc prunes nothing
    # says why.
    let m = maintainSharedBare(f.gitBin, f.pool, ["ws-a"], force = true)
    check ("cannot vouch for " & f.b & ":") in m.expiryNotReadyReason
    # A pass that only registered a checkout it had not seen is not a
    # refusal, and names no path.
    writeFile(f.b / ".git" / "config", "")
    let incomplete = execCmdEx("sh " & q(retentionHookPath(f.pool)) &
      " --discover")
    checkpoint(incomplete.output)
    check incomplete.exitCode == 2
    check "cannot vouch" notin incomplete.output
    let complete = poolRetentionReadiness(f.gitBin, f.pool)
    check complete.ready
    check complete.reason == ""

  test "migration_converges_past_a_sibling_it_was_not_told_about":
    # ``migrateSharedClones`` runs the one discovery pass per pool. A sibling
    # checkout that is neither a candidate nor registered makes that pass
    # incomplete; migration then makes the later complete pass itself, so
    # one run still leaves the pool with the window enabled.
    let root = createTempDir("repro-spi1-migrate-converges-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root, siblingBorrower = true)
    writeFile(borrowersPath(f.pool), f.a & "\n")
    discard must(f.pool, "config", "gc.pruneExpire", PoolNeverExpire)
    let migration = migrateSharedClones(f.gitBin, f.cache, [f.a])
    checkpoint($migration.diagnostics)
    check f.b in readBorrowers(f.pool)
    check must(f.pool, "config", "--get", "gc.pruneExpire") == PoolPruneExpire
    check migration.poolExpiryReasons.len == 0
    # A pool nothing borrows from says why it stays at ``never``.
    writeFile(borrowersPath(f.pool), "")
    removeDir(f.a)
    removeDir(f.b)
    let emptied = migrateSharedClones(f.gitBin, f.cache, [])
    check must(f.pool, "config", "--get", "gc.pruneExpire") == PoolNeverExpire
    check emptied.poolExpiryReasons.len == 1
    check "no checkout is registered" in emptied.poolExpiryReasons[0][1]

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

  test "discovery_walk_spawns_no_process_per_directory":
    # Every directory of every sibling workspace is visited on every gc, so
    # a subshell, command substitution or pipeline in the walk costs a fork
    # per directory. `discover_leaf` may still run git, but only where a
    # `.git` exists; the recursion itself must stay inside the one shell.
    const header = "\nscan_dir() {\n"
    let start = RetentionHookScript.find(header)
    doAssert start >= 0, "scan_dir not found in the hook"
    let stop = RetentionHookScript.find("\n}\n", start + 1)
    doAssert stop > start
    let body = RetentionHookScript[start + header.len ..< stop]
      .replace("$((", "").replace("))", "").replace("||", "")
    checkpoint(body)
    check '(' notin body
    check '`' notin body
    check '|' notin body
    check "(scan_dir" notin RetentionHookScript
    check "scan_dir \"$workspace\" 2 || exit 1" in RetentionHookScript

  test "discovery_restores_depth_after_each_recursive_call":
    let root = createTempDir("repro-spi1-discovery-depth-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root, siblingBorrower = true)
    let url = "file://" & f.up
    # `a` sorts before `z` and is walked to the depth limit first. If its
    # recursion leaked its directory or depth into the caller, `z` would be
    # scanned with the exhausted depth and `z/q`, two levels down, missed.
    let edge = root / "ws-d" / "a" / "x"
    let beyond = edge / "y" / "deep"
    let later = root / "ws-d" / "z" / "q"
    for leaf in [edge, beyond, later]:
      createDir(leaf.parentDir)
      discard must(root, "clone", "-q", "--reference", f.pool, url, leaf)
    writeFile(borrowersPath(f.pool), f.a & "\n")
    let hook = execCmdEx("sh " & q(retentionHookPath(f.pool)) & " --discover")
    checkpoint(hook.output)
    check hook.exitCode == 2
    let found = readBorrowers(f.pool)
    check f.b in found
    check edge in found
    check later in found
    # Three directories below the workspace is outside the declared domain.
    check beyond notin found

  test "mutation_scan_dir_shared_variables_miss_later_sibling":
    # The same walk without a subshell, keeping its directory and depth in
    # shell globals: the recursion into `a` leaves depth exhausted for `z`.
    let root = createTempDir("repro-spi1-discovery-depth-mut-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root, siblingBorrower = true)
    let url = "file://" & f.up
    let edge = root / "ws-d" / "a" / "x"
    let later = root / "ws-d" / "z" / "q"
    for leaf in [edge, later]:
      createDir(leaf.parentDir)
      discard must(root, "clone", "-q", "--reference", f.pool, url, leaf)
    writeFile(borrowersPath(f.pool), f.a & "\n")
    var script = readFile(retentionHookPath(f.pool))
    for (fromText, toText) in [
        ("  [ -r \"$1\" ] && [ -x \"$1\" ] || return 1\n",
         "  directory=$1\n  depth=$2\n" &
         "  [ -r \"$directory\" ] && [ -x \"$directory\" ] || return 1\n"),
        ("discover_leaf \"$1\" || return 1", "discover_leaf \"$directory\" || return 1"),
        ("[ \"$2\" -gt 0 ]", "[ \"$depth\" -gt 0 ]"),
        ("\"$1\"/* \"$1\"/.[!.]* \"$1\"/..?*",
         "\"$directory\"/* \"$directory\"/.[!.]* \"$directory\"/..?*"),
        ("\"$(($2 - 1))\"", "\"$((depth - 1))\"")]:
      doAssert script.count(fromText) == 1, "mutation anchor not found: " & fromText
      script = script.replace(fromText, toText)
    writeFile(retentionHookPath(f.pool), script)
    let hook = execCmdEx("sh " & q(retentionHookPath(f.pool)) & " --discover")
    checkpoint(hook.output)
    let found = readBorrowers(f.pool)
    check edge in found
    check later notin found

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

  test "staged_blob_only_expired_history_reaches_survives_gc":
    # A blob the pool holds only through history nobody names any more,
    # staged in the registered leaf (``git checkout <old> -- <path>``). The
    # index is a root (§3.3): after gc the leaf can still commit it.
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi1-staged-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      let blob = stageExpiredBlob(f, f.a)
      let gc = gitIn(f.pool, "gc", "--quiet")
      checkpoint("gc: " & $gc.code & " " & gc.output)
      check gc.code == 0
      check not has(f.pool, f.bFeat)      # expiry really ran
      check has(f.pool, blob)
      let commit = gitIn(f.a, "commit", "-q", "-m", "staged")
      checkpoint("commit: " & commit.output)
      check commit.code == 0

  test "staged_blob_in_removed_linked_worktree_survives_gc":
    # The same blob staged in a linked worktree whose directory is gone: its
    # index is read through its git directory, ``worktrees/<id>``.
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi1-staged-wt-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      let wt = root / "elsewhere" / "wt"
      createDir(wt.parentDir)
      discard must(f.a, "worktree", "add", "-q", "--detach", wt, "HEAD")
      let blob = stageExpiredBlob(f, wt)
      removeDir(wt)
      let gc = gitIn(f.pool, "gc", "--quiet")
      checkpoint("gc: " & $gc.code & " " & gc.output)
      check gc.code == 0
      check not has(f.pool, f.bFeat)
      check has(f.pool, blob)

  test "mutation_hook_without_index_loses_staged_blob":
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi1-staged-mut-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      let blob = stageExpiredBlob(f, f.a)
      mutateHook(f.pool, "  # Index entries", "  grep -E ")
      discard must(f.pool, "gc", "--quiet")
      check not has(f.pool, blob)

  test "mutation_hook_without_worktree_indexes_loses_staged_blob":
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi1-staged-wt-mut-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      let wt = root / "elsewhere" / "wt"
      createDir(wt.parentDir)
      discard must(f.a, "worktree", "add", "-q", "--detach", wt, "HEAD")
      let blob = stageExpiredBlob(f, wt)
      removeDir(wt)
      let hook = retentionHookPath(f.pool)
      let script = readFile(hook)
      let anchor = " \"$common\"/worktrees/*; do"
      doAssert script.count(anchor) == 1, "mutation anchor not found in the hook"
      writeFile(hook, script.replace(anchor, "; do"))
      discard must(f.pool, "gc", "--quiet")
      check not has(f.pool, blob)

  test "mutation_unreadable_index_skipped_prunes":
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi1-index-unreadable-mut-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      writeFile(f.a / ".git" / "index", "not an index\n")
      let hook = retentionHookPath(f.pool)
      let script = readFile(hook)
      let anchor = "|| { indexes=1; break; }"
      doAssert script.count(anchor) == 1, "mutation anchor not found in the hook"
      writeFile(hook, script.replace(anchor, "|| continue"))
      discard must(f.pool, "gc", "--quiet")
      check not has(f.pool, f.bFeat)      # the corrupt index was ignored

  test "unreadable_index_aborts_pruning":
    # An index file that exists but cannot be read (here: corrupt, which
    # also stands in for a permission refusal, unenforceable as root) may
    # stage anything, so the hook refuses rather than treat it as empty.
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi1-index-unreadable-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      writeFile(f.a / ".git" / "index", "not an index\n")
      doAssert gitIn(f.a, "ls-files", "--stage").code != 0
      let gc = gitIn(f.pool, "gc", "--quiet")
      checkpoint("gc: " & $gc.code & " " & gc.output)
      check gc.code != 0
      check has(f.pool, f.bFeat)          # refused: nothing pruned

  test "resolved_conflict_stage_survives_gc":
    # A conflict resolved with ``git add`` and abandoned with ``git merge
    # --quit`` leaves its conflicted stages in the index's resolve-undo
    # record, which ``git checkout -m <path>`` reads to recreate the
    # conflict. Those stages are roots (§3.3): after gc the leaf can still
    # recreate it. Issue 2026-11-17-retention-hook-drops-resolve-undo-and-
    # cache-tree-and-expands-worktree-sparse-indexes.
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi1-resolve-undo-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      let blob = resolveConflictWithExpiredStage(f)
      let gc = gitIn(f.pool, "gc", "--quiet")
      checkpoint("gc: " & $gc.code & " " & gc.output)
      check gc.code == 0
      check not has(f.pool, f.bFeat)      # expiry really ran
      check has(f.pool, blob)
      let redo = gitIn(f.a, "checkout", "-m", "feat3.txt")
      checkpoint("checkout -m: " & redo.output)
      check redo.code == 0
      check readFile(f.a / "feat3.txt").contains("feat3")

  test "mutation_hook_without_resolve_undo_loses_conflict_stage":
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi1-resolve-undo-mut-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      let blob = resolveConflictWithExpiredStage(f)
      let hook = retentionHookPath(f.pool)
      let script = readFile(hook)
      let anchor = " --resolve-undo"
      doAssert script.count(anchor) == 1, "mutation anchor not found in the hook"
      writeFile(hook, script.replace(anchor, ""))
      discard must(f.pool, "gc", "--quiet")
      check not has(f.pool, blob)
      check gitIn(f.a, "checkout", "-m", "feat3.txt").code != 0

  test "sparse_linked_worktree_of_a_full_leaf_is_read_without_expansion":
    # A linked worktree's sparse index is read under that worktree's own
    # configuration, and outside any work tree, so it is not expanded
    # (§3.3): the hook prints the tree its sparse entry names, and opens no
    # object to do so. Read under the non-sparse leaf's configuration, git
    # expanded it: the hook printed the blobs under ``deep/`` instead of the
    # tree, and expanding rebuilt the cache-tree, which refreshed the pool's
    # copy of the tree as a side effect. Issue 2026-11-17-retention-hook-drops-
    # resolve-undo-and-cache-tree-and-expands-worktree-sparse-indexes.
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi1-sparse-wt-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      let wt = root / "outside" / "other" / "deep" / "wt"
      let tree = sparseWorktreeOverExpiredTree(f, wt)
      let aged = getLastModificationTime(looseObjectPath(f.pool, tree))
      let hook = runRetentionHook(f)
      checkpoint("hook: " & $hook.code & " " & hook.stderr)
      check hook.code == 0
      check tree in hook.ids
      check getLastModificationTime(looseObjectPath(f.pool, tree)) == aged
      for pass in 1 .. 2:
        let gc = gitIn(f.pool, "gc", "--quiet")
        checkpoint("gc " & $pass & ": " & $gc.code & " " & gc.output)
        check gc.code == 0
      check not has(f.pool, f.bFeat)      # expiry really ran
      check wt notin readBorrowers(f.pool)
      check has(f.pool, tree)
      check gitIn(wt, "sparse-checkout", "disable").code == 0
      check readFile(wt / "deep" / "inner.txt") == "inner\n"

  test "mutation_hook_reading_indexes_under_the_leaf_config_expands_them":
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi1-sparse-wt-mut-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      let wt = root / "outside" / "other" / "deep" / "wt"
      let tree = sparseWorktreeOverExpiredTree(f, wt)
      let script = readFile(retentionHookPath(f.pool))
      # The read as it was: the index by path, under the leaf's configuration.
      let anchor = "git -C \"$work/empty\" --git-dir=\"$gitdir\" --work-tree=\"$work/empty\""
      doAssert script.count(anchor) == 1, "mutation anchor not found in the hook"
      # The worktree's cache-tree names the same tree; drop it too, so what
      # this case observes is the ``ls-files`` read alone.
      let trees = "    cat \"$work/trees\" >> \"$work/names\"\n"
      doAssert script.count(trees) == 1, "mutation anchor not found in the hook"
      writeFile(retentionHookPath(f.pool), script.replace(anchor,
        "GIT_INDEX_FILE=\"$gitdir/index\" git -C \"$leaf\"").replace(trees, ""))
      let aged = getLastModificationTime(looseObjectPath(f.pool, tree))
      let hook = runRetentionHook(f)
      check tree notin hook.ids
      check getLastModificationTime(looseObjectPath(f.pool, tree)) != aged

  test "cache_tree_subtree_under_a_kept_root_survives_gc":
    # A's cache-tree root lives only in A and names a subtree only expired
    # pool history reaches. Git reuses a cache-tree root it finds without
    # looking below it, so after a gc that pruned the subtree, A's next
    # commit exited 0 and recorded a tree with a missing subtree. The hook
    # prints every valid cache-tree node (§3.3), and walks the history
    # behind the ones the pool lacks, so the subtree is kept.
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi1-cache-tree-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      let ct = cacheTreeOverExpiredSubtree(f, invalidateRoot = false)
      let hook = runRetentionHook(f)
      checkpoint("hook: " & $hook.code & " " & hook.stderr)
      check hook.code == 0
      check ct.root in hook.ids and ct.outer in hook.ids
      let gc = gitIn(f.pool, "gc", "--quiet")
      checkpoint("gc: " & $gc.code & " " & gc.output)
      check gc.code == 0
      check not has(f.pool, f.bFeat)      # expiry really ran
      check has(f.pool, ct.deep)
      let commit = gitIn(f.a, "commit", "-q", "-m", "over the cache-tree")
      checkpoint("commit: " & commit.output)
      check commit.code == 0
      check must(f.a, "rev-parse", "HEAD^{tree}") == ct.root
      let fsck = gitIn(f.a, "fsck", "--connectivity-only")
      checkpoint("A fsck: " & fsck.output)
      check fsck.code == 0

  test "cache_tree_subtree_under_an_invalidated_root_survives_gc":
    # The same, with the root invalidated by a later ``git add``: git
    # rebuilds the root but reuses the valid ``outer/`` it finds, again
    # without looking below it. Printing only the root would print nothing.
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi1-cache-tree-inv-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      let ct = cacheTreeOverExpiredSubtree(f, invalidateRoot = true)
      let hook = runRetentionHook(f)
      checkpoint("hook: " & $hook.code & " " & hook.stderr)
      check hook.code == 0
      check ct.root notin hook.ids        # invalid: no id to print
      check ct.outer in hook.ids
      let gc = gitIn(f.pool, "gc", "--quiet")
      checkpoint("gc: " & $gc.code & " " & gc.output)
      check gc.code == 0
      check not has(f.pool, f.bFeat)
      check has(f.pool, ct.deep)
      let commit = gitIn(f.a, "commit", "-q", "-m", "over the cache-tree")
      checkpoint("commit: " & commit.output)
      check commit.code == 0
      check must(f.a, "rev-parse", "HEAD:outer") == ct.outer
      let fsck = gitIn(f.a, "fsck", "--connectivity-only")
      checkpoint("A fsck: " & fsck.output)
      check fsck.code == 0

  test "mutation_hook_without_cache_tree_commits_a_missing_subtree":
    # The hook without the cache-tree trees: gc prunes ``outer/deep/``, and
    # A's next commit exits 0 over a tree that is gone. Only fsck notices.
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi1-cache-tree-mut-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      let ct = cacheTreeOverExpiredSubtree(f, invalidateRoot = false)
      let hook = retentionHookPath(f.pool)
      let script = readFile(hook)
      let anchor = "    cat \"$work/trees\" >> \"$work/names\"\n"
      doAssert script.count(anchor) == 1, "mutation anchor not found in the hook"
      writeFile(hook, script.replace(anchor, ""))
      let gc = gitIn(f.pool, "gc", "--quiet")
      checkpoint("gc: " & $gc.code & " " & gc.output)
      check gc.code == 0
      check not has(f.pool, ct.deep)
      check gitIn(f.a, "commit", "-q", "-m", "over the cache-tree").code == 0
      let fsck = gitIn(f.a, "fsck", "--connectivity-only")
      checkpoint("A fsck: " & fsck.output)
      check fsck.code != 0
      check ct.deep in fsck.output

  test "cache_tree_nodes_are_read_from_every_index_layout":
    # The hook walks the index file itself, so each layout git writes is a
    # different byte stream: version 3 with extended flags, version 4 with
    # prefix-compressed names, a split index (the cache-tree is in the front
    # file, behind a ``link`` extension), and the end-of-index-entries
    # extension (EOIE), which follows the cache-tree. Each must yield the same
    # valid nodes, and none may make the hook refuse.
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi1-cache-tree-layouts-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      let ct = cacheTreeOverExpiredSubtree(f, invalidateRoot = false)
      # Extended flags: skip-worktree on a file outside ``outer/``.
      let other = must(f.a, "ls-files").splitLines()[0]
      doAssert not other.startsWith("outer/")
      discard must(f.a, "update-index", "--skip-worktree", other)
      for layout in [@["update-index", "--index-version", "3"],
                     @["update-index", "--index-version", "4"],
                     @["-c", "index.recordEndOfIndexEntries=true",
                       "-c", "index.recordOffsetTable=true",
                       "-c", "index.threads=2",
                       "update-index", "--force-write-index"],
                     @["update-index", "--split-index"]]:
        # Refresh the cache-tree first: a later write-tree may rewrite the
        # index without the layout's ``-c`` settings.
        doAssert must(f.a, "write-tree") == ct.root
        discard must(f.a, layout)
        checkpoint("layout: " & layout.join(" "))
        if "--index-version" in layout:
          doAssert ord(readFile(f.a / ".git" / "index")[7]) == parseInt(layout[^1])
        if "index.recordEndOfIndexEntries=true" in layout:
          doAssert "EOIE" in readFile(f.a / ".git" / "index")
        let hook = runRetentionHook(f)
        checkpoint("hook: " & $hook.code & " " & hook.stderr)
        check hook.code == 0
        check ct.root in hook.ids and ct.outer in hook.ids
      check fileExists(f.a / ".git" / "index")
      var shared = false
      for kind, path in walkDir(f.a / ".git"):
        if path.extractFilename.startsWith("sharedindex."): shared = true
      check shared                        # the split really happened

  test "corrupt_cache_tree_extension_aborts_pruning":
    # An index whose extensions do not end where its checksum begins may
    # name anything: the hook refuses rather than print part of it. Git
    # skips the checksum of an index written with ``index.skipHash``, so
    # ``ls-files`` still reads this one.
    if findExe("git").len == 0 or not gitAtLeast(2, 42):
      skip("needs git on PATH, version 2.42 or newer (gc.recentObjectsHook)")
    else:
      let root = createTempDir("repro-spi1-cache-tree-corrupt-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      discard must(f.a, "-c", "index.skipHash=true", "update-index",
        "--force-write-index")
      discard must(f.a, "-c", "index.skipHash=true", "write-tree")
      let index = f.a / ".git" / "index"
      var bytes = readFile(index)
      let at = bytes.find("TREE")
      doAssert at > 0, "the index must carry a cache-tree"
      # Grow the TREE extension's size by one byte past the checksum.
      bytes[at + 7] = char(ord(bytes[at + 7]) + 1)
      writeFile(index, bytes)
      doAssert gitIn(f.a, "ls-files", "--stage").code == 0
      let gc = gitIn(f.pool, "gc", "--quiet")
      checkpoint("gc: " & $gc.code & " " & gc.output)
      check gc.code != 0
      check has(f.pool, f.bFeat)          # refused: nothing pruned

  test "reftable_leaf_refuses_expiry_and_gc":
    # A leaf on the reftable ref backend keeps HEAD and its reflogs in
    # reftable stacks the hook cannot read as files (§3.3). Its detached
    # HEAD names a pool-only commit no ref reaches; the pool must keep
    # ``never`` and a gc must refuse rather than expire that commit.
    if findExe("git").len == 0 or not gitAtLeast(2, 45):
      skip("needs git on PATH, version 2.45 or newer (--ref-format=reftable)")
    else:
      let root = createTempDir("repro-spi1-reftable-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      let r = reftableLeaf(f)
      check not poolRetentionReady(f.gitBin, f.pool)
      # The pass that maintenance runs before a gc takes the window away.
      var why = ""
      check ensureSharedBareSafety(f.gitBin, f.pool, readinessPass = true, why)
      check ("cannot vouch for " & r & ":") in why
      check must(f.pool, "config", "--get", "gc.pruneExpire") ==
        PoolNeverExpire
      discard must(f.pool, "config", "gc.pruneExpire", PoolPruneExpire)
      let gc = gitIn(f.pool, "gc", "--quiet")
      checkpoint("gc: " & $gc.code & " " & gc.output)
      check gc.code != 0
      check has(f.pool, f.bFeat)
      check gitIn(r, "fsck", "--connectivity-only").code == 0

  test "mutation_reftable_leaf_accepted_loses_detached_head":
    if findExe("git").len == 0 or not gitAtLeast(2, 45):
      skip("needs git on PATH, version 2.45 or newer (--ref-format=reftable)")
    else:
      let root = createTempDir("repro-spi1-reftable-mut-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      discard reftableLeaf(f)
      let hook = retentionHookPath(f.pool)
      let script = readFile(hook)
      let anchor = "\n  ref_storage_files \"$common\" || { status=1; continue; }"
      doAssert script.count(anchor) == 1, "mutation anchor not found in the hook"
      writeFile(hook, script.replace(anchor, ""))
      discard must(f.pool, "config", "gc.pruneExpire", PoolPruneExpire)
      discard must(f.pool, "gc", "--quiet")
      check not has(f.pool, f.bFeat)      # the reftable HEAD protected nothing

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
      let refuse = "--git-common-dir 2>/dev/null) || { status=1; continue; }\n"
      doAssert script.count(refuse) == 1, "mutation anchor not found in the hook"
      let discoveryRefusal = "--git-common-dir 2>/dev/null) || return 1"
      doAssert script.contains(discoveryRefusal)
      writeFile(hook, script.replace(refuse,
        "--git-common-dir 2>/dev/null) || continue\n").replace(
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
      # A refresh alone never enables the window (it runs no discovery).
      check prepareSharedBare(gitBin, pool) == ""
      check must(pool, "config", "--get", "gc.pruneExpire") == PoolNeverExpire
      check ensureSharedBareSafety(gitBin, pool, readinessPass = true)
      check must(pool, "config", "--get", "gc.pruneExpire") == PoolPruneExpire
      # ... and a later refresh leaves an enabled window in place.
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

  test "concurrent_engine_recordings_keep_every_engine":
    # ``<pool>/repro/engines`` (§3.4) is rewritten whole by each recording.
    # Repro processes that wire or check leaves of one pool at the same time
    # (two workspaces syncing, a sweep over another workspace's borrowers)
    # must each leave their engine in it: a recording that read the list
    # before another process wrote it must not drop that process's entry.
    # One round of simultaneous recorders does not always interleave, so the
    # case runs several rounds; any lost entry fails it. Only the pool's
    # ``repro`` directory is involved, so no git fixture is needed.
    let root = createTempDir("repro-spi1-engines-race-", "")
    defer: removeDir(root)
    let pool = root / "cache" / "up.git"
    createDir(poolReproDir(pool))
    var engines: seq[string]
    for i in 0 ..< MaxRecordedEngines:
      let engine = root / "engines" / ("engine " & $i)
      createDir(engine.parentDir)
      writeFile(engine, "")
      engines.add(engine)
    var lost = 0
    for round in 1 .. 12:
      writeFile(poolEnginesPath(pool), "")
      let start = root / ("start-" & $round)
      var children: seq[Process]
      for engine in engines:
        children.add(startProcess(getAppFilename(), args = @[
          "record-engine-child", pool, engine, start],
          options = {poParentStreams}))
      sleep(200)
      writeFile(start, "")
      for child in children:
        check child.waitForExit() == 0
        child.close()
      var recorded: seq[string]
      for line in readFile(poolEnginesPath(pool)).splitLines():
        if line.len > 0: recorded.add(line)
      for engine in engines:
        if engine notin recorded:
          checkpoint("round " & $round & " lost " & engine & "; list: " &
            recorded.join(", "))
          inc lost
      check recorded.len == engines.len
    check lost == 0

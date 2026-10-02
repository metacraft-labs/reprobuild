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
## way a checkout reprobuild never touched would be. Upstream then deletes
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
## Skip rule: ``git`` missing on PATH, or older than 2.42 (the hook needs it).

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

proc setUp(root: string): Fixture =
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
  result.a = root / "ws-a" / "up"
  result.b = root / "ws-b" / "up"
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

suite "SPI-1: the pool retains what registered leaves name":

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
      writeFile(hook, script.replace(refuse, "|| continue\n  : > "))
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
      let leaf = root / "leaf"
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

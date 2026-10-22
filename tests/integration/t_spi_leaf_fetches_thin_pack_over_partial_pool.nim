## A checkout that borrows from a partial-clone pool, and carries no promisor
## remote of its own, still fetches its upstream.
##
## Spec: ``reprobuild-specs/spec/Shared-Clone-Pool-Integrity.md`` §3.7 (a
## fetch in a leaf that has no promisor remote), with §3.4 (the refetch chain)
## and ``spec/CLI/workspace.md`` "Foreign-pool consolidation".
## Issue: ``reprobuild-pm/issues/2026-10-22-workspace-checkouts-borrowing-a-
## partial-clone-cache-fail-to-fetch-thin-packs.md``.
##
## The failure. A leaf "has" every commit its alternates reach. When the pool
## behind the alternate is a ``blob:none`` partial clone, the blobs of those
## commits are only promised. Upstream answers the leaf's fetch with a thin
## pack whose delta base is such a blob, and a leaf without a promisor remote
## dies in ``index-pack`` with "unresolved deltas left after unpacking". The
## §3.4 chain heals it, but only a leaf the detector has configured carries
## the chain: a leaf of a foreign cache never does, and a leaf of an owned
## pool lacks it until something runs the detector on it.
##
## The fixture reproduces it deterministically: the pool fetches commit two
## (big file's new blob omitted), upstream then commits three on the same big
## file, and the leaf fetches. Upstream allows filters and any-SHA1 wants, as
## GitHub effectively does (§3.4), so a lazy fetch of the base by id works.
##
## Cases:
##
##   - ``foreign_pool_leaf_fetch_succeeds_where_plain_fetch_fails`` — a pool
##     outside any reprobuild cache root, two identical leaves. A plain
##     ``git fetch origin`` in one FAILS with unresolved deltas (positive
##     control: the fixture reproduces the issue); reprobuild's fetch action
##     in the other succeeds, lands the new tip in ``refs/remotes/origin/main``
##     with its blob present, writes nothing into the leaf's config (marking
##     ``origin`` itself a promisor would leave
##     ``remote.origin.partialclonefilter=blob:none`` behind) and leaves
##     the pool's config, refs and packs as they were.
##   - ``owned_pool_leaf_without_chain_fetch_succeeds`` — the same with the
##     pool at its ``sharedBarePath`` under a cache root, prepared by
##     ``prepareSharedBare``, and the leaf never configured by the detector.
##   - ``leaf_fetch_needs_promisor_decision`` — ``leafFetchNeedsPromisor`` is
##     false for no alternates, for a full pool, and for a partial pool whose
##     leaf carries the chain; true for a partial pool without one, including
##     a pool whose only remaining partial-clone signal is a ``*.promisor``
##     pack file.
##
## No mocks: real ``git``, real repositories, and the real fetch action driven
## through the build engine (``runBuild``), as ``repro`` runs it. Hermetic: one
## ``createTempDir`` root per case, a private ``GIT_CONFIG_GLOBAL``,
## ``file://`` URLs throughout (a plain path would make git hardlink instead of
## borrow). Every presence probe runs with ``GIT_NO_LAZY_FETCH=1`` so it cannot
## heal what it checks. Skip rule: ``git`` missing on PATH.

import std/[algorithm, os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import git_actions
import git_tool
import repro_build_engine
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

proc has(repo, id: string): bool =
  gitIn(repo, "cat-file", "-e", id).code == 0

const GlobalConfig = """
[user]
  name = SPI Tester
  email = tester@example.invalid
[init]
  defaultBranch = main
"""

proc bigFile(extra: string): string =
  ## Large enough that git deltas the next version against this one.
  for i in 1 .. 20000:
    result.add("line " & $i & " " & $(i * 7919 mod 104729) & "\n")
  result.add(extra)

proc commitBig(up, body, message: string) =
  writeFile(up / "big.txt", body)
  discard must(up, "add", "big.txt")
  discard must(up, "commit", "-q", "-m", message)

type Fixture = object
  root, up, url, pool, gitBin: string
  leaves: seq[string]

proc cloneLeaf(f: Fixture; name: string): string =
  ## A leaf as a legacy tool leaves it: ``--reference`` the pool, so its
  ## alternates point there, and NO promisor remote of its own.
  result = f.root / "ws" / name
  createDir(result.parentDir)
  discard must(f.root, "clone", "-q", "--no-local", "--no-checkout",
    "--reference", f.pool, f.url, result)
  doAssert gitIn(result, "config", "--get-regexp", "promisor").code != 0

proc setUp(root, pool: string; owned: bool; leafCount: int): Fixture =
  ## Upstream at commit one; a ``blob:none`` pool at ``pool``; ``leafCount``
  ## leaves cloned from it; then the pool fetches commit two and upstream
  ## moves on to commit three, all three rewriting ``big.txt``.
  result.root = root
  result.gitBin = findExe("git")
  result.up = root / "up"
  result.url = "file://" & result.up
  result.pool = pool
  writeFile(root / "gitconfig", GlobalConfig)
  putEnv("GIT_CONFIG_GLOBAL", root / "gitconfig")
  putEnv("GIT_CONFIG_NOSYSTEM", "1")
  createDir(result.up)
  discard must(result.up, "init", "-q")
  discard must(result.up, "config", "uploadpack.allowFilter", "true")
  discard must(result.up, "config", "uploadpack.allowAnySHA1InWant", "true")
  commitBig(result.up, bigFile(""), "one")
  createDir(pool.parentDir)
  discard must(root, "clone", "-q", "--bare", "--no-local",
    "--filter=blob:none", result.url, pool)
  if owned:
    # What reprobuild installs on a pool it owns: the refspec and the
    # borrower-safety config.
    let prepared = prepareSharedBare(result.gitBin, pool)
    doAssert prepared.len == 0, prepared
  else:
    discard must(pool, "config", "remote.origin.fetch",
      "+refs/heads/*:refs/heads/*")
  for i in 1 .. leafCount:
    result.leaves.add(cloneLeaf(result, "leaf" & $i))
  commitBig(result.up, bigFile("extra\n"), "two")
  discard must(pool, "fetch", "-q", "origin")
  let two = must(result.up, "rev-parse", "HEAD")
  # Premise: the pool names commit two but only promises its big blob.
  doAssert has(pool, two)
  doAssert not has(pool, must(result.up, "rev-parse", "HEAD:big.txt"))
  commitBig(result.up, bigFile("extra\nmore\n"), "three")

proc tearDown() =
  delEnv("GIT_CONFIG_GLOBAL")
  delEnv("GIT_CONFIG_NOSYSTEM")

proc poolState(pool: string): string =
  ## Config, refs and pack names: what a fetch through the pool would change.
  result = readFile(pool / "config") & "\n--refs--\n" &
    must(pool, "for-each-ref") & "\n--packs--\n"
  var packs: seq[string]
  for kind, f in walkDir(pool / "objects" / "pack"):
    packs.add(f.lastPathPart)
  packs.sort()
  result.add(packs.join("\n"))

proc fetchThroughEngine(f: Fixture; leaf: string): BuildRunResult =
  ## Run reprobuild's fetch action on ``leaf`` the way ``repro`` does.
  let identity = ensureGitToolResolvable(tpmPathOnly, f.gitBin.parentDir)
  let work = f.root / "fetch-work-" & leaf.lastPathPart
  createDir(work)
  var act = gitFetchAction("spi-thin-fetch", identity, remoteName = "origin",
    repoPath = leaf, receiptPath = "fetch-receipt")
  act.cwd = work
  var config = defaultBuildEngineConfig(f.root / "engine-cache-" &
    leaf.lastPathPart)
  config.suppressTrace = true
  runBuild(graph([act]), config)

proc checkFetchHealed(f: Fixture; leaf: string) =
  let configBefore = readFile(leaf / ".git" / "config")
  let poolBefore = poolState(f.pool)
  check leafFetchNeedsPromisor(f.gitBin, leaf)
  let res = fetchThroughEngine(f, leaf)
  check res.results.len == 1
  if res.results.len == 1:
    if res.results[0].status != asSucceeded:
      checkpoint("fetch action stderr: " & res.results[0].stderr)
    check res.results[0].status == asSucceeded
  let three = must(f.up, "rev-parse", "HEAD")
  check gitIn(leaf, "rev-parse", "refs/remotes/origin/main").output == three
  check has(leaf, must(f.up, "rev-parse", "HEAD:big.txt"))
  # The promisor setting was per invocation: nothing persistent was written.
  check gitIn(leaf, "config", "--get-regexp", "promisor").code != 0
  check readFile(leaf / ".git" / "config") == configBefore
  # The missing base came from the remote being fetched, not via the pool.
  check poolState(f.pool) == poolBefore

suite "SPI: leaves of a partial-clone pool fetch thin packs":

  test "foreign_pool_leaf_fetch_succeeds_where_plain_fetch_fails":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi-thin-foreign-", "")
      defer:
        tearDown()
        removeDir(root)
      # Outside any reprobuild cache root, like the observed
      # ``~/.cache/repo-workspaces/clones/...`` pool.
      let f = setUp(root, root / "repo-workspaces" / "clones" / "up.git",
        owned = false, leafCount = 2)
      # Positive control: the fixture reproduces the issue with plain git.
      let plain = gitIn(f.leaves[0], "fetch", "origin")
      checkpoint("plain fetch: " & plain.output)
      check plain.code != 0
      check plain.output.contains("unresolved deltas")
      checkFetchHealed(f, f.leaves[1])

  test "owned_pool_leaf_without_chain_fetch_succeeds":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi-thin-owned-", "")
      defer:
        tearDown()
        removeDir(root)
      let cacheRoot = root / "cache"
      let f = setUp(root, sharedBarePath(cacheRoot, "file://" & root / "up"),
        owned = true, leafCount = 1)
      check f.pool in poolsOfLeaf(f.leaves[0], cacheRoot)
      checkFetchHealed(f, f.leaves[0])

  test "leaf_fetch_needs_promisor_decision":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi-thin-decide-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root, root / "pools" / "partial.git", owned = false,
        leafCount = 2)
      let git = f.gitBin
      # No alternates at all.
      let alone = root / "ws" / "alone"
      discard must(root, "clone", "-q", "--no-local", "--no-checkout", f.url,
        alone)
      check readAlternates(alone).len == 0
      check not leafFetchNeedsPromisor(git, alone)
      # A full (non-partial) pool.
      let full = root / "pools" / "full.git"
      discard must(root, "clone", "-q", "--bare", "--no-local", f.url, full)
      check not repoIsPartialClone(git, full)
      let fullLeaf = root / "ws" / "full-leaf"
      discard must(root, "clone", "-q", "--no-local", "--no-checkout",
        "--reference", full, f.url, fullLeaf)
      check readAlternates(fullLeaf).len == 1
      check not leafFetchNeedsPromisor(git, fullLeaf)
      # A partial pool, leaf without a promisor remote.
      check repoIsPartialClone(git, f.pool)
      check leafFetchNeedsPromisor(git, f.leaves[0])
      # The same leaf once it carries the §3.4 chain.
      let configured = ensureLeafPoolConfig(git, f.leaves[0], f.pool)
      check configured.len == 0
      check not leafFetchNeedsPromisor(git, f.leaves[0])
      # A pool whose config no longer says it is partial still is: its
      # ``*.promisor`` packs mark promised objects.
      # (git 2.54 records a ``blob:none`` clone as ``remote.origin.promisor``
      # alone; an older git also wrote ``extensions.partialClone``.)
      discard gitIn(f.pool, "config", "--unset", "extensions.partialClone")
      discard must(f.pool, "config", "--unset", "remote.origin.promisor")
      check gitIn(f.pool, "config", "--get-regexp", "promisor").code != 0
      check gitIn(f.pool, "config", "--get", "extensions.partialClone").code != 0
      check repoIsPartialClone(git, f.pool)
      check leafFetchNeedsPromisor(git, f.leaves[1])

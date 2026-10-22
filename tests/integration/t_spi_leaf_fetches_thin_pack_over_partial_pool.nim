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
##   - ``nested_full_alternate_of_partial_pool_leaf_fetch_succeeds`` — the
##     leaf's alternate is a FULL bare clone (no filter, no promisor remote,
##     no promisor packs) whose own ``objects/info/alternates`` names the
##     ``blob:none`` pool. Git follows alternates transitively, so the leaf
##     advertises the pool's commits as haves just the same. Positive
##     control: a plain fetch in one leaf fails with unresolved deltas; the
##     engine's fetch in the other succeeds, as in the first case.
##   - ``nested_alternates_decision`` — ``borrowedObjectStores`` and
##     ``leafFetchNeedsPromisor`` over hand-built chains of bare stores: a
##     chain of full stores (with a relative entry, a comment line and a
##     missing directory) is false; the same chain with a partial store three
##     hops away is true; a cycle terminates, false while every store is full
##     and true once one on it is partial; git's nesting cap is honoured (a
##     partial store six hops away counts, seven hops away does not), and the
##     cap is cross-checked against the installed git by object visibility;
##     an unreadable alternates file contributes nothing (git ignores it
##     too), while another branch of the chain is still evaluated.
##   - ``pinned_clone_fetch_over_unregistrable_partial_pool_succeeds`` — the
##     clone action with a commit-SHA revision, ``--single-branch`` and a
##     ``referencePath`` to a ``blob:none`` pool the user cannot write. The
##     pinned commit sits on a side branch outside ``--single-branch``, one
##     commit past the pool on the same big file, so ``cat-file -e`` misses
##     and the follow-up ``fetch --no-tags origin <sha>`` runs. Registration
##     fails (no ``repro/`` can be created in the pool) and the dissociating
##     ``repack -a -d`` fails too (the clone names blobs the pool only
##     promises), so the clone keeps its alternates with no promisor remote:
##     exactly the state that fetch must survive. Positive control: the same
##     fetch with plain git in a plain ``--reference`` twin fails with
##     unresolved deltas.
##
## No mocks: real ``git``, real repositories, and the real fetch and clone
## actions driven through the build engine (``runBuild``), as ``repro`` runs
## them. Two fixture states are made by hand rather than by a tool, and both
## are real git or filesystem state, not stand-ins: the nested-decision
## chains are ``git init --bare`` stores whose alternates files the test
## writes (git reads them exactly as it reads ones ``clone --reference``
## writes; the object-visibility cross-check proves it), and the unwritable
## pool is a real ``chmod``-ed directory, standing in for a shared cache that
## another user owns. That case and the unreadable-alternates check skip when
## running as root (root ignores the permission bits) and on Windows (POSIX
## modes there do not deny creating a subdirectory). Hermetic: one
## ``createTempDir`` root per case, a private ``GIT_CONFIG_GLOBAL``,
## ``file://`` URLs throughout (a plain path would make git hardlink instead of
## borrow). Every presence probe runs with ``GIT_NO_LAZY_FETCH=1`` so it cannot
## heal what it checks. Skip rule: ``git`` missing on PATH.

import std/[algorithm, os, osproc, strutils, tempfiles, unittest]
when not defined(windows):
  from std/posix import geteuid
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

proc cloneLeaf(f: Fixture; reference, name: string): string =
  ## A leaf as a legacy tool leaves it: ``--reference`` the pool (or the
  ## relay in front of it), so its alternates point there, and NO promisor
  ## remote of its own.
  result = f.root / "ws" / name
  createDir(result.parentDir)
  discard must(f.root, "clone", "-q", "--no-local", "--no-checkout",
    "--reference", reference, f.url, result)
  doAssert gitIn(result, "config", "--get-regexp", "promisor").code != 0

proc setUp(root, pool: string; owned: bool; leafCount: int;
           relay = ""): Fixture =
  ## Upstream at commit one; a ``blob:none`` pool at ``pool``; ``leafCount``
  ## leaves cloned from it; then the pool fetches commit two and upstream
  ## moves on to commit three, all three rewriting ``big.txt``.
  ##
  ## With ``relay``, a FULL bare clone is made there at commit one with
  ## ``--reference`` to the pool, and the leaves reference the relay instead:
  ## they reach the pool only through the relay's own alternates.
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
  var reference = pool
  if relay.len > 0:
    createDir(relay.parentDir)
    discard must(root, "clone", "-q", "--bare", "--no-local", "--reference",
      pool, result.url, relay)
    reference = relay
  for i in 1 .. leafCount:
    result.leaves.add(cloneLeaf(result, reference, "leaf" & $i))
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

proc permissionsAreEnforced(): bool =
  ## Whether a mode bit can deny this process a write: not on Windows, and
  ## not for root.
  when defined(windows):
    false
  else:
    geteuid() != 0

proc bareStore(root, name: string): string =
  ## An empty bare repository: an object store with an owning git directory.
  result = root / "stores" / name
  createDir(result.parentDir)
  discard must(root, "init", "-q", "--bare", result)

proc linkStores(fromRepo: string; entries: varargs[string]) =
  ## Write ``fromRepo``'s ``objects/info/alternates`` as git reads it: one
  ## entry per line.
  createDir(fromRepo / "objects" / "info")
  writeFile(fromRepo / "objects" / "info" / "alternates",
    entries.join("\n") & "\n")

proc markPartial(repo: string) =
  ## The config signal of a partial clone: a promisor remote.
  discard must(repo, "config", "remote.origin.url", "file:///nowhere")
  discard must(repo, "config", "remote.origin.promisor", "true")

proc unmarkPartial(repo: string) =
  discard must(repo, "config", "--unset", "remote.origin.promisor")

proc storeBlob(repo, body: string): string =
  ## Write a blob into ``repo``'s own object store and return its id.
  let res = execCmdEx("git --git-dir=" & q(repo) & " hash-object -w --stdin",
    input = body)
  doAssert res.exitCode == 0, res.output
  res.output.strip()

proc cloneThroughEngine(f: Fixture; revision, reference: string;
                        singleBranch: bool): tuple[res: BuildRunResult;
                                                   clone: string] =
  ## Run reprobuild's clone action the way ``repro`` does.
  let identity = ensureGitToolResolvable(tpmPathOnly, f.gitBin.parentDir)
  let work = f.root / "clone-ws"
  createDir(work)
  let act = gitCloneAction("spi-thin-clone", identity, remoteUrl = f.url,
    repoPath = "clone", receiptPath = "clone-receipt", revision = revision,
    cwd = work, referencePath = reference, singleBranch = singleBranch)
  var config = defaultBuildEngineConfig(f.root / "engine-cache-clone")
  config.suppressTrace = true
  (res: runBuild(graph([act]), config), clone: work / "clone")

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

  test "nested_full_alternate_of_partial_pool_leaf_fetch_succeeds":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi-thin-nested-fetch-", "")
      defer:
        tearDown()
        removeDir(root)
      let relay = root / "relay" / "up.git"
      let f = setUp(root, root / "repo-workspaces" / "clones" / "up.git",
        owned = false, leafCount = 2, relay = relay)
      # Premise: the leaves borrow from a FULL repository, and reach the
      # partial pool only through that repository's own alternates.
      check not repoIsPartialClone(f.gitBin, relay)
      let relayAlternates = readAlternates(relay)
      check relayAlternates.len == 1
      if relayAlternates.len == 1:
        check samePathOnDisk(relayAlternates[0], f.pool / "objects")
      let direct = poolsOfLeaf(f.leaves[0])
      check direct.len == 1
      if direct.len == 1:
        check samePathOnDisk(direct[0], relay)
      check borrowedObjectStores(f.leaves[0]).len == 2
      # Positive control: the nested chain reproduces the issue too.
      let plain = gitIn(f.leaves[0], "fetch", "origin")
      checkpoint("plain fetch: " & plain.output)
      check plain.code != 0
      check plain.output.contains("unresolved deltas")
      let relayBefore = poolState(relay)
      checkFetchHealed(f, f.leaves[1])
      check poolState(relay) == relayBefore

  test "nested_alternates_decision":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi-thin-nested-decide-", "")
      defer:
        tearDown()
        removeDir(root)
      writeFile(root / "gitconfig", GlobalConfig)
      putEnv("GIT_CONFIG_GLOBAL", root / "gitconfig")
      putEnv("GIT_CONFIG_NOSYSTEM", "1")
      let git = findExe("git")
      let leaf = root / "ws" / "leaf"
      discard must(root, "init", "-q", leaf)
      var s: seq[string]
      for i in 1 .. 7:
        s.add(bareStore(root, "s" & $i & ".git"))
      proc objects(repo: string): string = expandFilename(repo / "objects")

      # A chain of full stores: leaf -> s1 -> s2 -> s3. s1's file carries a
      # comment, an entry for a directory that does not exist, and s2 as a
      # path relative to s1's object directory.
      linkStores(leaf / ".git", s[0] / "objects")
      linkStores(s[0], "# a comment, not a path",
        root / "stores" / "missing.git" / "objects", "../../s2.git/objects")
      linkStores(s[1], s[2] / "objects")
      check borrowedObjectStores(leaf) ==
        @[objects(s[0]), objects(s[1]), objects(s[2])]
      check not leafFetchNeedsPromisor(git, leaf)
      # The same chain with a partial store three hops away.
      markPartial(s[2])
      check leafFetchNeedsPromisor(git, leaf)
      unmarkPartial(s[2])
      check not leafFetchNeedsPromisor(git, leaf)

      # A cycle, s3 -> s1, terminates with each store listed once.
      linkStores(s[2], s[0] / "objects")
      check borrowedObjectStores(leaf) ==
        @[objects(s[0]), objects(s[1]), objects(s[2])]
      check not leafFetchNeedsPromisor(git, leaf)
      markPartial(s[1])
      check leafFetchNeedsPromisor(git, leaf)
      unmarkPartial(s[1])

      # Git's nesting cap: leaf -> s1 -> ... -> s7. Git reads six of them.
      for i in 0 .. 5:
        linkStores(s[i], s[i + 1] / "objects")
      linkStores(s[6])
      var six: seq[string]
      for i in 0 .. 5:
        six.add(objects(s[i]))
      check borrowedObjectStores(leaf) == six
      # Cross-check against the installed git: an object only in s6 is
      # visible from the leaf, one only in s7 is not.
      let inSix = storeBlob(s[5], "only in s6\n")
      let inSeven = storeBlob(s[6], "only in s7\n")
      check has(leaf, inSix)
      check not has(leaf, inSeven)
      markPartial(s[6])
      check not leafFetchNeedsPromisor(git, leaf)
      markPartial(s[5])
      check leafFetchNeedsPromisor(git, leaf)
      unmarkPartial(s[5])
      unmarkPartial(s[6])

      # An unreadable alternates file contributes nothing, as in git; another
      # branch of the chain is still evaluated.
      if permissionsAreEnforced():
        markPartial(s[1])
        check leafFetchNeedsPromisor(git, leaf)
        let inTwo = storeBlob(s[1], "only in s2\n")
        check has(leaf, inTwo)
        let alt = s[0] / "objects" / "info" / "alternates"
        let mode = getFilePermissions(alt)
        setFilePermissions(alt, {})
        defer: setFilePermissions(alt, mode)
        check not has(leaf, inTwo)
        check borrowedObjectStores(leaf) == @[objects(s[0])]
        check not leafFetchNeedsPromisor(git, leaf)
        let partial = bareStore(root, "partial.git")
        markPartial(partial)
        linkStores(leaf / ".git", s[0] / "objects", partial / "objects")
        check leafFetchNeedsPromisor(git, leaf)
      else:
        checkpoint("unreadable-alternates check not run: permission bits " &
          "are not enforced for this process")

  test "pinned_clone_fetch_over_unregistrable_partial_pool_succeeds":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    elif not permissionsAreEnforced():
      skip("needs POSIX permission bits enforced (not root, not Windows) " &
        "to make the pool unwritable")
    else:
      let root = createTempDir("repro-spi-thin-pinned-clone-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root, root / "repo-workspaces" / "clones" / "up.git",
        owned = false, leafCount = 0)
      # Move commit three onto a side branch and give main a commit four
      # without big.txt. The clone checks out main, so its tip must not need
      # a blob the pool only promises; and under --single-branch the clone
      # does not fetch ``side``, so commit three is absent and the pinned
      # fetch runs.
      let three = must(f.up, "rev-parse", "HEAD")
      discard must(f.up, "branch", "side", three)
      discard must(f.up, "reset", "-q", "--hard", "HEAD~1")
      discard must(f.up, "rm", "-q", "big.txt")
      writeFile(f.up / "readme.txt", "four\n")
      discard must(f.up, "add", "readme.txt")
      discard must(f.up, "commit", "-q", "-m", "four")
      let bigThree = must(f.up, "rev-parse", three & ":big.txt")
      let poolBefore = poolState(f.pool)
      # The pool is a cache this user cannot write, so registration cannot
      # create its ``repro/`` registry.
      let mode = getFilePermissions(f.pool)
      setFilePermissions(f.pool, {fpUserRead, fpUserExec, fpGroupRead,
        fpGroupExec, fpOthersRead, fpOthersExec})
      defer: setFilePermissions(f.pool, mode)

      # Positive control: in a plain ``--reference`` twin, the same fetch of
      # the pinned commit fails with unresolved deltas.
      let twin = root / "twin"
      discard must(root, "clone", "-q", "--no-local", "--single-branch",
        "--reference", f.pool, f.url, twin)
      check not has(twin, three)
      let plain = gitIn(twin, "fetch", "--no-tags", "origin", three)
      checkpoint("plain pinned fetch: " & plain.output)
      check plain.code != 0
      check plain.output.contains("unresolved deltas")

      let (res, clone) = cloneThroughEngine(f, three, f.pool,
        singleBranch = true)
      check res.results.len == 1
      if res.results.len == 1:
        if res.results[0].status != asSucceeded:
          checkpoint("clone action: " & res.results[0].reason & ": " &
            res.results[0].stderr)
        check res.results[0].status == asSucceeded
      check gitIn(clone, "rev-parse", "HEAD").output == three
      check has(clone, bigThree)
      # The state that fetch had to survive was the real one: registration
      # failed, the dissociating repack failed, and the clone still borrows
      # from the pool with no promisor remote of its own.
      check not fileExists(borrowersPath(f.pool))
      let alternates = readAlternates(clone)
      check alternates.len == 1
      if alternates.len == 1:
        check samePathOnDisk(alternates[0], f.pool / "objects")
      check gitIn(clone, "config", "--get-regexp", "promisor").code != 0
      check poolState(f.pool) == poolBefore

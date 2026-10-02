## A shared bare's refresh and maintenance must not break the checkouts that
## borrow from it.
##
## Spec: ``reprobuild-specs/Workspace-And-Develop-Mode.md`` §"Cache
## maintenance: gc / repack" (a shared bare never loses an object and never
## rewrites its commit-graph).
##
## No mocks. Every case drives the real ``git`` binary against a real upstream,
## a real shared bare and two real checkouts wired to it with ``git clone
## --reference`` — the same wiring ``repro sync`` / ``init`` produce. The
## property under test is a statement about what git's own automatic
## maintenance and commit-graph writer do to an alternates network, so a fake
## could only agree with the assertions.
##
## The scenario is the one measured on a real host after an upstream history
## rewrite: checkout B still has remote-tracking refs naming pre-rewrite
## commits whose objects live only in the bare, and checkout A has a split
## commit-graph layer chained onto the bare's layer. The upstream is then
## rewritten (orphan history, a branch deleted) and the bare is refreshed.
##
## Git is made as aggressive as a real host can be through a private global
## config (``GIT_CONFIG_GLOBAL``): automatic gc on every fetch, immediate
## prune expiry, fetch-time and gc-time commit-graph writes. That is what makes
## the damage deterministic in a small fixture; on a real host the same thing
## happens once the thresholds and the two-week expiry are reached.
##
## Cases:
##
##   - ``control_a_plain_refresh_breaks_the_borrowers`` — POSITIVE CONTROL. The
##     refresh as it used to be run (``git fetch --all --prune`` on a bare
##     carrying only the refspec) destroys the borrowed objects and A's
##     commit-graph chain. Without this the other cases could pass because the
##     fixture never triggered maintenance at all.
##   - ``control_prune_now_maintenance_drops_borrowed_objects`` — POSITIVE
##     CONTROL for the maintenance half: even on a protected bare, the
##     ``git gc --prune=now`` the maintenance pass used to run deletes them.
##   - ``refresh_shared_bare_keeps_borrowed_objects_and_graph_chain`` —
##     ``refreshSharedBare`` (init / rewire path) followed by a forced
##     ``maintainSharedBare`` pass leaves both borrowers intact, and the bare
##     carries the safety config afterwards (the in-place migration).
##   - ``sync_refresh_bare_action_keeps_borrowed_objects_and_graph_chain`` —
##     the ``refresh-bare`` engine action ``repro sync`` schedules, run through
##     the real engine, leaves both borrowers intact too. That action used to
##     fetch with no refspec and no protection at all.
##
## Skip rule: ``git`` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import git_actions
import git_tool
import repro_build_engine
import shared_clones

proc q(value: string): string = quoteShell(value)

proc gitIn(gitBin, cwd: string; args: varargs[string]): tuple[code: int;
                                                              output: string] =
  var cmd = q(gitBin) & " -C " & q(cwd)
  for a in args:
    cmd.add(" " & q(a))
  let res = execCmdEx(cmd)
  (code: res.exitCode, output: res.output.strip())

proc must(gitBin, cwd: string; args: varargs[string]): string =
  let res = gitIn(gitBin, cwd, args)
  if res.code != 0:
    checkpoint("git " & args.join(" ") & " in " & cwd & " failed: " &
      res.output)
  doAssert res.code == 0, "fixture git command failed: " & args.join(" ")
  res.output

proc commitFile(gitBin, work, name, body: string) =
  writeFile(work / name, body)
  discard must(gitBin, work, "add", name)
  discard must(gitBin, work, "commit", "-q", "-m", name)

type Scenario = object
  gitBin, root, up, bare, a, b: string
  oldMain, oldFeat: string

const AggressiveGlobalConfig = """
[user]
  name = Shared Bare Tester
  email = tester@example.invalid
[init]
  defaultBranch = main
[gc]
  auto = 1
  autoPackLimit = 1
  pruneExpire = now
  autoDetach = false
  writeCommitGraph = true
[maintenance]
  strategy = gc
  autoDetach = false
[transfer]
  unpackLimit = 1
[fetch]
  writeCommitGraph = true
"""

proc setUp(gitBin, root: string): Scenario =
  # The bare lives exactly where ``refreshSharedBare`` derives it from the
  # URL, so the library path under test finds this pre-existing bare.
  result = Scenario(gitBin: gitBin, root: root, up: root / "up",
    bare: sharedBarePath(root / "cache", "file://" & (root / "up")),
    a: root / "ws-a" / "up", b: root / "ws-b" / "up")
  writeFile(root / "gitconfig", AggressiveGlobalConfig)
  putEnv("GIT_CONFIG_GLOBAL", root / "gitconfig")
  putEnv("GIT_CONFIG_NOSYSTEM", "1")
  let upUrl = "file://" & result.up

  createDir(result.up)
  discard must(gitBin, result.up, "init", "-q")
  for i in 1 .. 3:
    commitFile(gitBin, result.up, "f" & $i, $i & "\n")
  discard must(gitBin, result.up, "checkout", "-q", "-b", "feat")
  commitFile(gitBin, result.up, "fx", "x\n")
  discard must(gitBin, result.up, "checkout", "-q", "main")

  # The bare in the state a user's cache is in today: cloned, packed, given
  # the heads refspec + prune by the earlier migration, and carrying a split
  # commit-graph layer of its own.
  createDir(result.bare.parentDir)
  discard must(gitBin, root, "clone", "-q", "--bare", upUrl, result.bare)
  discard must(gitBin, result.bare, "repack", "-adq")
  discard must(gitBin, result.bare, "config", "--replace-all",
    "remote.origin.fetch", SharedBareFetchRefspec)
  discard must(gitBin, result.bare, "config", "remote.origin.prune", "true")
  discard must(gitBin, result.bare, "commit-graph", "write", "--reachable",
    "--split")

  for co in [result.a, result.b]:
    createDir(co.parentDir)
    discard must(gitBin, root, "clone", "-q", "--reference", result.bare,
      upUrl, co)
  # A: a local commit and a split commit-graph layer chained onto the bare's.
  commitFile(gitBin, result.a, "a", "a\n")
  discard must(gitBin, result.a, "commit-graph", "write", "--reachable",
    "--split")
  let chain = readFile(result.a / ".git" / "objects" / "info" /
    "commit-graphs" / "commit-graph-chain").strip().splitLines()
  # Premise: A really did chain onto the bare's layer (else the commit-graph
  # assertions below would prove nothing).
  doAssert chain.len == 2, "fixture: A did not chain onto the bare's layer"
  result.oldMain = must(gitBin, result.b, "rev-parse", "origin/main")
  result.oldFeat = must(gitBin, result.b, "rev-parse", "origin/feat")
  # Premise: B borrows these objects rather than holding its own copy.
  doAssert must(gitBin, result.b, "count-objects", "-v").contains("in-pack: 0")

  # The upstream history rewrite: orphan history on main, feat deleted.
  discard must(gitBin, result.up, "checkout", "-q", "--orphan", "new")
  discard must(gitBin, result.up, "rm", "-q", "-r", "-f", ".")
  commitFile(gitBin, result.up, "n", "n\n")
  discard must(gitBin, result.up, "branch", "-q", "-D", "main", "feat")
  discard must(gitBin, result.up, "branch", "-q", "-m", "main")

proc advanceUpstream(s: Scenario) =
  commitFile(s.gitBin, s.up, "q", "q\n")

proc bareHas(s: Scenario; sha: string): bool =
  ## Presence in the bare itself. Lazy fetching is off for the probe: a
  ## prepared bare is a partial clone of upstream
  ## (Shared-Clone-Pool-Integrity §3.4), and this fixture's upstream still
  ## holds the rewritten-away commits, so a lazy read would fetch them back
  ## and report the bare as never having lost them.
  let res = execCmdEx("GIT_NO_LAZY_FETCH=1 " & q(s.gitBin) & " -C " &
    q(s.bare) & " cat-file -e " & q(sha))
  res.exitCode == 0

proc graphWarning(s: Scenario): string =
  ## stderr+stdout of an ordinary history walk in A; git prints the chain
  ## warning on every command once the bare's layer is gone.
  gitIn(s.gitBin, s.a, "log", "--oneline", "-3").output

proc borrowersIntact(s: Scenario) =
  check bareHas(s, s.oldMain)
  check bareHas(s, s.oldFeat)
  let fsck = gitIn(s.gitBin, s.b, "fsck", "--connectivity-only")
  checkpoint("B fsck: " & fsck.output)
  check fsck.code == 0
  check "invalid sha1 pointer" notin fsck.output
  let log = graphWarning(s)
  checkpoint("A log: " & log)
  check "commit-graph" notin log
  let fetch = gitIn(s.gitBin, s.b, "fetch", "-q")
  checkpoint("B fetch: " & fetch.output)
  check fetch.code == 0

proc tearDown() =
  delEnv("GIT_CONFIG_GLOBAL")
  delEnv("GIT_CONFIG_NOSYSTEM")

suite "shared bare refresh keeps what borrowers reference":

  test "control_a_plain_refresh_breaks_the_borrowers":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case drives the real git binary")
    else:
      let root = createTempDir("repro-bare-borrow-control-", "")
      defer:
        tearDown()
        removeDir(root)
      let s = setUp(gitBin, root)
      discard must(gitBin, s.bare, "fetch", "--all", "--prune", "--quiet")
      s.advanceUpstream()
      discard must(gitBin, s.bare, "fetch", "--all", "--prune", "--quiet")
      # Both kinds of damage the host observed.
      check not bareHas(s, s.oldFeat)
      check "unable to find all commit-graph files" in graphWarning(s)
      check "invalid sha1 pointer" in
        gitIn(gitBin, s.b, "fsck", "--connectivity-only").output

  test "control_prune_now_maintenance_drops_borrowed_objects":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case drives the real git binary")
    else:
      let root = createTempDir("repro-bare-borrow-gc-control-", "")
      defer:
        tearDown()
        removeDir(root)
      let s = setUp(gitBin, root)
      check prepareSharedBare(gitBin, s.bare) == ""
      discard must(gitBin, s.bare, "fetch", "--all", "--prune", "--quiet")
      check bareHas(s, s.oldFeat)          # protected refresh kept it ...
      discard must(gitBin, s.bare, "gc", "--quiet", "--prune=now")
      check not bareHas(s, s.oldFeat)      # ... the old maintenance did not

  test "refresh_shared_bare_keeps_borrowed_objects_and_graph_chain":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case drives the real git binary")
    else:
      let root = createTempDir("repro-bare-borrow-refresh-", "")
      defer:
        tearDown()
        removeDir(root)
      let s = setUp(gitBin, root)
      let cacheRoot = root / "cache"
      let url = "file://" & s.up
      let derived = s.bare
      let s2 = s
      let first = refreshSharedBare(gitBin, cacheRoot, url)
      checkpoint(first.diagnostic)
      check first.ok
      s2.advanceUpstream()
      check refreshSharedBare(gitBin, cacheRoot, url).ok
      # The refresh did advance the bare (so it was a real refresh, with
      # --prune, not a no-op that trivially keeps everything).
      check must(gitBin, derived, "rev-parse", "refs/heads/main") ==
        must(gitBin, s2.up, "rev-parse", "HEAD")
      check gitIn(gitBin, derived, "rev-parse", "--verify", "-q",
        "refs/heads/feat").code != 0
      for (key, value) in SharedBareSafetyConfig:
        check must(gitBin, derived, "config", "--get", key) == value
      borrowersIntact(s2)
      # And a forced maintenance pass on top keeps them as well.
      let m = maintainSharedBare(gitBin, derived, ["ws-a", "ws-b"],
        force = true)
      checkpoint(m.diagnostic)
      check m.ok
      check m.ran
      borrowersIntact(s2)

  test "sync_refresh_bare_action_keeps_borrowed_objects_and_graph_chain":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case drives the real git binary")
    else:
      let root = createTempDir("repro-bare-borrow-action-", "")
      defer:
        tearDown()
        removeDir(root)
      let s = setUp(gitBin, root)
      let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)
      var config = defaultBuildEngineConfig(root / "engine-cache")
      config.suppressTrace = true
      for round in 1 .. 2:
        if round == 2:
          s.advanceUpstream()
        var act = gitRefreshBareAction("refresh-bare-" & $round, identity,
          remoteUrl = "file://" & s.up, barePath = s.bare,
          receiptPath = "receipt-" & $round)
        act.cwd = root
        let res = runBuild(graph([act]), config)
        check res.results.len == 1
        checkpoint("refresh-bare round " & $round & ": " &
          $res.results[0].status & " " & res.results[0].reason & " " &
          res.results[0].stderr)
        check res.results[0].status == asSucceeded
      check must(gitBin, s.bare, "rev-parse", "refs/heads/main") ==
        must(gitBin, s.up, "rev-parse", "HEAD")
      for (key, value) in SharedBareSafetyConfig:
        check must(gitBin, s.bare, "config", "--get", key) == value
      borrowersIntact(s)

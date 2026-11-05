## A CONTAINER directory output is restored by creating the directory, never
## from the tree snapshot its record stores (Incremental-Invalidation.md
## §"Non-regular outputs", "Container directory outputs": the action's claim
## about a container is only that it exists; its other entries belong to
## other writers or to nobody).
##
## Found by the independent verification of campaign M17 chunk 2b. A record
## stores a directory output's payload as a snapshot of the whole tree at
## record time, and `materializeActionCacheOutputs` restored it by REPLACING
## the directory with that snapshot. For a container that is wrong both
## ways, and the owner's decision of 2026-11-03 (Step 3.3: a payload-backed
## record whose output is modified or missing is restored in place) made it
## reachable on every `repro build --peer-cache=...`:
##
##   * a `preserveTree` whose one copied entry was modified restored ALL its
##     outputs, the root included, and the root's snapshot replaced the
##     directory: every other writer's entry (CodeTracer copies `ui.js` into a
##     `preserveTree` root) and every user file in it was deleted;
##   * an `ensureDir` whose directory was removed was recreated full of the
##     files it happened to hold when the builtin last ran -- other actions'
##     stale objects, which a consumer that lists the directory then reads.
##
## The restore mode (`--restore-cached-outputs`) had both since it existed.

import std/[os, tempfiles, unittest]

import repro_build_engine
import repro_hash
import repro_local_store

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(KeyError, id)

proc describe(item: ActionResult): string =
  item.id & " status=" & $item.status & " launched=" & $item.launched &
    " decision=" & $item.cacheDecision & " reason=" & item.reason

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("t-container-restore." & name)

proc configFor(mode, cacheRoot: string): BuildEngineConfig =
  result = defaultBuildEngineConfig(cacheRoot)
  if mode == "restore mode":
    result.enableCachedOutputRestore()
  else:
    # What `repro build --peer-cache=...` runs: in place, payloads stored.
    result.rebuildMissingOutputsOnCacheHit = true
    result.deferLocalOutputBlobs = false
  result.bypassRunQuota = true

suite "a container directory output is not restored from its snapshot":
  for mode in ["in-place, payload-backed", "restore mode"]:
    test "preserveTree: restoring a modified entry keeps the root's other entries (" &
        mode & ")":
      let root = createTempDir("t-container-restore", "")
      defer: removeDir(root)
      let work = root / "w"
      createDir(work / "src" / "tree")
      writeFile(work / "src" / "tree" / "one.txt", "one\n")
      let preserve = builtinAction(bakPreserveTree, "pt", cwd = work,
        inputs = ["src/tree/one.txt"],
        outputs = ["out/pub", "out/pub/one.txt",
          ".repro/preserve-tree/pt.manifest"],
        text = "src/tree\nout/pub", entries = ["file\tone.txt"],
        cacheable = true, weakFingerprint = weak("pt"),
        actionCachePolicy = ffpChecksum,
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      # Another writer into the same root, as CodeTracer's `ui.js` copy.
      let writer = builtinAction(bakWriteText, "ui", cwd = work, deps = ["pt"],
        outputs = ["out/pub/ui.js"], text = "ui\n", cacheable = true,
        weakFingerprint = weak("ui"), actionCachePolicy = ffpChecksum,
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      let g = graph([preserve, writer])
      let config = configFor(mode, root / "cache")
      require runBuild(g, config).byId("ui").status == asSucceeded
      # A file nobody declared, as a user leaves one.
      writeFile(work / "out" / "pub" / "notes.txt", "mine\n")
      writeFile(work / "out" / "pub" / "one.txt", "tampered\n")
      let warm = runBuild(g, config)
      checkpoint describe(warm.byId("pt"))
      checkpoint describe(warm.byId("ui"))
      check readFile(work / "out" / "pub" / "one.txt") == "one\n"
      check not warm.byId("pt").launched
      check readFile(work / "out" / "pub" / "notes.txt") == "mine\n"
      check readFile(work / "out" / "pub" / "ui.js") == "ui\n"
      check not warm.byId("ui").launched
      # The modified entry is the one overwrite; the root is not one.
      check warm.byId("pt").outputOverwrites.len == 1

    test "ensureDir: a removed directory comes back empty, not with stale files (" &
        mode & ")":
      let root = createTempDir("t-container-restore", "")
      defer: removeDir(root)
      let work = root / "w"
      # The builtin runs over a directory an earlier build filled, so its
      # record's snapshot holds those files.
      createDir(work / "build" / "c")
      writeFile(work / "build" / "c" / "stale.o", "from an earlier build\n")
      let g = graph([builtinAction(bakEnsureDir, "dir", cwd = work,
        outputs = ["build/c"], cacheable = true, weakFingerprint = weak("dir"),
        actionCachePolicy = ffpChecksum,
        governingLockIdentity = lockIdentityOutsideSolvedGraph())])
      let config = configFor(mode, root / "cache")
      require runBuild(g, config).byId("dir").status == asSucceeded
      removeDir(work / "build" / "c")
      let warm = runBuild(g, config)
      checkpoint describe(warm.byId("dir"))
      check dirExists(work / "build" / "c")
      check not fileExists(work / "build" / "c" / "stale.o")

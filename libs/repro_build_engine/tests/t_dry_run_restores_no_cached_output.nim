## A DRY RUN never restores a cached output (CLI/build.md §"Dry Run": "No
## action process runs, no declared output is written").
##
## Found by the independent verification of campaign M17 chunk 2b. The owner's
## decision of 2026-11-03 (Incremental-Invalidation.md §"Minimum check set"
## Step 3.3) made a payload-backed record whose output is modified or missing
## RESTORE in the in-place mode, through one seam
## (`restoreRecordedOutputs`). That seam ran under `--dry-run` exactly as in a
## real build, so `repro build --dry-run --peer-cache=...` wrote the recorded
## bytes over the file the user had just edited, and recreated one the user
## had deleted -- a dry run asked "what would happen?" and did it. The
## restore mode (`--restore-cached-outputs`) had always done so.
##
## A dry run still makes the real build's decision -- it reads the inputs and
## the outputs, and reports the hit a restore would serve -- and withholds
## only the writes.

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

proc copyGraph(work: string): BuildGraph =
  graph([builtinAction(bakCopyFile, "copy", cwd = work,
    inputs = ["src/in.txt"], outputs = ["out/o.txt"], cacheable = true,
    weakFingerprint = weakFingerprintFromText("t-dry-run-restore.copy"),
    actionCachePolicy = ffpChecksum,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())])

proc inPlacePayloadBacked(cacheRoot: string): BuildEngineConfig =
  ## What `repro build --peer-cache=...` runs: in place, payloads stored.
  result = defaultBuildEngineConfig(cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = false
  result.bypassRunQuota = true

proc restoreMode(cacheRoot: string): BuildEngineConfig =
  ## What `repro build --restore-cached-outputs` runs.
  result = defaultBuildEngineConfig(cacheRoot)
  result.enableCachedOutputRestore()
  result.bypassRunQuota = true

suite "a dry run restores no cached output":
  for mode in ["in-place, payload-backed", "restore mode"]:
    test "a MODIFIED output is left as the user edited it (" & mode & ")":
      let root = createTempDir("t-dry-run-restore", "")
      defer: removeDir(root)
      let work = root / "w"
      createDir(work / "src")
      writeFile(work / "src" / "in.txt", "recorded\n")
      var config =
        if mode == "restore mode": restoreMode(root / "cache")
        else: inPlacePayloadBacked(root / "cache")
      require runBuild(copyGraph(work), config).byId("copy").status ==
        asSucceeded
      writeFile(work / "out" / "o.txt", "the user's edit\n")
      config.dryRun = true
      let dry = runBuild(copyGraph(work), config)
      let item = dry.byId("copy")
      checkpoint describe(item)
      check readFile(work / "out" / "o.txt") == "the user's edit\n"
      check not item.launched
      # Reported as the hit the real build would serve; no overwrite is
      # reported as DONE (`repro build` prints those as "restored ...").
      check item.cacheDecision == cdHit
      check item.outputOverwrites.len == 0
      var wouldOverwrite = 0
      for event in dry.trace:
        if event.event == "cache-restore-would-overwrite":
          inc wouldOverwrite
      check wouldOverwrite == 1
      # The real build then restores, and reports it.
      config.dryRun = false
      let real = runBuild(copyGraph(work), config)
      checkpoint describe(real.byId("copy"))
      check readFile(work / "out" / "o.txt") == "recorded\n"
      check real.byId("copy").outputOverwrites.len == 1

    test "a DELETED output is not recreated (" & mode & ")":
      let root = createTempDir("t-dry-run-restore", "")
      defer: removeDir(root)
      let work = root / "w"
      createDir(work / "src")
      writeFile(work / "src" / "in.txt", "recorded\n")
      var config =
        if mode == "restore mode": restoreMode(root / "cache")
        else: inPlacePayloadBacked(root / "cache")
      require runBuild(copyGraph(work), config).byId("copy").status ==
        asSucceeded
      removeFile(work / "out" / "o.txt")
      config.dryRun = true
      let dry = runBuild(copyGraph(work), config)
      checkpoint describe(dry.byId("copy"))
      check not fileExists(work / "out" / "o.txt")
      check not dry.byId("copy").launched

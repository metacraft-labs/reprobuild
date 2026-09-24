## The whole-graph up-to-date shortcut must decide what the per-edge lookup
## decides — on BOTH of its arms.
##
## MOCK POLICY — NO MOCKS, DOUBLES OR FAKES ARE USED IN THIS FILE, AND NONE
## MAY BE ADDED. Every case drives the real `runBuild` scheduler, the real
## graph-built `repro` io-monitor driver and monitor shim (through
## `prepareMonitorTools`), the real per-edge `ActionCache` and CAS in
## `repro_local_store`, a real child process and real files on a real
## filesystem. The input mutation is performed with `writeFile` +
## `setLastModificationTime`, which is what `utimensat(2)` does and what a
## build tool, an editor writing in place, or a restored archive does by
## accident — not a synthesized record and not a patched cache file. A
## constructed record would have decided the question by construction; the
## whole point is that the filesystem really can present this state.
##
## WHY THIS FILE EXISTS
## ---------------------------------------------------------------------
## `tryFastNoopCacheHits` answers "nothing in this graph needs to run"
## WITHOUT entering the scheduler, so no per-edge cache decision ever
## happens on that path. It has two arms, chosen by
## `BuildEngineConfig.skipCacheHitEvidence`:
##
##   arm A (`skipCacheHitEvidence = true`, the CLI default)
##     `scanHotIndexMetadataInputsUnchanged` — one batched metadata scan.
##   arm B (`skipCacheHitEvidence = false`)
##     `lookupHotMetadataRecord` per edge, then
##     `hotMetadataRecordInputsUnchanged`.
##
## `skipCacheHitEvidence` is a REPORTING decision — whether the per-edge
## cache-hit evidence lists need reconstructing for a report to render. It
## has no bearing on whether a cached artifact is still valid. So the two
## arms must return the same verdict, always, and any property that holds
## on only one of them is a property that holds nowhere.
##
## Both cases below were red before the fix and are red again if either
## half of it is reverted; the mutations are named in each case.
##
## Issue #382 defects 1 and 2.
##
## Governing spec text:
##
## * Incremental-Invalidation.md §"File Fingerprint Policies" — the checksum
##   policy's validation criterion is the recorded content hash.
## * Failure-Semantics.md:11-12 — "Ambiguous correctness failures MUST fail
##   closed: reject cache reuse, rerun, or require review rather than
##   silently accepting stale state."

import std/[options, os, strutils, times, unittest]

import repro_build_engine
import repro_hash
import repro_local_store
import repro_test_support

const
  ChildFlag = "--whole-graph-shortcut-child"
  TmpDir = "build/test-tmp/t_whole_graph_shortcut_matches_per_edge_verdict"

let StableMtime = fromUnix(1_700_000_000)
  ## A whole second, so a `getFileInfo` → `setLastModificationTime`
  ## round-trip is lossless whatever precision the platform call carries.

# The edge's payload, executed as a real monitored child process: read the
# input through libc so the monitor observes it, and derive the output from
# what was read so a stale hit is visible in the bytes on disk.
if paramCount() == 3 and paramStr(1) == ChildFlag:
  writeFile(paramStr(3), "derived:" & readFile(paramStr(2)))
  quit(0)

type Fixture = object
  root, work, inputPath, outputPath: string
  config: BuildEngineConfig
  savedShim: tuple[present: bool, value: string]

proc setupFixture(name: string; policy: FileFingerprintPolicy): Fixture =
  result.root = absolutePath(TmpDir / name)
  if dirExists(result.root):
    removeDir(result.root)
  result.work = result.root / "work"
  createDir(result.work)
  result.inputPath = result.work / "input.txt"
  result.outputPath = result.work / "out.txt"
  writeFile(result.inputPath, "alpha\n")
  # A WHOLE SECOND, so `getFileInfo`/`setLastModificationTime` round-trips
  # it exactly and `rewritePreservingMetadata` really can leave `mtimeNs`
  # alone. See the note there.
  setLastModificationTime(result.inputPath, StableMtime)
  result.savedShim = (existsEnv("REPRO_MONITOR_SHIM_LIB"),
    getEnv("REPRO_MONITOR_SHIM_LIB"))
  let tools = prepareMonitorTools(ReprobuildRepoRoot, result.root,
    "whole-graph-shortcut")
  putEnv("REPRO_MONITOR_SHIM_LIB", tools.shim)
  result.config = defaultBuildEngineConfig(result.root / "cache")
  result.config.runQuotaCliPath = tools.monitorCliPath
  result.config.monitorCliPath = tools.monitorCliPath
  result.config.monitorCliArgs = tools.monitorCliArgs
  # The shape `tryFastNoopCacheHits` requires to run at all.
  result.config.rebuildMissingOutputsOnCacheHit = true
  result.config.deferLocalOutputBlobs = true
  discard policy

proc cleanup(f: Fixture) =
  if f.savedShim.present: putEnv("REPRO_MONITOR_SHIM_LIB", f.savedShim.value)
  else: delEnv("REPRO_MONITOR_SHIM_LIB")
  removeDir(f.root)

proc edge(f: Fixture; policy: FileFingerprintPolicy): BuildAction =
  action("whole-graph-shortcut/derive",
    [getAppFilename(), ChildFlag, f.inputPath, f.outputPath],
    cwd = f.work, outputs = [f.outputPath], cacheable = true,
    actionCachePolicy = policy,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc runOnce(f: var Fixture; act: BuildAction): ActionResult =
  let build = runBuild(graph([act]), f.config)
  require build.results.len == 1
  build.results[0]

proc output(f: Fixture): string =
  if fileExists(f.outputPath): readFile(f.outputPath).strip()
  else: "<missing>"

proc rewritePreservingMetadata(path, content: string) =
  ## Change the CONTENT and leave `{kind, sizeBytes, mtimeNs}` exactly as it
  ## was — the state `utimensat(2)` produces, and the one a metadata-only
  ## check cannot distinguish from "nothing happened".
  ##
  ## THE POST-CONDITIONS BELOW ARE THE CASE'S DENOMINATOR AND ARE NOT
  ## OPTIONAL. Written without them, this case passed against a build that
  ## had the refusal DELETED: `setLastModificationTime` round-trips a
  ## `Time` read back from `getFileInfo`, and on an mtime carrying
  ## sub-second precision the restored value differed in `mtimeNs`. The
  ## metadata had moved, every arm noticed, and the case reported [OK] while
  ## measuring nothing it claimed to measure. `StableMtime` (a whole second)
  ## is what makes the round-trip exact; this assert is what proves it did.
  let prior = getFileInfo(path).lastWriteTime
  let before = observeFile(path, ffpChecksum)
  doAssert before.metadata.sizeBytes == uint64(content.len),
    "fixture error: the mutation must preserve the file's size"
  doAssert readFile(path) != content
  writeFile(path, content)
  setLastModificationTime(path, prior)
  let after = observeFile(path, ffpChecksum)
  doAssert after.metadata == before.metadata,
    "fixture error: the mutation moved the file's metadata (" &
      $before.metadata & " -> " & $after.metadata & "), so a metadata-only " &
      "check would catch it and this case would prove nothing"
  doAssert after.localHash != before.localHash,
    "fixture error: the content did not actually change"

proc recordCount(cacheRoot: string; weak: ContentDigest): int =
  let cache = openActionCache(cacheRoot / "action-cache")
  cache.loadPerEdgeRecords(weak).len

suite "whole-graph shortcut matches the per-edge verdict":

  test "a checksum-policy content change under preserved size and mtime is not served, on either arm":
    ## DEFECT 2. `scanHotIndexMetadataInputsUnchanged` compares
    ## `FileMetadata` = `{kind, sizeBytes, mtimeNs}` only; `ffpChecksum`'s
    ## criterion is `FileFingerprint.localHash`, which is NOT in `metadata`.
    ## `lookupHotMetadataRecord` refused the policy outright; the scan did
    ## not, so arm A validated a content-keyed edge by metadata and reported
    ## the whole graph up to date.
    ##
    ## MEASURED BEFORE THE FIX, on this exact fixture: arm A returned
    ## `asUpToDate` / `cdHit` / `launched = false` and left `derived:alpha`
    ## on disk after the input had become `bravo`. A WRONG BUILD, not a slow
    ## one. Arm B relaunched and produced `derived:bravo` from the same
    ## cache and the same mutation.
    ##
    ## MUTATION THAT REDDENS IT: delete the
    ## `probe.policy notin MetadataValidatedPolicies` refusal at the top of
    ## `scanHotIndexMetadataInputsUnchanged`. The `skipEvidence = true` pass
    ## then reports `cdHit` with `derived:alpha`.
    for skipEvidence in [true, false]:
      var f = setupFixture("checksum-" & $skipEvidence, ffpChecksum)
      defer: f.cleanup()
      f.config.skipCacheHitEvidence = skipEvidence
      let act = f.edge(ffpChecksum)

      let cold = f.runOnce(act)
      checkpoint("arm skipCacheHitEvidence=" & $skipEvidence &
        " cold: " & $cold.status & " " & cold.stderr)
      require cold.status == asSucceeded
      check cold.launched
      check f.output() == "derived:alpha"

      # CONTROL. Without this the assertion after the mutation would also
      # pass against an engine that never cached this edge at all.
      let warm = f.runOnce(act)
      checkpoint("warm: " & $warm.status & " " & $warm.cacheDecision)
      check warm.cacheDecision == cdHit
      check not warm.launched
      check f.output() == "derived:alpha"

      rewritePreservingMetadata(f.inputPath, "bravo\n")

      let after = f.runOnce(act)
      checkpoint("after the content change: " & $after.status & " " &
        $after.cacheDecision & " launched=" & $after.launched &
        " output=" & f.output())
      check after.status == asSucceeded
      check after.cacheDecision != cdHit
      check after.launched
      check f.output() == "derived:bravo"

  test "the two arms agree on an edge that already has two records":
    ## DEFECT 1. The scan's docstring says `hmssHit` iff every probe has A
    ## matching record whose inputs are all metadata-unchanged — an ∃, and
    ## the same quantifier `lookupActionResultImpl`'s candidate walk uses.
    ## The code ran `for record in records:` and failed the probe if ANY
    ## record had a changed input — a ∀. `loadRecordsForWeak` returns the
    ## edge's history (up to `MaxRecFilesPerEdge` = 8 records), so ONE
    ## superseded record poisoned the edge forever.
    ##
    ## THE DENOMINATOR IS THE RECORD COUNT, and it is asserted below. On a
    ## fresh cache every edge has exactly one record and the two arms agree
    ## trivially — which is why this held in CI and on no developer machine.
    ## The disagreement appears at the SECOND record, which is to say after
    ## the edge has been rebuilt once.
    ##
    ## MUTATION THAT REDDENS IT: restore the `for record in records:` loop
    ## over every matching record in place of the newest-matching selection.
    ## The scan then answers `hmssInputChanged` for the superseded record
    ## while arm B, which reads only the newest, answers unchanged.
    var f = setupFixture("two-records", ffpTimestamp)
    defer: f.cleanup()
    f.config.skipCacheHitEvidence = true
    let act = f.edge(ffpTimestamp)
    let cacheRoot = f.root / "cache"

    require f.runOnce(act).status == asSucceeded
    check f.output() == "derived:alpha"

    # A genuine change — content AND mtime — so the edge really re-runs and
    # really publishes a SECOND record under the same weak fingerprint.
    writeFile(f.inputPath, "gamma\n")
    setLastModificationTime(f.inputPath,
      getFileInfo(f.inputPath).lastWriteTime + initDuration(seconds = 11))
    let second = f.runOnce(act)
    checkpoint("second build: " & $second.status & " " & second.stderr)
    require second.status == asSucceeded
    check second.launched
    check f.output() == "derived:gamma"

    let records = recordCount(cacheRoot, act.weakFingerprint)
    checkpoint("records for this edge: " & $records)
    require records >= 2

    # Now ask BOTH arms the same question about the same cache, the way
    # `tryFastNoopCacheHits` asks it.
    var cache = openActionCache(cacheRoot / "action-cache")
    let resolver = act.actionEnvResolver(unsafeAddr f.config)
    let probe = HotMetadataProbe(
      weakFingerprint: act.weakFingerprint,
      policy: act.actionCachePolicy,
      outputRoot: act.cwd,
      refuseRecordWithNoInputs: act.refusesRecordWithNoInputs())

    let scan = cache.scanHotIndexMetadataInputsUnchanged([probe], nil,
      [resolver])

    let hot = cache.lookupHotMetadataRecord(act.weakFingerprint,
      act.actionCachePolicy)
    let perRecordArm =
      hot.isSome and
      outputStateMismatch(hot.get(), act.cwd).len == 0 and
      hotMetadataRecordInputsUnchanged([hot.get()], nil, [resolver])

    checkpoint("arm A (scan) = " & $scan.status &
      "; arm B (per-record) unchanged = " & $perRecordArm)
    check perRecordArm
    check scan.status == hmssHit

    # And the verdict the two arms exist to produce is the one the build
    # actually takes: nothing runs.
    let third = f.runOnce(act)
    check third.cacheDecision == cdHit
    check not third.launched
    check f.output() == "derived:gamma"

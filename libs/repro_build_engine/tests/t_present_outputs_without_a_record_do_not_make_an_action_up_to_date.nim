## An action whose outputs are on disk but which no usable cache record
## vouches for must EXECUTE, not be declared up to date.
##
## Incremental-Invalidation.md §"Rebuild Decision Model" lists "action-cache
## records are present" among the conditions for answering "up to date", and
## adds: "If any required condition cannot be checked, Reprobuild MUST fail
## closed by re-executing the action or rejecting reuse." With no record, the
## identity, path-set and output-metadata conditions have nothing to be
## checked against.
##
## The scheduler's "outputs present" shortcut used to fire for a cacheable
## action on every lookup miss it had no dedicated flag for, and it asks only
## whether the declared output paths EXIST. Observed in codetracer-shell-
## recorders (reprobuild-pm issue 2026-11-12, "an action with no cache record
## is declared up to date because its outputs exist"): a `cargo build` binary
## written by a plain cargo run at older sibling pins was reported
## `asUpToDate` / `outputs-present` with `no cache record for weak
## fingerprint`, and the tests then ran the stale binary.
##
## The three cases are the three lookup outcomes that reached the shortcut:
##
## * `aclMissNoRecord` — no record at all for the weak fingerprint (the
##   observed case: outputs produced outside repro);
## * `aclMissNoRecord` produced by REFUSING a record that hit
##   (`unservableCacheRecordReason`, here the record of another action's
##   outputs);
## * `aclMissNoOutputPayload` — a metadata-only record consulted in the
##   restore configuration while the output on disk is not the recorded one.
##
## The action is a real `sh` process with a `dgRecognizedFormat` (make
## depfile) policy, the cargo edge's shape: a cacheable process edge whose
## policy does not on its own force execution (`needsExecutionForPolicy`), so
## the cache decision is the only thing deciding whether it runs. No mocks:
## the real engine, the real per-edge store and the real filesystem.

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_core
import repro_depfile
import repro_hash
import repro_local_store

when not defined(windows):
  proc depfilePolicy(path: string): DependencyGatheringPolicy =
    DependencyGatheringPolicy(
      kind: dgRecognizedFormat,
      completeness: decComplete,
      recognizedReports: @[
        RecognizedDependencyReportSpec(
          formatName: DependencyFormatName(MakeDepfileFormatName),
          outputs: @[ExpectedDependencyFile(
            logicalName: "deps",
            path: path,
            required: true)],
          completeness: decComplete)
      ],
      suppressMonitorShimSeed: true)

  proc copyAction(root, id, output: string;
                  weak = ""): BuildAction =
    ## `cp src/input.txt <output>`, appending one line to `runs.txt` per run
    ## and writing the depfile that names the input it read.
    let script =
      "cp src/input.txt " & output & " && echo run >> runs.txt && " &
      "printf '%s: %s\\n' " & output & " " & (root / "src" / "input.txt") &
      " > deps.d"
    action(id, ["/bin/sh", "-c", script],
      cwd = root,
      inputs = ["src/input.txt"],
      outputs = [output],
      cacheable = true,
      weakFingerprint = weakFingerprintFromText(
        "no-record-shortcut." & (if weak.len > 0: weak else: id)),
      actionCachePolicy = ffpChecksum,
      dependencyPolicy = depfilePolicy("deps.d"),
      governingLockIdentity = lockIdentityOutsideSolvedGraph())

  proc inPlaceConfig(cacheRoot: string): BuildEngineConfig =
    ## What `repro build` runs with: reuse in place, rebuild what is missing,
    ## records without payloads.
    result = defaultBuildEngineConfig(cacheRoot)
    result.rebuildMissingOutputsOnCacheHit = true
    result.deferLocalOutputBlobs = true
    result.bypassRunQuota = true
    result.maxParallelism = 1

  proc runs(root: string): int =
    if not fileExists(root / "runs.txt"):
      return 0
    readFile(root / "runs.txt").countLines() - 1

  proc setUp(tempRoot: string): string =
    result = tempRoot / "work"
    createDir(result / "src")
    createDir(result / "out")
    writeFile(result / "src" / "input.txt", "schema 7\n")

  suite "present outputs without a usable record":
    test "no record for the weak fingerprint: the action executes":
      let tempRoot = createTempDir("repro-no-record-shortcut", "")
      defer: removeDir(tempRoot)
      let root = setUp(tempRoot)
      # Produced outside repro, from an older input. Nothing ever recorded
      # producing it.
      writeFile(root / "out" / "tool", "schema 6\n")
      # ...together with the depfile that run left, as `cargo build` leaves
      # `target/release/<bin>.d` beside the binary.
      writeFile(root / "deps.d",
        "out/tool: " & (root / "src" / "input.txt") & "\n")
      let config = inPlaceConfig(tempRoot / "cache")

      let first = runBuild(graph([copyAction(root, "copy", "out/tool")]),
        config)
      checkpoint(first.results[0].stderr)
      check first.results[0].status == asSucceeded
      check first.results[0].launched
      check first.results[0].cacheDecision == cdMiss
      check "no cache record" in first.results[0].cacheMissReason
      check readFile(root / "out" / "tool") == "schema 7\n"
      check runs(root) == 1

      # Now a record exists, so the next build is a genuine in-place hit.
      let second = runBuild(graph([copyAction(root, "copy", "out/tool")]),
        config)
      check second.results[0].status == asUpToDate
      check second.results[0].cacheDecision == cdHit
      check not second.results[0].launched
      check runs(root) == 1

    test "a refused record leaves no record, and the action executes":
      let tempRoot = createTempDir("repro-refused-record-shortcut", "")
      defer: removeDir(tempRoot)
      let root = setUp(tempRoot)
      let config = inPlaceConfig(tempRoot / "cache")

      # Publish a record for `out/a` under a weak fingerprint the second
      # action shares. It hits for the second action (every input it is
      # keyed on matches, its own output is in place) and is then refused:
      # its outputs are not that action's (`recordOutputsNotOwnedBy`).
      let owner = runBuild(graph([copyAction(root, "copy-a", "out/a",
        weak = "shared")]), config)
      check owner.results[0].status == asSucceeded
      check runs(root) == 1

      writeFile(root / "out" / "b", "stale\n")
      let second = runBuild(graph([copyAction(root, "copy-b", "out/b",
        weak = "shared")]), config)
      checkpoint(second.results[0].stderr)
      check second.results[0].status == asSucceeded
      check second.results[0].launched
      check second.results[0].cacheDecision == cdMiss
      check readFile(root / "out" / "b") == "schema 7\n"
      check runs(root) == 2
      var refused = false
      for event in second.trace:
        if event.actionId == "copy-b" and event.event == "cache-record-refused":
          refused = true
      check refused

    test "a metadata-only record whose output was replaced: the action executes":
      let tempRoot = createTempDir("repro-payloadless-shortcut", "")
      defer: removeDir(tempRoot)
      let root = setUp(tempRoot)
      let cacheRoot = tempRoot / "cache"

      # The default in-place build publishes a record without payloads.
      let first = runBuild(graph([copyAction(root, "copy", "out/tool")]),
        inPlaceConfig(cacheRoot))
      check first.results[0].status == asSucceeded
      check runs(root) == 1

      # The output is replaced by something the record does not describe,
      # and the next build runs in the restore configuration. The record's
      # inputs all match, it cannot restore (no payload), and the output on
      # disk is not the recorded one.
      writeFile(root / "out" / "tool", "tampered\n")
      var restore = defaultBuildEngineConfig(cacheRoot)
      restore.enableCachedOutputRestore()
      restore.bypassRunQuota = true
      restore.maxParallelism = 1
      let second = runBuild(graph([copyAction(root, "copy", "out/tool")]),
        restore)
      checkpoint(second.results[0].stderr)
      check second.results[0].status == asSucceeded
      check second.results[0].launched
      check second.results[0].cacheDecision == cdMiss
      check readFile(root / "out" / "tool") == "schema 7\n"
      check runs(root) == 2

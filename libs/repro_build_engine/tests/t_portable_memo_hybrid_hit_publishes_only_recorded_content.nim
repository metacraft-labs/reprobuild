## Campaign M17 (ReproOS-Campaign-Completion.milestones.org), found by the
## independent verification of chunk 1 (publication gating): a portable memo
## record derived from a LOCAL HIT on an `ffpHybrid` record binds only the
## content that record was made from (Edge-Derived-Identities.md §3.3a).
##
## A hybrid lookup trusts an input whose kind, size and mtime are unchanged
## without reading it (`refreshedInputs`). That is the policy's local
## trade-off, and the owner accepts it for local reuse. But the portable
## record derived from such a hit (`recordPortableFromLocalHit`) takes each
## input's BLAKE3 NOW. When the bytes changed under unchanged metadata, that
## identity is of content the execution never saw, and publishing it would
## hand another host a record binding the new content to outputs made from
## the old: a content claim the record never made, computed after the fact,
## which §3.3a forbids. So before a hybrid hit derives a portable record, the
## inputs must still have the content hashes the record carries; when one
## does not, nothing is derived or published, the trace names the input, and
## the hit itself is served exactly as before.
##
## An `ffpChecksum` hit needs no such step: its lookup re-hashed every input
## against the record a moment ago.
##
## MOCK POLICY: a recording closure in the engine's portable publisher slot
## (the real publisher is exercised by `t_portable_memo_cache` and
## `t_portable_memo_refuses_timestamp_records`); everything else is the real
## engine, action cache and CAS.

import std/[os, strutils, times, unittest]

from repro_test_support import testCaseScratchSlug

import repro_build_engine
import repro_core/paths
import repro_local_store

let TmpDir = absolutePath(
  "build/test-tmp/t_portable_memo_hybrid_hit-" & testCaseScratchSlug())

type
  Published = ref object
    strongs: seq[string]
  Built = object
    result: ActionResult
    trace: string

proc recorder(into: Published): PortableMemoPublisher =
  result = proc (roots: seq[LogicalRoot]; record: PortableMemoRecord;
                 withOutputs: bool): string {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      into.strongs.add(record.strongHex)
    ""

proc project(name, source: string): string =
  result = TmpDir / name / "proj"
  createDir(result / "src")
  createDir(result / "out")
  writeFile(result / "src" / "main.c", source)

proc build(project: string; policy: FileFingerprintPolicy;
           publisher: PortableMemoPublisher): Built =
  let action = builtinAction(bakWriteText, "t-portable-hybrid-hit",
    cwd = project,
    inputs = [project / "src" / "main.c"],
    outputs = [project / "out" / "result.txt"],
    cacheable = true,
    actionCachePolicy = policy,
    text = "built\n",
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  var config = defaultBuildEngineConfig(project.parentDir / "cache")
  config.maxParallelism = 1
  # Restore mode: the hit goes through the full candidate walk, which is
  # where a hybrid record is served on unchanged metadata.
  config.rebuildMissingOutputsOnCacheHit = false
  config.deferLocalOutputBlobs = false
  config.portableRoots = @[
    LogicalRoot(label: "project", path: project, kind: lrkTracked)]
  config.portableMemoPublisher = publisher
  let run = runBuild(graph(@[action], newSeq[BuildPool]()), config)
  require run.results.len == 1
  result.result = run.results[0]
  for event in run.trace:
    result.trace.add(event.event & ": " & event.detail & "\n")
  checkpoint(result.trace)
  require result.result.status in {asSucceeded, asCacheHit, asUpToDate}

proc rewriteKeepingMetadata(path, text: string) =
  ## New bytes, the same size and the same mtime: what a hybrid lookup
  ## cannot see without reading the file.
  doAssert readFile(path).len == text.len
  let mtime = getLastModificationTime(path)
  writeFile(path, text)
  setLastModificationTime(path, mtime)

suite "M17: a portable record derived from a hybrid hit binds the recorded content":

  setup:
    if dirExists(TmpDir):
      removeDir(extendedPath(TmpDir))
    createDir(TmpDir)

  test "an input changed under unchanged metadata: the hit serves, nothing is published":
    let p = project("changed", "AAAA\n")
    let published = Published()
    let first = build(p, ffpHybrid, recorder(published))
    check first.result.launched
    require published.strongs.len == 1
    rewriteKeepingMetadata(p / "src" / "main.c", "BBBB\n")
    let second = build(p, ffpHybrid, recorder(published))
    # Local reuse is the hybrid policy's, unchanged: a hit.
    check not second.result.launched
    check second.result.cacheDecision == cdHit
    # But no record binding BBBB to outputs made from AAAA leaves the host.
    check published.strongs.len == 1
    check not second.result.portable
    check "main.c" in second.result.portableReason
    check "portable-memo-published" notin second.trace

  test "control: an unchanged input, and a hit derives and publishes":
    let p = project("unchanged", "AAAA\n")
    let first = build(p, ffpHybrid, nil)
    check first.result.launched
    let published = Published()
    let second = build(p, ffpHybrid, recorder(published))
    check not second.result.launched
    check second.result.portable
    check published.strongs.len == 1
    check "portable-memo-published" in second.trace

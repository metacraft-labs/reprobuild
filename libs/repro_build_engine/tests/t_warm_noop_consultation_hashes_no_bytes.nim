## A warm no-op consultation must not read artifact BYTES.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every assertion drives the real `runBuild` scheduler, the real per-edge
## `ActionCache` and the real CAS in `repro_local_store`, a real C compiler
## and real files under a real temporary directory. The counter under test
## lives inside the store's blob paths, so a substituted store would make
## the whole file vacuous: it would count a fake's calls, not the product's.
##
## WHY THIS FILE EXISTS
##
## Caching-Architecture.md §"Known Limit: The Default Policy Can Serve A
## Stale Result" states the cost model the timestamp default protects:
## "metadata comparison costs one `lstat(2)` per input and scales with input
## count, while content verification scales with input bytes. Reprobuild is
## not willing to pay that on every consultation by default." It also names
## the scenario: "The warm no-op consultation is the property the timestamp
## default protects". That is a claim about work performed, and
## until now nothing checked it. The neighbouring guards count LAUNCHED
## EDGES (`t_action_cache_output_integrity.nim`, "warm re-run executes zero
## edges") or assert RECORD SHAPE (`opkMetadataOnly` vs `opkCasBlobs` in
## `t_m4_publisher_path_stores_output_blobs.nim`). A build can satisfy both
## of those and still re-hash every cached artifact on the way to deciding
## there is nothing to do — which is precisely the regression this file
## makes impossible to land silently.
##
## The counter is `casContentDigestStats()`, incremented at every place
## `repro_local_store` passes over a blob's bytes. Asserting on it rather
## than on elapsed time means the test states the property ("zero passes
## over artifact bytes") instead of a machine-specific proxy for it.
##
## WHY THE ZERO IS NOT VACUOUS
##
## A counter that is always zero would pass this file trivially, and so
## would a build that consulted no cache at all. Both are excluded, in the
## test bodies rather than in prose:
##
## * the restore-mode case below runs the SAME graph through
##   `enableCachedOutputRestore()` and requires the counter to be
##   NON-zero, so a counter that stopped counting fails there; and
## * the warm case requires every edge to come back `cdHit` and
##   `not launched`, so a build that skipped the cache — or found nothing
##   in it — fails before the zero is ever reached.
##
## Governing spec text:
##
## * Caching-Architecture.md §"Memoization Layer": "Metadata-only records are
##   valid for local in-place builds whose policy is 'rebuild missing
##   outputs' rather than 'restore missing outputs'."
## * Caching-Architecture.md §"Persistent Local Metadata Store": payload
##   blobs go to the content store "only when the selected mode needs
##   payload-backed reuse".
## * Incremental-Invalidation.md §"Validation Criteria": "a warm re-run of
##   an unchanged graph still executes zero actions".

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_hash
import repro_local_store

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("warm-noop-hashes-no-bytes." & name)

proc ccPath(): string =
  result = findExe("cc")
  if result.len == 0:
    result = findExe("gcc")

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

proc buildConfig(cacheRoot: string): BuildEngineConfig =
  ## Exactly the mode `repro build` runs in without
  ## `--restore-cached-outputs`: metadata-only publication, in-place reuse.
  ## Mirrors the object literals in
  ## `libs/repro_cli_support/src/repro_cli_support.nim`.
  result = defaultBuildEngineConfig(cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.bypassRunQuota = true
  result.maxParallelism = 4'u32

proc restoreConfig(cacheRoot: string): BuildEngineConfig =
  ## What `--restore-cached-outputs` selects. Taken from the production
  ## helper rather than set field by field, so a helper that stopped
  ## selecting restore mode fails here instead of being papered over.
  result = defaultBuildEngineConfig(cacheRoot)
  result.enableCachedOutputRestore()
  result.bypassRunQuota = true
  result.maxParallelism = 4'u32

const ProgramSource = """
#include <stdio.h>
static int helper_one(int v) { return v + 1; }
static int helper_two(int v) { return v * 3; }
int main(void) {
  int acc = 0;
  for (int i = 0; i < 64; ++i) acc += helper_two(helper_one(i));
  printf("OK %d\n", acc);
  return 0;
}
"""

proc fixtureGraph(workRoot: string; idPrefix: string): BuildGraph =
  ## Three compile edges and a link edge, so "zero digests" is a statement
  ## about a graph with several cached artifacts rather than about one.
  createDir(workRoot / "src")
  createDir(workRoot / "out")
  var actions: seq[BuildAction] = @[]
  var objects: seq[string] = @[]
  for i in 0 ..< 3:
    let stem = "unit" & $i
    writeFile(workRoot / "src" / (stem & ".c"),
      "int " & stem & "_value(void) { return " & $(i * 7) & "; }\n")
    objects.add("out/" & stem & ".o")
    actions.add(action(idPrefix & "/compile-" & stem,
      [ccPath(), "-O1", "-c", "-MD", "-MF", "out/" & stem & ".d",
       "-o", "out/" & stem & ".o", "src/" & stem & ".c"],
      cwd = workRoot,
      inputs = ["src/" & stem & ".c"],
      outputs = ["out/" & stem & ".o"],
      depfile = "out/" & stem & ".d",
      cacheable = true,
      weakFingerprint = weak(idPrefix & "/compile-" & stem),
      actionCachePolicy = ffpTimestamp,
      governingLockIdentity = lockIdentityOutsideSolvedGraph()))
  writeFile(workRoot / "src" / "main.c", ProgramSource)
  actions.add(action(idPrefix & "/compile-main",
    [ccPath(), "-O1", "-c", "-MD", "-MF", "out/main.d",
     "-o", "out/main.o", "src/main.c"],
    cwd = workRoot,
    inputs = ["src/main.c"],
    outputs = ["out/main.o"],
    depfile = "out/main.d",
    cacheable = true,
    weakFingerprint = weak(idPrefix & "/compile-main"),
    actionCachePolicy = ffpTimestamp,
    governingLockIdentity = lockIdentityOutsideSolvedGraph()))
  # The link runs the real linker; the wrapper exists only so the edge
  # emits a depfile, because an edge without one falls through to automatic
  # monitor gathering and this test has no io-monitor driver. It is a build
  # RULE, not a stand-in for anything under test.
  let linker = workRoot / "link.sh"
  writeFile(linker,
    "#!/bin/sh\n" &
    "set -e\n" &
    "cc=\"$1\"; out=\"$2\"; dep=\"$3\"; shift 3\n" &
    "\"$cc\" -o \"$out\" \"$@\"\n" &
    "printf '%s: %s\\n' \"$out\" \"$*\" > \"$dep\"\n")
  setFilePermissions(linker, {fpUserRead, fpUserWrite, fpUserExec})
  var linkArgv = @[linker, ccPath(), "out/app", "out/app.d", "out/main.o"]
  var linkInputs = @["out/main.o"]
  for obj in objects:
    linkArgv.add(obj)
    linkInputs.add(obj)
  actions.add(action(idPrefix & "/link",
    linkArgv,
    cwd = workRoot,
    deps = @[idPrefix & "/compile-main", idPrefix & "/compile-unit0",
             idPrefix & "/compile-unit1", idPrefix & "/compile-unit2"],
    inputs = linkInputs,
    outputs = ["out/app"],
    depfile = "out/app.d",
    cacheable = true,
    weakFingerprint = weak(idPrefix & "/link"),
    actionCachePolicy = ffpTimestamp,
    governingLockIdentity = lockIdentityOutsideSolvedGraph()))
  graph(actions)

proc allEdgesWereWarmHits(res: BuildRunResult; g: BuildGraph): bool =
  ## The no-op really consulted the cache and really reused everything.
  ## Without this, "zero digests" would also be true of a build that never
  ## looked anything up.
  for act in g.actions:
    let r = res.byId(act.id)
    if r.launched:
      return false
    if r.cacheDecision != cdHit:
      return false
  true

suite "warm no-op consultation reads no artifact bytes":

  test "a warm no-op of a metadata-only graph performs zero content digests":
    let cc = ccPath()
    if cc.len == 0:
      skip()
    else:
      let tempRoot = createTempDir("repro-warm-noop-digests", "")
      defer: removeDir(tempRoot)
      let workRoot = tempRoot / "work"
      let cacheRoot = tempRoot / "cache"
      let g = fixtureGraph(workRoot, "noop")
      let config = buildConfig(cacheRoot)

      let cold = runBuild(g, config)
      for act in g.actions:
        check cold.byId(act.id).status == asSucceeded
      check fileExists(workRoot / "out" / "app")

      # Publication is metadata-only, so even the COLD build stores no
      # payloads. Stated as a separate check because it is the premise the
      # warm assertion rests on: if the cold build had stored blobs, a warm
      # lookup would have something to verify and the zero below would be
      # measuring the absence of records rather than the record shape.
      check casContentDigestStats().calls == 0

      let warm = runBuild(g, config)
      check allEdgesWereWarmHits(warm, g)

      let digests = casContentDigestStats()
      check digests.calls == 0
      check digests.bytes == 0'i64

  test "the per-edge scheduler path also performs zero content digests":
    ## The case above is served by `tryFastNoopCacheHits`, the whole-graph
    ## shortcut, which has no `verifyOutputBlobs` concept at all. That makes
    ## it the WEAKER of the two paths to assert on: it cannot hash artifact
    ## bytes even if the record shape changed underneath it.
    ##
    ## Installing a progress callback is what a real `repro build` does
    ## whenever it renders anything, and the shortcut declines to run when
    ## one is present. So this case drives the per-edge scheduler lookup —
    ## `lookupActionResult` with `verifyOutputBlobs` and
    ## `allowMetadataOnlyHit` — which is the path where a regression to
    ## payload verification would actually land.
    let cc = ccPath()
    if cc.len == 0:
      skip()
    else:
      let tempRoot = createTempDir("repro-warm-noop-scheduler", "")
      defer: removeDir(tempRoot)
      let workRoot = tempRoot / "work"
      let g = fixtureGraph(workRoot, "scheduler")
      var config = buildConfig(tempRoot / "cache")

      let cold = runBuild(g, config)
      for act in g.actions:
        check cold.byId(act.id).status == asSucceeded

      var progressEvents = 0
      config.progressCallback = proc(event: BuildProgressEvent) =
        inc progressEvents
      let warm = runBuild(g, config)
      # The shortcut really was declined: without this the case would
      # silently degrade into a duplicate of the one above.
      check progressEvents > 0
      check allEdgesWereWarmHits(warm, g)

      let digests = casContentDigestStats()
      check digests.calls == 0
      check digests.bytes == 0'i64

  test "the same graph in restore mode DOES hash bytes (counter control)":
    ## The mutation guard for the test above. `--restore-cached-outputs` is
    ## the mode whose whole purpose is payload-backed reuse, so it must pay
    ## the byte-scaled cost. If this case ever reports zero, the counter has
    ## stopped counting and the zero next door means nothing.
    let cc = ccPath()
    if cc.len == 0:
      skip()
    else:
      let tempRoot = createTempDir("repro-warm-restore-digests", "")
      defer: removeDir(tempRoot)
      let workRoot = tempRoot / "work"
      let cacheRoot = tempRoot / "cache"
      let g = fixtureGraph(workRoot, "restore")
      let config = restoreConfig(cacheRoot)

      let cold = runBuild(g, config)
      for act in g.actions:
        check cold.byId(act.id).status == asSucceeded
      # Storing the payloads is itself a pass over the bytes.
      check casContentDigestStats().calls > 0

      let warm = runBuild(g, config)
      for act in g.actions:
        check not warm.byId(act.id).launched
      let digests = casContentDigestStats()
      check digests.calls > 0
      check digests.bytes > 0'i64

  test "the counter is per build, not cumulative":
    ## `runBuild` zeroes the accumulator, so a reading after a build
    ## describes that build. Without this, a long-lived process (the
    ## daemon, `repro watch`, a test binary) would report every earlier
    ## build's bytes too, and the zero above would decay into "no build in
    ## this process ever hashed anything".
    let cc = ccPath()
    if cc.len == 0:
      skip()
    else:
      let tempRoot = createTempDir("repro-digest-counter-reset", "")
      defer: removeDir(tempRoot)
      let restoreWork = tempRoot / "restore-work"
      let restoreGraph = fixtureGraph(restoreWork, "reset-restore")
      discard runBuild(restoreGraph, restoreConfig(tempRoot / "restore-cache"))
      check casContentDigestStats().calls > 0

      # A metadata-only build in the SAME process must report its own zero.
      let noopWork = tempRoot / "noop-work"
      let noopGraph = fixtureGraph(noopWork, "reset-noop")
      let noopConfig = buildConfig(tempRoot / "noop-cache")
      discard runBuild(noopGraph, noopConfig)
      let warm = runBuild(noopGraph, noopConfig)
      check allEdgesWereWarmHits(warm, noopGraph)
      check casContentDigestStats().calls == 0

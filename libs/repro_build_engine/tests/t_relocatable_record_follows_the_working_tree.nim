## A RELOCATABLE action's record is served to a byte-identical copy of its
## working tree at another path, and is revalidated against THAT copy.
##
## Hermetic-Builds-And-Path-Independence.md §"Engine-internal recipe
## compiles" (owner decision 2026-10-09): the engine's own recipe compiles
## run in the recipe's directory, and their records name what they observed
## beside that directory relative to it (`recordedInputNames`), so the same
## recipe at another path, in another worktree or under another work root is
## one cache entry, not one per location. What a relative name may not do is
## carry the FIRST location's verdict to the second: the second location's
## own files decide the hit (`repro_local_store.recordedInputLocation`). The
## cases below are the hit and every way it must turn into a miss — an edited
## input, a configuration file appearing in an ancestor directory (Nim reads
## `config.nims` from every ancestor), an anchored input changing, and a
## working tree at a different depth.
##
## The child is this binary re-invoked with a marker, and the monitor
## evidence is a canned RMDF per location, the shape
## `t_cache_record_for_other_outputs_is_not_served.nim` uses.

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_core
import repro_hash
import repro_local_store
import io_mon/[capabilities, types, writer]

const WriteMarker = "--relocatable-write"

if commandLineParams().len >= 3 and commandLineParams()[0] == WriteMarker:
  # argv: <marker> <input> <output>, both relative to the cwd.
  let output = commandLineParams()[2]
  createDir(parentDir(output))
  writeFile(output, "built from " & readFile(commandLineParams()[1]))
  quit(0)

proc writeRmdf(path: string; reads, probes: openArray[string];
               output: string) =
  var records = profileRecords(defaultHooksMonitorProfile())
  for read in reads:
    records.add(MonitorRecord(kind: mrFileRead, observationKind: moFileRead,
      osPid: 7777, threadId: 7777, path: read, detail: ""))
  for probe in probes:
    records.add(MonitorRecord(kind: mrPathProbe,
      observationKind: moPathProbe, osPid: 7777, threadId: 7777,
      path: probe, detail: ""))
  records.add(MonitorRecord(kind: mrFileWrite, observationKind: moFileWrite,
    osPid: 7777, threadId: 7777, path: output, detail: ""))
  let raw = encodeCanonical(records)
  var text = newString(raw.len)
  if raw.len > 0:
    copyMem(addr text[0], unsafeAddr raw[0], raw.len)
  writeFile(path, text)

proc treeAt(tempRoot, location: string): string =
  ## `<tempRoot>/<location>/work/proj`, holding the recipe-like input.
  result = tempRoot / location / "work" / "proj"
  createDir(result)
  writeFile(result / "input.txt", "payload")

proc relocatableAction(tempRoot, proj: string;
                       relocatable = true): BuildAction =
  ## The same computation wherever `proj` is: read `input.txt`, probe for a
  ## `config.nims` in the parent directory, read an anchored tool file.
  let anchor = tempRoot / "anchored"
  let output = proj / "out" / "product.txt"
  let rmdf = proj & ".rdep"
  writeRmdf(rmdf,
    reads = [proj / "input.txt", anchor / "tool.txt"],
    probes = [parentDir(proj) / "config.nims"],
    output = output)
  result = action("produce",
    @[getAppFilename(), WriteMarker, "input.txt", "out/product.txt"],
    cwd = proj,
    inputs = @["input.txt"],
    outputs = @["out/product.txt"],
    cacheable = true,
    weakFingerprint = weakFingerprintFromText("relocatable test edge"),
    actionCachePolicy = ffpHybrid,
    governingLockIdentity = lockIdentityOutsideSolvedGraph(),
    relocatable = relocatable,
    relocationAnchors = @[anchor])
  result.monitorDepfile = rmdf

proc restoreConfig(cacheRoot: string): BuildEngineConfig =
  result = defaultBuildEngineConfig(cacheRoot)
  result.enableCachedOutputRestore()
  result.bypassRunQuota = true

proc only(r: BuildRunResult; id: string): ActionResult =
  for item in r.results:
    if item.id == id:
      return item
  raise newException(ValueError, "no result for " & id)

proc describe(item: ActionResult): string =
  "status=" & $item.status & " cache=" & $item.cacheDecision &
    " launched=" & $item.launched & " reason=" & item.reason &
    " miss=" & item.cacheMissReason

proc setup(): tuple[tempRoot, alpha: string; config: BuildEngineConfig] =
  let tempRoot = createTempDir("repro-relocatable", "")
  createDir(tempRoot / "anchored")
  writeFile(tempRoot / "anchored" / "tool.txt", "tool v1")
  let config = restoreConfig(tempRoot / "cache")
  let alpha = treeAt(tempRoot, "alpha")
  let first = runBuild(graph([relocatableAction(tempRoot, alpha)]), config)
  doAssert first.only("produce").launched, first.only("produce").describe
  (tempRoot, alpha, config)

suite "a relocatable record follows the working tree":

  test "the record names inputs relative to the cwd, anchors absolutely":
    let (tempRoot, alpha, _) = setup()
    defer: removeDir(tempRoot)
    let edge = relocatableAction(tempRoot, alpha)
    let cache = openActionCache(tempRoot / "cache" / "action-cache")
    let records = cache.loadPerEdgeRecords(edge.weakFingerprint)
    require records.len == 1
    var names: seq[string] = @[]
    for input in records[0].inputs:
      names.add(input.path)
    checkpoint("recorded inputs: " & names.join(", "))
    check "input.txt" in names
    check ("..".joinPath("config.nims")) in names
    check (tempRoot / "anchored" / "tool.txt") in names
    for name in names:
      check not name.startsWith(alpha)
    check records[0].outputs.len == 1
    check records[0].outputs[0].path == "out/product.txt"

  test "a byte-identical copy at another path is served from the record":
    let (tempRoot, alpha, config) = setup()
    defer: removeDir(tempRoot)
    let beta = treeAt(tempRoot, "beta")
    let edge = relocatableAction(tempRoot, beta)
    check edge.weakFingerprint ==
      relocatableAction(tempRoot, alpha).weakFingerprint
    let served = runBuild(graph([edge]), config).only("produce")
    checkpoint("beta: " & served.describe)
    check served.status == asCacheHit
    check not served.launched
    check readFile(beta / "out" / "product.txt") == "built from payload"
    # Alpha's tree is not written by beta's restore.
    removeFile(alpha / "out" / "product.txt")
    discard runBuild(graph([relocatableAction(tempRoot, beta)]), config)
    check not fileExists(alpha / "out" / "product.txt")

  test "an edited input at the copy is a miss":
    let (tempRoot, _, config) = setup()
    defer: removeDir(tempRoot)
    let beta = treeAt(tempRoot, "beta")
    writeFile(beta / "input.txt", "edited")
    let item = runBuild(graph([relocatableAction(tempRoot, beta)]),
      config).only("produce")
    checkpoint("beta edited: " & item.describe)
    check item.launched
    check readFile(beta / "out" / "product.txt") == "built from edited"

  test "a config file in the copy's ancestor directory is a miss":
    let (tempRoot, _, config) = setup()
    defer: removeDir(tempRoot)
    let beta = treeAt(tempRoot, "beta")
    writeFile(parentDir(beta) / "config.nims", "switch(\"define\", \"x\")")
    let item = runBuild(graph([relocatableAction(tempRoot, beta)]),
      config).only("produce")
    checkpoint("beta with ancestor config: " & item.describe)
    check item.launched

  test "a changed anchored input is a miss everywhere":
    let (tempRoot, _, config) = setup()
    defer: removeDir(tempRoot)
    writeFile(tempRoot / "anchored" / "tool.txt", "tool v2")
    let beta = treeAt(tempRoot, "beta")
    let item = runBuild(graph([relocatableAction(tempRoot, beta)]),
      config).only("produce")
    checkpoint("beta after anchored change: " & item.describe)
    check item.launched

  test "a working tree at another depth is another edge":
    let (tempRoot, alpha, _) = setup()
    defer: removeDir(tempRoot)
    let deeper = tempRoot / "gamma" / "x" / "work" / "proj"
    createDir(deeper)
    check relocatableAction(tempRoot, deeper).weakFingerprint !=
      relocatableAction(tempRoot, alpha).weakFingerprint

  test "an ordinary action records absolute names and keeps its key":
    let tempRoot = createTempDir("repro-relocatable-off", "")
    defer: removeDir(tempRoot)
    let proj = treeAt(tempRoot, "alpha")
    let edge = relocatableAction(tempRoot, proj, relocatable = false)
    let deeper = tempRoot / "gamma" / "x" / "work" / "proj"
    createDir(deeper)
    # Not keyed on the cwd's depth: the identity it always had.
    check edge.weakFingerprint ==
      relocatableAction(tempRoot, deeper, relocatable = false).weakFingerprint
    check edge.weakFingerprint !=
      relocatableAction(tempRoot, proj).weakFingerprint
    check edge.recordedInputNames([proj / "input.txt"]) ==
      @[proj / "input.txt"]

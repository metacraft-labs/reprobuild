## A cached record whose outputs are not the requesting action's own outputs
## is not served.
##
## Incremental-Invalidation.md §"Minimum check set per target consultation",
## Step 3.3, defines a hit by the action's OWN declared outputs: they exist and
## match the record, or they are materialized from it. A weak fingerprint does
## not pin those outputs — `action()` derives its default from the id, and a
## caller-supplied one need not mention them — so two actions in different
## places can address the same record set: the same edge in two checkouts, a
## record installed from a peer laid out elsewhere, a plain collision.
##
## Before the guard, such a record was served. With payload-backed records
## (`enableCachedOutputRestore`), the second action's lookup was a HIT, its own
## output was never produced, and the restore wrote the FIRST action's output
## path — a file the second action does not own
## (Filesystem-Policy-And-Observed-Inputs.md §"Double Writes"). With the guard
## it is a miss: the second action runs and produces its own output, and the
## first action's directory is left alone.
##
## The child is this binary re-invoked with a marker (no shell, no PATH
## lookup), and the monitor evidence is a canned RMDF, the shape
## `test_s7_cached_output_restore_mode.nim` uses.

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_core
import repro_hash
import repro_local_store
import io_mon/[capabilities, types, writer]

const WriteMarker = "--other-outputs-write"

if commandLineParams().len >= 3 and commandLineParams()[0] == WriteMarker:
  # argv: <marker> <input> <output>. Copy the shared input to this action's
  # own output, tagged with the output's directory so the two locations'
  # products are distinguishable.
  let output = commandLineParams()[2]
  createDir(parentDir(output))
  writeFile(output, readFile(commandLineParams()[1]) & "@" &
    extractFilename(parentDir(parentDir(output))) & "\n")
  quit(0)

proc writeRmdf(path: string; input, output: string) =
  let records = profileRecords(defaultHooksMonitorProfile()) & @[
    MonitorRecord(kind: mrFileRead, observationKind: moFileRead,
      osPid: 7777, threadId: 7777, path: input, detail: ""),
    MonitorRecord(kind: mrFileWrite, observationKind: moFileWrite,
      osPid: 7777, threadId: 7777, path: output, detail: "")]
  let raw = encodeCanonical(records)
  var text = newString(raw.len)
  if raw.len > 0:
    copyMem(addr text[0], unsafeAddr raw[0], raw.len)
  writeFile(path, text)

proc locationAction(tempRoot, location: string;
                    sharedWeak: ContentDigest): BuildAction =
  ## The same computation (same input, same weak fingerprint) declared in
  ## `location`, with its output under `location`.
  let root = tempRoot / location
  let input = tempRoot / "shared" / "input.txt"
  let output = root / "out" / "product.txt"
  createDir(root)
  let rmdf = tempRoot / (location & ".rdep")
  writeRmdf(rmdf, input, output)
  result = action("produce", @[getAppFilename(), WriteMarker, input, output],
    cwd = root,
    inputs = @[input],
    outputs = @[output],
    cacheable = true,
    weakFingerprint = sharedWeak,
    actionCachePolicy = ffpChecksum,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  result.monitorDepfile = rmdf

proc restoreConfig(cacheRoot: string): BuildEngineConfig =
  ## The payload-backed configuration: the one in which serving a foreign
  ## record WRITES somewhere. The metadata-only configuration fails the same
  ## lookup closed for a different reason (no payload), so it cannot show the
  ## hazard.
  result = defaultBuildEngineConfig(cacheRoot)
  result.enableCachedOutputRestore()
  result.bypassRunQuota = true

proc only(r: BuildRunResult; id: string): ActionResult =
  for item in r.results:
    if item.id == id:
      return item
  raise newException(ValueError, "no result for " & id)

suite "a cached record of another location's outputs is not served":

  test "the second location runs its own action and the first is left alone":
    let tempRoot = createTempDir("repro-other-outputs", "")
    defer: removeDir(tempRoot)
    createDir(tempRoot / "shared")
    writeFile(tempRoot / "shared" / "input.txt", "payload")
    let sharedWeak = weakFingerprintFromText("one weak key, two locations")
    let config = restoreConfig(tempRoot / "cache")

    let first = locationAction(tempRoot, "alpha", sharedWeak)
    let firstRun = runBuild(graph([first]), config)
    require firstRun.only("produce").status == asSucceeded
    require firstRun.only("produce").launched
    let alphaOutput = tempRoot / "alpha" / "out" / "product.txt"
    require readFile(alphaOutput) == "payload@alpha\n"

    # The premise: the record exists, under the shared weak fingerprint, and
    # it names alpha's output. Without it the second build would miss for
    # "no record" and this case would assert nothing.
    let cache = openActionCache(tempRoot / "cache" / "action-cache")
    let records = cache.loadPerEdgeRecords(first.weakFingerprint)
    require records.len == 1
    require records[0].outputs.len == 1
    require records[0].outputs[0].path == alphaOutput

    # A foreign restore is visible as alpha's output coming back.
    removeFile(alphaOutput)

    let second = locationAction(tempRoot, "beta", sharedWeak)
    # The two locations really do address one record set.
    require second.weakFingerprint == first.weakFingerprint
    let secondRun = runBuild(graph([second]), config)
    let betaResult = secondRun.only("produce")
    checkpoint("beta: status=" & $betaResult.status & " cache=" &
      $betaResult.cacheDecision & " launched=" & $betaResult.launched &
      " reason=" & betaResult.reason)
    check betaResult.status == asSucceeded
    check betaResult.launched
    check betaResult.cacheDecision != cdHit
    let betaOutput = tempRoot / "beta" / "out" / "product.txt"
    check fileExists(betaOutput)
    if fileExists(betaOutput):
      check readFile(betaOutput) == "payload@beta\n"
    check not fileExists(alphaOutput)

    # The diagnostic names the reason, so a miss here reads as what it is.
    var traced = false
    for event in secondRun.trace:
      if event.event == "cache-record-refused" and
          "not one of this action's declared outputs" in event.detail:
        traced = true
    check traced

  test "the record still serves the location that produced it":
    ## Non-vacuity: the guard refuses foreign records, not records.
    let tempRoot = createTempDir("repro-other-outputs-own", "")
    defer: removeDir(tempRoot)
    createDir(tempRoot / "shared")
    writeFile(tempRoot / "shared" / "input.txt", "payload")
    let sharedWeak = weakFingerprintFromText("own location")
    let config = restoreConfig(tempRoot / "cache")

    let first = locationAction(tempRoot, "alpha", sharedWeak)
    require runBuild(graph([first]), config).only("produce").launched
    let alphaOutput = tempRoot / "alpha" / "out" / "product.txt"
    removeFile(alphaOutput)

    let again = runBuild(graph([locationAction(tempRoot, "alpha",
      sharedWeak)]), config).only("produce")
    checkpoint("alpha again: status=" & $again.status & " cache=" &
      $again.cacheDecision & " launched=" & $again.launched &
      " reason=" & again.reason)
    check again.status == asCacheHit
    check not again.launched
    check again.cacheDecision == cdHit
    check readFile(alphaOutput) == "payload@alpha\n"

suite "recordOutputsNotOwnedBy":

  proc recordWith(paths: openArray[string]): ActionResultRecord =
    for path in paths:
      result.outputs.add(OutputBlob(path: path))

  test "the same outputs, spelled the way the action spells them, are owned":
    check recordOutputsNotOwnedBy(recordWith(["out/a", "/abs/b"]), "/root",
      ["/abs/b", "out/a"]).len == 0
    check recordOutputsNotOwnedBy(recordWith(["out/a"]), "/root",
      ["/root/out/a"]).len == 0
    check recordOutputsNotOwnedBy(recordWith([]), "/root", []).len == 0

  test "relative outputs resolve against the requesting action's cwd":
    # Recorded relative, so a restore places them under whichever cwd asks:
    # not a foreign write, and not refused.
    check recordOutputsNotOwnedBy(recordWith(["out/a"]), "/elsewhere",
      ["out/a"]).len == 0

  test "an absolute output elsewhere is foreign":
    check "not one of this action's declared outputs" in
      recordOutputsNotOwnedBy(recordWith(["/alpha/out/a"]), "/beta",
        ["/beta/out/a"])

  test "a record missing one of the action's outputs is refused too":
    check "does not describe it" in recordOutputsNotOwnedBy(
      recordWith(["out/a"]), "/root", ["out/a", "out/b"])

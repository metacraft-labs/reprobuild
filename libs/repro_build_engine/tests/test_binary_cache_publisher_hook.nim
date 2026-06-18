## M9.L.4-refactor Step A — engine-side binary-cache publisher hook.
##
## Verifies that the engine's new ``BinaryCachePublisher`` closure
## seam fires exactly when the action carries
## ``publishToBinaryCache = true`` AND
## ``cacheEntryIdentity.isSome`` AND the engine is configured with a
## non-nil ``binaryCachePublisher`` AND the action completes
## successfully. All other combinations leave the publisher
## un-invoked.
##
## The test fakes the publisher closure with a mutable capture so the
## assertions can inspect every recorded invocation byte-for-byte.
## No network, no HTTP server, no disk-IO beyond the engine's own
## CAS / action-cache for the one ``bakWriteText`` action under test.
##
## See ``libs/repro_build_engine/src/repro_build_engine.nim``
## §publishBinaryCacheBundle + ``BuildAction.publishToBinaryCache`` /
## ``BuildAction.cacheEntryIdentity`` / ``BuildEngineConfig.
## binaryCachePublisher`` for the seam under test.

import std/[options, os, tables, unittest]

import repro_binary_cache_client/cache_key
import repro_binary_cache_server/types as bcsTypes
import repro_build_engine
import repro_hash
import repro_local_store

const TmpDir = "build/test-tmp/test_binary_cache_publisher_hook"

proc resetTmp() =
  if dirExists(TmpDir):
    removeDir(TmpDir)
  createDir(TmpDir)

# ---------------------------------------------------------------------------
# Fixtures.
# ---------------------------------------------------------------------------

type
  Recorder = ref object
    ## Mutable capture for the mock publisher closure. ``invocations``
    ## holds every request the engine handed off; ``returnOk`` controls
    ## the synthetic response so we can exercise the soft-fail branch.
    invocations: seq[BinaryCachePublishRequest]
    returnOk: bool
    statusCode: int
    error: string
    bytesUploaded: int

proc newRecorder(returnOk: bool = true; statusCode = 200; bytesUploaded = 1024;
                 error = ""): Recorder =
  result = Recorder(
    invocations: @[],
    returnOk: returnOk,
    statusCode: statusCode,
    error: error,
    bytesUploaded: bytesUploaded)

proc makePublisher(recorder: Recorder): BinaryCachePublisher =
  result = proc(req: BinaryCachePublishRequest):
      BinaryCachePublishResult {.gcsafe, closure.} =
    recorder.invocations.add(req)
    BinaryCachePublishResult(
      ok: recorder.returnOk,
      statusCode: recorder.statusCode,
      error: recorder.error,
      bytesUploaded: recorder.bytesUploaded)

proc stubIdentity(packageName, packageVersion, providerRevision: string):
    CacheEntryIdentity =
  result = newCacheEntryIdentity(
    packageName = packageName,
    packageVersion = packageVersion,
    platform = bcsTypes.PlatformTriple(
      cpu: "x86_64", os: "linux", abi: "gnu", libcVariant: "glibc"),
    toolchain = bcsTypes.ToolchainIdentity(
      name: "stub", version: "1", hostLdSoAbi: "", extraFingerprint: ""),
    providerRevision = providerRevision)

proc fingerprintForPayload(payload: string): ContentDigest =
  casDigest(payload.toOpenArrayByte(0, payload.high),
            domain = hdActionFingerprint)

proc oneAction(outputPath, payload: string;
               publish: bool;
               identity: Option[CacheEntryIdentity];
               fingerprintToken = "default"): BuildGraph =
  let action = BuildAction(
    kind: bakWriteText,
    id: "t-bcp-write",
    deps: @[],
    inputs: @[],
    outputs: @[outputPath],
    cacheable: true,
    actionCachePolicy: ffpTimestamp,
    weakFingerprint: fingerprintForPayload(payload & "|" & fingerprintToken),
    builtinText: payload,
    publishToBinaryCache: publish,
    cacheEntryIdentity: identity)
  graph(@[action], newSeq[BuildPool]())

proc producerCfg(cacheRoot: string; recorder: Recorder): BuildEngineConfig =
  result = defaultBuildEngineConfig(cacheRoot)
  result.maxParallelism = 1
  result.deferLocalOutputBlobs = false
  result.binaryCachePublisher = makePublisher(recorder)

# ---------------------------------------------------------------------------
# Tests.
# ---------------------------------------------------------------------------

suite "M9.L.4-refactor Step A — engine binary-cache publisher hook":

  test "publisher fires on success when flag + identity + closure are all set":
    resetTmp()
    let cacheRoot = TmpDir / "cache-fires"
    let outputPath = absolutePath(TmpDir / "outputs-fires" / "hello.txt")
    createDir(cacheRoot)
    createDir(splitPath(outputPath).head)

    let recorder = newRecorder()
    let identity = stubIdentity("test-pkg", "1.0.0", "rev-fires")
    let payload = "binary-cache fires\n"

    let g = oneAction(
      outputPath, payload,
      publish = true,
      identity = some(identity),
      fingerprintToken = "fires")
    let res = runBuild(g, producerCfg(cacheRoot, recorder))
    check res.results.len == 1
    check res.results[0].status == asSucceeded
    check fileExists(outputPath)
    check recorder.invocations.len == 1
    let req = recorder.invocations[0]
    check req.actionId == "t-bcp-write"
    check req.identity.packageName == "test-pkg"
    check req.identity.packageVersion == "1.0.0"
    check req.identity.providerRevision == "rev-fires"
    check req.declaredOutputs == @[outputPath]
    check req.recordOutputs.len == 1
    check req.recordOutputs[0] == outputPath

  test "publisher is NOT invoked when publishToBinaryCache = false":
    resetTmp()
    let cacheRoot = TmpDir / "cache-noflag"
    let outputPath = absolutePath(TmpDir / "outputs-noflag" / "noflag.txt")
    createDir(cacheRoot)
    createDir(splitPath(outputPath).head)
    let recorder = newRecorder()
    let identity = stubIdentity("test-pkg", "1.0.0", "rev-noflag")
    let g = oneAction(
      outputPath, "no-flag payload\n",
      publish = false,
      identity = some(identity),
      fingerprintToken = "noflag")
    let res = runBuild(g, producerCfg(cacheRoot, recorder))
    check res.results.len == 1
    check res.results[0].status == asSucceeded
    check recorder.invocations.len == 0

  test "publisher is NOT invoked when cacheEntryIdentity is None":
    resetTmp()
    let cacheRoot = TmpDir / "cache-noid"
    let outputPath = absolutePath(TmpDir / "outputs-noid" / "noid.txt")
    createDir(cacheRoot)
    createDir(splitPath(outputPath).head)
    let recorder = newRecorder()
    let g = oneAction(
      outputPath, "no-identity payload\n",
      publish = true,
      identity = none(CacheEntryIdentity),
      fingerprintToken = "noid")
    let res = runBuild(g, producerCfg(cacheRoot, recorder))
    check res.results.len == 1
    check res.results[0].status == asSucceeded
    check recorder.invocations.len == 0

  test "publisher is NOT invoked when closure field is nil":
    resetTmp()
    let cacheRoot = TmpDir / "cache-noclosure"
    let outputPath = absolutePath(TmpDir / "outputs-noclosure" / "noclosure.txt")
    createDir(cacheRoot)
    createDir(splitPath(outputPath).head)
    let identity = stubIdentity("test-pkg", "1.0.0", "rev-noclosure")
    let g = oneAction(
      outputPath, "no-closure payload\n",
      publish = true,
      identity = some(identity),
      fingerprintToken = "noclosure")
    var cfg = defaultBuildEngineConfig(cacheRoot)
    cfg.maxParallelism = 1
    cfg.deferLocalOutputBlobs = false
    # binaryCachePublisher intentionally left nil — engine MUST not
    # crash and MUST not attempt to invoke a nil closure.
    let res = runBuild(g, cfg)
    check res.results.len == 1
    check res.results[0].status == asSucceeded
    # No recorder to check — the test asserts no crash + successful
    # build with the publisher disabled.

  test "publisher soft-fail leaves the build succeeded":
    ## When the publisher closure returns ok=false (or raises), the
    ## engine logs into stats but the action's status MUST remain
    ## ``asSucceeded`` — publish failures NEVER abort the build.
    resetTmp()
    let cacheRoot = TmpDir / "cache-softfail"
    let outputPath = absolutePath(TmpDir / "outputs-softfail" / "softfail.txt")
    createDir(cacheRoot)
    createDir(splitPath(outputPath).head)
    let recorder = newRecorder(
      returnOk = false, statusCode = 500,
      error = "synthetic server error",
      bytesUploaded = 0)
    let identity = stubIdentity("test-pkg", "1.0.0", "rev-softfail")
    let g = oneAction(
      outputPath, "soft-fail payload\n",
      publish = true,
      identity = some(identity),
      fingerprintToken = "softfail")
    let res = runBuild(g, producerCfg(cacheRoot, recorder))
    check res.results.len == 1
    check res.results[0].status == asSucceeded
    check recorder.invocations.len == 1
    # The action's result must NOT carry the publish error as a build
    # failure — soft-fail is engine-internal stats only.
    check res.results[0].stderr == ""

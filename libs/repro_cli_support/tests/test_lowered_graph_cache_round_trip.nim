{.define: reproLoweredGraphCodecTest.}

import std/[options, strutils, tables, unittest]

import repro_binary_cache_client/cache_key
import repro_build_engine
import repro_cli_support
import repro_core
import repro_depfile
import repro_hash
import repro_local_store

proc testFingerprint(): ContentDigest =
  weakFingerprintFromText("lowered-graph-round-trip")

suite "lowered graph cache action round trip":
  test "preserves execution, type, cache, and policy metadata":
    var identity = publicInterfaceIdentity(
      packageName = "zlib",
      packageVersion = "1.3.1",
      toolchainName = "autotools",
      providerRevision = "recipe-revision")
    identity.addOption("feature", "shared")
    identity.addDep(
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    let action = BuildAction(
      governingLockIdentity: emptySolvedGraphIdentity("codec-round-trip-test"),
      kind: bakProcess,
      id: "install-mirror-zlib",
      deps: @["install-zlib"],
      inputs: @["install.stamp"],
      outputs: @["mirror.stamp"],
      argv: @["sh", "-c", "true"],
      cwd: "/recipe/zlib",
      env: @["A=B", "PATH=/tool/bin"],
      envPassthrough: @["PATH"],
      pool: "compile",
      poolUnits: 2,
      cpuMilli: 1500,
      memoryBytes: 4096,
      commandStatsId: "install-mirror",
      cacheable: true,
      weakFingerprint: testFingerprint(),
      actionCachePolicy: ffpHybrid,
      dependencyPolicy: DependencyGatheringPolicy(
        kind: dgAutomaticMonitor, completeness: decComplete,
        captureNonDeterminism: true, captureIpc: true),
      targetNames: @["zlib"],
      typedOutputs: @[EngineTypedOutput(
        fieldName: "library", types: @["Library"], path: "usr/lib")],
      publishToBinaryCache: true,
      cacheEntryIdentity: some(identity),
      toolIdentityRefs: @["sh", "gcc"],
      toolIdentityRefKinds: @[dkNative, dkBuild],
      cachePlatformTag: "x86_64-linux-gnu",
      declaredOutputs: @["/recipe/zlib/.repro/output/install"],
      readOnlyRoots: @["/recipe/zlib/src"],
      requiresElevation: true)

    let decoded = loweredGraphActionRoundTripForTest(@[action])
    check decoded.len == 1
    let roundTrip = decoded[0]
    check roundTrip.governingLockIdentity == action.governingLockIdentity
    check roundTrip.id == action.id
    check roundTrip.targetNames == action.targetNames
    check roundTrip.typedOutputs.len == 1
    check roundTrip.typedOutputs[0].types == @["Library"]
    check roundTrip.publishToBinaryCache
    check roundTrip.cacheEntryIdentity.isSome
    check deriveCacheEntryKeyHex(roundTrip.cacheEntryIdentity.get()) ==
      deriveCacheEntryKeyHex(identity)
    check roundTrip.toolIdentityRefs == action.toolIdentityRefs
    check roundTrip.toolIdentityRefKinds == action.toolIdentityRefKinds
    check roundTrip.cachePlatformTag == action.cachePlatformTag
    check roundTrip.declaredOutputs == action.declaredOutputs
    check roundTrip.readOnlyRoots == action.readOnlyRoots
    check roundTrip.requiresElevation

    # The declared/passthrough CLASSIFICATION must survive the cache, and
    # this is not a formality. Before it was serialised, a warm build
    # decoded every action with an empty passthrough set: the stage-2
    # census reported 1391 actions naming a passthrough variable cold and
    # 0 warm, and `launchChildEnv`'s passthrough resolution was dead on
    # any warm build. The weak fingerprint is stored explicitly so keys
    # did not move, which is exactly why nothing noticed.
    check roundTrip.env == action.env
    check roundTrip.envPassthrough == action.envPassthrough
    check roundTrip.envPassthrough == @["PATH"]
    # And the classification must survive as a DISTINCTION, not just as
    # two non-empty seqs: `PATH` is declared AND passthrough here, `A` is
    # declared only.
    check "A=B" in roundTrip.env
    check "A" notin roundTrip.envPassthrough

    # Feature 1: the event-interest opt-ins on the dependency-gathering
    # policy must survive the lowered-graph-cache round trip. Before they
    # were serialised, a warm build decoded every action with both flags
    # false, so an edge that opted into non-determinism / IPC capture lost
    # that interest on any cache hit.
    check roundTrip.dependencyPolicy.captureNonDeterminism
    check roundTrip.dependencyPolicy.captureIpc

  test "rejects the previous cache version instead of decoding without lock identity":
    let action = BuildAction(
      governingLockIdentity: emptySolvedGraphIdentity("codec-version-test"),
      kind: bakStamp,
      id: "codec-version-test")
    var encoded = loweredGraphCacheBytesForTest(@[action])
    let versionOffset = loweredGraphCacheVersionOffsetForTest()
    check encoded[versionOffset] == 7'u8
    check encoded[versionOffset + 1] == 0'u8
    # An older version could not carry the newer per-action fields (v5:
    # `envPassthrough`; v6: the dependency-policy event-interest opt-ins).
    # Decoding such a record under the current layout would silently return
    # defaults for every action rather than failing, so the rejection below
    # is what makes a field's absence impossible instead of invisible.
    encoded[versionOffset] = 6'u8
    var rejected = false
    try:
      discard loweredGraphCacheActionsForTest(encoded)
    except CatchableError as err:
      rejected = true
      check "unsupported lowered graph cache version" in err.msg
    check rejected

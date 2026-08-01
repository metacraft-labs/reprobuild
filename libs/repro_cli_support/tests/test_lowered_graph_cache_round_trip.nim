{.define: reproLoweredGraphCodecTest.}

import std/[options, tables, unittest]

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
      kind: bakProcess,
      id: "install-mirror-zlib",
      deps: @["install-zlib"],
      inputs: @["install.stamp"],
      outputs: @["mirror.stamp"],
      argv: @["sh", "-c", "true"],
      cwd: "/recipe/zlib",
      env: @["A=B"],
      pool: "compile",
      poolUnits: 2,
      cpuMilli: 1500,
      memoryBytes: 4096,
      commandStatsId: "install-mirror",
      cacheable: true,
      weakFingerprint: testFingerprint(),
      actionCachePolicy: ffpHybrid,
      dependencyPolicy: DependencyGatheringPolicy(
        kind: dgAutomaticMonitor, completeness: decComplete),
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

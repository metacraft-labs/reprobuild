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
  test "an incomplete identity remains unusable after graph cache restore":
    var identity = publicInterfaceIdentity("pending", "1", "cmake", "entry")
    identity.addOption(PendingCacheIdentityOptionKey, "unbound source closure")
    let action = BuildAction(
      governingLockIdentity: emptySolvedGraphIdentity("pending-codec"),
      kind: bakStamp,
      id: "pending",
      publishToBinaryCache: true,
      cacheEntryIdentity: some(identity))
    let decoded = loweredGraphActionRoundTripForTest(@[action])
    require decoded.len == 1
    check "incomplete binary-cache identity" in
      actionCacheIdentityError(decoded[0])
    expect CacheKeyError:
      discard deriveActionCacheKeyHex(decoded[0])

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
        captureBreadth: mcbOmitAmbientReads,
        suppressMonitorShimSeed: true),
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
      nonDeterminism: ndpEntropyBlessed,
      nonDeterminismJustification: "temp names only",
      requiresElevation: true,
      fixedOutput: true)

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
    # Windows-Build-Correctness M6: the invoked tool's entropy blessing. A
    # lowered-graph cache that dropped it would silently unbless every tool
    # on every warm run -- the direction that costs cache hits rather than
    # correctness, but silently, and the reverse (a codec that read a stale
    # byte as a blessing) is the one that costs correctness.
    check roundTrip.nonDeterminism == ndpEntropyBlessed
    check roundTrip.nonDeterminismJustification == "temp names only"
    check roundTrip.requiresElevation
    # Cache-Scope P3.4: a fixed-output action may be resolved by the portable
    # lookup on its description alone, so the flag must survive a warm build.
    check roundTrip.fixedOutput

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

    # DA-6: the TOOL PACKAGE's capture-breadth declaration must survive the
    # lowered-graph-cache round trip, and the NON-DEFAULT value is what is
    # pinned here because the default is the zero value and a decoder that
    # dropped the byte entirely would still satisfy an assertion on
    # `mcbFullCapture`.
    #
    # WHY IT MATTERS ON A WARM BUILD. `monitorInterest` reads this field, and
    # `monitorEvidenceRequirement` derives the REQUIRED interest from the same
    # answer. A warm build that decoded the wrong value therefore asks io-mon
    # for one set and demands another: decoded too NARROW it refuses its own
    # fresh captures (a cost), and decoded too WIDE it would demand more than
    # the cold build did and re-capture (also a cost). Both are bounded, which
    # is why the v10 version bump refuses a v9 record rather than guessing a
    # byte: the ordinals are not compatible (v9's `captureNonDeterminism =
    # false` is ordinal 0, which reads here as `mcbFullCapture` — the opposite
    # of what that value now spells), and the failure a guess produces is a
    # capture narrowed by nobody's decision.
    #
    # This replaces two assertions on `captureNonDeterminism` / `captureIpc`.
    # `captureIpc` is retired (DA-5 made `mrIpcConnect` ungate-able, so no value
    # of it could be honoured) and `captureNonDeterminism` is now a DSL spelling
    # of this field.
    check roundTrip.dependencyPolicy.captureBreadth == mcbOmitAmbientReads

    # Same argument for the shim-seed opt-out, with a sharper consequence: an
    # edge that must not receive `REPRO_MONITOR_SHIM_LIB` is one that performs
    # library interposition itself, so a warm build that decoded the flag as
    # false would hand it a second interposer and livelock — the failure this
    # flag exists to prevent, reappearing only on cache hits.
    check roundTrip.dependencyPolicy.suppressMonitorShimSeed

  test "an UNBLESSED action round-trips unblessed":
    ## The distinguishing direction for M6. The case above round-trips a
    ## blessing, and a decoder that answered "blessed" unconditionally would
    ## satisfy it while turning every warm-graph action in the tree into a
    ## blessed one — the failure that costs correctness rather than hits.
    let action = BuildAction(
      governingLockIdentity: emptySolvedGraphIdentity("codec-unblessed-test"),
      kind: bakProcess,
      id: "compile-unblessed",
      argv: @["gcc", "-c", "a.c"],
      cacheable: true,
      weakFingerprint: testFingerprint(),
      dependencyPolicy: DependencyGatheringPolicy(
        kind: dgAutomaticMonitor, completeness: decComplete))
    let decoded = loweredGraphActionRoundTripForTest(@[action])
    check decoded.len == 1
    check decoded[0].nonDeterminism == ndpUnblessed
    check decoded[0].nonDeterminismJustification == ""
    # ...and an action that is not fixed-output does not become one.
    check not decoded[0].fixedOutput

  test "rejects the previous cache version instead of decoding without lock identity":
    let action = BuildAction(
      governingLockIdentity: emptySolvedGraphIdentity("codec-version-test"),
      kind: bakStamp,
      id: "codec-version-test")
    var encoded = loweredGraphCacheBytesForTest(@[action])
    let versionOffset = loweredGraphCacheVersionOffsetForTest()
    check encoded[versionOffset] == 11'u8
    check encoded[versionOffset + 1] == 0'u8
    # An older version could not carry the newer per-action fields (v5:
    # `envPassthrough`; v6: the dependency-policy event-interest opt-ins;
    # v8: the dependency-policy shim-seed opt-out; v9: the tool's entropy
    # blessing; v10: the dependency-policy capture-breadth declaration, which
    # REPLACED v6's two bools with one enum byte; v11: the fixed-output
    # sentinel, one byte after the cache identity, whose absence would shift
    # every later field). Decoding such a record under
    # the current layout would silently return defaults for every action rather
    # than failing, so the rejection below is what makes a field's absence
    # impossible instead of invisible.
    #
    # THE POKED VALUE IS THE IMMEDIATELY PRECEDING VERSION, which is what this
    # case's name promises and what v10 specifically needs asserted. v10 is the
    # first bump whose predecessor's bytes could be MISREAD rather than merely
    # come up short: v9 wrote two bool bytes where v10 writes one enum byte, and
    # v9's `captureNonDeterminism = false` — the value almost every edge carried
    # — is ordinal 0, which decodes here as `mcbFullCapture`, the OPPOSITE of
    # what that value now spells. Poking an ancient version instead would leave
    # the one skew that can silently mis-restore a warm edge's capture unasserted
    # by anything.
    encoded[versionOffset] = 10'u8
    var rejected = false
    try:
      discard loweredGraphCacheActionsForTest(encoded)
    except CatchableError as err:
      rejected = true
      check "unsupported lowered graph cache version" in err.msg
    check rejected

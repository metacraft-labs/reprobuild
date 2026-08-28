## Platform-And-Microarchitecture-Constraints PMC-4 — the resolved target is
## IN the cache key, and adding it cost the existing fleet nothing.
##
## Two properties, and the second is why this test is long.
##
## **Separation.** `Binary-Caches.md` §"Cache Entry Identity" states the hard
## invariant: "two entries that are not interchangeable at runtime MUST NOT
## share one cache key". A v3-optimised build and a v2 build of the same
## package at the same version, with the same options, toolchain, closure and
## provider revision, are not interchangeable — the v3 one traps on a v2 host.
## Before PMC-4 they shared a key. So two hosts differing ONLY in
## microarchitecture must derive different keys, and two identical hosts must
## derive the same one, because a key that varied for any other reason would
## be leaking nondeterminism into the fleet's addressing scheme.
##
## **Compatibility.** Every entry the fleet has already published declares no
## floor. A new field in the canonical encoding would have moved every one of
## those keys at once — a mass cache-miss event dressed as a safety fix, and
## the exact hazard PMC-2 and PMC-3 each sidestepped by emitting their new
## field only when non-default. So a level-less identity must encode to the
## SAME BYTES it did before this milestone, and this test pins that with a
## golden hex CAPTURED FROM THE PRE-PMC-4 TREE (`git stash` on `libs/`, derive,
## restore) rather than from the code under test. A golden that the
## implementation generated would agree with any implementation.
##
## The marker deserves its own note. "Emit nothing when default" is not by
## itself a safe extension of a flat length-prefixed format: with the field
## absent the next bytes are `toolchain.name`'s length prefix, so a reader must
## decide what it is looking at from the bytes alone. `MicroarchFieldMarker`
## (`0xFFFFFFFF`) is not a length any string in this encoding can have, which
## makes that decision total and keeps the encoder injective. This test walks
## the round trip through the manifest codec to prove the decoder agrees.
##
## Falsifiable:
##   * drop the `microarch` arm of `encodePlatform` -> separation fails, v2
##     and v3 collapse onto one hex;
##   * make the arm unconditional (emit the empty string too) -> the golden
##     fails, which is the fleet-wide cache-miss event caught at its source;
##   * drop the marker and write a bare string -> the decoder round trip
##     fails, because the reader consumes the floor as `toolchain.name`.
##
## Hermetic: pure value construction. No host read, no network, no store.

import std/[strutils, unittest]

import repro_binary_cache_client/cache_key
import repro_binary_cache_server/types as bcsTypes
import repro_binary_cache_server/key as bcsKey
import repro_binary_cache_server/manifest_codec as bcsCodec
import repro_dsl_stdlib/packages_schema

const LevellessGoldenHex =
  "8a27630aa12dbf6d6653b6c7573ad4a3fcc2844b1d6625a023442178423076d9"
  ## The key `demo 2.0.0` derives on `x86_64-linux-gnu/glibc` with the gcc
  ## 15.2.0 toolchain below and no declared floor.
  ##
  ## **Captured from the tree as it stood before PMC-4**, not from this
  ## implementation: `git stash push -u -- libs/`, derive, `git stash pop`.
  ## That provenance is the whole value of the constant. Every entry in the
  ## fleet today is a level-less entry, so this hex standing still is the
  ## statement that PMC-4 invalidated none of them.

proc triple(microarch = ""): bcsTypes.PlatformTriple =
  bcsTypes.PlatformTriple(cpu: "x86_64", os: "linux", abi: "gnu",
    libcVariant: "glibc", microarch: microarch)

proc identity(microarch = "";
              packageName = "demo";
              packageVersion = "2.0.0"): CacheEntryIdentity =
  newCacheEntryIdentity(
    packageName = packageName,
    packageVersion = packageVersion,
    platform = triple(microarch),
    toolchain = bcsTypes.ToolchainIdentity(name: "gcc", version: "15.2.0",
      hostLdSoAbi: "ld-linux-x86-64.so.2", extraFingerprint: ""),
    providerRevision = "rev-demo")

proc hexOf(microarch = ""): string =
  deriveCacheEntryKeyHex(identity(microarch))

suite "PMC-4 — the cache key separates v2 and v3 artifacts":

  test "t_cache_key_separates_v2_and_v3_artifacts":

    # ---- separation: differ ONLY in microarchitecture -------------------
    #
    # Everything else about these two identities is the same object literal.
    # A difference in the derived key therefore has exactly one possible
    # source, which is what makes this an assertion about the field rather
    # than about the test fixture.
    block twoHostsDifferingOnlyInMicroarchitecture:
      check hexOf("x86-64-v2") != hexOf("x86-64-v3")

    # ---- every level is its own namespace, pairwise ----------------------
    block everyLevelIsDistinct:
      let levels = ["", "x86-64-v1", "x86-64-v2", "x86-64-v3", "x86-64-v4"]
      var seen: seq[string] = @[]
      for lv in levels:
        let h = hexOf(lv)
        check h notin seen
        seen.add(h)

    # ---- the fine axis separates too ------------------------------------
    #
    # PMC-3's point: `avx512vnni` is named by no psABI level, so a build
    # requiring it is not v4 and must not share v4's key.
    block featureSetsAreTheirOwnNamespace:
      check hexOf("x86-64-v3") != hexOf("x86-64-v3+avx512vnni")
      check hexOf("x86-64-v3+avx512vnni") != hexOf("x86-64-v3+avx512vl")
      check hexOf("x86-64-v4") != hexOf("x86-64-v4+avx512vnni")

    # ---- determinism: the target leaks no nondeterminism into the key ----
    #
    # The milestone's acceptance asks for both halves. Two IDENTICAL hosts
    # must produce identical keys, or the addressing scheme is unusable
    # regardless of how well it separates.
    block twoIdenticalHostsAgree:
      for lv in ["", "x86-64-v2", "x86-64-v3+avx512vl,avx512vnni"]:
        check hexOf(lv) == hexOf(lv)
        # Derived twice from two separately-constructed identities, so this
        # is a statement about the encoding and not about caching a string.
        check deriveCacheEntryKeyHex(identity(lv)) ==
              deriveCacheEntryKeyHex(identity(lv))

    # ---- set-literal order does not reach the key -----------------------
    #
    # `renderCpuFeatureTokens` emits in ENUM order, so an author who writes
    # the same requirement in a different order gets the same key. Without
    # that, re-harvesting an unchanged catalog would silently re-key it.
    block featureOrderIsCanonical:
      check renderResolvedTarget(mlX86_64_v3, {cfAvx512vl, cfAvx512f}) ==
            renderResolvedTarget(mlX86_64_v3, {cfAvx512f, cfAvx512vl})
      check hexOf(renderResolvedTarget(mlX86_64_v3,
              {cfAvx512vl, cfAvx512f})) ==
            hexOf(renderResolvedTarget(mlX86_64_v3,
              {cfAvx512f, cfAvx512vl}))

    # ---- THE COMPATIBILITY GUARANTEE ------------------------------------
    #
    # A level-less identity derives the hex it derived before PMC-4 existed.
    # Zero of the 259 checked-in `packages/<tool>.nim` declare `cpu_level` or
    # `cpu_features`, so this one constant covers the whole published fleet.
    block levellessKeysAreByteIdenticalToPrePmc4:
      check hexOf("") == LevellessGoldenHex

    # ---- and the bytes, not merely the digest ---------------------------
    #
    # A digest match is evidence; the byte sequence is the claim. A
    # level-less platform must contribute exactly the four strings it always
    # did — no marker, no empty-string length prefix, nothing.
    block levellessEncodingEmitsNoMicroarchBytes:
      let bare = encodeCacheEntryKey(deriveCacheEntryKey(identity("")))
      let floored =
        encodeCacheEntryKey(deriveCacheEntryKey(identity("x86-64-v3")))
      # The floored encoding is longer by exactly the marker (4 bytes) plus
      # a length-prefixed "x86-64-v3" (4 + 9).
      check floored.len == bare.len + 4 + 4 + "x86-64-v3".len
      # The marker appears in the floored bytes and in no level-less ones.
      var markerBytes: seq[byte] = @[]
      for shift in countup(0, 24, 8):
        markerBytes.add(byte((bcsKey.MicroarchFieldMarker shr
          uint32(shift)) and 0xff'u32))
      check markerBytes == @[0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8]
      var bareHasMarker = false
      for i in 0 .. bare.len - 4:
        if bare[i .. i + 3] == markerBytes:
          bareHasMarker = true
      check not bareHasMarker

    # ---- the decoder agrees, which is what makes the marker sound -------
    #
    # An encoder-only change would pass every block above and still corrupt
    # every manifest on the wire: without the marker the reader consumes the
    # floor string as `toolchain.name` and every field after it shifts.
    block theCodecRoundTripsBothShapes:
      for lv in ["", "x86-64-v1", "x86-64-v3+avx512vl,avx512vnni"]:
        let key = deriveCacheEntryKey(identity(lv))
        let manifest = bcsTypes.BinaryCacheManifest(
          formatVersion: bcsTypes.BinaryCacheFormatVersion,
          entryKey: key,
          payloads: @[],
          relocationPolicy: bcsTypes.rpOptional,
          createdAtUnix: 0)
        let decoded = bcsCodec.decodeManifest(bcsCodec.encodeManifest(manifest))
        check decoded.entryKey.platform.microarch == lv
        # Every field AFTER the optional one survives, which is the
        # property a mis-framed extension destroys.
        check decoded.entryKey.toolchain.name == "gcc"
        check decoded.entryKey.toolchain.version == "15.2.0"
        check decoded.entryKey.toolchain.hostLdSoAbi ==
              "ld-linux-x86-64.so.2"
        check decoded.entryKey.providerRevision == "rev-demo"
        check cacheEntryKeyHex(decoded.entryKey) == deriveCacheEntryKeyHex(
          identity(lv))

    # ---- the target string a resolved arm produces is the one keyed -----
    #
    # `resolvedTargetOf` is the single bridge from a selected `PlatformBinary`
    # to the string the key records. Keying a differently-spelled rendering
    # would separate entries that are in fact interchangeable — a silent
    # cache miss rather than a silent cache hit, but still a defect.
    block theArmsOwnRenderingIsWhatGetsKeyed:
      let v3Arm = initPlatformBinary(cpu = pcX86_64, os = poLinux,
        url = "https://example.invalid/demo-v3.tar.gz",
        sha256 = "3333333333333333333333333333333333333333333333333333333333333333",
        cpu_level = mlX86_64_v3)
      check resolvedTargetOf(v3Arm) == "x86-64-v3"
      check hexOf(resolvedTargetOf(v3Arm)) == hexOf("x86-64-v3")

      let levellessArm = initPlatformBinary(cpu = pcX86_64, os = poLinux,
        url = "https://example.invalid/demo.tar.gz",
        sha256 = "1111111111111111111111111111111111111111111111111111111111111111")
      check resolvedTargetOf(levellessArm) == ""
      check hexOf(resolvedTargetOf(levellessArm)) == LevellessGoldenHex

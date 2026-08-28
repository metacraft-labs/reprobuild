## PMC-6 deliverable 4 — the microarchitecture belongs in the cache KEY, and
## must stay out of the cache NAMESPACE.
##
## ## The question this settles
##
## PMC-6 unifies two cross-ness predicates. Before touching either, it has to
## answer whether a microarchitecture difference needs its own cache
## NAMESPACE, or whether the key alone is enough. Get it wrong in the
## permissive direction and a v3-targeted native tool collides with a
## v1-targeted host artifact; get it wrong in the cautious direction and you
## repartition every namespace in the fleet for nothing.
##
## ## The answer, measured rather than assumed
##
## `PlatformTriple.microarch` is encoded into the DERIVED KEY BYTES
## (`key.nim`, guarded by `MicroarchFieldMarker`), not carried as metadata
## beside it. Two artifacts whose only difference is the microarchitecture
## floor therefore already have different keys — inside one namespace.
##
## So the namespace does NOT need it. `cachePlatformTagFor` partitions on the
## TRIPLE (`dkNative` -> `buildPlatformTriple()`, `dkBuild`/`dkRuntime` ->
## `resolvedTargetTriple()`), and a microarchitecture-only divergence does not
## change either triple. Collapsing to `"native"` in that case stays correct.
##
## **This de-risks PMC-6 substantially, and the earlier spec text was wrong to
## imply otherwise.** Unifying the predicates is not, by itself, a
## cache-repartitioning event — provided the microarchitecture keeps
## travelling in the key.
##
## ## The corollary, which is the part that will actually get broken
##
## The tempting "fix" for the two-predicates inconsistency is to make
## `cachePlatformTagFor` microarchitecture-aware. THAT would repartition every
## namespace in the fleet, and it is unnecessary because the key already
## separates. The last case below pins the tag's independence so that change
## cannot be made silently.

import std/unittest

import repro_binary_cache_client/cache_key
import repro_binary_cache_server/types as bcsTypes
import repro_build_engine/platform as enginePlatform

proc identityWith(microarch: string): CacheEntryIdentity =
  ## One identity, differing only in the microarchitecture floor.
  newCacheEntryIdentity(
    packageName = "demo",
    packageVersion = "2.0.0",
    platform = bcsTypes.PlatformTriple(
      cpu: "x86_64", os: "linux", abi: "gnu", libcVariant: "glibc",
      microarch: microarch),
    toolchain = bcsTypes.ToolchainIdentity(
      name: "gcc", version: "15.2.0",
      hostLdSoAbi: "ld-linux-x86-64.so.2", extraFingerprint: ""),
    providerRevision = "rev-demo")

suite "PMC-6 — microarchitecture is a KEY fact, not a NAMESPACE fact":

  test "a floor changes the derived key":
    # If this ever stops holding, a v3 artifact can be served to a v2 host
    # inside a shared namespace, which is the SIGILL PMC-4 exists to prevent.
    check deriveCacheEntryKeyHex(identityWith("x86-64-v3")) !=
          deriveCacheEntryKeyHex(identityWith(""))

  test "different floors are different keys":
    check deriveCacheEntryKeyHex(identityWith("x86-64-v2")) !=
          deriveCacheEntryKeyHex(identityWith("x86-64-v3"))

  test "features participate too, not only the level":
    # PMC-3 made the level sugar over a feature set; a key that folded only the
    # level would lose a distinction selection can make.
    check deriveCacheEntryKeyHex(identityWith("x86-64-v3")) !=
          deriveCacheEntryKeyHex(identityWith("x86-64-v3+avx512vl"))

  test "no floor keys identically to no floor (determinism)":
    # Without this, the inequalities above could pass for the wrong reason.
    check deriveCacheEntryKeyHex(identityWith("")) ==
          deriveCacheEntryKeyHex(identityWith(""))

  test "the NAMESPACE tag is microarchitecture-independent, by construction":
    # The decision, made executable. `cachePlatformTagFor` takes a DepKind and
    # a triple resolver -- there is no microarchitecture parameter to pass and
    # no ambient one to read, so a floor cannot move a namespace.
    #
    # Adding one would repartition every namespace in the fleet, and would be
    # redundant with the key assertions above. If a future change makes this
    # call microarchitecture-aware, this test should FAIL and the person making
    # it should have to argue for the repartition rather than discover it.
    check cachePlatformTagFor(dkNative) == NativeTriple
    check cachePlatformTagFor(dkBuild) == NativeTriple
    check cachePlatformTagFor(dkRuntime) == NativeTriple

  test "a native build collapses both routes onto one tag":
    # The pre-M9.R.7 compatibility property the namespace scheme rests on: with
    # no target triple resolver, everything is "native" and keys stay
    # byte-identical to what they were before namespacing existed.
    check cachePlatformTagFor(dkNative) == cachePlatformTagFor(dkBuild)
    check cachePlatformTagFor(dkBuild) == cachePlatformTagFor(dkRuntime)

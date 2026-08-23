## Platform-And-Microarchitecture-Constraints PMC-4 — the binary cache does
## not hand a v3-optimised artifact to a v2 host.
##
## **This test is the milestone's reason for existing, and it was written
## before the implementation.** `Package-Model.md` §"Two hazards specific to
## this project" states the failure plainly: a cache key that omits the
## microarchitecture "will serve a v3-optimised binary to a v2 host. The
## failure is ``SIGILL`` at some later instruction, not a resolution error —
## no message, no obvious culprit." A crash inside somebody else's build, with
## nothing pointing back at the substitution that caused it, is not a bug that
## gets diagnosed; it is a bug that gets worked around.
##
## Two independent mechanisms have to hold, and the test asserts BOTH because
## each covers a case the other does not:
##
##   1. **Key separation.** The v3 artifact's cache key differs from the key a
##      v2 host derives, so a v2 host asking the cache for what it needs never
##      names the v3 entry at all. This is the everyday path and it is a pure
##      miss — no diagnostic, and none wanted.
##
##   2. **The compatibility gate.** ``checkCompat`` REFUSES a manifest whose
##      declared floor this host cannot satisfy, naming the shortfall. This is
##      the path key separation cannot cover: an entry key that reached the
##      client from somewhere other than its own derivation — a lock file, a
##      hand-run ``lookup <hex>``, a closure walk following
##      ``depReferences``, or an entry published before its floor was declared
##      — is a key the client did not compute and cannot have separated. The
##      gate runs BEFORE any payload byte is fetched, which is the property
##      ``Binary-Caches.md`` §"Compatibility Checks" already requires of every
##      other platform coordinate; the microarchitecture is simply the
##      coordinate that was missing.
##
## Falsifiable, per mechanism:
##   * delete the ``microarch`` arm of ``encodePlatform`` and (1) fails — the
##     v2 and v3 keys collapse onto one hex;
##   * delete the microarch gate in ``checkCompat`` and (2) fails — the v2
##     host accepts the v3 manifest, which is the ``SIGILL`` verbatim.
##
## Hermetic: synthetic manifests and synthetic hosts. ``LocalPlatform`` is a
## plain value, so naming a v2 or a v3 host costs a field rather than the
## silicon. Nothing here reads the real machine.

import std/[strutils, unittest]

import repro_binary_cache_client/cache_key
import repro_binary_cache_client/compat_check
import repro_binary_cache_client/types as bccTypes
import repro_binary_cache_server/types as bcsTypes

const StoreDir = "/repro/store"

proc triple(microarch: string): bcsTypes.PlatformTriple =
  ## The same platform in every coordinate BUT the microarchitecture, so a
  ## difference in the derived key can only have come from that field.
  bcsTypes.PlatformTriple(cpu: "x86_64", os: "linux", abi: "gnu",
    libcVariant: "glibc", microarch: microarch)

proc host(microarch: string): LocalPlatform =
  LocalPlatform(cpu: "x86_64", os: "linux", abi: "gnu",
    libcVariant: "glibc", microarch: microarch, storeDir: StoreDir)

proc identity(microarch: string): CacheEntryIdentity =
  newCacheEntryIdentity(
    packageName = "demo",
    packageVersion = "2.0.0",
    platform = triple(microarch),
    toolchain = bcsTypes.ToolchainIdentity(name: "gcc", version: "15.2.0",
      hostLdSoAbi: "ld-linux-x86-64.so.2", extraFingerprint: ""),
    providerRevision = "rev-demo")

proc publish(microarch: string): bcsTypes.BinaryCacheManifest =
  ## The producer side: an artifact built against ``microarch``, published
  ## under the key that identity derives.
  bcsTypes.BinaryCacheManifest(
    formatVersion: bcsTypes.BinaryCacheFormatVersion,
    entryKey: deriveCacheEntryKey(identity(microarch)),
    payloads: @[],
    relocationPolicy: bcsTypes.rpOptional,
    createdAtUnix: 0)

suite "PMC-4 — the cache refuses to serve an unsatisfiable floor":

  test "t_cache_refuses_to_serve_an_unsatisfiable_floor":

    # ---- (1) key separation: a v2 host never names the v3 entry ---------
    block v2HostNeverNamesTheV3Entry:
      let v3Key = deriveCacheEntryKeyHex(identity("x86-64-v3"))
      let v2Key = deriveCacheEntryKeyHex(identity("x86-64-v2"))
      check v3Key != v2Key

    # ---- (2) the gate: handed the manifest anyway, the client refuses ---
    #
    # This is the block the milestone exists for. Before PMC-4 the answer
    # here was ``ok = true``: every other coordinate matches, so the client
    # substituted a binary carrying AVX2 onto a host without it.
    block v2HostRefusesTheV3Manifest:
      let manifest = publish("x86-64-v3")
      let verdict = checkCompat(manifest, host("x86-64-v2"), @[],
        enforceTrust = false)
      check not verdict.ok
      # The refusal NAMES the shortfall. A bare "platform mismatch" here
      # would send the reader looking for a missing build for their OS.
      check verdict.reason.contains("x86-64-v3")
      check verdict.reason.contains("x86-64-v2")
      check verdict.reason.contains("microarchitecture")

    # ---- the same manifest on a host that CAN run it is served ----------
    #
    # A gate that refused everything would pass the block above and be
    # worthless. The refusal has to be specific to the shortfall.
    block v3HostIsServed:
      let manifest = publish("x86-64-v3")
      let verdict = checkCompat(manifest, host("x86-64-v3"), @[],
        enforceTrust = false)
      check verdict.ok
      check verdict.reason == ""

    # ---- a host ABOVE the floor is served: this is an ordering ----------
    block v4HostIsServedAV3Artifact:
      let manifest = publish("x86-64-v3")
      let verdict = checkCompat(manifest, host("x86-64-v4"), @[],
        enforceTrust = false)
      check verdict.ok

    # ---- an unstated host is refused a floored artifact -----------------
    #
    # PMC-2's asymmetry, carried to the cache: on the ARTIFACT side "no
    # floor" means "runs anywhere"; on the HOST side it means "unknown",
    # which is NOT v1. Guessing high here is the SIGILL again.
    block unstatedHostIsRefusedAFlooredArtifact:
      let manifest = publish("x86-64-v3")
      let verdict = checkCompat(manifest, host(""), @[], enforceTrust = false)
      check not verdict.ok
      check verdict.reason.contains("x86-64-v3")

    # ---- the compatibility guarantee: a level-less entry is unchanged ---
    #
    # Every entry published before this milestone carries no floor. All of
    # them must still be served, to every host, including one that states
    # nothing — otherwise PMC-4 is a fleet-wide cache-miss event wearing a
    # safety fix's clothes.
    block levellessEntriesAreServedEverywhere:
      let manifest = publish("")
      for h in ["", "x86-64-v1", "x86-64-v2", "x86-64-v3", "x86-64-v4"]:
        let verdict = checkCompat(manifest, host(h), @[], enforceTrust = false)
        check verdict.ok

    # ---- a feature floor no level names is refused too ------------------
    #
    # PMC-3's axis, carried to the cache. ``avx512vnni`` is named by no
    # psABI level, so an ordering alone cannot express this requirement and
    # a v4 host does not automatically satisfy it.
    block featureFloorIsRefusedWhenTheHostLacksIt:
      let manifest = publish("x86-64-v3+avx512vnni")
      let onV4 = checkCompat(manifest, host("x86-64-v4"), @[],
        enforceTrust = false)
      check not onV4.ok
      check onV4.reason.contains("avx512vnni")
      let onV4Plus = checkCompat(manifest, host("x86-64-v4+avx512vnni"), @[],
        enforceTrust = false)
      check onV4Plus.ok

    # ---- an unreadable floor is a REFUSAL, never a pass-through ---------
    #
    # A manifest from a future producer that names a target this client
    # cannot parse must not be substituted. Failing open here would defeat
    # the entire gate the moment the vocabulary grows.
    block unparseableFloorIsRefused:
      let manifest = publish("x86-64-v9")
      let verdict = checkCompat(manifest, host("x86-64-v4"), @[],
        enforceTrust = false)
      check not verdict.ok
      check verdict.reason.contains("x86-64-v9")

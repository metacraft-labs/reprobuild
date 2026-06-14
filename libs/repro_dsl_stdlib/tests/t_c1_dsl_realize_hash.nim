## C1 P4: realize-hash differentiation test for foreign packages.
##
## Verifies the campaign spec § C1 differentiation requirements:
##
##   1. Same (distro, name), different snapshot → different hash.
##   2. Same (name, snapshot), different distro → different hash.
##   3. Same (distro, name, snapshot, version), adding a dep → different
##      hash. Removing a dep → different hash. Reordering deps yields
##      the SAME hash (the closure encoder sorts before hashing).
##   4. Stability: the same catalog with the same inputs produces the
##      SAME hash on two runs (no insertion-order leakage).
##
## The hash is composed via the A3 ``CacheEntryIdentity`` shape from
## ``repro_binary_cache_client/cache_key`` (re-exported through
## ``foreign_common``). This test proves the realize-hash pipeline
## reuses the existing Tier 1 cache-entry-key infrastructure rather
## than inventing a parallel hash plane.

import std/[unittest]

import repro_dsl_stdlib/packages/foreign_apt
import repro_dsl_stdlib/packages/foreign_dnf

proc mkBaseCatalog(distro, name, snapshot, version: string): ForeignCatalog =
  result = ForeignCatalog(
    formatVersion: 1,
    package: mkForeignPackageRef(distro, name, snapshot),
    version: version,
    provisioningMethods: @[
      ForeignProvisioningMethod(
        kind: fpkDirectSnapshotUrl,
        url: "https://example.test/" & name & ".deb",
        sha256: "0000000000000000000000000000000000000000000000000000000000000000",
        sizeBytes: 0,
      )
    ],
    dependencyClosure: @[],
  )

let hostPlatform = PlatformTriple(
  cpu: "x86_64",
  os: "linux",
  abi: "gnu",
  libcVariant: "glibc-2.42")

suite "C1 realize-hash differentiation":

  test "same package, different snapshot → different hash":
    let c1 = mkBaseCatalog("apt", "git",
      "debian/bookworm/20260601T000000Z", "1:2.39.5")
    let c2 = mkBaseCatalog("apt", "git",
      "debian/bookworm/20260801T000000Z", "1:2.39.5")
    let h1 = deriveCacheEntryKeyHex(
      foreignPackageIdentity(c1, hostPlatform))
    let h2 = deriveCacheEntryKeyHex(
      foreignPackageIdentity(c2, hostPlatform))
    check h1 != h2
    check h1.len == 64
    check h2.len == 64

  test "same name, different distro → different hash":
    let cApt = mkBaseCatalog("apt", "git",
      "debian/bookworm/20260601T000000Z", "1:2.39.5")
    let cDnf = mkBaseCatalog("dnf", "git",
      "fedora/39/20260601", "1:2.39.5")
    let hApt = deriveCacheEntryKeyHex(
      foreignPackageIdentity(cApt, hostPlatform))
    let hDnf = deriveCacheEntryKeyHex(
      foreignPackageIdentity(cDnf, hostPlatform))
    check hApt != hDnf

  test "different name → different hash":
    let c1 = mkBaseCatalog("apt", "git",
      "debian/bookworm/20260601T000000Z", "1:2.39.5")
    let c2 = mkBaseCatalog("apt", "curl",
      "debian/bookworm/20260601T000000Z", "1:2.39.5")
    let h1 = deriveCacheEntryKeyHex(
      foreignPackageIdentity(c1, hostPlatform))
    let h2 = deriveCacheEntryKeyHex(
      foreignPackageIdentity(c2, hostPlatform))
    check h1 != h2

  test "adding a dep → different hash; removing → reverts":
    var c = mkBaseCatalog("apt", "git",
      "debian/bookworm/20260601T000000Z", "1:2.39.5")
    let hEmpty = deriveCacheEntryKeyHex(
      foreignPackageIdentity(c, hostPlatform))
    c.dependencyClosure.add mkForeignPackageRef("apt", "libc6",
      "debian/bookworm/20260601T000000Z")
    let hOne = deriveCacheEntryKeyHex(
      foreignPackageIdentity(c, hostPlatform))
    check hEmpty != hOne
    c.dependencyClosure.add mkForeignPackageRef("apt", "libssl3",
      "debian/bookworm/20260601T000000Z")
    let hTwo = deriveCacheEntryKeyHex(
      foreignPackageIdentity(c, hostPlatform))
    check hOne != hTwo
    check hEmpty != hTwo

    # Removing the second dep reverts to the one-dep hash. (Same closure
    # contents → same encoded depClosure bytes → same digest.)
    c.dependencyClosure.setLen(1)
    let hOneAgain = deriveCacheEntryKeyHex(
      foreignPackageIdentity(c, hostPlatform))
    check hOneAgain == hOne

  test "reordering deps yields the same hash":
    var cA = mkBaseCatalog("apt", "git",
      "debian/bookworm/20260601T000000Z", "1:2.39.5")
    var cB = mkBaseCatalog("apt", "git",
      "debian/bookworm/20260601T000000Z", "1:2.39.5")
    let snap = "debian/bookworm/20260601T000000Z"
    cA.dependencyClosure = @[
      mkForeignPackageRef("apt", "libc6", snap),
      mkForeignPackageRef("apt", "libssl3", snap),
      mkForeignPackageRef("apt", "zlib1g", snap),
    ]
    cB.dependencyClosure = @[
      mkForeignPackageRef("apt", "zlib1g", snap),
      mkForeignPackageRef("apt", "libc6", snap),
      mkForeignPackageRef("apt", "libssl3", snap),
    ]
    let hA = deriveCacheEntryKeyHex(
      foreignPackageIdentity(cA, hostPlatform))
    let hB = deriveCacheEntryKeyHex(
      foreignPackageIdentity(cB, hostPlatform))
    check hA == hB

  test "deterministic: same inputs → same hash on repeat invocation":
    let c = mkBaseCatalog("apt", "git",
      "debian/bookworm/20260601T000000Z", "1:2.39.5")
    let h1 = deriveCacheEntryKeyHex(
      foreignPackageIdentity(c, hostPlatform))
    let h2 = deriveCacheEntryKeyHex(
      foreignPackageIdentity(c, hostPlatform))
    let h3 = deriveCacheEntryKeyHex(
      foreignPackageIdentity(c, hostPlatform))
    check h1 == h2
    check h2 == h3

  test "providerRevision is part of the hash":
    let c = mkBaseCatalog("apt", "git",
      "debian/bookworm/20260601T000000Z", "1:2.39.5")
    let hPlaceholder = deriveCacheEntryKeyHex(
      foreignPackageIdentity(c, hostPlatform,
        providerRevision = "c1-placeholder"))
    let hReal = deriveCacheEntryKeyHex(
      foreignPackageIdentity(c, hostPlatform,
        providerRevision = "abcdef0123456789abcdef0123456789"))
    check hPlaceholder != hReal

  test "version is part of the hash":
    let c1 = mkBaseCatalog("apt", "git",
      "debian/bookworm/20260601T000000Z", "1:2.39.5-0+deb12u1")
    let c2 = mkBaseCatalog("apt", "git",
      "debian/bookworm/20260601T000000Z", "1:2.39.5-0+deb12u2")
    let h1 = deriveCacheEntryKeyHex(
      foreignPackageIdentity(c1, hostPlatform))
    let h2 = deriveCacheEntryKeyHex(
      foreignPackageIdentity(c2, hostPlatform))
    check h1 != h2

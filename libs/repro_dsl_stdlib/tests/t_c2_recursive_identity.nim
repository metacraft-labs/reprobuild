## C2 P4 validation: prove the recursive ``foreignPackageIdentity``
## composer replaces C1's synthetic mixer with real BLAKE3-derived
## per-dep digests, AND the on-disk resolver recurses correctly.

import std/[options, os, strutils, tempfiles, unittest]

import repro_dsl_stdlib/packages/foreign_apt

let hostPlatform = PlatformTriple(
  cpu: "x86_64",
  os: "linux",
  abi: "gnu",
  libcVariant: "glibc-2.42")

# A thread-local catalog root + a gcsafe resolver pointing at it. The
# test mutates this variable between cases instead of capturing the
# tempdir in a closure (which would require {.gcsafe.} access to a
# GC'd local, refused by Nim's effect system).
var catalogRootGlobal* {.threadvar.}: string

proc tempCatalogResolver*(depRef: PackageRef): Option[ForeignCatalog]
    {.gcsafe.} =
  {.gcsafe.}:
    if catalogRootGlobal.len == 0:
      return none(ForeignCatalog)
    let p = catalogRootGlobal / depRef.distro &
      DirSep & depRef.name & ".json"
    if fileExists(p):
      return some(readForeignCatalog(p))
    none(ForeignCatalog)

proc mkCat(name: string; deps: openArray[string] = []): ForeignCatalog =
  result = ForeignCatalog(
    formatVersion: 1,
    package: mkForeignPackageRef("apt", name,
      "debian/bookworm/20260601T000000Z"),
    version: "1.0",
    provisioningMethods: @[
      ForeignProvisioningMethod(
        kind: fpkDirectSnapshotUrl,
        url: "https://example.test/" & name & ".deb",
        sha256: "0000000000000000000000000000000000000000000000000000000000000000",
        sizeBytes: 0)],
    dependencyClosure: @[],
  )
  for d in deps:
    result.dependencyClosure.add mkForeignPackageRef("apt", d,
      "debian/bookworm/20260601T000000Z")

suite "C2 P4 recursive identity composer":

  test "noop resolver returns leaf BLAKE3 (no longer the C1 mixer)":
    let cat = mkCat("git", ["libc6", "zlib1g"])
    let idy = foreignPackageIdentity(cat, hostPlatform,
      resolver = noopDepResolver)
    # The leaf BLAKE3 hex MUST differ for distinct deps:
    check idy.depClosure.len == 2
    check idy.depClosure[0] != idy.depClosure[1]
    # Hex shape check: 64 lowercase hex chars.
    for hex in idy.depClosure:
      check hex.len == 64
      for ch in hex:
        check ch in {'0'..'9', 'a'..'f'}
    # And the leaf BLAKE3 is sensitive to (distro, name, snapshot):
    # changing the snapshot must produce a different leaf hex.
    var cat2 = cat
    cat2.dependencyClosure[0] = mkForeignPackageRef("apt", "libc6",
      "debian/bookworm/20260801T000000Z")
    let idy2 = foreignPackageIdentity(cat2, hostPlatform,
      resolver = noopDepResolver)
    check idy.depClosure[0] != idy2.depClosure[0]

  test "on-disk resolver derives real recursive CacheEntryKey":
    let dir = createTempDir("c2-resolv-", "")
    let aptDir = dir / "apt"
    createDir(aptDir)
    # Write libc6 + zlib1g + git catalogs.
    writeForeignCatalog(mkCat("libc6"), aptDir / "libc6.json")
    writeForeignCatalog(mkCat("zlib1g"), aptDir / "zlib1g.json")
    let git = mkCat("git", ["libc6", "zlib1g"])
    writeForeignCatalog(git, aptDir / "git.json")

    catalogRootGlobal = dir
    let resolver: ForeignDepResolver = tempCatalogResolver

    # Compose git's identity through the resolver. Each dep's hex must
    # equal the standalone identity hex of that dep.
    let gitIdyRecursive = foreignPackageIdentity(git, hostPlatform,
      resolver = resolver)
    let gitIdyLeaf = foreignPackageIdentity(git, hostPlatform,
      resolver = noopDepResolver)
    # The recursive composer's dep hex MUST differ from the leaf form
    # (because the recursive form passes through deriveCacheEntryKeyHex
    # for each dep, while the leaf form is the leaf-BLAKE3 of the
    # PackageRef alone).
    check gitIdyRecursive.depClosure != gitIdyLeaf.depClosure
    # Each recursive dep hex matches the standalone identity of that
    # dep through the same resolver (recursion is consistent). To
    # match the recursive composer's per-dep computation, we feed the
    # dep's own canonical providerRevision — the recursive composer
    # uses ``blake3(serializeCatalog(depCatalog))`` for each dep, and
    # we mirror that here via ``canonicalCatalogProviderRevision``.
    let libc6Cat = mkCat("libc6")
    let libc6Prov = canonicalCatalogProviderRevision(libc6Cat)
    let libc6Idy = foreignPackageIdentity(libc6Cat, hostPlatform,
      providerRevision = libc6Prov,
      resolver = resolver)
    let libc6Hex = deriveCacheEntryKeyHex(libc6Idy)
    check libc6Hex in gitIdyRecursive.depClosure
    removeDir(dir)
    catalogRootGlobal = ""

  test "canonicalCatalogProviderRevision is byte-stable + 64 hex":
    let cat = mkCat("git", ["libc6"])
    let r1 = canonicalCatalogProviderRevision(cat)
    let r2 = canonicalCatalogProviderRevision(cat)
    check r1 == r2
    check r1.len == 64
    for ch in r1:
      check ch in {'0'..'9', 'a'..'f'}

  test "canonicalCatalogProviderRevision is independent of signed_envelope":
    let cat = mkCat("git", ["libc6"])
    let r1 = canonicalCatalogProviderRevision(cat)
    var withSig = cat
    withSig.signedEnvelope = some(ForeignSignedEnvelope(
      digestHex: r1,
      signatureHex: "feedface" & "00".repeat(60),
      signerKeyId: "test"))
    let r2 = canonicalCatalogProviderRevision(withSig)
    check r1 == r2

  test "cycle-protection: A -> B -> A does not infinite-loop":
    # Cycles shouldn't occur in apt closures but the composer must
    # tolerate them via the visited-set guard.
    let dir = createTempDir("c2-cyc-", "")
    let aptDir = dir / "apt"
    createDir(aptDir)
    writeForeignCatalog(mkCat("a", ["b"]), aptDir / "a.json")
    writeForeignCatalog(mkCat("b", ["a"]), aptDir / "b.json")
    catalogRootGlobal = dir
    let aCat = readForeignCatalog(aptDir / "a.json")
    let idy = foreignPackageIdentity(aCat, hostPlatform,
      resolver = tempCatalogResolver)
    check idy.depClosure.len == 1
    removeDir(dir)
    catalogRootGlobal = ""

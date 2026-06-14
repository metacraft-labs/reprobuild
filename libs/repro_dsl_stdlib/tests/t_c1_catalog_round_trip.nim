## C1 P4: catalog file write→read round-trip + byte-identical
## reserialization test.
##
## Exercises the campaign spec § C1 ``t_c1_catalog_round_trip.nim``
## requirement:
##
##   * Build a ForeignCatalog for ``git-from-debian-bookworm-snapshot-
##     20260601``. Write it to disk. Read it back. The two values are
##     equal field-for-field.
##   * Serialize the read-back catalog → bytes match the originally-
##     written bytes (the C2 harvester's idempotency requirement; bytes
##     are sorted-key JSON terminated by a trailing newline).
##   * Adding a dep closure and writing again still produces sorted-key
##     output regardless of insertion order — the
##     ``serializeCatalog`` sort is performed before encoding.
##   * The signed_envelope round-trip works for both the unset
##     (``signed_envelope: null``) and set cases.

import std/[options, os, strutils, tempfiles, unittest]

import repro_dsl_stdlib/packages/foreign_apt

proc mkGitCatalog(): ForeignCatalog =
  ForeignCatalog(
    formatVersion: 1,
    package: mkForeignPackageRef("apt", "git",
      "debian/bookworm/20260601T000000Z"),
    version: "1:2.39.5-0+deb12u2",
    provisioningMethods: @[
      ForeignProvisioningMethod(
        kind: fpkDirectSnapshotUrl,
        url: "https://snapshot.debian.org/archive/debian/" &
          "20260601T000000Z/pool/main/g/git/git_2.39.5-0+deb12u2_amd64.deb",
        sha256: "deadbeefcafef00d0123456789abcdef" &
          "deadbeefcafef00d0123456789abcdef",
        sizeBytes: 10485760'i64,
      )
    ],
    dependencyClosure: @[],
    signedEnvelope: none(ForeignSignedEnvelope),
  )

suite "C1 catalog round-trip":

  test "write→read recovers all fields":
    let c = mkGitCatalog()
    let dir = createTempDir("c1-rt-", "")
    let p = dir / "git.json"
    writeForeignCatalog(c, p)
    let r = readForeignCatalog(p)
    check r.formatVersion == c.formatVersion
    check r.package.tier == c.package.tier
    check r.package.distro == c.package.distro
    check r.package.name == c.package.name
    check r.package.snapshot == c.package.snapshot
    check r.version == c.version
    check r.provisioningMethods.len == c.provisioningMethods.len
    check r.provisioningMethods[0].kind == c.provisioningMethods[0].kind
    check r.provisioningMethods[0].url == c.provisioningMethods[0].url
    check r.provisioningMethods[0].sha256 == c.provisioningMethods[0].sha256
    check r.provisioningMethods[0].sizeBytes == c.provisioningMethods[0].sizeBytes
    check r.dependencyClosure.len == 0
    check r.signedEnvelope.isNone
    removeDir(dir)

  test "reserialization is byte-identical":
    let c = mkGitCatalog()
    let dir = createTempDir("c1-rt-bytes-", "")
    let p = dir / "git.json"
    writeForeignCatalog(c, p)
    let originalBytes = readFile(p)
    let r = readForeignCatalog(p)
    let roundTripBytes = serializeCatalog(r)
    check originalBytes == roundTripBytes
    removeDir(dir)

  test "dep closure round-trips + insertion order does not perturb output":
    var c = mkGitCatalog()
    let snap = "debian/bookworm/20260601T000000Z"
    # Insert in reverse-alphabetical order
    c.dependencyClosure = @[
      mkForeignPackageRef("apt", "zlib1g", snap),
      mkForeignPackageRef("apt", "libssl3", snap),
      mkForeignPackageRef("apt", "libc6", snap),
    ]
    let s1 = serializeCatalog(c)
    # Insert in alphabetical order
    c.dependencyClosure = @[
      mkForeignPackageRef("apt", "libc6", snap),
      mkForeignPackageRef("apt", "libssl3", snap),
      mkForeignPackageRef("apt", "zlib1g", snap),
    ]
    let s2 = serializeCatalog(c)
    check s1 == s2

    # Read it back and confirm the deps are present in sorted order.
    let r = readForeignCatalogFromString(s1)
    check r.dependencyClosure.len == 3
    check r.dependencyClosure[0].name == "libc6"
    check r.dependencyClosure[1].name == "libssl3"
    check r.dependencyClosure[2].name == "zlib1g"

  test "signed envelope round-trips":
    var c = mkGitCatalog()
    c.signedEnvelope = some(ForeignSignedEnvelope(
      digestHex: "0123456789abcdef0123456789abcdef" &
        "0123456789abcdef0123456789abcdef",
      signatureHex: "feedface" & "00".repeat(60),
      signerKeyId: "debian-archive-12"))
    let s = serializeCatalog(c)
    let r = readForeignCatalogFromString(s)
    check r.signedEnvelope.isSome
    check r.signedEnvelope.get.digestHex == c.signedEnvelope.get.digestHex
    check r.signedEnvelope.get.signatureHex == c.signedEnvelope.get.signatureHex
    check r.signedEnvelope.get.signerKeyId == c.signedEnvelope.get.signerKeyId

    # And a second round-trip is byte-identical.
    check s == serializeCatalog(r)

  test "output is sorted-key JSON ending in a trailing newline":
    let c = mkGitCatalog()
    let s = serializeCatalog(c)
    check s.endsWith("\n")
    # Sorted-key check: ``dependency_closure`` appears before
    # ``format_version`` before ``package`` before ``provisioning_methods``
    # before ``signed_envelope`` at the top level.
    let iDeps = s.find("\"dependency_closure\":")
    let iFmt = s.find("\"format_version\":")
    let iPkg = s.find("\"package\":")
    let iProv = s.find("\"provisioning_methods\":")
    let iSigEnv = s.find("\"signed_envelope\":")
    check iDeps >= 0
    check iFmt > iDeps
    check iPkg > iFmt
    check iProv > iPkg
    check iSigEnv > iProv

  test "all three sample catalogs round-trip byte-identically":
    const RecipesRoot =
      currentSourcePath.parentDir.parentDir.parentDir.parentDir /
        "recipes" / "catalog" / "foreign"
    for relpath in ["apt/git.json", "dnf/htop.json", "pacman/neovim.json"]:
      let path = RecipesRoot / relpath
      check fileExists(path)
      let originalBytes = readFile(path)
      let r = readForeignCatalogFromString(originalBytes)
      let roundTripBytes = serializeCatalog(r)
      check roundTripBytes == originalBytes

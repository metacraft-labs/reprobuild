## The apt-jammy adapter's store identity is keyed by the bytes it installs,
## not by the snapshot string or the package names the caller asked for.
##
## Regression and attack test for
## ``reprobuild-pm/issues/2026-11-12-apt-adapter-the-snapshot-string-is-not-a-trust-root-inrelease-is-never-signature-checked.md``
## (spec: ``reprobuild-pm/spec/External-Package-Catalog-Adapters.md`` §2
## "apt.extract", §3 "Idempotency and content-addressing", §6 "Snapshot pin
## semantics").
##
## The issue's threat: the snapshot string ``ubuntu/jammy/<ts>`` names no
## digest, so any mirror the snapshot is resolved through can serve
## different ``.deb`` bytes for the same (snapshot, package-name) request.
## Each host's registry is internally consistent (the ``.deb`` matches the
## sha256 that host was given), so per-``.deb`` verification passes on both.
## If the store path is derived from the snapshot and the names, two hosts —
## or one host fed first by an honest mirror and then by a hostile one —
## hold DIFFERENT bytes under the SAME ``<storeRoot>/<hash>``, which poisons
## any store or cache shared by that hash. The cases below are written from
## the attacker's side: each one is a request the hostile actor controls,
## and the assertion is that it cannot reach or overwrite the honest path.
##
## The same issue names three more defects in the identity, each with a case:
##   * no field framing — two different requests whose fields concatenate to
##     the same string must not share an identity;
##   * truncation to 16 hex chars (64 bits; a collision costs ~2^32 work) —
##     identities must be full SHA-256 (64 hex chars);
##   * ``expectedFiles`` inside the identity — tightening an assertion that
##     holds must not fork identical content into a new path, and the
##     assertion must still be checked when an existing path is reused.
##
## No mocks, stubs or fakes are used. Every case calls the production procs
## (``installAptDeb``, ``extractAptDeb``, ``installSystemdUnit``) on real
## ``.deb`` archives written to a real temporary directory, extracted by the
## real host ``tar``, and asserts on the real store tree those procs leave
## behind. The archives are assembled byte-for-byte by
## ``apt_deb_fixture_builder.nim`` (a plain ``data.tar`` member, so only a
## host ``tar`` is needed), which is the only test-side code between the
## assertions and the adapter.

import std/[algorithm, os, strutils, tempfiles, unittest]

import repro_dsl_stdlib/packages/apt_jammy
import ./apt_deb_fixture_builder

const
  # One snapshot pin for every case that is not ABOUT the snapshot: the
  # hostile mirror is reached through the same pin as the honest one.
  PinnedSnapshot = "ubuntu/jammy/20260615T000000Z"

  # The single file every fixture ships. The honest and the hostile archive
  # put DIFFERENT bytes at the SAME path under the SAME package name, which
  # is exactly what a substituted ``.deb`` looks like to the adapter.
  LibPath = "usr/lib/x86_64-linux-gnu/libreprofixture.so.1"
  HonestBytes = "honest library bytes, as published in the archive\n"
  HostileBytes = "hostile library bytes, served by a substituting mirror\n"

  PackageName = "libreprofixture1"
  PackageVersion = "1.0-1"

type Fixture = object
  debPath: string
  sha256: string

proc writeFixture(root, fileName, dataPath, dataBytes: string): Fixture =
  ## Write a one-file ``.deb`` under ``root`` and return it with the sha256
  ## of its bytes: the digest a registry consistent with THAT archive would
  ## carry, so per-``.deb`` verification succeeds for it.
  let dir = root / "debs"
  createDir(dir)
  result.debPath = dir / fileName
  writeFile(result.debPath, debArchiveBytes(dataPath, dataBytes, ddcPlain))
  result.sha256 = sha256OfFile(result.debPath)

proc source(fx: Fixture; name = PackageName;
            version = PackageVersion): AptDebSource =
  AptDebSource(name: name, version: version, debPath: fx.debPath,
               sha256: fx.sha256)

proc storeEntries(storeRoot: string): seq[string] =
  ## The names directly under ``storeRoot``, sorted: the set of store
  ## identities that exist.
  for kind, path in walkDir(storeRoot, relative = true):
    result.add(path)
  result.sort()

proc isFullSha256Hex(s: string): bool =
  ## 64 lowercase hex characters: an untruncated SHA-256 digest (256 bits,
  ## comfortably above the issue's 160-bit floor).
  s.len == 64 and s.allCharsInSet({'0' .. '9', 'a' .. 'f'})

suite "apt install store identity is byte-keyed":

  test "hostile mirror: same snapshot and package name, different .deb bytes land at different store paths":
    let root = createTempDir("apt_ident_hostile_", "")
    defer: removeDir(root)
    let storeRoot = root / "store"
    createDir(storeRoot)
    let honest = writeFixture(root, "honest.deb", LibPath, HonestBytes)
    let hostile = writeFixture(root, "hostile.deb", LibPath, HostileBytes)
    require honest.sha256 != hostile.sha256

    # Host 1 (or the first resolution) is served the honest archive.
    let a = installAptDeb(snapshot = PinnedSnapshot,
                          debs = @[honest.source()],
                          storeRoot = storeRoot)
    require readFile(a.tree(LibPath)) == HonestBytes

    # The hostile mirror answers the SAME request — same pin, same package
    # name, same claimed version — with different bytes, and a registry
    # whose sha256 matches them, so verification passes.
    let b = installAptDeb(snapshot = PinnedSnapshot,
                          debs = @[hostile.source()],
                          storeRoot = storeRoot)

    # The two byte sets must not share an identity ...
    check a.storePath != b.storePath
    # ... and the honest path must still hold the honest bytes: the second
    # request may not have replaced them in place.
    check readFile(a.tree(LibPath)) == HonestBytes
    check readFile(b.tree(LibPath)) == HostileBytes

  test "the same .deb bytes reached under two snapshot strings share one store path":
    # The snapshot string is provenance, not identity: a package unchanged
    # between two snapshots is the same content and must be stored once.
    let root = createTempDir("apt_ident_snapshots_", "")
    defer: removeDir(root)
    let storeRoot = root / "store"
    createDir(storeRoot)
    let honest = writeFixture(root, "honest.deb", LibPath, HonestBytes)

    let a = installAptDeb(snapshot = "ubuntu/jammy/20260101T000000Z",
                          debs = @[honest.source()],
                          storeRoot = storeRoot)
    let b = installAptDeb(snapshot = "ubuntu/jammy/20260615T000000Z",
                          debs = @[honest.source()],
                          storeRoot = storeRoot)
    check a.storePath == b.storePath
    check readFile(b.tree(LibPath)) == HonestBytes

  test "framing: requests whose snapshot and name concatenate equally do not collide":
    # Unframed, ("s", ["ab"]) and ("sa", ["b"]) both serialise to "...sab...".
    # Two different package names are two different identities whatever
    # snapshot string precedes them.
    let root = createTempDir("apt_ident_frame_snap_", "")
    defer: removeDir(root)
    let storeRoot = root / "store"
    createDir(storeRoot)
    let honest = writeFixture(root, "honest.deb", LibPath, HonestBytes)

    let a = installAptDeb(snapshot = "s", debs = @[honest.source(name = "ab")],
                          storeRoot = storeRoot)
    let b = installAptDeb(snapshot = "sa", debs = @[honest.source(name = "b")],
                          storeRoot = storeRoot)
    check a.storePath != b.storePath
    check a.debs[0].name == "ab"
    check b.debs[0].name == "b"

  test "framing: triples whose name and version concatenate equally do not collide":
    # ("ab", "c", sha) and ("a", "bc", sha) are different resolved packages;
    # a fingerprint that concatenated name and version without a length
    # prefix would give them one store path.
    let root = createTempDir("apt_ident_frame_triple_", "")
    defer: removeDir(root)
    let storeRoot = root / "store"
    createDir(storeRoot)
    let honest = writeFixture(root, "honest.deb", LibPath, HonestBytes)

    let a = installAptDeb(snapshot = PinnedSnapshot,
                          debs = @[honest.source(name = "ab", version = "c")],
                          storeRoot = storeRoot)
    let b = installAptDeb(snapshot = PinnedSnapshot,
                          debs = @[honest.source(name = "a", version = "bc")],
                          storeRoot = storeRoot)
    check a.storePath != b.storePath

  test "width: every store path name is a full 64-hex SHA-256 digest":
    let root = createTempDir("apt_ident_width_", "")
    defer: removeDir(root)
    let storeRoot = root / "store"
    createDir(storeRoot)
    let honest = writeFixture(root, "honest.deb", LibPath, HonestBytes)
    let unitDeb = writeFixture(root, "unit.deb",
      "lib/systemd/system/reprofixture.service",
      "[Service]\nType=oneshot\nExecStart=/usr/bin/true\n")

    let installed = installAptDeb(snapshot = PinnedSnapshot,
                                  debs = @[honest.source()],
                                  storeRoot = storeRoot)
    let extracted = extractAptDeb(debPath = honest.debPath,
                                  sha256 = honest.sha256,
                                  storeRoot = storeRoot)
    let unitSrc = extractAptDeb(debPath = unitDeb.debPath,
                                sha256 = unitDeb.sha256,
                                storeRoot = storeRoot)
    let unit = installSystemdUnit(unit = unitSrc,
                                  unitName = "reprofixture.service",
                                  storeRoot = storeRoot)

    check isFullSha256Hex(installed.storePath.extractFilename)
    check isFullSha256Hex(extracted.storePath.extractFilename)
    check isFullSha256Hex(unit.storePath.extractFilename)

  test "expectedFiles: adding an assertion that holds does not fork the store path":
    let root = createTempDir("apt_ident_ef_same_", "")
    defer: removeDir(root)
    let storeRoot = root / "store"
    createDir(storeRoot)
    let honest = writeFixture(root, "honest.deb", LibPath, HonestBytes)

    let unasserted = installAptDeb(snapshot = PinnedSnapshot,
                                   debs = @[honest.source()],
                                   storeRoot = storeRoot)
    let asserted = installAptDeb(snapshot = PinnedSnapshot,
                                 debs = @[honest.source()],
                                 expectedFiles = @[LibPath],
                                 storeRoot = storeRoot)
    check unasserted.storePath == asserted.storePath

  test "expectedFiles: a failing assertion raises on the reuse path too":
    # The first call creates and completes the store path. The second asks
    # for the same bytes with an assertion that does not hold: it must
    # reach the existing path AND still fail, not return the cached path
    # unchecked.
    let root = createTempDir("apt_ident_ef_reuse_", "")
    defer: removeDir(root)
    let storeRoot = root / "store"
    createDir(storeRoot)
    let honest = writeFixture(root, "honest.deb", LibPath, HonestBytes)

    let first = installAptDeb(snapshot = PinnedSnapshot,
                              debs = @[honest.source()],
                              expectedFiles = @[LibPath],
                              storeRoot = storeRoot)
    require dirExists(first.storePath)
    let entriesBefore = storeEntries(storeRoot)

    expect AptExpectedFileMissing:
      discard installAptDeb(
        snapshot = PinnedSnapshot,
        debs = @[honest.source()],
        expectedFiles = @[LibPath, "usr/lib/x86_64-linux-gnu/not-shipped.so"],
        storeRoot = storeRoot)

    # The failing call reached the EXISTING path: it did not mint a second
    # identity for the same bytes (which is how an identity that contains
    # ``expectedFiles`` would make this assertion fail without ever taking
    # the reuse path).
    check storeEntries(storeRoot) == entriesBefore
    # A failed assertion is the caller's error, not a defect in the stored
    # bytes: the completed path is left intact for callers whose assertions
    # hold.
    check readFile(first.tree(LibPath)) == HonestBytes

  test "one request naming the same package twice with different bytes is refused":
    # Without this, the later archive is extracted over the earlier one in
    # the same store path, and which bytes win depends on sort order.
    let root = createTempDir("apt_ident_dup_", "")
    defer: removeDir(root)
    let storeRoot = root / "store"
    createDir(storeRoot)
    let honest = writeFixture(root, "honest.deb", LibPath, HonestBytes)
    let hostile = writeFixture(root, "hostile.deb", LibPath, HostileBytes)

    expect AptAdapterError:
      discard installAptDeb(snapshot = PinnedSnapshot,
                            debs = @[honest.source(), hostile.source()],
                            storeRoot = storeRoot)

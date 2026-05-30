## M69 — catalog_lookup.nim: resolve a PackageReference to a
## VersionedProvisioning slice (or fail closed).
##
## Two flavours of test:
##
## 1. Fixture catalog (a `seq[VersionedProvisioning]` built inline)
##    exercising the resolver's `selectDefault` / `selectVersion`
##    branches plus the well-formed-version pin gate. This isolates
##    the resolver from the catalog registry so the test pins the
##    contract independently of the registered tool list.
## 2. Live registry calls against `jdk` (the M63 reference catalog)
##    — bare reference resolves to the catalog's defaultVersion;
##    a missing version raises `EVersionNotInCatalog`; an
##    unregistered tool raises `EUnknownPackageId`.

import std/unittest

import repro_dsl_stdlib/packages_schema
import repro_dsl_stdlib/catalog_registry
import repro_home_apply/catalog_lookup

proc fixturePlatform(version: string): seq[PlatformBinary] =
  result.add initPlatformBinary(
    cpu = pcX86_64, os = poWindows,
    url = "https://example.invalid/jdk-" & version & ".zip",
    sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
    extract_path = "jdk-" & version)

proc fixtureCatalog(): seq[VersionedProvisioning] =
  # Newest-first per the M63 convention (the last entry is the
  # `defaultVersion`). The resolver respects the array order via
  # `selectDefault` (which returns the LAST entry).
  result.add initVersionedProvisioning(
    version = "21.0.5",
    archive_format = afZip,
    install_method = imExtract,
    bin_relpath = @["bin/javac.exe", "bin/java.exe"],
    platforms = fixturePlatform("21.0.5"),
    env = [("JAVA_HOME", "${prefix}")])
  result.add initVersionedProvisioning(
    version = "17.0.13",
    archive_format = afZip,
    install_method = imExtract,
    bin_relpath = @["bin/javac.exe", "bin/java.exe"],
    platforms = fixturePlatform("17.0.13"),
    env = [("JAVA_HOME", "${prefix}")])
  result.add initVersionedProvisioning(
    version = "11.0.25",
    archive_format = afZip,
    install_method = imExtract,
    bin_relpath = @["bin/javac.exe", "bin/java.exe"],
    platforms = fixturePlatform("11.0.25"),
    env = [("JAVA_HOME", "${prefix}")])

suite "M69 catalog_lookup":

  test "fixture catalog: pinned `21.0.5` resolves to that exact slice":
    let cat = fixtureCatalog()
    let pick = selectVersion(cat, "21.0.5")
    check pick.found
    check pick.entry.version == "21.0.5"
    # The lookup proc wraps this; we re-verify the wrapping below
    # via the live `jdk` registry path so this branch focuses on
    # `selectVersion` behavior in isolation.

  test "fixture catalog: pinned `17.0.13` resolves to the 17.x slice":
    let cat = fixtureCatalog()
    let pick = selectVersion(cat, "17.0.13")
    check pick.found
    check pick.entry.version == "17.0.13"

  test "fixture catalog: bare reference picks the LAST entry per M63 convention":
    let cat = fixtureCatalog()
    let pick = selectDefault(cat)
    check pick.found
    # `selectDefault` returns the LAST entry — which in our newest-
    # first fixture is `11.0.25`. The harvested production catalogs
    # are also newest-first, but a tool author writing a hand-rolled
    # catalog could intentionally surface a different default.
    check pick.entry.version == "11.0.25"

  test "fixture catalog: unknown version `999.0.0` returns no match":
    let cat = fixtureCatalog()
    let miss = selectVersion(cat, "999.0.0")
    check (not miss.found)

  test "lookup proc: registered tool + valid version resolves":
    # The jdk catalog ships in M63 with version 21.0.5. The lookup
    # proc returns the slice + the resolved version (== the
    # requested version for an exact pin).
    let s = lookupCatalogSlice("jdk", "21.0.5")
    check s.packageId == "jdk"
    check s.requestedVersion == "21.0.5"
    check s.resolvedVersion == "21.0.5"
    check s.slice.bin_relpath.len > 0

  test "lookup proc: bare reference resolves to defaultVersion":
    let s = lookupCatalogSlice("jdk")
    check s.packageId == "jdk"
    check s.requestedVersion == ""
    check s.resolvedVersion.len > 0

  test "lookup proc: missing version raises EVersionNotInCatalog":
    var raised = false
    try:
      discard lookupCatalogSlice("jdk", "999.0.0")
    except EVersionNotInCatalog as err:
      raised = true
      check err.packageId == "jdk"
      check err.requestedVersion == "999.0.0"
      check err.availableVersions.len > 0
    check raised

  test "lookup proc: unknown package id raises EUnknownPackageId":
    var raised = false
    try:
      discard lookupCatalogSlice("nonexistent-tool-xyz")
    except EUnknownPackageId as err:
      raised = true
      check err.packageId == "nonexistent-tool-xyz"
      check err.registered.len > 0
    check raised

  test "lookup proc: malformed version rejected as not-in-catalog":
    # A version string containing shell metacharacters does NOT pass
    # the well-formed-pin guard; the resolver treats it as a miss
    # rather than smuggling the bad bytes into the realize loop.
    var raised = false
    try:
      discard lookupCatalogSlice("jdk", "21.0.5; rm -rf /")
    except EVersionNotInCatalog:
      raised = true
    check raised

  test "registered tool names snapshot is non-empty":
    check registeredToolNames().len >= 1
    check "jdk" in registeredToolNames()

  test "latestCatalogVersion returns the highest-SemVer slice":
    let latest = latestCatalogVersion("jdk")
    check latest.found
    check latest.version.len > 0

  test "latestCatalogVersion returns false for unregistered tool":
    let latest = latestCatalogVersion("nonexistent-tool-xyz")
    check (not latest.found)

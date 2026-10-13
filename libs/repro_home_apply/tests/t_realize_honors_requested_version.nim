## M1 (Realize-Layer-Plumbing-Closures) → GM4b gate: the realize side honours
## a version-pinned profile reference.
##
## Pre-M1 `realizePlannedPackages` dropped `PlannedPackage.requestedVersion`;
## M1 threaded it into the (since removed) adapter chain. GM4b: the pin is
## part of the selection request (Provisioning-Contributions.md §"Profile
## Package References" → Selection), so the realized prefix is the archive of
## exactly the pinned version. Contract, restated:
##
##   1. ``test_m1_realize_threads_requested_version_to_chain_resolve`` — a
##      pin on the SECOND declared version realizes that version's archive.
##   2. ``test_m1_realize_unversioned_package_resolves_default`` — a bare
##      reference realizes the FIRST declared version (the default).
##   3. ``test_m1_realize_unknown_version_fails_closed`` — an unknown pin
##      fails the realize step with `EApplyRealizeFailed` naming the pin and
##      the versions on offer; nothing is realized from another version.
##
## Real realization, no seam: the fixture package `gm4bversionedtool` is
## registered in this process (`registerPackageDef`, what the `package` macro
## does at module init) with two `raw` archives at `file://` URLs this test
## writes; the real `uses:` provisioning edge realizes them into a scratch
## store. The shared binary cache is switched off. No mocks.

import std/[os, strutils, unittest]
from repro_core/paths import extendedPath

import repro_local_store
import repro_project_dsl
import repro_tool_profiles

import repro_home_apply/plan
import repro_home_apply/realize
import repro_home_apply/package_catalog
import repro_home_apply/errors
from repro_test_support import testCaseScratchSlug

const ToolName = "gm4bversionedtool"
const ExeSuffix = when defined(windows): ".exe" else: ""

let FixtureRoot = absolutePath(
  "build/test-tmp/t-m1-realize-requested-version" / testCaseScratchSlug())

proc resetDir(path: string) =
  if dirExists(extendedPath(path)):
    removeDir(extendedPath(path))
  createDir(extendedPath(path))

proc writeExecutable(path, body: string) =
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), body)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

var fixtureReady = false

proc record(version: string): TarballProvisioningDef =
  let payload = FixtureRoot / "archive" / version / (ToolName & "-payload")
  writeExecutable(payload, "#!/bin/sh\necho " & version & "\n")
  TarballProvisioningDef(url: "file://" & payload,
    sha256: fileSha256Hex(payload), archiveType: "raw",
    executablePath: ToolName & ExeSuffix,
    packageId: ToolName & "@" & version,
    lockIdentity: "fixture:" & ToolName & "@" & version,
    detail: TarballArchiveDetail(version: version))

proc setupFixture() =
  if fixtureReady:
    return
  fixtureReady = true
  resetDir(FixtureRoot)
  putEnv("REPRO_CACHE_DISABLE", "1")
  # Default (2.0) first: an unpinned reference takes the first eligible.
  registerPackageDef(PackageDef(packageName: ToolName,
    sourceFile: currentSourcePath(), sourceLine: 1,
    tarballProvisioning: @[record("2.0"), record("1.0")]))

proc realizePinned(version, name: string): seq[RealizedRecord] =
  setupFixture()
  let storeDir = FixtureRoot / ("store-" & name)
  resetDir(storeDir)
  var store = openStore(storeDir)
  defer: store.close()
  realizePlannedPackages(store, @[PlannedPackage(packageId: ToolName,
    requestedVersion: version, fromActivity: "test")],
    hostProfileResolutionContext())

suite "M1/GM4b — realize side honors requestedVersion":

  test "test_m1_realize_threads_requested_version_to_chain_resolve":
    let realized = realizePinned("1.0", "pinned")
    check realized.len == 1
    check realized[0].adapter == akTarball
    check realized[0].resolvedVersion == "1.0"
    check realized[0].selection.version == "1.0"
    check readFile(realized[0].resolvedExecutablePath) ==
      "#!/bin/sh\necho 1.0\n"

  test "test_m1_realize_unversioned_package_resolves_default":
    let realized = realizePinned("", "bare")
    check realized.len == 1
    check realized[0].resolvedVersion == "2.0"
    check readFile(realized[0].resolvedExecutablePath) ==
      "#!/bin/sh\necho 2.0\n"

  test "test_m1_realize_unknown_version_fails_closed":
    var raised = false
    try:
      discard realizePinned("9.9.9-nonexistent", "unknown")
    except EApplyRealizeFailed as err:
      raised = true
      check "9.9.9-nonexistent" in err.msg
      check "2.0" in err.msg
      check "1.0" in err.msg
    check raised
    # Nothing was realized from another version.
    var store = openStore(FixtureRoot / "store-unknown")
    defer: store.close()
    check listPrefixes(store).len == 0

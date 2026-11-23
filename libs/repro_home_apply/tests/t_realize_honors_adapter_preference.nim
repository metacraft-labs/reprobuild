## M1 (Realize-Layer-Plumbing-Closures) → GM4b gate: the realize side
## honours the profile's `adapterPreference:` — since GM4b the profile's
## SELECTION POLICY (Provisioning-Contributions.md §"Selection policy") — and
## selects exactly what the `--plan` preview selects.
##
## M1 fixed a realize side that dropped the per-host chain on the floor. GM4b
## removed the chain; preview and realize now share one
## `ProfileResolutionContext`. Contract, restated:
##
##   1. ``test_m1_realize_uses_per_host_chain_when_adapter_preference_present``
##      — `adapterPreference` lists `path` before `tarball` for THIS host's
##      OS; a package with both an archive and an executable on PATH is
##      realized from PATH.
##   2. ``test_m1_realize_uses_platform_default_when_adapter_preference_absent``
##      — no block: the default policy (tarball first, the same on every
##      platform) realizes the archive.
##   3. ``test_m1_realize_falls_back_when_per_os_key_missing`` — a block that
##      names another OS only: the default policy applies to this host.
##   4. ``test_m1_realize_chain_routing_matches_preview`` — for each policy,
##      the realized record's selection equals the preview's selection (kind
##      and lock identity).
##
## Real realization, no seam: the fixture package `gm4bpolicytool` is
## registered in this process (`registerPackageDef`, the call the `package`
## macro makes at module init) with a `raw` archive at a `file://` URL this
## test writes, so the `tarball` kind is realized by the real `uses:`
## provisioning edge into a scratch store, and the `path` kind by the real path
## adapter from a stub executable on PATH. The shared binary cache is switched
## off so nothing is published. No mocks.

import std/[options, os, tables, unittest]
from repro_core/paths import extendedPath

import repro_local_store
import repro_project_dsl
import repro_tool_profiles

import repro_home_apply/plan
import repro_home_apply/realize
import repro_home_apply/package_catalog
from repro_test_support import testCaseScratchSlug

const ToolName = "gm4bpolicytool"
const ExeSuffix = when defined(windows): ".exe" else: ""

let FixtureRoot = absolutePath("build/test-tmp/t-m1-realize-adapter-preference" /
  testCaseScratchSlug())

proc resetDir(path: string) =
  if dirExists(extendedPath(path)):
    removeDir(extendedPath(path))
  createDir(extendedPath(path))

proc writeExecutable(path, body: string) =
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), body)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc hostOsKey(): string =
  adapterPreferenceKey(detectHostOs())

proc otherOsKey(): string =
  if hostOsKey() == "linux": "windows" else: "linux"

var fixtureReady = false

proc setupFixture() =
  ## Build the archive and the PATH stub, then register the definition.
  ## Once per process: the registry is process-wide.
  if fixtureReady:
    return
  fixtureReady = true
  resetDir(FixtureRoot)
  let payload = FixtureRoot / "archive" / (ToolName & "-payload")
  writeExecutable(payload, "#!/bin/sh\necho from-archive\n")
  let stub = FixtureRoot / "path-bin" / (ToolName & ExeSuffix)
  writeExecutable(stub, "#!/bin/sh\necho from-path\n")
  putEnv("PATH", (FixtureRoot / "path-bin") & PathSep & getEnv("PATH"))
  putEnv("REPRO_CACHE_DISABLE", "1")
  registerPackageDef(PackageDef(packageName: ToolName,
    sourceFile: currentSourcePath(), sourceLine: 1,
    tarballProvisioning: @[TarballProvisioningDef(
      url: "file://" & payload, sha256: fileSha256Hex(payload),
      archiveType: "raw", executablePath: ToolName & ExeSuffix,
      packageId: ToolName & "@1.0", lockIdentity: "fixture:" & ToolName & "@1.0",
      detail: TarballArchiveDetail(version: "1.0"))]))

proc realizeWith(ap: OrderedTable[string, seq[string]]; name: string):
    tuple[preview: PackagePreview; record: RealizedRecord] =
  setupFixture()
  let storeDir = FixtureRoot / ("store-" & name)
  resetDir(storeDir)
  let ctx = hostProfileResolutionContext(ap)
  let packages = @[PlannedPackage(packageId: ToolName, fromActivity: "test")]
  let previews = previewPackageResolutions(packages, ctx)
  check previews.len == 1
  var store = openStore(storeDir)
  defer: store.close()
  let realized = realizePlannedPackages(store, packages, ctx)
  check realized.len == 1
  (previews[0], realized[0])

suite "M1/GM4b — realize side honors the selection policy":

  test "test_m1_realize_uses_per_host_chain_when_adapter_preference_present":
    var ap = initOrderedTable[string, seq[string]]()
    ap[hostOsKey()] = @["path", "tarball"]
    let r = realizeWith(ap, "per-host")
    check r.record.adapter == akPath
    check r.record.selection.kind == rkPath
    check r.record.fromProductionCatalog
    check r.record.cacheHit
    check readFile(r.record.resolvedExecutablePath) ==
      "#!/bin/sh\necho from-path\n"

  test "test_m1_realize_uses_platform_default_when_adapter_preference_absent":
    let r = realizeWith(initOrderedTable[string, seq[string]](), "default")
    check r.record.adapter == akTarball
    check r.record.selection.kind == rkTarball
    check r.record.resolvedVersion == "1.0"
    check fileExists(r.record.resolvedExecutablePath)
    check readFile(r.record.resolvedExecutablePath) ==
      "#!/bin/sh\necho from-archive\n"

  test "test_m1_realize_falls_back_when_per_os_key_missing":
    var ap = initOrderedTable[string, seq[string]]()
    ap[otherOsKey()] = @["path"]
    let r = realizeWith(ap, "missing-key")
    # Not this host's key: the default policy (tarball first) applies.
    check r.record.adapter == akTarball
    check r.record.selection.kind == rkTarball

  test "test_m1_realize_chain_routing_matches_preview":
    for (name, policy) in [("sym-path", @["path", "tarball"]),
                           ("sym-tarball", @["tarball", "path"])]:
      var ap = initOrderedTable[string, seq[string]]()
      ap[hostOsKey()] = policy
      let r = realizeWith(ap, name)
      checkpoint name
      check r.preview.resolved
      check r.preview.resolution.selection.kind == r.record.selection.kind
      check r.preview.resolution.selection.lockIdentity ==
        r.record.selection.lockIdentity

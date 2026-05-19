## Realize planned packages through the appropriate M55/M56 adapter.
##
## The M63 pipeline supports three adapters at the apply layer:
##
##   * `scoop`  — Windows-only; binds through `repro_tool_profiles.resolveScoopTool`
##                with a sandboxed `$SCOOP` root.
##   * `tarball` — cross-platform fallback for verified-source packages
##                (not exercised by Phase A gates, present for symmetry).
##   * `path`    — universal "the executable already lives at an
##                absolute path" adapter. Used by gate 4 to install
##                `fd` from a fixture stub executable without forcing
##                a real Scoop install. Records a real `prefixes/...`
##                row in the M56 store with a hardlink-or-copy of the
##                source executable.
##
## The picker is driven by:
##
##   1. `$REPRO_TEST_PACKAGE_SOURCE` (semicolon-separated
##      `<pkg>=<absolute-path>` entries) — exercised by the Phase A
##      gates to declare path-adapter packages without going through
##      Scoop.
##   2. `$REPRO_TEST_PACKAGE_SCOOP` (semicolon-separated
##      `<pkg>=<bucket>/<app>@<version>[#<execName>]`) — exercised by
##      the fresh-install gate to route a package through the Scoop
##      adapter against the sandboxed root.
##
## The env-driven indirection is the same shape as the M61 catalog
## lookup seam (`REPRO_HOME_PACKAGE_CATALOG`) and keeps the gates'
## "no fake apply" rule intact: the actual realization still goes
## through the real store + the real Scoop adapter; the env vars
## only carry per-package binding instructions a future package
## catalog (M65+) will provide.

import std/[os, strutils, tables]

import blake3
import repro_local_store
import repro_home_generations
when defined(windows):
  import repro_interface_artifacts
  import repro_tool_profiles

import ./errors
import ./plan

const
  PackageSourceEnvVar* = "REPRO_TEST_PACKAGE_SOURCE"
  PackageScoopEnvVar* = "REPRO_TEST_PACKAGE_SCOOP"
  ScoopOverrideEnvVar* = "REPRO_TEST_SCOOP_OVERRIDE"

type
  AdapterKind* = enum
    akPath = "path"
    akScoop = "scoop"
    akTarball = "tarball"

  RealizedRecord* = object
    ## Per-package realization output: the prefix id + the resolved
    ## executable path, both fed into the manifest writer and the
    ## launch-plan synthesizer.
    packageId*: string
    adapter*: AdapterKind
    prefixId*: PrefixIdBytes
    prefixRelativePath*: string
    prefixAbsolutePath*: string
    resolvedExecutablePath*: string
    provenance*: seq[byte]

# ---------------------------------------------------------------------------
# Env-driven catalog
# ---------------------------------------------------------------------------

type
  PathPackageSpec = object
    sourcePath: string
  ScoopPackageSpec = object
    bucket: string
    app: string
    version: string
    executableName: string

proc parsePathCatalog(): Table[string, PathPackageSpec] =
  let raw = getEnv(PackageSourceEnvVar)
  if raw.len == 0:
    return
  for piece in raw.split(';'):
    let trimmed = piece.strip()
    if trimmed.len == 0:
      continue
    let eq = trimmed.find('=')
    if eq <= 0:
      continue
    let pkg = trimmed[0 ..< eq].strip()
    let src = trimmed[eq + 1 .. ^1].strip()
    if pkg.len == 0 or src.len == 0:
      continue
    result[pkg] = PathPackageSpec(sourcePath: src)

proc parseScoopCatalog(): Table[string, ScoopPackageSpec] =
  let raw = getEnv(PackageScoopEnvVar)
  if raw.len == 0:
    return
  for piece in raw.split(';'):
    let trimmed = piece.strip()
    if trimmed.len == 0:
      continue
    let eq = trimmed.find('=')
    if eq <= 0:
      continue
    let pkg = trimmed[0 ..< eq].strip()
    var rest = trimmed[eq + 1 .. ^1].strip()
    if pkg.len == 0 or rest.len == 0:
      continue
    var execName = ""
    let hash = rest.find('#')
    if hash >= 0:
      execName = rest[hash + 1 .. ^1].strip()
      rest = rest[0 ..< hash]
    let slash = rest.find('/')
    if slash <= 0:
      continue
    let bucket = rest[0 ..< slash].strip()
    var afterSlash = rest[slash + 1 .. ^1]
    var version = ""
    let at = afterSlash.find('@')
    var app = afterSlash
    if at >= 0:
      app = afterSlash[0 ..< at].strip()
      version = afterSlash[at + 1 .. ^1].strip()
    if execName.len == 0:
      execName = app
    result[pkg] = ScoopPackageSpec(bucket: bucket, app: app,
      version: version, executableName: execName)

# ---------------------------------------------------------------------------
# Path-adapter realization
# ---------------------------------------------------------------------------

proc realizePathAdapter(store: var Store; packageId, sourcePath: string):
    RealizedRecord =
  ## Hardlink-or-copy `sourcePath` (an absolute path on the host) into
  ## a freshly realized `prefixes/...` directory inside the M56 store.
  ## The realization-hash is derived deterministically from
  ## `(packageId, sourcePath)` so two applies of the same intent
  ## produce the same prefix id (no-op short-circuit relies on this).
  if not fileExists(sourcePath):
    raiseRealizeFailed(packageId, "path",
      "source executable not found at '" & sourcePath & "' (" &
      PackageSourceEnvVar & ")")
  let leafName = extractFilename(sourcePath)
  let hint = StoreReceiptHint(
    adapter: "path",
    packageName: packageId,
    version: "fixture",
    declaredExecutablePath: leafName,
    exportedExecutables: @[leafName],
    lockIdentity: "path:" & sourcePath,
    provenanceUrl: "file:///" & sourcePath.replace('\\', '/'),
    provenanceChecksum: "",
    materializationMechanism: "")
  let prefixId = computeRealizationHash(packageId, "fixture", "path",
    "path:" & sourcePath, leafName,
    "file:///" & sourcePath.replace('\\', '/'), "", [packageId])
  let outcome = realizePrefix(store, prefixId, hint,
    proc(stagingDir: string; mechanism: var string) =
      let dst = stagingDir / leafName
      try:
        createHardlink(sourcePath, dst)
        mechanism = "hardlink"
      except OSError, IOError:
        copyFile(sourcePath, dst)
        mechanism = "copy")
  result.packageId = packageId
  result.adapter = akPath
  result.prefixId = prefixId
  result.prefixRelativePath = outcome.relativePath
  result.prefixAbsolutePath = outcome.absolutePath
  result.resolvedExecutablePath = outcome.absolutePath / leafName
  # Pack the provenance: a single typed line of "path:<sourcePath>".
  let prov = "path:" & sourcePath
  result.provenance = newSeq[byte](prov.len)
  for i, ch in prov:
    result.provenance[i] = byte(ord(ch))

# ---------------------------------------------------------------------------
# Scoop-adapter realization
# ---------------------------------------------------------------------------

when defined(windows):
  proc realizeScoopAdapter(store: var Store; packageId: string;
                           spec: ScoopPackageSpec): RealizedRecord =
    ## Bind the package through the M55 Scoop adapter.
    ## `resolveScoopTool` itself creates the realized prefix under the
    ## store via `registerInUnifiedStore`; we synthesize the
    ## `RealizedRecord` view of that result for the manifest writer.
    let useDef = InterfaceToolUse(
      rawConstraint: packageId,
      packageSelector: packageId,
      executableName: spec.executableName,
      location: SourceLocation(file: "home-apply", line: 1))
    var provisioning = InterfaceScoopProvisioning(
      packageName: packageId,
      bucket: spec.bucket,
      app: spec.app,
      version: spec.version,
      preferredVersion: "",
      manifestChecksum: "",
      executablePath: spec.executableName,
      requiresExecutionProfileChecksum: false,
      packageId: spec.bucket & "/" & spec.app,
      lockIdentity: "scoop:" & spec.bucket & "/" & spec.app,
      location: SourceLocation(file: "home-apply", line: 2))
    var withScoop = useDef
    withScoop.scoopProvisioning = @[provisioning]
    let scoopOverride = getEnv(ScoopOverrideEnvVar)
    let profile =
      try:
        resolveScoopTool(withScoop, store.root, scoopOverride)
      except CatchableError as err:
        raiseRealizeFailed(packageId, "scoop", err.msg)
    # `resolveScoopTool` populated `selectedStorePath` with the
    # realized prefix. Reverse-compute the relative path under the
    # store + read the receipt to obtain the canonical prefix id.
    let absPath = profile.selectedStorePath
    let relPath = block:
      var rel = absPath
      let prefix = store.root & DirSep
      if rel.startsWith(prefix):
        rel = rel[prefix.len .. ^1]
      rel.replace('\\', '/')
    # The receipt path under the prefix encodes the realization hash.
    let receiptPath = absPath / ".repro-receipt"
    if not fileExists(receiptPath):
      raiseRealizeFailed(packageId, "scoop",
        "no receipt at expected path " & receiptPath)
    let recipt = readReceiptFile(receiptPath)
    result.packageId = packageId
    result.adapter = akScoop
    result.prefixId = recipt.realizationHash
    result.prefixRelativePath = relPath
    result.prefixAbsolutePath = absPath
    result.resolvedExecutablePath = profile.resolvedExecutablePath
    let prov = "scoop:" & spec.bucket & "/" & spec.app & "@" & spec.version
    result.provenance = newSeq[byte](prov.len)
    for i, ch in prov:
      result.provenance[i] = byte(ord(ch))

# ---------------------------------------------------------------------------
# Public dispatcher
# ---------------------------------------------------------------------------

proc realizePlannedPackages*(store: var Store;
                             packages: seq[PlannedPackage]):
    seq[RealizedRecord] =
  ## Realize every planned package through its declared adapter.
  let pathCatalog = parsePathCatalog()
  let scoopCatalog = parseScoopCatalog()
  for p in packages:
    if p.packageId in pathCatalog:
      result.add(realizePathAdapter(store, p.packageId,
        pathCatalog[p.packageId].sourcePath))
    elif p.packageId in scoopCatalog:
      when defined(windows):
        result.add(realizeScoopAdapter(store, p.packageId,
          scoopCatalog[p.packageId]))
      else:
        raiseRealizeFailed(p.packageId, "scoop",
          "the scoop adapter is Windows-only; this build runs on a " &
          "non-Windows platform")
    else:
      raiseRealizeFailed(p.packageId, "<none>",
        "no adapter binding declared. Set " & PackageSourceEnvVar &
        "=<pkg>=<absolute-path> for a path-adapter binding, or " &
        PackageScoopEnvVar & "=<pkg>=<bucket>/<app>@<version> for " &
        "a Scoop-adapter binding.")

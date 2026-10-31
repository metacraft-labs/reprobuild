## Compatibility surface for the shared tarball provisioning realizer.
## All fetching, verification, installation, caching and publication are owned
## by resolveTarballTool's build-graph edge. This wrapper only projects its
## prefix into the home apply result and attaches activation metadata.
import std/[json, os, strutils]
from repro_core/paths import extendedPath
import repro_local_store
import repro_interface_artifacts
import repro_tool_profiles
import repro_tool_profiles/[archive_inputs, archive_steps]
import repro_home_resources/drivers/app_bundle
export archive_inputs, archive_steps

proc realizeBuiltinPackage*(store: var Store; resolution: ArchiveRealization;
    appTrust: AppTrustPolicy = {}): RealizeBuiltinResult =
  let record = archiveRecordOf(resolution)
  let useDef = InterfaceToolUse(rawConstraint: resolution.packageId,
    packageSelector: resolution.packageId, executableName: resolution.executableName,
    tarballProvisioning: @[record])
  let previousTrust = tarballAppTrust
  tarballAppTrust = appTrust
  defer: tarballAppTrust = previousTrust
  let profile = resolveTarballTool(useDef, store.root)
  result.prefixAbsolutePath = profile.selectedStorePath
  result.prefixRelativePath = relativePath(profile.selectedStorePath, store.root)
  let receipt = readReceiptFile(profile.selectedStorePath / ".repro-receipt")
  result.prefixId = receipt.realizationHash
  result.resolvedExecutablePath = profile.resolvedExecutablePath
  result.cacheHit = profile.tarballCacheHit
  result.urlUsed = profile.tarballSelectedUrl
  result.digestAlgorithm = resolution.digestAlgorithm
  result.digestValue = resolution.digestValue
  result.archiveFormat = resolution.archiveFormat
  result.envBindings = substituteEnv(resolution.envSubstitutions,
    profile.selectedStorePath)
  for action in resolution.preInstallActions:
    if action.kind == piaAddPath:
      result.envBindings.add((name: "PATH+=", value:
        action.target.replace("$dir", profile.selectedStorePath).replace("${prefix}", profile.selectedStorePath)))
  let installation = profile.selectedStorePath / ".repro-installation.json"
  if fileExists(extendedPath(installation)):
    for arg in parseFile(extendedPath(installation)){"installerArgvUsed"}:
      result.installerArgvUsed.add(arg.getStr().replace("${prefix}", profile.selectedStorePath).replace("${archive}", record.url))
  publishAppItem(result, resolution, profile.selectedStorePath)

proc powershellZipExtractCommand*(powershell, archivePath, destination: string): string =
  zipExtractCommand((exe: powershell, kind: "powershell"), archivePath, destination)

proc extractZip*(packageId, archivePath, destDir: string) =
  extractTarballArchive(archivePath, destDir, "zip", 0)

proc extractTar*(packageId, archivePath, destDir, format: string) =
  extractTarballArchive(archivePath, destDir, format, 0)

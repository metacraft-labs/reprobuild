## Strict tarball metadata projection shared by recipe and home callers.
## Retains the canonical record so compatibility callers cannot lose fields
## belonging to the provisioning edge (mirrors, closure, pruning or aliases).

import std/strutils
import repro_interface_artifacts
import repro_dsl_stdlib/packages_schema
import ./realization_selection
from repro_home_resources/drivers/app_bundle import installerProductPathError

type
  ArchiveRealization* = object
    ## Strictly decoded input to the shared tarball provisioning realizer.
    ## Built by ``archiveRealizationOf`` from the selected record — it is a
    ## projection of that record, never a second source of truth.
    record*: InterfaceTarballProvisioning
      ## Original record retained for lossless compatibility projection.
    packageId*: string
    app*: string
    resolvedVersion*: string         ## the record's version, when declared
    executableName*: string
    cacheHit*: bool                  ## set by the realizer when the CAS
                                     ## prefix already exists
    builtinVersion*: string          ## the record's ``detail.version``
    builtinCpuLevel*: MicroarchLevel
                                     ## PMC-2: the microarchitecture FLOOR the
                                     ## selected record declared, or
                                     ## ``mlNone``.
    builtinCpuFeatures*: set[CpuFeature]
                                     ## PMC-3: the extra extensions the
                                     ## selected record declared beyond its
                                     ## floor (the DECLARED set, not its
                                     ## expansion).
    resolvedTarget*: string
                                     ## PMC-4: ``renderResolvedTarget`` of the
                                     ## two above — the single spelling a lock
                                     ## entry and a cache key use. ``""`` for a
                                     ## record that declares no floor.
    urlUsed*: string
    digestAlgorithm*: string         ## "sha256" | "sha512" | "sha1"
    digestValue*: string             ## hex digest (lowercase)
    archiveFormat*: ArchiveFormat
    installMethod*: InstallMethod
    binRelpath*: seq[string]
    extractPath*: string             ## inner-dir flatten
    installerArgs*: seq[string]
    pacmanPackages*: seq[string]
    bootstrapArgv*: seq[string]
    envSubstitutions*: seq[tuple[name, value: string]]
    nested7z*: bool
    preInstallActions*: seq[PreInstallAction]
    preInstallUnrecognized*: seq[string]
    msiAdminInstall*: bool
      ## When true archive realization uses ``msiexec /a`` instead of
      ## ``dark.exe`` for MSI extraction (the per-record form of the global
      ## ``CAKBUILTIN_PREFER_MSIEXEC=1``).
    launcherEmit*: seq[LauncherEmitSpec]
    appBundle*: string
      ## GM4c: the ``.app`` bundle's path inside the archive, for an
      ## ``imAppBundle`` record (Store-And-Installation-Layout.md § macOS
      ## Application Bundles). With ``bundleId`` / ``teamId`` and the
      ## record's version it is what the realizer verifies. For a macOS
      ## installer application it is the product bundle's path inside the
      ## installed prefix (§ Installer applications).
    bundleId*: string
    teamId*: string
    installerApp*: string
      ## The installer application's path inside the archive, for a macOS
      ## ``imInstallerSilent`` record (Store-And-Installation-Layout.md
      ## § Installer applications); "" for a Windows installer.


const
  MacosPkgInstallRefusal* =
    "no system-scope realizer runs macOS installer packages yet"
    ## The reason a ``pkg-install`` record is refused, quoted verbatim in the
    ## refusal so tests and callers can recognise it.

proc refuseUnrealizableMacosShape*(packageId: string;
                                  record: InterfaceTarballProvisioning) =
  ## GM4c: the macOS vendor shapes a contribution may DECLARE but nothing
  ## realizes (Store-And-Installation-Layout.md § macOS Application Bundles,
  ## "Shapes this does not cover"), and the application shapes declared for
  ## another os. Refused at resolution, so ``--plan`` names the reason
  ## before anything is downloaded. A macOS ``installer-silent`` record is
  ## an installer application and IS realized (§ Installer applications);
  ## ``archiveRealizationOf`` refuses one that lacks a field the realizer
  ## verifies.
  let detail = record.detail
  let os = parsePlatformOsToken(record.os)
  let macos = os.ok and os.os == poMacos
  if detail.installMethod == $imPkgInstall:
    raise newException(ValueError,
      "the tarball realization of package '" & packageId & "' (" &
      record.url & ") is an installer package that must be run as root " &
      "(installMethod pkg-install): its scripts and privileged components " &
      "are what install the product, which makes it system scope (P3). " &
      "A home profile cannot realize it, and " & MacosPkgInstallRefusal &
      ". Install it outside Reprobuild until one does.")
  if detail.installMethod == $imAppBundle and not macos:
    raise newException(ValueError,
      "the tarball realization of package '" & packageId & "' (" &
      record.url & ") declares installMethod app-bundle for os '" &
      record.os & "'; an application bundle is a macOS realization")
  if detail.installerApp.len > 0 and not macos:
    raise newException(ValueError,
      "the tarball realization of package '" & packageId & "' (" &
      record.url & ") names the installer application " &
      detail.installerApp.escape & " for os '" & record.os & "'; an " &
      "installer application is a macOS realization")

proc archiveRealizationOf*(packageId: string;
                           record: InterfaceTarballProvisioning):
    ArchiveRealization =
  ## Project a selected ``tarball`` record into the provisioning realizer's
  ## input. Every field is decoded strictly: an archive format, install
  ## method, pre-install step or launcher spec the realizer cannot read is a
  ## refusal, not a default.
  refuseUnrealizableMacosShape(packageId, record)
  result.record = record
  let detail = record.detail
  result.packageId = packageId
  result.app = packageId
  result.resolvedVersion = detail.version
  result.builtinVersion = detail.version
  let level = parseMicroarchLevelToken(detail.cpuLevel)
  let features = parseCpuFeatureSet(detail.cpuFeatures)
  if not level.ok or not features.ok:
    raise newException(ValueError, "package '" & packageId &
      "': unreadable cpuLevel/cpuFeatures on " & record.url)
  result.builtinCpuLevel = level.level
  result.builtinCpuFeatures = features.features
  result.resolvedTarget = renderResolvedTarget(level.level, features.features)
  result.urlUsed = record.url
  if record.sha256.len > 0:
    result.digestAlgorithm = "sha256"
    result.digestValue = normalizedHexDigest(record.sha256, "sha256")
  elif detail.sha512.len > 0:
    result.digestAlgorithm = "sha512"
    result.digestValue = normalizedHexDigest(detail.sha512, "sha512")
  elif detail.sha1.len > 0:
    result.digestAlgorithm = "sha1"
    result.digestValue = normalizedHexDigest(detail.sha1, "sha1")
  else:
    raise newException(ValueError, "package '" & packageId &
      "': the tarball realization " & record.url & " names no digest")
  let digestLength =
    case result.digestAlgorithm
    of "sha256": 64
    of "sha512": 128
    else: 40
  var validDigest = result.digestValue.len == digestLength
  for digit in result.digestValue:
    if digit notin {'0' .. '9', 'a' .. 'f'}:
      validDigest = false
  if not validDigest:
    raise newException(ValueError, "package '" & packageId & "': invalid " &
      result.digestAlgorithm & " digest: " & result.digestValue)
  let format = parseArchiveFormatToken(record.archiveType)
  if not format.ok:
    raise newException(ValueError, "package '" & packageId &
      "': archive type '" & record.archiveType & "' is not one the tarball " &
      "realizer reads")
  result.archiveFormat = format.format
  let installMethod = parseInstallMethodToken(detail.installMethod)
  if not installMethod.ok:
    raise newException(ValueError, "package '" & packageId &
      "': unknown installMethod '" & detail.installMethod & "'")
  result.installMethod = installMethod.installMethod
  result.binRelpath = @[record.executablePath] & detail.extraExecutables
  result.extractPath = detail.extractPath
  result.installerArgs = detail.installerArgs
  result.pacmanPackages = detail.pacmanPackages
  result.bootstrapArgv = detail.bootstrapArgv
  var env: seq[tuple[name, value: string]] = @[]
  for binding in detail.env:
    let eq = binding.find('=')
    if eq <= 0:
      raise newException(ValueError, "package '" & packageId &
        "': env binding " & binding.escape() & " is not NAME=value")
    env.add((name: binding[0 ..< eq], value: binding[eq + 1 .. ^1]))
  # Stable order: by name, so the realize loop's output is deterministic.
  for i in 0 ..< env.len:
    for j in i + 1 ..< env.len:
      if env[j].name < env[i].name:
        swap(env[i], env[j])
  result.envSubstitutions = env
  result.nested7z = detail.nested7z
  result.msiAdminInstall = detail.msiAdminInstall
  for encoded in detail.preInstall:
    result.preInstallActions.add(decodePreInstallAction(encoded))
  result.preInstallUnrecognized = detail.preInstallUnrecognized
  for encoded in detail.launcherEmit:
    let launcher = decodeLauncherEmitSpec(encoded)
    if launcher.kind == lekScript:
      raise newException(ValueError, "package '" & packageId &
        "': script launcher emission is not supported")
    result.launcherEmit.add(launcher)
  result.appBundle = detail.appBundle
  result.bundleId = detail.bundleId
  result.teamId = detail.teamId
  result.installerApp = detail.installerApp
  if result.installMethod == imInstallerSilent and
      (result.installerApp.len > 0 or result.appBundle.len > 0 or
       result.bundleId.len > 0 or result.teamId.len > 0):
    # An installer-silent record that names an installer application or
    # any application field is a macOS installer APPLICATION
    # (Store-And-Installation-Layout.md § Installer applications): the
    # realizer verifies the installer against teamId and the product it
    # produced against appBundle / bundleId / version / teamId, so a record
    # missing any of them cannot be realized. One that names none of them
    # is a Windows installer (NSIS / MSI), realized as before.
    var missing: seq[string] = @[]
    if result.installerApp.len == 0: missing.add("installerApp")
    if result.appBundle.len == 0: missing.add("appBundle")
    if result.bundleId.len == 0: missing.add("bundleId")
    if result.teamId.len == 0: missing.add("teamId")
    if result.builtinVersion.len == 0: missing.add("version")
    if missing.len > 0:
      raise newException(ValueError, "package '" & packageId &
        "': the tarball realization " & record.url & " is a macOS " &
        "installer application (installMethod installer-silent) and must " &
        "declare installerApp (the installer's path inside the archive), " &
        "appBundle (the product bundle in the installed prefix), bundleId, " &
        "teamId and version; it lacks " & missing.join(", "))
    # The paths the realizer walks, checked before anything is downloaded
    # (§ Installer applications, "Declaring it"): the product path has one
    # or two components and the first is the placed item, never a bundle
    # holding another; the installer is a bundle inside the archive.
    let productError = installerProductPathError(result.appBundle)
    if productError.len > 0:
      raise newException(ValueError, "package '" & packageId &
        "': the installer application " & record.url & " declares " &
        "appBundle " & result.appBundle.escape & ", the product bundle in " &
        "the installed prefix; " & productError)
    let installerPath = result.installerApp.replace('\\', '/')
    var installerOk = not installerPath.startsWith("/") and
      installerPath.endsWith(".app")
    for part in installerPath.split('/'):
      if part.len == 0 or part == "." or part == "..":
        installerOk = false
    if not installerOk:
      raise newException(ValueError, "package '" & packageId &
        "': the installer application " & record.url & " declares " &
        "installerApp " & result.installerApp.escape & "; it must be a " &
        "relative path inside the archive naming a .app bundle")
    if result.archiveFormat notin {afDmg, afZip, afTarGz, afTarXz,
        afTarBz2}:
      raise newException(ValueError, "package '" & packageId &
        "': the installer application " & record.url & " is delivered " &
        "as " & $result.archiveFormat & "; an installer application is " &
        "copied out of a dmg, zip, tar.gz, tar.xz or tar.bz2 (a flat " &
        "installer package that must run is installMethod pkg-install)")
  if result.installMethod == imAppBundle and (result.appBundle.len == 0 or
      result.bundleId.len == 0 or result.teamId.len == 0 or
      result.builtinVersion.len == 0):
    raise newException(ValueError, "package '" & packageId &
      "': the app-bundle realization " & record.url & " must declare " &
      "appBundle, bundleId, teamId and version (the bundle's " &
      "CFBundleShortVersionString); realization verifies all four")
  if result.installMethod == imAppBundle:
    # The commands an application declares (``extraExecutable``) are
    # exported from the PLACED bundle (Store-And-Installation-Layout.md
    # § macOS Application Bundles, "Command line"), so each must name a
    # file inside the bundle, the prefix's only content. The realizer then
    # refuses one that is absent or not executable after extraction.
    let leaf = result.appBundle.replace('\\', '/').split('/')[^1]
    for rel in detail.extraExecutables:
      let parts = rel.replace('\\', '/').split('/')
      var inside = parts.len >= 2 and parts[0] == leaf
      for part in parts:
        if part.len == 0 or part == "." or part == "..":
          inside = false
      if not inside:
        raise newException(ValueError, "package '" & packageId &
          "': the app-bundle realization " & record.url & " declares " &
          "extraExecutable " & rel.escape & "; a command of an application " &
          "is a path inside its bundle, relative to the realized prefix: " &
          "it must start with '" & leaf & "/' and contain no '.' or '..' " &
          "component")
  # ``executablePath`` is a TARGET-platform path (``bin\gh.exe`` for a
  # Windows record); split on both separators so the leaf is right whichever
  # platform the resolution runs on.
  result.executableName = record.executablePath.split({'/', '\\'})[^1]

proc archiveRecordOf*(resolution: ArchiveRealization):
    InterfaceTarballProvisioning =
  ## Recover the canonical record for the compatibility adapter. Starting
  ## with its retained record preserves fields the decoded view does not
  ## expose, including mirrors, stripping, pruning, aliases and closures.
  result = resolution.record
  if result.url.len > 0:
    var decoded = archiveRealizationOf(resolution.packageId, result)
    # These fields report resolution/realization state, not record metadata.
    decoded.cacheHit = resolution.cacheHit
    decoded.resolvedVersion = resolution.resolvedVersion
    decoded.app = resolution.app
    decoded.executableName = resolution.executableName
    decoded.resolvedTarget = resolution.resolvedTarget
    if decoded == resolution:
      return
  result.url = resolution.urlUsed
  if result.packageName.len == 0:
    result.packageName = resolution.packageId
  if result.packageId.len == 0:
    result.packageId = resolution.packageId
  if resolution.record.url.len == 0:
    result.cpu = $detectHostCpu()
    result.os = $detectHostOs()
  if not parseArchiveFormatToken(result.archiveType).ok or
      parseArchiveFormatToken(result.archiveType).format != resolution.archiveFormat:
    result.archiveType = $resolution.archiveFormat
  result.executablePath =
    if resolution.binRelpath.len > 0: resolution.binRelpath[0] else: ""
  result.detail.extraExecutables =
    if resolution.binRelpath.len > 1: resolution.binRelpath[1 .. ^1] else: @[]
  case resolution.digestAlgorithm
  of "sha256": result.sha256 = resolution.digestValue
  of "sha512":
    result.sha256 = ""
    result.detail.sha512 = resolution.digestValue
  of "sha1":
    result.sha256 = ""
    result.detail.sha512 = ""
    result.detail.sha1 = resolution.digestValue
  else:
    raise newException(ValueError, "package '" & resolution.packageId &
      "': unknown digest algorithm '" & resolution.digestAlgorithm & "'")
  result.detail.version = resolution.builtinVersion
  result.detail.cpuLevel = $resolution.builtinCpuLevel
  result.detail.cpuFeatures = renderCpuFeatureTokens(resolution.builtinCpuFeatures)
  result.detail.installMethod = $resolution.installMethod
  result.detail.extractPath = resolution.extractPath
  result.detail.installerArgs = resolution.installerArgs
  result.detail.pacmanPackages = resolution.pacmanPackages
  result.detail.bootstrapArgv = resolution.bootstrapArgv
  result.detail.env = @[]
  for binding in resolution.envSubstitutions:
    result.detail.env.add(binding.name & "=" & binding.value)
  result.detail.nested7z = resolution.nested7z
  result.detail.msiAdminInstall = resolution.msiAdminInstall
  result.detail.preInstall = @[]
  for action in resolution.preInstallActions:
    result.detail.preInstall.add(preInstallAction($action.kind, action.source,
      action.target, action.recurse, action.literal))
  result.detail.preInstallUnrecognized = resolution.preInstallUnrecognized
  result.detail.launcherEmit = @[]
  for spec in resolution.launcherEmit:
    result.detail.launcherEmit.add(launcherEmitSpec($spec.kind, spec.target,
      spec.interpreter_package_id, spec.launcher_name))
  result.detail.appBundle = resolution.appBundle
  result.detail.bundleId = resolution.bundleId
  result.detail.teamId = resolution.teamId
  result.detail.installerApp = resolution.installerApp

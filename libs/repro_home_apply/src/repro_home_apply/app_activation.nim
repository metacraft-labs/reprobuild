## GM4c — activating realized macOS application bundles.
##
## A package whose selected realization has the ``app-bundle`` install shape
## realizes a verified ``<Name>.app`` at the root of its store prefix
## (``builtin_adapter``). The apply places a COPY of it in the user's
## Applications directory through the home resource lifecycle, so the
## placement is planned, drift-checked, recorded in the generation and
## reversed by rollback like every other home-scope object. This module
## turns the realized records into those ``macos.appBundle`` resources; the
## driver that places them is ``repro_home_resources/drivers/app_bundle``.
## Store-And-Installation-Layout.md § macOS Application Bundles.
##
## Address convention (stable across applies, so a re-apply of the same
## bundle is a lifecycle no-op): ``home.package.<package>.app``. Like the
## ``home.package.<id>.bin`` PATH resources of ``env_binding``, the
## ``home.package.`` namespace is reserved for synthesized resources.


import std/[os, strutils]

import repro_home_resources

from ./builtin_adapter import appPlacedItem
import ./package_catalog
import ./realize

# The address helpers (`appBundleAddress`, `packageIdOfAppBundleAddress`)
# live in `repro_home_resources/concerns`, beside the concern classification
# that reads the same namespace.

proc appBundleActivationResource*(record: RealizedRecord;
                                  applicationsDir: string): Resource =
  ## The ``macos.appBundle`` resource that places ``record``'s bundle in
  ## ``applicationsDir``. ``record`` must carry an app-bundle realization.
  doAssert record.appBundle.storeBundlePath.len > 0,
    "appBundleActivationResource needs a realized app bundle"
  Resource(
    kind: rkMacosAppBundle,
    address: appBundleAddress(record.packageId),
    lifecyclePolicy: lpDefault,
    appBundleSource: record.appBundle.storeBundlePath,
    appBundleTargetDir: applicationsDir,
    appBundleName: record.appBundle.bundleName,
    appBundleMainPath: record.appBundle.mainBundlePath,
    appBundleExpectation: record.appBundle.expectation,
    appBundleTrust: record.appBundle.trust,
    appBundleIdentity: record.appBundle.identity)

proc planAppBundleActivations*(realized: seq[RealizedRecord];
                               homeDir: string): seq[Resource] =
  ## One home-scope placement per realized application bundle, in
  ## ``~/Applications`` (spec P3: unelevated, so home scope). Order follows
  ## ``realized``, which is the profile's package order.
  let target = applicationsDir(apsHome, homeDir)
  for record in realized:
    if record.appBundle.storeBundlePath.len > 0:
      result.add(appBundleActivationResource(record, target))

# ---------------------------------------------------------------------------
# Command line (Store-And-Installation-Layout.md § macOS Application Bundles,
# "Command line")
# ---------------------------------------------------------------------------
#
# An application's commands are the executables its record declares with
# ``extraExecutable`` -- the same field, and the same realization-time
# existence check, every other archive record uses for the executables it
# exports beyond ``executablePath``. For an application the paths are
# relative to the prefix, which holds the bundle at its root, so they start
# with the bundle's name. Each becomes a launcher named after the path's
# last component, in the home profile's bin directory beside the package's
# own launcher.
#
# Every launcher of an application runs the PLACED copy in the Applications
# directory, not the store copy. The commands these bundles carry are not
# standalone tools: ``code`` locates the bundle it lives in and starts that
# bundle's Electron, ``utmctl`` and ``hs`` talk to the running application.
# Run from the store, they would start a second copy of the application from
# a content-addressed path -- the very thing activation copies the bundle to
# avoid (Launch Services, the Dock and privacy grants would record the store
# path, and garbage collection later removes it). The placed path is the
# same for every generation that places the application, so the launcher
# needs no update when the version changes, and the generation that writes
# the launcher is the one that placed (and records) the bundle; rolling back
# to a generation without the application removes both.

proc applicationCommandPaths*(archive: ArchiveRealization): seq[string] =
  ## The commands an application record declares, as prefix-relative paths:
  ## its ``extraExecutable`` entries (``binRelpath`` after
  ## ``executablePath``).
  if archive.binRelpath.len > 1:
    result = archive.binRelpath[1 .. ^1]

proc commandNameOf*(executableRelPath: string): string =
  ## The command a declared executable is exported as: its file name.
  executableRelPath.replace('\\', '/').split('/')[^1]

proc applicationCommandPathError*(archive: ArchiveRealization;
                                  relPath: string): string =
  ## Why ``relPath`` cannot be a command of the application ``archive``
  ## realizes, or "" when it can: it must be a relative path inside the
  ## placed item (the bundle, or an installer application's product folder)
  ## naming a file below it, with no ``.`` or ``..`` component.
  let placed = appPlacedItem(archive).item
  let parts = relPath.replace('\\', '/').split('/')
  if relPath.len == 0 or relPath.startsWith("/") or relPath.startsWith("\\"):
    return "it must be a relative path"
  for part in parts:
    if part.len == 0 or part == "." or part == "..":
      return "it must not contain empty, '.' or '..' components"
  if parts.len < 2 or parts[0] != placed:
    return "it must be a path inside " & placed & ", starting with '" &
      placed & "/'"
  ""

proc launcherExecutablePath*(record: RealizedRecord;
                             executableRelPath, applicationsDir: string):
    string =
  ## The executable a launcher of ``record`` runs. ``executableRelPath`` is
  ## the launcher's declared command ("" for the package's own executable).
  ## For an application whose bundle is placed in ``applicationsDir``, the
  ## path inside the PLACED copy (see above); otherwise the realized prefix.
  ## ``applicationsDir`` is "" when the apply places nothing (a remote
  ## bundle build), which keeps the store path.
  var rel = executableRelPath
  if rel.len == 0 and record.prefixAbsolutePath.len > 0 and
      record.resolvedExecutablePath.startsWith(
        record.prefixAbsolutePath & DirSep):
    rel = record.resolvedExecutablePath[record.prefixAbsolutePath.len + 1 ..
      ^1]
  if applicationsDir.len > 0 and record.appBundle.storeBundlePath.len > 0 and
      rel.len > 0 and
      rel.replace('\\', '/').split('/')[0] == record.appBundle.bundleName:
    return applicationsDir / rel
  if executableRelPath.len > 0:
    record.prefixAbsolutePath / executableRelPath
  else:
    record.resolvedExecutablePath

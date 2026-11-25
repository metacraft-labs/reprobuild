## `repro home adopt` carries the active generation forward.
##
## Adopt claims an existing object without changing it
## (the `repro home adopt` specification, § Carry-forward). The new generation is therefore the active generation plus the
## adopted binding: only the packages that own the adopted addresses are
## resolved and realized, and every other package, launcher, generated file,
## managed block and resource binding of the active generation is carried over
## as recorded. The pipeline (`pipeline.nim`) skips its file, block and
## resource steps for an adopt run and composes the manifest with
## `carryForwardManifest`.
##
## This module holds the pure parts (which packages an adopt names, how the
## manifest is composed) and the one filesystem part (copying the carried
## launchers), so each is testable without running an apply.

import std/[options, os, sequtils, sets, strutils, tables]
from repro_core/paths import extendedPath
import repro_home_generations
import repro_home_resources
import repro_launch_plan

proc adoptedPackageIds*(addresses: openArray[string]): HashSet[string] =
  ## The packages whose realization an adopt of ``addresses`` needs: the owner
  ## of each synthesized application-bundle address (`home.package.<id>.app`).
  ## An address that names no package (a file, a managed block, a setting)
  ## needs no realization.
  result = initHashSet[string]()
  for address in addresses:
    let id = packageIdOfAppBundleAddress(address)
    if id.len > 0:
      result.incl(id)

proc carryForwardManifest*(prev: Option[ActivationManifest];
                           adoptedPackageIds: HashSet[string];
                           adoptedCommandNames: HashSet[string];
                           realized: seq[RealizedPackage];
                           launchers: seq[ExportedCommand];
                           adoptedBindings: seq[ResourceBinding]):
    ActivationManifest =
  ## The adopt generation's manifest: ``prev`` (the active generation's, or
  ## empty when there is none) with
  ## * the records of ``adoptedPackageIds`` replaced by ``realized``,
  ## * the commands of ``adoptedCommandNames`` (every command the adopted
  ##   packages plan, so one the package no longer plans is dropped)
  ##   replaced by ``launchers``, and
  ## * the bindings at the addresses of ``adoptedBindings`` replaced by them.
  ## Everything else, including bindings whose resource the profile no longer
  ## declares, stays as recorded.
  if prev.isSome:
    result = prev.get
  else:
    result = ActivationManifest(schemaVersion: ManifestSchemaVersion)
  result.realizedPackages = result.realizedPackages.filterIt(
    it.packageId notin adoptedPackageIds) & realized
  var newCommands = initHashSet[string]()
  for l in launchers:
    newCommands.incl(l.commandName)
  result.exportedCommands = result.exportedCommands.filterIt(
    it.commandName notin adoptedCommandNames and
    it.commandName notin newCommands) & launchers
  var adoptedAddresses = initHashSet[string]()
  for b in adoptedBindings:
    adoptedAddresses.incl(b.resourceAddress)
  result.resourceBindings = result.resourceBindings.filterIt(
    it.resourceAddress notin adoptedAddresses) & adoptedBindings

proc carriedCommands*(manifest: ActivationManifest;
                      materialized: seq[ExportedCommand]): seq[ExportedCommand] =
  ## The commands of ``manifest`` that ``materialized`` did not just write:
  ## the launchers to copy from the active generation's bin directory.
  var written = initHashSet[string]()
  for m in materialized:
    written.incl(m.commandName)
  manifest.exportedCommands.filterIt(it.commandName notin written)

proc copyCarriedLaunchers*(prevBinDir, newBinDir: string;
                           carried: seq[ExportedCommand]) =
  ## Copy each carried launcher (and, on Windows, the launch-plan sidecar
  ## beside its `.exe`) from the active generation's bin directory into the
  ## new generation's, keeping the file mode. A launcher the active
  ## generation's directory does not hold is an error: the manifest names it.
  createDir(extendedPath(newBinDir))
  for c in carried:
    let rel = c.binDirRelativePath
    if rel.len == 0 or isAbsolute(rel) or ".." in rel.split({'/', '\\'}):
      raise newException(IOError, "repro home adopt: the active generation " &
        "records command '" & c.commandName & "' at '" & rel &
        "', which is not a path inside its bin directory")
    let src = prevBinDir / rel
    if not fileExists(extendedPath(src)):
      raise newException(IOError, "repro home adopt: the active generation " &
        "records command '" & c.commandName & "' at " & src &
        ", which does not exist; run `repro home apply` instead")
    let dst = newBinDir / rel
    createDir(extendedPath(parentDir(dst)))
    copyFileWithPermissions(extendedPath(src), extendedPath(dst))
    let sidecar = src & LaunchPlanSidecarSuffix
    if fileExists(extendedPath(sidecar)):
      copyFileWithPermissions(extendedPath(sidecar),
        extendedPath(dst & LaunchPlanSidecarSuffix))

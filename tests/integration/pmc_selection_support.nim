## Shared helpers for the Platform-And-Microarchitecture-Constraints tests
## after GM4b.
##
## Selection now runs over ``tarball`` realization records
## (``InterfaceTarballProvisioning``) through
## ``realization_selection.selectTarballRecord`` / ``selectRealization`` —
## the one selection a recipe's ``uses:`` and a home profile share. These
## helpers build such records the way a package's ``tarball`` statement
## projects them, and run selection for an explicit synthetic target, so the
## PMC tests stay hermetic (no v2/v3/v4 hardware) and test the production
## code path. Nothing here is a mock: the records are plain data and the
## selection is the real one.

import std/[options]

import repro_interface_artifacts
import repro_project_dsl
import repro_tool_profiles/realization_selection

export repro_interface_artifacts, realization_selection
export TarballArchiveDetail

proc tarballRecord*(url, sha256: string; cpu = "x86_64"; os = "linux";
                    level = ""; features = ""; version = "1.0.0";
                    contributor = ""; executablePath = "bin/demo"):
    InterfaceTarballProvisioning =
  ## One ``tarball`` realization, as ``tarball url = ..., cpu = ..., os =
  ## ..., cpuLevel = ..., cpuFeatures = ...`` projects it.
  InterfaceTarballProvisioning(packageName: "demo", contributor: contributor,
    url: url, sha256: sha256, archiveType: "tar.gz",
    executablePath: executablePath, cpu: cpu, os: os,
    packageId: "demo@" & version,
    detail: TarballArchiveDetail(version: version, cpuLevel: level,
      cpuFeatures: features))

proc demoUse*(records: openArray[InterfaceTarballProvisioning]):
    InterfaceToolUse =
  result = InterfaceToolUse(rawConstraint: "demo", packageSelector: "demo",
    executableName: "demo")
  result.tarballProvisioning = @records

proc targetOf*(cpu: PlatformCpu; os: PlatformOs; level = mlNone;
               features: set[CpuFeature] = {}): RealizationTarget =
  realizationTargetFor(cpu, os, level, features)

proc selectFor*(records: openArray[InterfaceTarballProvisioning];
                cpu: PlatformCpu; os: PlatformOs; level = mlNone;
                features: set[CpuFeature] = {}; version = ""):
    tuple[choice: KindChoice; record: InterfaceTarballProvisioning] =
  ## ``selectTarballRecord`` for a synthetic target; ``record`` is the
  ## selected record (default when nothing was selected).
  let choice = selectTarballRecord(records, targetOf(cpu, os, level,
    features), version, none(string))
  result.choice = choice
  if choice.status == kcSelected:
    result.record = records[choice.index]

proc resolveDemo*(records: openArray[InterfaceTarballProvisioning];
                  target: RealizationTarget): RealizationSelection =
  ## The full selection (policy ``[tarball]``) — raises
  ## ``EMissingRealization`` whose message names the package, the target and
  ## the per-kind reason.
  selectRealization(demoUse(records), SelectionRequest(packageName: "demo",
    target: target, policy: @[rkTarball], definitionKnown: true))

## Compatibility entry point for home archive conformance callers.
## Both callers realize and probe each record through tarball_conformance,
## including its strict primary executable and every extra/alias binding.

import repro_interface_artifacts
import repro_tool_profiles/tarball_conformance

type
  ArchiveArmConformanceVerdict* = enum
    aacOk = "ok"
    aacOwnedByUsesEdge = "owned-by-uses-edge"
      ## Legacy verdict; unified realization never produces it.
    aacProjectionFailed = "projection-failed"
      ## Legacy verdict; decoding refusals are shared realization failures.
    aacRealizeFailed = "realize-failed"
    aacDeclaredExecutableMissing = "declared-executable-missing"
    aacDeclaredExecutableNotExecutable = "declared-executable-not-executable"
    aacDeclaredExecutableOutsidePrefix = "declared-executable-outside-prefix"
    aacDeclaredExecutableSymlinked = "declared-executable-symlinked"
    aacDeclaredExtraExecutableUnbound = "declared-extra-executable-unbound"
    aacDeclaredAliasMissing = "declared-alias-missing"

  ArchiveArmConformance* = object
    packageSelector*: string
    url*: string
    declaredExecutablePath*: string
    archiveType*: string
    os*: string
    cpu*: string
    verdict*: ArchiveArmConformanceVerdict
    detail*: string
    prefix*: string
    resolvedExecutablePath*: string

proc conformArchiveArm*(packageSelector: string;
                        arm: InterfaceTarballProvisioning;
                        storeDir: string): ArchiveArmConformance =
  ## Preserve the home caller API while sharing realization and every probe.
  let useDef = InterfaceToolUse(rawConstraint: packageSelector,
    packageSelector: packageSelector, executableName: packageSelector,
    tarballProvisioning: @[arm])
  let shared = conformTarballArm(useDef, arm, storeDir)
  result = ArchiveArmConformance(packageSelector: shared.packageSelector,
    url: shared.url, declaredExecutablePath: shared.declaredExecutablePath,
    archiveType: shared.archiveType, os: shared.os, cpu: shared.cpu,
    detail: shared.detail, prefix: shared.prefix,
    resolvedExecutablePath: shared.resolvedExecutablePath)
  result.verdict =
    case shared.verdict
    of acvOk: aacOk
    of acvOwnedByHomeRealizer: aacRealizeFailed
    of acvRealizeFailed: aacRealizeFailed
    of acvDeclaredExecutableMissing: aacDeclaredExecutableMissing
    of acvDeclaredExecutableSymlinked: aacDeclaredExecutableSymlinked
    of acvDeclaredExecutableNotExecutable: aacDeclaredExecutableNotExecutable
    of acvDeclaredExecutableOutsidePrefix: aacDeclaredExecutableOutsidePrefix
    of acvDeclaredExtraExecutableUnbound: aacDeclaredExtraExecutableUnbound
    of acvDeclaredAliasMissing: aacDeclaredAliasMissing

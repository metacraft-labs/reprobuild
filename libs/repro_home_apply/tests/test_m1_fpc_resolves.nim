## M1 (Realize-Closure spec) → GM4b — fpc resolves on a Windows target
## through its `tarball` realization.
##
## Validates the resolution path the M1 spec unblocked for the M71 Pascal
## Phase-2 partial, restated for GM4b (the `fpcCatalog` record is now a
## `tarball` realization of `package fpc:`):
##
##   * the engine links a definition of `fpc`, whose only archive is the
##     upstream Windows installer pinned by a SHA-1 (the M1 weak-hash case:
##     upstream publishes nothing stronger);
##   * a profile reference resolves, for an x86_64-windows target under the
##     default policy, to that `tarball` realization at version 3.2.2;
##   * both callers project that same Inno Setup realization through the
##     provisioning edge, retaining its SHA-1 digest and installer metadata;
##   * its installer helper is an explicit provisioning requirement.
##
## Nothing is realized (no network). No mocks.

import std/[options, unittest]

import repro_dsl_stdlib/package_registry
import repro_tool_profiles
import repro_home_apply/package_catalog

let windowsX64 = realizationTargetFor(pcX86_64, poWindows, mlX86_64_v1)

suite "M1/GM4b — fpc end-to-end resolvable":

  test "the engine links fpc, with a sha1-pinned Windows archive at 3.2.2":
    check isLinkedPackage("fpc")
    let useDef = profileToolUse("fpc").useDef
    check useDef.tarballProvisioning.len == 1
    let record = useDef.tarballProvisioning[0]
    check record.os == "windows"
    check record.detail.version == "3.2.2"
    check record.sha256 == ""
    check record.detail.sha512 == ""
    check record.detail.sha1.len == 40
    check offeredVersions("fpc") == @["3.2.2"]

  test "fpc resolves via its tarball realization on x86_64-windows":
    let r = resolveProfilePackage("fpc", windowsX64, DefaultSelectionPolicy)
    check r.selection.kind == rkTarball
    check r.selection.version == "3.2.2"
    check r.selection.lockIdentity == "sha1:" & r.selection.tarball.detail.sha1
    check r.archiveRoute == arExtract
    check r.archive.builtinVersion == "3.2.2"
    check r.archive.digestAlgorithm == "sha1"
    check r.archive.digestValue.len == 40
    check r.archive.installMethod == imInstallerInnoSetup
    check r.selection.trace.len == 1
    check r.selection.trace[0].kind == rkTarball
    check r.selection.trace[0].selected

  test "a recipe's uses: edge accepts the same installer record and digest":
    let useDef = profileToolUse("fpc").useDef
    let home = resolveProfilePackage("fpc", windowsX64, DefaultSelectionPolicy)
    let recipe = tarballAcquisitionPlan(useDef, target = windowsX64)
    check recipe.record == home.selection.tarball
    check recipe.digestAlgorithm == "sha1"
    check recipe.digestValue == home.archive.digestValue
    check recipe.url == home.archive.urlUsed
    check recipe.record.detail.installMethod == "installer-inno-setup"
    check "innounp" in installationToolRoles(recipe.record)

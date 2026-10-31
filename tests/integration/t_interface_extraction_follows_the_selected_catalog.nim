## Selecting a different `reprobuild-packages` catalog re-extracts the project
## interface instead of serving the previous catalog's.
##
## reprobuild-specs issues/2026-10-02-...-ignores-the-catalog-a-package-
## resolves-from.md: `$REPROBUILD_PACKAGES_ROOT` decides which module a
## `uses:` of a catalog package imports, and the recipe's text does not change
## when it does. The extraction cache was keyed on the recipe's import closure
## and reprobuild's own sources only, so after switching catalogs it kept
## serving the interface of the first one: the new catalog's realizations
## never reached the dev environment. `catalogSelectionIdentity` is now part
## of the extraction's identity.
##
## Real compiles throughout: the same consumer is extracted twice into the same
## artifact path, once per catalog, by the real in-process extractor; nothing
## is mocked. The two catalogs define the same package with different tarball
## realizations, so the second extraction is right only if it re-ran.

import std/[os, tempfiles, unittest]

import repro_interface_artifacts
import repro_project_dsl

proc writeCatalog(root, packageId: string) =
  let dir = root / "packages" / "interfaces" / "rpselectedfixture"
  createDir(dir)
  writeFile(dir / "repro.nim", """
import repro_project_dsl

package rpselectedfixture:
  provisioning:
    tarball url = "https://example.invalid/""" & packageId & """.zip",
      sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
      archiveType = "zip",
      executablePath = "rpselectedfixture",
      packageId = """" & packageId & """",
      lockIdentity = "tarball:""" & packageId & """:sha256:0000000000000000000000000000000000000000000000000000000000000000"
""")

proc fixturePackageIds(artifact: ProjectInterfaceArtifact): seq[string] =
  for use in artifact.projectInterface.toolUses:
    if use.packageSelector == "rpselectedfixture":
      for realization in use.tarballProvisioning:
        result.add(realization.packageId)

suite "interface extraction follows the selected catalog":
  test "switching REPROBUILD_PACKAGES_ROOT re-extracts against the new catalog":
    let scratch = createTempDir("repro-selected-catalog-", "")
    let previous = getEnv(ReprobuildPackagesRootEnv)
    let hadPrevious = existsEnv(ReprobuildPackagesRootEnv)
    defer:
      if hadPrevious: putEnv(ReprobuildPackagesRootEnv, previous)
      else: delEnv(ReprobuildPackagesRootEnv)
      removeDir(scratch)
    let catalogA = scratch / "catalog-a"
    let catalogB = scratch / "catalog-b"
    writeCatalog(catalogA, "rpselectedfixture@1.0")
    writeCatalog(catalogB, "rpselectedfixture@2.0")
    let project = scratch / "consumer"
    createDir(project)
    let modulePath = project / "repro.nim"
    writeFile(modulePath, """
import repro_project_dsl

package selectedCatalogConsumer:
  defaultToolProvisioning "tarball"
  uses:
    "rpselectedfixture"
""")
    let artifactPath = scratch / "out" / "project-interface.rbsz"
    let stubPath = scratch / "out" / "project-interface.nim"
    createDir(artifactPath.parentDir)

    putEnv(ReprobuildPackagesRootEnv, catalogA)
    let first = extractInterfaceFromModule(modulePath, artifactPath, stubPath,
      getCurrentDir())
    check fixturePackageIds(first) == @["rpselectedfixture@1.0"]

    putEnv(ReprobuildPackagesRootEnv, catalogB)
    let second = extractInterfaceFromModule(modulePath, artifactPath, stubPath,
      getCurrentDir())
    check fixturePackageIds(second) == @["rpselectedfixture@2.0"]

    # Positive control for the cache itself: selecting B again is a warm hit
    # that still answers B.
    let third = extractInterfaceFromModule(modulePath, artifactPath, stubPath,
      getCurrentDir())
    check fixturePackageIds(third) == @["rpselectedfixture@2.0"]

## A `uses:` name the stdlib does not bundle resolves from the
## `reprobuild-packages` catalog.
##
## Package definitions are moving from the engine's bundled stdlib into
## `reprobuild-packages` (reprobuild-specs/Provisioning-Contributions.md,
## "Repository Composition"); `sqlite3` was the first. A recipe still writes a
## plain `uses: "sqlite3"`, so the auto-import has to find the moved module:
## `reprobuildPackagesInterfaceModule` looks for
## `<catalog>/packages/interfaces/<name>/repro.nim`, where the catalog is
## `$REPROBUILD_PACKAGES_ROOT`, a `reprobuild-packages` beside the consumer or
## an ancestor of it, or one beside the reprobuild checkout.
##
## The fixture catalog is `tests/reprobuild-packages`, which the walk up from
## this file reaches first. Remove the catalog branch from `usesImportCode`
## and `rpcatalogfixture` is never imported: it is not registered, and the
## consumer's tool use carries no provisioning.

import std/[sequtils, unittest]

import repro_interface_artifacts
import repro_project_dsl

package rpCatalogConsumer:
  defaultToolProvisioning "tarball"
  uses:
    "rpcatalogfixture"
    # Neither stdlib nor catalog: stays unresolved, as before.
    "rpcatalognosuchpackage"

suite "uses: resolves a reprobuild-packages interface":
  test "the catalog's package is imported and its provisioning reaches the tool use":
    check registeredPackages().anyIt(it.packageName == "rpcatalogfixture")

    let artifact = artifactFromRegisteredDsl(currentSourcePath())
    let fixtureUse = artifact.projectInterface.toolUses.filterIt(
      it.packageSelector == "rpcatalogfixture")
    check fixtureUse.len == 1
    check fixtureUse[0].tarballProvisioning.len == 1
    check fixtureUse[0].tarballProvisioning[0].packageId == "rpcatalogfixture@1.0"

  test "a name no catalog defines stays unresolved":
    check not registeredPackages().anyIt(
      it.packageName == "rpcatalognosuchpackage")

  test "the lookup rejects names that are not bare package names":
    check reprobuildPackagesInterfaceModule("../etc", currentSourcePath()) == ""
    check reprobuildPackagesInterfaceModule("a/b", currentSourcePath()) == ""
    check reprobuildPackagesInterfaceModule("", currentSourcePath()) == ""

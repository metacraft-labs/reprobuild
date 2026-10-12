## A `nativeBuildDeps:` or `runtimeDeps:` name the stdlib does not bundle
## resolves from the `reprobuild-packages` catalog, exactly as a `uses:` name
## does.
##
## reprobuild-specs/Provisioning-Contributions.md, "Catalog Lookup And
## Provisioning": a moved package resolves from the catalog wherever a recipe
## names it. Before this test, `usesImportCode` consulted the catalog only for
## `uses:` (`pkg.toolUses`); its dependency-only import loop looked at the
## bundled stdlib list alone. A package that moved out of the stdlib therefore
## stopped being imported the moment a recipe named it in a dependency list:
## it was not registered, and the dependency's tool use carried no
## provisioning, with no diagnostic.
##
## The fixture catalog is `tests/reprobuild-packages`, which the lookup's walk
## up from this file reaches first (see
## `t_uses_resolves_reprobuild_packages_interface`). Nothing is mocked: the
## real `package` macro expands the consumers below and the real interface
## extractor lowers them.

import std/[sequtils, unittest]

import repro_interface_artifacts
import repro_project_dsl

package rpCatalogNativeDepConsumer:
  defaultToolProvisioning "tarball"
  nativeBuildDeps:
    "rpcatalogfixture"

package rpCatalogRuntimeDepConsumer:
  defaultToolProvisioning "tarball"
  runtimeDeps:
    "rpcatalogruntimefixture"

proc dependencyUse(consumer, selector: string): seq[InterfaceToolUse] =
  for pkg in registeredPackages():
    if pkg.packageName != consumer:
      continue
    let iface = toProjectInterface(pkg, registeredPackages(),
      registeredProvisioningContributions())
    return iface.toolUses.filterIt(it.packageSelector == selector)

suite "dependency lists resolve a reprobuild-packages interface":
  test "nativeBuildDeps: the catalog's package is imported and its provisioning reaches the dependency":
    check registeredPackages().anyIt(it.packageName == "rpcatalogfixture")
    let uses = dependencyUse("rpCatalogNativeDepConsumer", "rpcatalogfixture")
    check uses.len == 1
    if uses.len == 1:
      check uses[0].tarballProvisioning.len == 1
      if uses[0].tarballProvisioning.len == 1:
        check uses[0].tarballProvisioning[0].packageId == "rpcatalogfixture@1.0"

  test "runtimeDeps: the catalog's package is imported and its provisioning reaches the dependency":
    check registeredPackages().anyIt(
      it.packageName == "rpcatalogruntimefixture")
    let uses = dependencyUse("rpCatalogRuntimeDepConsumer",
      "rpcatalogruntimefixture")
    check uses.len == 1
    if uses.len == 1:
      check uses[0].tarballProvisioning.len == 1
      if uses[0].tarballProvisioning.len == 1:
        check uses[0].tarballProvisioning[0].packageId ==
          "rpcatalogruntimefixture@2.0"

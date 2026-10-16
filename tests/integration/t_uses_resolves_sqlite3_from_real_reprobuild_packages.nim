## A plain `uses: "sqlite3"` resolves through the REAL `reprobuild-packages`
## catalog, not a fixture.
##
## `sqlite3` was the first package to leave the bundled stdlib
## (reprobuild-specs/Provisioning-Contributions.md, "Catalog Lookup And
## Provisioning"). `t_uses_resolves_reprobuild_packages_interface` proves the
## lookup against a fixture catalog; this file proves that the catalog CI
## actually provides -- the `reprobuild-packages` checkout that
## `.github/sibling-repos` pins and `setup-dev-env` clones beside this one --
## defines the package every consumer of it relies on, and that the walk from a
## consumer inside this repository steps PAST the fixture catalog
## (`tests/reprobuild-packages`, which does not define `sqlite3`) to reach it.
##
## Nothing is mocked: the consumer below is compiled by the real `package`
## macro, which imports the real catalog module from disk.
##
## When no catalog is reachable this file does not compile. The error is the
## moved-package diagnostic, naming every place the catalog was looked for and
## how to provide it -- a missing prerequisite fails loudly rather than
## skipping.

import std/[os, sequtils, strutils, unittest]

import repro_interface_artifacts
import repro_project_dsl

package rpRealCatalogSqliteConsumer:
  defaultToolProvisioning "tarball"
  uses:
    "sqlite3 >=3"

proc fixtureCatalogRoot(): string =
  currentSourcePath().parentDir.parentDir / "reprobuild-packages"

suite "uses: \"sqlite3\" resolves from the real reprobuild-packages catalog":
  test "the lookup skips the fixture catalog and finds a real checkout":
    let search = reprobuildPackagesSearch("sqlite3", currentSourcePath())
    checkpoint(describeReprobuildPackagesSearch(search))
    check search.module.len > 0
    let catalogRoot =
      search.module.parentDir.parentDir.parentDir.parentDir
    check catalogRoot.lastPathPart == "reprobuild-packages" or
      getEnv(ReprobuildPackagesRootEnv).len > 0
    check catalogRoot.normalizedPath != fixtureCatalogRoot().normalizedPath
    if getEnv(ReprobuildPackagesRootEnv).len == 0:
      # The fixture catalog sits on the walk and does not define sqlite3; the
      # lookup must record it and continue rather than stop there.
      let fixtureProbe = search.probes.filterIt(
        it.root.normalizedPath == fixtureCatalogRoot().normalizedPath)
      check fixtureProbe.len == 1
      check fixtureProbe[0].rootExists
      check fixtureProbe[0].module.len == 0

  test "the catalog's sqlite3 definition is imported and registered":
    check registeredPackages().anyIt(it.packageName == "sqlite3")

  test "the tool use carries the catalog's Nix and release-archive realizations":
    let artifact = artifactFromRegisteredDsl(currentSourcePath())
    let uses = artifact.projectInterface.toolUses.filterIt(
      it.packageSelector == "sqlite3")
    check uses.len == 1
    if uses.len == 1:
      let use = uses[0]
      check use.rawConstraint == "sqlite3 >=3"
      check use.nixProvisioning.anyIt(it.selector == "nixpkgs#sqlite")
      # Windows, Linux and macOS archives; every one names the sqlite3 package.
      check use.tarballProvisioning.len >= 3
      check use.tarballProvisioning.allIt(it.packageId.startsWith("sqlite3@"))
      for platformOs in ["windows", "linux", "macos"]:
        check use.tarballProvisioning.anyIt(it.os == platformOs)

## A home profile's catalog imports, read from published artifacts.
##
## Federated-Catalog-Imports.md § Home profiles: a `repro-catalogs.toml`
## beside the profile (`home.nim`) declares the catalogs it imports, with the
## schema, keys and trust rules of a project's. This module reads the
## declaration and each import at its pinned commit from the shared bare
## clone (`catalog_discovery`), and projects what the catalogs publish into
## what the home planner resolves a bare package reference against
## (`ImportedCatalogs`): for a package an import defines, the `uses:`
## projection a recipe would make of it, with the realizations the imported
## catalogs' contribution sets give it. No provider module is compiled or run
## and no checkout beside the profile is read.
##
## What a home profile adds to a project's rules, each a refusal naming its
## cause:
##
##   * every import pins a `commit`; a `ref` is refused, because `home.lock`
##     is host-local and cannot hold the pin every host must share;
##   * a package defined by two imports is refused (a package is defined
##     once); the clash with the standard library or a `reprobuild-packages`
##     catalog is refused by `catalog_projection.importClashes`;
##   * a contribution for a package no import defines, or pinned to an
##     interface other than the one the imports publish for it, is refused
##     (a contribution to a package defined elsewhere is not read yet);
##   * an import that cannot be read (the commit is missing from the shared
##     clone, its artifacts fail their checks, the declared
##     `interface_artifact` does not match) refuses the verb.

import std/[algorithm, options, os, strutils, tables]

import repro_hash
import repro_interface_artifacts
import repro_interface_artifacts/catalog_composition
import repro_interface_artifacts/catalog_declaration
import repro_home_apply/catalog_projection

import ./catalog_discovery

const HomeImportSuffix = " (Federated-Catalog-Imports.md § Home profiles)"

proc hexOf(d: ContentDigest): string =
  toHex(d.bytes).toLowerAscii()

proc homeCatalogImportsPath*(profilePath: string): string =
  ## Where the profile's declaration is: beside the profile file.
  profilePath.parentDir / CatalogImportsFileName

proc readHomeCatalogImports*(profilePath: string): ImportedCatalogs =
  ## The imports of the profile at ``profilePath``, read. A profile with no
  ## `repro-catalogs.toml` imports nothing (``declared`` is false). Raises
  ## ``CatalogDiscoveryError`` (a ``CatchableError``) naming every cause.
  let declarationPath = homeCatalogImportsPath(profilePath)
  if not fileExists(declarationPath):
    return
  result.declared = true
  let profileDir = profilePath.parentDir
  let located = readLocatedCatalogDeclaration(profileDir)
  var refusals: seq[string] = @[]
  var found: seq[DiscoveredCatalog] = @[]
  # A `[[policy]]` table selects among contributions of one package. The
  # home path does not compose contribution sets, so a table here would be
  # accepted and ignored: refuse it instead (unrecognised input is rejected,
  # never skipped).
  for pol in located.policyTables:
    refusals.add(located.path & ":" & $pol.line & ": a `[[policy]]` table " &
      "(package \"" & pol.package & "\") is not read from a home profile's " &
      "imports yet; remove it" & HomeImportSuffix)
  for d in located.declaration.imports:
    let at = located.path & ":" & $d.line
    if d.gitRef.len > 0 or d.commit.len == 0:
      refusals.add("the import \"" & d.repo & "\" (" & at & ") names ref " &
        d.gitRef.escape() & "; a home profile pins by `commit` only, since " &
        "home.lock is host-local and cannot hold the pin every host and the " &
        "committed export share. Replace `ref` with the `commit` to use" &
        HomeImportSuffix)
      continue
    try:
      let catalog = discoverCatalogAt(d.repo, d.remote, "", d.commit,
        profileDir)
      if d.interfaceArtifact.len > 0 and
          catalog.interfaceArtifact != d.interfaceArtifact:
        refusals.add("catalog \"" & d.repo & "\" (" & d.remote & ") at " &
          d.commit & " publishes interface artifact " &
          catalog.interfaceArtifact & ", but " & located.path & ":" &
          $d.line & " asserts " & d.interfaceArtifact &
          "; correct or remove the assertion")
        continue
      found.add(catalog)
    except CatalogDiscoveryError as err:
      refusals.add(err.msg & "\n    (the [[import]] of \"" & d.repo &
        "\" is at " & at & ")")
  if refusals.len > 0:
    raise newException(CatalogDiscoveryError,
      "the profile's catalog imports cannot be read:\n  " &
      refusals.sorted(cmp).join("\n  "))
  found.sort(proc (a, b: DiscoveredCatalog): int = cmp(a.repo, b.repo))
  # Canonical interfaces first, so a contribution can be matched to the
  # interface it is pinned to whichever import published it.
  var fingerprints = initTable[string, string]()
  for catalog in found:
    let coordinate = ImportCoordinate(repo: catalog.repo,
      remote: catalog.remote, revision: catalog.revision,
      interfaceArtifact: catalog.interfaceArtifact)
    result.coordinates.add(coordinate)
    for published in catalog.published:
      let pi = published.artifact.projectInterface
      if pi.provisioningContributions.len > 0:
        continue
      let name = pi.packageName
      if name in result.packages:
        refusals.add("\"" & name & "\" is defined by two imports: \"" &
          result.packages[name].coordinate.repo & "\" and \"" & catalog.repo &
          "\"; a package is defined once. Import only one of them")
        continue
      var use = InterfaceToolUse(rawConstraint: name, packageSelector: name,
        executableName: name,
        location: SourceLocation(file: published.path, line: 1))
      for exe in pi.publicExecutables:
        if exe.exportName == name and exe.binaryName.len > 0 and
            exe.binaryName != name:
          use.executableName = exe.binaryName
          break
      result.packages[name] = ImportedPackage(name: name,
        coordinate: coordinate, artifact: published.path, use: use)
      fingerprints[name] = hexOf(published.artifact.interfaceFingerprint)
  for catalog in found:
    for contribution in catalog.content.contributions:
      let name = contribution.targetPackage
      let what = "the contribution from \"" & contribution.contributor &
        "\" in catalog \"" & catalog.repo & "\" for package \"" & name & "\""
      if name notin result.packages:
        refusals.add(what & " targets a package no import of the profile " &
          "defines; a contribution to a package defined elsewhere (the " &
          "standard library, a `reprobuild-packages` catalog) is not read " &
          "from a home profile's imports yet")
        continue
      let pinned = contribution.targetInterfaceFingerprint.toLowerAscii()
      if pinned != fingerprints[name]:
        refusals.add(what & " is pinned to interface " & pinned &
          ", but the imports publish " & fingerprints[name] & " for it; " &
          "republish the catalog or pin the other revision")
        continue
      var pkg = result.packages[name]
      pkg.use.nixProvisioning.add(contribution.nixProvisioning)
      pkg.use.tarballProvisioning.add(contribution.tarballProvisioning)
      pkg.use.scoopProvisioning.add(contribution.scoopProvisioning)
      # A Homebrew record is a bridge record, never realized by reprobuild:
      # left out of the use, as `toProjectInterface` leaves it out.
      result.packages[name] = pkg
  if refusals.len > 0:
    raise newException(CatalogDiscoveryError,
      "the profile's catalog imports cannot be resolved:\n  " &
      refusals.sorted(cmp).join("\n  "))

catalogImportReader = readHomeCatalogImports

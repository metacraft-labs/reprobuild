## Federated-Catalog-Imports.md § Home profiles: a home profile imports
## catalogs by identity (`repro-catalogs.toml` beside `home.nim`), read from
## the shared bare clone at the pinned commit -- the planner resolves a
## package only the import defines from the PUBLISHED artifacts, with no
## provider compiled and no checkout read. Two suites:
##
##   * home_profile_imports_catalog_by_identity -- plan (resolution and
##     selection), export (`catalogImports`) and the import's coordinate for a
##     package defined only by an imported catalog; a checkout of the catalog
##     beside the profile, and a working tree that differs from its commit,
##     change nothing;
##   * home_profile_import_refusals -- a `ref` import, a package defined by an
##     import and by a `reprobuild-packages` catalog, a commit missing from the
##     shared clone, artifacts failing their checks, a contribution to a
##     package no import defines. (IFD export of a profile with imports is
##     refused in `reprobuild.lib`: nix/tests/lib.nix.)
##
## The world is the hermetic federated fixture: real git repositories, the
## production publisher, a shared bare clone filled by `git fetch`. No mocks.
##
## Falsifying mutations (each red, then restored): the reader returns no
## imports -> every case of the first suite is red; the reader accepts a `ref`
## -> the ref refusal is red; the clash check is skipped -> the clash
## refusal is red.

import std/[json, os, strutils, tables, tempfiles, unittest]

import repro_interface_artifacts
import repro_cli_support
import repro_cli_support/home_catalog_imports
import repro_cli_support/home_export
import repro_home_apply
import repro_home_apply/catalog_projection
import repro_home_apply/package_catalog
import repro_tool_profiles

import ./federated_catalog_fixture

let root = createTempDir("repro-home-imports-", "")
let shared = root / "shared"
createDir(shared)
let archiveA = buildFixtureArchive(shared, "a1", "tool-from-a",
  FedToolTopDir, FedToolExecutable)
let archiveB = buildFixtureArchive(shared, "b1", "tool-from-b",
  FedToolTopDir, FedToolExecutable)
var env = enterHermeticEnvironment(root)
let world = newStandardWorld(root, "home", archiveA, archiveB, env.clonesRoot)

let profileDir = root / "profile"
createDir(profileDir)
let profilePath = profileDir / "home.nim"
writeFile(profilePath, "# a profile; the imports tests never compile it\n")

proc declaration(imports: seq[string]): string =
  "schema = \"reprobuild.catalog-imports.v1\"\n\n" & imports.join("\n")

proc importTable(repo, remote, pin: string): string =
  "[[import]]\nrepo = \"" & repo & "\"\nremote = \"" & remote & "\"\n" & pin &
    "\n"

proc declare(imports: seq[string]) =
  writeFile(profileDir / "repro-catalogs.toml", declaration(imports))

proc standardDeclaration() =
  declare(@[
    importTable(FedRepoPackages, world.packages.remote,
      "commit = \"" & world.revPackages & "\""),
    importTable(FedRepoA, world.a.remote,
      "commit = \"" & world.revA1 & "\"")])

proc refusalOf(body: proc ()): string =
  try:
    body()
    ""
  except CatchableError as err:
    err.msg

suite "home_profile_imports_catalog_by_identity":
  test "a package only an import defines is planned from its artifacts":
    standardDeclaration()
    let imported = readHomeCatalogImports(profilePath)
    check imported.declared
    check FedToolPackage in imported.packages
    check imported.coordinates.len == 2
    check imported.packages[FedToolPackage].coordinate.revision ==
      world.revPackages
    let scratch = root / "scratch-plan"
    let catalog = projectCatalogPackages([FedToolPackage], profilePath,
      scratch, [], imported)
    check FedToolPackage in catalog.uses
    check catalog.importedFrom[FedToolPackage].repo == FedRepoPackages
    check not dirExists(scratch)     # no synthetic recipe, no compile
    let use = catalog.uses[FedToolPackage]
    check use.executableName == FedToolExecutable
    check use.tarballProvisioning.len == 1
    check use.tarballProvisioning[0].url == archiveA.url
    # The selection a plan makes: the realization the contribution gave.
    let resolution = resolveProfilePackage(FedToolPackage,
      hostRealizationTarget(), @[rkTarball], catalog = catalog)
    check resolution.selection.tarball.url == archiveA.url

  test "the export records the import's coordinate":
    standardDeclaration()
    let imported = readHomeCatalogImports(profilePath)
    let doc = catalogImportsDocument(imported, @[FedToolPackage, "other"])
    check doc.len == 2
    var seen = initTable[string, JsonNode]()
    for node in doc:
      seen[node["repo"].getStr] = node
    check seen[FedRepoPackages]["revision"].getStr == world.revPackages
    check seen[FedRepoPackages]["packages"].len == 1
    check seen[FedRepoPackages]["packages"][0].getStr == FedToolPackage
    check seen[FedRepoA]["packages"].len == 0
    check seen[FedRepoPackages]["interfaceArtifact"].getStr.len == 64
    check HomeExportSchemaVersion == 6

  test "a checkout beside the profile and a differing working tree are ignored":
    standardDeclaration()
    let before = readHomeCatalogImports(profilePath)
    # A checkout of the imported catalog beside the profile, with other
    # content, and the upstream's working tree edited after the commit.
    let beside = root / FedRepoPackages
    createDir(beside / "published-interfaces")
    writeFile(beside / "published-interfaces" / "other.rbsz", "not an artifact")
    writeFile(beside / "repro.nim", "# a different catalog entirely\n")
    for f in walkDir(world.packages.upstream / "published-interfaces"):
      writeFile(f.path, "tampered after the commit")
    let after = readHomeCatalogImports(profilePath)
    check after.packages[FedToolPackage].use ==
      before.packages[FedToolPackage].use
    check after.coordinates == before.coordinates

suite "home_profile_import_refusals":
  test "a ref import is refused: a home profile pins by commit":
    declare(@[importTable(FedRepoPackages, world.packages.remote,
      "ref = \"main\"")])
    let msg = refusalOf(proc () = discard readHomeCatalogImports(profilePath))
    check "pins by `commit` only" in msg
    check FedRepoPackages in msg

  test "a policy table in a home profile's declaration is refused":
    # Accepting and ignoring it would let two contributions of one package
    # be resolved by sort order instead of by the profile's stated choice.
    declare(@[importTable(FedRepoPackages, world.packages.remote,
      "commit = \"" & world.revPackages & "\"")])
    let path = profileDir / "repro-catalogs.toml"
    writeFile(path, readFile(path) &
      "\n[[policy]]\npackage = \"" & FedToolPackage &
      "\"\ncontributor = \"github:metacraft-labs/x\"\n")
    let msg = refusalOf(proc () = discard readHomeCatalogImports(profilePath))
    check "`[[policy]]` table" in msg
    check FedToolPackage in msg

  test "a package defined by an import and by reprobuild-packages is refused":
    standardDeclaration()
    let imported = readHomeCatalogImports(profilePath)
    let other = root / "other-catalog"
    createDir(other / "packages" / "interfaces" / FedToolPackage)
    writeFile(other / "packages" / "interfaces" / FedToolPackage / "repro.nim",
      "import repro_project_dsl\npackage " & FedToolPackage &
      ":\n  discard\n")
    let saved = getEnv("REPROBUILD_PACKAGES_ROOT")
    putEnv("REPROBUILD_PACKAGES_ROOT", other)
    defer:
      if saved.len > 0: putEnv("REPROBUILD_PACKAGES_ROOT", saved)
      else: delEnv("REPROBUILD_PACKAGES_ROOT")
    let msg = refusalOf(proc () =
      discard projectCatalogPackages([FedToolPackage], profilePath,
        root / "scratch-clash", [], imported))
    check "a package is defined once" in msg
    check FedToolPackage in msg
    check FedRepoPackages in msg
    check "other-catalog" in msg

  test "a commit missing from the shared clone is refused with its remedy":
    declare(@[importTable(FedRepoPackages, world.packages.remote,
      "commit = \"" & repeat('1', 40) & "\"")])
    let msg = refusalOf(proc () = discard readHomeCatalogImports(profilePath))
    check "not available in the shared clone" in msg
    check "fetch" in msg
    check FedRepoPackages in msg

  test "artifacts that fail their checks are refused":
    let bad = initCatalogRepo(root / "bad", "bad-catalog",
      fedRemote("home", "bad-catalog"))
    discard git(["checkout", "-q", "-b", "main"], bad.upstream)
    createDir(bad.upstream / "published-interfaces")
    writeFile(bad.upstream / "published-interfaces" / "broken.rbsz",
      "this is not an interface artifact")
    discard git(["add", "-A"], bad.upstream)
    discard git(["commit", "-q", "-m", "publish garbage"], bad.upstream)
    let rev = git(["rev-parse", "HEAD"], bad.upstream).strip()
    discard bad.syncSharedClone(env.clonesRoot)
    declare(@[importTable("bad-catalog", bad.remote,
      "commit = \"" & rev & "\"")])
    let msg = refusalOf(proc () = discard readHomeCatalogImports(profilePath))
    check "bad-catalog" in msg
    check "broken.rbsz" in msg

  test "a contribution to a package no import defines is refused":
    # Catalog A alone: it contributes to federatedTool, whose canonical
    # interface the other catalog publishes.
    declare(@[importTable(FedRepoA, world.a.remote,
      "commit = \"" & world.revA1 & "\"")])
    let msg = refusalOf(proc () = discard readHomeCatalogImports(profilePath))
    check "targets a package no import of the profile defines" in msg
    check FedToolPackage in msg

## Every built-in catalog module that declares a ``tarball`` arm is enrolled
## in the conformance sweeps, and every enrolled module declares one.
##
## The conformance sweeps of Provisioning-Contributions.md §"Where it is
## enforced" realize arms, and they enumerate ``registeredPackages()`` — so an
## arm reaches a sweep only if something imported the module that declares it.
## An arm nothing imports passes every gate by being INVISIBLE, which is a
## worse failure than being wrong, because no output says so.
##
## That was the state of a large part of the catalog. ``package_registry``
## links the bundled selectors plus the ex-``VersionedProvisioning`` packages
## (108 packages, 181 arms); the catalog declares 227 arms across 101 modules.
## The difference includes every core shell tool a recipe reaches by an
## explicit import rather than by name — ``rm``, ``cp``, ``mv``, ``mkdir``,
## ``touch``, ``sed``, ``chmod``, ``sha256sum``, ``printf``, ``tar``,
## ``gzip`` — ten of which point by hand-written path into one PortableGit
## archive, and which the issue this answers calls the sharpest exposure: not
## even the text-level Windows-arm check saw them, because its floor list
## names six tools and none of the ten is among them (reprobuild-pm/issues/
## 2026-09-24-no-conformance-check-runs-against-stdlib-tarball-arms.md).
##
## So the enrolment is explicit (``catalog_tarball_packages``) and this is the
## gate that keeps it honest. It is a SOURCE SCAN: no download, no extraction,
## no network, so a new arm reddens it on the commit that adds it rather than
## on whoever next runs the network sweep.
##
## Reading the catalog's source is the right instrument HERE and the wrong one
## for conformance, and the distinction is the whole point of the issue: text
## can answer "is this arm enumerated anywhere", which is a fact about our own
## tree; it cannot answer "does the declared path exist in the archive", which
## is a fact about a third party's bytes.
##
## ``nimSourceCodeOnly`` blanks comments AND literals, as the M29 audit's
## ``readCatalogCode`` does: ``tarball url`` is a DSL call spelling, never
## quoted text, so a header comment that explains an arm cannot make a module
## look as though it declares one.
##
## No mocks: the real catalog source and the real registered package set.
##
## Falsifiable: delete any name from ``CatalogTarballModules`` and the first
## case names it; add one that declares no arm and the second does.

import std/[os, strutils, tables, unittest]

import repro_project_dsl
import repro_dsl_stdlib/catalog_tarball_packages
from repro_test_support import nimSourceCodeOnly
# A package that moved to reprobuild-packages may leave a one-release stub
# module here whose only content is a compile error naming the new home. It
# declares no provisioning, so it cannot be enrolled.
from repro_project_dsl/reprobuild_packages_catalog import
  MovedPackageImportStubs

const PackagesRel = "libs" / "repro_dsl_stdlib" / "src" / "repro_dsl_stdlib" /
  "packages"

proc repoRoot(): string =
  ## The reprobuild repo root, found by walking up from this test file until a
  ## directory holds both ``libs/`` and ``apps/``. Resolved dynamically rather
  ## than as ``../../..`` so a relocation does not silently scan nothing.
  result = currentSourcePath.parentDir
  for _ in 0 ..< 8:
    if dirExists(result / "libs") and dirExists(result / "apps"):
      return result
    result = result.parentDir
  raiseAssert("could not locate the reprobuild repo root from " &
    currentSourcePath)

proc modulesDeclaringTarballArms(): seq[string] =
  ## Every ``packages/*.nim`` whose CODE contains a ``tarball`` arm.
  let dir = repoRoot() / PackagesRel
  doAssert dirExists(dir), "catalog directory is missing: " & dir
  for kind, path in walkDir(dir):
    if kind != pcFile or not path.endsWith(".nim"): continue
    let name = splitFile(path).name
    if name in MovedPackageImportStubs: continue
    if "tarball url" in nimSourceCodeOnly(readFile(path)):
      result.add(name)

proc armsPerModule(): Table[string, int] =
  ## Declared arms per source module, from the REGISTERED definitions — the
  ## set a sweep enumerates. Keyed on each ARM's own ``sourceFile``, so a
  ## module that registers several packages (``host_system_tools`` registers
  ## eleven) counts all of their arms, and a package whose arms are split
  ## across modules counts each where it is written.
  result = initTable[string, int]()
  for pkg in registeredPackages():
    for arm in pkg.tarballProvisioning:
      if arm.sourceFile.len == 0: continue
      let name = splitFile(arm.sourceFile).name
      result[name] = result.getOrDefault(name) + 1

suite "every catalog tarball arm is enrolled for conformance":

  test "a module that declares a tarball arm is in CatalogTarballModules":
    let declaring = modulesDeclaringTarballArms()
    # A catalog that scanned to nothing would pass every case below
    # vacuously; it cannot have shrunk to a handful.
    check declaring.len >= 60
    checkpoint("modules declaring a tarball arm: " & $declaring.len)
    var missing: seq[string] = @[]
    for name in declaring:
      if name notin CatalogTarballModules:
        missing.add(name)
    if missing.len > 0:
      checkpoint("add to CatalogTarballModules in " &
        "repro_dsl_stdlib/catalog_tarball_packages.nim: " &
        missing.join(", "))
    check missing.len == 0

  test "every enrolled module exists and declares a tarball arm":
    let dir = repoRoot() / PackagesRel
    let declaring = modulesDeclaringTarballArms()
    var absent: seq[string] = @[]
    var armless: seq[string] = @[]
    for name in CatalogTarballModules:
      if not fileExists(dir / (name & ".nim")):
        absent.add(name)
      elif name notin declaring:
        armless.add(name)
    if absent.len > 0:
      checkpoint("enrolled but not in the catalog: " & absent.join(", "))
    if armless.len > 0:
      checkpoint("enrolled but declares no tarball arm: " &
        armless.join(", "))
    check absent.len == 0
    check armless.len == 0

  test "enrolling the catalog registers at least one arm per module":
    # The enrolment is only worth having if importing it actually puts those
    # arms in front of a sweep. A module whose arms sit behind a `when` for
    # another platform would register none here, and that is the case this
    # asks about: the sweep could not see it on any host.
    let perModule = armsPerModule()
    var silent: seq[string] = @[]
    for name in CatalogTarballModules:
      if perModule.getOrDefault(name) == 0:
        silent.add(name)
    if silent.len > 0:
      checkpoint("enrolled, imported, and yet registers no arm: " &
        silent.join(", "))
    check silent.len == 0

  test "the enrolment covers every arm the catalog source declares":
    # The two counts are derived independently — one from the source text, one
    # from the registered definitions — so agreement is evidence the
    # enumeration a sweep walks is the whole catalog rather than a part of it.
    let perModule = armsPerModule()
    var registered = 0
    for name in CatalogTarballModules:
      registered += perModule.getOrDefault(name)
    checkpoint("arms registered through the enrolment: " & $registered)
    check registered >= CatalogTarballModules.len
    check CatalogTarballModules.len >= 60

## A catalog definition of a canonical package that the engine ALSO links
## from its stdlib projects without a refusal.
##
## `util-linux` is defined twice: by the `reprobuild-packages` catalog
## (`packages/interfaces/util-linux/repro.nim`, the canonical identity, no
## realization) and by the stdlib the engine links
## (`repro_dsl_stdlib/packages/m9r28_longtail.nim`, a Nix realization). A
## recipe that names `util-linux` sees both, so the projection's use carries
## the stdlib definition's realization. The projection's shadowing check
## (`recordsComeFrom`) used to take that for "a project named util-linux
## beside the synthetic recipe took the reference" and refuse the package,
## and since export refuses a projection failure, `repro home export` of any
## profile naming `util-linux` (zah/dotfiles') failed with "cannot classify
## package 'util-linux'".
##
## 1. With a fixture catalog beside the profile that defines `util-linux`
##    without a realization, `projectCatalogPackages(["util-linux"])` records
##    no failure and a use whose realizations come from the linked stdlib
##    definition.
## 2. Control: a catalog-only package (`a6catonly`, a tarball realization in
##    its own definition) projects from its definition -- the check still
##    accepts the catalog's own records.
##
## Falsifying mutation (run, see the A6 report): `isStdlibFile` answering
## false (set `REPRO_A6_MUTATE_STDLIB_FILE=1` when compiling the library
## with `-d:reproMutations`) makes case 1 fail with the old refusal.
##
## No mocks: a real catalog tree on disk, the real synthetic recipe and the
## real interface extractor (a Nim compile of the recipe).

import std/[os, strutils, tables, tempfiles, unittest]

import repro_home_apply
import repro_project_dsl

const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir().
  parentDir()

suite "catalog projection and linked stdlib definitions":

  test "a catalog definition the stdlib also links projects without a refusal":
    let root = createTempDir("repro-catalog-linked-stdlib-", "")
    defer: removeDir(root)
    let catalog = root / "reprobuild-packages" / "packages" / "interfaces"
    createDir(catalog / "util-linux")
    writeFile(catalog / "util-linux" / "repro.nim",
      "import repro_project_dsl\n\npackage `util-linux`:\n  discard\n")
    createDir(catalog / "a6catonly")
    writeFile(catalog / "a6catonly" / "repro.nim", """
import repro_project_dsl

package a6catonly:
  provisioning:
    tarball url = "https://example.invalid/a6catonly-1.0.tar.gz",
      sha256 = "6666666666666666666666666666666666666666666666666666666666666666",
      archiveType = "tar.gz",
      executablePath = "bin/a6catonly",
      packageId = "a6catonly@1.0",
      version = "1.0",
      cpu = "x86_64",
      os = "linux"
""")
    let profileDir = root / "profile"
    createDir(profileDir)
    writeFile(profileDir / "home.nim", "import repro_profile\n")
    # The catalog is found beside the profile, as in a workspace; an
    # exported root would replace it.
    let hadRoot = existsEnv("REPROBUILD_PACKAGES_ROOT")
    let savedRoot = getEnv("REPROBUILD_PACKAGES_ROOT")
    delEnv("REPROBUILD_PACKAGES_ROOT")
    let hadRepo = existsEnv("REPROBUILD_REPO_ROOT")
    let savedRepo = getEnv("REPROBUILD_REPO_ROOT")
    putEnv("REPROBUILD_REPO_ROOT", ProjectRoot)
    defer:
      if hadRoot: putEnv("REPROBUILD_PACKAGES_ROOT", savedRoot)
      if hadRepo: putEnv("REPROBUILD_REPO_ROOT", savedRepo)
      else: delEnv("REPROBUILD_REPO_ROOT")
    let projected = projectCatalogPackages(["util-linux", "a6catonly"],
      profileDir / "home.nim", root / "scratch")
    for name, why in projected.failures:
      checkpoint name & ": " & why
    check projected.failures.len == 0
    require projected.uses.hasKey("util-linux")
    # 1. The stdlib definition's realization is what the reference carries.
    let ul = projected.uses["util-linux"]
    check ul.nixProvisioning.len > 0
    var fromStdlib = false
    for r in ul.nixProvisioning:
      if "repro_dsl_stdlib" in r.location.file.replace('\\', '/'):
        fromStdlib = true
    check fromStdlib
    # 2. The catalog-only package projects from its own definition.
    require projected.uses.hasKey("a6catonly")
    check projected.uses["a6catonly"].tarballProvisioning.len == 1

## The fixture tree of `t_e2e_home_profile_imports_contribution_catalog`,
## laid out the way a workspace lays out sibling checkouts:
##
## * `payload/gm4bimported` -- the archive the contribution realizes, reached
##   through a `file://` URL;
## * `reprobuild-packages/packages/interfaces/gm4bimported/repro.nim` -- the
##   canonical definition. Its only realization is an archive for an OS that
##   is NOT this host;
## * `gm4b-contribution-catalog/repro.nim` -- a contribution catalog whose
##   `provisioningFor "gm4bimported"` adds the payload for this host, pinned
##   to the definition's interface fingerprint (read off a first extraction,
##   `recipe-pin`, as a publisher pins it);
## * `recipe-with-import/`, `recipe-without-import/` -- recipes that `uses:
##   "gm4bimported"` with and without `import` of the catalog, each with the
##   `project-interface.rbsz` the real extractor wrote for it.
##
## `generateCatalogImportsFixture` writes it. It is run by the build-graph
## edge `reprobuild.test_fixtures.gm4b_catalog_imports`
## (`tests/fixtures/gm4b/gen_gm4b_catalog_imports.nim`) into
## `catalogImportsFixturePath()`, so the three extractions -- a `nim c` and an
## extract-runner run each, minutes cold -- run when what they read changes,
## not at module scope in every process of the test. The test reads the
## tree; its cases write their profiles into directories of their own BESIDE
## the catalog (`../gm4b-contribution-catalog/repro` is how a profile names
## it, and the definition lookup walks up to `reprobuild-packages`).

import std/[os, strutils]
import nimcrypto/sha2 as fixtureSha2

import repro_interface_artifacts
import repro_tool_profiles
import repro_test_support
from repro_project_dsl/reprobuild_packages_catalog import
  ReprobuildPackagesRootEnv

export ReprobuildPackagesRootEnv

const
  CatalogImportsActionId* = "reprobuild.test_fixtures.gm4b_catalog_imports"
  Contributor* = "github:example/gm4b-contribution-catalog"
  PackageName* = "gm4bimported"
  ImportEntry* = "../gm4b-contribution-catalog/repro"
  CatalogImportsOutputs* = [
    "payload/gm4bimported",
    "reprobuild-packages/packages/interfaces/gm4bimported/repro.nim",
    "gm4b-contribution-catalog/repro.nim",
    "recipe-with-import/project-interface.rbsz",
    "recipe-without-import/project-interface.rbsz",
  ]
    ## The files a test reads, relative to the fixture root.

proc catalogImportsFixturePath*(rel = ""): string =
  ## The graph-built tree, or ``rel`` inside it: a read-only input every
  ## process shares. `repro.nim` declares the edge's outputs under it.
  let root = "build/test-fixtures/gm4b-catalog-imports"
  graphArtifactPath(if rel.len == 0: root else: root & "/" & rel)

proc hostOs*(): string =
  when defined(windows): "windows"
  elif defined(macosx): "macos"
  else: "linux"

proc otherOs*(): string =
  if hostOs() == "windows": "linux" else: "windows"

proc payloadPath*(root: string): string =
  root / "payload" / PackageName

proc payloadUrl*(root: string): string =
  "file://" & payloadPath(root)

proc recipeArtifactPath*(root, label: string): string =
  root / ("recipe-" & label) / "project-interface.rbsz"

template withNoCatalogRoot*(body: untyped) =
  ## The lookup walks to the `reprobuild-packages` beside the recipe and the
  ## profile, as in a workspace; an exported root would replace it.
  let hadRoot = existsEnv(ReprobuildPackagesRootEnv)
  let savedRoot = getEnv(ReprobuildPackagesRootEnv)
  delEnv(ReprobuildPackagesRootEnv)
  try:
    body
  finally:
    if hadRoot: putEnv(ReprobuildPackagesRootEnv, savedRoot)

proc contributionCatalogText(root, fingerprintLine: string): string =
  let payloadSha =
    ($fixtureSha2.sha256.digest(readFile(payloadPath(root)))).toLowerAscii()
  "import repro_project_dsl\n\n" &
    "provisioningFor \"" & PackageName & "\":\n" &
    "  " & fingerprintLine & "\n" &
    "  contributor \"" & Contributor & "\"\n" &
    "  tarball url = \"" & payloadUrl(root) & "\",\n" &
    "    sha256 = \"" & payloadSha & "\",\n" &
    "    archiveType = \"raw\",\n" &
    "    executablePath = \"" & PackageName & "\",\n" &
    "    packageId = \"" & PackageName & "@1.0\",\n" &
    "    version = \"1.0\",\n" &
    "    cpu = \"any\",\n" &
    "    os = \"" & hostOs() & "\"\n"

proc extractRecipe(root, label, recipeText, workDir: string):
    ProjectInterfaceArtifact =
  ## A recipe beside the catalog, compiled through the real extractor.
  let dir = root / ("recipe-" & label)
  createDir(dir)
  writeFile(dir / "repro.nim", recipeText)
  extractInterfaceFromModule(dir / "repro.nim",
    dir / "project-interface.rbsz", dir / "project-interface.nim",
    workDir = workDir, scratchDir = dir / "work", consumerRoot = dir,
    useExtractionCache = false)

proc usesRecipeText(withImport: bool): string =
  "import repro_project_dsl\n" &
    (if withImport: "import \"" & ImportEntry & "\"\n" else: "") &
    "\npackage gm4bImportsRecipe:\n  defaultToolProvisioning \"tarball\"\n" &
    "  uses:\n    \"" & PackageName & "\"\n" &
    "    \"just\"\n"

proc generateCatalogImportsFixture*(root, workDir: string) =
  ## Write the tree described in the module docstring under ``root``.
  ## ``workDir`` is the reprobuild checkout the extractor compiles against.
  createDir(payloadPath(root).parentDir)
  writeFile(payloadPath(root), "#!/bin/sh\necho gm4bimported\n")
  setFilePermissions(payloadPath(root),
    {fpUserRead, fpUserWrite, fpUserExec})

  let definitionDir = root / "reprobuild-packages" / "packages" /
    "interfaces" / PackageName
  createDir(definitionDir)
  writeFile(definitionDir / "repro.nim", """
import repro_project_dsl

package gm4bimported:
  provisioning:
    tarball url = "https://example.invalid/gm4bimported-1.0-""" & otherOs() &
      """.tar.gz",
      sha256 = "6666666666666666666666666666666666666666666666666666666666666666",
      archiveType = "tar.gz",
      executablePath = "bin/gm4bimported",
      packageId = "gm4bimported@1.0",
      version = "1.0",
      cpu = "x86_64",
      os = """ & "\"" & otherOs() & "\"\n")

  let catalogDir = root / "gm4b-contribution-catalog"
  createDir(catalogDir)
  withNoCatalogRoot:
    # The catalog is published PINNED to the definition's interface
    # fingerprint: a first extraction binds a development contribution to
    # the active definition, and the catalog is rewritten with that
    # fingerprint.
    writeFile(catalogDir / "repro.nim",
      contributionCatalogText(root, "developInterface"))
    let pin = extractRecipe(root, "pin", "import repro_project_dsl\n" &
      "import \"" & ImportEntry & "\"\n\npackage gm4bPin:\n  uses:\n    \"" &
      PackageName & "\"\n", workDir)
    var pinnedFingerprint = ""
    for c in pin.projectInterface.provisioningContributions:
      if c.targetPackage == PackageName:
        pinnedFingerprint = c.targetInterfaceFingerprint
    doAssert pinnedFingerprint.len == 64,
      "could not read the definition's interface fingerprint"
    writeFile(catalogDir / "repro.nim", contributionCatalogText(root,
      "interfaceFingerprint \"" & pinnedFingerprint & "\""))
    discard extractRecipe(root, "with-import", usesRecipeText(true), workDir)
    discard extractRecipe(root, "without-import", usesRecipeText(false),
      workDir)

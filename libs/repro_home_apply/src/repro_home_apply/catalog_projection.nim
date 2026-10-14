## Profile package references defined by the `reprobuild-packages` catalog.
##
## Provisioning-Contributions.md §"Profile Package References": a home
## profile's ``package "<name>"`` resolves through the same candidates as a
## recipe's ``uses: "<name>"``. The engine links the stdlib definitions
## (``repro_dsl_stdlib/package_registry``); a name the stdlib does not bundle
## reaches a recipe from the catalog, because the ``package`` macro's
## ``usesImportCode`` finds ``<catalog>/packages/interfaces/<name>/repro.nim``
## (``reprobuildPackagesSearch``) and imports it into the recipe's compile.
## The engine cannot import a module at run time, and a profile's package
## names are only known once its intent has been evaluated (they may come
## from a data file read at plan time), so this module does what a recipe
## does, as a recipe:
##
## 1. for each referenced name that is not a bundled stdlib selector (for
##    those ``usesImportCode`` imports the stdlib module and never consults
##    the catalog), look the name up with ``reprobuildPackagesSearch``
##    anchored at the PROFILE's own source file, so the catalog beside the
##    profile (or above it), ``$REPROBUILD_PACKAGES_ROOT`` and the catalog
##    beside the reprobuild sources are found in the order a recipe at that
##    path would find them;
## 2. for the names a catalog defines, write a synthetic recipe whose
##    ``uses:`` lists them, and extract its interface with the real extractor
##    (``extractInterfaceFromModule``) with ``$REPROBUILD_PACKAGES_ROOT`` set
##    to the catalog step 1 chose, so ``usesImportCode`` imports exactly that
##    module;
## 3. hand the extracted ``InterfaceToolUse`` records — the projection
##    ``toProjectInterface`` makes of a ``uses:`` — to ``profileToolUse``,
##    which selects from them exactly as it selects from a linked definition.
##
## So the candidate records are the ones a recipe beside the profile would
## extract, through the same lookup, the same import and the same projection.
##
## The extraction is cached by the extractor's own fingerprint (the recipe's
## text, the reprobuild libraries, the compiler, the selected catalog root).
## The recipe's text carries the content digest of every catalog module it
## names, so editing a definition in place re-extracts.

import std/[algorithm, os, strutils, tables]
from repro_core/paths import extendedPath
from repro_core/source_root import resolveReprobuildSourceRoot,
  describeReprobuildSourceRootSearch
import nimcrypto/sha2 as catalogSha2

import repro_project_dsl
import repro_interface_artifacts

type
  CatalogPackage* = object
    ## One profile package reference a catalog defines.
    name*: string
    module*: string
      ## ``<root>/packages/interfaces/<name>/repro.nim``.
    root*: string
      ## The catalog checkout (``catalogRootOfInterfaceModule(module)``).

  ProfileCatalog* = object
    ## The catalog-defined profile references of one apply, projected.
    uses*: Table[string, InterfaceToolUse]
      ## Name -> the ``uses:`` projection of its catalog definition.
    modules*: Table[string, string]
      ## Name -> the catalog module that defines it.
    failures*: Table[string, string]
      ## Name -> why its catalog definition could not be projected (the
      ## extraction failed). Resolution reports this instead of
      ## "unknown package".

const SyntheticPackageName = "reproHomeProfileCatalog"
  ## The synthetic recipe's package. Never registered in the engine.

proc catalogPackagesFor*(names: openArray[string];
                         anchorFile: string): seq[CatalogPackage] =
  ## The names among ``names`` that a ``uses:`` in a recipe at
  ## ``anchorFile`` would resolve from the catalog: not a bundled stdlib
  ## selector, and defined by a catalog ``reprobuildPackagesSearch`` finds
  ## from there. Distinct, in first-seen order.
  var seen: seq[string] = @[]
  for name in names:
    if name in seen:
      continue
    seen.add(name)
    if isBundledStdlibSelector(name):
      continue
    let search = reprobuildPackagesSearch(name, anchorFile)
    if search.module.len == 0:
      continue
    let file = search.module & ".nim"
    result.add(CatalogPackage(name: name, module: file,
      root: catalogRootOfInterfaceModule(file)))

proc moduleDigest(file: string): string =
  ## The content digest the synthetic recipe records for a catalog module.
  try:
    "sha256:" & ($catalogSha2.sha256.digest(readFile(extendedPath(file)))).
      toLowerAscii()
  except IOError, OSError:
    "unreadable"

proc syntheticRecipeText*(packages: openArray[CatalogPackage]): string =
  ## The recipe whose ``uses:`` is the profile's catalog references. Its
  ## comment lines carry each module's content digest: the extractor keys
  ## its cache on the recipe's text, and the catalog modules reach the
  ## compile through the macro, not through a textual import.
  var sorted = @packages
  sorted.sort(proc(a, b: CatalogPackage): int = cmp(a.name, b.name))
  result = "## Generated by `repro home apply`: the profile package references\n" &
    "## the reprobuild-packages catalog defines, as a recipe's `uses:`.\n"
  for pkg in sorted:
    result.add("##   " & pkg.name & " " & moduleDigest(pkg.module) & "\n")
  result.add("\nimport repro_project_dsl\n\npackage " & SyntheticPackageName &
    ":\n  uses:\n")
  for pkg in sorted:
    result.add("    " & pkg.name.escape & "\n")

proc catalogKey(root: string): string =
  ($catalogSha2.sha256.digest(root.replace('\\', '/'))).toLowerAscii()[0 ..< 16]

proc writeIfChanged(path, text: string) =
  ## Publish by rename so a reader never sees a partial file.
  if fileExists(extendedPath(path)) and readFile(extendedPath(path)) == text:
    return
  let tmp = path & ".tmp-" & $getCurrentProcessId()
  writeFile(extendedPath(tmp), text)
  moveFile(extendedPath(tmp), extendedPath(path))

proc canonicalFile(path: string): string =
  ## ``path`` with symlinks resolved: the compiler records the resolved path
  ## of a module (``/private/tmp`` for ``/tmp`` on macOS), the lookup the
  ## path it was given.
  let resolved =
    try: expandFilename(path)
    except OSError: absolutePath(path)
  resolved.replace('\\', '/')

proc recordsComeFrom(use: InterfaceToolUse; module: string): bool =
  ## Whether the projection carries a realization written in ``module``, or
  ## none at all. A workspace project named like the package would take the
  ## ``uses:`` before the catalog (``usesImportCode``'s order); the synthetic
  ## recipe lives in the state directory, where that should never happen,
  ## and this is the check that it did not.
  var files: seq[string] = @[]
  for r in use.tarballProvisioning: files.add(r.location.file)
  for r in use.nixProvisioning: files.add(r.location.file)
  for r in use.scoopProvisioning: files.add(r.location.file)
  if files.len == 0:
    return true
  let wanted = canonicalFile(module)
  for file in files:
    if canonicalFile(file) == wanted:
      return true
  false

proc extractCatalogGroup(packages: seq[CatalogPackage]; root, scratchDir,
                         workDir: string; catalog: var ProfileCatalog) =
  let dir = scratchDir / ("catalog-" & catalogKey(root))
  createDir(extendedPath(dir))
  let modulePath = dir / "repro.nim"
  let artifactPath = dir / "project-interface.rbsz"
  let stubPath = dir / "project-interface.nim"
  var lock = acquireInterfaceArtifactLock(artifactPath)
  let savedRoot = getEnv(ReprobuildPackagesRootEnv)
  let hadRoot = existsEnv(ReprobuildPackagesRootEnv)
  var artifact: ProjectInterfaceArtifact
  try:
    writeIfChanged(modulePath, syntheticRecipeText(packages))
    # The lookup in step 1 already chose the catalog; the variable makes the
    # macro's own lookup choose the same one (when set, it is the only place
    # `reprobuildPackagesSearch` consults), and the extractor keys its cache
    # on it (`catalogSelectionIdentity`).
    putEnv(ReprobuildPackagesRootEnv, root)
    artifact = extractInterfaceFromModule(modulePath, artifactPath, stubPath,
      workDir = workDir, scratchDir = dir / "work",
      consumerRoot = dir)
  finally:
    if hadRoot: putEnv(ReprobuildPackagesRootEnv, savedRoot)
    else: delEnv(ReprobuildPackagesRootEnv)
    releaseInterfaceArtifactLock(lock)
  for pkg in packages:
    var found = false
    for use in artifact.projectInterface.toolUses:
      if use.packageSelector != pkg.name:
        continue
      found = true
      if not recordsComeFrom(use, pkg.module):
        catalog.failures[pkg.name] = "the catalog definition of '" &
          pkg.name & "' (" & pkg.module & ") was not what the synthetic " &
          "recipe imported; a project named '" & pkg.name & "' beside " &
          dir & " took the reference"
      else:
        catalog.uses[pkg.name] = use
      break
    if not found:
      catalog.failures[pkg.name] = "the interface extracted for the " &
        "catalog definitions at " & root & " has no use of '" & pkg.name & "'"

proc projectCatalogPackages*(names: openArray[string];
                             anchorFile, scratchDir: string): ProfileCatalog =
  ## Project every reference in ``names`` that the catalog defines (see the
  ## module documentation). ``anchorFile`` is the profile's source file;
  ## ``scratchDir`` holds the synthetic recipes and their extraction state
  ## (the home state directory's ``catalog-projection``). Names nothing in
  ## a catalog defines are left out; a failed extraction is recorded per name
  ## in ``failures``, so the other references still resolve.
  let packages = catalogPackagesFor(names, anchorFile)
  if packages.len == 0:
    return
  for pkg in packages:
    result.modules[pkg.name] = pkg.module
  var groups = initOrderedTable[string, seq[CatalogPackage]]()
  for pkg in packages:
    groups.mgetOrPut(pkg.root, @[]).add(pkg)
  let workDir = resolveReprobuildSourceRoot()
  for root, group in groups:
    if workDir.len == 0:
      for pkg in group:
        result.failures[pkg.name] = "projecting the catalog definition " &
          pkg.module & " needs the reprobuild sources, and none were " &
          "found:\n" & describeReprobuildSourceRootSearch()
      continue
    try:
      extractCatalogGroup(group, root, scratchDir, workDir, result)
    except CatchableError as err:
      for pkg in group:
        result.failures[pkg.name] = "the catalog definition " & pkg.module &
          " could not be projected (interface extraction failed): " & err.msg

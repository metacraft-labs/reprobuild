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
##
## Contribution catalogs. A recipe IMPORTS a provisioning-contribution
## catalog (``import "../reprobuild-scoop-packages/repro"``), and the
## ``provisioningFor`` blocks the import registers are folded into its
## ``uses:`` by ``toProjectInterface``. A profile declares the same imports
## in its ``catalogs:`` section (``Profile.catalogImports``). When it does,
## the synthetic recipe is the recipe beside the profile that imports them:
## every recipe this module writes carries one ``import`` per declared
## module, and EVERY reference with a definition in scope is projected
## through extraction, not only the catalog-defined ones, so a contribution
## to a bundled stdlib package (the Scoop catalog's ``cmake``) reaches the
## profile as it reaches the recipe. The references no ``reprobuild-packages``
## catalog defines are projected by one more recipe, extracted with
## ``$REPROBUILD_PACKAGES_ROOT`` naming an empty directory so its own lookup
## finds no catalog either; it imports the linked stdlib modules of the
## references that are neither bundled nor catalog-defined, as a recipe
## naming them imports them. Without a ``catalogs:`` section nothing about
## the projection changes.

import std/[algorithm, os, sequtils, strutils, tables]
from repro_core/paths import extendedPath
from repro_core/source_root import resolveReprobuildSourceRoot,
  describeReprobuildSourceRootSearch
import nimcrypto/sha2 as catalogSha2

import repro_project_dsl
import repro_interface_artifacts
from repro_profile/catalog_refs import catalogImportPathProblem,
  CatalogModuleExtension

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
    importedModules*: seq[string]
      ## The contribution-catalog modules the profile's ``catalogs:``
      ## section imports, resolved against the profile directory (absolute
      ## ``.nim`` files), in declaration order. Every synthetic recipe of
      ## the projection imports them.

const SyntheticPackageName = "reproHomeProfileCatalog"
  ## The synthetic recipe's package. Never registered in the engine.

const PlainGroupDir = "imports-plain"
  ## The scratch directory of the recipe that projects the references no
  ## ``reprobuild-packages`` catalog defines (only written when the profile
  ## imports contribution catalogs).

proc resolveCatalogImports*(anchorFile: string;
                            declared: openArray[string]): seq[string] =
  ## The module files the profile's ``catalogs:`` entries name: each entry
  ## resolved against the directory of ``anchorFile`` (the profile), with
  ## ``.nim`` appended when omitted -- the file a Nim ``import`` of that
  ## path from the profile's directory opens. A malformed entry or a module
  ## that does not exist raises ``ValueError`` naming the entry: a declared
  ## import that is skipped would resolve the profile without the
  ## contributions it asked for (Core-Invariants.md §Unrecognised Input Is
  ## Rejected, Not Skipped).
  let profileDir = anchorFile.parentDir
  for entry in declared:
    let problem = catalogImportPathProblem(entry)
    if problem.len > 0:
      raise newException(ValueError, "the profile's `catalogs:` entry " &
        entry.escape & " cannot name a catalog module: " & problem)
    var file = normalizedPath(absolutePath(profileDir / entry))
    if not file.endsWith(CatalogModuleExtension):
      file.add CatalogModuleExtension
    if not fileExists(extendedPath(file)):
      raise newException(ValueError, "the profile's `catalogs:` entry " &
        entry.escape & " names " & file & ", which does not exist (paths " &
        "are relative to the profile directory " & profileDir & ")")
    if file notin result:
      result.add file

proc isRegisteredPackage(name: string): bool =
  ## Whether a definition of ``name`` is registered in this process (the
  ## engine links the stdlib definitions, ``repro_dsl_stdlib/
  ## package_registry``).
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return true
  false

proc linkedStdlibModule(name: string): string =
  ## ``repro_dsl_stdlib/packages/<module>`` for a name the engine links from
  ## a stdlib package module, "" otherwise. A recipe reaches such a package
  ## (one that is not a bundled selector) through exactly this import.
  for pkg in registeredPackages():
    if pkg.packageName != name:
      continue
    let file = pkg.sourceFile.replace('\\', '/')
    let marker = "/repro_dsl_stdlib/packages/"
    let at = file.rfind(marker)
    if at >= 0 and file.endsWith(".nim"):
      let module = file[at + marker.len ..< file.len - ".nim".len]
      if module.len > 0 and '/' notin module:
        return "repro_dsl_stdlib/packages/" & module
  ""

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

proc syntheticRecipeText*(packages: openArray[CatalogPackage];
                          imports: openArray[string] = [];
                          linkedModules: openArray[string] = []): string =
  ## The recipe whose ``uses:`` is the profile's references in
  ## ``packages``, importing the contribution-catalog modules ``imports``
  ## (absolute ``.nim`` files) and the linked stdlib modules
  ## ``linkedModules``. Its comment lines carry each catalog and imported
  ## module's content digest: the extractor keys its cache on the recipe's
  ## text, and the catalog modules reach the compile through the macro, not
  ## through a textual import. A ``CatalogPackage`` with an empty ``module``
  ## names a reference no catalog defines.
  var sorted = @packages
  sorted.sort(proc(a, b: CatalogPackage): int = cmp(a.name, b.name))
  result = "## Generated by `repro home apply`: the profile package references\n" &
    "## as a recipe's `uses:`, with the profile's contribution-catalog imports.\n"
  for pkg in sorted:
    if pkg.module.len > 0:
      result.add("##   " & pkg.name & " " & moduleDigest(pkg.module) & "\n")
  for file in imports:
    result.add("##   import " & file.replace('\\', '/') & " " &
      moduleDigest(file) & "\n")
  result.add("\nimport repro_project_dsl\n")
  for module in linkedModules:
    result.add("import " & module & " as " &
      module.split('/')[^1] & "_linked_module\n")
  for i, file in imports:
    # The import a recipe writes, by path; the alias keeps two catalogs whose
    # modules are both named `repro` apart.
    let modulePath = file.replace('\\', '/')[0 ..< file.len -
      CatalogModuleExtension.len]
    result.add("import " & modulePath.escape & " as reproHomeCatalogImport" &
      $i & "\n")
  result.add("\npackage " & SyntheticPackageName & ":\n  uses:\n")
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
  ##
  ## Only the definition's own (in-package) realizations are compared: a
  ## contribution an imported catalog registers is written in that catalog.
  var files: seq[string] = @[]
  for r in use.tarballProvisioning:
    if r.contributor.len == 0: files.add(r.location.file)
  for r in use.nixProvisioning:
    if r.contributor.len == 0: files.add(r.location.file)
  for r in use.scoopProvisioning:
    if r.contributor.len == 0: files.add(r.location.file)
  if files.len == 0:
    return true
  let wanted = canonicalFile(module)
  for file in files:
    if canonicalFile(file) == wanted:
      return true
  false

proc hasRecords(use: InterfaceToolUse): bool =
  use.tarballProvisioning.len > 0 or use.nixProvisioning.len > 0 or
    use.scoopProvisioning.len > 0

proc extractCatalogGroup(packages: seq[CatalogPackage]; root, scratchDir,
                         workDir: string; catalog: var ProfileCatalog;
                         plainGroup = false) =
  ## Extract one synthetic recipe and record its projections. ``root`` is
  ## the ``reprobuild-packages`` checkout the group's names come from, or,
  ## for the ``plainGroup`` (names no catalog defines; written only when the
  ## profile imports contribution catalogs), an empty directory, so the
  ## macro's own lookup finds no catalog either.
  let dir = scratchDir / (if plainGroup: PlainGroupDir
                          else: "catalog-" & catalogKey(root))
  createDir(extendedPath(dir))
  let modulePath = dir / "repro.nim"
  let artifactPath = dir / "project-interface.rbsz"
  let stubPath = dir / "project-interface.nim"
  var lock = acquireInterfaceArtifactLock(artifactPath)
  let savedRoot = getEnv(ReprobuildPackagesRootEnv)
  let hadRoot = existsEnv(ReprobuildPackagesRootEnv)
  var artifact: ProjectInterfaceArtifact
  try:
    var linkedModules: seq[string] = @[]
    if plainGroup:
      for pkg in packages:
        if isBundledStdlibSelector(pkg.name):
          continue
        let module = linkedStdlibModule(pkg.name)
        if module.len > 0 and module notin linkedModules:
          linkedModules.add(module)
    writeIfChanged(modulePath, syntheticRecipeText(packages,
      catalog.importedModules, linkedModules))
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
      if plainGroup:
        # No catalog defines the name. A definition the engine links, or
        # any realization at all (a contribution, or a definition in an
        # imported module), makes the projection the reference's
        # candidates; otherwise the name stays unknown, as it was.
        if isBundledStdlibSelector(pkg.name) or isRegisteredPackage(pkg.name) or
            hasRecords(use):
          catalog.uses[pkg.name] = use
      elif not recordsComeFrom(use, pkg.module):
        catalog.failures[pkg.name] = "the catalog definition of '" &
          pkg.name & "' (" & pkg.module & ") was not what the synthetic " &
          "recipe imported; a project named '" & pkg.name & "' beside " &
          dir & " took the reference"
      else:
        catalog.uses[pkg.name] = use
      break
    if not found:
      catalog.failures[pkg.name] = "the interface extracted for the " &
        (if plainGroup: "profile's references" else: "catalog definitions at " &
          root) & " has no use of '" & pkg.name & "'"

proc projectCatalogPackages*(names: openArray[string];
                             anchorFile, scratchDir: string;
                             catalogImports: openArray[string] = []):
    ProfileCatalog =
  ## Project every reference in ``names`` that the catalog defines (see the
  ## module documentation) -- and, when the profile imports contribution
  ## catalogs (``catalogImports``, the ``catalogs:`` entries as declared),
  ## every other reference a definition in scope names, with those catalogs
  ## imported. ``anchorFile`` is the profile's source file; ``scratchDir``
  ## holds the synthetic recipes and their extraction state (the home state
  ## directory's ``catalog-projection``). Names nothing projects are left
  ## out; a failed extraction is recorded per name in ``failures``, so the
  ## other references still resolve. A ``catalogs:`` entry that does not
  ## name an existing module raises ``ValueError``
  ## (``resolveCatalogImports``).
  result.importedModules = resolveCatalogImports(anchorFile, catalogImports)
  let packages = catalogPackagesFor(names, anchorFile)
  var plain: seq[CatalogPackage] = @[]
  if result.importedModules.len > 0:
    var seen: seq[string] = @[]
    for pkg in packages:
      seen.add(pkg.name)
    for name in names:
      if name in seen:
        continue
      seen.add(name)
      # A moved name that no catalog defines is a compile error of the
      # recipe that names it (§ Moved packages are a compile error without
      # a catalog); it would fail every other reference of the group, so it
      # is left to the linked resolution, which reports it unknown.
      if name in MovedToReprobuildPackages and not isRegisteredPackage(name):
        continue
      plain.add(CatalogPackage(name: name))
  if packages.len == 0 and plain.len == 0:
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
  if plain.len > 0:
    let names = plain.mapIt(it.name).join(", ")
    if workDir.len == 0:
      for pkg in plain:
        result.failures[pkg.name] = "projecting '" & pkg.name & "' with " &
          "the profile's contribution catalogs needs the reprobuild " &
          "sources, and none were found:\n" &
          describeReprobuildSourceRootSearch()
      return
    let noCatalog = scratchDir / PlainGroupDir / "no-catalog"
    try:
      createDir(extendedPath(noCatalog))
      extractCatalogGroup(plain, noCatalog, scratchDir, workDir, result,
        plainGroup = true)
    except CatchableError as err:
      for pkg in plain:
        result.failures[pkg.name] = "'" & pkg.name & "' could not be " &
          "projected with the profile's contribution catalogs (" &
          result.importedModules.join(", ") & "; interface extraction of " &
          "the recipe using " & names & " failed): " & err.msg

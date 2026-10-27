## Finding a package's definition in the `reprobuild-packages` catalog.
##
## Package definitions are moving out of the engine's bundled stdlib into
## `reprobuild-packages` (reprobuild-specs/Provisioning-Contributions.md,
## "Catalog Lookup And Provisioning"). A plain ``uses: "<name>"`` still reaches
## one that has moved: a name the stdlib does not bundle, and that no workspace
## project provides, is looked up as
## ``<catalog>/packages/interfaces/<name>/repro.nim``.
##
## This module holds the lookup itself, the record of where it looked, and the
## diagnostic for a moved package that no catalog defines. The macro layer runs
## it at compile time, and the engine runs it at run time (the home planner's
## catalog projection, `repro home export`). The one place the two differ is
## how the reprobuild source tree is found (`reprobuildSourceTree`).

import std/[os, strutils]
# Relative, not `repro_core/source_root`: several consumers compile this module
# with no search path for `repro_core` (it was std-only until it needed the
# run-time source root), and the relative spelling resolves to the same file,
# so it is the same module wherever both spellings meet.
from ../../../repro_core/src/repro_core/source_root import
  resolveReprobuildSourceRoot

const ReprobuildPackagesRootEnv* = "REPROBUILD_PACKAGES_ROOT"
  ## Where the `reprobuild-packages` catalog checkout lives, when it is not a
  ## workspace sibling. When it is set, it is the ONLY place looked in. The
  ## daemon forwards it (`DaemonExplicitForwardedEnvVars`).

const ReprobuildPackagesRepositoryUrl* =
  "https://github.com/metacraft-labs/reprobuild-packages"

const MovedToReprobuildPackages*: seq[string] =
  @["sqlite3", "shellcheck", "shfmt", "prek"]
  ## Names the bundled stdlib USED to define and the catalog now defines.
  ##
  ## Before its move, a recipe's ``uses:`` of one of these always resolved:
  ## the stdlib travels with the engine. After it, the name resolves only when
  ## a catalog is reachable, and without this list an unreachable catalog is
  ## silent -- the selector stays unresolved, the recipe compiles, the tool use
  ## loses its provisioning, and the failure (if any) surfaces much later as a
  ## provisioning or PATH error that names neither the catalog nor the move.
  ## A moved name that resolves nowhere is therefore a compile error, and it
  ## says where the catalog was looked for.
  ##
  ## Add a name here in the same change that deletes it from the stdlib.

const MovedPackageImportStubs*: seq[string] = @["shellcheck", "shfmt", "prek"]
  ## Moved names whose stdlib module is still present for one release, as a
  ## stub that fails to compile with "moved to reprobuild-packages; drop the
  ## import and rely on uses:". A recipe that imported the module directly
  ## (rather than naming the package in ``uses:``) would otherwise stop with
  ## "cannot open file", which names neither the move nor the remedy.
  ##
  ## A stub is not a package definition: it declares no ``package`` and is
  ## not on the bundled selector list, so a ``uses:`` line never imports it
  ## and still reaches the catalog. Delete a name here together with its stub
  ## module, in the release after the first release that ships the stub.

type
  ReprobuildPackagesProbe* = object
    ## One place the catalog was looked for.
    origin*: string
      ## Why this place was consulted, for the diagnostic.
    root*: string
      ## The candidate catalog checkout.
    rootExists*: bool
    module*: string
      ## The interface module found under ``root``, WITHOUT ``.nim``; "" when
      ## ``root`` has none for the selector.

  ReprobuildPackagesSearch* = object
    selector*: string
    envRoot*: string
      ## The value of ``$REPROBUILD_PACKAGES_ROOT``; "" when unset.
    probes*: seq[ReprobuildPackagesProbe]
    module*: string
      ## The first probe's module that exists, or "".

proc isBareCatalogSelector(selector: string): bool =
  if selector.len == 0:
    return false
  for ch in selector:
    if ch == '/' or ch == '\\' or ch == '.' or ch == ':':
      return false
  true

const
  ReprobuildPackagesRepositoryName* = "reprobuild-packages"
    ## The catalog repository's name: the checkout directory the workspace
    ## convention looks for, and the name a lock records it under.
  CatalogRevisionMarkerFile* = "catalog-revision"
    ## In a catalog COPY that is not a git checkout -- the one an installed
    ## reprobuild ships at ``share/repro/reprobuild-packages`` -- the
    ## repository and commit it was copied from, one ``key=value`` per line:
    ## ``url=<fetch url>`` and ``revision=<commit id>``. It is what lets a lock
    ## record the revision of a catalog that has no ``.git`` to ask.
  CommittedLockFileName* = "repro.lock"
    ## Standard committed lock filename.

proc findLockedCatalogRevision*(lockContent: string): string =
  ## Extract the pinned `revision` of `reprobuild-packages` from `repro.lock` content.
  if lockContent.len == 0:
    return ""
  var searchFrom = 0
  while true:
    let idx = lockContent.find(ReprobuildPackagesRepositoryName, searchFrom)
    if idx < 0:
      return ""
    let entryStart = lockContent.rfind('{', 0, idx)
    let entryEnd = lockContent.find('}', idx)
    let slice =
      if entryStart >= 0 and entryEnd > entryStart:
        lockContent[entryStart .. entryEnd]
      else:
        let lineStart = lockContent.rfind('\n', 0, idx)
        let lineEnd = lockContent.find('\n', idx)
        lockContent[(if lineStart >= 0: lineStart else: 0) .. (if lineEnd >= 0: lineEnd else: lockContent.len - 1)]

    if ("\"" & ReprobuildPackagesRepositoryName & "\"") in slice:
      var searchRegion = slice
      if entryStart < 0 or entryEnd <= entryStart:
        let nextTable = lockContent.find('[', idx)
        searchRegion = lockContent[idx ..< (if nextTable >= 0: nextTable else: lockContent.len)]

      const revKey = "revision"
      var rIdx = searchRegion.find(revKey)
      if rIdx >= 0:
        let eqIdx = searchRegion.find('=', rIdx + revKey.len)
        if eqIdx >= 0:
          let firstQuote = searchRegion.find('"', eqIdx + 1)
          if firstQuote >= 0:
            let secondQuote = searchRegion.find('"', firstQuote + 1)
            if secondQuote >= 0:
              let rev = searchRegion[firstQuote + 1 ..< secondQuote].strip()
              if rev.len > 0:
                return rev
    searchFrom = idx + ReprobuildPackagesRepositoryName.len

proc findEnclosingLockPinnedCatalog*(consumerSourceFile: string):
    tuple[consumerRoot, revision: string] =
  ## Find the nearest enclosing `repro.lock` walking up from `consumerSourceFile`
  ## and extract the locked `reprobuild-packages` revision, if any.
  if consumerSourceFile.len == 0:
    return ("", "")
  var dir = if dirExists(consumerSourceFile): consumerSourceFile else: consumerSourceFile.parentDir
  for _ in 0 ..< 16:
    let lockPath = dir / CommittedLockFileName
    if fileExists(lockPath):
      try:
        let content = readFile(lockPath)
        let rev = findLockedCatalogRevision(content)
        if rev.len > 0:
          return (dir, rev)
      except CatchableError:
        discard
    let parent = dir.parentDir
    if parent.len == 0 or parent == dir:
      break
    dir = parent
  return ("", "")

proc reprobuildSourceTree(): string =
  ## The reprobuild source tree whose sibling `reprobuild-packages` is the
  ## lookup's last place, or "" when none is known.
  ##
  ## At COMPILE time (a recipe's ``uses:`` expanding in the macro layer) it is
  ## the tree this module is being compiled from: ``currentSourcePath()`` five
  ## levels up. That is a source checkout, or ``<prefix>/share/repro/source``
  ## for an installed reprobuild, whose sibling is the catalog the release
  ## ships at ``<prefix>/share/repro/reprobuild-packages``.
  ##
  ## At RUN time ``currentSourcePath()`` is still that compile-time constant.
  ## Inside a released engine image it names the checkout the RELEASE was
  ## built in, which does not exist on the user's machine, so an installed
  ## engine never reached its own shipped catalog (reprobuild-pm issue
  ## 2026-10-27-installed-repro-profile-package-lookup-never-reaches-the-
  ## shipped-catalog). The running image therefore asks
  ## `resolveReprobuildSourceRoot`, the resolver every post-install compile
  ## uses: the explicit variables, the installed layout's
  ## ``share/repro/source`` beside the image's ``bin/``, the current
  ## directory, and the build checkout only while the image runs from inside
  ## it. That last rule matters here as well: an engine copied out of its
  ## checkout must not silently read whatever catalog sits beside that
  ## checkout now. A Nix-store install resolves to the store copy of its
  ## sources, which has no catalog beside it; Nix hosts name theirs in
  ## ``$REPROBUILD_PACKAGES_ROOT``.
  ##
  ## The resolver's current-directory arm grants nothing new here. It is
  ## reached only when no variable names a tree and the image has no
  ## installed layout, and whichever tree it selects is also the tree the
  ## profile compile builds against -- so the catalog beside it is the one
  ## that compile's own ``uses:`` lookup reaches at compile time. Choosing a
  ## different tree at run time would make the planner and the compile
  ## disagree about which catalog defines a package.
  when nimvm:
    # <reprobuild>/libs/repro_project_dsl/src/repro_project_dsl/<this file>
    currentSourcePath().parentDir.parentDir.parentDir.parentDir.parentDir
  else:
    resolveReprobuildSourceRoot()

proc reprobuildPackagesSearch*(selector, consumerSourceFile: string):
    ReprobuildPackagesSearch =
  ## Look for package ``selector`` in the catalog, recording every place
  ## consulted. The checkout is found, in order:
  ##
  ## 1. ``$REPROBUILD_PACKAGES_ROOT`` -- when set, nothing else is consulted,
  ##    so an explicitly chosen catalog is never silently replaced by another;
  ## 2. a ``reprobuild-packages`` directory beside the consumer's project or
  ##    any ancestor of it -- the workspace-sibling convention, and where
  ##    `setup-dev-env` clones a `.github/sibling-repos` entry in CI;
  ## 3. the lock-pinned catalog, under
  ##    ``<consumerRoot>/.repro/cross-repo-producers/reprobuild-packages/<rev>``;
  ## 4. a ``reprobuild-packages`` directory beside the reprobuild source tree
  ##    (`reprobuildSourceTree`): at compile time the tree this module is
  ##    compiled from, at run time the one the running image resolves. For an
  ##    installed reprobuild both are ``<prefix>/share/repro/source``, so this
  ##    finds the catalog its release ships at
  ##    ``<prefix>/share/repro/reprobuild-packages``.
  ##
  ## A checkout that lacks the interface does not end the walk; the next place
  ## is consulted. A selector that is not a bare package name is never looked
  ## up (no probes are recorded).
  result.selector = selector
  if not isBareCatalogSelector(selector):
    return
  proc probe(search: var ReprobuildPackagesSearch; origin, root: string) =
    var entry = ReprobuildPackagesProbe(origin: origin, root: root)
    if root.len > 0:
      entry.rootExists = dirExists(root)
      let candidate = root / "packages" / "interfaces" / selector / "repro.nim"
      if entry.rootExists and fileExists(candidate):
        entry.module = candidate.changeFileExt("")
    search.probes.add(entry)
    if search.module.len == 0 and entry.module.len > 0:
      search.module = entry.module
  result.envRoot = getEnv(ReprobuildPackagesRootEnv)
  if result.envRoot.len > 0:
    probe(result, "$" & ReprobuildPackagesRootEnv, result.envRoot)
    return
  var seen: seq[string] = @[]
  if consumerSourceFile.len > 0:
    var dir = consumerSourceFile.parentDir
    for _ in 0 ..< 16:
      let parent = dir.parentDir
      if parent.len == 0 or parent == dir:
        break
      let root = parent / "reprobuild-packages"
      seen.add(root)
      probe(result, "beside " & dir, root)
      if result.module.len > 0:
        return
      dir = parent

  # Step 3: Locked catalog revision from nearest enclosing repro.lock
  if consumerSourceFile.len > 0:
    let (lockDir, lockedRev) = findEnclosingLockPinnedCatalog(consumerSourceFile)
    if lockDir.len > 0 and lockedRev.len > 0:
      let lockedRoot = lockDir / ".repro" / "cross-repo-producers" /
        ReprobuildPackagesRepositoryName / lockedRev
      seen.add(lockedRoot)
      probe(result, "locked at " & lockedRev, lockedRoot)
      if result.module.len > 0:
        return

  let sourceTree = reprobuildSourceTree()
  if sourceTree.len == 0:
    return
  let besideReprobuild = sourceTree.parentDir / ReprobuildPackagesRepositoryName
  if besideReprobuild notin seen:
    probe(result, "beside the reprobuild sources " & sourceTree,
      besideReprobuild)

proc reachableReprobuildPackagesRoots*(consumerSourceFile: string):
    seq[string] =
  ## The catalog checkouts that exist among the places
  ## `reprobuildPackagesSearch` consults from ``consumerSourceFile``, in
  ## search order. Empty when no catalog is reachable at all -- then a name
  ## no linked definition provides is "unknown" only because the catalog
  ## could not be read, not because nothing defines it.
  const probeSelector = "reprobuild-catalog-reachability-probe"
  for probe in reprobuildPackagesSearch(probeSelector,
      consumerSourceFile).probes:
    if probe.rootExists and probe.root notin result:
      result.add probe.root

proc reprobuildPackagesInterfaceModule*(selector, consumerSourceFile: string):
    string =
  ## The module that defines package ``selector`` in the catalog --
  ## ``<root>/packages/interfaces/<selector>/repro.nim`` -- WITHOUT its
  ## ``.nim`` extension, or "" when there is none. See
  ## `reprobuildPackagesSearch` for where it looks.
  reprobuildPackagesSearch(selector, consumerSourceFile).module

proc catalogSelectionIdentity*(consumerSourceFile: string = ""): string =
  ## What an interface extraction's cache identity must carry about the
  ## catalog: the explicitly selected catalog, `$REPROBUILD_PACKAGES_ROOT`,
  ## when it is set; or when unset and the consumer has a locked catalog
  ## revision (with no develop sibling override), the locked revision; "" otherwise.
  ##
  ## The variable decides which module a ``uses:`` of a catalog package
  ## imports, and the recipe's text does not change when it does, so an
  ## extraction keyed on the recipe and the files it read would serve the
  ## interface of the previously selected catalog. Keyed by VALUE because it
  ## is a choice of input, not host noise. An edit to the selected module in
  ## place is a content change of a file the compile read, which the
  ## extraction's recorded inputs already cover. "" when unset and no locked
  ## revision governs, so the identity of every extraction that does not
  ## select or lock a catalog is unchanged.
  let root = getEnv(ReprobuildPackagesRootEnv)
  if root.len > 0:
    return "catalog-root:" & root.replace('\\', '/')
  if consumerSourceFile.len > 0:
    var dir = if dirExists(consumerSourceFile): consumerSourceFile else: consumerSourceFile.parentDir
    var hasDevelopSibling = false
    for _ in 0 ..< 16:
      let parent = dir.parentDir
      if parent.len == 0 or parent == dir:
        break
      if dirExists(parent / ReprobuildPackagesRepositoryName):
        hasDevelopSibling = true
        break
      dir = parent
    if not hasDevelopSibling:
      let (_, lockedRev) = findEnclosingLockPinnedCatalog(consumerSourceFile)
      if lockedRev.len > 0:
        return "catalog-locked:" & lockedRev
  return ""

proc catalogRootOfInterfaceModule*(file: string): string =
  ## The catalog checkout that ``file`` belongs to when ``file`` is a catalog
  ## interface module, ``<root>/packages/interfaces/<name>/repro.nim``; ""
  ## otherwise. This is how a realization's source location (the file its
  ## ``provisioning:`` block was written in) names the catalog it came from.
  let normalized = file.replace('\\', '/')
  if not normalized.endsWith("/repro.nim"):
    return ""
  let packageDir = normalized.parentDir
  let interfacesDir = packageDir.parentDir
  let packagesDir = interfacesDir.parentDir
  if packageDir.extractFilename.len == 0 or
      interfacesDir.extractFilename != "interfaces" or
      packagesDir.extractFilename != "packages":
    return ""
  packagesDir.parentDir

proc readCatalogRevisionMarker*(root: string): tuple[url, revision: string] =
  ## The ``url`` / ``revision`` recorded by `CatalogRevisionMarkerFile` in
  ## ``root``; empty fields when there is no marker or it lacks them.
  let marker = root / CatalogRevisionMarkerFile
  if not fileExists(marker):
    return
  for rawLine in readFile(marker).splitLines():
    let line = rawLine.strip()
    let eq = line.find('=')
    if eq <= 0:
      continue
    let value = line[eq + 1 .. ^1].strip()
    case line[0 ..< eq].strip()
    of "url": result.url = value
    of "revision": result.revision = value
    else: discard

proc reprobuildPackagesRemedy*(): string =
  ## How to make the catalog reachable. Shared by the compile-time diagnostic
  ## and the tool resolver's missing-provisioning errors.
  "Provide the catalog in one of these ways:\n" &
    "  - clone " & ReprobuildPackagesRepositoryUrl & " as `reprobuild-packages`" &
    " beside the project, or beside any directory above it (a workspace" &
    " sibling);\n" &
    "  - set " & ReprobuildPackagesRootEnv & " to a reprobuild-packages" &
    " checkout (a Nix dev shell exports it from a flake input);\n" &
    "  - in CI, list `reprobuild-packages` in .github/sibling-repos, which" &
    " setup-dev-env clones beside the checkout."

proc describeReprobuildPackagesSearch*(search: ReprobuildPackagesSearch):
    string =
  ## The places consulted, one per line, each with what was found there.
  if search.probes.len == 0:
    return "  (not looked up: `" & search.selector &
      "` is not a bare package name)"
  var lines: seq[string] = @[]
  if search.envRoot.len == 0:
    lines.add("  - $" & ReprobuildPackagesRootEnv & ": not set")
  for probe in search.probes:
    let finding =
      if probe.module.len > 0:
        "defines it"
      elif probe.rootExists:
        "checkout present, but it has no packages/interfaces/" &
          search.selector & "/repro.nim"
      else:
        "no such directory"
    var line = "  - " & probe.root & " (" & probe.origin & "): " & finding
    if probe.origin.startsWith("$"):
      line.add("; it is set, so no other location was consulted")
    lines.add(line)
  lines.join("\n")

proc movedPackageUnresolvedDiagnostic*(selector, rawConstraint,
    consumerSourceFile: string; sourceLine = 0; listName = "uses";
    lookupSourceFile = ""): string =
  ## "" unless ``selector`` is a moved package (`MovedToReprobuildPackages`)
  ## that no catalog defines for this consumer; otherwise the full error text.
  ## ``listName`` is the recipe block that names it: ``uses``,
  ## ``nativeBuildDeps`` or ``runtimeDeps``. ``lookupSourceFile`` supplies
  ## the original compiler source location when ``consumerSourceFile`` is a
  ## recipe-relative name persisted for diagnostics.
  if selector notin MovedToReprobuildPackages:
    return ""
  # Persisted recipe metadata can name a source relative to its recipe. The
  # macro supplies its original source location separately so the lookup walks
  # from the consumer, while the displayed diagnostic keeps the recipe's name.
  let search = reprobuildPackagesSearch(selector,
    if lookupSourceFile.len > 0: lookupSourceFile else: consumerSourceFile)
  if search.module.len > 0:
    return ""
  let where =
    if consumerSourceFile.len > 0 and sourceLine > 0:
      consumerSourceFile & "(" & $sourceLine & "): "
    elif consumerSourceFile.len > 0:
      consumerSourceFile & ": "
    else:
      ""
  where & listName & ": \"" & rawConstraint & "\" names `" & selector &
    "`, which is no longer bundled with reprobuild's stdlib: it is defined" &
    " by the reprobuild-packages catalog (packages/interfaces/" & selector &
    "/repro.nim), and no reachable catalog defines it.\n" &
    "The catalog was looked for at:\n" &
    describeReprobuildPackagesSearch(search) & "\n" &
    reprobuildPackagesRemedy()

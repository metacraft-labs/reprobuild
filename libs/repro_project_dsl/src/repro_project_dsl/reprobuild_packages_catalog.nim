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
##
## Everything else is ONE implementation for both: it asks the file system
## only through `fileExists`, `dirExists` and `readFile` (and parses JSON from
## a string), which the Nim VM provides, so it never runs a subprocess -- a
## checkout's ``HEAD`` commit is read from its git directory directly
## (`checkoutHeadRevision`).

import std/[json, os, strutils]
# Relative, not `repro_core/source_root`: several consumers compile this module
# with no search path for `repro_core` (it was std-only until it needed the
# run-time source root), and the relative spelling resolves to the same file,
# so it is the same module wherever both spellings meet.
from ../../../repro_core/src/repro_core/source_root import
  resolveReprobuildSourceRoot
from ../../../repro_core/src/repro_core/workspace_root import
  SettingsFileName, StateFileName, WorkspaceConfigEnvVar

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

  ExternalCatalogKind* = enum
    ## Why the external catalog of a lookup was selected
    ## (Provisioning-Contributions.md §"Lookup", step 3).
    eckNone
      ## Nothing could be selected: no pin, no checkout beside the consumer
      ## or an ancestor, and no reprobuild source tree is known.
    eckDevelopOverride
      ## The lock pins the catalog, and a develop override (`repro develop`)
      ## records a checkout for it.
    eckWorkspaceCheckout
      ## The lock pins the catalog, and the consumer's workspace declares a
      ## checkout of it (``repos/reprobuild-packages.toml``).
    eckSiblingAtPin
      ## The lock pins the catalog at ``R``, and a checkout beside the
      ## consumer or an ancestor is at ``R``.
    eckLockPinned
      ## The lock pins the catalog at ``R``: the materialized copy under
      ## ``<lockDir>/.repro/cross-repo-producers/reprobuild-packages/<R>``.
    eckAmbientSibling
      ## No lock pins the catalog: the nearest checkout beside the consumer
      ## or an ancestor outside the consumer's repository.
    eckBesideSources
      ## No lock pins the catalog and no such checkout exists: the one
      ## beside the reprobuild source tree.

  PassedOverCatalog* = object
    ## An existing external checkout the selection did not take.
    root*: string
    reason*: string

  ExternalCatalogSelection* = object
    ## The ONE external catalog selected for a consumer. Every lookup from
    ## that consumer consults it after the catalogs inside the consumer's
    ## repository, and nothing external after it.
    kind*: ExternalCatalogKind
    root*: string
      ## The selected checkout; it may not exist (an unmaterialized pin, a
      ## missing catalog beside the sources). "" for ``eckNone``.
    origin*: string
      ## Why it was selected, for the diagnostic.
    lockDir*: string
      ## The directory of the lock that pins the catalog; "" when none does.
    revision*: string
      ## The pinned revision; "" when no lock pins the catalog.
    passedOver*: seq[PassedOverCatalog]

  ReprobuildPackagesSearch* = object
    selector*: string
    envRoot*: string
      ## The value of ``$REPROBUILD_PACKAGES_ROOT``; "" when unset.
    probes*: seq[ReprobuildPackagesProbe]
    module*: string
      ## The first probe's module that exists, or "".
    selection*: ExternalCatalogSelection
      ## The external catalog selected for the consumer; ``eckNone`` when
      ## ``$REPROBUILD_PACKAGES_ROOT`` is set or a catalog inside the
      ## consumer's repository defined the interface first.
    fromExternal*: bool
      ## Whether ``module`` came from ``selection``, rather than from a
      ## catalog inside the consumer's repository or the explicit root.

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

    # The entry must BE the catalog's: its `name` names it. Matching the quoted
    # name anywhere in the entry also matched a project whose self record
    # `depends = "reprobuild-packages"` and returned the PROJECT's own
    # revision as the catalog's, so the lock-pinned catalog was looked for
    # under a revision it was never fetched at.
    #
    # And it must not be the lock's OWN record. The catalog's own `repro.lock`
    # names itself `reprobuild-packages` with `self = "true"` (v3; `path =
    # "."` in v2), and that record is its own revision, not a pin of a
    # catalog: read as one, a module inside a catalog checkout found its
    # "pin" in the catalog's own lock and never reached the lock of the
    # project that consumes it.
    let isSelfRecord = "self = \"true\"" in slice or "self=\"true\"" in slice or
      "path = \".\"" in slice or "path=\".\"" in slice
    if not isSelfRecord and (
        ("name = \"" & ReprobuildPackagesRepositoryName & "\"") in slice or
        ("name=\"" & ReprobuildPackagesRepositoryName & "\"") in slice):
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

const LockedCatalogEnv* = "REPRO_LOCKED_CATALOG"
  ## The answer to `findEnclosingLockPinnedCatalog` for the files of ONE
  ## recipe directory, resolved by the process that launches the recipe's
  ## compile and declared in that compile's environment:
  ## ``<recipe dir>\t<lock dir>\t<revision>``, the last two empty when no
  ## enclosing lock pins the catalog. It answers for a consumer file directly
  ## in the recipe directory (the recipe and the modules beside it), whose
  ## walk would start where the recipe's does; any other file still walks.
  ##
  ## WHY. The compile resolves catalog ``uses:`` at macro time, and the walk
  ## READS the nearest ``repro.lock`` to do it. Inside a monitored compile
  ## edge that read made the WHOLE lock an input of the edge, so every
  ## ``repro lock refresh`` -- which rewrites the lock -- re-ran the recipe's
  ## interface and provider compiles, though all they take from the lock is
  ## the catalog revision. That revision is already part of both edges'
  ## identity (`catalogSelectionIdentity`), and the paths name the recipe's
  ## own location, so the compile edges pass the variable through rather
  ## than key on it (`ProviderCompileEnvironmentPassthrough`).

proc findEnclosingLockPinnedCatalogByWalk(consumerSourceFile: string):
    tuple[consumerRoot, revision: string]

proc absoluteSpelling(path: string): string =
  ## ``path`` absolute and normalized. At compile time (macro expansion) the
  ## compiler hands absolute paths already, and the VM has no getcwd.
  when nimvm:
    normalizedPath(path)
  else:
    normalizedPath(absolutePath(path))

proc lockedCatalogFromEnv(consumerSourceFile: string;
                          answer: var tuple[consumerRoot, revision: string]):
    bool =
  let declared = getEnv(LockedCatalogEnv)
  if declared.len == 0:
    return false
  let fields = declared.split('\t')
  if fields.len != 3 or fields[0].len == 0:
    return false
  if absoluteSpelling(consumerSourceFile).parentDir != fields[0]:
    return false
  answer = (fields[1], fields[2])
  true

proc declaredLockedCatalog*(consumerSourceFile: string;
                            answer: var tuple[consumerRoot, revision: string]):
    bool =
  ## Whether this process was launched with a `LockedCatalogEnv` that answers
  ## for ``consumerSourceFile``, and the answer when it was.
  lockedCatalogFromEnv(consumerSourceFile, answer)

proc lockedCatalogDeclaration*(recipe: string): string =
  ## The `LockedCatalogEnv` value for ``recipe``, computed by walking now.
  ## For the launching process, which is not monitored.
  let recipePath = absoluteSpelling(recipe)
  let found = findEnclosingLockPinnedCatalogByWalk(recipePath)
  recipePath.parentDir & "\t" & found.consumerRoot & "\t" & found.revision

proc findEnclosingLockPinnedCatalog*(consumerSourceFile: string):
    tuple[consumerRoot, revision: string] =
  ## Find the nearest enclosing `repro.lock` walking up from `consumerSourceFile`
  ## and extract the locked `reprobuild-packages` revision, if any. A compile
  ## launched with `LockedCatalogEnv` for this file takes the declared answer
  ## and reads no lock.
  if consumerSourceFile.len == 0:
    return ("", "")
  if lockedCatalogFromEnv(consumerSourceFile, result):
    return
  findEnclosingLockPinnedCatalogByWalk(consumerSourceFile)

proc findEnclosingLockPinnedCatalogByWalk(consumerSourceFile: string):
    tuple[consumerRoot, revision: string] =
  if consumerSourceFile.len == 0:
    return ("", "")
  var dir = if dirExists(consumerSourceFile): consumerSourceFile else: consumerSourceFile.parentDir
  for _ in 0 ..< 64:
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

proc probeCatalogRoot(search: var ReprobuildPackagesSearch;
                      origin, root: string) =
  ## Record one place `reprobuildPackagesSearch` consults.
  ##
  ## A top-level proc on purpose, not a closure nested in the search: the
  ## search runs inside the ``package`` macro at compile time, and Nim's VM
  ## refuses a nested proc's captured environment ("cannot evaluate at compile
  ## time: :env") when the macro expands in a module compiled after another
  ## module's ``package`` block -- which is every test compiled into a group
  ## binary (Test-Binary-Grouping M2: ``t_home_profile_lock`` then
  ## ``t_runtime_library_binding``). The selector travels in ``search``.
  var entry = ReprobuildPackagesProbe(origin: origin, root: root)
  if root.len > 0:
    entry.rootExists = dirExists(root)
    let candidate = root / "packages" / "interfaces" / search.selector /
      "repro.nim"
    if entry.rootExists and fileExists(candidate):
      entry.module = candidate.changeFileExt("")
  search.probes.add(entry)
  if search.module.len == 0 and entry.module.len > 0:
    search.module = entry.module

proc readCatalogRevisionMarker*(root: string): tuple[url, revision: string]

# ---- what surrounds the consumer ----------------------------------------
#
# The selection rule (Provisioning-Contributions.md §"Lookup") is stated in
# terms of the consumer's repository, the lock that pins the catalog, the
# develop overrides, the workspace and the HEAD commit of a checkout. Each is
# answered here from the file system alone, because the same code runs in the
# Nim VM while a recipe's ``uses:`` expands: no subprocess, no current
# directory, no ``walkDir``.

const AncestorWalkLimit = 64
  ## How many directories above the consumer any of the walks below visits.

proc readTrimmed(path: string): string =
  ## ``path``'s content, stripped; "" when it is absent or unreadable.
  try:
    if fileExists(path): readFile(path).strip() else: ""
  except CatchableError:
    ""

proc consumerDirectoryOf(consumerSourceFile: string): string =
  ## The directory the lookup walks from: ``consumerSourceFile`` itself when
  ## it names a directory, otherwise the directory that holds it.
  if consumerSourceFile.len == 0:
    return ""
  let path = absoluteSpelling(consumerSourceFile)
  if dirExists(path): path else: path.parentDir

proc isAtOrBelow(path, top: string): bool =
  ## Whether ``path`` is ``top`` or lies inside it. Both are normalized.
  if top.len == 0 or path.len == 0:
    return false
  if path == top:
    return true
  let prefix =
    if top.endsWith(DirSep) or top.endsWith(AltSep): top else: top & DirSep
  path.startsWith(prefix)

proc enclosingRepositoryTop*(consumerDir: string): string =
  ## The consumer's repository: the nearest directory at or above
  ## ``consumerDir`` that holds a ``.git`` entry (a directory, or the file a
  ## worktree or submodule has). "" when there is none.
  var dir = consumerDir
  for _ in 0 ..< AncestorWalkLimit:
    if dir.len == 0:
      break
    if dirExists(dir / ".git") or fileExists(dir / ".git"):
      return dir
    let parent = dir.parentDir
    if parent.len == 0 or parent == dir:
      break
    dir = parent
  ""

proc gitDirectoryOf(checkout: string): string =
  ## ``checkout``'s git directory: ``.git`` itself, or the directory a
  ## ``.git`` FILE names (``gitdir: <path>``, a worktree or a submodule).
  ## "" when ``checkout`` is not the top of a git checkout.
  let dotGit = checkout / ".git"
  if dirExists(dotGit):
    return dotGit
  let content = readTrimmed(dotGit)
  const prefix = "gitdir:"
  if content.startsWith(prefix):
    let raw = content[prefix.len .. ^1].strip()
    if raw.len > 0:
      return normalizedPath(if raw.isAbsolute: raw else: checkout / raw)
  ""

proc gitCommonDirectoryOf(gitDir: string): string =
  ## Where a worktree's shared refs live: the directory its ``commondir``
  ## file names (https://git-scm.com/docs/gitrepository-layout), or
  ## ``gitDir`` itself for an ordinary checkout.
  let raw = readTrimmed(gitDir / "commondir")
  if raw.len == 0:
    return gitDir
  normalizedPath(if raw.isAbsolute: raw else: gitDir / raw)

proc resolveGitRef(gitDir, commonDir, refName: string): string =
  ## The commit ``refName`` names: a loose ref (in the worktree's own git
  ## directory, then the shared one), else its line in ``packed-refs``,
  ## following symbolic refs a few levels. "" when it cannot be resolved.
  var name = refName
  for _ in 0 ..< 8:
    var value = ""
    for base in [gitDir, commonDir]:
      value = readTrimmed(base / name)
      if value.len > 0:
        break
    if value.len == 0:
      # packed-refs: "<sha> <ref>" lines, "#" headers, "^<sha>" peeled tags.
      for line in readTrimmed(commonDir / "packed-refs").splitLines():
        let entry = line.strip()
        if entry.len == 0 or entry[0] in {'#', '^'}:
          continue
        let space = entry.find(' ')
        if space > 0 and entry[space + 1 .. ^1].strip() == name:
          value = entry[0 ..< space]
          break
    if value.startsWith("ref:"):
      name = value[4 .. ^1].strip()
      continue
    return value
  ""

proc checkoutHeadRevision*(checkout: string): string =
  ## The commit ``checkout`` has checked out, read from its git directory
  ## without running git; for a catalog COPY with no ``.git``, the revision
  ## its `CatalogRevisionMarkerFile` records. "" when neither says.
  let gitDir = gitDirectoryOf(checkout)
  if gitDir.len == 0:
    return readCatalogRevisionMarker(checkout).revision
  let head = readTrimmed(gitDir / "HEAD")
  if head.startsWith("ref:"):
    return resolveGitRef(gitDir, gitCommonDirectoryOf(gitDir),
      head[4 .. ^1].strip())
  head

proc sameRevision(a, b: string): bool =
  a.len > 0 and cmpIgnoreCase(a, b) == 0

proc tomlStringEntry(line: string): tuple[key, value: string; ok: bool] =
  ## ``key = "value"`` or ``key = 'value'`` on one line. The develop-override
  ## file and a repo fragment are machine-written with one such pair per line;
  ## their strict readers (`repro_workspace_manifests`) do not run in the VM,
  ## and an entry this cannot read selects nothing (the pin then governs).
  let eq = line.find('=')
  if eq <= 0:
    return
  let key = line[0 ..< eq].strip()
  let rest = line[eq + 1 .. ^1].strip()
  if rest.len >= 2 and rest[0] == '\'':
    let close = rest.find('\'', 1)
    if close > 0:
      return (key, rest[1 ..< close], true)
    return
  if rest.len < 2 or rest[0] != '"':
    return
  var value = ""
  var i = 1
  while i < rest.len and rest[i] != '"':
    if rest[i] == '\\' and i + 1 < rest.len:
      inc i
      case rest[i]
      of 'n': value.add('\n')
      of 't': value.add('\t')
      else: value.add(rest[i])
    else:
      value.add(rest[i])
    inc i
  if i < rest.len:
    result = (key, value, true)

proc resolvedAgainst(path, base: string): string =
  normalizedPath(if path.isAbsolute: path else: base / path)

proc catalogOverrideInWorkspaceFile(root: string): tuple[root, file: string] =
  ## The ``local_path`` a ``[[override]]`` for `reprobuild-packages` records
  ## in ``<root>/.repro/develop-overrides.toml`` (written by `repro develop`;
  ## ``repro_workspace_manifests/develop_overrides``), resolved against
  ## ``root``; empty when there is none.
  if root.len == 0:
    return
  let file = root / ".repro" / "develop-overrides.toml"
  let text = readTrimmed(file)
  if text.len == 0:
    return
  var inOverride = false
  var package, localPath: string
  for raw in text.splitLines() & @["[end]"]:
    let line = raw.strip()
    if line.startsWith("["):
      if inOverride and package == ReprobuildPackagesRepositoryName and
          localPath.len > 0:
        return (resolvedAgainst(localPath, root), file)
      inOverride = line == "[[override]]"
      package = ""
      localPath = ""
      continue
    if not inOverride:
      continue
    let entry = tomlStringEntry(line)
    if entry.ok:
      case entry.key
      of "package": package = entry.value
      of "local_path": localPath = entry.value
      else: discard

proc catalogOverrideInProjectFile(projectRoot: string):
    tuple[root, file: string] =
  ## The ``path`` a `reprobuild-packages` entry records in the project's
  ## develop-override document: ``<git dir>/reprobuild/develop-overrides.json``
  ## when ``projectRoot`` is a git checkout, otherwise
  ## ``<projectRoot>/.repro/local/develop-overrides.json`` (the layout
  ## `repro develop` writes; ``developOverridesMetadataPath`` in
  ## `repro_cli_support`). Empty when there is none.
  if projectRoot.len == 0:
    return
  let gitDir = gitDirectoryOf(projectRoot)
  let file =
    if gitDir.len > 0: gitDir / "reprobuild" / "develop-overrides.json"
    else: projectRoot / ".repro" / "local" / "develop-overrides.json"
  let text = readTrimmed(file)
  if text.len == 0:
    return
  try:
    let doc = parseJson(text)
    if doc.kind != JObject or not doc.hasKey("overrides") or
        doc["overrides"].kind != JArray:
      return
    for item in doc["overrides"]:
      if item.kind != JObject:
        continue
      let node =
        if item.hasKey("node"): item["node"].getStr()
        else: item{"dependency"}.getStr()
      let path = item{"path"}.getStr()
      if node == ReprobuildPackagesRepositoryName and path.len > 0:
        return (resolvedAgainst(path, projectRoot), file)
  except CatchableError:
    discard

proc enclosingWorkspaceRoot(consumerDir: string): string =
  ## The workspace root above ``consumerDir``: the directory of the settings
  ## file ``$REPRO_WORKSPACE_CONFIG`` names, else the nearest ancestor that
  ## holds ``repro-workspace.toml`` or ``.repro/workspace-state.toml``
  ## (Workspace-Settings-Files.md §6; the same markers
  ## ``repro_core/workspace_root`` reads first). The rest of that module's
  ## rule -- the manifest-checkout and committed-lock tiers -- is about
  ## workspaces that declare no repository fragments, which cannot declare a
  ## catalog checkout either, and it needs ``walkDir``, which the VM lacks.
  ##
  ## The markers are probed with plain `fileExists`, not that module's
  ## ``settingsFileIn`` / ``stateFileIn``: those go through ``extendedPath``,
  ## which on Windows calls ``absolutePath`` and so ``getCurrentDir`` -- and
  ## the Nim VM cannot run ``getcwd``, so a recipe compile on Windows would
  ## stop with "cannot 'importc' variable at compile time". The paths here
  ## are already absolute and short (a workspace root and one file below it).
  let configured = getEnv(WorkspaceConfigEnvVar)
  if configured.len > 0:
    let settings = absoluteSpelling(configured)
    if fileExists(settings):
      return settings.parentDir
  var dir = consumerDir
  for _ in 0 ..< AncestorWalkLimit:
    if dir.len == 0:
      break
    if (configured.len == 0 and fileExists(dir / SettingsFileName)) or
        fileExists(dir / ".repro" / StateFileName):
      return dir
    let parent = dir.parentDir
    if parent.len == 0 or parent == dir:
      break
    dir = parent
  ""

proc workspaceDeclaredCatalog(workspaceRoot: string):
    tuple[root, fragment: string] =
  ## The checkout the workspace's manifests declare for `reprobuild-packages`:
  ## the ``path`` of its repo fragment ``repos/reprobuild-packages.toml``
  ## (at the workspace root, or in the materialized manifest checkout under
  ## ``.repro/manifests``), resolved against the workspace root. A fragment
  ## without ``path`` checks the repository out under its name. Empty when
  ## the workspace declares no such fragment.
  if workspaceRoot.len == 0:
    return
  let fragmentName = ReprobuildPackagesRepositoryName & ".toml"
  for fragment in [workspaceRoot / "repos" / fragmentName,
      workspaceRoot / ".repro" / "manifests" / "repos" / fragmentName]:
    let text = readTrimmed(fragment)
    if text.len == 0:
      continue
    var table = ""
    var path = ""
    for raw in text.splitLines():
      let line = raw.strip()
      if line.startsWith("["):
        table = line
        continue
      if table == "[repo]":
        let entry = tomlStringEntry(line)
        if entry.ok and entry.key == "path":
          path = entry.value
    if path.len == 0:
      path = ReprobuildPackagesRepositoryName
    return (resolvedAgainst(path, workspaceRoot), fragment)


proc besideSourcesCatalog(): tuple[root, sourceTree: string] =
  let sourceTree = reprobuildSourceTree()
  if sourceTree.len == 0:
    return
  (sourceTree.parentDir / ReprobuildPackagesRepositoryName, sourceTree)

type CatalogSibling = object
  besideDir: string
    ## The directory the checkout is beside (a sibling of).
  root: string

proc externalSiblingCandidates(consumerDir, repositoryTop: string):
    seq[CatalogSibling] =
  ## Every ``reprobuild-packages`` path beside ``consumerDir`` or beside an
  ## ancestor of it that lies OUTSIDE the consumer's repository, nearest
  ## first, whether or not it exists.
  var dir = consumerDir
  for _ in 0 ..< AncestorWalkLimit:
    if dir.len == 0:
      break
    let parent = dir.parentDir
    if parent.len == 0 or parent == dir:
      break
    if not isAtOrBelow(parent, repositoryTop):
      result.add CatalogSibling(besideDir: dir,
        root: parent / ReprobuildPackagesRepositoryName)
    dir = parent

proc repositoryLocalCatalogs(consumerDir: string):
    seq[tuple[origin, root: string]] =
  ## The catalogs inside the consumer's repository that exist, in the order
  ## they are consulted: the repository's top when it is itself a catalog
  ## (it holds ``packages/interfaces/``), then each ``reprobuild-packages``
  ## directory inside it beside the consumer's directory or an ancestor,
  ## nearest first. They are committed with the consumer, so they are not a
  ## catalog revision and are consulted per interface.
  let top = enclosingRepositoryTop(consumerDir)
  if top.len == 0:
    return
  if dirExists(top / "packages" / "interfaces"):
    result.add(("the consumer's own repository, which is a catalog", top))
  var dir = consumerDir
  for _ in 0 ..< AncestorWalkLimit:
    let parent = dir.parentDir
    if parent.len == 0 or parent == dir or not isAtOrBelow(parent, top):
      break
    let root = parent / ReprobuildPackagesRepositoryName
    if dirExists(root):
      result.add(("inside the consumer's repository, beside " & dir, root))
    dir = parent

proc passOver(selection: var ExternalCatalogSelection; root, reason: string) =
  ## Record ``root`` as passed over, once, unless it is the selection.
  if root.len == 0 or root == selection.root:
    return
  for entry in selection.passedOver:
    if entry.root == root:
      return
  selection.passedOver.add PassedOverCatalog(root: root, reason: reason)

proc selectExternalCatalog*(consumerSourceFile: string):
    ExternalCatalogSelection =
  ## Select the ONE external catalog for ``consumerSourceFile``
  ## (Provisioning-Contributions.md §"Lookup", step 3). Every caller that
  ## needs to know which catalog a consumer builds against asks this: the
  ## lookup (`reprobuildPackagesSearch`), the extraction identity
  ## (`catalogSelectionIdentity`) and the build engine's materialization of
  ## the pin (`ensureLockPinnedCatalog` in `repro_cli_support`).
  ##
  ## When the consumer's lock pins the catalog at ``R``, a checkout replaces
  ## the pin only when develop mode substitutes it -- a develop override,
  ## then the workspace's own declared checkout -- or when it IS the pin, a
  ## checkout beside the consumer or an ancestor whose HEAD is ``R``.
  ## Otherwise the pin is the materialized copy under the lock's directory.
  ## Any other checkout beside the consumer is passed over, at whatever
  ## revision it is: a stale ``~/src/reprobuild-packages`` must not replace
  ## the pin of every project under ``~/src``.
  ##
  ## When no lock pins it, the nearest existing checkout beside the consumer
  ## or an ancestor outside the consumer's repository, else the one beside
  ## the reprobuild source tree.
  ##
  ## Does not consult ``$REPROBUILD_PACKAGES_ROOT``; the callers do, first.
  let consumerDir = consumerDirectoryOf(consumerSourceFile)
  let candidates = externalSiblingCandidates(consumerDir,
    enclosingRepositoryTop(consumerDir))
  let beside = besideSourcesCatalog()
  let pin = findEnclosingLockPinnedCatalog(consumerSourceFile)
  template select(k: ExternalCatalogKind; r, why: string) =
    result.kind = k
    result.root = r
    result.origin = why

  if pin.revision.len > 0:
    result.lockDir = pin.consumerRoot
    result.revision = pin.revision
    let lockFile = pin.consumerRoot / CommittedLockFileName
    let workspace = enclosingWorkspaceRoot(consumerDir)
    # 1. A develop override: the project's own document, then the lock
    #    directory's and the workspace's `.repro/develop-overrides.toml`.
    var overrides = @[catalogOverrideInProjectFile(pin.consumerRoot),
      catalogOverrideInWorkspaceFile(pin.consumerRoot)]
    if workspace.len > 0 and workspace != pin.consumerRoot:
      overrides.add catalogOverrideInWorkspaceFile(workspace)
    for entry in overrides:
      if entry.root.len == 0:
        continue
      if dirExists(entry.root):
        select(eckDevelopOverride, entry.root,
          "the develop override for " & ReprobuildPackagesRepositoryName &
          " in " & entry.file)
        break
      result.passOver(entry.root, "the develop override in " & entry.file &
        " names it, but it does not exist")
    # 2. The workspace's own declared checkout.
    if result.kind == eckNone and workspace.len > 0:
      let declared = workspaceDeclaredCatalog(workspace)
      if declared.root.len > 0 and dirExists(declared.root):
        select(eckWorkspaceCheckout, declared.root,
          "the workspace's own checkout, declared by " & declared.fragment)
    # 3. A checkout beside the consumer or an ancestor that IS the pin.
    if result.kind == eckNone:
      for candidate in candidates:
        if not dirExists(candidate.root):
          continue
        let head = checkoutHeadRevision(candidate.root)
        if sameRevision(head, pin.revision):
          select(eckSiblingAtPin, candidate.root,
            "beside " & candidate.besideDir & ", at the pinned " &
            pin.revision)
          break
        result.passOver(candidate.root,
          (if head.len > 0: "its HEAD is " & head
           else: "its HEAD commit could not be read") &
          ", not the " & pin.revision & " that " & lockFile & " pins; a" &
          " checkout replaces the pin only at the pinned commit or through" &
          " develop mode")
    # 4. The materialized pin.
    if result.kind == eckNone:
      select(eckLockPinned, pin.consumerRoot / ".repro" /
        "cross-repo-producers" / ReprobuildPackagesRepositoryName /
        pin.revision, "locked at " & pin.revision)
    let because = lockFile & " pins the catalog, and " & result.root &
      " was selected for it"
    for candidate in candidates:
      if dirExists(candidate.root):
        result.passOver(candidate.root, because)
    if dirExists(beside.root):
      result.passOver(beside.root, because)
    return

  for candidate in candidates:
    if not dirExists(candidate.root):
      continue
    if result.kind == eckNone:
      select(eckAmbientSibling, candidate.root, "beside " & candidate.besideDir)
    else:
      result.passOver(candidate.root,
        "a nearer checkout, " & result.root & ", was selected")
  if result.kind == eckNone:
    if beside.root.len > 0:
      select(eckBesideSources, beside.root,
        "beside the reprobuild sources " & beside.sourceTree)
  elif dirExists(beside.root):
    result.passOver(beside.root,
      "a nearer checkout, " & result.root & ", was selected")

proc reprobuildPackagesSearch*(selector, consumerSourceFile: string):
    ReprobuildPackagesSearch =
  ## Look for package ``selector`` in the catalog, recording every place
  ## consulted (Provisioning-Contributions.md §"Lookup"):
  ##
  ## 1. ``$REPROBUILD_PACKAGES_ROOT`` -- when set, nothing else is consulted,
  ##    so an explicitly chosen catalog is never silently replaced by another;
  ## 2. the catalogs inside the consumer's own repository
  ##    (`repositoryLocalCatalogs`): its top when that is a catalog, then each
  ##    ``reprobuild-packages`` inside it beside the consumer's directory or
  ##    an ancestor (reprobuild's fixture catalog ``tests/reprobuild-packages``).
  ##    They are consulted per interface;
  ## 3. the ONE external catalog `selectExternalCatalog` selects: when the
  ##    consumer's lock pins the catalog, a develop override, the workspace's
  ##    declared checkout, a sibling at the pinned commit, or the materialized
  ##    pin -- never any other checkout beside the consumer; when nothing
  ##    pins it, the nearest checkout beside an ancestor outside the
  ##    repository, else the one beside the reprobuild source tree
  ##    (`reprobuildSourceTree`; for an installed reprobuild that is the
  ##    catalog its release ships at ``<prefix>/share/repro/reprobuild-packages``).
  ##
  ## The selected external catalog lacking the interface ENDS the lookup:
  ## no other external checkout is consulted, so one consumer never takes
  ## interfaces from two catalog revisions. The search records what was
  ## passed over (``selection.passedOver``) for the diagnostic. A selector
  ## that is not a bare package name is never looked up (no probes).
  result.selector = selector
  if not isBareCatalogSelector(selector):
    return
  result.envRoot = getEnv(ReprobuildPackagesRootEnv)
  if result.envRoot.len > 0:
    probeCatalogRoot(result, "$" & ReprobuildPackagesRootEnv, result.envRoot)
    return
  var consulted: seq[string] = @[]
  for (origin, root) in repositoryLocalCatalogs(
      consumerDirectoryOf(consumerSourceFile)):
    consulted.add(root)
    probeCatalogRoot(result, origin, root)
    if result.module.len > 0:
      return
  result.selection = selectExternalCatalog(consumerSourceFile)
  if result.selection.root.len > 0 and result.selection.root notin consulted:
    probeCatalogRoot(result, result.selection.origin, result.selection.root)
    result.fromExternal = result.module.len > 0

proc reachableReprobuildPackagesRoots*(consumerSourceFile: string):
    seq[string] =
  ## The catalog checkouts that exist among the places
  ## `reprobuildPackagesSearch` consults from ``consumerSourceFile``, in
  ## search order. Empty when no catalog is reachable at all -- then a name
  ## no linked definition provides is "unknown" only because the catalog
  ## could not be read, not because nothing defines it. A checkout the
  ## selection passed over is not reachable.
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

var catalogsSelectedInThisCompile {.compileTime.}:
    seq[tuple[catalog, root, origin, consumer: string]]
  ## Each external catalog an interface was resolved from in THIS compile,
  ## with the first consumer that resolved one from it. A compile-time
  ## variable lives exactly as long as one compiler run, which is the scope
  ## of "one catalog per compile".

proc catalogOfSelection(selection: ExternalCatalogSelection): string =
  ## What "the same catalog" means for one compile, by revision. A catalog
  ## the PIN selects is its revision: two projects that pin the same
  ## revision each materialize their own copy of it (or find it at different
  ## paths), and those copies are one catalog revision. A develop-mode or
  ## unpinned checkout is its directory, whose content is whatever it holds
  ## now. See `sameCatalogInCompile` for the second way two selections are
  ## one catalog.
  if selection.kind in {eckLockPinned, eckSiblingAtPin}:
    "revision " & selection.revision
  else:
    "checkout " & selection.root

proc catalogRootKey(root: string): string =
  ## A selected root, spelled so that two spellings of one directory
  ## compare equal (separators, `.` and `..` segments, a trailing slash).
  normalizedPath(root).replace('\\', '/')

proc sameCatalogInCompile(catalog, root, priorCatalog,
    priorRoot: string): bool =
  ## Whether a selection (``catalog``, ``root``) is the catalog an earlier
  ## lookup of the same compile selected. Either the same revision
  ## (`catalogOfSelection`), or the SAME DIRECTORY: two consumers that read
  ## their interfaces from one checkout read the same files, so nothing of
  ## a second revision enters the graph, whatever reason each consumer had
  ## for selecting it. This is the workspace layout CI builds in: a
  ## checkout of the catalog at the pin of one lock (`eckSiblingAtPin`) is
  ## also the nearest checkout for a sibling whose lock pins no catalog
  ## (`eckAmbientSibling`), and comparing only the two identities -- a
  ## revision against a directory -- refused that compile although it
  ## takes every interface from one tree.
  catalog == priorCatalog or
    (root.len > 0 and catalogRootKey(root) == catalogRootKey(priorRoot))

proc reprobuildPackagesInterfaceModuleInCompile*(selector,
    consumerSourceFile: string): tuple[module, conflict: string]
    {.compileTime.} =
  ## `reprobuildPackagesInterfaceModule` for the macro layer, which also
  ## enforces ONE CATALOG PER COMPILE (Provisioning-Contributions.md
  ## §"Lookup"): when this lookup resolves the interface from an external
  ## catalog other than the one an earlier lookup of the same compile
  ## resolved from, ``conflict`` is the compile error, naming both catalogs
  ## and the consumer that selected each. Two consumer modules under locks
  ## that pin different revisions would otherwise build one graph from two
  ## catalog revisions.
  ##
  ## Only a resolution from the external catalog counts. A catalog inside
  ## the consumer's repository is committed with it, and a catalog's own
  ## interface modules resolve one another from their own repository, so a
  ## lookup answered there takes nothing from any external catalog -- and a
  ## lookup that resolves nothing takes nothing either.
  let search = reprobuildPackagesSearch(selector, consumerSourceFile)
  result.module = search.module
  if not search.fromExternal:
    return
  let root = search.selection.root
  let catalog = catalogOfSelection(search.selection)
  let consumer = consumerSourceFile & " (`" & selector & "`)"
  for prior in catalogsSelectedInThisCompile:
    if sameCatalogInCompile(catalog, root, prior.catalog, prior.root):
      return
  if catalogsSelectedInThisCompile.len > 0:
    let prior = catalogsSelectedInThisCompile[0]
    result.conflict =
      "this compile would resolve " & ReprobuildPackagesRepositoryName &
      " interfaces from two catalogs, so one graph would mix two catalog" &
      " revisions:\n" &
      "  - " & prior.root & " (" & prior.origin & "), selected for " &
      prior.consumer & "\n" &
      "  - " & root & " (" & search.selection.origin & "), selected for " &
      consumer & "\n" &
      "Every module of one compile must select the same catalog: pin the" &
      " same " & ReprobuildPackagesRepositoryName & " revision in both" &
      " locks, or develop one checkout of it for both."
    return
  catalogsSelectedInThisCompile.add(
    (catalog, root, search.selection.origin, consumer))

proc catalogSelectionIdentity*(consumerSourceFile: string = ""): string =
  ## What an interface extraction's cache identity must carry about the
  ## catalog: the explicitly selected catalog, `$REPROBUILD_PACKAGES_ROOT`,
  ## when it is set; or when unset and the PIN selects the consumer's catalog
  ## (`selectExternalCatalog`: the materialized pin, or a checkout at the
  ## pinned commit), the locked revision; "" otherwise.
  ##
  ## The variable decides which module a ``uses:`` of a catalog package
  ## imports, and the recipe's text does not change when it does, so an
  ## extraction keyed on the recipe and the files it read would serve the
  ## interface of the previously selected catalog. Keyed by VALUE because it
  ## is a choice of input, not host noise. An edit to the selected module in
  ## place is a content change of a file the compile read, which the
  ## extraction's recorded inputs already cover. A develop-mode checkout
  ## (an override or the workspace's own) contributes "": the compile reads
  ## the override and the workspace fragment that select it, and its files.
  ## "" when unset and no locked revision governs, so the identity of every
  ## extraction that does not select or lock a catalog is unchanged.
  let root = getEnv(ReprobuildPackagesRootEnv)
  if root.len > 0:
    return "catalog-root:" & root.replace('\\', '/')
  if consumerSourceFile.len > 0:
    let selection = selectExternalCatalog(consumerSourceFile)
    if selection.kind in {eckSiblingAtPin, eckLockPinned}:
      return "catalog-locked:" & selection.revision
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
    "  - in a workspace whose project declares reprobuild-packages, run" &
    " `repro sync --only=reprobuild-packages` from the workspace root;\n" &
    "  - clone " & ReprobuildPackagesRepositoryUrl & " as `reprobuild-packages`" &
    " beside the project, or beside any directory above it (a workspace" &
    " sibling); when the project's repro.lock pins the catalog, check that" &
    " clone out at the pinned revision, or select it with `repro develop" &
    " reprobuild-packages`;\n" &
    "  - set " & ReprobuildPackagesRootEnv & " to a reprobuild-packages" &
    " checkout (a Nix dev shell exports it from a flake input);\n" &
    "  - in CI, list `reprobuild-packages` in .github/sibling-repos, which" &
    " setup-dev-env clones beside the checkout (at the revision repro.lock" &
    " pins, when it pins one)."

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
    elif probe.root == search.selection.root and probe.module.len == 0:
      line.add("; it is the selected catalog, so no other checkout was" &
        " consulted")
    lines.add(line)
  if search.envRoot.len == 0:
    if search.selection.kind == eckNone and search.module.len == 0:
      lines.add("  - (no " & ReprobuildPackagesRepositoryName &
        " checkout beside the consumer or any directory above it, no lock" &
        " pins one, and the reprobuild source tree is not known)")
    for skipped in search.selection.passedOver:
      lines.add("  - " & skipped.root & ": passed over, " & skipped.reason)
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

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
## diagnostic for a moved package that no catalog defines. It depends on
## ``std/[os, strutils]`` only, so the macro layer runs it at compile time and
## the tool resolver can quote the same remedy at run time.

import std/[os, strutils]

const ReprobuildPackagesRootEnv* = "REPROBUILD_PACKAGES_ROOT"
  ## Where the `reprobuild-packages` catalog checkout lives, when it is not a
  ## workspace sibling. When it is set, it is the ONLY place looked in. The
  ## daemon forwards it (`DaemonExplicitForwardedEnvVars`).

const ReprobuildPackagesRepositoryUrl* =
  "https://github.com/metacraft-labs/reprobuild-packages"

const MovedToReprobuildPackages*: seq[string] = @["sqlite3"]
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

proc reprobuildCheckoutRoot(): string =
  # <reprobuild>/libs/repro_project_dsl/src/repro_project_dsl/<this file>
  currentSourcePath().parentDir.parentDir.parentDir.parentDir.parentDir

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
  ## 3. a ``reprobuild-packages`` directory beside the reprobuild checkout
  ##    this module was compiled from.
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
  let besideReprobuild = reprobuildCheckoutRoot().parentDir / "reprobuild-packages"
  if besideReprobuild notin seen:
    probe(result, "beside the reprobuild checkout " & reprobuildCheckoutRoot(),
      besideReprobuild)

proc reprobuildPackagesInterfaceModule*(selector, consumerSourceFile: string):
    string =
  ## The module that defines package ``selector`` in the catalog --
  ## ``<root>/packages/interfaces/<selector>/repro.nim`` -- WITHOUT its
  ## ``.nim`` extension, or "" when there is none. See
  ## `reprobuildPackagesSearch` for where it looks.
  reprobuildPackagesSearch(selector, consumerSourceFile).module

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
    consumerSourceFile: string; sourceLine = 0): string =
  ## "" unless ``selector`` is a moved package (`MovedToReprobuildPackages`)
  ## that no catalog defines for this consumer; otherwise the full error text.
  if selector notin MovedToReprobuildPackages:
    return ""
  let search = reprobuildPackagesSearch(selector, consumerSourceFile)
  if search.module.len > 0:
    return ""
  let where =
    if consumerSourceFile.len > 0 and sourceLine > 0:
      consumerSourceFile & "(" & $sourceLine & "): "
    elif consumerSourceFile.len > 0:
      consumerSourceFile & ": "
    else:
      ""
  where & "uses: \"" & rawConstraint & "\" names `" & selector &
    "`, which is no longer bundled with reprobuild's stdlib: it is defined" &
    " by the reprobuild-packages catalog (packages/interfaces/" & selector &
    "/repro.nim), and no reachable catalog defines it.\n" &
    "The catalog was looked for at:\n" &
    describeReprobuildPackagesSearch(search) & "\n" &
    reprobuildPackagesRemedy()

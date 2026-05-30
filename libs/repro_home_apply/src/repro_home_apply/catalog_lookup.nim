## M69 — package-reference → catalog-slice resolver.
##
## Bridges the parsed `home.nim` ``package(<id>[, "<version>"])``
## references (produced by `repro_home_intent` and threaded through
## the planner as ``PlannedPackage.requestedVersion``) onto the M63
## ``VersionedProvisioning`` catalog slice.
##
## Resolution rules (spec-mandated, fail-closed):
##
##   * The ``packageId`` must be registered in the M65 catalog
##     registry (``catalog_registry.getCatalog``). An unknown id
##     raises ``EUnknownPackageId``.
##   * A bare reference (empty ``requestedVersion``) picks the
##     catalog's ``defaultVersion`` slice (the last entry per the
##     M63 convention, surfaced via ``selectDefault``).
##   * A pinned reference picks the slice whose ``version`` field
##     matches exactly (``selectVersion``). A miss raises
##     ``EVersionNotInCatalog`` carrying the requested + available
##     versions so the apply pipeline can surface a structured
##     diagnostic.
##   * Semver-range references and ``latest`` are NOT resolved here:
##     the structural editor materializes ``latest`` at edit time
##     (writing the concrete pinned literal), so the apply pipeline
##     sees an exact version pin or a bare reference exclusively.
##     Future range support lands in a follow-up milestone; until
##     then a ``requestedVersion`` containing characters other than
##     ``[0-9a-zA-Z._-+]`` is rejected as ill-formed.
##
## The resolved slice is bundled into a ``LookedUpSlice`` carrying
## the registered catalog entry and the registered package id so
## downstream callers can hand the result straight to the M64
## ``builtin_adapter`` realize loop via
## ``resolveBuiltinPackage`` without re-walking the catalog.

import std/options
import std/strutils

import repro_dsl_stdlib/catalog_registry
import repro_dsl_stdlib/packages_schema

type
  EUnknownPackageId* = object of CatchableError
    ## M69: the requested ``packageId`` has no entry in the built-in
    ## catalog registry. The exception carries the rejected id and
    ## the registered alternatives so the CLI can surface a "did you
    ## mean ..." style diagnostic.
    packageId*: string
    registered*: seq[string]

  EVersionNotInCatalog* = object of CatchableError
    ## M69: the catalog for ``packageId`` exists but no slice
    ## matches ``requestedVersion``. Carries the available version
    ## list so the CLI can suggest a valid pin.
    packageId*: string
    requestedVersion*: string
    availableVersions*: seq[string]

  LookedUpSlice* = object
    packageId*: string                ## the registered catalog key
    requestedVersion*: string         ## "" when bare; the literal pin
                                      ## otherwise
    resolvedVersion*: string          ## the slice's actual `version`
                                      ## (== requestedVersion for a pinned
                                      ## lookup; defaultVersion for bare)
    slice*: VersionedProvisioning

proc registeredToolNames*(): seq[string] =
  ## Return a sorted snapshot of the registered tool names. Used by
  ## the error-rendering paths so a `EUnknownPackageId` carries the
  ## set the user could have pinned.
  for name in RegisteredTools:
    result.add(name)

proc raiseUnknownPackageId*(packageId: string) {.noreturn.} =
  var e = newException(EUnknownPackageId,
    "no built-in catalog registered for package '" & packageId &
    "'. Registered tools: " & registeredToolNames().join(", ") &
    ". Add a `packages/<tool>.nim` entry and register it in " &
    "`catalog_registry.nim` to make `package(" & packageId & ")` " &
    "resolvable.")
  e.packageId = packageId
  e.registered = registeredToolNames()
  raise e

proc raiseVersionNotInCatalog*(packageId, requestedVersion: string;
                               available: seq[string]) {.noreturn.} =
  var e = newException(EVersionNotInCatalog,
    "version '" & requestedVersion & "' is not in the built-in catalog " &
    "for package '" & packageId & "'. Available versions: " &
    available.join(", ") &
    ". Pin a known version, drop the pin to fall back to the catalog's " &
    "defaultVersion, or extend `packages/" & packageId & ".nim` with a " &
    "new slice carrying that version.")
  e.packageId = packageId
  e.requestedVersion = requestedVersion
  e.availableVersions = available
  raise e

proc isWellFormedVersionPin*(v: string): bool =
  ## A version pin is a non-empty SemVer-ish string limited to ASCII
  ## alphanumerics + `.`, `_`, `-`, `+`. The structural editor and
  ## the M65 CLI both write this shape; anything else is a sign of a
  ## malformed home.nim or a future range form that the M69 resolver
  ## does NOT handle.
  if v.len == 0: return false
  for ch in v:
    if not (ch.isAlphaAscii() or ch.isDigit() or ch in {'.', '_', '-', '+'}):
      return false
  true

proc lookupCatalogSlice*(packageId: string;
                         requestedVersion = ""): LookedUpSlice =
  ## Resolve a ``home.nim`` package reference to a catalog slice.
  ## Raises ``EUnknownPackageId`` for an unregistered tool;
  ## ``EVersionNotInCatalog`` for a pinned reference whose version
  ## is not in the registered catalog.
  let catOpt = getCatalog(packageId)
  if catOpt.isNone:
    raiseUnknownPackageId(packageId)
  let catalog = catOpt.get
  if catalog.len == 0:
    # The registry entry exists but the catalog literal is empty —
    # treat as "no versions in catalog" (an empty available list) so
    # downstream diagnostics are accurate.
    raiseVersionNotInCatalog(packageId,
      if requestedVersion.len > 0: requestedVersion else: "<default>",
      @[])
  if requestedVersion.len == 0:
    let def = selectDefault(catalog)
    if not def.found:
      raiseVersionNotInCatalog(packageId, "<default>", @[])
    result = LookedUpSlice(
      packageId: packageId,
      requestedVersion: "",
      resolvedVersion: def.entry.version,
      slice: def.entry)
    return
  if not isWellFormedVersionPin(requestedVersion):
    raiseVersionNotInCatalog(packageId, requestedVersion,
      block:
        var versions: seq[string]
        for vp in catalog: versions.add(vp.version)
        versions)
  let exact = selectVersion(catalog, requestedVersion)
  if not exact.found:
    var versions: seq[string]
    for vp in catalog: versions.add(vp.version)
    raiseVersionNotInCatalog(packageId, requestedVersion, versions)
  result = LookedUpSlice(
    packageId: packageId,
    requestedVersion: requestedVersion,
    resolvedVersion: exact.entry.version,
    slice: exact.entry)

proc latestCatalogVersion*(packageId: string):
    tuple[found: bool; version: string] =
  ## M69: structural editor support for ``repro home add <tool>@latest``.
  ## Returns the highest-SemVer slice's ``version`` for ``packageId``,
  ## or ``(found: false, "")`` when the tool is unregistered or its
  ## catalog is empty. "Highest" is computed by a simple lexicographic
  ## comparison over dot-separated numeric components — the catalog
  ## convention is newest-first so the implementation reduces to
  ## ``selectDefault``. A future range-aware resolver will replace
  ## this with a proper SemVer parse.
  let catOpt = getCatalog(packageId)
  if catOpt.isNone:
    return (false, "")
  let catalog = catOpt.get
  let def = selectDefault(catalog)
  if not def.found:
    return (false, "")
  (true, def.entry.version)

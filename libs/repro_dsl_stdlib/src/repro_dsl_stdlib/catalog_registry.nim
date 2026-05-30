## M65 — built-in catalog registry.
##
## A small lookup table that maps a tool name (the ``packageId`` shape
## the apply pipeline passes to ``resolvePackage``) to the corresponding
## ``<tool>Catalog: seq[VersionedProvisioning]`` literal exported by the
## tool's ``packages/<tool>.nim`` module.
##
## **Why a registry?** The M65 adapter selection chain must consult the
## built-in catalog without importing every ``packages/<tool>.nim`` at
## the call site (there are ~70 of them and growing). The chain calls
## ``getCatalog(toolName)`` and the registry handles the per-tool import
## fanout, returning an ``Option[seq[VersionedProvisioning]]`` that the
## chain feeds straight into ``resolveBuiltinPackage``.
##
## **Scope.** M65 ships ONE registered entry (``jdk`` — the M63 reference
## catalog). M67 and M68 bulk-populate the registry as catalogs are
## harvested from the public Scoop buckets. Until then,
## ``getCatalog("anything-else")`` returns ``none(seq[VersionedProvisioning])``
## and the chain falls through to the next adapter (cakScoop / cakPath).
##
## **Future shape.** The registry is intentionally a plain proc with a
## ``case`` over tool names rather than a compile-time table — this
## keeps the per-tool import statements explicit and grep-able, lets us
## detect a missing registration as a build-time error in M67/M68 (the
## bulk-populate milestones add one ``case`` arm per harvested tool),
## and avoids a startup-time table construction cost on every CLI
## invocation. When the registry grows past ~50 entries M67 may switch
## to a compile-time generated table; the proc signature is stable.

import std/[options, sets]

import ./packages_schema
import ./packages/jdk
# M67 bulk-harvested catalogs. The Scoop bucket provenance and per-tool
# version pin live in each module's auto-generated header comment.
import ./packages/cabal
import ./packages/composer
import ./packages/crystal
import ./packages/elixir
import ./packages/erlang
import ./packages/ghc
import ./packages/gradle
import ./packages/maven
import ./packages/php
import ./packages/ruby
import ./packages/swift
import ./packages/zig

export packages_schema

const RegisteredTools* = [
  ## The tool names the M65 registry recognizes. M67/M68 bulk-populate
  ## adds entries here. Exposed for diagnostics (the adapter chain can
  ## name "the built-in catalog knows: <list>" in its skip-reason
  ## telemetry).
  "jdk",
  # M67 — JVM/Apple toolchains, niche obj+linker, functional + dynamic
  # langs (alphabetized within the M67 block for grep-friendliness).
  "cabal",
  "composer",
  "crystal",
  "elixir",
  "erlang",
  "ghc",
  "gradle",
  "maven",
  "php",
  "ruby",
  "swift",
  "zig",
]

proc getCatalog*(toolName: string):
    Option[seq[VersionedProvisioning]] =
  ## Look up the built-in ``<tool>Catalog`` for ``toolName``. Returns
  ## ``some(catalog)`` when the tool is registered AND the catalog is
  ## non-empty; ``none`` otherwise (the chain falls through to the next
  ## adapter on ``none``).
  ##
  ## Case-sensitive: the registry's authoritative keys are the
  ## ``packages/<tool>.nim`` basenames, which are lowercased by
  ## convention. Callers normalize before lookup if their input source
  ## (e.g. ``home.nim`` ``package(...)`` references) is case-insensitive.
  template selectIfNonEmpty(catVal: typed): untyped =
    if catVal.len > 0:
      some(catVal)
    else:
      none(seq[VersionedProvisioning])
  case toolName
  of "jdk":      selectIfNonEmpty(jdkCatalog)
  of "cabal":    selectIfNonEmpty(cabalCatalog)
  of "composer": selectIfNonEmpty(composerCatalog)
  of "crystal":  selectIfNonEmpty(crystalCatalog)
  of "elixir":   selectIfNonEmpty(elixirCatalog)
  of "erlang":   selectIfNonEmpty(erlangCatalog)
  of "ghc":      selectIfNonEmpty(ghcCatalog)
  of "gradle":   selectIfNonEmpty(gradleCatalog)
  of "maven":    selectIfNonEmpty(mavenCatalog)
  of "php":      selectIfNonEmpty(phpCatalog)
  of "ruby":     selectIfNonEmpty(rubyCatalog)
  of "swift":    selectIfNonEmpty(swiftCatalog)
  of "zig":      selectIfNonEmpty(zigCatalog)
  else:
    none(seq[VersionedProvisioning])

proc isRegistered*(toolName: string): bool =
  ## True when ``toolName`` has an entry in the registry, independent
  ## of whether the catalog is currently empty. Useful for the chain's
  ## diagnostic message: a ``none`` from ``getCatalog`` could mean
  ## either "no registry entry" or "registry entry exists but the
  ## catalog literal is empty"; ``isRegistered`` distinguishes them.
  for name in RegisteredTools:
    if name == toolName:
      return true
  false

proc registeredToolSet*(): HashSet[string] =
  ## The set of registered tool names. Stable across calls (the
  ## underlying ``RegisteredTools`` array is a compile-time constant).
  for name in RegisteredTools:
    result.incl(name)

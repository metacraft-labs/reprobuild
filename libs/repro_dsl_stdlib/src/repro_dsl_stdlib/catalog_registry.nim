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
# M68 baseline dev tools (env.ps1 / repo-workspaces bootstrap targets).
# Some merge their catalog with a pre-existing M21 ``package <tool>:`` DSL
# block (nim, git, gh, just, gcc, node, python3); cmake / ninja / meson /
# dotnet_sdk are new files. ``python`` and ``dotnet-sdk`` were harvested
# via --app-alias to satisfy Nim-identifier constraints.
import ./packages/cmake
import ./packages/dotnet_sdk
import ./packages/gcc
import ./packages/gh
import ./packages/git
import ./packages/just
import ./packages/meson
import ./packages/nim
import ./packages/ninja
import ./packages/node
import ./packages/python3
# M1 (Realize-Closure spec) — Pascal toolchain graduation. fpc's Scoop
# manifest ships a sha1 digest, so the schema extension landed first.
import ./packages/fpc
# M3 (Realize-Closure-And-Catalog-Expansion spec) — 7-Zip catalog
# prerequisite. Registered under the operator-facing tool name ``7zip``
# (string); the underlying packages/<file>.nim is sevenzip.nim because
# Nim identifiers cannot start with a digit. Hand-authored against the
# upstream standalone 7zr.exe — see packages/sevenzip.nim's header for
# the rationale + the operator-visible re-harvest caveat.
import ./packages/sevenzip
# M4 (Realize-Closure-And-Catalog-Expansion spec) — Windows installer
# family prerequisites:
#   * wix3 — provides dark.exe for MSI extraction (imInstallerMsi +
#     imInstallerNsisBundle realize hooks).
#   * innounp — provides innounp.exe for Inno Setup extraction
#     (imInstallerInnoSetup realize hook).
# Both are catalog packages per the bundling-posture amendment (NO
# vendored binaries); cakBuiltin discovers them via the standard
# catalog-prefix → PATH → fail-closed order.
import ./packages/wix3
import ./packages/innounp
# M4 amendment (post-live-smoke finding): lessmsi is the canonical
# MSI-to-file-tree extractor. WiX dark.exe stays in the registry for
# completeness (some operators use it for MSI decompilation) but the
# M4 ``imInstallerMsi`` realize hook dispatches through lessmsi by
# default. See packages/lessmsi.nim's header for the rationale.
import ./packages/lessmsi

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
  # M68 — baseline dev tools every env.ps1 currently provisions
  # (alphabetized within the M68 block for grep-friendliness).
  # ``python3`` and ``dotnet-sdk`` are the registered keys; the
  # underlying packages/<tool>.nim files use the (renamed) Nim-identifier
  # names ``python3`` and ``dotnet_sdk``.
  "cmake",
  "dotnet-sdk",
  "gcc",
  "gh",
  "git",
  "just",
  "meson",
  "nim",
  "ninja",
  "node",
  "python3",
  # M1 (Realize-Closure spec) — Pascal toolchain (sha1 weak-hash).
  "fpc",
  # M3 (Realize-Closure-And-Catalog-Expansion spec) — 7-Zip as a
  # catalog package. Discovery-by-prefix bootstraps the cakBuiltin 7z
  # family hooks (SFX flatten + nested 7z + Scoop pre_install runner)
  # without requiring a host PATH 7z.
  "7zip",
  # M4 (Realize-Closure-And-Catalog-Expansion spec) — WiX v3 + innounp
  # as catalog packages. Discovery-by-prefix bootstraps the cakBuiltin
  # Windows installer family hooks (MSI extract via dark.exe; NSIS+MSI
  # bundle flatten; Inno Setup extract via innounp.exe) without
  # requiring host PATH copies.
  "wix3",
  "innounp",
  # M4 amendment: lessmsi as the canonical MSI extractor.
  "lessmsi",
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
  of "jdk":        selectIfNonEmpty(jdkCatalog)
  of "cabal":      selectIfNonEmpty(cabalCatalog)
  of "composer":   selectIfNonEmpty(composerCatalog)
  of "crystal":    selectIfNonEmpty(crystalCatalog)
  of "elixir":     selectIfNonEmpty(elixirCatalog)
  of "erlang":     selectIfNonEmpty(erlangCatalog)
  of "ghc":        selectIfNonEmpty(ghcCatalog)
  of "gradle":     selectIfNonEmpty(gradleCatalog)
  of "maven":      selectIfNonEmpty(mavenCatalog)
  of "php":        selectIfNonEmpty(phpCatalog)
  of "ruby":       selectIfNonEmpty(rubyCatalog)
  of "swift":      selectIfNonEmpty(swiftCatalog)
  of "zig":        selectIfNonEmpty(zigCatalog)
  # M68 baseline dev tools.
  of "cmake":      selectIfNonEmpty(cmakeCatalog)
  of "dotnet-sdk": selectIfNonEmpty(dotnet_sdkCatalog)
  of "gcc":        selectIfNonEmpty(gccCatalog)
  of "gh":         selectIfNonEmpty(ghCatalog)
  of "git":        selectIfNonEmpty(gitCatalog)
  of "just":       selectIfNonEmpty(justCatalog)
  of "meson":      selectIfNonEmpty(mesonCatalog)
  of "nim":        selectIfNonEmpty(nimCatalog)
  of "ninja":      selectIfNonEmpty(ninjaCatalog)
  of "node":       selectIfNonEmpty(nodeCatalog)
  of "python3":    selectIfNonEmpty(python3Catalog)
  # M1 (Realize-Closure spec) — Pascal toolchain.
  of "fpc":        selectIfNonEmpty(fpcCatalog)
  # M3 (Realize-Closure-And-Catalog-Expansion spec) — 7-Zip.
  of "7zip":       selectIfNonEmpty(sevenzipCatalog)
  # M4 (Realize-Closure-And-Catalog-Expansion spec) — WiX v3 + innounp.
  of "wix3":       selectIfNonEmpty(wix3Catalog)
  of "innounp":    selectIfNonEmpty(innounpCatalog)
  of "lessmsi":    selectIfNonEmpty(lessmsiCatalog)
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

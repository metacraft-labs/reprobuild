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

# PMC-1 (Platform-And-Microarchitecture-Constraints): the package-level
# ``platforms:`` declaration lives on ``PackageDef``, which the ``package``
# macro registers into ``repro_project_dsl``'s process-wide registry at module
# init. Every ``packages/<tool>.nim`` this module imports below already pulls
# ``repro_project_dsl`` in, so the direct import adds no weight — it only
# brings ``declaredPackagePlatforms`` into scope so the resolver can ask this
# module (the one place that guarantees the stdlib recipes are IMPORTED, and
# therefore registered) where a package is allowed to exist.
import repro_project_dsl

import ./packages_schema
import ./packages/jdk
# M67 bulk-harvested catalogs. The Scoop bucket provenance and per-tool
# version pin live in each module's auto-generated header comment.
import ./packages/cabal
# Dotfiles-Migration-Completion M0 — Anthropic Claude Code CLI.
# Upstream ships a single bare native binary per (cpu, os) under a
# stable GCS prefix; catalog uses afRaw + imExtract per
# packages/claude_code.nim's header.
import ./packages/claude_code
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
# clingo: the ASP solver repro_solver dlopens at module init. Wired now that
# the `conda` archiveType can realize conda-forge's Windows package; the
# scaffold sat unimported while that was inexpressible.
import ./packages/clingo
# chocolatey: the Windows `choco` CLI. Unlike most entries this is an OUTPUT
# tool — the codetracer-*-recorder repos run `choco pack` / `choco push` to
# publish a release, the Windows sibling of their Homebrew/Scoop/AUR lanes.
# Declared here so those projects can `uses: "chocolatey"` and get the same
# pinned binary in a developer's dev env and in CI, instead of depending on
# whatever a runner happened to have installed.
import ./packages/chocolatey
# zstd: dlopen'd by `repro cache substitute` to decompress binary-cache
# payloads. The entry and its Windows slice (facebook/zstd v1.5.6 win64
# release) already existed but were never imported, so the catalog could not
# resolve it and repro.nim's Windows staging edge fell back to probing PATH.
# Wiring it is a prerequisite for that edge consuming a realized prefix instead.
import ./packages/zstd
import ./packages/dotnet_sdk
import ./packages/gcc
import ./packages/gh
import ./packages/git
import ./packages/go
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
# Nim identifiers cannot start with a digit.
#
# **M8 transition**: replaced the hand-authored 7zr.exe bootstrap entry
# with the harvested Scoop MSI catalog (re-harvest:
# ``repro_catalog_harvester harvest --bucket ScoopInstaller/Main
# --app 7zip --app-alias 7zip=sevenzip``). The MSI ships the full 7-Zip
# distribution (CLI + GUI + plugins including the zstd codec — closes a
# follow-up from M6's MSYS2 .zst extraction). M3's hand-authored
# ``bin/7z.exe`` shape is gone; the MSI places ``7z.exe`` at the prefix
# root after lessmsi flattens ``Files\7-Zip``. ``discoverSevenZipExe`` in
# repro_home_apply was extended in M8 to probe both ``<prefix>/bin/7z.exe``
# (legacy + synthetic test seeds) and ``<prefix>/7z.exe`` (M8 MSI shape).
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
# M6 (Realize-Closure-And-Catalog-Expansion spec) — MSYS2 pacman
# harvester source enables OCaml as a catalog package. The .pkg.tar.zst
# format extracts via the M6 zstd-capable extractor discovery
# (catalog 7z → host tar --zstd → host zstd pipe) and the realize hook
# flattens the inner ``mingw64/`` subtree to the prefix root. Dependency
# resolution stays the operator's responsibility — list every required
# MSYS2 package in home.nim (e.g. flexdll, gmp).
import ./packages/autoconf
import ./packages/automake
import ./packages/libtool
import ./packages/ocaml
# M7 (Realize-Closure-And-Catalog-Expansion spec) — GitHub Releases
# harvester source. ``alire`` (Ada toolchain manager) is the first
# end-to-end consumer; the ``alr-...-bin-x86_64-windows.zip`` asset
# ships ``bin/alr.exe`` at the archive root, fitting cakBuiltin's
# ``afZip + imExtract`` baseline without any new dispatch surface.
import ./packages/alire
# M8 (Realize-Closure-And-Catalog-Expansion spec) — bulk-harvest pass
# over the M6 + M7 harvester sources. Two new GitHub-Releases-harvested
# Windows toolchains land here:
#   * ``gcc-winlibs`` — brechtsanders/winlibs_mingw distribution. Ships
#     the full mingw-w64 GCC stack (gcc + g++ + gfortran + binutils ld)
#     under ``mingw64/`` inside a ``.7z`` archive. Coexists with the M68
#     ``gcc`` entry (nuwen.net components-20.0 via Scoop); the M68 entry
#     lacks gfortran while winlibs bundles it.
#   * ``llvm-mingw`` — mstorsjo/llvm-mingw distribution. Ships clang +
#     clang++ + lld (ld.lld.exe) under a top-level
#     ``llvm-mingw-<tag>-<crt>-<arch>/`` directory inside a ``.zip``.
#     First clang-on-Windows catalog (M68 left clang DEFERRED per its
#     header note — Scoop main has no ``clang.json``).
import ./packages/gcc_winlibs
import ./packages/llvm_mingw
# Recorder dev-env additions (codetracer-*-recorder family). Each
# entry pairs an existing nixpkgs# selector (where one exists) with
# a Windows / non-Nix-Linux catalog slice. ``circom`` and ``forc``
# carry only the catalog block because their tools live outside
# nixpkgs (mcl-blockchain builds them out-of-tree). ``rustc`` /
# ``cargo`` / ``rustfmt`` / ``clippy`` all share the same per-channel
# Rust toolchain archive on Windows; the realize loop dedups the
# download by URL when multiple consumers reference the same SHA.
import ./packages/cargo
import ./packages/circom
import ./packages/clippy
import ./packages/forc
import ./packages/foundry
import ./packages/rustc
import ./packages/rustfmt
import ./packages/solc
import ./packages/create_dmg

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
  # Dotfiles-Migration-Completion M0 — Anthropic Claude Code CLI.
  "claude-code",
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
  # M6 (Realize-Closure-And-Catalog-Expansion spec) — first MSYS2-
  # harvested catalog tool.
  "autoconf",
  "automake",
  "libtool",
  "libtoolize",
  "ocaml",
  # M7 (Realize-Closure-And-Catalog-Expansion spec) — first
  # GitHub-Releases-harvested catalog tool. Ada toolchain manager.
  "alire",
  # M8 (Realize-Closure-And-Catalog-Expansion spec) — bulk-harvest
  # additions. ``gcc-winlibs`` is the operator-facing key for the
  # winlibs-distributed GCC (coexists with the M68 ``gcc`` Scoop entry;
  # winlibs ships gfortran which the nuwen.net components-20.0 does not).
  # ``llvm-mingw`` is the operator-facing key for the mstorsjo/llvm-mingw
  # clang+lld distribution (the first clang-on-Windows catalog entry).
  "gcc-winlibs",
  "llvm-mingw",
  # Recorder dev-env additions (codetracer-*-recorder family). The
  # five new tools are joined by Windows/non-Nix-Linux slices on the
  # four existing Rust-toolchain entries so the recorder dev shells
  # can be materialised end-to-end through cakBuiltin.
  "cargo",
  "circom",
  "clippy",
  "forc",
  "foundry",
  "rustc",
  "rustfmt",
  "solc",
  "create-dmg",
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
  of "claude-code": selectIfNonEmpty(claudeCodeCatalog)
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
  of "go":         selectIfNonEmpty(goCatalog)
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
  # M6 (Realize-Closure-And-Catalog-Expansion spec) — MSYS2-harvested.
  of "autoconf":   selectIfNonEmpty(autoconfCatalog)
  of "automake":   selectIfNonEmpty(automakeCatalog)
  of "libtool":    selectIfNonEmpty(libtoolCatalog)
  of "libtoolize": selectIfNonEmpty(libtoolizeCatalog)
  of "ocaml":      selectIfNonEmpty(ocamlCatalog)
  # M7 (Realize-Closure-And-Catalog-Expansion spec) — GitHub-Releases-harvested.
  of "alire":      selectIfNonEmpty(alireCatalog)
  # M8 (Realize-Closure-And-Catalog-Expansion spec) — bulk-harvest.
  # The Nim-identifier filenames (``gcc_winlibs`` / ``llvm_mingw``) are
  # mapped to the operator-facing hyphenated keys (``gcc-winlibs`` /
  # ``llvm-mingw``).
  of "gcc-winlibs": selectIfNonEmpty(gcc_winlibsCatalog)
  of "llvm-mingw":  selectIfNonEmpty(llvm_mingwCatalog)
  # Recorder dev-env additions.
  of "cargo":       selectIfNonEmpty(cargoCatalog)
  of "circom":      selectIfNonEmpty(circomCatalog)
  of "clippy":      selectIfNonEmpty(clippyCatalog)
  of "forc":        selectIfNonEmpty(forcCatalog)
  of "foundry":     selectIfNonEmpty(foundryCatalog)
  of "rustc":       selectIfNonEmpty(rustcCatalog)
  of "rustfmt":     selectIfNonEmpty(rustfmtCatalog)
  of "solc":        selectIfNonEmpty(solcCatalog)
  of "create-dmg":  selectIfNonEmpty(create_dmgCatalog)
  else:
    none(seq[VersionedProvisioning])

proc packageAvailability*(packageId: string): PackageAvailability =
  ## PMC-1: where is ``packageId`` DECLARED to exist?
  ##
  ## Reads the package-level ``platforms:`` block off the registered
  ## ``PackageDef``. Returns ``declared = false`` when the package wrote no
  ## such block, when the name is not a registered package, or when the
  ## recipe module was never imported into this process — all three of which
  ## must behave exactly as they did before PMC-1, so the resolver leaves the
  ## adapter chain alone for them.
  ##
  ## Lookup is by DSL package name, the same key ``registeredPackages()``
  ## uses. That is the name the ``uses:`` selector and the apply pipeline's
  ## ``packageId`` already carry.
  let declaration = declaredPackagePlatforms(packageId)
  if not declaration.declared:
    return PackageAvailability(declared: false)
  result.declared = true
  result.message = declaration.message
  for constraint in declaration.platforms:
    # The DSL stores the coordinate as the same token vocabulary the arm
    # setters use; the resolver works in the schema enums. A token that fails
    # to parse cannot reach here — the ``package`` macro rejects it at
    # authoring time — but a defensive skip keeps a future vocabulary drift
    # from turning into a package that is available nowhere.
    let cpu = parsePlatformCpuToken(constraint.cpu)
    let os = parsePlatformOsToken(constraint.os)
    if cpu.ok and os.ok:
      result.platforms.add(PackagePlatform(cpu: cpu.cpu, os: os.os))

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

## The stdlib package definitions the engine links for profile resolution.
##
## GM4b (Provisioning-Contributions.md §"Profile Package References"): a home
## profile's ``package "<name>"`` resolves through the canonical definition and
## its contributions, exactly as a recipe's ``uses:`` does. A recipe gets its
## definitions by importing package modules at compile time; the engine that
## runs ``repro home apply`` gets them by linking this module, whose imports
## register every definition below into ``repro_project_dsl``'s process-wide
## registry (``registeredPackages()`` / ``registeredProvisioningContributions()``).
##
## Two groups are linked:
##
## * the BUNDLED selectors — ``BundledStdlibSelectors``, the list
##   ``usesImportCode`` auto-imports for a bare ``uses:`` line. The imports are
##   generated from that list, so every package a recipe resolves by name is a
##   package a profile resolves by name;
## * the stdlib packages that carried a ``VersionedProvisioning`` catalog before
##   GM4b (``jdk``, ``maven``, ``sevenzip``, ...). A recipe reaches these through an
##   explicit import; a profile reached them through the retired
##   ``catalog_registry``, and must keep reaching them.
##
## This module replaces ``catalog_registry``: there is no separate catalog any
## more, only package definitions whose ``tarball`` realizations carry what the
## catalog records held.

import std/[macros, sets]

import repro_project_dsl

import ./packages_schema

export packages_schema

macro importBundledStdlibPackages(): untyped =
  ## One ``import repro_dsl_stdlib/packages/<module>`` per bundled selector,
  ## generated from ``BundledStdlibSelectors`` with ``usesImportCode``'s own
  ## selector-to-module mapping, so the two cannot list different packages.
  result = newStmtList()
  var seen: seq[string] = @[]
  for selector in BundledStdlibSelectors:
    let module = bundledStdlibModuleName(selector)
    if module in seen:
      continue
    seen.add(module)
    result.add(nnkImportStmt.newTree(
      nnkInfix.newTree(ident("/"),
        nnkInfix.newTree(ident("/"), ident("repro_dsl_stdlib"),
          ident("packages")),
        ident(module))))

importBundledStdlibPackages()

# The stdlib packages whose archive realizations lived in a
# ``VersionedProvisioning`` catalog before GM4b. Explicit and grep-able, as the
# retired registry's imports were; several are also bundled, and a module
# imported twice is initialized once.
import ./packages/[jdk, cabal, claude_code, composer, crystal, elixir, erlang,
  ghc, gradle, maven, php, ruby, swift, zig, cmake, clingo, chocolatey, zstd,
  dotnet_sdk, gcc, gh, git, go, just, meson, nim, ninja, node, python3, fpc,
  sevenzip, wix3, innounp, lessmsi, autoconf, automake, libtool, ocaml, alire,
  gcc_winlibs, llvm_mingw, cargo, circom, clippy, forc, foundry, rustc,
  rustfmt, solc, create_dmg]

proc linkedPackageNames*(): HashSet[string] =
  ## The names of every package definition registered in this process — the
  ## definitions a profile reference can resolve against.
  for pkg in registeredPackages():
    result.incl(pkg.packageName)

proc isLinkedPackage*(name: string): bool =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return true
  false

proc packageAvailability*(packageId: string): PackageAvailability =
  ## PMC-1: where is ``packageId`` DECLARED to exist?
  ##
  ## Reads the package-level ``platforms:`` block off the registered
  ## ``PackageDef``. Returns ``declared = false`` when the package wrote no
  ## such block or is not a registered package, which leaves resolution
  ## exactly as it was before PMC-1 for both.
  ##
  ## GM4b: the PMC-5 table of declarations for harvested-only packages
  ## (``HarvestedPlatformDeclarations``) is gone with the catalog it covered.
  ## Those packages (wix3, innounp, lessmsi, sevenzip) now have ``package``
  ## blocks, so their declarations are ordinary ``platforms:`` lines that a
  ## re-harvest no longer regenerates away.
  let declaration = declaredPackagePlatforms(packageId)
  if not declaration.declared:
    return PackageAvailability(declared: false)
  result.declared = true
  result.message = declaration.message
  for constraint in declaration.platforms:
    # The DSL stores the coordinate in the token vocabulary the arm setters
    # use; the selector works in the schema enums. The ``package`` macro
    # rejects an unparseable token at authoring time, so the skip is only a
    # guard against vocabulary drift turning into "available nowhere".
    let cpu = parsePlatformCpuToken(constraint.cpu)
    let os = parsePlatformOsToken(constraint.os)
    if cpu.ok and os.ok:
      result.platforms.add(PackagePlatform(cpu: cpu.cpu, os: os.os))

# ---------------------------------------------------------------------------
# PMC-5 — packages whose archive realizations cover ONE OS
# ---------------------------------------------------------------------------
#
# A package whose ``tarball`` realizations name exactly one OS is either
# platform-bound (declare ``platforms:`` on the package) or merely narrowly
# harvested. The data cannot tell the two apart, so each such package is
# decided by a human: declared, or listed here with the reason the narrow
# coverage is a gap rather than a property. ``t_single_platform_entries_
# declare_platforms`` fails for a package that is neither.
const PartialCatalogCoverage* = {
  "gcc": "gcc.nim's nixPackage is the realization on Nix-capable hosts; " &
    "the harvested archives are the Windows half only.",
  "gcc-winlibs": "the WinLibs distribution of gcc; gcc proper is cross-platform.",
  "git": "harvested Windows archives only.",
  "python3": "harvested Windows archives only.",
  "ruby": "harvested Windows archives only.",
  "php": "harvested Windows archives only.",
  "composer": "harvested Windows archives only.",
  "erlang": "harvested Windows archives only.",
  "elixir": "harvested Windows archives only.",
  "meson": "harvested Windows archives only.",
  "ocaml": "harvested Windows archives only.",
  "swift": "harvested Windows archives only.",
  "dotnet-sdk": "harvested Windows archives only.",
  "fpc": "Free Pascal runs on POSIX too; harvested Windows archive only.",
  "autoconf": "harvested Windows archives only.",
  "automake": "harvested Windows archives only.",
  "libtool": "harvested Windows archives only.",
  "libtoolize": "harvested Windows archives only.",
  # GM4b broadened the survey from the former catalog packages to every
  # linked package; these carry a Windows archive beside a nixPackage (or
  # are plainly portable tools) and exist on every platform.
  "clingo": "Windows conda archive only; POSIX hosts use the nixPackage.",
  "nsis": "makensis runs on POSIX too; Windows archive only.",
  "curl": "Windows archive only; POSIX hosts use the nixPackage.",
  "make": "Windows archive only; POSIX hosts use the nixPackage.",
  "bash": "Windows archive only; POSIX hosts use the nixPackage.",
  "clang": "Windows archive only; POSIX hosts use the nixPackage.",
  "capnp": "Windows archive only; POSIX hosts use the nixPackage.",
  "zstd": "Windows archive only; POSIX hosts use the nixPackage.",
  "tmux": "Windows archive only; POSIX hosts use the nixPackage.",
  "sh": "Windows archive only; POSIX hosts have a system shell.",
  "openssl": "Windows archive only; POSIX hosts use the nixPackage."
}

const PlatformDeclarationSourceFile* =
  "libs/repro_dsl_stdlib/src/repro_dsl_stdlib/package_registry.nim"
  ## Named in diagnostics so a developer does not have to find it.

proc platformDeclarationGuidance*(packageId: string; onlyOs: string): string =
  ## The remediation text for "this package's archive realizations cover
  ## exactly one OS and nobody has said whether that is a fact about the
  ## package or about what was harvested". Beside the table so every surface
  ## that asks the question renders the same words.
  let os = if onlyOs.len > 0: onlyOs else: "one OS"
  result = """
  Package '""" & packageId & """' has archive realizations for """ & os &
    """ only, and nothing records WHY. Reprobuild cannot infer it: "this
  package cannot exist elsewhere" and "we only harvested this platform" look
  identical in the data, and guessing wrong in one direction breaks builds.

  Pick ONE of the two:

  (a) The package genuinely cannot exist on other platforms.
      Declare it on the package itself, in its packages/<name>.nim:

          package """ & packageId & """:
            platforms [""" & os & """]

      Effect: an unguarded `uses: """" & packageId & """"` or profile
      reference on another platform now FAILS NAMING THE REASON instead of
      reporting a missing realization, and PATH stops being reachable for it
      -- so it can no longer silently resolve to a same-named binary.

  (b) The package exists elsewhere; only this platform was harvested.
      Add to PartialCatalogCoverage in """ & PlatformDeclarationSourceFile & """:

          """" & packageId & """": "harvested """ & os & """ archives only.",

      Effect: nothing changes at resolution time. This records the decision
      so the package stops being flagged.

  HOW TO DECIDE: ask whether a build of this package for another platform
  could exist AT ALL -- not whether we have one. `wix3`, `innounp`, `lessmsi`
  wrap Windows Installer formats -> (a). `gcc`, `git`, `python3` run
  everywhere -> (b).

  IF YOU ARE UNSURE, CHOOSE (b). The two errors are NOT symmetric:
    * Wrongly choosing (b) leaves today's behaviour exactly as it is.
    * Wrongly choosing (a) makes the package UNAVAILABLE on every platform you
      did not list. Declaring `gcc` windows-only would stop it resolving on
      Linux.
"""

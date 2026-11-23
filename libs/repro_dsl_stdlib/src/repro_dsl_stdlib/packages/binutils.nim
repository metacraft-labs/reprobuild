## ``binutils`` — GNU binutils stdlib package shim.
##
## DSL-port M9.R.2 ships typed Layer-3 CLI surfaces for the binutils
## tools recipes call most often: ``ld`` (linker), ``ar`` (archiver),
## ``ranlib`` (archive index regenerator), ``strip`` (symbol stripper),
## ``nm`` (symbol table dumper), ``objdump`` (object disassembler),
## ``objcopy`` (object format converter), and ``gas`` (assembler — Nim
## reserves ``as`` as a keyword so the package value is renamed
## ``gas``; the underlying binary name stays ``as``).
##
## **Design note — separate packages vs. multi-executable.** The DSL
## macro layer's typed-wrapper emitter (``toolActionWrapperCode`` in
## ``libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim``)
## emits per-subcmd procs ONLY when the surrounding ``package`` declares
## exactly one ``executable`` block (the explicit early-return at
## ``if pkg.executables.len != 1: return``). The natural shape — one
## ``package binutils:`` with seven ``executable`` blocks so call sites
## read ``binutils.ld(...)`` / ``binutils.ar(...)`` — therefore can't
## fly today; the typed wrapper would never get emitted. We instead
## ship seven separate top-level ``package`` blocks under one shared
## file so the typed call sites are ``ld.call(...)`` / ``ar.call(...)``
## / etc. The ergonomic ``binutils.ld(...)`` form is deferred to a
## future milestone that lifts the one-executable restriction.
##
## All command selectors retain their Nix provisioning shape. ``ar`` and
## ``strip`` additionally select their own version-correct views of the
## pinned distributions GCC uses (WinLibs on Windows x64, the Bootlin
## toolchain on Linux x86_64); normal sibling realization reuse shares the
## verified payload without a second extraction. Other command selectors keep
## their existing provisioning channels.

import std/os
import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/winlibs_pin
import repro_dsl_stdlib/linux_toolchain_pin
# DSL-port M9.R.2c — typed slot var for each ``executable <tool>Bin:``
# declared below (ldBin / arBin / ranlibBin / stripBin / nmBin /
# objdumpBin / objcopyBin / gasBin).
import repro_dsl_stdlib/types/executable

# Aggregate provisioning for recipes that depend on the binutils package as a
# toolchain bundle. The resolver adds the selected binary's parent directory to
# PATH, making the complete pinned binutils tool set available at cycle breaks.
package binutils:
  provisioning:
    nixPackage "nixpkgs#binutils", executablePath = "bin/ld",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

# ---------------------------------------------------------------------------
# ld — GNU linker.
#   ld -o <output> [-L<libdir>...] [-l<lib>...] [-shared] [-static]
#      [-soname=<name>] <object>...
# ---------------------------------------------------------------------------

package ld:
  provisioning:
    nixPackage "nixpkgs#binutils", executablePath = "bin/ld",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

  executable ldBin:
    cli:
      dependencyPolicy automaticMonitor

      call:
        flag output is string,
          alias = "-o",
          format = separate,
          role = output,
          required = true
        flag libDirs is seq[string],
          alias = "-L",
          format = concat,
          repeated = true
        flag libs is seq[string],
          alias = "-l",
          format = concat,
          repeated = true
        boolFlag shared is bool, alias = "-shared"
        boolFlag static is bool, alias = "-static"
        flag soname is string,
          alias = "-soname=",
          format = concat
        flag entry is string,
          alias = "-e",
          format = separate
        pos objects is seq[string],
          position = 0,
          role = input,
          repeated = true

        outputs output

# ---------------------------------------------------------------------------
# ar — GNU archiver.
#   ar rcs <archive> <object>...        # create + replace + write index
#   ar t  <archive>                     # list contents
# Note: ``ar``'s "modifier letters" (``rcs``, ``t``, ``x``, ...) are a
# single positional argument that immediately precedes the archive
# path. We expose them via the ``modifiers`` positional (position 0,
# string scalar) so call sites read ``ar.call(modifiers = "rcs",
# archive = ..., objects = @[...])``.
# ---------------------------------------------------------------------------

package ar:
  provisioning:
    nixPackage "nixpkgs#binutils", executablePath = "bin/ar",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

    # A view of the existing compiler bundle, not another toolchain pin.
    # The release's GNU Binutils version belongs to ar; GCC's version does not.
    tarball url = WinLibsX64Url,
      sha256 = WinLibsX64Sha256,
      archiveType = "7z",
      stripComponents = 1,
      executablePath = "bin/ar.exe",
      packageId = WinLibsX64PackageId,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = WinLibsX64LockIdentity,
      version = WinLibsBinutilsVersion

    # Linux x86_64: the archiver of the toolchain the ``gcc`` package
    # realizes (``linux_toolchain_pin``), from the same pin and relocated
    # the same way, so it runs on any Linux x86_64 host and under the
    # monitor.
    tarball url = LinuxToolchainX64Url,
      sha256 = LinuxToolchainX64Sha256,
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = LinuxToolchainArchiver,
      elfInterpreter = LinuxToolchainLoader,
      elfRunpath = LinuxToolchainRuntimeDir,
      elfPatchDir = LinuxToolchainPatchDirs[0],
      elfPatchDir = LinuxToolchainPatchDirs[1],
      elfPatchDir = LinuxToolchainPatchDirs[2],
      elfPatchDir = LinuxToolchainPatchDirs[3],
      packageId = LinuxToolchainX64PackageId,
      cpu = "x86_64",
      os = "linux",
      lockIdentity = LinuxToolchainX64LockIdentity,
      version = LinuxToolchainBinutilsVersion

  executable arBin:
    cli:
      dependencyPolicy automaticMonitor

      # Caching-Architecture.md D2 -- THE INPUT-CHECK POLICY this tool's edges
      # take when they state none: ``hybrid``. A typed call gets it as the
      # default of its ``actionCachePolicy``; an edge that names the tool only
      # in ``toolIdentityRefs`` gets it through
      # ``repro_core/tool_input_check_policies``, which
      # ``t_tool_input_check_policies`` checks against this line. ``hybrid``
      # records a content hash for every input, so a record of the edge can
      # be shared across checkouts (Edge-Derived-Identities.md §3.3a), and
      # still hashes only an input whose metadata moved. An edge that states
      # ``timestamp`` keeps it.
      inputCheckPolicy hybrid

      call:
        pos modifiers is string,
          position = 0
        pos archive is string,
          position = 1,
          role = output
        pos objects is seq[string],
          position = 2,
          role = input,
          repeated = true

        outputs archive

# ---------------------------------------------------------------------------
# ranlib — generate index to archive.
#   ranlib <archive>
# ---------------------------------------------------------------------------

package ranlib:
  provisioning:
    nixPackage "nixpkgs#binutils", executablePath = "bin/ranlib",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

  executable ranlibBin:
    cli:
      dependencyPolicy automaticMonitor

      call:
        pos archive is string,
          position = 0,
          role = output

        outputs archive

# ---------------------------------------------------------------------------
# strip — discard symbols.
#   strip -s -o <output> <input>        # strip all symbols (-s)
#   strip -S -o <output> <input>        # strip debug symbols only (-S)
#   strip -o <output> -K <symbol>... <input>   # keep the named symbols
#
# ``-o`` is required. Without it ``strip`` rewrites ``<input>`` in place, and
# ``<input>`` is the declared output of the edge that linked it: a second
# writer of that path that declares nothing, which
# Filesystem-Policy-And-Observed-Inputs.md §"Double Writes" and §"Source
# Rewrites" make an error by default. Strip to a separate output instead.
# ---------------------------------------------------------------------------

package strip:
  provisioning:
    nixPackage "nixpkgs#binutils", executablePath = "bin/strip",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

    # Views of the compiler bundles, as ``ar`` above: the same pin and lock
    # identity as ``gcc``, ``strip``'s own program, the Binutils version.
    tarball url = WinLibsX64Url,
      sha256 = WinLibsX64Sha256,
      archiveType = "7z",
      stripComponents = 1,
      executablePath = "bin/strip.exe",
      packageId = WinLibsX64PackageId,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = WinLibsX64LockIdentity,
      version = WinLibsBinutilsVersion

    tarball url = LinuxToolchainX64Url,
      sha256 = LinuxToolchainX64Sha256,
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = LinuxToolchainStrip,
      elfInterpreter = LinuxToolchainLoader,
      elfRunpath = LinuxToolchainRuntimeDir,
      elfPatchDir = LinuxToolchainPatchDirs[0],
      elfPatchDir = LinuxToolchainPatchDirs[1],
      elfPatchDir = LinuxToolchainPatchDirs[2],
      elfPatchDir = LinuxToolchainPatchDirs[3],
      packageId = LinuxToolchainX64PackageId,
      cpu = "x86_64",
      os = "linux",
      lockIdentity = LinuxToolchainX64LockIdentity,
      version = LinuxToolchainBinutilsVersion

  executable stripBin:
    cli:
      dependencyPolicy automaticMonitor

      call:
        boolFlag stripAll is bool, alias = "-s"
        boolFlag stripDebug is bool, alias = "-S"
        boolFlag stripUnneeded is bool, alias = "--strip-unneeded"
        flag output is string,
          alias = "-o",
          format = separate,
          role = output,
          required = true
        flag keepSymbols is seq[string],
          alias = "-K",
          format = separate,
          repeated = true
        pos input is string,
          position = 0,
          role = input

proc separateStripOutput*(input, output: string): string =
  ## ``output`` when it names a path other than ``input``; raises
  ## ``ValueError`` otherwise. ``gccStrip`` and ``clangStrip`` call it before
  ## they build the edge: an empty ``output`` (strip in place) or one naming
  ## the input both rewrite the producing edge's declared output from a
  ## second edge, which is refused by default
  ## (Filesystem-Policy-And-Observed-Inputs.md §"Double Writes", §"Source
  ## Rewrites"). Paths are compared after lexical normalization, so
  ## ``./app`` and ``dir/../app`` are the input ``app``.
  if output.len == 0 or (input.len > 0 and
      normalizedPath(output) == normalizedPath(input)):
    raise newException(ValueError,
      "strip of '" & input & "' must name a separate output: " &
      (if output.len == 0: "an empty target strips in place"
       else: "target '" & output & "' is the input") &
      ", which rewrites the output of the edge that produced it without " &
      "declaring that write: two edges would write one path. Set " &
      "StripOptions.target to a different path.")
  output

# ---------------------------------------------------------------------------
# nm — list symbol table.
#   nm [-D] [-g] <object>
# ---------------------------------------------------------------------------

package nm:
  provisioning:
    nixPackage "nixpkgs#binutils", executablePath = "bin/nm",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

  executable nmBin:
    cli:
      dependencyPolicy automaticMonitor

      call:
        boolFlag dynamic is bool, alias = "-D"
        boolFlag externalOnly is bool, alias = "-g"
        boolFlag demangle is bool, alias = "-C"
        pos input is string,
          position = 0,
          role = input

# ---------------------------------------------------------------------------
# objdump — display information from object files.
#   objdump -d <object>                 # disassemble
#   objdump -h <object>                 # section headers
# ---------------------------------------------------------------------------

package objdump:
  provisioning:
    nixPackage "nixpkgs#binutils", executablePath = "bin/objdump",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

  executable objdumpBin:
    cli:
      dependencyPolicy automaticMonitor

      call:
        boolFlag disassemble is bool, alias = "-d"
        boolFlag sectionHeaders is bool, alias = "-h"
        boolFlag fullContents is bool, alias = "-s"
        flag section is string,
          alias = "-j",
          format = separate
        pos input is string,
          position = 0,
          role = input

# ---------------------------------------------------------------------------
# objcopy — copy and translate object files.
#   objcopy -O <format> <input> <output>
# ---------------------------------------------------------------------------

package objcopy:
  provisioning:
    nixPackage "nixpkgs#binutils", executablePath = "bin/objcopy",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

  executable objcopyBin:
    cli:
      dependencyPolicy automaticMonitor

      call:
        flag outputFormat is string,
          alias = "-O",
          format = separate
        flag inputFormat is string,
          alias = "-I",
          format = separate
        flag onlySection is string,
          alias = "-j",
          format = separate
        boolFlag stripAll is bool, alias = "-S"
        boolFlag stripDebug is bool, alias = "--strip-debug"
        pos input is string,
          position = 0,
          role = input
        pos output is string,
          position = 1,
          role = output

        outputs output

# ---------------------------------------------------------------------------
# gas — GNU assembler. (Package value renamed from ``as`` to ``gas``
# because ``as`` is a Nim reserved word; the underlying binary remains
# ``as``.)
#   as -o <output> <input>
# ---------------------------------------------------------------------------

package gas:
  provisioning:
    nixPackage "nixpkgs#binutils", executablePath = "bin/as",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

  executable gasBin:
    cli:
      dependencyPolicy automaticMonitor

      call:
        flag output is string,
          alias = "-o",
          format = separate,
          role = output,
          required = true
        flag includePaths is seq[string],
          alias = "-I",
          format = separate,
          repeated = true
        pos input is string,
          position = 0,
          role = input

        outputs output

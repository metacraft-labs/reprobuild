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
## All seven packages share the same Nix provisioning shape
## (``nixpkgs#binutils``). Windows / non-Nix Linux operators reuse the
## binutils that ships inside the gcc.nim mingw distribution — no
## separate Scoop manifest is harvested here.

import repro_project_dsl

# ---------------------------------------------------------------------------
# ld — GNU linker.
#   ld -o <output> [-L<libdir>...] [-l<lib>...] [-shared] [-static]
#      [-soname=<name>] <object>...
# ---------------------------------------------------------------------------

package ld:
  provisioning:
    nixPackage "nixpkgs#binutils", executablePath = "bin/ld",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

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
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

  executable arBin:
    cli:
      dependencyPolicy automaticMonitor

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
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

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
# ---------------------------------------------------------------------------

package strip:
  provisioning:
    nixPackage "nixpkgs#binutils", executablePath = "bin/strip",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

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
          role = output
        pos input is string,
          position = 0,
          role = input

# ---------------------------------------------------------------------------
# nm — list symbol table.
#   nm [-D] [-g] <object>
# ---------------------------------------------------------------------------

package nm:
  provisioning:
    nixPackage "nixpkgs#binutils", executablePath = "bin/nm",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

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
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

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
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

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
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

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

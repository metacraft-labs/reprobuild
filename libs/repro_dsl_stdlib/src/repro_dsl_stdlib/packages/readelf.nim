## ``readelf`` — the ELF metadata reader, as a reprobuild package.
##
## Distribution-And-Packaging.md §6 rules 1 + 2, same shape as
## ``packages/patchelf.nim`` and ``packages/dpkg_deb.nim``: the tool is
## a real package, and the edge that needs it takes a real build-graph
## dependency on it.
##
## ## Why this exists when ``patchelf`` is already on the closure edge
##
## The runtime-closure walk reads ELF metadata with
## ``patchelf --print-needed`` / ``--print-rpath`` and needs nothing
## else, which is why M0 shipped no readelf. The **dependency floor**
## does need something else, and it is not a gap patchelf could be
## asked to close: patchelf edits ``DT_*`` dynamic-section entries, and
## the floor is read from ``.gnu.version_r``, the *version requirements*
## section — a different section, holding data patchelf has no reader
## for and no reason to have one. So it is a new tool rather than a new
## flag.
##
## What the floor is, and why it cannot be computed at graph time:
## rewriting ``PT_INTERP`` to the target's canonical loader path binds
## the produced package to the TARGET's C library, so the package owes
## its package manager a ``Depends: libc6 (>= X)`` / ``Requires: glibc
## >= X``. ``X`` is the maximum ``GLIBC_x.y`` version reference across
## the payload AND the vendored closure — files no edge has produced at
## the moment the graph is built, exactly as with ``DT_NEEDED``. So the
## floor is computed inside the closure action, from this tool's
## output. See ``packaging/runtime_contract.glibcFloorFunctions``.
##
## ## Why ``nixpkgs#binutils`` rather than ``nixpkgs#elfutils``
##
## Both ship a ``readelf``. GNU binutils' is the one whose ``-V`` output
## format the shell parser in ``runtime_contract`` is written against,
## and binutils is already in this repository's package set
## (``packages/binutils.nim`` provisions eight executables from the same
## derivation), so the closure edge gains a tool it can get from a
## derivation the build already realises rather than a second one.
##
## **No Windows channel, deliberately.** ``.gnu.version_r`` is an ELF
## concept; a Windows target stages no closure edge at all
## (``stageInstallTree`` gates it on ``targetOs == toLinux``), so there
## is nothing for a Windows readelf to do. Per §6.1 an unavailable
## format is just an unresolvable tool dependency surfaced through the
## normal mechanism.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
# DSL-port M9.R.2c — typed slot var for ``executable readelfBin:``.
import repro_dsl_stdlib/types/executable

package readelf:
  provisioning:
    nixPackage "nixpkgs#binutils", executablePath = "bin/readelf",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

  executable readelfBin:
    cli:
      dependencyPolicy automaticMonitor

      call:
        # ``-V`` / ``--version-info`` dumps ``.gnu.version``,
        # ``.gnu.version_d`` and ``.gnu.version_r``. The floor reads the
        # third: each ``Name: GLIBC_x.y`` line under a ``File:
        # libc.so.6`` entry is a symbol version the object was linked
        # against and the target's glibc must therefore provide.
        boolFlag versionInfo is bool, alias = "-V"
        boolFlag dynamic is bool, alias = "-d"
        boolFlag wide is bool, alias = "-W"
        pos input is string,
          position = 0,
          role = input,
          required = true

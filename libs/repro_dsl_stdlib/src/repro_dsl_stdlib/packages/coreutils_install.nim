## ``install`` — copy a file into place WITH its mode, as a reprobuild
## package.
##
## The packaging layer stages an install tree out of build edges. Two
## facts make plain ``fs.copyFile`` insufficient for the POSIX targets:
##
## * ``fs.writeText`` — how the §5 wrapper scripts, the deb maintainer
##   scripts and the systemd units get into the tree — necessarily
##   creates its output with the process umask default. A ``.deb`` whose
##   ``postinst`` is not 0755 is rejected by dpkg at install time, and a
##   wrapper that is not executable is not a wrapper.
## * The mode a file needs in the INSTALL tree is a property of the
##   distribution, not of whatever the build tree happens to hold. A
##   config file staged from a checked-out source file must land 0644
##   even if the checkout gave it 0755.
##
## ``install -m <mode> -D <src> <dst>`` does copy + mode + parent-dir
## creation in one edge whose output is a DIFFERENT path from its input.
## That last property is why this tool is here rather than a ``chmod``:
## a ``chmod`` edge would mutate a path some other edge already declared
## as its output, and the packaging layer holds itself to every staging
## edge having an output nothing else claims (see the ``--output`` note
## in ``packages/patchelf.nim``).
##
## Per Distribution-And-Packaging.md §6 rule 1 the tool is a reprobuild
## package, not a host assumption.
##
## **Windows carries no channel on purpose.** POSIX mode bits do not
## exist there, and the MSI producer neither needs nor can express them
## — this is the concrete place where the "structurally different second
## format" of the M0 gate shows up inside the layer, and the right
## answer is that mode application is part of the POSIX staging path
## only, not that the layer invents a Windows equivalent. The Windows
## staging path uses the engine's own ``fs.copyFile`` builtin and has no
## tool dependency here at all.

import std/strutils
import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
# DSL-port M9.R.2c — typed slot var for ``executable installBin:``.
import repro_dsl_stdlib/types/executable

type
  InstallBinCall* = object
    ## The call record the ``implicitTargetName`` hook below receives.
    ## Hand-declared with a same-named field for every CLI parameter —
    ## see the note on ``PatchelfBinCall`` in ``packages/patchelf.nim``.
    mode*: string
    createParents*: bool
    preserveTimestamps*: bool
    source*: string
    target*: string

package `install-file`:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/install",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

  executable installBin:
    cli:
      dependencyPolicy automaticMonitor

      call:
        flag mode is string,
          alias = "-m",
          format = separate
        # ``-D`` creates the destination's parent directories. Without
        # it every staged file would need its own preceding
        # ``ensureDir`` edge, which is three times the edges for no
        # additional guarantee.
        boolFlag createParents is bool, alias = "-D"
        # ``install`` sets the destination's mtime to now, which would
        # make the staged tree — and therefore the archive built from it
        # — differ between two otherwise identical builds. ``-p``
        # preserves the source's timestamps instead, so the tree is a
        # pure function of its inputs.
        boolFlag preserveTimestamps is bool, alias = "-p"
        pos source is string,
          position = 0,
          role = input,
          required = true
        pos target is string,
          position = 1,
          role = output,
          required = true

        outputs target

    # Named-Targets: the implicit target name for an edge defaults to
    # its output's BASENAME with conventional extensions stripped, and
    # the DSL rejects two edges in one package that claim the same name.
    #
    # That default cannot work for a staging tool. Two producers over
    # one ``Distribution`` stage two trees whose files legitimately have
    # the SAME names — ``deb/usr/bin/hello.real`` and
    # ``tar/bin/hello.real`` are the same file staged twice — so the
    # basename rule makes an ordinary two-format build fail outright
    # with a duplicate-target error. The whole PATH is what identifies a
    # staged file, so that is what the name is derived from.
    implicitTargetName(call: InstallBinCall): string =
      call.target.replace("/", "-")

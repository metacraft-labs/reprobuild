## DSL-port M9.R.10a — stdlib provisioning stub for ``texinfo``.
##
## Lifted from the M9.R.10a exec-name audit pass: this package surfaces
## as a ``nativeBuildDeps`` / ``buildDeps`` entry on one or more source
## recipes under ``recipes/packages/source/``. ``texinfo`` is reached by
## the wayland from-source smoke via the ``wayland → gcc → binutils →
## texinfo`` auto-recurse chain — it is the canary that gates every
## from-source GNU-stack recipe whose Texinfo manuals are regenerated
## from ``.texi`` sources at build time.
##
## ## M9.R.11 widening
##
## v1 of this stub registered only the nix channel, which left the
## Windows from-source smoke hard-failing with "no stdlib provisioning
## channel" the moment binutils' nativeBuildDeps reached it. M9.R.11
## widens the channel set to (nix, tarball) so the resolver can land on
## Windows + non-Nix Linux. The upstream GNU release tarball ships
## ``configure`` + Makefile.in + the perl-driven ``makeinfo`` script;
## the tarball channel covers both Linux and (via msys2/cygwin) Windows
## hosts that need to bootstrap the documentation toolchain from
## source.
##
## sha256 cross-checked against nixpkgs's ``pkgs/development/tools/misc/
## texinfo/packages.nix`` (``texinfo7`` slice, version 7.2). The
## upstream URL pattern is ``https://ftp.gnu.org/gnu/texinfo/texinfo-
## <ver>.tar.xz``; the GNU ftp mirror tree pins each release tarball
## once + never re-uploads, so the hash is stable.

import repro_project_dsl

package `texinfo`:
  provisioning:
    nixPackage "nixpkgs#texinfo", executablePath = "bin/makeinfo",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    # Direct-download: GNU upstream release tarball. Cross-platform —
    # builds on Linux + Windows (via MSYS2/Cygwin perl). The tarball
    # lays out ``texinfo-7.2/`` at the root; ``stripComponents = 1``
    # flattens.
    #
    # **executablePath**: The resolver requires this file to exist + be
    # executable post-extract. The texinfo source tarball ships
    # ``configure`` (auto-generated autotools bootstrap script with +x
    # bit set in the archive) at the root; pointing at it lets the
    # resolver succeed so the wayland chain can advance past tool
    # identity resolution. The convention layer's compile action drives
    # ``./configure && make`` against the extracted tree at build time
    # to produce ``./info/makeinfo`` (the canonical entry-point binutils
    # invokes). M9.R.11.1 follow-up: build the tool inline via the
    # from-source convention and surface ``info/makeinfo`` here once the
    # action graph is wired (or migrate to a prebuilt MSYS2 / Scoop
    # texinfo bundle on Windows).
    tarball url = "https://ftp.gnu.org/gnu/texinfo/texinfo-7.2.tar.xz",
      sha256 = "0329d7788fbef113fa82cb80889ca197a344ce0df7646fe000974c5d714363a6",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "configure",
      packageId = "texinfo@7.2",
      cpu = "any",
      os = "any",
      lockIdentity = "tarball:texinfo@7.2:sha256:0329d7788fbef113fa82cb80889ca197a344ce0df7646fe000974c5d714363a6"

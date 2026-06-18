## Source-from-tarball gcc recipe — M9.N Batch E compiler-chain slice.
##
## gcc is the GNU Compiler Collection: the canonical host C / C++
## toolchain every from-source recipe under
## ``recipes/packages/source/`` that declares ``uses: "gcc"`` consumes
## at compile + link time. The Batch E (gcc + binutils + make) slice
## sits BELOW Batch D (cmake + autoconf + automake + libtool +
## pkgconf) in the bootstrap layering: every Batch D autotools recipe
## ultimately drives gcc + binutils + make under the hood. R5 musl-tcc
## is the long-term clean root for the bootstrap chain; Batch E ships
## the recipes against the existing upstream tarballs as declarative
## shape so the M9.K convention layer can lower them when the recipe
## graph asks for the host C compiler.
##
## ## Convention chosen — ``from-source-custom``
##
## gcc's upstream build does NOT fit any of the four standard
## ``from-source-*`` conventions (meson / cmake / autotools / make):
##
##   * ``from-source-meson`` requires ``mesonOptions:`` to be populated
##     — gcc has no meson build path.
##   * ``from-source-cmake`` requires ``cmakeFlags:`` populated — gcc
##     is autotools-rooted, not cmake-rooted.
##   * ``from-source-autotools`` requires ``configureFlags:`` populated
##     AND that the ``./configure`` script live at the source root.
##     gcc's canonical build uses an OUT-OF-TREE build directory: the
##     upstream documentation REQUIRES ``mkdir build && cd build &&
##     ../configure ...`` because gcc's in-tree configure would
##     contaminate the source tree with build artefacts that break
##     subsequent re-configures.
##   * ``from-source-make`` requires ``makeFlags:`` populated. gcc
##     drives ``make`` AFTER ``../configure`` lays out the generated
##     ``Makefile``s, but the canonical entry point is the configure
##     driver.
##
## The M9.N Batch C.1 ``from-source-custom`` convention claims this
## recipe via the ``shell()`` action surface on ``build:`` blocks: the
## recipe records the four-shell-action mkdir-configure-build-install
## pipeline as a verbatim shell sequence under the ``gcc`` artifact.
## This mirrors the cmake precedent (the only other ``from-source-
## custom`` consumer in the corpus that drives a multi-shell build).
##
## ## sha256 strategy
##
## The fetch URL points at the upstream ftp.gnu.org release tarball
## ``gcc-14.2.0.tar.xz``. The sha256 was computed locally by
## downloading the tarball from the canonical ftp.gnu.org release
## endpoint and running ``sha256sum`` over the bytes. nixpkgs's
## ``pkgs/development/compilers/gcc/14/default.nix`` pins gcc 14.x via
## fetchurl + an SRI-hashed mirror URL; the cross-check with the
## upstream sha256 holds when both fetch the same source file.
##
## ## Why gcc is NOT vendored
##
## The ``gcc-14.2.0.tar.xz`` tarball weighs ~88 MB which is on the
## edge of GitHub's 100-MB single-file ceiling. Per the kernel-recipe
## precedent (``recipes/packages/source/kernel/``), large vendor
## tarballs are NOT checked into the repo — the live ``fetch:`` block
## points at the upstream URL directly and a future vendoring pass
## (R5 musl-tcc) will host the bootstrap-critical archives on a
## reprobuild-managed mirror.
##
## ## Version choice — 14.2.0 (per task brief)
##
## gcc releases are cut on ftp.gnu.org under tags of the form
## ``gcc-<X>.<Y>.<Z>``. 14.2.0 is the latest stable in the 14.x line
## as of the task brief. The 14.x cut introduced the C23 feature set
## the modern desktop story relies on (``[[deprecated]]`` /
## ``constexpr`` / ``typeof`` extensions) and is the stable line the
## Linux 6.6 LTS kernel + the systemd / KDE / Plasma desktop
## components all build against.
##
## ## Build deferral — declarative shape only
##
## gcc is the LARGEST package in the from-source corpus: the upstream
## tarball weighs ~88 MB, the extracted tree is ~3.5 GB, the build
## consumes ~15 GB of disk + 8-16 GB of RAM, and the
## ``--disable-bootstrap`` single-stage build takes 2-4 HOURS on a
## modern desktop CPU. Per the task brief, v1 of this recipe
## DECLARES the build pipeline as shell actions but defers the actual
## compilation — the recipe records the four-shell mkdir-configure-
## build-install sequence so the M9.K convention layer's stage-copy
## step knows what binaries to harvest, but the heavy lifting fires
## only when a downstream consumer recipe explicitly asks for a
## ``$out/bin/gcc`` artifact edge.
##
## ## Artifacts
##
## gcc exposes three load-bearing CLI binaries + two shared libraries
## on disk (out of the dozens of binaries the upstream install body
## lays out under ``$PREFIX/bin/`` / ``$PREFIX/lib/`` —
## ``cc1`` / ``cc1plus`` / ``collect2`` / ``lto1`` / ... live under
## ``$PREFIX/libexec/`` and are NOT user-facing entry points):
##
##   * ``gcc``       — ``$PREFIX/bin/gcc``, the canonical C compiler
##                      driver every C recipe in
##                      ``recipes/packages/source/`` invokes.
##   * ``g++``       — ``$PREFIX/bin/g++``, the canonical C++ compiler
##                      driver every C++ recipe (kded, kio,
##                      kwidgetsaddons, plasma-framework, qt6-base,
##                      cmake-built consumers) invokes.
##   * ``cpp``       — ``$PREFIX/bin/cpp``, the C preprocessor driver
##                      consumed by autoconf's ``./configure`` probes
##                      and by hand-rolled Makefiles that shell out
##                      to ``cpp -E`` for header expansion.
##   * ``libgcc_s``  — ``$PREFIX/lib/libgcc_s.so``, the GCC runtime
##                      shared library every gcc-produced binary
##                      links against for stack-unwinding + soft-float
##                      helpers + ``__builtin_*`` intrinsics.
##   * ``libstdc++`` — ``$PREFIX/lib/libstdc++.so``, the GNU C++
##                      standard library every g++-produced binary
##                      links against. Re-exposes the ``std::``
##                      namespace + the ABI symbols the C++ ecosystem
##                      pins (libstdc++.so.6 SONAME, GCC_*
##                      versioned-symbol stamps).
##
## ## Configurables
##
## v1 ships NO configurables. The configure-pipeline is hardcoded to
## the canonical single-stage build:
##
##   * ``--prefix=$out``           — installs under the per-package
##                                    output dir.
##   * ``--enable-languages=c,c++`` — restrict to C + C++ frontends
##                                    (the desktop story does not
##                                    need Fortran / Ada / Go / D /
##                                    Objective-C).
##   * ``--disable-multilib``       — skip the 32-bit-on-64-bit
##                                    multilib pass (the desktop
##                                    story is x86_64-only).
##   * ``--disable-bootstrap``      — single-stage build; skips the
##                                    triple-recompile self-bootstrap
##                                    pass. Cuts the build time from
##                                    8-12 hours to 2-4 hours; the
##                                    self-bootstrap pass is a
##                                    correctness defence the host
##                                    compiler is already trusted to
##                                    provide.
##   * ``--disable-nls``            — skip the gettext native-language
##                                    support pass. NLS adds a build-
##                                    time dep on libintl and is
##                                    unused on a reproducible-build
##                                    host (no per-locale message
##                                    catalogs to consume).
##   * ``--without-headers``        — skip the libc-headers integration
##                                    pass; the host glibc / musl
##                                    headers already live under
##                                    ``/usr/include`` and gcc's
##                                    ``--with-sysroot`` chain picks
##                                    them up at configure time.

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package gccSource:
  ## From-source gcc — M9.N Batch E compiler-chain slice.
  ##
  ## ``from-source-custom`` convention consumer: the recipe's
  ## ``build:`` block records the four-shell-action mkdir-configure-
  ## build-install pipeline as a verbatim shell sequence under the
  ## ``gcc`` artifact. ``$extracted`` resolves to ``<projectRoot>/src/
  ## ``; ``$out`` resolves to ``<projectRoot>/.repro/build/from-source-
  ## custom/gccSource/``. The three executable + two library artifacts
  ## share the same install-tree (all five binaries land under
  ## ``$out/bin/`` + ``$out/lib/``); the convention's stage-copy step
  ## probes ``$out/bin/<member>`` per executable artifact and
  ## ``$out/lib/<member>.so`` per library artifact.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## ftp.gnu.org release tarball URL; ``sourceRepository`` points
    ## at the canonical gcc.gnu.org git tree.
    "14.2.0":
      sourceRevision = "releases/gcc-14.2.0"
      sourceUrl = "https://ftp.gnu.org/gnu/gcc/gcc-14.2.0/gcc-14.2.0.tar.xz"
      sourceRepository = "https://gcc.gnu.org/git/gcc.git"

  fetch:
    ## Live upstream URL. NOT vendored — the tarball weighs ~88 MB
    ## (on the edge of GitHub's 100-MB single-file ceiling) so the
    ## kernel-recipe precedent applies: live URL, no vendor/ copy.
    ## A future R5 musl-tcc pass will host the bootstrap-critical
    ## archives on a reprobuild-managed mirror.
    ##
    ## sha256 computed locally over the upstream ftp.gnu.org tarball;
    ## nixpkgs ships gcc 14.x via fetchurl + an SRI-hashed mirror URL
    ## so the cross-check holds when both fetch the same source
    ## bytes.
    url: "https://ftp.gnu.org/gnu/gcc/gcc-14.2.0/gcc-14.2.0.tar.xz"
    sha256: "a7b39bc69cbf9e25826c5a60ab26477001f7c08d85cec04bc0e29cabed6f3cc9"
    extractStrip: 1

  uses:
    ## binutils provides ``ld`` / ``as`` / ``ar`` that gcc shells out
    ## to at link + assemble time. gcc's configure probes for the
    ## binutils versions at ``./configure`` time so the version pin
    ## here is load-bearing.
    "binutils >=2.39"
    ## make is the build-system driver — the from-source-custom
    ## pipeline shells out to ``make`` after the out-of-tree
    ## ``../configure`` step lays out the generated ``Makefile``s.
    "make >=4.3"
    ## gmp / mpfr / mpc are the arbitrary-precision-arithmetic
    ## libraries gcc's middle-end consumes for constant folding +
    ## floating-point analysis. The upstream tarball ships a
    ## ``contrib/download_prerequisites`` script that fetches them
    ## into the source tree; a real production build either runs
    ## that script as a pre-configure step or links against system
    ## copies. v1 declares the system-copy expectation.
    "gmp >=6.2"
    "mpfr >=4.1"
    "mpc >=1.2"
    ## perl is invoked by gcc's ``configure`` script for a handful
    ## of code-generation passes (e.g. ``gcc/genopinit.pl``).
    "perl >=5.32"
    ## bison + flex are consumed by gcc's parser-generation passes
    ## under ``gcc/`` (the C / C++ parsers are hand-written but the
    ## modula-2 + d frontends use bison-generated parsers; the
    ## configure script probes for both unconditionally).
    "bison >=3.6"
    "flex >=2.6"

  executable gcc:
    ## ``$PREFIX/bin/gcc`` — the canonical C compiler driver every
    ## C recipe in ``recipes/packages/source/`` that declares
    ## ``uses: "gcc"`` invokes at compile + link time.
    ##
    ## M9.N Batch E — mkdir-configure-build-install body via the
    ## ``shell()`` action surface on ``build:`` blocks. The
    ## ``from-source-custom`` convention claims this recipe (no flag
    ## channels declared, four shell actions registered) and emits
    ## one ``BuildActionDef`` per shell line. ``$extracted`` is the
    ## extracted source root the convention's fetch action produces;
    ## ``$out`` is the per-package output root the stage-copy actions
    ## probe for ``bin/gcc`` + ``bin/g++`` + ``bin/cpp`` +
    ## ``lib/libgcc_s.so`` + ``lib/libstdc++.so``.
    ##
    ## NOTE: the v1 build is DEFERRED — the recipe declares the
    ## pipeline so the convention layer's stage-copy step knows what
    ## binaries to harvest, but the heavy compilation (2-4 hours,
    ## ~15 GB disk, 8-16 GB RAM) fires only when a downstream
    ## consumer recipe explicitly asks for a ``$out/bin/gcc``
    ## artifact edge.
    build:
      # Out-of-tree build directory — gcc's upstream documentation
      # REQUIRES this because the in-tree configure would
      # contaminate the source tree with build artefacts. The
      # mkdir-cd-configure idiom is the canonical pattern.
      shell "mkdir -p $extracted/build"
      # Configure step — out-of-tree configure with the desktop-
      # baseline flag set per the task brief. ``--prefix=$out``
      # routes the install body under the per-package output dir;
      # ``--enable-languages=c,c++`` restricts to the two frontends
      # the desktop story consumes; ``--disable-multilib`` skips the
      # 32-bit-on-64-bit pass; ``--disable-bootstrap`` cuts the
      # triple-recompile self-bootstrap (8-12 -> 2-4 hours);
      # ``--disable-nls`` skips the gettext NLS pass;
      # ``--without-headers`` skips the libc-headers integration
      # (the host glibc / musl headers under ``/usr/include`` are
      # already on the include path).
      shell "cd $extracted/build && ../configure --prefix=$out --enable-languages=c,c++ --disable-multilib --disable-bootstrap --disable-nls --without-headers"
      # Build step — drives the generated ``Makefile``s. No ``-jN``
      # flag because the cache-key would be coupled to the host's
      # CPU count; M9.L's convention layer can compute a host-job-
      # count flag at action-emission time and override.
      shell "cd $extracted/build && make"
      # Install step — copies the binaries + libraries + libexec
      # tree under ``$out/bin/`` + ``$out/lib/`` + ``$out/libexec/``.
      shell "cd $extracted/build && make install"

  executable "g++":
    ## ``$PREFIX/bin/g++`` — the canonical C++ compiler driver.
    ## String-form artifact declaration because ``+`` is not a
    ## valid Nim identifier character; the M3 artifact registry
    ## stores the literal ``"g++"`` string. No per-artifact build
    ## body: the ``gcc`` build: block above already installs
    ## ``g++`` under ``$out/bin/`` via the ``make install`` step.
    discard

  executable cpp:
    ## ``$PREFIX/bin/cpp`` — the C preprocessor driver consumed by
    ## autoconf's ``./configure`` probes and by hand-rolled
    ## Makefiles that shell out to ``cpp -E`` for header expansion.
    ## No per-artifact build body: shared install-tree with ``gcc``.
    discard

  library libgcc_s:
    ## ``$PREFIX/lib/libgcc_s.so`` — the GCC runtime shared library
    ## every gcc-produced binary links against for stack-unwinding +
    ## soft-float helpers + ``__builtin_*`` intrinsics. The
    ## ``_s`` suffix marks the shared variant (vs the static
    ## ``libgcc.a`` archive). No per-artifact build body: shared
    ## install-tree with ``gcc``.
    discard

  library "libstdc++":
    ## ``$PREFIX/lib/libstdc++.so`` — the GNU C++ standard library
    ## every g++-produced binary links against. String-form
    ## artifact declaration because ``+`` is not a valid Nim
    ## identifier character; the M3 artifact registry stores the
    ## literal ``"libstdc++"`` string. No per-artifact build body:
    ## shared install-tree with ``gcc``.
    discard

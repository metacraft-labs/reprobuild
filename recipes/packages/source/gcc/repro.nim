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
## ## Build execution
##
## gcc is the LARGEST package in the from-source corpus: the upstream
## tarball weighs ~88 MB, the extracted tree is ~3.5 GB, the build
## consumes substantial disk and memory, and the
## ``--disable-bootstrap`` single-stage build is intentionally fixed
## at eight parallel jobs. The recipe executes the complete
## configure-build-install pipeline and publishes the resulting host
## compiler and runtime libraries.
##
## ## Artifacts
##
## gcc exposes three load-bearing CLI binaries + four shared libraries
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
##   * ``libgomp``    — ``$PREFIX/lib/libgomp.so``, the OpenMP
##                      runtime used by binaries built with ``-fopenmp``.
##   * ``libatomic``  — ``$PREFIX/lib/libatomic.so``, the fallback
##                      runtime for non-lock-free atomic operations.
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
# DSL-port M9.R.2c — pulls ``Library`` / ``Executable`` into scope for
# the typed artifact slot vars the ``package`` macro injects. (This
# recipe doesn't import ``repro_dsl_stdlib/constructors`` so the
# implicit re-export through ``types/package_result`` doesn't apply.)
import repro_dsl_stdlib/types
# DSL-port M9.R.10a — bring perl + bison + flex + gmp + mpfr + mpc +
# binutils stdlib packages into scope so the from-source resolver
# finds their provisioning metadata on this recipe's nativeBuildDeps
# / buildDeps uses.
import repro_dsl_stdlib/packages/system_tools
import repro_dsl_stdlib/packages/clang

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

  nativeBuildDeps:
    ## Break the compiler self-cycle with the pinned Clang bootstrap
    ## toolchain. The resulting GCC binaries and runtime libraries are
    ## still compiled from this recipe's upstream GCC sources.
    "clang"
    ## binutils provides ``ld`` / ``as`` / ``ar`` that gcc shells out
    ## to at link + assemble time. gcc's configure probes for the
    ## binutils versions at ``./configure`` time so the version pin
    ## here is load-bearing.
    "binutils >=2.39"
    ## make is the build-system driver — the from-source-custom
    ## pipeline shells out to ``make`` after the out-of-tree
    ## ``../configure`` step lays out the generated ``Makefile``s.
    "make >=4.3"
    ## perl is invoked by gcc's ``configure`` script for a handful
    ## of code-generation passes (e.g. ``gcc/genopinit.pl``).
    "perl >=5.32"
    ## bison + flex are consumed by gcc's parser-generation passes
    ## under ``gcc/`` (the C / C++ parsers are hand-written but the
    ## modula-2 + d frontends use bison-generated parsers; the
    ## configure script probes for both unconditionally).
    "bison >=3.6"
    "flex >=2.6"

  buildDeps:
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
    ## The recipe executes the full single-stage compilation. The
    ## heavy build is cacheable as a normal custom-convention action
    ## and is reused when downstream recipes request compiler or
    ## runtime artifacts from this install tree.
    build:
      # Out-of-tree build directory — gcc's upstream documentation
      # REQUIRES this because the in-tree configure would
      # contaminate the source tree with build artefacts. The
      # bootstrap sysroot supplies the glibc headers and startup files
      # that NixOS intentionally does not expose under /usr. It is used
      # only while building target libraries and is not installed as
      # GCC's default runtime sysroot.
      shell "bootstrap_sysroot=$extracted/bootstrap-sysroot; glibc_include=$(clang -E -Wp,-v -xc /dev/null 2>&1 | grep glibc | tail -n1 | xargs); glibc_lib=$(dirname $(clang --print-file-name=libc.so.6)); test -d $glibc_include; test -f $glibc_lib/libc.so.6; mkdir -p $extracted/build $bootstrap_sysroot/usr; ln -sfn $glibc_include $bootstrap_sysroot/usr/include; ln -sfn $glibc_lib $bootstrap_sysroot/lib; ln -sfn $glibc_lib $bootstrap_sysroot/lib64; ln -sfn $glibc_lib $bootstrap_sysroot/usr/lib"
      # Configure step — out-of-tree configure with the desktop-
      # baseline flag set per the task brief. ``--prefix=$out``
      # routes the install body under the per-package output dir;
      # ``--enable-languages=c,c++`` restricts to the two frontends
      # the desktop story consumes; ``--disable-multilib`` skips the
      # 32-bit-on-64-bit pass; ``--disable-bootstrap`` cuts the
      # triple-recompile self-bootstrap (8-12 -> 2-4 hours);
      # ``--disable-nls`` skips the gettext NLS pass;
      # optional sanitizer, transactional-memory, vtable-verification,
      # legacy SSP, and Fortran quadmath runtimes are outside the
      # package's declared C/C++ compiler and OpenMP artifact surface;
      # ``--with-build-sysroot`` makes the first source-built xgcc find
      # libc headers and startup objects while compiling libgcc/libstdc++.
      # GCC's target linker must bypass the Nix binutils wrapper. That
      # wrapper injects its host glibc RUNPATH into xgcc outputs, which
      # is incompatible with the newer glibc paired with Clang.
      shell "gmp_prefix=$(pwd)/../../gmp/.repro/output/install/usr; mpfr_prefix=$(pwd)/../../mpfr/.repro/output/install/usr; mpc_prefix=$(pwd)/../../mpc/.repro/output/install/usr; glibc_lib=$(dirname $(clang --print-file-name=libc.so.6)); binutils_wrapper=$(dirname $(dirname $(readlink -f $(command -v ld)))); raw_binutils=$(cat $binutils_wrapper/nix-support/orig-bintools); test -x $raw_binutils/bin/ld; cd $extracted/build && CC=clang CXX=clang++ LD=$raw_binutils/bin/ld LDFLAGS_FOR_TARGET=-Wl,--dynamic-linker=$glibc_lib/ld-linux-x86-64.so.2 ../configure --prefix=$out --enable-languages=c,c++ --disable-multilib --disable-bootstrap --disable-nls --disable-werror --disable-libsanitizer --disable-libitm --disable-libvtv --disable-libssp --disable-libquadmath --with-build-sysroot=$extracted/bootstrap-sysroot --with-gmp=$gmp_prefix --with-mpfr=$mpfr_prefix --with-mpc=$mpc_prefix"
      # Build step — drives the generated ``Makefile``s with a fixed
      # job count. Keeping the value explicit makes the action and its
      # cache identity independent of host CPU discovery.
      shell "cd $extracted/build && make -j8"
      # Install step — copies the binaries + libraries + libexec
      # tree under ``$out/bin/`` + ``$out/lib/`` + ``$out/libexec/``.
      shell "cd $extracted/build && make install"
      # GCC uses lib64 for x86_64 target runtimes. Publish stable lib
      # aliases so declared library artifacts resolve consistently.
      shell "mkdir -p $out/lib; for runtime in libgcc_s.so libgcc_s.so.1 libstdc++.so libstdc++.so.6 libgomp.so libgomp.so.1 libatomic.so libatomic.so.1; do test -e $out/lib64/$runtime; ln -sfn ../lib64/$runtime $out/lib/$runtime; done"

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

  library libgomp:
    ## OpenMP runtime required by binaries built with ``-fopenmp``.
    discard

  library libatomic:
    ## Atomic fallback runtime for targets without lock-free operations.
    discard

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard

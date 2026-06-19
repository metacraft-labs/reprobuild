## Source-from-tarball cmake recipe — M9.N Batch D build-tool slice.
##
## cmake is a meta-build system: the upstream tarball ships a hand-
## rolled ``./bootstrap`` driver that compiles a minimal cmake binary
## from the bundled C++ sources, then runs the freshly-built binary
## against the full source tree to drive the canonical
## ``configure / build / install`` cycle. The on-disk artefacts are
## three CLI binaries (``cmake`` + ``ctest`` + ``cpack``).
##
## ## Convention chosen — ``from-source-custom``
##
## cmake's upstream build does NOT fit any of the four standard
## ``from-source-*`` conventions (meson / cmake / autotools / make):
##
##   * ``from-source-meson`` requires ``uses:`` to list ``meson`` AND
##     ``mesonOptions:`` to be populated.
##   * ``from-source-cmake`` requires ``cmakeFlags:`` populated — and
##     we'd be bootstrapping cmake via cmake, which is the chicken-and-
##     egg.
##   * ``from-source-autotools`` requires ``configureFlags:`` populated
##     AND the existence of an autotools-style ``./configure`` script —
##     cmake's ``./bootstrap`` is a bespoke shell driver, NOT an
##     autoconf-generated script.
##   * ``from-source-make`` requires ``makeFlags:`` populated. cmake's
##     bootstrap runs ``make`` AFTER ``./bootstrap`` lays out the
##     generated ``Makefile``s, but the canonical entry point is the
##     bootstrap driver.
##
## The M9.N Batch C.1 ``from-source-custom`` convention claims this
## recipe via the ``shell()`` action surface on ``build:`` blocks: the
## recipe records the three-shell-action bootstrap-build-install
## pipeline as a verbatim shell sequence.
##
## ## sha256 strategy
##
## The fetch URL points at the upstream cmake.org release tarball
## ``cmake-3.31.2.tar.gz``. The sha256 was computed locally by
## downloading the tarball from the canonical GitHub release endpoint
## and running ``sha256sum`` over the bytes. nixpkgs's by-name
## ``cm/cmake/package.nix`` pins cmake 4.1.2 with SRI
## ``sha256-ZD8EGCt7oyOrMfUm94UTT7ecujGIqFIgbvBHP+4oKhU=``, NOT the
## 3.31.2 release the task brief requests, so the nixpkgs cross-check
## is deferred to the follow-up pass that lifts cmake to nixpkgs's
## 4.x line.
##
## ## Version choice — 3.31.2 (per task brief)
##
## cmake releases are cut on github.com/Kitware/CMake under tags of
## the form ``v<X>.<Y>.<Z>``. 3.31.2 was the latest stable in the
## 3.31.x line as of the task brief. The 3.31 cut introduced the new
## ``cmake --workflow`` driver + the stabilised CXX module support;
## anything ``>=3.25`` covers every consumer's modern-cmake pinning.
##
## ## Artifacts
##
## cmake exposes three load-bearing CLI binaries on disk:
##
##   * ``cmake`` — ``$PREFIX/bin/cmake``, the meta-build driver every
##                  C / C++ recipe in ``recipes/packages/source/`` that
##                  declares ``uses: "cmake"`` invokes at configure +
##                  build + install time (kded, kio, kwidgetsaddons,
##                  plasma-framework, json-c, ...).
##   * ``ctest`` — ``$PREFIX/bin/ctest``, the test-runner sidecar the
##                  cmake-generated build trees invoke for
##                  ``cmake --build . --target test``.
##   * ``cpack`` — ``$PREFIX/bin/cpack``, the packaging sidecar that
##                  generates distribution archives (.tar.gz, .deb,
##                  .rpm, .nsis, .dmg) from a configured cmake project.
##
## ## Configurables
##
## v1 ships NO configurables. The bootstrap pipeline is hardcoded to
## ``./bootstrap --prefix=$out -- -DCMAKE_USE_OPENSSL=OFF``:
##
##   * ``--prefix=$out``               — installs under the per-package
##                                        output dir the from-source-
##                                        custom convention substitutes
##                                        at emit time.
##   * ``-DCMAKE_USE_OPENSSL=OFF``     — skip the OpenSSL link
##                                        (cmake's ``file(DOWNLOAD)``
##                                        HTTPS support uses libcurl
##                                        which can be linked against
##                                        either OpenSSL or BearSSL;
##                                        skipping the OpenSSL channel
##                                        cuts the build-time dependency
##                                        surface on the bootstrap host).

import repro_project_dsl
# DSL-port M9.R.2c — pulls ``Library`` / ``Executable`` into scope for
# the typed artifact slot vars the ``package`` macro injects. (This
# recipe doesn't import ``repro_dsl_stdlib/constructors`` so the
# implicit re-export through ``types/package_result`` doesn't apply.)
import repro_dsl_stdlib/types

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package cmakeSource:
  ## From-source cmake — M9.N Batch D build-tool slice.
  ##
  ## ``from-source-custom`` convention consumer: the recipe's
  ## ``build:`` block records the three-shell-action bootstrap-build-
  ## install pipeline as a verbatim shell sequence under the ``cmake``
  ## artifact. ``$extracted`` resolves to ``<projectRoot>/src/``;
  ## ``$out`` resolves to ``<projectRoot>/.repro/build/from-source-
  ## custom/cmakeSource/``. The ``ctest`` + ``cpack`` artifacts share
  ## the same install-tree (all three binaries land under
  ## ``$out/bin/``); the convention's stage-copy step probes
  ## ``$out/bin/<member>`` per declared artifact member.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## github.com release tarball URL; ``sourceRepository`` points at
    ## the canonical project tree.
    "3.31.2":
      sourceRevision = "v3.31.2"
      sourceUrl = "https://github.com/Kitware/CMake/releases/download/v3.31.2/cmake-3.31.2.tar.gz"
      sourceRepository = "https://github.com/Kitware/CMake"

  fetch:
    ## Live upstream URL. The vendor/ directory is reserved for a
    ## follow-up vendoring pass. v1 of this recipe ships the upstream
    ## URL directly because the cmake source archive is hosted on a
    ## stable GitHub release endpoint.
    ##
    ## sha256 computed locally from the upstream GitHub release
    ## tarball; nixpkgs cross-check deferred because nixpkgs ships
    ## cmake 4.1.2 (not the 3.31.2 the task brief requests).
    url: "https://github.com/Kitware/CMake/releases/download/v3.31.2/cmake-3.31.2.tar.gz"
    sha256: "42abb3f48f37dbd739cdfeb19d3712db0c5935ed5c2aef6c340f9ae9114238a2"
    extractStrip: 1

  nativeBuildDeps:
    ## gcc is the host C++ toolchain — cmake is C++17 with no external
    ## runtime dependencies beyond the system libstdc++.
    "gcc >=11"
    ## make is the build-system driver the ``./bootstrap`` step
    ## generates ``Makefile``s for; the bootstrap chain runs
    ## ``./bootstrap && make && make install``.
    "make"

  executable cmake:
    ## ``$PREFIX/bin/cmake`` — the meta-build driver consumed by every
    ## C / C++ recipe that declares ``uses: "cmake"`` (kded, kio,
    ## kwidgetsaddons, plasma-framework, json-c, ...).
    ##
    ## M9.N Batch D — bootstrap-build-install body via the new
    ## ``shell()`` action surface on ``build:`` blocks. The ``from-
    ## source-custom`` convention claims this recipe (no flag channels
    ## declared, three shell actions registered) and emits one
    ## ``BuildActionDef`` per shell line. ``$extracted`` is the
    ## extracted source root the convention's fetch action produces;
    ## ``$out`` is the per-package output root the stage-copy actions
    ## probe for ``bin/cmake`` + ``bin/ctest`` + ``bin/cpack``.
    build:
      # Bootstrap step — compiles the minimal cmake binary from the
      # bundled C++ sources and lays out the generated ``Makefile``s
      # at the source root. ``-DCMAKE_USE_OPENSSL=OFF`` skips the
      # OpenSSL channel to cut the bootstrap-host dependency surface.
      shell "./bootstrap --prefix=$out -- -DCMAKE_USE_OPENSSL=OFF"
      # Build step — drives the generated ``Makefile``s.
      shell "make"
      # Install step — copies the three CLI binaries + the cmake
      # module tree under ``$out/bin/`` + ``$out/share/cmake-3.31/``.
      shell "make install"

  executable ctest:
    ## ``$PREFIX/bin/ctest`` — the test-runner sidecar shared with the
    ## same install-tree as ``cmake``. No per-artifact build body: the
    ## cmake ``build:`` block above already installs ``ctest`` under
    ## ``$out/bin/`` via the ``make install`` step.
    discard

  executable cpack:
    ## ``$PREFIX/bin/cpack`` — the packaging sidecar shared with the
    ## same install-tree as ``cmake``. No per-artifact build body: the
    ## cmake ``build:`` block above already installs ``cpack`` under
    ## ``$out/bin/`` via the ``make install`` step.
    discard

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard

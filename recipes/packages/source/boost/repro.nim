## Source-from-tarball boost recipe — the FIRST custom-build C++ multi-module
## library to land in the from-source corpus.
##
## Boost (boostorg/boost) is the de-facto C++ standard-library extension
## the modern Linux desktop stack consumes for:
##
##   * ``Boost.System``      — error-category framework Plasma's
##                              libplasma-activities QML plugin runtime + a
##                              long tail of KDE Frameworks 6 modules link
##                              against.
##   * ``Boost.Filesystem``  — directory-walking + path-arithmetic surface
##                              consumed by libplasma-activities + several
##                              consumer apps in the Plasma 6 line.
##   * ``Boost.Thread``      — kept on by default because libplasma-activities
##                              + a handful of other Plasma 6 modules link
##                              ``boost::thread``.
##   * ``Boost.DateTime``    — date / time formatting consumed by KDE
##                              Frameworks 6 archive + JSON helpers.
##   * ``Boost.ProgramOptions`` — CLI-flag parser consumed by ``boost::asio``
##                                 helpers in upstream demos and a small
##                                 number of KDE Frameworks 6 internal tools.
##
## ## Why boost matters for the v1 desktop story
##
## ``find_package(Boost <ver> REQUIRED)`` is the single largest blocker on
## the plasma-activities CMakeLists; plasma-activities is the prereq for
## plasma-framework's ``find_package(PlasmaActivities REQUIRED)``, and
## plasma-framework is the prereq for kwin, plasma-workspace, and sddm.
## Closing the boost recipe unblocks the entire Plasma 6 desktop chain.
##
## ## Why the custom build shape (not ``cmake_package``)
##
## Boost ships TWO upstream build paths:
##
##   1. ``bootstrap.sh`` + ``./b2 install`` — the historical Boost build
##      driver; produces every shipping Boost library + headers without any
##      external dependency on CMake or autotools.
##   2. ``cmake`` super-build — Boost's modern but still-experimental CMake
##      entrypoint; requires every individual Boost component to opt in via
##      its own ``CMakeLists.txt``, with several modules still missing or
##      broken on 1.86.0.
##
## Path 1 is the canonical, upstream-endorsed shape on Linux and the only
## build path the nixpkgs / Debian / Fedora packages drive. Path 2 is
## experimental and explicitly NOT recommended for v1.86.0 in the upstream
## release notes. We take Path 1 — same shape as the gcc recipe (M9.N Batch
## E): a per-artifact ``build:`` block with verbatim ``shell()`` actions
## wired through the ``from-source-custom`` convention.
##
## ## sha256 strategy
##
## Live upstream URL — boost_1_86_0.tar.bz2 weighs ~126 MB which is well
## past the github.com 100-MB single-file ceiling, so the kernel- /
## gcc-recipe precedent applies: live URL, no vendor/ copy. A future R5
## musl-tcc pass will host the bootstrap-critical archives on a reprobuild-
## managed mirror.
##
## sha256 was computed locally over the upstream archives.boost.io tarball
## (126,220,652 bytes); the hash matches the upstream-published hash
## (``boost_1_86_0.tar.bz2.json``).
##
## ## Version choice — 1.86.0 (current stable in the 1.86.x line)
##
## Boost cuts a release every ~4 months under ``boost_<X>_<Y>_<Z>``
## tag-flavoured tarball names. 1.86.0 (released 2024-08-14) is a current
## stable release; plasma-activities's ``find_package(Boost 1.49 REQUIRED)``
## floor is satisfied by anything ``>= 1.49``.
##
## ## Build shape — bootstrap-b2-stage-copy
##
## Three shell actions drive the build (mirrored on the libBoostSystem
## anchor artifact per the gcc multi-artifact precedent — sibling library
## artifacts share the same install-tree and ship empty build bodies):
##
##   1. ``./bootstrap.sh --prefix=$out --with-libraries=...`` — runs the
##      Boost.Build (``b2``) bootstrap; produces a ``./b2`` driver at the
##      source root and a ``project-config.jam`` honouring the per-library
##      filter list.
##   2. ``./b2 install --prefix=$out link=shared threading=multi`` —
##      drives the compile + install pass; emits all shipping shared
##      libraries + headers under ``$out/lib`` + ``$out/include``.
##   3. ``mkdir -p $out/install/usr && cp -a $out/lib $out/include
##      $out/install/usr/`` — moves the install tree under the canonical
##      ``install/usr`` prefix the stage-copy step expects.
##
## ## Configurables
##
## v1 ships NO configurables. The library filter is hardcoded to
## ``system,filesystem,thread,date_time,program_options`` — the exact set
## plasma-activities + the wider Plasma 6 surface consume. A future
## downstream variant can widen the filter to ``all`` for a fuller Boost
## install (at the cost of build time + disk usage).

import repro_project_dsl
# DSL-port M9.R.2c — pulls ``Library`` / ``Executable`` into scope for
# the typed artifact slot vars the ``package`` macro injects.
import repro_dsl_stdlib/types
# DSL-port M9.R.10a — bring perl + python3 + make stdlib packages into
# scope so the from-source resolver finds their provisioning metadata on
# this recipe's nativeBuildDeps / buildDeps uses.
import repro_dsl_stdlib/packages/system_tools

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package boostSource:
  ## From-source boost — the FIRST C++ multi-module library to land in the
  ## from-source corpus and the prereq for plasma-activities ->
  ## plasma-framework -> kwin / plasma-workspace / sddm.
  ##
  ## ``from-source-custom`` convention consumer: the anchor artifact's
  ## ``build:`` block records the bootstrap.sh + b2 + stage-copy shell
  ## sequence as verbatim shell actions. ``$extracted`` resolves to
  ## ``<projectRoot>/src/``; ``$out`` resolves to ``<projectRoot>/.repro/
  ## build/from-source-custom/boostSource/``. The shared install-tree
  ## under ``$out/install/usr/`` carries all per-library .so files + the
  ## headers tree.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## archives.boost.io release-tarball URL so a future maintainer
    ## running ``repro update-source`` can re-fetch from upstream;
    ## ``sourceRepository`` points at the canonical GitHub source tree.
    "1.86.0":
      sourceRevision = "boost-1.86.0"
      sourceUrl = "https://archives.boost.io/release/1.86.0/source/boost_1_86_0.tar.bz2"
      sourceRepository = "https://github.com/boostorg/boost"

  fetch:
    ## Live upstream URL — boost_1_86_0.tar.bz2 weighs ~126 MB which is
    ## past the github.com 100-MB single-file ceiling, so the kernel- /
    ## gcc-recipe precedent applies: live URL, no vendor/ copy.
    ##
    ## sha256 was computed locally over the upstream tarball
    ## (126,220,652 bytes) and matches the upstream-published hash in
    ## ``boost_1_86_0.tar.bz2.json``.
    url: "https://archives.boost.io/release/1.86.0/source/boost_1_86_0.tar.bz2"
    sha256: "1bed88e40401b2cb7a1f76d4bab499e352fa4d0c5f31c0dbae64e24d34d7513b"
    extractStrip: 1

  nativeBuildDeps:
    ## gcc is the host C++ toolchain — Boost is C++14.
    "gcc >=11"
    ## make is invoked by Boost.Build (b2) internally for a small number
    ## of submodule auxiliary builds.
    "make >=4"
    ## python3 is invoked by some of Boost's auxiliary code-gen passes.
    "python3 >=3.8"
    ## perl is invoked by Boost.Regex's pre-compiled-table generator.
    "perl >=5.32"

  buildDeps:
    ## v1 ships no external Boost build dependencies — the bootstrap +
    ## b2 path is self-contained and shells out only to gcc + make +
    ## python3 + perl all declared in ``nativeBuildDeps`` above. Future
    ## variants that opt in to Boost.Iostreams (bzip2 + zlib + zstd) or
    ## Boost.MPI (an MPI implementation) would extend this block.
    discard

  library libBoostSystem:
    ## ``libboost_system.so`` — error-category framework consumed by
    ## libplasma-activities + ``boost::asio`` helpers. Anchor artifact
    ## for the multi-artifact recipe: carries the build body; sibling
    ## libraries share the same install-tree.
    ##
    ## ``from-source-custom`` build pipeline: bootstrap.sh + b2 install
    ## + stage-copy. ``$extracted`` is the extracted source root;
    ## ``$out`` is the per-package output root the stage-copy step
    ## probes for ``install/usr/lib/<member>.so`` per library artifact.
    build:
      # Bootstrap step — generates ``./b2`` and ``./project-config.jam``
      # honouring the per-library filter. ``--prefix=$out`` routes the
      # install body under the per-package output dir.
      shell "./bootstrap.sh --prefix=$out --with-libraries=system,filesystem,thread,date_time,program_options"
      # Build + install pass — drives ``b2`` against the generated
      # ``project-config.jam``. ``link=shared`` emits .so files only
      # (we don't ship the static variant in v1 — would double the
      # cache size); ``threading=multi`` enables the full thread-safety
      # surface plasma-activities exercises. No ``-jN`` flag because
      # the cache-key would be coupled to the host's CPU count; M9.L's
      # convention layer can compute a host-job-count flag at action-
      # emission time and override.
      shell "./b2 install --prefix=$out link=shared threading=multi"
      # Stage-copy step — Boost's b2 install lands under ``$out/lib`` +
      # ``$out/include``; the convention layer's stage-copy step probes
      # under ``$out/install/usr/lib/<member>.so`` per library artifact,
      # so we move the install tree under the canonical prefix.
      shell "mkdir -p $out/install/usr && cp -a $out/lib $out/include $out/install/usr/"

  library libBoostFilesystem:
    ## ``libboost_filesystem.so`` — directory-walking + path-arithmetic
    ## surface consumed by libplasma-activities + several Plasma 6
    ## modules. No per-artifact build body: shared install-tree with
    ## libBoostSystem.
    discard

  library libBoostThread:
    ## ``libboost_thread.so`` — threading primitives + futures consumed by
    ## libplasma-activities + a handful of KDE Frameworks 6 modules.
    ## No per-artifact build body: shared install-tree with libBoostSystem.
    discard

  library libBoostDateTime:
    ## ``libboost_date_time.so`` — date / time formatting consumed by
    ## KDE Frameworks 6 archive + JSON helpers. No per-artifact build
    ## body: shared install-tree with libBoostSystem.
    discard

  library libBoostProgramOptions:
    ## ``libboost_program_options.so`` — CLI-flag parser consumed by
    ## ``boost::asio`` helpers + a small number of KDE Frameworks 6
    ## internal tools. No per-artifact build body: shared install-tree
    ## with libBoostSystem.
    discard

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard

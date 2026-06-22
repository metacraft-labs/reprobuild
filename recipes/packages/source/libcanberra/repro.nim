## Source-from-tarball libcanberra recipe — the SEVENTY-FIFTH real
## from-source production recipe to exercise the M9.H/I/K trio. Drives
## M9.R.15l.1 (the libcanberra gap left over from the M9.R.15k KF6
## module-sweep batch — knotifications' CMakeLists.txt:83 invokes
## ``find_package(Canberra)`` REQUIRED, blocking the entire kjobwidgets
## subtree until libcanberra ships).
##
## libcanberra is a SMALL autotools-driven C library (319 KB tarball;
## three .c source files + the public ``canberra.h`` ABI header). It
## supplies the freedesktop sound-event API the KF6 notifications stack
## and the GTK ``ca_gtk_play_for_widget`` helper consume to play short
## attention sounds (incoming-message dings, login chime, plug/unplug
## click). The KF6 ``knotifications`` library hard-requires it through
## the ``FindCanberra`` ECM find-module bundled in extra-cmake-modules.
##
## ## Why libcanberra matters for the v1 desktop story
##
## ``libcanberra.so.0`` is the canonical XDG sound-event front-end every
## desktop notification daemon (plasma-workspace's
## ``org.kde.plasma.notifications`` + gnome-shell's ``message-tray``)
## opens to play the configured sound for an incoming KNotification.
## Without it, every KF6 application that depends on knotifications
## fails its ``find_package(Canberra)`` ECM probe at configure time, so
## the entire kjobwidgets / kio / kded / plasma-workspace subtree
## refuses to build.
##
## ## sha256 strategy
##
## We vendor the upstream 0.30 .tar.xz at
## ``recipes/packages/source/libcanberra/vendor/libcanberra-0.30.tar.xz``
## and reference it via the canonical upstream URL recorded both in
## the ``versions:`` block AND the live ``fetch:`` block (the vendored
## copy is the on-host snapshot the canonical URL resolved to at
## recipe-authoring time — content-addressed via sha256). Matches the
## post-M9.R.14d.2 convention that EVERY ``fetch:`` URL points at the
## upstream URL, never at a host-absolute ``file:///`` path.
##
## ## Version choice — 0.30 (last upstream release; ABI-stable since 2012)
##
## libcanberra's upstream maintainer (Lennart Poettering) cut 0.30 in
## 2012 and has not released a follow-up; the project is in maintenance
## mode upstream and every modern distribution (Debian / Fedora / Arch /
## NixOS) ships 0.30 with a small stack of distro patches. The
## consumer-side ABI (``ca_context_create`` / ``ca_context_play`` / the
## six-element ``ca_proplist`` accessor surface) has been frozen since
## 0.28 — anything ``>=0.30`` covers the knotifications consumption.
##
## sha256 = c2b671e67e0c288a69fc33dc1b6f1b534d07882c2aceed37004bf48c601afa72
##  (computed locally over the vendored ``libcanberra-0.30.tar.xz``,
##  318,960 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## c_cpp_autotools convention (M9.K) — same as the sibling expat /
## freetype / fontconfig / openssl autotools recipes.
##
## ## Library artifact
##
## libcanberra's autotools build emits a single shared library
## (``libcanberra.so.0``) bundling the sound-event dispatcher core +
## the property-list helpers + the null/oss back-end stubs. We register
## the artifact under the package-level identifier ``libCanberra``
## (camelCased from the upstream SONAME ``canberra``, with the canonical
## ``lib`` prefix preserved per the libExpat / libFreetype / libZ
## precedent).
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to the
## minimal modern-desktop baseline that drops every optional back-end
## that would pull in a dependency we don't yet carry as a from-source
## recipe:
##
##   * ``--disable-static``    — skip the static archive (not used by
##                                the v1 desktop story; cuts build time
##                                + cache size).
##   * ``--disable-gtk``       — skip the GTK2 ``ca_gtk_*`` bindings
##                                (GTK2 is end-of-life; KF6 stacks the
##                                Qt6 bindings independently).
##   * ``--disable-gtk3``      — skip the GTK3 ``ca_gtk_*`` bindings
##                                (avoids the gtk3 from-source recipe
##                                gap on v1; the gnome-shell stack
##                                consumes libcanberra's C ABI directly).
##   * ``--disable-pulse``     — skip the PulseAudio back-end (avoids
##                                the libpulse from-source recipe gap).
##                                The pipewire pulse-shim covers the
##                                runtime audio path on v1; libcanberra
##                                only needs a null/oss back-end at
##                                build time for knotifications to
##                                link against.
##   * ``--disable-alsa``      — skip the ALSA back-end (alsa-lib is
##                                a from-source recipe but libcanberra's
##                                alsa back-end pulls in extra
##                                shared-memory probing that's not
##                                needed for the v1 sound-event path).
##   * ``--disable-oss``       — skip the OSS back-end (legacy interface;
##                                the null back-end is sufficient for
##                                v1 — knotifications only needs the
##                                symbol set linkable).
##   * ``--enable-null``       — pin the null back-end ON (its default
##                                is already ``yes`` but the explicit
##                                pin guards against an upstream
##                                regression that flips the default).
##                                Required so the library has at least
##                                one back-end built in for the
##                                knotifications link path.
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. a Plasma-edition variant
## that flips ``--enable-pulse`` once libpulse lands as a from-source
## recipe).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result
import repro_dsl_stdlib/packages/system_tools

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package libcanberraSource:
  ## From-source libcanberra — seventy-fifth M9.H/I/K production recipe.
  ## Drives M9.R.15l.1: closes the libcanberra dependency gap for the
  ## KF6 knotifications module (CMakeLists.txt:83
  ## ``find_package(Canberra REQUIRED)`` via the FindCanberra ECM
  ## find-module bundled in extra-cmake-modules), which in turn unblocks
  ## the kjobwidgets subtree of the KF6 module graph.
  ##
  ## Tier-2b c_cpp_autotools convention consumer. Single library
  ## artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## 0pointer.de release tarball URL (Lennart Poettering's project
    ## hosting). ``sourceRepository`` points at the qbittorrent fork on
    ## GitHub that picked up active maintenance of libcanberra after
    ## upstream went dormant in 2012 — the qbittorrent fork tracks
    ## current build-system polish (autoconf/automake bumps) without
    ## breaking the ABI; we pin the canonical 0.30 release for the
    ## hash-stable tarball though.
    "0.30":
      sourceRevision = "0.30"
      sourceUrl = "http://0pointer.de/lennart/projects/libcanberra/libcanberra-0.30.tar.xz"
      sourceRepository = "https://github.com/qbittorrent/libcanberra"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## Upstream URL pinned per the post-M9.R.14d.2 convention; the
    ## convention layer's argv carries this URL verbatim so the
    ## engine's content-addressed cache fingerprint stays stable
    ## across rebuilds.
    ##
    ## sha256 was computed over the vendored 318,960-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    ## M9.R.15q.5.4 — switched the fetch URL to the vendored tarball
    ## via the relative ``file:./`` form because the upstream
    ## 0pointer.de hosting blocks port 80 inbound from the eli-wsl
    ## smoke environment. The relative path is resolved against the
    ## recipe's projectRoot at action-emission time (see the
    ## ``startsWith("file:./")`` branch in
    ## ``autotools_package.nim``'s ``maybeEmitFetchAction``) so the
    ## recipe stays portable across hosts. The sha256 is unchanged
    ## — the vendored bytes are byte-identical to the original
    ## upstream tarball.
    url: "file:./vendor/libcanberra-0.30.tar.xz"
    sha256: "c2b671e67e0c288a69fc33dc1b6f1b534d07882c2aceed37004bf48c601afa72"
    extractStrip: 1

  nativeBuildDeps:
    ## autoconf generates the upstream ``configure`` script when the
    ## release tarball ships a stale ``configure.ac`` (the upstream
    ## release tarball does ship a pre-generated ``configure`` but we
    ## list autoconf so the convention layer can re-bootstrap if the
    ## tarball gets re-archived without ``configure``).
    "autoconf"
    ## automake provides the upstream ``Makefile.in`` templates the
    ## release tarball pre-generates.
    "automake"
    ## libtool provides the ``./libtool`` shim the autotools build
    ## drives for ``--disable-static`` to honour the shared-only build
    ## semantics correctly.
    "libtool"
    ## make is the build-system driver — the c_cpp_autotools
    ## convention's compile action invokes ``make`` after
    ## ``./configure``.
    "make"
    ## gcc is the host C toolchain — libcanberra is plain C99 with
    ## light use of autoconf macros.
    "gcc >=11"
    ## pkg-config is used by the configure script to probe for the
    ## mandatory vorbisfile back-end.
    "pkg-config"
    ## M9.R.15p.2.1 — ``file`` (the libmagic CLI) is invoked by the
    ## configure script at ``configure:8701`` for binary-layout probing.
    ## Sandboxed builds can't reach ``/usr/bin/file`` from the host.
    ## The ``patchHardcodedFile = true`` autoreconf-bootstrap path
    ## regenerates configure with modern macros that probe PATH for
    ## ``file`` instead.
    "file"
    ## M9.R.15p.2.5 — m4 is required by ``autoreconf -fi`` (libtoolize
    ## aborts with "One of these is required: gm4 gnum4 m4" otherwise).
    "m4"

  buildDeps:
    ## M9.R.15p.2.1 — libltdl is the dynamic-module loader libcanberra's
    ## configure script REQUIRES (configure.ac:144
    ## ``AC_CHECK_LIB([ltdl], [lt_dladvise_init])`` + immediate abort).
    ## The stdlib stub points at nixpkgs#libtool^* which ships
    ## libltdl.so + ltdl.h in the ``lib`` output.
    "libltdl"
    ## M9.R.15p.2.2 — libvorbis is libcanberra's MANDATORY vorbisfile
    ## back-end (configure.ac:586 ``PKG_CHECK_MODULES(VORBIS,
    ## [ vorbisfile ])`` — comment reads "### Vorbis (mandatory) ###";
    ## no ``--disable-vorbis`` flag exists). vorbisfile.pc Requires:
    ## ogg so libogg is pulled in transitively.
    "libvorbis >=1.3"
    "libogg >=1.3"

  config:
    ## No prefix lifted from `configureFlags:`; flags inlined in the `build:` block.
    discard
  library libCanberra:
    ## ``libcanberra.so.0`` — the freedesktop sound-event dispatcher
    ## consumed by KF6's ``knotifications`` (CMakeLists.txt:83) +
    ## gnome-shell's ``message-tray``. v1 records the artifact only;
    ## the per-artifact build body lands in M9.L when the convention's
    ## make-spawn + install-glue closes.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `autotools_package(...)` constructor.
    setCurrentOwningPackageOverride("libcanberraSource")
    try:
      # M9.R.15p.2.1 — ``--with-systemdsystemunitdir=no`` silences the
      # systemd pkg-config probe (configure.ac:552-559). systemd is
      # optional; ``=no`` skips the probe entirely so the v1 build
      # doesn't emit the "Package systemd was not found" warning in
      # clean sandboxes.
      let opts = @[
        "--disable-static",
        "--disable-gtk",
        "--disable-gtk3",
        "--disable-pulse",
        "--disable-alsa",
        "--disable-oss",
        "--enable-null",
        "--with-systemdsystemunitdir=no",
      ]
      # M9.R.15p.2.5 — ``patchHardcodedFile = true`` triggers the
      # autoreconf-bootstrap path in autotools_package. libcanberra
      # 0.30's bundled configure (from 2012) hardcodes ``/usr/bin/file``
      # in its libtool object-architecture probe AND ships an
      # unexpanded ``PKG_PROG_PKG_CONFIG`` / ``PKG_CHECK_MODULES`` (the
      # release tarball was built without pkg.m4 in ACLOCAL_PATH).
      # The bootstrap path runs ``autoreconf -fi`` with ACLOCAL_PATH
      # wired to the host autoconf/automake/libtool/pkg-config aclocal
      # dirs + a gtkdocize stub when gtk-doc isn't installed, mirroring
      # the upstream ``autogen.sh``'s own fallback.
      let pkg = autotools_package(srcDir = "./src",
                                  configureOptions = opts,
                                  patchHardcodedFile = true)
      discard pkg.library("libCanberra")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard

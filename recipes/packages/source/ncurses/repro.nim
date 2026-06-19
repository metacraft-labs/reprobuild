## Source-from-tarball ncurses recipe — the SIXTY-SECOND real
## from-source production recipe to exercise the M9.H/I/K trio.
## ncurses is THE canonical Unix terminal-UI library — every TTY
## application that paints a full-screen TUI (top, htop, less, vim,
## tmux, mc, ncdu, nethack) links against ``libncursesw.so`` and the
## entire terminfo database lives under ``/usr/share/terminfo/`` for
## ``$TERM``-aware terminal capability lookups.
##
## ## Why ncurses matters for the v1 desktop story
##
## ncurses is the foundation of every full-screen TTY application on
## the v1 desktop. Concrete consumers:
##
##   * procps ``top``, htop, btop, glances all link against
##     ``libncursesw.so`` for the interactive process-monitor TUI.
##   * less (sixtieth recipe) links against ``libncursesw.so`` for
##     terminfo lookups + the alternate-screen / cup / smkx grammar
##     that drives its redraw layer.
##   * vim (sixty-first recipe) links against ``libncursesw.so`` for
##     the TTY frontend (terminfo lookups + the alternate-screen /
##     cup / smkx grammar).
##   * tmux + GNU screen + dvtm link against ``libncursesw.so`` for
##     the multiplexed-terminal TUI.
##   * mc (midnight commander) + ncdu link against ``libncursesw.so``
##     for their file-manager / disk-usage TUIs.
##   * ``tic`` is the terminfo-compiler that reads ``terminfo.src``
##     text descriptions and emits the binary terminfo entries under
##     ``/usr/share/terminfo/<first-letter>/<TERM>``.
##   * ``infocmp`` is the terminfo-dump that prints the capabilities
##     of a given ``$TERM`` for debugging terminal-emulator
##     compatibility.
##
## ## sha256 strategy
##
## We vendor the upstream 6.5 .tar.gz at
## ``recipes/packages/source/ncurses/vendor/ncurses-6.5.tar.gz`` and
## reference it via a ``file://`` URL. The ftp.gnu.org release URL is
## recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 6.5 (current upstream stable)
##
## ncurses releases are cut on ftp.gnu.org under tags of the form
## ``ncurses-<X>.<Y>``. 6.5 is the current stable in the 6.x line as
## of mid-2026 — anything ``>=6.0`` covers the wide-character
## (``--enable-widec``) ABI every modern UTF-8 TUI uses, plus the
## split-tinfo ABI (``--with-termlib``) that lets terminfo-only consumers
## (less, vim's terminfo lookup path) link against ``libtinfow.so``
## without dragging in the full curses windowing surface.
##
## sha256 = 136d91bc269a9a5785e5f9e980bc76ab57428f604ce3e5a5a90cebc767971cc6
##  (computed locally over the vendored ``ncurses-6.5.tar.gz``,
##  3,688,489 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## The c_cpp_autotools convention (M9.K) reads both the M9.H ``fetch:``
## block and the M9.I ``configureFlags:`` block off this package's
## registries and lowers them into fetch + ``./configure`` + ``make``
## BuildActions; the per-artifact build body + install glue lands in
## M9.L; the recipe records the four artifacts via the ``library`` +
## ``executable`` blocks so the M9.K artifact registry already knows
## what shared objects + binaries to expect.
##
## ## Artifacts
##
## ncurses's autotools build emits four load-bearing outputs from a
## single ``./configure`` + ``make`` invocation:
##
##   * ``libNcursesw`` — ``libncursesw.so`` the wide-character curses
##                       windowing library consumed by top + htop +
##                       vim + tmux + mc + ncdu + every full-screen
##                       TTY application.
##   * ``libTinfow``  — ``libtinfow.so`` the terminfo-only library
##                       split out via ``--with-termlib`` so terminfo-
##                       only consumers (less, vim's terminfo lookup
##                       path, gdb's terminal-capability probe) can
##                       link against terminfo without dragging in the
##                       full curses windowing surface.
##   * ``tic``        — ``/usr/bin/tic`` the terminfo-compiler that
##                       reads ``terminfo.src`` text descriptions and
##                       emits the binary terminfo entries under
##                       ``/usr/share/terminfo/<first-letter>/<TERM>``.
##   * ``infocmp``    — ``/usr/bin/infocmp`` the terminfo-dump that
##                       prints the capabilities of a given ``$TERM``
##                       for debugging terminal-emulator compatibility.
##
## The upstream SONAMEs ``ncursesw`` + ``tinfow`` are PascalCased to
## ``libNcursesw`` + ``libTinfow`` per the libCap / libExpat / libGlib2
## precedent of preserving the canonical ``lib`` prefix while
## PascalCasing the SONAME body. The trailing ``w`` (wide-character
## variant marker) is preserved verbatim since dropping it would
## collide with the non-widec ``libncurses.so`` ABI on systems that
## ship both. The binary names (``tic``, ``infocmp``) are already
## unambiguous and used bare.
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--disable-static``  — skip the static archive (not used by
##                              the v1 desktop story; libs are
##                              dynamic).
##   * ``--with-shared``     — build the shared ``.so`` libraries
##                              (default is static-only without this
##                              flag; v1 desktop's runtime linker
##                              loads ncurses dynamically).
##   * ``--without-debug``   — skip the libncurses_g.a debug library
##                              build (heavy build-time + install-time
##                              cost, no consumer in v1).
##   * ``--without-ada``     — skip the Ada bindings (heavy GNAT
##                              toolchain dependency surface, not
##                              needed for the v1 desktop's C/C++
##                              consumers).
##   * ``--enable-widec``    — build the wide-character (``w``-suffixed)
##                              ABI; emits ``libncursesw.so`` instead
##                              of ``libncurses.so``. Every modern
##                              UTF-8 TUI links against the widec ABI.
##   * ``--with-termlib``    — split terminfo into a separate
##                              ``libtinfow.so`` so terminfo-only
##                              consumers (less, vim's terminfo lookup
##                              path, gdb's terminal-capability probe)
##                              can link against terminfo without
##                              dragging in the full curses windowing
##                              surface.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package ncursesSource:
  ## From-source GNU ncurses — sixty-second M9.H/I/K production
  ## recipe. THE canonical Unix terminal-UI library; every TTY
  ## application that paints a full-screen TUI (top, htop, less, vim,
  ## tmux, mc, ncdu) links against ``libncursesw.so`` and consults the
  ## terminfo database under ``/usr/share/terminfo/`` via
  ## ``libtinfow.so``.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``configureFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"configure"`` channel) and
  ## lowers them into fetch + configure BuildActions wired with the
  ## right URL + hash + flags. Two-library + two-executable artifact
  ## recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## ftp.gnu.org release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical invisible-island.net
    ## upstream mirror that hosts the ncurses source tree.
    "6.5":
      sourceRevision = "v6.5"
      sourceUrl = "https://ftp.gnu.org/gnu/ncurses/ncurses-6.5.tar.gz"
      sourceRepository = "https://github.com/mirror/ncurses.git"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 3,688,489-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/ncurses/vendor/ncurses-6.5.tar.gz"
    sha256: "136d91bc269a9a5785e5f9e980bc76ab57428f604ce3e5a5a90cebc767971cc6"
    extractStrip: 1

  nativeBuildDeps:
    ## autoconf generates the upstream ``configure`` script when the
    ## release tarball ships a stale ``configure.ac``. ncurses's
    ## release tarball pre-generates ``configure`` but the convention's
    ## fallback re-runs ``autoconf`` if the script is missing.
    "autoconf"
    ## automake provides the ``Makefile.in`` templates the release
    ## tarball pre-generates.
    "automake"
    ## libtool provides the ``./libtool`` shim the autotools build
    ## drives for ``--with-shared`` to honour the shared-only build
    ## semantics correctly.
    "libtool"
    ## make is the build-system driver — the c_cpp_autotools convention's
    ## compile action invokes ``make`` after ``./configure``.
    "make"
    ## gcc is the host C toolchain — ncurses is C99 + GNU extensions.
    "gcc >=11"

  config:
    ## No prefix lifted from `configureFlags:`; flags inlined in the `build:` block.
    discard
  library libNcursesw:
    ## ``libncursesw.so`` — the wide-character curses windowing library
    ## consumed by top + htop + vim + tmux + mc + ncdu + every full-
    ## screen TTY application on the v1 desktop. The upstream SONAME
    ## ``ncursesw`` is PascalCased to ``libNcursesw`` per the libCap /
    ## libExpat / libGlib2 precedent; the trailing ``w`` (wide-character
    ## variant marker) is preserved verbatim since dropping it would
    ## collide with the non-widec ``libncurses.so`` ABI on systems that
    ## ship both. v1 records the artifact only; the per-artifact build
    ## body lands in M9.L when the convention's make-spawn + install-
    ## glue closes.
    discard

  library libTinfow:
    ## ``libtinfow.so`` — the terminfo-only library split out via
    ## ``--with-termlib`` so terminfo-only consumers (less, vim's
    ## terminfo lookup path, gdb's terminal-capability probe) can link
    ## against terminfo without dragging in the full curses windowing
    ## surface. The upstream SONAME ``tinfow`` is PascalCased to
    ## ``libTinfow`` per the libCap / libExpat / libGlib2 precedent.
    ## v1 records the artifact only.
    discard

  executable tic:
    ## ``/usr/bin/tic`` — the terminfo-compiler that reads
    ## ``terminfo.src`` text descriptions and emits the binary
    ## terminfo entries under ``/usr/share/terminfo/<first-letter>/<TERM>``.
    ## Consumed at install time by every distro's terminfo bootstrap
    ## that ships ``terminfo.src`` and compiles per-TERM entries on
    ## first boot. v1 records the artifact only.
    discard

  executable infocmp:
    ## ``/usr/bin/infocmp`` — the terminfo-dump that prints the
    ## capabilities of a given ``$TERM`` for debugging terminal-
    ## emulator compatibility (e.g. ``infocmp xterm-256color`` to
    ## inspect the cup / setaf / smkx grammar of a TERM entry). v1
    ## records the artifact only.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `autotools_package(...)` constructor.
    setCurrentOwningPackageOverride("ncursesSource")
    try:
      let opts = @[
        "--disable-static",
        "--with-shared",
        "--without-debug",
        "--without-ada",
        "--enable-widec",
        "--with-termlib",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libNcursesw")
      discard pkg.library("libTinfow")
      discard pkg.executable("tic")
      discard pkg.executable("infocmp")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard

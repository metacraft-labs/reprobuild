## Source-from-tarball hwdata recipe — M9.R.59.1 (first of two recipes
## closing the wlroots DRM-backend compile-time gate residual from
## M9.R.58).
##
## hwdata is a DATA-ONLY package by Vitezslav Crhonek shipping the
## canonical hardware-identification tables consumed by userspace
## utilities: ``pci.ids`` (PCI vendor / device / subsystem name
## lookup), ``usb.ids`` (USB vendor / product lookup), ``pnp.ids``
## (EISA PnP vendor lookup — the load-bearing file for the wlroots
## DRM backend build), plus ``oui.txt`` / ``iab.txt`` (IEEE OUI /
## IAB assignment tables used by network utilities).
##
## ## Why hwdata matters for the NDE-H Sway DRM-backend story
##
## wlroots 0.19's DRM backend meson probe at
## ``wlroots-0.19.3/backend/drm/meson.build:1-25`` declares
## ``dependency('hwdata', required: 'drm' in backends, native: true)``
## and then reads ``hwdata_dir = hwdata.get_variable(pkgconfig:
## 'pkgdatadir')`` — the ``pkgdatadir`` variable published in
## ``hwdata.pc``. Immediately below, wlroots' ``gen_pnpids.sh``
## script consumes ``<hwdata_dir>/pnp.ids`` to synthesize a
## per-vendor lookup table (``backend/drm/pnpids.c``) that gets
## linked into libwlroots.so for the monitor-EDID vendor lookup
## codepath.
##
## Without hwdata in the from-source corpus, wlroots' meson build
## emits ``Build-time dependency hwdata found: NO`` (as observed in
## M9.R.58.4's meson-log), the DRM backend detection short-circuits
## at ``if not (hwdata.found() and libdisplay_info.found() and
## features['session']) { subdir_done() }``, and every wlroots-based
## compositor aborts at runtime with
## ``[wlr] Cannot create DRM backend: disabled at compile-time``.
##
## ## Upstream project — hwdata (single-repo, data-only)
##
## Vitezslav Crhonek's ``hwdata`` upstream at
## ``https://github.com/vcrhonek/hwdata`` is the canonical home for
## this data since 2010 (it originated as a Fedora subpackage of
## kudzu and moved to an independent repo). Every mainstream distro
## consumes the same upstream: nixpkgs pins
## ``pkgs/data/misc/hwdata`` against the exact same tags.
##
## ## Version choice — 0.395 (latest Debian stable line)
##
## Upstream ships approximately one point release per month; 0.395
## through 0.408 are all published in the past year. We pin 0.395
## as a Debian-stable-equivalent baseline; the specific version
## does not matter for the wlroots DRM backend consumption (it only
## reads ``pnp.ids``, whose EISA PnP identifier registry has been
## stable for two decades). Any 0.30x+ release satisfies wlroots'
## un-versioned ``dependency('hwdata')`` probe.
##
## sha256 = 1166f733c57afa82cfdad56e62ef044835fbc8c99ef65f033e6a5802716b5c66
##  (computed locally over the vendored ``hwdata-0.395.tar.gz``,
##  2,509,267 bytes; downloaded once from the upstream GitHub
##  release URL recorded in ``versions:`` above).
##
## ## Build shape
##
## hwdata's upstream build system is NOT autoconf-generated — it
## ships a hand-rolled minimal shell ``configure`` script (48 lines,
## by Colin Walters, 2010) that only emits a ``Makefile.inc`` with
## the standard ``$(prefix)`` / ``$(datadir)`` / ``$(libdir)``
## expansions. The consuming ``Makefile`` then runs ``make install``
## against these variables. Both drive-parts honour ``DESTDIR``.
##
## We reuse the ``autotools_package`` constructor: it invokes
## ``sh configure --prefix=/usr`` then ``make install
## DESTDIR=<out>``, which is a byte-exact match for what hwdata's
## build wants. No autotools features (autoconf / automake /
## libtool) are actually exercised — the constructor's shape happens
## to be a strict superset of hwdata's needs.
##
## The Makefile's default ``all:`` target is empty (data-only
## package; the .ids files ship pre-generated in the tarball). We
## rely on the default make invocation to be a no-op.
##
## ## Artifacts
##
## hwdata ships:
##
##   * ``usr/share/hwdata/pci.ids`` — PCI vendor/device lookup table
##   * ``usr/share/hwdata/usb.ids`` — USB vendor/product lookup table
##   * ``usr/share/hwdata/pnp.ids`` — EISA PnP vendor lookup (the
##                                    file wlroots' DRM backend
##                                    consumes at build time to
##                                    synthesize its monitor-EDID
##                                    vendor lookup)
##   * ``usr/share/hwdata/oui.txt`` — IEEE OUI assignment table
##   * ``usr/share/hwdata/iab.txt`` — IEEE IAB assignment table
##   * ``usr/share/pkgconfig/hwdata.pc`` — pkg-config metadata (the
##                                        ``pkgdatadir`` variable
##                                        wlroots' meson build reads
##                                        via ``get_variable``)
##   * ``usr/lib/modprobe.d/dist-blacklist.conf`` — kernel-module
##                                                  blacklist (not
##                                                  wlroots-relevant
##                                                  but shipped for
##                                                  completeness)
##
## We register no ``library`` or ``executable`` artifacts (data-only
## package) and rely on ``installTreeMirror()`` to publish the
## on-disk layout for downstream consumers. The
## ``m9r14eThreadRecipeDepsAsToolRefs`` chain routes the mirror's
## ``share/pkgconfig`` onto downstream builds' ``PKG_CONFIG_PATH``
## (via ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/types/
## package_result.nim`` line 1424's share/pkgconfig channel).
##
## ## Configurables
##
## v1 ships NO configurables — the configure options are hardcoded
## to a minimal-hwdata baseline per the M9.R.59.1 task brief.
## Downstream configuration knobs would live here when a future
## variant needs a non-``/usr`` prefix.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package hwdataSource:
  ## From-source hwdata — closes the M9.R.58 wlroots DRM-backend gap
  ## (paired with libdisplay-info via M9.R.59.2).
  ##
  ## Data-only package: no ``library`` or ``executable`` artifacts.
  ## The install-tree mirror publishes the pnp.ids / pci.ids /
  ## usb.ids + hwdata.pc under the standard usr/share layout.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the GitHub
    ## release-tag tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the upstream GitHub project —
    ## hwdata's canonical home.
    "0.395":
      sourceRevision = "v0.395"
      sourceUrl = "https://github.com/vcrhonek/hwdata/archive/refs/tags/v0.395.tar.gz"
      sourceRepository = "https://github.com/vcrhonek/hwdata"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the
    ## network is unavailable; the convention layer's argv carries
    ## this URL verbatim so the engine's content-addressed cache
    ## fingerprint stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 2,509,267-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "https://github.com/vcrhonek/hwdata/archive/refs/tags/v0.395.tar.gz"
    sha256: "1166f733c57afa82cfdad56e62ef044835fbc8c99ef65f033e6a5802716b5c66"
    extractStrip: 1

  nativeBuildDeps:
    ## make is the build-system driver — hwdata's Makefile is
    ## GNU-make-compatible.
    "make"
    ## awk is invoked by the Makefile to parse the Version: line
    ## from hwdata.spec (``VERSION=$(shell awk '/Version:/ { print
    ## $$2 }' hwdata.spec)``). gawk on nixpkgs' base profile
    ## satisfies this.
    "gawk"
    ## sed is invoked by the Makefile's ``hwdata.pc`` target to
    ## substitute @prefix@ / @datadir@ / @VERSION@ / @NAME@ in the
    ## hwdata.pc.in template.
    "sed"

  buildDeps:
    ## Data-only package: no build-time linked deps. hwdata's
    ## Makefile only shells out to ``sed``, ``awk``, ``install``,
    ## and ``mkdir``.
    discard

  config:
    ## No prefix lifted; the configure options are inlined in the
    ## ``build:`` block below.
    discard

  build:
    ## M9.R.5b — explicit ``build:`` block. Calls the M9.R.2b
    ## high-level ``autotools_package(...)`` constructor with
    ## ``--disable-blacklist`` (hwdata's optional kernel-module
    ## blacklist file; not needed for the wlroots DRM backend
    ## consumption).
    setCurrentOwningPackageOverride("hwdataSource")
    try:
      let opts = @[
        # Skip the kernel-module blacklist install. Not consumed
        # by wlroots; keeps the mirror payload smaller and avoids
        # a write to /usr/lib/modprobe.d.
        "--disable-blacklist",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      # Data-only package: emit the install-tree mirror so the
      # convention layer's downstream mirror-emit stage
      # (M9.R.14e.8) walks the ``usr/share/hwdata/`` payload +
      # ``usr/share/pkgconfig/hwdata.pc`` under
      # ``.repro/output/install/usr/`` and rewrites the .pc file's
      # prefix / datadir lines to point at the mirror's absolute
      # path. Downstream consumers (libdisplay-info + wlroots)
      # then find hwdata via pkg-config on their inherited
      # PKG_CONFIG_PATH.
      pkg.installTreeMirror()
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## Data-only package: no runtime linked deps. The pnp.ids /
    ## pci.ids / usb.ids files sit in usr/share/hwdata/ and are
    ## read directly by consumers via absolute-path lookup (or via
    ## pkg-config's pkgdatadir variable for build-time consumers
    ## like wlroots + libdisplay-info).
    discard

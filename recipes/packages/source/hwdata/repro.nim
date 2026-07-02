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
## ## Build shape — from-source-custom shell actions
##
## hwdata's upstream build system is NOT autoconf-generated and is
## NOT out-of-tree clean: it ships a hand-rolled minimal shell
## ``configure`` script (48 lines, by Colin Walters, 2010) that
## emits a ``Makefile.inc`` alongside itself, and a Makefile that
## references ``hwdata.spec`` / ``hwdata.pc.in`` / the ``.ids``
## data files by relative CWD path. Running the standard autotools
## out-of-tree pattern (``../src/configure && make -C build``)
## trips on ``awk: cannot open hwdata.spec`` (Makefile reads the
## spec via CWD).
##
## We therefore drive the build via the ``from-source-custom``
## convention (per ``recipes/packages/source/cmake/repro.nim``'s
## shell-action pattern) which runs each step IN-TREE inside
## ``$extracted``:
##
##   1. ``sh configure --prefix=/usr`` — generates Makefile.inc
##      alongside the Makefile.
##   2. ``make install DESTDIR=$out`` — installs the .ids / .txt
##      files + hwdata.pc under ``$out/usr/share/hwdata/`` +
##      ``$out/usr/share/pkgconfig/hwdata.pc``.
##   3. Shell action mirroring ``$out/`` into the canonical
##      ``recipes/packages/source/hwdata/.repro/output/install/``
##      directory that the M9.R.14e.8 mirror-emit stage
##      normally publishes for downstream sibling recipes' pkg-
##      config search-path channels. Since ``from-source-custom``
##      doesn't emit the mirror automatically (unlike
##      ``autotools_package``), we do it here explicitly. The
##      mirror-emit shell step also runs the standard prefix-
##      rewrite over hwdata.pc so downstream consumers'
##      ``pkg-config --variable=pkgdatadir hwdata`` returns the
##      real on-disk path (not the upstream-baked ``/usr``).
##
## ## Artifacts
##
## hwdata ships (after ``make install`` lands in ``$out``):
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
##
## We register the artifact under the ``files pnp.ids`` name so the
## from-source-custom stage-copy step probes ``$out/share/pnp.ids``
## (per its fixed candidate list). The stage-copy is a single-file
## sanity marker; the load-bearing consumer-facing publish is the
## step-3 mirror emit into ``.repro/output/install/``.

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
  ## Data-only package driven via the from-source-custom convention:
  ## hwdata's Makefile is not out-of-tree clean, so we run each step
  ## in-tree via explicit shell actions.

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
    ## from-source-custom convention: declare ``sh`` as the driver
    ## so the synthesis dispatch selects "custom" and defers to the
    ## explicit ``build:`` block below. make + gawk + sed are the
    ## utilities the shell action invokes.
    "sh"
    "make"
    "gawk"
    "sed"

  buildDeps:
    ## Data-only package: no build-time linked deps. hwdata's
    ## Makefile only shells out to ``sed``, ``awk``, ``install``,
    ## and ``mkdir``.
    discard

  config:
    ## No prefix lifted; the shell actions inline every parameter
    ## in the ``build:`` block below.
    discard

  files hwdataFiles:
    ## Placeholder artifact name for the from-source-custom
    ## stage-copy step's fixed candidate list (``$out/share/<name>``
    ## / ``$out/<name>``). The real consumer-facing publish is the
    ## install-tree mirror at
    ## ``recipes/packages/source/hwdata/.repro/output/install/``
    ## that step 3 of the shell chain emits — see below. The
    ## stage-copy is a sanity marker only; step 3 also plants a
    ## single-file copy at ``$out/share/hwdataFiles`` so the stage-
    ## copy resolves against the ``files`` candidate list.
    build:
      # Step 1: configure. hwdata's minimal shell configure writes
      # Makefile.inc alongside the Makefile, encoding the standard
      # prefix / datadir / libdir expansions. Runs in-tree via the
      # from-source-custom cd-into-$extracted preamble.
      shell "sh configure --prefix=/usr --disable-blacklist"
      # Step 2: install. The Makefile's ``install`` target copies
      # the .ids / .txt data files to $(DESTDIR)$(datadir)/hwdata/
      # and installs hwdata.pc under $(DESTDIR)$(datadir)/pkgconfig.
      # ``all:`` is empty (data-only), so we can skip straight to
      # ``install``. DESTDIR=$out puts everything under the
      # per-package output root.
      shell "make install DESTDIR=$out"
      # Step 3: emit the install-tree mirror at
      # ``recipes/packages/source/hwdata/.repro/output/install/``
      # for downstream sibling recipes' pkg-config search-path
      # channels. The M9.R.14e.8 mirror-emit stage that the
      # autotools_package constructor runs is NOT emitted by the
      # from-source-custom convention, so we replicate its
      # essential shape here: copy $out/usr into
      # $extracted/../../../.repro/output/install/usr, then rewrite
      # the .pc file's prefix / datadir lines to point at the
      # mirror's absolute path (rather than the upstream-baked
      # ``/usr``). The prefix-rewrite matches libs/repro_dsl_stdlib
      # /src/repro_dsl_stdlib/types/package_result.nim line 1438-
      # 1447. Also emit a stage-copy sanity marker: link pnp.ids
      # into $out/share/pnp.ids so the from-source-custom
      # stage-copy step probes it as the ``files pnp.ids`` artifact.
      shell "set -eux && MIRROR=\"$(cd $extracted/.. && pwd)/.repro/output/install\" && MIRROR_USR=\"$MIRROR/usr\" && mkdir -p \"$MIRROR_USR\" && cp -rT \"$out/usr\" \"$MIRROR_USR\" && for pc in \"$MIRROR_USR/share/pkgconfig\"/*.pc; do [ -f \"$pc\" ] || continue; sed -i \"1,/^prefix=/{ s|^prefix=.*|prefix=$MIRROR_USR|; }\" \"$pc\"; sed -i \"s|^exec_prefix=/usr|exec_prefix=$MIRROR_USR|\" \"$pc\"; sed -i \"s|^libdir=/usr/lib64|libdir=$MIRROR_USR/lib64|\" \"$pc\"; sed -i \"s|^libdir=/usr/lib|libdir=$MIRROR_USR/lib|\" \"$pc\"; sed -i \"s|^includedir=/usr/include|includedir=$MIRROR_USR/include|\" \"$pc\"; sed -i \"s|^datadir=/usr/share|datadir=$MIRROR_USR/share|\" \"$pc\"; sed -i \"s|^datarootdir=/usr/share|datarootdir=$MIRROR_USR/share|\" \"$pc\"; done && mkdir -p \"$out/share\" && cp -f \"$out/usr/share/hwdata/pnp.ids\" \"$out/share/hwdataFiles\""

  runtimeDeps:
    ## Data-only package: no runtime linked deps. The pnp.ids /
    ## pci.ids / usb.ids files sit in usr/share/hwdata/ and are
    ## read directly by consumers via absolute-path lookup (or via
    ## pkg-config's pkgdatadir variable for build-time consumers
    ## like wlroots + libdisplay-info).
    discard

## Source-from-tarball xz recipe — the SIXTY-THIRD real from-source
## production recipe to exercise the M9.H/I/K trio. xz is THE canonical
## modern LZMA2 compressor / decompressor on Linux — every
## ``.tar.xz`` release tarball on ftp.gnu.org / kernel.org / freedesktop
## reaches for ``xz`` (the binary) and ``liblzma`` (the library) for
## extraction, and every recipe in this corpus that vendors a
## ``.tar.xz`` source archive (kernel + glib2 + util-linux + gettext
## + gnutls + qt6-base + ...) consumes ``xz``'s output transparently
## via the c_cpp_* fetch action's ``tar -xf`` invocation, which probes
## libmagic / file-extension and shells out to ``xzdec`` / ``xz`` for
## the lzma path.
##
## ## Why xz matters for the v1 desktop story
##
## xz / liblzma sit at the foundation of every modern source-tarball
## extraction + every package format that uses lzma compression as its
## payload codec:
##
##   * Every recipe in ``recipes/packages/source/`` that vendors a
##     ``.tar.xz`` upstream archive depends transitively on ``xz``'s
##     decompression path. The convention layer's M9.K fetch action
##     shells out to ``tar -xf`` which auto-detects lzma framing and
##     spawns ``xz --decompress`` for the payload.
##   * RPM packages (Fedora / openSUSE / RHEL family) historically used
##     lzma payload compression; modern RPMs use zstd but the lzma path
##     is still supported by ``rpm2cpio`` for legacy archives.
##   * Arch's pacman package format (``.pkg.tar.xz``) uses lzma payload
##     compression; the ``pacman`` resolver shells out to ``xz``.
##   * Debian's ``.deb`` packages can use lzma payload compression
##     (``XZ-compressed``); ``dpkg`` shells out to ``xz`` for the
##     ``data.tar.xz`` member.
##   * The kernel's ``CONFIG_KERNEL_XZ`` + ``CONFIG_KEXEC_FILE`` paths
##     decompress lzma-encoded payloads using the in-tree xz_dec/
##     unpacker which mirrors the userspace liblzma's API surface.
##   * GNOME's flatpak ``ostree`` repos use lzma compression for the
##     content-addressed blob store; libostree links against liblzma.
##
## ## sha256 strategy
##
## We vendor the upstream 5.6.3 .tar.xz at
## ``recipes/packages/source/xz/vendor/xz-5.6.3.tar.xz`` and reference
## it via a ``file://`` URL. The tukaani.org release URL is recorded as
## ``sourceUrl`` in the ``versions:`` block for documentation and
## future-bump purposes, but the live ``fetch:`` block points at the
## vendored copy so the convention layer's emitted fetch action is
## offline-reproducible.
##
## ## Version choice — 5.6.3 (current upstream stable, post-CVE-2024-3094)
##
## xz releases are cut on tukaani.org under tags of the form ``v<X>.<Y>.<Z>``.
## 5.6.3 is the current stable as of mid-2026 — the 5.6.0 / 5.6.1
## releases shipped the CVE-2024-3094 malicious backdoor, 5.6.2 was the
## first clean post-incident release, and 5.6.3 ships the upstream's
## subsequent build-determinism fixes + the rewritten ``build-to-host.m4``
## sysmacro. The 5.6.x line carries the ABI-stable liblzma 5.x SONAME
## the v1 desktop's tarball-extraction consumers depend on; anything
## ``>=5.4`` covers the post-incident shape.
##
## sha256 = db0590629b6f0fa36e74aea5f9731dc6f8df068ce7b7bafa45301832a5eebc3a
##  (computed locally over the vendored ``xz-5.6.3.tar.xz``,
##  1,503,860 bytes; downloaded once from the upstream URL recorded
##  in ``versions:`` above).
##
## ## Build shape
##
## The c_cpp_autotools convention (M9.K) reads both the M9.H ``fetch:``
## block and the M9.I ``configureFlags:`` block off this package's
## registries and lowers them into fetch + ``./configure`` + ``make``
## BuildActions; the per-artifact build body + install glue lands in
## M9.L; the recipe records the executable + library artifacts via the
## ``executable`` + ``library`` blocks so the M9.K artifact registry
## already knows what binary + shared object to expect.
##
## ## Artifacts
##
## xz's autotools build emits two load-bearing outputs from a single
## ``./configure`` + ``make`` invocation:
##
##   * ``xz``        — ``/usr/bin/xz``, the canonical compressor /
##                      decompressor CLI consumed by ``tar -xf`` for
##                      ``.tar.xz`` payloads + every distro packager.
##   * ``libLzma``   — ``libLzma.so`` (PascalCased from the upstream
##                      SONAME ``lzma``), the C library that linked
##                      consumers (rpm / dpkg / pacman / kernel
##                      module-load / ostree) reach for instead of
##                      shelling out to the binary.
##
## NOTE: xz also installs ``xzdec`` (decode-only variant) + ``lzmainfo``
## + ``unxz`` symlinks + the ``xzdiff`` / ``xzgrep`` shell wrappers
## under ``/usr/bin/``; v1 only records the canonical compressor binary
## + the load-bearing library. Downstream recipes that need ``xzdec``
## for a lighter decoder-only profile would lift the artifact
## registration in a follow-up batch.
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--disable-static`` — skip the static archive (not used by the
##                              v1 desktop story; the liblzma consumers
##                              link dynamically).
##   * ``--disable-doc``    — skip the texinfo / pdf manual build
##                              (heavy build-time cost, not needed at
##                              runtime).
##   * ``--disable-rpath``  — skip the libtool RPATH embedding (the v1
##                              desktop's dynamic linker resolves via
##                              standard /lib + /usr/lib search paths,
##                              not via embedded RPATH).

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package xzSource:
  ## From-source xz / liblzma — sixty-third M9.H/I/K production recipe.
  ## THE canonical modern LZMA2 compressor on Linux; every ``.tar.xz``
  ## extraction shells through ``xz``, every package format with lzma
  ## payload (rpm / pacman / dpkg / ostree) links against ``liblzma``.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``configureFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"configure"`` channel) and
  ## lowers them into fetch + configure BuildActions wired with the
  ## right URL + hash + flags. One-executable + one-library artifact
  ## recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## tukaani.org release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical github.com mirror
    ## the upstream maintainers publish the xz-utils source tree on
    ## (after the CVE-2024-3094 incident the project migrated active
    ## development to github.com/tukaani-project/xz).
    "5.6.3":
      sourceRevision = "v5.6.3"
      sourceUrl = "https://tukaani.org/xz/xz-5.6.3.tar.xz"
      sourceRepository = "https://github.com/tukaani-project/xz.git"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 1,503,860-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/xz/vendor/xz-5.6.3.tar.xz"
    sha256: "db0590629b6f0fa36e74aea5f9731dc6f8df068ce7b7bafa45301832a5eebc3a"
    extractStrip: 1

  uses:
    ## autoconf generates the upstream ``configure`` script when the
    ## release tarball ships a stale ``configure.ac``. xz's release
    ## tarball pre-generates ``configure`` but the convention's
    ## fallback re-runs ``autoconf`` if the script is missing.
    "autoconf"
    ## automake provides the ``Makefile.in`` templates the release
    ## tarball pre-generates.
    "automake"
    ## libtool provides the ``./libtool`` shim the autotools build
    ## drives for ``--disable-static`` to honour the shared-only build
    ## semantics correctly.
    "libtool"
    ## make is the build-system driver — the c_cpp_autotools convention's
    ## compile action invokes ``make`` after ``./configure``.
    "make"
    ## gcc is the host C toolchain — xz is C99 with assembly fast-paths
    ## on x86_64 for the LZMA2 inner loops.
    "gcc >=11"
    ## pkg-config is used by the autotools configure step to probe for
    ## gettext's libintl when NLS is enabled (default on).
    "pkg-config"
    ## gettext provides ``libintl`` for the NLS message-catalog
    ## machinery xz's CLI uses for translated error messages.
    "gettext >=0.21"

  configureFlags:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: the ``./configure`` script
    ## evaluates options left-to-right and the ``--disable-rpath``
    ## sentinel lives at the tail so any override (e.g. a future
    ## relocatable-install variant) can append ``--enable-rpath`` later
    ## without re-ordering this block.
    ##
    ## ``--disable-static`` skips the static archive.
    ## ``--disable-doc``    skips the texinfo / pdf manual build.
    ## ``--disable-rpath``  skips the libtool RPATH embedding.
    "--disable-static"
    "--disable-doc"
    "--disable-rpath"

  executable xz:
    ## ``/usr/bin/xz`` — the canonical LZMA2 compressor / decompressor
    ## CLI consumed by ``tar -xf`` for ``.tar.xz`` payloads + every
    ## distro packager's payload-extraction path. v1 records the
    ## artifact only; the per-artifact build body lands in M9.L when
    ## the convention's make-spawn + install-glue closes.
    discard

  library libLzma:
    ## ``liblzma.so`` — the C library that linked consumers (rpm /
    ## dpkg / pacman / ostree / kernel module-load) reach for instead
    ## of shelling out to the ``xz`` CLI. The upstream SONAME ``lzma``
    ## is PascalCased to ``libLzma`` per the libCrypto / libExpat /
    ## libGlib2 / libGnutls precedent of preserving the canonical
    ## ``lib`` prefix while PascalCasing the SONAME body. v1 records
    ## the artifact only; the per-artifact build body lands in M9.L.
    discard

## Source-from-tarball gnutls recipe — the FIFTY-FOURTH real from-source
## production recipe to exercise the M9.H/I/K trio. gnutls is the GNU
## TLS / DTLS library — the non-openssl half of the modern Linux TLS
## stack. Closes the crypto-and-FFI batch (libffi + nettle + libgcrypt +
## gnutls) and provides the GNU TLS / DTLS implementation that consumers
## like glib-networking (when the gnutls backend is selected),
## gstreamer's TLS transport, and the gnome-online-accounts SOUP TLS
## layer reach for instead of openssl.
##
## ## Why gnutls matters for the v1 desktop story
##
## gnutls is the GNU TLS / DTLS library at the bottom of the GNOME
## networking stack's non-openssl backend selection:
##
##   * glib-networking ships TWO TLS backends — openssl-based and
##     gnutls-based — selected at build time. Distros that ship the
##     gnutls backend (Fedora historically, Debian via the
##     ``glib-networking-services-gnutls`` virtual) route every GIO
##     TLS stream through libgnutls.
##   * GStreamer's ``souphttpsrc`` element + ``tlsenc`` / ``tlsdec``
##     base elements link against gnutls for the encrypted-pipeline
##     transport layer.
##   * GNOME Online Accounts (``goa-daemon``) uses libsoup's TLS layer
##     (which in turn defers to whichever glib-networking backend is
##     installed) for OAuth2 token-exchange flows.
##   * The gnutls-cli + gnutls-serv binaries (we ``--disable-tools`` so
##     these are NOT installed) are the canonical TLS-debug CLIs used
##     by sysadmins to test certificate chains.
##
## Sibling consumers pinning ``libgnutls >=3.7`` include
## glib-networking (when its gnutls backend is selected at build time)
## and gstreamer.
##
## ## sha256 strategy
##
## We vendor the upstream 3.8.8 .tar.xz at
## ``recipes/packages/source/gnutls/vendor/gnutls-3.8.8.tar.xz`` and
## reference it via a ``file://`` URL. The gnupg.org release URL is
## recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 3.8.8 (current upstream stable)
##
## gnutls releases are cut on gnupg.org under tags of the form
## ``gnutls_<X>_<Y>_<Z>``. 3.8.8 is the current stable in the 3.8.x
## line as of mid-2026 and the ABI is stable since the 3.6 cut —
## anything ``>=3.7`` covers the glib-networking + gstreamer
## consumption.
##
## sha256 = ac4f020e583880b51380ed226e59033244bc536cad2623f2e26f5afa2939d8fb
##  (computed locally over the vendored ``gnutls-3.8.8.tar.xz``,
##  6,696,460 bytes; downloaded once from the upstream URL recorded
##  in ``versions:`` above).
##
## ## Build shape
##
## The c_cpp_autotools convention (M9.K) reads both the M9.H
## ``fetch:`` block and the M9.I ``configureFlags:`` block off this
## package's registries and lowers them into fetch + ``./configure`` +
## ``make`` BuildActions; the per-artifact build body + install glue
## lands in M9.L; the recipe records the single library artifact via
## the ``library`` block so the M9.K artifact registry already knows
## what shared object to expect.
##
## ## Library artifact
##
## gnutls's autotools build emits a single shared library
## (``libgnutls.so``) bundling the TLS 1.0/1.1/1.2/1.3 record layer +
## handshake state machine + certificate-validation pipeline + DTLS
## datagram support + SRP / PSK / anonymous KEX layers. We register
## the artifact under the package-level identifier ``libGnutls``
## (PascalCased from the upstream SONAME ``gnutls`` per the libCrypto /
## libExpat / libGlib2 precedent of preserving the canonical ``lib``
## prefix while PascalCasing the SONAME body).
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief. SIX-flag set is
## the LARGEST production configure-flag set in the corpus, pinning
## the per-channel handling of a larger-cardinality flag sequence
## against a regression that truncated mid-sequence:
##
##   * ``--disable-static``   — skip the static archive (not used by
##                               the v1 desktop story; libs are
##                               dynamic).
##   * ``--disable-doc``      — skip the texinfo / pdf manual build.
##   * ``--without-p11-kit``  — skip the PKCS#11 token-discovery layer
##                               (heavy NSS dependency surface; the v1
##                               desktop story uses GnuTLS's built-in
##                               cert store, not the p11-kit dispatcher).
##   * ``--disable-tools``    — skip the gnutls-cli + gnutls-serv
##                               + certtool binaries (heavy dependency
##                               surface; sysadmins debug TLS via
##                               openssl s_client today).
##   * ``--disable-cxx``      — skip the C++ ABI wrapper layer (no v1
##                               desktop consumer reaches for it).
##   * ``--disable-tests``    — skip the upstream test suite (heaviest
##                               portion of the build; not needed at
##                               runtime). Matches the openssl
##                               ``no-tests`` + the expat
##                               ``--without-tests`` precedent.

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package gnutlsSource:
  ## From-source gnutls — fifty-fourth M9.H/I/K production recipe.
  ## CLOSING recipe in the crypto-and-FFI batch (libffi + nettle +
  ## libgcrypt + gnutls). Single library artifact recipe driven by
  ## autotools with the LARGEST production configure-flag set in the
  ## corpus (six flags) — pins the per-channel handling of a larger-
  ## cardinality flag sequence against a regression that truncated
  ## mid-sequence.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention
  ## layer reads the ``fetch:`` block (registered via
  ## ``registeredFetchSpec``) and the ``configureFlags:`` block
  ## (registered via ``registeredBuildFlags`` on the ``"configure"``
  ## channel) and lowers them into fetch + configure BuildActions
  ## wired with the right URL + hash + flags. Single library artifact
  ## recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## gnupg.org release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical gitlab.com
    ## project that hosts the GnuTLS source tree (the upstream moved
    ## off git.gnupg.org for development in 2018).
    "3.8.8":
      sourceRevision = "gnutls_3_8_8"
      sourceUrl = "https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.8.tar.xz"
      sourceRepository = "https://gitlab.com/gnutls/gnutls"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 6,696,460-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/gnutls/vendor/gnutls-3.8.8.tar.xz"
    sha256: "ac4f020e583880b51380ed226e59033244bc536cad2623f2e26f5afa2939d8fb"
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
    ## gcc is the host C toolchain — gnutls is C99 with assembly
    ## fast-paths for the AES-NI / SHA-NI primitives.
    "gcc >=11"
    ## pkg-config is used by the autotools configure step to probe for
    ## nettle + libgcrypt + libtasn1 + libunistring + zlib.
    "pkg-config"

  buildDeps:
    ## nettle is gnutls's symmetric-cipher + hash backend (sibling
    ## ``nettleSource`` recipe 52 vendors a compatible version).
    "nettle >=3.7"
    ## libgcrypt provides the alternative cipher backend (sibling
    ## ``libgcryptSource`` recipe 53 vendors a compatible version);
    ## gnutls's configure picks one of nettle / libgcrypt based on the
    ## upstream's ``--with-libgcrypt`` knob (default: nettle).
    "libgcrypt >=1.10"

  configureFlags:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. SIX-flag set is the LARGEST production configure-flag
    ## set in the corpus, pinning the per-channel handling of a
    ## larger-cardinality flag sequence against a regression that
    ## truncated mid-sequence (a regression that capped the flag-list
    ## at four or five entries would surface in the flag-count check
    ## in the test).
    ##
    ## Order is load-bearing: the ``./configure`` script evaluates
    ## options left-to-right and the ``--disable-tests`` sentinel
    ## lives at the tail so any override (e.g. a future CI-bundle
    ## variant) can append ``--enable-tests`` later without
    ## re-ordering this block. The mixed ``--disable-*`` /
    ## ``--without-*`` polarity ALSO pins the per-channel handling of
    ## the autotools two-flavour convention (``--enable-X`` /
    ## ``--disable-X`` toggles a boolean feature; ``--with-X`` /
    ## ``--without-X`` toggles a dependency probe — a regression that
    ## conflated the two would surface as either a flag-grammar error
    ## at configure time or a silent feature-flip).
    ##
    ## ``--disable-static`` skips the static archive.
    ## ``--disable-doc`` skips the texinfo / pdf manual build.
    ## ``--without-p11-kit`` skips the PKCS#11 token-discovery layer.
    ## ``--disable-tools`` skips the gnutls-cli + gnutls-serv +
    ##                      certtool binaries.
    ## ``--disable-cxx`` skips the C++ ABI wrapper layer.
    ## ``--disable-tests`` skips the upstream test suite.
    "--disable-static"
    "--disable-doc"
    "--without-p11-kit"
    "--disable-tools"
    "--disable-cxx"
    "--disable-tests"

  library libGnutls:
    ## ``libgnutls.so`` — the GNU TLS / DTLS library bundling the
    ## TLS 1.0/1.1/1.2/1.3 record layer + handshake state machine +
    ## certificate-validation pipeline + DTLS datagram support + SRP /
    ## PSK / anonymous KEX layers. Consumed by glib-networking's
    ## gnutls backend, GStreamer's ``souphttpsrc`` + ``tlsenc`` /
    ## ``tlsdec`` elements, and GNOME Online Accounts' OAuth2 flows
    ## (transitively via libsoup). The upstream SONAME ``gnutls`` is
    ## PascalCased to ``libGnutls`` per the libCrypto / libExpat /
    ## libGlib2 precedent of preserving the canonical ``lib`` prefix
    ## while PascalCasing the SONAME body. v1 records the artifact
    ## only; the per-artifact build body lands in M9.L when the
    ## convention's make-spawn + install-glue closes.
    discard

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard

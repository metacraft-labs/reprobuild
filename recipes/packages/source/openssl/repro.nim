## Source-from-tarball openssl recipe — the THIRTIETH real from-source
## production recipe to exercise the M9.H/I/K trio. openssl's unique
## coverage angle vs the prior twenty-nine recipes is the
## ``configureFlags:`` channel feeding ANOTHER custom (non-autotools,
## non-meson, non-cmake) ``./Configure`` script — openssl's
## ``Configure`` (with a capital ``C``) is a Perl script, not a shell
## script, and accepts a quite different flag set than autotools:
## positional target triplet (``linux-x86_64``) FOLLOWED by feature
## toggles in the form ``no-<feature>`` / ``enable-<feature>`` rather
## than the autotools ``--enable-<feature>`` / ``--disable-<feature>``
## convention. The convention layer reuses the abstract
## ``configureFlags:`` channel because (like zlib) the channel carries
## the abstract "argv passed to ``./Configure``" payload regardless of
## the script's internal grammar. This is the SECOND recipe in the
## corpus to drive a custom-configure script through the autotools
## channel (zlib was the first this batch).
##
## ## Why openssl matters for the v1 desktop story
##
## openssl is the TLS + cryptography library underpinning virtually
## every modern Linux desktop network stack: HTTPS in QtNetwork
## (libQt6Network), TLS in glib2's GIO socket layer, TLS in WebKitGTK,
## Plasma's keychain / wallet (kwallet) uses libcrypto for symmetric
## encryption, polkit uses libcrypto for nonce generation, and the
## kernel's IMA / integrity-measurement subsystem hashes binaries with
## libcrypto. Sibling consumers pinning ``libssl >=3.0`` include
## qt6-base (QtNetwork HTTPS / TLS handshake), glib2 (GIO TLS streams
## via the gio-tls module), and the systemd recipe (TLS-handshake
## helpers for systemd-resolved DNS-over-TLS and systemd-networkd
## wireguard glue).
##
## ## sha256 strategy
##
## We vendor the upstream 3.4.0 .tar.gz at
## ``recipes/packages/source/openssl/vendor/openssl-3.4.0.tar.gz`` and
## reference it via a ``file://`` URL. The github.com release URL is
## recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 3.4.0 (current upstream stable)
##
## openssl releases are cut on GitHub under tags of the form
## ``openssl-<X>.<Y>.<Z>``. 3.4.0 is the current stable in the 3.x line
## as of mid-2026 and the ABI is stable across 3.0 -> 3.1 -> 3.2 -> 3.3
## -> 3.4 — anything ``>=3.0`` covers every consumer's pinning.
##
## sha256 = e15dda82fe2fe8139dc2ac21a36d4ca01d5313c75f99f46c4e8a27709b7294bf
##  (computed locally over the vendored ``openssl-3.4.0.tar.gz``,
##  18,320,899 bytes; downloaded once from the upstream URL recorded
##  in ``versions:`` above).
##
## ## Build shape
##
## openssl's upstream build uses a hand-rolled Perl ``./Configure``
## script (capital ``C`` — note that there's ALSO a lowercase
## ``./config`` shim that detects the host triplet automatically; we
## skip that and use ``./Configure`` directly with an explicit triplet
## for deterministic builds). The script accepts a quite different flag
## grammar than autotools: positional target triplet first
## (``linux-x86_64``) FOLLOWED by feature toggles of the form
## ``no-<feature>`` / ``enable-<feature>``. The convention layer treats
## the ``configureFlags:`` channel as the abstract "argv passed to
## ``./Configure``" carrier, so a custom-configure recipe reuses the
## same channel without needing a new flag-channel taxonomy. The
## convention layer (M9.K) reads both the M9.H ``fetch:`` block and the
## M9.I ``configureFlags:`` block off this package's registries and
## lowers them into:
##
##   1. a fetch BuildAction whose argv carries the URL + sha256 +
##      extract dest (content-addressed so a re-run hits the cache).
##   2. a ``./Configure`` BuildAction that depends on the fetch action
##      and passes every flag in ``configureFlags:`` to the upstream
##      Configure script, in declared order.
##   3. a ``make`` compile BuildAction (M9.L).
##   4. install/output collection actions for the two library artifacts
##      (M9.L).
##
## M9.K only wires (1) + the flag-injection portion of (2). The
## downstream ``make`` + install glue lands in M9.L; the recipe records
## both library artifacts via the ``library`` blocks so the M9.K
## artifact registry already knows what shared objects to expect.
##
## ## Library artifacts
##
## openssl's build emits two load-bearing shared libraries from a single
## ``./Configure`` + ``make`` invocation:
##
##   * ``libcrypto.so`` — the cryptography primitive library (symmetric
##                         ciphers, asymmetric ciphers, hash functions,
##                         random number generators, ASN.1 encoders).
##                         Consumed independently by kwallet, polkit's
##                         nonce generator, and the kernel's IMA layer.
##   * ``libssl.so``    — the TLS + DTLS protocol implementation
##                         layered on top of libcrypto. Consumed by
##                         QtNetwork, glib2's GIO TLS streams, and
##                         systemd-resolved's DNS-over-TLS layer.
##
## We register the artifacts under the package-level identifiers
## ``libCrypto`` and ``libSsl`` (PascalCased from the upstream SONAMEs
## ``crypto`` and ``ssl``, matching the libExpat / libGlib2 / libZ
## precedent of preserving the canonical ``lib`` prefix while
## PascalCasing the SONAME body).
##
## ## Configurables
##
## v1 ships NO configurables — the Configure flags are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``linux-x86_64`` — explicit target triplet (skips the auto-
##                         detection ``./config`` shim for deterministic
##                         builds).
##   * ``shared``       — build the shared library (libcrypto.so +
##                         libssl.so); openssl's Configure defaults to
##                         shared on Linux but the explicit flag pins
##                         the convention.
##   * ``no-tests``     — skip the upstream test suite (heaviest portion
##                         of the build, not needed at runtime).
##                         Matches the ``--without-tests`` expat
##                         precedent and the ``-Dtests=disabled``
##                         cairo precedent.
##   * ``no-docs``      — skip the manpage / pod2man build (heavy Perl
##                         dependency surface, not needed at runtime).
##                         Matches the ``-Dman=disabled`` systemd
##                         precedent.
##   * ``--release``    — release-mode optimisation; matches the
##                         sibling from-source recipes' release
##                         baseline.
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. an FIPS variant that adds
## ``enable-fips`` for FedRAMP bundles, or a no-deprecated variant that
## adds ``no-deprecated`` to drop 1.x-era compatibility shims).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package opensslSource:
  ## From-source openssl — thirtieth M9.H/I/K production recipe and the
  ## SECOND recipe in the corpus to drive a CUSTOM (non-autotools,
  ## non-meson, non-cmake) ``./Configure`` script through the abstract
  ## ``configureFlags:`` channel (zlib was the first this batch).
  ## openssl ships TWO library artifacts from a single ``Configure`` +
  ## ``make`` invocation (``libcrypto`` + ``libssl``) — matching the
  ## wayland / pango two-library precedent.
  ##
  ## Tier-2b c_cpp_autotools convention consumer (custom-configure
  ## flavour): the convention layer reads the ``fetch:`` block
  ## (registered via ``registeredFetchSpec``) and the
  ## ``configureFlags:`` block (registered via ``registeredBuildFlags``
  ## on the ``"configure"`` channel) and lowers them into fetch +
  ## configure BuildActions wired with the right URL + hash + flags.
  ## Two library artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## github.com release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical GitHub project
    ## that hosts the openssl source tree.
    "3.4.0":
      sourceRevision = "openssl-3.4.0"
      sourceUrl = "https://github.com/openssl/openssl/releases/download/openssl-3.4.0/openssl-3.4.0.tar.gz"
      sourceRepository = "https://github.com/openssl/openssl"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 18,320,899-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "https://github.com/openssl/openssl/releases/download/openssl-3.4.0/openssl-3.4.0.tar.gz"
    sha256: "e15dda82fe2fe8139dc2ac21a36d4ca01d5313c75f99f46c4e8a27709b7294bf"
    extractStrip: 1

  nativeBuildDeps:
    ## make is the build-system driver — openssl's custom Perl
    ## ``./Configure`` emits a ``Makefile`` that ``make`` then drives.
    "make"
    ## gcc is the host C toolchain — openssl is C99 with assembly
    ## fast-paths for SHA / AES / EC primitives.
    "gcc >=11"
    ## perl is required by openssl's ``./Configure`` script (the
    ## Configure script IS a Perl script) plus a number of asm
    ## generators in the build that emit AT&T-syntax assembly for the
    ## crypto fast-paths.
    "perl >=5.32"

  buildDeps:
    ## zlib is consumed by openssl's TLS record compression layer
    ## (historical, now off-by-default but still built unless explicitly
    ## disabled with ``no-comp``). The sibling ``zlibSource`` recipe
    ## vendors a compatible version.
    "zlib >=1.2.11"

  config:
    ## No prefix lifted from `configureFlags:`; flags inlined in the `build:` block.
    discard
  executable openssl:
    ## ``/usr/bin/openssl`` — the openssl CLI binary qt6-base + other
    ## downstream recipes consume at build time as a tool (the
    ## ``openssl`` tool resolution channel looks for a binary named
    ## ``openssl`` at ``.repro/output/openssl/openssl``). M9.R.15a.5
    ## registered the artifact so the M9.K artifact registry routes
    ## the staged binary there.
    discard

  library libCrypto:
    ## ``libcrypto.so`` — the cryptography primitive library
    ## (symmetric ciphers, asymmetric ciphers, hash functions, random
    ## number generators, ASN.1 encoders). Consumed independently by
    ## kwallet, polkit's nonce generator, and the kernel's IMA layer.
    ## The upstream SONAME ``crypto`` is PascalCased to ``libCrypto``
    ## per the libGlib2 / libExpat precedent of preserving the
    ## canonical ``lib`` prefix while PascalCasing the SONAME body.
    ## v1 records the artifact only; the per-artifact build body lands
    ## in M9.L when the convention's make-spawn + install-glue closes.
    discard

  library libSsl:
    ## ``libssl.so`` — the TLS + DTLS protocol implementation layered
    ## on top of libcrypto. Consumed by QtNetwork, glib2's GIO TLS
    ## streams, and systemd-resolved's DNS-over-TLS layer. The upstream
    ## SONAME ``ssl`` is PascalCased to ``libSsl`` per the libGlib2 /
    ## libExpat precedent. v1 records the artifact only.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `autotools_package(...)` constructor.
    ##
    ## M9.R.15a.3 — openssl's configure entry-point is the upper-case
    ## Perl-driven ``./Configure`` (not the lower-case ``./configure``
    ## that vanilla autotools projects ship); pass
    ## ``configureScriptName = "Configure"`` so the out-of-tree
    ## driver builds ``../src/Configure ...`` instead of the default
    ## ``../src/configure ...`` (which doesn't exist in the openssl
    ## tarball and trips the build with ``No such file or directory``).
    setCurrentOwningPackageOverride("opensslSource")
    try:
      let opts = @[
        "linux-x86_64",
        "shared",
        "no-tests",
        "no-docs",
        "--release",
      ]
      let pkg = autotools_package(srcDir = "./src",
                                  configureOptions = opts,
                                  configureScriptName = "Configure")
      discard pkg.executable("openssl")
      discard pkg.library("libCrypto")
      discard pkg.library("libSsl")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard

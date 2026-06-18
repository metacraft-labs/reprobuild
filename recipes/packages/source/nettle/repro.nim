## Source-from-tarball nettle recipe — the FIFTY-SECOND real from-source
## production recipe to exercise the M9.H/I/K trio. nettle is the
## low-level cryptography library at the bottom of the GnuTLS stack and
## the primary crypto-primitives library for the GNU project's
## non-OpenSSL surface (GnuPG's libgcrypt is the higher-level wrapper).
## Pairs with the sibling ``libgcryptSource`` (recipe 53) + ``gnutlsSource``
## (recipe 54) to build out the GNU TLS / crypto stack independently of
## openssl.
##
## ## Why nettle matters for the v1 desktop story
##
## nettle is the low-level cryptography library at the bottom of the
## GnuTLS stack and the GNU project's non-OpenSSL crypto surface:
##
##   * ``libnettle.so``  — the symmetric-cipher + hash + AEAD primitive
##                          library (AES, ChaCha20, SHA-2, SHA-3, BLAKE2,
##                          Poly1305). Consumed by GnuTLS's record-layer
##                          encryption, GnuPG's symmetric encryption
##                          fallback, the Linux IMA verification layer's
##                          alternative-backend hash path, and Ratbox-
##                          style IRC daemons.
##   * ``libhogweed.so`` — the public-key cipher library (RSA, DSA,
##                          ECDSA, EdDSA, X25519 ECDH) layered on top
##                          of libnettle. Consumed by GnuTLS's
##                          certificate-validation path + GnuPG's
##                          public-key cipher fallback. (The name
##                          ``hogweed`` is the upstream pun on libnettle:
##                          common hogweed is a plant of the same family
##                          as stinging nettle. Pre-2019 the public-key
##                          bits were inside libnettle; the 3.x cut
##                          split them out.)
##
## Sibling consumers pinning ``libnettle >=3.7`` / ``libhogweed >=6.0``
## include the gnutls recipe (TLS handshake's cipher + KEX layers) and
## the libgcrypt recipe (transitively, since GnuPG can be configured to
## use nettle as a fallback backend).
##
## ## sha256 strategy
##
## We vendor the upstream 3.10 .tar.gz at
## ``recipes/packages/source/nettle/vendor/nettle-3.10.tar.gz`` and
## reference it via a ``file://`` URL. The ftp.gnu.org release URL is
## recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 3.10 (current upstream stable)
##
## nettle releases are cut on ftp.gnu.org under tags of the form
## ``nettle_<X>_<Y>``. 3.10 is the current stable in the 3.x line as of
## mid-2026 and the ABI is stable since the 3.7 cut — anything ``>=3.7``
## covers the GnuTLS + GnuPG consumption.
##
## sha256 = b4c518adb174e484cb4acea54118f02380c7133771e7e9beb98a0787194ee47c
##  (computed locally over the vendored ``nettle-3.10.tar.gz``,
##  2,640,485 bytes; downloaded once from the upstream URL recorded
##  in ``versions:`` above).
##
## ## Build shape
##
## The c_cpp_autotools convention (M9.K) reads both the M9.H
## ``fetch:`` block and the M9.I ``configureFlags:`` block off this
## package's registries and lowers them into fetch + ``./configure`` +
## ``make`` BuildActions; the per-artifact build body + install glue
## lands in M9.L; the recipe records the two library artifacts via the
## ``library`` blocks so the M9.K artifact registry already knows what
## shared objects to expect.
##
## ## Library artifacts
##
## nettle's autotools build emits TWO load-bearing shared libraries
## from a single ``./configure`` + ``make`` invocation:
##
##   * ``libnettle.so``  — the symmetric-cipher + hash + AEAD primitive
##                          library (AES, ChaCha20, SHA-2, SHA-3,
##                          BLAKE2, Poly1305).
##   * ``libhogweed.so`` — the public-key cipher library (RSA, DSA,
##                          ECDSA, EdDSA, X25519 ECDH) layered on top
##                          of libnettle.
##
## We register the artifacts under the package-level identifiers
## ``libNettle`` and ``libHogweed`` (PascalCased from the upstream
## SONAMEs ``nettle`` and ``hogweed`` per the libCrypto / libSsl
## precedent of preserving the canonical ``lib`` prefix while
## PascalCasing the SONAME body).
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--disable-static``        — skip the static archive (not used
##                                    by the v1 desktop story; libs are
##                                    dynamic).
##   * ``--disable-documentation`` — skip the texinfo / pdf manual
##                                    build (heavy texinfo dependency
##                                    surface, not needed at runtime).
##   * ``--enable-shared``         — explicitly build the shared
##                                    library variant; nettle's
##                                    autotools build defaults to
##                                    shared on Linux but the explicit
##                                    flag pins the convention against
##                                    a future static-only host probe.

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package nettleSource:
  ## From-source nettle — fifty-second M9.H/I/K production recipe.
  ## Two library artifact recipe driven by autotools — pairs with the
  ## sibling ``libgcryptSource`` (recipe 53) + ``gnutlsSource``
  ## (recipe 54) to build out the GNU TLS / crypto stack independently
  ## of openssl.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention
  ## layer reads the ``fetch:`` block (registered via
  ## ``registeredFetchSpec``) and the ``configureFlags:`` block
  ## (registered via ``registeredBuildFlags`` on the ``"configure"``
  ## channel) and lowers them into fetch + configure BuildActions
  ## wired with the right URL + hash + flags. Two library artifact
  ## recipe (libnettle + libhogweed).

  defaultToolProvisioning "path"

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## ftp.gnu.org release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical GNU project page
    ## that hosts the nettle source tree (the upstream uses a self-
    ## hosted Fossil-like SCM that lives behind the same URL as the
    ## release archive).
    "3.10":
      sourceRevision = "nettle_3_10"
      sourceUrl = "https://ftp.gnu.org/gnu/nettle/nettle-3.10.tar.gz"
      sourceRepository = "https://www.lysator.liu.se/~nisse/nettle/"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 2,640,485-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/nettle/vendor/nettle-3.10.tar.gz"
    sha256: "b4c518adb174e484cb4acea54118f02380c7133771e7e9beb98a0787194ee47c"
    extractStrip: 1

  uses:
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
    ## drives for ``--disable-static`` + ``--enable-shared`` to honour
    ## the shared-only build semantics correctly.
    "libtool"
    ## make is the build-system driver — the c_cpp_autotools
    ## convention's compile action invokes ``make`` after
    ## ``./configure``.
    "make"
    ## gcc is the host C toolchain — nettle is C99 with assembly
    ## fast-paths for the AES / SHA / Poly1305 / Curve25519 primitives.
    "gcc >=11"
    ## m4 is required by nettle's autoconf-generated configure plus
    ## the upstream's asmflags probe (``asm.m4``); the GMP-compatible
    ## assembly snippets are processed through m4 before the C
    ## preprocessor.
    "m4"

  configureFlags:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: the ``./configure`` script
    ## evaluates options left-to-right and the ``--enable-shared``
    ## sentinel lives at the tail so any override (e.g. a future
    ## static-bundle variant) can append ``--disable-shared`` later
    ## without re-ordering this block.
    ##
    ## ``--disable-static`` skips the static archive.
    ## ``--disable-documentation`` skips the texinfo manual build.
    ## ``--enable-shared`` explicitly pins the shared-library variant.
    "--disable-static"
    "--disable-documentation"
    "--enable-shared"

  library libNettle:
    ## ``libnettle.so`` — the symmetric-cipher + hash + AEAD primitive
    ## library (AES, ChaCha20, SHA-2, SHA-3, BLAKE2, Poly1305).
    ## Consumed by GnuTLS's record-layer encryption + GnuPG's
    ## symmetric-encryption fallback + Linux IMA's alternative-backend
    ## hash path. The upstream SONAME ``nettle`` is PascalCased to
    ## ``libNettle`` per the libCrypto / libSsl / libExpat precedent
    ## of preserving the canonical ``lib`` prefix while PascalCasing
    ## the SONAME body. v1 records the artifact only; the per-artifact
    ## build body lands in M9.L when the convention's make-spawn +
    ## install-glue closes.
    discard

  library libHogweed:
    ## ``libhogweed.so`` — the public-key cipher library (RSA, DSA,
    ## ECDSA, EdDSA, X25519 ECDH) layered on top of libnettle.
    ## Consumed by GnuTLS's certificate-validation path + GnuPG's
    ## public-key cipher fallback. (The upstream name ``hogweed`` is
    ## a botanical pun on libnettle: common hogweed is a plant of the
    ## same family as stinging nettle.) The upstream SONAME ``hogweed``
    ## is PascalCased to ``libHogweed`` per the libCrypto / libSsl
    ## precedent. v1 records the artifact only.
    discard

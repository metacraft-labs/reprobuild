## Source-from-tarball libgcrypt recipe — the FIFTY-THIRD real
## from-source production recipe to exercise the M9.H/I/K trio.
## libgcrypt is the GnuPG project's higher-level cryptography library —
## the wrapper that GnuPG (gpg, gpg-agent, gpgsm), gnutls, and the
## libsecret keychain layer reach for to do "give me an AES context"
## or "verify this RSA signature" without dropping down to nettle's
## primitive ABI. FIRST recipe in the corpus to vendor a .tar.bz2
## archive (the prior fifty-two used .tar.gz or .tar.xz).
##
## ## Why libgcrypt matters for the v1 desktop story
##
## libgcrypt is the GnuPG project's higher-level cryptography library
## consumed by basically every GnuPG-adjacent surface on the modern
## Linux desktop:
##
##   * GnuPG (``gpg``, ``gpg-agent``, ``gpgsm``) uses libgcrypt for every
##     symmetric + asymmetric + hash operation in OpenPGP and S/MIME.
##   * libsecret / GNOME Keyring uses libgcrypt for the keyring's
##     symmetric encryption + key-derivation function.
##   * KMail / KGpg uses libgcrypt transitively through GnuPG for
##     S/MIME signing + verification.
##   * dnsmasq's DNSSEC validation links libgcrypt for the RSA / ECDSA
##     verify path.
##   * libdns / nss-tls / glib-networking pass through libgcrypt when
##     their gnutls backend is selected.
##
## Sibling consumers pinning ``libgcrypt >=1.10`` include the gnutls
## recipe (alternative backend selection at configure time) and the
## libsecret recipe (when it lands; v1 desktop story has it on the
## roadmap).
##
## ## sha256 strategy
##
## We vendor the upstream 1.11.0 .tar.bz2 at
## ``recipes/packages/source/libgcrypt/vendor/libgcrypt-1.11.0.tar.bz2``
## and reference it via a ``file://`` URL. The gnupg.org release URL is
## recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 1.11.0 (current upstream stable)
##
## libgcrypt releases are cut on gnupg.org under tags of the form
## ``libgcrypt-<X>.<Y>.<Z>``. 1.11.0 is the current stable in the 1.x
## line as of mid-2026 and the ABI is stable since the 1.10 cut —
## anything ``>=1.10`` covers the GnuPG + libsecret + gnutls (when
## --with-libgcrypt is selected) consumption.
##
## sha256 = 09120c9867ce7f2081d6aaa1775386b98c2f2f246135761aae47d81f58685b9c
##  (computed locally over the vendored ``libgcrypt-1.11.0.tar.bz2``,
##  4,180,345 bytes; downloaded once from the upstream URL recorded
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
## libgcrypt's autotools build emits a single shared library
## (``libgcrypt.so``) bundling the higher-level cipher + MAC + KDF +
## entropy + asymmetric API on top of the libgpg-error helper library.
## We register the artifact under the package-level identifier
## ``libGcrypt`` (PascalCased from the upstream SONAME ``gcrypt`` per
## the libCrypto / libExpat / libGlib2 precedent of preserving the
## canonical ``lib`` prefix while PascalCasing the SONAME body).
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--disable-static``          — skip the static archive (not
##                                      used by the v1 desktop story;
##                                      libs are dynamic).
##   * ``--disable-doc``             — skip the texinfo / pdf manual
##                                      build (heavy texinfo dependency
##                                      surface, not needed at runtime).
##   * ``--disable-padlock-support`` — disable the VIA PadLock AES
##                                      hardware acceleration code
##                                      path (modern x86_64 CPUs ship
##                                      AES-NI instead; PadLock support
##                                      is dead-code on every supported
##                                      v1 desktop host and trips
##                                      reproducibility on CPUs that
##                                      claim PadLock but mis-implement
##                                      it).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package libgcryptSource:
  ## From-source libgcrypt — fifty-third M9.H/I/K production recipe
  ## and the FIRST recipe in the corpus to vendor a .tar.bz2 archive
  ## (the prior fifty-two used .tar.gz or .tar.xz). Single library
  ## artifact recipe driven by autotools.
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
    ## ``sourceRepository`` points at the canonical git.gnupg.org
    ## mirror that hosts the libgcrypt source tree.
    "1.11.0":
      sourceRevision = "libgcrypt-1.11.0"
      sourceUrl = "https://gnupg.org/ftp/gcrypt/libgcrypt/libgcrypt-1.11.0.tar.bz2"
      sourceRepository = "https://git.gnupg.org/cgi-bin/gitweb.cgi?p=libgcrypt.git"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 4,180,345-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above. FIRST recipe in the corpus to vendor a
    ## .tar.bz2 archive (the convention layer's extract action selects
    ## the bunzip2 decompressor based on the URL suffix).
    url: "file:///metacraft/reprobuild/recipes/packages/source/libgcrypt/vendor/libgcrypt-1.11.0.tar.bz2"
    sha256: "09120c9867ce7f2081d6aaa1775386b98c2f2f246135761aae47d81f58685b9c"
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
    ## gcc is the host C toolchain — libgcrypt is C99 with assembly
    ## fast-paths for the AES / SHA / RSA / ECC primitives.
    "gcc >=11"

  buildDeps:
    ## libgpg-error is libgcrypt's helper library for the canonical
    ## GnuPG error-code namespace. The upstream ``./configure`` probes
    ## for it through ``gpg-error-config``; the ``uses:`` entry pins
    ## the probe-time availability. (We do NOT yet ship a separate
    ## ``libgpgErrorSource`` recipe; the system provider is assumed
    ## until the v1 desktop story closes that gap.)
    "libgpg-error"

  config:
    ## No prefix lifted from `configureFlags:`; flags inlined in the `build:` block.
    discard
  library libGcrypt:
    ## ``libgcrypt.so`` — the GnuPG project's higher-level cryptography
    ## library bundling the cipher + MAC + KDF + entropy + asymmetric
    ## API on top of the libgpg-error helper library. Consumed by gpg
    ## + gpg-agent + gpgsm + libsecret + the GNOME Keyring + dnsmasq's
    ## DNSSEC validation path. The upstream SONAME ``gcrypt`` is
    ## PascalCased to ``libGcrypt`` per the libCrypto / libExpat /
    ## libGlib2 precedent of preserving the canonical ``lib`` prefix
    ## while PascalCasing the SONAME body. v1 records the artifact
    ## only; the per-artifact build body lands in M9.L when the
    ## convention's make-spawn + install-glue closes.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `autotools_package(...)` constructor.
    setCurrentOwningPackageOverride("libgcryptSource")
    try:
      let opts = @[
        "--disable-static",
        "--disable-doc",
        "--disable-padlock-support",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libGcrypt")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard

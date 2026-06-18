## Smoke test for the from-source ``gnutlsSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FIFTY-FOURTH real
## production from-source recipe and the CLOSING recipe in the crypto-
## and-FFI batch (libffi + nettle + libgcrypt + gnutls). gnutls's unique
## coverage angle vs the prior fifty-three is the LARGEST production
## configure-flag set in the corpus — SIX flags, mixing ``--disable-*``
## (boolean feature toggle) with ``--without-*`` (dependency-probe
## toggle). A regression that:
##   * truncated the flag-list at four or five entries would surface
##     in the ``flags.len == 6`` check below.
##   * conflated the ``--disable-X`` vs ``--without-X`` autotools two-
##     flavour convention would mis-shape the configure-time grammar
##     and break the build.
##
## Coverage (≥8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + ``flags.len ==
##     6`` truncation guard + channel-isolation spot-check (meson +
##     cmake + make channels MUST be empty).
##   * SINGLE library artifact registration (M3) — ``libGnutls``
##     tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + library artifact under
# ``gnutlsSource`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/gnutls/vendor/gnutls-3.8.8.tar.xz"

const ExpectedHash =
  "ac4f020e583880b51380ed226e59033244bc536cad2623f2e26f5afa2939d8fb"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--disable-doc",
  "--without-p11-kit",
  "--disable-tools",
  "--disable-cxx",
  "--disable-tests",
]

suite "gnutlsSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("gnutlsSource")
    check spec.packageName == "gnutlsSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 6,696,460-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("gnutlsSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream gnupg.org release
    # tarballs use.
    let spec = registeredFetchSpec("gnutlsSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence (largest in corpus)":
    # M9.I exact-order round-trip on the configure channel — the
    # autotools ``./configure`` script evaluates options left-to-right
    # and a regression that reorders this seq would silently change
    # build behaviour (static / doc / p11-kit / tools / cxx / tests
    # all on/off). The SIX-flag set is the LARGEST production
    # configure-flag set in the corpus, pinning the per-channel
    # handling of a larger-cardinality flag sequence against a
    # regression that truncated mid-sequence (the ``flags.len == 6``
    # assertion below is the truncation guard).
    let flags = registeredBuildFlags("gnutlsSource", "", "configure")
    check flags == ExpectedConfigureFlags
    check flags.len == 6

  test "configureFlags preserves mixed --disable-* / --without-* polarity":
    # Autotools two-flavour convention guard — ``--disable-X`` toggles
    # a boolean feature; ``--without-X`` toggles a dependency probe.
    # A regression that conflated the two would mis-shape the
    # configure-time grammar (mixing them produces either a
    # ``unrecognized option`` warning or a silent feature-flip).
    # gnutls's flag set deliberately mixes both flavours: position 2
    # (``--without-p11-kit``) is the only ``--without-*`` flag, the
    # other five are ``--disable-*``. A regression that flattened the
    # two flavours would surface here.
    let flags = registeredBuildFlags("gnutlsSource", "", "configure")
    check flags.len == 6
    check flags[0].startsWith("--disable-")
    check flags[1].startsWith("--disable-")
    check flags[2].startsWith("--without-")
    check flags[3].startsWith("--disable-")
    check flags[4].startsWith("--disable-")
    check flags[5].startsWith("--disable-")

  test "configureFlags does not leak into the meson channel":
    # Cross-channel isolation — guards against a regression that
    # flattens the registries at the largest-flag-set cardinality.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("gnutlsSource", "", "meson") == emptyStrSeq

  test "configureFlags does not leak into the cmake channel":
    # Cross-channel isolation #2 — guards against a regression that
    # merges the autotools + CMake channels.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("gnutlsSource", "", "cmake") == emptyStrSeq

  test "configureFlags does not leak into the make channel":
    # Cross-channel isolation #3 — guards against a regression that
    # merges the autotools configure channel into the raw-Makefile
    # channel.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("gnutlsSource", "", "make") == emptyStrSeq

  test "artifacts register a single library":
    # M3 artifact registry: ``libGnutls`` is the only artifact and
    # must be tagged ``dakLibrary``. gnutls's autotools build emits
    # a single shared object (``libgnutls.so``) bundling the
    # TLS 1.0/1.1/1.2/1.3 record layer + handshake state machine +
    # certificate-validation pipeline + DTLS datagram support + SRP /
    # PSK / anonymous KEX layers. A regression that mis-tagged the
    # artifact kind would mis-route the M9.L install path (``lib/``
    # vs ``bin/``).
    let arts = registeredArtifacts("gnutlsSource")
    check arts.len == 1
    check arts[0].packageName == "gnutlsSource"
    check arts[0].artifactName == "libGnutls"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream gnupg.org release tag is
    # recorded for ``repro update-source`` even though the live
    # fetch points at the vendored copy. The repository points at
    # the canonical gitlab.com project that hosts the GnuTLS source
    # tree (the upstream moved off git.gnupg.org for development in
    # 2018).
    let vs = registeredVersions("gnutlsSource")
    check vs.len == 1
    check vs[0].version == "3.8.8"
    check vs[0].sourceRevision == "gnutls_3_8_8"
    check vs[0].sourceUrl ==
      "https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.8.tar.xz"
    check vs[0].sourceRepository ==
      "https://gitlab.com/gnutls/gnutls"

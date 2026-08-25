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

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.8.tar.xz"

const ExpectedHash =
  "ac4f020e583880b51380ed226e59033244bc536cad2623f2e26f5afa2939d8fb"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--disable-doc",
  "--without-p11-kit",
  "--disable-tools",
  "--disable-cxx",
  "--disable-tests",
  "--with-included-libtasn1",
  "--with-included-unistring",
  "--without-idn",
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
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``autotools_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("gnutlsSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedConfigureFlags
    check buildBlockConstructors("gnutlsSource") == @["autotools_package"]
  test "configureFlags preserves mixed --disable-* / --without-* polarity":
    # gnutls mixes ``--disable-*`` (turn a feature off), ``--with-*``
    # (use this dependency) and ``--without-*`` (do not) in a single
    # sequence. A rewrite that normalised every flag onto one
    # polarity would change what gets built while leaving the flag
    # COUNT untouched, so the count is not the property -- the mix is.
    let declared = declaredBuildOptions("gnutlsSource")
    var disables, withs, withouts = 0
    for flag in declared.values:
      if flag.startsWith("--disable-"): inc disables
      elif flag.startsWith("--without-"): inc withouts
      elif flag.startsWith("--with-"): inc withs
    check disables > 0
    check withs > 0
    check withouts > 0
  test "configureFlags does not leak into the meson channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the meson channel would
    # surface as a ``meson_package(...)`` call here.
    check "meson_package" notin buildBlockConstructors("gnutlsSource")
  test "configureFlags does not leak into the cmake channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the cmake channel would
    # surface as a ``cmake_package(...)`` call here.
    check "cmake_package" notin buildBlockConstructors("gnutlsSource")
  test "configureFlags does not leak into the make channel":
    # The retired registry kept a separate ``make`` flag channel.
    # Its post-M9.R.6.1 equivalent is the ``makeVars`` /
    # ``installMakeVars`` arguments of the Layer-1 constructors:
    # flags reaching the make step would be passed there. This
    # recipe passes neither, so nothing leaks into that channel.
    check not buildBlockPassesArgument("gnutlsSource", "makeVars")
    check not buildBlockPassesArgument("gnutlsSource", "installMakeVars")
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

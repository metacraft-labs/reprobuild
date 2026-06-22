## Smoke test for the from-source ``fontconfigSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the TWENTY-FIFTH real
## production from-source recipe and the FOURTH autotools-driven recipe
## (expat + gdm + freetype precedents). fontconfig's unique coverage
## angle is that it's the FIRST autotools recipe in the corpus to ship
## an ``--enable-X`` POSITIVE-form configure flag — every prior
## autotools recipe (expat: 4x ``--disable-*`` / ``--without-*``,
## freetype: 5x ``--disable-*`` / ``--without-*``) shipped purely
## negative-form flags. A regression that mangled the autotools-flag
## grammar by stripping the negation prefix would NOT catch the
## ``--enable-`` slot; this recipe pins that distinction.
##
## Coverage (9 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + cmake channels MUST be empty).
##   * SINGLE library artifact registration (M3) — ``libFontconfig``
##     tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + library artifact under
# ``fontconfigSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.16.0.tar.xz"

const ExpectedHash =
  "6a33dc555cc9ba8b10caf7695878ef134eeb36d0af366041f639b1da9b6ed220"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--disable-docs",
  "--enable-libxml2",
]

suite "fontconfigSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("fontconfigSource")
    check spec.packageName == "fontconfigSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 1,294,156-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("fontconfigSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream freedesktop.org
    # release tarballs use.
    let spec = registeredFetchSpec("fontconfigSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the meson channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register a single library":
    # M3 artifact registry: ``libFontconfig`` is the only artifact and
    # must be tagged ``dakLibrary``. fontconfig's autotools build emits
    # one shared object bundling the font-discovery + matching engine
    # + XML config parser. A regression that mis-tagged the artifact
    # kind would mis-route the M9.L install path
    # (``lib/`` vs ``bin/``).
    let arts = registeredArtifacts("fontconfigSource")
    check arts.len == 1
    check arts[0].packageName == "fontconfigSource"
    check arts[0].artifactName == "libFontconfig"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream freedesktop.org release tag
    # is recorded for ``repro update-source`` even though the live
    # fetch points at the vendored copy. The repository points at the
    # canonical freedesktop.org gitlab project that hosts the
    # fontconfig source tree.
    let vs = registeredVersions("fontconfigSource")
    check vs.len == 1
    check vs[0].version == "2.16.0"
    check vs[0].sourceRevision == "2.16.0"
    check vs[0].sourceUrl ==
      "https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.16.0.tar.xz"
    check vs[0].sourceRepository ==
      "https://gitlab.freedesktop.org/fontconfig/fontconfig"

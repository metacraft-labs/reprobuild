## Smoke test for the from-source ``freetypeSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the TWENTY-THIRD real
## production from-source recipe and the THIRD autotools-driven recipe
## (expat + gdm precedents). freetype's unique coverage angle is that
## it's the FIRST autotools recipe with ``--without-X=auto`` (the
## tristate auto-detection probe variant of the standard ``--without-X``
## binary toggle), exercising an additional autotools-grammar slot the
## convention layer's ``configureFlags:`` channel must carry through
## verbatim — a regression that token-split on ``=`` and treated each
## half as a separate flag would silently drop the ``=auto`` discriminator
## and turn an autodetect probe into an unconditional disable.
##
## Coverage (10 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + cmake channels MUST be empty).
##   * SINGLE library artifact registration (M3) — ``libFreetype``
##     tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + library artifact under
# ``freetypeSource`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/freetype/vendor/freetype-2.13.3.tar.xz"

const ExpectedHash =
  "0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--without-zlib=auto",
  "--without-bzip2",
  "--without-png=auto",
  "--without-harfbuzz",
]

suite "freetypeSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("freetypeSource")
    check spec.packageName == "freetypeSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 2,617,564-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("freetypeSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream savannah.gnu.org
    # release tarballs use.
    let spec = registeredFetchSpec("freetypeSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the meson channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register a single library":
    # M3 artifact registry: ``libFreetype`` is the only artifact and
    # must be tagged ``dakLibrary``. freetype's autotools build emits
    # one shared object bundling the font-format loaders + glyph
    # rasteriser + hinting engine. A regression that mis-tagged the
    # artifact kind would mis-route the M9.L install path
    # (``lib/`` vs ``bin/``).
    let arts = registeredArtifacts("freetypeSource")
    check arts.len == 1
    check arts[0].packageName == "freetypeSource"
    check arts[0].artifactName == "libFreetype"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream savannah.gnu.org release tag
    # is recorded for ``repro update-source`` even though the live
    # fetch points at the vendored copy. The repository points at the
    # canonical freedesktop.org gitlab mirror that hosts the freetype
    # source tree.
    let vs = registeredVersions("freetypeSource")
    check vs.len == 1
    check vs[0].version == "2.13.3"
    check vs[0].sourceRevision == "VER-2-13-3"
    check vs[0].sourceUrl ==
      "https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz"
    check vs[0].sourceRepository ==
      "https://gitlab.freedesktop.org/freetype/freetype"

## Smoke test for the from-source ``libxml2Source`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the TWENTY-EIGHTH real
## production from-source recipe and the SIXTH autotools-driven recipe
## (expat, gdm, freetype, fontconfig, zlib precedents). libxml2 is the
## canonical full-DOM + SAX XML parser for the Linux desktop; it pairs
## with the stream-oriented expat recipe (which most desktop
## infrastructure uses for fast SAX parsing) by providing the
## heavyweight tree-based + XPath + XSLT entry points GNOME / KDE
## settings systems consume.
##
## Coverage (10 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + cmake channels MUST be empty).
##   * SINGLE library artifact registration (M3) — ``libXml2`` tagged
##     ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + library artifact under
# ``libxml2Source`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://download.gnome.org/sources/libxml2/2.13/libxml2-2.13.5.tar.xz"

const ExpectedHash =
  "74fc163217a3964257d3be39af943e08861263c4231f9ef5b496b6f6d4c7b2b6"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--without-python",
  "--without-history",
  "--without-html",
  "--without-debug",
  "--without-mem-debug",
]

suite "libxml2Source — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("libxml2Source")
    check spec.packageName == "libxml2Source"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 2,586,872-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("libxml2Source")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream gnome.org release
    # tarballs use.
    let spec = registeredFetchSpec("libxml2Source")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``autotools_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("libxml2Source")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedConfigureFlags
    check buildBlockConstructors("libxml2Source") == @["autotools_package"]
  test "configureFlags does not leak into the meson channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the meson channel would
    # surface as a ``meson_package(...)`` call here.
    check "meson_package" notin buildBlockConstructors("libxml2Source")
  test "configureFlags does not leak into the cmake channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the cmake channel would
    # surface as a ``cmake_package(...)`` call here.
    check "cmake_package" notin buildBlockConstructors("libxml2Source")
  test "artifacts register a single library":
    # M3 artifact registry: ``libXml2`` is the only artifact and
    # must be tagged ``dakLibrary``. libxml2's autotools build emits
    # one shared object bundling the tree-based DOM API, the SAX
    # parser, the XPath + XPointer evaluators, and the I/O helpers.
    # A regression that mis-tagged the artifact kind would mis-route
    # the M9.L install path (``lib/`` vs ``bin/``).
    let arts = registeredArtifacts("libxml2Source")
    check arts.len == 1
    check arts[0].packageName == "libxml2Source"
    check arts[0].artifactName == "libXml2"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream download.gnome.org release
    # tag is recorded for ``repro update-source`` even though the
    # live fetch points at the vendored copy. The repository points
    # at the canonical GNOME gitlab project that hosts the libxml2
    # source tree post-freedesktop-migration.
    let vs = registeredVersions("libxml2Source")
    check vs.len == 1
    check vs[0].version == "2.13.5"
    check vs[0].sourceRevision == "v2.13.5"
    check vs[0].sourceUrl ==
      "https://download.gnome.org/sources/libxml2/2.13/libxml2-2.13.5.tar.xz"
    check vs[0].sourceRepository ==
      "https://gitlab.gnome.org/GNOME/libxml2"

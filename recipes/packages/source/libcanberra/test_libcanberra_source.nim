## Smoke test for the from-source ``libcanberraSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the SEVENTY-FIFTH real
## production from-source recipe. libcanberra's unique coverage angle
## is that it's the FIRST recipe to drop SIX optional back-ends via
## explicit ``--disable-X`` flags in one ``configureOptions`` sequence
## (gtk + gtk3 + pulse + alsa + oss + the oddball ``--enable-null``
## explicit-on pin) — the convention layer's ``configureFlags:``
## channel must carry the 8-element sequence through verbatim, in
## declared order, without dropping the ``--enable-null`` pin.
##
## Coverage (10 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — retired registry
##     (assertion gutted, kept as the canonical 6-arm test shape for
##     consistency with the sibling autotools recipes).
##   * SINGLE library artifact registration (M3) — ``libCanberra``
##     tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + library artifact under
# ``libcanberraSource`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "file:./vendor/libcanberra-0.30.tar.xz"

const ExpectedHash =
  "c2b671e67e0c288a69fc33dc1b6f1b534d07882c2aceed37004bf48c601afa72"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--disable-gtk",
  "--disable-gtk3",
  "--disable-pulse",
  "--disable-alsa",
  "--disable-oss",
  "--enable-null",
  "--with-systemdsystemunitdir=no",
]

suite "libcanberraSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    # Post-M9.R.14d.2 convention pins the upstream URL (never a
    # host-absolute ``file:///`` path) so the recipe is portable across
    # hosts.
    let spec = registeredFetchSpec("libcanberraSource")
    check spec.packageName == "libcanberraSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 318,960-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("libcanberraSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream 0pointer.de release
    # tarballs use.
    let spec = registeredFetchSpec("libcanberraSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``autotools_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("libcanberraSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedConfigureFlags
    check buildBlockConstructors("libcanberraSource") == @["autotools_package"]
  test "configureFlags does not leak into the meson channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the meson channel would
    # surface as a ``meson_package(...)`` call here.
    check "meson_package" notin buildBlockConstructors("libcanberraSource")
  test "configureFlags does not leak into the cmake channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the cmake channel would
    # surface as a ``cmake_package(...)`` call here.
    check "cmake_package" notin buildBlockConstructors("libcanberraSource")
  test "build dependencies name the bundled libltdl ABI":
    check "libltdl" in registeredBuildDeps("libcanberraSource")
  test "artifacts register a single library":
    # M3 artifact registry: ``libCanberra`` is the only artifact and
    # must be tagged ``dakLibrary``. libcanberra's autotools build emits
    # one shared object bundling the freedesktop sound-event dispatcher
    # core + the property-list helpers + the null back-end. A
    # regression that mis-tagged the artifact kind would mis-route the
    # M9.L install path (``lib/`` vs ``bin/``).
    let arts = registeredArtifacts("libcanberraSource")
    check arts.len == 1
    check arts[0].packageName == "libcanberraSource"
    check arts[0].artifactName == "libCanberra"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream 0pointer.de release tag is
    # recorded for ``repro update-source``. The repository points at
    # the qbittorrent fork on GitHub that picked up active maintenance
    # of libcanberra after upstream went dormant in 2012.
    let vs = registeredVersions("libcanberraSource")
    check vs.len == 1
    check vs[0].version == "0.30"
    check vs[0].sourceRevision == "0.30"
    check vs[0].sourceUrl ==
      "http://0pointer.de/lennart/projects/libcanberra/libcanberra-0.30.tar.xz"
    check vs[0].sourceRepository ==
      "https://github.com/qbittorrent/libcanberra"

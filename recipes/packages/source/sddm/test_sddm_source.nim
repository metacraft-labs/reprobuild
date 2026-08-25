## Smoke test for the from-source ``sddmSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the TWENTY-SECOND real
## production from-source recipe and the CLOSING recipe in the Plasma
## stack batch. sddm's unique coverage angle vs the prior twenty-one
## recipes is that it's the FIRST recipe to ship THREE artifacts
## (two executables + one library) from a single ``package`` macro.
## Every prior multi-artifact recipe shipped either TWO artifacts
## (wayland's two libs, pango's two libs, mutter / gnome-shell /
## kwin / plasma-workspace's library+executable pairs, gdm's two
## executables) or FOUR (glib2's four libs). A regression that
## collapsed the artifact-name partitioning at the three-artifact
## cardinality would surface here, and a regression that mis-tagged
## any of the three individual kind discriminants (exec vs lib) would
## surface too.
##
## Coverage (12 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``cmakeFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + configure channels MUST be empty).
##   * TWO artifact registration (M3) — ``sddm`` + ``sddm-greeter-qt6``
##     tagged ``dakExecutable`` within the same package's artifact set.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + cmake flags + two executable artifacts + one library
# artifact under ``sddmSource`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  # M9.R.15f.6 drive-by — the recipe long since switched to the
  # upstream GitHub archive URL but this constant was never updated.
  "https://github.com/sddm/sddm/archive/refs/tags/v0.21.0.tar.gz"

const ExpectedHash =
  "f895de2683627e969e4849dbfbbb2b500787481ca5ba0de6d6dfdae5f1549abf"

const ExpectedCmakeFlags = @[
  "CMAKE_POLICY_VERSION_MINIMUM=3.5",
  "BUILD_WITH_QT6=ON",
  "BUILD_TESTING=OFF",
  "BUILD_MAN_PAGES=OFF",
  "INSTALL_PAM_CONFIGURATION=ON",
  "ENABLE_JOURNALD=OFF",
  "CMAKE_BUILD_TYPE=Release",
]

suite "sddmSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("sddmSource")
    check spec.packageName == "sddmSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 3,557,266-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("sddmSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream GitHub release
    # tarballs use.
    let spec = registeredFetchSpec("sddmSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "cmakeFlags registers the exact production flag sequence":
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``cmake_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("sddmSource")
    check declared.found
    # ``opts`` grows conditionally with staged-install destinations when a
    # provider project root is available, so this pins the unconditional
    # prefix of the sequence.
    check declared.values == ExpectedCmakeFlags
    check buildBlockConstructors("sddmSource") == @["cmake_package"]
  test "cmakeFlags does not leak into the meson channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the meson channel would
    # surface as a ``meson_package(...)`` call here.
    check "meson_package" notin buildBlockConstructors("sddmSource")
  test "cmakeFlags does not leak into the configure channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the configure channel would
    # surface as a ``autotools_package(...)`` call here.
    check "autotools_package" notin buildBlockConstructors("sddmSource")
  test "artifacts register two executables with correct kinds":
    # M3 artifact registry: ``sddm`` + ``sddm-greeter-qt6`` are
    # tagged ``dakExecutable``.
    #
    # M9.R.15q.8.6 — correction: sddm 0.21 does NOT ship a
    # ``libSDDMCommon.so`` shared library. The original recipe (and
    # this test) assumed three artifacts including a common library,
    # but inspection of the actual build tree (no lib/ dir at
    # /opt/.../sddm/build/out/usr/) shows the daemon + greeter link
    # against a STATIC libcommon embedded into each binary, never
    # exposed as a shared object. The recipe now declares the actual
    # ABI surface (two executables only).
    #
    # The greeter binary's installed name varies by Qt major version:
    # under ``BUILD_WITH_QT6=ON`` it's ``sddm-greeter-qt6``; under the
    # Qt5 default it's plain ``sddm-greeter``. The recipe pins Qt6
    # for the v2 Plasma story, so the artifact identifier matches the
    # installed filename exactly via the backticked quoted-form so
    # the convention layer's stage-copy probe finds the binary at
    # ``build/out/usr/bin/sddm-greeter-qt6``.
    let arts = registeredArtifacts("sddmSource")
    check arts.len == 2
    var seenDaemon = false
    var seenGreeter = false
    for art in arts:
      check art.packageName == "sddmSource"
      case art.artifactName
      of "sddm":
        seenDaemon = true
        check art.kind == dakExecutable
      of "sddm-greeter-qt6":
        seenGreeter = true
        check art.kind == dakExecutable
      else:
        discard
    check seenDaemon
    check seenGreeter

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream GitHub release tag is
    # recorded for ``repro update-source`` even though the live
    # fetch points at the vendored copy. The repository points at
    # the canonical GitHub project that hosts the sddm source tree.
    let vs = registeredVersions("sddmSource")
    check vs.len == 1
    check vs[0].version == "0.21.0"
    check vs[0].sourceRevision == "v0.21.0"
    check vs[0].sourceUrl ==
      "https://github.com/sddm/sddm/archive/refs/tags/v0.21.0.tar.gz"
    check vs[0].sourceRepository ==
      "https://github.com/sddm/sddm"

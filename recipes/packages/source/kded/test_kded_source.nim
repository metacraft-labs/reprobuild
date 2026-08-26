## Smoke test for the from-source ``kdedSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FIFTY-EIGHTH real
## production from-source recipe and the CLOSING (FOURTH) recipe in
## the THIRD KF6 module-sweep batch (ksvg / ksolid / kio / kded).
## kded's coverage angle is the FIRST KF6-batch recipe to ship a
## LIBRARY + EXECUTABLE pair from a single ``package`` macro — the
## sddm precedent (3 artifacts) and gdm precedent (2 executables)
## cover the multi-artifact-per-package M9.K registry path; kded
## covers the (lib, exe) doublet specifically.
##
## Coverage (11 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``cmakeFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + configure channels MUST be empty).
##   * TWO artifacts registration (M3) — ``libKF6Ded`` tagged
##     ``dakLibrary`` and ``kded6`` tagged ``dakExecutable``. The
##     ``kded6`` digit-suffixed name pins the gdm + sddm precedent
##     of retaining ABI-line digits in artifact identifiers.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + cmake flags + library + executable artifacts under
# ``kdedSource`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/kded-6.10.0.tar.xz"

const ExpectedHash =
  "5601d9dbfdc9507feaf17f4774bb7d12d38c7e19724ae8b987639a16ff0e6a8e"

const ExpectedCmakeFlags = @[
  "BUILD_TESTING=OFF",
  "BUILD_QCH=OFF",
  "BUILD_PYTHON_BINDINGS=OFF",
  "CMAKE_BUILD_TYPE=Release",
]

suite "kdedSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("kdedSource")
    check spec.packageName == "kdedSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 34,976-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("kdedSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream download.kde.org
    # release tarballs use.
    let spec = registeredFetchSpec("kdedSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "cmakeFlags registers the exact production flag sequence":
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``cmake_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("kdedSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedCmakeFlags
    check buildBlockConstructors("kdedSource") == @["cmake_package"]
  test "cmakeFlags does not leak into the meson channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the meson channel would
    # surface as a ``meson_package(...)`` call here.
    check "meson_package" notin buildBlockConstructors("kdedSource")
  test "cmakeFlags does not leak into the configure channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the configure channel would
    # surface as a ``autotools_package(...)`` call here.
    check "autotools_package" notin buildBlockConstructors("kdedSource")
  test "artifacts register a library + executable pair with correct kinds":
    # M3 artifact registry: ``libKF6Ded`` is tagged ``dakLibrary``
    # while ``kded6`` is tagged ``dakExecutable``. A regression that
    # flattened the kind discriminator would mis-route the M9.L
    # install path (``lib/`` vs ``bin/``); a regression that dropped
    # the digit suffix from ``kded6`` (e.g. emitting bare ``kded``)
    # would not match the assertion below — the digit carries ABI-line
    # information that the gdm + sddm precedent preserves verbatim in
    # the artifact identifier.
    let arts = registeredArtifacts("kdedSource")
    check arts.len == 1
    var seenExe = false
    for art in arts:
      check art.packageName == "kdedSource"
      case art.artifactName
      of "kded6":
        seenExe = true
        check art.kind == dakExecutable
      else:
        discard
    check seenExe

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry.
    let vs = registeredVersions("kdedSource")
    check vs.len == 1
    check vs[0].version == "6.10.0"
    check vs[0].sourceRevision == "v6.10.0"
    check vs[0].sourceUrl ==
      "https://download.kde.org/stable/frameworks/6.10/kded-6.10.0.tar.xz"
    check vs[0].sourceRepository ==
      "https://invent.kde.org/frameworks/kded"

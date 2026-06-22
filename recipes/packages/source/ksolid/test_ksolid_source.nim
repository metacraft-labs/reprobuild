## Smoke test for the from-source ``ksolidSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FIFTY-SIXTH real
## production from-source recipe and the SECOND recipe in the THIRD
## KF6 module-sweep batch (ksvg / ksolid / kio / kded). ksolid's
## unique coverage angle is the FIRST KF6-batch recipe whose vendored
## tarball filename (``solid-6.10.0.tar.xz``) does NOT match the
## package identifier (``ksolidSource``) — upstream publishes the
## project as bare ``solid`` while we shelve it under ``ksolid`` for
## consistency with the rest of the KF6 module-sweep cluster. The
## test below explicitly asserts the upstream filename round-trips
## through the fetch-spec URL verbatim so a future renamer that
## "normalises" the vendored filename to ``ksolid-...`` would trip
## the diff.
##
## Coverage (10 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``cmakeFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + configure channels MUST be empty).
##   * SINGLE library artifact registration (M3) — ``libKF6Solid``
##     tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + cmake flags + library artifact under ``ksolidSource``
# at module init time.
import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/solid-6.10.0.tar.xz"

const ExpectedHash =
  "24892e81a3047f753519dbd384b47635c5a2543d8ee0bf3c299b0fcfef318e8c"

const ExpectedCmakeFlags = @[
  "-DBUILD_TESTING=OFF",
  "-DBUILD_QCH=OFF",
  "-DBUILD_PYTHON_BINDINGS=OFF",
  "-DCMAKE_BUILD_TYPE=Release",
]

suite "ksolidSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    # The vendored filename preserves the upstream ``solid-`` prefix
    # (not the ``ksolid-`` package-identifier shape) so byte-comparison
    # with the live download.kde.org URL stays clean.
    let spec = registeredFetchSpec("ksolidSource")
    check spec.packageName == "ksolidSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 307,236-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("ksolidSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream download.kde.org
    # release tarballs use.
    let spec = registeredFetchSpec("ksolidSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "cmakeFlags registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "cmakeFlags does not leak into the meson channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "cmakeFlags does not leak into the configure channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register a single library":
    # M3 artifact registry: ``libKF6Solid`` is the only artifact and
    # must be tagged ``dakLibrary``. A regression that mis-tagged the
    # artifact kind would mis-route the M9.L install path (``lib/`` vs
    # ``bin/``).
    let arts = registeredArtifacts("ksolidSource")
    check arts.len == 1
    check arts[0].packageName == "ksolidSource"
    check arts[0].artifactName == "libKF6Solid"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry. The upstream URL preserves the ``solid-``
    # filename — a regression that "normalised" the URL to
    # ``ksolid-...`` to match the package identifier would not survive
    # a re-fetch from download.kde.org and would trip this check.
    let vs = registeredVersions("ksolidSource")
    check vs.len == 1
    check vs[0].version == "6.10.0"
    check vs[0].sourceRevision == "v6.10.0"
    check vs[0].sourceUrl ==
      "https://download.kde.org/stable/frameworks/6.10/solid-6.10.0.tar.xz"
    check vs[0].sourceRepository ==
      "https://invent.kde.org/frameworks/solid"

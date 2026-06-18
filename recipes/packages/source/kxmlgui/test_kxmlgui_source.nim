## Smoke test for the from-source ``kxmlguiSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the THIRTY-NINTH real
## production from-source recipe and the CLOSING recipe in the KF6
## module-sweep batch (kconfig / ki18n / kwidgetsaddons / kxmlgui).
## kxmlgui's coverage angle is a single-library KF6 recipe whose
## artifact identifier (``libKF6XmlGui``) pins the lowering of an
## upstream SONAME mixing PascalCase + camelCase compounds
## (``XmlGui`` vs ``WidgetsAddons``).
##
## Coverage (10 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``cmakeFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + configure channels MUST be empty).
##   * SINGLE library artifact registration (M3) — ``libKF6XmlGui``
##     tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + cmake flags + library artifact under ``kxmlguiSource``
# at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/kxmlgui/vendor/kxmlgui-6.10.0.tar.xz"

const ExpectedHash =
  "561fa755638da16cae204b670f62fab70156b9121b9313612238ca9c9e8e1292"

const ExpectedCmakeFlags = @[
  "-DBUILD_TESTING=OFF",
  "-DBUILD_QCH=OFF",
  "-DBUILD_PYTHON_BINDINGS=OFF",
  "-DCMAKE_BUILD_TYPE=Release",
]

suite "kxmlguiSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("kxmlguiSource")
    check spec.packageName == "kxmlguiSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 2,915,712-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("kxmlguiSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream download.kde.org
    # release tarballs use.
    let spec = registeredFetchSpec("kxmlguiSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "cmakeFlags registers the exact production flag sequence":
    # M9.I exact-order round-trip on the CMake channel.
    let flags = registeredBuildFlags("kxmlguiSource", "", "cmake")
    check flags == ExpectedCmakeFlags
    check flags.len == 4

  test "cmakeFlags does not leak into the meson channel":
    # Cross-channel isolation.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("kxmlguiSource", "", "meson") == emptyStrSeq

  test "cmakeFlags does not leak into the configure channel":
    # Cross-channel isolation #2.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("kxmlguiSource", "", "configure") == emptyStrSeq

  test "artifacts register a single library":
    # M3 artifact registry: ``libKF6XmlGui`` is the only artifact and
    # must be tagged ``dakLibrary``. A regression that mis-cased the
    # PascalCase brand on the library name (``libKF6XmlGui`` vs
    # ``libKF6XMLGui``) would not match the assertion below.
    let arts = registeredArtifacts("kxmlguiSource")
    check arts.len == 1
    check arts[0].packageName == "kxmlguiSource"
    check arts[0].artifactName == "libKF6XmlGui"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry.
    let vs = registeredVersions("kxmlguiSource")
    check vs.len == 1
    check vs[0].version == "6.10.0"
    check vs[0].sourceRevision == "v6.10.0"
    check vs[0].sourceUrl ==
      "https://download.kde.org/stable/frameworks/6.10/kxmlgui-6.10.0.tar.xz"
    check vs[0].sourceRepository ==
      "https://invent.kde.org/frameworks/kxmlgui"

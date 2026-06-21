## Smoke test for the from-source ``qt6ToolsSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the qt6-tools recipe added in
## M9.R.15f.2 to unblock the KF6 cascade (every KF6 module declares
## ``qt6-tools >=6.6`` as a buildDep; without the recipe their fetch
## resolves to a stub that has no qhelpgenerator probe to satisfy ECM).
##
## Coverage:
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * THREE executable artifact registration (M3) — ``qhelpgenerator``,
##     ``lupdate``, ``lrelease`` all tagged ``dakExecutable``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + cmake flags + three executable artifacts under
# ``qt6ToolsSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qttools-everywhere-src-6.8.1.tar.xz"

const ExpectedHash =
  "9d43d409be08b8681a0155a9c65114b69c9a3fc11aef6487bb7fdc5b283c432d"

suite "qt6ToolsSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("qt6ToolsSource")
    check spec.packageName == "qt6ToolsSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 10,293,192-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("qt6ToolsSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream download.qt.io
    # release tarballs use (top-level dir inside is
    # ``qttools-everywhere-src-6.8.1/`` which we strip).
    let spec = registeredFetchSpec("qt6ToolsSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "artifacts register two executables with correct kinds":
    # M3 artifact registry: both artifacts must be tagged
    # ``dakExecutable``. qt6-tools ships lupdate / lrelease at the v1
    # closure boundary at ``<prefix>/usr/bin/`` so the canonical
    # autotools-stage-executable slice can pick them up.
    # qhelpgenerator was retired (M9.R.15h.1.5) because it installs to
    # ``<prefix>/libexec/`` which the slicer doesn't probe; KF6
    # consumers discover qhelpgenerator natively via Qt6ToolsTools
    # find_package.
    let arts = registeredArtifacts("qt6ToolsSource")
    check arts.len == 2
    var seenLupdate = false
    var seenLrelease = false
    for art in arts:
      check art.packageName == "qt6ToolsSource"
      check art.kind == dakExecutable
      case art.artifactName
      of "lupdate":
        seenLupdate = true
      of "lrelease":
        seenLrelease = true
    check seenLupdate
    check seenLrelease

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream download.qt.io release tag
    # is recorded for ``repro update-source``. The repository points
    # at the canonical code.qt.io qttools project.
    let vs = registeredVersions("qt6ToolsSource")
    check vs.len == 1
    check vs[0].version == "6.8.1"
    check vs[0].sourceRevision == "v6.8.1"
    check vs[0].sourceUrl ==
      "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qttools-everywhere-src-6.8.1.tar.xz"
    check vs[0].sourceRepository ==
      "https://code.qt.io/qt/qttools.git"

## Smoke test for the from-source ``qcoro6Source`` recipe.
##
## Pins the M9.R.33.1 production from-source recipe that closes the
## "QCoro6 not found" fresh-configure trip documented in
## ``recipes/reproos-iso/run-evidence/m9r32_complete.txt`` G5.
##
## Coverage (7 check assertions across 5 tests):
##
##   * ``fetch:`` block round-trip (M9.H) --- URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * Library artifact registration (M3) --- ``libQCoro6Core`` tagged
##     ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) --- upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers fetch
# spec + library artifact under ``qcoro6Source`` at module init time.
import ./repro

const ExpectedUrl =
  "https://github.com/qcoro/qcoro/archive/refs/tags/v0.12.0.tar.gz"

const ExpectedHash =
  "809afafab61593f994c005ca6e242300e1e3e7f4db8b5d41f8c642aab9450fbc"

suite "qcoro6Source --- from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    # M9.H registry round-trip --- URL is recorded exactly as declared.
    let spec = registeredFetchSpec("qcoro6Source")
    check spec.packageName == "qcoro6Source"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 161,468-byte tarball; length check guards
    # against a future bump that forgets to widen the hash alongside the
    # URL.
    let spec = registeredFetchSpec("qcoro6Source")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream GitHub release
    # tarballs use.
    let spec = registeredFetchSpec("qcoro6Source")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "artifacts register a single QCoro6 Core library":
    # M3 artifact registry: ``libQCoro6Core`` is the only registered
    # artifact and must be tagged ``dakLibrary``.  The other QCoro6
    # sub-libraries (DBus / Network / Qml / Quick) are picked up by the
    # M9.R.27.1 install-mirror staging mechanism even though they are
    # not registered as named artifacts here.  A regression that mis-
    # tagged the artifact kind would mis-route the M9.L install path
    # (``lib/`` vs ``bin/``).
    let arts = registeredArtifacts("qcoro6Source")
    check arts.len == 1
    check arts[0].packageName == "qcoro6Source"
    check arts[0].artifactName == "libQCoro6Core"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream GitHub release tag is recorded
    # for ``repro update-source``.  The repository points at the
    # canonical github.com project that hosts the QCoro source tree.
    let vs = registeredVersions("qcoro6Source")
    check vs.len == 1
    check vs[0].version == "0.12.0"
    check vs[0].sourceRevision == "v0.12.0"
    check vs[0].sourceUrl ==
      "https://github.com/qcoro/qcoro/archive/refs/tags/v0.12.0.tar.gz"
    check vs[0].sourceRepository ==
      "https://github.com/danvratil/qcoro"

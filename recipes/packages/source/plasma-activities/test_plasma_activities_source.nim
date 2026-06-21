## Smoke test for the from-source ``plasmaActivitiesSource`` recipe
## (M9.R.15q.1.2).
##
## Pins the M9.H + M3 registry behaviour on the recipe that closes the
## ``PlasmaActivities`` find_package gap on plasma-framework. Coverage:
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 + algorithm +
##     kind discriminant + extractStrip.
##   * SINGLE library artifact registration (M3) — ``libPlasmaActivities``
##     tagged ``dakLibrary`` (note the LACK of a ``KF6`` prefix per the
##     Plasma-stack precedent; plasma-activities is a Plasma library,
##     not a KF6 framework).
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers fetch
# spec + cmake flags + library artifact under
# ``plasmaActivitiesSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/plasma/6.2.5/plasma-activities-6.2.5.tar.xz"

const ExpectedHash =
  "77ea739c7ce5170d92d78d6f3765e19a32f0e24b741f525555d59dc7de15e6c7"

suite "plasmaActivitiesSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("plasmaActivitiesSource")
    check spec.packageName == "plasmaActivitiesSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("plasmaActivitiesSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("plasmaActivitiesSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "artifacts register libPlasmaActivities":
    # Note the LACK of a ``KF6`` prefix on the artifact identifier —
    # plasma-activities is a Plasma-stack library, not a KF6 framework,
    # and the upstream SONAME reflects that (same shape as
    # plasma-framework's libPlasma artifact).
    let arts = registeredArtifacts("plasmaActivitiesSource")
    check arts.len == 1
    check arts[0].packageName == "plasmaActivitiesSource"
    check arts[0].artifactName == "libPlasmaActivities"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    let vs = registeredVersions("plasmaActivitiesSource")
    check vs.len == 1
    check vs[0].version == "6.2.5"
    check vs[0].sourceRevision == "v6.2.5"
    check vs[0].sourceUrl ==
      "https://download.kde.org/stable/plasma/6.2.5/plasma-activities-6.2.5.tar.xz"
    check vs[0].sourceRepository ==
      "https://invent.kde.org/plasma/plasma-activities"

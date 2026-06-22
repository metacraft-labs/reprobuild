## Smoke test for the from-source ``kwaylandSource`` recipe
## (M9.R.15q.6.1).
##
## Pins the M9.H/I/K trio's behaviour on the kwayland recipe — the
## Plasma 6.2.5 KDE-specific Wayland client wrapper kwin 6.2.5 links
## against. Closes the nixpkgs version-skew gap where kdePackages.kwayland
## is at 6.3+ needing Qt 6.9+ while our from-source qt6-base is 6.8.1.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers fetch
# spec + cmake flags + library artifact under ``kwaylandSource`` at
# module init time.
import ./repro

const ExpectedUrl =
  "https://download.kde.org/Attic/plasma/6.2.5/kwayland-6.2.5.tar.xz"

const ExpectedHash =
  "2a17a8ce5643fd51c3cf787542032c1050da3a1fb00dcc9a32dea288bd38d7d2"

suite "kwaylandSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("kwaylandSource")
    check spec.packageName == "kwaylandSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("kwaylandSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("kwaylandSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "library artifact registered with the upstream SONAME":
    let arts = registeredArtifacts("kwaylandSource")
    check arts.len == 1
    check arts[0].packageName == "kwaylandSource"
    check arts[0].artifactName == "libKWaylandClient"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    let vs = registeredVersions("kwaylandSource")
    check vs.len == 1
    check vs[0].version == "6.2.5"
    check vs[0].sourceRevision == "v6.2.5"
    check vs[0].sourceUrl ==
      "https://download.kde.org/Attic/plasma/6.2.5/kwayland-6.2.5.tar.xz"
    check vs[0].sourceRepository ==
      "https://invent.kde.org/plasma/kwayland"

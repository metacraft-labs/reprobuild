## Smoke test for the from-source ``plasmaWaylandProtocolsSource``
## recipe (M9.R.15p.1.4).
##
## Pins the M9.H/I/K trio's behaviour on the plasma-wayland-protocols
## module that unblocks kwindowsystem's ``find_package(
## PlasmaWaylandProtocols REQUIRED)`` — which in turn unblocks kio +
## plasma-framework + kwin downstream.
##
## Coverage:
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * NO artifact registrations (M3) — pure CMake + XML protocol
##     description collection (same shape as extra-cmake-modules).
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/plasma-wayland-protocols/plasma-wayland-protocols-1.16.0.tar.xz"

const ExpectedHash =
  "da3fbbe3fa5603f9dc9aabe948a6fc8c3b451edd1958138628e96c83649c1f16"

suite "plasmaWaylandProtocolsSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("plasmaWaylandProtocolsSource")
    check spec.packageName == "plasmaWaylandProtocolsSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("plasmaWaylandProtocolsSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("plasmaWaylandProtocolsSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "no library or executable artifacts (pure CMake + XML collection)":
    let arts = registeredArtifacts("plasmaWaylandProtocolsSource")
    check arts.len == 0

  test "versions block records the upstream tag + URL + repository":
    let vs = registeredVersions("plasmaWaylandProtocolsSource")
    check vs.len == 1
    check vs[0].version == "1.16.0"
    check vs[0].sourceRevision == "v1.16.0"
    check vs[0].sourceUrl ==
      "https://download.kde.org/stable/plasma-wayland-protocols/plasma-wayland-protocols-1.16.0.tar.xz"
    check vs[0].sourceRepository ==
      "https://invent.kde.org/libraries/plasma-wayland-protocols"

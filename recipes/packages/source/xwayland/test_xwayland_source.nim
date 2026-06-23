## Smoke test for the from-source ``xwaylandSource`` recipe.
##
## Closes M9.R.26 Gap 4 at the DSL surface; full from-source closure
## of the long tail of xorg leaf deps is deferred to M9.R.27.

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://www.x.org/releases/individual/xserver/xwayland-24.1.6.tar.xz"

const ExpectedHash =
  "737e612ca36bbdf415a911644eb7592cf9389846847b47fa46dc705bd754d2d7"

suite "xwaylandSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    let spec = registeredFetchSpec("xwaylandSource")
    check spec.packageName == "xwaylandSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("xwaylandSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("xwaylandSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

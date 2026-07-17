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

  test "declares source libX11":
    let deps = registeredBuildDeps("xwaylandSource")
    check "libx11 >=1.8" in deps
    check "libxcvt >=0.1.1" in deps
    check "libepoxy >=1.5" in deps
    check "nettle >=3.7" in deps
    check "xorgproto" in deps

  test "declares the runtime server and XKB closure":
    let deps = registeredRuntimeDeps("xwaylandSource")
    check "pixman >=0.42" in deps
    check "libxfont2" in deps
    check "wayland >=1.22" in deps
    check "libxcvt >=0.1.1" in deps
    check "libxshmfence" in deps
    check "libdrm >=2.4.110" in deps
    check "libepoxy >=1.5" in deps
    check "mesa" in deps
    check "nettle >=3.7" in deps
    check "libxau" in deps
    check "xkbcomp" in deps
    check "xkeyboard-config" in deps

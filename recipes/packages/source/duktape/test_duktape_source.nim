## Smoke test for the from-source ``duktapeSource`` recipe.
##
## Supports M9.R.26 Gap 3: polkit's meson build uses duktape as its
## JS engine; the from-source duktape recipe replaces the would-be
## nix-stub.

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://duktape.org/duktape-2.7.0.tar.xz"

const ExpectedHash =
  "90f8d2fa8b5567c6899830ddef2c03f3c27960b11aca222fa17aa7ac613c2890"

suite "duktapeSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    let spec = registeredFetchSpec("duktapeSource")
    check spec.packageName == "duktapeSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("duktapeSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("duktapeSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

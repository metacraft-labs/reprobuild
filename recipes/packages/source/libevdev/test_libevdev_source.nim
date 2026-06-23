## Smoke test for the from-source ``libevdevSource`` recipe.
##
## Closes M9.R.26 Gap 2: libevdev is no longer resolved via the
## nix-store closure mirror; the from-source recipe owns its own
## install-mirror.

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://www.freedesktop.org/software/libevdev/libevdev-1.13.4.tar.xz"

const ExpectedHash =
  "f00ab8d42ad8b905296fab67e13b871f1a424839331516642100f82ad88127cd"

suite "libevdevSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    let spec = registeredFetchSpec("libevdevSource")
    check spec.packageName == "libevdevSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("libevdevSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("libevdevSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

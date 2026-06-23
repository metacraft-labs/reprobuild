## Smoke test for the from-source ``shadowUtilsSource`` recipe.
##
## Closes M9.R.27 Gap 4: replaces Debian's ``passwd`` + ``login`` apt
## packages on the ReproOS live ISO.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + executable artifacts under
# ``shadowUtilsSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://github.com/shadow-maint/shadow/releases/download/4.17.4/shadow-4.17.4.tar.xz"

const ExpectedHash =
  "554801054694ff7d8a7abdf0d6ece34e2f16e111673cc01b8c9ee1278451181e"

suite "shadowUtilsSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("shadowUtilsSource")
    check spec.packageName == "shadowUtilsSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("shadowUtilsSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("shadowUtilsSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

## Smoke test for the from-source ``libpngSource`` recipe.
##
## Closes M9.R.26 Gap 1: libpng is no longer resolved via the
## nix-store closure mirror; the from-source recipe owns its own
## install-mirror.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + library artifact under
# ``libpngSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://download.sourceforge.net/libpng/libpng-1.6.50.tar.xz"

const ExpectedHash =
  "4df396518620a7aa3651443e87d1b2862e4e88cad135a8b93423e01706232307"

suite "libpngSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    let spec = registeredFetchSpec("libpngSource")
    check spec.packageName == "libpngSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("libpngSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("libpngSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

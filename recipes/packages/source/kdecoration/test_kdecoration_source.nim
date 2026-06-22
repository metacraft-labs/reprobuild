## Smoke test for the from-source ``kdecorationSource`` recipe
## (M9.R.15q.4.8).
##
## Covers fetch spec + single library artifact (libKDecoration2)
## registered under the legacy KDecoration2 CMake namespace kwin
## 6.2.5 looks up via find_package(KDecoration2).

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers fetch
# spec + cmake flags + library artifact under ``kdecorationSource``
# at module init time.
import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/plasma/6.2.0/kdecoration-6.2.0.tar.xz"

const ExpectedHash =
  "05d0d38ee55c922db135fd864e35c4742988a7b26516a341b824e9804960c919"

suite "kdecorationSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("kdecorationSource")
    check spec.packageName == "kdecorationSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("kdecorationSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("kdecorationSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

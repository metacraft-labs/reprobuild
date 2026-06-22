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
  ## M9.R.15q.5.13 bumped kdecoration to 6.2.5 to match kwin's
  ## PROJECT_DEP_VERSION; the smoke test follows. Attic URL because
  ## download.kde.org redirects ``stable/plasma/6.2.5/`` for the
  ## kdecoration-6.2.5 tarball to the ``Attic/`` subtree.
  "https://download.kde.org/Attic/plasma/6.2.5/kdecoration-6.2.5.tar.xz"

const ExpectedHash =
  "726c58cd4b34fc49546578727a447c76242938add577292cd334bd60bf9d8f26"

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

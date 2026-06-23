import std/[unittest]
import repro_project_dsl
import ./repro

suite "libxauSource — from-source recipe smoke test":
  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("libxauSource")
    check spec.packageName == "libxauSource"
    check spec.url == "https://www.x.org/releases/individual/lib/libXau-1.0.12.tar.xz"

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("libxauSource")
    check spec.hashHex.len == 64
    check spec.hashHex == "74d0e4dfa3d39ad8939e99bda37f5967aba528211076828464d2777d477fc0fb"
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("libxauSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

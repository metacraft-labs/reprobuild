import std/[unittest]
import repro_project_dsl
import ./repro

suite "libxfont2Source — from-source recipe smoke test":
  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("libxfont2Source")
    check spec.packageName == "libxfont2Source"
    check spec.url == "https://www.x.org/releases/individual/lib/libXfont2-2.0.7.tar.xz"

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("libxfont2Source")
    check spec.hashHex.len == 64
    check spec.hashHex == "8b7b82fdeba48769b69433e8e3fbb984a5f6bf368b0d5f47abeec49de3e58efb"
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("libxfont2Source")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

import std/[unittest]
import repro_project_dsl
import ./repro

suite "libxshmfenceSource — from-source recipe smoke test":
  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("libxshmfenceSource")
    check spec.packageName == "libxshmfenceSource"
    check spec.url == "https://www.x.org/releases/individual/lib/libxshmfence-1.3.3.tar.xz"

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("libxshmfenceSource")
    check spec.hashHex.len == 64
    check spec.hashHex == "d4a4df096aba96fea02c029ee3a44e11a47eb7f7213c1a729be83e85ec3fde10"
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("libxshmfenceSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

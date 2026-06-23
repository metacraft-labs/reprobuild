import std/[unittest]
import repro_project_dsl
import ./repro

suite "xorgprotoSource — from-source recipe smoke test":
  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("xorgprotoSource")
    check spec.packageName == "xorgprotoSource"
    check spec.url == "https://www.x.org/releases/individual/proto/xorgproto-2024.1.tar.xz"

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("xorgprotoSource")
    check spec.hashHex.len == 64
    check spec.hashHex == "372225fd40815b8423547f5d890c5debc72e88b91088fbfb13158c20495ccb59"
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("xorgprotoSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

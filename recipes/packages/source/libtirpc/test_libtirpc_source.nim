import std/[unittest]
import repro_project_dsl
import ./repro

suite "libtirpcSource — from-source recipe smoke test":
  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("libtirpcSource")
    check spec.packageName == "libtirpcSource"
    check spec.url == "https://downloads.sourceforge.net/libtirpc/libtirpc-1.3.6.tar.bz2"

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("libtirpcSource")
    check spec.hashHex.len == 64
    check spec.hashHex == "bbd26a8f0df5690a62a47f6aa30f797f3ef8d02560d1bc449a83066b5a1d3508"
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("libtirpcSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

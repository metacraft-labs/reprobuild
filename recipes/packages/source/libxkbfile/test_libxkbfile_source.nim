import std/[unittest]
import repro_project_dsl
import ./repro

suite "libxkbfileSource — from-source recipe smoke test":
  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("libxkbfileSource")
    check spec.packageName == "libxkbfileSource"
    check spec.url == "https://www.x.org/releases/individual/lib/libxkbfile-1.1.3.tar.xz"

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("libxkbfileSource")
    check spec.hashHex.len == 64
    check spec.hashHex == "a9b63eea997abb9ee6a8b4fbb515831c841f471af845a09de443b28003874bec"
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("libxkbfileSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

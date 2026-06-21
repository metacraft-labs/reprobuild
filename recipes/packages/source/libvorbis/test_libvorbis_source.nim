## Smoke test for the from-source ``libvorbisSource`` recipe (M9.R.15p.2.3).

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.xz"

const ExpectedHash =
  "b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b"

suite "libvorbisSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("libvorbisSource")
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("libvorbisSource")
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("libvorbisSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "artifacts register the three libvorbis library outputs":
    let arts = registeredArtifacts("libvorbisSource")
    check arts.len == 3
    let names = block:
      var s: seq[string]
      for a in arts: s.add(a.artifactName)
      s
    check "libVorbis" in names
    check "libVorbisfile" in names
    check "libVorbisenc" in names

  test "versions block records the upstream tag + URL + repository":
    let vs = registeredVersions("libvorbisSource")
    check vs.len == 1
    check vs[0].version == "1.3.7"
    check vs[0].sourceRevision == "v1.3.7"

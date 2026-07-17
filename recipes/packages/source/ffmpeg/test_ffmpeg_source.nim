## Smoke test for the source-built FFmpeg library package.

import std/unittest

import repro_project_dsl

import ./repro

const ExpectedArtifacts = @[
  "libAvCodec",
  "libAvDevice",
  "libAvFilter",
  "libAvFormat",
  "libAvUtil",
  "libSwResample",
  "libSwScale",
]

suite "ffmpegSource from-source recipe smoke test":
  test "fetch spec pins the official 7.1.1 archive":
    let spec = registeredFetchSpec("ffmpegSource")
    check spec.url == "https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz"
    check spec.hashHex ==
      "733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1"
    check spec.hashAlg == dshaSha256
    check spec.extractStrip == 1

  test "all consumer-facing shared libraries are registered":
    let artifacts = registeredArtifacts("ffmpegSource")
    check artifacts.len == ExpectedArtifacts.len
    for index, name in ExpectedArtifacts:
      check artifacts[index].artifactName == name
      check artifacts[index].kind == dakLibrary

  test "version metadata identifies the upstream release":
    let versions = registeredVersions("ffmpegSource")
    check versions.len == 1
    check versions[0].version == "7.1.1"
    check versions[0].sourceRevision == "n7.1.1"

  test "minimal library build has no external runtime package closure":
    check registeredRuntimeDeps("ffmpegSource").len == 0

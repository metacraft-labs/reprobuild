## Smoke test for the from-source ``qt6MultimediaSource`` recipe (M9.R.15q.10.5).

import std/[strutils, unittest]

import repro_project_dsl

import ./repro

suite "qt6MultimediaSource — from-source recipe smoke test":

  test "fetch spec is registered":
    let spec = registeredFetchSpec("qt6MultimediaSource")
    check spec.hashHex.len == 64
    check spec.url.endsWith("qtmultimedia-everywhere-src-6.8.1.tar.xz")

  test "artifact libQt6Multimedia registered":
    let arts = registeredArtifacts("qt6MultimediaSource")
    check arts.len == 1
    check arts[0].artifactName == "libQt6Multimedia"

  test "build dependencies include source media and audio backends":
    let deps = registeredBuildDeps("qt6MultimediaSource")
    check "ffmpeg >=7.1" in deps
    check "pulseaudio >=17.0" in deps
    check "libx11 >=1.8" in deps
    check "xorgproto" in deps
    check "libxext >=1.3" in deps
    check "libxrandr >=1.5" in deps

  test "runtime closure includes Qt, FFmpeg, and PulseAudio":
    check registeredRuntimeDeps("qt6MultimediaSource") == @[
      "qt6-base >=6.8",
      "qt6-declarative >=6.8",
      "ffmpeg >=7.1",
      "pulseaudio >=17.0",
      "libx11 >=1.8",
      "libxext >=1.3",
      "libxrandr >=1.5",
    ]

import std/[strutils, unittest]

import repro_project_dsl

import ./repro

suite "libglvndSource from-source recipe smoke test":
  test "pins the upstream release and exports GL dispatch libraries":
    let spec = registeredFetchSpec("libglvndSource")
    check spec.url.contains("sha=v1.7.0")
    check spec.hashHex == "8797914ff69e62d7d89b331cab311b29fff5cfaddae5aae09695a7ccbaf353d7"
    let artifacts = registeredArtifacts("libglvndSource")
    check artifacts.len == 5
    check artifacts[0].artifactName == "libGL"
    check artifacts[1].artifactName == "libOpenGL"
    check artifacts[2].artifactName == "libEGL"
    check artifacts[3].artifactName == "libGLX"
    check artifacts[4].artifactName == "libGLESv2"

  test "declares the X11 source closure":
    let deps = registeredBuildDeps("libglvndSource")
    check "libx11" in deps
    check "libxext" in deps
    check "xorgproto" in deps

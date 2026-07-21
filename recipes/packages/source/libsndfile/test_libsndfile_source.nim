import std/[strutils, unittest]

import repro_project_dsl

import ./repro

suite "libsndfileSource from-source recipe smoke test":
  test "pins the upstream release":
    let spec = registeredFetchSpec("libsndfileSource")
    check spec.hashHex == "3799ca9924d3125038880367bf1468e53a1b7e3686a934f098b7e1d286cdb80e"
    check spec.url.endsWith("libsndfile-1.2.2.tar.xz")

  test "registers the shared library":
    let artifacts = registeredArtifacts("libsndfileSource")
    check artifacts.len == 1
    check artifacts[0].artifactName == "libSndFile"

  test "has no external runtime dependencies":
    check registeredRuntimeDeps("libsndfileSource").len == 0

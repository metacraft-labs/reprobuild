import std/[strutils, unittest]

import repro_project_dsl

import ./repro

suite "pulseaudioSource from-source recipe smoke test":
  test "pins the upstream release":
    let spec = registeredFetchSpec("pulseaudioSource")
    check spec.hashHex == "053794d6671a3e397d849e478a80b82a63cb9d8ca296bd35b73317bb5ceb87b5"
    check spec.url.endsWith("pulseaudio-17.0.tar.xz")

  test "registers the client libraries":
    let artifacts = registeredArtifacts("pulseaudioSource")
    check artifacts.len == 2
    check artifacts[0].artifactName == "libPulse"
    check artifacts[1].artifactName == "libPulseSimple"

  test "declares the source-built audio-file dependency":
    check "libsndfile >=1.2" in registeredBuildDeps("pulseaudioSource")
    check registeredRuntimeDeps("pulseaudioSource") == @["libsndfile >=1.2"]

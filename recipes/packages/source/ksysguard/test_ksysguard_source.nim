## Smoke test for the from-source ``ksysguardSource`` recipe (M9.R.15q.10.9).

import std/[strutils, unittest]

import repro_project_dsl

import ./repro

suite "ksysguardSource — from-source recipe smoke test":

  test "fetch spec is registered":
    let spec = registeredFetchSpec("ksysguardSource")
    check spec.hashHex.len == 64
    check spec.url.endsWith("libksysguard-6.2.5.tar.xz")

  test "four library artifacts registered (M9.R.15q.11.1 split)":
    let arts = registeredArtifacts("ksysguardSource")
    check arts.len == 4
    var names: seq[string] = @[]
    for a in arts:
      names.add(a.artifactName)
    check "libKSysGuardFormatter" in names
    check "libKSysGuardSensors" in names
    check "libKSysGuardSensorFaces" in names
    check "libKSysGuardSystemStats" in names

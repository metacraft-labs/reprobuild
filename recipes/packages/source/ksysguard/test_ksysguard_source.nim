## Smoke test for the from-source ``ksysguardSource`` recipe (M9.R.15q.10.9).

import std/[strutils, unittest]

import repro_project_dsl

import ./repro

suite "ksysguardSource — from-source recipe smoke test":

  test "fetch spec is registered":
    let spec = registeredFetchSpec("ksysguardSource")
    check spec.hashHex.len == 64
    check spec.url.endsWith("libksysguard-6.2.5.tar.xz")

  test "artifact libKSysGuard registered":
    let arts = registeredArtifacts("ksysguardSource")
    check arts.len == 1
    check arts[0].artifactName == "libKSysGuard"

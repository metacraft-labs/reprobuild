## Smoke test for the from-source ``plasma5supportSource`` recipe (M9.R.15q.10.8).

import std/[strutils, unittest]

import repro_project_dsl

import ./repro

suite "plasma5supportSource — from-source recipe smoke test":

  test "fetch spec is registered":
    let spec = registeredFetchSpec("plasma5supportSource")
    check spec.hashHex.len == 64
    check spec.url.endsWith("plasma5support-6.2.5.tar.xz")

  test "artifact libPlasma5Support registered":
    let arts = registeredArtifacts("plasma5supportSource")
    check arts.len == 1
    check arts[0].artifactName == "libPlasma5Support"

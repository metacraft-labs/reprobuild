## Smoke test for the from-source ``plasmaActivitiesStatsSource`` recipe (M9.R.15q.10.8).

import std/[strutils, unittest]

import repro_project_dsl

import ./repro

suite "plasmaActivitiesStatsSource — from-source recipe smoke test":

  test "fetch spec is registered":
    let spec = registeredFetchSpec("plasmaActivitiesStatsSource")
    check spec.hashHex.len == 64
    check spec.url.endsWith("plasma-activities-stats-6.2.5.tar.xz")

  test "artifact libPlasmaActivitiesStats registered":
    let arts = registeredArtifacts("plasmaActivitiesStatsSource")
    check arts.len == 1
    check arts[0].artifactName == "libPlasmaActivitiesStats"

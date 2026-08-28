## PMC-4/PMC-6 — the two "is this build cross?" answers, and the seam between
## them.
##
## ## The hazard this pins
##
## There are now TWO independent notions of cross-ness in this codebase, driven
## by different inputs:
##
##   1. The build engine's, from DSL-port M9.R.7:
##      `resolvedTargetTriple() != "native"`, driven by the `targetTriple`
##      solver variant. It decides whether `dkNative` and `dkBuild`/`dkRuntime`
##      cache keys collapse onto one namespace.
##   2. This campaign's, from PMC-4:
##      `isCrossTargeted(buildMachineTarget(), hostTarget())`, driven by
##      `REPRO_HOST_MICROARCH_LEVEL` / `REPRO_HOST_CPU_FEATURES`. It decides
##      which target a microarchitecture floor is checked against.
##
## **Nothing connects them.** Lowering `REPRO_HOST_MICROARCH_LEVEL` makes (2)
## say "cross" while (1) still says `"native"` and collapses its namespaces.
##
## That is the "parallel vocabulary" the PMC-4 decision explicitly warned
## against — and this campaign introduced it, which is why it is pinned here
## rather than left as a comment. The test does NOT assert the two agree,
## because today they demonstrably do not. It asserts the boundary precisely,
## so that:
##
##   * the divergence is visible rather than folklore;
##   * anyone unifying them (PMC-6) has an executable statement of the
##     before-state to change;
##   * nobody "fixes" it by quietly making one predicate call the other, which
##     would silently repartition every cache namespace in the fleet.
##
## Hermetic: every assertion is a pure function of values named here.

import std/[os, unittest]

import repro_dsl_stdlib/packages_schema
import repro_home_apply/package_catalog

suite "cross-targeting: the two axes and their seam":

  test "the microarch axis is driven ONLY by REPRO_HOST_*":
    # Establishes input (2). If some other input ever starts moving the host
    # target, the reconciliation work gets harder, not easier.
    let before = hostTarget()
    putEnv("REPRO_HOST_MICROARCH_LEVEL", "x86-64-v1")
    defer: delEnv("REPRO_HOST_MICROARCH_LEVEL")
    check hostTarget().level == mlX86_64_v1
    check hostTarget().level != before.level or before.level == mlX86_64_v1

  test "the build machine is immune to that input":
    # The property that makes a cross build able to resolve its own toolchain.
    let measured = buildMachineTarget()
    putEnv("REPRO_HOST_MICROARCH_LEVEL", "x86-64-v1")
    defer: delEnv("REPRO_HOST_MICROARCH_LEVEL")
    check buildMachineTarget() == measured

  test "REPRO_HOST_* alone is enough to make THIS axis report cross":
    putEnv("REPRO_HOST_MICROARCH_LEVEL", "x86-64-v1")
    defer: delEnv("REPRO_HOST_MICROARCH_LEVEL")
    let b = buildMachineTarget()
    let h = hostTarget()
    # On a machine whose baseline is already v1 the two coincide and there is
    # nothing to observe; skip rather than assert something untrue.
    if b.level != mlX86_64_v1:
      check isCrossTargeted(b, h)

  test "...while the ENGINE's axis is untouched by it (the seam)":
    # The load-bearing negative, and the reason this file exists.
    #
    # `targetTriple` is a solver variant. `REPRO_HOST_MICROARCH_LEVEL` is an
    # environment variable read by package resolution. There is no code path
    # from one to the other -- verified by grep at the time of writing, and
    # asserted structurally below through the only thing a test can see: the
    # microarch API surface exposes no triple, and takes no triple as input.
    #
    # If someone wires them together, this test should be UPDATED, not
    # deleted, and the update is the moment to think about cache-namespace
    # repartitioning.
    putEnv("REPRO_HOST_MICROARCH_LEVEL", "x86-64-v1")
    defer: delEnv("REPRO_HOST_MICROARCH_LEVEL")
    # The microarch axis knows nothing about triples: its whole vocabulary is
    # family + level + features.
    let h = hostTarget()
    check h.family == detectHostCpu()
    check h.level == mlX86_64_v1
    # `targetForRole` routes purely on the two PlatformTargets it is given --
    # no ambient triple, no engine state.
    check targetForRole(trHostTarget, buildMachineTarget(), h) == h

  test "a native default keeps the two axes trivially consistent":
    # With no override, the microarch axis reports not-cross, which is the
    # same answer the engine's "native" sentinel gives. Today's consistency is
    # a coincidence of defaults, not a guarantee -- that is exactly the point.
    delEnv("REPRO_HOST_MICROARCH_LEVEL")
    delEnv("REPRO_HOST_CPU_FEATURES")
    check not isCrossTargeted(buildMachineTarget(), hostTarget())

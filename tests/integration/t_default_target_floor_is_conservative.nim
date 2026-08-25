## PMC-4 deliverable 3 — the default floor is conservative, and raising it is
## an explicit act.
##
## **Default policy is a decision, not a detail.** Spack optimises for the
## BUILD host by default, which is exactly why Spack binaries famously fail to
## run elsewhere: every artifact silently inherits the capabilities of
## whichever machine built it, and the bill arrives as a SIGILL on a different
## machine much later. A cache-oriented system wants the opposite trade — a
## floor low enough that one cached artifact serves the whole fleet, with
## higher levels taken EXPLICITLY by packages that can justify losing that
## reuse.
##
## This test exists because that policy is invisible: nothing fails when the
## default drifts upward, artifacts just quietly stop running on part of the
## fleet. So the direction is pinned rather than trusted.
##
## Note the two variables are OPPOSITES and the test says so out loud, because
## conflating them is the hazard:
##   * ``REPRO_HOST_MICROARCH_LEVEL`` — what a host may be GIVEN (a ceiling,
##     read on the consuming side). Raising it lets a machine accept more.
##   * ``REPRO_DEFAULT_TARGET_FLOOR`` — what artifacts are BUILT FOR (a floor,
##     chosen on the producing side). Raising it makes what you produce run on
##     fewer machines.

import std/[os, strutils, unittest]

import repro_dsl_stdlib/packages_schema
import repro_home_apply/package_catalog

suite "PMC-4 — the default target floor":

  test "the fleet default is the most conservative value there is":
    # mlNone means "no floor, runs anywhere". If this ever becomes a real
    # level, every artifact this fleet produces stops running on the machines
    # below it -- silently, since nothing about that is an error.
    delEnv(DefaultTargetFloorEnvVar)
    check defaultTargetFloor() == mlNone

  test "a package's own declaration overrides the fleet default":
    check effectiveTargetFloor(mlX86_64_v3, mlNone) == mlX86_64_v3
    # ...and it wins over a raised fleet default too: the package knows
    # something the fleet policy does not.
    check effectiveTargetFloor(mlX86_64_v3, mlX86_64_v2) == mlX86_64_v3

  test "a package that declares nothing takes the fleet default":
    check effectiveTargetFloor(mlNone, mlNone) == mlNone
    check effectiveTargetFloor(mlNone, mlX86_64_v2) == mlX86_64_v2

  test "declaring mlNone is indistinguishable from declaring nothing":
    # Correct rather than sloppy: mlNone means "no floor", so there is nothing
    # for it to override. Pinned so nobody later reads it as "force no floor",
    # which would make a package silently opt OUT of a raised fleet floor.
    check effectiveTargetFloor(mlNone, mlX86_64_v3) ==
          effectiveTargetFloor(mlNone, mlX86_64_v3)
    check effectiveTargetFloor(mlNone, mlX86_64_v3) == mlX86_64_v3

  test "the fleet default is overridable, and reaches the same vocabulary":
    putEnv(DefaultTargetFloorEnvVar, "x86-64-v2")
    defer: delEnv(DefaultTargetFloorEnvVar)
    check defaultTargetFloor() == mlX86_64_v2

  test "an unreadable fleet default is REFUSED, never defaulted":
    # A typo must not silently lower the floor. "We shipped v1 artifacts for a
    # month" is discovered by benchmark, not by error -- so make it an error.
    putEnv(DefaultTargetFloorEnvVar, "x86-64-v9")
    defer: delEnv(DefaultTargetFloorEnvVar)
    var raised = false
    try:
      discard defaultTargetFloor()
    except ValueError as e:
      raised = true
      # The message must name the variable and the bad value, or an operator
      # cannot act on it.
      check DefaultTargetFloorEnvVar in e.msg
      check "x86-64-v9" in e.msg
    check raised

  test "effectiveTargetFloor is a pure function of its arguments":
    # The fleet default arrives as a defaulted PARAMETER, not an env read in
    # the body, so a test can name a synthetic policy without setting a
    # process-wide variable. This is the same seam that keeps every
    # microarchitecture test in this campaign hermetic.
    putEnv(DefaultTargetFloorEnvVar, "x86-64-v4")
    defer: delEnv(DefaultTargetFloorEnvVar)
    # The env says v4; the explicitly passed policy must win regardless.
    check effectiveTargetFloor(mlNone, mlX86_64_v2) == mlX86_64_v2

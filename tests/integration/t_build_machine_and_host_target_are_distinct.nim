## PMC-4 deliverable 4, made executable — the BUILD machine and the HOST
## target are two different things.
##
## ## The failure this prevents
##
## Until now "host" meant both "the machine running `repro`" and "what the
## artifacts must run on". Those coincide on a native build, which is why one
## word has worked. They stop coinciding the moment a cross build exists, and
## the failure is silent in both directions:
##
##   * Resolve a NATIVE build tool against the host target and a cross build
##     cannot find its own compiler -- you have told reprobuild the machine
##     executing gcc lacks instructions gcc's binary actually uses.
##   * Resolve a PRODUCED artifact against the build machine and it silently
##     inherits capabilities the target machine does not have. That is a SIGILL
##     on someone else's computer, arbitrarily far from this decision. It is
##     also exactly why Spack binaries are famous for not running elsewhere.
##
## Neither reports an error at the point of the mistake, so the split has to be
## structural rather than a convention people remember.
##
## ## Hermetic by construction
##
## `targetForRole` and `isCrossTargeted` are pure functions of two targets
## passed in. No machine is consulted, so every property below is checkable on
## hardware that can only ever BE one of the two -- which is the whole point,
## since a box cannot be both a v2 and a v3 machine to prove the routing works.

import std/[os, unittest]

import repro_dsl_stdlib/packages_schema
import repro_home_apply/package_catalog

let
  v3Machine = initPlatformTarget(pcX86_64, mlX86_64_v3)
  v1Target  = initPlatformTarget(pcX86_64, mlX86_64_v1)
  v3Plus    = initPlatformTarget(pcX86_64, mlX86_64_v3, {cfAvx512f})

suite "build machine vs host target":

  test "a native build has them equal, and is not cross":
    check not isCrossTargeted(v3Machine, v3Machine)
    check targetForRole(trBuildMachine, v3Machine, v3Machine) == v3Machine
    check targetForRole(trHostTarget, v3Machine, v3Machine) == v3Machine

  test "lowering the host target makes the build cross":
    # The ordinary, desirable case: a capable machine producing conservative
    # artifacts so one cache entry serves the fleet.
    check isCrossTargeted(v3Machine, v1Target)

  test "native tools resolve against the BUILD machine, not the host target":
    # The load-bearing routing property. Building v1 artifacts on a v3 machine
    # must NOT restrict the compiler that runs during the build -- it executes
    # here, on v3 silicon.
    check targetForRole(trBuildMachine, v3Machine, v1Target) == v3Machine
    check targetForRole(trBuildMachine, v3Machine, v1Target).level ==
      mlX86_64_v3

  test "produced artifacts resolve against the HOST target, not the machine":
    # The other direction, and the dangerous one. If this ever returned the
    # build machine, artifacts would silently inherit v3 while claiming v1.
    check targetForRole(trHostTarget, v3Machine, v1Target) == v1Target
    check targetForRole(trHostTarget, v3Machine, v1Target).level ==
      mlX86_64_v1

  test "the two roles never collapse onto one another when they differ":
    # Stated as its own property because every silent failure in this area is
    # some version of "the wrong one was used and nothing noticed".
    check targetForRole(trBuildMachine, v3Machine, v1Target) !=
          targetForRole(trHostTarget, v3Machine, v1Target)

  test "features participate, but only once the HOST states them":
    # PMC-3 made the level sugar over a feature set, so a split comparing only
    # levels would treat a feature difference as native and silently share
    # artifacts. But "the host said nothing" is not a difference: PMC-3 also
    # made features DECLARED rather than probed, so an unstated host answers
    # `{}` while `buildMachineTarget` measures real silicon. Comparing those
    # raw values reported CROSS on an ordinary machine with no configuration,
    # which is what this pair of cases now pins apart.
    #
    # host STATES a different feature set -> cross.
    check isCrossTargeted(v3Machine, v3Plus)
    # host states NOTHING -> native, however capable the build machine is.
    check not isCrossTargeted(v3Plus, v3Machine)
    # Routing is unaffected either way: the host target is still returned.
    check targetForRole(trHostTarget, v3Plus, v3Machine) == v3Machine

  test "a higher host target is cross too, not an error":
    # Cross-compiling FOR a more capable machine is legitimate. What matters is
    # that the two stop being interchangeable, not which is larger.
    check isCrossTargeted(v1Target, v3Machine)

  test "the build machine is a measurement, not an override":
    # REPRO_HOST_* describes what you are building FOR. If it also rewrote what
    # this machine IS, a cross build could not resolve its own toolchain.
    let before = buildMachineTarget()
    putEnv("REPRO_HOST_MICROARCH_LEVEL", "x86-64-v1")
    defer: delEnv("REPRO_HOST_MICROARCH_LEVEL")
    check buildMachineTarget() == before          # unmoved
    check hostTarget().level == mlX86_64_v1       # moved
    # ...and when that moves the host BELOW the build machine, it is a cross
    # build. Guarded because `baselineMicroarchLevel(x86_64)` is itself v1
    # (PMC-2), so on a host that has not declared a higher level there is
    # nothing to move and nothing to observe -- asserting unconditionally
    # would pin an accident of this machine's baseline.
    if before.level != mlX86_64_v1:
      check isCrossTargeted(buildMachineTarget(), hostTarget())

  test "detectHostTarget still means the HOST target":
    # The established name, kept so existing callers (the binary-cache compat
    # check, the PMC-2/PMC-3 tests) keep working. If this ever drifted to mean
    # the build machine, published artifacts would start being keyed by the
    # wrong axis.
    putEnv("REPRO_HOST_MICROARCH_LEVEL", "x86-64-v2")
    defer: delEnv("REPRO_HOST_MICROARCH_LEVEL")
    check detectHostTarget() == hostTarget()
    check detectHostTarget().level == mlX86_64_v2

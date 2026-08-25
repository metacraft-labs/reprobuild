## PMC-6 — one host-target authority, not two.
##
## ## What was wrong
##
## PMC-4 decided the microarchitecture rides the EXISTING host axis, then
## shipped a second axis beside it. Two independent cross-ness predicates
## resulted, driven by different inputs and connected by nothing:
##
##   * the engine's `resolvedTargetTriple() != "native"`, from the
##     `targetTriple` solver variant;
##   * this campaign's `isCrossTargeted(...)`, from `REPRO_HOST_*`.
##
## They agreed only because both defaulted to native. Lowering
## `REPRO_HOST_MICROARCH_LEVEL` already made a build cross for artifact
## SELECTION while it stayed native for cache KEYING, with nothing reporting
## the contradiction.
##
## ## The seam, and why it is a closure
##
## `targetTriple` is a solver variant; resolving it needs the solver, and
## `package_catalog` must not import it — the same layering rule that made the
## build engine take a `TargetTripleResolver` closure rather than reaching for
## `repro_dsl_stdlib` itself. So the CLI, the only layer that sees both, wires
## a `HostTargetResolver` here exactly as it already wires one there.
##
## The result is ONE decision point. These tests pin that: when a resolver is
## wired it is authoritative, and when it is not the environment default is
## unchanged from before PMC-6 — so a library or test consumer sees no
## behaviour change at all.

import std/[os, unittest]

import repro_dsl_stdlib/packages_schema
import repro_home_apply/package_catalog

suite "PMC-6 — the wired resolver is the single host-target authority":

  setup:
    # Every case starts from "nobody wired one".
    setHostTargetResolver(nil)
    delEnv("REPRO_HOST_MICROARCH_LEVEL")
    delEnv("REPRO_HOST_CPU_FEATURES")

  teardown:
    setHostTargetResolver(nil)
    delEnv("REPRO_HOST_MICROARCH_LEVEL")
    delEnv("REPRO_HOST_CPU_FEATURES")

  test "with no resolver, behaviour is exactly the pre-PMC-6 environment one":
    # The compatibility guarantee. A library consumer that never wires
    # anything must not notice this milestone happened.
    check hostTarget() == environmentHostTarget()
    check not isCrossTargeted(buildMachineTarget(), hostTarget())

  test "a wired resolver is authoritative":
    setHostTargetResolver(proc(): PlatformTarget =
      initPlatformTarget(pcX86_64, mlX86_64_v2))
    check hostTarget().level == mlX86_64_v2

  test "the resolver WINS over the environment, so there is one answer":
    # The load-bearing case. Before PMC-6 these were two channels that could
    # disagree; now the environment is an input the resolver may consult, not
    # a rival authority that silently overrides it.
    putEnv("REPRO_HOST_MICROARCH_LEVEL", "x86-64-v4")
    setHostTargetResolver(proc(): PlatformTarget =
      initPlatformTarget(pcX86_64, mlX86_64_v2))
    check hostTarget().level == mlX86_64_v2
    # ...and the environment value is still readable on its own, which is what
    # lets a CLI resolver COMPOSE the two rather than reimplement the parsing.
    check environmentHostTarget().level == mlX86_64_v4

  test "a resolver can compose the environment rather than ignore it":
    # The shape the CLI actually uses: prefer the variant, fall back to the
    # environment. Composing keeps ONE copy of the parsing and refusal rules.
    putEnv("REPRO_HOST_MICROARCH_LEVEL", "x86-64-v3")
    setHostTargetResolver(proc(): PlatformTarget = environmentHostTarget())
    check hostTarget().level == mlX86_64_v3

  test "unwiring restores the default":
    setHostTargetResolver(proc(): PlatformTarget =
      initPlatformTarget(pcX86_64, mlX86_64_v4))
    check hostTarget().level == mlX86_64_v4
    setHostTargetResolver(nil)
    check hostTarget() == environmentHostTarget()

  test "the resolver moves cross-ness too, not only the value":
    # If `isCrossTargeted` still read the environment directly it would answer
    # "native" here while selection resolved against v2 -- exactly the split
    # this milestone closes.
    setHostTargetResolver(proc(): PlatformTarget =
      initPlatformTarget(pcX86_64, mlX86_64_v2))
    let b = buildMachineTarget()
    if b.level != mlX86_64_v2:
      check isCrossTargeted(b, hostTarget())

suite "PMC-6 — dependencies route to the target that must satisfy them":

  test "native build tools resolve against the BUILD machine":
    check targetRoleForDepKind("dkNative") == trBuildMachine
    check targetRoleForDepKind("nativeBuildDeps") == trBuildMachine

  test "linked and runtime deps resolve against the HOST target":
    check targetRoleForDepKind("dkBuild") == trHostTarget
    check targetRoleForDepKind("dkRuntime") == trHostTarget

  test "an unrecognised kind defaults to the HOST target, not the machine":
    # The direction matters. Defaulting to the build machine would let an
    # artifact silently inherit capabilities the target lacks -- a SIGILL
    # elsewhere. Defaulting to the host target can only be too conservative,
    # and too conservative fails loudly here instead of quietly there.
    check targetRoleForDepKind("dkSomethingNew") == trHostTarget
    check targetRoleForDepKind("") == trHostTarget

  test "the routing actually returns different targets on a cross build":
    # Ties the role decision to the values, so this cannot pass while
    # `targetForRole` has been broken to return one of them twice.
    let buildT = initPlatformTarget(pcX86_64, mlX86_64_v3)
    let hostT = initPlatformTarget(pcX86_64, mlX86_64_v1)
    check targetForRole(targetRoleForDepKind("dkNative"), buildT, hostT) == buildT
    check targetForRole(targetRoleForDepKind("dkRuntime"), buildT, hostT) == hostT
    check targetForRole(targetRoleForDepKind("dkNative"), buildT, hostT) !=
          targetForRole(targetRoleForDepKind("dkRuntime"), buildT, hostT)

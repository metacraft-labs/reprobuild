## NLF-PROP-5 — a feature demanded by a host tool does not leak into the
## shipped graph, ON A NATIVE BUILD.
##
## Named-Lock-Files NLF-M7. Corpus case **NLF-PROP-5**: "Cargo's resolver-v1
## bug does not reproduce. **MUST run on a NATIVE build — a cross fixture
## separates them for the wrong reason and passes vacuously.**"
##
## ## The instruction, and why it is the whole design of this file
##
## Cargo's resolver-v1 defect is feature unification across the host/target
## boundary: a build-dependency that enables a feature turns that feature on
## for the normal dependency too, because there is one feature set for the
## whole graph. Named lock files prevent it by there being two graphs.
##
## A CROSS fixture would separate the two graphs anyway — different platforms,
## different solves, different everything — so it would report a pass no
## matter what the lock-file mechanism did. The separation has to come from
## the DESIGNATION and from nothing else, so:
##
##   * both generation requests carry the **same platform**, and the first
##     test asserts that they do rather than leaving it to be inferred from
##     the fixture;
##   * the two graphs differ in exactly one thing — which packages designation
##     put in them.
##
## ## What "a feature" is here
##
## A bool variant, `tls`, defaulting to `false`. The host tool DEMANDS
## `tls = true` (a `vpOverride` contribution, the priority an in-scope
## `c.override v` produces). The shipped binary demands nothing. Under two
## lock files the demand reaches the host graph and stops; under one it
## reaches the single graph everything shares, which is the leak.
##
## The variant also GATES a dependency, so the leak has a consequence in the
## SOLVED VERSIONS and not only in a variant assignment: the two arms demand
## disjoint ranges of `libcore`, so which arm fired is readable off the pinned
## version. A test that checked only the variant value would pass against an
## implementation that partitioned the assignment but not the closure it
## implies.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## See `nlf_m7_fixture`'s header, which states the policy in full. The variant
## resolution is a real clingo solve over a real encoded universe, not a
## lookup in a table this test wrote.

import std/[tables, unittest]

import repro_lock_gen

import ./nlf_m7_fixture

const
  Tablegen = "tablegen"
  App = "app"
  LibShared = "libshared"
  LibCore = "libcore"
  TlsVariant = "tls"
  TargetRuntime = "targetRuntime"

proc workspace(): Recipe =
  Recipe(
    packages: @[
      # The build-machine tool, which wants TLS.
      RecipePackage(name: Tablegen, versions: @["1.0.0"],
        deps: @[dep(LibShared, ">=1.0 <2.0")],
        demands: @[(variant: TlsVariant, value: "true")]),
      # The shipped binary, which does not.
      RecipePackage(name: App, versions: @["1.0.0"],
        deps: @[dep(LibShared, ">=1.0 <2.0")]),
      # The library both of them use. Which `libcore` it needs is gated on
      # the variant, and the two arms are MUTUALLY EXCLUSIVE — the same shape
      # `t_variant_conditioned_uses_over_approximated` uses, for the same
      # reason. A gated dependency constrains the RANGE, not the package's
      # presence in the solved graph (`repro_solver/version_encoder`'s header,
      # item 5), so asserting that a package is ABSENT when its arm is dormant
      # would be asserting something the encoder does not promise. Two
      # disjoint arms make the VERSION the discriminator instead, and a
      # version the encoder does promise.
      RecipePackage(name: LibShared, versions: @["1.4.0"],
        deps: @[
          dep(LibCore, ">=2.0 <3.0", dpTarget, TlsVariant, "true"),
          dep(LibCore, ">=1.0 <2.0", dpTarget, TlsVariant, "false")]),
      RecipePackage(name: LibCore, versions: @["1.1.0", "1.5.0", "2.2.0"])],
    artifacts: @[
      RecipeArtifact(name: Tablegen, package: Tablegen,
        lockFile: HostToolsLockFileName),
      RecipeArtifact(name: App, package: App, lockFile: TargetRuntime)],
    boolVariants: @[TlsVariant])

suite "NLF-PROP-5 no feature leak across the host/target boundary":

  setup:
    resetLockFileDeclarations()
    discard declareLockFile(TargetRuntime, description = "What we ship.")

  test "this is a NATIVE build — both graphs are solved for one platform":
    # The corpus case's own precondition, asserted rather than assumed. If
    # these two ever diverge the rest of this file stops being evidence for
    # anything about lock files.
    let reg = startRegistry("prop5-native")
    try:
      let prop = propagationOf(workspace())
      let hostReq = reg.request(
        declsFor(workspace(), prop, HostToolsLockFileName), lsHighest)
      let targetReq = reg.request(
        declsFor(workspace(), prop, TargetRuntime), lsHighest)
      check hostReq.platform == targetReq.platform
      check hostReq.platform == currentPlatformId()
    finally:
      reg.shutdown()

  test "the host tool's feature demand reaches the host graph":
    let reg = startRegistry("prop5-host")
    try:
      let solved = reg.solvePerLockFile(workspace(), lsHighest)
      check solved[HostToolsLockFileName].solvedVariant(TlsVariant) == "true"
      # And the demand is live: it selects the TLS arm's `libcore` range.
      check solved[HostToolsLockFileName].solvedVersions()[LibCore] == "2.2.0"
    finally:
      reg.shutdown()

  test "and does NOT reach the shipped graph":
    # The property. Same platform, same library, same solver — and the shipped
    # graph keeps the default because the demand was never in its closure.
    let reg = startRegistry("prop5-target")
    try:
      let solved = reg.solvePerLockFile(workspace(), lsHighest)
      check solved[TargetRuntime].solvedVariant(TlsVariant) == "false"
      # And the consequence: the shipped graph takes the non-TLS arm, so its
      # `libcore` is a `1.x`. Under the leak it would be the `2.2.0` the host
      # tool's demand selects.
      check solved[TargetRuntime].solvedVersions()[LibCore] == "1.5.0"
      # The shared library IS in both graphs, so the two are not separated by
      # simply having nothing in common.
      check solved[HostToolsLockFileName].solvedVersions().hasKey(LibShared)
      check solved[TargetRuntime].solvedVersions().hasKey(LibShared)
    finally:
      reg.shutdown()

  test "under ONE lock file the same recipe leaks — resolver-v1 reproduced":
    # The control, and the reason the case is not vacuous. With the two
    # designations ignored, the host tool's demand and the shipped binary land
    # in one graph, the single `tls` assignment goes to `true`, and the
    # shipped closure acquires the TLS arm's `libcore` — a version nothing in
    # it asked for. That is Cargo's resolver-v1 bug, reproduced here on
    # purpose so the test above is measured against a graph that CAN exhibit it.
    let reg = startRegistry("prop5-control")
    try:
      let unified = reg.solveUnified(workspace(), lsHighest)
      check unified.solvedVariant(TlsVariant) == "true"
      check unified.solvedVersions().hasKey(App)
      # The shipped binary's own graph now carries the TLS arm's `libcore` —
      # a version nothing in the shipped closure asked for.
      check unified.solvedVersions()[LibCore] == "2.2.0"
    finally:
      reg.shutdown()

  test "the two graphs have different identities, so their edges key apart":
    let reg = startRegistry("prop5-identity")
    try:
      let solved = reg.solvePerLockFile(workspace(), lsHighest)
      check solved[HostToolsLockFileName].lockIdentity !=
        solved[TargetRuntime].lockIdentity
    finally:
      reg.shutdown()

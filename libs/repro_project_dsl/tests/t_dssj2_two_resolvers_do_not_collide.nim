## Shared-Development-Services J-2 — THE RESOLVER IS PER-SERVICE: two
## shared services and two `<package>.<activity>.<service>.shared()`
## calls in ONE recipe do not collide.
##
## THE FIXTURE THE CAMPAIGN OWED, named in the round that could not
## close the finding with the one-resolver fixture it had: "A reviewer
## wanting it closed should add a second shared service to the owner's
## recipe and a second `.shared()` to the consumer's; that is the
## fixture that would redden it."
##
## WHY ONE RESOLVER COULD NOT PROVE THIS. Every assertion the existing
## `t_dss11_resolutions_reach_the_dev_env_artifact` makes about a
## resolution passes for an implementation that holds ONE resolution in
## a scalar, keys the deposit on the CONSUMER rather than on the
## service, or announces only the first. §4.6 / D-SS11 make the resolver
## "the CROSS-PROCESS BOUNDARY for §5's contributions", so if the
## boundary is not per-service then one consumer's two contributions
## reach one service -- and a fixture user's e-mail address registered
## as an OIDC application is exactly the laundering D-SS12 refuses.
##
## WHAT THIS FILE ASSERTS, each the thing one resolver cannot support:
##
##   * TWO resolutions are recorded for one `enable`, each naming its
##     own activity and service;
##   * each resolver's CONTRIBUTIONS reach only its own point -- no
##     member of one appears anywhere in the other;
##   * the two owner services get DISTINCT INSTANCE KEYS, through the
##     real `serviceInstanceKey`;
##   * the two owner services' REGISTRATIONS are disjoint, and each
##     carries only its own point;
##   * both survive the artifact codec, so the second resolution is not
##     the one a cached dev-env drops.
##
## MOCK POLICY -- NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED.
## A real two-activity owner and a real consumer whose single `enable`
## makes two real resolver calls, expanded by the real DSL macro;
## resolutions from the real `buildPackageDevEnv`; instance keys from the
## real `serviceInstanceKey` over the real `discoverServiceScopeContext`;
## the artifact from the real `artifactFromDevEnvResult` and its real SSZ
## codec.

import std/[algorithm, os, strutils, unittest]

import repro_project_dsl
import repro_provider_runtime
import repro_dev_env_artifacts
import repro_resources/service_identity
import repro_resources/service_registry

import dssj2_two_resolver_fixtures

proc pkgDef(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "fixture drift: " & name & " missing")

proc fixtureRoot(): string =
  ## Per-process, because every case of this binary runs as its own
  ## process in the suite and a fixed path would be shared between
  ## concurrent cases (`scripts/check_fixed_test_scratch_dirs.py`).
  getTempDir() / ("dssj2-two-resolver-" & $getCurrentProcessId())

proc devEnvRequest(pkg: PackageDef; activity: string):
    ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider",
    entryPointId: pkg.packageName & ".dev-env",
    entryPointBodyHash: pkg.packageName & ".build.v1",
    reason: girExplicitUserRequest,
    arguments: fixtureRoot(),
    namespace: "project-" & pkg.packageName,
    activity: activity)

proc ownerDevEnv(activity: string): DevEnvResult =
  clearRegisteredServices(Dssj2OwnerName)
  let pkg = pkgDef(Dssj2OwnerName)
  buildPackageDevEnv(pkg, devEnvRequest(pkg, activity),
    devEnvDssj2OwnerPackage)

proc stackDevEnv(): DevEnvResult =
  clearRegisteredServices(Dssj2StackName)
  let pkg = pkgDef(Dssj2StackName)
  buildPackageDevEnv(pkg, devEnvRequest(pkg, "stack"),
    devEnvDssj2StackPackage)

proc resolutionFor(res: DevEnvResult; service: string):
    DevEnvSharedResolution =
  for resolution in res.sharedResolutions:
    if resolution.serviceName == service:
      return resolution
  raise newException(ValueError,
    "no shared resolution for `" & service & "`; the recipe makes two " &
    "resolver calls, so a missing one is the collision this file " &
    "exists to detect, not a fixture detail")

proc serviceDefFor(name: string): DslServiceDef =
  for svc in registeredServices(Dssj2OwnerName):
    if svc.serviceName == name:
      return svc
  raise newException(ValueError, "no registered service named " & name)

suite "shared resolver ownership belongs to one dev-env evaluation":
  test "switching handle arguments replaces the previous ownership":
    let pkg = pkgDef("dssj2Switching")
    defer: Dssj2SwapHandles = false
    for swapped in [false, true, false]:
      Dssj2SwapHandles = swapped
      let env = buildPackageDevEnv(pkg, devEnvRequest(pkg, "first"),
        devEnvDssj2SwitchingPackage)
      let artifact = decodeDevEnvArtifact(encodeDevEnvArtifact(
        artifactFromDevEnvResult(env)))
      var services: seq[string] = @[]
      for resolution in artifact.sharedResolutions:
        services.add(resolution.serviceName)
      check services == @[(if swapped: "proxy" else: "idp")]

  test "a resolver absent from this evaluation is not a global resolver":
    let pkg = pkgDef("dssj2OptionalGlobal")
    defer: Dssj2IncludeGlobal = true
    for included in [true, false, true]:
      Dssj2IncludeGlobal = included
      let env = buildPackageDevEnv(pkg, devEnvRequest(pkg, "ordinary"),
        devEnvDssj2OptionalGlobalPackage)
      check env.sharedResolutions.len == (if included: 1 else: 0)

  test "binding a retained handle preserves its resolution and contributions":
    let pkg = pkgDef("dssj2Retained")
    defer: Dssj2ResolveRetained = true
    for resolveAgain in [true, false, false]:
      Dssj2ResolveRetained = resolveAgain
      let env = buildPackageDevEnv(pkg, devEnvRequest(pkg, "stack"),
        devEnvDssj2RetainedPackage)
      check env.sharedResolutions.len == 1
      if env.sharedResolutions.len == 1:
        check env.sharedResolutions[0].serviceName == "idp"
        check env.sharedResolutions[0].contributionMembers == @[Dssj2IdpMember]

suite "J-2: ONE recipe, TWO resolvers, and both are recorded":

  test "the consumer's single `enable` records TWO resolutions":
    # THE POSITIVE CONTROL for the whole file. An implementation holding
    # one resolution in a scalar, or suppressing every resolution after
    # the first, fails here and nowhere else -- which is precisely why
    # the one-resolver fixture could not close the finding.
    let res = stackDevEnv()
    check res.sharedResolutions.len == 2
    var services: seq[string] = @[]
    for resolution in res.sharedResolutions:
      services.add(resolution.serviceName)
    services.sort()
    check services == @[Dssj2IdpService, Dssj2ProxyService]

  test "each resolution names its OWN activity, not the other's":
    # The middle component of §4.6's three-part spelling, which is the
    # one a per-service-but-not-per-activity resolver would get wrong.
    let res = stackDevEnv()
    check resolutionFor(res, Dssj2IdpService).activityName ==
      Dssj2SsoActivity
    check resolutionFor(res, Dssj2ProxyService).activityName ==
      Dssj2EdgeActivity

  test "both resolutions name ONE owner and ONE consumer":
    # The control for the two cases above: they differ in the service
    # and the activity and in NOTHING else, so a difference asserted
    # below is a difference the resolver made.
    let res = stackDevEnv()
    for resolution in res.sharedResolutions:
      check resolution.ownerPackage == Dssj2OwnerName
      check resolution.consumerPackage == Dssj2StackName

suite "J-2: each resolver reaches ONLY its own service -- no cross-talk":

  test "the idp resolution carries the idp's point and member only":
    let resolution = resolutionFor(stackDevEnv(), Dssj2IdpService)
    check resolution.contributionPoints == @[Dssj2RelyingParties]
    check resolution.contributionMembers == @[Dssj2IdpMember]
    check resolution.contributionMemberPoints == @[Dssj2RelyingParties]
    # AND NOT the other service's, asserted on the point AND on the
    # member because either alone could be satisfied by half a leak.
    check Dssj2Sites notin resolution.contributionPoints
    check Dssj2ProxyMember notin resolution.contributionMembers

  test "the proxy resolution carries the proxy's point and member only":
    let resolution = resolutionFor(stackDevEnv(), Dssj2ProxyService)
    check resolution.contributionPoints == @[Dssj2Sites]
    check resolution.contributionMembers == @[Dssj2ProxyMember]
    check resolution.contributionMemberPoints == @[Dssj2Sites]
    check Dssj2RelyingParties notin resolution.contributionPoints
    check Dssj2IdpMember notin resolution.contributionMembers

  test "neither member appears ANYWHERE in the other resolution":
    # The strongest form, over the whole record rather than over the
    # fields the two cases above happen to name: a leak into
    # `contributionSites`, `contributionOperations` or any other
    # parallel list would pass both of them.
    let res = stackDevEnv()
    let idp = resolutionFor(res, Dssj2IdpService)
    let proxy = resolutionFor(res, Dssj2ProxyService)
    proc allText(r: DevEnvSharedResolution): string =
      (r.contributionPoints & r.contributionOperations &
        r.contributionPrecedences & r.contributionSites &
        r.contributionMemberPoints & r.contributionMembers).join("\u0001")
    check Dssj2ProxyMember notin allText(idp)
    check Dssj2IdpMember notin allText(proxy)
    # ... and the positive control for this extractor: each DOES carry
    # its own member, so a predicate matching nothing says so.
    check Dssj2IdpMember in allText(idp)
    check Dssj2ProxyMember in allText(proxy)

suite "J-2: the two shared services get DISTINCT INSTANCE KEYS":

  test "the two instance keys differ, and differ in the IDENTITY":
    # §4.4: state is keyed by identity. Two shared services whose keys
    # collapsed would share a state root, a lease and a registration
    # set -- so this is the assertion a mutation keying the resolver or
    # the instance on something SHARED (the owner package, the
    # consumer, the workspace) would redden.
    discard ownerDevEnv(Dssj2SsoActivity)
    let idp = serviceDefFor(Dssj2IdpService)
    discard ownerDevEnv(Dssj2EdgeActivity)
    let proxy = serviceDefFor(Dssj2ProxyService)
    let root = fixtureRoot()
    createDir(root)
    let ctx = discoverServiceScopeContext(root)
    let idpKey = serviceInstanceKey(idp, ctx, environment = "development")
    let proxyKey = serviceInstanceKey(proxy, ctx,
      environment = "development")
    check idpKey != proxyKey
    check idpKey.identity == Dssj2IdpStableId
    check proxyKey.identity == Dssj2ProxyStableId
    check encodeServiceInstanceKey(idpKey) !=
      encodeServiceInstanceKey(proxyKey)
    # The control: everything OTHER than the identity is the same, so
    # the difference above is the identity and not the scope, the
    # environment or the scope key.
    check idpKey.scope == proxyKey.scope
    check idpKey.scopeKey == proxyKey.scopeKey
    check idpKey.environment == proxyKey.environment
    check idpKey.identityKind == proxyKey.identityKind

  test "the declared stable ids are what the recipe wrote":
    # `identity stable` takes a STRING LITERAL, so the fixture cannot
    # splice its own consts there. This is the case that says the two
    # agree instead of a reader comparing them by eye.
    discard ownerDevEnv(Dssj2SsoActivity)
    check serviceDefFor(Dssj2IdpService).identity.stableId ==
      Dssj2IdpStableId
    discard ownerDevEnv(Dssj2EdgeActivity)
    check serviceDefFor(Dssj2ProxyService).identity.stableId ==
      Dssj2ProxyStableId

suite "J-2: the two services' REGISTRATIONS are disjoint":

  test "each owner service converges its own point and no other":
    proc serviceNamed(res: DevEnvResult; name: string):
        DevEnvServiceMetadata =
      for svc in res.services:
        if svc.name == name:
          return svc
      raise newException(ValueError, "no service named " & name)
    let idp = serviceNamed(ownerDevEnv(Dssj2SsoActivity), Dssj2IdpService)
    check idp.registrationPoints.len == 1
    check idp.registrationPoints[0].endsWith("." & Dssj2RelyingParties)
    let proxy = serviceNamed(ownerDevEnv(Dssj2EdgeActivity),
      Dssj2ProxyService)
    check proxy.registrationPoints.len == 1
    check proxy.registrationPoints[0].endsWith("." & Dssj2Sites)
    check idp.registrationPoints[0] != proxy.registrationPoints[0]

  test "selecting one activity routes ONE service, not both":
    # The activity gate, measured here because two shared services in
    # two activities is the first fixture that can tell "gated" from
    # "there is only one".
    check ownerDevEnv(Dssj2SsoActivity).services.len == 1
    check ownerDevEnv(Dssj2EdgeActivity).services.len == 1
    check ownerDevEnv(Dssj2SsoActivity).services[0].name ==
      Dssj2IdpService
    check ownerDevEnv(Dssj2EdgeActivity).services[0].name ==
      Dssj2ProxyService

suite "J-2: BOTH resolutions survive the artifact codec":

  test "the artifact carries two resolutions and the codec round-trips them":
    # D-SS11 made the artifact hop non-optional because a cached dev-env
    # edge is answered from the artifact. With two resolutions there is
    # a second failure available that one could not expose: a codec that
    # wrote the list and read back only its head.
    let artifact = artifactFromDevEnvResult(stackDevEnv())
    check artifact.sharedResolutions.len == 2
    let decoded = decodeDevEnvArtifact(encodeDevEnvArtifact(artifact))
    check decoded.sharedResolutions.len == 2
    var pairs: seq[string] = @[]
    for resolution in decoded.sharedResolutions:
      check resolution.contributionMembers.len == 1
      pairs.add(resolution.serviceName & "=" &
        resolution.contributionMembers[0])
    pairs.sort()
    check pairs == @[Dssj2IdpService & "=" & Dssj2IdpMember,
                     Dssj2ProxyService & "=" & Dssj2ProxyMember].sorted()

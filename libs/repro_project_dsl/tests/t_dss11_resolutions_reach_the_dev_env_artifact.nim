## Shared-Development-Services D-SS11 (§4.6) — the OWNER's lift carries
## its contribution points, and a CONSUMER's resolver call reaches the
## dev-env artifact.
##
## These are the two halves of §4.6's third part that live inside one
## process. The cross-process half -- a deposit in the instance's
## identity-keyed store, read by the owner's converge -- is
## `libs/repro_resources/tests/
## t_dss11_cross_process_contribution_store.nim` for its algebra and
## `tests/integration/
## t_dss11_cross_process_contribution_reaches_the_instance.nim` for the
## real two-process case.
##
## WHAT L9 MEASURED, AND WHY THE ARTIFACT HOP EXISTS. L9's F2 found
## `contributionMemberAttribution` with exactly one non-test caller,
## inside the owner's own provider process, so "a cross-repo
## `contribute:` would compile, look wired, and do nothing". A resolver
## that recorded its contributions in the CONSUMER's
## `dslPortContributions` would have the identical defect: the fold
## would show the member in the consumer's process and the owner's
## instance would never see it. So a resolver records a RESOLUTION, the
## resolution travels on the artifact, and this file is where "it
## travels" is measured rather than asserted in a comment.
##
## AND WHY THE ARTIFACT RATHER THAN THE PROVIDER WIRE ALONE. A cached
## dev-env edge is answered from the artifact without re-running the
## provider, so a resolution that lived only on the provider wire would
## be deposited on a cold evaluation and silently not on a cached one.
## The round-trip suite below is what makes that claim checkable.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED.
## The fixture is a real multi-package recipe module expanded by the
## real DSL macro; the dev-env result comes from the real
## `buildPackageDevEnv`; the interface records come from the real
## `toProjectInterface`; the artifact is produced by the real
## `artifactFromDevEnvResult` and round-tripped through the real codec.
## The one constructed value in this file is the `ProjectInterface` in
## the fingerprint suite, and it is constructed because the property
## under test is "a point added or removed MOVES the digest", which
## needs two interfaces differing in exactly that -- a pair of fixture
## recipes would differ in their source locations too.

import std/[os, strutils, unittest]

import repro_project_dsl
import repro_provider_runtime
import repro_dev_env_artifacts
import repro_interface_artifacts
import repro_resources/service_attach

import dss11_resolver_fixtures

const
  FixtureRoot = "/tmp/dss11-resolver-fixture-root"
  OwnerPackage = "dss11Owner"
  LoudPackage = "dss11Loud"
  QuietPackage = "dss11Quiet"
  UnresolvedPackage = "dss11Unresolved"

proc pkgDef(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "fixture drift: " & name & " missing")

proc devEnvRequest(pkg: PackageDef; activity: string):
    ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider",
    entryPointId: pkg.packageName & ".dev-env",
    entryPointBodyHash: pkg.packageName & ".build.v1",
    reason: girExplicitUserRequest,
    arguments: FixtureRoot,
    namespace: "project-" & pkg.packageName,
    activity: activity)

proc ownerDevEnv(): DevEnvResult =
  clearRegisteredServices(OwnerPackage)
  let pkg = pkgDef(OwnerPackage)
  buildPackageDevEnv(pkg, devEnvRequest(pkg, "sso"), devEnvDss11OwnerPackage)

proc loudDevEnv(): DevEnvResult =
  clearRegisteredServices(LoudPackage)
  let pkg = pkgDef(LoudPackage)
  buildPackageDevEnv(pkg, devEnvRequest(pkg, "stack"),
    devEnvDss11LoudPackage)

proc quietDevEnv(): DevEnvResult =
  clearRegisteredServices(QuietPackage)
  let pkg = pkgDef(QuietPackage)
  buildPackageDevEnv(pkg, devEnvRequest(pkg, "ide"), devEnvDss11QuietPackage)

proc unresolvedDevEnv(): DevEnvResult =
  clearRegisteredServices(UnresolvedPackage)
  let pkg = pkgDef(UnresolvedPackage)
  buildPackageDevEnv(pkg, devEnvRequest(pkg, "bare"),
    devEnvDss11UnresolvedPackage)

proc interfaceOf(name: string): ProjectInterface =
  toProjectInterface(pkgDef(name))

proc serviceRow(pi: ProjectInterface; name: string): InterfaceService =
  for svc in pi.publicServices:
    if svc.name == name:
      return svc
  raise newException(ValueError, "no lifted service named " & name)

proc resolutionFor(res: DevEnvResult; service: string):
    DevEnvSharedResolution =
  for resolution in res.sharedResolutions:
    if resolution.serviceName == service:
      return resolution
  raise newException(ValueError, "no shared resolution for " & service)

suite "D-SS11 §4.6 — the owner's LIFT carries its contribution points":
  test "the lifted service row names the points the body converges":
    let row = serviceRow(interfaceOf(OwnerPackage), "idp")
    check row.contributionPoints == @[Dss11RelyingParties, Dss11FixtureUsers]
    check row.identityStableId == Dss11IdpStableId

  test "a service that converges nothing lifts an EMPTY point list":
    # The control. Without it every assertion above would pass for an
    # implementation that filled the field from the activity's `config:`
    # keys rather than from `converge`.
    let row = serviceRow(interfaceOf(OwnerPackage), "plain")
    check row.contributionPoints.len == 0
    check row.identityStableId == Dss11PlainStableId

  test "the DSL registry and the lifted artifact agree about the points":
    # Two readings of one declaration, compared rather than trusted --
    # the rule L8's artifact-vs-interface refusal is built on.
    var registered: seq[string] = @[]
    for svc in registeredServiceInterfaces():
      if svc.packageName == OwnerPackage and svc.name == "idp":
        registered = svc.contributionPoints
    check registered == @[Dss11RelyingParties, Dss11FixtureUsers]
    check registered == serviceRow(interfaceOf(OwnerPackage),
      "idp").contributionPoints

suite "D-SS11 §4.6 — the points reach the ATTACH-DECISION snapshot":
  test "the snapshot carries one contribution-point member per point":
    let snapshot = serviceInterfaceSnapshot(interfaceOf(OwnerPackage), "idp")
    check contributionPointsOf(snapshot) ==
      @[Dss11RelyingParties, Dss11FixtureUsers]
    var kinds = 0
    for member in snapshot.members:
      if member.kind == smkContributionPoint:
        inc kinds
    check kinds == 2

  test "a service that converges nothing has no such member":
    let snapshot = serviceInterfaceSnapshot(interfaceOf(OwnerPackage),
      "plain")
    check contributionPointsOf(snapshot).len == 0

  test "dropping a point MOVES the per-service interface fingerprint":
    # §4.3 decides attach-or-warn on this digest, and §4.6 makes the
    # points part of what a consumer compiles against -- so an instance
    # that stopped converging a point its consumer contributes to has to
    # be a difference the decision can see. Measured in both directions
    # over two interfaces differing in exactly the point list.
    var withPoints = interfaceOf(OwnerPackage)
    var withoutPoints = interfaceOf(OwnerPackage)
    for svc in withoutPoints.publicServices.mitems:
      if svc.name == "idp":
        svc.contributionPoints = @[]
    let before = serviceInterfaceFingerprint(
      serviceInterfaceMembers(withPoints, "idp"))
    let after = serviceInterfaceFingerprint(
      serviceInterfaceMembers(withoutPoints, "idp"))
    check before.len == 64
    check after.len == 64
    check before != after
    # And the diff NAMES them, which is §4.3's "the members that
    # differ". An empty member list beside a moved digest is the defect
    # L6's review measured for reorders.
    let diffs = memberDifferences(
      serviceInterfaceSnapshot(withoutPoints, "idp"),
      serviceInterfaceSnapshot(withPoints, "idp"))
    var named: seq[string] = @[]
    for d in diffs:
      if d.kind == smkContributionPoint:
        named.add(d.name)
    check named == @[Dss11RelyingParties, Dss11FixtureUsers]

  test "a v25 interface envelope decodes to NO points rather than refusing":
    # The additive-decode rule every retained field in this codec
    # follows: a pre-v26 row carries no points, and the empty list is
    # what such a service really converged. Written by the CURRENT codec
    # at version 25, as L6's own gating test writes its v24 envelope --
    # a hand-typed byte string would be a guess about what v25 was.
    # (25/26 and not 23/24: the points moved up two when this branch
    # merged ``agents`` -- see ``EnvelopeVersion``'s note on numbering.)
    let pi = interfaceOf(OwnerPackage)
    let v25 = decodeInterfacePayload(encodeInterfacePayload(pi, 25'u16),
      25'u16)
    check serviceRow(v25, "idp").contributionPoints.len == 0
    # ... and the SAME payload at v26 carries them, so the assertion
    # above is about the version and not about the encoder dropping them.
    let v26 = decodeInterfacePayload(encodeInterfacePayload(pi, 26'u16),
      26'u16)
    check serviceRow(v26, "idp").contributionPoints ==
      @[Dss11RelyingParties, Dss11FixtureUsers]

suite "D-SS11 §4.6 — a resolver call reaches the dev-env result":
  test "the resolution names the owner, the service and the consumer":
    let resolution = resolutionFor(loudDevEnv(), "idp")
    check resolution.ownerPackage == OwnerPackage
    check resolution.serviceName == "idp"
    check resolution.activityName == "sso"
    check resolution.consumerPackage == LoudPackage
    check resolution.sourceFile.endsWith("dss11_resolver_fixtures.nim")
    check resolution.sourceLine > 0

  test "the owner's recipe DIRECTORY travels, and it is this fixture's":
    # §4.3 compares fingerprints, and the consumer has no other way to
    # reach the owner's lifted interface. Asserted as a directory that
    # contains the fixture rather than as a literal, because the test
    # binary and the fixture share a tree whose absolute path is the
    # checkout's.
    let resolution = resolutionFor(loudDevEnv(), "idp")
    check resolution.ownerRecipeDir.len > 0
    check fileExists(resolution.ownerRecipeDir /
      "dss11_resolver_fixtures.nim")

  test "the contributions travel as arguments, point by point":
    let resolution = resolutionFor(loudDevEnv(), "idp")
    check resolution.contributionPoints ==
      @[Dss11RelyingParties, Dss11FixtureUsers]
    check resolution.contributionOperations == @["coAppend", "coAppend"]
    check resolution.contributionPrecedences == @["epSet", "epSet"]
    check resolution.contributionMemberPoints ==
      @[Dss11RelyingParties, Dss11RelyingParties, Dss11FixtureUsers]
    check resolution.contributionMembers ==
      @[Dss11LoudMember, "dss11-loud-second", Dss11LoudFixtureUser]
    for site in resolution.contributionSites:
      check site.contains("dss11_resolver_fixtures.nim:")

  test "a consumer that contributes NOTHING still records its resolution":
    # The second control: "the resolution travelled" and "a contribution
    # travelled" are different facts, and a resolver with no arguments
    # is a legitimate recipe (§9.4). An implementation that only
    # recorded resolutions carrying contributions would pass every
    # assertion above.
    let resolution = resolutionFor(quietDevEnv(), "idp")
    check resolution.consumerPackage == QuietPackage
    check resolution.contributionPoints.len == 0
    check resolution.contributionMembers.len == 0

  test "a consumer with no resolver records NOTHING":
    check unresolvedDevEnv().sharedResolutions.len == 0

  test "the OWNER's own dev-env records no resolution":
    # The owner declares the service; it does not resolve it. A
    # resolution on the owner's result would mean the lane had attributed
    # the owner's own `converge` to a resolver.
    check ownerDevEnv().sharedResolutions.len == 0

  test "a resolution is attributed to the package whose enable site wrote it":
    # Both consumers resolve the SAME service in the SAME process. The
    # filter is the consuming package, and without it one consumer's
    # result would carry the other's contributions -- which at `repro up`
    # would deposit them under the wrong contributor and make them
    # unwithdrawable.
    discard loudDevEnv()
    let quiet = quietDevEnv()
    check quiet.sharedResolutions.len == 1
    check quiet.sharedResolutions[0].consumerPackage == QuietPackage
    check quiet.sharedResolutions[0].contributionMembers.len == 0
    let loud = loudDevEnv()
    check loud.sharedResolutions.len == 1
    check loud.sharedResolutions[0].consumerPackage == LoudPackage
    check loud.sharedResolutions[0].contributionMembers.len == 3

suite "D-SS11 §4.6 — the resolution survives the artifact codec":
  test "every field round-trips through encode and decode":
    let artifact = artifactFromDevEnvResult(loudDevEnv())
    let decoded = decodeDevEnvArtifact(encodeDevEnvArtifact(artifact))
    check decoded.schemaVersion == DevEnvArtifactSchemaVersion
    var found = false
    for resolution in decoded.sharedResolutions:
      if resolution.serviceName != "idp":
        continue
      found = true
      check resolution.ownerPackage == OwnerPackage
      check resolution.activityName == "sso"
      check resolution.consumerPackage == LoudPackage
      check resolution.ownerRecipeDir.len > 0
      check resolution.contributionPoints ==
        @[Dss11RelyingParties, Dss11FixtureUsers]
      check resolution.contributionOperations == @["coAppend", "coAppend"]
      check resolution.contributionPrecedences == @["epSet", "epSet"]
      check resolution.contributionMembers ==
        @[Dss11LoudMember, "dss11-loud-second", Dss11LoudFixtureUser]
      check resolution.contributionMemberPoints.len ==
        resolution.contributionMembers.len
      check resolution.sourceLine > 0
    # Asserted so a rename cannot make every check above vacuous.
    check found

  test "the JSON view shows the resolution":
    # `repro dev-env --json` is the only view an operator has of what a
    # recipe declared before `repro up` acts on it, and a resolver whose
    # contributions were invisible there is one nobody can check.
    let json = toJsonInspection(artifactFromDevEnvResult(loudDevEnv()))
    check json.contains("\"sharedResolutions\":")
    check json.contains("\"consumerPackage\":\"" & LoudPackage & "\"")
    check json.contains(Dss11LoudMember)

  test "an artifact with no resolution carries an empty list":
    let json = toJsonInspection(artifactFromDevEnvResult(unresolvedDevEnv()))
    check json.contains("\"sharedResolutions\":[]")

suite "D-SS11 §4.6 — `resolveSharedService` refuses rather than records":
  setup:
    resetSharedServiceResolutions()

  test "a second resolver for ONE service in ONE consumer is refused":
    # Two resolvers would take two leases and deposit two contribution
    # sets for one key, and the second deposit would have to either lose
    # or duplicate the first. Not reachable as a compile error -- the
    # two call sites are each individually well formed -- so it is a
    # refusal at evaluation, and it names both sites.
    beginResolverPackage("dss11Probe")
    defer: endResolverPackage()
    discard resolveSharedService[LiftedServiceHandle](
      dss11OwnerSsoIdpSharedService, currentResolverPackage(),
      @[sharedContribution(Dss11RelyingParties, @["first"])],
      "probe.nim", 10)
    var raised = false
    try:
      discard resolveSharedService[LiftedServiceHandle](
        dss11OwnerSsoIdpSharedService, currentResolverPackage(),
        @[sharedContribution(Dss11RelyingParties, @["second"])],
        "probe.nim", 20)
    except EDslPortSharedServiceRefusal as err:
      raised = true
      check "resolves `dss11Owner.idp` twice" in err.msg
      check "probe.nim:10" in err.msg
      check "probe.nim:20" in err.msg
    check raised

  test "a byte-identical replay is NOT a second resolver":
    # Module init replays (`rerunServiceDeclarators` re-executes every
    # service and activity body during provider-graph emission), so
    # every resolver in the repository is evaluated at least twice. A
    # refusal that fired on the replay would make the surface unusable.
    beginResolverPackage("dss11Probe")
    defer: endResolverPackage()
    let first = resolveSharedService[LiftedServiceHandle](
      dss11OwnerSsoIdpSharedService, currentResolverPackage(),
      @[sharedContribution(Dss11RelyingParties, @["same"])],
      "probe.nim", 30)
    let second = resolveSharedService[LiftedServiceHandle](
      dss11OwnerSsoIdpSharedService, currentResolverPackage(),
      @[sharedContribution(Dss11RelyingParties, @["same"])],
      "probe.nim", 30)
    check first == second
    check registeredSharedServiceResolutions().len == 1

  test "a contribution to an undeclared point is refused at the runtime too":
    # The resolver MACRO refuses this at the consumer's compile time.
    # This is the same check for a direct caller of the public proc: a
    # proc that trusted its arguments would make the macro's check the
    # only one, and a library caller's mistake silent.
    beginResolverPackage("dss11Probe")
    defer: endResolverPackage()
    var raised = false
    try:
      discard resolveSharedService[LiftedServiceHandle](
        dss11OwnerSsoIdpSharedService, currentResolverPackage(),
        @[sharedContribution("nosuchPoint", @["x"])], "probe.nim", 40)
    except EDslPortSharedServiceRefusal as err:
      raised = true
      check "declares no contribution point `nosuchPoint`" in err.msg
      check Dss11RelyingParties in err.msg
    check raised
    check registeredSharedServiceResolutions().len == 0

  test "a `replace` contribution is refused at the runtime too":
    beginResolverPackage("dss11Probe")
    defer: endResolverPackage()
    var raised = false
    try:
      discard resolveSharedService[LiftedServiceHandle](
        dss11OwnerSsoIdpSharedService, currentResolverPackage(),
        @[sharedContribution(Dss11RelyingParties, @["x"],
          operation = coReplace)], "probe.nim", 50)
    except EDslPortSharedServiceRefusal as err:
      raised = true
      # Keyed on the shared helper rather than on a re-typed substring,
      # for the reason its doc comment gives: §5.1's judgement is
      # refused at three stages and had three independent phrasings, so
      # a hand-typed fragment here would be a fourth copy. See the
      # matching assertion in
      # `repro_resources/tests/t_dss11_cross_process_contribution_store.nim`.
      check sharedServiceReplaceRefusal() in err.msg
      # The part local to THIS stage, which the shared text does not
      # carry -- so the case still distinguishes the evaluation-time
      # refusal from the other two.
      check "Refused at EVALUATION" in err.msg
    check raised

  test "a resolver with NO consuming package in scope is refused":
    # The ambient is set only around a generated dev-env body, so this
    # is the "a resolver in a position nothing reads" case that is
    # genuinely unattributable. Refused rather than recorded with a
    # blank contributor: §5 requires every converged member to name its
    # contributor, and a blank one can never be withdrawn.
    check currentResolverPackage().len == 0
    var raised = false
    try:
      discard resolveSharedService[LiftedServiceHandle](
        dss11OwnerSsoIdpSharedService, currentResolverPackage(),
        @[sharedContribution(Dss11RelyingParties, @["x"])],
        "probe.nim", 60)
    except EDslPortSharedServiceRefusal as err:
      raised = true
      check "no CONSUMING package is in scope" in err.msg
    check raised

  test "a hand-built declaration naming no owner is refused":
    beginResolverPackage("dss11Probe")
    defer: endResolverPackage()
    var raised = false
    try:
      discard resolveSharedService[LiftedServiceHandle](
        SharedServiceDeclarationDef(), currentResolverPackage(), @[],
        "probe.nim", 70)
    except EDslPortSharedServiceRefusal as err:
      raised = true
      check "names no owner package" in err.msg
    check raised

suite "D-SS11 §4.6 — the generated declaration const is the lift's":
  test "the const carries exactly what the owner declared":
    check dss11OwnerSsoIdpSharedService.ownerPackage == OwnerPackage
    check dss11OwnerSsoIdpSharedService.serviceName == "idp"
    check dss11OwnerSsoIdpSharedService.activityName == "sso"
    check dss11OwnerSsoIdpSharedService.contributionPoints ==
      @[Dss11RelyingParties, Dss11FixtureUsers]
    check dss11OwnerSsoIdpSharedPoints ==
      @[Dss11RelyingParties, Dss11FixtureUsers]

  test "a session-owned service gets NO declaration const":
    # The discriminant is the `instance:` block, and this is how
    # `sharedServiceNotResolvable` becomes reachable rather than
    # theoretical.
    check not declared(dss11OwnerSsoPlainSharedService)
    check not declared(dss11OwnerSsoPlainSharedPoints)

  test "the const name is derived by the ONE shared derivation":
    # Both emitters call `sharedServiceConstBase`, and the resolver
    # macro rebuilds the same name from the author's own expression. A
    # second copy of this derivation is how a resolver would compile
    # against one route to the producer and not the other.
    check sharedServiceConstBase(OwnerPackage, "sso", "idp") ==
      "dss11_ownerSsoIdp"
    check sharedServiceConstBase(OwnerPackage, "", "idp") ==
      "dss11_ownerIdp"

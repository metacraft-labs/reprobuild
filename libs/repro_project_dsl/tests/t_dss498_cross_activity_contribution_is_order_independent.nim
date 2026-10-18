## Shared-Development-Services, reprobuild issue #498: A CROSS-ACTIVITY
## CONTRIBUTION IS ORDER-INDEPENDENT, AND THE ARTIFACT'S TWO VIEWS OF
## ONE POINT AGREE.
##
## What #498 measured, and what this file pins so it cannot come back:
##
## | the contributing activity is declared | argv | `registrationMembers` |
## |---|---|---|
## | **before** the owning one | has the member | has the member |
## | **after** the owning one | **missing** | has it |
##
## Both orders exited 0, so declaration order was semantically
## significant with no diagnostic, and in the owner-first arrangement ONE
## dev-env artifact stated TWO different member sets for one contribution
## point -- the launcher started without the member on its command line
## while the converge lane handed that same member to the registrar.
##
## THE RESOLUTION, implemented in `dsl_port_runtime.nim` /
## `macros_b.nim` / `runtime_provider.nim`: the argv fold of a
## contribution point is DEFERRED to finalization, after every activity
## body in the package has run. The alternative -- refusing a
## contribution that arrives after a fold -- was rejected because
## `t_l8_contribution_operation_is_a_second_axis.nim`'s "a second
## consumer arriving does not renumber or re-make the first's" asserts
## that a late contribution MUST land, so refusing one would contradict
## an asserted semantic.
##
## MOCK POLICY -- NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED.
## The fixture is a real two-package recipe module expanded by the real
## DSL macro; the dev-env records come from the real
## `buildPackageDevEnv`; the artifact comes from the real
## `artifactFromDevEnvResult` and is round-tripped through the real SSZ
## codec.
##
## WHY THE COMPARISON IS "THE SAME ARTIFACT" AND NOT "BOTH CONTAIN THE
## MEMBER". Two artifacts can agree and both be wrong, so every case
## below asserts against `Dss498ExpectedArgv` / `Dss498ExpectedMembers`
## -- a text the fixture states once -- AND against each other. The
## second assertion alone would pass for an implementation that dropped
## the member in both orders.

import std/[strutils, unittest]

import repro_project_dsl
import repro_provider_runtime
import repro_dev_env_artifacts

import dss498_order_fixtures

const FixtureRoot = "/tmp/dss498-order-fixture-root"

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

proc devEnvFor(package: string): DevEnvResult =
  ## Lowered through the REAL provider entry point, both activities
  ## enabled, with the OWNING activity selected -- which is what makes
  ## the owner's service the one whose facts are routed.
  ##
  ## THE WITHDRAWAL IS LOAD-BEARING AND IT IS A TRAP THIS FILE FELL INTO
  ## ONCE. The contribution registry is process-level, so a SECOND
  ## lowering in one process starts with the PREVIOUS lowering's late
  ## contribution already recorded -- and then the eager fold reads it
  ## and the owner-first arrangement looks correct. Measured: with the
  ## withdrawal removed, the red case below passes against the unfixed
  ## code. Each case must therefore re-create the pristine condition,
  ## and `withdrawPackageContributions` is the real registry mutator
  ## rather than a reset of a copy. The owner's own construction default
  ## carries the empty package name and is explicitly held by it, so
  ## what is withdrawn is exactly the activity body's contribution.
  discard withdrawPackageContributions(package)
  clearRegisteredServices(package)
  let pkg = pkgDef(package)
  if package == Dss498OwnerFirstName:
    buildPackageDevEnv(pkg, devEnvRequest(pkg, Dss498OwnerActivity),
      devEnvDss498OwnerFirstPackage)
  elif package == Dss498ContributorFirstName:
    buildPackageDevEnv(pkg, devEnvRequest(pkg, Dss498OwnerActivity),
      devEnvDss498ContributorFirstPackage)
  else:
    buildPackageDevEnv(pkg, devEnvRequest(pkg, Dss498OwnerActivity),
      devEnvDss498ExplicitOverridePackage)

proc serviceNamed(res: DevEnvResult; name: string): DevEnvServiceMetadata =
  for svc in res.services:
    if svc.name == name:
      return svc
  raise newException(ValueError, "no service named " & name)

proc ownerService(package: string): DevEnvServiceMetadata =
  serviceNamed(devEnvFor(package), Dss498ServiceName)

proc argvOf(svc: DevEnvServiceMetadata): seq[string] =
  ## The command line WITHOUT the executable, which is the part the
  ## recipe's `args` setters wrote. The executable differs in nothing
  ## here, but naming the slice keeps the assertion about argv rather
  ## than about a command whose head is incidental.
  if svc.typedCommand.len == 0:
    raise newException(ValueError,
      "the lowered service carries an EMPTY typed command, so nothing " &
      "below is measuring argv. This is the extractor's own positive " &
      "control: a service lowered from the fixture always has at least " &
      "its executable.")
  svc.typedCommand[1 .. ^1]

suite "#498: the fixture really does declare the two orders":

  test "both packages are present, with the owning activity's service":
    # THE POSITIVE CONTROL for every case below. A broken extractor --
    # a renamed package, a renamed service, an activity gate that
    # routed nothing -- would otherwise make the comparisons pass by
    # both sides being empty.
    for package in [Dss498OwnerFirstName,
                    Dss498ContributorFirstName]:
      let res = devEnvFor(package)
      check res.services.len == 1
      let svc = serviceNamed(res, Dss498ServiceName)
      check svc.typedCommand.len >= 2
      check Dss498ArgvFlag in svc.typedCommand
      check svc.registrationPoints.len == 1

  test "the two packages' bodies differ ONLY in declaration order":
    # Read off the registered `DslActivityDef.bodyRepr`s rather than
    # asserted in a comment: if a later edit changes one package's
    # service body, the two orders stop being comparable and every
    # "identical artifact" case below becomes a tautology about two
    # different recipes.
    #
    # THE ACTIVITY REGISTRY IS FILLED BY LOWERING, not at module init:
    # `activity` declarations register from inside the dev-env body. The
    # runner executes every case in its own process (`--run
    # "<suite>::<test>"`), so this case cannot lean on the case above
    # having lowered both packages -- run alone, it would read an empty
    # registry and report drift that is not there. Lower both here.
    proc activityBody(package, activity: string): string =
      if registeredActivities(package).len == 0:
        discard devEnvFor(package)
      for act in registeredActivities(package):
        if act.activityName == activity:
          return act.bodyRepr
      raise newException(ValueError,
        "fixture drift: " & package & "." & activity & " missing")
    proc withoutComments(text: string): string =
      ## Doc comments survive into `bodyRepr`, and the two bodies carry
      ## different ones (the owner-first copy explains why the readiness
      ## probe is there). The comparison is of the DECLARATIONS.
      var kept: seq[string] = @[]
      for line in text.splitLines():
        if line.strip().startsWith("##"):
          continue
        kept.add(line)
      kept.join("\n")
    let ownerFirstOwner = withoutComments(
      activityBody(Dss498OwnerFirstName, Dss498OwnerActivity))
    let contributorFirstOwner = withoutComments(
      activityBody(Dss498ContributorFirstName, Dss498OwnerActivity))
    check ownerFirstOwner.len > 0
    check "args members" in ownerFirstOwner
    check "converge members" in ownerFirstOwner
    check ownerFirstOwner.replace("owner-first",
      "contributor-first") == contributorFirstOwner

suite "#498: the argv fold is deferred, so declaration order does not matter":

  test "CONTRIBUTOR FIRST: the member reaches argv":
    # The arrangement that already worked. Here so the case below is a
    # comparison against a known-good reading rather than against
    # nothing.
    check argvOf(ownerService(Dss498ContributorFirstName)) ==
      Dss498ExpectedArgv

  test "OWNER FIRST: the member reaches argv TOO -- #498's red case":
    # THE CASE #498 IS. Before the fix this reads
    # @["--members", "owner-default"] -- the member is folded into
    # `registrationMembers` and never into the command line.
    check argvOf(ownerService(Dss498OwnerFirstName)) ==
      Dss498ExpectedArgv

  test "both orders produce the SAME argv":
    check argvOf(ownerService(Dss498OwnerFirstName)) ==
      argvOf(ownerService(Dss498ContributorFirstName))

suite "#498: argv and registrationMembers agree, in BOTH orders":

  test "OWNER FIRST: the artifact's two views of one point agree":
    # The half of #498 that is worse than the order-dependence: the
    # launcher's command line and the converge lane's member set
    # disagreeing inside ONE artifact.
    let svc = ownerService(Dss498OwnerFirstName)
    check svc.registrationMembers == Dss498ExpectedMembers
    for member in svc.registrationMembers:
      check member in svc.typedCommand
    check argvOf(svc)[1 .. ^1] == svc.registrationMembers

  test "CONTRIBUTOR FIRST: the same two views agree":
    let svc = ownerService(Dss498ContributorFirstName)
    check svc.registrationMembers == Dss498ExpectedMembers
    check argvOf(svc)[1 .. ^1] == svc.registrationMembers

  test "the member is attributed to the activity that contributed it":
    # Order-independence must not be bought by dropping the
    # attribution: the contributing package is still named, in both
    # orders, for the member it contributed and for no other.
    for package in [Dss498OwnerFirstName,
                    Dss498ContributorFirstName]:
      let svc = ownerService(package)
      check svc.registrationContributors.len ==
        svc.registrationMembers.len
      check svc.registrationContributors[0] == ""
      check svc.registrationContributors[1] == package

suite "#498: the deferred fold survives the artifact codec":

  test "both orders encode and decode to the same service summary":
    proc summaryFor(package: string): DevEnvServiceSummary =
      let artifact = artifactFromDevEnvResult(devEnvFor(package))
      let bytes = encodeDevEnvArtifact(artifact)
      for svc in decodeDevEnvArtifact(bytes).services:
        if svc.name == Dss498ServiceName:
          return svc
      raise newException(ValueError, "no summary named " &
        Dss498ServiceName)
    let ownerFirst = summaryFor(Dss498OwnerFirstName)
    let contributorFirst = summaryFor(Dss498ContributorFirstName)
    check ownerFirst.typedCommand == contributorFirst.typedCommand
    check ownerFirst.registrationMembers ==
      contributorFirst.registrationMembers
    check ownerFirst.registrationMembers == Dss498ExpectedMembers
    check Dss498LateMember in ownerFirst.typedCommand

suite "#498: the deferral is a live slot, and it is observable":

  test "a contribution arriving AFTER finalization re-folds the slot":
    # THE MEASUREMENT THAT THE SLOT IS DEFERRED rather than correct for
    # some other reason. `foldDeferredServiceArgv` returns the number of
    # services whose argv it CHANGED, so this reads the mechanism
    # directly instead of inferring it from an argv that happens to be
    # right: a second call with no new contribution must change nothing,
    # and a call after a new contribution must change exactly one
    # service.
    let res = devEnvFor(Dss498ContributorFirstName)
    check res.services.len == 1
    check foldDeferredServiceArgv(Dss498ContributorFirstName) == 0
    contributeConfigurableRaw(Dss498ContributorFirstKey,
      "dss498ArrivesLater", epSet, coAppend,
      dslScalarSeqString(@["arrived-after-finalization"]),
      "t_dss498.nim", 1)
    check foldDeferredServiceArgv(Dss498ContributorFirstName) == 1
    var argv: seq[string] = @[]
    for svc in registeredServices(Dss498ContributorFirstName):
      if svc.serviceName == Dss498ServiceName:
        argv = svc.args
    check argv == @[Dss498ArgvFlag, Dss498OwnerDefault, Dss498LateMember,
                    "arrived-after-finalization"]
    discard withdrawPackageContributions("dss498ArrivesLater")

  test "a service with NO contribution point on argv is left alone":
    # The control for the case above: the fold must report 0 for a
    # package whose services carry only literal tokens, or the count it
    # returns says nothing.
    let package = Dss498ExplicitOverrideName
    discard devEnvFor(package)
    check foldDeferredServiceArgv(package) == 0

suite "#498: an EXPLICIT enable-site argument is frozen, not deferred":

  test "the explicit value reaches argv and the contribution does not":
    # §6.6 / §6: the owner may override its own environment at its own
    # `enable` site, and that argument must not be undone by a later
    # contribution. Measured in the presence of exactly the contribution
    # the two order fixtures receive.
    let svc = ownerService(Dss498ExplicitOverrideName)
    check argvOf(svc) == @[Dss498ArgvFlag, Dss498ExplicitMember]
    check Dss498LateMember notin svc.typedCommand
    check Dss498OwnerDefault notin svc.typedCommand

  test "the converge lane still reports the POINT, and that is pre-existing":
    # STATED RATHER THAN GLOSSED, because it looks like the defect #498
    # is about and is not. An explicit `enable` argument binds the
    # PARAMETER; `registrationMembers` is folded from the POINT, which
    # the argument does not touch. So the two disagree here -- and they
    # disagreed in exactly this way before the deferral existed, for
    # the same reason, in BOTH declaration orders. What #498 found was
    # a disagreement with no author-visible cause; this one has one at
    # the `enable` site. Pinned so a later change cannot silently turn
    # the explicit argument into a contribution (which would be a
    # different decision, and one this file would then have to record).
    let svc = ownerService(Dss498ExplicitOverrideName)
    check svc.registrationMembers == Dss498ExpectedMembers
    check svc.registrationMembers != argvOf(svc)[1 .. ^1]

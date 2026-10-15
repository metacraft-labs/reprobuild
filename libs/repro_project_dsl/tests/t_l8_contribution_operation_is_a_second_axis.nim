## Shared-Development-Services L8: the OPERATION is a second axis,
## independent of priority.
##
## What this file measures, and why each case is here rather than
## implied by another:
##
##   * the FOUR-CELL MATRIX against the same base, which is the gate's
##     named proof. Two of the four cells are the ones a one-axis design
##     gets wrong, and they are asserted on the PRESENCE of the lower
##     contribution rather than only on the winner's members -- a design
##     that discards downward passes a "the force member is present"
##     assertion and fails these;
##   * the per-operation `prForce` limit: at most one `force` `replace`,
##     several `force` `append`s;
##   * attribution, read off the contribution list;
##   * withdrawal of one package's members and NOTHING else;
##   * the step-4 diagnostic naming BOTH sites.
##
## MOCK POLICY -- NO MOCKS. The fixture is real `package` blocks expanded
## by the real DSL macro (see its header); this file reads the real
## `dsl_port_runtime` registries through their public accessors. The
## cases that need a contribution the DSL cannot author at macro level
## (an `epDefault` append, a second `force` `replace` from a second
## site) call `contributeConfigurableRaw` directly -- that is the same
## funnel the macro's emission calls, not a stub of it, and the test
## says so at each site.

import std/[strutils, unittest]
import repro_project_dsl
import repro_dsl_stdlib/types    # Executable, for the artifact slot var
import l8_contribution_fixtures

proc pkgDef(): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == "l8MatrixOwner":
      return pkg
  raise newException(ValueError, "fixture drift: l8MatrixOwner missing")

proc devEnvRequest(pkg: PackageDef; activity: string):
    ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider",
    entryPointId: pkg.packageName & ".dev-env",
    entryPointBodyHash: pkg.packageName & ".build.v1",
    reason: girExplicitUserRequest,
    arguments: "/tmp/l8-matrix-fixture-root",
    namespace: "project-" & pkg.packageName,
    activity: activity)

const
  AppendLow = "l8MatrixOwner.sso.appendLow"
  AppendHigh = "l8MatrixOwner.sso.appendHigh"
  ReplaceLow = "l8MatrixOwner.sso.replaceLow"
  ReplaceHigh = "l8MatrixOwner.sso.replaceHigh"
  NoDefault = "l8MatrixOwner.sso.noDefault"
  EnvBound = "l8MatrixOwner.sso.envBound"
  EmptyPoint = "l8MatrixOwner.sso.emptyPoint"
  PackageLevel = "l8PackageLevelOwner.siteList"

proc members(key: string): seq[string] =
  readConfigurable[seq[string]](key)

suite "Shared-Development-Services L8: a collection IS a configurable":

  test "an ordered-collection `config:` key is a contribution point":
    # Not a bespoke collection primitive: the key is in the ordinary
    # configurable registry, enumerable with every other `config:` key.
    check isContributionPoint(AppendLow)
    check AppendLow in registeredConfigKeys()
    check AppendLow in registeredContributionPoints()
    # And a SCALAR key is not one, so the two are distinguishable.
    check not isContributionPoint("l8MatrixOwner.sso.doesNotExist")

  test "a contribution point with no default seeds EMPTY and is not required":
    # L5's "a key with no default is REQUIRED" is right for a scalar and
    # wrong for a collection: "nothing contributed yet" is a value.
    check not configurableIsRequired(NoDefault)
    check NoDefault notin unsatisfiedRequiredConfigKeys()

  test "a second `contribute:` section in one package is honoured":
    # Honouring only the first would be a silent drop.
    check members(NoDefault) == @["from-second-section"]

suite "L8: the runtime funnel refuses by name rather than dropping":

  test "`append` aimed at a SCALAR key is refused, naming the kind":
    # The compile-time walker cannot know this -- the key may belong to
    # another module -- so the refusal is at the funnel, and it must not
    # degrade into a replace.
    var raised = false
    try:
      contributeConfigurableRaw("l8MatrixOwner.sso.aScalar", "pkg",
        epSet, coAppend, dslScalarSeqString(@["x"]), "p.nim", 1)
    except EDslPortMissingKey:
      # The scalar key does not exist in the fixture, so the key check
      # fires first. Register one and re-probe, so the case measures the
      # refusal it names rather than a different one.
      recordConfigDefault[string]("l8MatrixOwner", "aScalar", "s")
      try:
        contributeConfigurableRaw("l8MatrixOwner.aScalar", "pkg",
          epSet, coAppend, dslScalarSeqString(@["x"]), "p.nim", 1)
      except EDslPortNotAContributionPoint as e:
        raised = true
        check "dskString" in e.msg
        check "only operation is `replace`" in e.msg
    check raised

  test "a contribution to an UNKNOWN key is refused, naming the key":
    var raised = false
    try:
      contributeConfigurableRaw("l8MatrixOwner.sso.notDeclared", "pkg",
        epSet, coAppend, dslScalarSeqString(@["x"]), "p.nim", 1)
    except EDslPortMissingKey as e:
      raised = true
      check "l8MatrixOwner.sso.notDeclared" in e.msg
    check raised

  test "a contribution of the WRONG kind is refused, naming both kinds":
    let snapshot = contributionSnapshot()
    defer: restoreContributions(snapshot)
    var raised = false
    try:
      contributeConfigurableRaw(AppendLow, "pkg", epSet, coReplace,
        dslScalarString("not-a-collection"), "p.nim", 1)
    except EDslPortTypeMismatch as e:
      raised = true
      check "dskString" in e.msg
      check "dskSeqString" in e.msg
    check raised

  test "withdrawing a package that contributed nothing removes nothing":
    let snapshot = contributionSnapshot()
    defer: restoreContributions(snapshot)
    check withdrawPackageContributions("neverContributed") == 0
    check members(AppendLow) == @["owner-default", "consumer-a", "cell"]

suite "L8: the four-cell matrix, against the same base":

  test "every cell starts from the SAME base, so the cells are comparable":
    for key in [AppendLow, AppendHigh, ReplaceLow, ReplaceHigh]:
      let rows = configurableContributions(key)
      # row 0 is the owner's construction default; the consumer-A append
      # is present in every cell with the same priority and value.
      check rows[0].operation == coReplace
      check rows[0].precedence == epDefault
      check rows[0].value.seqStrVals == @["owner-default"]
      var sawConsumerA = false
      for r in rows:
        if r.package == "l8MatrixConsumerA":
          check r.operation == coAppend
          check r.precedence == epSet
          check r.value.seqStrVals == @["consumer-a"]
          sawConsumerA = true
      check sawConsumerA

  test "CELL 1 append-low: the member is added, nothing is lost":
    check members(AppendLow) == @["owner-default", "consumer-a", "cell"]

  test "CELL 2 append-high: an AUTHORITATIVE append leaves every lower contribution present":
    # THE CLAUSE A ONE-AXIS DESIGN GETS WRONG. `appendForce` is
    # `epForce`, the top of the ladder. Under priority alone the force
    # contribution would WIN and discard everything beneath it, leaving
    # @["cell"]. The assertion is on the lower members being there, not
    # on "cell" being there.
    let got = members(AppendHigh)
    check "consumer-a" in got
    check "owner-default" in got
    check got == @["owner-default", "consumer-a", "cell"]
    # And nothing was discarded, which is the other half of the same
    # claim: an append is never destructive, so step 4 has no work.
    check discardedContributions(AppendHigh).len == 0

  test "CELL 3 replace-low: destructive downward, but an append at the SAME priority survives":
    # R is at `epSet`. The construction default (a `replace` at
    # `epDefault`) is superseded, so "owner-default" is gone. Consumer
    # A's append is AT `epSet`, i.e. not below R, so step 3 applies it.
    check members(ReplaceLow) == @["cell", "consumer-a"]
    check discardedContributions(ReplaceLow).len == 0

  test "CELL 4 replace-high: an append BELOW a winning replace is discarded":
    check members(ReplaceHigh) == @["cell"]
    check "consumer-a" notin members(ReplaceHigh)

  test "the discards are also enumerable across every point at once":
    # `allDiscardedContributions` is the whole-profile view an engine or
    # a CLI would print; a public accessor with no case is a thing that
    # rots, so it has one.
    var found = false
    for d in allDiscardedContributions():
      if d.key == ReplaceHigh:
        found = true
    check found
    # Recomputed, not accumulated: withdraw the `replace` and the
    # discard it caused is gone rather than still being reported.
    let snapshot = contributionSnapshot()
    defer: restoreContributions(snapshot)
    discard withdrawPackageContributions("l8MatrixConsumerB")
    for d in allDiscardedContributions():
      check d.key != ReplaceHigh

  test "CELL 4's discard carries a diagnostic naming BOTH sites":
    # The clause a one-axis design makes VANISH silently.
    let discarded = discardedContributions(ReplaceHigh)
    check discarded.len == 1
    let d = discarded[0]
    check d.key == ReplaceHigh
    check d.discarded.package == "l8MatrixConsumerA"
    check d.discarded.operation == coAppend
    check d.discarded.precedence == epSet
    check d.discarded.sourceFile.len > 0
    check d.discarded.sourceLine > 0
    check d.supersededBy.package == "l8MatrixConsumerB"
    check d.supersededBy.operation == coReplace
    check d.supersededBy.precedence == epOverride
    check d.supersededBy.sourceFile.len > 0
    let rendered = renderDiscardedContribution(d)
    # BOTH sites, by name, in one message.
    check "l8MatrixConsumerA" in rendered
    check "l8MatrixConsumerB" in rendered
    check "l8_contribution_fixtures" in rendered
    check "DISCARDED" in rendered
    check ReplaceHigh in rendered

  test "the four cells differ ONLY in the cell contribution":
    # The control for "against the same base": strip consumer B's row
    # from each key and all four resolve identically.
    let snapshot = contributionSnapshot()
    defer: restoreContributions(snapshot)
    discard withdrawPackageContributions("l8MatrixConsumerB")
    for key in [AppendLow, AppendHigh, ReplaceLow, ReplaceHigh]:
      check members(key) == @["owner-default", "consumer-a"]

suite "L8: `prForce` is limited per OPERATION, not per configurable":

  test "several `force` appends are NOT an error":
    # `contributeConfigurableRaw` is the same funnel the macro emits
    # into; it is called directly here because the DSL cannot author two
    # contributions from one site with different line numbers.
    let snapshot = contributionSnapshot()
    defer: restoreContributions(snapshot)
    contributeConfigurableRaw(AppendHigh, "pkgOne", epForce, coAppend,
      dslScalarSeqString(@["force-one"]), "a.nim", 10)
    contributeConfigurableRaw(AppendHigh, "pkgTwo", epForce, coAppend,
      dslScalarSeqString(@["force-two"]), "b.nim", 20)
    let got = members(AppendHigh)
    check "force-one" in got
    check "force-two" in got
    # ... and the LOWER contributions are still all present, which is
    # the same independence claim at the top of the ladder.
    check "owner-default" in got
    check "consumer-a" in got

  test "a second `force` REPLACE is an error naming both sites":
    let snapshot = contributionSnapshot()
    defer: restoreContributions(snapshot)
    contributeConfigurableRaw(ReplaceHigh, "pkgOne", epForce, coReplace,
      dslScalarSeqString(@["force-one"]), "first.nim", 11)
    var raised = false
    try:
      contributeConfigurableRaw(ReplaceHigh, "pkgTwo", epForce, coReplace,
        dslScalarSeqString(@["force-two"]), "second.nim", 22)
    except EDslPortDuplicateForceReplace as e:
      raised = true
      check "first.nim:11" in e.msg
      check "second.nim:22" in e.msg
      check "pkgOne" in e.msg
      check "pkgTwo" in e.msg
    check raised

  test "a byte-identical `force` replace is a replay, not a second claim":
    let snapshot = contributionSnapshot()
    defer: restoreContributions(snapshot)
    contributeConfigurableRaw(ReplaceHigh, "pkgOne", epForce, coReplace,
      dslScalarSeqString(@["force-one"]), "first.nim", 11)
    # The SAME row again -- what `rerunServiceDeclarators` produces.
    contributeConfigurableRaw(ReplaceHigh, "pkgOne", epForce, coReplace,
      dslScalarSeqString(@["force-one"]), "first.nim", 11)
    check members(ReplaceHigh) == @["force-one"]

  test "two DIFFERENT replaces tied at one priority are a contradiction":
    let snapshot = contributionSnapshot()
    defer: restoreContributions(snapshot)
    contributeConfigurableRaw(ReplaceLow, "pkgOne", epOverride, coReplace,
      dslScalarSeqString(@["one"]), "first.nim", 11)
    contributeConfigurableRaw(ReplaceLow, "pkgTwo", epOverride, coReplace,
      dslScalarSeqString(@["two"]), "second.nim", 22)
    var raised = false
    try:
      discard members(ReplaceLow)
    except EDslPortContradictoryReplace as e:
      raised = true
      check "first.nim:11" in e.msg
      check "second.nim:22" in e.msg
    check raised

suite "L8: convergence is idempotent, incremental and attributed":

  test "two consumers each contributing to one point: BOTH are present":
    let got = members(AppendLow)
    check "consumer-a" in got
    check "cell" in got

  test "every converged member records its contributing package":
    let attributed = contributionMemberAttribution(AppendLow)
    check attributed.len == 3
    check attributed[0].member == "owner-default"
    check attributed[0].package == ""
    check attributed[1].member == "consumer-a"
    check attributed[1].package == "l8MatrixConsumerA"
    check attributed[2].member == "cell"
    check attributed[2].package == "l8MatrixConsumerB"

  test "a second consumer arriving does not renumber or re-make the first's":
    # The identifier the gate names is the FIRST registration's; here it
    # is the member string itself plus its index, both of which must be
    # byte-identical before and after.
    let snapshot = contributionSnapshot()
    defer: restoreContributions(snapshot)
    let beforeMembers = members(NoDefault)
    let beforeAttribution = contributionMemberAttribution(NoDefault)
    contributeConfigurableRaw(NoDefault, "arrivesLater", epSet, coAppend,
      dslScalarSeqString(@["later-member"]), "later.nim", 5)
    let afterMembers = members(NoDefault)
    let afterAttribution = contributionMemberAttribution(NoDefault)
    for i in 0 ..< beforeMembers.len:
      check afterMembers[i] == beforeMembers[i]
      check afterAttribution[i].member == beforeAttribution[i].member
      check afterAttribution[i].package == beforeAttribution[i].package
    check afterMembers.len == beforeMembers.len + 1

  test "a replayed contribution is dropped, so convergence is idempotent":
    let snapshot = contributionSnapshot()
    defer: restoreContributions(snapshot)
    let before = configurableContributions(AppendLow).len
    for row in configurableContributions(AppendLow):
      contributeConfigurableRaw(row.key, row.package, row.precedence,
        row.operation, row.value, row.sourceFile, row.sourceLine)
    check configurableContributions(AppendLow).len == before
    check members(AppendLow) == @["owner-default", "consumer-a", "cell"]

  test "withdrawing a dependency removes its members and NOTHING else":
    let snapshot = contributionSnapshot()
    defer: restoreContributions(snapshot)
    # The expected count is DERIVED from the registry rather than typed:
    # a number nobody computes is where a fixture change silently stops
    # being covered (the campaign's own working agreement makes this
    # rule for `:evidence:` counts, and it reads the same here).
    var expected = 0
    for key in registeredContributionPoints():
      for row in configurableContributions(key):
        if row.package == "l8MatrixConsumerA":
          inc expected
    check expected > 0
    let removed = withdrawPackageContributions("l8MatrixConsumerA")
    check removed == expected
    check members(AppendLow) == @["owner-default", "cell"]
    # the OTHER consumer's member survives, and so does the owner's
    # construction default -- the seed row is explicitly held.
    check "cell" in members(AppendLow)
    check "owner-default" in members(AppendLow)
    check "consumer-a" notin members(AppendLow)

  test "withdrawing the port's own rows never removes the seed":
    let snapshot = contributionSnapshot()
    defer: restoreContributions(snapshot)
    discard withdrawPackageContributions("")
    # Still resolvable: the construction default is held even though it
    # carries the empty package name.
    check members(AppendLow) == @["owner-default", "consumer-a", "cell"]

suite "L8: both authoring surfaces lower a contribution point":

  test "a PACKAGE-LEVEL `seq[string]` config key is a contribution point":
    # The package-level `config:` emitter and the activity-level one are
    # two emitters, so a point declared at package level needs its own
    # case rather than being implied by the activity one.
    check isContributionPoint(PackageLevel)
    check members(PackageLevel) == @["owner-site", "consumer-site"]
    let attributed = contributionMemberAttribution(PackageLevel)
    check attributed.len == 2
    check attributed[0].package == ""
    check attributed[1].package == "l8PackageLevelConsumer"

suite "L8: an `environment` binding is a `replace` at `epOverride`":

  test "unbound, the owner default and the consumer append both stand":
    resetConfigurable(EnvBound)
    check members(EnvBound) == @["owner-default", "consumer-a"]
    check discardedContributions(EnvBound).len == 0

  test "bound, it REPLACES and the consumer's lower append is DISCARDED":
    # L5's own deferral note: "An environment binding is a `replace` at
    # `epOverride` in the terms L8 will introduce, and this code does
    # not pre-empt the spelling." This case is that prediction measured.
    resetConfigurable(EnvBound)
    applyEnvironment("l8MatrixOwner", "dev")
    check members(EnvBound) == @["from-environment"]
    let discarded = discardedContributions(EnvBound)
    check discarded.len == 1
    check discarded[0].discarded.package == "l8MatrixConsumerA"
    check discarded[0].supersededBy.precedence == epOverride
    check discarded[0].supersededBy.operation == coReplace
    # and the reset puts it back, so the two readings above are of ONE
    # definition under two bindings rather than of two definitions.
    resetConfigurable(EnvBound)
    check members(EnvBound) == @["owner-default", "consumer-a"]

  test "a FAILING environment rolls back the contribution row too":
    # The defect this case exists for was INTRODUCED by L8 and found by
    # reading rather than by a failure: `applyEnvironment` is
    # all-or-nothing and snapshotted only `dslPortOverrides`, while a
    # binding to a CONTRIBUTION POINT now writes the contribution
    # registry instead. A half-applied environment would therefore have
    # restored its scalar half and left its collection half in force.
    #
    # DRIVEN THROUGH THE REAL `applyEnvironment`, over a real applier
    # registered through the real `registerEnvironment` /
    # `registerEnvironmentApplier` — which is the pair the `environment`
    # macro itself emits. The applier binds the contribution point and
    # THEN raises, which is the "a binding that raised partway" shape
    # §6's all-or-nothing paragraph names. A test that re-implemented
    # the snapshot/restore pattern instead would assert that the
    # pattern works, not that `applyEnvironment` uses it.
    resetConfigurable(EnvBound)
    let before = members(EnvBound)
    let snapshot = contributionSnapshot()
    defer: restoreContributions(snapshot)
    registerEnvironment(DslEnvironmentDef(
      packageName: "l8MatrixOwner", name: "l8RollbackProbe"))
    registerEnvironmentApplier("l8MatrixOwner", "l8RollbackProbe",
      proc () {.closure.} =
        bindEnvironmentConfigurable("l8MatrixOwner", "l8RollbackProbe",
          EnvBound, @["from-a-failing-environment"])
        raise newException(EDslPortMissingKey,
          "the second binding of this environment cannot be applied"))
    var raised = false
    try:
      applyEnvironment("l8MatrixOwner", "l8RollbackProbe")
    except EDslPortMissingKey:
      raised = true
    check raised
    # The point: the FIRST binding is gone, because BOTH registries were
    # restored. Without the contribution half it would still be there.
    check members(EnvBound) == before
    check "from-a-failing-environment" notin members(EnvBound)

suite "L8: an EMPTY contribution point contributes nothing to argv":

  test "it folds to the empty collection":
    check members(EmptyPoint).len == 0

  test "and puts NO token on the service's argv, not an empty one":
    # An empty-string argument would reach the service as a positional
    # it cannot parse; no token is the only honest answer.
    clearRegisteredServices("l8MatrixOwner")
    let pkg = pkgDef()
    discard buildPackageDevEnv(pkg, devEnvRequest(pkg, "sso"),
      devEnvL8MatrixOwnerPackage)
    var argv: seq[string] = @[]
    var found = false
    for svc in registeredServices("l8MatrixOwner"):
      if svc.serviceName != "zitadelEmpty": continue
      found = true
      for arg in svc.typedArgs:
        argv.add(arg.value)
    check found
    check argv == @["--only-this"]

suite "L8: `converge` resolves a contribution point or refuses by name":

  test "an unknown point is refused, naming the declared points":
    var raised = false
    try:
      discard resolveServiceConvergePoint("l8MatrixOwner", "notAPoint")
    except EDslPortMissingKey as e:
      raised = true
      check "notAPoint" in e.msg
      check "l8MatrixOwner.sso.appendLow" in e.msg
    check raised

  test "a known point resolves to the fully qualified key":
    check resolveServiceConvergePoint("l8MatrixOwner", "appendLow") ==
      AppendLow

  test "a package with no points at all says so rather than nothing":
    var raised = false
    try:
      discard resolveServiceConvergePoint("noSuchPackage", "x")
    except EDslPortMissingKey as e:
      raised = true
      check "(none)" in e.msg
    check raised

suite "L8: the contributed members reach the service's argv":

  test "a service's argv carries the folded collection, from two packages":
    # Re-lowered through the REAL `buildPackageDevEnv`, the way L5's
    # argv test does, because a service body is evaluated when the
    # activity is invoked rather than at module init.
    clearRegisteredServices("l8MatrixOwner")
    let pkg = pkgDef()
    discard buildPackageDevEnv(pkg, devEnvRequest(pkg, "sso"),
      devEnvL8MatrixOwnerPackage)
    var argv: seq[string] = @[]
    var found = false
    for svc in registeredServices("l8MatrixOwner"):
      if svc.serviceName != "zitadel": continue
      found = true
      for arg in svc.typedArgs:
        argv.add(arg.value)
    check found
    check argv == @["start-from-init", "--relying-parties",
                    "owner-default", "consumer-a", "cell"]

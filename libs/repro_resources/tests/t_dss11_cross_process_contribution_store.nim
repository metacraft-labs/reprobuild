## Shared-Development-Services D-SS11 (§4.6) — THE CROSS-PROCESS
## CONTRIBUTION STORE: the identity-keyed record a consumer deposits
## into and the owner's converge reads, and the fold that turns it into
## the member list the instance registers.
##
## §4.6 requires two things of this lane, both of them refusals:
##
##   * "a contribution to a point the running instance **does not
##     declare** must be refused, never dropped -- including across a
##     version skew, where the running instance was built from an older
##     definition that lacks the point. §4.3's three outcomes already
##     decide the skew case; a contribution to an absent point is the
##     refusing row, not the warning row";
##   * §5.1's: a consumer "must be able to `append` ... and must **not**
##     be able to `replace`", "because a consumer that could replace them
##     would fork the instance it is trying to join".
##
## AND ONE PROPERTY THAT IS NOT A REFUSAL: the algebra is L8's, called
## rather than reimplemented. `foldCrossProcessContributions` calls
## `foldContributionRows`, which is `foldContributionPoint`'s own body
## after this change -- so "which append wins" has one answer for both
## lanes. The suite below measures that by checking the priority
## ordering a second implementation would have had to get right
## independently.
##
## WHY THE OWNER MUST READ THE STORE AT ALL, measured as a property
## rather than asserted in prose: `reconcileServiceRegistrations`
## REMOVES a member no longer contributed (§5's withdrawal property), so
## an owner that reconciled only its own folded members would withdraw
## every consumer's registration on its next converge. The
## "registrations survive the owner's converge" case below is that
## measurement.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED.
## Every contribution set goes into a real `StateStore` on a real
## filesystem under a throwaway root; every key comes from the real
## `serviceInstanceKey`; every fold goes through the real
## `foldContributionRows` in `repro_project_dsl`; and the registration
## reconcile is the real `reconcileServiceRegistrations` with a real
## deterministic minter closure.
##
## THE ONE INJECTED FUNCTION IS NOT A SEAM FOR A DOUBLE. The minter
## passed to `reconcileServiceRegistrations` is a parameter of that proc
## by design -- `service_registry.nim` must not know how to talk to a
## running identity provider -- and the closure here is the same shape
## the CLI passes: a deterministic digest of the instance address and the
## member. It is the only minter that exists outside a live issuer, and
## L8's own suite uses it for the same reason.

import std/[options, os, strutils, tables, times, unittest]

import repro_project_dsl
import repro_resources/service_identity
import repro_resources/service_registry
import repro_resources/instance # ResourceDeterminism (rdVolatile)
import repro_resources/state_store

const
  Owner = "dss11owner"
  LoudConsumer = "dss11loud"
  QuietConsumer = "dss11quiet"
  PointA = "relyingParties"
  PointB = "fixtureUsers"
  UndeclaredPoint = "nosuchPoint"
  DeclaredPoints = [PointA, PointB]

var caseCounter = 0

proc throwawayRoot(label: string): string =
  ## A throwaway directory, never `.repro/` and never a live tree — the
  ## campaign's working-agreement guardrail for every instance-identity
  ## experiment.
  caseCounter.inc
  result = getTempDir() / ("repro-dss11-" & $getCurrentProcessId() & "-" &
    $caseCounter & "-" & label)
  createDir(result)

proc keyFor(root: string): ServiceInstanceKey =
  ## A real instance key through the real derivation. `workspaceId` is
  ## supplied because the service declares `scope workspace`: without it
  ## `resolveServiceScope` correctly DEGRADES to `project` and reports
  ## it, and this file would be measuring the degradation.
  serviceInstanceKey(
    DslServiceDef(
      packageName: Owner, serviceName: "idp",
      identity: ServiceIdentityDef(kind: sikStable,
        stableId: "com.example.dss11.idp"),
      scope: sscWorkspace),
    ServiceScopeContext(projectRoot: canonicalRoot(root),
      workspaceRoot: canonicalRoot(root), workspaceId: "dss11-workspace",
      user: "dss11tester"),
    [], "development")

proc contribution(point, contributor: string; members: seq[string];
                  precedence = "epSet"; operation = "coAppend";
                  site = "recipe.nim:1"): ServiceContribution =
  ServiceContribution(point: point, contributor: contributor,
    operation: operation, precedence: precedence, members: members,
    site: site)

proc minter(address: string): ServiceRegistrationMinter =
  ## The same shape the CLI passes: a deterministic identifier derived
  ## from the instance address and the member. Deterministic so a reused
  ## registration is BYTE-IDENTICAL on a second reconcile, which is the
  ## property L8 built `reconcileServiceRegistrations` for.
  result = proc (member, contributor: string): string {.closure.} =
    "mint-" & $address.len & "-" & member

suite "D-SS11 §4.6 — the store is identity-keyed and round-trips":
  test "the address is the instance's own, with a contributions suffix":
    let key = keyFor(throwawayRoot("address"))
    check serviceContributionsAddress(key) ==
      serviceInstanceAddress(key) & ServiceContributionsAddressSuffix
    # §4.4: keyed by identity, never by path. Two different project
    # roots under one workspace identity reach the SAME address, which
    # is the whole point of the lane -- otherwise a contribution would
    # belong to whichever checkout deposited it.
    check serviceContributionsAddress(keyFor(throwawayRoot("other"))) ==
      serviceContributionsAddress(key)

  test "a deposited set reads back field for field":
    let root = throwawayRoot("roundtrip")
    let key = keyFor(root)
    let deposited = depositServiceContributions(root, key, LoudConsumer,
      [contribution(PointA, LoudConsumer, @["loud-a", "loud-b"]),
       contribution(PointB, LoudConsumer, @["dev@dss11.test"],
         precedence = "epOverride", site = "recipe.nim:42")])
    check deposited.added == 2
    check deposited.replaced == 0
    let read = readServiceContributions(root, key)
    check read.contributions.len == 2
    check read.contributions[0].point == PointA
    check read.contributions[0].contributor == LoudConsumer
    check read.contributions[0].members == @["loud-a", "loud-b"]
    check read.contributions[0].precedence == "epSet"
    check read.contributions[1].precedence == "epOverride"
    check read.contributions[1].site == "recipe.nim:42"

  test "an absent record reads as an EMPTY set rather than raising":
    let root = throwawayRoot("absent")
    let read = readServiceContributions(root, keyFor(root))
    check read.contributions.len == 0
    check read.address == serviceContributionsAddress(keyFor(root))

  test "a set written by a FUTURE version is refused by name":
    # Not read as "no contributions here", and the reason is in the
    # refusal: that reading would make the owner's next converge
    # withdraw every consumer's registration because of a format
    # boundary.
    let root = throwawayRoot("future")
    let key = keyFor(root)
    let store = openStateStore(root)
    store.writeStateRecord(ResourceStateRecord(
      address: serviceContributionsAddress(key),
      typeId: ServiceContributionsTypeId,
      determinism: rdVolatile,
      attrsTypeId: ServiceContributionsAttrsTypeId & "-from-the-future",
      attrsJson: "{}",
      identity: key.identity,
      present: true,
      holders: initTable[string, Time](),
      effectiveDeadline: none(Time),
      lastRenewed: getTime()))
    var raised = false
    try:
      discard readServiceContributions(root, key)
    except ValueError as err:
      raised = true
      check "would make this instance's cross-process contributions " &
        "look absent" in err.msg
      check "WITHDRAW every registration" in err.msg
    check raised

suite "D-SS11 §5 — one contributor, one slot":
  test "a deposit replaces only the depositing package's rows":
    let root = throwawayRoot("replace-own")
    let key = keyFor(root)
    discard depositServiceContributions(root, key, LoudConsumer,
      [contribution(PointA, LoudConsumer, @["loud-first"])])
    discard depositServiceContributions(root, key, QuietConsumer,
      [contribution(PointA, QuietConsumer, @["quiet-only"])])
    let second = depositServiceContributions(root, key, LoudConsumer,
      [contribution(PointA, LoudConsumer, @["loud-second"])])
    check second.replaced == 1
    check second.added == 1
    var members: seq[string] = @[]
    for c in readServiceContributions(root, key).contributions:
      for m in c.members:
        members.add(m)
    check "quiet-only" in members
    check "loud-second" in members
    check "loud-first" notin members

  test "an EMPTY deposit is a withdrawal, not a no-op":
    # A consumer whose recipe no longer contributes must stop
    # contributing, and the only way its `repro up` can say so is by
    # depositing nothing. Skipping the write would leave last week's
    # members registered forever with nothing asking for them.
    let root = throwawayRoot("withdraw")
    let key = keyFor(root)
    discard depositServiceContributions(root, key, LoudConsumer,
      [contribution(PointA, LoudConsumer, @["gone-next-time"])])
    discard depositServiceContributions(root, key, QuietConsumer,
      [contribution(PointA, QuietConsumer, @["stays"])])
    let withdrawn = depositServiceContributions(root, key, LoudConsumer, [])
    check withdrawn.replaced == 1
    check withdrawn.added == 0
    let read = readServiceContributions(root, key)
    check read.contributions.len == 1
    check read.contributions[0].contributor == QuietConsumer

  test "a deposit with no contributor is refused":
    let root = throwawayRoot("nocontributor")
    var raised = false
    try:
      discard depositServiceContributions(root, keyFor(root), "", [])
    except ServiceRegistryError as err:
      raised = true
      check "needs the contributing package" in err.msg
    check raised

  test "a deposit carrying another package's row is refused":
    # A mixed batch would write rows this deposit cannot replace later,
    # or silently re-attribute them.
    let root = throwawayRoot("mixedbatch")
    var raised = false
    try:
      discard depositServiceContributions(root, keyFor(root), LoudConsumer,
        [contribution(PointA, QuietConsumer, @["x"])])
    except ServiceRegistryError as err:
      raised = true
      check "attributed to `" & QuietConsumer & "`" in err.msg
    check raised

suite "D-SS11 §4.6 — a contribution to an undeclared point is REFUSED":
  test "an undeclared point is refused by name, with the declared set":
    var raised = false
    try:
      validateServiceContributions(DeclaredPoints,
        [contribution(UndeclaredPoint, LoudConsumer, @["x"],
          site = "recipe.nim:7")], "service:probe")
    except ServiceRegistryError as err:
      raised = true
      check "contributes to `" & UndeclaredPoint & "`" in err.msg
      check "declares no such contribution point" in err.msg
      check "`" & PointA & "`" in err.msg
      check "`" & PointB & "`" in err.msg
      check "recipe.nim:7" in err.msg
      check "refusing row, not the warning row" in err.msg
    check raised

  test "the VERSION-SKEW case is the same refusal, and it is reached":
    # The skew: the running instance was built from an older definition
    # that converges ONE point, while the consumer compiled against a
    # newer one that converges two. The consumer's compile-time check
    # passed -- the owner's artifact on disk declares the point -- and
    # the refusal has to happen here, against what the INSTANCE
    # declares.
    var raised = false
    try:
      validateServiceContributions([PointA],
        [contribution(PointA, LoudConsumer, @["fine"]),
         contribution(PointB, LoudConsumer, @["too-new"])],
        "service:probe")
    except ServiceRegistryError as err:
      raised = true
      check "contributes to `" & PointB & "`" in err.msg
      check "It converges `" & PointA & "`" in err.msg
    check raised

  test "an instance that declares NO points refuses and says so":
    var raised = false
    try:
      validateServiceContributions([],
        [contribution(PointA, LoudConsumer, @["x"])], "service:probe")
    except ServiceRegistryError as err:
      raised = true
      check "no contribution points at all" in err.msg
    check raised

  test "a declared point is NOT refused":
    # The positive control. Without it every assertion above would pass
    # for an implementation that refused every contribution.
    #
    # The assertion is on the FOLD's output rather than on "no exception
    # was raised": a case whose only claim is `check true` is the vacuous
    # shape this repository's own lint gate refuses, and it would also
    # pass for a `validateServiceContributions` that returned without
    # looking at anything.
    validateServiceContributions(DeclaredPoints,
      [contribution(PointA, LoudConsumer, @["x"]),
       contribution(PointB, QuietConsumer, @["y"])], "service:probe")
    let folded = foldCrossProcessContributions(DeclaredPoints,
      [contribution(PointA, LoudConsumer, @["x"]),
       contribution(PointB, QuietConsumer, @["y"])], "service:probe")
    check folded.members == @["x", "y"]
    check folded.contributors == @[LoudConsumer, QuietConsumer]

  test "a stored `replace` is refused, at every priority":
    for op in ["coReplace"]:
      for prec in ["epSet", "epOverride", "epForce"]:
        var raised = false
        try:
          validateServiceContributions(DeclaredPoints,
            [contribution(PointA, LoudConsumer, @["x"],
              precedence = prec, operation = op)], "service:probe")
        except ServiceRegistryError as err:
          raised = true
          # ASSERTED AGAINST THE HELPER'S OWN OUTPUT, not against a
          # hand-typed fragment of it. §5.1's judgement is refused at
          # three stages and used to be typed out three times in three
          # phrasings; it now has one source
          # (`sharedServiceReplaceRefusal`), and a test that re-typed a
          # substring of it would be a fourth copy free to drift from
          # the other three. This assertion cannot drift: if the shared
          # wording changes, it follows, and if this site stops using
          # the shared wording, it fails.
          check sharedServiceReplaceRefusal() in err.msg
          # …and the part that is genuinely THIS stage's, which the
          # shared text deliberately does not contain. Without this the
          # case would pass for a converge site that printed the shared
          # judgement and dropped the reason the owner refuses too.
          check "discard every other consumer's appends" in err.msg
        check raised

  test "a contribution with no members is refused":
    var raised = false
    try:
      validateServiceContributions(DeclaredPoints,
        [contribution(PointA, LoudConsumer, @[])], "service:probe")
    except ServiceRegistryError as err:
      raised = true
      check "contributes NO members" in err.msg
    check raised

  test "an unknown precedence word is refused rather than defaulted":
    # `epDefault` is the LOWEST rung, so a mis-read word would demote an
    # `appendForce` to the rung a `replace` discards and the member would
    # vanish with a step-4 diagnostic nobody asked for.
    var raised = false
    try:
      discard foldCrossProcessContributions(DeclaredPoints,
        [contribution(PointA, LoudConsumer, @["x"],
          precedence = "epWhatever")], "service:probe")
    except ServiceRegistryError as err:
      raised = true
      check "which this build does not know" in err.msg
    check raised

suite "D-SS11 §5 — the fold is L8's, and it is called rather than redone":
  test "members are attributed to the package that contributed them":
    let folded = foldCrossProcessContributions(DeclaredPoints,
      [contribution(PointA, LoudConsumer, @["loud-a"]),
       contribution(PointA, QuietConsumer, @["quiet-a"]),
       contribution(PointB, LoudConsumer, @["loud-b"])],
      "service:probe")
    check folded.members.len == folded.contributors.len
    check folded.members == @["loud-a", "quiet-a", "loud-b"]
    check folded.contributors == @[LoudConsumer, QuietConsumer, LoudConsumer]

  test "a higher-priority append lands AFTER a lower one, never instead":
    # `Configurable-System.md` §Resolution steps 3 and 4: appends apply
    # "in priority order and then contribution order", and an `append`
    # is never destructive at any priority. A second implementation of
    # the fold would have had to get this right independently; this
    # case is what says it did not have to.
    let folded = foldCrossProcessContributions([PointA],
      [contribution(PointA, LoudConsumer, @["forced"],
        precedence = "epForce"),
       contribution(PointA, QuietConsumer, @["plain"],
         precedence = "epSet"),
       contribution(PointA, "third", @["override"],
         precedence = "epOverride")],
      "service:probe")
    check folded.members == @["plain", "override", "forced"]
    check folded.contributors == @[QuietConsumer, "third", LoudConsumer]

  test "points are folded in the INSTANCE's declaration order":
    # Not in store order: a store whose row order decided the result
    # would make the registration set depend on which consumer ran
    # first.
    let rows = [contribution(PointB, LoudConsumer, @["b-member"]),
                contribution(PointA, LoudConsumer, @["a-member"])]
    check foldCrossProcessContributions(DeclaredPoints, rows,
      "service:probe").members == @["a-member", "b-member"]
    check foldCrossProcessContributions([PointB, PointA], rows,
      "service:probe").members == @["b-member", "a-member"]

  test "no contributions fold to no members":
    let folded = foldCrossProcessContributions(DeclaredPoints, [],
      "service:probe")
    check folded.members.len == 0
    check folded.contributors.len == 0

suite "D-SS11 §4.6 — the owner's converge preserves a consumer's registration":
  test "a consumer's member survives the owner's next reconcile, byte-identical":
    # THE PROPERTY THE OWNER'S READ OF THE STORE EXISTS FOR.
    # `reconcileServiceRegistrations` removes a member no longer
    # contributed, so the first reconcile below is what the owner does
    # with the union and the second is what it would do WITHOUT the
    # store -- and the difference is a deleted registration.
    let root = throwawayRoot("preserve")
    let key = keyFor(root)
    let address = serviceInstanceAddress(key)
    discard depositServiceContributions(root, key, LoudConsumer,
      [contribution(PointA, LoudConsumer, @["consumer-rp"])])
    let stored = readServiceContributions(root, key)
    let folded = foldCrossProcessContributions(DeclaredPoints,
      stored.contributions, address)
    # The owner's own fold, plus the cross-process members: exactly what
    # `convergeSharedServiceInstances` passes.
    var members = @["owner-rp"]
    var contributors = @[Owner]
    for i in 0 ..< folded.members.len:
      members.add(folded.members[i])
      contributors.add(folded.contributors[i])
    let first = reconcileServiceRegistrations(root, key, members,
      contributors, minter(address))
    check first.set.registrations.len == 2
    let ownerMinted = mintedIdFor(first.set, "owner-rp")
    let consumerMinted = mintedIdFor(first.set, "consumer-rp")
    check ownerMinted.len > 0
    check consumerMinted.len > 0
    # The owner converges again with the union: nothing is re-minted and
    # nothing is withdrawn.
    let second = reconcileServiceRegistrations(root, key, members,
      contributors, minter(address))
    check mintedIdFor(second.set, "owner-rp") == ownerMinted
    check mintedIdFor(second.set, "consumer-rp") == consumerMinted
    for outcome in second.outcomes:
      check outcome.outcome == sroReused
    # THE NEGATIVE CONTROL: the owner converging with its OWN members
    # only -- which is what it did before this change -- WITHDRAWS the
    # consumer's registration. This is the measurement, not a claim.
    let withoutStore = reconcileServiceRegistrations(root, key,
      @["owner-rp"], @[Owner], minter(address))
    check mintedIdFor(withoutStore.set, "consumer-rp").len == 0
    var withdrawn = false
    for outcome in withoutStore.outcomes:
      if outcome.member == "consumer-rp" and
         outcome.outcome == sroWithdrawn:
        withdrawn = true
    check withdrawn

  test "a SECOND consumer arriving mints only its own member":
    # L8's byte-identical property, with the second consumer arriving
    # THROUGH THE RESOLVER's store rather than through the owner's
    # recipe -- which is the clause L9's gate carried forward.
    let root = throwawayRoot("second-consumer")
    let key = keyFor(root)
    let address = serviceInstanceAddress(key)
    discard depositServiceContributions(root, key, LoudConsumer,
      [contribution(PointA, LoudConsumer, @["loud-rp"])])
    proc unionFor(): tuple[members, contributors: seq[string]] =
      let folded = foldCrossProcessContributions(DeclaredPoints,
        readServiceContributions(root, key).contributions, address)
      result.members = @["owner-rp"]
      result.contributors = @[Owner]
      for i in 0 ..< folded.members.len:
        result.members.add(folded.members[i])
        result.contributors.add(folded.contributors[i])
    let before = unionFor()
    let firstPass = reconcileServiceRegistrations(root, key,
      before.members, before.contributors, minter(address))
    let ownerMinted = mintedIdFor(firstPass.set, "owner-rp")
    let loudMinted = mintedIdFor(firstPass.set, "loud-rp")
    discard depositServiceContributions(root, key, QuietConsumer,
      [contribution(PointA, QuietConsumer, @["quiet-rp"])])
    let after = unionFor()
    let secondPass = reconcileServiceRegistrations(root, key,
      after.members, after.contributors, minter(address))
    check secondPass.set.registrations.len == 3
    check mintedIdFor(secondPass.set, "owner-rp") == ownerMinted
    check mintedIdFor(secondPass.set, "loud-rp") == loudMinted
    check mintedIdFor(secondPass.set, "quiet-rp").len > 0
    var minted = 0
    var reused = 0
    for outcome in secondPass.outcomes:
      case outcome.outcome
      of sroMinted: inc minted
      of sroReused: inc reused
      of sroWithdrawn: check false
    check minted == 1
    check reused == 2
    # And the attribution names the right contributor for each.
    for reg in secondPass.set.registrations:
      case reg.member
      of "owner-rp": check reg.contributor == Owner
      of "loud-rp": check reg.contributor == LoudConsumer
      of "quiet-rp": check reg.contributor == QuietConsumer
      else: check false

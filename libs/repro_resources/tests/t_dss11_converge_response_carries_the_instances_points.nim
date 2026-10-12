## Shared-Development-Services D-SS11 (§4.6) — THE CONVERGE RESPONSE's
## CONTRIBUTION POINTS: which snapshot they come from, that they survive
## the wire, and that an older daemon's body still parses.
##
## WHY THIS FILE EXISTS. `applyServiceConverge` answers with
##
##     if decision.hadInstance:
##       contributionPointsOf(registry.entries[address].record.snapshot)
##     else:
##       contributionPointsOf(snapshot)          # the REQUEST's
##
## which §4.3 at `reprobuild-specs@8429bcf` now requires in writing: the
## two snapshots must be INDEPENDENTLY SOURCED or the check proves
## nothing. Before this file nothing measured it. A review's mutation
## collapsed the branch to the request's snapshot and the whole suite
## stayed green (the integration binary reported 3 OK / 0 FAILED after a
## correct `scripts/build_apps.sh` rebuild), because in the existing skew
## fixture the consumer's request snapshot is DERIVED from the owner's
## stale artifact -- both arms carry the same one-point set and the
## comparison agrees vacuously. `grep` also found no test anywhere
## referencing `DaemonServiceConvergeResponse.contributionPoints`: not
## the branch, not the body's round-trip, not the older-daemon guard.
##
## The three suites below are those three gaps, in that order.
##
## WHAT MAKES THE FIRST SUITE DISCRIMINATE, and it is the point of the
## fixture rather than of the assertions: the registry entry is
## materialised from `dss11CvOne` (which converges ONE point) and the
## converge request carries `dss11CvBoth`'s snapshot (which converges
## TWO). The two sets are genuinely different and genuinely
## independently produced -- two separate `package` definitions, each
## lifted by the real macro -- so reading the wrong snapshot changes the
## answer. See `dss11_converge_fixtures.nim` for why they differ in
## exactly one declared way.
##
## BOTH DIRECTIONS ARE MEASURED. The instance-declares-fewer case and
## the instance-declares-more case are separate tests, because a single
## direction would also pass for an implementation that always answered
## with the shorter list, or with the intersection, or with whichever
## snapshot happened to be scanned first.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED.
## Specifically:
##
## * both interface snapshots come from real `package` blocks in
##   `dss11_converge_fixtures.nim`, expanded by the real DSL macro and
##   lifted by the real `toProjectInterface`;
## * the instance key comes from the real `serviceInstanceKey` over the
##   fixture's own declared identity and scope;
## * the registry is a real `openServiceInstanceRegistry` over a real
##   `StateStore` on a real filesystem under a throwaway root;
## * the running instance is a REAL detached child process, started by
##   the real `materialiseServiceInstanceProcess` the daemon calls and
##   stopped by the real `stopServiceInstanceProcess`;
## * the liveness probe is the real `writerLiveness`, reached through the
##   real `serviceInstanceLivenessProbe` the daemon installs;
## * the request and response are driven through the real
##   `applyServiceConverge` -- the daemon's own `udkServiceConverge`
##   handler body -- and the real `encodeServiceInstanceKey` /
##   `encodeServiceInterfaceSnapshot`, so the request this file builds is
##   the one the CLI sends;
## * the wire suites use the real `serviceConvergeResponseBody` /
##   `parseServiceConvergeResponseBody`.
##
## ONE CONSTRUCTED VALUE IS USED, AND IT IS NOT A DOUBLE OF ANYTHING.
## The older-daemon case needs a response body as a daemon built BEFORE
## D-SS11 wrote one. There is no such daemon to run, and hand-typing the
## bytes would be a guess about the other eight fields. So the body is
## produced by the REAL encoder with an EMPTY point list and its last
## four bytes are removed -- `writeStringSeq(@[])` is exactly
## `writeU32Le(0)`, four bytes, which the case asserts before relying on
## it. Every other byte is the real encoder's. This is the same technique
## (and the same justification) that `l6_attach_fixtures`-era suites use
## for a superseded envelope: write it with the current encoder at the
## older shape rather than typing a byte string.
##
## THE ONE INJECTED FUNCTION IS NOT A SEAM FOR A DOUBLE.
## `ServiceInstanceRegistry.probe` exists because `writerLiveness` lives
## in `repro_daemon_core`, which DEPENDS ON `repro_resources` — so
## `service_registry.nim` cannot import it without a library cycle. This
## file installs the real one, which is the only one that exists. The
## same note appears in
## `t_l7_instance_registry_converges_in_any_order.nim`, for the same
## reason.
##
## Governing text — `Shared-Development-Services.md`:
##
## * §4.6: a contribution to a point "the running instance does not
##   declare" is refused, "including across a version skew, where the
##   running instance was built from an older definition that lacks the
##   point";
## * §4.3 (at `reprobuild-specs@8429bcf`): the two snapshots the
##   comparison reads must be independently sourced.

import std/[options, os, strutils, tables, times, unittest]

import repro_project_dsl
import repro_interface_artifacts
import repro_resources
import repro_resources/service_attach
import repro_resources/service_identity
import repro_resources/service_registry

# The REAL daemon-side half: the converge handler body, the liveness
# probe, the materialiser and the stop. Imported rather than
# reimplemented so this file measures the code the daemon runs.
import repro_daemon_core
import repro_daemon_core/instance_registry
import repro_daemon_core/writer_identity

import ./dss11_converge_fixtures

const
  OnePointPackage = "dss11CvOne"
  BothPointsPackage = "dss11CvBoth"
  NoPointsPackage = "dss11CvNone"
  ServiceName = "zitadel"
  PointA = "relyingParties"
  PointB = "fixtureUsers"

# ---------------------------------------------------------------------------
# Snapshots and keys, from the real lift. The projections are the same
# four `t_l7_instance_registry_converges_in_any_order.nim` uses, and are
# duplicated for the reason that file records for duplicating L6's: the
# sibling keeps them private, and copying three short projections is
# cheaper than widening that file's surface for this one.
# ---------------------------------------------------------------------------

proc packageDefNamed(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError,
    "fixture drift: no package named " & name & " is registered")

proc normalisedInterface(name: string): ProjectInterface =
  ## The lifted interface with every PACKAGE-DERIVED HANDLE TYPE replaced
  ## by a constant, undoing the same artifice L6's lift fixtures undo:
  ## the scenario is ONE package edited between two revisions, the two
  ## fixtures cannot share a name inside one module, and the handle type
  ## is derived from the package name -- so without this the pair would
  ## differ on `handleType` as well as on the converge list, and the
  ## fixture's one-declared-difference discipline would be a fiction.
  result = toProjectInterface(packageDefNamed(name))
  for act in result.publicActivities.mitems:
    act.handleType = "NormalisedHandle_" & act.name
  for svc in result.publicServices.mitems:
    if svc.handleType.len > 0:
      svc.handleType = "NormalisedHandle_" & svc.activityName

proc snapshotOf(package: string): ServiceInterfaceSnapshot =
  serviceInterfaceSnapshot(normalisedInterface(package), ServiceName)

proc declaredDefFromLift(package: string): DslServiceDef =
  let pi = normalisedInterface(package)
  for svc in pi.publicServices:
    if svc.name != ServiceName:
      continue
    return DslServiceDef(
      packageName: package, serviceName: svc.name,
      identity: ServiceIdentityDef(
        kind: ServiceIdentityKind(ord(svc.identityMode)),
        stableId: svc.identityStableId),
      scope: ServiceScope(ord(svc.scope)))
  raise newException(ValueError,
    "fixture drift: " & package & " lifts no service " & ServiceName)

var caseCounter = 0

proc throwawayRoot(label: string): string =
  ## A throwaway directory, never `.repro/` and never a live tree — the
  ## campaign's working-agreement guardrail for every instance-identity
  ## experiment.
  caseCounter.inc
  result = getTempDir() / ("repro-dss11cv-" & $getCurrentProcessId() &
    "-" & $caseCounter & "-" & label)
  createDir(result)

proc scopeContext(root: string): ServiceScopeContext =
  ## `workspaceId` is supplied because the fixtures declare `scope
  ## workspace`: without it `resolveServiceScope` correctly DEGRADES to
  ## `project` and reports it, and the address would be a project-scoped
  ## one — which would make this file measure the degradation rather than
  ## the response.
  ServiceScopeContext(projectRoot: canonicalRoot(root),
    workspaceRoot: canonicalRoot(root), workspaceId: "dss11cv-workspace",
    user: "dss11cvtester")

proc keyFor(root: string): ServiceInstanceKey =
  ## ONE key for both fixtures, which is the scenario: the identity and
  ## the scope are declared identically in both packages (so they ARE one
  ## instance), and only the converge list differs. Through the real
  ## `serviceInstanceKey` over a real `ServiceIdentityDef`.
  serviceInstanceKey(declaredDefFromLift(OnePointPackage),
    scopeContext(root), [], "dev")

# ---------------------------------------------------------------------------
# Real instances: real detached child processes.
# ---------------------------------------------------------------------------

proc instanceCommand(): seq[string] =
  @["sh", "-c", "while :; do sleep 1; done"]

var spawned: seq[ServiceInstanceProcess] = @[]

proc materialise(workingDir: string): ServiceInstanceProcess =
  ## Through the REAL daemon materialiser, and recorded so the teardown
  ## reaps anything a failing case leaves behind. A leaked `sleep` loop
  ## would outlive the suite.
  result = materialiseServiceInstanceProcess(instanceCommand(), workingDir)
  spawned.add(result)

proc reapEverySpawnedInstance() =
  for process in spawned:
    discard stopServiceInstanceProcess(process, graceMs = 1500)
  spawned.setLen(0)

proc freshRegistry(storeRoot: string): ServiceInstanceRegistry =
  openServiceInstanceRegistry(storeRoot, serviceInstanceLivenessProbe())

proc convergeRequestFor(key: ServiceInstanceKey; package, holderId,
                        workingDir: string): DaemonServiceConvergeRequest =
  ## The request the CLI sends, built with the real encoders the protocol
  ## documents as the only way these two values cross the frame.
  DaemonServiceConvergeRequest(
    scope: dlsUser,
    keyJson: encodeServiceInstanceKey(key),
    snapshotJson: encodeServiceInterfaceSnapshot(snapshotOf(package)),
    holderId: holderId,
    ttlSeconds: -1,          ## negative == `keep`, per the field's doc
    command: instanceCommand(),
    workingDir: workingDir,
    replace: false,
    force: false)

proc materialiseFrom(registry: var ServiceInstanceRegistry;
                     key: ServiceInstanceKey;
                     package, holderId, workingDir: string) =
  ## Put a RUNNING instance in the registry whose persisted snapshot is
  ## `package`'s. Driven through `applyServiceConverge` itself rather
  ## than through `recordMaterialisedInstance` directly, so the entry
  ## this file then reads was written by the same handler body the cases
  ## are about.
  let response = applyServiceConverge(registry,
    convergeRequestFor(key, package, holderId, workingDir))
  doAssert response.ok,
    "fixture could not materialise the instance: " & response.diagnostic
  doAssert response.outcome == outcomeWord(scoMaterialise),
    "fixture expected a materialise and got " & response.outcome &
    ": " & response.diagnostic
  for address, entry in registry.entries:
    spawned.add(entry.record.process)

suite "D-SS11 §4.6 — the converge response reports the INSTANCE's points":
  teardown:
    # AFTER EVERY CASE, including a failing one. `unittest`'s `teardown`
    # runs on the way out of each `test` body whether it passed or
    # raised, which is why the reap is here rather than at the end of
    # each body: a case that fails an early `check` and aborts would
    # otherwise leave its `sleep` loop running for the rest of the
    # suite, and the sibling L7 file -- which calls the reap explicitly
    # at the end of each body -- leaks exactly that way.
    reapEverySpawnedInstance()

  test "the running instance declares FEWER points than the request asks about":
    # THE CASE THE SURVIVING MUTATION NEEDED. The instance is
    # materialised from the definition that converges ONE point; the
    # request carries the definition that converges TWO. A response
    # built from the REQUEST's snapshot would say two, and a consumer
    # contributing to the second point would be told the instance
    # accepts it -- which is the silent drop §4.6 exists to refuse.
    let root = throwawayRoot("fewer")
    var registry = freshRegistry(root / "store")
    let key = keyFor(root)
    let holder = serviceLeaseHolderId(throwawayRoot("consumer-fewer"))
    registry.materialiseFrom(key, OnePointPackage, holder, root)

    # The premise, asserted rather than assumed: the two fixtures really
    # do declare different sets. If this failed, every assertion below
    # would pass vacuously -- which is exactly how the previous fixture
    # failed to measure this branch.
    check contributionPointsOf(snapshotOf(OnePointPackage)) == @[PointA]
    check contributionPointsOf(snapshotOf(BothPointsPackage)) ==
      @[PointA, PointB]

    let response = applyServiceConverge(registry,
      convergeRequestFor(key, BothPointsPackage, holder, root))
    checkpoint("outcome=" & response.outcome &
      " diagnostic=" & response.diagnostic &
      " points=" & response.contributionPoints.join(","))
    check response.ok
    # An ATTACH, not a materialise and not a refusal: that is what makes
    # `hadInstance` true and the branch reachable at all.
    check response.hadInstance
    # THE ASSERTION. The instance's set, not the request's.
    check response.contributionPoints == @[PointA]
    check PointB notin response.contributionPoints

  test "the running instance declares MORE points than the request asks about":
    # The other direction, and it is not a restatement. With only the
    # case above, an implementation that answered with the SHORTER of
    # the two lists, or with their intersection, would pass. Here the
    # instance's set is the longer one, so those implementations fail.
    let root = throwawayRoot("more")
    var registry = freshRegistry(root / "store")
    let key = keyFor(root)
    let holder = serviceLeaseHolderId(throwawayRoot("consumer-more"))
    registry.materialiseFrom(key, BothPointsPackage, holder, root)

    let response = applyServiceConverge(registry,
      convergeRequestFor(key, OnePointPackage, holder, root))
    checkpoint("outcome=" & response.outcome &
      " diagnostic=" & response.diagnostic &
      " points=" & response.contributionPoints.join(","))
    check response.ok
    check response.hadInstance
    check response.contributionPoints == @[PointA, PointB]

  test "THE CONTROL: with NO instance running, the REQUEST's points are reported":
    # The `else` arm, and the pair's other half. Without it, every
    # assertion above would also pass for an implementation that ignored
    # the request's snapshot entirely and always read the registry --
    # and that implementation would answer an empty list on the
    # materialise path, where there is no entry to read yet.
    let root = throwawayRoot("control")
    var registry = freshRegistry(root / "store")
    let key = keyFor(root)
    let holder = serviceLeaseHolderId(throwawayRoot("consumer-control"))
    let response = applyServiceConverge(registry,
      convergeRequestFor(key, BothPointsPackage, holder, root))
    checkpoint("outcome=" & response.outcome &
      " diagnostic=" & response.diagnostic &
      " points=" & response.contributionPoints.join(","))
    check response.ok
    check not response.hadInstance
    check response.outcome == outcomeWord(scoMaterialise)
    check response.contributionPoints == @[PointA, PointB]
    for address, entry in registry.entries:
      spawned.add(entry.record.process)

  test "the reported set is the instance's EVEN WHEN the request declares none":
    # The degenerate direction of the same branch, and the one a
    # `contributionPoints` that defaulted to empty would survive: an
    # older consumer whose snapshot carries no points at all must not
    # make the daemon forget what the instance converges, because the
    # answer is what the CLI refuses a misspelled contribution against.
    let root = throwawayRoot("emptyreq")
    var registry = freshRegistry(root / "store")
    let key = keyFor(root)
    let holder = serviceLeaseHolderId(throwawayRoot("consumer-emptyreq"))
    registry.materialiseFrom(key, BothPointsPackage, holder, root)

    # The request carries a REAL definition that converges nothing --
    # `dss11CvNone` -- rather than a snapshot with its contribution-point
    # members removed by hand. The fixture module records what went wrong
    # with the hand-stripped version and why it made this case vacuous.
    check contributionPointsOf(snapshotOf(NoPointsPackage)).len == 0
    let response = applyServiceConverge(registry,
      convergeRequestFor(key, NoPointsPackage, holder, root))
    checkpoint("outcome=" & response.outcome &
      " diagnostic=" & response.diagnostic &
      " points=" & response.contributionPoints.join(","))
    check response.ok
    check response.hadInstance
    # A WARNING attach, which is the shape that says the two snapshots
    # really differ. The hand-stripped draft of this case produced
    # `AttachSilently` with an empty diagnostic -- the two fingerprints
    # compared equal -- and that is what revealed it was measuring
    # nothing. Asserted here so the fixture cannot quietly regress to
    # that.
    check response.outcome == outcomeWord(scoAttachWithWarning)
    check response.contributionPoints == @[PointA, PointB]

suite "D-SS11 §4.6 — the points survive the response frame":
  test "a point list round-trips through the response body, in order":
    # Nothing referenced `DaemonServiceConvergeResponse.contributionPoints`
    # on the wire before this case. The field is appended at the END of
    # the body, so a writer and a reader that disagreed about it would
    # corrupt nothing above it and would simply lose the points -- a
    # silent drop, which is the failure mode this lane is built to
    # refuse.
    let original = DaemonServiceConvergeResponse(
      ok: true, outcome: outcomeWord(scoAttachWithWarning),
      diagnostic: "a diagnostic, so the field above is non-empty too",
      address: "service:dss11cv:probe", pid: 4242,
      hadInstance: true, holderSetRecoverable: true,
      holders: @["holder:one", "holder:two"],
      contributionPoints: @[PointA, PointB])
    let decoded = parseServiceConvergeResponseBody(
      serviceConvergeResponseBody(original))
    # ORDER, not set membership: §4.6 says "declaration order", and the
    # CLI prints the set in that order when it refuses a misspelling.
    check decoded.contributionPoints == @[PointA, PointB]
    # And the fields that precede it on the wire are intact, which is
    # what says the appended field did not shift anything.
    check decoded.ok == original.ok
    check decoded.outcome == original.outcome
    check decoded.diagnostic == original.diagnostic
    check decoded.address == original.address
    check decoded.pid == original.pid
    check decoded.hadInstance == original.hadInstance
    check decoded.holderSetRecoverable == original.holderSetRecoverable
    check decoded.holders == original.holders

  test "an EMPTY point list DECODES as an empty list":
    # TITLED FOR WHAT THE ONE ASSERTION BELOW MEASURES. It used to read
    # "round-trips as empty, not as absent", and the "not as absent"
    # half is a claim this body cannot make: it never looks at the
    # bytes, so "present and empty" and "absent" are indistinguishable
    # to it. The byte-level presence check is in the NEXT case, which
    # asserts the four count bytes are there before removing them. A
    # title that claims the distinction its body cannot draw is the
    # same defect class as a guard satisfiable by the change it guards
    # against: it reads as coverage that is somewhere else.
    #
    # A service that converges no points is a real state, so "empty"
    # has to survive as empty. This is also the control for the
    # older-daemon case below: that case removes these four bytes, so
    # this one establishes that with them present the answer is the same
    # empty list by a DIFFERENT route.
    let original = DaemonServiceConvergeResponse(
      ok: true, outcome: outcomeWord(scoAttachSilently),
      address: "service:dss11cv:probe", hadInstance: true,
      contributionPoints: @[])
    let body = serviceConvergeResponseBody(original)
    check parseServiceConvergeResponseBody(body).contributionPoints.len == 0

  test "a body an OLDER daemon wrote parses, with an empty point list":
    # The guard is `if pos < body.len` in
    # `parseServiceConvergeResponseBody`, and nothing exercised it. Its
    # whole purpose is that a newer CLI can still talk to a daemon built
    # before D-SS11: without it, every response from such a daemon would
    # fail to parse and the client could not talk to it at all.
    #
    # THE BODY IS THE REAL ENCODER'S, MINUS THE TRAILING FIELD. See the
    # file header for why that is the honest way to have one.
    let withEmpty = serviceConvergeResponseBody(
      DaemonServiceConvergeResponse(
        ok: true, outcome: outcomeWord(scoAttachSilently),
        diagnostic: "", address: "service:dss11cv:probe", pid: 7,
        hadInstance: true, holderSetRecoverable: true,
        holders: @["holder:one"], contributionPoints: @[]))
    # The premise of the construction, asserted before it is relied on:
    # an empty string seq is exactly a four-byte zero count, so removing
    # four bytes removes exactly this field and nothing else.
    check withEmpty.len > 4
    check withEmpty[^4 .. ^1] == @[0'u8, 0'u8, 0'u8, 0'u8]
    let olderBody = withEmpty[0 .. ^5]
    let decoded = parseServiceConvergeResponseBody(olderBody)
    check decoded.contributionPoints.len == 0
    # Everything the older daemon DID send is still read correctly --
    # which is the half of the guard that says it skipped a field rather
    # than mis-parsed one.
    check decoded.ok
    check decoded.outcome == outcomeWord(scoAttachSilently)
    check decoded.address == "service:dss11cv:probe"
    check decoded.pid == 7
    check decoded.hadInstance
    check decoded.holderSetRecoverable
    check decoded.holders == @["holder:one"]

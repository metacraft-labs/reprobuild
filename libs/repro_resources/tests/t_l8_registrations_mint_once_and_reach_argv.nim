## Shared-Development-Services L8 (§7) — A VALUE THE SERVICE MINTS IS A
## RESOURCE ATTRIBUTE, computed when the registration reconciles, and
## MINTED ONCE.
##
## The clause this file exists for, quoted from the gate: "a second
## consumer arriving **without** re-registering, renumbering or
## invalidating the first's — asserted on the first registration's
## identifier being byte-identical before and after, because
## re-registering an OIDC client mints a new client id and silently
## invalidates whatever was configured earlier".
##
## So the assertions are on BYTE-IDENTITY of the first registration
## across a second consumer's arrival, and on the MINTER NOT BEING
## CALLED for a member that already has one. The second is the stronger
## of the two: a minter that happened to be deterministic would satisfy
## byte-identity while really re-registering, which is exactly the
## failure mode (a real issuer's `POST /applications` is not
## deterministic, and the damage is done at the issuer rather than in
## the record).
##
## MOCK POLICY — ONE TEST DOUBLE, AND IT IS JUSTIFIED HERE.
## `ServiceRegistrationMinter` is injected, and these cases inject a
## counting one. It is NOT a mock standing in for a real collaborator
## this test could have used: there is no OIDC client and no identity
## provider in this repository, so the real minter does not exist to be
## called — L9 owns the shared identity provider. The injection is also
## the production shape, not a test seam: `repro_cli_support` passes its
## own minter at the converge site, exactly as the daemon passes the
## real liveness probe into `ServiceInstanceRegistry.probe`. Everything
## else here is real: a real `StateStore` on a real filesystem, the real
## `reconcileServiceRegistrations`, the real JSON codec.
##
## The COUNT is the point of the double. A real minter could not be
## asked "how many times were you called", and that question is the
## clause.

import std/[os, strutils, tables, times, unittest]

import repro_project_dsl
import repro_resources/service_identity
import repro_resources/service_registry

proc scratchRoot(tag: string): string =
  let root = getTempDir() / ("l8-reg-" & tag & "-" & $getCurrentProcessId())
  removeDir(root)
  createDir(root)
  root

proc testKey(): ServiceInstanceKey =
  serviceInstanceKey(
    DslServiceDef(
      packageName: "l8RegPkg",
      serviceName: "sso",
      identity: ServiceIdentityDef(kind: sikStable,
        stableId: "com.metacraft-labs.l8-registrations"),
      scope: sscWorkspace),
    discoverServiceScopeContext(getCurrentDir()),
    environment = "dev")

type Counter = ref object
  calls: int
  members: seq[string]

proc countingMinter(c: Counter): ServiceRegistrationMinter =
  proc (member, contributor: string): string {.closure.} =
    inc c.calls
    c.members.add(member)
    "minted-" & $c.calls & "-for-" & member

suite "L8: the registration lane mints once and persists":

  test "a first reconcile mints one identifier per member":
    let root = scratchRoot("first")
    let c = Counter()
    let got = reconcileServiceRegistrations(root, testKey(),
      @["isonim-site", "isonim-cli"],
      @["isonimPlatform", "isonimPlatform"], countingMinter(c))
    check c.calls == 2
    check got.set.registrations.len == 2
    check got.outcomes.len == 2
    for outcome in got.outcomes:
      check outcome.outcome == sroMinted
    check mintedIdFor(got.set, "isonim-site").len > 0
    check mintedIdFor(got.set, "isonim-cli") !=
      mintedIdFor(got.set, "isonim-site")

  test "a SECOND CONSUMER arriving leaves the first's identifier byte-identical":
    let root = scratchRoot("second")
    let key = testKey()
    let first = Counter()
    let before = reconcileServiceRegistrations(root, key,
      @["isonim-site"], @["isonimPlatform"], countingMinter(first))
    check first.calls == 1
    let firstId = mintedIdFor(before.set, "isonim-site")
    let firstMintedAt = before.set.registrations[0].mintedAtUnix
    check firstId.len > 0

    # A second consumer arrives, contributing its own member. Its
    # minter is a FRESH counter, so if the first's member were
    # re-registered the identifier would change AND the count would show
    # it.
    let second = Counter()
    let after = reconcileServiceRegistrations(root, key,
      @["isonim-site", "codetracer-ide"],
      @["isonimPlatform", "codetracer"], countingMinter(second))
    # BYTE-IDENTICAL.
    check mintedIdFor(after.set, "isonim-site") == firstId
    for reg in after.set.registrations:
      if reg.member == "isonim-site":
        check reg.mintedAtUnix == firstMintedAt
        check reg.contributor == "isonimPlatform"
    # AND THE MINTER WAS NOT CALLED FOR IT. This is the assertion a
    # deterministic minter cannot fake.
    check second.calls == 1
    check second.members == @["codetracer-ide"]
    # Both present afterwards, and each attributed to its own package.
    check after.set.registrations.len == 2
    var sawIsonim = false
    var sawCodetracer = false
    for reg in after.set.registrations:
      if reg.contributor == "isonimPlatform": sawIsonim = true
      if reg.contributor == "codetracer": sawCodetracer = true
    check sawIsonim
    check sawCodetracer
    # The outcomes name which was which.
    var reused = 0
    var minted = 0
    for outcome in after.outcomes:
      case outcome.outcome
      of sroReused: inc reused
      of sroMinted: inc minted
      of sroWithdrawn: discard
    check reused == 1
    check minted == 1

  test "a re-reconcile with the SAME members mints nothing":
    let root = scratchRoot("idem")
    let key = testKey()
    let first = Counter()
    let before = reconcileServiceRegistrations(root, key,
      @["a", "b"], @["p", "p"], countingMinter(first))
    let second = Counter()
    let after = reconcileServiceRegistrations(root, key,
      @["a", "b"], @["p", "p"], countingMinter(second))
    check second.calls == 0
    check encodeServiceRegistrations(after.set) ==
      encodeServiceRegistrations(before.set)

  test "withdrawing a contributor's member removes it and NOTHING else":
    let root = scratchRoot("withdraw")
    let key = testKey()
    let first = Counter()
    discard reconcileServiceRegistrations(root, key,
      @["isonim-site", "codetracer-ide"],
      @["isonimPlatform", "codetracer"], countingMinter(first))
    let firstSet = readServiceRegistrations(root, key)
    let keptId = mintedIdFor(firstSet, "isonim-site")
    let second = Counter()
    let after = reconcileServiceRegistrations(root, key,
      @["isonim-site"], @["isonimPlatform"], countingMinter(second))
    check second.calls == 0
    check after.set.registrations.len == 1
    check mintedIdFor(after.set, "isonim-site") == keptId
    check mintedIdFor(after.set, "codetracer-ide") == ""
    var withdrawn: seq[string] = @[]
    for outcome in after.outcomes:
      if outcome.outcome == sroWithdrawn:
        withdrawn.add(outcome.member)
    check withdrawn == @["codetracer-ide"]
    # And the removal is PERSISTED, not only reported.
    check readServiceRegistrations(root, key).registrations.len == 1

  test "the set survives a round trip through the real state store":
    let root = scratchRoot("store")
    let key = testKey()
    let c = Counter()
    let written = reconcileServiceRegistrations(root, key,
      @["m1", "m2"], @["pkgA", "pkgB"], countingMinter(c))
    let readBack = readServiceRegistrations(root, key)
    check encodeServiceRegistrations(readBack) ==
      encodeServiceRegistrations(written.set)
    check readBack.address == serviceRegistrationsAddress(key)

suite "L8: the registration lane refuses rather than inventing":

  test "a nil minter is a refusal, not a default":
    let root = scratchRoot("nilminter")
    var raised = false
    try:
      discard reconcileServiceRegistrations(root, testKey(), @["m"],
        @["p"], nil)
    except ServiceRegistryError as e:
      raised = true
      check "nil minter" in e.msg
    check raised

  test "an EMPTY minted identifier is a refusal (D-SS10)":
    let root = scratchRoot("empty")
    var raised = false
    try:
      discard reconcileServiceRegistrations(root, testKey(), @["m"],
        @["p"], proc (member, contributor: string): string {.closure.} = "")
    except ServiceRegistryError as e:
      raised = true
      check "EMPTY identifier" in e.msg
    check raised

  test "mismatched member/contributor lists are a refusal":
    let root = scratchRoot("mismatch")
    let c = Counter()
    var raised = false
    try:
      discard reconcileServiceRegistrations(root, testKey(),
        @["m1", "m2"], @["only-one"], countingMinter(c))
    except ServiceRegistryError as e:
      raised = true
      check "parallel by construction" in e.msg
    check raised

  test "a set written by a future version is refused by name":
    var raised = false
    try:
      discard decodeServiceRegistrations("service:x/registrations",
        "reprobuild.service-registrations.v99", "{}")
    except ValueError as e:
      raised = true
      check "v99" in e.msg
      check "re-mint every identifier" in e.msg
    check raised

  test "a registration row with no member is refused, not skipped":
    var raised = false
    try:
      discard decodeServiceRegistrations("service:x/registrations",
        ServiceRegistrationsAttrsTypeId,
        """{"registrations":[{"mintedId":"abc"}]}""")
    except ValueError as e:
      raised = true
      check "no `member`" in e.msg
    check raised

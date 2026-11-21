## Shared-Development-Services **§7.2** — A REGISTRATION IS REUSED ONLY BY
## THE REGISTRAR THAT MINTED IT, so §7.2's substitution cannot be rebuilt
## inside the fix for it.
##
## § THE DEFECT THIS FILE EXISTS FOR, AND IT WAS INTRODUCED BY A FIX
##
## §7.2 makes the provenance of a minted identifier a property of the
## installed registrar, applied at the write. L8 makes a registration
## **byte-stable**: "a member that already has a registration keeps its
## `mintedId` and its `mintedAtUnix` BYTE-IDENTICAL. `mint` is not called for
## it."
##
## Compose those two literally and the result is exactly the substitution
## §7.2 forbids. A workspace that ran `repro up` offline has rows minted by
## the development registrar; install the owning project's real registrar and
## run again, and every one of those rows is **reused** — the issuer is never
## asked — while the value now carries the issuer's provenance stamp, because
## the stamp comes from who is installed. The consumer then receives "a
## well-formed identifier that no issuer has ever heard of" with a stamp
## saying it did, which is worse than the state §7.2 set out to fix: there is
## now a mark, and it is wrong.
##
## So the registration record carries WHICH REGISTRAR minted it, and reuse
## requires that to match. A row minted by a different registrar is re-minted
## rather than reused. That is the one place L8's byte-stability is
## deliberately not absolute, and this file is where the boundary is drawn.
##
## § WHY THE DEFAULT PARAMETER IS PART OF THE TEST
##
## `reconcileServiceRegistrations`' `registrar` parameter defaults to `""`, so
## every pre-§7.2 caller keeps the exact behaviour it had: `""` matches `""`.
## A case below asserts that, because the alternative — a default that
## silently re-mints for every existing caller — would have shown up as a
## suite-wide behaviour change rather than as a decision.
##
## § MOCK POLICY — NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED.
##
## Every case drives the real `reconcileServiceRegistrations` against a real
## state store on the real filesystem, through the real JSON codec, and reads
## the result back with the real `readServiceRegistrations`. The MINTER is
## injected because that is the production shape (§7.2: reprobuild ships no
## product registrar); the minters here are two real, distinguishable
## registrars rather than doubles of one.

import std/[os, strutils, unittest]

import repro_project_dsl
import repro_resources/service_identity
import repro_resources/service_registry
import repro_resources/readiness_edge   # DevelopmentRegistrarName

const
  Members = @["isonim-site", "codetracer-cli"]
  Contributors = @["isonim", "codetracer"]
  IssuerRegistrar = "external:/opt/example/register-rp"

proc scratchRoot(tag: string): string =
  let root = getTempDir() / ("dss72-reuse-" & tag & "-" &
    $getCurrentProcessId())
  removeDir(root)
  createDir(root)
  root

proc testKey(): ServiceInstanceKey =
  serviceInstanceKey(
    DslServiceDef(
      packageName: "dss72Pkg",
      serviceName: "sso",
      identity: ServiceIdentityDef(kind: sikStable,
        stableId: "com.metacraft-labs.dss72-reuse"),
      scope: sscWorkspace),
    discoverServiceScopeContext(getCurrentDir()),
    environment = "dev")

type Calls = ref object
  members: seq[string]

proc taggedMinter(c: Calls; tag: string): ServiceRegistrationMinter =
  ## A registrar whose identifiers say who minted them, so a reused row
  ## and a re-minted one are distinguishable in the record itself.
  proc (member, contributor: string): string {.closure.} =
    c.members.add(member)
    tag & "-id-for-" & member

proc idFor(root: string; key: ServiceInstanceKey; member: string): string =
  mintedIdFor(readServiceRegistrations(root, key), member)

proc registrarFor(root: string; key: ServiceInstanceKey;
                  member: string): string =
  for reg in readServiceRegistrations(root, key).registrations:
    if reg.member == member:
      return reg.registrar
  ""

suite "§7.2 — reuse is keyed on the registrar, not on the member alone":

  test "the same registrar twice REUSES, byte-identical":
    # L8's property, unchanged where the registrar has not changed.
    let root = scratchRoot("same")
    let key = testKey()
    let first = Calls()
    let before = reconcileServiceRegistrations(root, key, Members,
      Contributors, taggedMinter(first, "dev"),
      registrar = DevelopmentRegistrarName)
    check first.members == Members
    let firstId = idFor(root, key, Members[0])
    let firstAt = before.set.registrations[0].mintedAtUnix
    let second = Calls()
    let after = reconcileServiceRegistrations(root, key, Members,
      Contributors, taggedMinter(second, "dev2"),
      registrar = DevelopmentRegistrarName)
    check second.members.len == 0          # the minter was not called
    check idFor(root, key, Members[0]) == firstId
    for reg in after.set.registrations:
      if reg.member == Members[0]:
        check reg.mintedAtUnix == firstAt
    for outcome in after.outcomes:
      check outcome.outcome == sroReused

  test "a DIFFERENT registrar RE-MINTS rather than reusing":
    # THE CLAUSE. The development registrar's rows are not handed to the
    # issuer's registrar to be stamped as the issuer's.
    let root = scratchRoot("switch")
    let key = testKey()
    let dev = Calls()
    discard reconcileServiceRegistrations(root, key, Members, Contributors,
      taggedMinter(dev, "dev"), registrar = DevelopmentRegistrarName)
    let devId = idFor(root, key, Members[0])
    check devId.startsWith("dev-id-for-")
    check registrarFor(root, key, Members[0]) == DevelopmentRegistrarName

    let issuer = Calls()
    let after = reconcileServiceRegistrations(root, key, Members,
      Contributors, taggedMinter(issuer, "issuer"),
      registrar = IssuerRegistrar)
    # Every member went back to the registrar.
    check issuer.members == Members
    for outcome in after.outcomes:
      check outcome.outcome == sroMinted
    # The record now holds the issuer's value, attributed to the issuer's
    # registrar, and the development value is GONE rather than carried
    # forward under a new stamp.
    check idFor(root, key, Members[0]).startsWith("issuer-id-for-")
    check idFor(root, key, Members[0]) != devId
    check registrarFor(root, key, Members[0]) == IssuerRegistrar
    check readServiceRegistrations(root, key).registrations.len ==
      Members.len

  test "switching BACK re-mints again, in the other direction":
    # Symmetry matters: an issuer row must not be reused by the
    # development registrar either, or an offline run would report a
    # development provenance over an identifier the issuer minted.
    let root = scratchRoot("back")
    let key = testKey()
    discard reconcileServiceRegistrations(root, key, Members, Contributors,
      taggedMinter(Calls(), "issuer"), registrar = IssuerRegistrar)
    let dev = Calls()
    discard reconcileServiceRegistrations(root, key, Members, Contributors,
      taggedMinter(dev, "dev"), registrar = DevelopmentRegistrarName)
    check dev.members == Members
    check idFor(root, key, Members[0]).startsWith("dev-id-for-")
    check registrarFor(root, key, Members[0]) == DevelopmentRegistrarName

  test "a row written before the field existed re-mints ONCE, then reuses":
    # A legacy record decodes with `registrar: \"\"`, which matches no
    # named registrar. One re-mint is the honest answer -- nothing
    # claimed that row -- and the run after it reuses, so the re-mint
    # does not repeat forever.
    let root = scratchRoot("legacy")
    let key = testKey()
    let legacy = Calls()
    discard reconcileServiceRegistrations(root, key, Members, Contributors,
      taggedMinter(legacy, "legacy"))         # no registrar named
    check registrarFor(root, key, Members[0]) == ""
    let firstNamed = Calls()
    discard reconcileServiceRegistrations(root, key, Members, Contributors,
      taggedMinter(firstNamed, "dev"),
      registrar = DevelopmentRegistrarName)
    check firstNamed.members == Members       # re-minted once
    let secondNamed = Calls()
    discard reconcileServiceRegistrations(root, key, Members, Contributors,
      taggedMinter(secondNamed, "dev"),
      registrar = DevelopmentRegistrarName)
    check secondNamed.members.len == 0        # and then reuses

  test "the DEFAULT parameter preserves the pre-§7.2 behaviour exactly":
    # Two reconciles that name nobody reuse, as every pre-§7.2 caller
    # does. Without this the new field would have changed the behaviour
    # of the whole existing suite rather than adding a decision.
    let root = scratchRoot("default")
    let key = testKey()
    discard reconcileServiceRegistrations(root, key, Members, Contributors,
      taggedMinter(Calls(), "a"))
    let again = Calls()
    let after = reconcileServiceRegistrations(root, key, Members,
      Contributors, taggedMinter(again, "b"))
    check again.members.len == 0
    for outcome in after.outcomes:
      check outcome.outcome == sroReused

  test "the registrar survives the real JSON codec":
    # The field has to make it through `encodeServiceRegistrations` /
    # `decodeServiceRegistrations`, or the reuse key is computed against
    # a value the record never carried -- which would re-mint on every
    # run and look like a flaky issuer.
    let root = scratchRoot("codec")
    let key = testKey()
    let written = reconcileServiceRegistrations(root, key, Members,
      Contributors, taggedMinter(Calls(), "issuer"),
      registrar = IssuerRegistrar)
    let text = encodeServiceRegistrations(written.set)
    check text.contains(IssuerRegistrar)
    let roundTripped = decodeServiceRegistrations(written.set.address,
      ServiceRegistrationsAttrsTypeId, text)
    check roundTripped.registrations.len == Members.len
    for reg in roundTripped.registrations:
      check reg.registrar == IssuerRegistrar

  test "a withdrawal is still a withdrawal under a named registrar":
    # §5's withdrawal property must not be collateral damage: a member no
    # longer contributed is removed, and the registrar key does not turn
    # that into a re-mint.
    let root = scratchRoot("withdraw")
    let key = testKey()
    discard reconcileServiceRegistrations(root, key, Members, Contributors,
      taggedMinter(Calls(), "dev"), registrar = DevelopmentRegistrarName)
    let after = reconcileServiceRegistrations(root, key, @[Members[0]],
      @[Contributors[0]], taggedMinter(Calls(), "dev"),
      registrar = DevelopmentRegistrarName)
    check after.set.registrations.len == 1
    var withdrawn = 0
    for outcome in after.outcomes:
      if outcome.outcome == sroWithdrawn:
        inc withdrawn
        check outcome.member == Members[1]
    check withdrawn == 1

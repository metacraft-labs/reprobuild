## Shared-Development-Services **§7.2 / L9 F5** — THE DURABLE REGISTRATION ROW
## CARRIES ITS PROVENANCE, AND A ROW WRITTEN BEFORE IT DID FAILS CLOSED.
##
## § WHY THE STAMP HAD TO BECOME DURABLE
##
## §7.2 put the stamp beside the value: `recordComputedResourceAttribute`
## applies `installedRegistrarIdentity.provenance` to everything recorded while
## a registrar is installed, and `@issuer-minted:<member>@` refuses anything
## that does not claim `issuer`. That table lives in the PROCESS that minted
## the value.
##
## L9 F5 is a consumer in ANOTHER project's session reading what a shared
## instance minted. That process has no registrar installed and never will —
## it attaches, it does not mint — so the only thing it can read is the
## durable record. A crossing that lost the stamp would hand it an identifier
## it cannot ask about, which is strictly worse than the refusal it replaces:
## the refusal at least says what went wrong. So `ServiceRegistration` carries
## `provenance`, and these cases are what hold it there.
##
## § THE FOUR THINGS THAT COULD GO WRONG, EACH A CASE
##
##   1. THE STAMP IS NOT CARRIED. Round-tripped through the real codec, for
##      each of the three words.
##   2. A PRE-§7.2 ROW IS GUESSED AT. A record written before the field
##      existed has no such key, and the one answer it must not be read as is
##      `issuer`. It reads `unstamped`, which is the truth about it, and
##      `@issuer-minted:` refuses it.
##   3. AN UNKNOWN WORD IS GUESSED AT, or raises. Neither: a word this build
##      cannot read is a claim it cannot evaluate, so it is `unstamped`. A
##      raise would turn a newer writer's row into a hard failure of every
##      identifier in the record, which `decodeServiceRegistrations`' own
##      comment names as the one failure the record exists to prevent.
##   4. THE ATTRS TYPE ID IS BUMPED for the new field. It must NOT be: the
##      decode refuses an attrs type it does not know, so a bump turns every
##      pre-§7.2 record into that refusal and re-mints every identifier in it.
##      Case 4 pins the id, which is the only thing that makes "added without
##      bumping" more than a sentence in a comment.
##
## And one property that is about the RELATION between the two new facts:
##
##   5. A REUSED ROW IS NOT RE-STAMPED. `registrar` is part of the reuse key,
##      so a row can only be reused by the registrar that minted it, and one
##      registrar has ONE provenance. Re-stamping a reused row from the
##      current caller would be §7.2's substitution rebuilt inside the fix for
##      it — and `t_dss72`'s own no-re-stamp control exists because the
##      session-file half was written that way first.
##
## § MOCKS: NONE, AND THE ONE INJECTION NAMED
##
## No test double, stub or fake. The real codec encodes and decodes real JSON;
## the real `reconcileServiceRegistrations` reads and writes a real state
## store under a real temporary directory on the real filesystem.
##
## The MINTER is a closure supplied by these cases, and that is not a mock: it
## is the injection point the library declares (`ServiceRegistrationMinter`),
## for the reason its own header gives — "the real implementation talks to a
## running service, which this library must not know how to do". `repro up`
## injects its own; here the cases inject one that counts its calls, because
## "`mint` was not called for a reused member" is exactly what mint-once
## means and it cannot be observed any other way.

import std/[json, os, strutils, tables, tempfiles, times, unittest]

import repro_project_dsl              # ServiceScope (`sscUser`)
import repro_resources/service_identity
import repro_resources/service_registry

proc key(): ServiceInstanceKey =
  ServiceInstanceKey(
    identity: "com.example.f5.provenance",
    scope: sscUser,
    environment: "development")

suite "§7.2 / L9 F5 — the durable registration row carries its provenance":
  test "each of the three words round-trips through the real codec":
    for word in RegistrarProvenance:
      let value = ServiceRegistrationSet(
        address: serviceRegistrationsAddress(key()),
        registrations: @[ServiceRegistration(
          member: "https://site.example.test:8443/callback",
          contributor: "someproduct",
          mintedId: "394610871109772528",
          mintedAtUnix: 1_760_000_000,
          registrar: "external:/opt/registrar.sh",
          provenance: word)])
      let encoded = encodeServiceRegistrations(value)
      # The key is in the document under the ONE spelling both documents
      # that carry a minted identifier share.
      check encoded.contains("\"" & MintedProvenanceField & "\":\"" &
        $word & "\"")
      let back = decodeServiceRegistrations(value.address,
        ServiceRegistrationsAttrsTypeId, encoded)
      check back.registrations.len == 1
      check back.registrations[0].provenance == word
      check back.registrations[0].mintedId == "394610871109772528"
      check back.registrations[0].registrar == "external:/opt/registrar.sh"

  test "the encoding is deterministic with the new field":
    # Two encodes of one set produce identical bytes, which is what the
    # record's own header requires of it. A field appended in a
    # nondeterministic position would make a byte comparison of two runs
    # report a change that is not one.
    let value = ServiceRegistrationSet(
      address: serviceRegistrationsAddress(key()),
      registrations: @[
        ServiceRegistration(member: "a", contributor: "p", mintedId: "1",
          mintedAtUnix: 7, registrar: "development",
          provenance: rprDevelopment),
        ServiceRegistration(member: "b", contributor: "q", mintedId: "2",
          mintedAtUnix: 8, registrar: "external:/x", provenance: rprIssuer)])
    check encodeServiceRegistrations(value) == encodeServiceRegistrations(value)

  test "a row written BEFORE the field existed reads `unstamped`":
    # The exact shape a pre-§7.2 build wrote: every other key present, no
    # `provenance` at all. THE ONE ANSWER IT MUST NOT BE READ AS IS `issuer`
    # — that is the substitution §7.2 exists to make impossible, and reading
    # an absent claim as the strongest one is how it would be rebuilt here.
    let legacy = $(%*{
      "attrsTypeId": ServiceRegistrationsAttrsTypeId,
      "registrations": [{
        "member": "https://site.example.test:8443/callback",
        "contributor": "someproduct",
        "mintedId": "394610871109772528",
        "mintedAtUnix": 1_750_000_000,
        "registrar": "external:/opt/registrar.sh"}]})
    let back = decodeServiceRegistrations("addr",
      ServiceRegistrationsAttrsTypeId, legacy)
    check back.registrations.len == 1
    check back.registrations[0].provenance == rprUnstamped
    check back.registrations[0].provenance != rprIssuer
    # The identifier itself is still readable, so the offline path a
    # pre-§7.2 workspace had is unchanged: `@minted:` resolves this row.
    check back.registrations[0].mintedId == "394610871109772528"

  test "an unknown provenance word reads `unstamped`, and does not raise":
    # A word from a FUTURE build. Not a guess (`issuer` would be the guess
    # that matters) and not a parse failure: raising would make one
    # unreadable row re-mint every identifier in the record.
    let future = $(%*{
      "attrsTypeId": ServiceRegistrationsAttrsTypeId,
      "registrations": [{
        "member": "m", "contributor": "p", "mintedId": "9",
        "mintedAtUnix": 1,
        MintedProvenanceField: "notarizedByAFutureAuthority"}]})
    var back: ServiceRegistrationSet
    # `decodeServiceRegistrations` must RETURN here rather than raise, so the
    # assertion is that this line does not throw and the stamp is the
    # fail-closed one.
    back = decodeServiceRegistrations("addr",
      ServiceRegistrationsAttrsTypeId, future)
    check back.registrations.len == 1
    check back.registrations[0].provenance == rprUnstamped
    # And the ONE decode is shared with the session file's reader, so the
    # two cannot disagree about this word.
    check parseRegistrarProvenance("notarizedByAFutureAuthority") ==
      rprUnstamped
    check parseRegistrarProvenance("") == rprUnstamped
    check parseRegistrarProvenance("issuer") == rprIssuer
    check parseRegistrarProvenance("development") == rprDevelopment

  test "the attrs type id did NOT move for this field":
    # THE PIN THAT MAKES "ADDED WITHOUT BUMPING" STRUCTURAL. The decode
    # refuses an attrs type it does not know, by name, because "reading it
    # anyway would re-mint every identifier in it, which is the one failure
    # this record exists to prevent". Bumping the id for an ADDITIVE field
    # would turn every record written before §7.2 into exactly that refusal.
    check ServiceRegistrationsAttrsTypeId ==
      "reprobuild.service-registrations.v1"
    # And the refusal is still reachable for an id that really is different,
    # which is what keeps this pin from being an argument against the guard.
    expect ValueError:
      discard decodeServiceRegistrations("addr",
        "reprobuild.service-registrations.v2",
        $(%*{"attrsTypeId": "reprobuild.service-registrations.v2"}))

  test "a reconcile stamps what it MINTS and never re-stamps what it REUSES":
    let root = createTempDir("repro-f5-prov-", "")
    defer:
      try: removeDir(root) except OSError, IOError: discard
    let k = key()
    var mintCalls = 0
    proc minter(member, contributor: string): string {.closure.} =
      inc mintCalls
      "mint-" & member
    # FIRST reconcile: the development registrar mints, and the row is
    # stamped `development`.
    let first = reconcileServiceRegistrations(root, k, @["alpha"],
      @["productA"], minter, registrar = "development",
      provenance = rprDevelopment)
    check mintCalls == 1
    check first.set.registrations.len == 1
    check first.set.registrations[0].provenance == rprDevelopment
    check first.outcomes[0].outcome == sroMinted

    # SECOND reconcile, SAME registrar, but the caller now claims `issuer`.
    # The row is REUSED, so `mint` is not called and the stamp does not
    # move. A re-stamp here is §7.2's substitution: the value is still the
    # offline digest and it would now claim the issuer produced it.
    let reused = reconcileServiceRegistrations(root, k, @["alpha"],
      @["productA"], minter, registrar = "development",
      provenance = rprIssuer)
    check mintCalls == 1
    check reused.outcomes[0].outcome == sroReused
    check reused.set.registrations[0].mintedId ==
      first.set.registrations[0].mintedId
    check reused.set.registrations[0].provenance == rprDevelopment

    # THIRD reconcile, a DIFFERENT registrar. `registrar` is part of the
    # reuse key, so the row is re-minted — and the new row takes the new
    # registrar's stamp, which is the other half of the same rule.
    let reminted = reconcileServiceRegistrations(root, k, @["alpha"],
      @["productA"], minter, registrar = "external:/opt/registrar.sh",
      provenance = rprIssuer)
    check mintCalls == 2
    check reminted.outcomes[0].outcome == sroMinted
    check reminted.set.registrations[0].provenance == rprIssuer
    check reminted.set.registrations[0].registrar ==
      "external:/opt/registrar.sh"

    # And it is DURABLE: read back through the store, by the same proc the
    # cross-session reader uses.
    let stored = readServiceRegistrations(root, k)
    check stored.registrations.len == 1
    check stored.registrations[0].provenance == rprIssuer

  test "a caller that names a registrar but no provenance claims nothing":
    # The DEFAULT is `rprUnstamped` and not the caller's word, because a
    # caller that supplied no provenance has made no claim. Every pre-§7.2
    # call site is this shape, and `unstamped` is the only answer that is not
    # a guess — `@minted:` resolves it, `@issuer-minted:` refuses it.
    let root = createTempDir("repro-f5-prov-default-", "")
    defer:
      try: removeDir(root) except OSError, IOError: discard
    proc minter(member, contributor: string): string {.closure.} =
      "mint-" & member
    let got = reconcileServiceRegistrations(root, key(), @["beta"],
      @["productB"], minter, registrar = "development")
    check got.set.registrations[0].provenance == rprUnstamped
    check got.set.registrations[0].registrar == "development"

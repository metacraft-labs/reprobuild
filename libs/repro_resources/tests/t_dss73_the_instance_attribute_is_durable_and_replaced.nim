## Shared-Development-Services **§7.3** — THE INSTANCE'S OWN ATTRIBUTES, ON
## THE DURABLE RECORD, AND WHAT MAKES A STALE ONE UNREACHABLE.
##
## §7.3 decides where the issuer URL lives:
##
## > **The decision: the issuer URL is a computed attribute OF THE INSTANCE,
## > reached by the same mechanism as the minted client id. It does not become
## > a field on the handle.**
##
## This file is the STORE half of that lane: `ServiceInstanceAttribute` rows on
## the same instance-keyed `ServiceRegistrationSet` the minted ids live on,
## written by `reconcileServiceInstanceAttributes`, read by whichever session
## asks — including a consumer in another project's `repro up`, which is the
## crossing L9's F5 opened for the minted half.
##
## § THE THREE PROPERTIES THIS FILE EXISTS FOR
##
##   1. **It round-trips.** A row written is the row read, stamp and all. An
##      attribute whose provenance did not survive the codec would arrive at
##      the point of use indistinguishable from a guess, which is §7.2's
##      defect one row set over.
##
##   2. **IT IS REPLACED, NOT MERGED.** This is the one place the attribute
##      lane deliberately differs from the registration lane, and the
##      difference is not an oversight: a minted client id MUST be reused
##      byte-for-byte across runs (re-minting silently invalidates whatever a
##      developer configured last week), while an issuer URL legitimately
##      MOVES when the instance rebinds. So `reconcileServiceInstanceAttributes`
##      replaces the whole set with what the registrar installed RIGHT NOW
##      answered. The case that matters is the offline one: a workspace that
##      converged against an issuer yesterday and converges with the
##      development registrar today must NOT serve yesterday's URL. That is
##      the `dev-server.sh` descriptor defect L9's review measured — a
##      registrar answering from the previous run — and it is closed here by
##      construction rather than by a check.
##
##   3. **NEITHER RECONCILE MAY CLEAR THE OTHER'S ROWS.** Both procs write the
##      whole record, so each one carries the other's rows forward. A missing
##      carry-forward is invisible in any single-purpose test and is exactly
##      the silent drop this campaign keeps finding: registrations would
##      survive and attributes would vanish on every converge, leaving a token
##      refusing for a reason that names no cause.
##
## § MOCK POLICY — NO MOCK OBJECTS
##
## There is no test double in this file. The state store is the real
## `openStateStore` over a real temporary directory, the codec is the real
## one, and the minter passed to `reconcileServiceRegistrations` is a real
## closure returning a real string — the injection point the library declares,
## not a substituted type. `ServiceRegistrationMinter` is INJECTED by design
## ("the real implementation talks to a running service, which this library
## must not know how to do"), so supplying one is using the interface, not
## mocking it.

import std/[os, strutils, tempfiles, unittest]

import repro_project_dsl                # ServiceScope (`sscUser`)
import repro_resources/service_identity
import repro_resources/service_registry
import repro_resources/readiness_edge   # IssuerAttributeName

const
  IssuerUrl = "https://login.metacraft-labs.test"
  MovedIssuerUrl = "https://login.metacraft-labs.test:8443"
  ExternalRegistrar = "external:/opt/infra/scripts/sso-register-relying-party.sh"
  Member = "isonim-site"
  MintedId = "394615916756821232"

proc testKey(): ServiceInstanceKey =
  ServiceInstanceKey(
    identity: "com.metacraft-labs.dss73.sso",
    scope: sscUser,
    environment: "development")

proc minterOf(value: string): ServiceRegistrationMinter =
  result = proc (member, contributor: string): string {.closure.} = value

suite "D-SS §7.3 — the instance attribute is durable":

  test "an attribute round-trips through the record's codec, stamp and all":
    let root = createTempDir("repro-dss73-store-", "")
    defer: removeDir(root)
    let key = testKey()
    let written = reconcileServiceInstanceAttributes(root, key,
      @[(name: IssuerAttributeName, value: IssuerUrl)],
      registrar = ExternalRegistrar, provenance = rprIssuer)
    check written.attributes.len == 1
    let back = readServiceRegistrations(root, key)
    check back.attributes.len == 1
    check back.attributes[0].name == IssuerAttributeName
    check back.attributes[0].value == IssuerUrl
    check back.attributes[0].registrar == ExternalRegistrar
    check back.attributes[0].provenance == rprIssuer
    check back.attributes[0].recordedAtUnix > 0

  test "the answer the registrar gives REPLACES a moved URL":
    let root = createTempDir("repro-dss73-store-", "")
    defer: removeDir(root)
    let key = testKey()
    discard reconcileServiceInstanceAttributes(root, key,
      @[(name: IssuerAttributeName, value: IssuerUrl)],
      registrar = ExternalRegistrar, provenance = rprIssuer)
    discard reconcileServiceInstanceAttributes(root, key,
      @[(name: IssuerAttributeName, value: MovedIssuerUrl)],
      registrar = ExternalRegistrar, provenance = rprIssuer)
    let back = readServiceRegistrations(root, key)
    check back.attributes.len == 1
    check back.attributes[0].value == MovedIssuerUrl

  test "AN OFFLINE CONVERGE REMOVES THE PREVIOUS RUN'S ISSUER URL":
    # THE ANTI-STALENESS PROPERTY, and the reason the attribute lane
    # replaces where the registration lane reuses. Yesterday this
    # workspace converged against an issuer; today it converges offline,
    # where the development registrar reports no attributes at all. A
    # merge would keep yesterday's URL and hand it to a consumer as this
    # instance's.
    let root = createTempDir("repro-dss73-store-", "")
    defer: removeDir(root)
    let key = testKey()
    discard reconcileServiceInstanceAttributes(root, key,
      @[(name: IssuerAttributeName, value: IssuerUrl)],
      registrar = ExternalRegistrar, provenance = rprIssuer)
    check readServiceRegistrations(root, key).attributes.len == 1
    discard reconcileServiceInstanceAttributes(root, key,
      @[], registrar = DevelopmentRegistrarName,
      provenance = rprDevelopment)
    check readServiceRegistrations(root, key).attributes.len == 0

  test "one reported attribute of two disappearing removes only that one":
    let root = createTempDir("repro-dss73-store-", "")
    defer: removeDir(root)
    let key = testKey()
    discard reconcileServiceInstanceAttributes(root, key,
      @[(name: IssuerAttributeName, value: IssuerUrl),
        (name: "adminApi", value: "https://admin.test")],
      registrar = ExternalRegistrar, provenance = rprIssuer)
    check readServiceRegistrations(root, key).attributes.len == 2
    discard reconcileServiceInstanceAttributes(root, key,
      @[(name: IssuerAttributeName, value: IssuerUrl)],
      registrar = ExternalRegistrar, provenance = rprIssuer)
    let back = readServiceRegistrations(root, key)
    check back.attributes.len == 1
    check back.attributes[0].name == IssuerAttributeName

suite "D-SS §7.3 — neither reconcile clears the other's rows":

  test "reconcileServiceRegistrations CARRIES THE ATTRIBUTES FORWARD":
    # THE CONTROL FOR THE SILENT DROP. `reconcileServiceRegistrations`
    # writes the whole record, so a set built without `attributes` would
    # erase every instance attribute on every converge -- and nothing in
    # the registration tests would notice.
    let root = createTempDir("repro-dss73-store-", "")
    defer: removeDir(root)
    let key = testKey()
    discard reconcileServiceInstanceAttributes(root, key,
      @[(name: IssuerAttributeName, value: IssuerUrl)],
      registrar = ExternalRegistrar, provenance = rprIssuer)
    discard reconcileServiceRegistrations(root, key, @[Member],
      @["isonim-platform"], minterOf(MintedId),
      registrar = ExternalRegistrar, provenance = rprIssuer)
    let back = readServiceRegistrations(root, key)
    check back.registrations.len == 1
    check back.attributes.len == 1
    check back.attributes[0].value == IssuerUrl
    check back.attributes[0].provenance == rprIssuer

  test "reconcileServiceInstanceAttributes CARRIES THE REGISTRATIONS FORWARD":
    let root = createTempDir("repro-dss73-store-", "")
    defer: removeDir(root)
    let key = testKey()
    discard reconcileServiceRegistrations(root, key, @[Member],
      @["isonim-platform"], minterOf(MintedId),
      registrar = ExternalRegistrar, provenance = rprIssuer)
    discard reconcileServiceInstanceAttributes(root, key,
      @[(name: IssuerAttributeName, value: IssuerUrl)],
      registrar = ExternalRegistrar, provenance = rprIssuer)
    let back = readServiceRegistrations(root, key)
    check back.attributes.len == 1
    check back.registrations.len == 1
    check back.registrations[0].mintedId == MintedId
    check back.registrations[0].provenance == rprIssuer

  test "a reconcile of registrations after one of attributes keeps BOTH":
    # The order the CLI runs them in, asserted as a pair rather than as
    # two one-way carries: the record after both calls is the record a
    # consumer in another session reads.
    let root = createTempDir("repro-dss73-store-", "")
    defer: removeDir(root)
    let key = testKey()
    discard reconcileServiceRegistrations(root, key, @[Member],
      @["isonim-platform"], minterOf(MintedId),
      registrar = ExternalRegistrar, provenance = rprIssuer)
    discard reconcileServiceInstanceAttributes(root, key,
      @[(name: IssuerAttributeName, value: IssuerUrl)],
      registrar = ExternalRegistrar, provenance = rprIssuer)
    discard reconcileServiceRegistrations(root, key, @[Member],
      @["isonim-platform"], minterOf("must-not-be-reached"),
      registrar = ExternalRegistrar, provenance = rprIssuer)
    let back = readServiceRegistrations(root, key)
    check back.attributes.len == 1
    check back.registrations.len == 1
    # Mint-once is untouched by any of this: the second reconcile reused
    # the stored row rather than calling the minter.
    check back.registrations[0].mintedId == MintedId

suite "D-SS §7.3 — a value nobody determined is refused":

  test "an EMPTY value is refused at the reconcile, naming the attribute":
    let root = createTempDir("repro-dss73-store-", "")
    defer: removeDir(root)
    var message = ""
    try:
      discard reconcileServiceInstanceAttributes(root, testKey(),
        @[(name: IssuerAttributeName, value: "")],
        registrar = ExternalRegistrar, provenance = rprIssuer)
      check false
    except CatchableError as err:
      message = err.msg
    check message.contains("`" & IssuerAttributeName & "`")
    check message.contains("EMPTY")
    check message.contains("must not be chosen")

  test "an EMPTY name is refused":
    let root = createTempDir("repro-dss73-store-", "")
    defer: removeDir(root)
    expect CatchableError:
      discard reconcileServiceInstanceAttributes(root, testKey(),
        @[(name: "", value: IssuerUrl)],
        registrar = ExternalRegistrar, provenance = rprIssuer)

  test "the same attribute reported twice is refused, not last-writer-wins":
    let root = createTempDir("repro-dss73-store-", "")
    defer: removeDir(root)
    var message = ""
    try:
      discard reconcileServiceInstanceAttributes(root, testKey(),
        @[(name: IssuerAttributeName, value: IssuerUrl),
          (name: IssuerAttributeName, value: MovedIssuerUrl)],
        registrar = ExternalRegistrar, provenance = rprIssuer)
      check false
    except CatchableError as err:
      message = err.msg
    check message.contains("twice")
    check message.contains(IssuerUrl)
    check message.contains(MovedIssuerUrl)

  test "a refused reconcile writes NOTHING, so the record is unchanged":
    # Validation happens before the read-modify-write, which is what
    # makes a refusal non-destructive. A refusal that had already
    # cleared the stored attributes would turn a bad answer into a lost
    # one.
    let root = createTempDir("repro-dss73-store-", "")
    defer: removeDir(root)
    let key = testKey()
    discard reconcileServiceInstanceAttributes(root, key,
      @[(name: IssuerAttributeName, value: IssuerUrl)],
      registrar = ExternalRegistrar, provenance = rprIssuer)
    expect CatchableError:
      discard reconcileServiceInstanceAttributes(root, key,
        @[(name: IssuerAttributeName, value: "")],
        registrar = ExternalRegistrar, provenance = rprIssuer)
    check readServiceRegistrations(root, key).attributes[0].value == IssuerUrl

  test "an unstamped reconcile records `unstamped`, never `issuer`":
    let root = createTempDir("repro-dss73-store-", "")
    defer: removeDir(root)
    let key = testKey()
    discard reconcileServiceInstanceAttributes(root, key,
      @[(name: IssuerAttributeName, value: IssuerUrl)])
    check readServiceRegistrations(root, key).attributes[0].provenance ==
      rprUnstamped

suite "D-SS §7.3 — the codec refuses what it must not read as absent":

  test "a record holding ONLY attributes decodes them":
    # The shape that would be dropped by decoding attributes after the
    # `registrations` early return: an instance whose consumers have all
    # withdrawn still has an issuer.
    let text = "{\"attrsTypeId\": \"" & ServiceRegistrationsAttrsTypeId &
      "\", \"" & InstanceAttributesField & "\": [{\"name\": \"" &
      IssuerAttributeName & "\", \"value\": \"" & IssuerUrl &
      "\", \"registrar\": \"" & ExternalRegistrar & "\", \"" &
      MintedProvenanceField & "\": \"issuer\"}]}"
    let back = decodeServiceRegistrations("service:x/registrations",
      ServiceRegistrationsAttrsTypeId, text)
    check back.registrations.len == 0
    check back.attributes.len == 1
    check back.attributes[0].value == IssuerUrl

  test "a stored row with an EMPTY value is refused by the decoder":
    let text = "{\"attrsTypeId\": \"" & ServiceRegistrationsAttrsTypeId &
      "\", \"" & InstanceAttributesField & "\": [{\"name\": \"" &
      IssuerAttributeName & "\", \"value\": \"\"}]}"
    var message = ""
    try:
      discard decodeServiceRegistrations("service:x/registrations",
        ServiceRegistrationsAttrsTypeId, text)
      check false
    except CatchableError as err:
      message = err.msg
    check message.contains("EMPTY")
    check message.contains(IssuerAttributeName)

  test "a stored row with no name is refused by the decoder":
    let text = "{\"attrsTypeId\": \"" & ServiceRegistrationsAttrsTypeId &
      "\", \"" & InstanceAttributesField & "\": [{\"value\": \"" &
      IssuerUrl & "\"}]}"
    expect CatchableError:
      discard decodeServiceRegistrations("service:x/registrations",
        ServiceRegistrationsAttrsTypeId, text)

  test "a record written by a build that predates the field decodes as none":
    # FAIL-CLOSED, not a parse failure: an absent key means this
    # instance reported no attributes, which is the truth about an old
    # record, and `@instance-attribute:` then refuses by name rather
    # than resolving something nothing claimed.
    let text = "{\"attrsTypeId\": \"" & ServiceRegistrationsAttrsTypeId &
      "\", \"registrations\": [{\"member\": \"" & Member &
      "\", \"mintedId\": \"" & MintedId & "\"}]}"
    let back = decodeServiceRegistrations("service:x/registrations",
      ServiceRegistrationsAttrsTypeId, text)
    check back.registrations.len == 1
    check back.attributes.len == 0

  test "a stored row with an unknown provenance word reads `unstamped`":
    let text = "{\"attrsTypeId\": \"" & ServiceRegistrationsAttrsTypeId &
      "\", \"" & InstanceAttributesField & "\": [{\"name\": \"" &
      IssuerAttributeName & "\", \"value\": \"" & IssuerUrl &
      "\", \"" & MintedProvenanceField & "\": \"from-the-future\"}]}"
    let back = decodeServiceRegistrations("service:x/registrations",
      ServiceRegistrationsAttrsTypeId, text)
    check back.attributes[0].provenance == rprUnstamped

  test "`issuer` the attribute name is not `issuer` the provenance word":
    # They are equal as strings and are compared against different
    # things. Pinned because a refactor that bound one to the other
    # would compile, pass every test that only reads one of them, and
    # make a rename of the provenance word silently rename the
    # attribute.
    check IssuerAttributeName == $rprIssuer
    check IssuerAttributeName != ClientIdAttributeName

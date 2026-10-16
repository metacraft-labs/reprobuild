## Shared-Development-Services L7 (§4.5) — THE `instance` DECLARATION
## SURFACE: every key it accepts is honoured, and every plausible
## misspelling, near-miss and wrong-shape spelling is REFUSED BY NAME.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every case calls the real `parseSharedServiceInstance` the CLI and the
## supervisor both call, over a real metadata string of the shape a real
## `servicePlaceholder` emits, and the skip cases run the real
## `derivedReadyTimeoutMs` over a real `DevEnvArtifact` value.
##
## WHY THE ENTRY POINT IS THE PARSER AND NOT `repro up`. Each declaration
## shape here would otherwise need its own project directory and its own
## provider compile — measured on this host at `478abb590`: a cold
## `repro up` in one fixture project spends about 40 s in
## `repro dev-env`, so the thirty-five probes below would be over twenty
## minutes of compiling to measure a function of one string. The CLI path
## for the
## declarations that DO converge is driven end to end by
## `tests/integration/t_l7_repro_up_converges_on_one_shared_instance.nim`
## against a real daemon; what is narrowed here is the entry point, and
## nothing is replaced.
##
## § THE STANDING HUNT THIS FILE IS
##
## The campaign's dominant finding is "constructs that are declared, look
## wired, and are silently dropped" — twenty instances so far, every one
## found by going looking. A JSON block read with `node{"key"}`
## accessors is the ideal habitat: every misspelling reads as absent and
## every absent key reads as a default. So the parser enumerates the keys
## it accepts and refuses everything else, and this file is the probe set
## that says so: for each spelling, either it is honoured or the refusal
## NAMES IT.
##
## THE SIZE OF THE PROBE SET IS A CONSTANT, NOT A SENTENCE. The seven
## groups are the module-level `const`s below, every loop iterates one of
## them, and `allRefusalProbes()` is asserted to hold THIRTY-FIVE
## spellings by a case of its own. Three prose numbers for one set is how
## a probe set silently shrinks: an earlier revision of this file said
## "twenty-eight" in this header and "Four shapes" over a loop of six,
## and its milestone drawer said "thirty-one" — none of which was the
## real count. Nothing here now states a number that is not read from
## the set.

import std/[json, os, strutils, unittest]

import cbor
import repro_dev_env_artifacts
import repro_project_dsl
import repro_resources/service_identity

import repro_cli_support/dev_session

const
  UnrecognisedKeyProbes* = [
    ## Twelve spellings a real author could write, including the
    ## camelCase/normalised pairs and the dotted-head shape that
    ## `issues/2026-10-08-service-body-setters-are-silently-dropped.md`
    ## records for the DSL's own setters.
    "identityKind", "stableId", "Scope", "SCOPE", "enviroment",
    "environmentName", "env", "leasePolicy", "ttl", "ttlSecs",
    "interface", "schemaId"
  ]
  DeclaredElsewhereKeyProbes* = ["identity", "scope"]
    ## The two an author is MOST likely to write, because §4.1 and §4.2
    ## are about them -- and they are declared on the typed `service`
    ## block instead.
  NonObjectInstanceProbes* = [
    ## SIX shapes, not four. `true` is the one worth naming: it is what
    ## an author writes when they think the block is a flag.
    "true", "false", "\"shared\"", "1", "[]", "null"
  ]
  InertTtlProbes* = [
    ## A `ttlSeconds` the policy in force would never read.
    """{"ttlSeconds":3600}""",
    """{"lease":"keep","ttlSeconds":3600}"""
  ]
  UnusableDelayedTtlProbes* = [
    """{"lease":"delayed"}""",
    """{"lease":"delayed","ttlSeconds":0}""",
    """{"lease":"delayed","ttlSeconds":-5}""",
    """{"lease":"delayed","ttlSeconds":"3600"}"""
  ]
  UnknownLeaseWordProbes* = ["forever", "Keep", "KEEP", "delay", "never", ""]
  WrongTypedAcceptedKeyProbes* = [
    """{"environment":7}""",
    """{"environment":["dev"]}""",
    """{"lease":3}"""
  ]

proc allRefusalProbes(): seq[string] =
  ## Every spelling the standing hunt below drives, in group order. The
  ## ONE place the size of the probe set is computed.
  result = @[]
  for probe in UnrecognisedKeyProbes: result.add(probe)
  for probe in DeclaredElsewhereKeyProbes: result.add(probe)
  for probe in NonObjectInstanceProbes: result.add(probe)
  for probe in InertTtlProbes: result.add(probe)
  for probe in UnusableDelayedTtlProbes: result.add(probe)
  for probe in UnknownLeaseWordProbes: result.add(probe)
  for probe in WrongTypedAcceptedKeyProbes: result.add(probe)

proc metadataWith(instanceBlock: string): string =
  ## A real dev-session service metadata document with `instanceBlock`
  ## spliced in as its `instance` value, or with no `instance` at all
  ## when it is empty.
  const head = "{\"schemaId\":\"reprobuild.dev-session.service.v1\"," &
    "\"command\":[\"sh\",\"scripts/sso.sh\"],\"cwd\":\".\""
  var doc = head
  if instanceBlock.len > 0:
    doc.add(",\"instance\":" & instanceBlock)
  doc.add("}")
  doc

proc parsed(instanceBlock: string): SharedServiceInstanceDeclaration =
  parseSharedServiceInstance("sso", metadataWith(instanceBlock))

proc refusalFor(instanceBlock: string): string =
  ## The refusal message, or `""` when the declaration was accepted.
  try:
    discard parsed(instanceBlock)
    ""
  except CatchableError as err:
    err.msg

suite "L7 — the `instance` block's accepted keys are honoured":
  test "no `instance` block at all is not a shared instance, and is not an error":
    let declaration = parsed("")
    check not declaration.declared
    check declaration.serviceName == "sso"
    # The DEFAULT policy is still reported, because a caller that reads
    # `leaseTtlSeconds` off an undeclared declaration must not get 0
    # (`immediate`), which would reap on the first sweep.
    check declaration.leaseTtlSeconds ==
      SharedServiceInstanceDefaultTtlSeconds

  test "an empty object declares a shared instance with every default":
    let declaration = parsed("{}")
    check declaration.declared
    check declaration.environment == ""
    # D-SS5's decision: `keep` (-1 on the wire) is the default.
    check declaration.leaseTtlSeconds == -1

  test "`environment` is read verbatim, after stripping":
    check parsed("""{"environment":"production"}""").environment ==
      "production"
    check parsed("""{"environment":"  dev  "}""").environment == "dev"
    check parsed("""{"environment":""}""").environment == ""

  test "each `lease` word maps to its wire encoding":
    check parsed("""{"lease":"keep"}""").leaseTtlSeconds == -1
    check parsed("""{"lease":"immediate"}""").leaseTtlSeconds == 0
    check parsed(
      """{"lease":"delayed","ttlSeconds":3600}""").leaseTtlSeconds == 3600

suite "L7 — the standing hunt: every near-miss is refused BY NAME":
  test "an unrecognised key is refused and the message names it":
    ## The generic arm: `UnrecognisedKeyProbes`, whose own comment says
    ## what the twelve spellings are and why each is plausible.
    for probe in UnrecognisedKeyProbes:
      let message = refusalFor("""{"""" & probe & """":"x"}""")
      checkpoint("probe: " & probe)
      check message.len > 0
      check message.contains(probe)
      # And the refusal says what IS accepted, so the author can fix it
      # from the message alone.
      check message.contains("environment")

  test "`identity` and `scope` are refused with the reason they are refused":
    ## These two are the ones an author is MOST likely to write, because
    ## §4.1 and §4.2 are about them — and they are declared on the typed
    ## `service` block instead. The refusal has to say so rather than
    ## only "unknown key", or the author will delete the wrong thing.
    ##
    ## Driven per key rather than in a loop, because the two refusals
    ## must cite DIFFERENT sections and a loop could only assert the
    ## shared part. The group const is still the authority on which keys
    ## those are, so it cannot drift from this case.
    check DeclaredElsewhereKeyProbes == ["identity", "scope"]
    let identityMessage = refusalFor(
      """{"identity":{"stable":"com.example.sso"}}""")
    check identityMessage.contains("identity")
    check identityMessage.contains("typed `service` block")
    check identityMessage.contains("§4.2")
    let scopeMessage = refusalFor("""{"scope":"workspace"}""")
    check scopeMessage.contains("scope")
    check scopeMessage.contains("typed `service` block")
    check scopeMessage.contains("§4.1")

  test "a non-object `instance` is refused rather than ignored":
    ## `NonObjectInstanceProbes` -- SIX shapes. An earlier revision of
    ## this comment said "Four shapes" over this same loop of six, which
    ## is why the set is now a named const with a counted assertion.
    ## `true` is the one worth naming: it is what an author writes when
    ## they think the block is a flag, and ignoring it would leave the
    ## service session-owned while its author believed it was shared.
    for probe in NonObjectInstanceProbes:
      let message = refusalFor(probe)
      checkpoint("probe: " & probe)
      check message.len > 0
      check message.contains("must be a JSON object")
      check message.contains("session-owned")

  test "`ttlSeconds` without `lease: delayed` is refused, not silently inert":
    ## The exact shape the hunt is for: the key parses, the value is a
    ## plausible number, and nothing reads it because the default policy
    ## has no deadline.
    ## `InertTtlProbes`: the implicit default first, then `keep` spelled
    ## out explicitly, which is the same situation one step more
    ## deliberate.
    let message = refusalFor(InertTtlProbes[0])
    check message.contains("ttlSeconds")
    check message.contains("read by nothing")
    let withKeep = refusalFor(InertTtlProbes[1])
    check withKeep.len > 0
    check withKeep.contains("ttlSeconds")

  test "`lease: delayed` without a usable ttl is refused":
    for probe in UnusableDelayedTtlProbes:
      checkpoint("probe: " & probe)
      let message = refusalFor(probe)
      check message.len > 0
      check message.contains("positive")

  test "an unknown `lease` word is refused and the words are named":
    for probe in UnknownLeaseWordProbes:
      checkpoint("probe: " & probe)
      let message = refusalFor("""{"lease":"""" & probe & """"}""")
      check message.len > 0
      check message.contains("keep, immediate, delayed")

  test "a wrong-typed accepted key is refused rather than coerced":
    for probe in WrongTypedAcceptedKeyProbes:
      checkpoint("probe: " & probe)
      let message = refusalFor(probe)
      check message.len > 0
      check (message.contains("environment") or message.contains("lease"))

  test "the probe set is THIRTY-FIVE spellings, and every group is driven":
    ## The one place a number about this file is stated, and it is read
    ## from the set rather than written in prose. A probe set that
    ## shrinks silently is the same defect class this file hunts, and
    ## three disagreeing prose counts is how it stayed invisible.
    let all = allRefusalProbes()
    check all.len == 35
    check UnrecognisedKeyProbes.len == 12
    check DeclaredElsewhereKeyProbes.len == 2
    check NonObjectInstanceProbes.len == 6
    check InertTtlProbes.len == 2
    check UnusableDelayedTtlProbes.len == 4
    check UnknownLeaseWordProbes.len == 6
    check WrongTypedAcceptedKeyProbes.len == 3
    # And the groups do not overlap, so 35 is a count of DISTINCT
    # spellings rather than a sum with a double-counted member.
    var seen: seq[string] = @[]
    for probe in all:
      check probe notin seen
      seen.add(probe)

  test "a second `instance` key is the one JSON itself decides, and the result is still parsed":
    ## A duplicate key is not something this parser can see: `parseJson`
    ## keeps the LAST occurrence and the parser is handed one object. So
    ## the honest assertion is what actually happens, not a refusal this
    ## code could not produce — measured, so a reader is not left
    ## believing a duplicate is caught.
    let declaration = parseSharedServiceInstance("sso",
      """{"command":["sh"],"instance":{"environment":"a"},""" &
      """"instance":{"environment":"b"}}""")
    check declaration.declared
    check declaration.environment == "b"

  test "metadata that is not JSON at all is refused, naming the service":
    let message = refusalFor("")
    check message.len == 0 # no `instance` key => not declared
    var raised = ""
    try:
      discard parseSharedServiceInstance("sso", "{not json")
    except CatchableError as err:
      raised = err.msg
    check raised.contains("sso")
    check raised.contains("not JSON")

  test "metadata that is valid JSON but not an object is not a declaration":
    ## `serviceSpecFromSummary` is the thing that refuses a service whose
    ## metadata is unusable, and it does so a moment later naming the
    ## service. This parser's job is only to answer "is this a shared
    ## instance", and for a non-object document the answer is no.
    check not parseSharedServiceInstance("sso", "[]").declared
    check not parseSharedServiceInstance("sso", "\"x\"").declared

suite "L7 — a shared instance is excluded from the session the supervisor runs":
  proc summary(name, instanceBlock: string): DevEnvServiceSummary =
    DevEnvServiceSummary(name: name,
      metadata: cborText("""{"schemaId":"reprobuild.dev-session.service.v1",""" &
        """"command":["sh","scripts/""" & name & """.sh"],"cwd":".",""" &
        """"readiness":{"kind":"fileExists","path":"state/""" & name &
        """.ready","timeoutMs":7000}""" &
        (if instanceBlock.len > 0: ""","instance":""" & instanceBlock
          else: "") & "}"))

  test "the readiness budget counts only the services the supervisor starts":
    ## The budget is the parent's patience, and §4.5 makes a shared
    ## instance something the parent is NOT waiting for: the supervisor
    ## does not start it. Counting it would make `repro up` wait for a
    ## service nothing is waiting on — the same two-processes-disagree-
    ## about-a-duration defect the derivation was introduced to fix.
    let sessionOwned = DevEnvArtifact(services: @[
      summary("db", ""), summary("api", "")])
    let oneShared = DevEnvArtifact(services: @[
      summary("db", ""), summary("sso", """{"environment":"dev"}""")])
    let allShared = DevEnvArtifact(services: @[
      summary("sso", """{"environment":"dev"}""")])
    # Two session-owned services at 7000 ms each, plus the margin.
    check derivedReadyTimeoutMs(sessionOwned) ==
      14_000 + DevSessionReadyMarginMs
    # One of the two is shared: only the other one's timeout counts.
    check derivedReadyTimeoutMs(oneShared) ==
      7000 + DevSessionReadyMarginMs
    # And a session whose only service is shared waits the bare margin —
    # which is the number this budget was before it was derived at all.
    check derivedReadyTimeoutMs(allShared) == DevSessionReadyMarginMs

  test "a declaration that cannot be parsed fails the budget LOUDLY, not leniently":
    ## `declaredReadinessTimeoutMs` is deliberately lenient about
    ## unparsable metadata, and the shared-instance skip must NOT inherit
    ## that leniency in the one direction that matters: a malformed
    ## `instance` block must not read as "not shared", because the
    ## service would then be started by this session AND by every other
    ## one.
    let malformed = DevEnvArtifact(services: @[
      summary("sso", """{"identity":{"stable":"x"}}""")])
    expect ValueError:
      discard derivedReadyTimeoutMs(malformed)

suite "L7 — the instance key is resolved from the lift, not from the JSON":
  test "a `derived` identity is refused where it cannot be computed":
    ## §4.2's default is `derived`, and `repro up`'s dev-session path has
    ## no materialised service closure to digest. Resolving one anyway
    ## would hand every service the digest of an empty definition — one
    ## instance for all of them.
    let declaration = parsed("""{"environment":"dev"}""")
    var raised = ""
    try:
      discard sharedServiceInstanceKey(declaration, getCurrentDir(),
        ServiceIdentityDef(kind: sikDerived), sscWorkspace)
    except CatchableError as err:
      raised = err.msg
    check raised.contains("derived")
    check raised.contains("§4.2")
    check raised.contains("identity stable")

  test "a stable identity yields the key the registry is addressed by":
    let declaration = parsed("""{"environment":"dev"}""")
    let key = sharedServiceInstanceKey(declaration, getCurrentDir(),
      ServiceIdentityDef(kind: sikStable, stableId: "com.example.l7.sso"),
      sscUser)
    check key.identityKind == sikStable
    check key.identity == "com.example.l7.sso"
    check key.scope == sscUser
    check key.environment == "dev"
    # And the environment really is part of the address, so two
    # environments are two instances (§6.5).
    let other = sharedServiceInstanceKey(
      parsed("""{"environment":"production"}"""), getCurrentDir(),
      ServiceIdentityDef(kind: sikStable, stableId: "com.example.l7.sso"),
      sscUser)
    check serviceInstanceAddress(other) != serviceInstanceAddress(key)
